import Foundation

// Keeping an app's spot on the Home Screen when Atelier deletes it and
// installs it again (5 Nov 2026): Offload then Reinstall, an install
// iOS can't put over the app (#76), and one under another bundle ID (#49).
// iOS puts a new app on the last page, or only in the App Library, so
// Atelier notes where the app was before deleting it, and once it's
// installed again, writes the layout back with the app in that spot.
//
// SpringBoard gives the layout over Direct installs (getIconState,
// formatVersion 2): the Dock, then each page, each a list of icons. It
// takes one back through setIconState in the form it imports, with the
// App Library as `ignored`: written back as a list, iOS puts every App
// Library app on a page. iOS doesn't report the App Library, the gaps
// between icons or hidden pages, so the App Library is worked out from the
// installed apps, a write closes the gaps, and a hidden page's apps would
// go to the App Library. homescreen-mcp found all this on iOS 27.0.1
// (https://github.com/kats1123/homescreen-mcp); its write keeps the App
// Library, folders and widgets' settings.
//
// A write can make gaps, though: iOS keeps a page's gaps by pinning the
// icons after them to their places (`listMetadata`'s `fixedLocations`, by
// page identifier), which homescreen-mcp writes. So Offload keeps the
// app's spot empty with a gap until Reinstall (6 Nov 2026), and
// every write sends the gaps Atelier keeps.

/// A dictionary from a property list, kept as it was read so that it's
/// written back unchanged.
public struct PlistDictionary: @unchecked Sendable, Equatable {
	public var values: [String: Any]

	public init(_ values: [String: Any] = [:]) {
		self.values = values
	}

	public subscript(key: String) -> Any? {
		get { values[key] }
		set { values[key] = newValue }
	}

	func string(_ key: String) -> String? {
		values[key] as? String
	}

	public static func == (lhs: Self, rhs: Self) -> Bool {
		NSDictionary(dictionary: lhs.values).isEqual(to: rhs.values)
	}
}

/// The Home Screen's layout, as SpringBoard gives it over Direct installs.
public struct HomeScreenLayout: Equatable, Sendable {
	/// What's on a page, in the Dock or in a folder.
	public enum Item: Equatable, Sendable {
		/// An app, by its bundle ID, or a web clip, by its identifier.
		case icon(id: String, raw: PlistDictionary)
		/// A folder, with its own pages.
		case folder(name: String, pages: [[Item]], raw: PlistDictionary)
		case widget(raw: PlistDictionary)
		/// Anything else, written back as it was read.
		case other(raw: PlistDictionary)

		init(_ value: Any) {
			if let id = value as? String {
				self = .icon(id: id, raw: PlistDictionary(["bundleIdentifier": id, "displayIdentifier": id]))
				return
			}
			let raw = PlistDictionary(value as? [String: Any] ?? [:])
			if Self.isWidget(raw) {
				self = .widget(raw: raw)
			} else if Self.isFolder(raw) {
				let pages = (raw["iconLists"] as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(Item.init) }
				self = .folder(name: raw.string("displayName") ?? raw.string("defaultDisplayName") ?? "Folder", pages: pages, raw: raw)
			} else if let id = raw.string("displayIdentifier") ?? raw.string("bundleIdentifier") {
				self = .icon(id: id, raw: raw)
			} else {
				self = .other(raw: raw)
			}
		}

		/// As homescreen-mcp tells them: a widget has a size or a stack's
		/// elements.
		static func isWidget(_ raw: PlistDictionary) -> Bool {
			raw["gridSize"] != nil || raw["elements"] != nil || raw.string("iconType") == "custom" || raw.string("elementType") == "widget"
		}

		/// Widgets and some apps have an empty `iconLists` too.
		static func isFolder(_ raw: PlistDictionary) -> Bool {
			raw.string("listType") == "folder" || (raw["iconLists"] != nil && !isWidget(raw) && raw.string("iconType") != "app")
		}

		/// The app's or web clip's identifier.
		public var id: String? {
			if case .icon(let id, _) = self { return id }
			return nil
		}

