import Foundation

/// Tells the two kinds of pairing file apart. They are easy to mix up: both are
/// plists, and tools save both as `pairingFile.plist`.
///
/// - `lockdown`: the classic record (jitterbugpair, idevicepair, Impactor's
///   default). Used with lockdownd on port 62078 plus a heartbeat.
/// - `remotePairing`: an RPPairing record (Ed25519 keys + identifier), used to
///   open a RemoteXPC tunnel, by default on port 49152. IDeviceKit, which Feather
///   uses, only reads this kind on iOS 17.4 and later.
public enum PairingFileKind: String, Equatable, Sendable {
	case lockdown
	case remotePairing
	case unknown
}

public struct PairingFileInfo: Equatable, Sendable {
	public var kind: PairingFileKind
	/// Top-level keys, for the log. Values are never logged: they are secrets.
	public var keys: [String]
	public var udid: String?
	public var hasWiFiMACAddress: Bool
	public var problems: [String]
}

public enum PairingFileInspector {
	static let lockdownRequired = ["DeviceCertificate", "HostCertificate", "HostPrivateKey", "RootCertificate", "HostID", "SystemBUID"]
	static let remotePairingRequired = ["public_key", "private_key", "identifier"]

	public static func inspect(_ data: Data) -> PairingFileInfo {
		guard
			let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
			let dict = object as? [String: Any]
		else {
			return PairingFileInfo(kind: .unknown, keys: [], udid: nil, hasWiFiMACAddress: false, problems: ["Not a property list dictionary"])
		}

		let keys = dict.keys.sorted()
		var problems: [String] = []

		if remotePairingRequired.allSatisfy({ dict[$0] != nil }) {
			for key in ["public_key", "private_key"] {
				if (dict[key] as? Data)?.count != 32 {
					problems.append("\(key) is not 32 bytes of data")
				}
			}
			if (dict["identifier"] as? String)?.isEmpty ?? true {
				problems.append("identifier is empty")
			}
			return PairingFileInfo(kind: .remotePairing, keys: keys, udid: dict["UDID"] as? String, hasWiFiMACAddress: false, problems: problems)
		}

		let missingLockdown = lockdownRequired.filter { dict[$0] == nil }
		if missingLockdown.count < lockdownRequired.count / 2 {
			problems += missingLockdown.map { "missing \($0)" }
			let udid = dict["UDID"] as? String
			if udid == nil {
				problems.append("missing UDID (some tools need it to pick the device)")
			}
			let hasMAC = dict["WiFiMACAddress"] != nil
			if !hasMAC {
				problems.append("missing WiFiMACAddress (needed for Wi-Fi lockdown connections)")
			}
			return PairingFileInfo(kind: .lockdown, keys: keys, udid: udid, hasWiFiMACAddress: hasMAC, problems: problems)
		}

		return PairingFileInfo(kind: .unknown, keys: keys, udid: nil, hasWiFiMACAddress: false, problems: ["Keys match neither a lockdown nor an RPPairing record"])
	}
}

extension PairingFileInspector {
	public enum Problem: Error, Equatable, CustomStringConvertible {
		case notAPairingFile
		/// A lockdown pairing record, for lockdownd on port 62078.
		case lockdownRecord
		case damaged([String])

		public var description: String {
			switch self {
			case .notAPairingFile:
				"That file isn't a pairing file."
			case .lockdownRecord:
				"This is an older kind of pairing file that Atelier can't use. Pair this \(ThisDevice.name) in Atelier's setup instead, or make a Remote Pairing file on a computer."
			case .damaged:
				"That pairing file is incomplete or damaged. Make it again, or pair this \(ThisDevice.name) in Atelier's setup."
			}
		}
	}

	/// Checks that `data` is an RPPairing record route A can use (#9). Taking
	/// a lockdown record for one is the most likely reason route A never
	/// worked in Feather (docs/install-routes.md).
	public static func check(_ data: Data) throws {
		let info = inspect(data)
		switch info.kind {
		case .remotePairing:
			if !info.problems.isEmpty { throw Problem.damaged(info.problems) }
		case .lockdown:
			throw Problem.lockdownRecord
		case .unknown:
			throw Problem.notAPairingFile
		}
	}
}

/// Where the pairing file is kept: one per Atelier, in Application Support,
/// readable only while the iPhone is unlocked and left out of backups.
/// While automatic updates need it (#72), readable after first unlock
/// instead, so a background update can install while the iPhone is locked;
/// the app sets `readableAfterFirstUnlockKey`, the same key CertKit's
/// `SecretProtection` reads.
/// Importing or pairing again replaces it.
public struct PairingFileStore: Sendable {
	public let url: URL

	public init(url: URL) {
		self.url = url
	}

	/// Application Support/Pairing/pairingFile.plist.
	public static func standard() throws -> PairingFileStore {
		let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		let store = PairingFileStore(url: support.appending(path: "Pairing/pairingFile.plist"))
		// Files saved before #22 were backed up; this takes them out.
		if store.exists { try? store.excludeFromBackup() }
		return store
	}

	/// Keeps the file out of iCloud and computer backups (#22). Set on its
	/// folder, as an atomic write replaces the file and its flags.
	func excludeFromBackup() throws {
		#if !os(Linux)
		var folder = url.deletingLastPathComponent()
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try folder.setResourceValues(values)
		#endif
	}

	public var exists: Bool {
		FileManager.default.fileExists(atPath: url.path)
	}

	/// When the file was saved, for Settings.
	public var savedAt: Date? {
		(try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
	}

	public static let readableAfterFirstUnlockKey = "secretsReadableAfterFirstUnlock"

	#if os(iOS)
	private static var readableAfterFirstUnlock: Bool {
		UserDefaults.standard.bool(forKey: readableAfterFirstUnlockKey)
	}

	/// Gives the saved file the current protection, after it changed. Only
	/// works while the iPhone is unlocked.
	public func reprotect() throws {
		guard exists else { return }
		let protection: FileProtectionType = Self.readableAfterFirstUnlock ? .completeUntilFirstUserAuthentication : .complete
		try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
	}
	#endif

	public func load() throws -> Data {
		try Data(contentsOf: url)
	}

	/// Checks and saves a pairing file, replacing the one there. Throws
	/// `PairingFileInspector.Problem` and keeps the old file when `data` isn't one.
	public func save(_ data: Data) throws {
		try PairingFileInspector.check(data)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try excludeFromBackup()
		#if os(iOS)
		// Whoever holds this file has a trusted computer's access to the
		// iPhone, so it can't be read while the iPhone is locked, unless
		// automatic updates need it after first unlock.
		try data.write(to: url, options: [.atomic, Self.readableAfterFirstUnlock ? .completeFileProtectionUntilFirstUserAuthentication : .completeFileProtection])
		#else
		try data.write(to: url, options: .atomic)
		#endif
	}

	public func remove() {
		try? FileManager.default.removeItem(at: url)
	}
}
