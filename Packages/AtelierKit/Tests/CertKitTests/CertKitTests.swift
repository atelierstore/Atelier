import Foundation
import InstallKit
import XCTest
@testable import CertKit

/// Fixtures come from make-fixtures.sh: throwaway certificates and profiles,
/// not real Apple ones. The expected values below are that script's output.
enum Fixture {
	static func data(_ name: String) throws -> Data {
		let url = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/\(name)")
		return try Data(contentsOf: url)
	}

	static func file(_ name: String) throws -> CertificateFiles.File {
		CertificateFiles.File(name: name, data: try data(name))
	}

	static let password = "ownstore"
	static let signingSerial = "AD973815E803D1C1"
	static let otherSerial = "915936D89DC77A5C"
	/// `openssl x509 -fingerprint -sha1` of signing.p12's certificate.
	static let signingFingerprint = "986AF4C1ECBF55012EE7538AC5E15F3D58C0E4A2"

	/// The DER certificate inside a fixture .p12: the leaf that a profile with
	/// the same name lists. Linux can't open a .p12, so tests stand in for
	/// `PKCS12.certificate` with this.
	static func opener(certificateFrom profileName: String) -> (Data, String) throws -> Data {
		{ _, password in
			guard password == Fixture.password else { throw CertificateImportError.wrongPassword }
			let profile = try ProvisioningProfile(data: Fixture.data(profileName))
			return profile.developerCertificates[0]
		}
	}

