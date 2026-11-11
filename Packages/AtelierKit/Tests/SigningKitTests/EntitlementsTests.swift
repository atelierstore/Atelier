import Foundation
import XCTest
@testable import SigningKit

/// Fitting entitlements to the profile (#7): reading them from binaries,
/// reconciling them with wildcard and explicit profiles, and what the
/// report says won't work.
final class EntitlementsTests: XCTestCase {
	private let team = "USERTEAM01"
	private let developer = "DEVTEAM123"

	/// A reseller-style wildcard profile: keychain groups, nothing else.
	private var wildcardProfile: [String: Any] {
		[
			"application-identifier": "\(team).*",
			"com.apple.developer.team-identifier": team,
			"get-task-allow": false,
			"keychain-access-groups": ["\(team).*"],
		]
	}

	/// A profile for one App ID that grants push and one app group.
	private var explicitProfile: [String: Any] {
		[
			"application-identifier": "\(team).com.reseller.app",
			"com.apple.developer.team-identifier": team,
			"aps-environment": "production",
			"com.apple.security.application-groups": ["group.com.reseller.app"],
			"keychain-access-groups": ["\(team).*"],
		]
	}

	/// What a developer's build of com.example.chat asks for.
	private var appEntitlements: [String: Any] {
		[
			"application-identifier": "\(developer).com.example.chat",
			"com.apple.developer.team-identifier": developer,
			"aps-environment": "production",
			"com.apple.security.application-groups": ["group.com.example.chat"],
			"keychain-access-groups": ["\(developer).com.example.chat", "\(developer).com.example.shared"],
		]
	}

	private var widgetEntitlements: [String: Any] {
		[
			"application-identifier": "\(developer).com.example.chat.widget",
			"com.apple.developer.team-identifier": developer,
			"com.apple.security.application-groups": ["group.com.example.chat"],
			"keychain-access-groups": ["\(developer).com.example.shared"],
		]
	}

	private func item(_ key: String, in report: EntitlementsReport, file: StaticString = #filePath, line: UInt = #line) throws -> EntitlementsReport.Item {
		try XCTUnwrap(report.items.first { $0.key == key }, "no \(key) in \(report.items.map(\.key))", file: file, line: line)
	}

	// MARK: Wildcard profile

	func testWildcardProfileKeepsTheAppsKeychainGroupsUnderTheUsersTeam() throws {
		let result = EntitlementReconciler.reconcile(
			profile: wildcardProfile, teamID: team, isWildcard: true,
			bundles: [.init(name: "", entitlements: appEntitlements)]
		)

		// The app's groups, its own first, so its default keychain group is its own.
		XCTAssertEqual(result.entitlements["keychain-access-groups"] as? [String], ["\(team).com.example.chat", "\(team).com.example.shared"])
		// Everything else stays the profile's, as signed before #7.
		XCTAssertEqual(result.entitlements["application-identifier"] as? String, "\(team).*")
		XCTAssertEqual(result.entitlements["get-task-allow"] as? Bool, false)
		XCTAssertNil(result.entitlements["aps-environment"])
		XCTAssertNil(result.entitlements["com.apple.security.application-groups"])

		let report = result.report
		XCTAssertEqual(report.appTeamID, developer)
		XCTAssertEqual(report.profileTeamID, team)
		XCTAssertEqual(try item("keychain-access-groups", in: report).outcome, .rewritten)
		XCTAssertEqual(try item("aps-environment", in: report).outcome, .dropped)
		XCTAssertEqual(try item("com.apple.security.application-groups", in: report).outcome, .dropped)
		XCTAssertFalse(report.items.contains { EntitlementsReport.fromProfile.contains($0.key) })
		XCTAssertEqual(report.extensionsUnderOneAppID, [])
		XCTAssertEqual(report.limits, [
			"Push notifications won't work: your certificate doesn't allow it.",
			"App Groups won't work: your certificate doesn't allow it.",
		])
	}

