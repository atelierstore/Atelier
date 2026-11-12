import Foundation

// Find Open Spaces Automatically (11 Nov 2026): iOS doesn't report the open
// spaces between icons, so Atelier takes a screenshot of the page and looks
// for them. The grid comes from the icons' outlines: the edge all along the
// middle of each side of a rounded square, which a wallpaper doesn't draw.
// Then each app's own icon, as SpringBoard draws it, is looked for at the
// grid's places, in the order iOS lists the page's items, and a folder,
// which has no one icon, by its outline. The places left over are empty.
// (12 Nov 2026: the first reading went by how unlike the wallpaper around
// it each place's middle was, which a wallpaper's sharp creases fooled.)

/// Reads a Home Screen page's empty places from a screenshot of it.
public enum OpenSpacesFinder {
	/// The width a screenshot is read at: wide enough for an icon's edges,
	/// small enough to be quick. The scores' scale comes from it.
	public static let readingWidth = 590
	/// An outline is where the colour a few pixels inside an icon's side
	/// differs from the colour as far outside it, all along the side.
	static let reach = 5
	/// Of each side, the middle part looked at: an icon's corners are round.
	static let straight = 0.6
	/// A change in colour counts up to this much, summed over red, green
	/// and blue, so a crease in the wallpaper crossing a side counts no
	/// more than an icon's edge would there.
	static let cap: Int32 = 150
	/// The most an empty place's outline scored in the screenshots tried,
	/// with some room: a crease along one side, or text across one.
	public static let emptyAtMost = 8.0
	/// The least an icon's did: a dark folder on a dark wallpaper.
	public static let iconAtLeast = 14.0
	/// How alike an app's icon and a place must be, from -1 to 1, for the
	/// app to count as found there. Its own icon is about 0.8 or more.
	public static let alike = 0.5

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
	/// the centres of its 4 columns and 6 rows, in pixels, and half an
	/// icon's side.
	public struct Grid: Codable, Equatable, Sendable {
		public var columns: [Double]
		public var rows: [Double]
		public var half: Double

		public init(columns: [Double], rows: [Double], half: Double) {
			self.columns = columns
			self.rows = rows
			self.half = half
		}

		/// Each place's centre, row by row.
		var centres: [(x: Double, y: Double)] {
			var centres: [(x: Double, y: Double)] = []
			for y in rows {
				for x in columns { centres.append((x, y)) }
			}
			return centres
		}
	}

	/// What a screenshot showed of a page.
	public struct Reading: Equatable, Sendable {
		public var grid: Grid
		/// How clearly each place shows an icon's outline, row by row: low
		/// for an empty place, high for an icon or a folder.
		public var scores: [Double]
		/// Where each of the page's items is, in the order iOS lists them.
		public var places: [Int]
		/// How alike each item's icon and its place are, from -1 to 1: nil
		/// for a folder, or an app whose icon didn't come.
		public var likeness: [Double?]
		/// How well the items fit where they were put, all told: higher is
		/// better, to choose between grids.
		var fit: Double

		/// The empty places, from 0, row by row.
		public var empty: [Int] {
			(0..<scores.count).filter { !places.contains($0) }
		}

		/// The empty places before the page's last item: its open spaces.
		/// Those after it are just room iOS leaves at the end of a page.
		public var openSpaces: [Int] {
			guard let last = places.last else { return [] }
			return empty.filter { $0 < last }
		}

		/// Whether some places were hard to tell: an app's icon that didn't
		/// look like itself, a folder's place without an outline, or an
		/// outline at a place left empty. The page needs checking.
		public var isDoubtful: Bool {
			for (item, place) in places.enumerated() {
				if let likeness = likeness[item] {
					if likeness < alike { return true }
				} else if scores[place] < iconAtLeast {
					return true
				}
			}
			return empty.contains { scores[$0] >= iconAtLeast }
		}

		/// How many apps' icons were found where they were put, and how
		/// many it had to look for: few found means another page.
		public var iconsFound: Int {
			likeness.compactMap { $0 }.filter { $0 >= alike }.count
		}

		public var iconsKnown: Int {
			likeness.compactMap { $0 }.count
		}

		/// How many places show an icon's outline, whatever the page has.
		public var outlines: Int {
			let middle: Double = (emptyAtMost + iconAtLeast) / 2
			var count = 0
			for score in scores where score >= middle { count += 1 }
			return count
		}

