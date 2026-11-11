import BackgroundTasks
import CertKit
import InstallKit
import AtelierCore
import SwiftData
import UIKit

/// Updates that install by themselves (#72): with Install updates
/// automatically on, a `BGProcessingTask` refreshes the sources, finds the
/// updates the Library would show (#18) and installs them directly (route A),
/// then `BackgroundInstalls` sends "Updated in the background".
///
/// iOS decides when it runs: in the spike, 12.7 s after the earliest allowed
/// time once and 3 h 36 min after it the other time. It only installs when
/// direct installs can run without Atelier in front: on Wi-Fi with
/// LocalDevVPN already connected, since switching LocalDevVPN on means
/// opening it. Otherwise it only checks, as a background refresh does
/// (`UpdateChecks`, #19), and waits for the next run.
@MainActor
enum AutoUpdates {
	static let enabledKey = "autoUpdate"
	static let whileChargingKey = "autoUpdateWhileCharging"
	/// Starts with the bundle ID and is listed in BGTaskSchedulerPermittedIdentifiers.
	static let taskIdentifier = "com.atelier.app.autoupdate"
	/// How soon after the last run the next may start, at the earliest.
	private static let interval: TimeInterval = 60 * 60

	/// Atelier's store, set at launch: a run can start without any screen.
	static var container: ModelContainer?

	/// On, and this iPhone is paired for direct installs. Each run checks
	/// the rest, LocalDevVPN included, before installing anything. Not
	/// `isSetUp`, which also asks whether LocalDevVPN is installed: a run
	/// launched in the background shouldn't hang on that, and until it was
	/// read at launch every launch cancelled the next run (#72).
	static var isOn: Bool {
		UserDefaults.standard.bool(forKey: enabledKey) && RouteASetup.shared.isPaired
	}

	static var onlyWhileCharging: Bool {
		UserDefaults.standard.object(forKey: whileChargingKey) as? Bool ?? true
	}

	/// What the setting does, under it in Settings › Updates.
	static let explanation = "Atelier checks your sources from time to time and installs updates by itself, in the background, when you're on Wi-Fi and LocalDevVPN is connected."

	/// Turns Install updates automatically on or off, from Settings ›
	/// Updates or the setup's Turn On Automatic Updates, while the iPhone
	/// is unlocked.
	static func setEnabled(_ on: Bool) {
		UserDefaults.standard.set(on, forKey: enabledKey)
		applyProtection()
		schedule()
		// For "Updated in the background".
		if on { Task { await CertificateNotifications.requestAuthorization() } }
	}

	/// Follows the setting with how the pairing file and certificates are
	/// protected: with it on, they're readable after first unlock, so a run
	/// can install while the iPhone is locked; with it off, only while it's
	/// unlocked, as before #72. The same while an Apple ID has apps on this
	/// iPhone, so their weekly renewal can run while it's locked (#49).
	/// GitHub sign-ins follow, so a run can download from a private repo.
	/// Called when the setting changes, and as Atelier comes to the front,
	/// while the iPhone is unlocked.
	static func applyProtection() {
		let renews = CertificatesModel.shared.appleIDs.contains { !($0.profiles ?? []).isEmpty }
		let relaxed = UserDefaults.standard.bool(forKey: enabledKey) || renews
		if relaxed != SecretProtection.readableAfterFirstUnlock {
			UserDefaults.standard.set(relaxed, forKey: SecretProtection.defaultsKey)
			try? PairingFileStore.standard().reprotect()
			CertificatesModel.shared.reprotect()
		}
		GitHubAccess.applyProtection(readableAfterFirstUnlock: relaxed)
	}

