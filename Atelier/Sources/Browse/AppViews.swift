import AtelierCore
import SourceKit
import SwiftData
import SwiftUI

/// An app in a list (#38): icon, name, its version under the name with how
/// many sources list it, subtitle or developer, and its Install button on
/// the right, whose long press's menu is the whole row's (`AppListRow`,
/// #113). The row shows and installs the listing from `sourceURL`, or the
/// preferred one.
struct AppRow: View {
	let entry: Catalog.Entry
	var sourceURL: URL?
	/// The installed app's version, or nil when Atelier hasn't installed it.
	let installedVersion: String?
	/// The icon iOS shows for the installed app, which its source may not
	/// list (#118); nil when it isn't installed or Atelier has none.
	let installedIcon: URL?
	/// Says "Not signed in to GitHub" in place of the subtitle while the
	/// listing's source needs a sign-in (#134); not on that source's own
	/// page, which says it once above its apps.
	var warnsOfSignIn = true
	@Environment(SourcesModel.self) private var sources

	var body: some View {
		let offer = entry.offer(from: sourceURL)
		let app = offer.app
		HStack(spacing: 12) {
			SourceIcon(url: installedIcon ?? app.iconURL, tint: app.tintColor ?? offer.source.tintColor, size: 48)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(app.name)
						.font(.headline)
						.lineLimit(1)
					if app.isBetaRelease { BetaTag() }
				}
				if let detail = detail(app) {
					Text(detail)
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				if warnsOfSignIn, sources.needsGitHubSignIn(offer.source.url) {
					NotSignedInToGitHubLabel()
				} else if let line = app.subtitle ?? app.developerName {
					Text(line)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			Spacer(minLength: 8)
			InstallButton(
				app: app,
				action: InstallAction(availability: app.availability(), installedVersion: installedVersion),
				sourceURL: offer.source.url,
				offers: entry.offers,
				compact: true,
				showsMenu: false
			)
		}
		.padding(.vertical, 2)
	}

	private func detail(_ app: SourceApp) -> String? {
		let sources = entry.offers.count > 1 ? "\(entry.offers.count) sources" : nil
		let parts = [app.latestVersion?.displayVersion, sources].compactMap { $0 }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}

/// Marks a beta (#38): the source flags it, or its version is a
/// pre-release. Betas are usually separate apps next to the stable one.
struct BetaTag: View {
	var body: some View {
		Text("BETA")
			.font(.caption2.weight(.bold))
			.foregroundStyle(.orange)
			.padding(.horizontal, 5)
			.padding(.vertical, 1)
			.background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
			.accessibilityLabel("Beta")
	}
}

/// The icon right before the title, also in a list row, where a label's
/// icon otherwise gets a column of its own, far from the title.
struct InlineLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.icon
			configuration.title
		}
	}
}

/// An app's row in a list that opens its details, without a chevron so the
/// Install button sits at the right edge. Touching and holding anywhere on
/// it brings up the Install button's menu (#113), with Custom Install… also
/// once the app is installed (#155): Atelier's row has no button while
/// it's up to date.
struct AppListRow: View {
	let entry: Catalog.Entry
	var sourceURL: URL?
	let installed: InstalledVersions
	/// The source's apps listing it (`AppLink.listID`).
	var listID: UUID?
	/// As `AppRow`'s (#134).
	var warnsOfSignIn = true
	@Environment(\.pushesAppPages) private var pushesAppPages

	var body: some View {
		let offer = entry.offer(from: sourceURL)
		let link = AppLink(entry, sourceURL: sourceURL, listID: listID)
		// A hidden link under the row, as for the source cards. The Install
		// button takes its own taps; the rest of the row opens the details.
		ZStack {
			if pushesAppPages {
				NavigationLink { PushedAppPage(.listing(link)) } label: { EmptyView() }
					.opacity(0)
			} else {
				NavigationLink(value: link) { EmptyView() }
					.opacity(0)
			}
			AppRow(
				entry: entry,
				sourceURL: sourceURL,
				installedVersion: installed[entry.bundleID],
				installedIcon: installed.icon(of: entry.bundleID),
				warnsOfSignIn: warnsOfSignIn
			)
		}
		.modifier(AppMenu(app: offer.app, version: offer.app.availability().version, sourceURL: offer.source.url, offers: entry.offers, signsAgain: installed[entry.bundleID] != nil))
	}
}

