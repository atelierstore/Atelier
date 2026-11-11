#if canImport(Network) && canImport(ObjectiveC)
import Foundation

/// One route B install: serves the IPA on 127.0.0.1, checks Atelier's
/// manifest endpoint, opens the `itms-services://` link, and follows the
/// install until it ends. The loopback server stops when `run` returns.
///
/// With `isRegistered` (`canOpenURL` for a scheme), it confirms the install
/// through the app's check scheme (`InstallCheck`).
///
/// When the alert closes without iOS asking for the IPA, the session waits
/// with the server still running, so `retry` shows the alert again for the
/// same signed IPA (#51).
///
/// Opening the link directly (no web page or Safari view) worked in the
/// install spike, and keeps Atelier in front while iOS downloads the IPA.
@MainActor
public final class RouteBSession {
	public enum StartError: Error, Equatable, CustomStringConvertible {
		case manifestUnreachable(String)
		case manifestRejected(status: Int, message: String)
		case manifestInvalid
		case linkNotOpened

		public var description: String {
			switch self {
			case .manifestUnreachable(let reason):
				"Couldn't reach the manifest endpoint: \(reason)"
			case .manifestRejected(let status, let message):
				"The manifest endpoint refused this app (HTTP \(status)): \(message)"
			case .manifestInvalid:
				"The manifest endpoint didn't return an install manifest. Check the endpoint in Settings."
			case .linkNotOpened:
				"iOS didn't open the install link."
			}
		}
	}

	public let info: IPAInfo
	public private(set) var phase: RouteBTracker.Phase = .waitingForApproval
	/// What happened, one line per event, for the install log.
	public private(set) var log: [String] = []
	/// Called on the main actor whenever `phase` or `log` changes.
	public var onChange: (() -> Void)?

	private let ipa: URL
	private let endpoint: URL
	private let confirmingSignals: Set<String>
	private let isRegistered: (@MainActor (String) -> Bool)?
	private let timing: RouteBTracker.Timing
	private var tracker: RouteBTracker?
	private var startedAt = Date()
	private var lastLoggedTenth = -1
	private var lastSystemPercent: Int?
	private var checkScheme: String?
	private var lastRegistered = false
	private var link: URL?
	private var openLink: ((URL) async -> Bool)?

	public init(
		ipa: URL,
		info: IPAInfo,
		endpoint: URL,
		confirmingSignals: Set<String> = [],
		isRegistered: (@MainActor (String) -> Bool)? = nil,
		timing: RouteBTracker.Timing = RouteBTracker.Timing()
	) {
		self.ipa = ipa
		self.info = info
		self.endpoint = endpoint
		self.confirmingSignals = confirmingSignals
		self.isRegistered = isRegistered
		self.timing = timing
	}

