import Foundation
import XCTest
@testable import InstallKit

/// A made-up Home Screen screenshot, read at `OpenSpacesFinder.readingWidth`:
/// a smooth or folded wallpaper and rounded icons, each app with a glyph of
/// its own, at a known grid.
private struct Screen {
	static let width = OpenSpacesFinder.readingWidth
	static let height = 1279
	static let pitch = 140.0
	static let middle = Double(width) / 2
	static let columns = OpenSpacesFinder.positions(4, from: middle - 1.5 * pitch, every: pitch)

	var rows = OpenSpacesFinder.positions(6, from: 178, every: pitch)
	/// The places with an icon, row by row.
	var icons: Set<Int>
	/// An icon's side: 98 as iOS draws icons with names, 112 when they're
	/// large, without names.
	var icon = 98.0
	/// Folds, like iOS 26's wallpaper: soft light and shade, and a sharp
	/// bright crease along each fold, some across the empty places.
	var folds = false
	/// Names under the icons, as iOS shows them unless they're hidden.
	var labels = false
	/// Icons drawn as dark mode draws them: near black, with a coloured glyph.
	var dark = false
	/// Places whose icon is drawn in nearly the wallpaper's colour.
	var dim: Set<Int> = []

	var grid: OpenSpacesFinder.Grid {
		OpenSpacesFinder.Grid(columns: Self.columns, rows: rows, half: icon / 2)
	}

	var pixels: OpenSpacesFinder.Pixels {
		var rgba = [UInt8](repeating: 255, count: Self.width * Self.height * 4)
		func put(_ x: Int, _ y: Int, _ colour: (Double, Double, Double)) {
			guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
			let i = (y * Self.width + x) * 4
			rgba[i] = UInt8(max(0, min(255, colour.0)))
			rgba[i + 1] = UInt8(max(0, min(255, colour.1)))
			rgba[i + 2] = UInt8(max(0, min(255, colour.2)))
		}
		for y in 0..<Self.height {
			for x in 0..<Self.width { put(x, y, wallpaper(x, y)) }
		}
		let half = icon / 2
		for place in icons.sorted() {
			let cx = Self.columns[place % 4], cy = rows[place / 4]
			let look: Look
			if dim.contains(place) {
				let behind = wallpaper(Int(cx), Int(cy))
				look = .dim(behind)
			} else {
				look = dark ? .dark : .plain
			}
			for y in Int(cy - half)..<Int(cy + half) {
				for x in Int(cx - half)..<Int(cx + half) {
					let u = (Double(x) + 0.5 - cx) / icon, v = (Double(y) + 0.5 - cy) / icon
					if let colour = Self.colour(of: place, u, v, look) { put(x, y, colour) }
				}
			}
			if labels {
				// Strokes of text, centred under the icon.
				let top = Int(cy + half + 7), bottom = top + 11
				let letters = 4 + place % 5
				let from = Int(cx) - letters * 4
				for y in top..<bottom {
					for x in from..<(from + letters * 8) where (x - from) % 4 < 2 || y == top || y == bottom - 1 {
						put(x, y, (245, 245, 245))
					}
				}
			}
		}
		return OpenSpacesFinder.Pixels(width: Self.width, height: Self.height, rgba: rgba)
	}

	/// How an icon is drawn: in its own colours, as dark mode draws it,
	/// or in nearly the colour of the wallpaper behind it.
	enum Look {
		case plain, dark
		case dim((Double, Double, Double))
	}

	/// An app's glyph: a ring, and a bar across or down, each its own size
	/// and place for each app, in icon sides from the icon's middle.
	struct Glyph {
		var x: Double, y: Double, radius: Double
		var across: Bool, offset: Double, length: Double

