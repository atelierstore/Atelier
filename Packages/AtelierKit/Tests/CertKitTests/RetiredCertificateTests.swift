import Foundation
import XCTest
@testable import CertKit

/// A deleted certificate imported again (#126): what's noted when it's
/// deleted, and how the import is told to be the same pair.
final class RetiredCertificateTests: XCTestCase {
	/// signing.p12's certificate with `profile`, or with
	/// mismatched.mobileprovision, the other certificate. All the fixture
	/// profiles run out on 1 Jan 2027, before the certificates.
	func pair(_ profile: String = "adhoc.mobileprovision", addedAt: Date = Fixture.utc(2026, 10, 20), name: String? = nil) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file(profile))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: profile))
		var stored = StoredCertificate(id: UUID(), addedAt: addedAt, certificate: validated.certificate, profile: validated.profile)
		stored.customName = name
		return stored
	}

	/// As Atelier noted a deleted certificate before #126.
	func noted(beforeTheFix certificate: StoredCertificate) -> RetiredCertificate {
		var retired = RetiredCertificate(certificate)
		retired.certificateFingerprint = nil
		retired.profileUUID = nil
		retired.deviceConfirmedAt = nil
		return retired
	}

	let installed = Fixture.utc(2026, 10, 15)

	func testNotesWhichPairItWas() throws {
		var adHoc = try pair(name: "Work")
		adHoc.deviceConfirmedAt = Fixture.utc(2026, 10, 18)
		let retired = RetiredCertificate(adHoc)
		XCTAssertEqual(retired.name, "Work")
		XCTAssertEqual(retired.expiresAt, Fixture.utc(2027, 1, 1))
		XCTAssertFalse(retired.revoked)
		XCTAssertEqual(retired.certificateFingerprint, Fixture.signingFingerprint)
		XCTAssertEqual(retired.profileUUID, adHoc.profile.uuid)
		XCTAssertEqual(retired.deviceConfirmedAt, Fixture.utc(2026, 10, 18))

		XCTAssertTrue(retired.isPair(adHoc.certificate, adHoc.profile))
		let development = try pair("development.mobileprovision")
		XCTAssertFalse(retired.isPair(development.certificate, development.profile), "the certificate with another profile")
		let other = try pair("mismatched.mobileprovision")
		XCTAssertFalse(retired.isPair(other.certificate, adHoc.profile), "another certificate with the profile")
		XCTAssertFalse(noted(beforeTheFix: adHoc).isPair(adHoc.certificate, adHoc.profile), "not noted before #126")
	}

	func testReadsWhatEarlierBuildsSaved() throws {
		// CertificatesModel's list, as builds before #126 saved it.
		let saved = #"{"name":"Signulous","expiresAt":820454400,"revoked":true}"#
		let old = try JSONDecoder().decode(RetiredCertificate.self, from: Data(saved.utf8))
		XCTAssertEqual(old.name, "Signulous")
		XCTAssertEqual(old.expiresAt, Date(timeIntervalSinceReferenceDate: 820_454_400))
		XCTAssertTrue(old.revoked)
		XCTAssertNil(old.certificateFingerprint)
		XCTAssertNil(old.profileUUID)
		XCTAssertNil(old.deviceConfirmedAt)

		var confirmed = try pair()
		confirmed.deviceConfirmedAt = Fixture.utc(2026, 10, 18)
		let new = RetiredCertificate(confirmed)
		XCTAssertEqual(try JSONDecoder().decode(RetiredCertificate.self, from: JSONEncoder().encode(new)), new)
	}

	func testFindsTheSamePairImportedAgain() throws {
		let adHoc = try pair()
		let retired = RetiredCertificate(adHoc)
		let development = try pair("development.mobileprovision")
		// Imported again before the app's install date, and signing for
		// another App ID: neither matters once the pair is known.
		let again = try pair(addedAt: Fixture.utc(2026, 10, 1))
		XCTAssertEqual(retired.reimported(among: [development, again], signedFor: "OTHERTEAM2.*", at: installed)?.id, again.id)
		XCTAssertNil(retired.reimported(among: [development], signedFor: "TESTTEAM01.*", at: installed), "only that pair")
	}

	func testTellsOneDeletedBeforeItsPairWasNoted() throws {
		let old = noted(beforeTheFix: try pair())
		let adHoc = try pair()
		let development = try pair("development.mobileprovision")
		let enterprise = try pair("enterprise.mobileprovision")

		XCTAssertEqual(old.reimported(among: [development, adHoc], signedFor: "TESTTEAM01.com.example.app", at: installed)?.id, adHoc.id, "the one for the app's App ID")
		XCTAssertEqual(old.reimported(among: [adHoc], signedFor: nil, at: installed)?.id, adHoc.id, "by expiry alone when the App ID wasn't noted")
		XCTAssertNil(old.reimported(among: [development, enterprise], signedFor: "TESTTEAM01.*", at: installed), "two for the App ID, both with its name")
		let other = try pair("mismatched.mobileprovision")
		XCTAssertEqual(old.reimported(among: [other, development], signedFor: "TESTTEAM01.*", at: installed)?.id, development.id, "of two, the one with its name")
		let renamed = try pair("enterprise.mobileprovision", name: "Work")
		XCTAssertEqual(old.reimported(among: [development, renamed], signedFor: "TESTTEAM01.*", at: installed)?.id, development.id, "of two, the one shown with its name")
		XCTAssertEqual(old.reimported(among: [other, renamed], signedFor: "TESTTEAM01.*", at: installed)?.id, renamed.id, "else the one whose certificate has its name")

		// The name it had in Atelier, not the certificate's own.
		var named = old
		named.name = "Signulous"
		XCTAssertEqual(named.reimported(among: [adHoc], signedFor: "TESTTEAM01.com.example.app", at: installed)?.id, adHoc.id, "the only one, whatever it's named now")
		let signulous = try pair("development.mobileprovision", name: "Signulous")
		XCTAssertEqual(named.reimported(among: [enterprise, signulous], signedFor: "TESTTEAM01.*", at: installed)?.id, signulous.id)

		let before = try pair(addedAt: Fixture.utc(2026, 10, 10))
		XCTAssertNil(old.reimported(among: [before], signedFor: nil, at: installed), "imported before the app was installed, so not imported again since")
		XCTAssertNil(old.reimported(among: [adHoc], signedFor: "TESTTEAM01.*", at: installed), "for another App ID")
		var later = old
		later.expiresAt = Fixture.utc(2027, 1, 1, 0, 0, 1)
		XCTAssertNil(later.reimported(among: [adHoc], signedFor: nil, at: installed), "running out at another second")
	}
}