		/// What tells it from the icons around it: the identifier of an app
		/// or a web clip, a folder's name, a widget's identifier.
		var key: String {
			switch self {
			case .icon(let id, _): id
			case .folder(let name, _, _): "folder:\(name)"
			case .widget(let raw): "widget:\(raw.string("uniqueIdentifier") ?? raw.string("userSelectedElementIdentifier") ?? raw.string("displayIdentifier") ?? raw.string("gridSize") ?? "")"
			case .other: "other"
			}
		}

		/// How many of a page's 24 places it takes: 4, 8 or 16 for a small,
		/// medium or large widget.
		var places: Int {
			guard case .widget(let raw) = self else { return 1 }
			switch raw.string("gridSize")?.lowercased() {
			case "medium": return 8
			case "large": return 16
			case "extralarge": return 32
			default: return 4
			}
		}

		/// As SpringBoard imports it: apps and web clips as their identifier,
		/// a folder with its pages, and a widget without the empty
		/// `iconLists` iOS gives it. A configured widget's settings hang off
		/// its identifier, which iOS only gives as
		/// `userSelectedElementIdentifier`, so it goes back as
		/// `uniqueIdentifier`, or the settings are lost.
		var archived: Any {
			switch self {
			case .icon(let id, _):
				return id
			case .folder(_, let pages, let raw):
				var values = raw.values
				let lists = pages.filter { !$0.isEmpty }
				values["iconLists"] = lists.map { $0.map(\.archived) }
				// One per page, as homescreen-mcp keeps them, when iOS gives
				// them.
				if let ids = values["listUniqueIdentifiers"] as? [Any] {
					let more: [Any] = lists.indices.map { _ in UUID().uuidString }
					values["listUniqueIdentifiers"] = Array((ids + more).prefix(lists.count))
				}
				return values
			case .widget(let raw):
				var values = raw.values
				values.removeValue(forKey: "iconLists")
				if values["uniqueIdentifier"] == nil, values["elements"] == nil, let element = values["userSelectedElementIdentifier"] {
					values["uniqueIdentifier"] = element
				}
				return values
			case .other(let raw):
				return raw.values
			}
		}

		/// The identifiers of the apps and web clips in it.
		var ids: [String] {
			switch self {
			case .icon(let id, _): [id]
			case .folder(_, let pages, _): pages.flatMap { $0.flatMap(\.ids) }
			default: []
			}
		}

		var isWidget: Bool {
			if case .widget = self { return true }
			return false
		}

		var isFolder: Bool {
			if case .folder = self { return true }
			return false
		}
	}

	/// What iOS's Dock holds on an iPhone.
	public static let dockPlaces = 4
	/// A page's places on an iPhone: 4 by 6.
	public static let pagePlaces = 24
	public static let pageColumns = 4
	public static let pageRows = 6
	/// A folder page's places on an iPhone: 3 by 3.
	public static let folderPagePlaces = 9

	public var dock: [Item]
	public var pages: [[Item]]

	public init(dock: [Item], pages: [[Item]]) {
		self.dock = dock
		self.pages = pages
	}

	/// From getIconState's answer: the Dock, then each page.
	public init?(iconState: Any) {
		guard let lists = iconState as? [Any], let dock = lists.first as? [Any] else { return nil }
		self.dock = dock.map(Item.init)
		self.pages = lists.dropFirst().map { ($0 as? [Any] ?? []).map(Item.init) }
	}