	static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
		var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
		components.calendar = Calendar(identifier: .gregorian)
		components.timeZone = TimeZone(identifier: "UTC")
		return components.date!
	}

	/// A stored (uncompressed) ZIP, enough to stand in for an IPA.
	static func zip(_ files: [(String, Data)]) -> Data {
		var out = Data()
		var central = Data()
		func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
		func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
		func append(_ target: inout Data, _ parts: [Data]) { for part in parts { target.append(part) } }
		for (path, data) in files {
			let offset = out.count
			let name = Data(path.utf8)
			append(&out, [le32(0x0403_4B50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
			append(&out, [le32(data.count), le32(data.count), le16(name.count), le16(0), name, data])
			append(&central, [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
			append(&central, [le32(data.count), le32(data.count), le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name])
		}
		let tableOffset = out.count
		out.append(central)
		append(&out, [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(tableOffset), le16(0)])
		return out
	}
}

final class ProvisioningProfileTests: XCTestCase {
	func testReadsDevelopmentProfile() throws {
		let profile = try ProvisioningProfile(data: Fixture.data("development.mobileprovision"))
		XCTAssertEqual(profile.name, "OwnStore Test development")
		XCTAssertEqual(profile.teamID, "TESTTEAM01")
		XCTAssertEqual(profile.teamName, "OwnStore Test")
		XCTAssertEqual(profile.kind, .development)
		XCTAssertEqual(profile.applicationIdentifier, "TESTTEAM01.*")
		XCTAssertEqual(profile.bundleIDPattern, "*")
		XCTAssertTrue(profile.isWildcard)
		XCTAssertEqual(profile.expirationDate, Fixture.utc(2027, 1, 1))
		XCTAssertEqual(profile.creationDate, Fixture.utc(2026, 1, 1))
		XCTAssertEqual(profile.provisionedDevices.count, 2)
		XCTAssertEqual(profile.developerCertificates.count, 1)
		XCTAssertEqual(profile.entitlements["get-task-allow"], "true")
		XCTAssertEqual(profile.entitlements["keychain-access-groups"], "TESTTEAM01.*, com.apple.token")
		XCTAssertEqual(profile.uuid.count, 36)
	}

	/// Apple encodes profiles with indefinite lengths and a chunked OCTET
	/// STRING; this fixture is streamed the same way.
	func testReadsStreamedAdHocProfile() throws {
		let data = try Fixture.data("adhoc.mobileprovision")
		XCTAssertEqual(Array(data.prefix(2)), [0x30, 0x80], "fixture should use indefinite lengths")
		let profile = try ProvisioningProfile(data: data)
		XCTAssertEqual(profile.kind, .adHoc)
		XCTAssertEqual(profile.bundleIDPattern, "com.example.app")
		XCTAssertFalse(profile.isWildcard)
		XCTAssertEqual(profile.entitlements["aps-environment"], "production")
	}

	/// The App Groups a certificate's profile has, which keep an app's own
	/// in folders (#49): never a pattern.
	func testAppGroups() throws {
		func profile(_ groups: Any?) throws -> ProvisioningProfile {
			var entitlements: [String: Any] = ["application-identifier": "S7GNTEAM42.app.otter4812.mango3307"]
			entitlements["com.apple.security.application-groups"] = groups
			return try ProvisioningProfile(plist: [
				"Name": "Signulous", "UUID": "1", "TeamIdentifier": ["S7GNTEAM42"],
				"ExpirationDate": Fixture.utc(2027, 1, 1), "DeveloperCertificates": [Data()],
				"Entitlements": entitlements,
			])
		}
		XCTAssertEqual(try profile(["group.5f3c9a1e7b2d4806.2", "group.5f3c9a1e7b2d4806.1"]).appGroups, ["group.5f3c9a1e7b2d4806.2", "group.5f3c9a1e7b2d4806.1"])
		XCTAssertEqual(try profile(["group.example.*", "group.a"]).appGroups, ["group.a"])
		XCTAssertEqual(try profile([String]()).appGroups, [])
		XCTAssertEqual(try profile(nil).appGroups, [])
	}

	func testProfileKinds() throws {
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("enterprise.mobileprovision")).kind, .enterprise)
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("appstore.mobileprovision")).kind, .appStore)
	}

	func testDeviceCheck() throws {
		let adHoc = try ProvisioningProfile(data: Fixture.data("adhoc.mobileprovision"))
		XCTAssertEqual(adHoc.check(deviceUDID: nil), .unknown)
		XCTAssertEqual(adHoc.check(deviceUDID: "00008110-000a1b2c3d4e5f60"), .included)
		XCTAssertEqual(adHoc.check(deviceUDID: "00008110-FFFFFFFFFFFFFFFF"), .notIncluded)
		let enterprise = try ProvisioningProfile(data: Fixture.data("enterprise.mobileprovision"))
		XCTAssertEqual(enterprise.check(deviceUDID: nil), .anyDevice)
	}

	/// The device a profile that lists only one has to be on (#113).
	func testOnlyDevice() throws {
		var development = try ProvisioningProfile(data: Fixture.data("development.mobileprovision"))
		XCTAssertEqual(development.provisionedDevices.count, 2)
		XCTAssertNil(development.onlyDevice)
		development.provisionedDevices = ["00008120-0011223344556677"]
		XCTAssertEqual(development.onlyDevice, "00008120-0011223344556677")
		// The same device twice, in either case, is still one.
		development.provisionedDevices = ["00008120-0011223344556677", "00008120-0011223344556677".lowercased()]
		XCTAssertEqual(development.onlyDevice, "00008120-0011223344556677")
		development.provisionedDevices = []
		XCTAssertNil(development.onlyDevice)

		var adHoc = try ProvisioningProfile(data: Fixture.data("adhoc.mobileprovision"))
		adHoc.provisionedDevices = ["00008110-000A1B2C3D4E5F60"]
		XCTAssertEqual(adHoc.onlyDevice, "00008110-000A1B2C3D4E5F60")

		// Enterprise and App Store profiles don't list the devices their
		// apps run on.
		var enterprise = try ProvisioningProfile(data: Fixture.data("enterprise.mobileprovision"))
		enterprise.provisionedDevices = ["00008120-0011223344556677"]
		XCTAssertNil(enterprise.onlyDevice)
		var appStore = try ProvisioningProfile(data: Fixture.data("appstore.mobileprovision"))
		appStore.provisionedDevices = ["00008120-0011223344556677"]
		XCTAssertNil(appStore.onlyDevice)
	}

	/// What route A checks this iPhone against (#9).
	func testDevicesRouteAChecks() throws {
		let listed = ProfileDevices.listed(["00008110-000A1B2C3D4E5F60", "00008120-0011223344556677"])
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("development.mobileprovision")).devices, listed)
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("adhoc.mobileprovision")).devices, listed)
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("enterprise.mobileprovision")).devices, .any)
		XCTAssertEqual(try ProvisioningProfile(data: Fixture.data("appstore.mobileprovision")).devices, .listed([]))
	}

	/// Route A checks the profile signed into the app it installs, which
	/// isn't always the default certificate's (#87); an extension's own
	/// profile doesn't count.
	func testReadsTheProfileSignedIntoAnIPA() throws {
		let ipa = Fixture.zip([
			("Payload/", Data()),
			("Payload/Test.app/PlugIns/Widget.appex/embedded.mobileprovision", try Fixture.data("enterprise.mobileprovision")),
			("Payload/Test.app/Info.plist", Data("<plist/>".utf8)),
			("Payload/Test.app/embedded.mobileprovision", try Fixture.data("adhoc.mobileprovision")),
		])
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString).ipa")
		try ipa.write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }
		let profile = try XCTUnwrap(ProvisioningProfile.embedded(inIPAAt: url))
		XCTAssertEqual(profile.name, "OwnStore Test adhoc")
		XCTAssertEqual(profile.kind, .adHoc)
	}

	func testAnIPAWithoutAProfileHasNone() throws {
		let ipa = Fixture.zip([
			("Payload/Test.app/Info.plist", Data("<plist/>".utf8)),
			("Payload/Test.app/PlugIns/Widget.appex/embedded.mobileprovision", try Fixture.data("enterprise.mobileprovision")),
		])
		XCTAssertNil(try ProvisioningProfile.embedded(inIPAData: ipa))
	}

	func testAnUnreadableIPAOrProfileThrows() {
		XCTAssertThrowsError(try ProvisioningProfile.embedded(inIPAData: Data("not a zip".utf8)))
		let ipa = Fixture.zip([("Payload/Test.app/embedded.mobileprovision", Data("junk".utf8))])
		XCTAssertThrowsError(try ProvisioningProfile.embedded(inIPAData: ipa))
	}

	func testRejectsOtherFiles() {
		XCTAssertThrowsError(try ProvisioningProfile(data: Data("hello".utf8)))
		XCTAssertThrowsError(try ProvisioningProfile(data: Fixture.data("signing.p12")))
		XCTAssertThrowsError(try ProvisioningProfile(data: Data([0x30, 0x80, 0x06])))
	}

	func testReadsBarePlist() throws {
		let plist: [String: Any] = [
			"Name": "Bare", "UUID": "X", "ExpirationDate": Date(timeIntervalSince1970: 0),
			"DeveloperCertificates": [Data([1])], "TeamIdentifier": ["T"],
			"Entitlements": ["application-identifier": "T.com.x"],
		]
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		let profile = try ProvisioningProfile(data: data)
		XCTAssertEqual(profile.kind, .appStore)
		XCTAssertEqual(profile.bundleIDPattern, "com.x")
	}

	func testReportsMissingField() throws {
		let plist: [String: Any] = ["Name": "No entitlements", "UUID": "X"]
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		XCTAssertThrowsError(try ProvisioningProfile(data: data)) { error in
			XCTAssertEqual(error as? ProvisioningProfile.Error, .missing("Entitlements"))
		}
	}
}

