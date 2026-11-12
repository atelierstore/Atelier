import AtelierCore
import Foundation
import InstallKit
import Observation
import UIKit

/// Open Spaces' pages (7 Nov 2026): the Home Screen as a read finds
/// it, its apps packed together as iOS reports them, with the spots Offload
/// keeps empty and the gaps you marked. Tapping an app puts a gap before
/// it; tapping a gap takes it out. Find Open Spaces Automatically marks
/// the ones a screenshot of the page shows (11 Nov 2026). Each page's marks
/// replace the ones it had, and nothing is written to the iPhone.
@MainActor
@Observable
final class YourGapsModel {
	enum State: Equatable {
		case reading
		case failed(String)
		case ready
	}

	/// Where a place goes on its page's grid of 4 columns, as iOS fits
	/// icons around widgets: each in the first free place, row by row.
	struct Cell: Identifiable, Equatable {
		/// Its place in the page's list.
		var index: Int
		var column: Int
		var row: Int
		var columns = 1
		var rows = 1

		var id: Int { index }
	}

	private(set) var state: State = .reading
	private(set) var screen: HomeScreenState?
	/// Each page's places, as you mark them.
	private(set) var pages: [[HomeScreenSlot]] = []
	/// The page shown, from 0.
	var page = 0 {
		didSet {
			guard page != oldValue else { return }
			notice = nil
			Task { await loadIcons() }
		}
	}
	/// SpringBoard's icons, by bundle ID.
	private(set) var icons: [String: UIImage] = [:]
	/// Why the last tap didn't put a gap in.
	private(set) var notice: String?
	/// Find Open Spaces Automatically's last look at each page.
	private(set) var findings: [Int: Finding] = [:]

	enum Finding: Equatable {
		case looking
		/// It marked `count` open spaces at `date`. `doubtful` when some
		/// places were hard to tell from icons; `cameBack` when Atelier came
		/// back to the front by itself.
		case found(count: Int, at: Date, doubtful: Bool, cameBack: Bool)
		/// What it says when a step failed.
		case failed(String)
	}

	/// The gaps kept for each page when it was read, which its marks
	/// replace: those a write would still keep there, and those last seen
	/// there that a write wouldn't.
	private var kept: [Int: [HomeScreenGap]] = [:]
	/// The icons asked for, got or not.
	private var asked: Set<String> = []
	private let installer = RouteASetup.shared.makeInstaller()

	/// Reads the Home Screen, through LocalDevVPN, and lays out its pages.
	func load() async {
		state = .reading
		if case .unavailable(let why) = await installer.check(startingVPN: true) {
			state = .failed(why)
			return
		}
		do {
			let screen = try await installer.homeScreen()
			let plan = screen.layout.plan(YourGaps.gaps(installed: screen.apps))
			self.screen = screen
			kept = [:]
			for (gap, state) in plan.marked {
				switch state {
				case .kept(let page), .noRoom(let page): kept[page, default: []].append(gap)
				case .shrank(let now, _): kept[now.page, default: []].append(gap)
				case .filled, .moved: kept[gap.page, default: []].append(gap)
				}
			}
			// A page with a widget shows no gaps, as it keeps none.
			pages = plan.pages.enumerated().map { page, slots in
				Self.canMark(screen.layout.pages[page]) ? slots : slots.filter { $0 != .gap }
			}
			page = min(page, max(pages.count - 1, 0))
			state = .ready
			await loadIcons()
		} catch {
			state = .failed(HomeScreenSpots.why(error))
		}
	}

	// MARK: The page shown

	var slots: [HomeScreenSlot] {
		slots(of: page)
	}

	/// Whether the page shown can keep gaps.
	var canMark: Bool {
		canMark(page: page)
	}

	/// A page's places, as you mark them.
	func slots(of page: Int) -> [HomeScreenSlot] {
		pages.indices.contains(page) ? pages[page] : []
	}