	/// From getIconState's answer as a property list.
	public init?(plist: Data) {
		guard let state = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) else { return nil }
		self.init(iconState: state)
	}

	// MARK: What's where

	/// Every app's and web clip's identifier the layout places, in folders
	/// too.
	public var placedIDs: Set<String> {
		Set((dock + pages.flatMap { $0 }).flatMap(\.ids))
	}

	public var folderCount: Int {
		(dock + pages.flatMap { $0 }).filter(\.isFolder).count
	}

	public var widgetCount: Int {
		pages.flatMap { $0 }.filter(\.isWidget).count
	}

	/// Where the app or web clip `id` is; nil when the layout doesn't
	/// place it: it's only in the App Library, or not on this iPhone.
	public func spot(of id: String) -> HomeScreenSpot? {
		let lists: [(page: Int?, items: [Item])] = [(nil, dock)] + pages.enumerated().map { ($0.offset, $0.element) }
		for list in lists {
			for (index, item) in list.items.enumerated() {
				if item.id == id {
					return HomeScreenSpot(page: list.page, index: index, around: list.items)
				}
				guard case .folder(let name, let folderPages, _) = item else { continue }
				for (folderPage, folderItems) in folderPages.enumerated() {
					if let inner = folderItems.firstIndex(where: { $0.id == id }) {
						var spot = HomeScreenSpot(page: list.page, index: inner, around: folderItems)
						spot.folder = HomeScreenSpot.Folder(name: name, index: index, page: folderPage)
						return spot
					}
				}
			}
		}
		return nil
	}

	/// For each app and web clip it places, where: to compare a layout
	/// read back with the one written.
	public var spots: [String: HomeScreenSpot] {
		var spots: [String: HomeScreenSpot] = [:]
		for id in placedIDs {
			spots[id] = spot(of: id)
		}
		return spots
	}

	/// What `other` places differently: an icon in another spot, or in
	/// one layout only. Gaps aren't compared, as iOS doesn't report them.
	public func differences(from other: HomeScreenLayout, names: [String: String] = [:]) -> [String] {
		let mine = spots, theirs = other.spots
		var lines: [String] = []
		for id in Set(mine.keys).union(theirs.keys).sorted() {
			let name = names[id] ?? id
			switch (theirs[id], mine[id]) {
			case let (was?, now?) where was.description != now.description:
				lines.append("\(name): \(now.description), not \(was.description)")
			case (let was?, nil):
				lines.append("\(name): gone from \(was.description)")
			case (nil, let now?):
				lines.append("\(name): added at \(now.description)")
			default:
				break
			}
		}
		if pages.count != other.pages.count {
			lines.append("\(pages.count) pages, not \(other.pages.count)")
		}
		return lines
	}

	// MARK: Moving an app

	/// Why an app couldn't go back in its spot.
	public enum PlacingProblem: Error, Equatable, CustomStringConvertible {
		case dockFull
		case pageFull(Int)
		case folderFull(String)

		public var description: String {
			switch self {
			case .dockFull: "the Dock is full"
			case .pageFull(let page): "page \(page + 1) is full"
			case .folderFull(let name): "\(name) is full"
			}
		}
	}

	/// The layout without the app or web clip `id`, wherever it was, and
	/// without a page or a folder page its move leaves empty: the one iOS
	/// added for a new app when the last was full.
	public func removing(_ id: String) -> HomeScreenLayout {
		var layout = self
		layout.dock = Self.removing(id, from: dock)
		layout.pages = pages.compactMap { page in
			let left = Self.removing(id, from: page)
			return left.isEmpty && !page.isEmpty ? nil : left
		}
		return layout
	}

	private static func removing(_ id: String, from items: [Item]) -> [Item] {
		items.compactMap { item in
			switch item {
			case .icon(let itemID, _) where itemID == id:
				return nil
			case .folder(let name, let pages, let raw):
				let left = pages.compactMap { page in
					let rest = removing(id, from: page)
					return rest.isEmpty && !page.isEmpty ? nil : rest
				}
				return .folder(name: name, pages: left, raw: raw)
			default:
				return item
			}
		}
	}

	/// The first icon for `id`, as the layout has it.
	func item(_ id: String) -> Item? {
		for item in dock + pages.flatMap({ $0 }) {
			if item.id == id { return item }
			if case .folder(_, let folderPages, _) = item, let inner = folderPages.flatMap({ $0 }).first(where: { $0.id == id }) {
				return inner
			}
		}
		return nil
	}

	/// The layout with the app or web clip `id` moved to `spot`, from
	/// wherever iOS put it: a new app goes on the last page, or only in
	/// the App Library. It goes after the icon it was after, or before the
	/// one it was before, or at its place in the list when neither is
	/// there any more. A page or a folder that went with the app, its
	/// last icon, comes back.
	public func placing(_ id: String, at spot: HomeScreenSpot) throws -> HomeScreenLayout {
		let icon = item(id) ?? .icon(id: id, raw: PlistDictionary(["bundleIdentifier": id, "displayIdentifier": id]))
		var layout = removing(id)
		var pageIndex: Int?
		if let page = spot.page {
			if spot.folder == nil, spot.previous == nil, spot.next == nil {
				// Alone on its page, which iOS took away with it.
				let index = min(page, layout.pages.count)
				layout.pages.insert([icon], at: index)
				return layout
			}
			pageIndex = layout.page(page)
		}
		var list = pageIndex.map { layout.pages[$0] } ?? layout.dock
		if let folder = spot.folder {
			let found = list.indices.contains(folder.index) && list[folder.index].key == "folder:\(folder.name)"
				? folder.index
				: list.firstIndex { $0.key == "folder:\(folder.name)" }
			if let found, case .folder(let name, var folderPages, let raw) = list[found] {
				let page = min(folder.page, folderPages.count)
				if page == folderPages.count { folderPages.append([]) }
				guard folderPages[page].count < Self.folderPagePlaces else { throw PlacingProblem.folderFull(name) }
				folderPages[page].insert(icon, at: spot.position(in: folderPages[page]))
				list[found] = .folder(name: name, pages: folderPages, raw: raw)
			} else {
				// The folder went with the app, its last.
				try Self.checkRoom(in: list, for: 1, page: pageIndex)
				let raw = PlistDictionary(["displayName": folder.name, "listType": "folder"])
				list.insert(.folder(name: folder.name, pages: [[icon]], raw: raw), at: min(folder.index, list.count))
			}
		} else {
			try Self.checkRoom(in: list, for: icon.places, page: pageIndex)
			list.insert(icon, at: spot.position(in: list))
		}
		if let pageIndex {
			layout.pages[pageIndex] = list
		} else {
			layout.dock = list
		}
		return layout
	}

	/// The index of page `page`, adding a last page when it's gone.
	private mutating func page(_ page: Int) -> Int {
		if page < pages.count { return page }
		pages.append([])
		return pages.count - 1
	}

	/// Throws when `places` more don't fit on page `page`, or in the Dock.
	private static func checkRoom(in list: [Item], for places: Int, page: Int?) throws {
		if let page {
			guard Self.places(list) + places <= pagePlaces else { throw PlacingProblem.pageFull(page) }
		} else {
			guard list.count < dockPlaces else { throw PlacingProblem.dockFull }
		}
	}

	static func places(_ items: [Item]) -> Int {
		items.reduce(0) { $0 + $1.places }
	}

	// MARK: Writing it back

	/// The apps only in the App Library: the installed ones the layout
	/// doesn't place, but for those iOS never shows on the Home Screen.
	/// iOS doesn't report the App Library, so it's worked out, as
	/// homescreen-mcp does: an app missing from both, iOS puts on a page.
	public func appLibrary(installed apps: [HomeScreenApp]) -> [String] {
		let placed = placedIDs
		return apps
			.filter { !placed.contains($0.bundleID) && !$0.hidden && !HomeScreenApp.neverOnHomeScreen.contains($0.bundleID) }
			.sorted { ($0.name.lowercased(), $0.bundleID) < ($1.name.lowercased(), $1.bundleID) }
			.map(\.bundleID)
	}

	/// The layout as SpringBoard's setIconState imports it, with
	/// `appLibrary` as the apps only in the App Library, and the gaps of
	/// `gaps` that `gapPlaces` keeps. The Today View isn't given, so it
	/// stays as it is. Other gaps close, as iOS doesn't report them.
	public func archive(appLibrary: [String], gaps: HomeScreenGaps = HomeScreenGaps()) -> [String: Any] {
		var iconLists = pages.map { $0.map(\.archived) }
		var archive: [String: Any] = [
			"buttonBar": dock.map(\.archived),
			"iconLists": iconLists,
			"ignored": appLibrary,
		]
		let places = gapPlaces(gaps)
		guard !places.isEmpty else { return archive }
		// New page identifiers, which the gaps are kept by, as
		// homescreen-mcp sends them.
		let pageIDs = pages.map { _ in UUID().uuidString }
		var metadata: [String: Any] = [:]
		for (page, gapPlaces) in places {
			var pinned: [String: Int] = [:]
			for (index, item) in pages[page].enumerated() {
				// Each icon after a gap is pinned to its place, past the
				// gaps before it.
				let gapsBefore = gapPlaces.filter { $0 <= index }.count
				guard gapsBefore > 0 else { continue }
				switch item {
				case .icon(let id, _):
					pinned[id] = index + gapsBefore
				case .folder:
					// A folder is pinned by its identifier, which iOS doesn't
					// give, so it gets one.
					guard var folder = iconLists[page][index] as? [String: Any] else { continue }
					let id = folder["uniqueIdentifier"] as? String ?? UUID().uuidString
					folder["uniqueIdentifier"] = id
					iconLists[page][index] = folder
					pinned[id] = index + gapsBefore
				case .widget, .other:
					// `gapPlaces` keeps no gap on their pages.
					continue
				}
			}
			metadata[pageIDs[page]] = [
				"fixedLocations": pinned,
				"fixedLocationsGridColumns": Self.pageColumns,
				"fixedLocationsGridRows": Self.pageRows,
			] as [String: Any]
		}
		archive["iconLists"] = iconLists
		archive["listUniqueIdentifiers"] = pageIDs
		archive["listMetadata"] = metadata
		return archive
	}

	/// `archive` as a binary property list.
	public func archiveData(appLibrary: [String], gaps: HomeScreenGaps = HomeScreenGaps()) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: archive(appLibrary: appLibrary, gaps: gaps), format: .binary, options: 0)
	}

	// MARK: Gaps

	/// Where on its page each of `gaps` goes: by page, from 0, the places
	/// in the page's list each gap goes before, in order. An offloaded
	/// app's spot goes after the icon its app was after, or before the one
	/// it was before; a gap you marked, between its two icons while nothing
	/// came between them (`plan`). Gaps are kept only on a page of apps,
	/// web clips and folders with room for them, and when an icon comes
	/// after them, as nothing else would move into them. A spot in the Dock
	/// or in a folder gets no gap.
	public func gapPlaces(_ gaps: HomeScreenGaps) -> [Int: [Int]] {
		plan(gaps).gapPlaces
	}
}