	func testWildcardProfileSignsExtensionsWithTheSameGroups() throws {
		let result = EntitlementReconciler.reconcile(
			profile: wildcardProfile, teamID: team, isWildcard: true,
			bundles: [.init(name: "", entitlements: appEntitlements), .init(name: "Widget", entitlements: widgetEntitlements)]
		)
		// One set for every bundle: the app's groups and the widget's, merged.
		XCTAssertEqual(result.entitlements["keychain-access-groups"] as? [String], ["\(team).com.example.chat", "\(team).com.example.shared"])
		let groups = try item("com.apple.security.application-groups", in: result.report)
		XCTAssertEqual(groups.outcome, .dropped)
		XCTAssertEqual(groups.bundles, ["", "Widget"])
		XCTAssertEqual(result.report.extensionsUnderOneAppID, [], "a wildcard App ID covers the widget's bundle ID")
		XCTAssertTrue(result.report.limits.contains("The app and its extensions can't share data: your certificate doesn't allow App Groups."), "\(result.report.limits)")
	}

	// MARK: Explicit profile

	func testExplicitProfileWithExtensionsAndAppGroups() throws {
		let result = EntitlementReconciler.reconcile(
			profile: explicitProfile, teamID: team, isWildcard: false,
			bundles: [.init(name: "", entitlements: appEntitlements), .init(name: "Widget", entitlements: widgetEntitlements)]
		)

		// The profile's group stays signed in, but it isn't the one the app's code opens.
		XCTAssertEqual(result.entitlements["com.apple.security.application-groups"] as? [String], ["group.com.reseller.app"])
		XCTAssertEqual(result.entitlements["application-identifier"] as? String, "\(team).com.reseller.app")
		XCTAssertEqual(result.entitlements["aps-environment"] as? String, "production")

		let report = result.report
		XCTAssertEqual(try item("com.apple.security.application-groups", in: report).outcome, .dropped)
		// Granted, but the developer's push service only knows their own team's app.
		XCTAssertEqual(try item("aps-environment", in: report).outcome, .teamBound)
		XCTAssertEqual(report.extensionsUnderOneAppID, ["Widget"])
		XCTAssertEqual(report.limits, [
			"The app and its extensions can't share data: your certificate doesn't allow App Groups.",
			"Push notifications probably won't work: it only works in the developer's own copy of the app.",
			"Your certificate only covers the app itself, so its extension may not work.",
		])
	}

	func testExplicitProfileWithoutExtensionsHasNoExtensionWarning() {
		let result = EntitlementReconciler.reconcile(
			profile: explicitProfile, teamID: team, isWildcard: false,
			bundles: [.init(name: "", entitlements: appEntitlements)]
		)
		XCTAssertEqual(result.report.extensionsUnderOneAppID, [])
	}

	// MARK: Values

	func testAGroupTheProfileGrantsIsKeptAndTheRestListed() throws {
		var profile = explicitProfile
		profile["com.apple.security.application-groups"] = ["group.com.example.chat", "group.com.reseller.app"]
		var app = appEntitlements
		app["com.apple.security.application-groups"] = ["group.com.example.chat", "group.com.example.other"]
		let report = EntitlementReconciler.reconcile(profile: profile, teamID: team, isWildcard: false, bundles: [.init(name: "", entitlements: app)]).report

		let groups = try item("com.apple.security.application-groups", in: report)
		XCTAssertEqual(groups.outcome, .kept)
		XCTAssertEqual(groups.missingValues, ["group.com.example.other"])
		XCTAssertTrue(report.limits.contains("App Groups may only partly work: your certificate doesn't allow all of it."), "\(report.limits)")
	}

	func testTheUsersOwnAppKeepsTeamBoundFeatures() throws {
		var app = appEntitlements
		app["com.apple.developer.team-identifier"] = team
		app["application-identifier"] = "\(team).com.example.chat"
		app["keychain-access-groups"] = ["\(team).com.example.chat"]
		let report = EntitlementReconciler.reconcile(profile: explicitProfile, teamID: team, isWildcard: false, bundles: [.init(name: "", entitlements: app)]).report
		XCTAssertEqual(report.appTeamID, team)
		XCTAssertEqual(try item("aps-environment", in: report).outcome, .kept)
		XCTAssertEqual(try item("keychain-access-groups", in: report).outcome, .kept)
	}

	func testKeychainGroupsTheProfileDoesntCoverAreLeftOut() throws {
		var profile = wildcardProfile
		profile["keychain-access-groups"] = ["\(team).com.example.chat"]
		var app = appEntitlements
		app["keychain-access-groups"] = ["\(developer).com.example.chat", "com.apple.token"]
		let result = EntitlementReconciler.reconcile(profile: profile, teamID: team, isWildcard: true, bundles: [.init(name: "", entitlements: app)])
		XCTAssertEqual(result.entitlements["keychain-access-groups"] as? [String], ["\(team).com.example.chat"])
		XCTAssertEqual(try item("keychain-access-groups", in: result.report).missingValues, ["com.apple.token"])
	}