/// App rows open their app's page pushed after their list with a view
/// link, rather than through the stack's path with a value link (#49). In
/// a stack whose pages are pushed as views, as Settings' are, a value
/// link's page goes right after the stack's root, under the pages pushed
/// since: a source's apps, opened from an app's page under Settings, showed
/// the list again rather than the app (4 Nov 2026).
private struct PushesAppPagesKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	var pushesAppPages: Bool {
		get { self[PushesAppPagesKey.self] }
		set { self[PushesAppPagesKey.self] = newValue }
	}
}

/// The installed apps' versions by bundle ID, looked up once per list rather
/// than with a query per row. Apps deleted outside Atelier are left out, so
/// their rows offer Install again (#55).
struct InstalledVersions {
	private let versions: [String: String]
	/// The bundle ID each app is installed as, by the one Browse knows it by.
	private let installedAs: [String: String]

	@MainActor
	init(_ installs: [InstallRecord]) {
		let present = installs.filter { InstallModel.presence(of: $0) != .deleted }
		var versions = Dictionary(present.map { ($0.bundleID, $0.version) }, uniquingKeysWith: { first, _ in first })
		var installedAs = Dictionary(present.map { ($0.bundleID, $0.bundleID) }, uniquingKeysWith: { first, _ in first })
		// Also by the bundle ID its source lists it under, when its IPA has
		// another (#116), unless an app is installed as that one.
		for install in present where install.target == .original && versions[install.sourceBundleID] == nil {
			versions[install.sourceBundleID] = install.version
			installedAs[install.sourceBundleID] = install.bundleID
		}
		// Atelier, as its own source lists it, whatever bundle ID it runs
		// as (#24).
		if let own = present.first(where: { SelfUpdate.shared.isOwn($0) }) {
			versions[SelfUpdate.sourceBundleID] = own.version
		}
		self.versions = versions
		self.installedAs = installedAs
	}

	subscript(bundleID: String) -> String? { versions[bundleID] }

	/// The icon iOS shows for the installed app Browse knows as `bundleID`,
	/// from the IPA Atelier signed (#118); nil when it isn't installed or
	/// Atelier has none.
	@MainActor
	func icon(of bundleID: String) -> URL? {
		installedAs[bundleID].flatMap { InstalledIcons.shared.url(for: $0) }
	}
}

extension AppCategory {
	var title: String {
		switch self {
		case .developer: "Developer"
		case .entertainment: "Entertainment"
		case .games: "Games"
		case .lifestyle: "Lifestyle"
		case .other: "Other"
		case .photoVideo: "Photo & Video"
		case .social: "Social"
		case .utilities: "Utilities"
		}
	}

	var systemImage: String {
		switch self {
		case .developer: "hammer"
		case .entertainment: "popcorn"
		case .games: "gamecontroller"
		case .lifestyle: "heart"
		case .other: "square.grid.2x2"
		case .photoVideo: "camera"
		case .social: "bubble.left.and.bubble.right"
		case .utilities: "wrench.and.screwdriver"
		}
	}
}

extension InstallAction {
	var title: String {
		switch self {
		case .install: "Install"
		case .update: "Update"
		case .open: "Open"
		case .notInstallable: "Not Installable"
		}
	}
}

/// The apps in one category, by name, with a search field for them (#124).
struct CategoryAppsView: View {
	let category: AppCategory
	@Environment(CatalogModel.self) private var model
	@Query private var installs: [InstallRecord]
	@State private var query = ""

	var body: some View {
		let entries = model.catalog.entries(in: category)
		let search = SearchText(query)
		let shown = search.isEmpty ? entries : Catalog.search(search, in: entries)
		let installed = InstalledVersions(installs)
		List(shown) { entry in
			AppListRow(entry: entry, installed: installed)
		}
		.listStyle(.plain)
		.overlay {
			if !search.isEmpty, shown.isEmpty {
				ContentUnavailableView.search(text: query)
			}
		}
		.searchable(text: $query, prompt: Text.searchingApps(entries.count))
		.navigationTitle(category.title)
	}
}

extension Text {
	/// The search field's prompt in a list of apps (#124): how many apps it
	/// searches, such as "Search 817 Apps", counted as the categories count
	/// theirs.
	static func searchingApps(_ count: Int) -> Text {
		switch count {
		case 0: Text("Search Apps")
		case 1: Text("Search 1 App")
		default: Text("Search \(count.formatted(.number)) Apps")
		}
	}
}
