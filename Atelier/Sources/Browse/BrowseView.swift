import AtelierCore
import SourceKit
import SwiftData
import SwiftUI
import UIKit

/// The Browse tab (#14): news, a card per source with its featured apps,
/// categories and every app across the user's sources, with search over all
/// of them.
///
/// Sources live here too (#38): each one is a card in its colour, with its
/// featured apps inside; tap its top for its apps, touch and hold it to copy
/// its URL or remove it, pull to refresh them all. The + menu adds a source or opens Manage Sources, the
/// list of all of them. Atelier's own source comes first and can't be
/// removed (#24); until the user adds one, an Add Source card follows it.
struct BrowseView: View {
	@Environment(CatalogModel.self) private var model
	@Environment(SourcesModel.self) private var sourcesModel
	@Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]
	@Query private var installs: [InstallRecord]
	@State private var query = ""
	@State private var path = NavigationPath()
	@State private var links = StoreLinks.shared

	private var catalog: Catalog { model.catalog }

	/// Manage Sources, pushed from the + menu.
	private struct ManageSources: Hashable {}

	var body: some View {
		NavigationStack(path: $path) {
			Group {
				if !query.trimmingCharacters(in: .whitespaces).isEmpty {
					SearchResults(query: query, installed: InstalledVersions(installs))
				} else {
					home
				}
			}
			.navigationTitle("Browse")
			.searchable(text: $query, prompt: "Apps, developers, bundle IDs")
			.toolbar {
				Menu {
					Button("Add Source", systemImage: "plus") { sourcesModel.beginAdd() }
					Button("Refresh Sources", systemImage: "arrow.clockwise") {
						Task { await sourcesModel.refreshAll() }
					}
					.disabled(sourcesModel.isRefreshing)
					Button("Manage Sources", systemImage: "tray.full") { path.append(ManageSources()) }
				} label: {
					Label("Sources", systemImage: "plus")
				}
			}
			.navigationDestination(for: AppLink.self) { link in
				AppDetailView(link: link, openSource: { path.append(SourceAppsLink(url: $0)) }, openInstall: { path.append($0) })
			}
			// An app's copy, or the app a copy is of, from its copies (#113).
			.navigationDestination(for: LibraryLink.self) { app in
				AppDetailView(library: app, openSource: { path.append(SourceAppsLink(url: $0)) }, openInstall: { path.append($0) })
			}
			.navigationDestination(for: AppCategory.self) { category in
				CategoryAppsView(category: category)
			}
			.navigationDestination(for: SourceRecord.self) { source in
				SourceAppsView(source: source)
			}
			// A source's apps, from the source chip on an app's page.
			.navigationDestination(for: SourceAppsLink.self) { link in
				SourceAppsLoader(url: link.url)
			}
			.navigationDestination(for: ManageSources.self) { _ in
				ManageSourcesView()
			}
		}
		// A link to a search, an added source or an app (#93).
		.onChange(of: links.browseRequest, initial: true) { _, request in
			guard let request else { return }
			links.browseRequest = nil
			switch request {
			case .search(let text):
				path = NavigationPath()
				query = text
			case .source(let source):
				path = NavigationPath([source])
			case .app(let link):
				path = NavigationPath([link])
			}
		}
		// From a repo's touch-and-hold menu, here or in Manage Sources (#104).
		.modifier(PrereleasesOffConfirmation())
	}

	private var home: some View {
		let installed = InstalledVersions(installs)
		// Until the catalog is built, placeholders where its content goes,
		// as much as Browse showed when it last loaded, so nothing moves
		// when the content comes.
		let shape = model.isLoaded ? nil : model.shape
		let showsNews = shape.map { $0.news > 0 } ?? !catalog.news.isEmpty
		return List {
			if showsNews {
				// Big cards on the page rather than in the list's grey box,
				// under a big heading (#84).
				Section {
					ZStack {
						if let shape {
							NewsPlaceholder(count: shape.news)
						} else {
							NewsCarousel(news: Array(catalog.news.prefix(10)), catalog: catalog, installed: installed) { path.append($0) }
						}
					}
					.animation(.easeInOut(duration: 0.25), value: shape == nil)
					.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
					.listRowBackground(Color.clear)
				} header: {
					Text("News")
						.font(.title2.bold())
						.foregroundStyle(.primary)
						.textCase(nil)
				}
			}
			// Each source as one card in its colour, with its featured apps
			// inside when it names any (#38). As wide as the list's other
			// sections (#84).
			Section {
				ForEach(sources) { source in
					SourceBlock(
						source: source,
						featured: catalog.source(url: source.url)?.featured ?? [],
						placeholders: shape?.featured(at: source.url) ?? 0,
						installed: installed,
						openSource: { path.append(source) },
						openApp: { path.append($0) },
						remove: { sourcesModel.remove(source) }
					)
					.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
				}
				if sources.allSatisfy(\.isBuiltIn) {
					AddSourceCard { sourcesModel.beginAdd() }
						.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)
				}
			}
			Section("Categories") {
				if let shape {
					ForEach(0..<shape.categories, id: \.self) { _ in
						CategoryPlaceholder()
					}
				} else {
					ForEach(catalog.categories, id: \.category) { item in
						NavigationLink(value: item.category) {
							LabeledContent {
								Text(item.count, format: .number)
							} label: {
								Label(item.category.title, systemImage: item.category.systemImage)
							}
						}
					}
				}
			}
			Section {
				if let shape {
					ForEach(0..<shape.apps, id: \.self) { _ in
						AppRowPlaceholder()
					}
				} else {
					ForEach(catalog.entries) { entry in
						AppListRow(entry: entry, installed: installed)
					}
				}
			} header: {
				if shape == nil {
					Text("All Apps (\(catalog.entries.count))")
				} else {
					Text("All Apps")
				}
			}
		}
		.refreshable { await sourcesModel.refreshAll() }
	}
}

