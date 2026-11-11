import Foundation

// Open Spaces (7 Nov 2026): iOS doesn't report the gaps you leave
// between icons, so a write closes them unless you mark them. A marked gap
// is kept between the icon or folder before it and the one after it, as an
// offloaded app's spot is, so it moves along with them when iOS moves
// icons. Once something fills it, or one of the two leaves the page,
// there's no gap there any more, and it's no longer kept. Something that
// takes only its first places, as a new app does, leaves the rest.

/// A gap you left between icons on a page, as Open Spaces keeps it.
public struct HomeScreenGap: Codable, Equatable, Hashable, Sendable {
	/// The page it's on, from 0, as last seen.
	public var page: Int
	/// The icon or folder before it; nil at the start of its page.
	public var after: String?
	/// The icon or folder after it. Space after a page's last icon needs no
	/// marking: iOS leaves it empty anyway.
	public var before: String
	/// How many places it takes.
	public var count: Int

	public init(page: Int, after: String?, before: String, count: Int = 1) {
		self.page = page
		self.after = after
		self.before = before
		self.count = count
	}
}

/// The gaps a write keeps: offloaded apps' spots, by bundle ID, and the
/// gaps you marked.
public struct HomeScreenGaps: Equatable, Sendable {
	public var held: [String: HomeScreenSpot]
	public var marked: [HomeScreenGap]

	public init(held: [String: HomeScreenSpot] = [:], marked: [HomeScreenGap] = []) {
		self.held = held
		self.marked = marked
	}

	public var isEmpty: Bool {
		held.isEmpty && marked.isEmpty
	}
}

/// A place on a page, as a write lays it out.
public enum HomeScreenSlot: Equatable, Sendable {
	case item(HomeScreenLayout.Item)
	/// An offloaded app's spot, kept empty: its bundle ID.
	case held(String)
	/// A gap you marked.
	case gap

	/// What a marked gap is kept beside; nil for a gap.
	public var key: String? {
		switch self {
		case .item(let item): item.key
		case .held(let id): id
		case .gap: nil
		}
	}

	var isGap: Bool {
		key == nil
	}

	/// A gap, or an offloaded app's spot: a place a write keeps empty.
	var isEmpty: Bool {
		switch self {
		case .item: false
		case .held, .gap: true
		}
	}
}

/// The pages as a write lays them out, and what became of the gaps you
/// marked.
public struct HomeScreenPlan: Equatable, Sendable {
	/// Each page's places: its icons, folders and widgets, the offloaded
	/// apps' spots and the gaps you marked.
	public var pages: [[HomeScreenSlot]]
	/// The pages that can't keep gaps: with a widget, or with more icons
	/// and gaps than places. Their gaps close.
	public var noGaps: Set<Int>
	/// Each marked gap, and whether it's still there.
	public var marked: [(gap: HomeScreenGap, state: HomeScreenGapState)]
	/// The offloaded apps' spots something came into while they were away,
	/// by bundle ID: what's there now, by key. They're no longer kept
	/// empty, as that would push those icons along (8 Nov 2026).
	public var taken: [String: [String]] = [:]

	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.pages == rhs.pages && lhs.noGaps == rhs.noGaps && lhs.taken == rhs.taken
			&& lhs.marked.map(\.gap) == rhs.marked.map(\.gap) && lhs.marked.map(\.state) == rhs.marked.map(\.state)
	}

	/// The marked gaps still there, on the page they're on now: what Your
	/// Gaps keeps after a write.
	public var kept: [HomeScreenGap] {
		marked.compactMap { gap, state in
			switch state {
			case .kept(let page):
				var kept = gap
				kept.page = page
				return kept
			case .shrank(let now, _):
				return now
			case .filled, .moved, .noRoom:
				return nil
			}
		}
	}

	/// Where on its page each gap goes: by page, from 0, the places in the
	/// page's list each gap goes before, in order. A gap with nothing after
	/// it needs nothing, as iOS leaves the end of a page empty anyway.
	public var gapPlaces: [Int: [Int]] {
		var places: [Int: [Int]] = [:]
		for (page, slots) in pages.enumerated() where !noGaps.contains(page) {
			var index = 0, waiting = 0
			for slot in slots {
				if slot.isEmpty {
					waiting += 1
					continue
				}
				places[page, default: []] += Array(repeating: index, count: waiting)
				waiting = 0
				index += 1
			}
		}
		return places.filter { !$0.value.isEmpty }
	}

	/// The gaps you'd see on `page`, as Open Spaces marks them: each run of
	/// gaps before an icon, folder or offloaded app's spot.
	public static func marked(in slots: [HomeScreenSlot], page: Int) -> [HomeScreenGap] {
		var gaps: [HomeScreenGap] = []
		var after: String?, waiting = 0
		for slot in slots {
			guard let key = slot.key else {
				waiting += 1
				continue
			}
			if waiting > 0 {
				gaps.append(HomeScreenGap(page: page, after: after, before: key, count: waiting))
			}
			after = key
			waiting = 0
		}
		return gaps
	}
}