	/// Whether a page can keep gaps: icons and folders only.
	func canMark(page: Int) -> Bool {
		guard let screen, screen.layout.pages.indices.contains(page) else { return false }
		return Self.canMark(screen.layout.pages[page])
	}

	/// The gaps marked on the page shown: each empty place counts.
	var gapCount: Int {
		slots.filter { $0 == .gap }.count
	}

	/// Whether every place on the page shown is taken, by its apps and
	/// folders and the offloaded apps' spots, so it has no open spaces.
	var isFull: Bool {
		slots.filter { $0 != .gap }.count >= HomeScreenLayout.pagePlaces
	}

	/// Whether the page shown might have open spaces: icons and folders
	/// only, and not full.
	var mightHaveOpenSpaces: Bool {
		canMark && !isFull
	}

	/// Find Open Spaces Automatically's last look at the page shown.
	var finding: Finding? {
		findings[page]
	}

	/// Whether Find Open Spaces Automatically is looking at a page.
	var isFinding: Bool {
		findings.values.contains(.looking)
	}

	/// Puts a gap before the place at `index` on `page`, or takes the gap
	/// there out.
	func tap(_ index: Int, on page: Int) {
		guard canMark(page: page), pages.indices.contains(page), pages[page].indices.contains(index) else { return }
		var slots = pages[page]
		if slots[index] == .gap {
			slots.remove(at: index)
		} else {
			slots.insert(.gap, at: index)
			// Space after the last icon doesn't count: iOS leaves it empty.
			let trailing = slots.reversed().prefix { $0 == .gap || Self.isHeld($0) }.count
			if slots.count - trailing > HomeScreenLayout.pagePlaces {
				let last = slots.last { $0 != .gap }.map(name) ?? "an app"
				notice = "Page \(page + 1) is full: an open space would push \(last) off it."
				return
			}
		}
		notice = nil
		pages[page] = slots
		save(page: page)
	}

	/// Has Atelier look at the page shown on the Home Screen, and marks the
	/// open spaces it sees there, as if they were tapped.
	func findOpenSpaces() async {
		let page = page
		guard mightHaveOpenSpaces, !isFinding, let screen else { return }
		findings[page] = .looking
		do {
			let counts: [Int?] = screen.layout.pages.map { Self.canMark($0) ? $0.count : nil }
			let target = HomeScreenLook.Target(page: page, icons: await itemIcons(page), counts: counts)
			let look = try await HomeScreenLook.look(at: target)
			guard let reading = look.reading,
			      let marked = OpenSpacesFinder.slots(pages[page], empty: reading.empty) else {
				findings[page] = .failed("Couldn’t look at your Home Screen: Atelier couldn’t make out page \(page + 1) in the screenshot. Mark them by hand, or try again.")
				return
			}
			if self.page == page { notice = nil }
			pages[page] = marked
			save(page: page)
			let count = marked.filter { $0 == .gap }.count
			findings[page] = .found(count: count, at: .now, doubtful: reading.isDoubtful, cameBack: look.cameBack)
		} catch let failure as HomeScreenLook.Failure {
			findings[page] = .failed(failure.message)
		} catch {
			findings[page] = .failed("Couldn’t look at your Home Screen: \(HomeScreenSpots.why(error)). Mark them by hand, or try again.")
		}
	}

	/// The name under a place: an app's, a folder's, or a widget's app's.
	func name(_ slot: HomeScreenSlot) -> String {
		switch slot {
		case .item(.icon(let id, let raw)):
			return screen?.names[id] ?? raw.values["displayName"] as? String ?? id
		case .item(.folder(let name, _, _)):
			return name
		case .item(.widget(let raw)):
			let container = raw.values["containerBundleIdentifier"] as? String
			return container.flatMap { screen?.names[$0] } ?? "Widget"
		case .item(.other):
			return ""
		case .held(let id):
			return HomeScreenSpots.noted(id)?.name ?? screen?.names[id] ?? id
		case .gap:
			return "Open space"
		}
	}

	// MARK: Helpers

