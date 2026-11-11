import Foundation
import InstallKit

public enum CertificateImportError: Swift.Error, Equatable, CustomStringConvertible {
	case wrongPassword
	case wrongPasswordOrUnsupportedP12
	case unreadableP12
	case noIdentityInP12
	case p12ImportFailed(Int)
	case notAProfile(String)
	case profileMissing(field: String)
	case invalidCertificate
	case unsupportedFile(String)
	case unreadableZip(String)
	case nothingInZip(String)
	case severalInZip(String, kind: String)
	case missingP12
	case missingProfile
	case mismatch(certificate: String, profile: String)
	case alreadyImported(String)
	case storageFailed(String)

	public var description: String {
		switch self {
		case .wrongPassword:
			"The password is wrong."
		case .wrongPasswordOrUnsupportedP12:
			"The password is wrong, or the .p12 is encrypted in a way iOS can't read. If the password is right, export the .p12 again with legacy encryption (openssl pkcs12 -legacy)."
		case .unreadableP12:
			"This .p12 file can't be read. It may be damaged, or not a .p12 at all."
		case .noIdentityInP12:
			"This .p12 has no certificate with its private key, so it can't sign."
		case .p12ImportFailed:
			"This .p12 can't be opened. It may be damaged; get it from your provider again."
		case .notAProfile(let name):
			"\(name) isn't a provisioning profile."
		case .profileMissing:
			"This profile is incomplete, so Atelier can't use it. Get it from your provider again."
		case .invalidCertificate:
			"The certificate in the .p12 can't be read."
		case .unsupportedFile(let name):
			"\(name) isn't a .p12, a .mobileprovision or a ZIP holding them."
		case .unreadableZip(let name):
			"\(name) can't be opened as a ZIP."
		case .nothingInZip(let name):
			"\(name) holds no .p12 or .mobileprovision."
		case .severalInZip(let name, let kind):
			"\(name) holds more than one \(kind). Pick the files you want one by one instead."
		case .missingP12:
			"Add the certificate (.p12)."
		case .missingProfile:
			"Add the provisioning profile (.mobileprovision)."
		case .mismatch(let certificate, let profile):
			"The profile “\(profile)” wasn't made for the certificate “\(certificate)”. Pick the profile that goes with this certificate."
		case .alreadyImported(let name):
			"“\(name)” is already imported with this profile."
		case .storageFailed(let why):
			"Atelier couldn't save the certificate: \(why)"
		}
	}
}

/// The two files an import needs, gathered from the Files picker, the share
/// sheet or a ZIP. Each new file replaces the one of its kind.
public struct CertificateFiles: Equatable, Sendable {
	public struct File: Equatable, Sendable {
		public var name: String
		public var data: Data

		public init(name: String, data: Data) {
			self.name = name
			self.data = data
		}
	}

	public var p12: File?
	public var profile: File?

	public init(p12: File? = nil, profile: File? = nil) {
		self.p12 = p12
		self.profile = profile
	}

	public var isComplete: Bool { p12 != nil && profile != nil }

	static let p12Extensions: Set = ["p12", "pfx"]
	static let profileExtensions: Set = ["mobileprovision", "provisionprofile"]

	/// Adds a file by its name and contents. A ZIP adds what it holds.
	public mutating func add(name: String, data: Data) throws {
		let ext = (name as NSString).pathExtension.lowercased()
		if Self.p12Extensions.contains(ext) {
			p12 = File(name: name, data: data)
		} else if Self.profileExtensions.contains(ext) {
			profile = File(name: name, data: data)
		} else if ext == "zip" || data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
			try addZip(name: name, data: data)
		} else if (try? ProvisioningProfile(data: data)) != nil {
			profile = File(name: name, data: data)
		} else {
			throw CertificateImportError.unsupportedFile(name)
		}
	}

	private mutating func addZip(name: String, data: Data) throws {
		let entries: [(path: String, data: Data)]
		do {
			entries = try ZipReader(data: data).entries { path in
				let parts = path.split(separator: "/")
				// Skip macOS resource forks and other hidden files.
				return !parts.contains("__MACOSX") && !(parts.last?.hasPrefix(".") ?? true)
			}
		} catch {
			throw CertificateImportError.unreadableZip(name)
		}
		func files(_ extensions: Set<String>) -> [File] {
			entries
				.filter { extensions.contains(($0.path as NSString).pathExtension.lowercased()) }
				.map { File(name: ($0.path as NSString).lastPathComponent, data: $0.data) }
		}
		let p12s = files(Self.p12Extensions)
		let profiles = files(Self.profileExtensions)
		if p12s.count > 1 { throw CertificateImportError.severalInZip(name, kind: ".p12") }
		if profiles.count > 1 { throw CertificateImportError.severalInZip(name, kind: ".mobileprovision") }
		if p12s.isEmpty, profiles.isEmpty { throw CertificateImportError.nothingInZip(name) }
		if let file = p12s.first { p12 = file }
		if let file = profiles.first { profile = file }
	}
}

/// A certificate and profile that belong together.
public struct ValidatedCertificate: Equatable, Sendable {
	public var certificate: SigningCertificate
	public var profile: ProvisioningProfile
}

public enum CertificateImporter {
	/// Opens the .p12, reads the profile and checks that the profile lists
	/// the certificate. `openP12` returns the .p12's certificate (DER).
	public static func validate(
		_ files: CertificateFiles,
		password: String,
		openP12: (Data, String) throws -> Data = PKCS12.certificate
	) throws -> ValidatedCertificate {
		guard let p12 = files.p12 else { throw CertificateImportError.missingP12 }
		guard let profileFile = files.profile else { throw CertificateImportError.missingProfile }

		let profile: ProvisioningProfile
		do {
			profile = try ProvisioningProfile(data: profileFile.data)
		} catch ProvisioningProfile.Error.missing(let field) {
			throw CertificateImportError.profileMissing(field: field)
		} catch {
			throw CertificateImportError.notAProfile(profileFile.name)
		}

		let certificate: SigningCertificate
		do {
			certificate = try SigningCertificate(der: openP12(p12.data, password))
		} catch is SigningCertificate.Error {
			throw CertificateImportError.invalidCertificate
		}

		guard profile.allows(certificate) else {
			throw CertificateImportError.mismatch(certificate: certificate.commonName, profile: profile.name)
		}
		return ValidatedCertificate(certificate: certificate, profile: profile)
	}
}
