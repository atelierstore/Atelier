import Foundation
import Observation

/// The icons of the apps Atelier installed, as iOS shows them, read from
/// the IPAs it signed (`IPAIcon`, #118). A source can list an app with
/// another app's picture: AppTesters lists Wallpapers, whose IPA is
/// WallpapersCentral, with Apalon's Wallpapers icon (#116). Atelier shows an
/// installed app with this one wherever it shows it: in the Library, on its
/// page, in the install bar and in Browse's rows and cards. Apps that aren't
/// installed have the sources'.
///
/// One PNG per installed bundle ID in Application Support/Icons, named
/// `<bundle ID>@<milliseconds since 1970>.png`, so a new icon has a new URL
/// and `ImagePipeline` doesn't keep showing the old one from memory. Bundle
/// IDs can't contain @.
///
/// `own` keeps, the same way in Application Support/OwnIcons, the icons
/// their IPAs have of apps signed with a tint or picture of the user's,
/// which iOS shows instead (#113, #155): Custom Install's pictures of new ones
/// start from them.
@MainActor
@Observable
final class InstalledIcons {
	static let shared = InstalledIcons()
	static let own = InstalledIcons(folder: InstalledIcons.ownFolder)

	/// Each icon, by the bundle ID its app is installed as.
	private var files: [String: URL] = [:]
	@ObservationIgnored private let folder: URL?

	init(folder: URL? = InstalledIcons.standardFolder) {
		self.folder = folder
		guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
		// Oldest first, so a newer icon left next to an older one wins.
		for name in names.sorted() where name.hasSuffix(".png") {
			guard let at = name.lastIndex(of: "@") else { continue }
			let bundleID = String(name[..<at])
			if let older = files[bundleID] { try? FileManager.default.removeItem(at: older) }
			files[bundleID] = folder.appending(path: name)
		}
	}

	nonisolated static var standardFolder: URL? {
		supportFolder(named: "Icons")
	}

	nonisolated static var ownFolder: URL? {
		supportFolder(named: "OwnIcons")
	}

	nonisolated private static func supportFolder(named name: String) -> URL? {
		try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
			.appending(path: name, directoryHint: .isDirectory)
	}

	/// The icon of the app installed as `bundleID`; nil when Atelier didn't
	/// find one in its IPA, or installed it before it kept them.
	func url(for bundleID: String) -> URL? {
		files[bundleID]
	}

	/// Keeps `png` as the icon of the app installed as `bundleID`, in place
	/// of the one it had.
	func save(_ png: Data, for bundleID: String) {
		guard let folder else { return }
		let file = folder.appending(path: "\(bundleID)@\(Int(Date.now.timeIntervalSince1970 * 1000)).png")
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try png.write(to: file, options: .atomic)
		} catch {
			return
		}
		if let old = files[bundleID], old != file { try? FileManager.default.removeItem(at: old) }
		files[bundleID] = file
	}

	/// Deletes the icon of the app installed as `bundleID`, such as when the
	/// IPA Atelier signed last had none, so its source's shows.
	func remove(for bundleID: String) {
		guard let file = files.removeValue(forKey: bundleID) else { return }
		try? FileManager.default.removeItem(at: file)
	}

	/// Deletes the icons of apps that are no longer in the Library.
	func keep(only bundleIDs: Set<String>) {
		for bundleID in files.keys where !bundleIDs.contains(bundleID) {
			remove(for: bundleID)
		}
	}
}
