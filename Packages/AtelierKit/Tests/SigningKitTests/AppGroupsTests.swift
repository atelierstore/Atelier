import Foundation
import XCTest
@testable import SigningKit

/// App Groups for apps signed with an Apple ID (#49): reading the ones the
/// app and its extensions ask for from the IPA, the names the Apple ID's
/// team gives them, and what the report says once the profile allows them.
final class AppGroupsTests: XCTestCase {
	private let team = "A1B2C3D4E5"
	private var folder: URL!

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	// MARK: Reading them

	func testReadsTheGroupsOfTheAppAndItsExtensionsTheAppsFirst() throws {
		var files = try Fixture.appFiles(main: Fixture.signedMachO(cmsBytes: 64, entitlements: [
			"application-identifier": "DEVTEAM123.com.example.chat",
			AppGroups.entitlement: ["group.com.example.chat", "group.com.example.app"],
		]))
		files["Payload/Test.app/PlugIns/Widget.appex/Widget"] = Fixture.signedMachO(cmsBytes: 64, entitlements: [
			AppGroups.entitlement: ["group.com.example.widgets", "group.com.example.chat"],
		])
		// An extension whose executable isn't named after its folder.
		files["Payload/Test.app/Extensions/Share.appex/Info.plist"] = try Fixture.infoPlist("com.example.test.share", executable: "ShareExtension")
		files["Payload/Test.app/Extensions/Share.appex/ShareExtension"] = Fixture.signedMachO(cmsBytes: 64, entitlements: [
			AppGroups.entitlement: ["group.com.example.share"],
		])
		let ipa = try Fixture.ipa(files, in: folder)
		XCTAssertEqual(try AppGroups.read(ipaAt: ipa), [
			"group.com.example.chat", "group.com.example.app", "group.com.example.share", "group.com.example.widgets",
		])
	}

	func testNoneWhenTheBinariesHaveNoEntitlements() throws {
		// As in a decrypted IPA, which often loses them.
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		XCTAssertEqual(try AppGroups.read(ipaAt: ipa), [])
	}

	func testRefusesWhatIsNotAnIPA() throws {
		let text = folder.appendingPathComponent("text.ipa")
		try Data("not a zip".utf8).write(to: text)
		XCTAssertThrowsError(try AppGroups.read(ipaAt: text)) { error in
			XCTAssertEqual(error as? SigningError, .corruptArchive("it isn't a ZIP archive"))
		}
	}

	func testFindsTheAppThenWhatIsInsideIt() {
		let paths = [
			"Payload/", "Payload/Test.app/", "Payload/Test.app/Info.plist", "Payload/Test.app/Test",
			"Payload/Test.app/Watch/Test Watch.app/Info.plist",
			"Payload/Test.app/PlugIns/Widget.appex/Info.plist",
			"Payload/Test.app/Frameworks/Kit.framework/Info.plist",
			"Payload/Test.app/Resources.bundle/Info.plist",
			"__MACOSX/Payload/Test.app/Info.plist",
		]
		XCTAssertEqual(AppGroups.bundles(in: paths), [
			"Payload/Test.app", "Payload/Test.app/PlugIns/Widget.appex", "Payload/Test.app/Watch/Test Watch.app",
		])
		XCTAssertEqual(AppGroups.bundles(in: ["Payload/Info.plist"]), [])
	}

	// MARK: Their names

	func testTheAppItselfHasEachGroupWithTheTeamIDOnTheEnd() {
		let names = AppGroups.names(for: ["group.com.example.chat", "group.com.example.other"], appBundleID: "com.example.chat", signedBundleID: "com.example.chat.\(team)", teamID: team)
		XCTAssertEqual(names, [
			"group.com.example.chat": "group.com.example.chat.\(team)",
			"group.com.example.other": "group.com.example.other.\(team)",
		])
		// What an app that builds its group's name from its bundle ID asks for.
		XCTAssertEqual(names["group.com.example.chat"], "group." + "com.example.chat.\(team)")
	}

