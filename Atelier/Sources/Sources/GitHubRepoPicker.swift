import GitHubKit
import AtelierCore
import SourceKit
import SwiftData
import SwiftUI

/// The add sheet's GitHub tab: each account's repos, then the ones they
/// starred, each with its newest release that has an .ipa, to add with a
/// tap. Search narrows the lists, and any `owner/repo` typed or pasted there
/// can be added too. The repo picked shows under the field in place of the
/// lists, as on the AltStore Source tab (#83). The accounts' pictures, at
/// the top right, open the GitHub screen in the sheet.
struct GitHubRepoPicker: View {
	@Environment(SourcesModel.self) private var model
	@Query private var sources: [SourceRecord]
	@State private var accounts = GitHubAccess.accounts.all
	/// Each account's own repos, in the accounts' order (#74).
	@State private var mine: [AccountRepos] = []
	@State private var starred: [Listed] = []
	@State private var newest: [GitHubRepo: Newest] = [:]
	@State private var isLoading = false
	@State private var error: String?
	@State private var showingAccounts = false

	enum Newest: Equatable {
		case app(tag: String, isPrerelease: Bool)
		case noApp
		case unknown
	}

	/// A repo in a list, with the account that listed it, which reads the
	/// repo when it's added from there (#74).
	struct Listed: Identifiable {
		let listing: GitHubAPI.Listing
		let account: GitHubAccount
		var id: String { listing.id }
	}

	struct AccountRepos: Identifiable {
		let account: GitHubAccount
		let repos: [Listed]
		var id: UUID { account.id }
	}