/// What the Home Screen shows, and the installed apps the App Library is
/// worked out from.
public struct HomeScreenState: Sendable {
	public var layout: HomeScreenLayout
	public var apps: [HomeScreenApp]
	/// The layout as SpringBoard gave it, as a property list, to keep for
	/// writing it back or to share.
	public var plist: Data?

	public init(layout: HomeScreenLayout, apps: [HomeScreenApp], plist: Data? = nil) {
		self.layout = layout
		self.apps = apps
		self.plist = plist
	}

	/// The apps only in the App Library.
	public var appLibrary: [String] {
		layout.appLibrary(installed: apps)
	}

	/// The installed apps' names, by bundle ID, for the log.
	public var names: [String: String] {
		Dictionary(apps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
	}
}

/// Where an app is on the Home Screen, to put it back there.
public struct HomeScreenSpot: Codable, Equatable, Sendable {
	/// The page, from 0; nil for the Dock.
	public var page: Int?
	/// The folder it's in, on that page or in the Dock.
	public var folder: Folder?
	/// Its place in its list, from 0.
	public var index: Int
	/// The icons either side of it, to find its place once others moved.
	public var previous: String?
	public var next: String?

	public struct Folder: Codable, Equatable, Sendable {
		public var name: String
		/// The folder's place on its page or in the Dock, from 0.
		public var index: Int
		/// The folder's own page, from 0.
		public var page: Int

