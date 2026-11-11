import AuthenticationServices
import GitHubKit
import InstallKit
import AtelierCore
import SourceKit
import SwiftData
import SwiftUI

/// Sources' last row (#30, #74): the GitHub account repos are read as, or
/// how many there are, opening the GitHub screen; Sign In to GitHub until
/// there's one. It was Settings › GitHub until the maintainer moved it under the repos
/// it's for (30 Oct 2026), out of the way of anyone who never adds one.
struct GitHubAccountRow: View {
	/// Opens the GitHub screen, to sign in.
	let signIn: () -> Void
	/// Read again whenever Sources shows, since the GitHub screen changes them.
	@State private var accounts = GitHubAccess.accounts.all

	var body: some View {
		Group {
			if let account = accounts.first {
				NavigationLink {
					GitHubAccountsView()
				} label: {
					LabeledContent {
						Text(accounts.count == 1 ? account.name : "\(accounts.count)")
					} label: {
						HStack(spacing: 9) {
							GitHubMark(size: 20)
							Text(accounts.count == 1 ? "GitHub Account" : "GitHub Accounts")
						}
					}
				}
			} else {
				// An action, so a blue line rather than a row with a chevron.
				Button(action: signIn) {
					HStack(spacing: 9) {
						GitHubMark(size: 20)
						Text("Sign In to GitHub")
					}
				}
			}
		}
		.onAppear { accounts = GitHubAccess.accounts.all }
	}
}

/// The GitHub screen (#74): the accounts Atelier reads repos as, each with
/// its own sign-in, then Add Account and Paste a Token. With none yet, Sign
/// In with GitHub or Paste a Token Instead, as before (#30).
struct GitHubAccountsView: View {
	@Environment(SourcesModel.self) private var sources
	@Environment(\.webAuthenticationSession) private var webAuthenticationSession
	@Query(sort: \SourceRecord.addedAt) private var records: [SourceRecord]
	@State private var accounts = GitHubAccess.accounts.all
	@State private var isSigningIn = false
	@State private var error: String?

	var body: some View {
		Form {
			if accounts.isEmpty {
				Section {
					Button {
						Task { await signIn() }
					} label: {
						HStack {
							Text("Sign In with GitHub").bold()
							if isSigningIn { ProgressView() }
						}
						.frame(maxWidth: .infinity)
					}
					.disabled(isSigningIn)
				} footer: {
					Text("Lets Atelier read your private repos and the ones shared with you, and lifts GitHub's limit from 60 to 5,000 checks an hour. GitHub only grants private access together with write access; Atelier only ever reads. The sign-in is kept in the Keychain.")
				}
				errorSection
				Section {
					NavigationLink("Paste a Token Instead") {
						GitHubTokenView { update() }
					}
					.foregroundStyle(.tint)
				} header: {
					Text("Or")
				} footer: {
					Text("A fine-grained token from github.com, if you'd rather give read-only access to only the repos you choose.")
				}
			} else {
				Section {
					ForEach(accounts) { account in
						let reads = repos(of: account)
						NavigationLink {
							GitHubAccountView(account: account, repos: reads, isOnly: accounts.count == 1) {
								signOut(account)
							}
						} label: {
							AccountRow(account: account, repoCount: reads.count)
						}
						// Straight away, as Sign Out on its page does.
						.swipeActions(edge: .trailing, allowsFullSwipe: true) {
							Button(account.kind == .token ? "Remove" : "Sign Out", role: .destructive) {
								signOut(account)
							}
						}
					}
					Button {
						Task { await signIn() }
					} label: {
						HStack {
							Label("Add Account", systemImage: "plus.circle.fill")
							if isSigningIn {
								Spacer()
								ProgressView()
							}
						}
					}
					.disabled(isSigningIn)
				} header: {
					Text("Accounts")
				} footer: {
					Text("A repo you add uses the first account that can see it, and keeps it. Each account lifts GitHub's limit from 60 to 5,000 checks an hour.")
				}
				errorSection
				Section {
					NavigationLink("Paste a Token") {
						GitHubTokenView { update() }
					}
					.foregroundStyle(.tint)
				} footer: {
					Text("A fine-grained token from github.com, if you'd rather give read-only access to only the repos you choose. It's listed with your accounts.")
				}
			}
		}
		.navigationTitle("GitHub")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { accounts = GitHubAccess.accounts.all }
		// #30's pasted token gets its owner's name.
		.task {
			await GitHubAccess.nameAccounts()
			accounts = GitHubAccess.accounts.all
		}
	}

