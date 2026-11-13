import CertKit
import SwiftUI

// How certificates look in Settings › Installs › Certificates: a tile
// coloured by the profile's kind, a bar for how much of its validity is left,
// and a status pill. The colours carry the same meaning as
// CertificateAttention (#5).

extension ProvisioningProfile.Kind {
	var symbol: String {
		switch self {
		case .development: "hammer.fill"
		case .adHoc: "iphone.gen3"
		case .enterprise: "building.2.fill"
		case .appStore: "bag.fill"
		}
	}

	var color: Color {
		switch self {
		case .development: .blue
		case .adHoc: .purple
		case .enterprise: .teal
		case .appStore: .gray
		}
	}
}

/// A certificate's overall state, for its pill and its bar's colour.
enum CertificateHealth: Equatable {
	case valid
	case expiring(daysLeft: Int)
	case expired
	case revoked

	init(_ certificate: StoredCertificate, now: Date = .now) {
		self.init(CertificateAttention(certificate, now: now))
	}

	/// An Apple ID's certificate (#49).
	init(_ account: StoredAppleID, now: Date = .now) {
		self.init(CertificateAttention(account, now: now))
	}

	private init(_ attention: CertificateAttention?) {
		switch attention {
		case .revoked: self = .revoked
		case .expired: self = .expired
		case .expiring(let days): self = .expiring(daysLeft: days)
		case nil: self = .valid
		}
	}

	var title: String {
		switch self {
		case .valid: "Valid"
		case .expiring: "Expiring soon"
		case .expired: "Expired"
		case .revoked: "Revoked"
		}
	}

	var symbol: String {
		switch self {
		case .valid: "checkmark.seal.fill"
		case .expiring: "exclamationmark.triangle.fill"
		case .expired: "clock.badge.xmark"
		case .revoked: "xmark.seal.fill"
		}
	}

	var color: Color {
		switch self {
		case .valid: .green
		case .expiring: .orange
		case .expired, .revoked: .red
		}
	}
}

/// Under Settings › Installs › Certificates, once the Settings tab has a
/// badge: the worst of what it counts by name, then how many others, on
/// one line, such as "side@alxp.gr is revoked, and 2 other issues"
/// (13 Nov 2026). Only the name is shortened, so the count always shows.
struct CertificatesAttentionLine: View {
	/// Worst first, as `CertificatesModel.needingAttention` gives them.
	let attention: [CertificatesModel.Attention]

	var body: some View {
		if let first = attention.first {
			HStack(spacing: 4) {
				Image(systemName: first.health.symbol)
				HStack(spacing: 0) {
					Text(first.name)
					Text(" " + Self.rest(of: attention))
						.fixedSize()
				}
			}
			.font(.footnote.weight(.medium))
			.foregroundStyle(first.health.color)
			.lineLimit(1)
			.accessibilityElement(children: .combine)
		}
	}

	/// What follows the first one's name: what's wrong with it, and how
	/// many others there are.
	static func rest(of attention: [CertificatesModel.Attention]) -> String {
		let what = switch attention.first?.health {
		case .revoked?: "is revoked"
		case .expired?: "has expired"
		case .expiring(let days)?: days == 1 ? "expires within a day" : "expires in \(days) days"
		case .valid?, nil: ""
		}
		let others = attention.count - 1
		switch others {
		case 0: return what
		case 1: return "\(what), and 1 other issue"
		default: return "\(what), and \(others) other issues"
		}
	}
}

extension StoredCertificate {
	/// How much of its validity is left, from 1 just after it was issued (or
	/// the profile was made, if later) to 0 when it runs out.
	func remainingFraction(now: Date = .now) -> Double {
		let start = max(certificate.notBefore, profile.creationDate ?? certificate.notBefore)
		let total = expiresAt.timeIntervalSince(start)
		guard total > 0 else { return 0 }
		return min(max(expiresAt.timeIntervalSince(now) / total, 0), 1)
	}

	/// "123 days left", "Less than a day left", "Expired".
	func remainingText(now: Date = .now) -> String {
		let days = expiry.daysLeft(now: now)
		switch days {
		case 0: return "Expired"
		case 1: return "Less than a day left"
		default: return "\(days) days left"
		}
	}
}

