import ActivityKit
import Foundation

/// The Live Activity for route A's later setup steps, Enable Local VPN and
/// Check (#54), so the step stays in sight while the user is in the App
/// Store, LocalDevVPN or Settings. Atelier writes the words
/// (SetupLiveActivity); the AtelierLiveActivity extension only draws them.
struct SetupActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		enum Tint: String, Codable {
			case blue, orange
		}

		/// "LocalDevVPN" or "Check", beside `symbol`.
		var title: String
		var symbol: String
		var tint: Tint
		/// "Step 1 of 2", or a short status such as "Problem".
		var status: String
		var headline: String
		var detail: String
		/// From 0 to 1.
		var progress: Double
		/// The compact Dynamic Island's trailing text, such as "1/2".
		var compact: String
	}
}
