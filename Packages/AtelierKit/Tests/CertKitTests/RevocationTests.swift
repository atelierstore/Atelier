import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import CertKit

/// Fixtures in Fixtures/ocsp come from make-ocsp-fixtures.sh: throwaway CAs
/// and an OCSP responder shaped like Apple's. Tests read every expected value
/// from the fixtures, so regenerating them needs no edits here.
enum OCSPFixture {
	static func data(_ name: String) throws -> Data { try Fixture.data("ocsp/\(name)") }

	static func certificate(_ name: String) throws -> X509Certificate {
		try X509Certificate(der: data("\(name).der"))
	}

	static func response(_ name: String) throws -> OCSPResponse {
		try OCSPResponse(der: data("\(name).ocsp"))
	}

	/// When the responder made the answer, so it's current.
	static func answeredAt(_ name: String) throws -> Date {
		try XCTUnwrap(response(name).singles.first?.thisUpdate)
	}
}

extension Fixture {
	/// The signing fixture with one of the profiles, as imported.
	static func stored(_ profile: String) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try file("signing.p12"), profile: try file(profile))
		let validated = try CertificateImporter.validate(files, password: password, openP12: opener(certificateFrom: profile))
		return StoredCertificate(id: UUID(), addedAt: .now, certificate: validated.certificate, profile: validated.profile)
	}
}

/// Checking signatures needs Security, so those tests skip on Linux.
func requireSecurity() throws {
	#if !canImport(Security)
	throw XCTSkip("Checking signatures needs Security")
	#endif
}

