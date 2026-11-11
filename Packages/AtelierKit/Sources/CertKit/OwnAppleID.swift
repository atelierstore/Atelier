import Foundation

/// Atelier itself as one of an Apple ID's apps (#152). A free Apple ID's
/// profile lasts 7 days, and Atelier installed with one, by the iPhone-only
/// installer or another tool, stops opening with the rest. Once the Apple ID
/// that installed it is signed in to Atelier, Atelier is one of its apps: it
/// gets a new profile with the others (`AppProfileRenewal`), first and
/// further ahead, and signs its own updates with it, for the App ID it runs
/// as. Atelier installed with an imported certificate stays as it was
/// (`OwnAppSigning`).
public enum OwnAppleID {
	/// What the Atelier that runs was installed with, as far as its own
	/// profile and the Apple IDs signed in to it tell.
	public enum Installed: Equatable, Sendable {
		/// One of this Apple ID's apps: the App ID iOS has for Atelier is its
		/// team's, whichever tool installed it.
		case appleID(UUID)
		/// A free Apple ID that isn't signed in to Atelier, of the team
		/// `teamID`. The profile in the build ends at `expires`.
		case freeAppleID(teamID: String, expires: Date)
		/// An imported certificate, or nothing Atelier can tell.
		case other
	}

	/// `applicationIdentifier` is the App ID iOS has for Atelier, from its
	/// entitlements, `bundleID` the one it runs as, and `profile` the one in
	/// its build. An Apple ID gives development profiles, so Atelier signed
	/// any other way is nobody's app, even with its team signed in.
	public static func installed(applicationIdentifier: String?, bundleID: String, profile: ProvisioningProfile?, accounts: [StoredAppleID]) -> Installed {
		guard let profile, profile.kind == .development else { return .other }
		let appID = applicationIdentifier ?? profile.applicationIdentifier
		let owners = accounts.filter { $0.team.id == profile.teamID && appID == "\($0.team.id).\(bundleID)" }
		// One whose certificate still signs, when two are in the same team.
		if let account = owners.first(where: { !AppProfileRenewal.needsSignIn($0) }) ?? owners.first {
			return .appleID(account.id)
		}
		return FreeAppleID.isFree(profile) ? .freeAppleID(teamID: profile.teamID, expires: profile.expirationDate) : .other
	}

	/// Atelier's own profile as its Apple ID keeps it, from the build that
	/// runs: `installed` is the profile in it, `signerSerial` the serial of
	/// the certificate it was signed with, and `noted` what the Apple ID has
	/// for it so far. The build's profile counts, unless Atelier put a later
	/// one on since without reinstalling, which `noted` then says.
	/// `appGroups` are the ones the build's entitlements ask for, which
	/// each new profile has to allow.
	public static func profile(bundleID: String, installed: ProvisioningProfile, signerSerial: String?, appGroups: [String] = [], noted: AppProfile?) -> AppProfile {
		let groups = appGroups.isEmpty ? nil : appGroups
		let fromBuild = AppProfile(bundleID: bundleID, uuid: installed.uuid, expires: installed.expirationDate, certificateSerial: signerSerial, appGroups: groups)
		guard var noted else { return fromBuild }
		let isSame = noted.uuid.map { $0.caseInsensitiveCompare(installed.uuid) == .orderedSame } ?? false
		let renewedSince = noted.renewedAt != nil && noted.expires >= installed.expirationDate
		guard isSame || renewedSince else { return fromBuild }
		// The build says what signed it and what it asks for, whatever was
		// noted.
		if let signerSerial { noted.certificateSerial = signerSerial }
		noted.appGroups = groups
		return noted
	}

	/// The profile iOS has for Atelier that ends last, among `installed`,
	/// misagent's, when that's later than `noted`: another tool may have put
	/// a new one on without reinstalling, as AltStore's refresh does, which
	/// the build can't tell.
	public static func later(than noted: AppProfile, applicationIdentifier: String, among installed: [ProvisioningProfile]) -> AppProfile? {
		let last = installed
			.filter { $0.applicationIdentifier == applicationIdentifier }
			.max { $0.expirationDate < $1.expirationDate }
		guard let last, last.expirationDate > noted.expires else { return nil }
		var later = noted
		later.uuid = last.uuid
		later.expires = last.expirationDate
		later.waitsUntil = nil
		return later
	}

	/// What Atelier's own update says about its App ID before it's asked of
	/// Apple, from what the Apple ID last kept of its limits.
	public enum AppIDUse: Equatable, Sendable {
		/// The team has it, so the update takes none of the week's.
		case again
		/// It ended, so Apple adds it again, taking one of the `left` this
		/// week.
		case new(left: Int)
		/// None are left this week, until `nextReturn`.
		case noneLeft(nextReturn: Date?)
		/// Not known: Apple doesn't count them, or wasn't asked yet.
		case unknown
	}

	public static func appIDUse(for bundleID: String, account: StoredAppleID, now: Date = .now) -> AppIDUse {
		guard account.isFree, let counts = account.limits?.appIDs, let entries = counts.entries else { return .unknown }
		let has = entries.contains { entry in
			entry.identifier.caseInsensitiveCompare(bundleID) == .orderedSame && (entry.expires.map { $0 > now } ?? true)
		}
		if has { return .again }
		guard let left = counts.left(now: now) else { return .unknown }
		return left > 0 ? .new(left: left) : .noneLeft(nextReturn: counts.nextReturn(now: now))
	}
}

/// The certificate an app was signed with, from its code signature (#152):
/// Atelier reads its own, as another tool's certificate signed it when
/// that tool installed it, and a new profile has to list that one for
/// Atelier to keep opening.
public enum CodeSigner {
	/// The certificates a code signature's CMS carries: the signer's, and
	/// Apple's above it.
	public static func certificates(inCMS data: Data) -> [SigningCertificate] {
		// ContentInfo ::= SEQUENCE { contentType, [0] EXPLICIT SignedData }
		// SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo,
		//   certificates [0] IMPLICIT SET OF Certificate OPTIONAL, ... }
		guard
			let contentInfo = try? ASN1Node.parse(data),
			contentInfo[0]?.objectIdentifier == "1.2.840.113549.1.7.2",
			let signedData = contentInfo[1]?[0],
			let certificates = signedData.children.first(where: { $0.tag == ASN1Node.contextSpecific(0) })
		else { return [] }
		return certificates.children.compactMap { try? SigningCertificate(der: Data($0.encoded)) }
	}

	/// The one that signed, among a signature's certificates: the one
	/// `profile` lists, as iOS only runs an app signed with one its profile
	/// lists; else the team's, which Apple's own above it aren't.
	public static func signer(inCMS data: Data, profile: ProvisioningProfile?) -> SigningCertificate? {
		let all = certificates(inCMS: data)
		if let profile, let listed = all.first(where: { profile.allows($0) }) { return listed }
		guard let teamID = profile?.teamID else { return nil }
		return all.first { $0.teamID == teamID }
	}
}
