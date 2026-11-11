import Foundation

/// What Atelier shows about a signing certificate, read from its DER
/// encoding. Apple's certificates put the team ID in OU and the team name
/// in O; the common name reads like "Apple Distribution: Name (TEAMID)".
public struct SigningCertificate: Codable, Equatable, Sendable {
	public var commonName: String
	public var teamID: String?
	public var teamName: String?
	/// Hex, uppercase, without leading zero bytes.
	public var serialNumber: String
	public var notBefore: Date
	public var notAfter: Date
	public var der: Data

	public enum Error: Swift.Error, Equatable {
		case invalid
	}

	public init(der: Data) throws {
		guard let certificate = try? X509Certificate(der: der) else { throw Error.invalid }
		let subject = X509Certificate.attributes(of: certificate.subject)
		var serial = certificate.serial[...]
		while serial.count > 1, serial.first == 0 { serial = serial.dropFirst() }

		self.commonName = subject["2.5.4.3"] ?? "Unnamed certificate"
		self.teamID = subject["2.5.4.11"]
		self.teamName = subject["2.5.4.10"]
		self.serialNumber = serial.map { String(format: "%02X", $0) }.joined()
		self.notBefore = certificate.notBefore
		self.notAfter = certificate.notAfter
		self.der = der
	}

	/// The SHA-1 of its DER, uppercase hex, as Keychain Access shows it:
	/// which certificate it is, whatever it's named (#126).
	public var fingerprint: String {
		SHA1.hash(der).map { String(format: "%02X", $0) }.joined()
	}
}
