import Foundation

// Keeping an app's data across a reinstall (#96). iOS won't install an app
// over one signed for another App ID (#76), so Atelier deletes the old one
// first (#20). With Direct installs, the old app's data container is copied
// out through house_arrest before it's deleted, and back into the new
// install before it's first opened. On the test iPhone (iOS 27.0.1, Developer
// Mode on), house_arrest opened an ad hoc app's container as well as a
// development build's, to read and to write (27 Oct 2026); enterprise apps
// are untested. The calls to the phone are behind `AppDataContainer`, which
// the app implements with idevice's C API; what's copied, and in what order,
// is here, tested with a stand-in.

/// What's at a path in an app's data container.
public enum AppDataItem: Equatable, Sendable {
	case folder
	case file(size: Int64)
	case link(target: String)
	/// Anything else, by AFC's `st_ifmt`, such as a socket. Not copied.
	case other(String)
}

/// An app's data container on this iPhone, opened through house_arrest.
/// Paths start at its root, such as "/Library/Preferences". Its calls
/// block, and throw `RouteAError`: one with AFC's own error (`isAFCError`)
/// is about that item, such as a file that can't be read; anything else
/// means the connection broke.
public protocol AppDataContainer: AnyObject {
	/// The names in a folder, without "." and "..".
	func contents(of path: String) throws -> [String]
	func item(at path: String) throws -> AppDataItem
	/// Reads a file, handing `chunk` its parts in order.
	func read(_ path: String, chunk: (Data) throws -> Void) throws
	/// Writes a file, replacing one that's there, with the parts `next`
	/// returns until it returns nil.
	func write(_ path: String, from next: () throws -> Data?) throws
	/// Makes a folder. One that's there already is fine.
	func makeFolder(_ path: String) throws
	func makeLink(at path: String, to target: String) throws
	/// Ends the connection to house_arrest.
	func close()
}

/// iOS wouldn't open an app's data container: house_arrest's answer, such
/// as for an app that isn't a development build.
public struct AppDataRefused: Error, Equatable, CustomStringConvertible {
	public var message: String

	public init(message: String) {
		self.message = message
	}

	public var description: String { message }
}

/// Why an app's data couldn't be copied aside before it was to be deleted,
/// so it wasn't (#96).
public enum AppDataCopyFailure: Equatable, Sendable, CustomStringConvertible {
	/// The copy broke off, and again when tried once more, with why.
	case brokeOff(String)
	/// iOS wouldn't open the app's data container, with its answer.
	case refused(String)
	/// The copy wouldn't leave `AppDataCopy.spareSpace` free on this iPhone.
	case notEnoughSpace(needed: Int64, free: Int64)

	public var description: String {
		switch self {
		case .brokeOff(let why): why
		case .refused(let answer): "iOS doesn't let Atelier open it: \(answer)"
		case .notEnoughSpace(let needed, let free): AppDataCopy.NotEnoughSpace(needed: needed, free: free).description
		}
	}
}

/// What copying an app's data did.
public struct AppDataCopyResult: Equatable, Sendable {
	public var files = 0
	public var folders = 0
	public var links = 0
	public var bytes: Int64 = 0
	/// What couldn't be copied, as "path: why".
	public var skipped: [String] = []

	public init() {}

	/// "412 files, 58.3 MB".
	public var summary: String {
		Self.describe(files: files, bytes: bytes)
	}

	static func describe(files: Int, bytes: Int64) -> String {
		"\(files == 1 ? "1 file" : "\(files) files"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
	}
}

public enum AppDataCopy {
	/// Left out, by path from the container's root: what an iPhone backup
	/// leaves out too (caches and temporary files), and what iOS keeps up
	/// itself (launch screen snapshots, its own services' data, iCloud's copy
	/// of the app's synced preferences and the container's record of whose
	/// it is). AFC isn't allowed to write SyncedPreferences back
	/// (`Afc(PermDenied)`, #96), and a re-signed app can't use iCloud anyway.
	public static let leftOut: Set<String> = [
		"/tmp",
		"/Library/Caches",
		"/Library/SplashBoard",
		"/Library/SyncedPreferences",
		"/SystemData",
		"/.com.apple.mobile_container_manager.metadata.plist",
	]

