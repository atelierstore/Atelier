import CoreGraphics
import Foundation
import ImageIO
import InstallKit
import UIKit

/// Find Open Spaces Automatically's look at one page of the Home Screen
/// (11 Nov 2026): Atelier mounts Apple's developer disk image if this
/// iPhone hasn't got it yet, presses Home, goes to the page, takes a
/// screenshot and opens itself again, through LocalDevVPN's tunnel to this
/// iPhone (IDeviceScreen.swift). Silent audio keeps it running in the
/// background meanwhile, as for pairing and installs. A step that fails
/// says which it was, once Atelier is back in front, and the setup's log
/// has each step.
///
/// To get to the page (12 Nov 2026), it slides a finger along the page
/// dots, as you can by hand, and checks the screenshot shows that page's
/// apps. If it doesn't, it presses Home again and swipes there one page at
/// a time, without stopping; after two such looks in a row, it swipes
/// straight there. It keeps the Home Screen's waits short, and comes back
/// as soon as it has the screenshot. The log says how long into the look
/// each step was.
@MainActor
enum HomeScreenLook {
	/// The steps, as a failure names them.
	enum Step: String {
		case connect, download, mount, home, swipe, screenshot
	}

	struct Failure: Error {
		var step: Step
		/// What Open Spaces says.
		var message: String
	}

	/// What a look at a page found.
	struct Look {
		/// What the screenshot showed of the page, or nil when no grid of
		/// icons showed in it.
		var reading: OpenSpacesFinder.Reading?
		/// Whether Atelier came back to the front by itself.
		var cameBack: Bool
	}

	/// The page to look at, and what Atelier knows of it and the others.
	struct Target: Sendable {
		/// The page, from 0.
		var page: Int
		/// Its items in the order iOS lists them: each app's icon as
		/// SpringBoard draws it, or nil for a folder or an app whose icon
		/// didn't come.
		var icons: [OpenSpacesFinder.Pixels?]
		/// Each page's number of items, nil for a page with a widget.
		var counts: [Int?]
	}

	/// How long the Home Screen takes to settle after a press, long enough
	/// apart that two presses aren't a double press.
	private static let afterHome: Duration = .milliseconds(600)
	/// Between swipes straight through to a page: the next page is in place.
	private static let betweenSwipes: Duration = .milliseconds(350)
	/// Before the screenshot: the page has stopped moving.
	private static let beforeScreenshot: Duration = .milliseconds(500)
	/// The page dots, as iOS 26 draws them in place of the Search button
	/// while pages change: 4 at a time, 14 points apart, their middle 150
	/// points above the bottom of the screen, on a 6.1-inch iPhone with 11
	/// pages (measured on a recording, 12 Nov 2026).
	private static let dotSpacing = 14.0
	private static let dotsAboveBottom = 150.0
	/// The slide along the dots, once the swipe that brings them out is
	/// done: a rest on the second page's dot, so iOS takes the touch, a dot
	/// a page in `slidePerPage` milliseconds, and a rest on the page's dot
	/// before letting go.
	private static let beforeSlide: Duration = .milliseconds(250)
	private static let slideHold: Duration = .milliseconds(100)
	private static let slidePerPage = 60
	private static let slideSettle: Duration = .milliseconds(150)
	/// When the look started, for the log's times.
	private static var started = ContinuousClock.now

	/// Takes a screenshot of the Home Screen's page and reads it.
	static func look(at target: Target) async throws -> Look {
		started = .now
		say("page \(target.page + 1): looking")
		if case .unavailable(let why) = await RouteASetup.shared.makeInstaller().check(startingVPN: true) {
			say("connect: \(why)")
			throw Failure(step: .connect, message: "Couldn’t look at your Home Screen. \(why)")
		}
		guard let pairingFile = try? PairingFileStore.standard().load() else {
			throw Failure(step: .connect, message: "Couldn’t look at your Home Screen. \(PairingInstaller.noPairingFile)")
		}
		let tunnel = try await mountedTunnel(pairingFile)
		do {
			let look = try await leaveAndLook(tunnel, target: target)
			await quietly { tunnel.close() }
			return look
		} catch {
			await quietly { tunnel.close() }
			throw error
		}
	}

	// MARK: The developer disk image

