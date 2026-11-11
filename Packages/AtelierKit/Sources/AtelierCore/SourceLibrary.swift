#if canImport(SwiftData)
import Foundation
import GitHubKit
import SourceKit
import SwiftData

/// Adds, refreshes and removes the user's sources (#13), keeping each one's
/// JSON and apps in the store so Browse works offline.
///
/// Adding takes two steps so the user sees what they're adding first:
/// `preview(_:)` downloads and parses the source, `add(_:)` keeps it.
@MainActor
public final class SourceLibrary {
	/// A downloaded source the user hasn't added yet.
	public struct Preview: Sendable {
		public var url: URL
		public var fetched: SourceFetcher.Fetched

		public var source: Source { fetched.parsed.source }
		/// The GitHub repo it is, when it's one (#30).
		public var gitHubRepo: GitHubRepo? { GitHubRepo(sourceURL: url) }
		/// What Atelier found in the repo, for a GitHub repo.
		public var gitHubSummary: GitHubSource.Summary? { GitHubSource.summary(of: fetched.data) }
		/// Who the user is trusting with what they install from it: the
		/// site, or for a GitHub repo, its owner's account.
		public var domain: String {
			if let gitHubRepo {
				let owner = gitHubSummary?.fullName.split(separator: "/").first.map(String.init) ?? gitHubRepo.owner
				return "github.com/\(owner)"
			}
			return url.host ?? url.absoluteString
		}
	}

	public enum Problem: Error, Equatable, CustomStringConvertible {
		case alreadyAdded(name: String)
		/// A source kept in a GitHub repo that only an account can read,
		/// while there's none: raw.githubusercontent.com answers 404 for a
		/// private repo's files, as for Atelier's own source while its repo
		/// is private, and GitHub's API for a private repo added as a source
		/// (#134).
		case gitHubSignIn

		public var description: String {
			switch self {
			case .alreadyAdded(let name): "You've already added this source (\(name))."
			case .gitHubSignIn: "Sign in to GitHub to load it."
			}
		}
	}

	private let context: ModelContext
	private let fetcher: SourceFetcher
	private let gitHub: GitHubSource
	/// Which sources list their betas (#104).
	private let prereleases: PrereleasePreferences
	private let now: () -> Date

	public init(
		context: ModelContext,
		fetcher: SourceFetcher = SourceFetcher(),
		gitHub: GitHubSource = GitHubSource(),
		prereleases: PrereleasePreferences = PrereleasePreferences(),
		now: @escaping () -> Date = { Date() }
	) {
		self.context = context
		self.fetcher = fetcher
		self.gitHub = gitHub
		self.prereleases = prereleases
		self.now = now
	}

	/// The text to show for an error from this type.
	public static func message(for error: Error) -> String {
		switch error {
		case let problem as Problem: problem.description
		case let problem as SourceLink.Problem: problem.description
		case let problem as SourceFetcher.Problem: problem.description
		case let problem as GitHubAPI.Problem: problem.description
		default: error.localizedDescription
		}
	}

