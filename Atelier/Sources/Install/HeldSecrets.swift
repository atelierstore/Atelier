import CertKit
import Foundation
import InstallKit
import SigningKit
import UIKit

/// What a round of direct installs needs if the iPhone locks before it ends
/// (#72): the certificates it signs with and the pairing file, read when
/// each install is queued, while the iPhone is unlocked. On disk they're
/// only readable while it's unlocked, unless automatic updates relaxed that
/// (`SecretProtection`).
///
/// The pairing file stays in memory. Signing needs files, so a held
/// certificate is written to Atelier's own temporary folder for each
/// signing, locked or not, since iOS only reports the lock about 10 s
/// after it and zsign reads the .p12 well into the signing: readable after
/// first unlock (never before), left out of backups, and deleted as soon as
/// that signing ends, however it ends. Anything left by Atelier being
/// ended mid-signing is deleted at the next launch.
@MainActor
final class HeldSecrets {
	static let shared = HeldSecrets()

	private struct Certificate {
		var p12: Data
		var profile: Data
		var password: String
	}

	private var certificates: [UUID: Certificate] = [:]
	private(set) var pairingFile: Data?

	private nonisolated static var folder: URL {
		FileManager.default.temporaryDirectory.appending(path: "HeldCertificates", directoryHint: .isDirectory)
	}

	/// Whether the stored certificates and pairing file can't be read now.
	static var lockedOut: Bool {
		!UIApplication.shared.isProtectedDataAvailable && !SecretProtection.readableAfterFirstUnlock
	}

	/// Reads the certificate `id` and the pairing file, if not held already.
	func hold(certificate id: UUID?, from model: CertificatesModel) {
		guard !Self.lockedOut else { return }
		if let id, certificates[id] == nil, let identity = try? model.signingIdentity(for: id),
		   let p12 = try? Data(contentsOf: identity.p12), let profile = try? Data(contentsOf: identity.profile) {
			certificates[id] = Certificate(p12: p12, profile: profile, password: identity.password)
		}
		if pairingFile == nil, let store = try? PairingFileStore.standard(), store.exists {
			pairingFile = try? store.load()
		}
	}

	func holds(certificate id: UUID) -> Bool {
		certificates[id] != nil
	}

	/// Writes the held certificate `id` for one signing; nil when it isn't
	/// held. The caller deletes it with `deleteWritten()` once signed.
	func writeIdentity(for id: UUID) throws -> SigningIdentity? {
		guard let held = certificates[id] else { return nil }
		let manager = FileManager.default
		var root = Self.folder
		try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try root.setResourceValues(values)
		let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		do {
			try manager.createDirectory(at: folder, withIntermediateDirectories: true)
			let p12 = folder.appending(path: "certificate.p12")
			let profile = folder.appending(path: "profile.mobileprovision")
			try held.p12.write(to: p12, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			try held.profile.write(to: profile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			return SigningIdentity(p12: p12, profile: profile, password: held.password)
		} catch {
			try? manager.removeItem(at: folder)
			throw error
		}
	}

	/// Deletes every certificate written for signing.
	nonisolated static func deleteWritten() {
		try? FileManager.default.removeItem(at: folder)
	}

	/// Forgets everything held, as the round ended.
	func release() {
		certificates = [:]
		pairingFile = nil
		Self.deleteWritten()
	}
}
