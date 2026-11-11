import DownloadKit
import Foundation
import GitHubKit
import SourceKit

/// The app's one view of GitHub (#30, #74): the user's GitHub accounts, each
/// with its sign-in or pasted token in the Keychain, and which account reads
/// each repo.
enum GitHubAccess {
	private static let store = GitHubAccounts(tokens: GitHubKeychain())

	/// Atelier's OAuth app on GitHub, registered by the maintainer on 23 Oct 2026.
	/// Its client secret is only in the Worker.
	static let clientID = "Ov23lihRDcwKimthYa2P"
	/// The Worker that holds the client secret (infra/manifest-worker).
	static let worker = URL(string: "https://api.atelierstore.app")!
	static let signIn = GitHubSignIn(clientID: clientID, worker: worker)
	/// Atelier's page in the user's GitHub settings, where a member of an
	/// organization that limits which apps can read its repos asks its
	/// owners to approve Atelier (#74).
	static let requestAccessURL = URL(string: "https://github.com/settings/connections/applications/\(clientID)")!

	/// Whether the tokens were last made readable after first unlock (#72).
	/// Tokens saved before they followed the certificates have none, and
	/// stay readable only while the iPhone is unlocked until they're given it.
	private static let tokensProtectionKey = "github.tokensReadableAfterFirstUnlock"

	/// Gives the tokens the certificates' protection (`AutoUpdates.applyProtection`)
	/// when it changed, or the first time. Only works while the iPhone is
	/// unlocked; otherwise the next call tries again.
	static func applyProtection(readableAfterFirstUnlock relaxed: Bool) {
		guard UserDefaults.standard.object(forKey: tokensProtectionKey) as? Bool != relaxed else { return }
		do {
			try accounts.reprotect()
			UserDefaults.standard.set(relaxed, forKey: tokensProtectionKey)
		} catch {}
	}

	/// Who signed in, when #30 kept one sign-in at most.
	private static let legacyLoginKey = "github.login"
	/// Set once #30's sign-in or token is listed as an account, or there was none.
	private static let adoptedKey = "github.legacyAdopted"

	/// The accounts. #30's sign-in or token joins them the first time the
	/// Keychain can be read, before Atelier asks GitHub anything as it.
	static var accounts: GitHubAccounts {
		if !UserDefaults.standard.bool(forKey: adoptedKey) {
			do {
				try store.adoptLegacyToken(login: UserDefaults.standard.string(forKey: legacyLoginKey))
				UserDefaults.standard.removeObject(forKey: legacyLoginKey)
				UserDefaults.standard.set(true, forKey: adoptedKey)
			} catch {
				// The iPhone is locked: next time.
			}
		}
		return store
	}

	/// Each account after the first signs in through a private browser
	/// session, so GitHub asks who's signing in instead of going on as
	/// whoever is signed in to github.com in Safari (#74).
	static var signsInPrivately: Bool { !accounts.all.isEmpty }

	/// Lists a GitHub sign-in, or renews it when its account is listed.
	@discardableResult
	static func add(_ account: GitHubSignIn.Account) throws -> GitHubAccount {
		try accounts.add(token: account.token, login: account.login, kind: .signedIn, avatarURL: account.avatarURL)
	}

	/// Asks GitHub whose a pasted token is, then lists it under that name.
	@discardableResult
	static func addPasted(_ pasted: String) async throws -> GitHubAccount {
		let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
		let user: GitHubAPI.User
		do {
			user = try await GitHubAPI(token: { token }).user()
		} catch GitHubAPI.Problem.badToken {
			throw RefusedToken()
		}
		return try accounts.add(token: token, login: user.login, kind: .token, avatarURL: user.avatarURL)
	}

	struct RefusedToken: Error, CustomStringConvertible {
		var description: String { "GitHub didn't accept this token. Check that all of it was copied, and that it hasn't expired." }
	}

	/// What to say when signing in or saving a token didn't work.
	static func message(for error: Error) -> String {
		switch error {
		case let problem as RefusedToken: problem.description
		case let problem as GitHubSignIn.Problem: problem.description
		case let problem as GitHubAPI.Problem: problem.description
		case let problem as GitHubKeychain.TokenError: problem.description
		default: error.localizedDescription
		}
	}