	func testWithoutKeychainGroupsTheProfilesStay() {
		var app = appEntitlements
		app["keychain-access-groups"] = nil
		let result = EntitlementReconciler.reconcile(profile: wildcardProfile, teamID: team, isWildcard: true, bundles: [.init(name: "", entitlements: app)])
		XCTAssertEqual(result.entitlements["keychain-access-groups"] as? [String], ["\(team).*"])
	}

	func testAnAppWithNoEntitlementsLosesNothing() {
		let result = EntitlementReconciler.reconcile(profile: wildcardProfile, teamID: team, isWildcard: true, bundles: [.init(name: "", entitlements: [:])], readFromApp: false)
		XCTAssertEqual(result.report.items, [])
		XCTAssertEqual(result.report.limits, [])
		XCTAssertNil(result.report.appTeamID)
		XCTAssertFalse(result.report.readFromApp)
		XCTAssertEqual(result.entitlements as NSDictionary, wildcardProfile as NSDictionary)
	}

	func testCoverage() {
		XCTAssertTrue(EntitlementReconciler.covers("\(team).*", "\(team).com.example", key: "k"))
		XCTAssertFalse(EntitlementReconciler.covers("\(team).com.a.*", "\(team).com.b", key: "k"))
		XCTAssertTrue(EntitlementReconciler.covers("*", "anything", key: "k"))
		XCTAssertTrue(EntitlementReconciler.covers(["a", "b*"], "bee", key: "k"))
		XCTAssertFalse(EntitlementReconciler.covers(["a"], "b", key: "k"))
		XCTAssertTrue(EntitlementReconciler.covers(true, true, key: "k"))
		XCTAssertTrue(EntitlementReconciler.covers(false, false, key: "k"))
		XCTAssertFalse(EntitlementReconciler.covers(false, true, key: "k"))
		XCTAssertTrue(EntitlementReconciler.covers("development", "production", key: "aps-environment"))
		XCTAssertEqual(EntitlementReconciler.teamPrefix("ABCDE12345.com.example"), "ABCDE12345")
		XCTAssertNil(EntitlementReconciler.teamPrefix("group.com.example"))
		XCTAssertNil(EntitlementReconciler.teamPrefix("abcde12345.com.example"))
	}

	// MARK: From the source

	func testPredictsFromTheSourcesKeys() {
		let report = EntitlementsReport.predict(
			sourceKeys: ["aps-environment", "com.apple.security.application-groups", "get-task-allow", "com.apple.developer.healthkit"],
			profileKeys: ["aps-environment", "com.apple.developer.healthkit", "application-identifier"],
			profileTeamID: team
		)
		XCTAssertFalse(report.readFromApp)
		XCTAssertEqual(report.items.map(\.key), ["aps-environment", "com.apple.developer.healthkit", "com.apple.security.application-groups"])
		XCTAssertEqual(report.items.map(\.outcome), [.teamBound, .kept, .dropped])
		XCTAssertEqual(report.limits, [
			"App Groups won't work: your certificate doesn't allow it.",
			"Push notifications probably won't work: it only works in the developer's own copy of the app.",
		])
	}

	func testLimitsNameAFeatureOnce() {
		let report = EntitlementsReport(
			items: [
				.init(key: "com.apple.developer.icloud-container-identifiers", outcome: .dropped),
				.init(key: "com.apple.developer.icloud-services", outcome: .dropped),
				.init(key: "com.example.custom", outcome: .dropped),
			],
			profileTeamID: team, appTeamID: developer
		)
		XCTAssertEqual(report.limits, [
			"iCloud won't work: your certificate doesn't allow it.",
			"com.example.custom won't work: your certificate doesn't allow it.",
		])
	}

	func testReportRoundTripsThroughJSON() throws {
		let report = EntitlementReconciler.reconcile(profile: explicitProfile, teamID: team, isWildcard: false, bundles: [.init(name: "", entitlements: appEntitlements)]).report
		let decoded = try JSONDecoder().decode(EntitlementsReport.self, from: JSONEncoder().encode(report))
		XCTAssertEqual(decoded, report)
	}