	@ViewBuilder
	private var errorSection: some View {
		if let error {
			Section {
				Label(error, systemImage: "xmark.octagon.fill")
					.foregroundStyle(.red)
			}
		}
	}

	/// The added GitHub repos that `account` reads.
	private func repos(of account: GitHubAccount) -> [SourceRecord] {
		records.filter { record in
			guard let repo = GitHubRepo(sourceURL: record.url) else { return false }
			return GitHubAccess.accounts.account(for: repo)?.id == account.id
		}
	}

	private func signIn() async {
		error = nil
		isSigningIn = true
		defer { isSigningIn = false }
		do {
			// Cancelled, it's back to this screen as it was.
			if try await GitHubAccess.signInOnTheWeb(using: webAuthenticationSession) { update() }
		} catch {
			self.error = GitHubAccess.message(for: error)
		}
	}

	private func signOut(_ account: GitHubAccount) {
		GitHubAccess.signOut(account)
		update()
	}

	/// After signing in or out: the list, and GitHub sources, which may see
	/// more or less now, or switch to another account.
	private func update() {
		accounts = GitHubAccess.accounts.all
		Task { await sources.refreshForAccounts() }
	}
}

extension GitHubAccess {
	/// Signs in with GitHub on the web and lists the account, or renews its
	/// sign-in when it's listed: the GitHub screen's Sign In with GitHub and
	/// Add Account, and Sign In to GitHub where a source or download needs
	/// an account (#134). False when the user cancelled, in the sheet or on
	/// GitHub's page.
	@MainActor
	static func signInOnTheWeb(using webAuthenticationSession: WebAuthenticationSession) async throws -> Bool {
		do {
			// The first account signs in with Safari's cookies, so someone
			// signed in to GitHub in Safari can go on as that account with a
			// tap. GitHub's account picker asks first, so signing in again
			// after signing out of every account can pick another one
			// (30 Oct 2026). Each account after it signs in privately, so GitHub
			// asks who's signing in rather than going on as an account that's
			// listed already (#74); there's no one signed in there to pick.
			let privately = signsInPrivately
			let attempt = try signIn.start(picksAccount: !privately)
			let session: WebAuthenticationSession.BrowserSession = privately ? .ephemeral : .shared
			let callback = try await webAuthenticationSession.authenticate(
				using: attempt.authorizeURL,
				callbackURLScheme: GitHubSignIn.callbackScheme,
				preferredBrowserSession: session
			)
			let account = try await signIn.finish(attempt, callback: callback)
			try add(account)
			return true
		} catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
			// Cancel in the sheet.
			return false
		} catch GitHubSignIn.Problem.denied {
			// Cancel on GitHub's page.
			return false
		}
	}
}

/// Sign In to GitHub where a source, a download or an install needs an
/// account, and where an app's page may be out of date without one (#134):
/// GitHub's sign-in straight away, as Sign In with GitHub does on the GitHub
/// screen, and the sources load again by themselves once it's done. A
/// token is pasted on the GitHub screen, as before.
struct GitHubSignInButton: View {
	/// A filled capsule, as the one thing to do on a source's page; a blue
	/// line otherwise, as Try again is.
	var isProminent = false
	/// Shorter where there's little room, as "Sign In" in the install bar.
	var title = "Sign In to GitHub"
	/// GitHub's mark before the title; not in the install bar, whose
	/// buttons are words only.
	var showsMark = true
	/// After signing in, as a download or an install starting again.
	var signedIn: () -> Void = {}
	@Environment(SourcesModel.self) private var sources
	@Environment(\.webAuthenticationSession) private var webAuthenticationSession
	@State private var isSigningIn = false
	@State private var error: String?
	@ScaledMetric(relativeTo: .body) private var largeMark: CGFloat = 20
	@ScaledMetric(relativeTo: .subheadline) private var smallMark: CGFloat = 17