	/// Runs the install. `open` opens a URL, normally `UIApplication.open`.
	/// Throws `StartError` when the install can't start, and
	/// `CancellationError` when the task is cancelled.
	public func run(open: @escaping (URL) async -> Bool) async throws -> RouteBTracker.Outcome {
		startedAt = Date()
		let server = LoopbackServer(fileURLs: [ipa])
		defer {
			server.stop()
			note("server stopped")
		}
		let port = try await server.start()
		note("serving \(info.bundleID) \(info.version) on 127.0.0.1:\(port)")

		let manifestURL = InstallLink.manifestURL(endpoint: endpoint, info: info, packageURL: server.url(of: server.packages[0], port: port))
		try await preflight(manifestURL)

		checkScheme = installCheckScheme()
		tracker = RouteBTracker(startedAt: Date(), timing: timing, confirmingSignals: confirmingSignals, checksInstall: checkScheme != nil)
		server.onRequest = { @Sendable [weak self] _, method in
			Task { @MainActor in self?.update("iOS sent \(method)") { $0.requestSeen(at: Date()) } }
		}
		server.onPayloadProgress = { @Sendable [weak self] _, sent, total in
			Task { @MainActor in self?.payloadProgress(sent: sent, total: total) }
		}
		server.onPayloadEnded = { @Sendable [weak self] _, whole in
			Task { @MainActor in
				self?.update(whole ? "iOS has the whole IPA" : "download broke off") { $0.payloadEnded(complete: whole, at: Date()) }
			}
		}
		let listener = SystemInstallSignals.listen { [weak self] name in
			Task { @MainActor in self?.update("notification \(name)") { $0.systemSignal(name, at: Date()) } }
		}
		defer { withExtendedLifetime(listener) {} }
		// Logged as well, so a device's install log shows how the alert and
		// Atelier's state line up (#51).
		let activity = [
			NotificationCenter.default.addObserver(forName: Self.resignedActive, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in self?.update("Atelier inactive") { $0.appResignedActive(at: Date()) } }
			},
			NotificationCenter.default.addObserver(forName: Self.becameActive, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in self?.update("Atelier active") { $0.appBecameActive(at: Date()) } }
			},
		]
		defer { activity.forEach { NotificationCenter.default.removeObserver($0) } }

		let link = InstallLink.itmsServicesURL(manifest: manifestURL)
		self.link = link
		openLink = open
		defer { openLink = nil }
		guard await open(link) else {
			throw StartError.linkNotOpened
		}
		note("install link opened; waiting for the iOS alert")

		while true {
			if case .finished(let outcome) = phase {
				note("finished: \(outcome)")
				return outcome
			}
			try Task.checkCancellation()
			let fraction = SystemInstallSignals.installProgress(for: info.bundleID)
			logSystemProgress(fraction)
			let registered = installCheck()
			update(nil) {
				$0.systemProgress(fraction, at: Date())
				if let registered { $0.installCheck(registered: registered, at: Date()) }
				$0.tick(at: Date())
			}
			try await Task.sleep(nanoseconds: 250_000_000)
		}
	}

	/// `UIApplication`'s notifications, by name, as InstallKit doesn't link UIKit.
	static let resignedActive = Notification.Name("UIApplicationWillResignActiveNotification")
	static let becameActive = Notification.Name("UIApplicationDidBecomeActiveNotification")

	/// Opens the install link again after the alert closed without
	/// installing, for the IPA already signed and served.
	public func retry() async {
		guard phase == .alertClosed, let link, let openLink else { return }
		update("trying again: opening the install link") { $0.retry(at: Date()) }
		if await openLink(link) {
			note("install link opened; waiting for the iOS alert")
		} else {
			update("iOS didn't open the install link") { $0.giveUp() }
		}
	}

	/// Ends an install whose alert closed, as not started.
	public func giveUp() {
		update("given up on the install alert") { $0.giveUp() }
	}

	/// The app's check scheme, if it can confirm this install: one that no
	/// installed app registers yet.
	private func installCheckScheme() -> String? {
		guard let isRegistered else { return nil }
		guard let scheme = InstallCheck.scheme(of: info) else {
			note("install check: the app has no check scheme, so the install can't be confirmed")
			return nil
		}
		if isRegistered(scheme) {
			note("install check: \(scheme) is already registered (this build is already installed, or another app has it), so the install can't be confirmed")
			return nil
		}
		note("install check: waiting for \(scheme)")
		return scheme
	}

	/// Asks whether the check scheme answers, once iOS has the whole IPA.
	private func installCheck() -> Bool? {
		guard let checkScheme, let isRegistered, case .installing = phase else { return nil }
		let registered = isRegistered(checkScheme)
		if registered != lastRegistered {
			lastRegistered = registered
			note("install check: \(checkScheme) \(registered ? "answers" : "stopped answering")")
		}
		return registered
	}

	/// Fetches the manifest the way iOS will, so a broken endpoint shows up as
	/// a clear error instead of iOS's generic "Unable to install" alert.
	private func preflight(_ manifestURL: URL) async throws {
		let fetched: (Data, URLResponse)
		do {
			fetched = try await URLSession.shared.data(from: manifestURL)
		} catch {
			throw StartError.manifestUnreachable(error.localizedDescription)
		}
		let (data, response) = fetched
		let status = (response as? HTTPURLResponse)?.statusCode ?? -1
		guard status == 200 else {
			let message = String(data: data.prefix(200), encoding: .utf8) ?? ""
			throw StartError.manifestRejected(status: status, message: message)
		}
		let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
		guard let items = (plist as? [String: Any])?["items"] as? [Any], items.count == 1 else {
			throw StartError.manifestInvalid
		}
		note("manifest from \(manifestURL.host ?? "?"): HTTP 200, \(data.count) bytes")
	}

	private func payloadProgress(sent: Int64, total: Int64) {
		let tenth = total > 0 ? Int(sent * 10 / total) : 0
		let line = tenth != lastLoggedTenth ? "sent \(tenth * 10)%" : nil
		lastLoggedTenth = tenth
		update(line) { $0.payloadProgress(sent: sent, total: total, at: Date()) }
	}

	/// Logs iOS's progress when it appears, changes by a percent, or goes.
	private func logSystemProgress(_ fraction: Double?) {
		let percent = fraction.map { Int($0 * 100) }
		guard percent != lastSystemPercent else { return }
		lastSystemPercent = percent
		note(percent.map { "iOS progress \($0)%" } ?? "iOS progress gone")
	}

	private func update(_ line: String?, _ change: (inout RouteBTracker) -> Void) {
		guard var tracker, !tracker.phase.isFinished else {
			if let line { note(line) }
			return
		}
		let before = tracker.phase
		change(&tracker)
		self.tracker = tracker
		if let line { note(line, notify: false) }
		if tracker.phase == .alertClosed, before != .alertClosed {
			note("the iOS alert closed and iOS didn't ask for the app; waiting for Try again", notify: false)
		}
		if tracker.phase != phase || line != nil {
			phase = tracker.phase
			onChange?()
		}
	}

	private func note(_ line: String, notify: Bool = true) {
		log.append(String(format: "%6.1fs ", Date().timeIntervalSince(startedAt)) + line)
		if notify { onChange?() }
	}
}
#endif
