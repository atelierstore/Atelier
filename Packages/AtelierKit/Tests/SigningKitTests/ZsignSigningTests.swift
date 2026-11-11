#if os(macOS) && canImport(Zsign)
import Foundation
import XCTest
import ZIPFoundation
@testable import SigningKit

/// Signs real iOS binaries with zsign and checks the result with Apple's
/// `codesign`. The binaries are compiled here with the iOS SDK, so these
/// tests skip on a Mac without Xcode.
///
/// `codesign --verify` needs a certificate issued by Apple: zsign puts Apple's
/// own developer CA certificates in every signature and writes Apple's
/// designated requirement, neither of which the throwaway certificate from
/// make-fixtures.sh can satisfy. So CI signs with the Signulous certificate
/// when its .p12 is in Codemagic's
/// secrets, passing a folder with identity.p12, password.txt and
/// profile.mobileprovision in ATELIER_SIGNING_IDENTITY (see codemagic.yaml).
/// Without it the tests sign with the throwaway certificate and check
/// everything but codesign's verdict.
final class ZsignSigningTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		guard (try? Shell.run("xcrun", "--sdk", "iphoneos", "--show-sdk-path"))?.status == 0 else {
			throw XCTSkip("The iOS SDK isn't installed.")
		}
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		if let folder { try? FileManager.default.removeItem(at: folder) }
	}

	func testSignsASingleApp() async throws {
		let app = try await sign(layout: [])
		try assertSigned(app, code: app)
	}

	func testSignsAnAppWithAnExtension() async throws {
		let app = try await sign(layout: [.appExtension])
		try assertSigned(app, code: app.appendingPathComponent("PlugIns/Widget.appex"))
	}

	func testSignsAnAppWithFrameworks() async throws {
		let app = try await sign(layout: [.framework, .dylib])
		try assertSigned(app, code: app.appendingPathComponent("Frameworks/Kit.framework"))
		try assertSigned(app, code: app.appendingPathComponent("Frameworks/libExtra.dylib"))
	}

	/// The app asks for its own keychain groups, under the developer's
	/// team; zsign signs the app and its widget with them moved to the
	/// signing team, and everything else from the profile (#7).
	func testSignsWithTheFittedEntitlements() async throws {
		let entitlements: [String: Any] = [
			"application-identifier": "DEVTEAM123.com.example.signingtest",
			"keychain-access-groups": ["DEVTEAM123.com.example.signingtest", "DEVTEAM123.com.example.shared"],
		]
		let app = try await sign(layout: [.appExtension], entitlements: entitlements)
		try assertSigned(app, code: app)
		let test = try TestIdentity.current
		for binary in ["SigningTest", "PlugIns/Widget.appex/Widget"] {
			let data = try XCTUnwrap(MachO.entitlements(app.appendingPathComponent(binary)), "\(binary) has no entitlements")
			let signed = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
			XCTAssertEqual(signed["keychain-access-groups"] as? [String], ["\(test.team).com.example.signingtest", "\(test.team).com.example.shared"], binary)
			XCTAssertEqual((signed["application-identifier"] as? String)?.hasPrefix("\(test.team)."), true, binary)
		}
	}

	/// Atelier's App Groups library (#49) builds for iOS, and an app and
	/// its widget that load it, weakly, from the app's Frameworks, still
	/// sign and pass codesign, the library too.
	func testAnAppLoadingTheAppGroupsLibrarySigns() async throws {
		let library = try FixtureApp.appGroupsLibrary(sdk: "iphoneos", in: folder)
		let ipa = try FixtureApp.build(layout: [.appExtension], in: folder)
		let unpacked = folder.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.unzipItem(at: ipa, to: unpacked)
		let app = unpacked.appendingPathComponent("Payload/SigningTest.app")
		let engine = ZsignEngine()
		XCTAssertTrue(try AppGroupRedirect.apply(["group.com.example.signingtest": "group.com.example.signingtest.TEAM"], library: library, to: app) { engine.load($0, into: $1) })
		// An executable that loads it already gets no second load command.
		XCTAssertTrue(engine.load(AppGroupRedirect.appPath, into: app.appendingPathComponent("SigningTest")))
		for (binary, path) in [("SigningTest", AppGroupRedirect.appPath), ("PlugIns/Widget.appex/Widget", AppGroupRedirect.extensionPath)] {
			let commands = try Shell.run("xcrun", "otool", "-l", app.appendingPathComponent(binary).path)
			XCTAssertEqual(commands.status, 0, commands.output)
			XCTAssertEqual(commands.output.components(separatedBy: "name \(path) (offset").count - 1, 1, commands.output)
			XCTAssertTrue(commands.output.contains("cmd LC_LOAD_WEAK_DYLIB"), commands.output)
		}

		let repacked = folder.appendingPathComponent("\(UUID().uuidString).ipa")
		try FileManager.default.zipItem(at: unpacked.appendingPathComponent("Payload"), to: repacked, compressionMethod: .deflate)
		let signed = try await SigningKit.sign(ipa: repacked, with: try TestIdentity.current.identity, options: SigningOptions(compressed: true), outputDirectory: folder)
		let result = folder.appendingPathComponent("signed-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.unzipItem(at: signed.url, to: result)
		let signedApp = result.appendingPathComponent("Payload/SigningTest.app")
		try assertSigned(signedApp, code: signedApp.appendingPathComponent("Frameworks/AtelierAppGroups.dylib"))
		try assertSigned(signedApp, code: signedApp.appendingPathComponent("PlugIns/Widget.appex"))
	}

	/// The library sends the app's own names for its groups to the ones in
	/// its Info.plist, and leaves other names alone: run on this Mac, in a
	/// tool that loads it as an app would, with the names in the Info.plist
	/// in its binary.
	func testTheAppGroupsLibrarySendsTheAppsNamesOn() throws {
		let library = try FixtureApp.appGroupsLibrary(sdk: "macosx", in: folder)
		let own = "group.com.example.signingtest.\(UUID().uuidString.prefix(8))"
		let team = own + ".TEAMID1234"
		let source = folder.appendingPathComponent("tool.m")
		try Data("""
		#import <Foundation/Foundation.h>
		int main(void) {
			@autoreleasepool {
				NSString *own = @"\(own)", *team = @"\(team)";
				NSUserDefaults *asked = [[NSUserDefaults alloc] initWithSuiteName:own];
				[asked setObject:@"shared" forKey:@"AtelierAppGroupsTest"];
				NSUserDefaults *teams = [[NSUserDefaults alloc] initWithSuiteName:team];
				printf("suite %s\\n", ([teams stringForKey:@"AtelierAppGroupsTest"] ?: @"none").UTF8String);
				[teams setObject:@"found" forKey:@"AtelierAppGroupsAdded"];
				NSUserDefaults *added = [[NSUserDefaults alloc] initWithSuiteName:@"atelier.unrelated"];
				[added addSuiteNamed:own];
				printf("added %s\\n", ([added stringForKey:@"AtelierAppGroupsAdded"] ?: @"none").UTF8String);
				[NSUserDefaults.standardUserDefaults removePersistentDomainForName:team];
				[NSUserDefaults.standardUserDefaults removePersistentDomainForName:own];
				NSURL *ownFolder = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:own];
				NSURL *teamFolder = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:team];
				NSURL *otherFolder = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.example.other"];
				printf("folder %s %s\\n", (ownFolder.lastPathComponent ?: @"none").UTF8String, (teamFolder.lastPathComponent ?: @"none").UTF8String);
				printf("other %s\\n", (otherFolder.lastPathComponent ?: @"none").UTF8String);
			}
			return 0;
		}
		""".utf8).write(to: source)
		let output = try runAppGroupsTool(source: source, library: library, info: [AppGroupRedirect.infoKey: [own: team]])
		let lines = output.split(separator: "\n").map(String.init)
		XCTAssertTrue(lines.contains("suite shared"), output)
		XCTAssertTrue(lines.contains("added found"), output)
		// macOS can refuse group folders to a tool; when it gives one, it's the team's.
		if let folders = lines.first(where: { $0.hasPrefix("folder ") }), !folders.hasSuffix(" none") {
			XCTAssertEqual(folders, "folder \(team) \(team)", output)
		}
		XCTAssertTrue(lines.contains("other group.com.example.other") || lines.contains("other none"), output)
	}

	/// What the library relies on to keep a group's settings in a folder
	/// with a certificate: Foundation keeps settings it's given a folder for
	/// in that folder's Library/Preferences, in a file named after them, as
	/// iOS keeps a group's in its folder.
	func testFoundationKeepsSettingsInTheFolderItIsGiven() throws {
		let container = folder.appendingPathComponent("container", isDirectory: true)
		try FileManager.default.createDirectory(at: container.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
		let suite = "group.com.example.signingtest.\(UUID().uuidString.prefix(8))"
		let source = folder.appendingPathComponent("settings.m")
		try Data("""
		#import <Foundation/Foundation.h>
		@interface NSUserDefaults (Container)
		- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
		@end
		int main(void) {
			@autoreleasepool {
				if (![NSUserDefaults instancesRespondToSelector:@selector(_initWithSuiteName:container:)]) { printf("missing\\n"); return 0; }
				NSURL *container = [NSURL fileURLWithPath:@"\(container.path)" isDirectory:YES];
				NSUserDefaults *settings = [[NSUserDefaults alloc] _initWithSuiteName:@"\(suite)" container:container];
				[settings setObject:@"kept" forKey:@"AtelierAppGroupsTest"];
				[settings synchronize];
				NSUserDefaults *again = [[NSUserDefaults alloc] _initWithSuiteName:@"\(suite)" container:container];
				printf("read %s\\n", ([again stringForKey:@"AtelierAppGroupsTest"] ?: @"none").UTF8String);
				NSUserDefaults *elsewhere = [[NSUserDefaults alloc] initWithSuiteName:@"\(suite)"];
				printf("elsewhere %s\\n", ([elsewhere stringForKey:@"AtelierAppGroupsTest"] ?: @"none").UTF8String);
			}
			return 0;
		}
		""".utf8).write(to: source)
		let tool = folder.appendingPathComponent("settings")
		let built = try Shell.run("xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-o", tool.path, source.path)
		XCTAssertEqual(built.status, 0, built.output)
		let output = try Self.runTool(tool)
		let lines = output.split(separator: "\n").map(String.init)
		XCTAssertTrue(lines.contains("read kept"), output)
		XCTAssertTrue(lines.contains("elsewhere none"), "not where settings of that name are kept otherwise: \(output)")
		let file = container.appendingPathComponent("Library/Preferences/\(suite).plist")
		var written: [String: Any]?
		for _ in 0..<20 where written == nil {
			written = (try? Data(contentsOf: file)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
			if written == nil { Thread.sleep(forTimeInterval: 0.1) }
		}
		XCTAssertEqual(written?["AtelierAppGroupsTest"] as? String, "kept", "in \(file.path)")
	}

	/// With a certificate, the library keeps the app's groups in folders of
	/// their own in the certificate's group, and their settings in those:
	/// run on this Mac, as above. macOS can refuse group folders to a tool,
	/// and then the app's are where they'd be without a group.
	func testTheAppGroupsLibraryKeepsTheAppsGroupsInFolders() throws {
		let library = try FixtureApp.appGroupsLibrary(sdk: "macosx", in: folder)
		let id = UUID().uuidString.prefix(8)
		let own = "group.com.example.signingtest.\(id)"
		let home = "group.com.example.signingtest.certificate.\(id)"
		let source = folder.appendingPathComponent("tool.m")
		try Data("""
		#import <Foundation/Foundation.h>
		int main(void) {
			@autoreleasepool {
				NSURL *home = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"\(home)"];
				NSURL *own = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"\(own.uppercased())"];
				printf("home %s\\n", (home.path ?: @"none").UTF8String);
				printf("folder %s\\n", (own.path ?: @"none").UTF8String);
				NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"\(own)"];
				[settings setObject:@"kept" forKey:@"AtelierAppGroupsTest"];
				[settings synchronize];
				NSUserDefaults *again = [[NSUserDefaults alloc] initWithSuiteName:@"\(own)"];
				printf("settings %s\\n", ([again stringForKey:@"AtelierAppGroupsTest"] ?: @"none").UTF8String);
				[again removeObjectForKey:@"AtelierAppGroupsTest"];
			}
			return 0;
		}
		""".utf8).write(to: source)
		let output = try runAppGroupsTool(source: source, library: library, info: [
			AppGroupRedirect.infoKey: [own: home],
			AppGroupRedirect.foldersKey: [own: "Atelier/\(own)"],
		])
		let lines = output.split(separator: "\n").map(String.init)
		XCTAssertTrue(lines.contains("settings kept"), output)
		let homePath = try XCTUnwrap(lines.first { $0.hasPrefix("home ") }).dropFirst("home ".count)
		guard homePath != "none" else {
			XCTAssertTrue(lines.contains("folder none"), output)
			return
		}
		let groupFolder = URL(fileURLWithPath: String(homePath), isDirectory: true)
		// Only the test's own group, which is named after its ID.
		defer { if groupFolder.lastPathComponent == home { try? FileManager.default.removeItem(at: groupFolder) } }
		// macOS gives its URL, but may not let anything be written there.
		guard (try? FileManager.default.createDirectory(at: groupFolder, withIntermediateDirectories: true)) != nil else { return }
		let kept = groupFolder.appendingPathComponent("Atelier/\(own)", isDirectory: true)
		XCTAssertTrue(lines.contains("folder \(kept.path)"), output)
		var isDirectory: ObjCBool = false
		XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("Library/Caches").path, isDirectory: &isDirectory) && isDirectory.boolValue)
		// Its settings, and the library's check that they're kept there.
		XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("Library/Preferences/\(own).plist").path), output)
		XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("Library/Preferences/\(own).atelier-check.plist").path), output)
	}

	/// Settings an app saved under its group's own name while it had none,
	/// which iOS kept in its own folder, move to where the library sends
	/// the name, once, without replacing what's there: run on this Mac as an
	/// app, since only the app moves them.
	func testTheAppGroupsLibraryMovesAnAppsSettingsOnce() throws {
		let library = try FixtureApp.appGroupsLibrary(sdk: "macosx", in: folder)
		let own = "group.com.example.signingtest.\(UUID().uuidString.prefix(8))"
		let team = own + ".TEAMID1234"
		let record = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/AtelierAppGroups.plist")
		let before = try? Data(contentsOf: record)
		defer {
			UserDefaults.standard.removePersistentDomain(forName: own)
			UserDefaults.standard.removePersistentDomain(forName: team)
			if let before { try? before.write(to: record) } else { try? FileManager.default.removeItem(at: record) }
		}
		let saved = try XCTUnwrap(UserDefaults(suiteName: own))
		saved.set("before", forKey: "AtelierAppGroupsMoved")
		saved.set("before", forKey: "AtelierAppGroupsThere")
		let there = try XCTUnwrap(UserDefaults(suiteName: team))
		there.set("there", forKey: "AtelierAppGroupsThere")
		XCTAssertTrue(CFPreferencesAppSynchronize(own as CFString) && CFPreferencesAppSynchronize(team as CFString))

		let source = folder.appendingPathComponent("tool.m")
		try Data("""
		#import <Foundation/Foundation.h>
		int main(void) {
			@autoreleasepool {
				NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:@"\(own)"];
				printf("moved %s\\n", ([settings stringForKey:@"AtelierAppGroupsMoved"] ?: @"none").UTF8String);
				printf("there %s\\n", ([settings stringForKey:@"AtelierAppGroupsThere"] ?: @"none").UTF8String);
				[settings removeObjectForKey:@"AtelierAppGroupsMoved"];
				[settings synchronize];
			}
			return 0;
		}
		""".utf8).write(to: source)
		let info: [String: Any] = [AppGroupRedirect.infoKey: [own: team]]
		var lines = try runAppGroupsTool(source: source, library: library, info: info, asApp: true).split(separator: "\n").map(String.init)
		XCTAssertTrue(lines.contains("moved before"), "\(lines)")
		XCTAssertTrue(lines.contains("there there"), "\(lines)")
		// Removed by the app, it stays removed.
		lines = try runAppGroupsTool(source: source, library: library, info: info, asApp: true).split(separator: "\n").map(String.init)
		XCTAssertTrue(lines.contains("moved none"), "\(lines)")
		XCTAssertTrue(lines.contains("there there"), "\(lines)")
	}

	/// Builds `source` into a tool that loads the App Groups library as
	/// Atelier has apps load it, with `info` in its Info.plist, as an app's
	/// bundle when `asApp`, runs it and returns what it printed.
	private func runAppGroupsTool(source: URL, library: URL, info: [String: Any], asApp: Bool = false) throws -> String {
		let root = folder.appendingPathComponent("tool-\(UUID().uuidString)", isDirectory: true)
		let executables = asApp ? root.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true) : root
		let frameworks = executables.appendingPathComponent("Frameworks", isDirectory: true)
		try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: library, to: frameworks.appendingPathComponent(AppGroupRedirect.fileName))
		let plist = root.appendingPathComponent("Info.plist")
		var values = info
		values["CFBundleIdentifier"] = "com.example.appgroupstool"
		values["CFBundleExecutable"] = "tool"
		try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
		if asApp { try FileManager.default.copyItem(at: plist, to: root.appendingPathComponent("Tool.app/Contents/Info.plist")) }
		let tool = executables.appendingPathComponent("tool")
		// With room for another load command, which a macOS tool's
		// headers don't leave by themselves.
		let built = try Shell.run("xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-Wl,-headerpad,0x1000", "-Wl,-sectcreate,__TEXT,__info_plist,\(plist.path)", "-o", tool.path, source.path)
		XCTAssertEqual(built.status, 0, built.output)
		// Loaded as Atelier has apps load it, then signed again for macOS to run it.
		XCTAssertTrue(ZsignEngine().load(AppGroupRedirect.appPath, into: tool))
		let resigned = try Shell.run("codesign", "--force", "--sign", "-", tool.path)
		XCTAssertEqual(resigned.status, 0, resigned.output)
		return try Self.runTool(tool)
	}

	/// Runs `tool` and returns what it printed, once it exited cleanly.
	private static func runTool(_ tool: URL) throws -> String {
		let process = Process()
		process.executableURL = tool
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()
		XCTAssertEqual(process.terminationStatus, 0, output)
		return output
	}

	func testWrongPasswordIsABadCertificate() async throws {
		let ipa = try FixtureApp.build(layout: [], in: folder)
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: "wrong")
		do {
			_ = try await SigningKit.sign(ipa: ipa, with: identity, outputDirectory: folder)
			XCTFail("expected badCertificate")
		} catch SigningError.badCertificate {}
	}

	// MARK: Helpers

	/// Builds an IPA, signs it, and returns the signed .app, unpacked.
	private func sign(layout: Set<FixtureApp.Part>, entitlements: [String: Any]? = nil) async throws -> URL {
		let ipa = try FixtureApp.build(layout: layout, entitlements: entitlements, in: folder)
		let signed = try await SigningKit.sign(ipa: ipa, with: try TestIdentity.current.identity, options: SigningOptions(compressed: true), outputDirectory: folder)
		XCTAssertEqual(signed.info.bundleID, "com.example.signingtest")
		XCTAssertNotNil(signed.entitlements, "the profile couldn't be read for the entitlements report")
		let unpacked = folder.appendingPathComponent("signed-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.unzipItem(at: signed.url, to: unpacked)
		let app = unpacked.appendingPathComponent("Payload/SigningTest.app")
		XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path), "the app has no embedded.mobileprovision")
		return app
	}

	/// `code` (the app or something nested in it) is signed by the test
	/// identity's team, and with an Apple certificate the whole app passes
	/// `codesign --verify`, which checks the code directory hashes, the
	/// resource seals, the nested code, the CMS signature and the designated
	/// requirement.
	private func assertSigned(_ app: URL, code: URL, file: StaticString = #filePath, line: UInt = #line) throws {
		let test = try TestIdentity.current
		let display = try Shell.run("codesign", "--display", "--verbose=4", code.path)
		XCTAssertEqual(display.status, 0, display.output, file: file, line: line)
		XCTAssertTrue(display.output.contains("TeamIdentifier=\(test.team)"), display.output, file: file, line: line)
		guard test.issuedByApple else { return }
		XCTAssertTrue(display.output.contains("Authority=Apple Worldwide Developer Relations Certification Authority"), display.output, file: file, line: line)
		let verify = try Shell.run("codesign", "--verify", "--deep", "--strict", "--verbose=4", app.path)
		XCTAssertEqual(verify.status, 0, "codesign --verify failed:\n\(verify.output)", file: file, line: line)
	}
}

