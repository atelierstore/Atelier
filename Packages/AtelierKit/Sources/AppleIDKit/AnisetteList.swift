import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The anisette servers Atelier signs in to Apple through, for free Apple ID
/// signing (#49), and what it sends Apple in place of their client info.
///
/// Apple's sign-in wants anisette data, which vouches for the device signing
/// in, and Atelier gets it from public anisette v3 servers. Which ones Apple
/// takes changes with Apple's own changes (iloader needed four fixes between
/// 13 and 28 October 2026), so the list comes from Atelier's worker
/// (infra/manifest-worker, /anisette) before each sign-in, through
/// `AnisetteListSource`. `builtIn` is the copy for when it can't be reached,
/// kept the same as the worker's by its tests.
public struct AnisetteList: Equatable, Sendable {
	public struct Server: Equatable, Sendable {
		/// Its address, with no path, as isideload adds its own.
		public var url: URL
		public var name: String
		/// What it runs Apple's code on, as SideStore's list says: "mac",
		/// "windows" or "other". Nil when the list doesn't say.
		public var kind: String?
		/// Whether Atelier sends Apple the client info the server hands out
		/// rather than the list's: for a server that checks which ones Apple
		/// takes and picks one itself, as anisette.lillq.me does every hour.
		public var usesOwnClientInfo: Bool

		public init(url: URL, name: String, kind: String? = nil, usesOwnClientInfo: Bool = false) {
			self.url = url
			self.name = name
			self.kind = kind
			self.usesOwnClientInfo = usesOwnClientInfo
		}

		/// Its host, which also names the folder its state is kept in.
		public var host: String { url.host ?? url.absoluteString }

		/// The file isideload keeps the server's anisette state in, the
		/// machine Apple sees, under the sign-in's `storage`: as the
		/// bridge's `anisette_folder` names its folder (appleid.rs), its
		/// address without the scheme, anything but letters, digits, dots
		/// and hyphens made "_".
		public func stateFile(in storage: URL) -> URL {
			var address = url.absoluteString
			for scheme in ["https://", "http://"] where address.hasPrefix(scheme) {
				address.removeFirst(scheme.count)
			}
			let folder = String(address.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" })
			return storage
				.appendingPathComponent("anisette", isDirectory: true)
				.appendingPathComponent(folder, isDirectory: true)
				.appendingPathComponent("anisette_state")
		}
	}

	/// What Atelier sends Apple in place of a server's own client info, while
	/// the servers catch up with a change of Apple's: iloader 2.4.1 did, to
	/// fix SMS codes failing with 403 (28 Oct 2026), and since 20 Nov 2026
	/// Apple's sign-in answers HTTP 503 to one that names the system
	/// "macOS", as the servers' and the list's did then.
	public struct ClientInfo: Equatable, Sendable {
		public var clientInfo: String
		public var userAgent: String

		public init(clientInfo: String, userAgent: String) {
			self.clientInfo = clientInfo
			self.userAgent = userAgent
		}
	}

	/// When the list last changed, as "2026-11-02".
	public var updated: String
	/// The most servers one sign-in tries.
	public var tries: Int
	/// Nil to send what each server says. `clientInfo(for:)` says what one
	/// sign-in sends.
	public var clientInfo: ClientInfo?
	public var servers: [Server]

	public init(updated: String, tries: Int, clientInfo: ClientInfo?, servers: [Server]) {
		self.updated = updated
		self.tries = tries
		self.clientInfo = clientInfo
		self.servers = servers
	}
}

// MARK: Reading the worker's answer

extension AnisetteList {
	/// The format Atelier reads. A change it can't read goes to another
	/// address on the worker, so this one keeps answering older Ateliers.
	public static let version = 1
	/// The most servers one sign-in tries, whatever a list says.
	public static let mostTries = 8
	/// When a list doesn't say.
	public static let defaultTries = 4

	public enum Problem: Error, Equatable {
		/// Not JSON, or not a list.
		case unreadable
		/// A format this Atelier doesn't read.
		case version(Int)
		/// No server Atelier can use.
		case noServers
	}

	private struct Wire: Decodable {
		struct Server: Decodable {
			var url: String
			var name: String?
			var kind: String?
			var ownClientInfo: Bool?
		}

		struct ClientInfo: Decodable {
			var clientInfo: String
			var userAgent: String
		}

		/// As an anisette server hands it out, at /v3/client_info.
		struct ServersClientInfo: Decodable {
			var client_info: String
			var user_agent: String
		}

		var version: Int
		var updated: String?
		var tries: Int?
		var clientInfo: ClientInfo?
		var servers: [Server]
	}

