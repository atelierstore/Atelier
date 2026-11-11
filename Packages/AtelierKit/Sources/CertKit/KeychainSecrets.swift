#if canImport(Security)
import Foundation
import Security

/// .p12 passwords in the Keychain, one generic password per certificate.
///
/// Readable only while the device is unlocked and never synced or restored
/// to another device (`WhenUnlockedThisDeviceOnly`), matching the complete
/// file protection on the .p12 itself; after first unlock
/// (`AfterFirstUnlockThisDeviceOnly`) while automatic updates need it
/// (`SecretProtection`, #72).
///
/// Apple IDs' own passwords (#49) are kept the same way under their own
/// service, always readable after first unlock, so the weekly renewal of
/// their apps' profiles can sign in again in the background.
public final class KeychainCertificateSecrets: CertificateSecrets {
	private let service: String
	private let alwaysAfterFirstUnlock: Bool

	public init(service: String = "com.atelier.app.certificate-password", alwaysAfterFirstUnlock: Bool = false) {
		self.service = service
		self.alwaysAfterFirstUnlock = alwaysAfterFirstUnlock
	}

	/// Where Apple IDs' own passwords are kept.
	public static func appleIDPasswords() -> KeychainCertificateSecrets {
		KeychainCertificateSecrets(service: "com.atelier.app.apple-id-password", alwaysAfterFirstUnlock: true)
	}

	public func setPassword(_ password: String, for id: UUID) throws {
		try? deletePassword(for: id)
		var item = query(for: id)
		item[kSecValueData as String] = Data(password.utf8)
		item[kSecAttrAccessible as String] = accessibility
		let status = SecItemAdd(item as CFDictionary, nil)
		guard status == errSecSuccess else { throw KeychainError(status: status) }
	}

	public func reprotect(_ ids: [UUID]) throws {
		for id in ids {
			let status = SecItemUpdate(query(for: id) as CFDictionary, [kSecAttrAccessible as String: accessibility] as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
		}
	}

	private var accessibility: CFString {
		alwaysAfterFirstUnlock || SecretProtection.readableAfterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
	}

	public func password(for id: UUID) throws -> String? {
		var item = query(for: id)
		item[kSecReturnData as String] = true
		item[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(item as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
		return String(decoding: data, as: UTF8.self)
	}

	public func deletePassword(for id: UUID) throws {
		let status = SecItemDelete(query(for: id) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
	}

	private func query(for id: UUID) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: id.uuidString,
			kSecUseDataProtectionKeychain as String: true,
		]
	}
}

public struct KeychainError: Error, CustomStringConvertible {
	public var status: OSStatus

	public var description: String {
		let message = SecCopyErrorMessageString(status, nil) as String?
		return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
	}
}
#endif