	/// A tunnel whose handshake lists the developer services, after mounting
	/// the developer disk image if they're missing.
	private static func mountedTunnel(_ pairingFile: Data) async throws -> Tunnel {
		let tunnel = try await connect(pairingFile)
		let missing: [String]
		do {
			missing = try await call { try tunnel.connection.missingDeveloperServices() }
		} catch {
			await quietly { tunnel.close() }
			throw failure(.mount, "this iPhone didn’t take Apple’s developer disk image", error)
		}
		guard !missing.isEmpty else {
			say("the developer services are there")
			return tunnel
		}
		say("missing \(missing.joined(separator: ", ")): mounting Apple’s developer disk image (\(DeveloperDiskImage.kind.rawValue))")
		do {
			try await mount(on: tunnel)
		} catch {
			await quietly { tunnel.close() }
			throw error
		}
		await quietly { tunnel.close() }
		// A new tunnel's handshake lists what the image brought.
		let after = try await connect(pairingFile)
		let still = (try? await call { try after.connection.missingDeveloperServices() }) ?? ["the list of services"]
		guard still.isEmpty else {
			say("mount: still missing \(still.joined(separator: ", "))")
			await quietly { after.close() }
			throw Failure(step: .mount, message: message("this iPhone didn’t take Apple’s developer disk image"))
		}
		say("mounted: the developer services are there")
		return after
	}

	/// Mounts the developer disk image: the one kept from before, or one
	/// downloaded now. When the kept one doesn't mount, it may be out of
	/// date, so it's downloaded once more.
	private static func mount(on tunnel: Tunnel) async throws {
		var files = try await diskImage(fresh: false)
		do {
			try await call { [files] in try tunnel.connection.mount(files) }
			return
		} catch {
			guard !files.downloaded else { throw failure(.mount, "this iPhone didn’t take Apple’s developer disk image", error) }
			say("mount: \(error); downloading it again")
		}
		files = try await diskImage(fresh: true)
		do {
			try await call { [files] in try tunnel.connection.mount(files) }
		} catch {
			throw failure(.mount, "this iPhone didn’t take Apple’s developer disk image", error)
		}
	}

	private static func diskImage(fresh: Bool) async throws -> DeveloperDiskImage.Files {
		do {
			let files = try await DeveloperDiskImage.files(fresh: fresh)
			if files.downloaded { say("downloaded Apple’s developer disk image, \(Int64(files.image.count).formatted(.byteCount(style: .file)))") }
			return files
		} catch {
			throw failure(.download, "Atelier couldn’t download Apple’s developer disk image", error)
		}
	}

	// MARK: The Home Screen

	/// Leaves Atelier for the page and reads its screenshot, then comes
	/// back, whatever happened on the way.
	private static func leaveAndLook(_ tunnel: Tunnel, target: Target) async throws -> Look {
		// Atelier keeps running once it isn't in front.
		do {
			try SilentAudio.shared.start(for: .openSpaces)
		} catch {
			say("silent audio didn’t start: \(error)")
		}
		let background = BackgroundTime()
		defer {
			SilentAudio.shared.stop(for: .openSpaces)
			background.end()
		}
		let session = try await startScreen(tunnel)
		let result: Result<OpenSpacesFinder.Reading?, Error>
		do {
			result = .success(try await goAndRead(session, target: target))
		} catch {
			result = .failure(error)
		}
		// Back first: iOS can take its time to stop the screen stream.
		let cameBack = await comeBack(tunnel)
		await quietly { session.end() }
		say("stopped the screen stream")
		return Look(reading: try result.get(), cameBack: cameBack)
	}

	/// Starts the screen stream, named Atelier, so that iOS's notification
	/// afterwards might say the iPhone was viewed from Atelier rather than
	/// from a Mac (12 Nov 2026). Without the name if iOS doesn't take it.
	private static func startScreen(_ tunnel: Tunnel) async throws -> ScreenSession {
		do {
			let session = try await call { try tunnel.connection.startScreen(named: "Atelier") }
			say("started the screen stream, named Atelier")
			return session
		} catch {
			say("the screen stream named Atelier didn’t start: \(error); starting it without a name")
		}
		let session = try await step(.home, "this iPhone didn’t let Atelier press Home") {
			try tunnel.connection.startScreen(named: nil)
		}
		say("started the screen stream")
		return session
	}

