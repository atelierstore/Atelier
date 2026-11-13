import Foundation

/// An imported certificate and profile pair.
public struct StoredCertificate: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var addedAt: Date
	public var certificate: SigningCertificate
	public var profile: ProvisioningProfile
	/// The last revocation check (#5), nil until one ran.
	public var revocation: RevocationState? = nil
	/// When an install signed with this pair's profile was first confirmed
	/// on this device (#45). iOS only installs development and ad hoc apps
	/// on devices their profile lists, so this device is one of them. Kept
	/// per profile: every pair with the same profile UUID shares it.
	public var deviceConfirmedAt: Date? = nil
	/// A name the user gave the pair, shown instead of the certificate's own.
	public var customName: String? = nil

	/// The user's name for the pair, or else the certificate's own.
	public var displayName: String {
		customName ?? originalName
	}

	/// The certificate's name without Apple's "Apple Distribution: " style prefix.
	public var originalName: String {
		let name = certificate.commonName
		guard let colon = name.firstIndex(of: ":") else { return name }
		return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
	}

	/// Whichever of the certificate and profile runs out first.
	public var expiresAt: Date { min(certificate.notAfter, profile.expirationDate) }
}

/// Where a certificate's .p12 password lives: the Keychain in the app,
/// memory in tests.
public protocol CertificateSecrets: AnyObject {
	func setPassword(_ password: String, for id: UUID) throws
	func password(for id: UUID) throws -> String?
	func deletePassword(for id: UUID) throws
	/// Gives the passwords of `ids` the current `SecretProtection`.
	func reprotect(_ ids: [UUID]) throws
}

public extension CertificateSecrets {
	func reprotect(_ ids: [UUID]) throws {}
}

/// Keeps imported certificates on the device: each pair's files in its own
/// folder under `directory`, the .p12 password in `secrets`, and an index
/// listing them and which one is the default. Apple IDs signed in with
/// (#49) are kept the same way: their certificate's .p12 and key in a
/// folder of their own, the .p12's password in `secrets`, the Apple ID's
/// own password in `appleIDPasswords` and Apple's token for signing in
/// again in `appleIDTokens` (#182). The default is one of either.
///
/// The files are written with complete file protection (readable only while
/// the device is unlocked), or "after first unlock" while automatic updates
/// need it (`SecretProtection`, #72), and the folder is excluded from
/// backups, so they never leave the device.
public final class CertificateStore {
	public let directory: URL
	private let secrets: CertificateSecrets
	private let appleIDPasswords: CertificateSecrets
	private let appleIDTokens: CertificateSecrets
	private var index: Index

	private struct Index: Codable {
		var version = 1
		var defaultID: UUID?
		var certificates: [StoredCertificate] = []
		/// Apple IDs signed in with (#49), which earlier files don't have.
		var appleIDs: [StoredAppleID] = []

		init() {}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
			defaultID = try container.decodeIfPresent(UUID.self, forKey: .defaultID)
			certificates = try container.decodeIfPresent([StoredCertificate].self, forKey: .certificates) ?? []
			appleIDs = try container.decodeIfPresent([StoredAppleID].self, forKey: .appleIDs) ?? []
		}

		/// What takes over from one deleted while in use: the oldest
		/// imported pair, else the oldest Apple ID.
		var firstID: UUID? { certificates.first?.id ?? appleIDs.first?.id }