	var body: some View {
		Button {
			Task { await signIn() }
		} label: {
			HStack(spacing: isProminent ? 9 : 6) {
				if showsMark {
					GitHubMark(size: isProminent ? largeMark : smallMark)
						// The button says it.
						.accessibilityHidden(true)
				}
				Text(title)
				if isSigningIn {
					ProgressView()
						.tint(isProminent ? Color.white : nil)
				}
			}
		}
		.disabled(isSigningIn)
		.modifier(Prominence(isProminent: isProminent))
		// Blue wherever it is, also on a page in its source's colour (#134).
		.tint(.blue)
		// GitHub's or the Keychain's own words, as on the GitHub screen.
		.alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK", role: .cancel) {}
		}
	}

	private func signIn() async {
		error = nil
		isSigningIn = true
		defer { isSigningIn = false }
		do {
			guard try await GitHubAccess.signInOnTheWeb(using: webAuthenticationSession) else { return }
			signedIn()
			await sources.refreshForAccounts()
		} catch {
			self.error = GitHubAccess.message(for: error)
		}
	}

	private struct Prominence: ViewModifier {
		let isProminent: Bool

		func body(content: Content) -> some View {
			if isProminent {
				content
					.bold()
					.buttonStyle(.borderedProminent)
					.buttonBorderShape(.capsule)
					.controlSize(.large)
			} else {
				content
			}
		}
	}
}

/// An account in the list: who it is, and how many repos it reads.
private struct AccountRow: View {
	let account: GitHubAccount
	let repoCount: Int

