import Foundation
import XCTest
@testable import CertKit

/// Atelier signs itself only for the App ID it was installed with (#24).
final class OwnAppSigningTests: XCTestCase {
	/// The fixtures' adhoc profile is for TESTTEAM01.com.example.app; the
	/// development and mismatched ones are for TESTTEAM01.*, and mismatched
	/// lists another certificate.
	private func stored(_ profile: String) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file(profile == "mismatched.mobileprovision" ? "other.p12" : "signing.p12"), profile: try Fixture.file(profile))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: profile))
		return StoredCertificate(id: UUID(), addedAt: .now, certificate: validated.certificate, profile: validated.profile)
	}

	private func profile(_ name: String) throws -> ProvisioningProfile {
		try ProvisioningProfile(data: Fixture.data(name))
	}

	private let ownAppID = "TESTTEAM01.com.example.app"
	private let beforeExpiry = Fixture.utc(2026, 11, 1)

	func testPrefersACertificateWhoseProfileIsForItsAppID() throws {
		let development = try stored("development.mobileprovision")
		let adHoc = try stored("adhoc.mobileprovision")
		let choice = OwnAppSigning.choose(from: [development, adHoc], applicationIdentifier: ownAppID, installedProfile: try profile("adhoc.mobileprovision"), now: beforeExpiry) { _ in true }
		XCTAssertEqual(choice, OwnAppSigning.Choice(certificateID: adHoc.id, usesInstalledProfile: false), "the default comes first, but is for another App ID")
	}

	func testElseSignsWithTheProfileItWasInstalledWith() throws {
		let development = try stored("development.mobileprovision")
		let mismatched = try stored("mismatched.mobileprovision")
		let installed = try profile("adhoc.mobileprovision")
		// The installed profile lists the signing certificate, not the other one.
		let choice = OwnAppSigning.choose(from: [mismatched, development], applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry) { _ in true }
		XCTAssertEqual(choice, OwnAppSigning.Choice(certificateID: development.id, usesInstalledProfile: true))

		// Not for re-signing, nor once that profile has run out.
		XCTAssertNil(OwnAppSigning.choose(from: [development], applicationIdentifier: ownAppID, installedProfile: installed, allowsInstalledProfile: false, now: beforeExpiry) { _ in true })
		XCTAssertNil(OwnAppSigning.choose(from: [development], applicationIdentifier: ownAppID, installedProfile: installed, now: Fixture.utc(2027, 2, 1)) { _ in true })
		// Nor when it's for another App ID than the one Atelier runs as.
		XCTAssertNil(OwnAppSigning.choose(from: [development], applicationIdentifier: "TESTTEAM01.other", installedProfile: installed, now: beforeExpiry) { _ in true })
		XCTAssertNil(OwnAppSigning.choose(from: [mismatched], applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry) { _ in true }, "a certificate the profile doesn't list")
	}

	func testLeavesOutCertificatesThatCantSign() throws {
		let development = try stored("development.mobileprovision")
		let adHoc = try stored("adhoc.mobileprovision")
		let installed = try profile("adhoc.mobileprovision")
		let choice = OwnAppSigning.choose(from: [adHoc, development], applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry) { $0.id != adHoc.id }
		XCTAssertEqual(choice, OwnAppSigning.Choice(certificateID: development.id, usesInstalledProfile: true))
		XCTAssertNil(OwnAppSigning.choose(from: [adHoc, development], applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry) { _ in false })
	}

	func testAnyCertificateWhenItsAppIDIsUnknown() throws {
		let development = try stored("development.mobileprovision")
		let adHoc = try stored("adhoc.mobileprovision")
		XCTAssertEqual(
			OwnAppSigning.choose(from: [development, adHoc], applicationIdentifier: nil, installedProfile: nil, now: beforeExpiry) { _ in true },
			OwnAppSigning.Choice(certificateID: development.id, usesInstalledProfile: false)
		)
	}

	func testSignAgainWithSaysHowEachCertificateSigns() throws {
		let installed = try profile("adhoc.mobileprovision")
		let adHoc = try stored("adhoc.mobileprovision")
		let development = try stored("development.mobileprovision")
		let mismatched = try stored("mismatched.mobileprovision")
		XCTAssertEqual(OwnAppSigning.choice(for: adHoc, applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry)?.usesInstalledProfile, false)
		XCTAssertEqual(OwnAppSigning.choice(for: development, applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry)?.usesInstalledProfile, true)
		XCTAssertNil(OwnAppSigning.choice(for: mismatched, applicationIdentifier: ownAppID, installedProfile: installed, now: beforeExpiry))
	}

	func testShowsTheAppIDWithoutItsTeam() {
		XCTAssertEqual(OwnAppSigning.bundleIDPart(of: "S7GNTEAM42.app.otter4812.mango3307", teamID: "S7GNTEAM42"), "app.otter4812.mango3307")
		XCTAssertEqual(OwnAppSigning.bundleIDPart(of: "S7GNTEAM42.app.otter4812.mango3307", teamID: nil), "app.otter4812.mango3307")
		XCTAssertEqual(OwnAppSigning.bundleIDPart(of: "S7GNTEAM42.*", teamID: "S7GNTEAM42"), "*")
		XCTAssertEqual(OwnAppSigning.bundleIDPart(of: "com.example.app", teamID: nil), "com.example.app")
	}
}
