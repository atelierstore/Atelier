import Foundation
import XCTest
@testable import CertKit

/// The certificate a copy of Atelier comes with, in a file Custom Install…
/// writes into the copy's app (#113, #155).
final class PackagedCertificateTests: XCTestCase {
	private func packaged(profile: String = "adhoc.mobileprovision", password: String = Fixture.password, name: String? = "Signulous Development", udid: String? = nil) throws -> PackagedCertificate {
		PackagedCertificate(p12: try Fixture.data("signing.p12"), profile: try Fixture.data(profile), password: password, name: name, udid: udid)
	}

	func testComesBackAsItWent() throws {
		let certificate = try packaged(password: "p&a=s s+/#é")
		let file = try certificate.encoded()
		XCTAssertEqual(try PackagedCertificate(file: file), certificate)
		// A binary property list, as the app's other files are.
		var format = PropertyListSerialization.PropertyListFormat.xml
		let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: file, format: &format) as? [String: Any])
		XCTAssertEqual(format, .binary)
		XCTAssertEqual(Set(plist.keys), ["p12", "profile", "password", "name", "id"])
		XCTAssertEqual(plist["p12"] as? Data, try Fixture.data("signing.p12"))
		XCTAssertEqual(plist["id"] as? String, certificate.id.uuidString)

		// No UDID unless the Atelier that installed the copy knew it.
		XCTAssertNil(certificate.udid)
		XCTAssertNil(plist["udid"])

		// Each copy's file is its own, also with the same certificate, so a
		// copy installed again imports it again.
		let again = try packaged(password: "p&a=s s+/#é")
		XCTAssertNotEqual(again.id, certificate.id)
		XCTAssertNotEqual(try again.encoded(), file)

		// Without a name, or one that's only spaces, the certificate keeps its own.
		let unnamed = try packaged(name: nil)
		XCTAssertNil(try PackagedCertificate(file: unnamed.encoded()).name)
		XCTAssertFalse(String(decoding: try unnamed.encoded(), as: UTF8.self).contains("name"))
		XCTAssertNil(try PackagedCertificate(file: packaged(name: "  ").encoded()).name)
		XCTAssertEqual(try PackagedCertificate(file: packaged(name: " Team A ").encoded()).name, "Team A")
		// A .p12 can have an empty password.
		XCTAssertEqual(try PackagedCertificate(file: packaged(password: "").encoded()).password, "")
	}

	func testSaysWhenItCantBeRead() throws {
		let empty = PackagedCertificate(p12: Data(), profile: try Fixture.data("adhoc.mobileprovision"), password: "")
		let noProfile = PackagedCertificate(p12: try Fixture.data("signing.p12"), profile: Data(), password: "")
		let noPassword = try PropertyListSerialization.data(fromPropertyList: ["p12": Data([1]), "profile": Data([1]), "id": UUID().uuidString], format: .binary, options: 0)
		let noID = try PropertyListSerialization.data(fromPropertyList: ["p12": Data([1]), "profile": Data([1]), "password": ""], format: .binary, options: 0)
		for file in [Data(), Data("not a plist".utf8), noPassword, noID, try empty.encoded(), try noProfile.encoded()] {
			XCTAssertThrowsError(try PackagedCertificate(file: file)) { error in
				XCTAssertEqual(error as? PackagedCertificate.Problem, .unreadable)
			}
		}
	}

	/// This iPhone's UDID, which the copy notes as its own when the profile
	/// it was installed with lists it.
	func testBringsThisIPhonesUDID() throws {
		let udid = "00008120-0011223344556677"
		let certificate = try packaged(udid: udid)
		let file = try certificate.encoded()
		XCTAssertEqual(try PackagedCertificate(file: file), certificate)
		let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
		XCTAssertEqual(plist["udid"] as? String, udid)
		// The UDIDs of older iPhones, 40 hex digits without a hyphen.
		let older = String(repeating: "0123456789abcdef", count: 3).prefix(40)
		XCTAssertEqual(try PackagedCertificate(file: packaged(udid: String(older)).encoded()).udid, String(older))
		XCTAssertEqual(try PackagedCertificate(file: packaged(udid: " \(udid)\n").encoded()).udid, udid)
		// Anything else, and the certificate still comes in, without it.
		for other in ["", "  ", "not a UDID at all, really", "00008120/0011223344556677", "00008120-001122334455667é", "0000-1111", String(repeating: "a", count: 65)] {
			let read = try PackagedCertificate(file: packaged(udid: other).encoded())
			XCTAssertNil(read.udid, other)
			XCTAssertEqual(read.p12, try Fixture.data("signing.p12"))
		}

		// Only one the profile the copy was installed with lists, in any case.
		let development = try ProvisioningProfile(data: Fixture.data("development.mobileprovision"))
		XCTAssertEqual(certificate.deviceUDID(installedWith: development), udid)
		XCTAssertEqual(try packaged(udid: "00008110-000a1b2c3d4e5f60").deviceUDID(installedWith: development), "00008110-000a1b2c3d4e5f60")
		XCTAssertNil(try packaged(udid: "00008120-FFFFFFFFFFFFFFFF").deviceUDID(installedWith: development))
		XCTAssertNil(certificate.deviceUDID(installedWith: nil))
		XCTAssertNil(try packaged().deviceUDID(installedWith: development))
		// An enterprise profile lists no devices, and an App Store one
		// installs nothing outside the App Store.
		XCTAssertEqual(certificate.deviceUDID(installedWith: try ProvisioningProfile(data: Fixture.data("enterprise.mobileprovision"))), udid)
		XCTAssertNil(certificate.deviceUDID(installedWith: try ProvisioningProfile(data: Fixture.data("appstore.mobileprovision"))))
	}

	func testGivesImportCertificateItsFiles() throws {
		let named = try packaged(name: "Team A/B").files
		XCTAssertEqual(named.p12, CertificateFiles.File(name: "Team A-B.p12", data: try Fixture.data("signing.p12")))
		XCTAssertEqual(named.profile, CertificateFiles.File(name: "Team A-B.mobileprovision", data: try Fixture.data("adhoc.mobileprovision")))
		XCTAssertTrue(named.isComplete)
		XCTAssertEqual(try packaged(name: nil).files.p12?.name, "Certificate.p12")
	}

	func testOnlyTheCertificateTheAppIsSignedWith() throws {
		let opener = Fixture.opener(certificateFrom: "adhoc.mobileprovision")
		let certificate = try packaged()
		// The profile the copy was installed with lists it.
		let installed = try ProvisioningProfile(data: Fixture.data("development.mobileprovision"))
		let validated = try certificate.validated(installedWith: installed, openP12: opener)
		XCTAssertEqual(validated.certificate.serialNumber, Fixture.signingSerial)
		XCTAssertEqual(validated.profile.kind, .adHoc)

		// One that doesn't, or none, as with a copy installed by another tool.
		let other = try ProvisioningProfile(data: Fixture.data("mismatched.mobileprovision"))
		XCTAssertFalse(other.allows(validated.certificate))
		for profile in [other, nil] {
			XCTAssertThrowsError(try certificate.validated(installedWith: profile, openP12: opener)) { error in
				XCTAssertEqual(error as? PackagedCertificate.Problem, .notSignedWithIt)
			}
		}

		// Checked as Import Certificate checks it.
		XCTAssertThrowsError(try packaged(password: "nope").validated(installedWith: installed, openP12: opener)) { error in
			XCTAssertEqual(error as? CertificateImportError, .wrongPassword)
		}
		XCTAssertThrowsError(try packaged(profile: "mismatched.mobileprovision").validated(installedWith: installed, openP12: opener)) { error in
			XCTAssertEqual(error as? CertificateImportError, .mismatch(certificate: "iPhone Distribution: OwnStore Test (TESTTEAM01)", profile: "OwnStore Test mismatched"))
		}
	}
}