		/// Whether the items are in two rows or more, which places the
		/// grid's rows. With one row, where the others are is a guess.
		public var placesTheRows: Bool {
			Set(places.map { $0 / HomeScreenLayout.pageColumns }).count > 1
		}
	}

	// MARK: Reading a page

	/// Reads the page in `pixels`, read at `readingWidth`, whose items are
	/// `icons`, in the order iOS lists them: each app's icon as SpringBoard
	/// draws it, or nil for a folder or an app whose icon didn't come. With
	/// the grid found in it or `known`, the grid an earlier reading on this
	/// screen found, whichever the items fit better. Nil when no grid shows,
	/// or the page is empty or full.
	public static func read(_ pixels: Pixels, icons: [Pixels?], known: Grid? = nil) -> Reading? {
		let items = icons.count
		guard items > 0, items < HomeScreenLayout.pagePlaces else { return nil }
		let outlines = Outlines(pixels)
		var grids: [Grid] = []
		if let found = grid(outlines, items: items) { grids.append(found) }
		if let known { grids.append(known) }
		guard !grids.isEmpty else { return nil }
		let looks = icons.map { icon in icon.flatMap(Look.init(icon:)) }
		let light = looks.contains { $0 != nil } ? Brightness(pixels) : nil
		var best: Reading?
		for grid in grids {
			let scores = Self.scores(outlines, grid: grid)
			let likeness = light.map { light in Self.likeness(looks, at: grid, in: light) } ?? looks.map { _ in nil }
			let next = reading(scores: scores, likeness: likeness, grid: grid)
			// The first of the best, so the grid found wins a tie.
			if let current = best, next.fit <= current.fit { continue }
			best = next
		}
		return best
	}

	/// Reads the page by the outlines alone, with `items` icons and
	/// folders on it.
	public static func read(_ pixels: Pixels, items: Int, known: Grid? = nil) -> Reading? {
		read(pixels, icons: [Pixels?](repeating: nil, count: items), known: known)
	}

	/// Puts the items in the places, in order, where they fit best: an app
	/// where its icon looks most like itself and shows an outline, a
	/// folder where an outline shows. `likeness` has each app's likeness
	/// to each place, or nil for a folder.
	static func reading(scores: [Double], likeness: [[Double]?], grid: Grid) -> Reading {
		let places = scores.count, items = likeness.count
		// How much better each item fits at each place than leaving the
		// place empty.
		let middle: Double = (emptyAtMost + iconAtLeast) / 2
		let spread: Double = (iconAtLeast - emptyAtMost) / 2
		func gain(_ item: Int, _ place: Int) -> Double {
			let score: Double = scores[place]
			let outline: Double = min(max((score - middle) / spread, -1), 1)
			guard let alikeness = likeness[item]?[place] else { return outline }
			let found: Double = alikeness - alike
			return 2 * found + outline
		}
		// best[item][place]: the most the items so far can add up to, with
		// this one at this place; each item after the one before it.
		var best = [[Double]](repeating: [Double](repeating: -.infinity, count: places), count: items)
		var from = [[Int]](repeating: [Int](repeating: -1, count: places), count: items)
		for item in 0..<items {
			let lowest = item, highest = places - items + item
			guard lowest <= highest else { continue }
			for place in lowest...highest {
				let here = gain(item, place)
				guard item > 0 else {
					best[item][place] = here
					continue
				}
				var before = -Double.infinity, at = -1
				for earlier in (item - 1)..<place where best[item - 1][earlier] > before {
					before = best[item - 1][earlier]
					at = earlier
				}
				guard at >= 0 else { continue }
				best[item][place] = before + here
				from[item][place] = at
			}
		}
		var placed = [Int](repeating: 0, count: items)
		var fit = -Double.infinity
		for place in 0..<places where best[items - 1][place] > fit {
			fit = best[items - 1][place]
			placed[items - 1] = place
		}
		if items > 1 {
			for item in stride(from: items - 1, to: 0, by: -1) {
				placed[item - 1] = from[item][placed[item]]
			}
		}
		var found: [Double?] = []
		for (item, place) in placed.enumerated() {
			found.append(likeness[item]?[place])
		}
		return Reading(grid: grid, scores: scores, places: placed, likeness: found, fit: fit)
	}

	// MARK: The grid

	/// The grid of the page in `pixels` with `items` icons and folders on
	/// it. Nil when no outlines show, as on an empty page.
	public static func grid(in pixels: Pixels, items: Int) -> Grid? {
		grid(Outlines(pixels), items: items)
	}

