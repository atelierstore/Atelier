import Foundation

/// Sends the names an app asks for its App Groups by to the ones the Apple
/// ID gave them (#49, `AppGroups.names`), or with a certificate, to folders
/// of the app's own in the certificate's group (`AppGroups.folders`). Most
/// apps have their group's name written into their code, and iOS only
/// hands an app the groups its signature lists, so otherwise their widgets
/// and extensions would find nothing.
///
/// Atelier's library, AtelierAppGroups.dylib (Atelier/AppGroups), goes in
/// the app's Frameworks, and the app and each of its extensions load it,
/// as tweak injectors have apps load theirs. It reads the names, and the
/// folders, from its bundle's Info.plist and sends them on when the app
/// asks for a group's folder or settings.
public enum AppGroupRedirect {
	/// The library's file, in Atelier's Frameworks and the app's.
	public static let fileName = "AtelierAppGroups.dylib"
	/// The Info.plist key the library reads the names from: the Apple ID's
	/// name for each group, or the certificate's group that keeps it, by
	/// the app's.
	static let infoKey = "AtelierAppGroups"
	/// The Info.plist key the library reads the folders from, with a
	/// certificate: the folder inside that group each group is kept in, by
	/// the app's name.
	static let foldersKey = "AtelierAppGroupFolders"

	/// Where each executable loads the library from: the app's own, and an
	/// extension's, two folders down in PlugIns or Extensions.
	static let appPath = "@executable_path/Frameworks/" + fileName
	static let extensionPath = "@executable_path/../../Frameworks/" + fileName

	/// Puts `library` in `app` and has the app and its extensions load it,
	/// with `names` and `folders` in each one's Info.plist, before signing.
	/// `load` adds the load command to an executable and says whether it
	/// could: an executable without room for one keeps its code as it is.
	/// Without the app's, nothing changes; an extension without room goes
	/// on without the names. Returns whether the app loads it.
	static func apply(_ names: [String: String], folders: [String: String] = [:], library: URL, to app: URL, load: (String, URL) -> Bool) throws -> Bool {
		guard !names.isEmpty, let executable = IPASigner.executable(of: app), load(appPath, executable) else { return false }
		let manager = FileManager.default
		let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
		try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
		let destination = frameworks.appendingPathComponent(fileName)
		// One left by an earlier signing, or a link in its place (#22).
		if (try? manager.attributesOfItem(atPath: destination.path)) != nil { try manager.removeItem(at: destination) }
		try manager.copyItem(at: library, to: destination)
		try set(names, folders: folders, in: app)
		for bundle in extensions(of: app) {
			guard let executable = IPASigner.executable(of: bundle), load(extensionPath, executable) else { continue }
			try set(names, folders: folders, in: bundle)
		}
		return true
	}

	/// The app's extensions: PlugIns' and ExtensionKit's. Watch apps run on
	/// the watch, and App Clips on their own, so neither loads it.
	static func extensions(of app: URL) -> [URL] {
		let manager = FileManager.default
		return ["PlugIns", "Extensions"].flatMap { folder in
			((try? manager.contentsOfDirectory(at: app.appendingPathComponent(folder, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
				.filter { $0.pathExtension == "appex" && manager.fileExists(atPath: $0.appendingPathComponent("Info.plist").path) }
				.sorted { $0.lastPathComponent < $1.lastPathComponent }
		}
	}

	/// Writes `names` and `folders` into a bundle's Info.plist, keeping its
	/// format, without folders an IPA brought.
	private static func set(_ names: [String: String], folders: [String: String], in bundle: URL) throws {
		let plist = bundle.appendingPathComponent("Info.plist")
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("\(bundle.lastPathComponent)'s Info.plist can't be read")
		}
		info[infoKey] = names
		info[foldersKey] = folders.isEmpty ? nil : folders
		try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
	}
}
