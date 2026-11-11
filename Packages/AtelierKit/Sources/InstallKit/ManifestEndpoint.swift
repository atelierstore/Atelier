import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where route B gets its install manifest: Atelier's own stateless endpoint
/// (`infra/manifest-worker`), or the user's own deployment of it.
///
/// iOS only accepts a manifest over HTTPS with a publicly trusted certificate,
/// so the loopback server can't serve it itself. The endpoint sees each app's
/// bundle ID, name and version, never the IPA or any certificate.
public enum ManifestEndpoint {
	/// Atelier's deployment, used when the user hasn't set their own.
	public static let defaultURL = URL(string: "https://api.atelierstore.app/manifest")!

	public enum Problem: Error, Equatable, CustomStringConvertible {
		case notAURL
		case notHTTPS
		case noHost

		public var description: String {
			switch self {
			case .notAURL: "That isn't a URL."
			case .notHTTPS: "The endpoint must use https://, or iOS refuses the manifest."
			case .noHost: "The URL has no host."
			}
		}
	}

	/// Where Atelier's install of itself leaves a background download that
	/// the endpoint answers `delay` seconds later, so that iOS relaunches
	/// Atelier once it has installed it (#24): `/relaunch` next to
	/// `/manifest`.
	public static func relaunchURL(for endpoint: URL, delay: Int) -> URL? {
		var components = URLComponents()
		components.scheme = endpoint.scheme
		components.host = endpoint.host
		components.port = endpoint.port
		let path = endpoint.path
		components.path = (path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "") + "/relaunch"
		components.queryItems = [URLQueryItem(name: "delay", value: String(delay))]
		return components.url
	}

	/// The endpoint for a value typed in Settings: empty means the default.
	public static func resolve(_ setting: String) -> Result<URL, Problem> {
		let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return .success(defaultURL) }
		guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return .failure(.notAURL) }
		guard scheme == "https" else { return .failure(.notHTTPS) }
		guard let host = url.host, !host.isEmpty else { return .failure(.noHost) }
		return .success(url)
	}

	/// Whether the endpoint answers, for onboarding and Setup health (#21).
	public enum Reachability: Equatable, Sendable {
		case reachable
		/// It answered, but not as the manifest worker does.
		case unexpected(status: Int)
		case unreachable(String)
	}

	/// Asks the endpoint with a HEAD and no app: the worker answers 400
	/// (no app given), which counts as reachable, as does any answer below
	/// 500 other than 404, since a user's own deployment may differ.
	public static func check(
		_ url: URL,
		fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
	) async -> Reachability {
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
		request.httpMethod = "HEAD"
		do {
			let (_, response) = try await fetch(request)
			guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unexpected(status: 0) }
			return reachability(status: status)
		} catch {
			return .unreachable(error.localizedDescription)
		}
	}

	static func reachability(status: Int) -> Reachability {
		status < 500 && status != 404 ? .reachable : .unexpected(status: status)
	}
}
