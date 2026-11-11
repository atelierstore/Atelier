import ActivityKit
import Foundation
import InstallKit
import UIKit

/// Shows route A's pairing in Atelier's own Live Activity (#54), with more
/// room than the bar of a BGContinuedProcessingTask: every step on the Lock
/// Screen, the step and code in the Dynamic Island, and more on a long press.
/// The AtelierLiveActivity extension draws it.
///
/// While it shows, SilentAudio keeps Atelier running instead of the
/// continued task, whose bar would fight it for the Dynamic Island (the maintainer chose
/// this on 23 Oct 2026). With Live Activities off, or if the silence can't
/// start, PhonePairing falls back to the continued task.
///
/// Picture in Picture was tried in the install spike too, but iOS hides an
/// app's Live Activity from the Dynamic Island while its PiP window is up, and
/// The maintainer chose the Live Activity (22 Oct 2026).
@MainActor
final class PairingLiveActivity {
	static let shared = PairingLiveActivity()

	private typealias State = PairingActivityAttributes.ContentState

	private var activity: Activity<PairingActivityAttributes>?
	/// Whether the Live Activity is up with silent audio keeping Atelier
	/// running, so pairing needs no continued task.
	var keepsAtelierRunning: Bool { activity != nil && SilentAudio.shared.isPlaying }
	private var endDate = Date()
	private var returnObserver: NSObjectProtocol?
	/// Opens the Dynamic Island on step 1 once Atelier leaves the front: iOS
	/// doesn't show an app's own Live Activity while the app is open, and
	/// step 1 usually starts before the user leaves.
	private var backgroundObserver: NSObjectProtocol?
	/// Logs Atelier coming back to the front, to match against the island
	/// sticking on step 1 (the maintainer suspects returning to Atelier mid-pairing).
	private var foregroundObserver: NSObjectProtocol?
	private var showedSettingsPath = false
	/// The state last sent, which `activity.content` only shows once iOS has it.
	private var lastState: State?
	/// The update being sent, which the next one waits for.
	private var pendingUpdate: Task<Void, Never>?

	/// Follows PhonePairing's status. Starting one needs Atelier in front,
	/// which it is when the user taps Pair.
	func show(_ status: PhonePairing.Status, attemptSeconds: TimeInterval) {
		switch status {
		case .starting:
			endDate = Date().addingTimeInterval(attemptSeconds)
			start(State(phase: .starting, endDate: endDate))
		case .ready:
			update(State(phase: .openSettings, endDate: endDate))
			if UIApplication.shared.applicationState == .background { showSettingsPath() }
		case .enterCode(let code):
			// An alert opens the Dynamic Island's expanded view for a moment.
			update(State(phase: .enterCode, code: code, endDate: endDate), alert: AlertConfiguration(
				title: "Pairing code \(code)",
				body: "Enter it in Settings",
				sound: .default
			))
		case .paired:
			// iOS doesn't let Atelier come back to the front by itself, so the
			// Dynamic Island opens to say that a tap does it.
			update(State(phase: .paired, endDate: endDate), alert: AlertConfiguration(
				title: "\(ThisDevice.name) paired",
				body: "Tap to return to Atelier",
				sound: .default
			))
			endOnReturn()
		case .idle, .failed:
			end()
		}
	}

	private func start(_ state: State) {
		end()
		// One left over from an attempt Atelier didn't see the end of.
		for old in Activity<PairingActivityAttributes>.activities {
			Task { await old.end(nil, dismissalPolicy: .immediate) }
		}
		guard ActivityAuthorizationInfo().areActivitiesEnabled else {
			PhonePairing.shared.note("Live Activities are off for Atelier; the steps show in the system bar instead")
			return
		}
		do {
			activity = try Activity.request(
				attributes: PairingActivityAttributes(deviceName: ThisDevice.name),
				content: ActivityContent(state: state, staleDate: endDate),
				pushType: nil
			)
		} catch {
			PhonePairing.shared.note("the Live Activity didn't start: \(error)")
			return
		}
		showedSettingsPath = false
		lastState = state
		backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated {
				PairingLiveActivity.shared.noteSwitch("left the front")
				PairingLiveActivity.shared.showSettingsPath()
			}
		}
		foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { PairingLiveActivity.shared.noteSwitch("came to the front") }
		}
		do {
			try SilentAudio.shared.start(for: .pairing)
		} catch {
			PhonePairing.shared.note("silent audio didn't start (\(error)); the system bar keeps Atelier running instead")
		}
	}

	/// Sends a new state, in order after the ones before it, the state on its
	/// own before its alert.
	///
	/// iOS sometimes ignores these while Atelier is in the background, even
	/// though silent audio keeps it running: on 23 Oct 2026 the pairing log
	/// showed the code sent and the island kept on step 1, more often after
	/// going back and forth between Atelier and Settings. Developers report
	/// the same for apps kept running by audio
	/// (developer.apple.com/forums/thread/717701), and sending inside a UIKit
	/// background task didn't help. The maintainer chose to leave it: the user then
	/// switches back to Atelier to read the code.
	private func update(_ state: State, alert: AlertConfiguration? = nil) {
		guard let activity else { return }
		lastState = state
		let content = ActivityContent(state: state, staleDate: endDate)
		let previous = pendingUpdate
		pendingUpdate = Task {
			await previous?.value
			await activity.update(content)
			if let alert {
				await activity.update(content, alertConfiguration: alert)
			}
			PhonePairing.shared.note("Live Activity at \(activity.content.state.phase.rawValue)\(alert == nil ? "" : ", with an alert") (sent \(state.phase.rawValue))")
		}
	}

	private func noteSwitch(_ what: String) {
		guard let activity else { return }
		PhonePairing.shared.note("Atelier \(what); Live Activity \(activity.activityState) at \(activity.content.state.phase.rawValue), silent audio \(SilentAudio.shared.isPlaying ? "playing" : "stopped")")
	}

	/// The alert that opens the Dynamic Island on step 1, once per attempt.
	private func showSettingsPath() {
		guard activity != nil, !showedSettingsPath, let state = lastState, state.phase == .openSettings else { return }
		showedSettingsPath = true
		update(state, alert: AlertConfiguration(
			title: "Pair this \(ThisDevice.name)",
			body: "\(State.settingsPath), \(State.settingsTap)",
			sound: .default
		))
	}

	/// Like the system bar, "paired" stays until the user comes back to
	/// Atelier, or for 20 s.
	private func endOnReturn() {
		guard UIApplication.shared.applicationState != .active else {
			end()
			return
		}
		returnObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { PairingLiveActivity.shared.end() }
		}
		let ending = activity
		DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
			MainActor.assumeIsolated {
				let shared = PairingLiveActivity.shared
				if let ending, shared.activity === ending { shared.end() }
			}
		}
	}

	private func end() {
		SilentAudio.shared.stop(for: .pairing)
		if let foregroundObserver {
			NotificationCenter.default.removeObserver(foregroundObserver)
			self.foregroundObserver = nil
		}
		if let backgroundObserver {
			NotificationCenter.default.removeObserver(backgroundObserver)
			self.backgroundObserver = nil
		}
		if let returnObserver {
			NotificationCenter.default.removeObserver(returnObserver)
			self.returnObserver = nil
		}
		guard let activity else { return }
		self.activity = nil
		let previous = pendingUpdate
		pendingUpdate = nil
		Task {
			await previous?.value
			await activity.end(nil, dismissalPolicy: .immediate)
		}
	}
}