final class SigningCertificateTests: XCTestCase {
	func testReadsAppleStyleSubject() throws {
		let profile = try ProvisioningProfile(data: Fixture.data("development.mobileprovision"))
		let certificate = try SigningCertificate(der: profile.developerCertificates[0])
		XCTAssertEqual(certificate.commonName, "iPhone Distribution: OwnStore Test (TESTTEAM01)")
		XCTAssertEqual(certificate.teamID, "TESTTEAM01")
		XCTAssertEqual(certificate.teamName, "OwnStore Test")
		XCTAssertEqual(certificate.serialNumber, Fixture.signingSerial)
		XCTAssertEqual(certificate.notBefore, Fixture.utc(2026, 10, 18, 15, 46, 48))
		XCTAssertEqual(certificate.notAfter, Fixture.utc(2036, 10, 15, 15, 46, 48))
	}

	func testRejectsGarbage() {
		XCTAssertThrowsError(try SigningCertificate(der: Data([0x30, 0x03, 0x02, 0x01, 0x01])))
		XCTAssertThrowsError(try SigningCertificate(der: Data()))
	}

	func testDates() throws {
		XCTAssertEqual(ASN1Node(tag: 0x17, content: Array("491231235959Z".utf8), children: []).date, Fixture.utc(2049, 12, 31, 23, 59, 59))
		XCTAssertEqual(ASN1Node(tag: 0x17, content: Array("500101000000Z".utf8), children: []).date, Fixture.utc(1950, 1, 1))
		XCTAssertEqual(ASN1Node(tag: 0x18, content: Array("20510101000000Z".utf8), children: []).date, Fixture.utc(2051, 1, 1))
		XCTAssertNil(ASN1Node(tag: 0x18, content: Array("20510101000000+0100".utf8), children: []).date)
	}
}

