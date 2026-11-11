import Foundation
import GitHubKit
import Observation
import AtelierCore
import SourceKit

/// The user's sources (#13): adding one, refreshing them and removing them.
/// The list itself comes from the store through `@Query`. Atelier's own
/// source is one of them from the start (#24).
@MainActor
@Observable
final class SourcesModel {
	/// A source being added, shown in the add sheet.
	struct Draft {
		/// The add sheet's tabs.
		enum Tab {
			case altStore
			case gitHub
		}

		enum Phase {
			case editing
			case checking
			/// Downloaded and shown under the field, waiting for the user to
			/// tap Add Source (#83).
			case confirming(SourceLibrary.Preview)
		}

		var tab = Tab.altStore
		/// The AltStore Source tab's field.
		var input = ""
		/// The GitHub tab's field: a search, or the repo being added.
		var search = ""
		var phase = Phase.editing
		var error: String?
		/// With `error`, when none of the user's GitHub accounts can see a
		/// repo of this organization: it may have to approve Atelier (#74).
		var organization: String?
		/// The source's Include Pre-releases (#104): off, unless all it
		/// lists are betas.
		var includesPrereleases = false
		/// What the link that opened the sheet is for, until the user changes
		/// the source (#93): the sheet shows only the source's tab, and for an
		/// app or an install, a note on why it needs the source.
		var link: LinkPurpose?

		var preview: SourceLibrary.Preview? {
			if case .confirming(let preview) = phase { return preview }
			return nil
		}

		/// The source shown on `tab`: a GitHub repo shows on the GitHub tab,
		/// any other source on the AltStore Source tab.
		func preview(on tab: Tab) -> SourceLibrary.Preview? {
			guard let preview, (preview.gitHubRepo != nil) == (tab == .gitHub) else { return nil }
			return preview
		}

		var isChecking: Bool {
			if case .checking = phase { return true }
			return false
		}

		/// The app an app or install link is for, as the source shows it to
		/// be listed, with or without its betas (#104): by its bundle ID, or
		/// by the IPA, one of its versions or their builds (#30).
		var linkedApp: SourceApp? {
			guard let preview, let link else { return nil }
			let apps = preview.source.listing(prereleases: includesPrereleases).apps
			switch link {
			case .source:
				return nil
			case .app(let bundleID):
				return apps.first { $0.bundleID == bundleID }
					?? apps.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
			case .install(let ipa):
				return apps.first { app in app.versions.contains { $0.downloading(ipa) != nil } }
			}
		}
	}

	/// What a link that opens the add sheet is for (#93).
	enum LinkPurpose: Equatable {
		/// The source alone.
		case source
		/// The app with this bundle ID, shown once the source is added.
		case app(bundleID: String)
		/// The IPA at this address, installed once the source is added.
		case install(URL)
	}

	/// Non-nil while the add sheet is showing.
	var draft: Draft?
	/// What the link that opened the add sheet was for, as of the last
	/// source added from the sheet (#93), when the sheet showed the app the
	/// link is for: nil otherwise, as when no link opened it or the user
	/// changed the source. An install link's app installs then without
	/// asking again, as the sheet said it would.
	private(set) var lastAddedLink: LinkPurpose?
	private(set) var isRefreshing = false
	/// Set when removing a source fails.
	var error: String?
	/// Turning a source's pre-releases off while betas from it are
	/// installed, waiting for the user to confirm (#104).
	var prereleasesOff: PrereleasesOff?
	/// The sources whose last refresh found them in a GitHub repo that only
	/// an account can read, while there's none (#134), kept by `RootView`
	/// from the saved sources.
	var signInNeeded: Set<URL> = []

	private let library: SourceLibrary
	private var checkTask: Task<Void, Never>?
	/// The refresh under way, which one after the GitHub accounts changed
	/// waits for, and its number, so only the last one says it's done.
	private var refreshing: Task<Void, Never>?
	private var refreshCount = 0
	/// Goes up as a source's Include Pre-releases changes, which isn't in
	/// the saved data, so what shows the setting follows it (#104).
	private var prereleaseSettingChanges = 0