	/// Presses Home, goes to the page, and reads its screenshot: by sliding
	/// along the page dots, then, if the screenshot shows another page, by
	/// swiping.
	private static func goAndRead(_ session: ScreenSession, target: Target) async throws -> OpenSpacesFinder.Reading? {
		let page = target.page
		try await step(.home, "this iPhone didn’t let Atelier press Home") { try session.pressHome() }
		guard await comesTrue(within: .seconds(3), { UIApplication.shared.applicationState != .active }) else {
			throw Failure(step: .home, message: message("this iPhone didn’t go to the Home Screen when Atelier pressed Home"))
		}
		say("pressed Home: Atelier is in the background")
		// Home again goes to the first page, once a folder or the App Library
		// that was open closes, and does nothing there.
		try await pressHome(session, times: 2)
		say("on the first page")
		guard page > 0 else { return try await readScreen(session, target: target, how: "first page") }

		// A swipe to the second page brings out the page dots. A finger then
		// slides along them to the page, unless that landed on another page
		// the last two times.
		try await swipe(session)
		if page > 1, slideMisses < 2 {
			try await slide(session, to: page)
			let slid = try await readScreen(session, target: target, how: "slide")
			let landed = isPage(slid, target: target)
			if let landed { slideMisses = landed ? 0 : slideMisses + 1 }
			if landed != false { return slid }
			say("swiping to page \(page + 1) instead, from the first page")
			try await pressHome(session, times: 2)
			try await swipe(session, pages: page)
		} else if page > 1 {
			say("the slide along the page dots landed elsewhere the last two times: swiping to page \(page + 1)")
			try await Task.sleep(for: betweenSwipes)
			try await swipe(session, pages: page - 1)
		}
		let swiped = try await readScreen(session, target: target, how: page > 1 ? "swipes" : "swipe")
		guard isPage(swiped, target: target) == false, let reading = swiped else { return swiped }
		// A swipe too few or too many: once more, either way, when the
		// number of outlines says which.
		let shown = OpenSpacesFinder.page(showing: reading.outlines, near: page, counts: target.counts)
		if shown == page - 1 {
			say("one swipe short: swiping once more")
			try await swipe(session)
		} else if shown == page + 1 {
			say("one swipe too many: swiping back")
			try await swipe(session, back: true)
		} else {
			return reading
		}
		return try await readScreen(session, target: target, how: "one more swipe")
	}

	/// Slides a finger along the page dots, which the swipe to the second
	/// page brought out, from its dot to where the page's would be, a dot a
	/// page.
	private static func slide(_ session: ScreenSession, to page: Int) async throws {
		try await Task.sleep(for: beforeSlide)
		let screen = screenSize
		let dot = dotSpacing / screen.width
		let from = 0.5 - 0.5 * dot, to = from + Double(page - 1) * dot
		let y = 1 - dotsAboveBottom / screen.height
		let hold = slideHold, move = Duration.milliseconds(slidePerPage * (page - 1)), settle = slideSettle
		do {
			try await call {
				try session.slide(fromX: from, toX: to, y: y, hold: hold, move: move, settle: settle)
			}
			say("slid along the page dots from page 2 to where page \(page + 1)’s dot would be (\(rounded(from, 3)) to \(rounded(to, 3)) across, \(rounded(y, 3)) down)")
		} catch {
			say("slide: \(error)")
		}
	}

	/// How many looks in a row the slide along the page dots landed on
	/// another page. After two, Atelier swipes straight to the page.
	private static var slideMisses: Int {
		get { UserDefaults.standard.integer(forKey: slideMissesKey) }
		set { UserDefaults.standard.set(newValue, forKey: slideMissesKey) }
	}

	private static let slideMissesKey = "openSpacesSlideMisses"

	/// Presses Home `times` times, far enough apart not to be a double
	/// press, and waits for the Home Screen to settle.
	private static func pressHome(_ session: ScreenSession, times: Int) async throws {
		for _ in 0..<times {
			try await Task.sleep(for: afterHome)
			try await step(.home, "this iPhone didn’t let Atelier press Home") { try session.pressHome() }
		}
		try await Task.sleep(for: afterHome)
	}

	/// Swipes to the next page, or back to the one before.
	private static func swipe(_ session: ScreenSession, back: Bool = false) async throws {
		try await step(.swipe, "this iPhone didn’t take Atelier’s swipe") {
			try session.swipe(fromX: back ? 0.15 : 0.85, toX: back ? 0.85 : 0.15, y: 0.55)
		}
	}

	/// Swipes `pages` pages on, one at a time, without stopping.
	private static func swipe(_ session: ScreenSession, pages: Int) async throws {
		for done in 0..<pages {
			if done > 0 { try await Task.sleep(for: betweenSwipes) }
			try await swipe(session)
		}
	}

