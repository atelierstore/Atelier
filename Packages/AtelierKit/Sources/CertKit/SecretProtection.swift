import Foundation

/// How certificates are protected on the device (#72). By default they
/// can only be read while the device is unlocked. With automatic updates
/// on, the app relaxes that to "after first unlock", so a background update
/// can sign while the iPhone is locked: readable once the user has unlocked
/// it since it started up, and not after a restart until they do again.
///
/// The app sets `defaultsKey`; InstallKit's pairing file store reads the
/// same key.
public enum SecretProtection {
	public static let defaultsKey = "secretsReadableAfterFirstUnlock"

	public static var readableAfterFirstUnlock: Bool {
		UserDefaults.standard.bool(forKey: defaultsKey)
	}

	#if os(iOS)
	static var fileProtection: FileProtectionType {
		readableAfterFirstUnlock ? .completeUntilFirstUserAuthentication : .complete
	}

	static var writingOptions: Data.WritingOptions {
		readableAfterFirstUnlock ? [.atomic, .completeFileProtectionUntilFirstUserAuthentication] : [.atomic, .completeFileProtection]
	}

	/// Gives `url`, and everything in it when it's a folder, the current protection.
	static func apply(to url: URL) throws {
		let manager = FileManager.default
		try manager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
		guard let contents = manager.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
		for case let item as URL in contents {
			try manager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: item.path)
		}
	}
	#endif
}