final class CertificateFilesTests: XCTestCase {
	func testSortsFilesByExtension() throws {
		var files = CertificateFiles()
		try files.add(name: "Cert.P12", data: Fixture.data("signing.p12"))
		XCTAssertFalse(files.isComplete)
		try files.add(name: "x.mobileprovision", data: Fixture.data("development.mobileprovision"))
		XCTAssertTrue(files.isComplete)
		XCTAssertEqual(files.p12?.name, "Cert.P12")
	}

	func testRecognisesProfileWithoutExtension() throws {
		var files = CertificateFiles()
		try files.add(name: "download", data: Fixture.data("adhoc.mobileprovision"))
		XCTAssertNotNil(files.profile)
	}

	func testReadsZipAndSkipsResourceForks() throws {
		var files = CertificateFiles()
		try files.add(name: "pair.zip", data: Fixture.data("pair.zip"))
		XCTAssertEqual(files.p12?.name, "OwnStore Test.p12")
		XCTAssertEqual(files.p12?.data, try Fixture.data("signing.p12"))
		XCTAssertEqual(files.profile?.name, "OwnStore Test.mobileprovision")
	}

	func testRejectsUnknownFiles() {
		var files = CertificateFiles()
		XCTAssertThrowsError(try files.add(name: "notes.txt", data: Data("hi".utf8))) { error in
			XCTAssertEqual(error as? CertificateImportError, .unsupportedFile("notes.txt"))
		}
		XCTAssertThrowsError(try files.add(name: "broken.zip", data: Data("PK\u{3}\u{4}nope".utf8))) { error in
			XCTAssertEqual(error as? CertificateImportError, .unreadableZip("broken.zip"))
		}
	}
}

