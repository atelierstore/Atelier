import Foundation
import XCTest
@testable import CertKit

/// The certificate the iPhone-only installer hands Atelier (#152).
final class InstallerCertificateTests: XCTestCase {
	var root: URL!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerCertificateTests-\(UUID().uuidString)")
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: root)
	}

	/// Application Support, as the installer finds it in Atelier's container.
	private var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }

	private func store() throws -> CertificateStore {
		try CertificateStore(directory: support.appendingPathComponent("Certificates", isDirectory: true), secrets: InMemoryCertificateSecrets())
	}

	private func certificateDER() throws -> Data {
		try ProvisioningProfile(data: Fixture.data("development.mobileprovision")).developerCertificates[0]
	}

	/// The installer's property list, as it writes it.
	private func plist(_ entries: [String: Any]? = nil) throws -> Data {
		let entries = try entries ?? [
			"teamID": "A1B2C3D4E5",
			"machineName": "Atelier Installer",
			"machineID": "0E5B1D2C-0000-4000-8000-000000000001",
			"serialNumber": Fixture.signingSerial,
			"certificate": certificateDER(),
			"privateKey": Data("installer key".utf8),
		]
		return try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
	}

	/// Writes `data` where the installer leaves it.
	@discardableResult
	private func leave(_ data: Data) throws -> URL {
		let url = InstallerCertificate.handoffURL(in: support)
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

	func testTheInstallerLeavesItNextToThePairingFile() {
		let url = InstallerCertificate.handoffURL(in: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Application Support"))
		XCTAssertEqual(url.path, "/var/mobile/Containers/Data/Application/X/Library/Application Support/Installer/certificate.plist")
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
