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
/// in a backup, and only for an Atelier whose Info.plist has
/// `AtelierInstallerHandOff`, the format's version (`version`). It's an XML
/// property list: `teamID` and `privateKey` (PKCS#8 DER, RSA), with
/// `machineName`, `machineID`, `serialNumber` and `certificate` (DER) as
/// Apple listed it; and `appleID`, `password`, `udid`, `anisetteServer` and
/// `anisetteState` (isideload's `anisette_state` from that server). Atelier
/// moves it into its certificate storage as it opens, the password into
/// the Keychain (`CertificateStore.keepInstallerCertificate`), and finds the
/// certificate Apple lists by its key, whatever its machine name or serial.
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
		public var password: String
		/// This iPhone's, which the installer registered it with.
		public var udid: String?
		/// The anisette server the installer's sign-in went through, as
		/// "https://ani.example.com".
		public var anisetteServer: String?
		/// isideload's `anisette_state` from that server: the machine Apple
		/// saw.
		public var anisetteState: Data?

		public init(appleID: String, password: String, udid: String? = nil, anisetteServer: String? = nil, anisetteState: Data? = nil) {
			self.appleID = appleID
			self.password = password
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

	/// The format the installer writes, which Atelier's Info.plist declares
	/// as `AtelierInstallerHandOff`.
	public static let version = 1

	public init(teamID: String, privateKey: Data, machineName: String? = nil, serialNumber: String? = nil, certificate: SigningCertificate? = nil, signIn: SignIn? = nil) {
		self.teamID = teamID
		self.privateKey = privateKey
		self.machineName = machineName
		self.serialNumber = serialNumber
		self.certificate = certificate
		self.signIn = signIn
	}

	/// Reads the property list the installer writes, or the one Atelier
	/// keeps, which leaves the password out: `password` is then the one
	/// kept in the Keychain. Without an Apple ID or a password, there's no
	/// sign-in.
	public init(plist data: Data, password: String? = nil) throws {
		let dictionary = try Self.dictionary(data)
		guard let teamID = (dictionary["teamID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty else {
			throw Problem.missing("teamID")
		}
		guard let privateKey = dictionary["privateKey"] as? Data, !privateKey.isEmpty else {
			throw Problem.missing("privateKey")
		}
		var signIn: SignIn?
		if let appleID = (dictionary["appleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !appleID.isEmpty,
		   let password = (dictionary[Self.passwordKey] as? String) ?? password, !password.isEmpty {
			signIn = SignIn(
				appleID: appleID,
				password: password,
				udid: (dictionary["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
				anisetteServer: (dictionary["anisetteServer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
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
	/// What goes with the sign-in, which Atelier keeps only until it has
	/// signed in with it once.
	static let signInKeys = ["appleID", passwordKey, "udid", "anisetteServer", "anisetteState"]

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