	// MARK: Reading binaries

	func testReadsEntitlementsFromBinaries() throws {
		let folder = try Fixture.temporaryFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		func read(_ data: Data) throws -> [String: Any]? {
			let url = folder.appendingPathComponent(UUID().uuidString)
			try data.write(to: url)
			return try MachO.entitlements(url).map { try XCTUnwrap(PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]) }
		}
		let entitlements: [String: Any] = ["application-identifier": "\(developer).com.example.chat", "get-task-allow": false]
		XCTAssertEqual(try read(Fixture.signedMachO(cmsBytes: 64, entitlements: entitlements)) as NSDictionary?, entitlements as NSDictionary)
		XCTAssertEqual(try read(Fixture.fat([Fixture.signedMachO(cmsBytes: 64, entitlements: entitlements), Fixture.machO()])) as NSDictionary?, entitlements as NSDictionary)
		// Signed without entitlements, unsigned, or not Mach-O at all.
		XCTAssertNil(try read(Fixture.signedMachO(cmsBytes: 64)))
		XCTAssertNil(try read(Fixture.machO()))
		XCTAssertNil(try read(Data("text".utf8)))
		// The CMS check still finds its blob past the entitlements.
		let url = folder.appendingPathComponent("cms")
		try Fixture.signedMachO(cmsBytes: 64, entitlements: entitlements).write(to: url)
		XCTAssertTrue(try MachO.hasCMSSignature(url))
	}
}