/// The certificate and profile the zsign tests sign with: Codemagic's, from
/// ATELIER_SIGNING_IDENTITY, or the throwaway fixtures.
struct TestIdentity {
	var identity: SigningIdentity
	var team: String
	var issuedByApple: Bool

	static var current: TestIdentity {
		get throws {
			guard let path = ProcessInfo.processInfo.environment["ATELIER_SIGNING_IDENTITY"], !path.isEmpty else {
				let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: Fixture.password)
				return TestIdentity(identity: identity, team: "TESTTEAM01", issuedByApple: false)
			}
			let folder = URL(fileURLWithPath: path, isDirectory: true)
			let profile = folder.appendingPathComponent("profile.mobileprovision")
			let password = try String(contentsOf: folder.appendingPathComponent("password.txt"), encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let identity = SigningIdentity(p12: folder.appendingPathComponent("identity.p12"), profile: profile, password: password)
			return TestIdentity(identity: identity, team: try team(of: profile), issuedByApple: true)
		}
	}

	private static func team(of profile: URL) throws -> String {
		// To a file: security also prints warnings, and Shell mixes them in.
		let decoded = profile.deletingPathExtension().appendingPathExtension("plist")
		_ = try Shell.run("security", "cms", "-D", "-i", profile.path, "-o", decoded.path)
		let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: decoded), format: nil) as? [String: Any]
		guard let team = (plist?["TeamIdentifier"] as? [String])?.first else {
			throw TeamError()
		}
		return team
	}

	private struct TeamError: Error, CustomStringConvertible {
		var description: String { "The exported profile has no TeamIdentifier." }
	}
}

