import Foundation
import InstallKit
#if canImport(Security)
import Security
#endif

#if canImport(Security)
/// The GitHub accounts' access tokens, in the Keychain (#30, #22, #74), one
/// item per account: readable only while the device is unlocked, never
/// synced or restored to another device, and never written into a source
/// URL or a log. While the certificates and the pairing file are readable
/// after first unlock (`PairingFileStore.readableAfterFirstUnlockKey`, #72),
/// so are the tokens: an automatic update from a private repo runs while
/// the iPhone is locked too, and without its token GitHub hides the repo.
public struct GitHubKeychain: GitHubTokenStore {
	private let service: String

	/// #30's one token was kept under this name; each account's is kept
	/// under its ID.
	private static let legacyName = "github.com"

	public init(service: String = "com.atelier.app.github-token") {
		self.service = service
	}

	private func query(_ name: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: name,
			kSecUseDataProtectionKeychain as String: true,
		]
	}

	/// Nil when there's no such item; throws when the Keychain won't say,
	/// as while the device is locked.
	private func read(_ name: String) throws -> String? {
		var item = query(name)
		item[kSecReturnData as String] = true
		item[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(item as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw TokenError(status: status) }
		let token = String(decoding: data, as: UTF8.self)
		return token.isEmpty ? nil : token
	}

	public func token(for account: UUID) -> String? {
		try? read(account.uuidString)
	}

	public func save(_ token: String, for account: UUID) throws {
		delete(account)
		var item = query(account.uuidString)
		item[kSecValueData as String] = Data(token.utf8)
		item[kSecAttrAccessible as String] = accessibility
		let status = SecItemAdd(item as CFDictionary, nil)
		guard status == errSecSuccess else { throw TokenError(status: status) }
	}

	public func reprotect(_ accounts: [UUID]) throws {
		for account in accounts {
			let status = SecItemUpdate(query(account.uuidString) as CFDictionary, [kSecAttrAccessible as String: accessibility] as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else { throw TokenError(status: status) }
		}
	}

	private var accessibility: CFString {
		UserDefaults.standard.bool(forKey: PairingFileStore.readableAfterFirstUnlockKey)
			? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
	}

	public func delete(_ account: UUID) {
		SecItemDelete(query(account.uuidString) as CFDictionary)
	}

	public func legacyToken() throws -> String? {
		try read(Self.legacyName)
	}

	public func deleteLegacyToken() {
		SecItemDelete(query(Self.legacyName) as CFDictionary)
	}

	public struct TokenError: Error, CustomStringConvertible {
		public var status: OSStatus
		public var description: String { "Atelier couldn't save your GitHub sign-in on this \(ThisDevice.name). Try again." }
	}
}
#endif
