import Foundation
import InstallKit
import XCTest
@testable import CertKit

/// A free Apple ID's limits (#49): the apps that hold the 3 places on this
/// iPhone, the week's 10 App IDs, and the bundle IDs apps install as.
final class AppleIDLimitsTests: XCTestCase {
	private func profile(_ appID: String, created: Date, days: Double, devices: [String] = ["00008110-0001"], getTaskAllow: Bool = true) throws -> ProvisioningProfile {
		try ProvisioningProfile(plist: [
			"Name": "iOS Team Provisioning Profile: \(appID)",
			"UUID": UUID().uuidString,
			"TeamIdentifier": [String(appID.prefix { $0 != "." })],
			"CreationDate": created,
			"ExpirationDate": created.addingTimeInterval(days * 86_400),
			"DeveloperCertificates": [Data()],
			"ProvisionedDevices": devices,
			"Entitlements": ["application-identifier": appID, "get-task-allow": getTaskAllow],
		])
	}

	private let start = Fixture.utc(2026, 11, 2)

	func testAFreeProfileLastsSevenDays() throws {
		XCTAssertTrue(FreeAppleID.isFree(try profile("A1B2C3D4E5.com.example.app.A1B2C3D4E5", created: start, days: 7)))
		XCTAssertFalse(FreeAppleID.isFree(try profile("Q1W2E3R4T5.com.example.app", created: start, days: 365)), "a paid team's lasts a year")
		XCTAssertFalse(FreeAppleID.isFree(try profile("Q1W2E3R4T5.com.example.app", created: start, days: 7, getTaskAllow: false)), "ad hoc isn't a free Apple ID's")
		XCTAssertFalse(FreeAppleID.isFree(try profile("Q1W2E3R4T5.com.example.app", created: start, days: 7, devices: [])), "nor is an App Store one")
	}

	func testTheAppsHoldingThePlacesAreThoseInstalledWithAFreeProfile() throws {
		let installed = [
			InstalledApp(bundleID: "com.example.twelve.A1B2C3D4E5", version: "4.2.1", build: "42", name: "30sec"),
			InstalledApp(bundleID: "com.example.signed", version: "1.0", build: "1", name: "Signed Elsewhere"),
			InstalledApp(bundleID: "com.SideStore.SideStore.Q1W2E3R4T5", version: "0.7", build: "7", name: "SideStore"),
		]
		let profiles = [
			try profile("A1B2C3D4E5.com.example.twelve.A1B2C3D4E5", created: start, days: 7),
			// Deleted from the Home Screen: iOS keeps its profile.
			try profile("A1B2C3D4E5.com.example.gone.A1B2C3D4E5", created: start, days: 7),
			try profile("Z9Y8X7W6V5.com.example.signed", created: start, days: 365),
			try profile("Q1W2E3R4T5.com.SideStore.SideStore.Q1W2E3R4T5", created: start, days: 7),
		]
		XCTAssertEqual(FreeAppleID.apps(installed: installed, profiles: profiles), [
			FreeApp(bundleID: "com.example.twelve.A1B2C3D4E5", name: "30sec", teamID: "A1B2C3D4E5"),
			FreeApp(bundleID: "com.SideStore.SideStore.Q1W2E3R4T5", name: "SideStore", teamID: "Q1W2E3R4T5"),
		])
		XCTAssertEqual(FreeAppleID.apps(installed: installed, profileFiles: [Data("not a profile".utf8)]), [])
	}

	func testThereIsRoomUntilThreeAppsHoldThePlaces() {
		let app = { (name: String) in FreeApp(bundleID: "com.example.\(name)", name: name, teamID: "A1B2C3D4E5") }
		XCTAssertTrue(AppleIDLimits.Apps(checkedAt: start, apps: [app("one"), app("two")]).hasRoom)
		XCTAssertFalse(AppleIDLimits.Apps(checkedAt: start, apps: [app("one"), app("two"), app("three")]).hasRoom)
	}

