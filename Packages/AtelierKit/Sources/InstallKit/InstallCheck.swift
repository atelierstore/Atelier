import Foundation

/// How Atelier tells that a route B install worked (#11).
///
/// iOS 27 doesn't tell a sandboxed app whether an install succeeded (see
/// docs/route-b.md). What it does answer is `UIApplication.canOpenURL` for a
/// URL scheme Atelier declares in `LSApplicationQueriesSchemes`: true only
/// once an installed app registers that scheme. So when Atelier signs an
/// app, it adds one of its own check schemes to the app's Info.plist, one
/// that no installed app has registered. Once that scheme answers, that very
/// build is installed; if it doesn't answer after iOS is done, the install
/// failed.
///
/// Each installed app keeps its scheme until it's updated or deleted, so
/// `schemes.count - 1` apps can hold one at a time, so that updating one of
/// them still finds a free scheme. An install that finds none free, or an
/// app signed before this existed, ends unconfirmed as before. iOS 27 caps
/// `LSApplicationQueriesSchemes` at 25 entries; the rest are left for
/// Atelier's other checks.
public enum InstallCheck {
	/// Atelier's check schemes. The app's `LSApplicationQueriesSchemes`
	/// (project.yml) lists exactly these.
	public static let schemes = (1...21).map { "atelier-check-\($0)" }

	/// The `CFBundleURLName` of the URL type Atelier adds.
	public static let urlTypeName = "com.atelier.install-check"

	public static func isCheckScheme(_ scheme: String) -> Bool {
		schemes.contains(scheme.lowercased())
	}

	/// The check scheme an app carries, if any.
	public static func scheme(of info: IPAInfo) -> String? {
		info.urlSchemes.first(where: isCheckScheme)?.lowercased()
	}

	/// A check scheme no installed app has registered, or nil if all are taken.
	/// `isRegistered` is `canOpenURL` for `<scheme>://`.
	///
	/// A deleted app's Library entry still holds its scheme until another
	/// install is given it, and reads as installed as soon as that install
	/// registers it. So one no entry holds (`held`) comes first, and one an
	/// offloaded app holds (`kept`) never: it would leave Offloaded for
	/// Installed, its data "not put back" (12 Nov 2026).
	public static func freeScheme(isRegistered: (String) -> Bool, held: Set<String> = [], kept: Set<String> = []) -> String? {
		let free = schemes.filter { !isRegistered($0) && !kept.contains($0) }
		return free.first { !held.contains($0) } ?? free.first
	}

	/// Info.plist with every check scheme removed and `scheme` added, in a URL
	/// type of its own. A nil `scheme` only removes them, so an IPA Atelier
	/// signed before never brings an old one along. URL types left empty go.
	public static func apply(_ scheme: String?, to info: [String: Any]) -> [String: Any] {
		var info = info
		var types = (info["CFBundleURLTypes"] as? [[String: Any]]) ?? []
		types = types.compactMap { type in
			guard let schemes = type["CFBundleURLSchemes"] as? [String] else { return type }
			let kept = schemes.filter { !isCheckScheme($0) }
			if kept.isEmpty { return nil }
			var type = type
			type["CFBundleURLSchemes"] = kept
			return type
		}
		if let scheme {
			types.append(["CFBundleURLName": urlTypeName, "CFBundleURLSchemes": [scheme]])
		}
		if types.isEmpty {
			info.removeValue(forKey: "CFBundleURLTypes")
		} else {
			info["CFBundleURLTypes"] = types
		}
		return info
	}
}
