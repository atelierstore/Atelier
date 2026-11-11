import Foundation

/// What Atelier knew of a certificate when it was deleted (#20): enough
/// for the apps signed with it to say it was revoked or when it runs out,
/// and which certificate and profile it was, so that importing the same
/// pair again gives those apps their certificate back (#126). Whether
/// Apple revokes it later can't be told any more.
public struct RetiredCertificate: Codable, Equatable, Sendable {
	public var name: String
	public var expiresAt: Date
	public var revoked: Bool
	/// The certificate's `fingerprint`. Nil for one deleted before #126.
	public var certificateFingerprint: String?
	/// The profile's UUID. Nil for one deleted before #126.
	public var profileUUID: String?
	/// When an install signed with its profile was first confirmed on this
	/// device (#45), which still holds once it's imported again.
	public var deviceConfirmedAt: Date?

	public init(_ certificate: StoredCertificate) {
		name = certificate.displayName
		expiresAt = certificate.expiresAt
		revoked = certificate.isRevoked
		certificateFingerprint = certificate.certificate.fingerprint
		profileUUID = certificate.profile.uuid
		deviceConfirmedAt = certificate.deviceConfirmedAt
	}

	/// Whether `certificate` with `profile` is the pair this was. Never for
	/// one deleted before #126, which didn't note it.
	public func isPair(_ certificate: SigningCertificate, _ profile: ProvisioningProfile) -> Bool {
		guard let certificateFingerprint, let profileUUID else { return false }
		return profileUUID == profile.uuid && certificateFingerprint == certificate.fingerprint
	}

	/// The one of `certificates` this was, imported again, for an app it
	/// signed for `applicationIdentifier` (nil when that wasn't noted) and
	/// installed at `installedAt`: the same pair.
	///
	/// One deleted before #126 didn't note its pair, so it's the one that
	/// runs out at the same second, signs for that App ID and was imported
	/// after the app was installed, as a pair can only be imported again
	/// once it's deleted. When several are, the one Atelier shows under its
	/// name, else the one whose certificate has that name. Nil when none
	/// is, or it can't be told which.
	public func reimported(among certificates: [StoredCertificate], signedFor applicationIdentifier: String?, at installedAt: Date) -> StoredCertificate? {
		if certificateFingerprint != nil {
			return certificates.first { isPair($0.certificate, $0.profile) }
		}
		let candidates = certificates.filter {
			$0.expiresAt == expiresAt && $0.addedAt > installedAt
				&& (applicationIdentifier == nil || $0.profile.applicationIdentifier == applicationIdentifier)
		}
		guard candidates.count > 1 else { return candidates.first }
		for named in [candidates.filter { $0.displayName == name }, candidates.filter { $0.originalName == name }] where !named.isEmpty {
			return named.count == 1 ? named[0] : nil
		}
		return nil
	}
}
