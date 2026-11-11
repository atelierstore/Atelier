import BackgroundTasks
import InstallKit
import AtelierCore
import UIKit
import UserNotifications

/// Keeps direct installs (route A) going after the user leaves Atelier
/// (#72). They need no alert, so on iOS 26 and later a
/// `BGContinuedProcessingTask` carries the whole queue, Update All included,
/// with its progress in the system's bar on the Lock Screen and in the
/// Dynamic Island, and a stop button there. When the last install ends, the
/// bar says how it went for a moment before it closes, and with Atelier in
/// the background a notification follows once the bar is gone. iOS can end
/// the bar first, as it did on the locked test iPhone, and would then stop
/// Atelier soon after, so silent audio (`SilentAudio`, as pairing uses)
/// keeps Atelier running for the rest of the round. If it stops anyway,
/// "Updates paused" says what's left.
///
/// The spike's continued task finished a 125.7 MB install 43.1 s after the maintainer
/// left the app. iOS ends one whose progress stands still for about 30 s, so
/// the progress creeps along while a step has none of its own.
///
/// Installs with iOS's alert (route B) don't get it: the alert needs the
/// user in Atelier. They keep the short background time `InstallModel`
/// asks for.
@MainActor
final class BackgroundInstalls {
	static let shared = BackgroundInstalls()

	/// Starts with the bundle ID and is listed in BGTaskSchedulerPermittedIdentifiers.
	static let taskIdentifier = "com.atelier.app.installs"
	/// The prefix of the notifications' identifiers; tapping one opens the Library.
	static let notificationPrefix = "installs."

	/// The app's one install model, which sets itself here.
	weak var model: InstallModel?

	private var round = BackgroundRound()
	/// The running BGContinuedProcessingTask, held as AnyObject so this type
	/// builds for the iOS 17 deployment target.
	private var continuedTask: AnyObject?
	/// Asked for and not started or refused yet.
	private var requested = false
	/// Counts the requests, so a late check matches its own.
	private var requestNumber = 0
	/// The last progress shown, and when it last moved.
	private var shown: (completed: Int64, at: Date) = (0, .distantPast)
	private var heartbeat: Timer?
	/// The install that went to iOS's alert after all, as Automatic does
	/// when direct installs can't run: no bar for it.
	private var promptedID: String?

	/// iOS didn't start the bar for this round.
	private var refused = false
	/// What became of the bar while no install was running, for the next
	/// install's log.
	private var pendingNotes: [String] = []

	/// How long the bar shows how the round went before it closes, so iOS
	/// draws the result on the Lock Screen and in the Dynamic Island first.
	private static let resultLinger: TimeInterval = 2
	/// How much later the notification comes: iOS shows the bar's own end
	/// for a moment, and the two shouldn't show at once.
	private static let notificationDelay: TimeInterval = 4
	/// The bar is showing how the last round went, and closes after
	/// `resultLinger` unless another round takes it over.
	private var showingResult = false
	/// Counts the results shown, so a late close matches its own.
	private var resultNumber = 0
	/// The notification waiting for the bar to be gone, taken back if
	/// Atelier comes to the front first: the Library says the same.
	private var waitingNotification: String?
	/// How long after Atelier last ran, once iOS has ended the bar with
	/// installs left, "Updates paused" comes: iOS pauses Atelier soon
	/// after, and the rest waits until it's opened (#72).
	private static let pausedDelay: TimeInterval = 15
	private static let pausedIdentifier = notificationPrefix + "paused"
	/// Puts "Updates paused" off again while Atelier still runs.
	private var pausedTimer: Timer?
	/// Whether this round holds the silent audio, and whether it wouldn't
	/// start, so it isn't tried again until the next round.
	private var holdsAudio = false
	private var audioRefused = false

	/// Whether the system's bar is showing these installs, or about to.
	var isShowing: Bool { continuedTask != nil || requested }

	/// Whether the downloads' own bar should give way: this round's bar
	/// covers its downloads, and also while it's being asked for again. The
	/// downloads' bar alone ends with the downloads, while the installs
	/// still need Atelier running.
	var coversDownloads: Bool {
		isShowing || (!round.isEmpty && !refused && promptedID == nil && mayInstallDirectly)
	}

