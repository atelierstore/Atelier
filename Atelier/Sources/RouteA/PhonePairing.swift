import BackgroundTasks
import Foundation
import IDevice
import InstallKit
import Network
import Observation
import UIKit

/// Pairs this iPhone with Atelier, with no computer (#9, iOS 27 and later).
///
/// iOS 27 lets the phone start a pairing with a host that advertises
/// `_remotepairing-pairable-host._tcp` on the local network. Atelier runs
/// that host itself (Packages/IDeviceBridge/src/pairing.rs, on idevice's
/// `PairableHost`) and advertises it through Bonjour, which needs only Local
/// Network access. The user picks "Atelier" under Settings › Privacy &
/// Security › Developer Mode and types the code Atelier shows; the pairing
/// file goes to `PairingFileStore`.
///
/// The install spike's host, which paired an iPhone on iOS 27.0.1 in
/// 42.7 s (spike/InstallSpike/Sources/OnPhonePairing.swift), without its
/// reconnect experiments. The steps and the code show in Atelier's own Live
/// Activity (PairingLiveActivity, #54), since the user types the code in
/// Settings, with silent audio keeping Atelier running meanwhile.
@MainActor
@Observable
final class PhonePairing: NSObject {
	static let shared = PhonePairing()

	/// Starts with the bundle ID and is listed in BGTaskSchedulerPermittedIdentifiers.
	static let taskIdentifier = "com.atelier.app.pairing"
	/// What the phone lists under Developer Mode.
	static let hostName = "Atelier"

	private static let serviceType = "_remotepairing-pairable-host._tcp"
	/// From the tap to a finished pairing.
	private static let attemptSeconds: UInt32 = 600
	/// For the advertisement to go live, including time to answer the Local
	/// Network alert.
	private static let readySeconds: TimeInterval = 60

	enum Status: Equatable {
		case idle
		/// Starting the host and advertising it; iOS may ask for Local Network access.
		case starting
		/// Advertised on the network: the user can go to Settings.
		case ready
		case enterCode(String)
		/// Paired with this phone ("name (model)").
		case paired(String)
		case failed(String)
	}

	private(set) var status: Status = .idle {
		didSet {
			if status != oldValue { PairingLiveActivity.shared.show(status, attemptSeconds: TimeInterval(Self.attemptSeconds)) }
		}
	}
	/// Lines for the pairing's log in Settings. Never keys or the code.
	private(set) var log: [String] = []
	/// Called on the main actor once a new pairing file is saved.
	@ObservationIgnored var onPaired: (@MainActor () -> Void)?

	var isActive: Bool {
		switch status {
		case .starting, .ready, .enterCode: true
		case .idle, .paired, .failed: false
		}
	}

	/// Whether this iOS can pair on the phone. Older ones need a pairing file
	/// made on a computer.
	static var isSupported: Bool {
		ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
	}

	@ObservationIgnored private var attempt = 0
	@ObservationIgnored private var session: OpaquePointer?
	@ObservationIgnored private var advertised: (instance: String, port: UInt16, txtRecord: Data)?
	@ObservationIgnored private var service: NetService?
	@ObservationIgnored private var browser: NWBrowser?
	@ObservationIgnored private var publishRetries = 0
	/// Why the attempt is being stopped, for the message once the host returns.
	@ObservationIgnored private var stopReason: String?
	/// The BGContinuedProcessingTask keeping Atelier running while the user is
	/// in Settings (iOS 26+), when Atelier's Live Activity and its silent audio
	/// can't (PairingLiveActivity). Held as AnyObject for the iOS 17 deployment
	/// target.
	@ObservationIgnored private var continuedTask: AnyObject?
	@ObservationIgnored private var progressText = "Starting"
	/// Ends the continued task once the user comes back after pairing.
	@ObservationIgnored private var returnObserver: NSObjectProtocol?

	/// The new pairing file, before it's checked and moved into the store.
	private static var incomingURL: URL {
		FileManager.default.temporaryDirectory.appending(path: "pairing-incoming.plist")
	}

	// MARK: Start and stop

