import Foundation

/// The certificate a copy of Atelier comes with (#113): the .p12 it's
/// signed with, its profile and password, the name the certificate has in
/// the Atelier that installed the copy, and this iPhone's UDID when that
/// Atelier knows it. Custom Install's Include Certificate writes it into the
/// copy's app before signing, next to its Info.plist, where the signature
/// seals it with the rest, and the copy imports it when it next opens,
/// however it's opened, so it can install apps and update itself from the
/// start (#155). Only the copy can read its app's files, and backups
/// leave them out. It stays there until the copy is updated or installed
/// again, as iOS doesn't let an app change its own files.
public struct PackagedCertificate: Codable, Equatable, Sendable {
	/// Its file, next to the app's Info.plist.
	public static let fileName = "AtelierCertificate.plist"

	public var p12: Data
	public var profile: Data
	public var password: String
	/// The name the user gave the certificate in the Atelier that installed
	/// the copy; nil keeps the certificate's own.
	public var name: String?
	/// This iPhone's UDID, which the Atelier that installed the copy read
	/// during its setup; nil when it hadn't. The copy notes it as its own,
	/// so it can check that each profile lists this iPhone without being
	/// set up first.
	public var udid: String?
	/// New for each copy it's put in, so the file is too: a copy installed
	/// again with the same certificate imports it again, also once it was
	/// deleted there.
	public var id: UUID

	public init(p12: Data, profile: Data, password: String, name: String? = nil, udid: String? = nil, id: UUID = UUID()) {
		self.p12 = p12
		self.profile = profile
		self.password = password
		self.name = name
		self.udid = udid
		self.id = id
	}

	public enum Problem: Error, Equatable, CustomStringConvertible {
		/// The file isn't one, or has no .p12 or profile in it.
		case unreadable
		/// The profile the app was installed with doesn't list it: it isn't
		/// the certificate the app is signed with.
		case notSignedWithIt

		public var description: String {
			switch self {
			case .unreadable: "The certificate this copy came with can't be read."
			case .notSignedWithIt: "The certificate this copy came with isn't the one it's signed with."
			}
		}
	}

	/// The file's contents: a binary property list.
	public func encoded() throws -> Data {
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		return try encoder.encode(self)
	}

	/// What the file holds.
	public init(file data: Data) throws {
		let decoded: PackagedCertificate
		do {
			decoded = try PropertyListDecoder().decode(PackagedCertificate.self, from: data)
		} catch {
			throw Problem.unreadable
		}
		guard !decoded.p12.isEmpty, !decoded.profile.isEmpty else { throw Problem.unreadable }
		let name = decoded.name?.trimmingCharacters(in: .whitespacesAndNewlines)
		self.init(
			p12: decoded.p12, profile: decoded.profile, password: decoded.password,
			name: name?.isEmpty == false ? name : nil, udid: decoded.udid.flatMap(Self.checkedUDID), id: decoded.id
		)
	}

	/// `text` as a UDID: hex digits, with a hyphen in newer iPhones' UDIDs.
	/// Nil for anything else, and the certificate still comes in without it.
	private static func checkedUDID(_ text: String) -> String? {
		let udid = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard (20...64).contains(udid.count), udid.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }) else { return nil }
		return udid
	}

	/// The .p12 and profile, as Import Certificate takes them, named after
	/// the certificate.
	public var files: CertificateFiles {
		let base = (name ?? "Certificate").replacingOccurrences(of: "/", with: "-")
		return CertificateFiles(
			p12: CertificateFiles.File(name: "\(base).p12", data: p12),
			profile: CertificateFiles.File(name: "\(base).mobileprovision", data: profile)
		)
	}

	/// Checks it as Import Certificate does, and that `installedProfile`,
	/// the profile the app it came in was installed with, lists it: that
	/// it's the certificate the app is signed with, as Custom Install… puts
	/// in. Throws otherwise, as for an IPA that brought another one with it.
	public func validated(
		installedWith installedProfile: ProvisioningProfile?,
		openP12: (Data, String) throws -> Data = PKCS12.certificate
	) throws -> ValidatedCertificate {
		let validated = try CertificateImporter.validate(files, password: password, openP12: openP12)
		guard let installedProfile, installedProfile.allows(validated.certificate) else { throw Problem.notSignedWithIt }
		return validated
	}

	/// `udid`, when it can be this iPhone's: `installedProfile`, the
	/// profile the app it came in was installed with, lists it, or is an
	/// enterprise one, which lists no devices. Nil otherwise, as for the
	/// UDID of an iPhone a backup came from.
	public func deviceUDID(installedWith installedProfile: ProvisioningProfile?) -> String? {
		guard let udid, let installedProfile else { return nil }
		switch installedProfile.check(deviceUDID: udid) {
		case .included, .anyDevice: return udid
		case .notIncluded, .unknown, .noDevices: return nil
		}
	}
}
