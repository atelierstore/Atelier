import AtelierCore
import CertKit
import InstallKit
import SwiftUI

// What the Library shows of apps installed with an Apple ID (#49): their
// own profile's days, which end long before the Apple ID's certificate,
// and the apps Disable took off this iPhone with their data kept. The maintainer
// approved the mockups on 3 Nov 2026.

/// How long an app's own profile from an Apple ID has left (#49).
enum AppProfileDays {
	/// How long a free Apple ID's profiles last, and a paid team's.
	static let free: TimeInterval = 7 * 86_400
	static let paid: TimeInterval = 365 * 86_400

	/// Whole days left, rounded up as a certificate's are: 1 for anything
	/// up to a day, 0 once it ended.
	static func days(until end: Date, now: Date = .now) -> Int {
		let seconds = end.timeIntervalSince(now)
		return seconds <= 0 ? 0 : Int((seconds / 86_400).rounded(.up))
	}

	/// "7 days left", "Less than a day left", "Ended".
	static func text(until end: Date, now: Date = .now) -> String {
		switch days(until: end, now: now) {
		case 0: "Ended"
		case 1: "Less than a day left"
		case let days: "\(days) days left"
		}
	}

	/// How much of it is left, from 1 when Apple gave it to 0 when it ends.
	static func fraction(until end: Date, isFree: Bool, now: Date = .now) -> Double {
		let total = isFree ? free : paid
		return min(max(end.timeIntervalSince(now) / total, 0), 1)
	}

	/// "Tue 10 Nov at 14:39".
	static func describe(_ date: Date) -> String {
		let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
		return "\(day) at \(date.formatted(date: .omitted, time: .shortened))"
	}

	/// "today at 14:39", "tomorrow at 14:39", "Thu 12 Nov at 14:39".
	static func relative(_ date: Date, now: Date = .now) -> String {
		let time = date.formatted(date: .omitted, time: .shortened)
		let calendar = Calendar.current
		if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
		if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow at \(time)" }
		return describe(date)
	}

	/// "today", "tomorrow", "on Fri 13 Nov".
	static func day(_ date: Date, now: Date = .now) -> String {
		let calendar = Calendar.current
		if calendar.isDate(date, inSameDayAs: now) { return "today" }
		if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
		if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
		return "on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
	}
}

/// An offloaded app's icon (#49): greyed, with a cloud, as iOS marks an
/// offloaded app (4 Nov 2026).
struct DisabledAppIcon: View {
	let url: URL?
	let tint: String?
	var size: CGFloat = 48

	var body: some View {
		SourceIcon(url: url, tint: tint, size: size)
			.saturation(0.55)
			.opacity(0.45)
			.overlay(alignment: .bottomTrailing) {
				Image(systemName: "icloud.and.arrow.down")
					.font(.system(size: size * 0.2, weight: .semibold))
					.foregroundStyle(.gray)
					.frame(width: size * 0.36, height: size * 0.36)
					.background(Circle().fill(.background))
					.offset(x: size * 0.1, y: size * 0.1)
			}
			.accessibilityLabel("Offloaded")
	}
}

/// On the Library's row of an app that holds one of a free Apple ID's 3
/// places on this iPhone (#49), so it's plain which apps to offload for
/// another (4 Nov 2026). Just the Apple ID's icon, as the filter
/// has it, so the app's name has the room (the same evening).
struct FreeAppleIDTag: View {
	var body: some View {
		Image(systemName: "person.badge.key.fill")
			.font(.caption2.weight(.semibold))
			.foregroundStyle(.blue)
			.padding(.horizontal, 5)
			.padding(.vertical, 2)
			.background(.blue.opacity(0.12), in: Capsule())
			.fixedSize()
			.accessibilityLabel("Free Apple ID")
	}
}

/// The Apple ID an app was installed with, in "Installed with" on its
/// page (#49): its own profile's days on the bar, as they end long before
/// the Apple ID's certificate; the team once the app is disabled.
struct AppleIDInstalledRow: View {
	let account: StoredAppleID
	let profile: AppProfile?
	/// Off this iPhone, so no profile runs it.
	var disabled = false

	var body: some View {
		let health = CertificateHealth(account)
		HStack(spacing: 12) {
			AppleIDTile(isRevoked: health == .revoked, size: 40)
			VStack(alignment: .leading, spacing: 4) {
				Text(account.displayName)
					.font(.headline)
					.lineLimit(1)
				if health == .revoked {
					Label("Revoked by Apple", systemImage: "xmark.seal.fill")
						.labelStyle(InlineLabelStyle())
						.font(.footnote.weight(.medium))
						.foregroundStyle(.red)
				} else if !disabled, let profile {
					let days = AppProfileDays.days(until: profile.expires)
					let color: Color = days == 0 ? .red : .green
					HStack(spacing: 8) {
						ValidityBar(fraction: AppProfileDays.fraction(until: profile.expires, isFree: account.isFree), color: color)
						Text(AppProfileDays.text(until: profile.expires))
							.font(.caption.weight(.medium))
							.foregroundStyle(days == 0 ? Color.red : Color.secondary)
							.fixedSize()
					}
				} else {
					Text(account.team.summary)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
		}
		.padding(.vertical, 4)
	}
}

/// What Custom Install's sheet offers (#49, #155), as Sign Again With did
/// (#17): an imported certificate, or an Apple ID, which gets the app a
/// profile of its own.
enum SigningChoice: Identifiable {
	case certificate(StoredCertificate)
	case appleID(StoredAppleID)

	var id: UUID {
		switch self {
		case .certificate(let certificate): certificate.id
		case .appleID(let account): account.id
		}
	}

	var displayName: String {
		switch self {
		case .certificate(let certificate): certificate.displayName
		case .appleID(let account): account.displayName
		}
	}

	var attention: CertificateAttention? {
		switch self {
		case .certificate(let certificate): CertificateAttention(certificate)
		case .appleID(let account): CertificateAttention(account)
		}
	}

	/// "Development", "Free Apple ID".
	var kind: String {
		switch self {
		case .certificate(let certificate): certificate.profile.kind.title
		case .appleID(let account):
			switch account.team.isFree {
			case true?: "Free Apple ID"
			case false?: "Apple Developer Program"
			case nil: "Apple ID"
			}
		}
	}

	/// A free Apple ID, whose installs take one of its 10 App IDs a week.
	var isFreeAppleID: Bool {
		if case .appleID(let account) = self { return account.isFree }
		return false
	}

	/// "54 days left", the certificate's.
	var remainingText: String {
		switch self {
		case .certificate(let certificate): certificate.remainingText()
		case .appleID(let account): account.remainingText()
		}
	}

	/// Every certificate and Apple ID, as Settings lists them.
	@MainActor
	static func all(_ certificates: CertificatesModel) -> [SigningChoice] {
		certificates.certificates.map(SigningChoice.certificate) + certificates.appleIDs.map(SigningChoice.appleID)
	}
}