	/// A grid's measures: 4 columns `pitch` apart about the middle, 6 rows
	/// `spacing` apart from `first`, and icons `half` across from their
	/// centres.
	struct Shape {
		var pitch: Double
		var half: Double
		var first: Double
		var spacing: Double

		func grid(width: Int) -> Grid {
			let middle = Double(width) / 2
			let columns = positions(HomeScreenLayout.pageColumns, from: middle - 1.5 * pitch, every: pitch)
			let rows = positions(HomeScreenLayout.pageRows, from: first, every: spacing)
			return Grid(columns: columns, rows: rows, half: half)
		}
	}

	/// The grid where the most places show an outline: roughly, from a
	/// pixel to the next, then exactly, from the middle of the stretch over
	/// which each measure tells the icons from the empty places about as
	/// well, as an outline is seen the same a few pixels either way.
	static func grid(_ outlines: Outlines, items: Int) -> Grid? {
		let width = Double(outlines.width), height = Double(outlines.height)
		guard outlines.width >= 100, height >= width else { return nil }
		let middle = width / 2
		// The first row lies between the status bar and a row lower on every
		// iPhone, and the last above the Search button.
		let lowest = Int(0.08 * height), highest = Int(0.19 * height)
		let bottom = 0.80 * height
		// An empty place's score counts for nothing here.
		let floor = emptyAtMost / 2
		var best: Shape?
		var bestValue = 0.0
		for pitch in stride(from: (0.18 * width).rounded(), through: 0.28 * width, by: 2) {
			let columns = positions(HomeScreenLayout.pageColumns, from: middle - 1.5 * pitch, every: pitch)
			for ratio in stride(from: 0.30, through: 0.451, by: 0.03) {
				let half = ratio * pitch
				let last = Int(bottom - half)
				guard last > highest else { continue }
				// How clearly the 4 places at each height show outlines.
				var profile = [Double](repeating: 0, count: last + 1)
				var top6 = [Double](repeating: 0, count: 6)
				for y in lowest...last {
					var total = 0.0
					for x in columns {
						let score = outlines.score(x: x, y: Double(y), half: half)
						total += max(score - floor, 0)
					}
					profile[y] = total
					if total > top6[0] {
						top6[0] = total
						top6.sort()
					}
				}
				// No 6 rows can add up to more than the 6 best heights.
				guard top6.reduce(0, +) > bestValue else { continue }
				for spacing in spacings(pitch) {
					for first in lowest...highest {
						let end = Double(first) + 5 * spacing
						guard end <= Double(last) else { break }
						var value = 0.0
						for row in 0..<HomeScreenLayout.pageRows {
							let y = Double(first) + Double(row) * spacing
							value += profile[Int(y.rounded())]
						}
						if value > bestValue {
							bestValue = value
							best = Shape(pitch: pitch, half: half, first: Double(first), spacing: spacing)
						}
					}
				}
			}
		}
		guard var shape = best else { return nil }
		// How clearly the icons' places show their outlines, all told: the
		// `items` best scores. Not less the others, which would have a
		// faint icon's outline missed on purpose.
		func outlined(_ shape: Shape) -> Double {
			let sorted = scores(outlines, grid: shape.grid(width: outlines.width)).sorted(by: >)
			return sorted.prefix(items).reduce(0, +)
		}
		for _ in 0..<2 {
			shape.pitch = centre(around: shape.pitch, within: 3, by: 0.25) { pitch in
				var trial = shape
				trial.pitch = pitch
				return outlined(trial)
			}
			shape.half = centre(around: shape.half, within: 0.04 * shape.pitch, by: 0.25) { half in
				var trial = shape
				trial.half = half
				return outlined(trial)
			}
			shape.first = centre(around: shape.first, within: 6, by: 0.5) { first in
				var trial = shape
				trial.first = first
				return outlined(trial)
			}
			shape.spacing = centre(around: shape.spacing, within: 3, by: 0.25) { spacing in
				var trial = shape
				trial.spacing = spacing
				return outlined(trial)
			}
		}
		let grid = shape.grid(width: outlines.width)
		guard separation(scores(outlines, grid: grid), items: items) >= iconAtLeast - emptyAtMost else { return nil }
		return grid
	}

	/// The spacings rows can have for columns `pitch` apart, a pixel apart,
	/// the pitch itself first: with no icons below the first row, the rows
	/// keep it.
	static func spacings(_ pitch: Double) -> [Double] {
		var spacings = [pitch]
		var step = 1.0
		while pitch + step <= 1.3 * pitch || pitch - step >= 0.95 * pitch {
			if pitch + step <= 1.3 * pitch { spacings.append(pitch + step) }
			if pitch - step >= 0.95 * pitch { spacings.append(pitch - step) }
			step += 1
		}
		return spacings
	}

