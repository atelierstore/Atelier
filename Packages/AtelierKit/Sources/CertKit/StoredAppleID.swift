import Foundation

/// An Apple ID Atelier signs in with (#49), kept with the certificates
/// rather than in the app's database: the Apple ID, the team its calls use,
/// and the development certificate Atelier made for this iPhone. Its
/// password, the certificate's key and its .p12 stay on this iPhone, in the
/// Keychain and the store's folder, never in this record.
///
/// Each app gets its own 7-day profile from it when it's installed, rather
/// than the one profile an imported certificate comes with.
public struct StoredAppleID: Codable, Equatable, Identifiable, Sendable {
	public struct Team: Codable, Equatable, Sendable {
		public var id: String
		public var name: String?
		/// A free Apple ID's team, which Xcode calls a Personal Team; nil
		/// when Apple's answer didn't say.
		public var isFree: Bool?

		public init(id: String, name: String?, isFree: Bool?) {
			self.id = id
			self.name = name
			self.isFree = isFree
		}
	}

	public var id: UUID
	public var addedAt: Date
	/// As the user typed it, which Apple's sign-in reads in lower case.
	public var email: String
	public var team: Team
	/// The development certificate Atelier made on this iPhone, or found
	/// again from an earlier sign-in, its key being here, or the one the
	/// iPhone-only installer made and handed over (#152).
	public var certificate: SigningCertificate
	/// The name Apple lists the certificate's machine under: "Atelier", or
	/// "Atelier Installer" for the installer's.
	public var machineName: String
	/// The last revocation check (#5), nil until one ran.
	public var revocation: RevocationState?
	/// The profile each app installed with it last got, by the bundle ID
	/// it's installed as; nil until one is.
	public var profiles: [AppProfile]?
	/// What it allows, as Apple and this iPhone last said; nil until
	/// Atelier asked.
	public var limits: AppleIDLimits?

	public init(id: UUID = UUID(), addedAt: Date = .now, email: String, team: Team, certificate: SigningCertificate, machineName: String, revocation: RevocationState? = nil) {
		self.id = id
		self.addedAt = addedAt
		self.email = email
		self.team = team
		self.certificate = certificate
		self.machineName = machineName
		self.revocation = revocation
	}

	/// The ID the Apple ID `email` is kept under in the team `teamID`: the
	/// same at every sign-in, whatever the case it's typed in. A sign-in
	/// that stopped after Apple made the certificate, before it was saved,
	/// so finds the certificate's key again next time rather than having
	/// Apple make another. A name-based UUID (version 5's layout, from
	/// SHA-1).
	public static func id(email: String, teamID: String) -> UUID {
		let name = "atelier.apple-id:" + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + ":" + teamID
		var bytes = Array(SHA1.hash(Array(name.utf8)).prefix(16))
		bytes[6] = bytes[6] & 0x0F | 0x50
		bytes[8] = bytes[8] & 0x3F | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}

	/// What Atelier calls it: the Apple ID.
	public var displayName: String { email }

	/// Whether it's the same Apple ID and team, whatever the case it was
	/// typed in.
	public func isSame(email other: String, teamID: String) -> Bool {
		email.caseInsensitiveCompare(other.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame && team.id == teamID
	}

	/// The certificate's, as each app's profile lasts 7 days at most and is
	/// renewed every week.
	public var expiresAt: Date { certificate.notAfter }

	public var expiry: CertificateExpiry {
		CertificateExpiry(certificate: certificate.notAfter, profile: certificate.notAfter)
	}

	public var isRevoked: Bool { revocation?.isRevoked ?? false }
}
