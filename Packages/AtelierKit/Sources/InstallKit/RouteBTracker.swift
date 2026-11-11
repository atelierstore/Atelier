import Foundation

/// Follows one route B install from what Atelier can see of it, and decides
/// when it is over and how it ended.
///
/// What Atelier can see: requests to its loopback server (iOS asks for the
/// IPA only after the user accepts the install alert), how much of the IPA
/// was sent, iOS's install progress through the private
/// `LSApplicationWorkspace` (when it answers), and system notifications.
///
/// It can't see the install alert either: iOS doesn't tell the app whether
/// the user tapped Install or Cancel. A Cancel is inferred: Atelier stops
/// being the active app while the alert is up and becomes active again when
/// it closes, so when it's back and iOS hasn't asked for the IPA a moment
/// later, the alert closed without installing (`alertClosed`). The link can
/// then be opened again with the IPA already signed (`retry`, #51). That
/// Atelier goes inactive for the alert on iOS 27 is unverified on a device;
/// if it doesn't, the approval time limit lands in `alertClosed` instead.
///
/// What it can't see on iOS 27, per the install spike: whether installd
/// succeeded. The progress object stops at 62–72% and disappears on success
/// and failure alike, and `applicationIsInstalled:` and `LSApplicationProxy`
/// say "not installed" even for installed apps. So the answer comes from the
/// install check (`InstallCheck`, #11): when the app carries a check scheme
/// no installed app had, the scheme answering once iOS's progress is gone
/// means `installed`, and it staying silent means `notInstalled`. Without a
/// check, an install whose IPA iOS took in full ends as `probablyInstalled`,
/// unless a signal listed in `confirmingSignals` arrives. That list is empty:
/// no notification has been seen to fire on success and stay quiet on
/// failure on a device.
///
/// Pure value type driven by the caller's clock, so it is tested without a
/// device or a real server.
public struct RouteBTracker: Sendable {
	public enum Phase: Equatable, Sendable {
		/// The link is open and iOS hasn't asked for the IPA yet: its install
		/// alert is showing, or the manifest was refused.
		case waitingForApproval
		/// The alert closed and iOS didn't ask for the IPA: the user cancelled
		/// it, or iOS refused the app. Waits for `retry` or `giveUp`.
		case alertClosed
		/// iOS is fetching the IPA from the loopback server.
		case downloading(fraction: Double)
		/// iOS has the whole IPA and is installing it. The fraction is iOS's own,
		/// when the private progress API answers.
		case installing(fraction: Double?)
		case finished(Outcome)

		public var isFinished: Bool {
			if case .finished = self { return true }
			return false
		}
	}

	public enum Outcome: Equatable, Sendable {
		/// A confirming signal arrived after iOS had the whole IPA.
		case installed(signal: String)
		/// iOS took the whole IPA and nothing reported a failure.
		case probablyInstalled
		/// iOS never asked for the IPA: the user cancelled the alert, or iOS
		/// refused the manifest, and the install wasn't tried again. Atelier
		/// can't tell these apart.
		case notStarted
		/// iOS stopped fetching the IPA part way and didn't come back for it.
		case downloadFailed
		/// iOS took the whole IPA, but the app's check scheme never answered:
		/// iOS refused the app.
		case notInstalled
	}

	public struct Timing: Sendable {
		/// How long the install alert may wait for the user.
		public var approval: TimeInterval = 180
		/// Once Atelier is active again after the alert, how long iOS has to
		/// ask for the IPA before the alert counts as closed without installing.
		public var alertClosedGrace: TimeInterval = 3
		/// How long a closed alert waits for Try again before the install ends.
		public var retryWindow: TimeInterval = 600
		/// How long a download may stall, or stay broken off, before giving up.
		public var downloadStall: TimeInterval = 60
		/// After iOS's progress disappears, how long to wait for a late
		/// confirming signal.
		public var progressGoneGrace: TimeInterval = 5
		/// After the IPA is sent, how long to wait when iOS's progress never shows.
		public var noProgress: TimeInterval = 90
		/// After the IPA is sent, the longest an install is followed.
		public var installLimit: TimeInterval = 300
		/// With an install check, after iOS's progress disappears, how long
		/// to wait for the check scheme before calling the install failed.
		public var checkGrace: TimeInterval = 20

		public init() {}
	}

	public private(set) var phase: Phase = .waitingForApproval
	/// Every system signal seen, in order, with seconds since the start.
	public private(set) var signals: [(name: String, after: TimeInterval)] = []
	public private(set) var sawSystemProgress = false

	public let startedAt: Date
	public let timing: Timing
	public let confirmingSignals: Set<String>
	/// Whether the install check is on: the app carries a check scheme that
	/// wasn't registered when the install started.
	public let checksInstall: Bool

	private var lastActivity: Date
	/// When the install link was last opened.
	private var approvalStartedAt: Date
	/// Whether Atelier stopped being active since the link was opened.
	private var leftApp = false
	/// When Atelier became active again after that.
	private var backAt: Date?
	private var closedAt: Date?
	private var progressShowing = false
	private var payloadBrokenAt: Date?
	private var payloadSentAt: Date?
	private var progressGoneAt: Date?

