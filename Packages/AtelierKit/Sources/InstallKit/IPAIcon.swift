import Foundation

/// An app's icon as iOS shows it, from its IPA: the largest loose PNG its
/// Info.plist names as its primary icon, or failing that any `AppIcon*.png`
/// next to its Info.plist. Apps built by Xcode keep these next to
/// `Assets.car` for older iOS versions, Icon Composer's icons too. The PNG is
/// as stored in the app, often Apple's iPhone PNG variant, which iOS draws.
///
/// GitHub sources list apps with it (#30), and the Library shows installed
/// apps with it, as a source can list an app with another app's picture (#118).
public enum IPAIcon {
	/// The icon among `files`, by path, with their sizes: the app's are in
	/// `appFolder` (`Payload/<App>.app/`). Nil when there's none.
	public static func file(plist: [String: Any], appFolder: String, files: [(path: String, size: Int64)]) -> String? {
		let names = ["CFBundleIcons", "CFBundleIcons~ipad"].flatMap { key -> [String] in
			let icons = plist[key] as? [String: Any]
			let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
			return primary?["CFBundleIconFiles"] as? [String] ?? []
		} + (plist["CFBundleIconFiles"] as? [String] ?? [])
		let topLevel = files.filter {
			$0.path.hasPrefix(appFolder) && !$0.path.dropFirst(appFolder.count).contains("/")
				&& $0.path.lowercased().hasSuffix(".png")
		}
		func file(_ entry: (path: String, size: Int64)) -> String { String(entry.path.dropFirst(appFolder.count)) }
		let named = topLevel.filter { entry in
			let name = file(entry)
			return names.contains { name.hasPrefix($0) }
		}
		let candidates = named.isEmpty ? topLevel.filter { file($0).hasPrefix("AppIcon") } : named
		// The largest is the sharpest.
		return candidates.max { $0.size < $1.size }?.path
	}

	/// The icon's PNG in the IPA at `url`; nil when it has none, or can't be
	/// read.
	public static func read(ipaAt url: URL) -> Data? {
		guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
		return try? read(ipaData: data)
	}

	static func read(ipaData data: Data) throws -> Data? {
		let zip = ZipReader(data: data)
		guard let plistPath = try zip.sizes(where: IPAInfo.isTopLevelInfoPlist).first?.path else { return nil }
		let plistData = try zip.extract { $0 == plistPath }
		guard let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else { return nil }
		// The PNGs next to Info.plist are the app's icons, and can be many
		// other pictures too, so only the icon is decompressed.
		let appFolder = String(plistPath.dropLast("Info.plist".count))
		let pngs = try zip.sizes { $0.hasPrefix(appFolder) && $0.lowercased().hasSuffix(".png") }
		guard let icon = file(plist: plist, appFolder: appFolder, files: pngs) else { return nil }
		return try zip.extract { $0 == icon }
	}
}