	var body: some View {
		let draft = model.draft
		let preview = draft?.preview(on: .gitHub)
		let isChecking = draft?.isChecking ?? false
		VStack(spacing: 0) {
			Form {
				Section {
					HStack(spacing: 8) {
						TextField("Search or enter owner/repo", text: Binding(
							get: { model.draft?.search ?? "" },
							set: { model.setSearch($0) }
						))
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.submitLabel(.go)
						.onSubmit(submit)
						.disabled(isChecking)
						if isChecking {
							ProgressView()
						} else if search.isEmpty {
							// PasteButton reads the clipboard without iOS asking for permission.
							PasteButton(payloadType: String.self) { strings in
								guard let text = strings.first else { return }
								Task { @MainActor in paste(text) }
							}
							.labelStyle(.iconOnly)
							.buttonBorderShape(.circle)
						} else {
							ClearButton { model.setSearch("") }
						}
					}
					if preview == nil, !isChecking, let typed, !listed(typed) {
						Button("Add \(typed.description)", systemImage: "plus.circle") { model.add(link: typed.description) }
					}
				}

				// The lists' own error only matters while they show.
				if let error = draft?.error ?? (preview == nil ? error : nil) {
					Section {
						Label(error, systemImage: "xmark.octagon.fill")
							.foregroundStyle(.red)
						if draft?.error != nil, draft?.organization != nil {
							Link(destination: GitHubAccess.requestAccessURL) {
								Label("Request Access on GitHub", systemImage: "arrow.up.right")
									.labelStyle(TrailingIconLabelStyle())
							}
						}
					} footer: {
						if draft?.error != nil, let organization = draft?.organization {
							Text("Opens Atelier's page in your GitHub settings: tap Request next to \(organization), and its owners get the request.")
						}
					}
				}

				if let preview {
					SourceToAdd(preview: preview)
				} else {
					if accounts.isEmpty {
						Section {
							NavigationLink {
								GitHubAccountsView()
							} label: {
								Label("Sign In to GitHub", systemImage: "person.crop.circle")
							}
						} footer: {
							Text("Sign in to see your repos, private ones included, and the ones you starred.")
						}
					}

					ForEach(mine) { own in
						list(filtered(own.repos), title: own.account.login.map { "Your repos · @\($0)" } ?? "Your repos", ownerShown: { $0.owner.lowercased() != own.account.login?.lowercased() })
					}
					list(filtered(starred), title: "Starred", ownerShown: { _ in true })

					if isLoading, mine.allSatisfy(\.repos.isEmpty), starred.isEmpty {
						Section {
							HStack {
								Spacer()
								ProgressView()
								Spacer()
							}
						}
					}
				}
			}
			.listSectionSpacing(preview == nil ? .default : .compact)
			if preview != nil {
				AddSourceButton()
			}
		}
		.task(id: accounts.map(\.id)) { await load() }
		.onAppear {
			// Back from the GitHub screen, with accounts added or signed out.
			accounts = GitHubAccess.accounts.all
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					showingAccounts = true
				} label: {
					AccountPictures(accounts: accounts)
				}
				.accessibilityLabel("GitHub Accounts")
			}
		}
		.navigationDestination(isPresented: $showingAccounts) {
			GitHubAccountsView()
		}
	}

	/// The field: a search, or the repo being added.
	private var search: String { model.draft?.search ?? "" }

	/// What's typed, when it names a repo.
	private var typed: GitHubRepo? {
		SourcesModel.gitHubRepo(in: search.trimmingCharacters(in: .whitespaces))
	}

	private func listed(_ repo: GitHubRepo) -> Bool {
		(mine.flatMap(\.repos) + starred).contains { $0.listing.repo == repo }
	}

	private func filtered(_ listed: [Listed]) -> [Listed] {
		let text = search.trimmingCharacters(in: .whitespaces).lowercased()
		guard !text.isEmpty else { return listed }
		return listed.filter { $0.listing.fullName.lowercased().contains(text) }
	}

	/// `ownerShown` says whether a repo shows its owner: in an account's own
	/// list, when it's someone else's (#74).
	@ViewBuilder
	private func list(_ listed: [Listed], title: String, ownerShown: @escaping (GitHubRepo) -> Bool) -> some View {
		if !listed.isEmpty {
			Section(title) {
				ForEach(listed) { item in
					RepoRow(
						listing: item.listing,
						ownerShown: ownerShown(item.listing.repo),
						newest: newest[item.listing.repo] ?? .unknown,
						isAdded: sources.contains { $0.url == item.listing.repo.sourceURL },
						add: {
							// Added from an account's list, it's read as that account.
							GitHubAccess.accounts.remember(item.account, for: item.listing.repo)
							model.add(link: item.listing.repo.description)
						}
					)
				}
			}
		}
	}

	/// Go loads a repo, or a link to another source on the AltStore Source
	/// tab; anything else stays a search.
	private func submit() {
		let text = search.trimmingCharacters(in: .whitespaces)
		if typed != nil || text.contains("://") { model.check() }
	}

	/// The same for what's pasted, which otherwise becomes the search.
	private func paste(_ text: String) {
		let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if SourcesModel.gitHubRepo(in: text) != nil || text.contains("://") {
			model.add(link: text)
		} else {
			model.setSearch(text)
		}
	}

	/// One account's repos and stars, or why GitHub didn't list them.
	private typealias Found = (account: GitHubAccount, mine: [GitHubAPI.Listing], starred: [GitHubAPI.Listing], problem: Error?)

	private func load() async {
		let accounts = self.accounts
		guard !accounts.isEmpty else {
			mine = []
			starred = []
			return
		}
		isLoading = true
		error = nil
		// Every account's lists at once.
		var found: [UUID: Found] = [:]
		await withTaskGroup(of: Found.self) { group in
			for account in accounts {
				let api = GitHubAccess.accounts.api(for: account)
				group.addTask {
					do {
						async let own = api.myRepos()
						async let stars = api.starredRepos()
						let lists = try await (own, stars)
						return (account, lists.0, lists.1, nil)
					} catch {
						return (account, [], [], error)
					}
				}
			}
			for await lists in group { found[lists.account.id] = lists }
		}
		guard !Task.isCancelled else { return }
		// A repo shows once: in the first account's list that has it, or
		// else under Starred.
		var seen = Set<GitHubRepo>()
		var problem: String?
		mine = accounts.compactMap { account in
			guard let lists = found[account.id] else { return nil }
			if var failure = lists.problem {
				// Whose sign-in GitHub refused.
				if let refused = failure as? GitHubAPI.Problem { failure = refused.naming(account) }
				problem = problem ?? SourceLibrary.message(for: failure)
			}
			let own = lists.mine.filter { seen.insert($0.repo).inserted }
			return AccountRepos(account: account, repos: own.map { Listed(listing: $0, account: account) })
		}
		starred = accounts.flatMap { account in
			(found[account.id]?.starred ?? [])
				.filter { seen.insert($0.repo).inserted }
				.map { Listed(listing: $0, account: account) }
		}
		error = problem
		isLoading = false

		// Which repos have apps: one request each, as the account that listed
		// it, a few at a time, so the rows fill in as answers come.
		let toCheck = (mine.flatMap(\.repos) + starred).filter { newest[$0.listing.repo] == nil }
		for batch in stride(from: 0, to: toCheck.count, by: 6).map({ Array(toCheck[$0..<min($0 + 6, toCheck.count)]) }) {
			await withTaskGroup(of: (GitHubRepo, Newest).self) { group in
				for item in batch {
					let api = GitHubAccess.accounts.api(for: item.account)
					let repo = item.listing.repo
					group.addTask {
						guard let release = try? await api.newestAppRelease(repo) else { return (repo, .noApp) }
						return (repo, .app(tag: release.tag, isPrerelease: GitHubSource.isPrerelease(release)))
					}
				}
				for await (repo, value) in group { newest[repo] = value }
			}
			if Task.isCancelled { return }
		}
	}
}