	/// Takes a screenshot once the page has stopped moving, and reads it.
	private static func readScreen(_ session: ScreenSession, target: Target, how: String) async throws -> OpenSpacesFinder.Reading? {
		try await Task.sleep(for: beforeScreenshot)
		let png = try await step(.screenshot, "this iPhone didn’t give Atelier a screenshot") { try session.screenshot() }
		say("took a screenshot, \(png.count / 1024) KB")
		let reading = await read(png, target: target)
		if let reading {
			let pages = target.counts.indices.filter { target.counts[$0] == reading.outlines }.map { String($0 + 1) }
			say("\(how): found \(reading.iconsFound) of \(reading.iconsKnown) apps’ icons where they go on page \(target.page + 1); \(reading.outlines) places show an outline, as many as page \(pages.isEmpty ? "none" : pages.joined(separator: ", ")) has items")
		}
		return reading
	}

	/// Whether a reading shows the page: nil when it can't tell, with no
	/// apps' icons to go by.
	private static func isPage(_ reading: OpenSpacesFinder.Reading?, target: Target) -> Bool? {
		guard let reading else { return false }
		guard reading.iconsKnown > 0 else { return nil }
		return reading.iconsFound * 2 >= reading.iconsKnown
	}

	/// The screen's size in points.
	private static var screenSize: CGSize {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		return scenes.first?.screen.bounds.size ?? CGSize(width: 393, height: 852)
	}

	/// Opens Atelier again, if it isn't in front: whether it came back.
	private static func comeBack(_ tunnel: Tunnel) async -> Bool {
		guard UIApplication.shared.applicationState != .active else { return true }
		guard let bundleID = Bundle.main.bundleIdentifier else { return false }
		do {
			try await call { try tunnel.connection.open(bundleID) }
		} catch {
			say("back: \(error)")
			return false
		}
		let back = await comesTrue(within: .seconds(5)) { UIApplication.shared.applicationState == .active }
		say(back ? "back in Atelier" : "back: Atelier didn’t come to the front")
		return back
	}

	// MARK: Reading the screenshot

	/// Where the grid an earlier reading on this screen found is kept.
	private static let gridKey = "openSpacesGrid2"

	/// The grid kept, with the size of the screenshot read at
	/// `OpenSpacesFinder.readingWidth` it was found on.
	private struct KeptGrid: Codable, Sendable {
		var width: Int
		var height: Int
		var grid: OpenSpacesFinder.Grid
	}

	/// Reads the page from its screenshot, with the grid an earlier reading
	/// on this screen found. Keeps the grid when it reads the page clearly
	/// and its rows show.
	private static func read(_ png: Data, target: Target) async -> OpenSpacesFinder.Reading? {
		let page = target.page
		let kept = UserDefaults.standard.data(forKey: gridKey).flatMap { try? JSONDecoder().decode(KeptGrid.self, from: $0) }
		let icons = target.icons
		let result = await Task.detached { () -> (pixels: OpenSpacesFinder.Pixels, reading: OpenSpacesFinder.Reading?)? in
			guard let pixels = OpenSpacesFinder.Pixels(png: png, width: OpenSpacesFinder.readingWidth) else { return nil }
			let known = kept.flatMap { $0.width == pixels.width && $0.height == pixels.height ? $0.grid : nil }
			return (pixels, OpenSpacesFinder.read(pixels, icons: icons, known: known))
		}.value
		guard let result else {
			say("page \(page + 1): the screenshot couldn’t be read")
			return nil
		}
		let size = "\(result.pixels.width) × \(result.pixels.height)"
		guard let reading = result.reading else {
			say("page \(page + 1): no grid of icons in the screenshot, read \(size)")
			return nil
		}
		let grid = reading.grid
		let found = reading.grid == kept?.grid ? "the grid from before" : "a grid found now"
		say("page \(page + 1): read \(size), \(found): columns \(rounded(grid.columns)), rows \(rounded(grid.rows)), icons \(rounded(2 * grid.half, 0)) across")
		let likeness = reading.likeness.map { $0.map { rounded($0, 2) } ?? "folder" }
		let check = reading.isDoubtful ? "; check this page" : ""
		say("page \(page + 1): outlines \(rounded(reading.scores)); items at \(places(reading.places)), likeness \(likeness.joined(separator: ", ")); open spaces \(places(reading.openSpaces))\(check)")
		if !reading.isDoubtful, reading.placesTheRows,
		   let data = try? JSONEncoder().encode(KeptGrid(width: result.pixels.width, height: result.pixels.height, grid: grid)) {
			UserDefaults.standard.set(data, forKey: gridKey)
		}
		return reading
	}