	/// Room left on this iPhone after a copy, so a copy doesn't fill it.
	public static let spareSpace: Int64 = 200_000_000

	/// The copy didn't fit in the free space.
	public struct NotEnoughSpace: Error, Equatable, CustomStringConvertible {
		public var needed: Int64
		public var free: Int64

		public var description: String {
			"\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of data, and only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
		}
	}

	/// Copies the container's data, apart from `leftOut`, into `folder`.
	/// Items AFC can't read are left out and listed; a broken connection
	/// throws. With `freeSpace`, a copy that wouldn't leave `spareSpace`
	/// free throws `NotEnoughSpace` before copying anything. `progress`
	/// gets the fraction of the bytes copied, every hundredth.
	public static func copyOut(
		from container: any AppDataContainer,
		to folder: URL,
		freeSpace: Int64? = nil,
		log: (String) -> Void = { _ in },
		progress: (Double) -> Void = { _ in },
		isCancelled: () -> Bool = { false }
	) throws -> AppDataCopyResult {
		var result = AppDataCopyResult()
		let entries = try scan(container, skipped: &result.skipped, isCancelled: isCancelled)
		let total = entries.reduce(Int64(0)) { sum, entry in
			if case .file(let size) = entry.item { sum + size } else { sum }
		}
		let fileCount = entries.filter { if case .file = $0.item { true } else { false } }.count
		log("found \(AppDataCopyResult.describe(files: fileCount, bytes: total)) to copy")
		if let freeSpace, total + spareSpace > freeSpace {
			throw NotEnoughSpace(needed: total, free: freeSpace)
		}

		let manager = FileManager.default
		try manager.createDirectory(at: folder, withIntermediateDirectories: true)
		var counter = Progress(total: total, verb: "copied")
		var links: [(path: String, local: URL, target: String)] = []
		for entry in entries {
			if isCancelled() { throw CancellationError() }
			let local = folder.appending(path: String(entry.path.dropFirst()))
			switch entry.item {
			case .folder:
				try manager.createDirectory(at: local, withIntermediateDirectories: true)
				result.folders += 1
			case .file:
				try manager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
				guard manager.createFile(atPath: local.path, contents: nil) else {
					throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: local.path])
				}
				let handle = try FileHandle(forWritingTo: local)
				var copied: Int64 = 0
				do {
					try container.read(entry.path) { chunk in
						try handle.write(contentsOf: chunk)
						copied += Int64(chunk.count)
						counter.add(Int64(chunk.count), log: log, progress: progress)
					}
					try handle.close()
					result.files += 1
					result.bytes += copied
				} catch let error as RouteAError where error.isAFCError {
					try? handle.close()
					try? manager.removeItem(at: local)
					result.skipped.append("\(entry.path): \(error.message)")
				} catch {
					try? handle.close()
					throw error
				}
			case .link(let target):
				links.append((entry.path, local, target))
			case .other(let kind):
				result.skipped.append("\(entry.path): \(kind.isEmpty ? "not a file or folder" : kind)")
			}
		}
		// Last, so nothing is written through a link.
		for link in links {
			do {
				try manager.createDirectory(at: link.local.deletingLastPathComponent(), withIntermediateDirectories: true)
				try manager.createSymbolicLink(atPath: link.local.path, withDestinationPath: link.target)
				result.links += 1
			} catch {
				result.skipped.append("\(link.path): link to \(link.target)")
			}
		}
		return result
	}

	/// Copies the data in `folder`, as `copyOut` left it, into the
	/// container: folders first, then files, replacing any that are there,
	/// then links. Items AFC refuses are listed; a broken connection throws.
	/// `progress` gets the fraction of the bytes written, every hundredth.
	public static func copyBack(
		from folder: URL,
		to container: any AppDataContainer,
		log: (String) -> Void = { _ in },
		progress: (Double) -> Void = { _ in },
		isCancelled: () -> Bool = { false }
	) throws -> AppDataCopyResult {
		var result = AppDataCopyResult()
		let entries = try scanLocal(folder)
		let total = entries.reduce(Int64(0)) { sum, entry in
			if case .file(let size) = entry.item { sum + size } else { sum }
		}
		var counter = Progress(total: total, verb: "put back")
		// Parents before their contents, which the scan already gives;
		// the ones there already, such as Library, are fine.
		for entry in entries {
			guard case .folder = entry.item else { continue }
			if isCancelled() { throw CancellationError() }
			do {
				try container.makeFolder(entry.path)
				result.folders += 1
			} catch let error as RouteAError where error.isAFCError {
				result.skipped.append("\(entry.path): \(error.message)")
			}
		}
		for entry in entries {
			guard case .file = entry.item else { continue }
			if isCancelled() { throw CancellationError() }
			let local = folder.appending(path: String(entry.path.dropFirst()))
			let handle = try FileHandle(forReadingFrom: local)
			defer { try? handle.close() }
			var written: Int64 = 0
			do {
				try container.write(entry.path) {
					guard let part = try handle.read(upToCount: 1 << 20), !part.isEmpty else { return nil }
					written += Int64(part.count)
					counter.add(Int64(part.count), log: log, progress: progress)
					return part
				}
				result.files += 1
				result.bytes += written
			} catch let error as RouteAError where error.isAFCError {
				result.skipped.append("\(entry.path): \(error.message)")
			}
		}
		for entry in entries {
			guard case .link(let target) = entry.item else { continue }
			do {
				try container.makeLink(at: entry.path, to: target)
				result.links += 1
			} catch let error as RouteAError where error.isAFCError {
				result.skipped.append("\(entry.path): link to \(target): \(error.message)")
			}
		}
		return result
	}

	struct Entry: Equatable {
		var path: String
		var item: AppDataItem
	}

	/// Everything in the container but `leftOut`, each folder before what's
	/// in it.
	static func scan(_ container: any AppDataContainer, skipped: inout [String], isCancelled: () -> Bool) throws -> [Entry] {
		var entries: [Entry] = []
		var folders = ["/"]
		var next = 0
		while next < folders.count {
			let folder = folders[next]
			next += 1
			if isCancelled() { throw CancellationError() }
			let names: [String]
			do {
				names = try container.contents(of: folder)
			} catch let error as RouteAError where error.isAFCError {
				skipped.append("\(folder): \(error.message)")
				continue
			}
			for name in names.sorted() where isPlainName(name) {
				let path = folder == "/" ? "/\(name)" : "\(folder)/\(name)"
				if leftOut.contains(path) { continue }
				let item: AppDataItem
				do {
					item = try container.item(at: path)
				} catch let error as RouteAError where error.isAFCError {
					skipped.append("\(path): \(error.message)")
					continue
				}
				entries.append(Entry(path: path, item: item))
				if item == .folder { folders.append(path) }
			}
		}
		return entries
	}

	/// What `copyOut` left in `folder`, as container paths, each folder
	/// before what's in it. Links aren't followed.
	static func scanLocal(_ folder: URL) throws -> [Entry] {
		let manager = FileManager.default
		var entries: [Entry] = []
		var folders = [""]
		var next = 0
		while next < folders.count {
			let relative = folders[next]
			next += 1
			let directory = relative.isEmpty ? folder : folder.appending(path: relative)
			for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() where isPlainName(name) {
				let path = relative.isEmpty ? name : "\(relative)/\(name)"
				if leftOut.contains("/\(path)") { continue }
				let attributes = try manager.attributesOfItem(atPath: folder.appending(path: path).path)
				let item: AppDataItem
				switch attributes[.type] as? FileAttributeType {
				case .typeDirectory?:
					item = .folder
					folders.append(path)
				case .typeSymbolicLink?:
					item = .link(target: try manager.destinationOfSymbolicLink(atPath: folder.appending(path: path).path))
				case .typeRegular?:
					item = .file(size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
				default:
					continue
				}
				entries.append(Entry(path: "/\(path)", item: item))
			}
		}
		return entries
	}

	/// A name that stays inside its folder.
	private static func isPlainName(_ name: String) -> Bool {
		!name.isEmpty && name != "." && name != ".." && !name.contains("/")
	}

	/// How far a copy has got: a line for the log every tenth of the way,
	/// and the fraction done every hundredth.
	private struct Progress {
		let total: Int64
		let verb: String
		private var done: Int64 = 0
		private var lastHundredth = 0

		init(total: Int64, verb: String) {
			self.total = total
			self.verb = verb
		}

		/// Counts `bytes` more, logging once they take it to another tenth.
		mutating func add(_ bytes: Int64, log: (String) -> Void, progress: (Double) -> Void) {
			done += bytes
			guard total > 0 else { return }
			let hundredth = Int(min(done, total) * 100 / total)
			guard hundredth > lastHundredth else { return }
			let tenth = hundredth / 10
			if tenth > lastHundredth / 10 { log("\(verb) \(tenth * 10) %") }
			lastHundredth = hundredth
			progress(Double(min(done, total)) / Double(total))
		}
	}
}