/// A tiny iOS app compiled with the iOS SDK, with the nested parts asked for.
enum FixtureApp {
	enum Part: Hashable {
		case appExtension, framework, dylib
	}

	/// With `entitlements`, the app's executable is ad hoc signed with them,
	/// as a developer's build would carry its own.
	static func build(layout: Set<Part>, entitlements: [String: Any]? = nil, in folder: URL) throws -> URL {
		let staging = folder.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
		let app = staging.appendingPathComponent("Payload/SigningTest.app", isDirectory: true)
		try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let source = staging.appendingPathComponent("main.c")
		try Data("int main(void) { return 0; }\n".utf8).write(to: source)
		let library = staging.appendingPathComponent("lib.c")
		try Data("int library_function(void) { return 1; }\n".utf8).write(to: library)

		try compile(source, to: app.appendingPathComponent("SigningTest"))
		try plist(["CFBundleIdentifier": "com.example.signingtest", "CFBundleExecutable": "SigningTest", "CFBundlePackageType": "APPL"], in: app)
		if let entitlements {
			let file = staging.appendingPathComponent("entitlements.plist")
			try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
			let result = try Shell.run("codesign", "--force", "--sign", "-", "--entitlements", file.path, app.appendingPathComponent("SigningTest").path)
			guard result.status == 0 else { throw CompileError(output: result.output) }
		}

		if layout.contains(.appExtension) {
			let appex = app.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
			try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
			try compile(source, to: appex.appendingPathComponent("Widget"))
			try plist([
				"CFBundleIdentifier": "com.example.signingtest.widget",
				"CFBundleExecutable": "Widget",
				"CFBundlePackageType": "XPC!",
				"NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
			], in: appex)
		}
		if layout.contains(.framework) {
			let framework = app.appendingPathComponent("Frameworks/Kit.framework", isDirectory: true)
			try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
			try compile(library, to: framework.appendingPathComponent("Kit"), dylib: "@rpath/Kit.framework/Kit")
			try plist(["CFBundleIdentifier": "com.example.kit", "CFBundleExecutable": "Kit", "CFBundlePackageType": "FMWK"], in: framework)
		}
		if layout.contains(.dylib) {
			let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
			try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
			try compile(library, to: frameworks.appendingPathComponent("libExtra.dylib"), dylib: "@rpath/libExtra.dylib")
		}

		let ipa = folder.appendingPathComponent("\(UUID().uuidString).ipa")
		try FileManager.default.zipItem(at: staging.appendingPathComponent("Payload"), to: ipa, compressionMethod: .deflate)
		try FileManager.default.removeItem(at: staging)
		return ipa
	}

