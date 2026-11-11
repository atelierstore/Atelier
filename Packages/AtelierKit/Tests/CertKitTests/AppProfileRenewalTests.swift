import Foundation
import XCTest
@testable import CertKit

/// Renewing an Apple ID's apps with a new profile, without reinstalling
/// them (#49).
final class AppProfileRenewalTests: XCTestCase {
	private let start = Fixture.utc(2026, 11, 8, 18, 5)
	private let appID = "A1B2C3D4E5.com.example.atlas.A1B2C3D4E5"

	/// The fixture's certificate stands for the Apple ID's: made on 18 Oct
	/// 2026.
	private func signing() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("development.mobileprovision")).developerCertificates[0]
	}

	private func other() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("mismatched.mobileprovision")).developerCertificates[0]
	}

	private func account(free: Bool = true, revocation: RevocationState? = nil) throws -> StoredAppleID {
		StoredAppleID(
			addedAt: Fixture.utc(2026, 11, 2),
			email: "sam@example.com",
			team: StoredAppleID.Team(id: "A1B2C3D4E5", name: "Sam Test", isFree: free),
			certificate: try SigningCertificate(der: signing()),
			machineName: "Atelier",
			revocation: revocation
		)
	}

	private func profile(_ appID: String? = nil, uuid: String = UUID().uuidString, created: Date, days: Double = 7, certificates: [Data]) throws -> ProvisioningProfile {
		try ProvisioningProfile(plist: [
			"Name": "iOS Team Provisioning Profile: \(appID ?? self.appID)",
			"UUID": uuid,
			"TeamIdentifier": ["A1B2C3D4E5"],
			"CreationDate": created,
			"ExpirationDate": created.addingTimeInterval(days * 86_400),
			"DeveloperCertificates": certificates,
			"ProvisionedDevices": ["00008110-0001"],
			"Entitlements": ["application-identifier": appID ?? self.appID, "get-task-allow": true],
		])
	}

	private func day(_ days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

	func testAFreeAppRenewsTwoDaysBeforeItsProfileEnds() {
		let atlas = AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "U1", expires: day(7))
		XCTAssertEqual(AppProfileRenewal.date(toRenew: atlas, isFree: true), day(5))
		XCTAssertFalse(AppProfileRenewal.isDue(atlas, isFree: true, now: day(4.9)))
		XCTAssertTrue(AppProfileRenewal.isDue(atlas, isFree: true, now: day(5)))
		XCTAssertTrue(AppProfileRenewal.isDue(atlas, isFree: true, now: day(8)), "and after it ended")

		let paid = AppProfile(bundleID: "com.example.atlas", uuid: "U2", expires: day(365))
		XCTAssertEqual(AppProfileRenewal.date(toRenew: paid, isFree: false), day(351), "a paid team's, two weeks before its year ends")
	}

	func testTheAppsDueAreTheOnesThatEndSoonest() throws {
		var account = try account()
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "U1", expires: day(7)))
		account.note(AppProfile(bundleID: "com.example.mosaic.A1B2C3D4E5", uuid: "U2", expires: day(1)))
		account.note(AppProfile(bundleID: "com.example.twelve.A1B2C3D4E5", uuid: "U3", expires: day(2)))
		XCTAssertEqual(account.profilesToRenew(now: start).map(\.uuid), ["U2", "U3"])
		XCTAssertEqual(account.profilesToRenew(now: day(-3)).map(\.uuid), [])
	}

	func testAnAppSignedWithTheCertificateBeforeRenewsAfterSigningInAgain() throws {
		var account = try account()
		// Signed before Apple revoked the certificate it had then.
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "U1", expires: day(5), certificateSerial: Fixture.otherSerial))
		account.note(AppProfile(bundleID: "com.example.mosaic.A1B2C3D4E5", uuid: "U2", expires: day(5), certificateSerial: Fixture.signingSerial))
		XCTAssertEqual(account.profilesToRenew(now: start).map(\.uuid), ["U1"])

		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "U3", expires: day(5), certificateSerial: Fixture.otherSerial, renewedAt: start))
		XCTAssertEqual(account.profilesToRenew(now: start).map(\.uuid), [], "its old certificate is still listed, so it renewed with a new profile")
	}

	func testTheCertificateAnAppWasSignedWith() throws {
		let account = try account()
		let noted = AppProfile(bundleID: "a", uuid: nil, expires: day(7), certificateSerial: Fixture.otherSerial)
		XCTAssertEqual(AppProfileRenewal.signingSerial(of: noted, account: account), Fixture.otherSerial, "as noted")

		let older = AppProfile(bundleID: "a", uuid: nil, expires: day(7))
		XCTAssertEqual(AppProfileRenewal.signingSerial(of: older, account: account), Fixture.signingSerial, "the Apple ID's, made before the profile")

		let beforeIt = AppProfile(bundleID: "a", uuid: nil, expires: Fixture.utc(2026, 10, 20))
		XCTAssertNil(AppProfileRenewal.signingSerial(of: beforeIt, account: account), "a profile from before the certificate was made")

		let renewed = AppProfile(bundleID: "a", uuid: nil, expires: day(7), renewedAt: start)
		XCTAssertNil(AppProfileRenewal.signingSerial(of: renewed, account: account), "a renewed one came long after the app was signed")
	}

	func testANewProfileListingTheAppsCertificateIsEnough() throws {
		let account = try account()
		let atlas = AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: day(2), certificateSerial: Fixture.signingSerial)
		let new = try profile(created: start, certificates: [other(), signing()])
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: account, new: new, now: start), .newProfile)

		let withoutIt = try profile(created: start, certificates: [other()])
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: account, new: withoutIt, now: start), .signAgain, "the app's certificate is gone")
	}

	func testAnAppleIDWhoseCertificateWasRevokedSignsInAgain() throws {
		let revoked = try account(revocation: .checked(.revoked(at: day(-1)), at: start))
		let atlas = AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: day(2), certificateSerial: Fixture.signingSerial)
		XCTAssertTrue(AppProfileRenewal.needsSignIn(revoked, now: start))
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: revoked, new: try profile(created: start, certificates: [signing()]), now: start), .signInAgain)

		let ended = try account()
		XCTAssertFalse(AppProfileRenewal.needsSignIn(ended, now: start))
		XCTAssertTrue(AppProfileRenewal.needsSignIn(ended, now: Fixture.utc(2036, 10, 16)), "its certificate ended")
	}

	func testWithoutTheSerialTheProfileOnTheIPhoneTells() throws {
		let account = try account()
		// Renewed by an Atelier that didn't note it, so the serial isn't known.
		let atlas = AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "old-uuid", expires: day(2), renewedAt: day(-5))
		let installed = [try profile(uuid: "OLD-UUID", created: day(-5), certificates: [signing()])]
		let new = try profile(created: start, certificates: [signing(), other()])
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: account, new: new, installed: installed, now: start), .newProfile)
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: account, new: try profile(created: start, certificates: [other()]), installed: installed, now: start), .signAgain)
		XCTAssertEqual(AppProfileRenewal.way(for: atlas, account: account, new: new, installed: [], now: start), .signAgain, "nothing tells, so it's signed again to be sure")
	}

	func testTheNewProfileTakesThePlaceOfTheOlderOnesForItsAppID() throws {
		let new = try profile(uuid: "NEW", created: start, certificates: [signing()])
		let installed = [
			try profile(uuid: "OLD", created: day(-5), certificates: [signing()]),
			try profile(uuid: "OLDER", created: day(-12), certificates: [signing()]),
			try profile(uuid: "NEW", created: start, certificates: [signing()]),
			try profile("A1B2C3D4E5.com.example.mosaic.A1B2C3D4E5", uuid: "MOSAIC", created: day(-5), certificates: [signing()]),
			try profile(uuid: "LATER", created: day(1), certificates: [signing()]),
		]
		XCTAssertEqual(AppProfileRenewal.replaced(by: new, among: installed), ["OLD", "OLDER"])
	}

	func testARenewedProfileKeepsTheCertificateTheAppWasSignedWith() throws {
		var account = try account()
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: day(2)))
		let renewed = account.renewed("com.example.atlas.A1B2C3D4E5", uuid: "NEW", expires: day(7), at: start)
		XCTAssertEqual(renewed, AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "NEW", expires: day(7), certificateSerial: Fixture.signingSerial, renewedAt: start))
	}

	func testAProfileThatEndsNoLaterWaitsForItsAppIDToEnd() throws {
		var account = try account()
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: day(2), certificateSerial: Fixture.signingSerial))
		// Should Apple end a profile with the App ID it's for.
		let same = account.renewed("com.example.atlas.A1B2C3D4E5", uuid: "NEW", expires: day(2), appIDEnds: day(2), at: start)
		XCTAssertEqual(same.waitsUntil, day(2))
		XCTAssertFalse(AppProfileRenewal.isDue(same, isFree: true, now: start), "not asked again and again")
		XCTAssertTrue(AppProfileRenewal.isDue(same, isFree: true, now: day(2)), "once its App ID ended")

		let longer = account.renewed("com.example.atlas.A1B2C3D4E5", uuid: "NEW", expires: day(7), appIDEnds: day(2), at: start)
		XCTAssertNil(longer.waitsUntil)
	}

	func testAProfileNotedBeforeRenewalStillReads() throws {
		let json = Data(#"{"bundleID":"com.example.atlas.A1B2C3D4E5","uuid":"OLD","expires":0}"#.utf8)
		let decoded = try JSONDecoder().decode(AppProfile.self, from: json)
		XCTAssertNil(decoded.certificateSerial)
		XCTAssertNil(decoded.renewedAt)
		XCTAssertNil(decoded.waitsUntil)
	}
}

