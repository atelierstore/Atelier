import Foundation
import SourceKit

/// A GitHub account Atelier reads repos as (#74): one signed in with
/// GitHub, or a pasted token. Its token is in the Keychain
/// (`GitHubKeychain`); this is what's listed about it.
public struct GitHubAccount: Codable, Hashable, Identifiable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// Signed in through GitHub's web sign-in.
		case signedIn
		/// A personal access token the user pasted.
		case token
	}

	public var id: UUID
	/// Who it is on GitHub. Nil for a token pasted before Atelier asked
	/// GitHub whose it is (#30), until it does.
	public var login: String?
	public var kind: Kind
	public var avatarURL: URL?

	public init(id: UUID = UUID(), login: String?, kind: Kind, avatarURL: URL? = nil) {
		self.id = id
		self.login = login
		self.kind = kind
		self.avatarURL = avatarURL
	}
}

/// Where the accounts' tokens are kept: the Keychain in the app
/// (`GitHubKeychain`), memory in tests.
public protocol GitHubTokenStore: Sendable {
	func token(for account: UUID) -> String?
	func save(_ token: String, for account: UUID) throws
	func delete(_ account: UUID)
	/// The one token #30 kept, from before there could be several; nil when
	/// there's none. Throws while it can't be read, as while the device is
	/// locked.
	func legacyToken() throws -> String?
	func deleteLegacyToken()
	/// Gives these accounts' tokens the protection a new one would be saved
	/// with now, after it changed (#72). Only works while the device is
	/// unlocked.
	func reprotect(_ accounts: [UUID]) throws
}

public extension GitHubTokenStore {
	func reprotect(_ accounts: [UUID]) throws {}
}

/// One account's view of GitHub, to try for a repo.
public struct GitHubCredential: Sendable {
	/// Nil when there are no accounts: GitHub without a token.
	public var account: GitHubAccount?
	public var api: GitHubAPI

	public init(account: GitHubAccount?, api: GitHubAPI) {
		self.account = account
		self.api = api
	}
}

/// Who Atelier asks GitHub as, repo by repo (#74).
public protocol GitHubCredentials: Sendable {
	/// The accounts to try for `repo`, in order, the one it uses first; one
	/// without a token when there are none.
	func candidates(for repo: GitHubRepo) -> [GitHubCredential]
	/// `account` could see `repo`, so it reads `repo` from now on.
	func remember(_ account: GitHubAccount, for repo: GitHubRepo)
}

extension GitHubCredentials {
	/// `request` as the account `repo` uses, or when that one can't see it,
	/// as each other account in turn until one can; `repo` keeps that one.
	/// GitHub answers 404 to accounts that can't see a private repo. Also
	/// returns the API that answered, for the requests that follow.
	public func first<T: Sendable>(
		for repo: GitHubRepo,
		_ request: @Sendable (GitHubAPI) async throws -> T
	) async throws -> (value: T, api: GitHubAPI) {
		let candidates = candidates(for: repo)
		var problems: [GitHubAPI.Problem] = []
		for candidate in candidates {
			do {
				let value = try await request(candidate.api)
				if let account = candidate.account { remember(account, for: repo) }
				return (value, candidate.api)
			} catch let problem as GitHubAPI.Problem where problem.triesAnotherAccount {
				problems.append(problem.naming(candidate.account))
			}
		}
		let accounts = candidates.filter { $0.account != nil }.count
		throw await Self.summary(of: problems, repo: repo, accounts: accounts, api: candidates.first?.api)
	}

	/// What to say when no account could: the limit, while one is over it;
	/// a sign-in GitHub refused; or that none can see the repo, and that
	/// its organization may have to approve Atelier.
	private static func summary(of problems: [GitHubAPI.Problem], repo: GitHubRepo, accounts: Int, api: GitHubAPI?) async -> GitHubAPI.Problem {
		if let limit = problems.first(where: \.isRateLimit) { return limit }
		if let refused = problems.first(where: \.isRefusedToken) { return refused }
		guard accounts > 0 else { return problems.first ?? .notFound(repo, accounts: 0) }
		// GitHub said so, or the owner is an organization, whose repos it
		// may not let Atelier read yet.
		let restricted = problems.contains {
			if case .notFound(_, _, .some) = $0 { return true }
			return false
		}
		var organization = restricted
		if !organization, let api { organization = await api.isOrganization(repo.owner) }
		return .notFound(repo, accounts: accounts, organization: organization ? repo.owner : nil)
	}
}

/// The user's GitHub accounts (#74), and which one reads each repo.
///
/// The list is in UserDefaults and each token in the Keychain. A repo keeps
/// the first account that could see it, so its refreshes and downloads ask
/// as that one; when that account is signed out, or can't see the repo any
/// more, the others are tried again. Public repos take any account, for its
/// higher limit.
public struct GitHubAccounts: GitHubCredentials, @unchecked Sendable {
	public typealias MakeAPI = @Sendable (_ token: @escaping @Sendable () -> String?) -> GitHubAPI