final class CertificateImporterTests: XCTestCase {
	func files(_ profile: String) throws -> CertificateFiles {
		CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file(profile))
	}

	func testValidPair() throws {
		let validated = try CertificateImporter.validate(
			files("adhoc.mobileprovision"), password: Fixture.password,
			openP12: Fixture.opener(certificateFrom: "adhoc.mobileprovision")
		)
		XCTAssertEqual(validated.certificate.serialNumber, Fixture.signingSerial)
		XCTAssertEqual(validated.certificate.fingerprint, Fixture.signingFingerprint)
		XCTAssertEqual(validated.profile.kind, .adHoc)
	}

	func testMismatchedPair() throws {
		XCTAssertThrowsError(try CertificateImporter.validate(
			files("mismatched.mobileprovision"), password: Fixture.password,
			openP12: Fixture.opener(certificateFrom: "development.mobileprovision")
		)) { error in
			XCTAssertEqual(error as? CertificateImportError, .mismatch(
				certificate: "iPhone Distribution: OwnStore Test (TESTTEAM01)",
				profile: "OwnStore Test mismatched"
			))
		}
	}

	func testWrongPassword() throws {
		XCTAssertThrowsError(try CertificateImporter.validate(
			files("adhoc.mobileprovision"), password: "nope",
			openP12: Fixture.opener(certificateFrom: "adhoc.mobileprovision")
		)) { error in
			XCTAssertEqual(error as? CertificateImportError, .wrongPassword)
		}
	}

	func testMissingFiles() throws {
		XCTAssertThrowsError(try CertificateImporter.validate(CertificateFiles(profile: Fixture.file("adhoc.mobileprovision")), password: "")) { error in
			XCTAssertEqual(error as? CertificateImportError, .missingP12)
		}
		XCTAssertThrowsError(try CertificateImporter.validate(CertificateFiles(p12: Fixture.file("signing.p12")), password: "")) { error in
			XCTAssertEqual(error as? CertificateImportError, .missingProfile)
		}
	}

	func testBadProfileComesBeforePassword() throws {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: .init(name: "junk.mobileprovision", data: Data("junk".utf8)))
		XCTAssertThrowsError(try CertificateImporter.validate(files, password: "nope", openP12: { _, _ in XCTFail("opened"); return Data() })) { error in
			XCTAssertEqual(error as? CertificateImportError, .notAProfile("junk.mobileprovision"))
		}
	}

	#if canImport(Security)
	/// The real .p12 path, on Apple platforms only.
	func testOpensFixtureP12WithSecurity() throws {
		let validated = try CertificateImporter.validate(files("development.mobileprovision"), password: Fixture.password)
		XCTAssertEqual(validated.certificate.serialNumber, Fixture.signingSerial)
	}

	func testWrongPasswordWithSecurity() throws {
		XCTAssertThrowsError(try CertificateImporter.validate(files("development.mobileprovision"), password: "nope")) { error in
			let error = error as? CertificateImportError
			XCTAssertTrue(error == .wrongPassword || error == .wrongPasswordOrUnsupportedP12, "\(String(describing: error))")
		}
	}
	#endif
}

