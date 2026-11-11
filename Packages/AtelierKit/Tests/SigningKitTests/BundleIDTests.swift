import Foundation
import InstallKit
import XCTest
@testable import SigningKit

/// The bundle ID policy (#8): which bundle ID an app is signed with, how a
/// copy's extensions are renamed, and when iOS would refuse an
/// update because the App ID changed.
final class BundleIDTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	// MARK: Targets

	func testAppsKeepTheirBundleIDByDefault() {
		XCTAssertEqual(InstallTarget.original.bundleID(for: "com.spotify.client"), "com.spotify.client")
	}

	func testACopyGetsTheSameIDEveryTime() {
		XCTAssertEqual(InstallTarget.copy(2).bundleID(for: "com.spotify.client"), "com.spotify.client.atelier2")
		XCTAssertEqual(InstallTarget.copyNumber(of: "com.spotify.client.atelier2", original: "com.spotify.client"), 2)
		XCTAssertEqual(InstallTarget.copyNumber(of: "com.spotify.client.atelier12", original: "com.spotify.client"), 12)
	}

	func testOnlyCopiesCountAsCopies() {
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client", original: "com.spotify.client"))
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client.widget", original: "com.spotify.client"))
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client.atelier", original: "com.spotify.client"))
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client.atelier1", original: "com.spotify.client"), "the original is the first")
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client.atelier02", original: "com.spotify.client"))
		XCTAssertNil(InstallTarget.copyNumber(of: "com.spotify.client.atelier2", original: "com.spotify"))
	}

	func testNewCopiesAreNumberedAfterTheHighest() {
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: []), .copy(2))
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: ["com.x"]), .copy(2))
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: ["com.x", "com.x.atelier2", "com.x.atelier3"]), .copy(4))
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: ["com.x.atelier5", "com.y.atelier9"]), .copy(6), "a gap isn't filled")
		// Copies signed with an Apple ID have its team ID before the suffix
		// (#49), and count too, so the next copy doesn't take their number.
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: ["com.x.A1B2C3D4E5", "com.x.A1B2C3D4E5.atelier3"]), .copy(4))
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: ["com.x.widget.more.atelier7", "com.xy.A1B2C3D4E5.atelier8"]), .copy(2), "only the app's own copies count")
	}

	func testACopyIsToldByItsSuffixAlone() {
		let copy = InstallTarget.split("com.ispazio.Wallpapers-Central.atelier3")
		XCTAssertEqual(copy.original, "com.ispazio.Wallpapers-Central")
		XCTAssertEqual(copy.target, .copy(3))
		for id in ["com.ispazio.Wallpapers-Central", "com.x.atelier1", "com.x.atelier02", "com.x.atelier", "atelier2"] {
			let split = InstallTarget.split(id)
			XCTAssertEqual(split.original, id)
			XCTAssertEqual(split.target, .original, id)
		}
	}

	// MARK: Renaming

	func testRenamesTheAppAndItsChildrenOnly() {
		let old = "com.example.test", new = "com.example.test.atelier2"
		XCTAssertEqual(BundleIDRewriter.renamed("com.example.test", from: old, to: new), new)
		XCTAssertEqual(BundleIDRewriter.renamed("com.example.test.widget", from: old, to: new), "com.example.test.atelier2.widget")
		XCTAssertNil(BundleIDRewriter.renamed("com.example.tester", from: old, to: new), "not a child, though it starts the same")
		XCTAssertNil(BundleIDRewriter.renamed("com.example.kit", from: old, to: new))
		XCTAssertNil(BundleIDRewriter.renamed("org.other.com.example.test", from: old, to: new))
	}

	func testRewritesExtensionsAndWatchAppsToStayChildren() throws {
		let app = folder.appendingPathComponent("Test.app", isDirectory: true)
		try Fixture.write([
			"Info.plist": try Fixture.infoPlist("com.example.test", executable: "Test"),
			"PlugIns/Widget.appex/Info.plist": try Fixture.infoPlist("com.example.test.widget", executable: "Widget"),
			"Frameworks/Kit.framework/Info.plist": try Fixture.infoPlist("com.example.kit", executable: "Kit"),
			"PlugIns/Other.appex/Info.plist": try Fixture.infoPlist("com.vendor.sdk.extension", executable: "Other"),
			"Watch/Watch.app/Info.plist": try Fixture.infoPlist("com.example.test.watchkitapp", executable: "Watch", extra: [
				"WKCompanionAppBundleIdentifier": "com.example.test",
			]),
			"Watch/Watch.app/PlugIns/WatchExt.appex/Info.plist": try Fixture.infoPlist("com.example.test.watchkitapp.extension", executable: "WatchExt", extra: [
				"NSExtension": ["NSExtensionAttributes": ["WKAppBundleIdentifier": "com.example.test.watchkitapp"], "NSExtensionPointIdentifier": "com.apple.watchkit"],
			]),
		], under: app)

		let changes = try BundleIDRewriter.rewrite(app: app, from: "com.example.test", to: "com.example.test.atelier2")

		XCTAssertEqual(changes.map(\.new), [
			"com.example.test.atelier2",
			"com.example.test.atelier2.widget",
			"com.example.test.atelier2.watchkitapp",
			"com.example.test.atelier2.watchkitapp.extension",
		])
		func info(_ path: String) throws -> [String: Any] {
			try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent(path)), format: nil) as? [String: Any])
		}
		XCTAssertEqual(try info("Info.plist")["CFBundleIdentifier"] as? String, "com.example.test.atelier2")
		XCTAssertEqual(try info("Frameworks/Kit.framework/Info.plist")["CFBundleIdentifier"] as? String, "com.example.kit", "frameworks keep theirs")
		XCTAssertEqual(try info("PlugIns/Other.appex/Info.plist")["CFBundleIdentifier"] as? String, "com.vendor.sdk.extension", "not a child of the app")
		XCTAssertEqual(try info("Watch/Watch.app/Info.plist")["WKCompanionAppBundleIdentifier"] as? String, "com.example.test.atelier2")
		let attributes = try info("Watch/Watch.app/PlugIns/WatchExt.appex/Info.plist")["NSExtension"] as? [String: Any]
		XCTAssertEqual((attributes?["NSExtensionAttributes"] as? [String: Any])?["WKAppBundleIdentifier"] as? String, "com.example.test.atelier2.watchkitapp")
		XCTAssertEqual(attributes?["NSExtensionPointIdentifier"] as? String, "com.apple.watchkit", "the rest of NSExtension stays")
	}

	func testSigningAsACopy() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let engine = FakeEngine()
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: Fixture.password)

		let signed = try await signer.sign(
			ipa: ipa, with: identity,
			options: SigningOptions(target: .copy(3)),
			outputDirectory: folder, progress: nil
		)

		XCTAssertEqual(signed.info.bundleID, "com.example.test.atelier3")
		XCTAssertNil(engine.lastOptions?.displayName, "a copy keeps the app's name")
		XCTAssertEqual(signed.identity.bundleID, "com.example.test.atelier3")
		XCTAssertEqual(signed.identity.originalBundleID, "com.example.test")
		XCTAssertEqual(signed.identity.applicationIdentifier, "TESTTEAM01.*", "the profile's, as zsign signs it")
		XCTAssertEqual(signed.identity.teamID, "TESTTEAM01")
		let widget = try XCTUnwrap(PropertyListSerialization.propertyList(from: Fixture.contents(of: "Payload/Test.app/PlugIns/Widget.appex/Info.plist", in: signed.url), format: nil) as? [String: Any])
		XCTAssertEqual(widget["CFBundleIdentifier"] as? String, "com.example.test.atelier3.widget")
	}

	func testACopyCanHaveItsOwnName() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let engine = FakeEngine()
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: Fixture.password)

		_ = try await signer.sign(ipa: ipa, with: identity, options: SigningOptions(target: .copy(2), displayName: "Work"), outputDirectory: folder, progress: nil)

		XCTAssertEqual(engine.lastOptions?.displayName, "Work")
	}

	func testSigningKeepsTheBundleIDByDefault() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let signer = IPASigner(engine: FakeEngine(), workRoot: folder.appendingPathComponent("work"))
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: Fixture.password)

		let signed = try await signer.sign(ipa: ipa, with: identity, options: SigningOptions(), outputDirectory: folder, progress: nil)

		XCTAssertEqual(signed.identity, SignedAppIdentity(bundleID: "com.example.test", originalBundleID: "com.example.test", applicationIdentifier: "TESTTEAM01.*", teamID: "TESTTEAM01"))
	}

	/// Atelier's own update is signed as the bundle ID Atelier was
	/// installed with, which another tool may have changed, and carries the
	/// token it checks on its next launch (#24).
	func testSigningAsAnInstalledBundleIDWithInfoValues() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let signer = IPASigner(engine: FakeEngine(), workRoot: folder.appendingPathComponent("work"))
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try Fixture.url("development.mobileprovision"), password: Fixture.password)

		let signed = try await signer.sign(
			ipa: ipa, with: identity,
			options: SigningOptions(bundleID: "com.example.test.TESTTEAM01", infoPlistValues: ["AtelierInstallToken": "abc"]),
			outputDirectory: folder, progress: nil
		)

		XCTAssertEqual(signed.identity.bundleID, "com.example.test.TESTTEAM01")
		XCTAssertEqual(signed.identity.originalBundleID, "com.example.test")
		let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Fixture.contents(of: "Payload/Test.app/Info.plist", in: signed.url), format: nil) as? [String: Any])
		XCTAssertEqual(info["AtelierInstallToken"] as? String, "abc")
		XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.2", "the rest stays")
		let widget = try XCTUnwrap(PropertyListSerialization.propertyList(from: Fixture.contents(of: "Payload/Test.app/PlugIns/Widget.appex/Info.plist", in: signed.url), format: nil) as? [String: Any])
		XCTAssertEqual(widget["CFBundleIdentifier"] as? String, "com.example.test.TESTTEAM01.widget")
		XCTAssertNil(widget["AtelierInstallToken"], "only the app's Info.plist")
	}

	// MARK: Reading an installed app

	/// What Atelier reads of itself: the App ID from its executable's
	/// entitlements, else from its embedded profile (#24).
	func testReadsWhatAnAppIsSignedAs() throws {
		let app = folder.appendingPathComponent("Own.app", isDirectory: true)
		let entitlements: [String: Any] = [
			"application-identifier": "TEAMAAAAAA.app.otter.mango",
			"com.apple.developer.team-identifier": "TEAMAAAAAA",
		]
		try Fixture.write([
			"Info.plist": try Fixture.infoPlist("com.atelier.app", executable: "Own"),
			"Own": Fixture.signedMachO(cmsBytes: 64, entitlements: entitlements),
		], under: app)
		XCTAssertEqual(
			SignedAppIdentity.read(app: app),
			SignedAppIdentity(bundleID: "com.atelier.app", originalBundleID: "com.atelier.app", applicationIdentifier: "TEAMAAAAAA.app.otter.mango", teamID: "TEAMAAAAAA")
		)

		// Without entitlements in its executable, its embedded profile says.
		try Fixture.write([
			"Own": Fixture.machO(),
			"embedded.mobileprovision": Data(contentsOf: Fixture.url("development.mobileprovision")),
		], under: app)
		XCTAssertEqual(
			SignedAppIdentity.read(app: app, originalBundleID: "com.atelier.app"),
			SignedAppIdentity(bundleID: "com.atelier.app", originalBundleID: "com.atelier.app", applicationIdentifier: "TESTTEAM01.*", teamID: "TESTTEAM01")
		)

		// Neither: only the bundle ID is known.
		try FileManager.default.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
		XCTAssertEqual(SignedAppIdentity.read(app: app)?.bundleID, "com.atelier.app")
		XCTAssertNil(SignedAppIdentity.read(app: app)?.applicationIdentifier)
		XCTAssertNil(SignedAppIdentity.read(app: folder.appendingPathComponent("Missing.app")))
	}

	// MARK: App ID changes

	private func identity(_ appID: String?, team: String? = "TEAMAAAAAA", bundleID: String = "com.example.app") -> SignedAppIdentity {
		SignedAppIdentity(bundleID: bundleID, originalBundleID: "com.example.app", applicationIdentifier: appID, teamID: team)
	}

	func testTheSameAppIDUpdatesFine() {
		let signed = identity("TEAMAAAAAA.app.otter.mango")
		XCTAssertNil(signed.upgradeProblem(over: signed))
		XCTAssertNil(signed.upgradeProblem(over: nil), "nothing installed under that bundle ID")
		XCTAssertNil(signed.upgradeProblem(over: identity(nil)), "installed before #8: not known")
	}

	func testANewProfileForAnotherAppIDIsRefused() throws {
		let installed = identity("TEAMAAAAAA.app.otter.mango")
		let problem = try XCTUnwrap(identity("TEAMAAAAAA.app.mango.kiwi").upgradeProblem(over: installed))
		XCTAssertEqual(problem, "If the app is still on this \(ThisDevice.name), this won't update it: it was installed with a different certificate. Delete the app first; its data will be lost.")
	}

	func testACertificateFromAnotherTeamIsRefused() throws {
		let installed = identity("TEAMAAAAAA.*")
		let problem = try XCTUnwrap(identity("TEAMBBBBBB.*", team: "TEAMBBBBBB").upgradeProblem(over: installed))
		XCTAssertTrue(problem.contains("it was installed with a certificate from another account"), problem)
	}

	func testASeparateCopyIsNotAnUpdateOfTheOriginal() {
		let original = identity("TEAMAAAAAA.app.otter.mango")
		let copy = identity("TEAMAAAAAA.app.mango.kiwi", bundleID: "com.example.app.atelier2")
		XCTAssertNil(copy.upgradeProblem(over: original))
	}

	func testSigningForAnotherAppIDNeedsAReinstall() {
		let installed = identity("TEAMAAAAAA.app.otter.mango")
		XCTAssertFalse(installed.needsReinstall(signingFor: "TEAMAAAAAA.app.otter.mango"))
		XCTAssertTrue(installed.needsReinstall(signingFor: "TEAMAAAAAA.app.heron.lime"))
		XCTAssertTrue(installed.needsReinstall(signingFor: "TEAMAAAAAA.*"))
		var unknown = installed
		unknown.applicationIdentifier = nil
		XCTAssertFalse(unknown.needsReinstall(signingFor: "TEAMAAAAAA.app.heron.lime"))
	}
}
