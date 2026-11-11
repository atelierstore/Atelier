import Foundation
import InstallKit
import XCTest
@testable import CertKit

/// The check before an install (#99): which certificate signs an app over
/// the one on this iPhone, and what's said when none can. The apps are as
/// iOS 27 gave them in #99's test.
final class InstalledAppSigningTests: XCTestCase {
	private let now = Fixture.utc(2026, 11, 1)
	private let devAppID = "S7GNTEAM42.app.otter4812.mango3307"
	private let distributionAppID = "S7GNTEAM42.app.heron2265.lime9140"

	/// The fixture pair, named and with a profile for `appID`. It expires
	/// on 1 January 2027.
	private func certificate(_ name: String, appID: String) throws -> StoredCertificate {
		var stored = try Fixture.stored("enterprise.mobileprovision")
		stored.customName = name
		stored.profile.applicationIdentifier = appID
		return stored
	}

	private func app(_ bundleID: String, name: String, signer: String?, appID: String?, appleAccount: Bool = false) -> InstalledAppRecord {
		InstalledAppRecord(bundleID: bundleID, name: name, signer: signer, applicationIdentifier: appID, hasAppleAccount: appleAccount)
	}

	private func decide(_ installed: InstalledAppRecord, appName: String? = nil, with certificate: StoredCertificate, among certificates: [StoredCertificate], picked: Bool = false) -> InstalledAppSigning {
		InstalledAppSigning.decide(installed: installed, appName: appName ?? installed.name, certificate: certificate, certificates: certificates, picked: picked, now: now)
	}

	private struct NotAConflict: Error {
		let result: InstalledAppSigning
	}

	private func conflict(_ result: InstalledAppSigning) throws -> InstalledConflict {
		guard case .conflict(let conflict) = result else { throw NotAConflict(result: result) }
		return conflict
	}