/// A source as one card in its colour (#38): its icon, name, when it last
/// updated and its app count, which open its apps, and its featured apps
/// inside when it names any. Touch and hold the top to copy its URL or
/// remove it.
private struct SourceBlock: View {
	let source: SourceRecord
	let featured: [Catalog.Entry]
	/// Featured apps' placeholders while Browse's apps load.
	let placeholders: Int
	let installed: InstalledVersions
	let openSource: () -> Void
	let openApp: (AppLink) -> Void
	let remove: () -> Void

	private var tint: SourceTint { SourceTint(hex: source.tintColor, url: source.url) }

	private var detail: String {
		source.refreshError ?? source.detail
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Button(action: openSource) {
				HStack(spacing: 10) {
					SourceIcon(url: source.iconURL, tint: source.tintColor, size: 44)
					VStack(alignment: .leading, spacing: 1) {
						SourceName(source: source)
							.font(.headline)
						HStack(spacing: 4) {
							if source.refreshError != nil {
								Image(systemName: "exclamationmark.triangle.fill")
							}
							Text(detail)
								.lineLimit(1)
						}
						.font(.caption)
						// Undimmed when it asks to sign in (#134).
						.opacity(source.needsGitHubSignIn ? 1 : 0.75)
					}
					Spacer(minLength: 8)
					HStack(spacing: 3) {
						Text(source.apps.count == 1 ? "1 app" : "\(source.apps.count) apps")
						Image(systemName: "chevron.right")
							.font(.caption.weight(.bold))
					}
					.font(.subheadline.bold())
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(.white.opacity(0.18), in: Capsule())
				}
				.padding(.horizontal, 12)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.contextMenu {
				SourceMenu(source: source, remove: remove)
			}
			if !featured.isEmpty || placeholders > 0 {
				// One on the other while they cross-fade.
				ZStack {
					if !featured.isEmpty {
						FeaturedPages(featured: featured, sourceURL: source.url, installed: installed, openApp: openApp)
					} else {
						FeaturedPlaceholders(count: placeholders, tint: tint)
					}
				}
			}
		}
		.animation(.easeInOut(duration: 0.25), value: placeholders)
		.padding(.vertical, 12)
		.foregroundStyle(tint.foreground)
		// A shade darker than the source's colour, so featured cards in the
		// same colour stand out from it.
		.background {
			let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
			shape.fill(tint.color)
				.overlay(shape.fill(.black.opacity(0.2)))
		}
		// Featured cards sliding past the card's edge are cut to its shape,
		// so none shows outside its rounded corners (#84).
		.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
	}
}

/// A source's featured apps, two to a page (#84), so both cards sit inside
/// the source's card with 12 pt around and between them; a lone card on the
/// last page keeps its width. Swipe for the next two, with dots for where
/// you are when there's more than one page.
private struct FeaturedPages: View {
	let featured: [Catalog.Entry]
	let sourceURL: URL
	let installed: InstalledVersions
	let openApp: (AppLink) -> Void
	@State private var page: Int? = 0

