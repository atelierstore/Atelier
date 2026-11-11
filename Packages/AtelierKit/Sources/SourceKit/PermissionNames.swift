import Foundation

// Readable names for what an app says it uses, for its detail screen (#14).

extension AppPermissions {
	/// Privacy permissions by name, with the app's reason, sorted by name.
	public var namedPrivacy: [(key: String, name: String, reason: String)] {
		privacy
			.map { (key: $0.key, name: Self.privacyName(for: $0.key), reason: $0.value) }
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// "Camera" for `NSCameraUsageDescription`. Keys Atelier doesn't know
	/// lose their `NS` and `UsageDescription` and get spaces between words.
	public static func privacyName(for key: String) -> String {
		if let known = privacyNames[key] { return known }
		var name = key
		if name.hasPrefix("NS") { name.removeFirst(2) }
		for suffix in ["UsageDescription", "Description"] where name.hasSuffix(suffix) {
			name.removeLast(suffix.count)
			break
		}
		return name.isEmpty ? key : spacedWords(name)
	}

	/// "Push Notifications" for `aps-environment`, or nil for entitlements
	/// Atelier doesn't have a name for.
	public static func entitlementName(for key: String) -> String? {
		entitlementNames[key]
	}

	private static let privacyNames: [String: String] = [
		"NSAppleMusicUsageDescription": "Media Library",
		"NSBluetoothAlwaysUsageDescription": "Bluetooth",
		"NSBluetoothPeripheralUsageDescription": "Bluetooth",
		"NSCalendarsUsageDescription": "Calendars",
		"NSCalendarsFullAccessUsageDescription": "Calendars",
		"NSCalendarsWriteOnlyAccessUsageDescription": "Adding to Calendars",
		"NSCameraUsageDescription": "Camera",
		"NSContactsUsageDescription": "Contacts",
		"NSFaceIDUsageDescription": "Face ID",
		"NSHealthShareUsageDescription": "Reading Health Data",
		"NSHealthUpdateUsageDescription": "Writing Health Data",
		"NSHomeKitUsageDescription": "Home",
		"NSLocalNetworkUsageDescription": "Local Network",
		"NSLocationAlwaysAndWhenInUseUsageDescription": "Location (Always)",
		"NSLocationAlwaysUsageDescription": "Location (Always)",
		"NSLocationUsageDescription": "Location",
		"NSLocationWhenInUseUsageDescription": "Location (While Using)",
		"NSMicrophoneUsageDescription": "Microphone",
		"NSMotionUsageDescription": "Motion & Fitness",
		"NFCReaderUsageDescription": "NFC",
		"NSPhotoLibraryAddUsageDescription": "Adding to Photos",
		"NSPhotoLibraryUsageDescription": "Photos",
		"NSRemindersUsageDescription": "Reminders",
		"NSRemindersFullAccessUsageDescription": "Reminders",
		"NSSiriUsageDescription": "Siri",
		"NSSpeechRecognitionUsageDescription": "Speech Recognition",
		"NSUserTrackingUsageDescription": "Tracking",
	]

	private static let entitlementNames: [String: String] = [
		"aps-environment": "Push Notifications",
		"com.apple.developer.associated-domains": "Associated Domains",
		"com.apple.developer.default-data-protection": "Data Protection",
		"com.apple.developer.family-controls": "Family Controls",
		"com.apple.developer.game-center": "Game Center",
		"com.apple.developer.healthkit": "HealthKit",
		"com.apple.developer.homekit": "HomeKit",
		"com.apple.developer.icloud-container-identifiers": "iCloud",
		"com.apple.developer.icloud-services": "iCloud",
		"com.apple.developer.kernel.extended-virtual-addressing": "Extended Virtual Addressing",
		"com.apple.developer.kernel.increased-memory-limit": "Increased Memory Limit",
		"com.apple.developer.networking.multicast": "Multicast Networking",
		"com.apple.developer.networking.networkextension": "Network Extensions",
		"com.apple.developer.networking.vpn.api": "Personal VPN",
		"com.apple.developer.networking.wifi-info": "Wi-Fi Information",
		"com.apple.developer.nfc.readersession.formats": "NFC Tag Reading",
		"com.apple.developer.siri": "Siri",
		"com.apple.developer.ubiquity-container-identifiers": "iCloud Documents",
		"com.apple.developer.ubiquity-kvstore-identifier": "iCloud Key-Value Storage",
		"com.apple.external-accessory.wireless-configuration": "Wireless Accessory Configuration",
		"com.apple.security.application-groups": "App Groups",
		"get-task-allow": "Debugging",
		"inter-app-audio": "Inter-App Audio",
		"keychain-access-groups": "Keychain Sharing",
	]

	/// "LocalNetwork" → "Local Network", keeping runs of capitals together:
	/// "NFCReader" → "NFC Reader".
	private static func spacedWords(_ string: String) -> String {
		var result = ""
		let characters = Array(string)
		for (i, character) in characters.enumerated() {
			if i > 0, character.isUppercase {
				let previous = characters[i - 1]
				let next = i + 1 < characters.count ? characters[i + 1] : nil
				if previous.isLowercase || (previous.isUppercase && next?.isLowercase == true) {
					result.append(" ")
				}
			}
			result.append(character)
		}
		return result
	}
}
