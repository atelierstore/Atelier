import Foundation

/// The development certificate the iPhone-only installer made with an Apple
/// ID to install Atelier (#152), its key, and the sign-in it made it with,
/// which the installer leaves in Atelier's container next to the pairing
/// file. A free Apple ID may only have two certificates, so signing in to
/// Atelier with the same Apple ID uses this one rather than having Apple
/// make another; and with the sign-in, Atelier signs in by itself when it
/// first opens.
///
/// The installer writes Library/Caches/Installer/certificate.plist, never
/// in a backup, and only for an Atelier whose Info.plist declares it: as
/// `SideloadHandOff`'s `SigningIdentity`, in its version 2
/// (`sideloadVersion`), or, for the installer's builds before that, as
/// `AtelierInstallerHandOff`, version 1 (`version`). It's an XML property
/// list: `teamID` and `privateKey` (PKCS#8 DER, RSA), with `machineName`,
/// `machineID`, `serialNumber` and `certificate` (DER) as Apple listed it;
/// and `appleID`, `udid`, `anisetteServer` and `anisetteState` (isideload's
/// `anisette_state` from that server). In version 1, `password`. In
/// version 2, which says its `version`, Apple's token in the password's
/// place (#182): `adsid`, `token`, `tokenDuration`, `tokenExpiry`,
/// `tokenReceived`, and `clientInfo` and `userAgent` when the sign-in sent
/// its own. Atelier moves it into its certificate storage as it opens, the
/// password or the token into the Keychain
/// (`CertificateStore.keepInstallerCertificate`), and finds the certificate
/// Apple lists by its key, whatever its machine name or serial.
public struct InstallerCertificate: Equatable, Sendable {
	/// The team the installer made it in: the Apple ID's own, for a free
	/// one.
	public var teamID: String
	/// The certificate's key, PKCS#8 DER.
	public var privateKey: Data
	/// The name Apple lists the certificate's machine under: "Atelier
	/// Installer".
	public var machineName: String?
	public var serialNumber: String?
	/// The certificate itself, when the installer said and it can be read.
	public var certificate: SigningCertificate?
	/// The sign-in the installer made it with, until Atelier has signed in
	/// with it once.
	public var signIn: SignIn?

	/// What Atelier signs in with by itself when it first opens, as the same
	/// machine to Apple as the installer was, so Apple doesn't ask for a
	/// code again.
	public struct SignIn: Equatable, Sendable {
		/// As typed into the installer.
		public var appleID: String
		/// The password, from the installer's version 1.
		public var password: String?
		/// Apple's token from the installer's sign-in, in the password's
		/// place, from its version 2 (#182).
		public var token: AppleIDToken?
		/// This iPhone's, which the installer registered it with.
		public var udid: String?
		/// The anisette server the installer's sign-in went through, as
		/// "https://ani.example.com".
		public var anisetteServer: String?
		/// isideload's `anisette_state` from that server: the machine Apple
		/// saw.
		public var anisetteState: Data?

		public init(appleID: String, password: String? = nil, token: AppleIDToken? = nil, udid: String? = nil, anisetteServer: String? = nil, anisetteState: Data? = nil) {
			self.appleID = appleID
			self.password = password
			self.token = token
			self.udid = udid
			self.anisetteServer = anisetteServer
			self.anisetteState = anisetteState
		}
	}

	public enum Problem: Error, Equatable {
		/// Not a property list with a dictionary in it.
		case unreadable
		/// Without `teamID` or `privateKey`, which it can't be used without.
		case missing(String)
	}

	/// The format the installer's builds before `SideloadHandOff` write,
	/// which Atelier's Info.plist declares as `AtelierInstallerHandOff`.
	public static let version = 1
	/// The format with Apple's token, which Atelier's Info.plist declares as
	/// `SideloadHandOff`'s `Version` (#182).
	public static let sideloadVersion = 2

	public init(teamID: String, privateKey: Data, machineName: String? = nil, serialNumber: String? = nil, certificate: SigningCertificate? = nil, signIn: SignIn? = nil) {
		self.teamID = teamID
		self.privateKey = privateKey
		self.machineName = machineName
		self.serialNumber = serialNumber
		self.certificate = certificate
		self.signIn = signIn
	}