/// The way to the GitHub screen, at the top right: the account's picture,
/// the first two overlapping when there are more, or a person while there
/// are none.
private struct AccountPictures: View {
	let accounts: [GitHubAccount]

	var body: some View {
		if let first = accounts.first {
			HStack(spacing: -10) {
				AccountAvatar(account: first, size: 30)
				if accounts.count > 1 {
					// Cut out of the first.
					AccountAvatar(account: accounts[1], size: 30)
						.padding(2)
						.background(.background, in: Circle())
				}
			}
		} else {
			Image(systemName: "person.crop.circle")
		}
	}
}

private struct RepoRow: View {
	let listing: GitHubAPI.Listing
	let ownerShown: Bool
	let newest: GitHubRepoPicker.Newest
	let isAdded: Bool
	let add: () -> Void

	private var name: String {
		ownerShown ? listing.fullName : String(listing.fullName.split(separator: "/").last ?? "")
	}

	private var detail: String {
		switch newest {
		case .app(let tag, let isPrerelease): isPrerelease ? "\(tag) · pre-release" : tag
		case .noApp: "No releases with an .ipa"
		case .unknown: "Checking…"
		}
	}

	private var hasApp: Bool {
		if case .app = newest { return true }
		return false
	}

	var body: some View {
		HStack(spacing: 12) {
			GitHubMark(size: 20)
				.foregroundStyle(.secondary)
				.frame(width: 36, height: 36)
				.background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(name)
						.font(.body.weight(.semibold))
						.lineLimit(1)
					if listing.isPrivate {
						Image(systemName: "lock.fill")
							.font(.caption)
							.foregroundStyle(.secondary)
							.accessibilityLabel("Private")
					}
				}
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 8)
			if isAdded {
				Text("Added")
					.foregroundStyle(.secondary)
			} else if hasApp {
				Button("Add", action: add)
					.buttonStyle(.bordered)
					.buttonBorderShape(.capsule)
					.controlSize(.small)
			}
		}
		// The whole row picks the repo, as Add does (#83).
		.contentShape(Rectangle())
		.onTapGesture {
			if hasApp, !isAdded { add() }
		}
		.opacity(newest == .noApp && !isAdded ? 0.45 : 1)
	}
}