/// The signing job reads the app's entitlements and hands zsign the fitted
/// set, with the fixture profile (`TESTTEAM01.*`, keychain `TESTTEAM01.*`).
final class SigningEntitlementsTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func identity(profile: URL? = nil) throws -> SigningIdentity {
		SigningIdentity(p12: try Fixture.url("signing.p12"), profile: try profile ?? Fixture.url("development.mobileprovision"), password: Fixture.password)
	}

	private func ipa() throws -> URL {
		var files = try Fixture.appFiles(main: Fixture.signedMachO(cmsBytes: 64, entitlements: [
			"application-identifier": "DEVTEAM123.com.example.test",
			"com.apple.developer.team-identifier": "DEVTEAM123",
			"aps-environment": "production",
			"keychain-access-groups": ["DEVTEAM123.com.example.test"],
		]))
		files["Payload/Test.app/PlugIns/Widget.appex/Widget"] = Fixture.signedMachO(cmsBytes: 64, entitlements: [
			"application-identifier": "DEVTEAM123.com.example.test.widget",
			"keychain-access-groups": ["DEVTEAM123.com.example.shared"],
		])
		return try Fixture.ipa(files, in: folder)
	}

	private func sign(options: SigningOptions = SigningOptions(), profile: URL? = nil, engine: FakeEngine) async throws -> SignedIPA {
		let signer = IPASigner(engine: engine, workRoot: folder.appendingPathComponent("work"))
		return try await signer.sign(ipa: try ipa(), with: try identity(profile: profile), options: options, outputDirectory: folder, progress: nil)
	}

	func testSignsWithTheFittedEntitlements() async throws {
		let engine = FakeEngine()
		let signed = try await sign(engine: engine)

		let entitlements = try XCTUnwrap(engine.lastEntitlements)
		XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["TESTTEAM01.com.example.test", "TESTTEAM01.com.example.shared"])
		XCTAssertEqual(entitlements["application-identifier"] as? String, "TESTTEAM01.*")
		XCTAssertEqual(entitlements["get-task-allow"] as? Bool, true)

		let report = try XCTUnwrap(signed.entitlements)
		XCTAssertTrue(report.readFromApp)
		XCTAssertEqual(report.appTeamID, "DEVTEAM123")
		XCTAssertEqual(report.items.map(\.key), ["aps-environment", "keychain-access-groups"])
		XCTAssertEqual(report.items.map(\.outcome), [.dropped, .rewritten])
		XCTAssertEqual(report.items.last?.bundles, ["", "Widget"])
		XCTAssertEqual(report.limits, ["Push notifications won't work: your certificate doesn't allow it."])
	}

	func testFittingCanBeTurnedOff() async throws {
		let engine = FakeEngine()
		let signed = try await sign(options: SigningOptions(fitsEntitlements: false), engine: engine)
		XCTAssertNil(engine.lastOptions?.entitlements, "zsign uses the profile's own")
		XCTAssertNotNil(signed.entitlements, "the report is still made")
	}

	func testAGivenEntitlementsFileIsUsedAsItIs() async throws {
		let file = folder.appendingPathComponent("given.plist")
		try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": true], format: .xml, options: 0).write(to: file)
		let engine = FakeEngine()
		_ = try await sign(options: SigningOptions(entitlements: file), engine: engine)
		XCTAssertEqual(engine.lastOptions?.entitlements, file)
	}

	func testExplicitProfileWarnsAboutTheExtension() async throws {
		// A bare plist reads as a profile too.
		let profile = folder.appendingPathComponent("explicit.mobileprovision")
		let plist: [String: Any] = [
			"Name": "Explicit", "UUID": "1", "TeamIdentifier": ["TESTTEAM01"],
			"ExpirationDate": Date.distantFuture, "DeveloperCertificates": [Data()],
			"ProvisionedDevices": ["00008110-000A1B2C3D4E5F60"],
			"Entitlements": ["application-identifier": "TESTTEAM01.com.reseller.app", "keychain-access-groups": ["TESTTEAM01.*"]],
		]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: profile)
		let signed = try await sign(profile: profile, engine: FakeEngine())
		XCTAssertEqual(signed.entitlements?.extensionsUnderOneAppID, ["Widget"])
	}

	func testAnUnreadableProfileLeavesItToZsign() async throws {
		let engine = FakeEngine()
		let signed = try await sign(profile: URL(fileURLWithPath: "/nonexistent.mobileprovision"), engine: engine)
		XCTAssertNil(signed.entitlements)
		XCTAssertNil(engine.lastOptions?.entitlements)
	}

	func testCapabilitiesGroupByFeatureWithTheLeastSupport() {
		let report = EntitlementsReport(items: [
			.init(key: "aps-environment", outcome: .teamBound),
			.init(key: "com.apple.developer.icloud-container-identifiers", outcome: .kept),
			.init(key: "com.apple.developer.icloud-services", outcome: .dropped),
			.init(key: "com.apple.security.application-groups", outcome: .dropped, bundles: ["", "Widget"]),
			.init(key: "keychain-access-groups", outcome: .rewritten, missingValues: ["TEAM.other"]),
			.init(key: "com.apple.developer.game-center", outcome: .kept),
		], profileTeamID: "TEAMAAAAAA", appTeamID: "TEAMBBBBBB", extensionsUnderOneAppID: ["Widget"])
		let capabilities = report.capabilities
		XCTAssertEqual(capabilities.map(\.name), ["App Groups", "Game Center", "iCloud", "Keychain sharing", "Push notifications"])
		XCTAssertEqual(capabilities.map(\.status), [.unsupported, .supported, .unsupported, .partly, .probablyNot])
		XCTAssertEqual(capabilities[0].detail, "Your certificate doesn't allow App Groups, so the app and its extensions can't share data.")
		XCTAssertNil(capabilities[1].detail)
		XCTAssertEqual(capabilities[2].keys, ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services"])
		XCTAssertEqual(capabilities[3].detail, "Your certificate doesn't allow all of it.")
		XCTAssertEqual(report.notes, ["Your certificate only covers the app itself, so its extension may not work."])
	}

	func testUncheckedCapabilitiesLeaveOutTheProfilesOwnKeys() {
		let capabilities = EntitlementsReport.unchecked(sourceKeys: ["aps-environment", "get-task-allow", "com.apple.developer.icloud-services", "com.apple.developer.ubiquity-kvstore-identifier"])
		XCTAssertEqual(capabilities, [
			.init(name: "iCloud", status: nil, keys: ["com.apple.developer.icloud-services", "com.apple.developer.ubiquity-kvstore-identifier"]),
			.init(name: "Push notifications", status: nil, keys: ["aps-environment"]),
		])
	}

	func testSignedPermissionsRoundTrip() throws {
		let permissions = SignedPermissions(privacy: ["NSCameraUsageDescription": "Scans codes."], entitlements: EntitlementsReport(items: [.init(key: "aps-environment", outcome: .dropped)], profileTeamID: "TEAMAAAAAA", appTeamID: nil))
		XCTAssertEqual(SignedPermissions.decoded(from: try XCTUnwrap(permissions.encoded())), permissions)
	}
}