	private static func rounded(_ values: [Double]) -> String {
		let parts = values.map { (value: Double) -> String in String(format: "%.0f", value) }
		return "[\(parts.joined(separator: ", "))]"
	}

	private static func rounded(_ value: Double, _ digits: Int) -> String {
		String(format: "%.\(digits)f", value)
	}

	/// Places counted from 1, as people count them.
	private static func places(_ indices: [Int]) -> String {
		let parts = indices.map { (index: Int) -> String in String(index + 1) }
		return "[\(parts.joined(separator: ", "))]"
	}

	// MARK: Helpers

	private static func connect(_ pairingFile: Data) async throws -> Tunnel {
		do {
			return try await call {
				let tunnel = try IDeviceRouteA().connect(pairingFile: pairingFile)
				guard let connection = tunnel as? IDeviceRouteA.Connection else {
					tunnel.close()
					throw CocoaError(.featureUnsupported)
				}
				return Tunnel(connection)
			}
		} catch {
			throw failure(.connect, "Atelier couldn’t connect to this iPhone through LocalDevVPN", error)
		}
	}

	/// Runs a call of the step's, off the main actor; when it fails, says
	/// so in the log and as `reason`.
	private static func step<T: Sendable>(_ step: Step, _ reason: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
		do {
			return try await call(body)
		} catch {
			throw failure(step, reason, error)
		}
	}

	private static func failure(_ step: Step, _ reason: String, _ error: Error) -> Failure {
		say("\(step.rawValue): \(error)")
		return Failure(step: step, message: message(reason))
	}

	/// What Open Spaces says when a step fails.
	private static func message(_ reason: String) -> String {
		"Couldn’t look at your Home Screen: \(reason). Mark them by hand, or try again."
	}

	/// Runs blocking calls off the main actor.
	private static func call<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
		try await Task.detached(operation: body).value
	}

	private static func quietly(_ body: @escaping @Sendable () -> Void) async {
		await Task.detached(operation: body).value
	}

	/// Whether `condition` comes true within `limit`, asked every tenth of
	/// a second.
	private static func comesTrue(within limit: Duration, _ condition: () -> Bool) async -> Bool {
		let deadline = ContinuousClock.now + limit
		while !condition() {
			guard ContinuousClock.now < deadline else { return false }
			try? await Task.sleep(for: .milliseconds(100))
		}
		return true
	}

	/// Notes `line` in the setup's log, with how long into the look it was.
	private static func say(_ line: String) {
		let elapsed = (ContinuousClock.now - started).components
		let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
		PhonePairing.shared.note("open spaces, \(rounded(seconds, 1)) s: \(line)")
	}
}

/// The look's tunnel, which its calls share, one at a time.
private final class Tunnel: @unchecked Sendable {
	let connection: IDeviceRouteA.Connection

	init(_ connection: IDeviceRouteA.Connection) {
		self.connection = connection
	}

	func close() {
		connection.close()
	}
}

/// Background time asked of iOS while Atelier is on the Home Screen, ended
/// once.
@MainActor
private final class BackgroundTime {
	private var task = UIBackgroundTaskIdentifier.invalid

	init() {
		task = UIApplication.shared.beginBackgroundTask(withName: "Find Open Spaces") { [weak self] in
			MainActor.assumeIsolated { self?.end() }
		}
	}

	func end() {
		guard task != .invalid else { return }
		UIApplication.shared.endBackgroundTask(task)
		task = .invalid
	}
}

extension OpenSpacesFinder.Pixels {
	/// `png` drawn `width` pixels wide, in sRGB.
	init?(png: Data, width: Int) {
		guard let source = CGImageSourceCreateWithData(png as CFData, nil),
		      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
		self.init(image: image, width: width)
	}

	/// `image` drawn `width` pixels wide, in sRGB, its clear parts clear.
	init?(image: CGImage, width: Int) {
		guard image.width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
		let scale = Double(width) / Double(image.width)
		let scaled = (Double(image.height) * scale).rounded()
		let height = max(Int(scaled), 1)
		var rgba = [UInt8](repeating: 0, count: width * height * 4)
		let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext(
				data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
				space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.interpolationQuality = .high
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		guard drawn else { return nil }
		self.init(width: width, height: height, rgba: rgba)
	}
}