/// What became of a gap you marked.
public enum HomeScreenGapState: Equatable, Sendable {
	/// Still between its two icons, on this page.
	case kept(page: Int)
	/// Something came between its two icons, as iOS puts a new app in the
	/// first free place: these, by key.
	case filled(by: [String])
	/// Something came into its first places, and the rest is still there:
	/// the gap as it is now, after what came, and what came, by key
	/// (8 Nov 2026).
	case shrank(to: HomeScreenGap, by: [String])
	/// One of its icons left the page, or isn't on the Home Screen.
	case moved
	/// Its page can't keep gaps now: it has a widget, or no room.
	case noRoom(page: Int)

	/// The page it's kept on, if it's kept.
	public var page: Int? {
		switch self {
		case .kept(let page): page
		case .shrank(let gap, _): gap.page
		case .filled, .moved, .noRoom: nil
		}
	}
}

extension HomeScreenLayout {
	/// The pages as a write with `gaps` lays them out.
	public func plan(_ gaps: HomeScreenGaps) -> HomeScreenPlan {
		var slots = pages.map { $0.map(HomeScreenSlot.item) }
		let taken = Self.hold(gaps.held, in: &slots)
		var states: [HomeScreenGapState] = []
		for gap in gaps.marked {
			states.append(Self.mark(gap, in: &slots))
		}
		// A page keeps gaps only with icons and folders on it, and room
		// for them, as iOS fits icons around widgets its own way.
		var noGaps: Set<Int> = []
		for (page, list) in slots.enumerated() {
			let trailing = list.reversed().prefix(while: \.isEmpty).count
			let hasGaps = list.dropLast(trailing).contains(where: \.isEmpty)
			guard hasGaps else { continue }
			let fits = list.count - trailing <= Self.pagePlaces
			let iconsOnly = pages[page].allSatisfy { $0.id != nil || $0.isFolder }
			if !fits || !iconsOnly { noGaps.insert(page) }
		}
		let marked = zip(gaps.marked, states).map { gap, state in
			if let page = state.page, noGaps.contains(page) {
				return (gap: gap, state: HomeScreenGapState.noRoom(page: page))
			}
			return (gap: gap, state: state)
		}
		return HomeScreenPlan(pages: slots, noGaps: noGaps, marked: marked, taken: taken)
	}

	/// What came into `spot` since its app left it, by key: see
	/// `HomeScreenSpot.taken(in:)`. Nil when the spot's icons, page or
	/// folder aren't there to tell.
	public func taken(_ spot: HomeScreenSpot) -> [String]? {
		var items: [Item]
		if let page = spot.page {
			guard pages.indices.contains(page) else { return nil }
			items = pages[page]
		} else {
			items = dock
		}
		if let folder = spot.folder {
			guard let found = items.first(where: { $0.key == "folder:\(folder.name)" }),
			      case .folder(_, let folderPages, _) = found, folderPages.indices.contains(folder.page)
			else { return nil }
			items = folderPages[folder.page]
		}
		return spot.taken(in: items.map(HomeScreenSlot.item))
	}