	var body: some View {
		HStack(spacing: 12) {
			AccountAvatar(account: account, size: 32)
			VStack(alignment: .leading, spacing: 1) {
				Text(account.name)
				Text(summary)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}

	/// "Signed in · 2 repos".
	private var summary: String {
		let kind = account.kind == .token ? "Token" : "Signed in"
		return repoCount == 1 ? "\(kind) · 1 repo" : "\(kind) · \(repoCount) repos"
	}
}

/// An account's GitHub picture, or a person or key while there's none.
struct AccountAvatar: View {
	let account: GitHubAccount
	let size: CGFloat

	var body: some View {
		LoadedImage(url: account.avatarURL, maxPoints: size) { image in
			// As it is, also in the GitHub tab's toolbar, which tints images.
			Image(uiImage: image)
				.renderingMode(.original)
				.resizable()
		} placeholder: {
			Image(systemName: account.kind == .token ? "key.fill" : "person.fill")
				.font(.system(size: size * 0.45))
				.foregroundStyle(.white)
				.frame(width: size, height: size)
				.background(Color.secondary.opacity(0.5))
		}
		.scaledToFill()
		.frame(width: size, height: size)
		.clipShape(Circle())
		.accessibilityHidden(true)
	}
}

/// One account (#74): who it is, the repos it reads, and Sign Out, or Remove
/// Token for a pasted one.
private struct GitHubAccountView: View {
	let account: GitHubAccount
	let repos: [SourceRecord]
	/// Whether it's the only account, so its repos have none to switch to.
	let isOnly: Bool
	let signOut: () -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		Form {
			Section {
				HStack(spacing: 14) {
					AccountAvatar(account: account, size: 52)
					VStack(alignment: .leading, spacing: 2) {
						Text(account.name)
							.font(.title3.bold())
						Text(account.kind == .token ? "Pasted token" : "Signed in with GitHub")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.vertical, 4)
			}
			Section {
				if repos.isEmpty {
					Text("None yet")
						.foregroundStyle(.secondary)
				}
				ForEach(repos) { source in
					AccountRepoRow(source: source)
				}
			} header: {
				Text("Repos")
			} footer: {
				Text("Atelier checks these repos and downloads their apps with this account.")
			}
			Section {
				Button(account.kind == .token ? "Remove Token" : "Sign Out", role: .destructive) {
					signOut()
					dismiss()
				}
				.frame(maxWidth: .infinity)
			} footer: {
				Text(signOutNote)
			}
		}
		.navigationTitle(account.name)
		.navigationBarTitleDisplayMode(.inline)
	}

	/// What happens to its repos, and where to revoke it on GitHub.
	private var signOutNote: String {
		let effect = if isOnly {
			account.kind == .token
				? "Private repos stop updating until you sign in or paste a token again; public ones keep updating, at GitHub's lower limit."
				: "Private repos stop updating until you sign in again; public ones keep updating, at GitHub's lower limit."
		} else {
			account.kind == .token || account.login == nil
				? "Repos another account can see switch to it; the others stop updating until you add one that can see them."
				: "Repos another account can see switch to it; the others stop updating until you sign in to \(account.name) again."
		}
		let revoke = account.kind == .token
			? "To also revoke the token, delete it on github.com in Settings › Developer settings."
			: "To also revoke Atelier's access, go to github.com/settings/applications."
		return effect + " " + revoke
	}
}

/// A repo an account reads, as its source is named.
private struct AccountRepoRow: View {
	let source: SourceRecord

	var body: some View {
		HStack(spacing: 12) {
			SourceIcon(url: source.iconURL, tint: source.tintColor, size: 36)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(source.name)
						.lineLimit(1)
					if isPrivate {
						Image(systemName: "lock.fill")
							.font(.caption)
							.foregroundStyle(.secondary)
							.accessibilityLabel("Private")
					}
				}
				Text(source.subtitle ?? GitHubRepo(sourceURL: source.url)?.description ?? "")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
	}

	private var isPrivate: Bool {
		source.json.flatMap(GitHubSource.summary(of:))?.isPrivate ?? false
	}
}

/// Pasting a fine-grained token, for read-only access to chosen repos.
/// GitHub says whose it is, which names it in the list (#74).
private struct GitHubTokenView: View {
	let saved: () -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var input = ""
	@State private var isSaving = false
	@State private var error: String?

	private static let createURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

	var body: some View {
		Form {
			Section {
				SecureField("github_pat_…", text: $input)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.textContentType(.password)
			} header: {
				Text("Access token")
			} footer: {
				Text("Paste a fine-grained personal access token with read-only Contents access to the repos you add. Atelier keeps it in this \(ThisDevice.name)'s Keychain and only sends it to GitHub.")
			}
			Section {
				Button {
					Task { await save() }
				} label: {
					HStack {
						Text("Save Token").bold()
						if isSaving { ProgressView() }
					}
					.frame(maxWidth: .infinity)
				}
				.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
			}
			if let error {
				Section {
					Label(error, systemImage: "xmark.octagon.fill")
						.foregroundStyle(.red)
				}
			}
			Section {
				Link(destination: Self.createURL) {
					Label("Create a Token on GitHub", systemImage: "arrow.up.right")
						.labelStyle(TrailingIconLabelStyle())
				}
			} footer: {
				Text("Opens github.com in Safari. Pick the repos under \"Repository access\", then Contents: Read-only under \"Permissions\".")
			}
		}
		.navigationTitle("Paste a Token")
		.navigationBarTitleDisplayMode(.inline)
	}

	private func save() async {
		error = nil
		isSaving = true
		defer { isSaving = false }
		do {
			try await GitHubAccess.addPasted(input)
			saved()
			dismiss()
		} catch {
			self.error = GitHubAccess.message(for: error)
		}
	}
}

/// The title, then the icon, as on links that leave the app.
struct TrailingIconLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.title
			configuration.icon
				.font(.footnote.weight(.semibold))
		}
	}
}