	/// Reads a list as the worker serves it, keeping what Atelier can use:
	/// HTTPS servers, each host once; a client info that can go in a header;
	/// from 1 to 8 tries.
	public init(json: Data) throws {
		let wire: Wire
		do {
			wire = try JSONDecoder().decode(Wire.self, from: json)
		} catch {
			throw Problem.unreadable
		}
		guard wire.version == Self.version else { throw Problem.version(wire.version) }
		var hosts = Set<String>()
		let servers = wire.servers.compactMap { server -> Server? in
			guard let url = Self.serverURL(server.url), let host = url.host?.lowercased(), hosts.insert(host).inserted else {
				return nil
			}
			let name = server.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			return Server(url: url, name: name.isEmpty ? host : name, kind: server.kind, usesOwnClientInfo: server.ownClientInfo ?? false)
		}
		guard !servers.isEmpty else { throw Problem.noServers }
		self.init(
			updated: wire.updated ?? "",
			tries: min(max(wire.tries ?? Self.defaultTries, 1), Self.mostTries),
			clientInfo: wire.clientInfo.flatMap { info in
				Self.isHeaderValue(info.clientInfo) && Self.isHeaderValue(info.userAgent)
					? ClientInfo(clientInfo: info.clientInfo, userAgent: info.userAgent)
					: nil
			},
			servers: servers
		)
	}

	/// An https:// address with a host and nothing else: isideload adds its
	/// paths to it, and the bridge keeps each host's state apart.
	public static func serverURL(_ string: String) -> URL? {
		guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
		      components.scheme?.lowercased() == "https",
		      let host = components.host, !host.isEmpty,
		      components.user == nil, components.password == nil,
		      components.path.isEmpty || components.path == "/",
		      components.query == nil, components.fragment == nil
		else { return nil }
		var url = URLComponents()
		url.scheme = "https"
		url.host = host.lowercased()
		url.port = components.port
		return url.url
	}

	/// Printable ASCII, as an HTTP header's value has to be.
	static func isHeaderValue(_ value: String) -> Bool {
		!value.isEmpty && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
	}
}

// MARK: The client info

extension AnisetteList {
	public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	public enum ClientInfoProblem: LocalizedError, Equatable {
		/// The server didn't hand one out, or not one that can go in a header.
		case notHandedOut(String)

		public var errorDescription: String? {
			switch self {
			case .notHandedOut(let why): "The anisette server didn't hand out its client info: \(why)"
			}
		}
	}

	/// What a sign-in through `server` sends Apple: the list's client info,
	/// unless the server picks its own or the list has none, when it's the
	/// one the server hands out, asked for here so that the sign-in and the
	/// note beside the server's state (`AnisetteMachine`) are of the same.
	/// Throws when the server doesn't hand one out.
	public func clientInfo(
		for server: Server,
		fetch: Fetch = { try await URLSession.shared.data(for: $0) }
	) async throws -> ClientInfo {
		if let clientInfo, !server.usesOwnClientInfo { return clientInfo }
		return try await Self.handedOutClientInfo(at: server.url, fetch: fetch)
	}

	/// The client info the anisette server at `url` hands out, as isideload
	/// asks for it.
	public static func handedOutClientInfo(at url: URL, fetch: Fetch) async throws -> ClientInfo {
		var request = URLRequest(url: url.appendingPathComponent("v3").appendingPathComponent("client_info"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await fetch(request)
		} catch {
			throw ClientInfoProblem.notHandedOut(error.localizedDescription)
		}
		guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
			let status = (response as? HTTPURLResponse)?.statusCode
			throw ClientInfoProblem.notHandedOut(status.map { "HTTP \($0)" } ?? "no HTTP answer")
		}
		guard let wire = try? JSONDecoder().decode(Wire.ServersClientInfo.self, from: data) else {
			throw ClientInfoProblem.notHandedOut("an answer that can't be read")
		}
		let clientInfo = wire.client_info.trimmingCharacters(in: .whitespaces)
		let userAgent = wire.user_agent.trimmingCharacters(in: .whitespaces)
		guard isHeaderValue(clientInfo), isHeaderValue(userAgent) else {
			throw ClientInfoProblem.notHandedOut("one that can't go in a header")
		}
		return ClientInfo(clientInfo: clientInfo, userAgent: userAgent)
	}
}

// MARK: Signing in

extension AnisetteList {
	/// The servers one sign-in tries, in order: the one the last sign-in
	/// worked through first, as Apple may trust its device by then and not
	/// ask for a code (the spike, 2 Nov 2026), then the list's order; `tries`
	/// of them at most. One the list no longer has isn't tried.
	public func serversToTry(lastWorked: URL?) -> [Server] {
		var order = servers
		if let host = lastWorked?.host?.lowercased(), let index = order.firstIndex(where: { $0.url.host == host }) {
			order.insert(order.remove(at: index), at: 0)
		}
		return Array(order.prefix(tries))
	}

	/// The copy built into Atelier: the worker's list when this build was
	/// made (anisette.json).
	public static let builtIn: AnisetteList = {
		if let url = Bundle.module.url(forResource: "anisette", withExtension: "json"),
		   let data = try? Data(contentsOf: url),
		   let list = try? AnisetteList(json: data) {
			return list
		}
		// AnisetteListTests checks the copy reads; this only keeps a build
		// that lost it able to sign in, through iloader's default.
		return AnisetteList(
			updated: "",
			tries: 1,
			clientInfo: nil,
			servers: [Server(url: URL(string: "https://mac-ani.jkcoxson.com")!, name: "jkcoxson (Mac)", kind: "mac")]
		)
	}()
}
