import Foundation

/// The anisette servers one sign-in goes through, one at a time and
/// silently, and when it stops (#49, the decisions of 23 Oct 2026):
///
/// - The list's servers in order, the one the last sign-in worked through
///   first, as Apple may trust its machine by then and not ask for a code;
///   `tries` of them at most. Or only the user's own server, which replaces
///   the list.
/// - The next server when one fails, or Apple's sign-in fails through it.
/// - Apple's "Try again" (-22421): the same server once more first. It came
///   once from the sign-in that follows the code, after Apple had taken it,
///   and the next server would have asked for a new code.
/// - Apple's "This action cannot be completed at this time" (-80045):
///   usually Apple refusing the Apple ID rather than the server, so two more
///   servers at most, of another kind than those it came from (a Mac's,
///   Windows' ADI or another).
/// - A wrong password, a locked Apple ID, a cancelled code or a refusal of
///   Apple's developer services: no other server changes that, so it stops.
public struct AnisetteRoute: Sendable {
	public enum Failure: Equatable, Sendable {
		/// The server didn't answer, or Apple's sign-in failed through it.
		case server
		/// Apple's "Try again" (-22421).
		case tryAgain
		/// Apple's "This action cannot be completed at this time" (-80045).
		case refused
		/// Nothing another server would change.
		case final
	}

	/// How many more servers a sign-in tries after Apple's first -80045.
	public static let moreAfterRefusal = 2

	/// The servers in the order they're tried.
	public let servers: [AnisetteList.Server]
	/// The most servers one sign-in tries.
	public let tries: Int
	/// Whether it's the user's own server rather than Atelier's list.
	public let isCustom: Bool
	/// The servers tried so far, each once, in order.
	public private(set) var tried: [AnisetteList.Server] = []
	/// How many times Apple answered -80045.
	public private(set) var refusals = 0
	/// The last failure, nil until one.
	public private(set) var lastFailure: Failure?

	private var position: Int?
	private var triedAgain = false
	private var refusedKinds: Set<String> = []

	/// Through Atelier's list, starting with the server the last sign-in
	/// worked through, if the list still has it.
	public init(list: AnisetteList, lastWorked: URL?) {
		var order = list.servers
		if let host = lastWorked?.host?.lowercased(), let index = order.firstIndex(where: { $0.host.lowercased() == host }) {
			order.insert(order.remove(at: index), at: 0)
		}
		servers = order
		tries = max(1, min(list.tries, order.count))
		isCustom = false
	}

	/// Only through the user's own server.
	public init(custom: URL) {
		servers = [AnisetteList.Server(url: custom, name: custom.host ?? custom.absoluteString)]
		tries = 1
		isCustom = true
	}

	/// The server being tried.
	public var current: AnisetteList.Server? {
		position.map { servers[$0] }
	}

	/// The first server to try.
	public mutating func start() -> AnisetteList.Server? {
		guard position == nil else { return current }
		return advance(from: -1)
	}

	/// The server to try after `failure` through the current one: the same
	/// one again, the next one, or nil to stop.
	public mutating func next(after failure: Failure) -> AnisetteList.Server? {
		guard let position else { return nil }
		lastFailure = failure
		switch failure {
		case .final:
			return nil
		case .tryAgain where !triedAgain:
			triedAgain = true
			return servers[position]
		case .tryAgain, .server:
			return advance(from: position)
		case .refused:
			refusals += 1
			guard refusals <= Self.moreAfterRefusal else { return nil }
			if let kind = servers[position].kind { refusedKinds.insert(kind) }
			return advance(from: position)
		}
	}

	/// The first server after `index` to try, skipping those of a kind
	/// Apple refused through, while fewer than `tries` were tried.
	private mutating func advance(from index: Int) -> AnisetteList.Server? {
		guard tried.count < tries else { return nil }
		var candidate = index + 1
		while candidate < servers.count {
			let server = servers[candidate]
			if let kind = server.kind, refusedKinds.contains(kind) {
				candidate += 1
				continue
			}
			position = candidate
			triedAgain = false
			tried.append(server)
			return server
		}
		return nil
	}

	/// What to tell the user when the sign-in stopped on `error`: nil when
	/// they cancelled it.
	public func explanation(of error: AppleIDError) -> String? {
		if error.kind == .cancelled { return nil }
		if error.isWrongPassword { return "Apple says the Apple ID or password is wrong." }
		if error.isLocked { return "Apple says this Apple ID is locked. Unlock it at iforgot.apple.com, then sign in again." }
		if error.kind == .noTeam {
			return "This Apple ID isn't in a developer team yet. Sign in to developer.apple.com with it once, then try again."
		}
		if error.kind == .developer { return "Apple's developer services refused it (\(error.appleCode)): \(error.message)" }
		// Anisette servers only mean something to people who run their own
		// (5 Nov 2026); the others hear of "servers it signs in through".
		if error.isTryLater {
			return "Apple isn't letting apps like Atelier sign in right now, which has happened on and off since October. Try again later."
		}
		if isCustom, let server = servers.first {
			let what = error.kind == .signIn ? "Apple refused the sign-in through your own sign-in server, \(server.host) (\(error.appleCode))." : "Your own sign-in server, \(server.host), didn't answer."
			return "\(what) Check that it's running, or turn it off in Settings › Installs › Advanced."
		}
		if error.kind == .signIn {
			return "Apple refused the sign-in (\(error.appleCode)): \(error.message)"
		}
		return tried.count > 1
			? "Atelier couldn't reach the servers it signs in through. Check your connection, then try again."
			: "Atelier couldn't reach the server it signs in through. Check your connection, then try again."
	}
}
