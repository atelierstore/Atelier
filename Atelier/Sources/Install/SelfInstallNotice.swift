import Foundation
import InstallKit
import UIKit
import UserNotifications

/// Says how Atelier's install of itself went while Atelier isn't running
/// (#24). iOS only installs over Atelier once it has closed, and doesn't
/// open it again afterwards, so Atelier leaves two things with iOS:
///
/// - A small download in a background session of its own, of `/relaunch`
///   next to the manifest endpoint (`infra/manifest-worker`), which answers
///   `relaunchDelay` seconds later. When it ends, iOS relaunches Atelier in
///   the background to hand over its events. If iOS installed it, that's
///   the build installed, which says "Updated to 0.2.0-alpha" in place of…
/// - …a notification `fallbackDelay` after closing that iOS should have
///   installed it by now, for when the relaunch doesn't come or isn't the
///   build installed.
///
/// iOS puts off a download an app starts while it's in the background, as
/// if `isDiscretionary` (Apple's URLSessionConfiguration documentation), and
/// one timed with `earliestBeginDate`: on the test iPhone, it hadn't started
/// one due 13 s after closing 47 s later (build 340, 28 Oct 2026). So the
/// download starts while Atelier is in front, once iOS has the build, and
/// again every `rearmInterval` until Atelier leaves the screen, the
/// endpoint holding back its answer; only the notification is timed again
/// as Atelier closes.
///
/// iOS keeps the download through the install, and relaunches the build
/// installed for it: 14 s after closing on the test iPhone, with the answer
/// due at 13 s (build 342, 28 Oct 2026). The attempt's log in Install
/// History says what Atelier left with iOS as it closed, whether and when
/// the relaunch came, and what iOS still had once Atelier was in front
/// again. Both are taken back then, as the install bar says how it went.
@MainActor
final class SelfInstallNotice {
	static let shared = SelfInstallNotice()

	/// Its background session, apart from the downloads'.
	nonisolated static let sessionIdentifier = "com.atelier.app.relaunch"
	/// Starts with `BackgroundInstalls.notificationPrefix`, so tapping it
	/// opens the Library.
	nonisolated static let notificationID = "installs.self"
	/// Marks a download Atelier replaced or took back, whose end isn't news.
	nonisolated fileprivate static let cancelledHere = "cancelled by Atelier"
	/// How long the endpoint is asked to hold back its answer to the
	/// download: iOS installs Atelier within a few seconds of it closing.
	private static let relaunchDelay = 15
	/// While Atelier is in front, so the answer comes 10 to 15 s after it
	/// leaves the screen.
	private static let rearmInterval = Duration.seconds(5)
	/// After Atelier closes, which leaves the relaunch time to replace it.
	private static let fallbackDelay: TimeInterval = 30
	/// Set while the download may be waiting with iOS.
	private static let scheduledKey = "selfInstallRelaunchScheduled"

	private var session: URLSession?
	/// iOS's handler for the relaunch, called once the session's events are in.
	private var eventsCompletion: (() -> Void)?
	/// Says in the relaunch that iOS installed it, which iOS waits for.
	private var notifying: Task<Void, Never>?
	/// From when iOS has the build until Atelier closes, or its install ends
	/// while it runs: Atelier in front again meanwhile keeps what it left.
	private var handedOver = false
	/// Starts the download again while Atelier is in front.
	private var rearming: Task<Void, Never>?
	/// When each download started, by task, to tell an endpoint that answers
	/// at once.
	private var started: [Int: Date] = [:]
	/// Why Atelier leaves no download with iOS, once it found out in front.
	private var noRelaunch: String?
	/// Closes Atelier once iOS has what it leaves (see `leaveAsItCloses`).
	private var closing: (([String]) -> Void)?
	/// The install Atelier closed for, once it launched after it.
	private var closedFor: PendingSelfInstall?
	/// The same, until Atelier is in front and its log says what iOS still
	/// had.
	private var toLookBack: PendingSelfInstall?