	/// Asks GitHub whose each unnamed token is, and for each account's
	/// picture: #30's sign-in or token came without them.
	static func nameAccounts() async {
		for account in accounts.all where account.login == nil || account.avatarURL == nil {
			guard let user = try? await accounts.api(for: account).user() else { continue }
			var named = account
			named.login = user.login
			named.avatarURL = user.avatarURL
			accounts.update(named)
		}
	}

	/// Signs out of `account`: its repos try the other accounts next time.
	static func signOut(_ account: GitHubAccount) {
		accounts.remove(account)
	}

	static func source() -> GitHubSource {
		GitHubSource(credentials: Credentials(), tint: IconTint.hex(of:))
	}

	/// For the download manager: a private repo's asset downloads from the
	/// short-lived address GitHub gives a request with the token of an
	/// account that can see the repo.
	@Sendable static func resolveDownload(_ url: URL) async throws -> URL? {
		if let repo = GitHubAPI.repo(ofAsset: url) {
			return try await accounts.first(for: repo) { try await $0.downloadURL(for: url) }.value
		}
		// A file in a release, by its link on github.com, as a pasted URL or
		// a source gives it: through an account too, so a private repo's
		// downloads (#134). Without one, as it is: github.com serves a public
		// repo's files without using up GitHub's lower limit, and the Library
		// offers to sign in when it answers 404.
		guard let link = GitHubReleaseLink(url: url), !accounts.all.isEmpty else { return nil }
		do {
			return try await accounts.first(for: link.repo) { try await $0.downloadURL(for: link) }.value
		} catch {
			// No account can see the repo: said so, as for a source.
			if case .notFound? = error as? GitHubAPI.Problem { throw error }
			// Over GitHub's limit, a sign-in it refused, or no connection: the
			// link as it is, which works for a public repo, as before.
			return nil
		}
	}

	/// Whether a download failed as GitHub can't find its file without an
	/// account, so signing in may be all it takes (#134): a release asset
	/// of a source read through an account, as Atelier's own while its repo
	/// is private, which only an account can download; or a file in a
	/// release by its link on github.com, which answers 404 for a private
	/// repo's. `failure` is what the download says.
	static func downloadNeedsSignIn(url: URL, failure: String) -> Bool {
		guard accounts.all.isEmpty else { return false }
		if let repo = GitHubAPI.repo(ofAsset: url) {
			return failure == DownloadManager.startFailure(GitHubAPI.Problem.notFound(repo, accounts: 0))
		}
		return GitHubReleaseLink(url: url) != nil && failure == DownloadVerifier.Problem.httpStatus(404).description
	}

	/// Images kept in a private repo that no account could read, this
	/// launch, so each is asked for once.
	@MainActor private static var unreadable: Set<URL> = []

	/// For images (`ImagePipeline`): a file kept in a private GitHub repo,
	/// which raw.githubusercontent.com answers 404 for, read through an
	/// account that can see the repo, as its source is (#24). Nil without
	/// accounts, or when none of them could read it.
	@MainActor static func privateFile(at url: URL) async -> Data? {
		guard let file = GitHubFile(rawURL: url), !accounts.all.isEmpty, !unreadable.contains(url) else { return nil }
		if case .fetched(let data, _)? = try? await accounts.first(for: file.repo, { try await $0.file(file) }).value {
			return data
		}
		unreadable.insert(url)
		return nil
	}

	/// `accounts` as it is at each request.
	private struct Credentials: GitHubCredentials {
		func candidates(for repo: GitHubRepo) -> [GitHubCredential] {
			GitHubAccess.accounts.candidates(for: repo)
		}

		func remember(_ account: GitHubAccount, for repo: GitHubRepo) {
			GitHubAccess.accounts.remember(account, for: repo)
		}
	}
}

extension GitHubAccount {
	/// Its login, or "Token" for a pasted token GitHub hasn't named yet.
	var name: String { login ?? "Token" }
	/// `@login`, as GitHub writes a user.
	var handle: String { login.map { "@\($0)" } ?? "Token" }
}