		init(_ app: Int) {
			var seed = UInt64(app + 1) &* 0x9E37_79B9_7F4A_7C15
			func next() -> Double {
				seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
				return Double(seed >> 11) / Double(1 << 53)
			}
			x = 0.24 * next() - 0.12
			y = 0.24 * next() - 0.12
			radius = 0.08 + 0.14 * next()
			across = next() < 0.5
			offset = 0.5 * next() - 0.25
			length = 0.15 + 0.2 * next()
		}

		func covers(_ u: Double, _ v: Double) -> Bool {
			let r = ((u - x) * (u - x) + (v - y) * (v - y)).squareRoot()
			if abs(r - radius) < 0.035 { return true }
			return across
				? abs(v - offset) < 0.035 && abs(u) < length
				: abs(u - offset) < 0.035 && abs(v) < length
		}
	}

	/// The colour of the icon of the app at `place` at (`u`, `v`), from its
	/// middle, in icon sides: nil outside its rounded square.
	static func colour(of place: Int, _ u: Double, _ v: Double, _ look: Look) -> (Double, Double, Double)? {
		let half = 0.5, corner = 0.225
		let du = max(abs(u) - (half - corner), 0), dv = max(abs(v) - (half - corner), 0)
		guard du * du + dv * dv <= corner * corner else { return nil }
		let isGlyph = Glyph(place).covers(u, v)
		let hue = Double(place * 37 % 255)
		switch look {
		case .plain:
			return isGlyph ? (250, 250, 250) : (hue, 120, 255 - hue)
		case .dark:
			return isGlyph ? (hue, 255 - hue, 160) : (18, 18, 22)
		case .dim(let behind):
			let lift = isGlyph ? 14.0 : 6.0
			return (behind.0 + lift, behind.1 + lift, behind.2 + lift)
		}
	}

	/// The icon of the app at `place` as SpringBoard draws it: `side`
	/// pixels across, in its own colours, its corners clear.
	static func appIcon(_ place: Int, side: Int = 120) -> OpenSpacesFinder.Pixels {
		var rgba = [UInt8](repeating: 0, count: side * side * 4)
		for y in 0..<side {
			for x in 0..<side {
				let u = (Double(x) + 0.5) / Double(side) - 0.5, v = (Double(y) + 0.5) / Double(side) - 0.5
				guard let colour = colour(of: place, u, v, .plain) else { continue }
				let i = (y * side + x) * 4
				rgba[i] = UInt8(colour.0)
				rgba[i + 1] = UInt8(colour.1)
				rgba[i + 2] = UInt8(colour.2)
				rgba[i + 3] = 255
			}
		}
		return OpenSpacesFinder.Pixels(width: side, height: side, rgba: rgba)
	}

	func wallpaper(_ x: Int, _ y: Int) -> (Double, Double, Double) {
		guard folds else {
			let u = Double(x) / Double(Self.width), v = Double(y) / Double(Self.height)
			let glow = exp(-((u - 0.8) * (u - 0.8) + (v - 0.15) * (v - 0.15)) * 4)
			return (40 + 70 * v + 50 * glow, 30 + 30 * u + 40 * glow, 70 + 90 * (1 - v) + 30 * glow)
		}
		let u = Double(x), v = Double(y)
		var light = 110.0
		// Folds across the page, each lit on one side and shaded on the other.
		for fold in 0..<4 {
			let crease = 120 + Double(fold) * 300 + 90 * sin(u / 130 + Double(fold) * 1.7)
			let d = v - crease
			light += d > 0 ? 45 * exp(-d / 60) : -35 * exp(d / 90)
			light += 95 * exp(-(d * d) / 2.5)
		}
		// And one down the page, through the middle columns.
		let d = u - (300 + 60 * sin(v / 150))
		light += d > 0 ? 40 * exp(-d / 50) : -30 * exp(d / 70)
		light += 95 * exp(-(d * d) / 2.5)
		return (light + 25, light + 12, light)
	}
}

