import Foundation

/// What Atelier calls this device in its text: "iPhone" or "iPad" (#61).
/// iOS 17 doesn't run on iPod touch, so those are the only two.
public enum ThisDevice {
	/// This device's name, from its hardware model. Read once; unlike
	/// `UIDevice.current.model`, it needs neither UIKit nor the main actor.
	public static let name = displayName(forModel: model)

	/// "iPad" for an iPad's model identifier ("iPad13,1"), "iPhone" for
	/// anything else, including models Atelier doesn't recognise.
	public static func displayName(forModel model: String) -> String {
		model.hasPrefix("iPad") ? "iPad" : "iPhone"
	}

	/// The hardware model ("iPhone16,1"), or the simulated one on the
	/// Simulator, whose hardware model is the Mac's ("arm64").
	static var model: String {
		if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
			return simulated
		}
		var info = utsname()
		uname(&info)
		return withUnsafeBytes(of: &info.machine) { bytes in
			String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
		}
	}
}