	func testGoesAheadWithTheSameAppID() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let beacon = app("com.Beacon.BeaconStore-iOS", name: "BeaconStore", signer: "Apple Distribution: Sample Signing Ltd (S7GNTEAM42)", appID: distributionAppID)
		XCTAssertEqual(decide(beacon, with: signulous, among: [signulous]), .proceed)
	}

	func testGoesAheadWhenTheRecordGivesNoAppID() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let bare = app("com.example.bare", name: "Bare", signer: nil, appID: nil)
		XCTAssertEqual(decide(bare, with: signulous, among: [signulous]), .proceed)
	}

	func testSignsWithTheCertificateTheAppWasInstalledWith() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let feather = try certificate("Feather cert", appID: devAppID)
		let nimbus = app("com.nimbus.app", name: "Nimbus", signer: "iPhone Developer: Created via API (D3VCERT0A1)", appID: devAppID)
		XCTAssertEqual(decide(nimbus, with: signulous, among: [signulous, feather]), .switchTo(feather))
	}

	func testSignsWithTheFirstUsableCertificateForThatAppID() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		var expired = try certificate("Old Feather cert", appID: devAppID)
		expired.profile.expirationDate = Fixture.utc(2026, 10, 1)
		var revoked = try certificate("Revoked Feather cert", appID: devAppID)
		revoked.revocation = .checked(.revoked(at: Fixture.utc(2026, 10, 2)), at: Fixture.utc(2026, 10, 3))
		let feather = try certificate("Feather cert", appID: devAppID)
		let other = try certificate("Another Feather cert", appID: devAppID)
		let nimbus = app("com.nimbus.app", name: "Nimbus", signer: "iPhone Developer: Created via API (D3VCERT0A1)", appID: devAppID)
		XCTAssertEqual(decide(nimbus, with: signulous, among: [signulous, expired, revoked, feather, other]), .switchTo(feather))
	}

	func testAppStoreAppsCantBeReplaced() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let youTube = app("com.google.ios.youtube", name: "YouTube", signer: InstalledAppRecord.appleSigner, appID: "EQHXZ8M8AV.com.google.ios.youtube", appleAccount: true)
		let found = try conflict(decide(youTube, appName: "YTLite", with: signulous, among: [signulous]))
		XCTAssertEqual(found, InstalledConflict(installedName: "YouTube", appName: "YTLite", bundleID: "com.google.ios.youtube", signer: .appStore, keepsData: false))
		XCTAssertFalse(found.canImport)
		XCTAssertEqual(found.title, "YouTube is already on this \(ThisDevice.name)")
		XCTAssertEqual(found.question, "It's from the App Store, so Atelier can't install over it. Install a second YTLite next to it, or delete it first, which erases its data.")
		XCTAssertEqual(found.failure, "YTLite wasn't installed: the YouTube on this \(ThisDevice.name) is from the App Store.")
		XCTAssertEqual(found.deleteTitle, "Delete YouTube and Install")
		XCTAssertEqual(found.dataNote, "Delete YouTube and Install deletes its data.")
	}

	func testMarketplaceAppsCantBeReplaced() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let stremio = app("com.stremio.pal", name: "Stremio", signer: InstalledAppRecord.appleSigner, appID: "9EWRZ4QP3J.com.stremio.pal")
		let found = try conflict(decide(stremio, with: signulous, among: [signulous]))
		XCTAssertEqual(found.signer, .marketplace)
		XCTAssertFalse(found.keepsData)
		XCTAssertEqual(found.question, "It's from an alternative app marketplace, so Atelier can't install over it. Install a second Stremio next to it, or delete it first, which erases its data.")
		XCTAssertEqual(found.failure, "Stremio wasn't installed: the one on this \(ThisDevice.name) is from an alternative app marketplace.")
	}

	func testTestFlightAppsKeepTheirData() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let tidepool = InstalledAppRecord(bundleID: "com.tidepool.app", name: "Tidepool", signer: InstalledAppRecord.testFlightSigner, profileValidated: true, applicationIdentifier: "K7X2M9Q4PL.com.tidepool.app", betaReports: true, hasAppleAccount: true)
		let found = try conflict(decide(tidepool, with: signulous, among: [signulous]))
		XCTAssertEqual(found.signer, .testFlight)
		XCTAssertTrue(found.keepsData)
		XCTAssertEqual(found.question, "It's from TestFlight, so Atelier can't install over it. Install a second Tidepool next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(found.failure, "Tidepool wasn't installed: the one on this \(ThisDevice.name) is from TestFlight.")
		XCTAssertEqual(found.dataNote, "Delete Tidepool and Install keeps its data. You may need to sign in to it again.")
	}

	func testNamesACertificateThatIsntInAtelier() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let radiance = app("com.radiance.app", name: "Radiance", signer: "Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)", appID: "K7X2M9Q4PL.com.radiance.app")
		let found = try conflict(decide(radiance, with: signulous, among: [signulous]))
		XCTAssertEqual(found.signer, .certificate("Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)"))
		XCTAssertTrue(found.canImport)
		XCTAssertTrue(found.keepsData)
		XCTAssertEqual(found.question, "It was installed with “Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)”, a certificate Atelier doesn't have, so Atelier can't install over it. Import that certificate, install a second Radiance next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(found.failure, "Radiance wasn't installed: the one on this \(ThisDevice.name) was installed with “Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)”, a certificate Atelier doesn't have.")
		XCTAssertEqual(found.dataNote, "Delete Radiance and Install keeps its data. You may need to sign in to it again.")
	}

	func testSaysWhenItsCertificateExpiredOrWasRevoked() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		var feather = try certificate("Feather cert", appID: devAppID)
		feather.profile.expirationDate = Fixture.utc(2026, 10, 2, 12)
		let nimbus = app("com.nimbus.app", name: "Nimbus", signer: "iPhone Developer: Created via API (D3VCERT0A1)", appID: devAppID)
		let expired = try conflict(decide(nimbus, with: signulous, among: [signulous, feather]))
		XCTAssertEqual(expired.signer, .expired("Feather cert", on: feather.expiresAt))
		XCTAssertTrue(expired.canImport)
		let day = feather.expiresAt.formatted(date: .long, time: .omitted)
		XCTAssertEqual(expired.question, "It was installed with Feather cert, which expired on \(day), so Atelier can't install over it. Import a new certificate for it, install a second Nimbus next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(expired.failure, "Nimbus wasn't installed: the one on this \(ThisDevice.name) was installed with Feather cert, which expired on \(day).")

		feather.revocation = .checked(.revoked(at: Fixture.utc(2026, 9, 1)), at: Fixture.utc(2026, 9, 2))
		let revoked = try conflict(decide(nimbus, with: signulous, among: [signulous, feather]))
		XCTAssertEqual(revoked.signer, .revoked("Feather cert"), "revoked comes before expired")
		XCTAssertEqual(revoked.question, "It was installed with Feather cert, which Apple revoked, so Atelier can't install over it. Import a new certificate for it, install a second Nimbus next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(revoked.failure, "Nimbus wasn't installed: the one on this \(ThisDevice.name) was installed with Feather cert, which Apple revoked.")
	}

	func testKeepsTheCertificateTheUserPicked() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let feather = try certificate("Feather cert", appID: devAppID)
		let nimbus = app("com.nimbus.app", name: "Nimbus", signer: "iPhone Developer: Created via API (D3VCERT0A1)", appID: devAppID)
		let found = try conflict(decide(nimbus, with: signulous, among: [feather, signulous], picked: true))
		XCTAssertEqual(found.signer, .notPicked("Feather cert", picked: "Signulous Distribution"))
		XCTAssertFalse(found.canImport)
		XCTAssertEqual(found.question, "It was installed with Feather cert, so Atelier can't install over it with Signulous Distribution. Install a second Nimbus next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(found.failure, "Nimbus wasn't installed: the one on this \(ThisDevice.name) was installed with Feather cert, not Signulous Distribution.")
	}

	func testARecordWithoutASigner() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let unsigned = app("com.example.app", name: "Example", signer: nil, appID: "ABCDE12345.com.example.app")
		let found = try conflict(decide(unsigned, with: signulous, among: [signulous]))
		XCTAssertEqual(found.signer, .unknown)
		XCTAssertEqual(found.question, "It was installed with a different certificate, so Atelier can't install over it. Install a second Example next to it, or delete it and install this one in its place, keeping its data (you may need to sign in again).")
		XCTAssertEqual(found.failure, "Example wasn't installed: the one on this \(ThisDevice.name) was installed with a different certificate.")
	}

	/// Your test's case: EeveeSpotify over Spotify from the App Store.
	func testNamesBothAppsWhenTheyDiffer() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let spotify = app("com.spotify.client", name: "Spotify", signer: InstalledAppRecord.appleSigner, appID: "2FNC3A47ZF.com.spotify.client", appleAccount: true)
		let store = try conflict(decide(spotify, appName: "EeveeSpotify", with: signulous, among: [signulous]))
		XCTAssertEqual(store.question, "It's from the App Store, so Atelier can't install over it. Install a second EeveeSpotify next to it, or delete it first, which erases its data.")

		let beta = InstalledAppRecord(bundleID: "com.spotify.client", name: "Spotify", signer: InstalledAppRecord.testFlightSigner, applicationIdentifier: "2FNC3A47ZF.com.spotify.client")
		let testFlight = try conflict(decide(beta, appName: "EeveeSpotify", with: signulous, among: [signulous]))
		XCTAssertEqual(testFlight.question, "It's from TestFlight, so Atelier can't install over it. Install a second EeveeSpotify next to it, or delete it and install EeveeSpotify in its place, keeping its data (you may need to sign in again).")
	}

	/// Your test's case: AltStore Classic, offloaded, which installd lists
	/// nowhere; only iOS's refusal named its App ID. Nothing says why iOS
	/// doesn't list it, so the details name no cause.
	func testAnAppOnlyTheRefusalNames() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let found = try conflict(InstalledAppSigning.decideUnlisted(
			appID: "6XVY5G3U44.com.rileytestut.AltStore",
			bundleID: "com.rileytestut.AltStore",
			installedName: "AltStore",
			appName: "AltStore Classic",
			certificate: signulous,
			certificates: [signulous],
			now: now
		))
		XCTAssertEqual(found.signer, .unlisted)
		XCTAssertEqual(found.installedName, "AltStore")
		XCTAssertEqual(found.bundleID, "com.rileytestut.AltStore")
		XCTAssertFalse(found.canImport)
		XCTAssertFalse(found.keepsData, "with no record of the app, Atelier can't tell whether it could copy its data")
		XCTAssertEqual(found.failure, "AltStore Classic wasn't installed: the AltStore on this \(ThisDevice.name) is hidden from Atelier, maybe offloaded, and was installed with a different certificate.")
		XCTAssertEqual(found.deleteTitle, "Delete AltStore and Install")
		XCTAssertEqual(found.dataNote, "iOS doesn't show this AltStore to Atelier. Delete AltStore and Install deletes it and its data.")
		XCTAssertEqual(found.question, "It's hidden from Atelier, maybe offloaded, and was installed with a different certificate, so Atelier can't install over it. Install a second AltStore Classic next to it, or delete it first, which erases its data.")
	}

	func testAnAppOnlyTheRefusalNamesForOneOfYourCertificates() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		var feather = try certificate("Feather cert", appID: devAppID)
		let decide = { InstalledAppSigning.decideUnlisted(appID: self.devAppID, bundleID: "com.nimbus.app", installedName: "", appName: "Nimbus", certificate: signulous, certificates: [signulous, feather], now: self.now) }
		XCTAssertEqual(decide(), .switchTo(feather), "Install with Another Certificate offers it")
		feather.profile.expirationDate = Fixture.utc(2026, 10, 2, 12)
		let expired = try conflict(decide())
		XCTAssertEqual(expired.signer, .unlisted, "a certificate that expired can't sign it")
		XCTAssertEqual(expired.installedName, "Nimbus", "the app's own name when there's none to give")
		XCTAssertEqual(InstalledAppSigning.decideUnlisted(appID: distributionAppID, bundleID: "com.nimbus.app", installedName: "Nimbus", appName: "Nimbus", certificate: signulous, certificates: [signulous], now: now), .proceed)
	}

	func testShowsTheInstalledNameOnOneLine() throws {
		let signulous = try certificate("Signulous Distribution", appID: distributionAppID)
		let shirabe = app("jp.shirabe", name: "Shirabe Jisho\nJapanese", signer: InstalledAppRecord.appleSigner, appID: "ABCDE12345.jp.shirabe", appleAccount: true)
		XCTAssertEqual(try conflict(decide(shirabe, appName: "Shirabe", with: signulous, among: [signulous])).installedName, "Shirabe Jisho Japanese")
		let nameless = app("jp.shirabe", name: "\u{200E}", signer: InstalledAppRecord.appleSigner, appID: "ABCDE12345.jp.shirabe", appleAccount: true)
		XCTAssertEqual(try conflict(decide(nameless, appName: "Shirabe", with: signulous, among: [signulous])).installedName, "Shirabe", "the app's own name when iOS gives none")
	}
}