public extension RouteAError {
	/// idevice's code for AFC's own errors, such as a file that can't be
	/// read; anything else is about the connection.
	static let afcErrorCode: Int32 = 106

	var isAFCError: Bool { code == Self.afcErrorCode }
}

/// When a kept copy of an app's data was made, how much it holds, and
/// whose it is.
public struct KeptAppData: Codable, Equatable, Sendable {
	public var copiedAt: Date
	public var files: Int
	public var bytes: Int64
	/// The app's bundle ID; nil in a copy the test build of #96 kept, whose
	/// folder is named after it.
	public var bundleID: String?
	/// When Disable took the app off the device with its data kept (#49),
	/// so the Library lists it as disabled until Enable installs it again;
	/// nil for a copy kept across a reinstall.
	public var disabledAt: Date?

	public init(copiedAt: Date, files: Int, bytes: Int64, bundleID: String? = nil, disabledAt: Date? = nil) {
		self.copiedAt = copiedAt
		self.files = files
		self.bytes = bytes
		self.bundleID = bundleID
		self.disabledAt = disabledAt
	}
}

/// The copies of apps' data Atelier keeps until they're put back into the
/// app's new install (#96), one per bundle ID, in Application Support and
/// left out of backups:
///
///     <root>/<bundle ID>/Container/…   the data, as the container had it
///     <root>/<bundle ID>/copy.json     when it was copied, and how much
public struct AppDataStore: Sendable {
	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	/// Application Support/App Data.
	public static func standard() throws -> AppDataStore {
		let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		return AppDataStore(root: support.appending(path: "App Data", directoryHint: .isDirectory))
	}