	func testAppIDsComeBackAWeekAfterTheyWereAdded() {
		let day = { (days: Double) in self.start.addingTimeInterval(days * 86_400) }
		let appIDs = AppleIDLimits.AppIDs(checkedAt: start, max: 10, available: 0, expiries: [day(5), day(2), day(-1), day(6)])
		XCTAssertEqual(appIDs.left(now: start), 0)
		XCTAssertEqual(appIDs.nextReturn(now: start), day(2), "the soonest still to come")
		XCTAssertEqual(appIDs.left(now: day(3)), 1, "one came back since Apple said")
		XCTAssertEqual(appIDs.nextReturn(now: day(3)), day(5))
		XCTAssertEqual(appIDs.left(now: day(7)), 3, "the one that expired before Apple said is already counted")
		XCTAssertNil(appIDs.nextReturn(now: day(7)))
		XCTAssertTrue(appIDs.isLimited)

		let full = AppleIDLimits.AppIDs(checkedAt: start, max: 10, available: 10, expiries: [day(1)])
		XCTAssertEqual(full.left(now: day(2)), 10, "never more than Apple allows")

		let paid = AppleIDLimits.AppIDs(checkedAt: start, max: nil, available: nil, expiries: [])
		XCTAssertNil(paid.left(now: start))
		XCTAssertFalse(paid.isLimited)
	}

	func testTheAppIDsAreKeptWithTheirApps() throws {
		let day = { (days: Double) in self.start.addingTimeInterval(days * 86_400) }
		let list = AppleIDAppIDList(
			appIDs: [
				.init(identifier: "com.b.A1B2C3D4E5", name: "B", expires: day(5)),
				.init(identifier: "com.a.A1B2C3D4E5", name: "A", expires: day(2)),
				.init(identifier: "com.gone.A1B2C3D4E5", name: "Gone", expires: day(-1)),
				.init(identifier: "com.lasting.A1B2C3D4E5", name: "Lasting", expires: nil),
			],
			max: 10,
			available: 7
		)
		let appIDs = list.limits(checkedAt: start)
		XCTAssertEqual(appIDs.entries, list.appIDs)
		XCTAssertEqual(appIDs.current(now: start)?.map(\.name), ["A", "B", "Lasting"], "the one that ends soonest first, without the one that ended")
		XCTAssertEqual(appIDs.current(now: day(3))?.map(\.name), ["B", "Lasting"])
		XCTAssertNil(AppleIDLimits.AppIDs(checkedAt: start, max: 10, available: 7, expiries: [day(2)]).current(now: start), "not kept")

		// Counts kept before the App IDs were decode without them.
		let older = #"{"checkedAt":0,"max":10,"available":4,"expiries":[0]}"#
		let decoded = try JSONDecoder().decode(AppleIDLimits.AppIDs.self, from: Data(older.utf8))
		XCTAssertNil(decoded.entries)
		XCTAssertEqual(decoded.available, 4)
		XCTAssertEqual(try JSONDecoder().decode(AppleIDLimits.AppIDs.self, from: JSONEncoder().encode(appIDs)), appIDs)
	}

