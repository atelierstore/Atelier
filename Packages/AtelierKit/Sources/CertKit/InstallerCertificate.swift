import Foundation

/// The development certificate the iPhone-only installer made with an Apple
/// ID to install Atelier (#152), and its key, which the installer leaves in
/// Atelier's container next to the pairing file. A free Apple ID may only
/// have two, so signing in to Atelier with the same Apple ID uses this one
/// rather than having Apple make another.
///
/// The installer writes Application Support/Installer/certificate.plist, an
/// XML property list: `teamID` and `privateKey` (PKCS#8 DER, RSA), with
/// `machineName`, `machineID`, `serialNumber` and `certificate` (DER) as
/// Apple listed it. Atelier moves it into its certificate storage as it
/// opens (`CertificateStore.keepInstallerCertificate`), and finds the
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

	public enum Problem: Error, Equatable {
		/// Not a property list with a dictionary in it.
		case unreadable
		/// Without `teamID` or `privateKey`, which it can't be used without.
		case missing(String)
	}

	public init(teamID: String, privateKey: Data, machineName: String? = nil, serialNumber: String? = nil, certificate: SigningCertificate? = nil) {
		self.teamID = teamID
		self.privateKey = privateKey
		self.machineName = machineName
		self.serialNumber = serialNumber
		self.certificate = certificate
	}

	/// Reads the property list the installer writes.
	public init(plist data: Data) throws {
		guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
			throw Problem.unreadable
		}
		guard let teamID = (dictionary["teamID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty else {
			throw Problem.missing("teamID")
		}
		guard let privateKey = dictionary["privateKey"] as? Data, !privateKey.isEmpty else {
			throw Problem.missing("privateKey")
		}
		self.init(
			teamID: teamID,
			privateKey: privateKey,
			machineName: dictionary["machineName"] as? String,
			serialNumber: dictionary["serialNumber"] as? String,
			certificate: (dictionary["certificate"] as? Data).flatMap { try? SigningCertificate(der: $0) }
		)
	}

	/// Where the installer leaves it: Installer/certificate.plist in the
	/// app's Application Support folder, `support`.
	public static func handoffURL(in support: URL) -> URL {
		support.appendingPathComponent("Installer", isDirectory: true).appendingPathComponent(fileName)
	}

	static let fileName = "certificate.plist"
}