/// The App Groups an app was signed with go on through its renewals (#49).
final class AppProfileGroupsTests: XCTestCase {
	private let groups = ["group.com.example.atlas.A1B2C3D4E5", "group.com.example.shared.A1B2C3D4E5"]

	func testARenewedProfileKeepsTheAppsGroups() throws {
		let start = Fixture.utc(2026, 11, 10, 18)
		var account = StoredAppleID(
			email: "sam@example.com",
			team: StoredAppleID.Team(id: "A1B2C3D4E5", name: "Sam Test", isFree: true),
			certificate: try SigningCertificate(der: ProvisioningProfile(data: Fixture.data("development.mobileprovision")).developerCertificates[0]),
			machineName: "Atelier"
		)
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: start, appGroups: groups))
		let renewed = account.renewed("com.example.atlas.A1B2C3D4E5", uuid: "NEW", expires: start.addingTimeInterval(7 * 86_400), at: start)
		XCTAssertEqual(renewed.appGroups, groups)
	}

	func testANewProfileHasToAllowTheGroupsTheAppWasSignedWith() {
		let atlas = AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "OLD", expires: .now, appGroups: groups)
		let both: [String: Any] = ["com.apple.security.application-groups": groups.reversed().map { $0.lowercased() }]
		XCTAssertEqual(AppProfileRenewal.missingGroups(of: atlas, allowedBy: both), [])
		let one: [String: Any] = ["com.apple.security.application-groups": [groups[0]]]
		XCTAssertEqual(AppProfileRenewal.missingGroups(of: atlas, allowedBy: one), [groups[1]])
		// As from an App ID Apple added again, which has no groups yet.
		XCTAssertEqual(AppProfileRenewal.missingGroups(of: atlas, allowedBy: ["get-task-allow": true]), groups)
		// An app signed without any.
		let plain = AppProfile(bundleID: "com.example.mosaic.A1B2C3D4E5", uuid: "OLD", expires: .now)
		XCTAssertEqual(AppProfileRenewal.missingGroups(of: plain, allowedBy: [:]), [])
	}

	func testAProfileNotedBeforeGroupsStillReads() throws {
		let json = Data(#"{"bundleID":"com.example.atlas.A1B2C3D4E5","uuid":"OLD","expires":0}"#.utf8)
		XCTAssertNil(try JSONDecoder().decode(AppProfile.self, from: json).appGroups)
	}
}