	func testAppsInstallAsTheirBundleIDAndTheTeamID() throws {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("development.mobileprovision"))
		let certificate = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "development.mobileprovision")).certificate
		var account = StoredAppleID(email: "sam.test@icloud.com", team: .init(id: "A1B2C3D4E5", name: nil, isFree: true), certificate: certificate, machineName: "Atelier")
		XCTAssertTrue(account.isFree)
		XCTAssertEqual(account.bundleID(for: "com.example.app"), "com.example.app.A1B2C3D4E5")
		XCTAssertEqual(account.bundleID(for: "com.example.app.A1B2C3D4E5"), "com.example.app.A1B2C3D4E5", "one signed with it before keeps its own")
		// And back, for the apps that have the team's App IDs.
		XCTAssertEqual(account.appBundleID(forAppID: "com.example.app.A1B2C3D4E5"), "com.example.app")
		XCTAssertEqual(account.appBundleID(forAppID: "com.Example.app.a1b2c3d4e5"), "com.Example.app", "whatever the case")
		XCTAssertNil(account.appBundleID(forAppID: "com.example.app"), "one Xcode made, which Atelier never signs as")
		XCTAssertNil(account.appBundleID(forAppID: "com.example.app.F6G7H8I9J0"), "another team's")
		XCTAssertNil(account.appBundleID(forAppID: ".A1B2C3D4E5"))

		let first = AppProfile(bundleID: "com.example.app.A1B2C3D4E5", uuid: "1", expires: start)
		let renewed = AppProfile(bundleID: "com.example.app.A1B2C3D4E5", uuid: "2", expires: start.addingTimeInterval(7 * 86_400))
		let other = AppProfile(bundleID: "com.example.other.A1B2C3D4E5", uuid: "3", expires: start)
		account.note(first)
		account.note(other)
		account.note(renewed)
		XCTAssertEqual(account.profile(for: "com.example.app.A1B2C3D4E5"), renewed, "the new one replaces the one before")
		XCTAssertEqual(account.profiles?.count, 2)
	}
}

/// Whether an app fits in an Apple ID's limits before Apple is asked
/// (#49).
final class AppleIDRoomTests: XCTestCase {
	private let now = Fixture.utc(2026, 11, 3, 14, 40)

	private func app(_ bundleID: String) -> FreeApp {
		FreeApp(bundleID: bundleID, name: bundleID, teamID: "A1B2C3D4E5")
	}

	func testAnAppFindsAPlaceUntilThreeAreTaken() {
		let two = [app("com.a.A1B2C3D4E5"), app("com.b.A1B2C3D4E5")]
		XCTAssertEqual(AppleIDRoom.place(for: "com.c.A1B2C3D4E5", apps: []), .free)
		XCTAssertEqual(AppleIDRoom.place(for: "com.c.A1B2C3D4E5", apps: two), .free)
		let three = two + [app("com.sidestore.SideStore.F9E8D7C6B5")]
		XCTAssertEqual(AppleIDRoom.place(for: "com.c.A1B2C3D4E5", apps: three), .full(three))
	}

	func testAnAppThatHoldsAPlaceKeepsIt() {
		let three = [app("com.a.A1B2C3D4E5"), app("com.b.A1B2C3D4E5"), app("com.c.A1B2C3D4E5")]
		XCTAssertEqual(AppleIDRoom.place(for: "com.b.A1B2C3D4E5", apps: three), .holds)
		// Signed again with an imported certificate, then with the Apple ID.
		XCTAssertEqual(AppleIDRoom.place(for: "com.d.A1B2C3D4E5", replacing: "com.c.A1B2C3D4E5", apps: three), .holds)
	}

	func testAnAppIDTheTeamHasIsUsedAgain() {
		let list = AppleIDAppIDList(
			appIDs: [
				.init(identifier: "com.a.A1B2C3D4E5", name: "A", expires: Fixture.utc(2026, 11, 9, 18, 2)),
				.init(identifier: "com.old.A1B2C3D4E5", name: "Old", expires: Fixture.utc(2026, 11, 2)),
			],
			max: 10,
			available: 0
		)
		XCTAssertEqual(AppleIDRoom.appID(for: "com.a.A1B2C3D4E5", in: list, now: now), .has(expires: Fixture.utc(2026, 11, 9, 18, 2)))
		XCTAssertEqual(AppleIDRoom.appID(for: "COM.A.a1b2c3d4e5", in: list, now: now), .has(expires: Fixture.utc(2026, 11, 9, 18, 2)), "whatever the case")
		// One that expired is gone, and needs adding again.
		XCTAssertEqual(AppleIDRoom.appID(for: "com.old.A1B2C3D4E5", in: list, now: now), .noneLeft(nextReturn: Fixture.utc(2026, 11, 9, 18, 2)))
	}