	private static let listKey = "github.accounts"
	private let defaults: UserDefaults
	private let tokens: any GitHubTokenStore
	private let makeAPI: MakeAPI

	public init(defaults: UserDefaults = .standard, tokens: any GitHubTokenStore, makeAPI: @escaping MakeAPI = { GitHubAPI(token: $0) }) {
		self.defaults = defaults
		self.tokens = tokens
		self.makeAPI = makeAPI
	}

	/// The accounts, in the order they were added.
	public var all: [GitHubAccount] {
		guard let data = defaults.data(forKey: Self.listKey) else { return [] }
		return (try? JSONDecoder().decode([GitHubAccount].self, from: data)) ?? []
	}

	private func store(_ accounts: [GitHubAccount]) {
		if accounts.isEmpty {
			defaults.removeObject(forKey: Self.listKey)
		} else if let data = try? JSONEncoder().encode(accounts) {
			defaults.set(data, forKey: Self.listKey)
		}
	}

	/// GitHub as `account`.
	public func api(for account: GitHubAccount) -> GitHubAPI {
		let tokens = tokens, id = account.id
		return makeAPI { tokens.token(for: id) }
	}

	/// Adds an account. One that's listed already, by the same login and
	/// kind, keeps its place and gets the new token instead: signing in to
	/// it again renews its sign-in.
	@discardableResult
	public func add(token: String, login: String?, kind: GitHubAccount.Kind, avatarURL: URL? = nil) throws -> GitHubAccount {
		var accounts = all
		let account: GitHubAccount
		if let login, let index = accounts.firstIndex(where: { $0.kind == kind && $0.login?.lowercased() == login.lowercased() }) {
			accounts[index].login = login
			accounts[index].avatarURL = avatarURL ?? accounts[index].avatarURL
			account = accounts[index]
		} else {
			account = GitHubAccount(login: login, kind: kind, avatarURL: avatarURL)
			accounts.append(account)
		}
		try tokens.save(token, for: account.id)
		store(accounts)
		return account
	}

	/// Keeps what's new about `account`, such as the login of a token
	/// pasted before Atelier asked GitHub whose it is.
	public func update(_ account: GitHubAccount) {
		var accounts = all
		guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
		accounts[index] = account
		store(accounts)
	}

	/// Signs out of `account`: its token goes, and its repos try the other
	/// accounts next time.
	public func remove(_ account: GitHubAccount) {
		tokens.delete(account.id)
		store(all.filter { $0.id != account.id })
	}

	/// Gives every account's token the protection a new one would be saved
	/// with now, as the certificates' follows automatic updates (#72).
	public func reprotect() throws {
		try tokens.reprotect(all.map(\.id))
	}

	// MARK: Repos

	private func key(_ repo: GitHubRepo) -> String { "github.account.\(repo)" }

	/// The account that reads `repo`, while it's signed in.
	public func account(for repo: GitHubRepo) -> GitHubAccount? {
		guard let id = defaults.string(forKey: key(repo)).flatMap(UUID.init(uuidString:)) else { return nil }
		return all.first { $0.id == id }
	}

	public func remember(_ account: GitHubAccount, for repo: GitHubRepo) {
		guard defaults.string(forKey: key(repo)) != account.id.uuidString else { return }
		defaults.set(account.id.uuidString, forKey: key(repo))
	}

	/// Forgets which account reads `repo`, as its source is removed.
	public func forget(_ repo: GitHubRepo) {
		defaults.removeObject(forKey: key(repo))
	}

	public func candidates(for repo: GitHubRepo) -> [GitHubCredential] {
		let accounts = all
		guard !accounts.isEmpty else { return [GitHubCredential(account: nil, api: makeAPI { nil })] }
		let current = account(for: repo)
		let ordered = (current.map { [$0] } ?? []) + accounts.filter { $0.id != current?.id }
		return ordered.map { GitHubCredential(account: $0, api: api(for: $0)) }
	}

	// MARK: #30's token

	/// One adoption at a time, so two can't list the same token twice.
	private static let adoption = NSLock()

	/// Lists the one token #30 kept as an account, and takes it out of its
	/// old place. `login` is who signed in, nil when it was pasted. Returns
	/// nil when there's no such token; throws while the Keychain can't be
	/// read, as while the device is locked, so it can be tried again.
	@discardableResult
	public func adoptLegacyToken(login: String?) throws -> GitHubAccount? {
		Self.adoption.lock()
		defer { Self.adoption.unlock() }
		guard let token = try tokens.legacyToken() else { return nil }
		let account = try add(token: token, login: login, kind: login == nil ? .token : .signedIn)
		tokens.deleteLegacyToken()
		return account
	}
}