		public init(name: String, index: Int, page: Int) {
			self.name = name
			self.index = index
			self.page = page
		}
	}

	public init(page: Int?, folder: Folder? = nil, index: Int, previous: String? = nil, next: String? = nil) {
		self.page = page
		self.folder = folder
		self.index = index
		self.previous = previous
		self.next = next
	}

	init(page: Int?, index: Int, around items: [HomeScreenLayout.Item]) {
		self.init(
			page: page,
			index: index,
			previous: index > 0 ? items[index - 1].key : nil,
			next: index + 1 < items.count ? items[index + 1].key : nil
		)
	}

	/// Where it goes in `items`: after the icon it was after, before the
	/// one it was before, or at its place.
	func position(in items: [HomeScreenLayout.Item]) -> Int {
		gapPosition(in: items) ?? min(index, items.count)
	}

	/// Where a gap for it goes in `items`: after the icon it was after, or
	/// before the one it was before; nil when neither is there, such as on
	/// the page after the one iOS took away with it.
	func gapPosition(in items: [HomeScreenLayout.Item]) -> Int? {
		if let previous, let found = items.firstIndex(where: { $0.key == previous }) { return found + 1 }
		if let next, let found = items.firstIndex(where: { $0.key == next }) { return found }
		return nil
	}

	/// As the log says it: "Page 2, 7th", "Dock, 3rd", "In Tools,
	/// 2nd". Places count row by row from the top left, as iOS doesn't
	/// say where the gaps are.
	public var description: String {
		let place = Self.ordinal(index + 1)
		if let folder {
			return folder.page > 0 ? "In \(folder.name), page \(folder.page + 1), \(place)" : "In \(folder.name), \(place)"
		}
		guard let page else { return "Dock, \(place)" }
		return "Page \(page + 1), \(place)"
	}

