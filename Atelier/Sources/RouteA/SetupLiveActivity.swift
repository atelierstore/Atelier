import ActivityKit
import Foundation
import UIKit

/// Keeps step 2 or 3 of the first setup in a Live Activity (#54), so it
/// stays in sight in the App Store, LocalDevVPN or Settings. The maintainer asked for
/// it on 23 Oct 2026, "if only to remember what we're doing", and on 1 Nov
/// 2026 for it to be silent and for the first setup only: it opened the
/// Dynamic Island with a sound each time Atelier left the front, came back
/// whenever a finished setup's check failed, and stayed after Atelier quit.
///
/// Settings › Installs › Setup sets `state` to the step that's waiting, or
/// nil. iOS only starts a Live Activity while Atelier is in front, and shows
/// it in the Dynamic Island by itself once Atelier leaves the front, with
/// no sound or banner. Nothing keeps Atelier running, so the island keeps
/// the step Atelier last saw until the user comes back; when Atelier quits
/// meanwhile, its next launch ends it (`endLeftovers`).
@MainActor
final class SetupLiveActivity {
	static let shared = SetupLiveActivity()

	typealias State = SetupActivityAttributes.ContentState

	private var activity: Activity<SetupActivityAttributes>?
	/// The update being sent, which the next one waits for.
	private var pendingUpdate: Task<Void, Never>?

	/// Setting it again retries a start that iOS refused, such as while
	/// Atelier wasn't in front.
	var state: State? {
		didSet {
			if let state {
				if activity == nil {
					start(state)
				} else if state != oldValue {
					update(state)
				}
			} else {
				end()
			}
		}
	}

	/// Ends any left by a run of Atelier that quit while the setup waited,
	/// which iOS would otherwise keep showing for hours. Called at launch.
	static func endLeftovers() {
		for old in Activity<SetupActivityAttributes>.activities {
			Task { await old.end(nil, dismissalPolicy: .immediate) }
		}
	}

	private func start(_ state: State) {
		Self.endLeftovers()
		guard UIApplication.shared.applicationState == .active,
		      ActivityAuthorizationInfo().areActivitiesEnabled else { return }
		activity = try? Activity.request(
			attributes: SetupActivityAttributes(),
			content: ActivityContent(state: state, staleDate: nil),
			pushType: nil
		)
	}

	private func update(_ state: State) {
		guard let activity else { return }
		let content = ActivityContent(state: state, staleDate: nil)
		let previous = pendingUpdate
		pendingUpdate = Task {
			await previous?.value
			await activity.update(content)
		}
	}

	private func end() {
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
