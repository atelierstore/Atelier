import Foundation
import XCTest
@testable import CertKit

/// The certificate the iPhone-only installer hands Atelier (#152).
final class InstallerCertificateTests: XCTestCase {
	var root: URL!
	/// The Keychain's Apple ID passwords and Apple's tokens, across
	/// launches.
	var passwords: InMemoryCertificateSecrets!
	var tokens: InMemoryCertificateSecrets!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerCertificateTests-\(UUID().uuidString)")
		passwords = InMemoryCertificateSecrets()
		tokens = InMemoryCertificateSecrets()
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: root)
	}

	/// Caches, as the installer finds it in Atelier's container.
	private var caches: URL { root.appendingPathComponent("Caches", isDirectory: true) }

	private func store() throws -> CertificateStore {
		try CertificateStore(
			directory: root.appendingPathComponent("Application Support/Certificates", isDirectory: true),
			secrets: InMemoryCertificateSecrets(),
			appleIDPasswords: passwords,
			appleIDTokens: tokens
		)
	}

	private func certificateDER() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("development.mobileprovision")).developerCertificates[0]
	}

	/// The installer's property list, as it writes it.
	private func plist(_ entries: [String: Any]? = nil) throws -> Data {
		let entries = try entries ?? certificateEntries()
		return try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
	}

	private func certificateEntries() throws -> [String: Any] {
		try [
			"teamID": "A1B2C3D4E5",
			"machineName": "Atelier Installer",
			"machineID": "0E5B1D2C-0000-4000-8000-000000000001",
			"serialNumber": Fixture.signingSerial,
			"certificate": certificateDER(),
			"privateKey": Data("installer key".utf8),
		]
	}

	/// What the installer adds for Atelier to sign in by itself.
	private let signInEntries: [String: Any] = [
		"appleID": "alex.test@icloud.com",
		"password": "installer password",
		"udid": "00008110-000A1B2C3D4E801E",
		"anisetteServer": "https://ani.example.com",
		"anisetteState": Data("<plist><dict/></plist>".utf8),
	]

	private var handedOverSignIn: InstallerCertificate.SignIn {
		InstallerCertificate.SignIn(
			appleID: "alex.test@icloud.com",
			password: "installer password",
			udid: "00008110-000A1B2C3D4E801E",
			anisetteServer: "https://ani.example.com",
			anisetteState: Data("<plist><dict/></plist>".utf8)
		)
	}

	private func plistSigningIn() throws -> Data {
		try plist(certificateEntries().merging(signInEntries) { $1 })
	}

	/// What the installer's version 2 has in the password's place (#182),
	/// as atelier-install writes it.
	private let tokenEntries: [String: Any] = [
		"version": 2,
		"adsid": "000123-45-6789",
		"token": "not a real token",
		"tokenDuration": 31_536_000,
		"tokenExpiry": 1_826_036_000_000 as UInt64,
		"tokenReceived": Date(timeIntervalSince1970: 1_794_500_000),
		"clientInfo": "<MacBookPro13,2> <macOS;13.1;22C65>",
		"userAgent": "akd/1.0",
	]

	private var handedOverToken: AppleIDToken {
		AppleIDToken(
			adsid: "000123-45-6789",
			token: "not a real token",
			duration: 31_536_000,
			expiry: 1_826_036_000_000,
			receivedAt: Date(timeIntervalSince1970: 1_794_500_000),
			server: "https://ani.example.com",
			clientInfo: "<MacBookPro13,2> <macOS;13.1;22C65>",
			userAgent: "akd/1.0"
		)
	}

	/// Version 2's sign-in: the token, and no password.
	private func plistWithToken() throws -> Data {
		var entries = try certificateEntries().merging(signInEntries) { $1 }.merging(tokenEntries) { $1 }
		entries["password"] = nil
		return try plist(entries)
	}

	private var handedOverTokenSignIn: InstallerCertificate.SignIn {
		var signIn = handedOverSignIn
		signIn.password = nil
		signIn.token = handedOverToken
		return signIn
	}

	/// Writes `data` where the installer leaves it.
	@discardableResult
	private func leave(_ data: Data) throws -> URL {
		let url = InstallerCertificate.handoffURL(in: caches)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url)
		return url
	}

	func testReadsWhatTheInstallerWrites() throws {
		let read = try InstallerCertificate(plist: plist())
		XCTAssertEqual(read.teamID, "A1B2C3D4E5")
		XCTAssertEqual(read.privateKey, Data("installer key".utf8))
		XCTAssertEqual(read.machineName, "Atelier Installer")
		XCTAssertEqual(read.serialNumber, Fixture.signingSerial)
		XCTAssertEqual(read.certificate?.serialNumber, Fixture.signingSerial)
	}

	func testNeedsTheTeamAndTheKeyOnly() throws {
		let bare = try InstallerCertificate(plist: plist(["teamID": "A1B2C3D4E5", "privateKey": Data("installer key".utf8)]))
		XCTAssertEqual(bare, InstallerCertificate(teamID: "A1B2C3D4E5", privateKey: Data("installer key".utf8)))
		// A certificate that can't be read is left out rather than refused,
		// as Atelier finds Apple's by the key.
		let damaged = try InstallerCertificate(plist: plist(["teamID": "A1B2C3D4E5", "privateKey": Data("k".utf8), "certificate": Data("not DER".utf8)]))
		XCTAssertNil(damaged.certificate)

		XCTAssertThrowsError(try InstallerCertificate(plist: plist(["privateKey": Data("k".utf8)]))) { error in
			XCTAssertEqual(error as? InstallerCertificate.Problem, .missing("teamID"))
		}
		XCTAssertThrowsError(try InstallerCertificate(plist: plist(["teamID": " ", "privateKey": Data("k".utf8)]))) { error in
			XCTAssertEqual(error as? InstallerCertificate.Problem, .missing("teamID"))
		}
		XCTAssertThrowsError(try InstallerCertificate(plist: plist(["teamID": "A1B2C3D4E5", "privateKey": Data()]))) { error in
			XCTAssertEqual(error as? InstallerCertificate.Problem, .missing("privateKey"))
		}
		XCTAssertThrowsError(try InstallerCertificate(plist: Data("not a plist".utf8))) { error in
			XCTAssertEqual(error as? InstallerCertificate.Problem, .unreadable)
		}
	}

	func testReadsTheSignIn() throws {
		XCTAssertNil(try InstallerCertificate(plist: plist()).signIn)
		XCTAssertEqual(try InstallerCertificate(plist: plistSigningIn()).signIn, handedOverSignIn)
		// The Apple ID and its password are enough.
		var entries = try certificateEntries()
		entries["appleID"] = "alex.test@icloud.com"
		entries["password"] = "installer password"
		XCTAssertEqual(try InstallerCertificate(plist: plist(entries)).signIn, InstallerCertificate.SignIn(appleID: "alex.test@icloud.com", password: "installer password"))
		// Without either, there's nothing to sign in with.
		entries["password"] = ""
		XCTAssertNil(try InstallerCertificate(plist: plist(entries)).signIn)
		XCTAssertEqual(try InstallerCertificate(plist: plist(entries), password: "kept").signIn?.password, "kept", "the one in the Keychain")
		entries["appleID"] = " "
		XCTAssertNil(try InstallerCertificate(plist: plist(entries), password: "kept").signIn)
	}

	func testReadsVersion2sTokenInThePasswordsPlace() throws {
		let read = try InstallerCertificate(plist: plistWithToken())
		XCTAssertEqual(read.signIn, handedOverTokenSignIn)
		XCTAssertEqual(read.signIn?.token?.endsAt, Date(timeIntervalSince1970: 1_826_036_000))
		XCTAssertEqual(read.teamID, "A1B2C3D4E5")

		// Without the server it came through, whose machine Apple knows it
		// by, or without the adsid, there's no token, so no sign-in.
		var entries = try certificateEntries().merging(signInEntries) { $1 }.merging(tokenEntries) { $1 }
		entries["password"] = nil
		entries["anisetteServer"] = nil
		XCTAssertNil(try InstallerCertificate(plist: plist(entries)).signIn)
		entries["anisetteServer"] = "https://ani.example.com"
		entries["adsid"] = ""
		XCTAssertNil(try InstallerCertificate(plist: plist(entries)).signIn)

		// What Apple didn't say is 0, and its end then unknown.
		entries["adsid"] = "000123-45-6789"
		for key in ["tokenDuration", "tokenExpiry", "clientInfo", "userAgent"] { entries[key] = nil }
		let bare = try XCTUnwrap(InstallerCertificate(plist: plist(entries)).signIn?.token)
		XCTAssertEqual([bare.duration, bare.expiry], [0, 0])
		XCTAssertNil(bare.endsAt)
		XCTAssertNil(bare.clientInfo)
		XCTAssertEqual(InstallerCertificate.sideloadVersion, 2, "as Atelier's Info.plist says, in SideloadHandOff")
	}

	func testTheTokenGoesToTheKeychain() throws {
		let store = try store()
		let kept = try store.keepInstallerCertificate(from: leave(plistWithToken()))
		XCTAssertEqual(kept?.signIn, handedOverTokenSignIn)
		XCTAssertNotNil(try tokens.password(for: CertificateStore.installerPasswordID))
		XCTAssertNil(try passwords.password(for: CertificateStore.installerPasswordID))
		let file = root.appendingPathComponent("Application Support/Certificates/Installer/certificate.plist")
		let written = try String(contentsOf: file, encoding: .utf8)
		XCTAssertFalse(written.contains("not a real token"), "not in the file")
		for key in InstallerCertificate.tokenKeys {
			XCTAssertFalse(written.contains("<key>\(key)</key>"), key)
		}
		XCTAssertEqual(try self.store().installerCertificate?.signIn, handedOverTokenSignIn, "kept across launches")

		// Tried once, it goes, and a later run's version 1 leaves none.
		store.forgetInstallerSignIn()
		XCTAssertNil(store.installerCertificate?.signIn)
		XCTAssertNil(try tokens.password(for: CertificateStore.installerPasswordID))
		try store.keepInstallerCertificate(from: leave(plistWithToken()))
		try store.keepInstallerCertificate(from: leave(plistSigningIn()))
		XCTAssertEqual(store.installerCertificate?.signIn, handedOverSignIn)
		XCTAssertNil(try tokens.password(for: CertificateStore.installerPasswordID))
		try store.keepInstallerCertificate(from: leave(plistWithToken()))
		store.forgetInstallerCertificate()
		XCTAssertNil(try tokens.password(for: CertificateStore.installerPasswordID))
	}

	func testThePasswordGoesToTheKeychain() throws {
		let store = try store()
		let left = try leave(plistSigningIn())

		let kept = try store.keepInstallerCertificate(from: left)
		XCTAssertEqual(kept?.signIn, handedOverSignIn)
		XCTAssertEqual(try passwords.password(for: CertificateStore.installerPasswordID), "installer password")
		let file = root.appendingPathComponent("Application Support/Certificates/Installer/certificate.plist")
		XCTAssertNil(try InstallerCertificate.dictionary(Data(contentsOf: file))["password"], "not in the file")
		XCTAssertEqual(try self.store().installerCertificate?.signIn, handedOverSignIn, "kept across launches")
	}

	func testTheSignInIsForgottenOnceTriedAndTheCertificateStays() throws {
		let store = try store()
		try store.keepInstallerCertificate(from: leave(plistSigningIn()))

		store.forgetInstallerSignIn()
		XCTAssertNil(store.installerCertificate?.signIn)
		XCTAssertEqual(store.installerCertificate?.teamID, "A1B2C3D4E5")
		XCTAssertEqual(store.installerCertificate?.serialNumber, Fixture.signingSerial)
		XCTAssertNil(try passwords.password(for: CertificateStore.installerPasswordID))
		let file = root.appendingPathComponent("Application Support/Certificates/Installer/certificate.plist")
		let left = try InstallerCertificate.dictionary(Data(contentsOf: file))
		for key in InstallerCertificate.signInKeys {
			XCTAssertNil(left[key], key)
		}
		XCTAssertEqual(left["machineID"] as? String, "0E5B1D2C-0000-4000-8000-000000000001")
	}

	func testForgettingTheCertificateForgetsThePasswordToo() throws {
		let store = try store()
		try store.keepInstallerCertificate(from: leave(plistSigningIn()))
		store.forgetInstallerCertificate()
		XCTAssertNil(store.installerCertificate)
		XCTAssertNil(try passwords.password(for: CertificateStore.installerPasswordID))

		// A later run without a sign-in leaves no password from before.
		try store.keepInstallerCertificate(from: leave(plistSigningIn()))
		try store.keepInstallerCertificate(from: leave(plist()))
		XCTAssertNil(store.installerCertificate?.signIn)
		XCTAssertNil(try passwords.password(for: CertificateStore.installerPasswordID))
	}

	func testTheInstallerLeavesItInCaches() {
		let url = InstallerCertificate.handoffURL(in: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Caches"))
		XCTAssertEqual(url.path, "/var/mobile/Containers/Data/Application/X/Library/Caches/Installer/certificate.plist")
		XCTAssertEqual(InstallerCertificate.version, 1, "as Atelier's Info.plist says, in AtelierInstallerHandOff")
	}

	func testMovesItIntoTheStore() throws {
		let store = try store()
		XCTAssertNil(store.installerCertificate)
		let left = try leave(plist())

		let kept = try store.keepInstallerCertificate(from: left)
		XCTAssertEqual(kept?.teamID, "A1B2C3D4E5")
		XCTAssertEqual(store.installerCertificate, kept)
		XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "only the store has it now")
		XCTAssertFalse(FileManager.default.fileExists(atPath: left.deletingLastPathComponent().path), "the installer's folder goes with it")
		XCTAssertEqual(try self.store().installerCertificate, kept, "kept across launches")

		// Nothing more until the installer runs again.
		XCTAssertNil(try store.keepInstallerCertificate(from: left))
		XCTAssertEqual(store.installerCertificate, kept)
	}

	func testALaterOneReplacesItAndForgettingRemovesIt() throws {
		let store = try store()
		try store.keepInstallerCertificate(from: leave(plist()))
		try store.keepInstallerCertificate(from: leave(plist(["teamID": "F6G7H8J9K0", "privateKey": Data("newer key".utf8)])))
		XCTAssertEqual(store.installerCertificate, InstallerCertificate(teamID: "F6G7H8J9K0", privateKey: Data("newer key".utf8)))

		store.forgetInstallerCertificate()
		XCTAssertNil(store.installerCertificate)
		XCTAssertNil(try self.store().installerCertificate)
	}

	func testOneThatCantBeReadIsRemovedAndTheOneKeptStays() throws {
		let store = try store()
		try store.keepInstallerCertificate(from: leave(plist()))
		let kept = store.installerCertificate
		let damaged = try leave(Data("not a plist".utf8))

		XCTAssertThrowsError(try store.keepInstallerCertificate(from: damaged))
		XCTAssertFalse(FileManager.default.fileExists(atPath: damaged.path))
		XCTAssertEqual(store.installerCertificate, kept)
	}
}
