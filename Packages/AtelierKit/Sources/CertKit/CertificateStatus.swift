import Foundation

/// What Atelier last learned about a certificate's revocation (#5).
public struct RevocationState: Codable, Equatable, Sendable {
	/// Apple's last answer, kept when a later check fails.
	public var status: RevocationStatus?
	/// When that answer came.
	public var checkedAt: Date?
	/// Why the last check failed; nil once one works.
	public var error: String?
	/// When Atelier last tried.
	public var attemptedAt: Date

	public init(status: RevocationStatus? = nil, checkedAt: Date? = nil, error: String? = nil, attemptedAt: Date) {
		self.status = status
		self.checkedAt = checkedAt
		self.error = error
		self.attemptedAt = attemptedAt
	}

	/// After a check that worked.
	public static func checked(_ status: RevocationStatus, at date: Date) -> RevocationState {
		RevocationState(status: status, checkedAt: date, attemptedAt: date)
	}

	/// After a check that failed, keeping what was known before.
	public func failed(_ error: String, at date: Date) -> RevocationState {
		RevocationState(status: status, checkedAt: checkedAt, error: error, attemptedAt: date)
	}

	public var isRevoked: Bool {
		if case .revoked = status { return true }
		return false
	}
}

/// When a certificate and profile pair stops signing apps that open, and
/// which of the two runs out first.
public struct CertificateExpiry: Equatable, Sendable {
	public enum Part: Equatable, Sendable {
		case certificate, profile
	}

	public var date: Date
	public var part: Part

	/// Days before expiry that Atelier warns at.
	public static let warningDays = [14, 7, 1]

	public init(certificate: Date, profile: Date) {
		// A tie goes to the certificate: replacing it means a new profile anyway.
		if profile < certificate {
			self.date = profile
			self.part = .profile
		} else {
			self.date = certificate
			self.part = .certificate
		}
	}

	public func isExpired(now: Date) -> Bool { date <= now }

	/// Whole days left, rounded up: 1 for anything up to a day, 0 once expired.
	public func daysLeft(now: Date) -> Int {
		let seconds = date.timeIntervalSince(now)
		return seconds <= 0 ? 0 : Int((seconds / 86_400).rounded(.up))
	}

	/// The closest warning reached: 14, 7 or 1 days, 0 once expired, or nil
	/// with more than 14 days to go.
	public func warning(now: Date) -> Int? {
		if isExpired(now: now) { return 0 }
		return Self.warningDays.last { now >= warningDate($0) }
	}

	/// When the warning `days` before expiry is due; the expiry itself for 0.
	public func warningDate(_ days: Int) -> Date {
		date.addingTimeInterval(-Double(days) * 86_400)
	}
}

extension StoredCertificate {
	public var expiry: CertificateExpiry {
		CertificateExpiry(certificate: certificate.notAfter, profile: profile.expirationDate)
	}

	public var isRevoked: Bool { revocation?.isRevoked ?? false }
}

/// A notification about a certificate (#5): revoked, about to expire, or
/// expired.
public struct CertificateAlert: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		/// The warning `days` before expiry.
		case expiring(days: Int)
		case expired
		case revoked
	}

	public var certificateID: UUID
	public var kind: Kind
	/// When it's due.
	public var date: Date
	public var title: String
	public var body: String

	/// The same for every plan, so a scheduled alert is replaced rather than
	/// added twice, and one already shown is recognised.
	public var identifier: String {
		let suffix: String
		switch kind {
		case .expiring(let days): suffix = "expiring-\(days)"
		case .expired: suffix = "expired"
		case .revoked: suffix = "revoked"
		}
		return "\(Self.identifierPrefix)\(certificateID.uuidString).\(suffix)"
	}

	public static let identifierPrefix = "certificate."
}

/// Works out which certificate alerts to show now and which to schedule.
/// Expiry is known in advance, so its warnings are scheduled and arrive even
/// if Atelier isn't opened; revocation is only known once a check finds it.
public enum CertificateAlerts {
	public struct Plan: Equatable, Sendable {
		/// Due now and not shown yet.
		public var now: [CertificateAlert]
		/// Due later: everything that should be pending, replacing what was.
		public var scheduled: [CertificateAlert]
		/// Identifiers shown or scheduled, to pass to the next plan.
		public var handled: Set<String>
	}

	/// `handled` is the last plan's `handled`. An alert that was scheduled
	/// and has since come due counts as shown, so it isn't shown twice.
	public static func plan(for certificates: [StoredCertificate], now: Date, handled: Set<String>) -> Plan {
		var due: [CertificateAlert] = []
		var later: [CertificateAlert] = []
		for certificate in certificates {
			let alerts = alerts(for: certificate, now: now)
			due += alerts.filter { $0.date <= now }
			later += alerts.filter { $0.date > now }
		}
		let shown = due.filter { !handled.contains($0.identifier) }
		// Only identifiers of certificates still imported are kept.
		let ids = Set(certificates.map { $0.id.uuidString })
		var kept = handled.filter { identifier in ids.contains { identifier.hasPrefix(CertificateAlert.identifierPrefix + $0) } }
		kept.formUnion(due.map(\.identifier))
		kept.formUnion(later.map(\.identifier))
		return Plan(now: shown, scheduled: later, handled: kept)
	}

	/// A certificate's alerts that matter now: the latest one due, and every
	/// one still to come. A revoked certificate only has its revocation.
	static func alerts(for stored: StoredCertificate, now: Date) -> [CertificateAlert] {
		let name = stored.displayName
		if stored.isRevoked {
			return [CertificateAlert(
				certificateID: stored.id,
				kind: .revoked,
				date: now,
				title: "\(name) was revoked",
				body: "Apple revoked this certificate, so apps signed with it won't open. Open Atelier to re-sign them with another certificate."
			)]
		}

		let expiry = stored.expiry
		let day = expiry.date.formatted(date: .abbreviated, time: .omitted)
		func alert(_ days: Int, at date: Date) -> CertificateAlert {
			if days == 0 {
				return CertificateAlert(
					certificateID: stored.id,
					kind: .expired,
					date: date,
					title: "\(name) has expired",
					body: "It has expired, so apps signed with it won't open. Open Atelier to re-sign them with another certificate."
				)
			}
			let left = expiry.daysLeft(now: date)
			return CertificateAlert(
				certificateID: stored.id,
				kind: .expiring(days: days),
				date: date,
				title: left == 1 ? "\(name) expires within a day" : "\(name) expires in \(left) days",
				body: "It expires on \(day). Apps signed with it stop opening then, so open Atelier to re-sign them with another certificate before that."
			)
		}

		var alerts: [CertificateAlert] = []
		if let current = expiry.warning(now: now) {
			alerts.append(alert(current, at: now))
		}
		for days in CertificateExpiry.warningDays + [0] where expiry.warningDate(days) > now {
			alerts.append(alert(days, at: expiry.warningDate(days)))
		}
		return alerts
	}
}