extension StoredAppleID {
	/// How much of its certificate's year is left, from 1 when Apple made
	/// it to 0 when it runs out.
	func remainingFraction(now: Date = .now) -> Double {
		let total = expiresAt.timeIntervalSince(certificate.notBefore)
		guard total > 0 else { return 0 }
		return min(max(expiresAt.timeIntervalSince(now) / total, 0), 1)
	}

	/// "365 days left", "Less than a day left", "Expired".
	func remainingText(now: Date = .now) -> String {
		switch expiry.daysLeft(now: now) {
		case 0: "Expired"
		case 1: "Less than a day left"
		case let days: "\(days) days left"
		}
	}
}

/// The rounded square at the start of a certificate's row.
struct CertificateTile: View {
	let certificate: StoredCertificate
	var size: CGFloat = 44

	var body: some View {
		let color = certificate.isRevoked ? Color.red : certificate.profile.kind.color
		RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
			.fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .topLeading, endPoint: .bottomTrailing))
			.frame(width: size, height: size)
			.overlay {
				Image(systemName: certificate.isRevoked ? "xmark.seal.fill" : certificate.profile.kind.symbol)
					.font(.system(size: size * 0.45, weight: .semibold))
					.foregroundStyle(.white)
			}
			.shadow(color: color.opacity(0.3), radius: size * 0.08, y: size * 0.04)
			.accessibilityHidden(true)
	}
}

/// A thin bar for how much validity is left.
struct ValidityBar: View {
	let fraction: Double
	let color: Color
	var height: CGFloat = 6

	var body: some View {
		GeometryReader { proxy in
			ZStack(alignment: .leading) {
				Capsule().fill(color.opacity(0.15))
				Capsule()
					.fill(color.gradient)
					.frame(width: max(height, proxy.size.width * fraction))
			}
		}
		.frame(height: height)
		.accessibilityHidden(true)
	}
}

/// A coloured capsule with an icon and a word.
struct StatusPill: View {
	let title: String
	let symbol: String
	let color: Color

	var body: some View {
		Label(title, systemImage: symbol)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(color.opacity(0.15), in: Capsule())
			.foregroundStyle(color)
	}
}

/// The top of a certificate's details: who it's for, its state and how long
/// it has left, and whether it's in use, or a button to use it. As an Apple
/// ID's page has it (3 Nov 2026): a pill only while it isn't valid,
/// the bar saying how long it has left, and the green In use for installs.
struct CertificateHeader: View {
	let certificate: StoredCertificate
	let isDefault: Bool
	/// Makes the name a button that renames the certificate.
	var rename: (() -> Void)? = nil
	/// Use for Installs, under the name while it isn't in use.
	var use: (() -> Void)? = nil

	var body: some View {
		let health = CertificateHealth(certificate)
		VStack(spacing: 14) {
			CertificateTile(certificate: certificate, size: 72)
			VStack(spacing: 4) {
				if let rename {
					Button(action: rename) {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Text(certificate.displayName)
								.foregroundStyle(.primary)
							Image(systemName: "pencil")
								.font(.subheadline)
						}
						.font(.title3.weight(.semibold))
						.multilineTextAlignment(.center)
					}
					.buttonStyle(.borderless)
					.accessibilityHint("Renames the certificate")
				} else {
					Text(certificate.displayName)
						.font(.title3.weight(.semibold))
						.multilineTextAlignment(.center)
				}
				Text([certificate.profile.kind.title, certificate.certificate.teamName].compactMap { $0 }.joined(separator: " · "))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			if health != .valid || isDefault {
				HStack(spacing: 6) {
					if health != .valid {
						StatusPill(title: health.title, symbol: health.symbol, color: health.color)
					}
					if isDefault {
						StatusPill(title: "In use for installs", symbol: "checkmark", color: .green)
					}
				}
			}
			if !isDefault, let use {
				Button("Use for Installs", action: use)
					.buttonStyle(.bordered)
					.controlSize(.small)
			}
			if health != .revoked {
				VStack(spacing: 6) {
					ValidityBar(fraction: certificate.remainingFraction(), color: health.color, height: 8)
					HStack {
						Text(certificate.remainingText())
							.fontWeight(.semibold)
							.foregroundStyle(health.color)
						Spacer()
						Text(certificate.expiresAt, format: .dateTime.day().month().year())
							.foregroundStyle(.secondary)
					}
					.font(.footnote)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 8)
	}
}