	/// How far apart the `items` best scores are from the rest: the mean of
	/// the one less the mean of the other.
	static func separation(_ scores: [Double], items: Int) -> Double {
		let sorted = scores.sorted(by: >)
		let count = min(max(items, 1), sorted.count - 1)
		let high = sorted.prefix(count).reduce(0, +) / Double(count)
		let low = sorted.dropFirst(count).reduce(0, +) / Double(sorted.count - count)
		return high - low
	}

	/// The middle of the stretch about `value`'s best, from `around` less
	/// `within` to `around` plus `within`, where it comes within a tenth of
	/// its range of its best.
	static func centre(around: Double, within: Double, by step: Double, _ value: (Double) -> Double) -> Double {
		let candidates = Array(stride(from: around - within, through: around + within + step / 2, by: step))
		let values = candidates.map(value)
		guard let most = values.max(), let least = values.min(), most > least,
		      let peak = values.firstIndex(of: most) else { return around }
		let near = most - 0.1 * (most - least)
		var low = peak, high = peak
		while low > 0, values[low - 1] >= near { low -= 1 }
		while high < values.count - 1, values[high + 1] >= near { high += 1 }
		return (candidates[low] + candidates[high]) / 2
	}

	// MARK: Outlines

	/// How clearly each place shows an icon's outline, row by row.
	public static func scores(_ pixels: Pixels, grid: Grid) -> [Double] {
		scores(Outlines(pixels), grid: grid)
	}

	static func scores(_ outlines: Outlines, grid: Grid) -> [Double] {
		grid.centres.map { outlines.score(x: $0.x, y: $0.y, half: grid.half) }
	}

	/// How sharply the colour changes at each pixel, from `reach` pixels on
	/// one side of it to as far on the other: across, where an icon's left
	/// and right sides are, and down, where its top and bottom are. Summed
	/// along each column and row, so that a side's mean takes two lookups.
	struct Outlines {
		let width: Int
		let height: Int
		/// Down each column, the sum of the change across over the rows
		/// before each: column x's, to row y, at x × (height + 1) + y.
		private var across: [Int32]
		/// Along each row, the sum of the change down over the columns
		/// before each: row y's, to column x, at y × (width + 1) + x.
		private var down: [Int32]

		init(_ pixels: Pixels) {
			let width = pixels.width, height = pixels.height
			self.width = width
			self.height = height
			var across = [Int32](repeating: 0, count: width * (height + 1))
			var down = [Int32](repeating: 0, count: height * (width + 1))
			let reach = OpenSpacesFinder.reach, cap = OpenSpacesFinder.cap
			pixels.rgba.withUnsafeBufferPointer { rgba in
				across.withUnsafeMutableBufferPointer { across in
					down.withUnsafeMutableBufferPointer { down in
						for y in 0..<height {
							for x in 0..<width {
								var sideways: Int32 = 0
								if x >= reach, x + reach < width {
									let left = (y * width + x - reach) * 4, right = (y * width + x + reach) * 4
									sideways = min(Self.change(rgba, left, right), cap)
								}
								let column = x * (height + 1) + y
								across[column + 1] = across[column] + sideways
								var upright: Int32 = 0
								if y >= reach, y + reach < height {
									let above = ((y - reach) * width + x) * 4, below = ((y + reach) * width + x) * 4
									upright = min(Self.change(rgba, above, below), cap)
								}
								let row = y * (width + 1) + x
								down[row + 1] = down[row] + upright
							}
						}
					}
				}
			}
			self.across = across
			self.down = down
		}