	/// A new empty folder to copy into, which `keep` makes an app's copy
	/// and `discard` deletes.
	public func newFolder() throws -> URL {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		#if !os(Linux)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		var store = root
		try? store.setResourceValues(values)
		#endif
		let folder = root.appending(path: ".incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
		#if os(iOS)
		// Readable while the iPhone is locked once it has been unlocked, as
		// a re-sign may run then (#72).
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
		#else
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		#endif
		return folder
	}

	/// Makes `folder`, from `newFolder`, the app's copy, replacing the one
	/// kept before.
	public func keep(_ folder: URL, for bundleID: String, info: KeptAppData) throws {
		let manager = FileManager.default
		let destination = appFolder(for: bundleID)
		let staging = root.appending(path: ".keeping-\(UUID().uuidString)", directoryHint: .isDirectory)
		try manager.createDirectory(at: staging, withIntermediateDirectories: true)
		try manager.moveItem(at: folder, to: staging.appending(path: Self.containerName))
		try Self.encoder.encode(info).write(to: staging.appending(path: Self.infoName))
		try? manager.removeItem(at: destination)
		try manager.moveItem(at: staging, to: destination)
	}

	/// The app's kept copy, if any.
	public func kept(_ bundleID: String) -> KeptAppData? {
		guard FileManager.default.fileExists(atPath: containerFolder(for: bundleID).path),
		      let data = try? Data(contentsOf: appFolder(for: bundleID).appending(path: Self.infoName))
		else { return nil }
		return try? Self.decoder.decode(KeptAppData.self, from: data)
	}

	/// The apps with a kept copy.
	public var keptBundleIDs: Set<String> {
		Set(allKept.keys)
	}

	/// Every kept copy, by the app's bundle ID.
	public var allKept: [String: KeptAppData] {
		let manager = FileManager.default
		guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [:] }
		let copies = names.filter { !$0.hasPrefix(".") }.compactMap { name -> (String, KeptAppData)? in
			guard manager.fileExists(atPath: root.appending(path: name).appending(path: Self.containerName).path),
			      let data = try? Data(contentsOf: root.appending(path: name).appending(path: Self.infoName)),
			      let info = try? Self.decoder.decode(KeptAppData.self, from: data)
			else { return nil }
			return (info.bundleID ?? name, info)
		}
		return Dictionary(copies, uniquingKeysWith: { first, _ in first })
	}

