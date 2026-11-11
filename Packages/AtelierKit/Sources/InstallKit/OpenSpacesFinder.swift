import Foundation

// Find Open Spaces Automatically (11 Nov 2026): iOS doesn't report the open
// spaces between icons, so Atelier takes a screenshot of the page and looks
// for them. With one page there's nothing to compare it with, so the grid
// comes from where the icons' edges are, and each place is scored by how
// unlike the wallpaper around it its middle is. The page's item count, from
// getIconState, then says how many places are empty: those with the lowest
// scores. A prototype of this, run on a recording of 11 pages in dark mode
// with hidden labels, found the one page's open spaces and none elsewhere.

/// Reads a Home Screen page's empty places from a screenshot of it.
public enum OpenSpacesFinder {
	/// The width a screenshot is read at, as the prototype read its frames:
	/// wide enough for an icon's edges, small enough to be quick. The
	/// scores' scale, and so `emptyAtMost` and `iconAtLeast`, come from it.
	public static let readingWidth = 590
	/// The highest score an empty place had in the prototype's pages, with
	/// some room: a place chosen as empty above it is doubtful.
	public static let emptyAtMost = 22.0
	/// The lowest an icon scored there was 23.1, a dim folder: a place not
	/// chosen as empty below this is doubtful.
	public static let iconAtLeast = 28.0

	/// A picture's pixels, 8-bit RGBA, row by row from the top left.
	public struct Pixels: Sendable {
		public var width: Int
		public var height: Int
		public var rgba: [UInt8]