	/// Call before launch finishes, like every BGTaskScheduler registration.
	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
			MainActor.assumeIsolated { run(task) }
		}
	}

	/// Asks for the next run, in place of the one asked for before, or
	/// cancels it when the setting is off. Called when the settings change
	/// and after each run.
	static func schedule() {
		guard isOn else {
			BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
			return
		}
		// Replaces the request waiting, if there is one.
		let request = BGProcessingTaskRequest(identifier: taskIdentifier)
		request.requiresNetworkConnectivity = true
		request.requiresExternalPower = onlyWhileCharging
		request.earliestBeginDate = .now.addingTimeInterval(interval)
		try? BGTaskScheduler.shared.submit(request)
	}

	/// While Atelier is in front: asks for a run when none is waiting, as
	/// after Atelier is installed again. Every launch used to cancel the
	/// waiting request and ask for a new one an hour later, including when
	/// iOS woke Atelier in the background, maybe for the run itself, and on
	/// the test iPhone no run came overnight (26 Oct). The spike asked once,
	/// and its runs came, as Atelier's did once it stopped asking at every
	/// launch (#72).
	static func scheduleIfNeeded() {
		guard isOn else { return }
		Task {
			let waiting = await BGTaskScheduler.shared.pendingTaskRequests().contains { $0.identifier == taskIdentifier }
			if !waiting { schedule() }
		}
	}

	private static func run(_ task: BGTask) {
		schedule()
		let work = Task { @MainActor in
			await installUpdates()
			task.setTaskCompleted(success: !Task.isCancelled)
		}
		task.expirationHandler = {
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					work.cancel()
					// iOS is about to suspend Atelier: the install history
					// says what was cancelled, and the next run tries again.
					InstallModel.shared.cancelAll()
				}
			}
		}
	}

	/// One run: nothing when the user's own installs are going, or when
	/// direct installs can't run now; otherwise every update the Library
	/// would show, one after another, until they've all ended, apart from
	/// those that ask for a new permission.
	static func installUpdates() async {
		let installer = InstallModel.shared
		guard isOn, let container else { return }
		guard !installer.isRunning, installer.waiting.isEmpty else { return }
		// Unless they're readable after first unlock, the pairing file and the
		// certificates can't be read while the iPhone is locked. Without
		// them, or direct installs, the run only checks: it tells about the
		// updates and downloads them ahead on Wi-Fi (#19).
		guard UIApplication.shared.isProtectedDataAvailable || SecretProtection.readableAfterFirstUnlock,
		      case .ready = await installer.directInstallsHealth()
		else {
			await UpdateChecks.run(from: .automatic)
			return
		}
		// The apps whose profile ends within two days first (#49).
		await ProfileRenewals.shared.renewDue(.background)
		guard !Task.isCancelled else { return }

		let context = container.mainContext
		await SourceLibrary(context: context, gitHub: GitHubAccess.source()).refreshAll()
		guard !Task.isCancelled else { return }
		let records = (try? context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
		let catalog = await CatalogModel.build(from: records)
		let installs = (try? context.fetch(FetchDescriptor<InstallRecord>())) ?? []
		let certificates = CertificatesModel.shared
		// The user may have started an install meanwhile.
		guard !Task.isCancelled, !installer.isRunning, installer.waiting.isEmpty else { return }
		for install in installs {
			let item = LibraryItem(install, catalog: catalog, certificates: certificates, installer: installer)
			// One that asks for a new permission waits for the user's Update,
			// as its row says it does (3 Nov 2026).
			guard let version = item.update, item.newPermissions.isEmpty else { continue }
			// One that needs the app deleted first is left for the Library to ask about.
			installer.updateAutomatically(install, to: version, in: catalog, downloads: BackgroundDownloads.shared.manager, certificates: certificates, into: context)
		}
		while installer.isRunning || !installer.waiting.isEmpty, !Task.isCancelled {
			try? await Task.sleep(for: .seconds(1))
		}
		// What's left, such as an update that needs the app deleted first.
		guard !Task.isCancelled else { return }
		await UpdateChecks.check(catalog, context: context, from: .automatic)
	}
}