	/// Must be called from a tap: iOS only grants the continued task for one.
	func start() {
		guard !isActive else { return }
		attempt += 1
		status = .starting
		log = []
		stopReason = nil
		publishRetries = 0
		note("starting")
		// The last pairing's "Return to Atelier" may still be showing.
		finishContinuedTask(success: true)
		// Setting the status started Atelier's Live Activity, and with it the
		// silent audio that keeps Atelier running; the continued task's bar
		// would fight it for the Dynamic Island, so it's only the fallback.
		if !PairingLiveActivity.shared.keepsAtelierRunning {
			requestContinuedTask()
		}
		runHost()
	}

	func cancel() {
		stop(because: nil)
	}

	/// Asks the host to stop; its result then arrives in `hostFinished`.
	private func stop(because reason: String?) {
		guard let session else { return }
		if stopReason == nil { stopReason = reason }
		atelier_pair_session_cancel(session)
	}

	private func runHost() {
		let session = atelier_pair_session_new()
		self.session = session
		let sessionBits = UInt(bitPattern: session)
		let outPath = Self.incomingURL.path
		try? FileManager.default.removeItem(atPath: outPath)
		// The host writes the file but doesn't create its folder, and iOS
		// can leave an app without its tmp folder: pairing then ended with
		// "No such file or directory (os error 2)" (22 Oct).
		try? FileManager.default.createDirectory(at: Self.incomingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let name = Self.hostName
		let seconds = Self.attemptSeconds
		DispatchQueue.global(qos: .userInitiated).async {
			let callbacks = AtelierPairCallbacks(ctx: nil, advertise: advertiseCallback, show_pin: showPinCallback, log: logCallback)
			var message: UnsafeMutablePointer<CChar>?
			let code = name.withCString { name in
				outPath.withCString { path in
					atelier_pair_session_run(OpaquePointer(bitPattern: sessionBits), name, path, seconds, callbacks, &message)
				}
			}
			let text = message.map { String(cString: $0) } ?? ""
			atelier_pair_string_free(message)
			DispatchQueue.main.async {
				MainActor.assumeIsolated { PhonePairing.shared.hostFinished(code: code, message: text) }
			}
		}
	}

	private func hostFinished(code: Int32, message: String) {
		atelier_pair_session_free(session)
		session = nil
		stopAdvertising()
		let reason = stopReason
		stopReason = nil
		switch code {
		case ATELIER_PAIR_PAIRED:
			do {
				let incoming = Self.incomingURL
				defer { try? FileManager.default.removeItem(at: incoming) }
				try PairingFileStore.standard().save(Data(contentsOf: incoming))
				// The host has already logged "paired with …".
				status = .paired(message)
				onPaired?()
				finishContinuedTaskPaired()
			} catch {
				note("paired, but the pairing file couldn't be saved: \(error)")
				status = .failed("Paired, but Atelier couldn't save the pairing. Try again.")
				finishContinuedTask(success: false)
			}
		case ATELIER_PAIR_CANCELLED:
			note("stopped" + (reason.map { ": \($0)" } ?? ""))
			status = reason.map(Status.failed) ?? .idle
			finishContinuedTask(success: false)
		case ATELIER_PAIR_TIMED_OUT:
			note("no phone paired within \(Self.attemptSeconds / 60) minutes")
			status = .failed("This \(ThisDevice.name) didn't pair within \(Self.attemptSeconds / 60) minutes. Tap Pair This \(ThisDevice.name) to try again.")
			finishContinuedTask(success: false)
		default:
			note("failed: \(message)")
			status = .failed(message.isEmpty ? "Pairing failed." : message.prefix(1).uppercased() + message.dropFirst())
			finishContinuedTask(success: false)
		}
	}

	func note(_ line: String) {
		log.append(line)
	}

	// MARK: Advertising (Bonjour)

	fileprivate func advertise(instance: String, port: UInt16, txtRecord: Data) {
		guard isActive else { return }
		advertised = (instance, port, txtRecord)
		publish()
		watchForService(named: instance)
	}

	private func publish() {
		guard let advertised else { return }
		service?.stop()
		let service = NetService(domain: "", type: Self.serviceType + ".", name: advertised.instance, port: Int32(advertised.port))
		service.delegate = self
		service.setTXTRecord(advertised.txtRecord)
		service.publish()
		self.service = service
		note("advertising on port \(advertised.port)")
	}

	fileprivate func publishFailed(_ error: String) {
		guard status == .starting else {
			if isActive { note("Bonjour reported the service as not published (\(error))") }
			return
		}
		publishRetries += 1
		note("Bonjour didn't publish the service (\(error)), retry \(publishRetries)")
		// iOS can refuse while its Local Network alert is still on screen
		// (TN3179), so keep trying; checkReady ends the attempt if it never works.
		let attempt = self.attempt
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			MainActor.assumeIsolated {
				let pairing = PhonePairing.shared
				guard pairing.attempt == attempt, pairing.status == .starting else { return }
				pairing.publish()
			}
		}
	}