	func testACopyHasGroupsOfItsOwn() {
		XCTAssertEqual(
			AppGroups.names(for: ["group.com.example.chat"], appBundleID: "com.example.chat", signedBundleID: "com.example.chat.\(team).atelier2", teamID: team),
			["group.com.example.chat": "group.com.example.chat.\(team).atelier2"]
		)
		// One under an App ID of the user's.
		XCTAssertEqual(
			AppGroups.names(for: ["group.com.example.chat"], appBundleID: "com.example.chat", signedBundleID: "com.example.chat-tests.\(team)", teamID: team),
			["group.com.example.chat": "group.com.example.chat.\(team).comexamplechattests"]
		)
	}

	func testTheTeamIDGoesOnOnlyOnce() {
		// An IPA taken from an install of AltStore's, signed for the team.
		XCTAssertEqual(
			AppGroups.names(for: ["group.com.example.chat.\(team)"], appBundleID: "com.example.chat.\(team)", signedBundleID: "com.example.chat.\(team)", teamID: team),
			["group.com.example.chat.\(team)": "group.com.example.chat.\(team)"]
		)
		XCTAssertEqual(
			AppGroups.names(for: ["group.com.example.chat.\(team)"], appBundleID: "com.example.chat.\(team)", signedBundleID: "com.example.chat.\(team).atelier2", teamID: team),
			["group.com.example.chat.\(team)": "group.com.example.chat.\(team).atelier2"]
		)
	}

	// MARK: The report

	/// A free Apple ID's profile for the app's App ID, once the team's
	/// groups were assigned to it.
	private var appleIDProfile: [String: Any] {
		[
			"application-identifier": "\(team).com.example.chat.\(team)",
			"com.apple.developer.team-identifier": team,
			"get-task-allow": true,
			AppGroups.entitlement: ["group.com.example.chat.\(team)"],
			"keychain-access-groups": ["\(team).*"],
		]
	}

	private let bundles: [EntitlementReconciler.Bundle] = [
		.init(name: "", entitlements: [
			"application-identifier": "DEVTEAM123.com.example.chat",
			AppGroups.entitlement: ["group.com.example.chat"],
		]),
		.init(name: "Widget", entitlements: [
			"application-identifier": "DEVTEAM123.com.example.chat.widget",
			AppGroups.entitlement: ["group.com.example.chat"],
		]),
	]

	func testGroupsTheProfileHasUnderTheTeamsNamesAreSupported() throws {
		let result = EntitlementReconciler.reconcile(
			profile: appleIDProfile, teamID: team, isWildcard: false, bundles: bundles,
			renamedGroups: ["group.com.example.chat": "group.com.example.chat.\(team)"]
		)
		// The app and its widget are signed with the team's group.
		XCTAssertEqual(result.entitlements[AppGroups.entitlement] as? [String], ["group.com.example.chat.\(team)"])
		let item = try XCTUnwrap(result.report.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .rewritten)
		XCTAssertEqual(item.missingValues, [])
		XCTAssertEqual(item.renamedValues, ["group.com.example.chat": "group.com.example.chat.\(team)"])
		XCTAssertFalse(result.report.limits.contains { $0.contains("App Groups") }, "\(result.report.limits)")

		let capability = try XCTUnwrap(result.report.capabilities.first { $0.name == "App Groups" })
		XCTAssertEqual(capability.status, .supported)
		XCTAssertEqual(capability.detail, "Your Apple ID added them under names of its own, which the app and its extensions share.")
		XCTAssertEqual(capability.renamedValues, ["group.com.example.chat": "group.com.example.chat.\(team)"])
	}

	func testWithoutTheGroupsTheyAreLostAsBefore() throws {
		// Apple refused them, so the profile allows none.
		var profile = appleIDProfile
		profile[AppGroups.entitlement] = nil
		let result = EntitlementReconciler.reconcile(
			profile: profile, teamID: team, isWildcard: false, bundles: bundles,
			renamedGroups: ["group.com.example.chat": "group.com.example.chat.\(team)"]
		)
		let item = try XCTUnwrap(result.report.items.first { $0.key == AppGroups.entitlement })
		XCTAssertEqual(item.outcome, .dropped)
		XCTAssertNil(item.renamedValues)
		XCTAssertTrue(result.report.limits.contains("The app and its extensions can't share data: your certificate doesn't allow App Groups."))
	}

