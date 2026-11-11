import Foundation

/// The link each app installed from an IPA link was downloaded from (#113),
/// so Custom Install… and Re-sign can download its IPA again (#155), by the
/// bundle ID iOS has the app under, in one JSON file in Application
/// Support. Never the IPA itself. An app installed from a
/// source has none, and so does one installed from an IPA file: iOS gives
/// Atelier copies of files, which it can't find again.
public final class IPAOrigins: @unchecked Sendable {
	/// Application Support/IPA Origins.json. Tests put another in its place.
	nonisolated(unsafe) public static var shared = IPAOrigins(file: IPAOrigins.standardFile)

	public let file: URL
	private let lock = NSLock()
	/// The file as last read or written; nil until it's read.
	private var cache: [String: URL]?

	public init(file: URL) {
		self.file = file
	}

	private static var standardFile: URL {
		let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
			?? FileManager.default.temporaryDirectory
		return support.appending(path: "IPA Origins.json")
	}

	/// The link the IPA of the app installed as `bundleID` came from; nil
	/// when Atelier doesn't know one.
	public func link(of bundleID: String) -> URL? {
		lock.lock()
		defer { lock.unlock() }
		return load()[bundleID]
	}

	/// Notes the link the IPA of the app installed as `bundleID` came from;
	/// nil forgets it, as for an app installed from a source or a file.
	public func save(_ link: URL?, for bundleID: String) {
		lock.lock()
		defer { lock.unlock() }
		var all = load()
		guard all[bundleID] != link else { return }
		all[bundleID] = link
		write(all)
	}

	/// Forgets the apps no longer in the Library: those whose bundle ID
	/// isn't among `installed`.
	public func keep(only installed: Set<String>) {
		lock.lock()
		defer { lock.unlock() }
		var all = load()
		let gone = all.keys.filter { !installed.contains($0) }
		guard !gone.isEmpty else { return }
		for bundleID in gone { all[bundleID] = nil }
		write(all)
	}

	/// The link's host, without "www.", or the link itself without one:
	/// "github.com".
	public static func site(of url: URL) -> String {
		guard let host = url.host, !host.isEmpty else { return url.absoluteString }
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}

	/// The link as its menu on the app's page shows it: whole, or past
	/// `limit` characters, shortened in the middle, as Codemagic's long
	/// ones are, keeping its start and its end.
	public static func shortened(_ url: URL, limit: Int = 72) -> String {
		let whole = url.absoluteString
		guard whole.count > limit, limit >= 3 else { return whole }
		let end = (limit - 1) / 3
		return whole.prefix(limit - 1 - end) + "…" + whole.suffix(end)
	}

	// MARK: The file

	/// One entry, `{"link": "https://…"}`. One without a link, such as the
	/// bookmarks to files that test builds kept, is read as nothing, rather
	/// than making the rest unreadable.
	private struct Entry: Codable {
		var link: URL?

		init(_ link: URL) {
			self.link = link
		}

		init(from decoder: any Decoder) throws {
			link = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(URL.self, forKey: .link)
		}
	}

	/// What the file holds, read once. Called with the lock held. A file
	/// that can't be read holds nothing.
	private func load() -> [String: URL] {
		if let cache { return cache }
		let entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
		let loaded = entries.compactMapValues(\.link)
		cache = loaded
		return loaded
	}

	/// Called with the lock held. A file that can't be written leaves the
	/// apps' pages without their IPA's link, and nothing else.
	private func write(_ all: [String: URL]) {
		cache = all
		if all.isEmpty {
			try? FileManager.default.removeItem(at: file)
			return
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		guard let data = try? encoder.encode(all.mapValues(Entry.init)) else { return }
		try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? data.write(to: file, options: .atomic)
	}
}
