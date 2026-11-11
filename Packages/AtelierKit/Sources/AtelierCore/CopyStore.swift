import Foundation
import SigningKit

/// What the user chose for an app in Custom Install…, a copy (#113) or any
/// installed app (#155), kept by `CopyStore` so its
/// updates and re-signs keep it: the bundle ID it's installed as, the
/// app's own name, its icon's tint, whether its icon is a picture of
/// theirs, the version it says it is, whether its URL schemes go, and
/// whether it shares its App Groups under an Apple ID's names (#49).
public struct CopySettings: Codable, Equatable, Sendable {
	/// The bundle ID it's installed as, in place of the numbered one its
	/// copy number gives it (`InstallTarget`). Nil for that one, and for
	/// the app itself, whose App ID stays, so it keeps its data (#155).
	public var bundleID: String?
	/// The name the app itself is signed with (#155); nil keeps the one
	/// its IPA has. A copy's is its Library entry's (`InstallRecord.name`).
	public var name: String?
	public var tint: AppIconTint?
	/// Its icon is a picture of the user's, which `CopyStore` keeps.
	public var hasPicture: Bool
	/// The version it says it is, for apps that won't run older versions.
	/// Nil for the app's own.
	public var version: String?
	public var removesURLSchemes: Bool
	/// Share App Groups (#49): signed with an Apple ID, the app and its
	/// extensions load Atelier's library that sends their own names for
	/// its App Groups to the Apple ID's (`SigningOptions.appGroupsLibrary`).
	/// On unless the user turned it off, for an app that won't open with it.
	public var sharesAppGroups: Bool

	public init(bundleID: String? = nil, name: String? = nil, tint: AppIconTint? = nil, hasPicture: Bool = false, version: String? = nil, removesURLSchemes: Bool = false, sharesAppGroups: Bool = true) {
		self.bundleID = bundleID
		self.name = name
		self.tint = tint
		self.hasPicture = hasPicture
		self.version = version
		self.removesURLSchemes = removesURLSchemes
		self.sharesAppGroups = sharesAppGroups
	}

	private enum CodingKeys: String, CodingKey {
		case bundleID, name, tint, hasPicture, version, removesURLSchemes, sharesAppGroups
	}

