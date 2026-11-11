import Foundation

/// What a background check tells the user about updates (#19): every update
/// the Library shows, once one of them is new. An update the user was told
/// about, or saw in Atelier, doesn't bring the notification back, so a
/// skipped or ignored one doesn't come up at every check.
public struct UpdateNotice: Equatable, Sendable {
	public struct Update: Equatable, Sendable {
		/// The app's bundle ID and the version's `UpdateCheck.key`.
		public var key: String
		public var name: String
		public var displayVersion: String

		public init(bundleID: String, version: AppVersion, name: String) {
			key = "\(bundleID) \(UpdateCheck.key(of: version))"
			self.name = name
			displayVersion = version.displayVersion
		}
	}

	public var title: String
	public var body: String

	/// The notification for `updates`, or nil when all of them are `told`.
	public static func notice(for updates: [Update], told: Set<String>) -> UpdateNotice? {
		guard updates.contains(where: { !told.contains($0.key) }) else { return nil }
		let title = updates.count == 1 ? "Update available" : "\(updates.count) updates available"
		let named = updates.map { "\($0.name) \($0.displayVersion)" }
		let shown = named.count > 4 ? Array(named.prefix(3)) + ["\(named.count - 3) more"] : named
		return UpdateNotice(title: title, body: "\(Self.list(shown)). Tap to open the Library.")
	}

	/// What's remembered as told after a check: the updates there are now,
	/// so one that went and came back is told again.
	public static func told(after updates: [Update]) -> Set<String> {
		Set(updates.map(\.key))
	}

	/// "A", "A and B", "A, B and C".
	static func list(_ items: [String]) -> String {
		guard items.count > 1 else { return items.first ?? "" }
		return items.dropLast().joined(separator: ", ") + " and " + items.last!
	}
}

/// News items a source flags with `notify` (#19), each told once.
public enum NewsNotice {
	public struct Item: Equatable, Sendable {
		/// The source's URL and the item's identifier, as `Catalog.News.id`.
		public var id: String
		public var sourceName: String
		public var item: NewsItem

		public init(id: String, sourceName: String, item: NewsItem) {
			self.id = id
			self.sourceName = sourceName
			self.item = item
		}

		public var title: String { "\(sourceName) · News" }

		public var body: String {
			guard let caption = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { return item.title }
			return "\(item.title): \(caption)"
		}
	}

	/// How old a flagged item may be and still be told, so a source added
	/// later doesn't bring up its old news.
	public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
	/// At most this many at once, newest first.
	public static let maxAtOnce = 3

	/// The items to tell about, and what's seen afterwards. `seen` is nil
	/// before the first check: everything there is then counts as seen.
	public static func check(_ items: [Item], seen: Set<String>?, now: Date) -> (notify: [Item], seen: Set<String>) {
		let ids = Set(items.map(\.id))
		guard let seen else { return ([], ids) }
		let fresh = items.filter { item in
			item.item.notify && !seen.contains(item.id)
				&& item.item.date.map { now.timeIntervalSince($0) < maxAge } ?? true
		}
		let newest = fresh.sorted { ($0.item.date ?? now) > ($1.item.date ?? now) }
		return (Array(newest.prefix(maxAtOnce)), seen.union(ids))
	}
}
