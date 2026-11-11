import Foundation

/// When an app installed with an Apple ID gets a new profile, and how (#49).
/// A free Apple ID's profile lasts 7 days, so Atelier puts a new one on
/// through misagent a little before it ends, without reinstalling: iOS goes
/// by the profile installed on the iPhone, not the one in the app.
public enum AppProfileRenewal {
	/// How long before a free Apple ID's profile ends Atelier renews it:
	/// a day to spare when LocalDevVPN is off the first time it tries.
	public static let freeLead: TimeInterval = 2 * 86_400
	/// The same for a paid team's, whose profiles last a year.
	public static let paidLead: TimeInterval = 14 * 86_400
	/// How long Apple's profiles last.
	static let freeLength: TimeInterval = 7 * 86_400
	static let paidLength: TimeInterval = 365 * 86_400

	/// When Atelier renews `profile` of an Apple ID that's free or not.
	public static func date(toRenew profile: AppProfile, isFree: Bool) -> Date {
		profile.expires.addingTimeInterval(-(isFree ? freeLead : paidLead))
	}

	/// Whether it's time to renew it, unless it waits for its App ID to end.
	public static func isDue(_ profile: AppProfile, isFree: Bool, now: Date = .now) -> Bool {
		now >= date(toRenew: profile, isFree: isFree) && profile.waitsUntil.map { now >= $0 } ?? true
	}

	/// Whether a new profile ending at `expires` gives the app more time
	/// than `profile`: an hour at least.
	public static func extends(_ profile: AppProfile, to expires: Date) -> Bool {
		expires > profile.expires.addingTimeInterval(3600)
	}

	/// The serial of the certificate the app with `profile` was signed
	/// with: as noted, or for one noted before Atelier kept it, the Apple
	/// ID's certificate when the profile came after it, as each install
	/// signs with the certificate the Apple ID has then. Nil when it's not
	/// known, as for a renewed profile, which came long after the app was
	/// signed.
	public static func signingSerial(of profile: AppProfile, account: StoredAppleID) -> String? {
		if let serial = profile.certificateSerial { return serial }
		guard profile.renewedAt == nil else { return nil }
		let issued = profile.expires.addingTimeInterval(-(account.isFree ? freeLength : paidLength))
		// An hour's slack for Apple's and the iPhone's clocks.
		return issued >= account.certificate.notBefore.addingTimeInterval(-3600) ? account.certificate.serialNumber : nil
	}

	/// What renewing an app takes.
	public enum Way: Equatable, Sendable {
		/// A new profile, put on without reinstalling: it lists the
		/// certificate the app was signed with.
		case newProfile
		/// Signing the app again with the Apple ID's certificate and
		/// reinstalling it, keeping its data: the certificate it was signed
		/// with is gone, so no new profile lets it open.
		case signAgain
		/// Signing in with the Apple ID again first: Apple revoked its
		/// certificate, or it ended, so Apple gives no profile for it.
		case signInAgain
	}

	/// Whether the Apple ID has to sign in again before any of its apps
	/// renew: its certificate was revoked or ended.
	public static func needsSignIn(_ account: StoredAppleID, now: Date = .now) -> Bool {
		account.isRevoked || account.certificate.notAfter <= now
	}

	/// How the app with `profile` renews, now that Apple gave `new`. When
	/// the certificate it was signed with isn't known, the profile it has on
	/// the iPhone (among `installed`, by UUID) tells: a new one listing each
	/// certificate that one does lists the app's.
	public static func way(for profile: AppProfile, account: StoredAppleID, new: ProvisioningProfile, installed: [ProvisioningProfile] = [], now: Date = .now) -> Way {
		if needsSignIn(account, now: now) { return .signInAgain }
		let listed = new.developerCertificates.compactMap { try? SigningCertificate(der: $0) }.filter { $0.notAfter > now }
		if let serial = signingSerial(of: profile, account: account) {
			return listed.contains { $0.serialNumber == serial } ? .newProfile : .signAgain
		}
		guard let uuid = profile.uuid, let old = installed.first(where: { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }),
			!old.developerCertificates.isEmpty
		else { return .signAgain }
		let serials = Set(listed.map(\.serialNumber))
		let olds = old.developerCertificates.compactMap { try? SigningCertificate(der: $0) }
		return olds.count == old.developerCertificates.count && olds.allSatisfy { serials.contains($0.serialNumber) } ? .newProfile : .signAgain
	}

	/// The App Groups the app with `profile` was signed with that a new
	/// profile with `entitlements` (`ProvisioningProfile.entitlements(in:)`)
	/// doesn't allow: none, or the app wouldn't open with it (#49).
	public static func missingGroups(of profile: AppProfile, allowedBy entitlements: [String: Any]) -> [String] {
		let allowed = entitlements["com.apple.security.application-groups"] as? [String] ?? []
		return (profile.appGroups ?? []).filter { group in !allowed.contains { $0.caseInsensitiveCompare(group) == .orderedSame } }
	}

	/// The profiles among `installed` that `new` takes the place of: the
	/// others for its App ID that end no later, which iOS would keep
	/// otherwise.
	public static func replaced(by new: ProvisioningProfile, among installed: [ProvisioningProfile]) -> [String] {
		installed
			.filter { $0.applicationIdentifier == new.applicationIdentifier && $0.uuid != new.uuid && $0.expirationDate <= new.expirationDate }
			.map(\.uuid)
	}
}

extension StoredAppleID {
	/// The profiles of its apps that are due to be renewed by `now`, the one
	/// that ends soonest first: those ending within the lead, and those
	/// signed with a certificate it no longer has, as after it signed in
	/// again once Apple revoked the one before, unless they were renewed
	/// since.
	public func profilesToRenew(now: Date = .now) -> [AppProfile] {
		(profiles ?? [])
			.filter { AppProfileRenewal.isDue($0, isFree: isFree, now: now) || isSignedWithAnother($0) }
			.sorted { $0.expires < $1.expires }
	}

	/// Whether the app with `profile` was signed with another certificate
	/// than the one it has now, and not renewed since that one was made.
	public func isSignedWithAnother(_ profile: AppProfile) -> Bool {
		guard let serial = profile.certificateSerial, serial != certificate.serialNumber else { return false }
		return (profile.renewedAt ?? .distantPast) < certificate.notBefore
	}

	/// The app's profile once Apple gave a new one, until `expires`, put on
	/// at `now`: the certificate and App Groups it was signed with stay the
	/// same. When it
	/// ends no later than the one before, Atelier waits until `appIDEnds`
	/// to renew it by itself again, rather than ask Apple over and over.
	public func renewed(_ bundleID: String, uuid: String?, expires: Date, appIDEnds: Date? = nil, at now: Date = .now) -> AppProfile {
		let old = profile(for: bundleID)
		let serial = old.flatMap { AppProfileRenewal.signingSerial(of: $0, account: self) }
		let extended = old.map { AppProfileRenewal.extends($0, to: expires) } ?? true
		return AppProfile(bundleID: bundleID, uuid: uuid, expires: expires, certificateSerial: serial, renewedAt: now, waitsUntil: extended ? nil : appIDEnds ?? expires, appGroups: old?.appGroups)
	}
}