	var body: some View {
		let pages = stride(from: 0, to: featured.count, by: 2).map { Array(featured[$0..<min($0 + 2, featured.count)]) }
		VStack(spacing: 10) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 0) {
					ForEach(pages.indices, id: \.self) { index in
						HStack(spacing: 12) {
							ForEach(pages[index]) { entry in
								FeaturedCard(
									offer: entry.offer(from: sourceURL),
									offers: entry.offers,
									installedVersion: installed[entry.bundleID],
									installedIcon: installed.icon(of: entry.bundleID)
								) {
									openApp(AppLink(entry, sourceURL: sourceURL))
								}
							}
							if pages[index].count == 1 {
								Color.clear
									.frame(maxWidth: .infinity, maxHeight: 0)
							}
						}
						.padding(.horizontal, 12)
						// Each page as wide as the source's card.
						.containerRelativeFrame(.horizontal)
					}
				}
				.scrollTargetLayout()
			}
			.scrollTargetBehavior(.paging)
			.scrollPosition(id: $page)
			if pages.count > 1 {
				PageDots(count: pages.count, current: page ?? 0)
			}
		}
	}
}

/// Browse's Add Source card, after Atelier's own source until the user
/// adds one (#24): Browse is never empty, as Atelier's is always there.
private struct AddSourceCard: View {
	let add: () -> Void

