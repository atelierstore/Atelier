import Foundation
import Observation
import AtelierCore
import SourceKit
import SwiftData

/// Every added source's apps as one `Catalog`, for Browse, search and app
/// details (#14). Rebuilt off the main thread whenever a source's JSON
/// changes, so a refresh of a large source doesn't stall scrolling.
@MainActor
@Observable
final class CatalogModel {
	private(set) var catalog = Catalog.empty
	/// False until the first build finishes, so Browse shows placeholders
	/// rather than "no apps" on launch.
	private(set) var isLoaded = false
	/// Whether a build is running, so the catalog is about to change.
	private(set) var isBuilding = false
	/// How much Browse showed when it last loaded, for its placeholders
	/// until the first build finishes.
	let shape = BrowseShape.saved()

	/// The sources as of the last `update`, nil before the first.
	private var wanted: [Stamp]?
	/// The shape saved since launch, if one was.
	private var savedShape: BrowseShape?
	/// Whether the sources changed while a build ran, so another follows it.
	private var buildAgain = false
	private var records: [SourceRecord] = []

	/// What decides whether a source needs parsing again: every download
	/// that works, changed or not, sets `lastRefreshedAt`. Doesn't touch the
	/// JSON, which lives in its own file.
	struct Stamp: Hashable {
		var url: URL
		var refreshedAt: Date?

		init(_ record: SourceRecord) {
			url = record.url
			refreshedAt = record.lastRefreshedAt
		}
	}

	static func stamps(_ records: [SourceRecord]) -> [Stamp] { records.map(Stamp.init) }

	/// `records` in the order the user added them.
	func update(from records: [SourceRecord]) {
		let stamps = Self.stamps(records)
		self.records = records
		guard stamps != wanted else { return }
		wanted = stamps
		startBuild()
	}

	/// Builds the catalog again after the user chose another build (#30).
	func buildChoicesChanged() {
		startBuild()
	}

	/// Builds the catalog again after a source's Include Pre-releases
	/// changed (#104).
	func prereleasesChanged() {
		startBuild()
	}

	/// Whether the catalog is built from `records` as they are now, with no
	/// build to come. `records` in the order the user added them.
	func isCurrent(for records: [SourceRecord]) -> Bool {
		!isBuilding && Self.stamps(records) == wanted
	}

	/// Builds the catalog from the latest records. A build that's running
	/// finishes and shows, and one more follows it. Cancelling it instead
	/// meant that at launch, each source that finished refreshing started
	/// the build over, so Browse showed only the sources' names until the
	/// slowest one had refreshed, rather than what was saved last time.
	private func startBuild() {
		guard !isBuilding else {
			buildAgain = true
			return
		}
		isBuilding = true
		Task {
			// The latest sources, but not one removed since the last update,
			// which can't be read any more.
			let records = self.records.filter { !$0.isDeleted && $0.modelContext != nil }
			let catalog = await Self.build(from: records)
			self.catalog = catalog
			isLoaded = true
			isBuilding = false
			let shape = BrowseShape(catalog)
			if shape != (savedShape ?? self.shape) {
				shape.save()
				savedShape = shape
			}
			if buildAgain {
				buildAgain = false
				startBuild()
			}
		}
	}

	/// The catalog of `records`, parsed off the main thread; also for
	/// background update runs, which have no Browse (#72). Each source lists
	/// its betas only while the user includes them (#104).
	static func build(from records: [SourceRecord]) async -> Catalog {
		let inputs = records.map { record in
			(
				info: Catalog.SourceInfo(url: record.url, name: record.name, tintColor: record.tintColor, iconURL: record.iconURL),
				json: record.json,
				prereleases: Prereleases.preferences.includes(record.url)
			)
		}
		let choices = BuildChoices.all()
		return await Task.detached(priority: .userInitiated) {
			Catalog(sources: inputs.compactMap { input in
				// A source whose JSON no longer parses keeps its card in
				// Browse with the error; it just has no apps.
				guard let json = input.json, let source = try? SourceParser.parse(json).source else { return nil }
				let listed = source.listing(prereleases: input.prereleases)
				return (info: input.info, source: BuildChoices.apply(choices, to: listed, at: input.info.url))
			})
		}.value
	}
}

