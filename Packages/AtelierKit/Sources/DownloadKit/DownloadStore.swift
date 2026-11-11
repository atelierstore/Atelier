import Foundation

/// Where downloads live on disk: the list of downloads as JSON, each finished
/// IPA, and the resume data of each paused or interrupted one.
///
///     <root>/downloads.json
///     <root>/<id>.ipa       finished and checked
///     <root>/<id>.resume    URLSession resume data
///     <root>/<id>.part      a finished transfer being checked
///
/// Kept in Application Support rather than Caches, so iOS doesn't purge an
/// IPA the user is about to install, and excluded from backups.
public struct DownloadStore: Sendable {
	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	/// Application Support/Downloads.
	public static func standard() throws -> DownloadStore {
		let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		return DownloadStore(root: support.appending(path: "Downloads", directoryHint: .isDirectory))
	}

	public func fileURL(for id: UUID) -> URL { root.appending(path: "\(id.uuidString).ipa") }
	public func resumeDataURL(for id: UUID) -> URL { root.appending(path: "\(id.uuidString).resume") }
	public func partialURL(for id: UUID) -> URL { root.appending(path: "\(id.uuidString).part") }
	private var listURL: URL { root.appending(path: "downloads.json") }

	public func prepare() throws {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var url = root
		try? url.setResourceValues(values)
	}

	/// The saved downloads, or none when there's no list yet or it can't be read.
	public func load() -> [Download] {
		guard let data = try? Data(contentsOf: listURL) else { return [] }
		return (try? Self.decoder.decode([Download].self, from: data)) ?? []
	}

	public func save(_ downloads: [Download]) throws {
		try prepare()
		try Self.encoder.encode(downloads).write(to: listURL, options: .atomic)
	}

	public func resumeData(for id: UUID) -> Data? {
		try? Data(contentsOf: resumeDataURL(for: id))
	}

	public func saveResumeData(_ data: Data, for id: UUID) {
		try? prepare()
		try? data.write(to: resumeDataURL(for: id), options: .atomic)
	}

	public func removeResumeData(for id: UUID) {
		try? FileManager.default.removeItem(at: resumeDataURL(for: id))
	}

	/// Deletes everything kept for a download.
	public func removeFiles(for id: UUID) {
		for url in [fileURL(for: id), resumeDataURL(for: id), partialURL(for: id)] {
			try? FileManager.default.removeItem(at: url)
		}
	}

	/// Deletes files that no download in `downloads` owns, such as those left
	/// by a download removed while Atelier was being killed.
	public func removeOrphans(keeping downloads: [Download]) {
		let owned = Set(downloads.map(\.id.uuidString))
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
		for name in names where name != "downloads.json" {
			let stem = (name as NSString).deletingPathExtension
			if !owned.contains(stem) {
				try? FileManager.default.removeItem(at: root.appending(path: name))
			}
		}
	}

	// Dates as seconds, which keep their fractions, unlike ISO 8601.
	private static let encoder = JSONEncoder()
	private static let decoder = JSONDecoder()
}