	/// With the folder's own spot, for the log: "In Tools (Page 1, 5th),
	/// 2nd".
	public var detail: String {
		guard let folder else { return description }
		let place = Self.ordinal(index + 1)
		let folderSpot = HomeScreenSpot(page: page, index: folder.index).description
		return "In \(folder.name) (\(folderSpot)), \(folder.page > 0 ? "page \(folder.page + 1), \(place)" : place)"
	}

	static func ordinal(_ n: Int) -> String {
		let suffix: String
		switch (n % 10, n % 100) {
		case (_, 11...13): suffix = "th"
		case (1, _): suffix = "st"
		case (2, _): suffix = "nd"
		case (3, _): suffix = "rd"
		default: suffix = "th"
		}
		return "\(n)\(suffix)"
	}
}

/// An app installd knows, as the App Library is worked out from.
public struct HomeScreenApp: Equatable, Sendable {
	public var bundleID: String
	public var name: String
	/// iOS hides it everywhere (SBAppTags has "hidden").
	public var hidden: Bool

	public init(bundleID: String, name: String, hidden: Bool = false) {
		self.bundleID = bundleID
		self.name = name
		self.hidden = hidden
	}

	/// System apps iOS never puts on a page, though nothing says so: a
	/// write that left them out didn't move them, on iOS 27.0.1 and
	/// 26.6.2 (homescreen-mcp).
	public static let neverOnHomeScreen: Set<String> = [
		"com.apple.FTMInternal", "com.apple.Posters.ImagePlaygroundPosterApp", "com.apple.PreviewShell",
		"com.apple.TVRemoteApp", "com.apple.sidecar", "com.apple.webapp", "com.apple.appleseed.FeedbackAssistant",
	]

	/// From installd's records as a property list: bundle ID → record.
	public static func apps(from plist: Data) -> [HomeScreenApp]? {
		guard let records = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any] else { return nil }
		return records.map { bundleID, value in
			let record = value as? [String: Any] ?? [:]
			let name = (record["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? record["CFBundleName"] as? String ?? bundleID
			let tags = record["SBAppTags"] as? [String] ?? []
			return HomeScreenApp(bundleID: bundleID, name: name, hidden: tags.contains("hidden"))
		}
	}
}

/// Keeps an app's Home Screen spot across Atelier deleting it and
/// installing it again: notes where it is before it's deleted, then moves
/// the new install there.
@MainActor
public protocol HomeScreenKeeping: AnyObject {
	/// Notes where the app installed as `bundleID` is, before Atelier
	/// deletes it. Doesn't throw: an install goes ahead without it.
	func note(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async
	/// Moves the app now installed as `bundleID` to the spot noted for
	/// `noted`, the bundle ID it had, if there's one. Doesn't throw: the
	/// install itself worked.
	func putBack(_ bundleID: String, notedAs noted: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async
}
