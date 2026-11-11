import Foundation
import XCTest
@testable import SigningKit

/// App Groups for apps signed with a certificate whose profile has groups
/// of its own (#49): the group and folders the app's are kept in, and what
/// the signing and the report do with them.
final class CertificateAppGroupsTests: XCTestCase {
	private let team = "S7GNTEAM42"
	/// As a signing service's profile lists them, not in order.
	private let certificateGroups = ["group.5f3c9a1e7b2d4806.2", "group.5f3c9a1e7b2d4806.4", "group.5f3c9a1e7b2d4806.1", "group.5f3c9a1e7b2d4806.5", "group.5f3c9a1e7b2d4806.3"]
	private let home = "group.5f3c9a1e7b2d4806.1"
	private let chat = "group.com.example.chat"
	private let other = "group.com.example.other"
	private let library = Data("library".utf8)
	private var folder: URL!

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	// MARK: The group and the folders

	func testTheFirstOfTheCertificatesGroupsByNameKeepsThem() {
		XCTAssertEqual(AppGroups.home(in: certificateGroups), home)
		XCTAssertEqual(AppGroups.home(in: ["group.example.*", "group.b", "group.a"]), "group.a", "never a pattern")
		XCTAssertNil(AppGroups.home(in: ["group.example.*"]))
		XCTAssertNil(AppGroups.home(in: [String]()))
		XCTAssertNil(AppGroups.home(in: nil))
		XCTAssertNil(AppGroups.home(in: "group.a"), "a list, as profiles have them")
	}

	func testEachGroupHasAFolderNamedAfterIt() {
		XCTAssertEqual(AppGroups.folders(for: [chat, other], appBundleID: "com.example.chat", signedBundleID: "com.example.chat"), [
			chat: "Atelier/group.com.example.chat",
			other: "Atelier/group.com.example.other",
		])
	}

	func testACopyHasFoldersOfItsOwn() {
		XCTAssertEqual(
			AppGroups.folders(for: [chat], appBundleID: "com.example.chat", signedBundleID: "com.example.chat.atelier2"),
			[chat: "Atelier/group.com.example.chat.atelier2"]
		)
		// One under an App ID of the user's.
		XCTAssertEqual(
			AppGroups.folders(for: [chat], appBundleID: "com.example.chat", signedBundleID: "com.example.chat-tests"),
			[chat: "Atelier/group.com.example.chat.comexamplechattests"]
		)
	}

	func testAFolderStaysInsideTheGroup() {
		XCTAssertEqual(
			AppGroups.folders(for: ["group.com.example/../../x", "..", ""], appBundleID: "a", signedBundleID: "a"),
			["group.com.example/../../x": "Atelier/group.com.example_.._.._x"]
		)
	}

	// MARK: The report

	private let bundles: [EntitlementReconciler.Bundle] = [
		.init(name: "", entitlements: [AppGroups.entitlement: ["group.com.example.chat", "group.com.example.other"]]),
		.init(name: "Widget", entitlements: [AppGroups.entitlement: ["group.com.example.chat"]]),
	]

	private var certificateProfile: [String: Any] {
		[
			"application-identifier": "\(team).app.otter4812.mango3307",
			"com.apple.developer.team-identifier": team,
			"get-task-allow": true,
			AppGroups.entitlement: certificateGroups,
			"keychain-access-groups": ["\(team).*", "com.apple.token"],
		]
	}

	func testGroupsKeptInTheCertificatesAreSupported() throws {
		let result = EntitlementReconciler.reconcile(
			profile: certificateProfile, teamID: team, isWildcard: false, bundles: bundles,
			renamedGroups: [chat: home, other: home],
			groupFolders: [chat: "Atelier/\(chat)", other: "Atelier/\(other)"]
		)
		// Signed with the certificate's groups, as before.
		XCTAssertEqual(result.entitlements[AppGroups.entitlement] as? [String], certificateGroups)
		let item = try XCTUnwrap(result.report.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .rewritten)
		XCTAssertEqual(item.missingValues, [])
		XCTAssertEqual(item.renamedValues, [chat: home, other: home], "both, though they share the group")
		XCTAssertEqual(item.folders, [chat: "Atelier/\(chat)", other: "Atelier/\(other)"])
		XCTAssertFalse(result.report.limits.contains { $0.contains("App Groups") }, "\(result.report.limits)")

		let capability = try XCTUnwrap(result.report.capabilities.first { $0.name == "App Groups" })
		XCTAssertEqual(capability.status, .supported)
		XCTAssertEqual(capability.detail, "Atelier keeps them in a folder of the app's own, in your certificate's App Group, which the app and its extensions share. Other apps signed with this certificate could read it.")
		XCTAssertEqual(capability.renamedValues, [chat: home, other: home])
		XCTAssertEqual(capability.folders, [chat: "Atelier/\(chat)", other: "Atelier/\(other)"])
	}

