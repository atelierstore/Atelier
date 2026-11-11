import Foundation

/// Every added source's apps as one catalog, for Browse, search and app
/// details (#14). Built off the main thread from the sources' parsed JSON,
/// with what search needs worked out once, so typing stays fast with
/// sources of hundreds of apps.
public struct Catalog: Sendable {
	/// What Browse shows about the source an app or news item comes from.
	public struct SourceInfo: Hashable, Sendable {
		/// The source's normalized URL, which identifies it.
		public var url: URL
		public var name: String
		/// Six hex digits, without `#`: the source's, or its first app's.
		public var tintColor: String?
		public var iconURL: URL?

		public init(url: URL, name: String, tintColor: String? = nil, iconURL: URL? = nil) {
			self.url = url
			self.name = name
			self.tintColor = tintColor
			self.iconURL = iconURL
		}
	}

	/// One source's listing of an app.
	public struct Offer: Sendable, Identifiable {
		public var id: URL { source.url }
		public var source: SourceInfo
		public var app: SourceApp
	}

	/// An app, listed by one source or more. Several sources listing the same
	/// bundle ID and name make one entry (see `AppName`).
	public struct Entry: Sendable, Identifiable {
		/// The apps' `SourceApp.id`.
		public var id: String
		public var bundleID: String
		/// Newest version first; sources with the same version keep the order
		/// they were added in.
		public var offers: [Offer]

		/// The listing Browse shows and installs from unless the user picks
		/// another source.
		public var preferred: Offer { offers[0] }
		public var app: SourceApp { preferred.app }

		/// The listing from the source at `url`, or the preferred one when
		/// that source doesn't list the app.
		public func offer(from url: URL?) -> Offer {
			offers.first { $0.source.url == url } ?? preferred
		}

		// Folded once for search.
		fileprivate var foldedName: String
		fileprivate var foldedOthers: [String]
	}

	/// A source's featured apps and all its apps, for its part of Browse.
	public struct SourceSection: Sendable, Identifiable {
		public var id: URL { source.url }
		public var source: SourceInfo
		/// Only the apps the source names as featured: Browse shows no row
		/// of them for a source that names none (#38).
		public var featured: [Entry]
		/// Every app the source lists, in the source's order (#38).
		public var apps: [Entry]
	}

	/// A news item with the source it comes from.
	public struct News: Sendable, Identifiable {
		public var id: String { "\(source.url.absoluteString)#\(item.identifier)" }
		public var source: SourceInfo
		public var item: NewsItem
	}

	/// Every app, by name.
	public private(set) var entries: [Entry]
	/// In the order the sources were added.
	public private(set) var sources: [SourceSection]
	/// Every source's news, newest first.
	public private(set) var news: [News]
	private var index: [String: Int]

	public static let empty = Catalog(sources: [])

	/// `sources` in the order the user added them. Each app's preferred
	/// listing is the one with the newest version `os` can run (#38).
	public init(sources: [(info: SourceInfo, source: Source)], os: OSVersion = .current) {
		var offers: [String: [Offer]] = [:]
		var firstSeen: [String] = []
		for (info, source) in sources {
			for app in source.apps {
				let id = app.id
				if offers[id] == nil { firstSeen.append(id) }
				offers[id, default: []].append(Offer(source: info, app: app))
			}
		}

		var entries = firstSeen.map { id in
			let listed = offers[id]!
			// Stable: equal versions keep the sources' order.
			let sorted = listed.enumerated().sorted { a, b in
				switch Self.comparePreferred(a.element.app, b.element.app, on: os) {
				case .orderedDescending: true
				case .orderedAscending: false
				case .orderedSame: a.offset < b.offset
				}
			}.map(\.element)
			let app = sorted[0].app
			return Entry(
				id: id,
				bundleID: app.bundleID,
				offers: sorted,
				foldedName: Self.fold(app.name),
				foldedOthers: [app.developerName, app.subtitle, app.bundleID].compactMap { $0.map(Self.fold) }
			)
		}
		entries.sort { a, b in
			let order = a.app.name.compare(b.app.name, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
			return order == .orderedSame ? a.id < b.id : order == .orderedAscending
		}
		let index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })

		self.entries = entries
		self.index = index
		self.sources = sources.map { info, source in
			SourceSection(
				source: info,
				featured: source.listedFeaturedApps.compactMap { index[$0.id].map { entries[$0] } },
				apps: source.apps.compactMap { index[$0.id].map { entries[$0] } }
			)
		}
		self.news = sources
			.flatMap { info, source in source.newsNewestFirst.map { News(source: info, item: $0) } }
			.enumerated()
			.sorted { a, b in
				// Newest first across sources; undated items last, in order.
				switch (a.element.item.date, b.element.item.date) {
				case let (x?, y?) where x != y: x > y
				case (_?, nil): true
				case (nil, _?): false
				default: a.offset < b.offset
				}
			}
			.map(\.element)
	}

	public var isEmpty: Bool { entries.isEmpty }

	/// The section of the source at `url`, or nil when its JSON didn't parse.
	public func source(url: URL) -> SourceSection? {
		sources.first { $0.source.url == url }
	}

	public func entry(id: String) -> Entry? {
		index[id].map { entries[$0] }
	}

	/// The first app, by name, with this bundle ID, for news items, which
	/// only name a bundle ID.
	public func entry(bundleID: String) -> Entry? {
		entries.first { $0.bundleID == bundleID }
	}

	/// The apps in `category`, by name, judged by each app's preferred listing.
	public func entries(in category: AppCategory) -> [Entry] {
		entries.filter { $0.app.category == category }
	}

	/// The categories that have apps, in the spec's order, with how many.
	public var categories: [(category: AppCategory, count: Int)] {
		var counts: [AppCategory: Int] = [:]
		for entry in entries { counts[entry.app.category, default: 0] += 1 }
		return AppCategory.allCases.compactMap { category in counts[category].map { (category, $0) } }
	}

	/// Apps whose name, developer, subtitle or bundle ID contains every word
	/// of `query`, ignoring case and accents. Names that start with the query
	/// come first, then other name matches, then the rest, each by name.
	public func search(_ query: String) -> [Entry] {
		Self.search(SearchText(query), in: entries)
	}

	/// The apps of `list`, such as a source's or a category's, that match
	/// `query` as Browse's search matches them, ranked the same way, each
	/// rank in `list`'s order (#124). Nothing when nothing is typed.
	public static func search(_ query: SearchText, in list: [Entry]) -> [Entry] {
		guard !query.isEmpty else { return [] }
		var prefix: [Entry] = [], name: [Entry] = [], other: [Entry] = []
		for entry in list {
			switch query.rank(foldedName: entry.foldedName, foldedOthers: entry.foldedOthers) {
			case .namePrefix?: prefix.append(entry)
			case .name?: name.append(entry)
			case .other?: other.append(entry)
			case nil: continue
			}
		}
		return prefix + name + other
	}

	static func fold(_ string: String) -> String {
		SearchText.fold(string)
	}

	/// Compares two listings by the newest version each offers that `os` can
	/// run, so a listing this device can install comes first; then, as for
	/// listings neither can install, by their latest versions.
	static func comparePreferred(_ a: SourceApp, _ b: SourceApp, on os: OSVersion) -> ComparisonResult {
		switch (a.availability(on: os).version, b.availability(on: os).version) {
		case let (x?, y?):
			let order = x.compareRelease(to: y)
			return order == .orderedSame ? compareLatest(a, b) : order
		case (_?, nil): return .orderedDescending
		case (nil, _?): return .orderedAscending
		case (nil, nil): return compareLatest(a, b)
		}
	}

	/// Compares two listings' latest versions: by version number, then build
	/// number, then date. Listings without versions count as oldest.
	static func compareLatest(_ a: SourceApp, _ b: SourceApp) -> ComparisonResult {
		switch (a.latestVersion, b.latestVersion) {
		case (nil, nil): .orderedSame
		case (nil, _): .orderedAscending
		case (_, nil): .orderedDescending
		case let (x?, y?): x.compareRelease(to: y)
		}
	}
}

extension AppVersion {
	/// Whether this version is newer than `other`: by version number, then
	/// build number when both have one, then date when both have one.
	public func compareRelease(to other: AppVersion) -> ComparisonResult {
		let byVersion = VersionNumber.compare(version, other.version)
		if byVersion != .orderedSame { return byVersion }
		if let build = buildVersion, let otherBuild = other.buildVersion {
			let byBuild = VersionNumber.compare(build, otherBuild)
			if byBuild != .orderedSame { return byBuild }
		}
		if let date, let otherDate = other.date, date != otherDate {
			return date < otherDate ? .orderedAscending : .orderedDescending
		}
		return .orderedSame
	}
}

/// Compares version strings such as "1.10", "1.9.2" or "2.0b3" part by part,
/// with numbers compared as numbers and missing parts counting as zero, so
/// "1.7" and "1.7.0" are the same version.
public enum VersionNumber {
	public static func compare(_ a: String, _ b: String) -> ComparisonResult {
		let left = parts(a), right = parts(b)
		for i in 0..<max(left.count, right.count) {
			let x = i < left.count ? left[i] : "0"
			let y = i < right.count ? right[i] : "0"
			let order = x.compare(y, options: [.numeric, .caseInsensitive])
			if order != .orderedSame { return order }
		}
		return .orderedSame
	}

	/// Whether the version ends in a pre-release tag: a, alpha, b, beta, rc
	/// or pre, with or without a number, as in 2.3.1rc, 1.2b2 or 2.0-beta.3.
	public static func isPrerelease(_ version: String) -> Bool {
		version.range(of: #"\d[-.]?(?:a|alpha|b|beta|rc|pre)[-.]?\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil
	}

	private static func parts(_ string: String) -> [String] {
		string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
	}
}

/// What an app's Install button offers (#14). Installing itself comes with
/// the one-tap install pipeline (#16).
public enum InstallAction: Equatable, Sendable {
	case install(AppVersion)
	/// Installed, with a newer version this device can run.
	case update(AppVersion)
	/// Installed, and up to date or with nothing newer this device can run.
	case open
	case notInstallable(NotInstallableReason)

	/// `installedVersion` is the installed app's `CFBundleShortVersionString`,
	/// or nil when Atelier hasn't installed it.
	public init(availability: AppAvailability, installedVersion: String?) {
		switch (availability, installedVersion) {
		case (.installable(let version), nil):
			self = .install(version)
		case (.installable(let version), let installed?):
			self = VersionNumber.compare(version.version, installed) == .orderedDescending ? .update(version) : .open
		case (.notInstallable, _?):
			self = .open
		case (.notInstallable(let reason), nil):
			self = .notInstallable(reason)
		}
	}
}