	public init(startedAt: Date, timing: Timing = Timing(), confirmingSignals: Set<String> = [], checksInstall: Bool = false) {
		self.startedAt = startedAt
		self.timing = timing
		self.confirmingSignals = confirmingSignals
		self.checksInstall = checksInstall
		lastActivity = startedAt
		approvalStartedAt = startedAt
	}

	/// Atelier stopped being the active app: iOS's alert is over it, or the
	/// user left it.
	public mutating func appResignedActive(at now: Date) {
		guard phase == .waitingForApproval else { return }
		leftApp = true
		backAt = nil
	}

	/// Atelier is the active app again.
	public mutating func appBecameActive(at now: Date) {
		guard phase == .waitingForApproval, leftApp else { return }
		backAt = now
	}

	/// The install link was opened again after the alert closed.
	public mutating func retry(at now: Date) {
		guard phase == .alertClosed else { return }
		phase = .waitingForApproval
		approvalStartedAt = now
		lastActivity = now
		leftApp = false
		backAt = nil
		closedAt = nil
	}

	/// The user gave up on an install whose alert closed, or is still showing.
	public mutating func giveUp() {
		guard phase == .alertClosed || phase == .waitingForApproval else { return }
		phase = .finished(.notStarted)
	}

	/// iOS sent a request for the IPA (HEAD or GET).
	public mutating func requestSeen(at now: Date) {
		guard !phase.isFinished else { return }
		lastActivity = now
		payloadBrokenAt = nil
		// Also after the alert counted as closed: iOS asked late.
		if phase == .waitingForApproval || phase == .alertClosed {
			phase = .downloading(fraction: 0)
		}
	}

	public mutating func payloadProgress(sent: Int64, total: Int64, at now: Date) {
		guard case .downloading = phase else { return }
		lastActivity = now
		phase = .downloading(fraction: total > 0 ? min(1, Double(sent) / Double(total)) : 0)
	}

	/// A GET of the IPA ended: `complete` if every byte was sent.
	public mutating func payloadEnded(complete: Bool, at now: Date) {
		guard case .downloading = phase else { return }
		lastActivity = now
		if complete {
			payloadSentAt = now
			phase = .installing(fraction: nil)
		} else {
			payloadBrokenAt = now
		}
	}

	/// iOS's install progress for the app, polled: nil when there is no
	/// progress object right now.
	public mutating func systemProgress(_ fraction: Double?, at now: Date) {
		guard !phase.isFinished else { return }
		progressShowing = fraction != nil
		if let fraction {
			sawSystemProgress = true
			progressGoneAt = nil
			if case .installing = phase {
				phase = .installing(fraction: fraction)
			}
		} else if sawSystemProgress, progressGoneAt == nil, payloadSentAt != nil {
			progressGoneAt = now
		}
	}

	/// A system notification that might mean an app was installed.
	public mutating func systemSignal(_ name: String, at now: Date) {
		signals.append((name, now.timeIntervalSince(startedAt)))
		guard case .installing = phase, confirmingSignals.contains(name) else { return }
		phase = .finished(.installed(signal: name))
	}

	/// Whether the app's check scheme answers, polled. It counts once iOS has
	/// the whole IPA and its progress is gone (or never showed), so a
	/// placeholder iOS shows during the install can't confirm it.
	public mutating func installCheck(registered: Bool, at now: Date) {
		guard checksInstall, registered, case .installing = phase, !progressShowing else { return }
		phase = .finished(.installed(signal: "install check"))
	}

	/// Applies the time limits. Call it regularly.
	public mutating func tick(at now: Date) {
		switch phase {
		case .finished:
			return
		case .waitingForApproval:
			let back = backAt.map { now.timeIntervalSince($0) >= timing.alertClosedGrace } ?? false
			if back || now.timeIntervalSince(approvalStartedAt) >= timing.approval {
				phase = .alertClosed
				closedAt = now
			}
		case .alertClosed:
			if let closedAt, now.timeIntervalSince(closedAt) >= timing.retryWindow {
				phase = .finished(.notStarted)
			}
		case .downloading:
			let since = payloadBrokenAt ?? lastActivity
			if now.timeIntervalSince(since) >= timing.downloadStall {
				phase = .finished(.downloadFailed)
			}
		case .installing:
			guard let payloadSentAt else { return }
			if checksInstall {
				if let progressGoneAt, now.timeIntervalSince(progressGoneAt) >= timing.checkGrace {
					phase = .finished(.notInstalled)
				} else if now.timeIntervalSince(payloadSentAt) >= timing.installLimit {
					// Still no answer: refused if iOS's progress is gone or never
					// showed, unknown if it's still showing.
					phase = .finished(progressShowing ? .probablyInstalled : .notInstalled)
				}
			} else if let progressGoneAt, now.timeIntervalSince(progressGoneAt) >= timing.progressGoneGrace {
				phase = .finished(.probablyInstalled)
			} else if !sawSystemProgress, now.timeIntervalSince(payloadSentAt) >= timing.noProgress {
				phase = .finished(.probablyInstalled)
			} else if now.timeIntervalSince(payloadSentAt) >= timing.installLimit {
				phase = .finished(.probablyInstalled)
			}
		}
	}
}
