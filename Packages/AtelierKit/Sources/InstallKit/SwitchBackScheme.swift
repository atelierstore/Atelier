import Foundation

/// The URL scheme LocalDevVPN opens to switch back to the Atelier that
/// connected it (`localdevvpn://enable?scheme=…`, #9).
///
/// It was `atelier`, which a copy of Atelier has too, as a copy keeps the
/// source schemes (#113). iOS then picked which one to open, and LocalDevVPN
/// switched to the copy rather than the Atelier that asked (4 Nov
/// 2026). So each Atelier has one of its own, made from its bundle ID, which
/// no other app on the iPhone has: a build has its own bundle ID's
/// (project.yml), and signing an Atelier under another bundle ID gives it
/// that one's.
public enum SwitchBackScheme {
	/// The `CFBundleURLName` of its URL type.
	public static let urlTypeName = "com.atelier.app.switch-back"

	/// The scheme of an Atelier signed as `bundleID`. A bundle ID holds only
	/// letters, digits, hyphens and dots, which a scheme can hold too.
	public static func scheme(for bundleID: String) -> String {
		"atelier-\(bundleID.lowercased())"
	}

	/// The scheme an Info.plist has in its URL type, if it has that type.
	public static func scheme(in info: [String: Any]) -> String? {
		let types = (info["CFBundleURLTypes"] as? [[String: Any]]) ?? []
		return types.first(where: isSwitchBack).flatMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
	}

	/// Whether a URL type is the switch-back one.
	public static func isSwitchBack(_ type: [String: Any]) -> Bool {
		type["CFBundleURLName"] as? String == urlTypeName
	}

	/// Info.plist with its URL type's scheme made `bundleID`'s. An Info.plist
	/// without that type, any other app's and Atelier's before it, is left
	/// as it is.
	public static func apply(bundleID: String, to info: [String: Any]) -> [String: Any] {
		guard var types = info["CFBundleURLTypes"] as? [[String: Any]],
		      let index = types.firstIndex(where: isSwitchBack)
		else { return info }
		var info = info
		types[index]["CFBundleURLSchemes"] = [scheme(for: bundleID)]
		info["CFBundleURLTypes"] = types
		return info
	}
}