	/// Atelier's App Groups library (#49), Atelier/AppGroups, built as
	/// project.yml builds it, for iOS or this Mac.
	static func appGroupsLibrary(sdk: String, in folder: URL) throws -> URL {
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
		let source = root.appendingPathComponent("Atelier/AppGroups/AtelierAppGroups.m")
		let output = folder.appendingPathComponent("library-\(sdk)-\(UUID().uuidString)").appendingPathComponent(AppGroupRedirect.fileName)
		try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
		var arguments = ["--sdk", sdk, "clang"]
		if sdk == "iphoneos" { arguments += ["-target", "arm64-apple-ios17.0"] }
		arguments += ["-dynamiclib", "-fno-objc-arc", "-framework", "Foundation", "-lobjc", "-install_name", "@rpath/\(AppGroupRedirect.fileName)", "-Wall", "-o", output.path, source.path]
		let result = try Shell.run("xcrun", arguments)
		guard result.status == 0 else { throw CompileError(output: result.output) }
		return output
	}

	private static func compile(_ source: URL, to output: URL, dylib installName: String? = nil) throws {
		var arguments = ["--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios17.0", "-o", output.path, source.path]
		if let installName { arguments += ["-dynamiclib", "-install_name", installName] }
		let result = try Shell.run("xcrun", arguments)
		guard result.status == 0 else { throw CompileError(output: result.output) }
	}

	struct CompileError: Error, CustomStringConvertible {
		var output: String
		var description: String { "Couldn't compile a fixture binary:\n\(output)" }
	}

	private static func plist(_ values: [String: Any], in bundle: URL) throws {
		var values = values
		values["CFBundleName"] = bundle.deletingPathExtension().lastPathComponent
		values["CFBundleShortVersionString"] = "1.0"
		values["CFBundleVersion"] = "1"
		values["MinimumOSVersion"] = "17.0"
		try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
			.write(to: bundle.appendingPathComponent("Info.plist"))
	}
}

enum Shell {
	struct Result {
		var status: Int32
		var output: String
	}

	static func run(_ tool: String, _ arguments: String...) throws -> Result {
		try run(tool, arguments)
	}

	static func run(_ tool: String, _ arguments: [String]) throws -> Result {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
		process.arguments = arguments
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		try process.run()
		let output = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
	}
}
#endif
