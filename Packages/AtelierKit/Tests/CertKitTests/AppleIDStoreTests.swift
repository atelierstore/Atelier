import Foundation
import XCTest
@testable import CertKit

/// Apple IDs kept with the certificates (#49).
final class AppleIDStoreTests: XCTestCase {
	var directory: URL!
	let secrets = InMemoryCertificateSecrets()
	let appleIDPasswords = InMemoryCertificateSecrets()

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleIDStoreTests-\(UUID().uuidString)")
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private func open() throws -> CertificateStore {
		try CertificateStore(directory: directory, secrets: secrets, appleIDPasswords: appleIDPasswords)
	}

	/// A certificate to stand for the one Atelier made: the fixture's.
	private func certificate() throws -> SigningCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("development.mobileprovision"))
		return try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "development.mobileprovision")).certificate
	}

	private func appleID(id: UUID = UUID(), email: String = "Sam.Test@iCloud.com", team: String = "A1B2C3D4E5") throws -> StoredAppleID {
		StoredAppleID(
			id: id,
			addedAt: Fixture.utc(2026, 11, 2),
			email: email,
			team: StoredAppleID.Team(id: team, name: "Sam Test", isFree: true),
			certificate: try certificate(),
			machineName: "Atelier"
		)
	}

	private func importPair(_ store: CertificateStore) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("adhoc.mobileprovision"))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "adhoc.mobileprovision"))
		return try store.add(validated, files: files, password: Fixture.password)
	}

	func testSavesAnAppleIDAndUsesItWhenNothingIsInUse() throws {
		let store = try open()
		let account = try appleID()
		_ = try store.keysFolder(for: account.id)
		try store.saveAppleID(account, p12: Data("p12".utf8), p12Password: "p12 password", password: "apple password")

		XCTAssertEqual(store.appleIDs, [account])
		XCTAssertEqual(store.defaultID, account.id, "in use, as nothing else was")
		XCTAssertEqual(store.defaultAppleID, account)
		XCTAssertNil(store.defaultCertificate, "no imported pair is in use")
		XCTAssertEqual(try Data(contentsOf: store.p12URL(for: account.id)), Data("p12".utf8))
		XCTAssertEqual(try store.password(for: account.id), "p12 password", "kept as an imported .p12's, for signing")
		XCTAssertEqual(try store.appleIDPassword(for: account.id), "apple password")

		let reopened = try open()
		XCTAssertEqual(reopened.appleIDs, [account], "survives a relaunch")
		XCTAssertEqual(reopened.defaultID, account.id)
	}

	func testDoesntTakeOverFromTheCertificateInUseUnlessAsked() throws {
		let store = try open()
		let pair = try importPair(store)
		let account = try appleID()
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		XCTAssertEqual(store.defaultID, pair.id)

		try store.setDefault(account.id)
		XCTAssertEqual(store.defaultID, account.id, "Use for Installs")
		try store.setDefault(pair.id)
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "", use: true)
		XCTAssertEqual(store.defaultID, account.id)
	}

	func testSigningInAgainReplacesItUnderItsID() throws {
		let store = try open()
		let account = try appleID()
		try store.saveAppleID(account, p12: Data("old".utf8), p12Password: "old", password: "old")
		XCTAssertEqual(store.appleID(email: " sam.test@icloud.com", teamID: "A1B2C3D4E5")?.id, account.id, "whatever the case it's typed in")
		XCTAssertNil(store.appleID(email: "sam.test@icloud.com", teamID: "Q1W2E3R4T5"), "another team is another one")

		var again = account
		again.team.name = "Sam"
		try store.saveAppleID(again, p12: Data("new".utf8), p12Password: "new", password: "new")
		XCTAssertEqual(store.appleIDs, [again])
		XCTAssertEqual(try store.appleIDPassword(for: account.id), "new")
		XCTAssertEqual(try Data(contentsOf: store.p12URL(for: account.id)), Data("new".utf8))
	}

	func testSigningOutRemovesItsKeyCertificateAndPasswords() throws {
		let store = try open()
		let pair = try importPair(store)
		let account = try appleID()
		let keys = try store.keysFolder(for: account.id)
		try Data("key".utf8).write(to: keys.appendingPathComponent("key"))
		try store.saveAppleID(account, p12: Data("p12".utf8), p12Password: "p12", password: "apple", use: true)

		try store.deleteAppleID(account.id)
		XCTAssertTrue(store.appleIDs.isEmpty)
		XCTAssertEqual(store.defaultID, pair.id, "the imported one takes over")
		XCTAssertFalse(FileManager.default.fileExists(atPath: keys.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: store.p12URL(for: account.id).path))
		XCTAssertNil(try store.password(for: account.id))
		XCTAssertNil(try store.appleIDPassword(for: account.id))
		XCTAssertEqual(store.certificates.map(\.id), [pair.id], "the imported one stays")
	}

	func testAnAppleIDTakesOverFromADeletedPairWhenItsAllThereIs() throws {
		let store = try open()
		let pair = try importPair(store)
		let account = try appleID()
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		try store.delete(pair.id)
		XCTAssertEqual(store.defaultID, account.id)
	}

	func testKeepsItsRevocationCheck() throws {
		let store = try open()
		let account = try appleID()
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		let checked = RevocationState(status: .good, checkedAt: Fixture.utc(2026, 11, 2), attemptedAt: Fixture.utc(2026, 11, 2))
		try store.setAppleIDRevocation(checked, for: account.id)
		try store.setAppleIDRevocation(checked, for: UUID())
		XCTAssertEqual(try open().appleIDs.first?.revocation, checked)
		XCTAssertFalse(try open().appleIDs.first?.isRevoked ?? true)
	}

	func testKeepsAnAppleIDUnderTheSameIDAtEverySignIn() {
		let id = StoredAppleID.id(email: "sam.test@icloud.com", teamID: "A1B2C3D4E5")
		XCTAssertEqual(StoredAppleID.id(email: " Sam.Test@iCloud.com ", teamID: "A1B2C3D4E5"), id, "whatever the case it's typed in")
		XCTAssertNotEqual(StoredAppleID.id(email: "sam.test@icloud.com", teamID: "Q1W2E3R4T5"), id, "another team is another one")
		XCTAssertNotEqual(StoredAppleID.id(email: "sam@icloud.com", teamID: "A1B2C3D4E5"), id)
		// A version 5 UUID, of RFC 4122's variant.
		XCTAssertEqual(id.uuid.6 >> 4, 5)
		XCTAssertEqual(id.uuid.8 >> 6, 2)
	}

	func testKeepsItsAppsProfilesAndLimitsAcrossASignInAgain() throws {
		let store = try open()
		let account = try appleID()
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		let profile = AppProfile(bundleID: "com.example.app.A1B2C3D4E5", uuid: "8C1F", expires: Fixture.utc(2026, 11, 9))
		let limits = AppleIDLimits(appIDs: .init(checkedAt: Fixture.utc(2026, 11, 2), max: 10, available: 7, expiries: [Fixture.utc(2026, 11, 9)]))
		try store.updateAppleID(account.id) { $0.note(profile) }
		try store.updateAppleID(account.id) { $0.limits = limits }
		try store.updateAppleID(UUID()) { $0.limits = nil }
		XCTAssertEqual(try open().appleIDs.first?.profiles, [profile])
		XCTAssertEqual(try open().appleIDs.first?.limits, limits)

		// Signing in again makes a new record, without them.
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		XCTAssertEqual(store.appleIDs.first?.profile(for: "com.example.app.A1B2C3D4E5"), profile)
		XCTAssertEqual(store.appleIDs.first?.limits, limits)
	}

	func testReadsTheIndexOfABuildBeforeInstallsWithAnAppleID() throws {
		let store = try open()
		let account = try appleID()
		try store.saveAppleID(account, p12: Data(), p12Password: "", password: "")
		let url = directory.appendingPathComponent("index.json")
		let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
		let appleIDs = try XCTUnwrap(index["appleIDs"] as? [[String: Any]])
		XCTAssertNil(appleIDs.first?["profiles"], "PR 2's build wrote none")
		XCTAssertNil(appleIDs.first?["limits"])

		let reopened = try open()
		XCTAssertEqual(reopened.appleIDs, [account])
		XCTAssertNil(reopened.appleIDs.first?.profiles)
	}

	func testReadsTheIndexOfABuildBeforeAppleIDs() throws {
		let pair = try importPair(open())
		let url = directory.appendingPathComponent("index.json")
		var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
		index["appleIDs"] = nil
		try JSONSerialization.data(withJSONObject: index).write(to: url)

		let reopened = try open()
		XCTAssertEqual(reopened.certificates.map(\.id), [pair.id])
		XCTAssertTrue(reopened.appleIDs.isEmpty)
		XCTAssertEqual(reopened.defaultID, pair.id)
	}
}