	func testWithoutFoldersTheyAreLostAsBefore() throws {
		let result = EntitlementReconciler.reconcile(profile: certificateProfile, teamID: team, isWildcard: false, bundles: bundles)
		let item = try XCTUnwrap(result.report.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .dropped)
		XCTAssertNil(item.folders)
		XCTAssertEqual(result.report.capabilities.first { $0.name == "App Groups" }?.status, .unsupported)
	}

	func testAReportWithFoldersReadsBack() throws {
		let item = EntitlementsReport.Item(key: AppGroups.entitlement, outcome: .rewritten, renamedValues: [chat: home], folders: [chat: "Atelier/\(chat)"], redirected: true)
		XCTAssertEqual(try JSONDecoder().decode(EntitlementsReport.Item.self, from: JSONEncoder().encode(item)), item)
		// And one kept before, without them.
		let json = Data(#"{"key":"com.apple.security.application-groups","outcome":"rewritten","bundles":[""],"missingValues":[],"renamedValues":{"a":"b"},"redirected":true}"#.utf8)
		XCTAssertNil(try JSONDecoder().decode(EntitlementsReport.Item.self, from: json).folders)
	}

	// MARK: Signing

	/// The app, asking for two groups, a widget and a share extension of
	/// ExtensionKit's asking for one, and a Watch app.
	private func chatIPA() throws -> URL {
		var files = try Fixture.appFiles(main: Fixture.signedMachO(cmsBytes: 64, entitlements: [AppGroups.entitlement: [chat, other]]))
		let groups = [AppGroups.entitlement: [chat]]
		files["Payload/Test.app/PlugIns/Widget.appex/Widget"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		files["Payload/Test.app/Extensions/Share.appex/Info.plist"] = try Fixture.infoPlist("com.example.test.share", executable: "ShareExtension")
		files["Payload/Test.app/Extensions/Share.appex/ShareExtension"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		files["Payload/Test.app/Watch/Watch.app/Info.plist"] = try Fixture.infoPlist("com.example.test.watch", executable: "Watch")
		files["Payload/Test.app/Watch/Watch.app/Watch"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		return try Fixture.ipa(files, in: folder)
	}

	/// Signs `chatIPA` with a certificate whose profile has `groups`, with
	/// Atelier's library unless `library` is false.
	private func signChat(groups: [String]? = nil, library: Bool = true, target: InstallTarget = .original, engine: FakeEngine) async throws -> SignedIPA {
		var entitlements = certificateProfile
		entitlements[AppGroups.entitlement] = groups ?? certificateGroups
		let profile = folder.appendingPathComponent("certificate.mobileprovision")
		try PropertyListSerialization.data(fromPropertyList: [
			"Name": "Signulous", "UUID": "1", "TeamIdentifier": [team],
			"ExpirationDate": Date.distantFuture, "DeveloperCertificates": [Data()],
			"ProvisionedDevices": ["00008130-000A1B2C3D4E5F60"],
			"Entitlements": entitlements,
		] as [String: Any], format: .xml, options: 0).write(to: profile)
		let libraryFile = folder.appendingPathComponent(AppGroupRedirect.fileName)
		try self.library.write(to: libraryFile)
		let options = SigningOptions(target: target, appGroupsLibrary: library ? libraryFile : nil)
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: profile, password: Fixture.password)
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		return try await signer.sign(ipa: try chatIPA(), with: identity, options: options, outputDirectory: folder, progress: nil)
	}

	private func info(_ plist: String, of ipa: URL) throws -> [String: Any] {
		let data = try Fixture.contents(of: "Payload/Test.app/" + plist, in: ipa)
		return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
	}

	func testTheAppAndItsExtensionsKeepTheirGroupsInTheCertificates() async throws {
		let engine = FakeEngine()
		let signed = try await signChat(engine: engine)

		XCTAssertEqual(engine.loads, [
			"Test": ["@executable_path/Frameworks/AtelierAppGroups.dylib"],
			"PlugIns/Widget.appex/Widget": ["@executable_path/../../Frameworks/AtelierAppGroups.dylib"],
			"Extensions/Share.appex/ShareExtension": ["@executable_path/../../Frameworks/AtelierAppGroups.dylib"],
		], "not the Watch app, which runs on the watch")
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/Frameworks/AtelierAppGroups.dylib", in: signed.url), library)
		for plist in ["Info.plist", "PlugIns/Widget.appex/Info.plist", "Extensions/Share.appex/Info.plist"] {
			let values = try info(plist, of: signed.url)
			XCTAssertEqual(values[AppGroupRedirect.infoKey] as? [String: String], [chat: home, other: home], plist)
			XCTAssertEqual(values[AppGroupRedirect.foldersKey] as? [String: String], [chat: "Atelier/\(chat)", other: "Atelier/\(other)"], plist)
		}
		XCTAssertNil(try info("Watch/Watch.app/Info.plist", of: signed.url)[AppGroupRedirect.infoKey])
		// Signed with the certificate's groups, which the library sends the app's to.
		XCTAssertEqual(engine.lastEntitlements?[AppGroups.entitlement] as? [String], certificateGroups)

		let item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.redirected, true)
		XCTAssertEqual(item.renamedValues, [chat: home, other: home])
		XCTAssertEqual(item.folders, [chat: "Atelier/\(chat)", other: "Atelier/\(other)"])
		XCTAssertEqual(signed.entitlements?.capabilities.first { $0.name == "App Groups" }?.status, .supported)
	}

	func testACopyKeepsThemInFoldersOfItsOwn() async throws {
		let signed = try await signChat(target: .copy(2), engine: FakeEngine())
		XCTAssertEqual(
			try info("Info.plist", of: signed.url)[AppGroupRedirect.foldersKey] as? [String: String],
			[chat: "Atelier/\(chat).atelier2", other: "Atelier/\(other).atelier2"]
		)
	}

	func testOnlyTheGroupsTheCertificateDoesntHave() async throws {
		// A profile of the developer's own, say, with one of them.
		let signed = try await signChat(groups: [chat, "group.com.example.z"], engine: FakeEngine())
		XCTAssertEqual(try info("Info.plist", of: signed.url)[AppGroupRedirect.infoKey] as? [String: String], [other: chat])
		XCTAssertEqual(try info("Info.plist", of: signed.url)[AppGroupRedirect.foldersKey] as? [String: String], [other: "Atelier/\(other)"])
		let item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.renamedValues, [other: chat])
		XCTAssertEqual(item.missingValues, [])
	}

	func testTheAppKeepsItsCodeWhenNothingIsKept() async throws {
		// Share App Groups off.
		var engine = FakeEngine()
		var signed = try await signChat(library: false, engine: engine)
		XCTAssertEqual(engine.loads, [:])
		XCTAssertNil(try Fixture.entries(of: signed.url)["Payload/Test.app/Frameworks/AtelierAppGroups.dylib"])
		var item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .dropped)
		XCTAssertNil(item.redirected)

		// A certificate without groups of its own, or only a pattern.
		for groups in [[], ["group.example.*"]] {
			engine = FakeEngine()
			signed = try await signChat(groups: groups, engine: engine)
			XCTAssertEqual(engine.loads, [:])
			item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
			XCTAssertEqual(item.outcome, .dropped)
			XCTAssertNil(item.redirected)
		}

		// One that has all of the app's.
		engine = FakeEngine()
		signed = try await signChat(groups: [chat, other], engine: engine)
		XCTAssertEqual(engine.loads, [:])
		item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .kept)
		XCTAssertNil(item.folders)
	}

	func testAnAppWithoutRoomForTheLibraryLosesThemAsBefore() async throws {
		let engine = FakeEngine()
		engine.noRoom = ["Test"]
		let signed = try await signChat(engine: engine)

		XCTAssertEqual(engine.loads, [:], "nor its extensions")
		XCTAssertNil(try Fixture.entries(of: signed.url)["Payload/Test.app/Frameworks/AtelierAppGroups.dylib"])
		XCTAssertNil(try info("Info.plist", of: signed.url)[AppGroupRedirect.infoKey])
		let item = try XCTUnwrap(signed.entitlements?.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .dropped)
		XCTAssertNil(item.folders)
		XCTAssertEqual(item.redirected, false)
	}

	func testFoldersAnIPABroughtAreLeftOutWithAnAppleID() throws {
		// An IPA taken from an install signed with a certificate.
		let app = folder.appendingPathComponent("Test.app", isDirectory: true)
		try Fixture.write([
			"Info.plist": try Fixture.infoPlist("com.example.test", executable: "Test", extra: [AppGroupRedirect.foldersKey: [chat: "Atelier/x"]]),
			"Test": Fixture.machO(),
		], under: app)
		let libraryFile = folder.appendingPathComponent(AppGroupRedirect.fileName)
		try library.write(to: libraryFile)
		XCTAssertTrue(try AppGroupRedirect.apply([chat: "\(chat).\(team)"], library: libraryFile, to: app) { _, _ in true })
		let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
		XCTAssertEqual(values[AppGroupRedirect.infoKey] as? [String: String], [chat: "\(chat).\(team)"])
		XCTAssertNil(values[AppGroupRedirect.foldersKey])
	}
}