	init(library: SourceLibrary) {
		self.library = library
		// Named as its JSON names it, also in a copy of Atelier before the
		// first refresh, which a private repo needs a GitHub sign-in for
		// (#113).
		try? library.addBuiltIn(at: SelfUpdate.sourceURL, name: SelfUpdate.sourceName)
	}

	/// Whether the source at `url` lists its betas (#104), for views to show
	/// and follow.
	func listsPrereleases(_ url: URL) -> Bool {
		_ = prereleaseSettingChanges
		return Prereleases.preferences.includes(url)
	}

	/// Whether what Atelier shows from the source at `url` may be out of
	/// date until the user signs in to GitHub (#134): an app it lists, its
	/// news, or an app installed from it says so.
	func needsGitHubSignIn(_ url: URL?) -> Bool {
		url.map { signInNeeded.contains($0) } ?? false
	}

	/// Opens the add sheet; from Manage Sources' GitHub section, on its tab.
	func beginAdd(gitHub: Bool = false) {
		if draft == nil { draft = Draft(tab: gitHub ? .gitHub : .altStore) }
	}

	/// Opens the add sheet, if it isn't open, for a source's address, an
	/// `atelier://` or `altstore://` link, a scanned code or a GitHub repo,
	/// and downloads the source straight away: a GitHub repo on the GitHub
	/// tab, any other source on the AltStore Source tab (#83). Nothing is
	/// added until the user taps Add Source. `purpose` is what a link that
	/// opened it is for (#93).
	func add(link: String, for purpose: LinkPurpose? = nil) {
		let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		var draft = self.draft ?? Draft()
		if let repo = Self.gitHubRepo(in: text) {
			draft.tab = .gitHub
			draft.search = repo.description
		} else {
			draft.tab = .altStore
			draft.input = text
		}
		draft.link = purpose
		self.draft = draft
		load()
	}

	/// The added source that a link or address names, if any: a link to one
	/// opens its page in Browse instead (#93).
	func addedSource(_ link: String) -> SourceRecord? {
		guard let url = try? SourceLink.sourceURL(from: link) else { return nil }
		return try? library.source(at: url)
	}

	/// Loads what's typed in the current tab's field, for Go. A GitHub repo
	/// typed on the AltStore Source tab, or a link to another source on the
	/// GitHub tab, moves over to its own tab (#83).
	func check() {
		guard var draft else { return }
		let text: String
		switch draft.tab {
		case .altStore:
			text = draft.input
			if Self.gitHubRepo(in: text) != nil { draft.input = "" }
		case .gitHub:
			text = draft.search
			if Self.gitHubRepo(in: text) == nil { draft.search = "" }
		}
		self.draft = draft
		add(link: text)
	}

	/// Shows another tab of the add sheet. A download under way stops and an
	/// error goes, as both are about the other tab's field (#83).
	func select(_ tab: Draft.Tab) {
		guard let current = draft, current.tab != tab else { return }
		if current.isChecking {
			checkTask?.cancel()
			draft?.phase = .editing
		}
		draft?.error = nil
		draft?.tab = tab
	}

	/// The AltStore Source tab's field changed: the source loaded from it
	/// goes until the new address loads (#83).
	func setInput(_ text: String) {
		guard draft?.input != text else { return }
		draft?.input = text
		edited(.altStore)
	}

	/// The GitHub tab's field changed: back to searching (#83).
	func setSearch(_ text: String) {
		guard draft?.search != text else { return }
		draft?.search = text
		edited(.gitHub)
	}

	private func edited(_ tab: Draft.Tab) {
		draft?.error = nil
		// Another source than the link's.
		draft?.link = nil
		guard draft?.preview(on: tab) != nil else { return }
		draft?.phase = .editing
	}