/// Opens an app's detail screen, from Browse, search or a source's app list.
struct AppLink: Hashable {
	/// `Catalog.Entry.id`: the bundle ID and name.
	var appID: String
	var bundleID: String
	/// The source to show it from; nil for the one with the newest version.
	var sourceURL: URL?
	/// The source's apps that listed it, each with its own, so that a list's
	/// row isn't shown as selected for the same app's link from another list
	/// further back on the path (30 Oct).
	var listID: UUID?

	init(appID: String, bundleID: String, sourceURL: URL? = nil, listID: UUID? = nil) {
		self.appID = appID
		self.bundleID = bundleID
		self.sourceURL = sourceURL
		self.listID = listID
	}

	init(_ entry: Catalog.Entry, sourceURL: URL? = nil, listID: UUID? = nil) {
		self.init(appID: entry.id, bundleID: entry.bundleID, sourceURL: sourceURL, listID: listID)
	}
}

/// Opens an app's detail screen from its Library row, by bundle ID rather
/// than the record, as the app can be deleted while the screen is open.
struct LibraryLink: Hashable {
	var bundleID: String
	/// The bundle ID its sources list it under, for a copy (#8).
	var sourceBundleID: String
	/// How the source it was installed from links the app, for its page
	/// once it's deleted from another one: it then shows the app as that
	/// one does, with Install, rather than nothing (30 Oct). Nil for
	/// a copy, an IPA file or an app its source no longer lists.
	var listing: AppLink?

	init(_ item: LibraryItem) {
		self.init(item.install, listing: item.listing)
	}

	/// An install as the Library links it, from another install's page
	/// (#113).
	@MainActor
	init(_ install: InstallRecord, in catalog: Catalog) {
		self.init(install, listing: InstallModel.listing(of: install, in: catalog))
	}

	private init(_ install: InstallRecord, listing: Catalog.Offer?) {
		bundleID = install.bundleID
		sourceBundleID = install.sourceBundleID
		if install.target == .original, let listing {
			self.listing = AppLink(appID: listing.app.id, bundleID: sourceBundleID, sourceURL: listing.source.url)
		}
	}
}

/// Opens a source's apps from the source chip in app details, by URL rather
/// than the record, as the source can be removed in Browse while the
/// Library shows its apps.
struct SourceAppsLink: Hashable {
	var url: URL
}

/// How much Browse showed when its apps last loaded, so that at launch,
/// until the catalog is built, its placeholders take the same space: News,
/// each source's featured apps, the categories and the first apps. Before
/// any build has saved one, a guess.
struct BrowseShape: Codable, Equatable {
	/// News cards, at most the 10 Browse shows.
	var news: Int
	/// Each source's featured apps, by URL; nil before any build.
	var featured: [String: Int]?
	var categories: Int
	/// All Apps' rows, at most the 8 placeholders show.
	var apps: Int

	private static let key = "browseShape"

	/// A full row of news, and two featured apps for every source.
	static let guess = BrowseShape(news: 10, featured: nil, categories: 4, apps: 6)

	static func saved() -> BrowseShape {
		guard let data = UserDefaults.standard.data(forKey: key),
		      let shape = try? JSONDecoder().decode(BrowseShape.self, from: data)
		else { return guess }
		return shape
	}

	func save() {
		if let data = try? JSONEncoder().encode(self) {
			UserDefaults.standard.set(data, forKey: Self.key)
		}
	}

	/// The source at `url`'s featured apps: none for a source added since,
	/// two for each before any build.
	func featured(at url: URL) -> Int {
		featured.map { $0[url.absoluteString] ?? 0 } ?? 2
	}
}

extension BrowseShape {
	init(_ catalog: Catalog) {
		news = min(catalog.news.count, 10)
		featured = Dictionary(catalog.sources.map { ($0.source.url.absoluteString, $0.featured.count) }, uniquingKeysWith: { first, _ in first })
		categories = catalog.categories.count
		apps = min(catalog.entries.count, 8)
	}
}