	var body: some View {
		Button(action: add) {
			HStack(spacing: 12) {
				Image(systemName: "plus")
					.font(.title3.weight(.semibold))
					.foregroundStyle(.tint)
					.frame(width: 44, height: 44)
					.background(Color.accentColor.opacity(0.12), in: Circle())
				VStack(alignment: .leading, spacing: 2) {
					Text("Add Source")
						.font(.headline)
						.foregroundStyle(.tint)
					Text("Add an AltStore source or a GitHub repo, and its apps will show up here.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 18)
			.overlay {
				RoundedRectangle(cornerRadius: 24, style: .continuous)
					.strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

/// Dots for the page or card a row shows (#84), in the text's colour.
private struct PageDots: View {
	let count: Int
	let current: Int

	var body: some View {
		HStack(spacing: 7) {
			ForEach(0..<count, id: \.self) { index in
				Circle()
					.frame(width: 7, height: 7)
					.opacity(index == current ? 1 : 0.3)
			}
		}
		.animation(.default, value: current)
		.accessibilityElement()
		.accessibilityLabel("Page \(current + 1) of \(count)")
	}
}

/// Every source as a card (#38), AltStore sources and GitHub repos (#30)
/// in their own sections, each with a + that opens Add Source on its tab:
/// tap for its apps, swipe to remove, touch and hold to copy its URL or
/// remove it. Atelier's own source comes first and can't be removed (#24).
/// The GitHub account repos are read as comes last (#74). Search finds a
/// source or repo by its name, subtitle, address or owner/repo (#124).
///
/// Get Ready and Status (#21) open it too, where Back leads to them: there
/// it lists the sources and adds them, and leaves their apps and removing
/// them to Browse.
struct ManageSourcesView: View {
	/// Off in Get Ready and Status, which aren't in Browse.
	var isInBrowse = true
	@Query(sort: \SourceRecord.addedAt) private var sources: [SourceRecord]
	@Environment(SourcesModel.self) private var model
	/// Sign In to GitHub was tapped.
	@State private var showsGitHub = false
	@State private var query = ""

	var body: some View {
		let search = SearchText(query)
		let shown = search.isEmpty ? sources : sources.filter { matches($0, search) }
		let gitHub = shown.filter { GitHubRepo(sourceURL: $0.url) != nil }
		let altStore = shown.filter { GitHubRepo(sourceURL: $0.url) == nil }
		// Each repo's account shows once there's more than one (#74).
		let showsAccounts = GitHubAccess.accounts.all.count > 1
		List {
			// Their cards don't open here (#21).
			if !isInBrowse, search.isEmpty {
				Text("Their apps are in Browse.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
			}
			// While searching, only the sections with a match.
			if search.isEmpty || !altStore.isEmpty {
				section("AltStore Sources", altStore, showsAccounts: false, empty: search.isEmpty ? "Sources from AltStore, SideStore, Feather and others." : nil) {
					model.beginAdd()
				}
			}
			if search.isEmpty || !gitHub.isEmpty {
				section("GitHub Repos", gitHub, showsAccounts: showsAccounts, empty: search.isEmpty ? "Repos whose releases have .ipa files." : nil) {
					model.beginAdd(gitHub: true)
				}
			}
			// Under the repos, with no header of its own (the mockup of
			// 29 Oct 2026).
			if search.isEmpty {
				Section {
					GitHubAccountRow { showsGitHub = true }
						.listRowSeparator(.hidden)
					Text("For private repos, and GitHub's limit of 5,000 checks an hour instead of 60.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
				}
			}
		}
		.listStyle(.plain)
		.overlay {
			if !search.isEmpty, shown.isEmpty {
				ContentUnavailableView.search(text: query)
			}
		}
		.refreshable { await model.refreshAll() }
		.searchable(text: $query, prompt: "Search Sources")
		.navigationTitle("Sources")
		.navigationDestination(isPresented: $showsGitHub) {
			GitHubAccountsView()
		}
	}

	/// By its name, subtitle and address, and a repo's owner/repo.
	private func matches(_ source: SourceRecord, _ search: SearchText) -> Bool {
		search.matches(name: source.name, others: [source.subtitle, source.url.host(), GitHubRepo(sourceURL: source.url)?.description])
	}

	/// In Browse, a hidden link under the card, so the card has no chevron,
	/// and its touch-and-hold menu; elsewhere, the card alone.
	@ViewBuilder
	private func card(_ source: SourceRecord, showsAccounts: Bool) -> some View {
		let sourceCard = SourceCard(source: source, account: showsAccounts ? account(of: source) : nil)
		if isInBrowse {
			ZStack {
				NavigationLink(value: source) { EmptyView() }
					.opacity(0)
				sourceCard
			}
			.contextMenu {
				SourceMenu(source: source) { model.remove(source) }
			}
		} else {
			sourceCard
		}
	}

	/// `empty` is said while the user hasn't added any: Atelier's own is
	/// always there.
	private func section(_ title: String, _ sources: [SourceRecord], showsAccounts: Bool, empty: String?, add: @escaping () -> Void) -> some View {
		Section {
			ForEach(sources) { source in
				card(source, showsAccounts: showsAccounts)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
					.deleteDisabled(source.isBuiltIn || !isInBrowse)
			}
			.onDelete { offsets in
				for index in offsets { model.remove(sources[index]) }
			}
			// Until the user adds one: Atelier's own is always there.
			if let empty, sources.allSatisfy(\.isBuiltIn) {
				Text(empty)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
			}
		} header: {
			HStack {
				Text(title)
					.font(.title3.bold())
					.foregroundStyle(.primary)
				Spacer()
				Button("Add", systemImage: "plus", action: add)
					.labelStyle(.iconOnly)
					.font(.title3)
			}
			.textCase(nil)
		}
	}

	/// The account a GitHub repo is read as.
	private func account(of source: SourceRecord) -> String? {
		GitHubRepo(sourceURL: source.url).flatMap { GitHubAccess.accounts.account(for: $0) }?.name
	}
}

private struct SearchResults: View {
	let query: String
	let installed: InstalledVersions
	@Environment(CatalogModel.self) private var model

	var body: some View {
		let results = model.catalog.search(query)
		List(results) { entry in
			AppListRow(entry: entry, installed: installed)
		}
		.listStyle(.plain)
		.overlay {
			// Until Browse's apps load, there's nothing to search yet.
			if !model.isLoaded {
				ProgressView()
			} else if results.isEmpty {
				ContentUnavailableView.search(text: query)
			}
		}
	}
}

/// A featured app as a compact card in its own colour, with its Install
/// button in the corner, half as wide as its page (#84). Tapping the card
/// opens the app.
private struct FeaturedCard: View {
	let offer: Catalog.Offer
	let offers: [Catalog.Offer]
	let installedVersion: String?
	/// The installed app's own icon (#118), as `AppRow` has it.
	let installedIcon: URL?
	let open: () -> Void

	var body: some View {
		let app = offer.app
		let tint = SourceTint(hex: app.tintColor ?? offer.source.tintColor, url: offer.source.url)
		ZStack(alignment: .topTrailing) {
			Button(action: open) {
				VStack(alignment: .leading, spacing: 2) {
					SourceIcon(url: installedIcon ?? app.iconURL, tint: app.tintColor, size: 52)
						.overlay(RoundedRectangle(cornerRadius: 52 * 0.22, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
						.shadow(color: .black.opacity(0.3), radius: 6, y: 3)
					Spacer(minLength: 8)
					HStack(spacing: 4) {
						Text(app.name)
							.font(.subheadline.bold())
							.lineLimit(1)
						if app.isBetaRelease { CardBetaTag() }
					}
					Text(app.subtitle ?? app.developerName ?? " ")
						.font(.caption)
						.lineLimit(1)
						.opacity(0.8)
				}
				.foregroundStyle(tint.foreground)
				.padding(12)
				.frame(maxWidth: .infinity, minHeight: 156, maxHeight: 156, alignment: .leading)
				.background(
					LinearGradient(colors: [tint.color.opacity(0.85), tint.color], startPoint: .topLeading, endPoint: .bottomTrailing),
					in: RoundedRectangle(cornerRadius: 20, style: .continuous)
				)
			}
			.buttonStyle(.plain)
			InstallButton(
				app: app,
				action: InstallAction(availability: app.availability(), installedVersion: installedVersion),
				sourceURL: offer.source.url,
				offers: offers,
				compact: true
			)
			.controlSize(.small)
			.tint(tint.foreground.opacity(0.25))
			.padding(10)
		}
	}
}

/// The 10 newest items as big cards (#84), one at a time with the next one
/// peeking in, snapping card by card, with dots for where you are. The list
/// clips a row to its inset margins, so the cards stay inside them.
private struct NewsCarousel: View {
	let news: [Catalog.News]
	let catalog: Catalog
	let installed: InstalledVersions
	let open: (AppLink) -> Void
	@State private var current: Int? = 0

	var body: some View {
		VStack(spacing: 12) {
			ScrollView(.horizontal, showsIndicators: false) {
				// Buttons rather than links: links inside a list row can take
				// over the whole row.
				LazyHStack(alignment: .top, spacing: 10) {
					ForEach(news.indices, id: \.self) { index in
						NewsCard(news: news[index], app: news[index].item.appID.flatMap(catalog.entry(bundleID:)), installed: installed, open: open)
							// Narrower than the row, so the next card peeks in.
							.containerRelativeFrame(.horizontal) { length, _ in news.count > 1 ? length - 30 : length }
					}
				}
				.scrollTargetLayout()
			}
			.scrollTargetBehavior(.viewAligned)
			// The card in the middle, so the last one counts once it's in
			// view, though it can't reach the leading edge.
			.scrollPosition(id: $current, anchor: .center)
			if news.count > 1 {
				PageDots(count: news.count, current: current ?? 0)
			}
		}
	}
}

/// A news item as a big card (#84): its picture on top, then its source and
/// date, title and caption, and at the bottom the app it's about with its
/// Install button, or its link's host. An item without a picture shows a
/// bigger title under the source's icon. Each part keeps its space when
/// it's empty, so every card is the same height. Opens the app, or else
/// the link.
private struct NewsCard: View {
	let news: Catalog.News
	/// The app the item is about, when one of the sources lists it.
	let app: Catalog.Entry?
	let installed: InstalledVersions
	let open: (AppLink) -> Void
	@Environment(\.openURL) private var openURL
	@Environment(SourcesModel.self) private var sources

	private var item: NewsItem { news.item }
	private var tint: SourceTint { SourceTint(hex: item.tintColor ?? news.source.tintColor, url: news.source.url) }

	var body: some View {
		Group {
			if let imageURL = item.imageURL {
				VStack(alignment: .leading, spacing: 0) {
					opening {
						VStack(alignment: .leading, spacing: 0) {
							NewsPicture(url: imageURL, tint: tint.color)
							text
						}
					}
					Spacer(minLength: 12)
					footer
				}
			} else {
				// Sized as a card with a picture, so the row stays even.
				VStack(alignment: .leading, spacing: 0) {
					Color.clear
						.aspectRatio(16 / 9, contentMode: .fit)
					text
					Spacer(minLength: 12)
					NewsAppBar.placeholder
						.padding([.horizontal, .bottom], 16)
				}
				.hidden()
				.overlay(alignment: .topLeading) { textOnly }
			}
		}
		.foregroundStyle(tint.foreground)
		.background { backdrop }
		// Its source needs a GitHub sign-in, so newer news may be missing
		// (#134).
		.overlay(alignment: .topTrailing) {
			if sources.needsGitHubSignIn(news.source.url) {
				Label("Not signed in to GitHub", systemImage: "exclamationmark.triangle.fill")
					.labelStyle(InlineLabelStyle())
					.font(.caption.weight(.semibold))
					.lineLimit(1)
					.foregroundStyle(.white)
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(.black.opacity(0.3), in: Capsule())
					.padding(.top, 18)
					.padding(.trailing, 16)
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
	}

	/// The source and date, title and caption, each keeping its lines.
	private var text: some View {
		VStack(alignment: .leading, spacing: 4) {
			eyebrow
				.padding(.bottom, 2)
			Text(item.title)
				.font(.title3.bold())
				.lineLimit(2, reservesSpace: true)
			Text(item.caption ?? " ")
				.font(.subheadline)
				.lineLimit(2, reservesSpace: true)
				.opacity(0.86)
		}
		.multilineTextAlignment(.leading)
		.padding(.horizontal, 16)
		.padding(.top, 14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// An item without a picture: a bigger title under the source's icon.
	private var textOnly: some View {
		VStack(alignment: .leading, spacing: 0) {
			opening {
				VStack(alignment: .leading, spacing: 6) {
					SourceIcon(url: news.source.iconURL, tint: news.source.tintColor, size: 56)
						.shadow(color: .black.opacity(0.3), radius: 8, y: 4)
						.padding(.bottom, 10)
					eyebrow
					Text(item.title)
						.font(.title2.bold())
						.lineLimit(4)
					if let caption = item.caption {
						Text(caption)
							.font(.subheadline)
							.lineLimit(3)
							.opacity(0.86)
					}
				}
				.multilineTextAlignment(.leading)
				.padding(.horizontal, 16)
				.padding(.top, 20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			Spacer(minLength: 12)
			footer
		}
	}

	/// The source, with its icon on cards with a picture, and the date: the
	/// year only when it isn't this one.
	private var eyebrow: some View {
		HStack(spacing: 6) {
			if item.imageURL != nil {
				SourceIcon(url: news.source.iconURL, tint: news.source.tintColor, size: 18)
			}
			Text(eyebrowText)
				.font(.caption.weight(.semibold))
				.tracking(0.5)
				.textCase(.uppercase)
				.lineLimit(1)
		}
		// As tall with the icon as without, for cards without a picture.
		.frame(minHeight: 18)
		.opacity(0.8)
	}

	private var eyebrowText: String {
		guard let date = item.date else { return news.source.name }
		let day = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
			? date.formatted(.dateTime.day().month(.abbreviated))
			: date.formatted(.dateTime.day().month(.abbreviated).year())
		return "\(news.source.name) · \(day)"
	}

	/// The app with its Install button, or else the link's host, in an app
	/// bar's height either way.
	private var footer: some View {
		Group {
			if let app {
				NewsAppBar(entry: app, sourceURL: news.source.url, installedVersion: installed[app.bundleID], installedIcon: installed.icon(of: app.bundleID), tint: tint) {
					open(AppLink(app, sourceURL: news.source.url))
				}
			} else {
				NewsAppBar.placeholder
					.hidden()
					.overlay(alignment: .leading) {
						if let url = item.url {
							Button { openURL(url) } label: {
								HStack(spacing: 5) {
									Text(Self.host(of: url))
										.lineLimit(1)
									Image(systemName: "arrow.up.right")
										.imageScale(.small)
								}
								.font(.subheadline.weight(.semibold))
								.padding(.horizontal, 12)
								.padding(.vertical, 7)
								.background(tint.foreground.opacity(0.14), in: Capsule())
							}
							.buttonStyle(.plain)
						}
					}
			}
		}
		.padding([.horizontal, .bottom], 16)
	}

	/// The item's colour, darker towards the bottom, with a light in the
	/// corner when there's no picture.
	private var backdrop: some View {
		ZStack {
			tint.color
			LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
			if item.imageURL == nil {
				RadialGradient(colors: [.white.opacity(0.25), .clear], center: .topTrailing, startRadius: 0, endRadius: 240)
			}
		}
	}

	/// `label` as a button that opens the app, or else the link, and as it
	/// is when there's neither.
	@ViewBuilder
	private func opening(@ViewBuilder _ label: () -> some View) -> some View {
		if app != nil || item.url != nil {
			Button(action: openItem) {
				label()
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		} else {
			label()
		}
	}

	private func openItem() {
		if let app {
			open(AppLink(app, sourceURL: news.source.url))
		} else if let url = item.url {
			openURL(url)
		}
	}

	/// The host without its "www.", as the link's chip shows it.
	private static func host(of url: URL) -> String {
		let host = url.host() ?? url.absoluteString
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}

/// A news item's picture (#84), whole on a blur of itself rather than on
/// flat colour. A small square one is an app's icon, as CyPwn's are, so it
/// shows as an icon instead of stretched. The item's colour until it loads.
private struct NewsPicture: View {
	let url: URL
	let tint: Color

	var body: some View {
		Color.clear
			.aspectRatio(16 / 9, contentMode: .fit)
			.overlay {
				LoadedImage(url: url, maxPoints: 400) { image in
					let icon = Self.isIcon(image)
					ZStack {
						Color.clear
							.overlay {
								Image(uiImage: image)
									.resizable()
									.scaledToFill()
							}
							.clipped()
							.blur(radius: icon ? 40 : 28, opaque: true)
							.saturation(1.3)
						if icon {
							Image(uiImage: image)
								.resizable()
								.scaledToFit()
								.frame(width: 118, height: 118)
								.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
								.shadow(color: .black.opacity(0.35), radius: 12, y: 6)
						} else {
							Image(uiImage: image)
								.resizable()
								.scaledToFit()
						}
					}
				} placeholder: {
					tint.opacity(0.6)
				}
			}
			.clipped()
	}

	/// Square and at most 512 pixels a side: an app's icon rather than a
	/// picture made for the news.
	static func isIcon(_ image: UIImage) -> Bool {
		let size = image.size
		guard size.width > 0, size.height > 0 else { return false }
		return (0.8...1.25).contains(size.width / size.height) && max(size.width, size.height) <= 512
	}
}

/// The app a news item is about (#84): its icon, name and subtitle, which
/// open its page, and its Install button, as on featured cards.
private struct NewsAppBar: View {
	let entry: Catalog.Entry
	let sourceURL: URL
	let installedVersion: String?
	/// The installed app's own icon (#118), as `AppRow` has it.
	let installedIcon: URL?
	let tint: SourceTint
	let open: () -> Void

	private static let iconSize: CGFloat = 42

	var body: some View {
		let offer = entry.offer(from: sourceURL)
		let app = offer.app
		HStack(spacing: 10) {
			Button(action: open) {
				HStack(spacing: 10) {
					SourceIcon(url: installedIcon ?? app.iconURL, tint: app.tintColor ?? offer.source.tintColor, size: Self.iconSize)
					VStack(alignment: .leading, spacing: 1) {
						HStack(spacing: 5) {
							Text(app.name)
								.font(.headline)
								.lineLimit(1)
							if app.isBetaRelease { CardBetaTag() }
						}
						Text(app.subtitle ?? app.developerName ?? " ")
							.font(.caption)
							.lineLimit(1)
							.opacity(0.8)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			InstallButton(
				app: app,
				action: InstallAction(availability: app.availability(), installedVersion: installedVersion),
				sourceURL: offer.source.url,
				offers: entry.offers,
				compact: true
			)
			.controlSize(.small)
			.tint(tint.foreground.opacity(0.25))
		}
		.padding(10)
		.background(tint.foreground.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
	}

	/// A bar's size without an app, for cards that have none.
	static var placeholder: some View {
		HStack(spacing: 10) {
			Color.clear
				.frame(width: iconSize, height: iconSize)
			VStack(alignment: .leading, spacing: 1) {
				Text("App")
					.font(.headline)
				Text("Subtitle")
					.font(.caption)
			}
			Spacer(minLength: 0)
		}
		.padding(10)
	}
}

/// Marks a beta on a card in its colour, where `BetaTag`'s orange wouldn't
/// read.
private struct CardBetaTag: View {
	var body: some View {
		Text("BETA")
			.font(.system(size: 9, weight: .bold))
			.padding(.horizontal, 4)
			.background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
			.accessibilityLabel("Beta")
	}
}

/// News while Browse's apps load: a news card's placeholder, the next one
/// peeking in and the dots when there were more, laid out as
/// `NewsCarousel` lays out the cards.
private struct NewsPlaceholder: View {
	let count: Int

	var body: some View {
		VStack(spacing: 12) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(alignment: .top, spacing: 10) {
					ForEach(0..<min(count, 2), id: \.self) { _ in
						NewsCardPlaceholder()
							.containerRelativeFrame(.horizontal) { length, _ in count > 1 ? length - 30 : length }
					}
				}
			}
			.scrollDisabled(true)
			if count > 1 {
				PageDots(count: count, current: -1)
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Loading news")
	}
}

/// A news card while Browse's apps load: shapes where its picture, source
/// and date, title, caption and app go, in a card as tall as `NewsCard`,
/// whose parts it lays out the same way.
private struct NewsCardPlaceholder: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Rectangle()
				.opacity(0.6)
				.aspectRatio(16 / 9, contentMode: .fit)
			VStack(alignment: .leading, spacing: 4) {
				Text(verbatim: "Source")
					.font(.caption.weight(.semibold))
					.frame(minHeight: 18)
					.hidden()
					.overlay(alignment: .leading) {
						Capsule()
							.frame(width: 110, height: 10)
					}
					.padding(.bottom, 2)
				PlaceholderLines(Text(verbatim: "Title").font(.title3.bold()), widths: [0.9, 0.6], height: 16)
				PlaceholderLines(Text(verbatim: "Caption").font(.subheadline), widths: [0.8, 0.45], height: 11)
			}
			.padding(.horizontal, 16)
			.padding(.top, 14)
			Spacer(minLength: 12)
			NewsAppBar.placeholder
				.hidden()
				.overlay {
					HStack(spacing: 10) {
						RoundedRectangle(cornerRadius: 42 * 0.22, style: .continuous)
							.frame(width: 42, height: 42)
						VStack(alignment: .leading, spacing: 7) {
							Capsule()
								.frame(width: 110, height: 12)
							Capsule()
								.frame(width: 76, height: 9)
						}
						Spacer(minLength: 0)
						Capsule()
							.frame(width: 72, height: 30)
					}
					.padding(10)
				}
				.padding([.horizontal, .bottom], 16)
		}
		.foregroundStyle(Color(.systemGray4))
		.background(Color(.systemGray5))
		.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		.placeholderPulse()
	}
}

/// A source's featured apps while Browse's apps load: as many cards as it
/// featured last time, two to a page as `FeaturedPages` shows them, with
/// shapes where each app's icon, Install button and name go, and the dots
/// when there were more than two.
private struct FeaturedPlaceholders: View {
	let count: Int
	let tint: SourceTint

	var body: some View {
		VStack(spacing: 10) {
			HStack(spacing: 12) {
				ForEach(0..<min(count, 2), id: \.self) { _ in
					card
				}
				if count == 1 {
					Color.clear
						.frame(maxWidth: .infinity, maxHeight: 0)
				}
			}
			.padding(.horizontal, 12)
			if count > 2 {
				PageDots(count: (count + 1) / 2, current: -1)
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Loading featured apps")
	}

	private var card: some View {
		RoundedRectangle(cornerRadius: 20, style: .continuous)
			.fill(tint.foreground.opacity(0.12))
			.frame(maxWidth: .infinity, minHeight: 156, maxHeight: 156)
			.overlay(alignment: .topLeading) {
				RoundedRectangle(cornerRadius: 52 * 0.22, style: .continuous)
					.frame(width: 52, height: 52)
					.padding(12)
			}
			.overlay(alignment: .topTrailing) {
				Capsule()
					.frame(width: 66, height: 28)
					.padding(10)
			}
			.overlay(alignment: .bottomLeading) {
				VStack(alignment: .leading, spacing: 8) {
					Capsule()
						.frame(width: 96, height: 11)
					Capsule()
						.frame(width: 120, height: 9)
				}
				.padding(12)
			}
			.foregroundStyle(tint.foreground.opacity(0.16))
			.placeholderPulse()
	}
}

/// A category's row while Browse's apps load.
private struct CategoryPlaceholder: View {
	var body: some View {
		HStack(spacing: 16) {
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.frame(width: 24, height: 24)
			Capsule()
				.frame(width: 120, height: 12)
			Spacer(minLength: 8)
			Capsule()
				.frame(width: 28, height: 12)
		}
		.foregroundStyle(Color(.systemGray5))
		.placeholderPulse()
		.accessibilityHidden(true)
	}
}

/// An app's row while Browse's apps load, as `AppRow` lays one out.
private struct AppRowPlaceholder: View {
	var body: some View {
		HStack(spacing: 12) {
			RoundedRectangle(cornerRadius: 48 * 0.22, style: .continuous)
				.frame(width: 48, height: 48)
			VStack(alignment: .leading, spacing: 7) {
				Capsule()
					.frame(width: 140, height: 12)
				Capsule()
					.frame(width: 60, height: 9)
				Capsule()
					.frame(width: 180, height: 10)
			}
			Spacer(minLength: 8)
			Capsule()
				.frame(width: 72, height: 30)
		}
		.padding(.vertical, 2)
		.foregroundStyle(Color(.systemGray5))
		.placeholderPulse()
		.accessibilityHidden(true)
	}
}

/// Bars where `text`'s lines go, one per entry of `widths`, each that
/// share of the width, in the space the text takes.
private struct PlaceholderLines: View {
	let text: Text
	let widths: [CGFloat]
	let height: CGFloat

	init(_ text: Text, widths: [CGFloat], height: CGFloat) {
		self.text = text
		self.widths = widths
		self.height = height
	}

	var body: some View {
		text
			.lineLimit(widths.count, reservesSpace: true)
			.frame(maxWidth: .infinity, alignment: .leading)
			.hidden()
			.overlay {
				GeometryReader { proxy in
					VStack(alignment: .leading, spacing: 0) {
						ForEach(widths.indices, id: \.self) { index in
							Capsule()
								.frame(width: proxy.size.width * widths[index], height: height)
								.frame(maxHeight: .infinity)
						}
					}
				}
			}
	}
}

private extension View {
	/// A placeholder's slow pulse while Browse's apps load, which Reduce
	/// Motion stills.
	func placeholderPulse() -> some View {
		modifier(PlaceholderPulse())
	}
}

private struct PlaceholderPulse: ViewModifier {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	@ViewBuilder
	func body(content: Content) -> some View {
		if reduceMotion {
			content
		} else {
			content.phaseAnimator([false, true]) { view, dimmed in
				view.opacity(dimmed ? 0.55 : 1)
			} animation: { _ in
				.easeInOut(duration: 0.9)
			}
		}
	}
}
