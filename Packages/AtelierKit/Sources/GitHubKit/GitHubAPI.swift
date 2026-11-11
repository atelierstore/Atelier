import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SourceKit

/// The few GitHub REST calls a repo source needs (#30): the repo, its
/// releases, and where a release asset actually downloads from.
///
/// Requests carry one account's access token when there is one, which lifts
/// GitHub's limit from 60 requests an hour per IP address to 5,000 per user
/// and is what lets Atelier see private repos. Which account asks for a
/// repo is `GitHubCredentials`'s choice (#74).
public struct GitHubAPI: Sendable {
	public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	public enum Problem: Error, Equatable, CustomStringConvertible {
		/// The repo doesn't exist, or it's private and none of the
		/// `accounts` that asked can see it (GitHub answers 404 for both).
		/// `organization` is its owner when that's an organization, which
		/// may limit which apps can read its repos (#74).
		case notFound(GitHubRepo, accounts: Int, organization: String? = nil)
		/// GitHub refused the token of `account`, by login when it's known.
		case badToken(account: String? = nil)
		/// The hourly limit is used up, until `reset` when GitHub says.
		case rateLimited(reset: Date?, hasToken: Bool)
		case status(Int)
		case notJSON
		case noReleases(GitHubRepo)

		public var description: String {
			switch self {
			case .notFound(let repo, let accounts, let organization):
				Self.notFound(repo, accounts: accounts) + (organization.map {
					" If \($0) limits which apps can read its repos, an owner has to approve Atelier first."
				} ?? "")
			case .badToken(let account):
				account.map { "GitHub didn't accept the sign-in of @\($0). Sign in to it again in Browse › Manage Sources." }
					?? "GitHub didn't accept your sign-in. Sign in again in Browse › Manage Sources."
			case .rateLimited(let reset, let hasToken):
				"GitHub's limit is used up"
					+ (reset.map { ". Try again after \(Self.time($0))" } ?? ". Try again later")
					+ (hasToken ? "." : ", or sign in to GitHub in Browse › Manage Sources.")
			case .status(let code):
				(500...599).contains(code) ? "GitHub had a problem. Try again later." : "GitHub refused the request (error \(code))."
			case .notJSON:
				"GitHub sent something Atelier couldn't read."
			case .noReleases(let repo):
				"\(repo) has no releases with an .ipa file."
			}
		}

		private static func notFound(_ repo: GitHubRepo, accounts: Int) -> String {
			switch accounts {
			case 0: "GitHub can't find \(repo). If it's private, sign in to GitHub in Browse › Manage Sources."
			case 1: "Your GitHub account can't see \(repo), or it doesn't exist."
			default: "None of your GitHub accounts can see \(repo), or it doesn't exist."
			}
		}

		private static func time(_ date: Date) -> String {
			let formatter = DateFormatter()
			formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
			formatter.timeStyle = .short
			return formatter.string(from: date)
		}

		/// Whether another account might do better: one that can see the
		/// repo, or isn't over its limit (#74).
		var triesAnotherAccount: Bool {
			switch self {
			case .notFound, .badToken, .rateLimited, .status(403): true
			default: false
			}
		}

		var isRateLimit: Bool {
			if case .rateLimited = self { return true }
			return false
		}

		var isRefusedToken: Bool {
			if case .badToken = self { return true }
			return false
		}

		/// The same, saying whose sign-in GitHub refused.
		public func naming(_ account: GitHubAccount?) -> Problem {
			if case .badToken(nil) = self, let login = account?.login { return .badToken(account: login) }
			return self
		}
	}

	/// What GitHub says about the repo itself.
	public struct Repository: Sendable, Equatable {
		/// `Owner/Repo` as GitHub spells it.
		public var fullName: String
		public var name: String
		public var description: String?
		public var isPrivate: Bool
		public var htmlURL: URL?
		/// The owner's name as their GitHub profile shows it, when they set
		/// one. Not part of GitHub's answer about the repo: `ownerName(_:)`.
		public var ownerName: String?
	}

	public struct Release: Sendable, Equatable {
		public var id: Int
		public var tag: String
		public var name: String?
		public var notes: String?
		public var isPrerelease: Bool
		public var publishedAt: Date?
		public var assets: [Asset]
	}

	public struct Asset: Sendable, Equatable {
		public var id: Int
		public var name: String
		public var size: Int64
		/// `github.com/…/releases/download/…`: works without a token for
		/// public repos.
		public var browserURL: URL
		/// `api.github.com/…/releases/assets/<id>`: needs the token for
		/// private repos, and `Accept: application/octet-stream`.
		public var apiURL: URL
	}

