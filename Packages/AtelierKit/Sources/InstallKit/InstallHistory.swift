import Foundation

/// One install attempt, whatever came of it (#11): for the Library (#17) and
/// for debugging.
public struct InstallAttempt: Codable, Equatable, Identifiable, Sendable {
	public enum Result: String, Codable, Sendable {
		case confirmed
		case unconfirmed
		case failed
		case cancelled
	}

	/// What was installed, so a failed attempt can be tried again from
	/// Install history while that's still there (#17).
	public enum Origin: Codable, Equatable, Sendable {
		/// A version from a source: the app's `SourceApp.id` and the
		/// version's `version`, installed as `copy` (nil for the app
		/// itself) under `displayName` (nil keeps the app's), signed with
		/// `certificateID` (nil for the default certificate).
		case source(sourceURL: URL?, appID: String, version: String, copy: Int?, displayName: String?, certificateID: UUID?)
		/// A download in the Downloads list, such as one from a pasted URL.
		case download(UUID)
		/// A picked file's copy, by its name in Atelier's installs folder.
		case picked(String)
		/// The signed copy kept of this bundle ID (#15), installed as it
		/// was. Atelier kept those until 29 Oct 2026.
		case signed(String)
		/// The app with this bundle ID signed again with the certificate
		/// `certificateID` and installed as the app `originalBundleID`
		/// lists: Atelier as it runs (#24), and until 29 Oct 2026 an app's
		/// kept signed copy.
		case signedAgain(bundleID: String, originalBundleID: String, certificateID: UUID?)
	}

	public var id: UUID
	/// Nil when the install failed before the app was read, such as a picked
	/// file that isn't an app.
	public var bundleID: String?
	public var name: String
	public var version: String?
	/// The certificate's name; nil when nothing was signed, such as a kept
	/// signed copy installed again.
	public var certificate: String?
	/// Nil when the install failed before a route was chosen.
	public var route: InstallRoute?
	public var startedAt: Date
	public var finishedAt: Date
	public var result: Result
	public var error: String?
	/// What won't work in the signed app, from its entitlements (#7). Nil
	/// for attempts recorded before #7 and ones that didn't get to signing.
	public var limits: [String]?
	public var log: [String]
	/// Nil for attempts recorded before #17.
	public var origin: Origin?
	/// True when Atelier installed it by itself, as a background update
	/// (#72); nil otherwise.
	public var automatic: Bool?

	public init(
		id: UUID = UUID(),
		bundleID: String?,
		name: String,
		version: String?,
		certificate: String?,
		route: InstallRoute?,
		startedAt: Date,
		finishedAt: Date,
		result: Result,
		error: String? = nil,
		limits: [String]? = nil,
		log: [String] = [],
		origin: Origin? = nil,
		automatic: Bool? = nil
	) {
		self.id = id
		self.bundleID = bundleID
		self.name = name
		self.version = version
		self.certificate = certificate
		self.route = route
		self.startedAt = startedAt
		self.finishedAt = finishedAt
		self.result = result
		self.error = error
		self.limits = limits
		self.log = log
		self.origin = origin
		self.automatic = automatic
	}

	/// Its name in Install history, "Delta 1.8". An install from a source
	/// names its version already, so it isn't added twice, as in "Across
	/// 1.12.8 1.12.8" (25 Oct).
	public var title: String {
		guard let version, !name.split(separator: " ").contains(where: { $0 == version }) else { return name }
		return "\(name) \(version)"
	}
}

/// The last `limit` install attempts, newest first, in one JSON file.
public struct InstallHistory: Sendable {
	public let file: URL
	public let limit: Int

	public init(file: URL, limit: Int = 200) {
		self.file = file
		self.limit = limit
	}

	/// Application Support/InstallHistory.json.
	public static func standard() throws -> InstallHistory {
		let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		return InstallHistory(file: support.appending(path: "InstallHistory.json"))
	}

	/// Newest first. An unreadable file reads as empty.
	public func attempts() -> [InstallAttempt] {
		guard let data = try? Data(contentsOf: file) else { return [] }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return (try? decoder.decode([InstallAttempt].self, from: data)) ?? []
	}

	public func record(_ attempt: InstallAttempt) throws {
		try save(Array(([attempt] + attempts()).prefix(limit)))
	}

	/// Changes the attempt with this ID, while it's still kept: Atelier's
	/// install of itself adds to its log once Atelier is in front again
	/// (#24).
	public func update(_ id: InstallAttempt.ID, _ change: (inout InstallAttempt) -> Void) throws {
		var attempts = attempts()
		guard let index = attempts.firstIndex(where: { $0.id == id }) else { return }
		change(&attempts[index])
		try save(attempts)
	}

	public func removeAll() {
		try? FileManager.default.removeItem(at: file)
	}

	private func save(_ attempts: [InstallAttempt]) throws {
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		try encoder.encode(attempts).write(to: file, options: .atomic)
	}
}
