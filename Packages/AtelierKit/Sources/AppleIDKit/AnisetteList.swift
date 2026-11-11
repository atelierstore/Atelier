import Foundation

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

		public init(url: URL, name: String, kind: String? = nil) {
			self.url = url
			self.name = name
			self.kind = kind
		}

		/// Its host, which also names the folder its state is kept in.
		public var host: String { url.host ?? url.absoluteString }
	}

	/// What Atelier sends Apple in place of a server's own client info, while
	/// the servers catch up with a change of Apple's: iloader 2.4.1 did, to
	/// fix SMS codes failing with 403 (28 Oct 2026).
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
	/// Nil to send what each server says.
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
		}

		struct ClientInfo: Decodable {
			var clientInfo: String
			var userAgent: String
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
			return Server(url: url, name: name.isEmpty ? host : name, kind: server.kind)
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
	static func serverURL(_ string: String) -> URL? {
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