	/// Reads the property list the installer writes, or the one Atelier
	/// keeps, which leaves the password and the token out: `password` and
	/// `token` are then the ones kept in the Keychain. Without an Apple ID,
	/// or without either a password or a token, there's no sign-in.
	public init(plist data: Data, password: String? = nil, token: AppleIDToken? = nil) throws {
		let dictionary = try Self.dictionary(data)
		guard let teamID = (dictionary["teamID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty else {
			throw Problem.missing("teamID")
		}
		guard let privateKey = dictionary["privateKey"] as? Data, !privateKey.isEmpty else {
			throw Problem.missing("privateKey")
		}
		var signIn: SignIn?
		let anisetteServer = Self.text(dictionary["anisetteServer"])
		let handedPassword = Self.text(dictionary[Self.passwordKey]) ?? password.flatMap { $0.isEmpty ? nil : $0 }
		let handedToken = Self.token(in: dictionary, server: anisetteServer) ?? token
		if let appleID = (dictionary["appleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !appleID.isEmpty,
		   handedPassword != nil || handedToken != nil {
			signIn = SignIn(
				appleID: appleID,
				password: handedPassword,
				token: handedToken,
				udid: Self.text(dictionary["udid"]),
				anisetteServer: anisetteServer,
				anisetteState: (dictionary["anisetteState"] as? Data).flatMap { $0.isEmpty ? nil : $0 }
			)
		}
		self.init(
			teamID: teamID,
			privateKey: privateKey,
			machineName: dictionary["machineName"] as? String,
			serialNumber: dictionary["serialNumber"] as? String,
			certificate: (dictionary["certificate"] as? Data).flatMap { try? SigningCertificate(der: $0) },
			signIn: signIn
		)
	}

	/// Where the installer leaves it: Installer/certificate.plist in the
	/// app's Caches folder, `caches`.
	public static func handoffURL(in caches: URL) -> URL {
		caches.appendingPathComponent("Installer", isDirectory: true).appendingPathComponent(fileName)
	}

	static let fileName = "certificate.plist"

	// MARK: The property list

	static let passwordKey = "password"
	/// Apple's token in version 2, which the Keychain keeps in place of the
	/// file.
	static let tokenKeys = ["adsid", "token", "tokenDuration", "tokenExpiry", "tokenReceived", "clientInfo", "userAgent"]
	/// What goes with the sign-in, which Atelier keeps only until it has
	/// signed in with it once.
	static let signInKeys = ["appleID", passwordKey, "udid", "anisetteServer", "anisetteState"] + tokenKeys

	/// A string that says something.
	private static func text(_ value: Any?) -> String? {
		(value as? String).flatMap { $0.isEmpty ? nil : $0 }
	}

	/// Apple's token in version 2, through the anisette server `server`,
	/// whose machine Apple knows it by. Nil without the account's adsid,
	/// the token, or that server.
	static func token(in dictionary: [String: Any], server: String?) -> AppleIDToken? {
		guard let server, let adsid = text(dictionary["adsid"]), let token = text(dictionary["token"]) else { return nil }
		let number = { (key: String) in (dictionary[key] as? NSNumber)?.uint64Value ?? 0 }
		return AppleIDToken(
			adsid: adsid,
			token: token,
			duration: number("tokenDuration"),
			expiry: number("tokenExpiry"),
			receivedAt: dictionary["tokenReceived"] as? Date ?? .now,
			server: server,
			clientInfo: text(dictionary["clientInfo"]),
			userAgent: text(dictionary["userAgent"])
		)
	}

	static func dictionary(_ data: Data) throws -> [String: Any] {
		guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
			throw Problem.unreadable
		}
		return dictionary
	}

	/// `data`, the installer's property list, without `keys`.
	static func plist(_ data: Data, leavingOut keys: [String]) throws -> Data {
		var dictionary = try dictionary(data)
		for key in keys { dictionary[key] = nil }
		return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
	}
}
