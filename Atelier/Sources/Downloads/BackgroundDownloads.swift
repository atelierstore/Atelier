import BackgroundTasks
import CertKit
import DownloadKit
import UIKit
import UserNotifications

/// The app's download manager (#15), and what ties it to iOS:
///
/// - The manager's background session keeps downloading while Atelier is
///   suspended or killed by iOS. When downloads finish then, iOS relaunches
///   Atelier in the background and hands it the session's events
///   (`AppDelegate`).
/// - On iOS 26 and later, a `BGContinuedProcessingTask` shows the downloads'
///   progress in the system UI while Atelier is in the background, the way
///   Feather does. It can only be asked for while Atelier is in front.
@MainActor
final class BackgroundDownloads {
	static let shared = BackgroundDownloads()

	/// Starts with the bundle ID and is listed in BGTaskSchedulerPermittedIdentifiers.
	static let taskIdentifier = "com.atelier.app.downloads"

	let manager: DownloadManager

	/// The running BGContinuedProcessingTask, held as AnyObject so this type
	/// builds for the iOS 17 deployment target.
	private var continuedTask: AnyObject?
	/// Asked for and not started or refused yet.
	private var requested = false

	private init() {
		let store = (try? DownloadStore.standard())
			?? DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "Downloads", directoryHint: .isDirectory))
		manager = DownloadManager(store: store)
		manager.onChange = { [weak self] in self?.update() }
		manager.resolveURL = GitHubAccess.resolveDownload
	}

	/// Call before launch finishes, like every BGTaskScheduler registration.
	static func register() {
		guard #available(iOS 26.0, *) else { return }
		BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
			MainActor.assumeIsolated { BackgroundDownloads.shared.launched(task) }
		}
	}

	/// Follows the downloads: asks for the system's progress UI when one
	/// starts, keeps it current, and ends it when none is left. Also called
	/// when Atelier comes to the front, to ask again after iOS ended it.
	func update() {
		guard #available(iOS 26.0, *) else { return }
		// A direct install's bar covers its download too (#72).
		guard isActive, !BackgroundInstalls.shared.coversDownloads else {
			finish(success: true)
			return
		}
		if let task = continuedTask as? BGContinuedProcessingTask {
			show(on: task)
		} else if !requested, UIApplication.shared.applicationState == .active {
			// On the next turn of the main loop: a download an install
			// started is followed by that install being queued, whose own bar
			// covers it.
			requested = true
			DispatchQueue.main.async {
				MainActor.assumeIsolated { BackgroundDownloads.shared.requestIfStillNeeded() }
			}
		}
	}

	private func requestIfStillNeeded() {
		guard #available(iOS 26.0, *), requested, continuedTask == nil else { return }
		requested = false
		guard isActive, !BackgroundInstalls.shared.coversDownloads, UIApplication.shared.applicationState == .active else { return }
		request()
	}

	@available(iOS 26.0, *)
	private func request() {
		let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: title, subtitle: subtitle)
		// Only start now: a queued task could start after the downloads end.
		request.strategy = .fail
		do {
			try BGTaskScheduler.shared.submit(request)
			requested = true
		} catch {
			// The downloads carry on in the background session without it.
			requested = false
		}
	}

	private func launched(_ task: BGTask) {
		requested = false
		guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask, isActive, continuedTask == nil, !BackgroundInstalls.shared.coversDownloads else {
			task.setTaskCompleted(success: false)
			return
		}
		continuedTask = task
		task.expirationHandler = {
			DispatchQueue.main.async {
				MainActor.assumeIsolated { BackgroundDownloads.shared.expired() }
			}
		}
		show(on: task)
	}

	@available(iOS 26.0, *)
	private func show(on task: BGContinuedProcessingTask) {
		let progress = activeProgress
		// Bytes when the sizes are known; otherwise a bar that sits short of
		// the end until the downloads finish.
		if let expected = progress.expected {
			task.progress.totalUnitCount = expected
			task.progress.completedUnitCount = min(progress.received, expected)
		} else {
			task.progress.totalUnitCount = 100
			task.progress.completedUnitCount = 50
		}
		task.updateTitle(title, subtitle: subtitle)
	}

	/// iOS ended the task, or the user stopped it from the system UI. The
	/// downloads keep going in the background session either way: iOS also
	/// ends a task whose progress stands still for about 30 seconds, which is
	/// what a download waiting out lost network looks like.
	private func expired() {
		continuedTask = nil
	}

	private func finish(success: Bool) {
		requested = false
		guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
		continuedTask = nil
		if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
		task.setTaskCompleted(success: success)
	}

	/// The downloads running for the user. Those started ahead (#19) run
	/// quietly, without the system's progress UI.
	private var active: [Download] {
		manager.downloads.filter { $0.status == .downloading && $0.isAhead != true }
	}

	private var isActive: Bool { !active.isEmpty }

	private var activeProgress: DownloadProgress {
		var received: Int64 = 0, expected: Int64 = 0
		for download in active {
			let current = manager.progress[download.id]
			received += current?.received ?? 0
			expected += current?.expected ?? download.expectedSize ?? 0
		}
		return DownloadProgress(received: received, expected: expected > 0 ? expected : nil)
	}

	private var title: String {
		let active = active
		return active.count == 1 ? "Downloading \(active[0].name)" : "Downloading \(active.count) apps"
	}

	private var subtitle: String {
		let progress = activeProgress
		let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
		guard let expected = progress.expected else { return received }
		return "\(received) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
	}
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// Must happen before launch finishes, or iOS rejects the task identifier.
		BackgroundDownloads.register()
		PhonePairing.registerBackgroundTask()
		BackgroundInstalls.register()
		// A certificate written for a signing Atelier was ended in the middle of (#72).
		HeldSecrets.deleteWritten()
		AutoUpdates.register()
		BackgroundRefresh.register()
		BackgroundRefresh.schedule()
		// Certificate notifications (#5) also show while Atelier is in front.
		UNUserNotificationCenter.current().delegate = self
		// Follows the network from launch, for downloads started ahead (#19).
		_ = NetworkPath.shared
		// Makes the background session now, so it gets the events of
		// downloads that finished while Atelier wasn't running.
		_ = BackgroundDownloads.shared
		return true
	}

	func application(
		_ application: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		switch identifier {
		case DownloadManager.sessionIdentifier:
			BackgroundDownloads.shared.manager.handleBackgroundEvents(completion: completionHandler)
		case SelfInstallNotice.sessionIdentifier:
			// After Atelier's install of itself (#24).
			SelfInstallNotice.shared.relaunched(completion: completionHandler)
		default:
			completionHandler()
		}
	}

	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		// In front, the install bar says how Atelier's own install went (#24).
		if notification.request.identifier == SelfInstallNotice.notificationID { return [] }
		return [.banner, .list, .sound]
	}

	/// An installs or updates notification opens the Library (#72, #19), and
	/// so does a certificate one, where its apps can be re-signed (#20), and
	/// a renewal one, where they can be renewed (#49); a news one opens
	/// Browse (#19).
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		let identifier = response.notification.request.identifier
		await MainActor.run {
			if identifier.hasPrefix(BackgroundInstalls.notificationPrefix) || identifier.hasPrefix(CertificateAlert.identifierPrefix) || identifier.hasPrefix(RenewalNotifications.prefix) || identifier == UpdateChecks.updatesNotificationID {
				BackgroundInstalls.shared.model?.libraryRequested = true
			} else if identifier.hasPrefix(UpdateChecks.newsNotificationPrefix) {
				BackgroundInstalls.shared.model?.browseRequested = true
			}
		}
	}
}
