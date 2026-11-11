import Foundation
import SourceKit

/// One IPA download: a specific version of an app from a specific source,
/// so the file can be checked against what that source says about it.
public struct Download: Codable, Equatable, Identifiable, Sendable {
	public enum Status: Codable, Equatable, Sendable {
		/// Running, or about to be resumed or retried.
		case downloading
		/// Paused by the user, or stopped because Atelier was force quit.
		/// Resuming continues from where it stopped when the server allows.
		case paused
		/// Gave up after retrying, or the file wasn't the app. Retrying starts
		/// again, from where it stopped if it can.
		case failed(String)
		/// Downloaded and checked. The IPA is at `DownloadStore.fileURL(for:)`.
		case finished
	}

	public var id: UUID
	/// The version's `downloadURL`.
	public var url: URL
	/// The app's `SourceApp.id` (bundle ID and name).
	public var appID: String
	public var bundleID: String
	public var name: String
	/// `AppVersion.version`, the `CFBundleShortVersionString` the source gives.
	public var version: String
	/// `AppVersion.displayVersion`.
	public var displayVersion: String
	/// The source the version comes from, by its normalized URL.
	public var sourceURL: URL?
	public var iconURL: URL?
	/// The source's `size`, which the download must match.
	public var expectedSize: Int64?
	/// Lowercase hex, when the source gives one (not in the spec).
	public var sha256: String?
	public var createdAt: Date
	public var status: Status
	/// The file's size once finished.
	public var fileSize: Int64?
	/// Started by Atelier to have an update ready before it's asked for
	/// (#19): it only downloads over Wi-Fi until the user asks for it.
	/// Optional, so downloads saved before it read as the user's.
	public var isAhead: Bool?

	public init(
		id: UUID = UUID(),
		url: URL,
		appID: String,
		bundleID: String,
		name: String,
		version: String,
		displayVersion: String,
		sourceURL: URL? = nil,
		iconURL: URL? = nil,
		expectedSize: Int64? = nil,
		sha256: String? = nil,
		createdAt: Date = .now,
		status: Status = .downloading,
		fileSize: Int64? = nil
	) {
		self.id = id
		self.url = url
		self.appID = appID
		self.bundleID = bundleID
		self.name = name
		self.version = version
		self.displayVersion = displayVersion
		self.sourceURL = sourceURL
		self.iconURL = iconURL
		self.expectedSize = expectedSize
		self.sha256 = sha256
		self.createdAt = createdAt
		self.status = status
		self.fileSize = fileSize
	}

	/// A download of `version` as `app` lists it in the source at `sourceURL`.
	public init(app: SourceApp, version: AppVersion, sourceURL: URL?) {
		self.init(
			url: version.downloadURL,
			appID: app.id,
			bundleID: app.bundleID,
			name: app.name,
			version: version.version,
			displayVersion: version.displayVersion,
			sourceURL: sourceURL,
			iconURL: app.iconURL,
			expectedSize: version.size.flatMap { $0 > 0 ? $0 : nil },
			sha256: version.sha256
		)
	}

	/// A download of an IPA at a URL the user pasted, from no source. Until
	/// it's finished, its name comes from the URL; then from the app itself
	/// (`DownloadManager`).
	public init(url: URL) {
		self.init(url: url, appID: "", bundleID: "", name: Self.name(from: url), version: "", displayVersion: "")
	}

	/// Whether this download came from a pasted URL rather than a source.
	public var isFromURL: Bool {
		sourceURL == nil && appID.isEmpty
	}

	/// Whether this is a download of `version` from the source at `sourceURL`.
	public func matches(_ version: AppVersion, sourceURL: URL?) -> Bool {
		// The display version carries the build number, so a new build at
		// the same URL isn't taken for the old one's download (#18).
		url == version.downloadURL && self.version == version.version && displayVersion == version.displayVersion && self.sourceURL == sourceURL
	}

	/// The file name without `.ipa`, or the host when the path has none.
	static func name(from url: URL) -> String {
		let file = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
		if !file.isEmpty, file != "/" { return file }
		return url.host ?? url.absoluteString
	}
}

/// How far a running download has got. Not saved: it comes back from the
/// system's next progress report after a relaunch.
public struct DownloadProgress: Equatable, Sendable {
	public var received: Int64
	/// From the server's Content-Length, or else the source's `size`.
	public var expected: Int64?

	public init(received: Int64, expected: Int64?) {
		self.received = received
		self.expected = expected
	}

	public var fraction: Double? {
		guard let expected, expected > 0 else { return nil }
		return min(1, Double(received) / Double(expected))
	}
}

/// When a failed download is tried again: 2, 4, 8, 16 and 32 seconds after
/// each failure, then it's left for the user to retry. A background session
/// already waits out network loss on its own; this covers servers that drop
/// the connection or time out.
public enum RetryPolicy {
	public static let maxAttempts = 5

	/// The wait before retry number `attempt` (from 1), or nil to give up.
	public static func delay(beforeAttempt attempt: Int) -> TimeInterval? {
		guard attempt >= 1, attempt <= maxAttempts else { return nil }
		return pow(2, Double(attempt))
	}
}