final class SHA1Tests: XCTestCase {
	func hex(_ string: String) -> String {
		SHA1.hash(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	/// FIPS 180 test vectors.
	func testVectors() {
		XCTAssertEqual(hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
		XCTAssertEqual(hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
		XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
		XCTAssertEqual(hex(String(repeating: "a", count: 1_000_000)), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
	}
}

final class X509Tests: XCTestCase {
	func testReadsWhatOCSPNeeds() throws {
		let ca = try OCSPFixture.certificate("rsa-ca")
		let leaf = try OCSPFixture.certificate("rsa-good")
		XCTAssertEqual(leaf.ocspURL, URL(string: "http://ocsp.ownstore.test/ocsp03-test"))
		XCTAssertNotNil(ca.publicKeyHash)
		XCTAssertEqual(ca.subjectKeyIdentifier, ca.publicKeyHash, "openssl's key IDs are the SHA-1 of the key, like Apple's")
		XCTAssertEqual(leaf.authorityKeyIdentifier, ca.publicKeyHash)
		XCTAssertTrue(leaf.issuer.encoded.elementsEqual(ca.subject.encoded))
	}

	/// Apple's developer CAs make their key IDs the SHA-1 of their key, so a
	/// leaf's authority key ID finds its issuer.
	func testAppleCAsKeyIDsAreKeyHashes() throws {
		let cas = try AppleDeveloperCAs.certificates.map { try X509Certificate(der: $0) }
		XCTAssertEqual(cas.count, 5)
		for ca in cas {
			XCTAssertNotNil(ca.subjectKeyIdentifier)
			XCTAssertEqual(ca.subjectKeyIdentifier, ca.publicKeyHash)
		}
	}

	func testSigningCertificateStillReads() throws {
		let leaf = try SigningCertificate(der: OCSPFixture.data("ec-good.der"))
		XCTAssertEqual(leaf.commonName, "iPhone Distribution: OwnStore Test good (TESTTEAM01)")
		XCTAssertEqual(leaf.teamID, "TESTTEAM01")
	}
}

final class OCSPParsingTests: XCTestCase {
	func testRequestMatchesOpenSSL() throws {
		let body = try OCSPRequest.body(for: OCSPFixture.certificate("rsa-good"), issuer: OCSPFixture.certificate("rsa-ca"))
		XCTAssertEqual(Data(body), try OCSPFixture.data("rsa-good.req"))
	}

	func testParsesAnswers() throws {
		XCTAssertEqual(try OCSPFixture.response("rsa-good").singles.map(\.status), [.good])
		XCTAssertEqual(try OCSPFixture.response("rsa-unknown").singles.map(\.status), [.unknown])
		let revoked = try XCTUnwrap(OCSPFixture.response("rsa-revoked").singles.first)
		guard case .revoked(let date) = revoked.status else { return XCTFail("\(revoked.status)") }
		let at = try XCTUnwrap(date)
		XCTAssertEqual(at.timeIntervalSince(revoked.thisUpdate), -2 * 86_400, accuracy: 120, "the fixture revokes it two days before answering")
		XCTAssertNotNil(revoked.nextUpdate)
		XCTAssertEqual(try OCSPFixture.response("rsa-good").certificates.count, 1, "openssl sends the responder's certificate")
	}

	func testResponderErrors() {
		// OCSPResponse { responseStatus tryLater (3) }
		XCTAssertThrowsError(try OCSPResponse(der: Data([0x30, 0x03, 0x0A, 0x01, 0x03]))) { error in
			XCTAssertEqual(error as? RevocationCheckError, .responderError(3))
		}
		XCTAssertThrowsError(try OCSPResponse(der: Data("<html>".utf8))) { error in
			XCTAssertEqual(error as? RevocationCheckError, .malformedResponse)
		}
	}

}

/// Checking answers.
final class OCSPTests: XCTestCase {
	override func setUpWithError() throws {
		try requireSecurity()
	}

	func status(_ response: String, about leaf: String, ca: String, now: Date? = nil) throws -> RevocationStatus {
		try OCSPFixture.response(response).status(
			of: OCSPFixture.certificate(leaf),
			issuer: OCSPFixture.certificate(ca),
			now: now ?? OCSPFixture.answeredAt(response)
		)
	}

	func testDelegatedResponder() throws {
		for ca in ["rsa", "ec"] {
			XCTAssertEqual(try status("\(ca)-good", about: "\(ca)-good", ca: "\(ca)-ca"), .good, ca)
			XCTAssertEqual(try status("\(ca)-unknown", about: "\(ca)-unknown", ca: "\(ca)-ca"), .unknown, ca)
			guard case .revoked(let date) = try status("\(ca)-revoked", about: "\(ca)-revoked", ca: "\(ca)-ca") else {
				return XCTFail("\(ca)-revoked should be revoked")
			}
			XCTAssertNotNil(date)
		}
	}

	func testSignedByTheCA() throws {
		XCTAssertEqual(try status("rsa-direct", about: "rsa-good", ca: "rsa-ca"), .good)
		XCTAssertEqual(try status("ec-direct", about: "ec-good", ca: "ec-ca"), .good)
	}

	func testRejectsAnswersNotFromTheIssuer() throws {
		XCTAssertThrowsError(try status("rsa-forged", about: "rsa-good", ca: "rsa-ca")) { error in
			XCTAssertEqual(error as? RevocationCheckError, .badSignature)
		}
		XCTAssertThrowsError(try status("rsa-ca-only-responder", about: "rsa-good", ca: "rsa-ca")) { error in
			XCTAssertEqual(error as? RevocationCheckError, .badSignature, "its signer isn't allowed to sign OCSP answers")
		}
		XCTAssertThrowsError(try status("rsa-good", about: "rsa-good", ca: "ec-ca")) { error in
			XCTAssertEqual(error as? RevocationCheckError, .notAboutThisCertificate, "it names another CA's key")
		}
	}

	func testRejectsAnswersAboutAnotherCertificate() throws {
		XCTAssertThrowsError(try status("rsa-revoked", about: "rsa-good", ca: "rsa-ca")) { error in
			XCTAssertEqual(error as? RevocationCheckError, .notAboutThisCertificate)
		}
	}

	func testRejectsOldAndFutureAnswers() throws {
		let answered = try OCSPFixture.answeredAt("rsa-good")
		XCTAssertThrowsError(try status("rsa-good", about: "rsa-good", ca: "rsa-ca", now: answered.addingTimeInterval(8 * 86_400))) { error in
			XCTAssertEqual(error as? RevocationCheckError, .stale)
		}
		XCTAssertThrowsError(try status("rsa-good", about: "rsa-good", ca: "rsa-ca", now: answered.addingTimeInterval(-3600))) { error in
			XCTAssertEqual(error as? RevocationCheckError, .stale)
		}
	}
}

final class RevocationCheckerTests: XCTestCase {
	func checker(trusting ca: String = "rsa-ca", answer: String, status: Int = 200, sent: SentRequests? = nil) throws -> RevocationChecker {
		let body = try OCSPFixture.data("\(answer).ocsp")
		return RevocationChecker(trustedIssuers: [try OCSPFixture.data("\(ca).der")]) { request in
			sent?.append(request)
			return (body, status)
		}
	}

	final class SentRequests: @unchecked Sendable {
		private let lock = NSLock()
		private var requests: [URLRequest] = []
		func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
		var all: [URLRequest] { lock.withLock { requests } }
	}

	/// The issue's acceptance: a revoked certificate is flagged by one check.
	func testFlagsARevokedCertificateInOneCheck() async throws {
		try requireSecurity()
		let sent = SentRequests()
		let leaf = try SigningCertificate(der: OCSPFixture.data("rsa-revoked.der"))
		let status = try await checker(answer: "rsa-revoked", sent: sent).check(leaf, now: OCSPFixture.answeredAt("rsa-revoked"))
		guard case .revoked = status else { return XCTFail("\(status)") }

		let request = try XCTUnwrap(sent.all.first)
		XCTAssertEqual(sent.all.count, 1)
		XCTAssertEqual(request.url, URL(string: "http://ocsp.ownstore.test/ocsp03-test"))
		XCTAssertEqual(request.httpMethod, "POST")
		XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/ocsp-request")
		XCTAssertEqual(request.httpBody.map { [UInt8]($0) }, try OCSPRequest.body(for: OCSPFixture.certificate("rsa-revoked"), issuer: OCSPFixture.certificate("rsa-ca")))
	}

	func testGoodCertificate() async throws {
		try requireSecurity()
		let leaf = try SigningCertificate(der: OCSPFixture.data("ec-good.der"))
		let status = try await checker(trusting: "ec-ca", answer: "ec-good").check(leaf, now: OCSPFixture.answeredAt("ec-good"))
		XCTAssertEqual(status, .good)
	}

	func testUntrustedIssuer() async throws {
		let leaf = try SigningCertificate(der: OCSPFixture.data("rsa-good.der"))
		do {
			_ = try await checker(trusting: "ec-ca", answer: "rsa-good").check(leaf)
			XCTFail("should throw")
		} catch {
			XCTAssertEqual(error as? RevocationCheckError, .unknownIssuer("OwnStore Test Developer Relations CA"))
		}
	}

	func testHTTPError() async throws {
		let leaf = try SigningCertificate(der: OCSPFixture.data("rsa-good.der"))
		do {
			_ = try await checker(answer: "rsa-good", status: 404).check(leaf)
			XCTFail("should throw")
		} catch {
			XCTAssertEqual(error as? RevocationCheckError, .httpStatus(404))
		}
	}

	/// Asks Apple about the certificate in a real provisioning profile, when
	/// the machine has one: in CI, the Signulous profile it installs for the
	/// build. Skipped elsewhere, and when Apple can't be reached.
	func testAppleAnswersAboutARealCertificate() async throws {
		try requireSecurity()
		let home = FileManager.default.homeDirectoryForCurrentUser
		let folders = ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"]
		let profiles = folders.flatMap { folder in
			((try? FileManager.default.contentsOfDirectory(at: home.appending(path: folder), includingPropertiesForKeys: nil)) ?? [])
				.filter { $0.pathExtension == "mobileprovision" }
		}
		guard let file = profiles.first else { throw XCTSkip("No provisioning profile installed") }
		let profile = try ProvisioningProfile(data: Data(contentsOf: file))
		let certificate = try SigningCertificate(der: XCTUnwrap(profile.developerCertificates.first))
		do {
			let status = try await RevocationChecker().check(certificate)
			print("Apple says \(certificate.commonName) is \(status)")
			XCTAssertNotEqual(status, .unknown, "Apple should know its own certificate")
		} catch RevocationCheckError.network(let message) {
			throw XCTSkip("Apple's responder can't be reached: \(message)")
		} catch RevocationCheckError.httpStatus(let status) {
			throw XCTSkip("Apple's responder answered HTTP \(status)")
		}
	}
}

final class CertificateExpiryTests: XCTestCase {
	let day: TimeInterval = 86_400

	func testTheSoonerDateWins() {
		let early = Fixture.utc(2026, 12, 1), late = Fixture.utc(2027, 3, 1)
		XCTAssertEqual(CertificateExpiry(certificate: late, profile: early).part, .profile)
		XCTAssertEqual(CertificateExpiry(certificate: early, profile: late).part, .certificate)
		XCTAssertEqual(CertificateExpiry(certificate: early, profile: late).date, early)
		XCTAssertEqual(CertificateExpiry(certificate: early, profile: early).part, .certificate)
	}

	func testWarnings() {
		let end = Fixture.utc(2026, 12, 1)
		let expiry = CertificateExpiry(certificate: end, profile: end.addingTimeInterval(100 * day))
		func at(_ days: Double) -> Date { end.addingTimeInterval(-days * day) }
		XCTAssertNil(expiry.warning(now: at(30)))
		XCTAssertNil(expiry.warning(now: at(14.01)))
		XCTAssertEqual(expiry.warning(now: at(14)), 14)
		XCTAssertEqual(expiry.warning(now: at(8)), 14)
		XCTAssertEqual(expiry.warning(now: at(7)), 7)
		XCTAssertEqual(expiry.warning(now: at(2)), 7)
		XCTAssertEqual(expiry.warning(now: at(1)), 1)
		XCTAssertEqual(expiry.warning(now: at(0.1)), 1)
		XCTAssertEqual(expiry.warning(now: end), 0)
		XCTAssertEqual(expiry.warning(now: at(-3)), 0)
	}

	func testDaysLeft() {
		let end = Fixture.utc(2026, 12, 1)
		let expiry = CertificateExpiry(certificate: end, profile: end)
		XCTAssertEqual(expiry.daysLeft(now: end.addingTimeInterval(-7 * day)), 7)
		XCTAssertEqual(expiry.daysLeft(now: end.addingTimeInterval(-6.5 * day)), 7)
		XCTAssertEqual(expiry.daysLeft(now: end.addingTimeInterval(-60)), 1)
		XCTAssertEqual(expiry.daysLeft(now: end), 0)
		XCTAssertEqual(expiry.daysLeft(now: end.addingTimeInterval(day)), 0)
	}

	/// The fixture pair: its profile runs out on 1 Jan 2027, before its
	/// certificate.
	func testFromAProfileAndCertificate() throws {
		let stored = try Fixture.stored("development.mobileprovision")
		XCTAssertEqual(stored.expiry.part, .profile)
		XCTAssertEqual(stored.expiry.date, Fixture.utc(2027, 1, 1))
		XCTAssertGreaterThan(stored.certificate.notAfter, stored.profile.expirationDate)
		XCTAssertEqual(stored.expiry.warning(now: Fixture.utc(2026, 12, 25)), 7)
		XCTAssertEqual(stored.expiry.daysLeft(now: Fixture.utc(2026, 12, 25)), 7)
	}
}

final class CertificateAlertsTests: XCTestCase {
	let day: TimeInterval = 86_400

	/// The fixture pair, which expires (its profile) on 1 Jan 2027.
	func stored(revoked: Bool = false) throws -> StoredCertificate {
		var stored = try Fixture.stored("enterprise.mobileprovision")
		if revoked { stored.revocation = .checked(.revoked(at: Fixture.utc(2026, 12, 1)), at: Fixture.utc(2026, 12, 2)) }
		return stored
	}

	let end = Fixture.utc(2027, 1, 1)

	func testSchedulesEveryWarningAhead() throws {
		let certificate = try stored()
		let plan = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-30 * day), handled: [])
		XCTAssertEqual(plan.now, [])
		XCTAssertEqual(plan.scheduled.map(\.kind), [.expiring(days: 14), .expiring(days: 7), .expiring(days: 1), .expired])
		XCTAssertEqual(plan.scheduled.map(\.date), [end.addingTimeInterval(-14 * day), end.addingTimeInterval(-7 * day), end.addingTimeInterval(-day), end])
		XCTAssertEqual(plan.scheduled[1].title, "OwnStore Test (TESTTEAM01) expires in 7 days")
		XCTAssertEqual(plan.scheduled[2].title, "OwnStore Test (TESTTEAM01) expires within a day")
		XCTAssertTrue(plan.scheduled[0].body.hasPrefix("It expires on"))
		XCTAssertEqual(plan.handled, Set(plan.scheduled.map(\.identifier)))
	}

	/// Imported with 3 days left: the 7-day warning shows now, saying 3 days,
	/// and only once.
	func testShowsTheCurrentWarningOnce() throws {
		let certificate = try stored()
		let now = end.addingTimeInterval(-3 * day)
		let first = CertificateAlerts.plan(for: [certificate], now: now, handled: [])
		XCTAssertEqual(first.now.map(\.kind), [.expiring(days: 7)])
		XCTAssertEqual(first.now.first?.title, "OwnStore Test (TESTTEAM01) expires in 3 days")
		XCTAssertEqual(first.scheduled.map(\.kind), [.expiring(days: 1), .expired])

		let again = CertificateAlerts.plan(for: [certificate], now: now.addingTimeInterval(3600), handled: first.handled)
		XCTAssertEqual(again.now, [])
		XCTAssertEqual(again.scheduled.map(\.kind), [.expiring(days: 1), .expired])
	}

	/// A scheduled warning that went off isn't shown again when Atelier opens.
	func testScheduledWarningsCountAsShown() throws {
		let certificate = try stored()
		let before = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-30 * day), handled: [])
		let after = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-6 * day), handled: before.handled)
		XCTAssertEqual(after.now, [])
		let expired = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(day), handled: after.handled)
		XCTAssertEqual(expired.now, [])
		XCTAssertEqual(expired.scheduled, [])
	}

	func testExpiredWithoutWarningShowsExpiry() throws {
		let plan = CertificateAlerts.plan(for: [try stored()], now: end.addingTimeInterval(day), handled: [])
		XCTAssertEqual(plan.now.map(\.kind), [.expired])
		XCTAssertEqual(plan.now.first?.title, "OwnStore Test (TESTTEAM01) has expired")
	}

	func testRevokedReplacesExpiryWarnings() throws {
		let certificate = try stored(revoked: true)
		let plan = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-30 * day), handled: [])
		XCTAssertEqual(plan.now.map(\.kind), [.revoked])
		XCTAssertEqual(plan.now.first?.title, "OwnStore Test (TESTTEAM01) was revoked")
		XCTAssertEqual(plan.scheduled, [])
		XCTAssertEqual(CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-29 * day), handled: plan.handled).now, [])
	}

	func testForgetsDeletedCertificates() throws {
		let certificate = try stored()
		let plan = CertificateAlerts.plan(for: [certificate], now: end.addingTimeInterval(-30 * day), handled: ["certificate.\(UUID().uuidString).expired"])
		XCTAssertEqual(plan.handled.count, 4)
		XCTAssertEqual(CertificateAlerts.plan(for: [], now: .now, handled: plan.handled).handled, [])
	}
}