	/// The page's items in order, as Find Open Spaces Automatically looks
	/// for them: each app's icon as SpringBoard draws it, asked for now if
	/// it hasn't come yet, or nil for a folder.
	private func itemIcons(_ page: Int) async -> [OpenSpacesFinder.Pixels?] {
		var ids: [String?] = []
		for slot in pages[page] {
			guard case .item(let item) = slot else { continue }
			if case .icon(let id, _) = item {
				ids.append(id)
			} else {
				ids.append(nil)
			}
		}
		let missing = ids.compactMap { $0 }.filter { icons[$0] == nil }
		if !missing.isEmpty, let pngs = try? await installer.homeScreenIcons(missing) {
			for (id, png) in pngs {
				icons[id] = UIImage(data: png)
			}
		}
		return ids.map { id in
			guard let id, let image = icons[id]?.cgImage else { return nil }
			return OpenSpacesFinder.Pixels(image: image, width: 96)
		}
	}

	/// Replaces the page's gaps with the ones marked on it now.
	private func save(page: Int) {
		let now = HomeScreenPlan.marked(in: pages[page], page: page)
		let before = kept[page] ?? []
		var marked = YourGaps.marked
		marked.removeAll { before.contains($0) }
		marked += now
		YourGaps.marked = marked
		kept[page] = now
		// You've seen them, so the first Offload needn't ask.
		GapsQuestion.isAnswered = true
	}

	/// Asks SpringBoard for the icons not asked for yet, of the page shown
	/// and then of the pages beside it, which a swipe brings in: their apps'
	/// and the first nine of each folder's.
	private func loadIcons() async {
		let shown = page
		for page in [shown, shown + 1, shown - 1] where pages.indices.contains(page) {
			var ids: [String] = []
			for slot in pages[page] {
				switch slot {
				case .item(.icon(let id, _)): ids.append(id)
				case .item(.folder(_, let folderPages, _)): ids += (folderPages.first ?? []).prefix(9).compactMap(\.id)
				default: break
				}
			}
			let wanted = ids.filter { !asked.contains($0) }
			guard !wanted.isEmpty else { continue }
			asked.formUnion(wanted)
			guard let pngs = try? await installer.homeScreenIcons(wanted) else { continue }
			for (id, png) in pngs {
				icons[id] = UIImage(data: png)
			}
		}
	}

	private static func canMark(_ items: [HomeScreenLayout.Item]) -> Bool {
		items.allSatisfy { item in
			switch item {
			case .icon, .folder: true
			case .widget, .other: false
			}
		}
	}

	private static func isHeld(_ slot: HomeScreenSlot) -> Bool {
		if case .held = slot { return true }
		return false
	}

	/// Each place in the first free spot of a 4-column grid, row by row:
	/// a widget takes 2 by 2 (small), 4 by 2 (medium) or 4 by 4 (large).
	static func cells(_ slots: [HomeScreenSlot]) -> (cells: [Cell], rows: Int) {
		var taken: Set<[Int]> = []
		var cells: [Cell] = []
		var rows = 0
		for (index, slot) in slots.enumerated() {
			var size = (columns: 1, rows: 1)
			if case .item(.widget(let raw)) = slot {
				switch (raw.values["gridSize"] as? String)?.lowercased() {
				case "medium": size = (4, 2)
				case "large", "extralarge": size = (4, 4)
				default: size = (2, 2)
				}
			}
			var row = 0, column = 0
			search: while true {
				for start in 0...(4 - size.columns) {
					let free = (row..<(row + size.rows)).allSatisfy { r in
						(start..<(start + size.columns)).allSatisfy { !taken.contains([r, $0]) }
					}
					if free {
						column = start
						break search
					}
				}
				row += 1
			}
			for r in row..<(row + size.rows) {
				for c in column..<(column + size.columns) { taken.insert([r, c]) }
			}
			cells.append(Cell(index: index, column: column, row: row, columns: size.columns, rows: size.rows))
			rows = max(rows, row + size.rows)
		}
		return (cells, rows)
	}
}
