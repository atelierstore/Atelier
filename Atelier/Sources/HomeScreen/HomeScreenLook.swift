import CoreGraphics
import Foundation
import ImageIO
import InstallKit
import UIKit

/// Find Open Spaces Automatically's look at one page of the Home Screen
/// (11 Nov 2026): Atelier mounts Apple's developer disk image if this
/// iPhone hasn't got it yet, presses Home, swipes to the page, takes a
/// screenshot and opens itself again, through LocalDevVPN's tunnel to this
/// iPhone (IDeviceScreen.swift). Silent audio keeps it running in the
/// background meanwhile, as for pairing and installs. A step that fails
/// says which it was, once Atelier is back in front, and the setup's log
/// has each step.
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

	struct Look {
		/// The page, as PNG data.
		var screenshot: Data
		/// Whether Atelier came back to the front by itself.
		var cameBack: Bool
	}

	/// How long the Home Screen takes to settle after a press, long enough
	/// apart that two presses aren't a double press.
	private static let afterHome: Duration = .milliseconds(1200)
	/// And after a swipe to the next page.
	private static let afterSwipe: Duration = .milliseconds(800)
	/// Less than this between two screenshots is the same page: the mean
	/// difference in brightness, 0 to 255.
	private static let samePage = 3.0

	/// Takes a screenshot of the Home Screen's `page`, from 0.
	static func look(atPage page: Int) async throws -> Look {
		say("page \(page + 1): looking")
		if case .unavailable(let why) = await RouteASetup.shared.makeInstaller().check(startingVPN: true) {
			say("connect: \(why)")
			throw Failure(step: .connect, message: "Couldn’t look at your Home Screen. \(why)")
		}
		guard let pairingFile = try? PairingFileStore.standard().load() else {
			throw Failure(step: .connect, message: "Couldn’t look at your Home Screen. \(PairingInstaller.noPairingFile)")
		}
		let tunnel = try await mountedTunnel(pairingFile)
		do {
			let look = try await leaveAndLook(tunnel, page: page)
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

	/// Leaves Atelier for the page and takes its screenshot, then comes
	/// back, whatever happened on the way.
	private static func leaveAndLook(_ tunnel: Tunnel, page: Int) async throws -> Look {
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
		let session = try await step(.home, "this iPhone didn’t let Atelier press Home") {
			try tunnel.connection.startScreen()
		}
		say("started the screen stream")
		let result: Result<Data, Error>
		do {
			result = .success(try await goAndLook(session, page: page))
		} catch {
			result = .failure(error)
		}
		await quietly { session.end() }
		let cameBack = await comeBack(tunnel)
		return Look(screenshot: try result.get(), cameBack: cameBack)
	}

	/// Presses Home, goes to the page and takes its screenshot.
	private static func goAndLook(_ session: ScreenSession, page: Int) async throws -> Data {
		try await step(.home, "this iPhone didn’t let Atelier press Home") { try session.pressHome() }
		guard await comesTrue(within: .seconds(3), { UIApplication.shared.applicationState != .active }) else {
			throw Failure(step: .home, message: message("this iPhone didn’t go to the Home Screen when Atelier pressed Home"))
		}
		say("pressed Home: Atelier is in the background")
		// Home again goes to the first page, once a folder or the App Library
		// that was open closes, and does nothing there.
		for _ in 0..<2 {
			try await Task.sleep(for: afterHome)
			try await step(.home, "this iPhone didn’t let Atelier press Home") { try session.pressHome() }
		}
		try await Task.sleep(for: afterHome)
		var shot = try await screenshot(session)
		say("on the first page")
		guard page > 0 else { return shot }
		for swipe in 1...page {
			let before = shot
			shot = try await swipeOnce(session)
			if try await isSamePage(before, shot) {
				say("swipe \(swipe) left the screen as it was; swiping again")
				shot = try await swipeOnce(session)
				if try await isSamePage(before, shot) {
					throw Failure(step: .swipe, message: message("this iPhone didn’t take Atelier’s swipe"))
				}
			}
		}
		say("swiped to page \(page + 1)")
		return shot
	}

	/// Swipes to the next page and takes its screenshot.
	private static func swipeOnce(_ session: ScreenSession) async throws -> Data {
		try await step(.swipe, "this iPhone didn’t take Atelier’s swipe") {
			try session.swipe(fromX: 0.85, toX: 0.15, y: 0.55)
		}
		try await Task.sleep(for: afterSwipe)
		return try await screenshot(session)
	}

	private static func screenshot(_ session: ScreenSession) async throws -> Data {
		try await step(.screenshot, "this iPhone didn’t give Atelier a screenshot") { try session.screenshot() }
	}

	/// Whether two screenshots show the same page: a swipe that didn't take.
	private static func isSamePage(_ first: Data, _ second: Data) async throws -> Bool {
		let difference = await Task.detached {
			guard let a = OpenSpacesFinder.Pixels(png: first, width: 90),
			      let b = OpenSpacesFinder.Pixels(png: second, width: 90) else { return Double.infinity }
			return OpenSpacesFinder.difference(a, b)
		}.value
		guard difference.isFinite else {
			throw Failure(step: .screenshot, message: message("this iPhone didn’t give Atelier a screenshot"))
		}
		return difference < samePage
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

	/// Reads the page's empty places from its screenshot, with `items`
	/// icons and folders on it, and the grid an earlier reading on this
	/// screen found. Keeps the grid when it reads the page clearly.
	static func read(_ png: Data, items: Int, page: Int) async -> OpenSpacesFinder.Reading? {
		guard let size = await Task.detached(operation: { pixelSize(of: png) }).value else {
			say("page \(page + 1): the screenshot couldn’t be read")
			return nil
		}
		let key = "openSpacesGrid.\(size.width)x\(size.height)"
		let known = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(OpenSpacesFinder.Grid.self, from: $0) }
		let reading = await Task.detached {
			OpenSpacesFinder.Pixels(png: png, width: OpenSpacesFinder.readingWidth).flatMap {
				OpenSpacesFinder.read($0, items: items, known: known)
			}
		}.value
		guard let reading else {
			say("page \(page + 1): no grid in the \(size.width) × \(size.height) screenshot")
			return nil
		}
		let grid = reading.grid
		say("page \(page + 1): \(size.width) × \(size.height), \(reading.grid == known ? "the grid from before" : "a grid found now"): columns \(rounded(grid.columns)), rows \(rounded(grid.rows)), at \(OpenSpacesFinder.readingWidth) px wide")
		say("page \(page + 1): scores \(rounded(reading.scores)); empty \(reading.empty.map { $0 + 1 }); open spaces \(reading.openSpaces.map { $0 + 1 })\(reading.isDoubtful ? "; check this page" : "")")
		if !reading.isDoubtful, let data = try? JSONEncoder().encode(grid) {
			UserDefaults.standard.set(data, forKey: key)
		}
		return reading
	}

	private nonisolated static func pixelSize(of png: Data) -> (width: Int, height: Int)? {
		guard let source = CGImageSourceCreateWithData(png as CFData, nil),
		      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
		      let width = properties[kCGImagePropertyPixelWidth] as? Int,
		      let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
		return (width, height)
	}

	private static func rounded(_ values: [Double]) -> String {
		"[" + values.map { String(format: "%.0f", $0) }.joined(separator: ", ") + "]"
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

	private static func say(_ line: String) {
		PhonePairing.shared.note("open spaces: \(line)")
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
		      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
		      image.width > 0,
		      let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
		let height = max(Int((Double(image.height) * Double(width) / Double(image.width)).rounded()), 1)
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