		/// Whether `id` is a pair's or an Apple ID's it lists.
		func has(_ id: UUID?) -> Bool {
			guard let id else { return false }
			return certificates.contains { $0.id == id } || appleIDs.contains { $0.id == id }
		}
	}

	static let p12FileName = "certificate.p12"
	static let profileFileName = "profile.mobileprovision"
	private var indexURL: URL { directory.appendingPathComponent("index.json") }

	/// Tests may leave `appleIDPasswords` and `appleIDTokens` out, keeping
	/// them in memory.
	public init(directory: URL, secrets: CertificateSecrets, appleIDPasswords: CertificateSecrets = InMemoryCertificateSecrets(), appleIDTokens: CertificateSecrets = InMemoryCertificateSecrets()) throws {
		self.directory = directory
		self.secrets = secrets
		self.appleIDPasswords = appleIDPasswords
		self.appleIDTokens = appleIDTokens
		let manager = FileManager.default
		if !manager.fileExists(atPath: directory.path) {
			var attributes: [FileAttributeKey: Any] = [:]
			#if os(iOS)
			attributes[.protectionKey] = SecretProtection.fileProtection
			#endif
			try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
		}
		#if !os(Linux)
		var folder = directory
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try folder.setResourceValues(values)
		#endif
		if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")) {
			index = try JSONDecoder().decode(Index.self, from: data)
		} else {
			index = Index()
		}
	}

	/// Oldest first.
	public var certificates: [StoredCertificate] { index.certificates }

	public var defaultID: UUID? { index.defaultID }

	/// The imported pair in use; nil when an Apple ID is.
	public var defaultCertificate: StoredCertificate? {
		index.certificates.first { $0.id == index.defaultID }
	}

	/// Saves a validated pair, under `name` if one is given. The first one
	/// becomes the default. With `id`, it's saved under that ID unless a
	/// pair has it already: a deleted pair imported again gets its ID back,
	/// so the apps signed with it find it again (#126).
	@discardableResult
	public func add(_ validated: ValidatedCertificate, files: CertificateFiles, password: String, name: String? = nil, id: UUID? = nil, now: Date = .now) throws -> StoredCertificate {
		guard let p12 = files.p12?.data, let profile = files.profile?.data else {
			throw files.p12 == nil ? CertificateImportError.missingP12 : CertificateImportError.missingProfile
		}
		if index.certificates.contains(where: {
			$0.certificate.der == validated.certificate.der && $0.profile.uuid == validated.profile.uuid
		}) {
			throw CertificateImportError.alreadyImported(validated.certificate.commonName)
		}

		let free = id.flatMap { id in index.certificates.contains { $0.id == id } ? nil : id }
		var stored = StoredCertificate(id: free ?? UUID(), addedAt: now, certificate: validated.certificate, profile: validated.profile)
		stored.deviceConfirmedAt = index.certificates.first { $0.profile.uuid == validated.profile.uuid }?.deviceConfirmedAt
		stored.customName = Self.cleanName(name)
		let folder = folder(for: stored.id)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try write(p12, to: folder.appendingPathComponent(Self.p12FileName))
			try write(profile, to: folder.appendingPathComponent(Self.profileFileName))
			try secrets.setPassword(password, for: stored.id)
			var updated = index
			updated.certificates.append(stored)
			if updated.defaultID == nil { updated.defaultID = stored.id }
			try save(updated)
		} catch {
			try? FileManager.default.removeItem(at: folder)
			try? secrets.deletePassword(for: stored.id)
			throw CertificateImportError.storageFailed(error.localizedDescription)
		}
		return stored
	}

	/// Removes a pair, its files and its password. If it was the default,
	/// the oldest remaining one takes over, an imported one first.
	public func delete(_ id: UUID) throws {
		var updated = index
		updated.certificates.removeAll { $0.id == id }
		if updated.defaultID == id { updated.defaultID = updated.firstID }
		try save(updated)
		try? FileManager.default.removeItem(at: folder(for: id))
		try? secrets.deletePassword(for: id)
	}

	public func setDefault(_ id: UUID) throws {
		guard index.certificates.contains(where: { $0.id == id }) || index.appleIDs.contains(where: { $0.id == id }) else { return }
		var updated = index
		updated.defaultID = id
		try save(updated)
	}

	/// Names a pair; an empty or nil name goes back to the certificate's own.
	public func setName(_ name: String?, for id: UUID) throws {
		guard let position = index.certificates.firstIndex(where: { $0.id == id }) else { return }
		var updated = index
		updated.certificates[position].customName = Self.cleanName(name)
		try save(updated)
	}

	static func cleanName(_ name: String?) -> String? {
		guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
		return trimmed
	}

	/// Records a revocation check (#5). Does nothing if the pair was deleted
	/// while it ran.
	public func setRevocation(_ state: RevocationState, for id: UUID) throws {
		guard let position = index.certificates.firstIndex(where: { $0.id == id }) else { return }
		var updated = index
		updated.certificates[position].revocation = state
		try save(updated)
	}

	/// Records that an app signed with a certificate installed on this
	/// device (#45), for every pair with that certificate's profile. Keeps
	/// the first date; does nothing if the pair was deleted meanwhile.
	public func setDeviceConfirmed(for id: UUID, at date: Date = .now) throws {
		guard let uuid = index.certificates.first(where: { $0.id == id })?.profile.uuid else { return }
		var updated = index
		var changed = false
		for position in updated.certificates.indices where updated.certificates[position].profile.uuid == uuid && updated.certificates[position].deviceConfirmedAt == nil {
			updated.certificates[position].deviceConfirmedAt = date
			changed = true
		}
		if changed { try save(updated) }
	}

	// What signing (#6) needs.

	public func p12URL(for id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.p12FileName) }

	public func profileURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.profileFileName) }

	public func password(for id: UUID) throws -> String? { try secrets.password(for: id) }

	/// Gives every file and password the current `SecretProtection`, after
	/// it changed (#72). Only works while the device is unlocked. Apple IDs'
	/// own passwords and tokens are always readable after first unlock.
	public func reprotect() throws {
		#if os(iOS)
		try SecretProtection.apply(to: directory)
		#endif
		try secrets.reprotect(index.certificates.map(\.id) + index.appleIDs.map(\.id))
	}

	// MARK: Apple IDs (#49)

	/// Oldest first.
	public var appleIDs: [StoredAppleID] { index.appleIDs }

	/// The Apple ID in use; nil when an imported pair is.
	public var defaultAppleID: StoredAppleID? {
		index.appleIDs.first { $0.id == index.defaultID }
	}

	/// The one kept for the Apple ID `email` in the team `teamID`, which
	/// signing in again replaces.
	public func appleID(email: String, teamID: String) -> StoredAppleID? {
		index.appleIDs.first { $0.isSame(email: email, teamID: teamID) }
	}

	/// Where the certificate's key is kept for the Apple ID `id`, made if
	/// needed, before the Apple ID is saved: isideload makes the key there
	/// and finds the certificate again with it at the next sign-in.
	public func keysFolder(for id: UUID) throws -> URL {
		let keys = folder(for: id).appendingPathComponent("keys", isDirectory: true)
		var attributes: [FileAttributeKey: Any] = [:]
		#if os(iOS)
		attributes[.protectionKey] = SecretProtection.fileProtection
		#endif
		try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true, attributes: attributes)
		return keys
	}

	/// Saves an Apple ID once signed in: its certificate's .p12, locked with
	/// `p12Password`, its `password`, and Apple's `token` from the sign-in
	/// (#182), which takes the place of one kept before, or deletes it when
	/// nil. One saved before with the same ID is replaced. It's put in use
	/// with `use`, or when nothing is.
	@discardableResult
	public func saveAppleID(_ account: StoredAppleID, p12: Data, p12Password: String, password: String, token: AppleIDToken? = nil, use: Bool = false) throws -> StoredAppleID {
		let folder = folder(for: account.id)
		let existing = index.appleIDs.firstIndex { $0.id == account.id }
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try write(p12, to: folder.appendingPathComponent(Self.p12FileName))
			try secrets.setPassword(p12Password, for: account.id)
			try appleIDPasswords.setPassword(password, for: account.id)
			try writeToken(token, for: account.id)
			var updated = index
			if let existing {
				// Its apps' profiles and its limits outlast a sign-in again.
				var account = account
				account.profiles = account.profiles ?? updated.appleIDs[existing].profiles
				account.limits = account.limits ?? updated.appleIDs[existing].limits
				updated.appleIDs[existing] = account
			} else {
				updated.appleIDs.append(account)
			}
			if use || updated.defaultID == nil || !updated.has(updated.defaultID) { updated.defaultID = account.id }
			try save(updated)
		} catch {
			// A new one leaves nothing behind; one saved before keeps what
			// it had, short of what this wrote over.
			if existing == nil {
				try? FileManager.default.removeItem(at: folder)
				try? secrets.deletePassword(for: account.id)
				try? appleIDPasswords.deletePassword(for: account.id)
				try? appleIDTokens.deletePassword(for: account.id)
			}
			throw CertificateImportError.storageFailed(error.localizedDescription)
		}
		return account
	}

	/// Signs out of an Apple ID: removes it, its certificate's .p12 and key,
	/// both passwords and Apple's token. It doesn't revoke the certificate,
	/// so apps signed with it open until their profiles run out. If it was
	/// in use, the oldest remaining certificate takes over, an imported one
	/// first.
	public func deleteAppleID(_ id: UUID) throws {
		var updated = index
		updated.appleIDs.removeAll { $0.id == id }
		if updated.defaultID == id { updated.defaultID = updated.firstID }
		try save(updated)
		try? FileManager.default.removeItem(at: folder(for: id))
		try? secrets.deletePassword(for: id)
		try? appleIDPasswords.deletePassword(for: id)
		try? appleIDTokens.deletePassword(for: id)
	}

	/// The Apple ID's own password, for signing in again.
	public func appleIDPassword(for id: UUID) throws -> String? { try appleIDPasswords.password(for: id) }

	/// Apple's token for signing in again as the Apple ID `id` without the
	/// password (#182); nil when none is kept, or what's kept can't be read.
	public func appleIDToken(for id: UUID) throws -> AppleIDToken? {
		guard let kept = try appleIDTokens.password(for: id) else { return nil }
		return try? JSONDecoder().decode(AppleIDToken.self, from: Data(kept.utf8))
	}

	/// Keeps `token` for the Apple ID `id`, in place of the one before, as
	/// after a sign-in with the password; nil deletes it, as once Apple
	/// refused it. Nothing is kept for an Apple ID signed out of meanwhile.
	public func setAppleIDToken(_ token: AppleIDToken?, for id: UUID) throws {
		guard token == nil || index.appleIDs.contains(where: { $0.id == id }) else { return }
		try writeToken(token, for: id)
	}

	private func writeToken(_ token: AppleIDToken?, for id: UUID) throws {
		guard let token else {
			try appleIDTokens.deletePassword(for: id)
			return
		}
		try appleIDTokens.setPassword(String(decoding: try JSONEncoder().encode(token), as: UTF8.self), for: id)
	}

	// MARK: The installer's certificate (#152)

	private var installerCertificateURL: URL {
		directory.appendingPathComponent("Installer", isDirectory: true).appendingPathComponent(InstallerCertificate.fileName)
	}

	/// Where the installer's Apple ID password is kept, in the Keychain with
	/// the Apple IDs' own, until Atelier has signed in with it once.
	static let installerPasswordID = UUID(uuidString: "77FD900F-A271-468B-B0A6-986A29AB60B5")!

	/// The certificate the iPhone-only installer left for Atelier, kept
	/// until an Apple ID of its team signs in, with the installer's sign-in
	/// until Atelier has tried it; nil when there's none.
	public var installerCertificate: InstallerCertificate? {
		guard let data = try? Data(contentsOf: installerCertificateURL) else { return nil }
		return try? InstallerCertificate(plist: data, password: try? appleIDPasswords.password(for: Self.installerPasswordID))
	}

	/// Moves the certificate the installer left at `url` (`InstallerCertificate.handoffURL`)
	/// into the store, written as the certificates' keys are, and its
	/// sign-in's password into the Keychain, replacing what was kept before.
	/// One that can't be read is removed too, as it's no use. Nil when
	/// there's nothing at `url`.
	@discardableResult
	public func keepInstallerCertificate(from url: URL) throws -> InstallerCertificate? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		let data = try Data(contentsOf: url)
		let certificate: InstallerCertificate
		let kept: Data
		do {
			certificate = try InstallerCertificate(plist: data)
			kept = try InstallerCertificate.plist(data, leavingOut: [InstallerCertificate.passwordKey])
		} catch {
			Self.remove(url)
			throw error
		}
		if let password = certificate.signIn?.password {
			try appleIDPasswords.setPassword(password, for: Self.installerPasswordID)
		} else {
			try? appleIDPasswords.deletePassword(for: Self.installerPasswordID)
		}
		var attributes: [FileAttributeKey: Any] = [:]
		#if os(iOS)
		attributes[.protectionKey] = SecretProtection.fileProtection
		#endif
		try FileManager.default.createDirectory(at: installerCertificateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: attributes)
		try write(kept, to: installerCertificateURL)
		Self.remove(url)
		return certificate
	}

	/// Once Atelier tried the installer's sign-in: its password leaves the
	/// Keychain, and the certificate stays for an Apple ID of its team.
	public func forgetInstallerSignIn() {
		try? appleIDPasswords.deletePassword(for: Self.installerPasswordID)
		guard let data = try? Data(contentsOf: installerCertificateURL),
		      let kept = try? InstallerCertificate.plist(data, leavingOut: InstallerCertificate.signInKeys)
		else { return }
		try? write(kept, to: installerCertificateURL)
	}

	/// Once an Apple ID of its team signed in, or Apple no longer lists it.
	public func forgetInstallerCertificate() {
		try? appleIDPasswords.deletePassword(for: Self.installerPasswordID)
		Self.remove(installerCertificateURL)
	}

	/// Removes the file at `url`, and its folder once that's empty.
	private static func remove(_ url: URL) {
		let manager = FileManager.default
		try? manager.removeItem(at: url)
		let folder = url.deletingLastPathComponent()
		if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
			try? manager.removeItem(at: folder)
		}
	}

	/// Records a revocation check (#5) of an Apple ID's certificate. Does
	/// nothing if it was signed out of while it ran.
	public func setAppleIDRevocation(_ state: RevocationState, for id: UUID) throws {
		try updateAppleID(id) { $0.revocation = state }
	}

	/// Changes what's kept about the Apple ID `id`, such as an app's new
	/// profile or what Apple said about its limits. Does nothing if it was
	/// signed out of meanwhile, or nothing changed.
	public func updateAppleID(_ id: UUID, _ change: (inout StoredAppleID) -> Void) throws {
		guard let position = index.appleIDs.firstIndex(where: { $0.id == id }) else { return }
		var updated = index
		change(&updated.appleIDs[position])
		guard updated.appleIDs[position] != index.appleIDs[position] else { return }
		try save(updated)
	}

	// MARK: Files

	private func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }

	private func save(_ updated: Index) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try write(encoder.encode(updated), to: indexURL)
		index = updated
	}

	private func write(_ data: Data, to url: URL) throws {
		#if os(iOS)
		try data.write(to: url, options: SecretProtection.writingOptions)
		#else
		try data.write(to: url, options: .atomic)
		#endif
	}
}

/// Passwords kept in memory, for tests and previews.
public final class InMemoryCertificateSecrets: CertificateSecrets {
	private var passwords: [UUID: String] = [:]

	public init() {}

	public func setPassword(_ password: String, for id: UUID) throws { passwords[id] = password }
	public func password(for id: UUID) throws -> String? { passwords[id] }
	public func deletePassword(for id: UUID) throws { passwords[id] = nil }
}