final class OpenSpacesFinderTests: XCTestCase {
	private func assertGrid(_ found: OpenSpacesFinder.Grid?, near screen: Screen, within tolerance: Double = 3, file: StaticString = #filePath, line: UInt = #line) {
		guard let found else { return XCTFail("no grid", file: file, line: line) }
		for (got, want) in zip(found.columns, Screen.columns) {
			XCTAssertEqual(got, want, accuracy: 2, "columns \(found.columns)", file: file, line: line)
		}
		for (got, want) in zip(found.rows, screen.rows) {
			XCTAssertEqual(got, want, accuracy: tolerance, "rows \(found.rows)", file: file, line: line)
		}
		XCTAssertEqual(found.half, screen.icon / 2, accuracy: 2, file: file, line: line)
	}

	func testFindsTheGridOfAFullPage() {
		let screen = Screen(icons: Set(0..<23))
		assertGrid(OpenSpacesFinder.grid(in: screen.pixels, items: 23), near: screen)
	}

	func testFindsTheGridOfADarkPage() {
		let screen = Screen(icons: Set(0..<20), dark: true)
		assertGrid(OpenSpacesFinder.grid(in: screen.pixels, items: 20), near: screen)
	}

	func testFindsTheGridWithNamesUnderTheIcons() {
		// With names, rows are further apart than columns.
		var screen = Screen(icons: Set(0..<22), labels: true)
		screen.rows = OpenSpacesFinder.positions(6, from: 165, every: 156)
		assertGrid(OpenSpacesFinder.grid(in: screen.pixels, items: 22), near: screen, within: 4)
	}

