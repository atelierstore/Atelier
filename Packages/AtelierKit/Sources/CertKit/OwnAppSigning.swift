import Foundation

/// Which certificate Atelier signs itself with (#24). iOS only replaces an
/// app with a build signed for the App ID it was installed with (Apple's
/// TN2319), and Atelier can't delete itself to install one signed for
/// another: doing that with another tool deletes its sources, certificates
/// and Library. So Atelier signs itself only for its own App ID: with a
/// certificate whose profile is for it, or with a certificate the profile
/// Atelier was installed with lists, signing with that profile.
public enum OwnAppSigning {
	public struct Choice: Equatable, Sendable {
		public var certificateID: UUID
		/// Signs with the profile Atelier was installed with, which lists
		/// the certificate, rather than the certificate's own, which is for
		/// another App ID.
		public var usesInstalledProfile: Bool

		public init(certificateID: UUID, usesInstalledProfile: Bool) {
			self.certificateID = certificateID
			self.usesInstalledProfile = usesInstalledProfile
		}
	}

	/// The certificate to sign Atelier with, from `certificates` in the
	/// order the caller prefers them (the one Atelier was installed with,
	/// say, then the default): the first whose own profile is for
	/// `applicationIdentifier`, else, when `allowsInstalledProfile`, the
	/// first that `installedProfile`, the profile Atelier was installed
	/// with, lists while it's still valid. `isUsable` leaves out ones that
	/// can't sign, such as revoked or expired ones. Nil when none can sign
	/// for the App ID. With `applicationIdentifier` unknown, any usable
	/// certificate will do, with its own profile.
	public static func choose(
		from certificates: [StoredCertificate],
		applicationIdentifier: String?,
		installedProfile: ProvisioningProfile?,
		allowsInstalledProfile: Bool = true,
		now: Date = .now,
		isUsable: (StoredCertificate) -> Bool
	) -> Choice? {
		let usable = certificates.filter(isUsable)
		guard let applicationIdentifier else {
			return usable.first.map { Choice(certificateID: $0.id, usesInstalledProfile: false) }
		}
		if let own = usable.first(where: { $0.profile.applicationIdentifier == applicationIdentifier }) {
			return Choice(certificateID: own.id, usesInstalledProfile: false)
		}
		guard allowsInstalledProfile, let installedProfile,
		      installedProfile.applicationIdentifier == applicationIdentifier,
		      installedProfile.expirationDate > now,
		      let listed = usable.first(where: { installedProfile.allows($0.certificate) })
		else { return nil }
		return Choice(certificateID: listed.id, usesInstalledProfile: true)
	}

	/// Whether `certificate` can sign Atelier for `applicationIdentifier`,
	/// for Custom Install's certificates, and how: nil when it can't.
	public static func choice(
		for certificate: StoredCertificate,
		applicationIdentifier: String?,
		installedProfile: ProvisioningProfile?,
		now: Date = .now
	) -> Choice? {
		choose(from: [certificate], applicationIdentifier: applicationIdentifier, installedProfile: installedProfile, now: now) { _ in true }
	}

	/// The App ID without its team, as people read it in a profile's name:
	/// `app.otter4812.mango3307` for
	/// `S7GNTEAM42.app.otter4812.mango3307`.
	public static func bundleIDPart(of applicationIdentifier: String, teamID: String?) -> String {
		if let teamID, applicationIdentifier.hasPrefix(teamID + ".") {
			return String(applicationIdentifier.dropFirst(teamID.count + 1))
		}
		guard let dot = applicationIdentifier.firstIndex(of: "."),
		      applicationIdentifier[..<dot].count == 10,
		      applicationIdentifier[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber })
		else { return applicationIdentifier }
		return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
	}
}