	public enum Releases: Sendable {
		case fetched([Release], etag: String?)
		/// HTTP 304: the list is the one Atelier has. Free under the limit.
		case notModified
	}

	public static let apiHost = "api.github.com"

	private let load: Load
	private let loadWithoutRedirects: Load
	private let token: @Sendable () -> String?

	/// `load` follows redirects; `loadWithoutRedirects` must not, so
	/// `downloadURL(for:)` can read where an asset is.
	public init(
		token: @escaping @Sendable () -> String? = { nil },
		load: @escaping Load = { try await URLSession.shared.data(for: $0) },
		loadWithoutRedirects: @escaping Load = { try await NoRedirects.session.data(for: $0) }
	) {
		self.token = token
		self.load = load
		self.loadWithoutRedirects = loadWithoutRedirects
	}

	public var hasToken: Bool { !(token() ?? "").isEmpty }

	public func repository(_ repo: GitHubRepo) async throws -> Repository {
		guard case .fetched(let repository, _) = try await repository(repo, etag: nil) else { throw Problem.notJSON }
		return repository
	}

	public enum RepositoryResult: Sendable {
		case fetched(Repository, etag: String?)
		/// HTTP 304: nothing about the repo changed. Free under the limit.
		case notModified
	}

	/// The repo, or `.notModified` when `etag` still matches.
	public func repository(_ repo: GitHubRepo, etag: String?) async throws -> RepositoryResult {
		let (data, response) = try await get("repos/\(repo.owner)/\(repo.name)", repo: repo, etag: etag)
		if response.statusCode == 304 { return .notModified }
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let fullName = json["full_name"] as? String
		else { throw Problem.notJSON }
		return .fetched(Repository(
			fullName: fullName,
			name: json["name"] as? String ?? repo.name,
			description: (json["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
			isPrivate: json["private"] as? Bool ?? false,
			htmlURL: (json["html_url"] as? String).flatMap(URL.init(string:))
		), etag: response.value(forHTTPHeaderField: "ETag"))
	}

	/// The name a user or organization shows on their profile, or nil when
	/// they haven't set one.
	public func ownerName(_ repo: GitHubRepo) async throws -> String? {
		let data: Data
		do {
			(data, _) = try await get("users/\(repo.owner)", repo: repo)
		} catch Problem.notFound {
			return nil
		}
		let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		return (json?["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
	}

	/// Whether `owner` is an organization rather than a person (#74); false
	/// when GitHub doesn't say.
	public func isOrganization(_ owner: String) async -> Bool {
		guard let answer = try? await get("users/\(owner)", repo: nil) else { return false }
		let json = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any]
		return json?["type"] as? String == "Organization"
	}

	/// Who the token belongs to.
	public struct User: Sendable, Equatable {
		public var login: String
		public var avatarURL: URL?
	}

	/// Who the token belongs to: for a sign-in, and for a pasted token, so it
	/// can be listed by name (#74).
	public func user() async throws -> User {
		let (data, _) = try await get("user", repo: nil)
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let login = json["login"] as? String else {
			throw Problem.notJSON
		}
		return User(login: login, avatarURL: (json["avatar_url"] as? String).flatMap(URL.init(string:)))
	}

	/// A repo in a list of the user's repos or stars.
	public struct Listing: Sendable, Equatable, Identifiable {
		public var repo: GitHubRepo
		/// `Owner/Repo` as GitHub spells it.
		public var fullName: String
		public var isPrivate: Bool
		public var id: String { fullName }
	}

	/// The repos the signed-in user owns or works on, most recently pushed
	/// first.
	public func myRepos() async throws -> [Listing] {
		try await listings("user/repos?per_page=100&sort=pushed")
	}

	/// The repos the signed-in user starred, most recently starred first.
	public func starredRepos() async throws -> [Listing] {
		try await listings("user/starred?per_page=100")
	}

	private func listings(_ path: String) async throws -> [Listing] {
		let (data, _) = try await get(path, repo: nil)
		guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Problem.notJSON }
		return list.compactMap { json in
			guard let fullName = json["full_name"] as? String, let repo = GitHubRepo(shorthand: fullName) else { return nil }
			return Listing(repo: repo, fullName: fullName, isPrivate: json["private"] as? Bool ?? false)
		}
	}

	/// The newest release with an .ipa, pre-releases included, among the
	/// latest 20; nil when there's none.
	public func newestAppRelease(_ repo: GitHubRepo) async throws -> Release? {
		let (data, _) = try await get("repos/\(repo.owner)/\(repo.name)/releases?per_page=20", repo: repo)
		guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Problem.notJSON }
		return list.compactMap(Self.release)
			.filter { $0.assets.contains { $0.name.lowercased().hasSuffix(".ipa") } }
			.max { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }
	}

	/// The newest 100 releases, newest first, without drafts.
	public func releases(_ repo: GitHubRepo, etag: String? = nil) async throws -> Releases {
		let (data, response) = try await get("repos/\(repo.owner)/\(repo.name)/releases?per_page=100", repo: repo, etag: etag)
		if response.statusCode == 304 { return .notModified }
		guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Problem.notJSON }
		let releases = list.compactMap(Self.release)
		return .fetched(releases, etag: response.value(forHTTPHeaderField: "ETag"))
	}