	/// Notes that the app's kept copy is a disabled app's, from `date`
	/// (#49), or with nil, that it's an enabled one's again, waiting to be
	/// put back. Throws when there's no copy.
	public func markDisabled(_ bundleID: String, at date: Date?) throws {
		guard var info = kept(bundleID) else { throw CocoaError(.fileNoSuchFile) }
		info.disabledAt = date
		try Self.encoder.encode(info).write(to: appFolder(for: bundleID).appending(path: Self.infoName), options: .atomic)
	}

	/// Where the app's kept data is, as its container had it.
	public func containerFolder(for bundleID: String) -> URL {
		appFolder(for: bundleID).appending(path: Self.containerName, directoryHint: .isDirectory)
	}

	public func remove(_ bundleID: String) {
		try? FileManager.default.removeItem(at: appFolder(for: bundleID))
	}

	/// Makes the app's kept copy `newBundleID`'s, replacing one kept for it
	/// before: the app installs under that bundle ID now, signed with an
	/// Apple ID or no longer with one (#49). Nothing to do without a copy.
	public func move(_ bundleID: String, to newBundleID: String) throws {
		guard bundleID != newBundleID, var info = kept(bundleID) else { return }
		let manager = FileManager.default
		let folder = appFolder(for: bundleID)
		info.bundleID = newBundleID
		try Self.encoder.encode(info).write(to: folder.appending(path: Self.infoName))
		let destination = appFolder(for: newBundleID)
		try? manager.removeItem(at: destination)
		try manager.moveItem(at: folder, to: destination)
	}

	/// Deletes a folder from `newFolder` that won't be kept.
	public func discard(_ folder: URL) {
		try? FileManager.default.removeItem(at: folder)
	}

	/// Deletes what a copy Atelier stopped in the middle of left behind.
	/// Only while no copy is running: installs run one at a time.
	public func removeLeftovers() {
		let manager = FileManager.default
		guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
		for name in names where name.hasPrefix(".incoming-") || name.hasPrefix(".keeping-") {
			try? manager.removeItem(at: root.appending(path: name))
		}
	}

	private static let containerName = "Container"
	private static let infoName = "copy.json"

	private static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}()

	private static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()

	private func appFolder(for bundleID: String) -> URL {
		// Bundle IDs are letters, digits, hyphens and dots, but an IPA could
		// claim anything, so nothing else reaches the path.
		let safe = String(bundleID.unicodeScalars.map { scalar -> Character in
			CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : "_"
		})
		let name = safe.isEmpty || safe.hasPrefix(".") ? "_\(safe)" : safe
		return root.appending(path: name, directoryHint: .isDirectory)
	}
}