	/// Browses for Atelier's own service as a second sign that it's live, so
	/// the user is only sent to Settings once the phone can find it. Browsing
	/// waits until Local Network access is granted.
	private func watchForService(named instance: String) {
		browser?.cancel()
		let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
		browser.browseResultsChangedHandler = { results, _ in
			let found = results.contains { result in
				if case let .service(name, _, _, _) = result.endpoint { return name == instance }
				return false
			}
			guard found else { return }
			DispatchQueue.main.async {
				MainActor.assumeIsolated { PhonePairing.shared.serviceReady(instance, how: "found by browsing") }
			}
		}
		browser.start(queue: .main)
		self.browser = browser

		let attempt = self.attempt
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.readySeconds) {
			MainActor.assumeIsolated { PhonePairing.shared.checkReady(attempt: attempt) }
		}
	}

	fileprivate func serviceReady(_ instance: String, how: String) {
		guard status == .starting, advertised?.instance == instance else { return }
		browser?.cancel()
		browser = nil
		note("the service is live (\(how))")
		status = .ready
		updateContinuedTask("Go to Settings › Developer Mode")
	}

	private func checkReady(attempt: Int) {
		guard attempt == self.attempt, status == .starting else { return }
		note("the service didn't go live within \(Int(Self.readySeconds)) s")
		stop(because: "Pairing couldn't start. Check that Wi-Fi is on and that Atelier may use the local network (Settings › Privacy & Security › Local Network), then try again.")
	}

	private func stopAdvertising() {
		service?.stop()
		service = nil
		browser?.cancel()
		browser = nil
		advertised = nil
	}

	// MARK: The code

	fileprivate func showCode(_ code: String) {
		guard isActive else { return }
		// The code isn't logged.
		note("this iPhone started pairing; code shown")
		status = .enterCode(code)
		updateContinuedTask("Code \(code)")
	}

	// MARK: Staying alive in Settings (iOS 26+)

	/// Call before launch finishes, like every BGTaskScheduler registration.
	static func registerBackgroundTask() {
		guard #available(iOS 26.0, *) else { return }
		BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
			MainActor.assumeIsolated { PhonePairing.shared.continuedTaskLaunched(task) }
		}
	}

	private func requestContinuedTask() {
		guard #available(iOS 26.0, *) else { return }
		let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: "Pairing this \(ThisDevice.name)", subtitle: progressText)
		// Fail rather than queue: a queued task could start after this attempt has ended.
		request.strategy = .fail
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			note("iOS refused the background task (\(error)); pairing still runs, but iOS may suspend Atelier while you're in Settings")
		}
	}

	private func continuedTaskLaunched(_ task: BGTask) {
		guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, isActive, continuedTask == nil else {
			task.setTaskCompleted(success: false)
			return
		}
		continuedTask = task
		task.expirationHandler = {
			DispatchQueue.main.async {
				MainActor.assumeIsolated { PhonePairing.shared.continuedTaskExpired() }
			}
		}
		task.progress.totalUnitCount = Int64(Self.attemptSeconds)
		updateContinuedTask(progressText)
		tickContinuedTask(attempt: attempt)
	}

	private func updateContinuedTask(_ text: String) {
		progressText = text
		guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
		task.updateTitle(task.title, subtitle: text)
	}

	/// iOS ends a continued task whose progress stands still for about 30 s
	/// (Apple DTS, developer forums thread 805554). Waiting for the user makes
	/// no progress of its own, so the bar counts the attempt's seconds.
	private func tickContinuedTask(attempt: Int) {
		guard #available(iOS 26.0, *), attempt == self.attempt, isActive, let task = continuedTask as? BGContinuedProcessingTask else { return }
		let progress = task.progress
		progress.completedUnitCount = min(progress.completedUnitCount + 1, progress.totalUnitCount - 1)
		DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
			MainActor.assumeIsolated { PhonePairing.shared.tickContinuedTask(attempt: attempt) }
		}
	}

	private func continuedTaskExpired() {
		if case .paired = status {
			finishContinuedTask(success: true)
			return
		}
		let inFront = UIApplication.shared.applicationState == .active
		note("background task ended by iOS or from its Live Activity")
		finishContinuedTask(success: false)
		// In front, Atelier keeps running anyway, so the attempt can go on.
		// iOS ending it and the user cancelling look the same; the log says both.
		if !inFront {
			stop(because: "Pairing cancelled. Tap Pair This \(ThisDevice.name) to try again.")
		}
	}

	/// Once paired, the Live Activity asks the user back to Atelier, and ends
	/// when they come back or after 20 s.
	private func finishContinuedTaskPaired() {
		guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
		guard UIApplication.shared.applicationState != .active else {
			finishContinuedTask(success: true)
			return
		}
		task.updateTitle("\(ThisDevice.name) paired", subtitle: "Return to Atelier")
		task.progress.completedUnitCount = task.progress.totalUnitCount
		returnObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { PhonePairing.shared.finishContinuedTask(success: true) }
		}
		let attempt = attempt
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
			MainActor.assumeIsolated {
				let shared = PhonePairing.shared
				if attempt == shared.attempt, !shared.isActive { shared.finishContinuedTask(success: true) }
			}
		}
	}

	private func finishContinuedTask(success: Bool) {
		progressText = "Starting"
		if let returnObserver {
			NotificationCenter.default.removeObserver(returnObserver)
			self.returnObserver = nil
		}
		guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
		continuedTask = nil
		if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
		task.setTaskCompleted(success: success)
	}
}

