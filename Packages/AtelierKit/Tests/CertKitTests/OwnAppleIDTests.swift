import Foundation
import XCTest
@testable import CertKit

/// Atelier itself as one of an Apple ID's apps (#152).
final class OwnAppleIDTests: XCTestCase {
	private let start = Fixture.utc(2026, 11, 11, 10, 42)
	private let team = "A1B2C3D4E5"
	private let bundleID = "com.atelier.app.A1B2C3D4E5"
	private var appID: String { "\(team).\(bundleID)" }

	private func signing() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("development.mobileprovision")).developerCertificates[0]
	}

	private func other() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("mismatched.mobileprovision")).developerCertificates[0]
	}

	private func account(team: String? = nil, email: String = "name@example.com", free: Bool = true, revocation: RevocationState? = nil) throws -> StoredAppleID {
		StoredAppleID(
			addedAt: start,
			email: email,
			team: StoredAppleID.Team(id: team ?? self.team, name: "Example Team", isFree: free),
			certificate: try SigningCertificate(der: signing()),
			machineName: "Atelier",
			revocation: revocation
		)
	}

	private func profile(_ appID: String? = nil, team: String? = nil, uuid: String = "BUILD", created: Date? = nil, days: Double = 7, certificates: [Data]? = nil, devices: [String] = ["00008110-0001"], debug: Bool = true) throws -> ProvisioningProfile {
		let created = created ?? start
		return try ProvisioningProfile(plist: [
			"Name": "iOS Team Provisioning Profile",
			"UUID": uuid,
			"TeamIdentifier": [team ?? self.team],
			"CreationDate": created,
			"ExpirationDate": created.addingTimeInterval(days * 86_400),
			"DeveloperCertificates": try certificates ?? [other()],
			"ProvisionedDevices": devices,
			"Entitlements": ["application-identifier": appID ?? self.appID, "get-task-allow": debug],
		])
	}

	private func day(_ days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

	// MARK: Whose app it is

	func testAtelierIsAnAppOfTheAppleIDWhoseTeamHasItsAppID() throws {
		let owner = try account()
		let found = OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(), accounts: [owner])
		XCTAssertEqual(found, .appleID(owner.id), "whichever tool installed it, and whichever certificate signed it")
	}

	func testAFreeAppleIDThatIsntSignedInIsAskedFor() throws {
		let free = try profile()
		XCTAssertEqual(
			OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: free, accounts: []),
			.freeAppleID(teamID: team, expires: day(7))
		)
		let another = try account(team: "Z9Y8X7W6V5", email: "other@example.com")
		XCTAssertEqual(
			OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: free, accounts: [another]),
			.freeAppleID(teamID: team, expires: day(7)),
			"another Apple ID's team can't renew it"
		)
	}

	func testAtelierSignedAnyOtherWayIsNobodysApp() throws {
		let owner = try account(free: false)
		// A paid team's development profile, with nobody signed in: an
		// imported certificate's, as before.
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(days: 365), accounts: []), .other)
		// An ad hoc or an enterprise profile isn't an Apple ID's, even with
		// its team signed in.
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(days: 365, debug: false), accounts: [owner]), .other)
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: nil, accounts: [owner]), .other, "no profile to read")
		// Signed for another App ID than the team's for the bundle ID it runs
		// as, such as a wildcard's: Apple would give a profile for another.
		XCTAssertEqual(
			OwnAppleID.installed(applicationIdentifier: "\(team).com.atelier.app", bundleID: bundleID, profile: try profile(days: 365), accounts: [owner]),
			.other
		)
	}

	func testAPaidAppleIDsAppToo() throws {
		let owner = try account(free: false)
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(days: 365), accounts: [owner]), .appleID(owner.id))
	}

	func testTheAppIDIsTheProfilesWhenTheEntitlementsCantBeRead() throws {
		let owner = try account()
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: nil, bundleID: bundleID, profile: try profile(), accounts: [owner]), .appleID(owner.id))
	}

	func testOfTwoInTheSameTeamTheOneThatStillSigns() throws {
		let revoked = try account(email: "old@example.com", revocation: RevocationState(status: .revoked(at: nil), checkedAt: start, attemptedAt: start))
		let owner = try account()
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(), accounts: [revoked, owner]), .appleID(owner.id))
		XCTAssertEqual(OwnAppleID.installed(applicationIdentifier: appID, bundleID: bundleID, profile: try profile(), accounts: [revoked]), .appleID(revoked.id), "which has to sign in again")
	}

	// MARK: Its profile

	func testTheBuildsProfileIsNotedWithTheCertificateThatSignedIt() throws {
		let noted = OwnAppleID.profile(bundleID: bundleID, installed: try profile(), signerSerial: Fixture.otherSerial, appGroups: ["group.com.SideStore.SideStore.A1B2C3D4E5"], noted: nil)
		XCTAssertEqual(noted, AppProfile(bundleID: bundleID, uuid: "BUILD", expires: day(7), certificateSerial: Fixture.otherSerial, appGroups: ["group.com.SideStore.SideStore.A1B2C3D4E5"]))
	}

	func testARenewedProfileStandsOverTheBuilds() throws {
		// Atelier put a new profile on four days in, without reinstalling.
		let renewed = AppProfile(bundleID: bundleID, uuid: "RENEWED", expires: day(11), certificateSerial: Fixture.otherSerial, renewedAt: day(4))
		let kept = OwnAppleID.profile(bundleID: bundleID, installed: try profile(), signerSerial: Fixture.otherSerial, noted: renewed)
		XCTAssertEqual(kept, renewed, "the build still carries the one it was installed with")
	}

	func testAnUpdateStartsOverFromItsOwnProfile() throws {
		// Renewed, then updated: signed again with the Apple ID's own
		// certificate, and a profile that ends later.
		let renewed = AppProfile(bundleID: bundleID, uuid: "RENEWED", expires: day(11), certificateSerial: Fixture.otherSerial, renewedAt: day(4))
		let updated = try profile(uuid: "UPDATE", created: day(5))
		let noted = OwnAppleID.profile(bundleID: bundleID, installed: updated, signerSerial: Fixture.signingSerial, noted: renewed)
		XCTAssertEqual(noted, AppProfile(bundleID: bundleID, uuid: "UPDATE", expires: day(12), certificateSerial: Fixture.signingSerial))
	}

	func testTheSameProfileKeepsWhatWasNoted() throws {
		var waiting = AppProfile(bundleID: bundleID, uuid: "build", expires: day(7), certificateSerial: nil, waitsUntil: day(6))
		let kept = OwnAppleID.profile(bundleID: bundleID, installed: try profile(), signerSerial: Fixture.otherSerial, noted: waiting)
		waiting.certificateSerial = Fixture.otherSerial
		XCTAssertEqual(kept, waiting, "with the certificate the build says")
		// A signature that can't be read keeps the serial noted.
		XCTAssertEqual(OwnAppleID.profile(bundleID: bundleID, installed: try profile(), signerSerial: nil, noted: waiting), waiting)
	}

	func testAProfileAnotherToolPutOnIsFoundOnTheIPhone() throws {
		let noted = AppProfile(bundleID: bundleID, uuid: "BUILD", expires: day(7), certificateSerial: Fixture.otherSerial, waitsUntil: day(6))
		let onIPhone = [
			try profile(uuid: "BUILD"),
			try profile(uuid: "REFRESHED", created: day(3)),
			try profile("\(team).com.example.atlas.\(team)", uuid: "ATLAS", created: day(6)),
		]
		let later = try XCTUnwrap(OwnAppleID.later(than: noted, applicationIdentifier: appID, among: onIPhone))
		XCTAssertEqual(later, AppProfile(bundleID: bundleID, uuid: "REFRESHED", expires: day(10), certificateSerial: Fixture.otherSerial))
		XCTAssertNil(OwnAppleID.later(than: later, applicationIdentifier: appID, among: onIPhone), "nothing later than what's noted")
	}

	// MARK: Renewing itself first

	func testAtelierRenewsItselfFourDaysAhead() {
		let own = AppProfile(bundleID: bundleID, uuid: "BUILD", expires: day(7))
		XCTAssertEqual(AppProfileRenewal.date(toRenew: own, isFree: true, isOwn: true), day(3))
		XCTAssertFalse(AppProfileRenewal.isDue(own, isFree: true, isOwn: true, now: day(2.9)))
		XCTAssertTrue(AppProfileRenewal.isDue(own, isFree: true, isOwn: true, now: day(3)))
		XCTAssertFalse(AppProfileRenewal.isDue(own, isFree: true, now: day(3)), "another app, two days ahead")
		let paid = AppProfile(bundleID: bundleID, uuid: "PAID", expires: day(365))
		XCTAssertEqual(AppProfileRenewal.date(toRenew: paid, isFree: false, isOwn: true), day(351), "a paid team's as its other apps")
	}

	func testAtelierComesFirstAmongTheAppsDue() throws {
		var account = try account()
		let serial = account.certificate.serialNumber
		account.note(AppProfile(bundleID: "com.example.atlas.A1B2C3D4E5", uuid: "U1", expires: day(4), certificateSerial: serial))
		account.note(AppProfile(bundleID: bundleID, uuid: "OWN", expires: day(6), certificateSerial: serial))
		account.note(AppProfile(bundleID: "com.example.mosaic.A1B2C3D4E5", uuid: "U2", expires: day(9), certificateSerial: serial))
		XCTAssertEqual(account.profilesToRenew(own: bundleID, now: day(2.5)).map(\.uuid), ["OWN", "U1"], "though Atlas's ends sooner")
		XCTAssertEqual(account.profilesToRenew(own: bundleID, now: day(1.5)).map(\.uuid), [])
		XCTAssertEqual(account.profilesToRenew(now: day(2.5)).map(\.uuid), ["U1"], "without knowing which is Atelier")
	}

	func testSignedWithTheInstallersCertificateItRenewsRightAfterTheSignIn() throws {
		var account = try account()
		account.note(AppProfile(bundleID: bundleID, uuid: "BUILD", expires: day(7), certificateSerial: Fixture.otherSerial))
		XCTAssertEqual(account.profilesToRenew(own: bundleID, now: start).map(\.uuid), ["BUILD"], "to find out whether a new profile lists that certificate")

		// Apple's new profile lists both, so it's put on.
		let new = try profile(uuid: "NEW", created: start, certificates: [signing(), other()])
		let own = try XCTUnwrap(account.profile(for: bundleID))
		XCTAssertEqual(AppProfileRenewal.way(for: own, account: account, new: new, now: start), .newProfile)
		// The certificate's own clock starts in October, so a renewal now
		// came after it.
		account.note(account.renewed(bundleID, uuid: "NEW", expires: day(7.01), at: start.addingTimeInterval(60)))
		XCTAssertEqual(account.profilesToRenew(own: bundleID, now: day(1)).map(\.uuid), [])
		XCTAssertEqual(account.profile(for: bundleID)?.certificateSerial, Fixture.otherSerial, "still signed with the installer's")
	}

	func testWithoutTheInstallersCertificateItHasToBeSignedAgain() throws {
		var account = try account()
		account.note(AppProfile(bundleID: bundleID, uuid: "BUILD", expires: day(7), certificateSerial: Fixture.otherSerial))
		let new = try profile(uuid: "NEW", created: start, certificates: [signing()])
		let own = try XCTUnwrap(account.profile(for: bundleID))
		XCTAssertEqual(AppProfileRenewal.way(for: own, account: account, new: new, now: start), .signAgain)
	}

	// MARK: Its App ID, before an update

	func testAnUpdateUsesItsAppIDAgainWhileTheTeamHasIt() throws {
		var account = try account()
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: start), .unknown, "before Apple was asked")

		let entries = [
			AppleIDAppIDList.Entry(identifier: bundleID.uppercased(), name: "Atelier", expires: day(3)),
			AppleIDAppIDList.Entry(identifier: "com.example.atlas.A1B2C3D4E5", name: "Atlas", expires: day(5)),
		]
		account.limits = AppleIDLimits(appIDs: AppleIDLimits.AppIDs(checkedAt: start, max: 10, available: 8, expiries: entries.compactMap(\.expires), entries: entries))
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: day(1)), .again)
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: day(4)), .new(left: 9), "it ended, and came back")

		account.limits?.appIDs?.available = 0
		account.limits?.appIDs?.expiries = [day(3), day(5), day(6)]
		account.limits?.appIDs?.max = 1
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: day(2)), .again)
		account.limits?.appIDs?.entries = [entries[1]]
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: day(2)), .noneLeft(nextReturn: day(3)))
	}

	func testAPaidTeamsAppIDsArentCounted() throws {
		var account = try account(free: false)
		account.limits = AppleIDLimits(appIDs: AppleIDLimits.AppIDs(checkedAt: start, max: nil, available: nil, expiries: [], entries: []))
		XCTAssertEqual(OwnAppleID.appIDUse(for: bundleID, account: account, now: start), .unknown)
	}

	// MARK: The certificate that signed it

	func testTheSignerIsTheCertificateTheProfileLists() throws {
		// A profile's own envelope is a CMS signature like a binary's, with
		// the certificate that signed it inside.
		let cms = try Fixture.data("development.mobileprovision")
		let all = CodeSigner.certificates(inCMS: cms)
		XCTAssertFalse(all.isEmpty)
		let lists = try profile(certificates: [all[0].der])
		XCTAssertEqual(CodeSigner.signer(inCMS: cms, profile: lists)?.serialNumber, all[0].serialNumber)
		XCTAssertNil(CodeSigner.signer(inCMS: cms, profile: try profile(team: "NOBODY0000", certificates: [other()])), "none the profile is for")
		XCTAssertEqual(CodeSigner.certificates(inCMS: Data([0x30, 0x03, 0x02, 0x01, 0x01])), [], "not a signature")
	}
}