	/// The GitHub repo `text` names, as `owner/repo`, its address or a
	/// source link to it.
	static func gitHubRepo(in text: String) -> GitHubRepo? {
		(try? SourceLink.sourceURL(from: text)).flatMap(GitHubRepo.init(sourceURL:))
	}

	/// Downloads and parses the source in the current tab's field.
	private func load() {
		guard let input = draft.map({ $0.tab == .gitHub ? $0.search : $0.input }) else { return }
		checkTask?.cancel()
		draft?.phase = .checking
		draft?.error = nil
		draft?.organization = nil
		checkTask = Task {
			do {
				let preview = try await library.preview(input)
				guard !Task.isCancelled, draft != nil else { return }
				// A source that only lists betas is added with them listed,
				// its switch on.
				draft?.includesPrereleases = preview.source.listsOnlyPrereleases
				draft?.phase = .confirming(preview)
			} catch {
				guard !Task.isCancelled, draft != nil else { return }
				draft?.phase = .editing
				draft?.error = SourceLibrary.message(for: error)
				if case .notFound(_, let accounts, let organization?)? = error as? GitHubAPI.Problem, accounts > 0 {
					draft?.organization = organization
				}
			}
		}
	}

	/// Lists the betas of the source being added or not, in the add sheet
	/// (#104). Its JSON has them either way, so nothing is read again.
	func setIncludesPrereleases(_ include: Bool) {
		draft?.includesPrereleases = include
	}

	/// Lists an added source's betas or not (#104), from the JSON it has.
	/// The catalog is built again by whoever changed it.
	func setIncludesPrereleases(_ include: Bool, for source: SourceRecord) {
		library.setIncludesPrereleases(include, for: source)
		prereleaseSettingChanges += 1
	}

	func confirmAdd() {
		guard let preview = draft?.preview else { return }
		do {
			try library.add(preview, includingPrereleases: draft?.includesPrereleases ?? false)
			prereleaseSettingChanges += 1
			lastAddedLink = draft?.linkedApp == nil ? nil : draft?.link
			draft = nil
		} catch {
			draft?.phase = .editing
			draft?.error = SourceLibrary.message(for: error)
		}
	}

	func cancelAdd() {
		checkTask?.cancel()
		draft = nil
	}

	/// Refreshes every source, as on launch, pull to refresh and Refresh
	/// Sources.
	func refreshAll() async {
		guard !isRefreshing else { return }
		await refresh()
	}

	/// Refreshes every source after signing in or out of GitHub, once any
	/// refresh under way is done, as that one asked GitHub as the accounts
	/// were before, such as one that started as the sign-in sheet closed
	/// (#134).
	func refreshForAccounts() async {
		if let refreshing { await refreshing.value }
		await refresh()
	}

	private func refresh() async {
		refreshCount += 1
		let number = refreshCount
		let task = Task { await library.refreshAll() }
		refreshing = task
		isRefreshing = true
		await task.value
		guard number == refreshCount else { return }
		refreshing = nil
		isRefreshing = false
	}

	/// Refreshes every source once none was refreshed for `age`, as when
	/// Atelier comes back to the screen, so it finds its own update then
	/// too (#24).
	func refreshIfStale(olderThan age: TimeInterval = 30 * 60) async {
		let latest = (try? library.sources())?.compactMap(\.lastRefreshedAt).max()
		if let latest, Date.now.timeIntervalSince(latest) < age { return }
		await refreshAll()
	}

	func remove(_ source: SourceRecord) {
		// Atelier updates itself from its own (#24).
		guard !source.isBuiltIn else { return }
		let repo = GitHubRepo(sourceURL: source.url)
		do {
			try library.remove(source)
			prereleaseSettingChanges += 1
			if let repo { GitHubAccess.accounts.forget(repo) }
		} catch {
			self.error = "Couldn't remove \(source.name): \(error.localizedDescription)"
		}
	}
}

extension SourceRecord {
	/// Atelier's own source, there from the start: Atelier updates itself
	/// from it, so it can't be removed (#24).
	var isBuiltIn: Bool { url == SelfUpdate.sourceURL }
}
