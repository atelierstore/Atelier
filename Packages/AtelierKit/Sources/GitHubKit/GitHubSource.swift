import Foundation
import SourceKit

/// A GitHub repository as a source (#30): each release with an `.ipa` is a
/// version, the newest release is the default install and the update
/// target, and IPAs with different bundle IDs are different apps.
///
/// The result is an AltStore Classic source, written out as JSON and parsed
/// like any other, so everything that reads sources (Browse, version
/// history, downloads, update checks) works unchanged. What Atelier learned
/// about each asset is kept in the JSON under `atelierGitHub`, so a refresh
/// only reads the IPAs it hasn't seen.
///
/// Releases don't say which app an IPA is, so Atelier reads the bundle ID,
/// name, version and icon from inside it (`RemoteIPA`). To keep adding a
/// repo with a long history quick, only a few IPAs of each kind (by file
/// name without version numbers) are read: the newest and the oldest, and
/// if those are different apps, enough between to find where it changed.
/// The rest take their app from the nearest one read, and their version
/// from the release tag. Version History names every version by its tag
/// (#104), read or not.
///
/// Pre-releases, by GitHub's mark or their tag, are read with the releases
/// (#104): each of their versions is marked `atelierPrerelease`, a beta
/// among the app's releases, and an app found only in pre-releases is a
/// beta app. Include Pre-releases then hides them as it hides any source's
/// betas.
public actor GitHubSource {
	/// The key Atelier's own notes live under in the JSON. Parsers ignore it.
	static let notesKey = "atelierGitHub"
	/// IPAs read per fetch at most, so a first add stays quick; the rest are
	/// read on later refreshes.
	static let readsPerFetch = 24
	/// Goes up when the way assets become apps changes, so sources written
	/// before are worked out again even when GitHub has nothing new.
	/// 9: pre-releases are always read (#104).
	static let format = 9
	/// The oldest format whose notes on assets are still right.
	static let assetsFormat = 2

	/// What Atelier read from one release asset.
	struct AssetInfo: Codable, Equatable {
		var bundleID: String?
		var name: String?
		var version: String?
		var build: String?
		var minOS: String?
		/// A colour from the app's icon, six hex digits.
		var tint: String?
		/// It couldn't be read as an app, so it's left out and not tried again.
		var failed: Bool?
	}

	/// What Atelier keeps about the repo between refreshes.
	struct Notes: Codable, Equatable {
		var format: Int?
		var repo: String
		var isPrivate: Bool
		var description: String?
		var website: String?
		var ownerName: String?
		var repoETag: String?
		var releaseCount: Int
		var assets: [String: AssetInfo]
	}

	/// What the add sheet shows about a repo.
	public struct Summary: Sendable, Equatable {
		/// `Owner/Repo` as GitHub spells it.
		public var fullName: String
		public var isPrivate: Bool
		/// Releases that are listed as versions.
		public var releaseCount: Int
	}

	/// Which account reads each repo (#74).
	private let credentials: any GitHubCredentials
	private let ipa: RemoteIPA
	private let tint: @Sendable (Data) -> String?
	/// Assets read since launch, so showing a repo again doesn't read them
	/// again.
	private var memory: [Int: AssetInfo] = [:]
	/// App icons read since launch, by asset.
	private var icons: [Int: Data] = [:]

	public init(
		credentials: any GitHubCredentials,
		ipa: RemoteIPA = RemoteIPA(),
		tint: @escaping @Sendable (Data) -> String? = { _ in nil }
	) {
		self.credentials = credentials
		self.ipa = ipa
		self.tint = tint
	}

	/// Every repo read with `api`.
	public init(
		api: GitHubAPI = GitHubAPI(),
		ipa: RemoteIPA = RemoteIPA(),
		tint: @escaping @Sendable (Data) -> String? = { _ in nil }
	) {
		self.init(credentials: OneAPI(api: api), ipa: ipa, tint: tint)
	}

	/// The same API for every repo.
	private struct OneAPI: GitHubCredentials {
		let api: GitHubAPI
		func candidates(for repo: GitHubRepo) -> [GitHubCredential] { [GitHubCredential(account: nil, api: api)] }
		func remember(_ account: GitHubAccount, for repo: GitHubRepo) {}
	}

	/// The colour a GitHub source has when its apps' icons give none.
	public static let defaultTint = "24292F"

	/// The repo's notes from a source JSON this type wrote.
	public static func summary(of json: Data) -> Summary? {
		guard let notes = notes(in: json) else { return nil }
		return Summary(fullName: notes.repo, isPrivate: notes.isPrivate, releaseCount: notes.releaseCount)
	}

	/// Fetches the repo's releases and turns them into a source. `previous`
	/// is the JSON from the last fetch, whose notes save reading IPAs again;
	/// `etag` is only sent along with it.
	public func fetch(_ repo: GitHubRepo, etag: String? = nil, previous: Data? = nil) async throws -> SourceFetcher.Outcome {
		let previousNotes = previous.flatMap(Self.notes(in:))
		let current = previousNotes?.format == Self.format ? previousNotes : nil

		// The repo's details (its description, say) and its releases each
		// have an ETag, so a refresh with nothing new costs nothing. Asking
		// for the details also finds the account that can see the repo
		// (#74), which asks for the rest.
		var repository: GitHubAPI.Repository
		let repoETag: String?
		let knownETag = current?.repoETag
		let (details, api) = try await credentials.first(for: repo) { try await $0.repository(repo, etag: knownETag) }
		switch details {
		case .fetched(var fetched, let tag):
			fetched.ownerName = try await api.ownerName(repo)
			repository = fetched
			repoETag = tag
		case .notModified:
			guard let notes = current else { throw GitHubAPI.Problem.status(304) }
			repository = GitHubAPI.Repository(
				fullName: notes.repo,
				name: String(notes.repo.split(separator: "/").last ?? Substring(repo.name)),
				description: notes.description,
				isPrivate: notes.isPrivate,
				htmlURL: notes.website.flatMap(URL.init(string:)),
				ownerName: notes.ownerName
			)
			repoETag = notes.repoETag
		}
		let repoChanged = current == nil || repoETag != current?.repoETag

		let releases: [GitHubAPI.Release]
		let newETag: String?
		// When the repo changed the source is written again, which needs the
		// list itself.
		switch try await api.releases(repo, etag: repoChanged ? nil : etag) {
		case .notModified:
			return .notModified
		case .fetched(let list, let tag):
			releases = list
			newETag = tag
		}

		let listed = releases
			.map { release in
				var release = release
				// TrollStore's .tipa and anything else isn't for Atelier.
				release.assets = release.assets.filter { $0.name.lowercased().hasSuffix(".ipa") }
				return release
			}
			.filter { !$0.assets.isEmpty }
			.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
		guard !listed.isEmpty else { throw GitHubAPI.Problem.noReleases(repo) }

		var known: [Int: AssetInfo] = memory
		// Assets noted before the way they're read changed are read again.
		for (id, info) in (previousNotes?.format ?? 0) >= Self.assetsFormat ? previousNotes!.assets : [:] {
			if let id = Int(id) { known[id] = info }
		}
		try await readApps(of: listed, known: &known, isPrivate: repository.isPrivate, api: api)

		let previousIcons = previous.map(Self.icons(in:)) ?? [:]
		let json = Self.sourceJSON(
			repo: repo,
			repository: repository,
			releases: listed,
			known: known,
			icons: previousIcons.merging(newestIcons(of: listed, known: known)) { _, new in new },
			repoETag: repoETag
		)
		let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
		let parsed = try SourceParser.parse(data)
		return .fetched(SourceFetcher.Fetched(data: data, parsed: parsed, etag: newETag, lastModified: nil))
	}

	// MARK: Reading IPAs

	/// Reads what Atelier needs to know which app each asset is: the newest
	/// and oldest of each kind of file name, and when those are different
	/// apps (an app that changed its bundle ID, say), the releases between,
	/// halving the gap until the release where it changed is found.
	private func readApps(of releases: [GitHubAPI.Release], known: inout [Int: AssetInfo], isPrivate: Bool, api: GitHubAPI) async throws {
		var budget = Self.readsPerFetch
		while budget > 0 {
			let toRead = Self.assetsToRead(in: releases, known: known, limit: budget)
			guard !toRead.isEmpty else { break }
			budget -= toRead.count
			try await read(toRead, into: &known, isPrivate: isPrivate, api: api)
		}
	}

	/// The assets of each kind, newest first, leaving out the ones that
	/// couldn't be read as apps.
	static func assetsByKind(_ releases: [GitHubAPI.Release], known: [Int: AssetInfo]) -> [(kind: String, assets: [GitHubAPI.Asset])] {
		var order: [String] = []
		var byKind: [String: [GitHubAPI.Asset]] = [:]
		for release in releases {
			for asset in release.assets where known[asset.id]?.failed != true {
				let kind = kind(of: asset.name)
				if byKind[kind] == nil { order.append(kind) }
				byKind[kind, default: []].append(asset)
			}
		}
		return order.map { ($0, byKind[$0]!) }
	}

	/// The next assets to read, at most `limit`.
	static func assetsToRead(in releases: [GitHubAPI.Release], known: [Int: AssetInfo], limit: Int) -> [GitHubAPI.Asset] {
		var toRead: [GitHubAPI.Asset] = []
		for (_, assets) in assetsByKind(releases, known: known) {
			var wanted: Set<Int> = [0, assets.count - 1]
			let read = assets.indices.filter { known[assets[$0].id]?.bundleID != nil }
			for (newer, older) in zip(read, read.dropFirst())
			where older - newer > 1 && known[assets[newer].id]?.bundleID != known[assets[older].id]?.bundleID {
				wanted.insert((newer + older) / 2)
			}
			for index in wanted.sorted() where known[assets[index].id] == nil {
				toRead.append(assets[index])
			}
		}
		return Array(toRead.prefix(limit))
	}

	private func read(_ toRead: [GitHubAPI.Asset], into known: inout [Int: AssetInfo], isPrivate: Bool, api: GitHubAPI) async throws {
		let ipa = ipa, tint = tint
		var results: [(Int, AssetInfo, Data?)] = []
		// A few at a time: each is a handful of small requests.
		for batch in stride(from: 0, to: toRead.count, by: 4).map({ Array(toRead[$0..<min($0 + 4, toRead.count)]) }) {
			try await withThrowingTaskGroup(of: (Int, AssetInfo, Data?).self) { group in
				for asset in batch {
					group.addTask {
						do {
							let url = try await api.downloadURL(for: isPrivate ? asset.apiURL : asset.browserURL)
							let info = try await ipa.read(url, size: asset.size)
							return (asset.id, AssetInfo(
								bundleID: info.bundleID,
								name: info.name,
								version: info.version,
								build: info.build,
								minOS: info.minimumOSVersion,
								tint: info.icon.flatMap(tint)
							), info.icon)
						} catch let problem as GitHubAPI.Problem {
							// The limit or the token affects every asset; say so.
							throw problem
						} catch is RemoteIPA.Problem {
							return (asset.id, AssetInfo(failed: true), nil)
						}
					}
				}
				for try await result in group { results.append(result) }
			}
		}
		for (id, info, icon) in results {
			known[id] = info
			memory[id] = info
			if let icon { icons[id] = icon }
		}
	}

	/// Each app's icon from the newest release it was read from, by bundle ID.
	private func newestIcons(of releases: [GitHubAPI.Release], known: [Int: AssetInfo]) -> [String: String] {
		var found: [String: String] = [:]
		for release in releases {
			for asset in release.assets {
				guard let icon = icons[asset.id], let bundleID = known[asset.id]?.bundleID, found[bundleID] == nil else { continue }
				found[bundleID] = Self.dataURL(icon)
			}
		}
		return found
	}

	/// An asset's file name without numbers, versions and its extension, so
	/// `Feather_v2.9.0.ipa` and `Feather_v2.8.1.ipa` are the same kind and
	/// `Feather-debug.ipa` isn't.
	static func kind(of fileName: String) -> String { AppBuild.kind(of: fileName) }

	static func isSpecialBuild(_ fileName: String) -> Bool { AppBuild.specialWord(in: fileName) != nil }

	// MARK: The source

	static func sourceJSON(
		repo: GitHubRepo,
		repository: GitHubAPI.Repository,
		releases: [GitHubAPI.Release],
		known: [Int: AssetInfo],
		icons: [String: String],
		repoETag: String? = nil
	) -> [String: Any] {
		// Assets that weren't read are the app of the nearest newer one of
		// their kind that was, or failing that the nearest older one.
		var inherited: [Int: AssetInfo] = [:]
		for (_, assets) in assetsByKind(releases, known: known) {
			let read = assets.compactMap { asset in known[asset.id].flatMap { $0.bundleID == nil ? nil : $0 } }
			var newer: AssetInfo?
			for asset in assets {
				if let info = known[asset.id], info.bundleID != nil {
					newer = info
				} else if let info = newer ?? read.first {
					inherited[asset.id] = info
				}
			}
		}

		var order: [String] = []
		var names: [String: String] = [:]
		var tints: [String: String] = [:]
		var versions: [String: [[String: Any]]] = [:]
		var usedReleases: Set<Int> = []
		// The apps with a version from a release, not only pre-releases.
		var released: Set<String> = []
		for release in releases {
			let prerelease = isPrerelease(release)
			// Several builds of one app in a release are listed as the
			// version's builds to choose from; the usual one is its download.
			var builds: [String: [(GitHubAPI.Asset, AssetInfo, read: Bool)]] = [:]
			for asset in release.assets {
				let read = known[asset.id]
				if read?.failed == true { continue }
				guard let info = read ?? inherited[asset.id], let bundleID = info.bundleID else { continue }
				builds[bundleID, default: []].append((asset, info, read: read != nil))
			}
			for (bundleID, candidates) in builds.sorted(by: { $0.key < $1.key }) {
				let (asset, info, read) = candidates.max { isBetterBuild($1.0, than: $0.0) }!
				if names[bundleID] == nil {
					order.append(bundleID)
					names[bundleID] = info.name
					if let tint = info.tint { tints[bundleID] = tint }
				}
				usedReleases.insert(release.id)
				var version: [String: Any] = [
					"version": read ? (info.version ?? tagVersion(release.tag)) : tagVersion(release.tag),
					"downloadURL": (repository.isPrivate ? asset.apiURL : asset.browserURL).absoluteString,
					"size": asset.size,
				]
				if read, let build = info.build { version["buildVersion"] = build }
				// What Version History names it by (#104).
				if let tag = Self.tagName(release.tag) { version["atelierTag"] = tag }
				// A beta, whatever the IPA's version number says (#104).
				if prerelease {
					version["atelierPrerelease"] = true
				} else {
					released.insert(bundleID)
				}
				if let date = release.publishedAt { version["date"] = ISO8601DateFormatter().string(from: date) }
				if let notes = releaseNotes(release) { version["localizedDescription"] = notes }
				if read, let minOS = info.minOS { version["minOSVersion"] = minOS }
				if candidates.count > 1 {
					version["atelierBuilds"] = candidates.map { asset, info, read -> [String: Any] in
						var build: [String: Any] = [
							"name": asset.name,
							"downloadURL": (repository.isPrivate ? asset.apiURL : asset.browserURL).absoluteString,
							"size": asset.size,
							"special": isSpecialBuild(asset.name),
						]
						if read, let minOS = info.minOS { build["minOSVersion"] = minOS }
						return build
					}
				}
				versions[bundleID, default: []].append(version)
			}
		}

		let owner = String(repository.fullName.split(separator: "/").first ?? Substring(repo.owner))
		// Apps found only in pre-releases after the others, so the source's
		// first app, and its colour, are the same with pre-releases hidden
		// (#104).
		let ordered = order.filter(released.contains) + order.filter { !released.contains($0) }
		let apps: [[String: Any]] = ordered.map { bundleID in
			var app: [String: Any] = [
				"name": names[bundleID] ?? repository.name,
				"bundleIdentifier": bundleID,
				"developerName": developer(login: owner, name: repository.ownerName),
				"versions": versions[bundleID] ?? [],
			]
			// About, not the one-line subtitle: a repo's description is
			// often longer than a line.
			if let description = repository.description { app["localizedDescription"] = description }
			if let icon = icons[bundleID] { app["iconURL"] = icon }
			if let tint = tints[bundleID] { app["tintColor"] = tint }
			// Only in pre-releases: a beta app, flagged as AltStore's own
			// source flags its betas.
			if !released.contains(bundleID) { app["beta"] = true }
			return app
		}

		var assets: [String: [String: Any]] = [:]
		for (id, info) in known {
			// Only what this repo still lists, so the notes don't grow forever.
			guard releases.contains(where: { $0.assets.contains { $0.id == id } }) else { continue }
			assets[String(id)] = assetJSON(info)
		}
		var notes: [String: Any] = [
			"format": format,
			"repo": repository.fullName,
			"isPrivate": repository.isPrivate,
			"releaseCount": usedReleases.count,
			"assets": assets,
		]
		if let description = repository.description { notes["description"] = description }
		if let website = repository.htmlURL { notes["website"] = website.absoluteString }
		if let ownerName = repository.ownerName { notes["ownerName"] = ownerName }
		if let repoETag { notes["repoETag"] = repoETag }

		var source: [String: Any] = [
			// The repo's name, whichever apps it has (#104).
			"name": repository.name,
			"identifier": "com.github.\(repo.owner).\(repo.name)",
			"subtitle": repository.fullName,
			"tintColor": ordered.first.flatMap { tints[$0] } ?? defaultTint,
			"apps": apps,
			"news": [],
			notesKey: notes,
		]
		if let description = repository.description { source["description"] = description }
		if let website = repository.htmlURL { source["website"] = website.absoluteString }
		return source
	}

	/// The usual build: not a debug or special build, then the largest.
	static func isBetterBuild(_ asset: GitHubAPI.Asset, than other: GitHubAPI.Asset) -> Bool {
		let special = isSpecialBuild(asset.name), otherSpecial = isSpecialBuild(other.name)
		if special != otherSpecial { return !special }
		return asset.size > other.size
	}

	/// `Sam Sample (@sample-user)`, `CLARATION (@claration)`,
	/// or `@someone` for an account without a name: GitHub's way of writing
	/// a handle.
	static func developer(login: String, name: String?) -> String {
		guard let name else { return "@\(login)" }
		return "\(name) (@\(login))"
	}

	/// `v2.9.0` → `2.9.0`.
	static func tagVersion(_ tag: String) -> String {
		if let first = tag.first, first == "v" || first == "V", tag.dropFirst().first?.isNumber == true {
			return String(tag.dropFirst())
		}
		return tag
	}

	/// Whether a release is a pre-release (#104): GitHub marks it as one, or
	/// its tag says so, as some developers publish betas without the mark.
	public static func isPrerelease(_ release: GitHubAPI.Release) -> Bool {
		release.isPrerelease || isPrereleaseTag(release.tag)
	}

	/// `v0.6.3-beta`, `0.2.0-alpha`, `2.0b3`, `v1.0-rc.1`, `v2.0-preview`,
	/// `nightly`; not `v1.2-hotfix` or `devtools-1.0`.
	static func isPrereleaseTag(_ tag: String) -> Bool {
		if VersionNumber.isPrerelease(tagVersion(tag)) { return true }
		return tag.lowercased().split { !$0.isLetter }.contains { prereleaseWords.contains(String($0)) }
	}

	private static let prereleaseWords: Set<String> = ["alpha", "beta", "rc", "pre", "prerelease", "preview", "dev", "nightly", "canary"]

	/// The name Version History gives a release's versions (#104): its tag
	/// as `tagVersion` writes it, so a beta says it's one (`0.6.5-beta` for
	/// an IPA that says 0.6.5) and no row has a build number the others
	/// don't. None for a tag without a number, such as `nightly`, which
	/// says nothing of the version.
	static func tagName(_ tag: String) -> String? {
		let tagged = tagVersion(tag)
		return tagged.contains(where: \.isNumber) ? tagged : nil
	}

	static func releaseNotes(_ release: GitHubAPI.Release) -> String? {
		let title = release.name.flatMap { $0 == release.tag || $0 == tagVersion(release.tag) ? nil : $0 }
		switch (title, release.notes) {
		case let (title?, notes?): return "\(title)\n\n\(notes)"
		case let (title?, nil): return title
		case let (nil, notes): return notes
		}
	}

	private static func assetJSON(_ info: AssetInfo) -> [String: Any] {
		var json: [String: Any] = [:]
		if let value = info.bundleID { json["bundleID"] = value }
		if let value = info.name { json["name"] = value }
		if let value = info.version { json["version"] = value }
		if let value = info.build { json["build"] = value }
		if let value = info.minOS { json["minOS"] = value }
		if let value = info.tint { json["tint"] = value }
		if let value = info.failed { json["failed"] = value }
		return json
	}

	static func dataURL(_ png: Data) -> String {
		"data:image/png;base64," + png.base64EncodedString()
	}

	// MARK: Reading back

	static func notes(in json: Data) -> Notes? {
		guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
			let notes = object[notesKey],
			let data = try? JSONSerialization.data(withJSONObject: notes)
		else { return nil }
		return try? JSONDecoder().decode(Notes.self, from: data)
	}

	/// The icons the last fetch found, by bundle ID.
	static func icons(in json: Data) -> [String: String] {
		guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
			let apps = object["apps"] as? [[String: Any]]
		else { return [:] }
		var icons: [String: String] = [:]
		for app in apps {
			if let bundleID = app["bundleIdentifier"] as? String, let icon = app["iconURL"] as? String { icons[bundleID] = icon }
		}
		return icons
	}
}