	/// What it doesn't know, such as a tint a later Atelier added, is left
	/// out rather than making the rest unreadable.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		bundleID = (try? container.decodeIfPresent(String.self, forKey: .bundleID)) ?? nil
		name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
		tint = ((try? container.decodeIfPresent(String.self, forKey: .tint)) ?? nil).flatMap(AppIconTint.init(rawValue:))
		hasPicture = ((try? container.decodeIfPresent(Bool.self, forKey: .hasPicture)) ?? nil) ?? false
		version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? nil
		removesURLSchemes = ((try? container.decodeIfPresent(Bool.self, forKey: .removesURLSchemes)) ?? nil) ?? false
		sharesAppGroups = ((try? container.decodeIfPresent(Bool.self, forKey: .sharesAppGroups)) ?? nil) ?? true
	}

	/// The copy's icon, with `picture` as the user's when it has one. Nil
	/// keeps the app's.
	public func icon(picture: Data?) -> IconChange? {
		let change = IconChange(picture: hasPicture ? picture : nil, tint: tint)
		return change.isEmpty ? nil : change
	}

	/// Whether its icon isn't the app's own: it has a tint or a picture.
	public var changesIcon: Bool {
		tint != nil || hasPicture
	}

	/// The name Custom Install… signs an installed app with (#155), from
	/// its Name field, `typed`, and the name the app has, `current`: the
	/// field's, or nil for its IPA's. That's for an empty field, and for
	/// the app itself also for the name it has while that's its IPA's,
	/// which `chosen`, the name chosen for it before, tells, so the name
	/// stays in every language the app has it in. A copy's is written in,
	/// as its updates do.
	public static func signingName(typed: String, current: String, chosen: String?, isCopy: Bool) -> String? {
		let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
		if name.isEmpty { return nil }
		if !isCopy, chosen == nil, name == current { return nil }
		return name
	}

	/// What's wrong with `id` as the bundle ID of copy `number` of the app
	/// whose IPA has `appBundleID`, or nil when nothing is. `taken` says
	/// whether another app in the Library has it.
	///
	/// iOS allows letters, digits, hyphens and full stops, in parts that
	/// aren't empty. The app's own is the app's, and other copies' numbered
	/// ones are kept for them, as `InstallTarget` tells copies by them.
	public static func problem(with id: String, copy number: Int, of appBundleID: String, taken: (String) -> Bool) -> String? {
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
		if id.isEmpty { return "A copy needs an App ID." }
		if !id.allSatisfy(allowed.contains) {
			return "An App ID can only have letters, digits, hyphens (-) and full stops (.)."
		}
		if id.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) {
			return "An App ID can't start or end with a full stop, or have two in a row."
		}
		let own = InstallTarget.copy(number).bundleID(for: appBundleID)
		if id.lowercased() == appBundleID.lowercased() { return "That's the app's own ID. A copy needs another one." }
		if id != own, case .copy(let other) = InstallTarget.split(id).target {
			return "IDs ending in .atelier\(other) are kept for Atelier's numbered copies."
		}
		if taken(id) { return "An app in your Library has that ID already." }
		return nil
	}

	/// The bundle ID copy `number` of the app whose IPA has `appBundleID`
	/// gets from its name: the app's, then the name's letters and digits,
	/// as `com.atelier.app.ateliertests` for a copy of Atelier named
	/// "Atelier Tests". The name it was suggested with, `suggestedName`,
	/// keeps the numbered one (`InstallTarget`), as does a name without
	/// letters or digits, or one whose ID can't be used (`problem`).
	public static func bundleID(named name: String, suggestedName: String, copy number: Int, of appBundleID: String, taken: (String) -> Bool) -> String {
		let numbered = InstallTarget.copy(number).bundleID(for: appBundleID)
		let part = idPart(of: name)
		guard !part.isEmpty, part != idPart(of: suggestedName) else { return numbered }
		let id = "\(appBundleID).\(part)"
		return problem(with: id, copy: number, of: appBundleID, taken: taken) == nil ? id : numbered
	}

	/// A name's letters and digits, as a bundle ID can have them: in Latin
	/// letters, without accents, in lower case, and at most 40.
	static func idPart(of name: String) -> String {
		let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
		let plain = latin.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
		let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
		return String(plain.filter(allowed.contains).prefix(40))
	}
}

/// Each copy's `CopySettings` (#113), by the bundle ID its copy number
/// gives it (`InstallTarget`), whatever bundle ID it's installed as, and
/// those of apps themselves, by their own (#155): in one JSON file in
/// Application Support/Copies, with the pictures as PNGs next to it. A
/// copy installed under a bundle ID of the user's choosing is told by it
/// from here, as its own doesn't say which copy it is.
public final class CopyStore: @unchecked Sendable {
	/// Application Support/Copies. Tests put another in its place.
	nonisolated(unsafe) public static var shared = CopyStore(folder: CopyStore.standardFolder)

	public let folder: URL
	private let lock = NSLock()
	/// The file as last read or written; nil until it's read.
	private var cache: [String: CopySettings]?

	public init(folder: URL) {
		self.folder = folder
	}

	private static var standardFolder: URL {
		let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
			?? FileManager.default.temporaryDirectory
		return support.appending(path: "Copies", directoryHint: .isDirectory)
	}

	private var file: URL {
		folder.appending(path: "Copies.json")
	}

	/// Where the copy numbered `numberedID` keeps its picture. Bundle IDs
	/// have no slashes.
	private func pictureFile(for numberedID: String) -> URL? {
		guard !numberedID.isEmpty, !numberedID.contains("/"), numberedID != ".", numberedID != ".." else { return nil }
		return folder.appending(path: "\(numberedID).png")
	}

	// MARK: Reading