extension PhonePairing: NetServiceDelegate {
	nonisolated func netServiceDidPublish(_ sender: NetService) {
		let instance = sender.name
		DispatchQueue.main.async {
			MainActor.assumeIsolated { PhonePairing.shared.serviceReady(instance, how: "published") }
		}
	}

	nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
		let error = errorDict.description
		DispatchQueue.main.async {
			MainActor.assumeIsolated { PhonePairing.shared.publishFailed(error) }
		}
	}
}

// MARK: Callbacks from the Rust host, on its own thread

private func advertiseCallback(
	_ ctx: UnsafeMutableRawPointer?,
	_ instance: UnsafePointer<CChar>?,
	_ port: UInt16,
	_ txtRecord: UnsafePointer<UInt8>?,
	_ txtLength: UInt
) {
	guard let instance else { return }
	let name = String(cString: instance)
	let record = txtRecord.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
	DispatchQueue.main.async {
		MainActor.assumeIsolated { PhonePairing.shared.advertise(instance: name, port: port, txtRecord: record) }
	}
}

private func showPinCallback(_ ctx: UnsafeMutableRawPointer?, _ pin: UnsafePointer<CChar>?) {
	guard let pin else { return }
	let code = String(cString: pin)
	DispatchQueue.main.async {
		MainActor.assumeIsolated { PhonePairing.shared.showCode(code) }
	}
}

private func logCallback(_ ctx: UnsafeMutableRawPointer?, _ line: UnsafePointer<CChar>?) {
	guard let line else { return }
	let text = String(cString: line)
	DispatchQueue.main.async {
		MainActor.assumeIsolated { PhonePairing.shared.note(text) }
	}
}
