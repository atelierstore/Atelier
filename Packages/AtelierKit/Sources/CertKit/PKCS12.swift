import Foundation
#if canImport(Security)
import Security
#endif

/// Opens a `.p12` with its password and returns the signing certificate (DER).
/// Apple platforms only: there is no PKCS#12 decoder on Linux, so tests
/// there pass their own opener to `CertificateImporter`.
public enum PKCS12 {
	public static func certificate(in p12: Data, password: String) throws -> Data {
		#if canImport(Security)
		var options: [String: Any] = [kSecImportExportPassphrase as String: password]
		#if os(macOS)
		// iOS never adds imported items to a keychain; macOS does unless told
		// not to, which would leave keys behind in tests.
		if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
		#endif
		var items: CFArray?
		let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
		switch status {
		case errSecSuccess: break
		case errSecAuthFailed: throw CertificateImportError.wrongPassword
		// errSecPkcs12VerifyFailure: the MAC didn't verify. Usually the
		// password, but also what modern (AES) .p12 files can give on older iOS.
		case -25264: throw CertificateImportError.wrongPasswordOrUnsupportedP12
		case errSecDecode, errSecUnknownFormat: throw CertificateImportError.unreadableP12
		default: throw CertificateImportError.p12ImportFailed(Int(status))
		}
		guard
			let first = (items as? [[String: Any]])?.first,
			let identityValue = first[kSecImportItemIdentity as String]
		else { throw CertificateImportError.noIdentityInP12 }
		let identity = identityValue as! SecIdentity
		var certificate: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
			throw CertificateImportError.noIdentityInP12
		}
		return SecCertificateCopyData(certificate) as Data
		#else
		throw CertificateImportError.p12ImportFailed(-4) // errSecUnimplemented
		#endif
	}
}