	/// The settings of the copy numbered `numberedID`; nil when it has none.
	public func settings(for numberedID: String) -> CopySettings? {
		read { $0[numberedID] }
	}

	/// The numbered bundle ID of the copy installed as `bundleID`, when
	/// that's one of the user's choosing; nil for any other.
	public func numberedID(installedAs bundleID: String) -> String? {
		read { all in
			all.filter { $0.key != bundleID && $0.value.bundleID == bundleID }.keys.min()
		}
	}

	/// The bundle ID the copy numbered `numberedID` is installed as: the one
	/// the user chose, else that one.
	public func installedID(of numberedID: String) -> String {
		settings(for: numberedID)?.bundleID ?? numberedID
	}

	/// Every copy's numbered bundle ID, for numbering new copies after them,
	/// as their installed ones may not say.
	public var numberedIDs: [String] {
		read { Array($0.keys) }
	}

	/// The copy's picture, when it has one.
	public func picture(for numberedID: String) -> Data? {
		guard settings(for: numberedID)?.hasPicture == true, let file = pictureFile(for: numberedID) else { return nil }
		return try? Data(contentsOf: file)
	}

	// MARK: Writing

	/// Keeps `settings` for the copy numbered `numberedID`, with `picture`
	/// as its icon's when they say it has one; without a picture, the one
	/// it has stays. Settings that change nothing are forgotten, picture
	/// and all. Another copy noted as installed under the same bundle ID
	/// is forgotten: iOS has one app for each.
	public func save(_ settings: CopySettings, picture: Data? = nil, for numberedID: String) throws {
		var settings = settings
		if settings.bundleID == numberedID { settings.bundleID = nil }
		if settings.hasPicture, pictureFile(for: numberedID) == nil { settings.hasPicture = false }
		lock.lock()
		defer { lock.unlock() }
		var all = load()
		let installed = settings.bundleID ?? numberedID
		for (other, kept) in all where other != numberedID && (kept.bundleID ?? other) == installed {
			all[other] = nil
			removePicture(of: other)
		}
		if settings == CopySettings() {
			all[numberedID] = nil
		} else {
			all[numberedID] = settings
		}
		if settings.hasPicture, let picture, let pictureFile = pictureFile(for: numberedID) {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try picture.write(to: pictureFile, options: .atomic)
		} else if !settings.hasPicture {
			removePicture(of: numberedID)
		}
		try write(all)
	}

	/// Forgets the copy numbered `numberedID`.
	public func remove(_ numberedID: String) {
		lock.lock()
		defer { lock.unlock() }
		var all = load()
		guard all.removeValue(forKey: numberedID) != nil else { return }
		removePicture(of: numberedID)
		try? write(all)
	}

	/// Forgets the copies no longer in the Library: those whose installed
	/// bundle ID isn't among `installed`.
	public func keep(only installed: Set<String>) {
		lock.lock()
		defer { lock.unlock() }
		var all = load()
		let gone = all.filter { !installed.contains($0.value.bundleID ?? $0.key) }.keys
		guard !gone.isEmpty else { return }
		for numberedID in gone {
			all[numberedID] = nil
			removePicture(of: numberedID)
		}
		try? write(all)
	}

	// MARK: The file

	private func read<Result>(_ body: ([String: CopySettings]) -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body(load())
	}

	/// What the file holds, read once. Called with the lock held. A file
	/// that can't be read holds nothing.
	private func load() -> [String: CopySettings] {
		if let cache { return cache }
		let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: CopySettings].self, from: $0) } ?? [:]
		cache = loaded
		return loaded
	}

	/// Called with the lock held.
	private func write(_ all: [String: CopySettings]) throws {
		cache = all
		if all.isEmpty {
			try? FileManager.default.removeItem(at: file)
			return
		}
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		try encoder.encode(all).write(to: file, options: .atomic)
	}

	/// Called with the lock held.
	private func removePicture(of numberedID: String) {
		guard let file = pictureFile(for: numberedID) else { return }
		try? FileManager.default.removeItem(at: file)
	}
}
