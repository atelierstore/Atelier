import ActivityKit
import Foundation

/// The Live Activity that shows route A's pairing steps and code while the
/// user is in Settings (#54): on the Lock Screen and in the Dynamic Island,
/// with more on a long press. Atelier starts and updates it
/// (PairingLiveActivity); the AtelierLiveActivity extension draws it.
struct PairingActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		enum Phase: String, Codable {
			/// Starting the pairing service; nothing to do in Settings yet.
			case starting
			/// The service is live: open Developer Mode and tap Atelier.
			case openSettings
			/// The phone asked for the code.
			case enterCode
			case paired
		}

		var phase: Phase
		/// Set in `enterCode`.
		var code: String?
		/// When the pairing attempt times out.
		var endDate: Date
	}

	/// "iPhone" or "iPad" (ThisDevice.name), which the extension can't read.
	var deviceName: String
}

extension PairingActivityAttributes.ContentState {
	/// The steps, in the order the user takes them.
	static let steps = [
		"Open Settings › Privacy & Security › Developer Mode and tap Pair with Atelier",
		"Enter this code",
		"Come back to Atelier",
	]

	/// Where step 1 goes, and what to tap there: the expanded Dynamic Island
	/// shows them on two lines.
	static let settingsPath = "Settings › Privacy & Security › Developer Mode"
	static let settingsTap = "then tap Pair with Atelier under Other Devices"

	/// The step the user is on, from 1; 0 before the first.
	var step: Int {
		switch phase {
		case .starting: 0
		case .openSettings: 1
		case .enterCode: 2
		case .paired: 3
		}
	}
}