// MARK: A source kept in a repo (#24)

extension GitHubSource {
	/// An AltStore source kept in a GitHub repo, read through a GitHub
	/// account that can see the repo: while the repo is private,
	/// raw.githubusercontent.com answers 404, as it does for Atelier's own
	/// source until its repo is public. Its downloads from the repo's
	/// releases move to GitHub's API, as a private repo's own releases
	/// download (#74); the app loads the images kept in the repo through an
	/// account too. `etag` is the last read's.
	public func fetch(_ file: GitHubFile, etag: String? = nil) async throws -> SourceFetcher.Outcome {
		let repo = file.repo
		// Without an account, GitHub's API can't see a private repo either.
		guard credentials.candidates(for: repo).contains(where: { $0.account != nil }) else {
			throw GitHubAPI.Problem.notFound(repo, accounts: 0)
		}
		let (result, api) = try await credentials.first(for: repo) { try await $0.file(file, etag: etag) }
		guard case .fetched(let data, let newETag) = result else { return .notModified }
		guard data.count <= SourceFetcher.maximumSize else { throw SourceFetcher.Problem.tooLarge }
		let json: Any
		do {
			_ = try SourceParser.parse(data)
			json = try JSONSerialization.jsonObject(with: data)
		} catch {
			throw SourceFetcher.Problem.notASource(String(describing: error))
		}
		var moves: [String: String] = [:]
		if case .fetched(let releases, _) = try await api.releases(repo) {
			moves = GitHubAPI.apiURLs(of: releases).mapValues(\.absoluteString)
		}
		let moved = try JSONSerialization.data(withJSONObject: Self.moving(moves, in: json))
		return .fetched(SourceFetcher.Fetched(data: moved, parsed: try SourceParser.parse(moved), etag: newETag))
	}

	/// `json` with each string that `moves` has, lowercased, replaced by
	/// what it maps to.
	static func moving(_ moves: [String: String], in json: Any) -> Any {
		switch json {
		case let string as String: moves[string.lowercased()] ?? string
		case let object as [String: Any]: object.mapValues { moving(moves, in: $0) }
		case let array as [Any]: array.map { moving(moves, in: $0) }
		default: json
		}
	}
}