final class CertificateStoreTests: XCTestCase {
	var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("CertKitTests-\(UUID().uuidString)")
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	func importPair(_ store: CertificateStore, profile: String = "adhoc.mobileprovision", password: String = Fixture.password, id: UUID? = nil) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file(profile))
		let validated = try CertificateImporter.validate(files, password: password, openP12: Fixture.opener(certificateFrom: profile))
		return try store.add(validated, files: files, password: password, id: id)
	}

	func testImportListDeleteAndDefault() throws {
		let secrets = InMemoryCertificateSecrets()
		let store = try CertificateStore(directory: directory, secrets: secrets)
		XCTAssertTrue(store.certificates.isEmpty)

		let first = try importPair(store)
		XCTAssertEqual(store.defaultID, first.id, "first import becomes the default")
		XCTAssertEqual(try store.password(for: first.id), Fixture.password)
		XCTAssertEqual(try Data(contentsOf: store.p12URL(for: first.id)), try Fixture.data("signing.p12"))
		XCTAssertEqual(try Data(contentsOf: store.profileURL(for: first.id)), try Fixture.data("adhoc.mobileprovision"))

		let second = try importPair(store, profile: "enterprise.mobileprovision")
		XCTAssertEqual(store.certificates.map(\.id), [first.id, second.id])
		XCTAssertEqual(store.defaultID, first.id)

		try store.setDefault(second.id)
		XCTAssertEqual(store.defaultCertificate?.id, second.id)

		// Survives a relaunch.
		let reopened = try CertificateStore(directory: directory, secrets: secrets)
		XCTAssertEqual(reopened.certificates, store.certificates)
		XCTAssertEqual(reopened.defaultID, second.id)

		try reopened.delete(second.id)
		XCTAssertEqual(reopened.defaultID, first.id, "deleting the default hands it to the oldest left")
		XCTAssertNil(try reopened.password(for: second.id))
		XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.p12URL(for: second.id).path))

		try reopened.delete(first.id)
		XCTAssertNil(reopened.defaultID)
		XCTAssertTrue(reopened.certificates.isEmpty)
	}

	func testNamesAPair() throws {
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("adhoc.mobileprovision"))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "adhoc.mobileprovision"))
		let named = try store.add(validated, files: files, password: Fixture.password, name: "  My iPhone  ")
		XCTAssertEqual(named.customName, "My iPhone", "trimmed")
		XCTAssertEqual(named.displayName, "My iPhone")

		try store.setName("Work", for: named.id)
		let reopened = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		XCTAssertEqual(reopened.certificates.first?.displayName, "Work", "survives a relaunch")

		try reopened.setName("  ", for: named.id)
		let cleared = try XCTUnwrap(reopened.certificates.first)
		XCTAssertNil(cleared.customName, "an empty name goes back to the certificate's own")
		XCTAssertEqual(cleared.displayName, cleared.originalName)
	}

	func testRecordsConfirmedDevicePerProfile() throws {
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		let adHoc = try importPair(store)
		let development = try importPair(store, profile: "development.mobileprovision")
		XCTAssertNil(adHoc.deviceConfirmedAt)

		try store.setDeviceConfirmed(for: adHoc.id, at: Fixture.utc(2026, 10, 21))
		try store.setDeviceConfirmed(for: adHoc.id, at: Fixture.utc(2026, 10, 22))
		try store.setDeviceConfirmed(for: UUID())
		let reopened = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		XCTAssertEqual(reopened.certificates.first { $0.id == adHoc.id }?.deviceConfirmedAt, Fixture.utc(2026, 10, 21), "keeps the first confirmation")
		XCTAssertNil(reopened.certificates.first { $0.id == development.id }?.deviceConfirmedAt, "another profile isn't confirmed by it")
	}

	func testDeletedPairComesBackUnderItsID() throws {
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		let first = try importPair(store)
		try store.delete(first.id)

		let again = try importPair(store, id: first.id)
		XCTAssertEqual(again.id, first.id, "a deleted pair imported again gets its ID back (#126)")
		XCTAssertEqual(store.defaultID, again.id)
		XCTAssertEqual(try store.password(for: again.id), Fixture.password)
		XCTAssertEqual(try Data(contentsOf: store.p12URL(for: again.id)), try Fixture.data("signing.p12"))
		XCTAssertEqual(try Data(contentsOf: store.profileURL(for: again.id)), try Fixture.data("adhoc.mobileprovision"))

		let other = try importPair(store, profile: "development.mobileprovision", id: again.id)
		XCTAssertNotEqual(other.id, again.id, "not under an ID a pair has")
		XCTAssertEqual(store.certificates.map(\.id), [again.id, other.id])
		let reopened = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		XCTAssertEqual(reopened.certificates.map(\.id), [again.id, other.id], "survives a relaunch")
	}

	func testRejectsDuplicate() throws {
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		_ = try importPair(store)
		XCTAssertThrowsError(try importPair(store)) { error in
			XCTAssertEqual(error as? CertificateImportError, .alreadyImported("iPhone Distribution: OwnStore Test (TESTTEAM01)"))
		}
		XCTAssertEqual(store.certificates.count, 1)
	}

	func testDisplayNameAndExpiry() throws {
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		let stored = try importPair(store)
		XCTAssertEqual(stored.displayName, "OwnStore Test (TESTTEAM01)")
		XCTAssertEqual(stored.expiresAt, Fixture.utc(2027, 1, 1), "the profile runs out before the certificate")
	}
}