	/// Puts each offloaded app's spot on its page: after the icon it was
	/// after, or before the one it was before, another offloaded app's
	/// included; left out when neither is there, or the app is there
	/// itself. A spot in the Dock or in a folder gets none. Returns the
	/// spots something came into, which it leaves out too.
	private static func hold(_ held: [String: HomeScreenSpot], in slots: inout [[HomeScreenSlot]]) -> [String: [String]] {
		var taken: [String: [String]] = [:]
		var waiting = held
			.filter { id, spot in
				guard let page = spot.page, spot.folder == nil, slots.indices.contains(page) else { return false }
				return !slots.joined().contains { $0.key == id }
			}
			.sorted { ($0.value.page ?? 0, $0.value.index, $0.key) < ($1.value.page ?? 0, $1.value.index, $1.key) }
		// The icon before comes first, so two spots side by side keep their
		// order; the icon after only once no spot can go after its icon.
		while !waiting.isEmpty {
			let after: Bool
			if let found = waiting.firstIndex(where: { place($0.value, after: true, in: slots) != nil }) {
				waiting.swapAt(0, found)
				after = true
			} else if let found = waiting.firstIndex(where: { place($0.value, after: false, in: slots) != nil }) {
				waiting.swapAt(0, found)
				after = false
			} else {
				break
			}
			let (id, spot) = waiting.removeFirst()
			if let keys = spot.taken(in: slots[spot.page!]), !keys.isEmpty {
				taken[id] = keys
				continue
			}
			slots[spot.page!].insert(.held(id), at: place(spot, after: after, in: slots)!)
		}
		return taken
	}

	/// Where `spot` goes on its page: after its previous icon, or before
	/// its next one.
	private static func place(_ spot: HomeScreenSpot, after: Bool, in slots: [[HomeScreenSlot]]) -> Int? {
		let list = slots[spot.page!]
		if after {
			guard let previous = spot.previous, let found = list.firstIndex(where: { $0.key == previous }) else { return nil }
			return found + 1
		}
		guard let next = spot.next, let found = list.firstIndex(where: { $0.key == next }) else { return nil }
		return found
	}

	/// Puts `gap` before its icon when the icon before that is still its
	/// other one, and says what became of it. When fewer places came
	/// between the two than the gap had, they took its first ones, as iOS
	/// puts a new app in the first free place, and the rest is still there.
	private static func mark(_ gap: HomeScreenGap, in slots: inout [[HomeScreenSlot]]) -> HomeScreenGapState {
		let count = max(gap.count, 1)
		for (page, list) in slots.enumerated() {
			guard let index = list.firstIndex(where: { $0.key == gap.before }) else { continue }
			let previous = list[..<index].lastIndex { !$0.isGap }
			let previousKey = previous.flatMap { list[$0].key }
			if previousKey == gap.after {
				slots[page].insert(contentsOf: Array(repeating: .gap, count: count), at: index)
				return .kept(page: page)
			}
			let came: ArraySlice<HomeScreenSlot>
			if let after = gap.after, let found = list[..<index].firstIndex(where: { $0.key == after }) {
				came = list[(found + 1)..<index]
			} else if gap.after == nil {
				came = list[..<index]
			} else {
				return .moved
			}
			let keys = came.compactMap(\.key)
			guard came.count < count else { return .filled(by: keys) }
			slots[page].insert(contentsOf: Array(repeating: .gap, count: count - came.count), at: index)
			let now = HomeScreenGap(page: page, after: previousKey, before: gap.before, count: count - came.count)
			return .shrank(to: now, by: keys)
		}
		return .moved
	}
}

extension HomeScreenSpot {
	/// What came into the spot since its app left it, by key, in `slots`,
	/// its list without the app: the icons and folders now between the two
	/// it was between, before the one it was before at the start of its
	/// list, or after the one it was after at its end. Empty when nothing
	/// came; nil when its icons aren't there to tell, or swapped.
	public func taken(in slots: [HomeScreenSlot]) -> [String]? {
		func at(_ key: String) -> Int? { slots.firstIndex { $0.key == key } }
		let between: Range<Int>
		switch (previous, next) {
		case let (previous?, next?):
			guard let before = at(previous), let after = at(next), before < after else { return nil }
			between = (before + 1)..<after
		case (nil, let next?):
			guard let after = at(next) else { return nil }
			between = 0..<after
		case (let previous?, nil):
			guard let before = at(previous) else { return nil }
			between = (before + 1)..<slots.count
		case (nil, nil):
			return nil
		}
		return slots[between].compactMap { slot in
			if case .item(let item) = slot { return item.key }
			return nil
		}
	}
}
