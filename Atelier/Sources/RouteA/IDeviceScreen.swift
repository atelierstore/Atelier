import Foundation
import IDevice

/// Find Open Spaces Automatically's calls to the phone (11 Nov 2026),
/// through Atelier's screen module (Packages/IDeviceBridge/src/screen.rs):
/// Apple's developer disk image, the developer services it brings, and
/// opening Atelier again. They block, so they run off the main actor, one
/// at a time.
extension IDeviceRouteA.Connection {
	/// The developer services iOS doesn't list in this tunnel's handshake:
	/// all of them before the developer disk image is mounted. A tunnel from
	/// before a mount doesn't list what it brings, so ask a new one after.
	func missingDeveloperServices() throws -> [String] {
		var missing: UnsafeMutablePointer<CChar>?
		try screenCheck(atelier_developer_services_missing(handshake, &missing))
		defer { atelier_screen_string_free(missing) }
		return (missing.map { String(cString: $0) } ?? "").split(separator: "\n").map(String.init)
	}

	/// Mounts the developer disk image, signed for this iPhone by Apple's
	/// signing server: as a cryptex from iOS 26.4, through the image
	/// mounter before.
	func mount(_ disk: DeveloperDiskImage.Files) throws {
		try disk.image.withBytes { image, imageLength in
			try disk.trustCache.withBytes { trustCache, trustCacheLength in
				try disk.buildManifest.withBytes { manifest, manifestLength in
					switch disk.kind {
					case .personalized:
						try screenCheck(atelier_mount_personalized_image(
							adapter, handshake,
							image, imageLength,
							trustCache, trustCacheLength,
							manifest, manifestLength
						))
					case .cryptex:
						try disk.info.withBytes { info, infoLength in
							try disk.rootHash.withBytes { rootHash, rootHashLength in
								try screenCheck(atelier_install_image_cryptex(
									adapter, handshake,
									image, imageLength,
									trustCache, trustCacheLength,
									info, infoLength,
									rootHash, rootHashLength,
									manifest, manifestLength
								))
							}
						}
					}
				}
			}
		}
	}

	/// Starts the screen stream iOS needs before it takes Atelier's presses
	/// and swipes, and connects the services that make them and take the
	/// screenshot. Needs the developer disk image mounted; the tunnel must
	/// stay open until the session ends.
	func startScreen() throws -> ScreenSession {
		var session: OpaquePointer?
		try screenCheck(atelier_screen_session_start(adapter, handshake, &session))
		return ScreenSession(session)
	}

	/// Opens the app installed as `bundleID`, or brings it to the front.
	func open(_ bundleID: String) throws {
		try screenCheck(atelier_launch_app(adapter, handshake, bundleID))
	}
}

/// A look at the Home Screen in progress: the screen stream, and the
/// services that press Home, swipe and take the screenshot. End it once.
final class ScreenSession: @unchecked Sendable {
	private var session: OpaquePointer?

	fileprivate init(_ session: OpaquePointer?) {
		self.session = session
	}

	func pressHome() throws {
		try screenCheck(atelier_screen_press_home(session))
	}

	/// Swipes across the screen at height `y`, from `fromX` to `toX`, each a
	/// fraction of the screen from its top left: from right to left goes to
	/// the Home Screen's next page.
	func swipe(fromX: Double, toX: Double, y: Double) throws {
		try screenCheck(atelier_screen_swipe(session, fromX, toX, y))
	}

	/// The screen as it is now, as PNG data.
	func screenshot() throws -> Data {
		var png: UnsafeMutablePointer<UInt8>?
		var length = 0
		try screenCheck(atelier_screen_screenshot(session, &png, &length))
		defer { atelier_screen_data_free(png, length) }
		guard let png else { throw ScreenCallError(code: 0, message: "no screenshot came back") }
		return Data(bytes: png, count: length)
	}

	/// Stops the screen stream, as far as iOS answers.
	func end() {
		atelier_screen_session_end(session)
		session = nil
	}
}

/// What idevice said when one of the screen module's calls failed.
struct ScreenCallError: Error, CustomStringConvertible {
	var code: Int32
	var message: String

	var description: String {
		"\(message.isEmpty ? "no message" : message) (idevice code \(code))"
	}
}

/// Turns idevice's error, if any, into a `ScreenCallError`, and frees it.
private func screenCheck(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
	guard let error else { return }
	let failure = ScreenCallError(
		code: error.pointee.code,
		message: error.pointee.message.map { String(cString: $0) } ?? ""
	)
	idevice_error_free(error)
	throw failure
}

private extension Data {
	/// Runs `body` with the bytes and their count, for a C call that reads
	/// them while it runs.
	func withBytes<T>(_ body: (UnsafePointer<UInt8>?, Int) throws -> T) rethrows -> T {
		try withUnsafeBytes { buffer in
			try body(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
		}
	}
}