final class CertificateNotesTests: XCTestCase {
	func stored(_ profile: String) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file(profile))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: profile))
		return StoredCertificate(id: UUID(), addedAt: .now, certificate: validated.certificate, profile: validated.profile)
	}

	func kinds(_ notes: [CertificateNote]) -> [CertificateNote.Kind] { notes.map(\.kind) }

	let beforeExpiry = Fixture.utc(2026, 11, 1)

	func testDevelopment() throws {
		let notes = try stored("development.mobileprovision").notes(now: beforeExpiry)
		XCTAssertEqual(kinds(notes), [.deviceUnknown, .developerModeNeeded])
	}

	func testAdHocOnListedDevice() throws {
		let notes = try stored("adhoc.mobileprovision").notes(now: beforeExpiry, deviceUDID: "00008120-0011223344556677")
		// An explicit App ID gets no note: the spike showed such a profile signs
		// apps with any bundle ID (docs/install-routes.md).
		XCTAssertEqual(kinds(notes), [.developerModeNeeded, .deviceInProfile])
		XCTAssertEqual(notes.last?.severity, .ok)
	}

	func testDeveloperModeFromRouteA() throws {
		let certificate = try stored("adhoc.mobileprovision")
		let on = certificate.notes(now: beforeExpiry, deviceUDID: "00008120-0011223344556677", developerModeOn: true)
		XCTAssertEqual(kinds(on), [.deviceInProfile, .developerModeOn])
		XCTAssertTrue(on.allSatisfy { $0.severity == .ok })
		let off = certificate.notes(now: beforeExpiry, deviceUDID: "00008120-FFFFFFFFFFFFFFFF", developerModeOn: false)
		XCTAssertEqual(kinds(off), [.deviceNotInProfile, .developerModeOff])
		XCTAssertTrue(off.allSatisfy { $0.severity == .problem })
		XCTAssertEqual(try stored("enterprise.mobileprovision").notes(now: beforeExpiry, developerModeOn: false), [], "enterprise apps don't need Developer Mode")
	}

	func testNotesNameTheDevice() throws {
		let certificate = try stored("adhoc.mobileprovision")
		let iPad = certificate.notes(now: beforeExpiry, deviceUDID: "00008120-0011223344556677", device: "iPad")
		XCTAssertEqual(iPad.last?.message, "Registered for this iPad.")
		let elsewhere = certificate.notes(now: beforeExpiry, deviceUDID: "00008120-FFFFFFFFFFFFFFFF", device: "iPad")
		XCTAssertEqual(elsewhere.first?.message, "This certificate isn't registered for this iPad, so apps signed with it won't install here.")
		let unknown = certificate.notes(now: beforeExpiry, device: "iPad")
		XCTAssertEqual(unknown.first?.message, "Atelier can't check yet whether this certificate is registered for this iPad. If it isn't, installs will fail. Finishing the setup lets it check.")
		XCTAssertFalse((iPad + elsewhere + unknown).contains { $0.message.contains("iPhone") })
	}

	func testEnterprise() throws {
		XCTAssertEqual(try stored("enterprise.mobileprovision").notes(now: beforeExpiry), [])
	}

	func testConfirmedInstallDropsDeviceWarning() throws {
		var certificate = try stored("adhoc.mobileprovision")
		XCTAssertEqual(kinds(certificate.notes(now: beforeExpiry)), [.deviceUnknown, .developerModeNeeded])
		XCTAssertTrue(certificate.notes(now: beforeExpiry).allSatisfy { $0.severity == .info }, "not knowing isn't a warning")
		certificate.deviceConfirmedAt = Fixture.utc(2026, 10, 21)
		XCTAssertEqual(kinds(certificate.notes(now: beforeExpiry)), [.developerModeNeeded, .deviceInProfile])
		// A known UDID that isn't listed still wins.
		XCTAssertEqual(kinds(certificate.notes(now: beforeExpiry, deviceUDID: "00008120-FFFFFFFFFFFFFFFF")), [.deviceNotInProfile, .developerModeNeeded])
	}

	func testAppStoreAndExpired() throws {
		let notes = try stored("appstore.mobileprovision").notes(now: Fixture.utc(2027, 6, 1))
		XCTAssertEqual(kinds(notes), [.profileExpired, .appStoreProfile])
		XCTAssertTrue(notes.allSatisfy { $0.severity == .problem })
	}
}
