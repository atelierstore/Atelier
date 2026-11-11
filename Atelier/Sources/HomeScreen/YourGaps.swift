import Foundation
import InstallKit

/// The gaps you marked between icons (Open Spaces, 7 Nov 2026), which
/// iOS doesn't report, so a write would close them. Every write sends them
/// with the offloaded apps' spots, then keeps the ones still there: a gap
/// something came into, or whose icons moved apart, is gone from the
/// iPhone too.
@MainActor
enum YourGaps {
	/// A JSON `[HomeScreenGap]`.
	static let key = "homeScreenGaps"

	static var marked: [HomeScreenGap] {
		get { decode(UserDefaults.standard.data(forKey: key)) }
		set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
	}

	/// The gaps kept as `data`, as Settings' `@AppStorage` has them.
	static func decode(_ data: Data?) -> [HomeScreenGap] {
		guard let data else { return [] }
		return (try? JSONDecoder().decode([HomeScreenGap].self, from: data)) ?? []
	}

	/// What a write sends: the spots Offload keeps empty for apps still
	/// away, and your gaps.
	static func gaps(installed: [HomeScreenApp]) -> HomeScreenGaps {
		HomeScreenGaps(held: HomeScreenSpots.heldGaps(installed: installed), marked: marked)
	}

	/// After a write of `layout` with `gaps`: keeps your gaps it kept, on
	/// the page they're on now, and the places left of any something took
	/// part of, and says why it didn't keep the others.
	/// Gaps marked since `gaps` was made stay as they are. An offloaded
	/// app's spot something came into is no longer kept empty.
	static func written(_ layout: HomeScreenLayout, gaps: HomeScreenGaps, names: [String: String], say: @MainActor (String) -> Void) {
		guard !gaps.isEmpty else { return }
		let plan = layout.plan(gaps)
		for (id, keys) in plan.taken.sorted(by: { $0.key < $1.key }) {
			let app = HomeScreenSpots.release(id) ?? names[id] ?? id
			let spot = gaps.held[id].map { " at \(HomeScreenSpots.text($0))" } ?? ""
			say("\(Self.names(keys, names)) took \(app)'s spot\(spot) meanwhile, so it's no longer kept empty")
		}
		var now = marked
		for (gap, state) in plan.marked {
			guard let index = now.firstIndex(of: gap) else { continue }
			switch state {
			case .kept(let page):
				now[index].page = page
				continue
			case .shrank(let kept, _):
				now[index] = kept
			case .filled, .moved, .noRoom:
				now.remove(at: index)
			}
			say(told(gap, state, names: names))
		}
		marked = now
	}

	/// ", and your 3 open spaces", or nothing for none kept: each empty place
	/// counts.
	static func kept(_ layout: HomeScreenLayout, _ gaps: HomeScreenGaps) -> String {
		let plan = layout.plan(gaps)
		let places = plan.kept.reduce(0) { $0 + $1.count }
		switch places {
		case 0: return ""
		case 1: return ", and your open space"
		default: return ", and your \(places) open spaces"
		}
	}

	/// "3 on 2 pages", "1 on page 9", or "None", for Settings. Each empty
	/// place counts.
	static func summary(_ gaps: [HomeScreenGap]) -> String {
		let places = gaps.reduce(0) { $0 + $1.count }
		let pages = Set(gaps.map(\.page))
		switch (places, pages.count) {
		case (0, _): return "None"
		case (_, 1): return "\(places) on page \(pages.first! + 1)"
		default: return "\(places) on \(pages.count) pages"
		}
	}

	/// Why a write didn't keep `gap` as it was, for the log.
	private static func told(_ gap: HomeScreenGap, _ state: HomeScreenGapState, names: [String: String]) -> String {
		let which = "your open space before \(name(gap.before, names)) on page \(gap.page + 1)"
		switch state {
		case .kept:
			return "\(which) is kept"
		case .filled(let keys):
			let what = keys.map { name($0, names) }.joined(separator: ", ")
			return "\(which) has \(what) in it now, so it's no longer kept"
		case .shrank(let kept, let keys):
			let what = keys.map { name($0, names) }.joined(separator: ", ")
			let rest = kept.count == 1 ? "its other place is kept" : "its other \(kept.count) places are kept"
			return "\(which) has \(what) in it now, so \(rest)"
		case .moved:
			let icons = [gap.after, gap.before].compactMap { $0 }.map { name($0, names) }.joined(separator: " or ")
			return "\(which) is gone: \(icons) moved, so it's no longer kept"
		case .noRoom(let page):
			return "\(which) closed: page \(page + 1) has a widget or no room now"
		}
	}

	/// "Tickets", "Tickets and Maps": what `keys` are, by name.
	static func names(_ keys: [String], _ names: [String: String]) -> String {
		keys.map { name($0, names) }.formatted(.list(type: .and))
	}

	/// An app's name, or a folder's.
	static func name(_ key: String, _ names: [String: String]) -> String {
		if key.hasPrefix("folder:") { return String(key.dropFirst("folder:".count)) }
		return names[key] ?? key
	}
}