	/// Call before launch finishes, like every BGTaskScheduler registration.
	static func register() {
		guard #available(iOS 26.0, *) else { return }
		BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
			MainActor.assumeIsolated { BackgroundInstalls.shared.launched(task) }
		}
	}

	/// Whether the next install may go through route A, judged before the
	/// route is picked: the setup is finished.
	var mayInstallDirectly: Bool {
		RouteASetup.shared.isSetUp
	}

	// MARK: What the install model reports

	func queued(id: String, name: String, version: String? = nil, isUpdate: Bool, isResign: Bool = false, automatic: Bool) {
		round.add(id: id, name: name, isUpdate: isUpdate, isResign: isResign, version: version)
		if automatic { round.isAutomatic = true }
		if mayInstallDirectly {
			// Asked once, while Atelier is in front, for the notification at the end.
			Task { await CertificateNotifications.requestAuthorization() }
		}
		update()
	}

	func removed(id: String) {
		round.remove(id: id)
		update()
	}

	/// The running install gave way to another, which takes its place (#99).
	func replaced(id: String) {
		round.drop(id: id)
		update()
	}

	func started(id: String) {
		round.start(id: id)
		for line in pendingNotes { model?.note(line) }
		pendingNotes = []
		update()
	}

	/// A line for the running install's log, or the next one's.
	private func say(_ line: String) {
		if round.currentID != nil, let model {
			model.note(line)
		} else {
			pendingNotes.append(line)
		}
	}

	func ended(id: String, _ outcome: BackgroundRound.Outcome) {
		round.end(id: id, outcome)
		if pausedTimer != nil { holdPaused() }
		update()
	}

	/// The queue is empty: the bar, which the last install's end left on
	/// how the round went, closes a moment later, and if Atelier isn't in
	/// front the notification follows once it's gone. Both ending at once put
	/// two cards on the Lock Screen that didn't agree, the bar's last line
	/// being "Starting" (#72).
	func roundOver() {
		dropPaused()
		stopRunning()
		let lingers = finish(success: true, showingResult: true)
		if UIApplication.shared.applicationState != .active, let summary = round.summary {
			notify(summary, after: lingers ? Self.resultLinger + Self.notificationDelay : nil)
		}
		round = BackgroundRound()
		promptedID = nil
		refused = false
		pendingNotes = []
		BackgroundDownloads.shared.update()
	}

	/// Follows the running install: asks for the system's bar while Atelier
	/// is in front and a direct install may run, and keeps it current.
	func update() {
		guard #available(iOS 26.0, *), !round.isEmpty else { return }
		// Route B's alert: the user is in Atelier and the bar would stand still.
		if case .installing(_, .waitingForApproval)? = model?.state {
			promptedID = round.currentID
		}
		if let promptedID, promptedID == round.currentID {
			if isShowing { say("background: the system's progress bar ended, as iOS's install alert needs Atelier in front") }
			finish(success: true)
			return
		}
		if mayInstallDirectly { keepRunning() }
		if let task = continuedTask as? BGContinuedProcessingTask {
			if showingResult {
				// Queued while the bar showed how the last round went: this
				// round carries on in it.
				showingResult = false
				shown = (0, .now)
				startHeartbeat()
			}
			show(on: task)
		} else if !requested, !refused, mayInstallDirectly, UIApplication.shared.applicationState == .active {
			request()
		}
	}

	/// Atelier is in front again: the bar can be asked for again, even if
	/// iOS didn't start it before.
	func becameActive() {
		refused = false
		audioRefused = false
		dropPaused()
		// The Library says how the round went.
		if let waitingNotification {
			UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [waitingNotification])
			self.waitingNotification = nil
		}
		update()
	}

	// MARK: The continued task

	@available(iOS 26.0, *)
	private func request() {
		let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: round.title, subtitle: subtitle)
		// Only start now: a queued task could start after the installs end.
		request.strategy = .fail
		// The downloads' bar gives way to this one first.
		requested = true
		BackgroundDownloads.shared.update()
		do {
			try BGTaskScheduler.shared.submit(request)
			// It starts at once or not at all, as asked. If iOS took it and
			// hasn't started it, the downloads' bar shouldn't wait on it.
			requestNumber += 1
			let number = requestNumber
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				MainActor.assumeIsolated { BackgroundInstalls.shared.checkStarted(number) }
			}
		} catch {
			// The installs carry on with the short background time, and the
			// downloads' bar can show again.
			requested = false
			refused = true
			say("background: iOS didn't start the system's progress bar: \(error.localizedDescription)")
			BackgroundDownloads.shared.update()
		}
	}

	private func checkStarted(_ number: Int) {
		guard number == requestNumber, requested, continuedTask == nil else { return }
		requested = false
		refused = true
		say("background: iOS took the request for the system's progress bar but didn't start it")
		BackgroundDownloads.shared.update()
	}

	private func launched(_ task: BGTask) {
		requested = false
		guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, !round.isEmpty, continuedTask == nil else {
			say("background: the system's progress bar started after the installs had ended, so it was closed")
			task.setTaskCompleted(success: false)
			BackgroundDownloads.shared.update()
			return
		}
		continuedTask = task
		shown = (0, .now)
		dropPaused()
		say("background: the system's progress bar started (new files: \(Self.newFileProtection))")
		task.expirationHandler = {
			DispatchQueue.main.async {
				MainActor.assumeIsolated { BackgroundInstalls.shared.expired() }
			}
		}
		show(on: task)
		startHeartbeat()
	}

	@available(iOS 26.0, *)
	private func show(on task: BGContinuedProcessingTask) {
		var progress = round.progress(stage: model?.state)
		if progress.completed > shown.completed {
			shown = (progress.completed, .now)
		} else {
			// A step with no progress of its own, such as signing or
			// connecting: creep along within the app's share, so iOS doesn't
			// take the stillness for a stuck task.
			let appEnd = progress.completed - progress.completed % 1000 + 999
			if Date.now.timeIntervalSince(shown.at) >= 10, shown.completed + 1 < appEnd {
				shown = (shown.completed + 1, .now)
			}
			progress.completed = shown.completed
		}
		// The lines first, so a full bar never shows with the last ones.
		task.updateTitle(round.title, subtitle: subtitle)
		task.progress.totalUnitCount = progress.total
		task.progress.completedUnitCount = min(progress.completed, progress.total)
	}

	private func startHeartbeat() {
		heartbeat?.invalidate()
		heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
			MainActor.assumeIsolated { BackgroundInstalls.shared.update() }
		}
	}

	/// The user stopped it from the system's bar, or iOS ended it. The
	/// queue isn't cancelled: Cancel All in the Library does that.
	private func expired() {
		let still = Int(Date.now.timeIntervalSince(shown.at))
		let state = UIApplication.shared.applicationState == .active ? "in front" : "in the background"
		let locked = UIApplication.shared.isProtectedDataAvailable ? "unlocked" : "locked"
		let audio = SilentAudio.shared.isPlaying ? "playing" : "stopped"
		say("background: iOS ended the system's progress bar, or it was stopped (Atelier \(state), iPhone \(locked), bar last moved \(still) s ago at \(shown.completed) of \(round.progress(stage: model?.state).total), silent audio \(audio))")
		heartbeat?.invalidate()
		heartbeat = nil
		if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
			// Closed as done, so iOS takes the bar away: closed as failed, iOS
			// left "Task failed" on the Lock Screen until it was swiped away,
			// even once the installs had gone through (#72).
			task.setTaskCompleted(success: true)
		}
		continuedTask = nil
		showingResult = false
		// The queue isn't cancelled: the installs go on while Atelier runs,
		// which the silent audio sees to, and carry on when it's back in
		// front, which asks for the bar again. If Atelier stops before then,
		// "Updates paused" says they're waiting.
		if UIApplication.shared.applicationState != .active { holdPaused() }
	}

	/// Keeps Atelier running for the rest of the round, even once iOS has
	/// ended the bar, which it can do early and then stop Atelier soon after
	/// (25 Oct 2026). The silence can only start while Atelier is in front.
	private func keepRunning() {
		guard !audioRefused, !(holdsAudio && SilentAudio.shared.isPlaying), UIApplication.shared.applicationState == .active else { return }
		do {
			try SilentAudio.shared.start(for: .installs)
			holdsAudio = true
		} catch {
			audioRefused = true
			say("background: silent audio didn't start (\(error.localizedDescription)), so Atelier runs only as long as the system's progress bar")
		}
	}

	private func stopRunning() {
		audioRefused = false
		guard holdsAudio else { return }
		holdsAudio = false
		SilentAudio.shared.stop(for: .installs)
	}

	/// Puts "Updates paused" off by `pausedDelay` again, with what's done
	/// and what's left, so it only comes once iOS has stopped Atelier
	/// running: a timer can't fire then. iOS holds it meanwhile.
	private func holdPaused() {
		guard let summary = round.paused else {
			dropPaused()
			return
		}
		let content = UNMutableNotificationContent()
		content.title = summary.title
		content.body = summary.body
		content.sound = .default
		// The same identifier replaces the one waiting.
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.pausedDelay, repeats: false)
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.pausedIdentifier, content: content, trigger: trigger))
		guard pausedTimer == nil else { return }
		pausedTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
			MainActor.assumeIsolated { BackgroundInstalls.shared.holdPaused() }
		}
	}

	/// The round is over, Atelier is in front or the bar is back: "Updates
	/// paused" isn't needed, or is no longer true if it came.
	private func dropPaused() {
		guard let timer = pausedTimer else { return }
		timer.invalidate()
		pausedTimer = nil
		let center = UNUserNotificationCenter.current()
		center.removePendingNotificationRequests(withIdentifiers: [Self.pausedIdentifier])
		Task {
			let came = await center.deliveredNotifications().contains { $0.request.identifier == Self.pausedIdentifier }
			center.removeDeliveredNotifications(withIdentifiers: [Self.pausedIdentifier])
			// In the log of the install it came during.
			if came, round.currentID != nil { say("background: iOS stopped Atelier with installs left, and the notification saying so came") }
		}
	}

	/// Ends the bar. With `showingResult`, it stays as it is for
	/// `resultLinger` first; returns whether it does.
	@discardableResult
	private func finish(success: Bool, showingResult: Bool = false) -> Bool {
		requested = false
		heartbeat?.invalidate()
		heartbeat = nil
		guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return false }
		if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
		if showingResult {
			self.showingResult = true
			resultNumber += 1
			let number = resultNumber
			DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultLinger) {
				MainActor.assumeIsolated { BackgroundInstalls.shared.resultShown(number) }
			}
			return true
		}
		self.showingResult = false
		continuedTask = nil
		task.setTaskCompleted(success: success)
		return false
	}

	private func resultShown(_ number: Int) {
		guard number == resultNumber, showingResult else { return }
		finish(success: true)
		// A download the bar was covering gets its own.
		BackgroundDownloads.shared.update()
	}

	private var subtitle: String {
		round.subtitle(stage: model?.state, bytes: model?.stageBytes)
	}

	/// The protection a new file gets, which the signing profile's
	/// entitlements decide: with "complete", nothing Atelier writes, such
	/// as a download or a signed app, can be read while the iPhone is locked.
	private static var newFileProtection: String {
		let manager = FileManager.default
		let url = manager.temporaryDirectory.appending(path: "protection-\(UUID().uuidString)")
		guard manager.createFile(atPath: url.path, contents: Data()) else { return "unknown" }
		defer { try? manager.removeItem(at: url) }
		switch (try? manager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType {
		case .complete?: return "complete"
		case .completeUnlessOpen?: return "complete unless open"
		case .completeUntilFirstUserAuthentication?: return "after first unlock"
		case FileProtectionType.none?: return "none"
		default: return "unknown"
		}
	}

	/// Sends the notification now, or after `delay` while the bar ends.
	/// iOS holds a delayed one, so it comes even if Atelier is suspended
	/// once the bar has closed.
	private func notify(_ summary: BackgroundRound.Summary, after delay: TimeInterval?) {
		let content = UNMutableNotificationContent()
		content.title = summary.title
		content.body = summary.body
		content.sound = .default
		let identifier = Self.notificationPrefix + UUID().uuidString
		let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
		waitingNotification = delay == nil ? nil : identifier
	}
}