		public init(width: Int, height: Int, rgba: [UInt8]) {
			precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "RGBA pixels of the size given")
			self.width = width
			self.height = height
			self.rgba = rgba
		}
	}

	/// Where a page's places are on a screenshot read at `readingWidth`:
	/// the centres of its 4 columns and 6 rows, in pixels, and the distance
	/// between columns, which sizes the part of each place scored.
	public struct Grid: Codable, Equatable, Sendable {
		public var columns: [Double]
		public var rows: [Double]
		public var pitch: Double

		public init(columns: [Double], rows: [Double], pitch: Double) {
			self.columns = columns
			self.rows = rows
			self.pitch = pitch
		}

		/// Each place's centre, row by row.
		var centres: [(x: Double, y: Double)] {
			rows.flatMap { y in columns.map { x in (x, y) } }
		}
	}

	/// What a screenshot showed of a page.
	public struct Reading: Equatable, Sendable {
		public var grid: Grid
		/// How unlike the wallpaper around it each place's middle is, row
		/// by row: low for an empty place, high for an icon.
		public var scores: [Double]
		/// The empty places, from 0, row by row.
		public var empty: [Int]
		/// Whether a place chosen as empty scored like an icon, or one not
		/// chosen like an empty place, so the page needs checking.
		public var isDoubtful: Bool

		/// The empty places before the page's last item: its open spaces.
		/// Those after it are just room iOS leaves at the end of a page.
		public var openSpaces: [Int] {
			guard let last = scores.indices.last(where: { !empty.contains($0) }) else { return [] }
			return empty.filter { $0 < last }
		}

		/// How far apart the empty places' scores and the icons' are: the
		/// lowest not chosen less the highest chosen.
		public var margin: Double {
			let chosen = empty.map { scores[$0] }.max() ?? 0
			let others = scores.indices.filter { !empty.contains($0) }.map { scores[$0] }.min() ?? .infinity
			return others - chosen
		}
	}

	// MARK: Reading a page

	/// Reads the page in `pixels`, read at `readingWidth`, with `items`
	/// icons and folders on it, and some room: with the grid found in it or
	/// `known`, the grid an earlier reading on this screen found, whichever
	/// tells the empty places from the icons better. Nil when no grid
	/// shows, or the page is empty or full.
	public static func read(_ pixels: Pixels, items: Int, known: Grid? = nil) -> Reading? {
		guard items > 0, items < HomeScreenLayout.pagePlaces else { return nil }
		let candidates = [grid(in: pixels, items: items), known].compactMap { $0 }
		let readings = candidates.map { grid in reading(scores(pixels, grid: grid), items: items, grid: grid) }
		// The first of the best, so the grid found wins a tie.
		return readings.reduce(nil) { best, next in
			guard let best else { return next }
			return next.margin > best.margin ? next : best
		}
	}

	/// The `places − items` lowest scores as the empty places.
	static func reading(_ scores: [Double], items: Int, grid: Grid) -> Reading {
		let free = max(scores.count - items, 0)
		let order = scores.indices.sorted { (scores[$0], $0) < (scores[$1], $1) }
		let empty = order.prefix(free).sorted()
		let chosen = empty.map { scores[$0] }.max() ?? 0
		let others = order.dropFirst(free).map { scores[$0] }.min() ?? .infinity
		return Reading(
			grid: grid,
			scores: scores,
			empty: empty,
			isDoubtful: chosen > emptyAtMost || others < iconAtLeast
		)
	}

	// MARK: The grid

	/// The grid of the page in `pixels` with `items` icons and folders on
	/// it: 4 columns spaced evenly about the middle, where the icons' sides
	/// are, and 6 rows at the spacing the icons' edges repeat at down the
	/// page, from where the scores tell that many icons from the empty
	/// places best. Edges alone put the rows on an icon's glyph, or its
	/// name, as readily as on the icon. Nil when there are no edges to go
	/// by, as on an empty page.
	public static func grid(in pixels: Pixels, items: Int) -> Grid? {
		guard let frame = frame(in: pixels) else { return nil }
		let height = Double(pixels.height)
		func grid(_ first: Double) -> Grid {
			Grid(columns: frame.columns, rows: (0..<HomeScreenLayout.pageRows).map { first + Double($0) * frame.spacing }, pitch: frame.pitch)
		}
		// How far apart the icons' scores are from the empty places'.
		func separation(_ first: Double, _ window: Window) -> Double {
			let sorted = grid(first).centres.map { window.score(pixels, x: Int($0.x), y: Int($0.y)) }.sorted()
			let empty = sorted.count - items
			let low = sorted.prefix(empty).reduce(0, +) / Double(max(empty, 1))
			let high = sorted.suffix(items).reduce(0, +) / Double(max(items, 1))
			return high - low
		}
		// The first row lies between the status bar and a row lower on every
		// iPhone. Roughly, from fewer pixels.
		let rough = Window(pitch: frame.pitch, every: 3)
		let starts = Array(stride(from: 0.08 * height, through: 0.19 * height, by: 3))
		let roughly = starts.map { separation($0, rough) }
		guard let best = roughly.indices.max(by: { roughly[$0] < roughly[$1] }) else { return nil }
		// Then exactly: the middle of the stretch where it tells them apart
		// about as well, as the scores hardly change while each core stays
		// inside its icon and each ring outside it.
		let fine = Window(pitch: frame.pitch, every: 2)
		let nearby = Array(stride(from: starts[best] - 15, through: starts[best] + 15, by: 1))
		let values = nearby.map { separation($0, fine) }
		guard let most = values.max(), let least = values.min() else { return nil }
		let close = nearby.indices.filter { values[$0] >= most - 0.15 * (most - least) }
		return grid(close.map { nearby[$0] }.reduce(0, +) / Double(close.count))
	}

	/// The columns of the page in `pixels`, the distance between them, and
	/// the distance between rows.
	static func frame(in pixels: Pixels) -> (columns: [Double], pitch: Double, spacing: Double)? {
		let width = pixels.width, height = pixels.height
		guard width >= 100, height >= width else { return nil }
		let (across, down) = gradients(pixels)
		// Between the status bar and the Search button above the Dock.
		let top = Int(Double(height) * 0.06), bottom = Int(Double(height) * 0.80)
		let middle = Double(width) / 2

		// Columns, roughly: the spacing that puts all 4 on the most edges.
		var edges = [Double](repeating: 0, count: width)
		var sides = [Double](repeating: 0, count: width)
		for y in top..<bottom {
			for x in 0..<width {
				edges[x] += across[y * width + x] + down[y * width + x]
				sides[x] += across[y * width + x]
			}
		}
		let radius = max(width / 24, 1)
		edges = smoothed(smoothed(edges, radius: radius), radius: radius)
		guard let most = edges.max(), most > 0 else { return nil }
		var pitch = 0.0, best = -Double.infinity
		for step in stride(from: 0.18 * Double(width), through: 0.28 * Double(width), by: 0.25) {
			let value = (0..<4).reduce(0.0) { $0 + sample(edges, middle + (Double($1) - 1.5) * step) }
			if value > best { (pitch, best) = (step, value) }
		}
		// Then exactly, from the icons' sides: the edges that run all the
		// way down an icon, which a lighter wallpaper on one side doesn't
		// move, as it does the middle of the edges. When they show.
		sides = smoothed(sides, radius: 1)
		let sideMean = sides.reduce(0, +) / Double(width)
		var sidePitch = pitch, sideBest = -Double.infinity
		for step in stride(from: pitch - 6, through: pitch + 6, by: 0.25) {
			for icon in stride(from: 0.5 * step, through: 0.85 * step, by: 0.5) {
				let value = (0..<4).reduce(0.0) { total, column in
					let centre = middle + (Double(column) - 1.5) * step
					return total + sample(sides, centre - icon / 2) + sample(sides, centre + icon / 2)
				}
				if value > sideBest { (sidePitch, sideBest) = (step, value) }
			}
		}
		if sideBest > 8 * 2 * sideMean { pitch = sidePitch }
		let columns = (0..<4).map { middle + (Double($0) - 1.5) * pitch }

		// The edges down the columns, for the rows' spacing.
		var inColumns = [Double](repeating: 0, count: height)
		for y in top..<bottom {
			for column in columns {
				let from = max(Int(column - 0.3 * pitch), 0), to = min(Int(column + 0.3 * pitch), width - 1)
				for x in from...to { inColumns[y] += across[y * width + x] + down[y * width + x] }
			}
		}
		return (columns, pitch, rowSpacing(inColumns, pitch: pitch, from: top, to: bottom))
	}

	/// The spacing the rows' edges repeat at, near the columns': with
	/// labels under the icons, rows are a little further apart than
	/// columns. The columns' when it doesn't show, as on a page of one row.
	static func rowSpacing(_ down: [Double], pitch: Double, from top: Int, to bottom: Int) -> Double {
		let band = smoothed(Array(down[top..<bottom]), radius: max(Int(pitch * 0.1), 1))
		let mean = band.reduce(0, +) / Double(band.count)
		let centred = band.map { $0 - mean }
		let energy = centred.reduce(0) { $0 + $1 * $1 }
		guard energy > 0 else { return pitch }
		func correlation(_ lag: Int) -> Double {
			guard lag > 0, lag < centred.count else { return 0 }
			var sum = 0.0
			for i in 0..<(centred.count - lag) { sum += centred[i] * centred[i + lag] }
			return sum / energy
		}
		var found: Int?, best = 0.25
		for lag in Int(pitch * 0.95)...Int(pitch * 1.3) {
			let value = correlation(lag)
			if value > best { (found, best) = (lag, value) }
		}
		guard let found else { return pitch }
		// Between whole pixels, from the peak's neighbours.
		let before = correlation(found - 1), after = correlation(found + 1)
		let curve = before - 2 * best + after
		let shift = curve < 0 ? min(max(0.5 * (before - after) / curve, -0.5), 0.5) : 0
		return Double(found) + shift
	}

	// MARK: Scores

	/// How unlike the wallpaper around it each place's middle is, row by
	/// row: a quadratic fit per colour to the ring of wallpaper from 0.42 to
	/// 0.49 of the pitch around the place's centre, and the mean difference
	/// from it of the place's core, within 0.29 of the pitch. An empty
	/// place's core is wallpaper, which the fit follows; an icon's isn't.
	/// `every` scores from every so many pixels across and down, which is
	/// quicker and nearly the same.
	public static func scores(_ pixels: Pixels, grid: Grid, every step: Int = 1) -> [Double] {
		let window = Window(pitch: grid.pitch, every: step)
		return grid.centres.map { centre in window.score(pixels, x: Int(centre.x), y: Int(centre.y)) }
	}

	/// The square around a place: its ring, its core, and the fit to the
	/// ring, the same for every place.
	struct Window {
		/// Offsets from the centre, across then down.
		let ring: [Int]
		let core: [Int]
		/// Each offset's terms, 6 apiece: 1, x, y, x², y², xy.
		let ringTerms: [Double]
		let coreTerms: [Double]
		/// The normal equations' inverse for the ring's terms, row by row.
		let inverse: [Double]

		/// The ring from 0.42 to 0.49 of `pitch` around the centre and the
		/// core within 0.29 of it, from every `step` pixels across and down.
		init(pitch: Double, every step: Int = 1) {
			let outer = max(Int(pitch * 0.49), 3), inner = Int(pitch * 0.42), coreSize = Int(pitch * 0.29)
			var ring: [Int] = [], core: [Int] = []
			var ringTerms: [Double] = [], coreTerms: [Double] = []
			for dy in stride(from: -outer, to: outer, by: max(step, 1)) {
				for dx in stride(from: -outer, to: outer, by: max(step, 1)) {
					let distance = max(abs(dx), abs(dy))
					let x = Double(dx) / Double(outer), y = Double(dy) / Double(outer)
					let terms = [1, x, y, x * x, y * y, x * y]
					if distance >= inner {
						ring += [dx, dy]
						ringTerms += terms
					}
					if distance < coreSize {
						core += [dx, dy]
						coreTerms += terms
					}
				}
			}
			self.ring = ring
			self.core = core
			self.ringTerms = ringTerms
			self.coreTerms = coreTerms
			var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
			for k in 0..<(ring.count / 2) {
				for i in 0..<6 {
					for j in 0..<6 { normal[i][j] += ringTerms[k * 6 + i] * ringTerms[k * 6 + j] }
				}
			}
			inverse = Self.inverted(normal).flatMap { $0 }
		}

		func score(_ pixels: Pixels, x: Int, y: Int) -> Double {
			let width = pixels.width, height = pixels.height
			var moments = [Double](repeating: 0, count: 18)
			var fit = [Double](repeating: 0, count: 18)
			var total = 0.0, count = 0
			pixels.rgba.withUnsafeBufferPointer { rgba in
				ring.withUnsafeBufferPointer { ring in
					ringTerms.withUnsafeBufferPointer { terms in
						moments.withUnsafeMutableBufferPointer { moments in
							// The ring's moments, per colour: the fit's right-hand side.
							for k in 0..<(ring.count / 2) {
								let px = x + ring[2 * k], py = y + ring[2 * k + 1]
								guard px >= 0, px < width, py >= 0, py < height else { continue }
								let i = (py * width + px) * 4
								for channel in 0..<3 {
									let v = Double(rgba[i + channel])
									for term in 0..<6 { moments[channel * 6 + term] += terms[k * 6 + term] * v }
								}
							}
						}
					}
				}
				for channel in 0..<3 {
					for row in 0..<6 {
						var sum = 0.0
						for column in 0..<6 { sum += inverse[row * 6 + column] * moments[channel * 6 + column] }
						fit[channel * 6 + row] = sum
					}
				}
				core.withUnsafeBufferPointer { core in
					coreTerms.withUnsafeBufferPointer { terms in
						fit.withUnsafeBufferPointer { fit in
							for k in 0..<(core.count / 2) {
								let px = x + core[2 * k], py = y + core[2 * k + 1]
								guard px >= 0, px < width, py >= 0, py < height else { continue }
								let i = (py * width + px) * 4
								for channel in 0..<3 {
									var expected = 0.0
									for term in 0..<6 { expected += fit[channel * 6 + term] * terms[k * 6 + term] }
									total += abs(Double(rgba[i + channel]) - expected)
									count += 1
								}
							}
						}
					}
				}
			}
			return count > 0 ? total / Double(count) : 0
		}

		/// Gauss–Jordan, with partial pivoting.
		static func inverted(_ matrix: [[Double]]) -> [[Double]] {
			let n = matrix.count
			var a = matrix
			var result = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
			for column in 0..<n {
				let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) } ?? column
				a.swapAt(column, pivot)
				result.swapAt(column, pivot)
				let divisor = a[column][column]
				guard divisor != 0 else { continue }
				for j in 0..<n {
					a[column][j] /= divisor
					result[column][j] /= divisor
				}
				for row in 0..<n where row != column {
					let factor = a[row][column]
					guard factor != 0 else { continue }
					for j in 0..<n {
						a[row][j] -= factor * a[column][j]
						result[row][j] -= factor * result[column][j]
					}
				}
			}
			return result
		}
	}

	// MARK: Comparing screenshots

	/// How different two pictures of the same size are where the Home
	/// Screen's icons are, between the status bar and the Search button:
	/// the mean difference in brightness, 0 to 255. A swipe that moved to
	/// another page changes it a lot; one that didn't, hardly at all.
	public static func difference(_ a: Pixels, _ b: Pixels) -> Double {
		guard a.width == b.width, a.height == b.height else { return .infinity }
		let top = Int(Double(a.height) * 0.06), bottom = Int(Double(a.height) * 0.80)
		guard bottom > top else { return 0 }
		let first = luminance(a), second = luminance(b)
		var total = 0.0
		for i in (top * a.width)..<(bottom * a.width) { total += abs(first[i] - second[i]) }
		return total / Double((bottom - top) * a.width)
	}

	// MARK: Helpers

	static func luminance(_ pixels: Pixels) -> [Double] {
		pixels.rgba.withUnsafeBufferPointer { rgba in
			(0..<(pixels.width * pixels.height)).map { i in
				0.299 * Double(rgba[i * 4]) + 0.587 * Double(rgba[i * 4 + 1]) + 0.114 * Double(rgba[i * 4 + 2])
			}
		}
	}

	/// How sharply the brightness changes at each pixel: across, which
	/// finds upright edges such as an icon's sides, and down, which finds
	/// level ones such as its top and bottom.
	static func gradients(_ pixels: Pixels) -> (across: [Double], down: [Double]) {
		let width = pixels.width, height = pixels.height
		let light = luminance(pixels)
		var across = [Double](repeating: 0, count: width * height)
		var down = [Double](repeating: 0, count: width * height)
		light.withUnsafeBufferPointer { l in
			across.withUnsafeMutableBufferPointer { a in
				down.withUnsafeMutableBufferPointer { d in
					for y in 1..<(height - 1) {
						for x in 1..<(width - 1) {
							let i = y * width + x
							a[i] = abs(l[i + 1] - l[i - 1])
							d[i] = abs(l[i + width] - l[i - width])
						}
					}
				}
			}
		}
		return (across, down)
	}

	/// The mean of each value and the `radius` on either side of it.
	static func smoothed(_ values: [Double], radius: Int) -> [Double] {
		let sums = prefixSums(values)
		return values.indices.map { i in
			let from = max(i - radius, 0), to = min(i + radius, values.count - 1)
			return (sums[to + 1] - sums[from]) / Double(to - from + 1)
		}
	}

	static func prefixSums(_ values: [Double]) -> [Double] {
		var sums = [Double](repeating: 0, count: values.count + 1)
		for (i, value) in values.enumerated() { sums[i + 1] = sums[i] + value }
		return sums
	}

	/// The sum of the values from `from` to `to`, whole pixels, clamped.
	static func boxSum(_ sums: [Double], from: Double, to: Double) -> Double {
		let count = sums.count - 1
		let start = min(max(Int(from.rounded()), 0), count), end = min(max(Int(to.rounded()) + 1, 0), count)
		return end > start ? sums[end] - sums[start] : 0
	}

	/// The value at `position`, between pixels linearly; 0 outside.
	static func sample(_ values: [Double], _ position: Double) -> Double {
		guard position >= 0, position <= Double(values.count - 1) else { return 0 }
		let low = Int(position), high = min(low + 1, values.count - 1)
		let fraction = position - Double(low)
		return values[low] * (1 - fraction) + values[high] * fraction
	}
}

