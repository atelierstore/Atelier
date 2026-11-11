import Foundation

/// Apple's developer disk image (11 Nov 2026), which brings the developer
/// services Find Open Spaces Automatically uses: pressing Home, swiping and
/// taking a screenshot. Atelier doesn't ship it. The first time, it's
/// downloaded from doronz88's DeveloperDiskImage repository on GitHub,
/// where StikDebug gets it too, and kept in Caches. iOS mounts it only with
/// a signature from Apple's signing server for this iPhone. From iOS 26.4
/// it's a cryptex, as StikDebug mounts it there.
enum DeveloperDiskImage {
	enum Kind: String, Sendable {
		/// Up to iOS 26.3, through the image mounter.
		case personalized
		/// From iOS 26.4, through cryptexd.
		case cryptex
	}

	struct Files: Sendable {
		var kind: Kind
		var image: Data
		var trustCache: Data
		var buildManifest: Data
		/// A cryptex's info and root hash; empty for the personalized image.
		var info = Data()
		var rootHash = Data()
		/// Whether they were downloaded just now rather than kept from before.
		var downloaded = false
	}

	/// What went wrong getting the files.
	struct Failure: Error, CustomStringConvertible {
		var description: String
	}

	/// The kind this iPhone mounts, as StikDebug picks it.
	static var kind: Kind {
		let version = ProcessInfo.processInfo.operatingSystemVersion
		return version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4) ? .cryptex : .personalized
	}

	/// The files for this iPhone: kept from before, or downloaded now.
	/// `fresh` downloads them again, as when the kept ones weren't mounted.
	static func files(fresh: Bool = false) async throws -> Files {
		let kind = kind
		let folder = folder(kind)
		let complete = folder.appending(path: ".complete")
		var downloaded = false
		if fresh || !FileManager.default.fileExists(atPath: complete.path) {
			try? FileManager.default.removeItem(at: folder)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			for name in names(kind) {
				let url = URL(string: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/\(source(kind))/\(name)")!
				let (download, response) = try await URLSession.shared.download(from: url)
				defer { try? FileManager.default.removeItem(at: download) }
				let status = (response as? HTTPURLResponse)?.statusCode ?? 0
				guard status == 200 else { throw Failure(description: "\(name): HTTP \(status)") }
				try FileManager.default.moveItem(at: download, to: folder.appending(path: name))
			}
			try Data().write(to: complete)
			downloaded = true
		}
		return try await Task.detached { [downloaded] in
			func read(_ name: String) throws -> Data {
				try Data(contentsOf: folder.appending(path: name))
			}
			let manifest = try read("BuildManifest.plist")
			let image = try read("Image.dmg")
			// Something other than the files, such as a page about them,
			// would be refused by the mount anyway; say so before.
			guard (try? PropertyListSerialization.propertyList(from: manifest, options: [], format: nil)) is [String: Any] else {
				try? FileManager.default.removeItem(at: complete)
				throw Failure(description: "BuildManifest.plist isn't a property list")
			}
			guard image.count > 1_000_000 else {
				try? FileManager.default.removeItem(at: complete)
				throw Failure(description: "Image.dmg is only \(image.count) bytes")
			}
			var files = Files(kind: kind, image: image, trustCache: try read("Image.dmg.trustcache"), buildManifest: manifest, downloaded: downloaded)
			if kind == .cryptex {
				files.info = try read("Image.dmg.cryptex_info")
				files.rootHash = try read("Image.dmg.root_hash")
			}
			return files
		}.value
	}

	/// The repository's folder for `kind`.
	private static func source(_ kind: Kind) -> String {
		switch kind {
		case .personalized: "Xcode_iOS_DDI_Personalized"
		case .cryptex: "Xcode_iOS_DDI_Cryptex"
		}
	}

	private static func names(_ kind: Kind) -> [String] {
		switch kind {
		case .personalized: ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
		case .cryptex: ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"]
		}
	}

	private static func folder(_ kind: Kind) -> URL {
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appending(path: "DeveloperDiskImage/\(kind.rawValue)", directoryHint: .isDirectory)
	}
}