	public enum FileResult: Sendable {
		case fetched(Data, etag: String?)
		/// HTTP 304: the file is the one Atelier has. Free under the limit.
		case notModified
	}

	/// A file in a repo as it is on its branch or tag, raw, or `.notModified`
	/// when `etag` still matches: how Atelier reads a source, or an image,
	/// kept in a private repo, which raw.githubusercontent.com answers 404
	/// for, as Atelier's own is while its repo is private (#24).
	public func file(_ file: GitHubFile, etag: String? = nil) async throws -> FileResult {
		let repo = file.repo
		let escapedPath = file.path.split(separator: "/")
			.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
			.joined(separator: "/")
		var query = CharacterSet.urlQueryAllowed
		query.remove(charactersIn: "&=+?#")
		let escapedRef = file.ref.addingPercentEncoding(withAllowedCharacters: query) ?? file.ref
		let (data, response) = try await get("repos/\(repo.owner)/\(repo.name)/contents/\(escapedPath)?ref=\(escapedRef)", repo: repo, etag: etag, accept: "application/vnd.github.raw+json")
		if response.statusCode == 304 { return .notModified }
		return .fetched(data, etag: response.value(forHTTPHeaderField: "ETag"))
	}

	/// Each of `releases`' assets' API URL, by its github.com URL, lowercased:
	/// where a private repo's downloads move to, as github.com answers 404
	/// for them while an API URL downloads with the token of an account that
	/// can see the repo (#24).
	public static func apiURLs(of releases: [Release]) -> [String: URL] {
		var assets: [String: URL] = [:]
		for asset in releases.flatMap(\.assets) where assets[asset.browserURL.absoluteString.lowercased()] == nil {
			assets[asset.browserURL.absoluteString.lowercased()] = asset.apiURL
		}
		return assets
	}