extension OpenSpacesFinder {
	/// A page's places with the open spaces a reading found: as many gaps
	/// before each item as the screenshot showed empty places there, less
	/// the offloaded apps' spots kept there, which look empty too. The
	/// page's other gaps go, as a mark of the page replaces them; a gap
	/// added to a run of places goes last in it, before the item. Nil when
	/// the reading doesn't fit the page: a different number of items, or
	/// more places than the page has.
	public static func slots(_ slots: [HomeScreenSlot], empty: [Int]) -> [HomeScreenSlot]? {
		let places = HomeScreenLayout.pagePlaces
		let items = slots.filter { if case .item = $0 { true } else { false } }.count
		let filled = (0..<places).filter { !empty.contains($0) }
		guard filled.count == items, empty.allSatisfy({ (0..<places).contains($0) }) else { return nil }
		var result: [HomeScreenSlot] = []
		var run: [HomeScreenSlot] = []
		var item = 0
		for slot in slots {
			guard case .item = slot else {
				run.append(slot)
				continue
			}
			// The empty places between this item and the one before it.
			let shown = filled[item] - (item == 0 ? 0 : filled[item - 1] + 1)
			let held = run.filter { if case .held = $0 { true } else { false } }.count
			var gaps = run.filter { $0 == .gap }.count
			let wanted = max(shown - held, 0)
			while gaps > wanted, let last = run.lastIndex(of: .gap) {
				run.remove(at: last)
				gaps -= 1
			}
			run += Array(repeating: .gap, count: wanted - gaps)
			result += run + [slot]
			run = []
			item += 1
		}
		// Room after the last item needs no gaps; offloaded apps' spots stay.
		result += run.filter { $0 != .gap }
		let trailing = result.reversed().prefix { if case .item = $0 { false } else { true } }.count
		guard result.count - trailing <= places else { return nil }
		return result
	}
}