	func testAReportKeptBeforeStillReads() throws {
		let json = Data(#"{"key":"com.apple.security.application-groups","outcome":"dropped","bundles":[""],"missingValues":[]}"#.utf8)
		let item = try JSONDecoder().decode(EntitlementsReport.Item.self, from: json)
		XCTAssertEqual(item.outcome, .dropped)
		XCTAssertNil(item.renamedValues)
		XCTAssertNil(item.redirected)
	}

	// MARK: Sending the app's names to them

	private let ownName = "group.com.example.chat"
	private var teamName: String { "group.com.example.chat.\(team)" }
	private let library = Data("library".utf8)

	/// The app, a widget, a share extension of ExtensionKit's and a Watch
	/// app, all asking for the group.
	private func chatIPA() throws -> URL {
		let groups = [AppGroups.entitlement: [ownName]]
		var files = try Fixture.appFiles(main: Fixture.signedMachO(cmsBytes: 64, entitlements: groups))
		files["Payload/Test.app/PlugIns/Widget.appex/Widget"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		files["Payload/Test.app/Extensions/Share.appex/Info.plist"] = try Fixture.infoPlist("com.example.test.share", executable: "ShareExtension")
		files["Payload/Test.app/Extensions/Share.appex/ShareExtension"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		files["Payload/Test.app/Watch/Watch.app/Info.plist"] = try Fixture.infoPlist("com.example.test.watch", executable: "Watch")
		files["Payload/Test.app/Watch/Watch.app/Watch"] = Fixture.signedMachO(cmsBytes: 64, entitlements: groups)
		return try Fixture.ipa(files, in: folder)
	}

	/// Signs `chatIPA` with an Apple ID's profile that allows the team's
	/// name for the group, unless `allowsGroup` is false.
	private func signChat(library: Bool = true, allowsGroup: Bool = true, engine: FakeEngine) async throws -> SignedIPA {
		var entitlements = appleIDProfile
		if !allowsGroup { entitlements[AppGroups.entitlement] = nil }
		let profile = folder.appendingPathComponent("appleid.mobileprovision")
		let plist: [String: Any] = [
			"Name": "Apple ID", "UUID": "1", "TeamIdentifier": [team],
			"ExpirationDate": Date.distantFuture, "DeveloperCertificates": [Data()],
			"ProvisionedDevices": ["00008110-000A1B2C3D4E5F60"],
			"Entitlements": entitlements,
		]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: profile)
		let libraryFile = folder.appendingPathComponent(AppGroupRedirect.fileName)
		try self.library.write(to: libraryFile)
		let options = SigningOptions(
			bundleID: "com.example.chat.\(team)",
			appGroups: [ownName: teamName],
			appGroupsLibrary: library ? libraryFile : nil
		)
		let identity = SigningIdentity(p12: try Fixture.url("signing.p12"), profile: profile, password: Fixture.password)
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		return try await signer.sign(ipa: try chatIPA(), with: identity, options: options, outputDirectory: folder, progress: nil)
	}

	private func names(in plist: String, of ipa: URL) throws -> [String: String]? {
		let data = try Fixture.contents(of: "Payload/Test.app/" + plist, in: ipa)
		let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		return info[AppGroupRedirect.infoKey] as? [String: String]
	}

	func testTheAppAndItsExtensionsSendTheirOwnNamesToTheTeams() async throws {
		let engine = FakeEngine()
		let signed = try await signChat(engine: engine)

		XCTAssertEqual(engine.loads, [
			"Test": ["@executable_path/Frameworks/AtelierAppGroups.dylib"],
			"PlugIns/Widget.appex/Widget": ["@executable_path/../../Frameworks/AtelierAppGroups.dylib"],
			"Extensions/Share.appex/ShareExtension": ["@executable_path/../../Frameworks/AtelierAppGroups.dylib"],
		], "not the Watch app, which runs on the watch")
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/Frameworks/AtelierAppGroups.dylib", in: signed.url), library)
		for plist in ["Info.plist", "PlugIns/Widget.appex/Info.plist", "Extensions/Share.appex/Info.plist"] {
			XCTAssertEqual(try names(in: plist, of: signed.url), [ownName: teamName], plist)
		}
		XCTAssertNil(try names(in: "Watch/Watch.app/Info.plist", of: signed.url))
		// Signed with the team's name, which the library sends the app's to.
		XCTAssertEqual(engine.lastEntitlements?[AppGroups.entitlement] as? [String], [teamName])

		let report = try XCTUnwrap(signed.entitlements)
		XCTAssertEqual(report.items.first { $0.key == AppGroups.entitlement }?.redirected, true)
		let capability = try XCTUnwrap(report.capabilities.first { $0.name == "App Groups" })
		XCTAssertEqual(capability.status, .supported)
		XCTAssertEqual(capability.detail, "Your Apple ID added them under names of its own, which the app and its extensions share. Atelier sends the app's own names to them.")
	}

	func testAnAppWithoutRoomForTheLibraryKeepsItsCode() async throws {
		let engine = FakeEngine()
		engine.noRoom = ["Test"]
		let signed = try await signChat(engine: engine)

		XCTAssertEqual(engine.loads, [:], "nor its extensions, which would use other names than the app")
		XCTAssertNil(try Fixture.entries(of: signed.url)["Payload/Test.app/Frameworks/AtelierAppGroups.dylib"])
		XCTAssertNil(try names(in: "Info.plist", of: signed.url))
		let report = try XCTUnwrap(signed.entitlements)
		XCTAssertEqual(report.items.first { $0.key == AppGroups.entitlement }?.redirected, false)
		XCTAssertEqual(report.capabilities.first { $0.name == "App Groups" }?.detail, "Your Apple ID added them under names of its own, which the app and its extensions share.")
	}

	func testAnExtensionWithoutRoomGoesOnWithoutIt() async throws {
		let engine = FakeEngine()
		engine.noRoom = ["PlugIns/Widget.appex/Widget"]
		let signed = try await signChat(engine: engine)

		XCTAssertEqual(Set(engine.loads.keys), ["Test", "Extensions/Share.appex/ShareExtension"])
		XCTAssertNil(try names(in: "PlugIns/Widget.appex/Info.plist", of: signed.url))
		XCTAssertEqual(try names(in: "Extensions/Share.appex/Info.plist", of: signed.url), [ownName: teamName])
		XCTAssertEqual(signed.entitlements?.items.first { $0.key == AppGroups.entitlement }?.redirected, true)
	}

	func testTheAppKeepsItsCodeWithoutTheLibraryOrTheGroups() async throws {
		// Share App Groups off.
		var engine = FakeEngine()
		var signed = try await signChat(library: false, engine: engine)
		XCTAssertEqual(engine.loads, [:])
		XCTAssertNil(try names(in: "Info.plist", of: signed.url))
		XCTAssertNil(signed.entitlements?.items.first { $0.key == AppGroups.entitlement }?.redirected)

		// Apple didn't give the App ID the group.
		engine = FakeEngine()
		signed = try await signChat(allowsGroup: false, engine: engine)
		XCTAssertEqual(engine.loads, [:])
		XCTAssertNil(try Fixture.entries(of: signed.url)["Payload/Test.app/Frameworks/AtelierAppGroups.dylib"])
		XCTAssertEqual(signed.entitlements?.items.first { $0.key == AppGroups.entitlement }?.outcome, .dropped)
	}

	func testALibraryLeftByAnEarlierSigningIsReplaced() async throws {
		let engine = FakeEngine()
		var files = try Fixture.appFiles(main: Fixture.signedMachO(cmsBytes: 64, entitlements: [AppGroups.entitlement: [ownName]]))
		files["Payload/Test.app/Frameworks/AtelierAppGroups.dylib"] = Fixture.machO()
		let ipa = try Fixture.ipa(files, in: folder)
		let profile = folder.appendingPathComponent("appleid.mobileprovision")
		try PropertyListSerialization.data(fromPropertyList: [
			"Name": "Apple ID", "UUID": "1", "TeamIdentifier": [team], "ExpirationDate": Date.distantFuture,
			"DeveloperCertificates": [Data()], "Entitlements": appleIDProfile,
		] as [String: Any], format: .xml, options: 0).write(to: profile)
		let libraryFile = folder.appendingPathComponent("new.dylib")
		try library.write(to: libraryFile)
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		let signed = try await signer.sign(
			ipa: ipa,
			with: SigningIdentity(p12: try Fixture.url("signing.p12"), profile: profile, password: Fixture.password),
			options: SigningOptions(appGroups: [ownName: teamName], appGroupsLibrary: libraryFile),
			outputDirectory: folder, progress: nil
		)
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/Frameworks/AtelierAppGroups.dylib", in: signed.url), library)
	}
}