	public func sources() throws -> [SourceRecord] {
		try context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.addedAt)]))
	}

	/// The added source at `url`, which must be normalized.
	public func source(at url: URL) throws -> SourceRecord? {
		// A handful of sources at most, so no predicate.
		try sources().first { $0.url == url }
	}

	/// Downloads and parses the source that `input` names: a URL, or an
	/// `atelier://` or `altstore://` source link.
	public func preview(_ input: String) async throws -> Preview {
		let url = try SourceLink.sourceURL(from: input)
		if let existing = try source(at: url) { throw Problem.alreadyAdded(name: existing.name) }
		let outcome: SourceFetcher.Outcome
		do {
			outcome = try await fetch(url, previous: nil)
		} catch GitHubAPI.Problem.notFound(_, let accounts, _) where accounts == 0 && GitHubRepo(sourceURL: url) == nil {
			// The add sheet says what the server said, as before (#134); for
			// a repo, that GitHub can't find it.
			throw SourceFetcher.Problem.status(404)
		}
		switch outcome {
		case .fetched(let fetched):
			return Preview(url: url, fetched: fetched)
		case .notModified:
			// Only a request with validators can get a 304, and this one has none.
			throw SourceFetcher.Problem.status(304)
		}
	}

	/// Keeps a source, listing its betas when `includingPrereleases` (#104).
	@discardableResult
	public func add(_ preview: Preview, includingPrereleases include: Bool = false) throws -> SourceRecord {
		if let existing = try source(at: preview.url) { throw Problem.alreadyAdded(name: existing.name) }
		prereleases.set(include, for: preview.url)
		let record = SourceRecord(url: preview.url, name: preview.source.name, addedAt: now())
		context.insert(record)
		apply(preview.fetched, to: record)
		record.lastRefreshedAt = now()
		try context.save()
		return record
	}

	/// Puts in the source at `url` that's there without the user adding it:
	/// Atelier's own, which it updates itself from (#24). It comes before
	/// the user's, and its apps with its first refresh. One the user added
	/// before stays, moved to the front. Its betas are listed until the user
	/// turns them off (#104), as Atelier's releases are alphas for now.
	@discardableResult
	public func addBuiltIn(at url: URL, name: String) throws -> SourceRecord {
		if let existing = try source(at: url) {
			if existing.addedAt != .distantPast {
				existing.addedAt = .distantPast
				try context.save()
			}
			return existing
		}
		prereleases.set(true, for: url)
		let record = SourceRecord(url: url, name: name, addedAt: .distantPast)
		context.insert(record)
		try context.save()
		return record
	}

	/// Refreshes one source. A failure is kept in `refreshError` and leaves the
	/// source's apps as they were.
	public func refresh(_ record: SourceRecord) async {
		let url = record.url
		// Without the JSON, a 304 would leave nothing to show.
		let conditional = record.json != nil
		let result: Result<SourceFetcher.Outcome, Error>
		do {
			result = .success(try await fetch(
				url,
				etag: conditional ? record.etag : nil,
				lastModified: conditional ? record.lastModified : nil,
				previous: record.json
			))
		} catch {
			result = .failure(Self.needsSignIn(error) ? Problem.gitHubSignIn : error)
		}
		// The user may have removed the source while it downloaded.
		guard let current = try? source(at: url) else { return }
		switch result {
		case .success(.fetched(let fetched)):
			apply(fetched, to: current)
			current.lastRefreshedAt = now()
			current.refreshError = nil
		case .success(.notModified):
			current.lastRefreshedAt = now()
			current.refreshError = nil
		case .failure(let error):
			current.refreshError = Self.message(for: error)
		}
		try? context.save()
	}

	/// Refreshes every source, downloading them in parallel.
	public func refreshAll() async {
		guard let records = try? sources() else { return }
		let refreshes = records.map { record in Task { await refresh(record) } }
		for refresh in refreshes { await refresh.value }
	}

	/// Removes the source and its apps. Apps installed from it stay installed;
	/// `hasRemovedSource(_:)` then says so.
	public func remove(_ record: SourceRecord) throws {
		let url = record.url
		context.delete(record)
		try context.save()
		prereleases.set(false, for: url)
	}

	/// Lists the source's betas or not (#104), from the JSON it has, so
	/// nothing is downloaded again.
	public func setIncludesPrereleases(_ include: Bool, for record: SourceRecord) {
		prereleases.set(include, for: record.url)
		guard let source = try? record.parsed() else { return }
		list(source, in: record)
		try? context.save()
	}

	/// Whether `install` came from a source the user has since removed.
	public func hasRemovedSource(_ install: InstallRecord) -> Bool {
		guard let url = install.sourceURL else { return false }
		return (try? source(at: url)) == nil
	}

	/// GitHub couldn't find the source's repo without an account, which may
	/// be all it takes to load it (#134): a source kept in a private repo,
	/// as Atelier's own is, or a private repo added as a source.
	private static func needsSignIn(_ error: Error) -> Bool {
		guard case .notFound(_, let accounts, _)? = error as? GitHubAPI.Problem else { return false }
		return accounts == 0
	}

	/// Downloads an AltStore source, or reads a GitHub repo's releases into
	/// one (#30). `previous` is the source's JSON from the last refresh.
	private func fetch(_ url: URL, etag: String? = nil, lastModified: String? = nil, previous: Data?) async throws -> SourceFetcher.Outcome {
		if let repo = GitHubRepo(sourceURL: url) {
			return try await gitHub.fetch(repo, etag: etag, previous: previous)
		}
		do {
			return try await fetcher.fetch(url, etag: etag, lastModified: lastModified)
		} catch SourceFetcher.Problem.status(404) {
			// A source kept in a private GitHub repo, which
			// raw.githubusercontent.com answers 404 for, is read through a
			// GitHub account that can see the repo (#74), as Atelier's own
			// is while its repo is private (#24). Without one, it's
			// `GitHubAPI.Problem.notFound` with no accounts.
			guard let file = GitHubFile(rawURL: url) else { throw SourceFetcher.Problem.status(404) }
			return try await gitHub.fetch(file, etag: etag)
		}
	}

	/// Copies a download into the record.
	private func apply(_ fetched: SourceFetcher.Fetched, to record: SourceRecord) {
		let source = fetched.parsed.source
		record.name = source.name
		record.subtitle = source.subtitle
		record.iconURL = source.effectiveIconURL
		record.tintColor = source.effectiveTintColor
		record.json = fetched.data
		record.etag = fetched.etag
		record.lastModified = fetched.lastModified
		list(source, in: record)
	}

	/// The record's apps as `source` lists them, its betas only while the
	/// user includes them (#104), updated in place so screens showing one
	/// keep it across refreshes.
	private func list(_ source: Source, in record: SourceRecord) {
		// By bundle ID and name, as a source can list several apps under one
		// bundle ID (see `AppName`).
		var existing = Dictionary(
			record.apps.map { (AppName.identity(bundleID: $0.bundleID, name: $0.name), $0) },
			uniquingKeysWith: { first, _ in first }
		)
		for (position, app) in source.listing(prereleases: prereleases.includes(record.url)).apps.enumerated() {
			let latest = app.latestVersion
			let appRecord: AppRecord
			if let found = existing.removeValue(forKey: app.id) {
				appRecord = found
				appRecord.name = app.name
				appRecord.latestVersion = latest?.displayVersion ?? ""
			} else {
				appRecord = AppRecord(bundleID: app.bundleID, name: app.name, latestVersion: latest?.displayVersion ?? "")
				context.insert(appRecord)
				appRecord.source = record
			}
			appRecord.latestVersionDate = latest?.date
			appRecord.developerName = app.developerName
			appRecord.subtitle = app.subtitle
			appRecord.iconURL = app.iconURL
			appRecord.tintColor = app.tintColor
			appRecord.category = app.category.rawValue
			appRecord.position = position
		}
		for gone in existing.values { context.delete(gone) }
	}
}

extension SourceRecord {
	/// Its last refresh found it in a GitHub repo that only an account can
	/// read, and there was none (#134): signing in may be all it takes.
	public var needsGitHubSignIn: Bool {
		refreshError == SourceLibrary.Problem.gitHubSignIn.description
	}
}
#endif