	/// Where an asset's bytes are: GitHub answers an asset URL with a
	/// redirect to short-lived storage, which takes range requests and needs
	/// no token. Taken by hand so the token never goes to that storage.
	public func downloadURL(for assetURL: URL) async throws -> URL {
		var request = URLRequest(url: assetURL, timeoutInterval: 30)
		request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
		if assetURL.host?.lowercased() == Self.apiHost, let token = token(), !token.isEmpty {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		let (data, response) = try await loadWithoutRedirects(request)
		guard let http = response as? HTTPURLResponse else { throw Problem.status(0) }
		switch http.statusCode {
		case 300..<400:
			guard let location = http.value(forHTTPHeaderField: "Location"),
				let url = URL(string: location, relativeTo: assetURL)?.absoluteURL,
				url.scheme?.lowercased() == "https"
			else { throw Problem.status(http.statusCode) }
			return url
		case 200..<300:
			// Served directly; the asset URL itself takes ranges.
			return assetURL
		default:
			throw problem(for: http, data: data, repo: Self.repo(ofAsset: assetURL))
		}
	}

	/// The release tagged `tag`, or the latest one when `tag` is nil, as
	/// links to a release's files on github.com name them.
	public func taggedRelease(_ repo: GitHubRepo, tag: String?) async throws -> Release {
		let releases = "repos/\(repo.owner)/\(repo.name)/releases"
		let path = tag.map { tag in
			"\(releases)/tags/" + tag.split(separator: "/", omittingEmptySubsequences: false)
				.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
				.joined(separator: "/")
		} ?? "\(releases)/latest"
		let (data, _) = try await get(path, repo: repo)
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let release = Self.release(json) else {
			throw Problem.notJSON
		}
		return release
	}

	/// Where a file in a release downloads from, by its link on github.com
	/// (#134): the same as its asset behind the API, which downloads with
	/// the token of an account that can see the repo, while github.com
	/// answers 404 for a private repo's. Nil when the repo has no such
	/// release or file, which github.com can say itself.
	public func downloadURL(for link: GitHubReleaseLink) async throws -> URL? {
		let release: Release
		do {
			release = try await taggedRelease(link.repo, tag: link.tag)
		} catch Problem.notFound {
			// GitHub answers 404 for a release it doesn't have, as for a repo
			// the account can't see: the repo itself says which.
			_ = try await repository(link.repo)
			return nil
		}
		guard let asset = Self.asset(named: link.name, in: release) else { return nil }
		return try await downloadURL(for: asset.apiURL)
	}

	/// The release's file by the name its link gives, which GitHub matches
	/// exactly; a link written in other capitals still finds it.
	static func asset(named name: String, in release: Release) -> Asset? {
		release.assets.first { $0.name == name } ?? release.assets.first { $0.name.lowercased() == name.lowercased() }
	}

	/// Whether `url` is a release asset behind GitHub's API, which only
	/// downloads after `downloadURL(for:)` (private repos).
	public static func isAPIAsset(_ url: URL) -> Bool {
		url.host?.lowercased() == apiHost && url.path.contains("/releases/assets/")
	}

	/// The repo an asset behind GitHub's API belongs to:
	/// `api.github.com/repos/<owner>/<repo>/releases/assets/<id>`.
	public static func repo(ofAsset url: URL) -> GitHubRepo? {
		guard isAPIAsset(url) else { return nil }
		let parts = url.path.split(separator: "/").map(String.init)
		guard parts.count == 6, parts[0] == "repos", parts[3] == "releases", parts[4] == "assets" else { return nil }
		return GitHubRepo(owner: parts[1], name: parts[2])
	}

	// MARK: Requests

	private func get(_ path: String, repo: GitHubRepo?, etag: String? = nil, accept: String = "application/vnd.github+json") async throws -> (Data, HTTPURLResponse) {
		var request = URLRequest(url: URL(string: "https://\(Self.apiHost)/\(path)")!, timeoutInterval: 30)
		// Atelier keeps the list and its ETag itself, so a cached response
		// must not stand in for GitHub's 304.
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue(accept, forHTTPHeaderField: "Accept")
		request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		if let token = token(), !token.isEmpty {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
		let (data, response) = try await load(request)
		guard let http = response as? HTTPURLResponse else { throw Problem.status(0) }
		guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
			throw problem(for: http, data: data, repo: repo)
		}
		return (data, http)
	}

	private func problem(for response: HTTPURLResponse, data: Data, repo: GitHubRepo?) -> Problem {
		let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
		let accounts = hasToken ? 1 : 0
		switch response.statusCode {
		case 403 where remaining == "0", 429:
			let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
				.flatMap(TimeInterval.init)
				.map(Date.init(timeIntervalSince1970:))
			return .rateLimited(reset: reset, hasToken: hasToken)
		case 401:
			return .badToken()
		case 403 where repo != nil && Self.isRestrictedByOrganization(data):
			return .notFound(repo!, accounts: accounts, organization: repo!.owner)
		case 404 where repo != nil:
			return .notFound(repo!, accounts: accounts)
		default:
			return .status(response.statusCode)
		}
	}

	/// GitHub's answer when the repo's organization limits which OAuth apps
	/// can read its repos, and hasn't approved Atelier (#74). Reading a
	/// private repo then mostly gets a 404, as if the user weren't a member.
	static func isRestrictedByOrganization(_ data: Data) -> Bool {
		let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		return (json?["message"] as? String)?.contains("OAuth App access restrictions") == true
	}

	private static let dateFormatter = ISO8601DateFormatter()

	static func release(_ json: [String: Any]) -> Release? {
		guard let id = json["id"] as? Int, let tag = json["tag_name"] as? String else { return nil }
		if json["draft"] as? Bool == true { return nil }
		let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { asset -> Asset? in
			guard let id = asset["id"] as? Int,
				let name = asset["name"] as? String,
				let browser = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
				let api = (asset["url"] as? String).flatMap(URL.init(string:))
			else { return nil }
			if let state = asset["state"] as? String, state != "uploaded" { return nil }
			let size = (asset["size"] as? Int).map(Int64.init) ?? 0
			return Asset(id: id, name: name, size: size, browserURL: browser, apiURL: api)
		}
		return Release(
			id: id,
			tag: tag,
			name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
			notes: (json["body"] as? String).flatMap { $0.isEmpty ? nil : $0 },
			isPrerelease: json["prerelease"] as? Bool ?? false,
			publishedAt: (json["published_at"] as? String).flatMap(dateFormatter.date(from:)),
			assets: assets
		)
	}
}

/// A session that hands redirects back instead of following them.
public final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	public static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

	public func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}
