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
/// folder of their own, the .p12's password in `secrets` and the Apple
/// ID's own password in `appleIDPasswords`. The default is one of either.
///
/// The files are written with complete file protection (readable only while
/// the device is unlocked), or "after first unlock" while automatic updates
/// need it (`SecretProtection`, #72), and the folder is excluded from
/// backups, so they never leave the device.
public final class CertificateStore {
	public let directory: URL
	private let secrets: CertificateSecrets
	private let appleIDPasswords: CertificateSecrets
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

	/// Tests may leave `appleIDPasswords` out, keeping them in memory.
	public init(directory: URL, secrets: CertificateSecrets, appleIDPasswords: CertificateSecrets = InMemoryCertificateSecrets()) throws {
		self.directory = directory
		self.secrets = secrets
		self.appleIDPasswords = appleIDPasswords
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
	/// own passwords are always readable after first unlock.
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
	/// `p12Password`, and its `password`. One saved before with the same ID
	/// is replaced. It's put in use with `use`, or when nothing is.
	@discardableResult
	public func saveAppleID(_ account: StoredAppleID, p12: Data, p12Password: String, password: String, use: Bool = false) throws -> StoredAppleID {
		let folder = folder(for: account.id)
		let existing = index.appleIDs.firstIndex { $0.id == account.id }
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try write(p12, to: folder.appendingPathComponent(Self.p12FileName))
			try secrets.setPassword(p12Password, for: account.id)
			try appleIDPasswords.setPassword(password, for: account.id)
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
			}
			throw CertificateImportError.storageFailed(error.localizedDescription)
		}
		return account
	}

	/// Signs out of an Apple ID: removes it, its certificate's .p12 and key,
	/// and both passwords. It doesn't revoke the certificate, so apps signed
	/// with it open until their profiles run out. If it was in use, the
	/// oldest remaining certificate takes over, an imported one first.
	public func deleteAppleID(_ id: UUID) throws {
		var updated = index
		updated.appleIDs.removeAll { $0.id == id }
		if updated.defaultID == id { updated.defaultID = updated.firstID }
		try save(updated)
		try? FileManager.default.removeItem(at: folder(for: id))
		try? secrets.deletePassword(for: id)
		try? appleIDPasswords.deletePassword(for: id)
	}

	/// The Apple ID's own password, for signing in again.
	public func appleIDPassword(for id: UUID) throws -> String? { try appleIDPasswords.password(for: id) }

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
