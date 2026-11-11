import Foundation

/// The user's own anisette server, from Settings › Installs › Advanced
/// (#49): it replaces Atelier's list rather than going first, so a sign-in
/// goes only through it, and a failure names it. It can be one on the
/// user's Mac, which usually answers plain http:// on the local network;
/// it never sees the Apple ID's password either way.
public enum CustomAnisetteServer {
	/// Where Settings keeps it: empty for Atelier's list.
	public static let defaultsKey = "customAnisetteServer"

	public enum Problem: Error, Equatable, CustomStringConvertible {
		case notAURL
		case notHTTP
		case noHost
		case hasMore

		public var description: String {
			switch self {
			case .notAURL: "That isn't a URL."
			case .notHTTP: "The server's address starts with https:// or http://."
			case .noHost: "The URL has no host."
			case .hasMore: "Only the server's address, without a path: Atelier adds its own, as anisette v3 servers expect."
			}
		}
	}

	/// The server for a value typed in Settings, as "https://host:port":
	/// nil when it's empty, for Atelier's list.
	public static func resolve(_ setting: String) -> Result<URL?, Problem> {
		let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return .success(nil) }
		guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
			return .failure(.notAURL)
		}
		guard scheme == "https" || scheme == "http" else { return .failure(.notHTTP) }
		guard let host = components.host, !host.isEmpty else { return .failure(.noHost) }
		guard components.user == nil, components.password == nil,
		      components.path.isEmpty || components.path == "/",
		      components.query == nil, components.fragment == nil
		else { return .failure(.hasMore) }
		var url = URLComponents()
		url.scheme = scheme
		url.host = host.lowercased()
		url.port = components.port
		guard let resolved = url.url else { return .failure(.notAURL) }
		return .success(resolved)
	}

	/// The server Settings names, nil for Atelier's list, or what's wrong
	/// with the address typed there.
	public static func current(_ defaults: UserDefaults = .standard) -> Result<URL?, Problem> {
		resolve(defaults.string(forKey: defaultsKey) ?? "")
	}
}