	private init() {}

	/// iOS has the build, and installs it once Atelier closes: leaves the
	/// download and the notification with iOS, in case iOS closes Atelier
	/// before it leaves the screen. The download starts again every
	/// `rearmInterval` while Atelier is in front.
	func leave(for pending: PendingSelfInstall, appName: String) {
		handedOver = true
		closedFor = nil
		toLookBack = nil
		noRelaunch = nil
		rearming?.cancel()
		rearming = Task {
			while !Task.isCancelled, noRelaunch == nil {
				await startRelaunch()
				try? await Task.sleep(for: Self.rearmInterval)
			}
		}
		let request = Self.fallback(for: pending, appName: appName)
		// The same identifier replaces the one left before.
		Task { try? await UNUserNotificationCenter.current().add(request) }
	}

	/// Atelier closes for iOS to install it: the notification is timed
	/// again from now, and the download stays as it last started in front.
	/// Then `close`, with what Atelier left with iOS, for the attempt's log:
	/// once iOS has answered, or after 2 s.
	func leaveAsItCloses(for pending: PendingSelfInstall, appName: String, then close: @escaping ([String]) -> Void) {
		// Closing right as iOS has the build, nothing was left in front.
		if !handedOver { noRelaunch = nil }
		handedOver = true
		closedFor = nil
		toLookBack = nil
		rearming?.cancel()
		rearming = nil
		closing = close
		Task {
			let left = await leaveWithIOS(pending, appName: appName)
			closeNow(left)
		}
		// iOS answers within moments, and closing doesn't wait long for it.
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
			MainActor.assumeIsolated { SelfInstallNotice.shared.closeNow(["closed before iOS answered what it has"]) }
		}
	}

	private func closeNow(_ left: [String]) {
		guard let closing else { return }
		self.closing = nil
		closing(left)
	}

	/// Leaves the notification and the download with iOS as Atelier closes,
	/// and says what it left.
	private func leaveWithIOS(_ pending: PendingSelfInstall, appName: String) async -> [String] {
		let center = UNUserNotificationCenter.current()
		let settings = await center.notificationSettings()
		var left = [
			Self.describe(settings),
			Self.describe(UIApplication.shared.backgroundRefreshStatus, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled),
		]
		do {
			// The same identifier replaces the one left before.
			try await center.add(Self.fallback(for: pending, appName: appName))
			left.append("notification: due \(Int(Self.fallbackDelay)) s after closing")
		} catch {
			left.append("notification: not left with iOS: \(error.localizedDescription)")
		}
		// One started now would be put off, and could come any time.
		let waiting = Self.waiting(await relaunchSession().allTasks)
		if let latest = waiting.compactMap({ started[$0.taskIdentifier] }).max() {
			let due = latest.addingTimeInterval(TimeInterval(Self.relaunchDelay))
			left.append("relaunch download: answer due \(Self.seconds(from: .now, to: due)) s after closing")
		} else {
			left.append("relaunch download: none" + (noRelaunch.map { ", as \($0)" } ?? ""))
		}
		return left
	}

	/// Starts the download, which the endpoint answers `relaunchDelay`
	/// seconds later, in place of any started before. Only in front: one
	/// started there stays, rather than be replaced as Atelier leaves the
	/// screen by one iOS would put off.
	private func startRelaunch() async {
		guard let url = Self.relaunchURL() else {
			noRelaunch = "the manifest endpoint in Settings isn't usable"
			return
		}
		let session = relaunchSession()
		let older = await session.allTasks
		guard !Task.isCancelled, noRelaunch == nil else { return }
		// Inactive may already be on the way to the background, so only the
		// first starts then.
		let state = UIApplication.shared.applicationState
		guard state == .active || (state == .inactive && Self.waiting(older).isEmpty) else { return }
		UserDefaults.standard.set(true, forKey: Self.scheduledKey)
		let task = session.downloadTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
		task.countOfBytesClientExpectsToSend = 512
		task.countOfBytesClientExpectsToReceive = 1024
		task.resume()
		started[task.taskIdentifier] = .now
		// Once the new one is under way.
		for task in older { cancel(task) }
	}

	/// iOS relaunched Atelier for the download's events. If it's the build
	/// iOS was to install, it says so in place of the notification left
	/// before closing. Either way, the attempt's log says the relaunch came.
	func relaunched(completion: @escaping () -> Void) {
		eventsCompletion = completion
		// Takes the events, then calls `completion`.
		_ = relaunchSession()
		UserDefaults.standard.removeObject(forKey: Self.scheduledKey)
		let own = SelfUpdate.shared
		// The note, or what Atelier took from it if its views came up first.
		guard let pending = (try? PendingSelfInstallStore.standard())?.load() ?? closedFor else { return }
		let outcome = pending.outcome(runningToken: own.runningToken, version: own.version, build: own.build)
		let relaunch = "relaunched in the background \(Self.seconds(from: pending.attempt.finishedAt, to: .now)) s after closing, as"
		// In front, the install bar says it.
		guard outcome == .installed, UIApplication.shared.applicationState != .active else {
			let found = switch outcome {
			case .installed: "the build installed, in front"
			case .notInstalled: "the build that was running: left the notification from before closing"
			case .superseded: "another build: left the notification from before closing"
			}
			note(["\(relaunch) \(found)"], for: pending.attempt.id)
			return
		}
		let notice = pending.installedNotification(appName: own.name)
		let content = UNMutableNotificationContent()
		content.title = notice.title
		content.body = notice.body
		content.sound = .default
		notifying = Task {
			let center = UNUserNotificationCenter.current()
			// The one left before closing goes first: on the test iPhone, it was
			// still waiting with iOS 24 s after closing, after the relaunch
			// at 14 s (build 342, 28 Oct 2026), to come after this one.
			center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
			do {
				// Comes now, in place of the one left before closing if that came.
				try await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
				note(["\(relaunch) the build installed: said so in a notification"], for: pending.attempt.id)
			} catch {
				note(["\(relaunch) the build installed, but couldn't say so in a notification: \(error.localizedDescription)"], for: pending.attempt.id)
			}
		}
	}

	/// The session's events are in: iOS can suspend Atelier again once it
	/// has the notification.
	private func eventsFinished() {
		let completion = eventsCompletion
		eventsCompletion = nil
		Task {
			await notifying?.value
			notifying = nil
			completion?()
		}
	}

	/// A download ended. While Atelier waits to close for its install, that
	/// can only be the endpoint answering at once, before the download was
	/// replaced: one left with iOS would relaunch Atelier before iOS
	/// installs it, so none is. Otherwise it ended while Atelier wasn't
	/// running, and iOS didn't relaunch Atelier for it: its events come once
	/// Atelier makes the session again.
	fileprivate func downloadEnded(task id: Int, status: Int?, servedAt: Date?, failure: String?) {
		let startedAt = started.removeValue(forKey: id)
		if handedOver {
			guard let startedAt, Date.now.timeIntervalSince(startedAt) < TimeInterval(Self.relaunchDelay - 3) else { return }
			let after = Self.seconds(from: startedAt, to: .now)
			let host = Self.relaunchURL()?.host ?? "the endpoint"
			noRelaunch = if let failure {
				"the download from \(host) failed after \(after) s: \(failure)"
			} else {
				"\(host) answered after \(after) s, not \(Self.relaunchDelay) s" + (status.map { " (HTTP \($0))" } ?? "")
			}
			rearming?.cancel()
			rearming = nil
			return
		}
		// In a relaunch for it, `relaunched` says it came.
		guard eventsCompletion == nil, let pending = closedFor else { return }
		let when = servedAt.map { " \(Self.seconds(from: pending.attempt.finishedAt, to: $0)) s after closing" } ?? ""
		let line = if let failure {
			"relaunch download: failed\(when): \(failure)"
		} else {
			"relaunch download: done\(when), but iOS didn't relaunch \(SelfUpdate.shared.name) for it"
		}
		note([line], for: pending.attempt.id)
	}

	/// Atelier launched after closing for this install, and took its note
	/// for Install History: once Atelier is in front, the attempt's log says
	/// what iOS still had.
	func launched(after pending: PendingSelfInstall) {
		closedFor = pending
		toLookBack = pending
	}

	/// Atelier's own install ended while it runs: iOS didn't take it, or it
	/// was cancelled before iOS had it. The install bar says how it went, so
	/// what was left with iOS goes.
	func installEnded() {
		handedOver = false
		rearming?.cancel()
		rearming = nil
		withdraw()
	}

	/// Atelier is in front, where the install bar says how its own install
	/// went, so what was left with iOS goes: the first time after closing
	/// for it, once the attempt's log says what iOS still had.
	func withdraw() {
		// In front again while it waits to close for its install, after
		// iOS's install alert or Control Center, it keeps them.
		guard !handedOver else { return }
		let pending = toLookBack
		toLookBack = nil
		let scheduled = UserDefaults.standard.bool(forKey: Self.scheduledKey)
		UserDefaults.standard.removeObject(forKey: Self.scheduledKey)
		Task {
			var found: [String] = []
			if let pending { found = await lookBack(after: pending) }
			let center = UNUserNotificationCenter.current()
			center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
			center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
			if scheduled || pending != nil {
				for task in await relaunchSession().allTasks { cancel(task) }
			}
			if let pending { note(found, for: pending.attempt.id) }
		}
	}

	/// What iOS still had of what Atelier left with it as it closed for
	/// `pending`, now that Atelier is in front.
	private func lookBack(after pending: PendingSelfInstall) async -> [String] {
		let closedAt = pending.attempt.finishedAt
		var found = ["opened \(Self.seconds(from: closedAt, to: .now)) s after closing"]
		let center = UNUserNotificationCenter.current()
		if let shown = await center.deliveredNotifications().first(where: { $0.request.identifier == Self.notificationID }) {
			found.append("notification: came \(Self.seconds(from: closedAt, to: shown.date)) s after closing: \(shown.request.content.title)")
		} else if await center.pendingNotificationRequests().contains(where: { $0.identifier == Self.notificationID }) {
			found.append("notification: not come yet, still waiting with iOS")
		} else {
			found.append("notification: none left: it was tapped or cleared, or iOS dropped it")
		}
		let waiting = Self.waiting(await relaunchSession().allTasks)
		found.append(waiting.isEmpty ? "relaunch download: none left with iOS" : "relaunch download: still waiting with iOS")
		return found
	}

	/// Adds to the attempt's log: in its note until Atelier takes that for
	/// Install History, then there, and in the install bar while it says how
	/// the install went.
	private func note(_ lines: [String], for id: UUID) {
		if let store = try? PendingSelfInstallStore.standard(), var noted = store.load(), noted.attempt.id == id {
			noted.attempt.log += lines
			try? store.save(noted)
		} else {
			try? InstallHistory.standard().update(id) { $0.log += lines }
			InstallModel.shared.selfInstallLogged(lines, for: id)
		}
	}

	/// Made once, before the first task or as iOS relaunches Atelier, so
	/// it gets the events of a download that ended meanwhile.
	private func relaunchSession() -> URLSession {
		if let session { return session }
		let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
		// Started by Atelier's install, so iOS shouldn't hold it back.
		configuration.isDiscretionary = false
		configuration.sessionSendsLaunchEvents = true
		let delegate = RelaunchDelegate()
		delegate.eventsFinished = {
			DispatchQueue.main.async {
				MainActor.assumeIsolated { SelfInstallNotice.shared.eventsFinished() }
			}
		}
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		self.session = session
		return session
	}

	/// `/relaunch` next to the manifest endpoint in Settings, answered
	/// `relaunchDelay` seconds later; nil when that endpoint isn't usable.
	private static func relaunchURL() -> URL? {
		guard case .success(let endpoint) = ManifestEndpoint.resolve(UserDefaults.standard.string(forKey: InstallModel.endpointKey) ?? "") else { return nil }
		return ManifestEndpoint.relaunchURL(for: endpoint, delay: relaunchDelay)
	}

	/// The downloads iOS hasn't finished.
	private static func waiting(_ tasks: [URLSessionTask]) -> [URLSessionTask] {
		tasks.filter { $0.state == .running || $0.state == .suspended }
	}

	/// Cancels a download Atelier replaced or took back: its end isn't news.
	private func cancel(_ task: URLSessionTask) {
		started[task.taskIdentifier] = nil
		task.taskDescription = Self.cancelledHere
		task.cancel()
	}

	/// The notification `fallbackDelay` from now that iOS should have
	/// installed it by now.
	private static func fallback(for pending: PendingSelfInstall, appName: String) -> UNNotificationRequest {
		let notice = pending.expectedNotification(appName: appName)
		let content = UNMutableNotificationContent()
		content.title = notice.title
		content.body = notice.body
		content.sound = .default
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fallbackDelay, repeats: false)
		return UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
	}

	/// Whole seconds from one to the other, for the log.
	private static func seconds(from start: Date, to end: Date) -> Int {
		Int(end.timeIntervalSince(start).rounded())
	}

	/// "notifications: allowed, as banners"
	private static func describe(_ settings: UNNotificationSettings) -> String {
		let allowed: String
		switch settings.authorizationStatus {
		case .authorized, .ephemeral:
			switch settings.alertStyle {
			case .banner: allowed = "allowed, as banners"
			case .alert: allowed = "allowed, as alerts"
			default: allowed = "allowed, without banners"
			}
		case .provisional: allowed = "delivered quietly, to Notification Center only"
		case .denied: return "notifications: not allowed"
		case .notDetermined: return "notifications: not asked for yet, so none shows"
		@unknown default: return "notifications: unknown setting"
		}
		// iOS holds them for the summary.
		let summary = settings.scheduledDeliverySetting == .enabled ? ", in the Scheduled Summary" : ""
		return "notifications: \(allowed)\(summary)"
	}

	/// "background app refresh: on"
	private static func describe(_ refresh: UIBackgroundRefreshStatus, lowPower: Bool) -> String {
		let status = switch refresh {
		case .available: "on"
		case .denied: "off"
		case .restricted: "restricted"
		@unknown default: "unknown"
		}
		return "background app refresh: \(status)" + (lowPower ? ", Low Power Mode on" : "")
	}
}

/// Takes the relaunch download's events: the file itself isn't needed.
private final class RelaunchDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	/// Set once, before the session is made.
	var eventsFinished: (@Sendable () -> Void)?

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		// Replaced or taken back by Atelier itself.
		guard task.taskDescription != SelfInstallNotice.cancelledHere else { return }
		let id = task.taskIdentifier
		let response = task.response as? HTTPURLResponse
		let status = response?.statusCode
		let servedAt = response?.value(forHTTPHeaderField: "Date").flatMap(Self.date(served:))
		let failure = (error as NSError?).map { error in
			// Why iOS cancelled it, when it did.
			let reason = (error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int).map { ", reason \($0)" } ?? ""
			return "\(error.localizedDescription) (\(error.domain) \(error.code)\(reason))"
		}
		DispatchQueue.main.async {
			MainActor.assumeIsolated { SelfInstallNotice.shared.downloadEnded(task: id, status: status, servedAt: servedAt, failure: failure) }
		}
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		eventsFinished?()
	}

	/// An HTTP Date header: "Tue, 27 Oct 2026 22:58:40 GMT".
	private static func date(served: String) -> Date? {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
		return formatter.date(from: served)
	}
}
