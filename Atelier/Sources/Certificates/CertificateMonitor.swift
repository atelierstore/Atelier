import BackgroundTasks
import CertKit
import SwiftUI
import UserNotifications

/// What a certificate's badge says (#5): on the certificate, and on every
/// installed app signed with it.
enum CertificateAttention: Equatable {
	case revoked
	case expired
	case expiring(daysLeft: Int)

	/// Nil when there's nothing to warn about.
	init?(_ certificate: StoredCertificate, now: Date = .now) {
		self.init(revoked: certificate.isRevoked, expiry: certificate.expiry, now: now)
	}

	/// For an Apple ID's certificate (#49), which its apps' profiles never
	/// outlast.
	init?(_ account: StoredAppleID, now: Date = .now) {
		self.init(revoked: account.isRevoked, expiry: account.expiry, now: now)
	}

	/// For a certificate deleted from Atelier, as it was then (#20).
	init?(_ retired: RetiredCertificate, now: Date = .now) {
		self.init(revoked: retired.revoked, expiry: CertificateExpiry(certificate: retired.expiresAt, profile: retired.expiresAt), now: now)
	}

	private init?(revoked: Bool, expiry: CertificateExpiry, now: Date) {
		if revoked {
			self = .revoked
		} else if expiry.isExpired(now: now) {
			self = .expired
		} else if expiry.warning(now: now) != nil {
			self = .expiring(daysLeft: expiry.daysLeft(now: now))
		} else {
			return nil
		}
	}

	var title: String {
		switch self {
		case .revoked: "Certificate revoked"
		case .expired: "Certificate expired"
		case .expiring(let days): days == 1 ? "Certificate expires within a day" : "Certificate expires in \(days) days"
		}
	}

	var symbol: String {
		switch self {
		case .revoked: "xmark.octagon.fill"
		case .expired: "clock.badge.xmark"
		case .expiring: "exclamationmark.triangle.fill"
		}
	}

	var color: Color {
		switch self {
		case .revoked, .expired: .red
		case .expiring: .orange
		}
	}
}

/// A small coloured label for `CertificateAttention`.
struct CertificateAttentionLabel: View {
	let attention: CertificateAttention

	var body: some View {
		Label(attention.title, systemImage: attention.symbol)
			.font(.caption.weight(.medium))
			.foregroundStyle(attention.color)
	}
}

/// Local notifications about certificates (#5). Expiry warnings are
/// scheduled ahead, so they arrive even if Atelier isn't opened; a
/// revocation is announced when a check finds it.
@MainActor
enum CertificateNotifications {
	/// The identifiers already shown or scheduled (`CertificateAlerts.Plan.handled`).
	private static let handledKey = "certificateAlertsHandled"

	/// Asks once, when there's a certificate to warn about.
	static func requestAuthorization() async {
		_ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
	}

	/// Replaces the pending certificate notifications with the current plan
	/// and shows what's due now.
	static func sync(_ certificates: [StoredCertificate]) async {
		let center = UNUserNotificationCenter.current()
		let defaults = UserDefaults.standard
		let handled = Set(defaults.stringArray(forKey: handledKey) ?? [])
		let plan = CertificateAlerts.plan(for: certificates, now: .now, handled: handled)

		let pending = await center.pendingNotificationRequests()
			.map(\.identifier)
			.filter { $0.hasPrefix(CertificateAlert.identifierPrefix) }
		center.removePendingNotificationRequests(withIdentifiers: pending)

		for alert in plan.now {
			try? await center.add(request(alert, trigger: nil))
		}
		for alert in plan.scheduled {
			let interval = alert.date.timeIntervalSinceNow
			guard interval > 0 else { continue }
			try? await center.add(request(alert, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
		}
		defaults.set(Array(plan.handled), forKey: handledKey)
	}

	/// Forgets that a certificate's revocation or expiry was announced, once
	/// a test of it ends (#20), so that a real one is announced too.
	static func forgetShown(for id: UUID) {
		let defaults = UserDefaults.standard
		let prefix = CertificateAlert.identifierPrefix + id.uuidString
		let shown: Set<String> = ["\(prefix).revoked", "\(prefix).expired"]
		let handled = (defaults.stringArray(forKey: handledKey) ?? []).filter { !shown.contains($0) }
		defaults.set(handled, forKey: handledKey)
	}

	private static func request(_ alert: CertificateAlert, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
		let content = UNMutableNotificationContent()
		content.title = alert.title
		content.body = alert.body
		content.sound = .default
		return UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger)
	}
}

/// Atelier's background app refresh: certificate checks (#5), the weekly
/// renewal of an Apple ID's apps (#49), then update and news checks (#19). iOS decides when it runs, usually a few times a
/// day for an app that's used.
@MainActor
enum BackgroundRefresh {
	/// Listed in BGTaskSchedulerPermittedIdentifiers.
	static let taskIdentifier = "com.atelier.app.refresh"

	/// Call before launch finishes, like every BGTaskScheduler registration.
	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
			MainActor.assumeIsolated { run(task) }
		}
	}

	/// Asks for the next run, a few hours away. Called on launch and after each run.
	static func schedule() {
		let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
		request.earliestBeginDate = .now.addingTimeInterval(4 * 60 * 60)
		try? BGTaskScheduler.shared.submit(request)
	}

	private static func run(_ task: BGTask) {
		schedule()
		let work = Task { @MainActor in
			await CertificatesModel.shared.refreshStatus()
			// An Apple ID's apps whose profile ends within two days (#49).
			await ProfileRenewals.shared.renewDue(.background)
			await UpdateChecks.run(from: .refresh)
			task.setTaskCompleted(success: !Task.isCancelled)
		}
		task.expirationHandler = { work.cancel() }
	}
}