		/// The change in colour from one pixel to another, summed over red,
		/// green and blue.
		private static func change(_ rgba: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> Int32 {
			var total: Int32 = 0
			for channel in 0..<3 {
				let first = Int32(rgba[a + channel]), second = Int32(rgba[b + channel])
				total += abs(first - second)
			}
			return total
		}

		/// The mean change across the upright line at `x`, from `top` to
		/// `bottom`, both included, per colour: 0 off the picture.
		func upright(_ x: Int, from top: Int, to bottom: Int) -> Double {
			guard x >= 0, x < width else { return 0 }
			let from = max(top, 0), to = min(bottom, height - 1)
			guard to >= from else { return 0 }
			let column = x * (height + 1)
			let sum = across[column + to + 1] - across[column + from]
			return Double(sum) / Double(3 * (to - from + 1))
		}

		/// The mean change down the level line at `y`, from `left` to
		/// `right`, both included, per colour: 0 off the picture.
		func level(_ y: Int, from left: Int, to right: Int) -> Double {
			guard y >= 0, y < height else { return 0 }
			let from = max(left, 0), to = min(right, width - 1)
			guard to >= from else { return 0 }
			let row = y * (width + 1)
			let sum = down[row + to + 1] - down[row + from]
			return Double(sum) / Double(3 * (to - from + 1))
		}

		/// The pixel a position falls on, to the nearest.
		private static func pixel(_ position: Double) -> Int {
			Int(position.rounded())
		}

		/// How clearly an icon's outline shows around (`x`, `y`), `half`
		/// across from its centre: the change across the middle of each of
		/// its 4 sides, the least of them. A wallpaper's crease may run
		/// along one side; it doesn't go round all 4.
		func score(x: Double, y: Double, half: Double) -> Double {
			let span: Double = half * OpenSpacesFinder.straight
			let left = Self.pixel(x - half), right = Self.pixel(x + half)
			let top = Self.pixel(y - half), bottom = Self.pixel(y + half)
			let fromY = Self.pixel(y - span), toY = Self.pixel(y + span)
			let fromX = Self.pixel(x - span), toX = Self.pixel(x + span)
			let sides = min(upright(left, from: fromY, to: toY), upright(right, from: fromY, to: toY))
			let ends = min(level(top, from: fromX, to: toX), level(bottom, from: fromX, to: toX))
			return min(sides, ends)
		}
	}

	// MARK: Icons

	/// What an icon looks like, coarsely: the brightness of a square of
	/// cells over its middle, and how sharply it changes from cell to cell,
	/// which stays where an icon's glyph is when Dark, Tinted or Clear
	/// changes its colours. Each scaled so two compare from -1 to 1.
	struct Look {
		static let cells = 20
		/// The middle of an icon compared, of its side: inside its rounded
		/// corners and the rim iOS draws round it.
		static let middle = 0.76

		var light: [Double]
		var edges: [Double]

		/// An app's icon as SpringBoard draws it: its opaque part, as the
		/// corners may be clear. Nil when it has none.
		init?(icon: Pixels) {
			var left = icon.width, right = -1, top = icon.height, bottom = -1
			for y in 0..<icon.height {
				for x in 0..<icon.width where icon.rgba[(y * icon.width + x) * 4 + 3] > 200 {
					left = min(left, x)
					right = max(right, x)
					top = min(top, y)
					bottom = max(bottom, y)
				}
			}
			guard right >= left, bottom >= top else { return nil }
			let side = Double(min(right - left, bottom - top) + 1)
			let x = Double(left + right + 1) / 2, y = Double(top + bottom + 1) / 2
			self.init(Brightness(icon), x: x, y: y, half: side / 2)
		}

		/// The icon-sized square about (`x`, `y`), `half` across from it.
		init(_ light: Brightness, x: Double, y: Double, half: Double) {
			let cells = Self.cells
			let size = 2 * half * Self.middle, cell = size / Double(cells)
			let left = x - size / 2, top = y - size / 2
			var values = [Double](repeating: 0, count: cells * cells)
			for row in 0..<cells {
				for column in 0..<cells {
					let x0 = left + Double(column) * cell, y0 = top + Double(row) * cell
					values[row * cells + column] = light.mean(x0, y0, x0 + cell, y0 + cell)
				}
			}
			var edges: [Double] = []
			edges.reserveCapacity((cells - 2) * (cells - 2))
			for row in 1..<(cells - 1) {
				for column in 1..<(cells - 1) {
					let across = values[row * cells + column + 1] - values[row * cells + column - 1]
					let down = values[(row + 1) * cells + column] - values[(row - 1) * cells + column]
					edges.append((across * across + down * down).squareRoot())
				}
			}
			self.light = Self.scaled(values)
			self.edges = Self.scaled(edges)
		}

		/// Less the mean, over the length: so two compare as a correlation.
		/// All zeros for a flat patch.
		static func scaled(_ values: [Double]) -> [Double] {
			let mean = values.reduce(0, +) / Double(max(values.count, 1))
			var centred = values
			var total = 0.0
			for i in centred.indices {
				centred[i] -= mean
				total += centred[i] * centred[i]
			}
			// Nearly flat: a plain stretch of wallpaper.
			guard total > 4 * Double(values.count) else { return [Double](repeating: 0, count: values.count) }
			let length = total.squareRoot()
			return centred.map { $0 / length }
		}

