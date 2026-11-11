import Foundation
import XCTest
@testable import InstallKit

/// A made-up Home Screen screenshot, read at `OpenSpacesFinder.readingWidth`:
/// a smooth wallpaper and rounded icons with a glyph, at a known grid.
private struct Screen {
	static let width = OpenSpacesFinder.readingWidth
	static let height = 1279
	static let pitch = 140.0
	static let icon = 98.0
	static let columns = (0..<4).map { Double(width) / 2 + (Double($0) - 1.5) * pitch }

	var rows = (0..<6).map { 178 + Double($0) * pitch }
	/// The places with an icon, row by row.
	var icons: Set<Int>
	/// Names under the icons, as iOS shows them unless they're hidden.
	var labels = false
	/// Icons drawn as dark mode draws them: near black, with a coloured glyph.
	var dark = false
	/// Places whose icon is drawn in nearly the wallpaper's colour.
	var dim: Set<Int> = []

	var grid: OpenSpacesFinder.Grid {
		OpenSpacesFinder.Grid(columns: Self.columns, rows: rows, pitch: Self.pitch)
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
			for x in 0..<Self.width { put(x, y, Self.wallpaper(x, y)) }
		}
		let half = Self.icon / 2, corner = Self.icon * 0.225
		for place in icons.sorted() {
			let cx = Self.columns[place % 4], cy = rows[place / 4]
			let hue = Double(place * 37 % 255)
			let fill: (Double, Double, Double)
			let glyph: (Double, Double, Double)
			if dim.contains(place) {
				let behind = Self.wallpaper(Int(cx), Int(cy))
				fill = (behind.0 + 6, behind.1 + 6, behind.2 + 6)
				glyph = (behind.0 + 14, behind.1 + 14, behind.2 + 14)
			} else if dark {
				fill = (18, 18, 22)
				glyph = (hue, 255 - hue, 160)
			} else {
				fill = (hue, 120, 255 - hue)
				glyph = (250, 250, 250)
			}
			for y in Int(cy - half)..<Int(cy + half) {
				for x in Int(cx - half)..<Int(cx + half) {
					// Rounded corners.
					let dx = max(abs(Double(x) + 0.5 - cx) - (half - corner), 0)
					let dy = max(abs(Double(y) + 0.5 - cy) - (half - corner), 0)
					guard dx * dx + dy * dy <= corner * corner else { continue }
					// A ring and a bar for a glyph.
					let r = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
					let isGlyph = (r > 18 && r < 26) || (abs(Double(y) - cy) < 4 && abs(Double(x) - cx) < 30)
					put(x, y, isGlyph ? glyph : fill)
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

	static func wallpaper(_ x: Int, _ y: Int) -> (Double, Double, Double) {
		let u = Double(x) / Double(width), v = Double(y) / Double(height)
		let glow = exp(-((u - 0.8) * (u - 0.8) + (v - 0.15) * (v - 0.15)) * 4)
		return (40 + 70 * v + 50 * glow, 30 + 30 * u + 40 * glow, 70 + 90 * (1 - v) + 30 * glow)
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
		XCTAssertEqual(found.pitch, Screen.pitch, accuracy: 1.5, file: file, line: line)
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
		screen.rows = (0..<6).map { 165 + Double($0) * 156 }
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
		screen.rows = (0..<6).map { 165 + Double($0) * 156 }
		let reading = try XCTUnwrap(OpenSpacesFinder.read(screen.pixels, items: screen.icons.count))
		XCTAssertEqual(reading.openSpaces, [1, 6, 7, 13])
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
		var scores = [Double](repeating: 60, count: 24)
		for place in 20..<24 { scores[place] = 3 }
		XCTAssertFalse(OpenSpacesFinder.reading(scores, items: 20, grid: grid).isDoubtful)
		scores[21] = 25
		XCTAssertTrue(OpenSpacesFinder.reading(scores, items: 20, grid: grid).isDoubtful)
		scores[21] = 3
		scores[4] = 26
		XCTAssertTrue(OpenSpacesFinder.reading(scores, items: 20, grid: grid).isDoubtful)
	}

	func testAPlainPictureHasNoGrid() {
		let plain = OpenSpacesFinder.Pixels(width: Screen.width, height: Screen.height, rgba: [UInt8](repeating: 90, count: Screen.width * Screen.height * 4))
		XCTAssertNil(OpenSpacesFinder.grid(in: plain, items: 3))
	}

	func testTellsAnotherPageFromTheSameOne() {
		let first = Screen(icons: Set(0..<20)).pixels
		let same = Screen(icons: Set(0..<20)).pixels
		let next = Screen(icons: Set(0..<13)).pixels
		XCTAssertEqual(OpenSpacesFinder.difference(first, same), 0)
		XCTAssertGreaterThan(OpenSpacesFinder.difference(first, next), 3)
	}

	// MARK: Marking what it found

	private func app(_ id: String) -> HomeScreenSlot {
		.item(.icon(id: id, raw: PlistDictionary(["bundleIdentifier": id])))
	}

	func testPutsTheOpenSpacesBeforeTheirApps() {
		let slots = (0..<20).map { app("a\($0)") }
		let marked = OpenSpacesFinder.slots(slots, empty: [19, 20, 21, 22])
		XCTAssertEqual(marked, Array(slots.prefix(19)) + Array(repeating: .gap, count: 4) + [slots[19]])
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