final class RevocationNotesTests: XCTestCase {
	func testRevokedAndExpiringNotes() throws {
		var certificate = try Fixture.stored("enterprise.mobileprovision")
		XCTAssertEqual(certificate.notes(now: Fixture.utc(2026, 12, 25)).map(\.kind), [.expiringSoon])
		XCTAssertTrue(certificate.notes(now: Fixture.utc(2026, 12, 25))[0].message.hasPrefix("This certificate expires in 7 days"))

		certificate.revocation = .checked(.revoked(at: nil), at: Fixture.utc(2026, 11, 1))
		XCTAssertEqual(certificate.notes(now: Fixture.utc(2026, 11, 2)).map(\.kind), [.revoked])
	}

	func testStoreKeepsRevocation() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("enterprise.mobileprovision"))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "enterprise.mobileprovision"))
		let stored = try store.add(validated, files: files, password: Fixture.password)
		XCTAssertNil(stored.revocation)

		let state = RevocationState.checked(.good, at: Fixture.utc(2026, 11, 1)).failed("offline", at: Fixture.utc(2026, 11, 2))
		try store.setRevocation(state, for: stored.id)
		let reopened = try CertificateStore(directory: directory, secrets: InMemoryCertificateSecrets())
		XCTAssertEqual(reopened.certificates.first?.revocation, state)
		XCTAssertEqual(state.status, .good)
		XCTAssertEqual(state.checkedAt, Fixture.utc(2026, 11, 1))
		XCTAssertEqual(state.error, "offline")
	}
}