		/// How alike two looks are, from -1 to 1: by brightness, or by
		/// where it changes, whichever says more.
		func likeness(_ other: Look) -> Double {
			max(Self.dot(light, other.light), Self.dot(edges, other.edges))
		}

		private static func dot(_ a: [Double], _ b: [Double]) -> Double {
			var sum = 0.0
			for i in a.indices { sum += a[i] * b[i] }
			return sum
		}
	}

	/// How alike each app's icon and each place are, from -1 to 1: nil for
	/// an item with no icon to go by. A few pixels either way, as the grid
	/// may be.
	static func likeness(_ looks: [Look?], at grid: Grid, in light: Brightness) -> [[Double]?] {
		let shifts: [Double] = [-2, 0, 2]
		var places: [[Look]] = []
		for centre in grid.centres {
			var shifted: [Look] = []
			for dy in shifts {
				for dx in shifts {
					shifted.append(Look(light, x: centre.x + dx, y: centre.y + dy, half: grid.half))
				}
			}
			places.append(shifted)
		}
		return looks.map { look in
			guard let look else { return nil }
			return places.map { shifted in
				var best = -1.0
				for place in shifted { best = max(best, look.likeness(place)) }
				return best
			}
		}
	}

	/// A picture's brightness, summed over the rectangle above and to the
	/// left of each pixel, so the mean over any rectangle takes 4 lookups.
	struct Brightness {
		let width: Int
		let height: Int
		/// At y × (width + 1) + x: the sum over the rows before y and the
		/// columns before x.
		private var sums: [Double]

		init(_ pixels: Pixels) {
			let width = pixels.width, height = pixels.height
			self.width = width
			self.height = height
			var sums = [Double](repeating: 0, count: (width + 1) * (height + 1))
			pixels.rgba.withUnsafeBufferPointer { rgba in
				sums.withUnsafeMutableBufferPointer { sums in
					for y in 0..<height {
						var row = 0.0
						for x in 0..<width {
							let i = (y * width + x) * 4
							let red = Double(rgba[i]), green = Double(rgba[i + 1]), blue = Double(rgba[i + 2])
							let value: Double = 0.299 * red + 0.587 * green + 0.114 * blue
							row += value
							let at: Int = (y + 1) * (width + 1) + x + 1
							let above: Double = sums[at - width - 1]
							sums[at] = above + row
						}
					}
				}
			}
			self.sums = sums
		}

		/// The mean brightness from (`x0`, `y0`) to (`x1`, `y1`), to whole
		/// pixels, at least one, inside the picture.
		func mean(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
			let left = min(max(Int(x0.rounded()), 0), width - 1)
			let top = min(max(Int(y0.rounded()), 0), height - 1)
			let right = min(max(Int(x1.rounded()), left + 1), width)
			let bottom = min(max(Int(y1.rounded()), top + 1), height)
			let stride = width + 1
			let total = sums[bottom * stride + right] - sums[top * stride + right] - sums[bottom * stride + left] + sums[top * stride + left]
			return total / Double((right - left) * (bottom - top))
		}
	}

	// MARK: Helpers

	/// `count` positions `step` apart, the first at `start`: a grid's
	/// columns or rows.
	static func positions(_ count: Int, from start: Double, every step: Double) -> [Double] {
		var positions: [Double] = []
		positions.reserveCapacity(count)
		for index in 0..<count {
			let offset = Double(index) * step
			positions.append(start + offset)
		}
		return positions
	}
}

extension OpenSpacesFinder {
	/// Which page a screenshot shows, of the page Atelier went to and the
	/// ones either side of it, by how many places show an outline: the one
	/// page with that many items. Nil when none has, or more than one, or a
	/// count isn't known. `counts` has each page's items, nil for a page
	/// with a widget.
	public static func page(showing outlines: Int, near page: Int, counts: [Int?]) -> Int? {
		Self.page(showing: outlines, among: [page, page - 1, page + 1], counts: counts)
	}

	/// Which of `pages` a screenshot shows, by how many places show an
	/// outline: the one with that many items, or nil.
	public static func page(showing outlines: Int, among pages: [Int], counts: [Int?]) -> Int? {
		let matching = pages.filter { counts.indices.contains($0) && counts[$0] == outlines }
		return matching.count == 1 ? matching[0] : nil
	}

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