	func testANewAppIDTakesOneOfTheWeeks() {
		var list = AppleIDAppIDList(appIDs: [], max: 10, available: 7)
		XCTAssertEqual(AppleIDRoom.appID(for: "com.new.A1B2C3D4E5", in: list, now: now), .adds(left: 7))
		list.available = 0
		XCTAssertEqual(AppleIDRoom.appID(for: "com.new.A1B2C3D4E5", in: list, now: now), .noneLeft(nextReturn: nil))
		// A paid team's aren't counted.
		XCTAssertEqual(AppleIDRoom.appID(for: "com.new.A1B2C3D4E5", in: AppleIDAppIDList(appIDs: [], max: nil, available: nil), now: now), .adds(left: nil))
	}

	func testTheCountsAfterAnInstall() {
		let before = AppleIDLimits.AppIDs(checkedAt: Fixture.utc(2026, 11, 3), max: 10, available: 7, expiries: [Fixture.utc(2026, 11, 9)])
		let after = before.adding(expires: Fixture.utc(2026, 11, 10, 14, 40), available: 7, max: 10, at: now)
		XCTAssertEqual(after, AppleIDLimits.AppIDs(checkedAt: now, max: 10, available: 6, expiries: [Fixture.utc(2026, 11, 9), Fixture.utc(2026, 11, 10, 14, 40)]))
		XCTAssertEqual(after.left(now: now), 6)
		// With the App IDs kept, the new one joins them; without, the next
		// check lists them all.
		XCTAssertNil(before.adding(expires: Fixture.utc(2026, 11, 10, 14, 40), available: 7, max: 10, identifier: "com.b.A1B2C3D4E5", name: "B", at: now).entries)
		let kept = AppleIDLimits.AppIDs(
			checkedAt: Fixture.utc(2026, 11, 3), max: 10, available: 7, expiries: [Fixture.utc(2026, 11, 9)],
			entries: [.init(identifier: "com.a.A1B2C3D4E5", name: "A", expires: Fixture.utc(2026, 11, 9))]
		)
		let added = kept.adding(expires: Fixture.utc(2026, 11, 10, 14, 40), available: 7, max: 10, identifier: "com.b.A1B2C3D4E5", name: "B", at: now)
		XCTAssertEqual(added.entries, [
			.init(identifier: "com.a.A1B2C3D4E5", name: "A", expires: Fixture.utc(2026, 11, 9)),
			.init(identifier: "com.b.A1B2C3D4E5", name: "B", expires: Fixture.utc(2026, 11, 10, 14, 40)),
		])
		XCTAssertEqual(added.left(now: now), 6)
		let again = added.adding(expires: Fixture.utc(2026, 11, 11), available: 6, max: 10, identifier: "COM.B.A1B2C3D4E5", name: "B", at: now)
		XCTAssertEqual(again.entries?.map(\.identifier), ["com.a.A1B2C3D4E5", "COM.B.A1B2C3D4E5"], "one for each App ID")

		let apps = AppleIDLimits.Apps(checkedAt: Fixture.utc(2026, 11, 3), apps: [app("com.a.A1B2C3D4E5"), app("com.b")])
		XCTAssertEqual(apps.installing(app("com.c.A1B2C3D4E5"), at: now).apps.map(\.bundleID), ["com.a.A1B2C3D4E5", "com.b", "com.c.A1B2C3D4E5"])
		XCTAssertEqual(apps.installing(app("com.a.A1B2C3D4E5"), at: now).apps.map(\.bundleID), ["com.b", "com.a.A1B2C3D4E5"])
		XCTAssertEqual(apps.installing(app("com.b.A1B2C3D4E5"), replacing: "com.b", at: now).apps.map(\.bundleID), ["com.a.A1B2C3D4E5", "com.b.A1B2C3D4E5"])
	}
}