	func testFindsTheOpenSpacesBeforeThePagesLastApp() throws {
		// 19 apps, 4 open spaces, then one more app.
		let screen = Screen(icons: Set(0..<19).union([23]))
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 20))
		XCTAssertEqual(reading.empty, [19, 20, 21, 22])
		XCTAssertEqual(reading.openSpaces, [19, 20, 21, 22])
		XCTAssertFalse(reading.isDoubtful, "scores \(reading.scores)")
	}

	func testRoomAfterTheLastAppIsntAnOpenSpace() throws {
		let screen = Screen(icons: Set(0..<10))
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 10))
		XCTAssertEqual(reading.empty, Array(10..<24))
		XCTAssertEqual(reading.openSpaces, [])
		XCTAssertFalse(reading.isDoubtful, "scores \(reading.scores)")
	}

	func testAnEmptyFirstRow() throws {
		let screen = Screen(icons: Set(4..<24))
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 20))
		XCTAssertEqual(reading.openSpaces, [0, 1, 2, 3])
		XCTAssertFalse(reading.isDoubtful, "scores \(reading.scores)")
	}

	func testScattersOpenSpacesOnADarkPageWithNames() throws {
		var screen = Screen(icons: Set(0..<24).subtracting([1, 6, 7, 13]).subtracting(20..<24), labels: true, dark: true)
		screen.rows = OpenSpacesFinder.positions(6, from: 165, every: 156)
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: screen.icons.count))
		XCTAssertEqual(reading.openSpaces, [1, 6, 7, 13])
	}

	func testTwoLargeAppsOnFolds() throws {
		// Large icons without names, and the wallpaper's creases across the
		// empty places between them.
		let screen = Screen(icons: [0, 3], icon: 112, folds: true)
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 2))
		XCTAssertEqual(reading.openSpaces, [1, 2], "scores \(reading.scores)")
		XCTAssertFalse(reading.isDoubtful, "scores \(reading.scores)")
	}

	func testFindsAppsByTheirIcons() throws {
		// A page with a folder at place 1, apps around it, and open spaces
		// at 3 and 4, with each app's icon as SpringBoard draws it.
		let screen = Screen(icons: [0, 1, 2, 5, 6, 7], icon: 112, folds: true)
		let icons: [OpenSpacesFinder.Pixels?] = [Screen.appIcon(0), nil, Screen.appIcon(2), Screen.appIcon(5), Screen.appIcon(6), Screen.appIcon(7)]
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, icons: icons))
		XCTAssertEqual(reading.places, [0, 1, 2, 5, 6, 7])
		XCTAssertEqual(reading.openSpaces, [3, 4])
		XCTAssertEqual(reading.iconsFound, 5)
		XCTAssertFalse(reading.isDoubtful, "likeness \(reading.likeness), scores \(reading.scores)")
	}

	func testFindsAnAppWhoseOutlineHardlyShows() throws {
		// An app drawn in nearly the wallpaper's colour, as a dark icon on a
		// dark wallpaper is: its glyph still shows where it is.
		let screen = Screen(icons: [0, 2, 3], dim: [2])
		let icons = [0, 2, 3].map { Optional(Screen.appIcon($0)) }
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, icons: icons))
		XCTAssertEqual(reading.places, [0, 2, 3])
		XCTAssertEqual(reading.openSpaces, [1])
		XCTAssertFalse(reading.isDoubtful, "likeness \(reading.likeness), scores \(reading.scores)")
	}

	func testFindsAppsInDarkMode() throws {
		// Dark mode draws the icons near black with a coloured glyph, unlike
		// SpringBoard's picture of them; the glyphs are where they were.
		let screen = Screen(icons: Set([0, 1, 4, 9]), dark: true)
		let icons = [0, 1, 4, 9].map { Optional(Screen.appIcon($0)) }
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, icons: icons))
		XCTAssertEqual(reading.openSpaces, [2, 3, 5, 6, 7, 8])
		XCTAssertFalse(reading.isDoubtful, "likeness \(reading.likeness), scores \(reading.scores)")
	}

	func testAnotherPagesAppsArentFound() throws {
		// The screenshot shows another page than the one looked for.
		let screen = Screen(icons: Set(10..<16))
		let icons = (0..<6).map { Optional(Screen.appIcon($0)) }
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, icons: icons))
		XCTAssertLessThan(reading.iconsFound * 2, reading.iconsKnown, "likeness \(reading.likeness)")
		XCTAssertTrue(reading.isDoubtful)
	}

	func testAPageOfFewAppsReadsWithTheGridFoundBefore() throws {
		let screen = Screen(icons: [0, 2])
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 2, known: screen.grid))
		XCTAssertEqual(reading.openSpaces, [1])
	}

	func testAnIconLikeTheWallpaperIsDoubtful() throws {
		let screen = Screen(icons: Set(0..<20), dim: [5])
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: 20, known: screen.grid))
		XCTAssertTrue(reading.isDoubtful, "scores \(reading.scores)")
	}

	func testDoubtComesFromTheScores() {
		let grid = Screen(icons: []).grid
		var scores = [Double](repeating: 40, count: 24)
		for place in 20..<24 { scores[place] = 2 }
		let folders = [[Double]?](repeating: nil, count: 20)
		XCTAssertFalse(OpenSpacesFinder.reading(scores: scores, likeness: folders, grid: grid).isDoubtful)
		// An outline at a place left empty.
		scores[21] = 20
		XCTAssertTrue(OpenSpacesFinder.reading(scores: scores, likeness: folders, grid: grid).isDoubtful)
		// A folder's place without one.
		scores[21] = 2
		scores[4] = 10
		XCTAssertTrue(OpenSpacesFinder.reading(scores: scores, likeness: folders, grid: grid).isDoubtful)
	}

	func testAnAppsIconPlacesItWhereItsOutlineIsFaint() {
		// A folder, then an app, and two places after the folder that could
		// each be the app's: its icon is found at place 2, so place 1 is
		// empty.
		let grid = Screen(icons: []).grid
		var scores = [Double](repeating: 1, count: 24)
		scores[0] = 40
		scores[1] = 11
		scores[2] = 11
		var second = [Double](repeating: 0.1, count: 24)
		second[2] = 0.9
		let reading = OpenSpacesFinder.reading(scores: scores, likeness: [nil, second], grid: grid)
		XCTAssertEqual(reading.places, [0, 2])
		XCTAssertEqual(reading.openSpaces, [1])
		XCTAssertFalse(reading.isDoubtful)
		// Without the app's icon to go by, place 1 is as likely.
		XCTAssertTrue(OpenSpacesFinder.reading(scores: scores, likeness: [nil, nil], grid: grid).isDoubtful)
	}

	func testAPlainPictureHasNoGrid() {
		let plain = OpenSpacesFinder.Pixels(width: Screen.width, height: Screen.height, rgba: [UInt8](repeating: 90, count: Screen.width * Screen.height * 4))
		XCTAssertNil(OpenSpacesFinder.grid(in: plain, items: 3))
	}

	func testTellsWhichPageAScreenshotShows() {
		let counts: [Int?] = [20, 24, nil, 24, 7, 3]
		XCTAssertEqual(OpenSpacesFinder.page(showing: 7, near: 4, counts: counts), 4)
		// One swipe short, or one too many.
		XCTAssertEqual(OpenSpacesFinder.page(showing: 24, near: 4, counts: counts), 3)
		XCTAssertEqual(OpenSpacesFinder.page(showing: 3, near: 4, counts: counts), 5)
		// Pages either side with as many items, or none with that many.
		XCTAssertNil(OpenSpacesFinder.page(showing: 24, near: 2, counts: counts))
		XCTAssertNil(OpenSpacesFinder.page(showing: 12, near: 4, counts: counts))
	}

	func testTellsWhereASlideLanded() {
		// Page 11 has 3 items, and the slide landed on page 9, the only
		// other with 23.
		let counts: [Int?] = [24, 24, nil, 24, 24, 22, 24, 24, 23, 24, 3]
		let others = counts.indices.filter { $0 != 10 }
		XCTAssertEqual(OpenSpacesFinder.page(showing: 23, among: others, counts: counts), 8)
		XCTAssertEqual(OpenSpacesFinder.page(showing: 22, among: others, counts: counts), 5)
		// Full pages, which most are, don't tell.
		XCTAssertNil(OpenSpacesFinder.page(showing: 24, among: others, counts: counts))
		// Nor does the page it went to, when its apps' icons didn't show.
		XCTAssertNil(OpenSpacesFinder.page(showing: 3, among: others, counts: counts))
	}

	// MARK: Marking what it found

	private func app(_ id: String) -> HomeScreenSlot {
		.item(.icon(id: id, raw: PlistDictionary(["bundleIdentifier": id])))
	}

	func testPutsTheOpenSpacesBeforeTheirApps() {
		let slots = (0..<20).map { app("a\($0)") }
		let marked = OpenSpacesFinder.slots(slots, empty: [19, 20, 21, 22])
		let expected: [HomeScreenSlot] = Array(slots.prefix(19)) + [HomeScreenSlot](repeating: .gap, count: 4) + [slots[19]]
		XCTAssertEqual(marked, expected)
	}

	func testReplacesThePagesGaps() {
		let slots = [app("a"), .gap, .gap, app("b"), app("c"), .gap]
		// a, an open space, then b and c.
		XCTAssertEqual(OpenSpacesFinder.slots(slots, empty: [1] + Array(4..<24)), [app("a"), .gap, app("b"), app("c")])
	}

	func testAnOffloadedAppsSpotLooksEmptyToo() {
		let slots = [app("a"), .held("x"), app("b"), .held("y")]
		// A spot for x, and an open space after it.
		XCTAssertEqual(OpenSpacesFinder.slots(slots, empty: [1, 2] + Array(4..<24)), [app("a"), .held("x"), .gap, app("b"), .held("y")])
		// Only x's spot.
		XCTAssertEqual(OpenSpacesFinder.slots(slots, empty: [1] + Array(3..<24)), [app("a"), .held("x"), app("b"), .held("y")])
	}

	func testDoesntFitAPageWithOtherItems() {
		XCTAssertNil(OpenSpacesFinder.slots([app("a"), app("b")], empty: Array(1..<24)))
	}
}
