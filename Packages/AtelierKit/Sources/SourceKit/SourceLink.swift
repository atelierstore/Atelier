import Foundation

/// Turns what the user gives Atelier to add a source into the source's URL:
/// a pasted or typed URL, a scanned QR code, or an "Add to AltStore" style
/// link (#13).
public enum SourceLink {
	/// The link schemes Atelier opens: its own, and AltStore's, SideStore's
	/// and Feather's, so their "Add to …" buttons on the web work in
	/// Atelier too (#93). `StoreLink` reads the rest of what they open.
	public static let schemes = ["atelier", "altstore", "altstore-classic", "altstore-pal", "sidestore", "feather"]

	public enum Problem: Error, Equatable, CustomStringConvertible {
		case empty
		case notAURL
		/// `http://` and other schemes. Sources ship code, so Atelier only
		/// fetches them over HTTPS.
		case notHTTPS(scheme: String)
		/// An `atelier://`, `altstore://` or other store link that names no
		/// source.
		case noSourceInLink

		public var description: String {
			switch self {
			case .empty: "Enter a source URL."
			case .notAURL: "That isn't a source URL."
			case .notHTTPS: "Atelier only adds sources whose address starts with https://."
			case .noSourceInLink: "This link doesn't name a source."
			}
		}
	}

	/// Whether `url` is a store link (one of `schemes`) rather than a web
	/// address or a shared file. Such a link is read as a source to add,
	/// or as one of the links `StoreLink` reads.
	public static func isSourceLink(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased() else { return false }
		return schemes.contains(scheme)
	}

	/// The source URL that `input` names, normalized so the same source added
	/// twice compares equal.
	///
	/// Accepts `https://…`, a URL without a scheme (read as HTTPS), a source
	/// link such as `altstore://source?url=…` or Feather's
	/// `feather://source/https://…` on any of `schemes`, and a GitHub
	/// repository as `owner/repo` or its address (#30).
	public static func sourceURL(from input: String) throws -> URL {
		let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw Problem.empty }

		if let link = URL(string: text), isSourceLink(link) {
			return try sourceURL(fromLink: link)
		}
		if let repo = GitHubRepo(shorthand: text) { return repo.sourceURL }
		// "example.com/apps.json" has no scheme; read it as HTTPS.
		let withScheme = text.contains("://") ? text : "https://" + text
		guard var components = URLComponents(string: withScheme), let scheme = components.scheme else {
			throw Problem.notAURL
		}
		guard scheme.lowercased() == "https" else { throw Problem.notHTTPS(scheme: scheme) }
		guard let host = components.host, !host.isEmpty, !host.contains(" ") else { throw Problem.notAURL }

		components.scheme = "https"
		components.host = host.lowercased()
		if components.port == 443 { components.port = nil }
		components.fragment = nil
		if components.path.isEmpty { components.path = "/" }
		guard let url = components.url else { throw Problem.notAURL }
		if let repo = GitHubRepo(sourceURL: url) { return repo.sourceURL }
		return url
	}

	private static func sourceURL(fromLink link: URL) throws -> URL {
		guard
			let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
			components.host?.lowercased() == "source",
			let value = linkTarget(components, query: "url"),
			!value.isEmpty
		else { throw Problem.noSourceInLink }
		// A link wrapping another link isn't something any site sends.
		if let inner = URL(string: value), isSourceLink(inner) { throw Problem.noSourceInLink }
		return try sourceURL(from: value)
	}

	/// The address a store link points at: the rest of the link after the
	/// host, as Feather's `feather://source/https://…` has it, or else its
	/// `query` item, as AltStore's and SideStore's `…://source?url=…` have
	/// it (the name in any case, as they read it).
	static func linkTarget(_ components: URLComponents, query: String) -> String? {
		let path = components.percentEncodedPath
		guard path.count > 1 else {
			// URLComponents has already percent-decoded the value.
			return components.queryItems?.first { $0.name.lowercased() == query }?.value
		}
		// Everything after the host is the address, its own query included.
		var rest = String(path.dropFirst())
		if let query = components.percentEncodedQuery { rest += "?" + query }
		// Some sites encode the whole address after the host.
		if !rest.contains("://"), let decoded = rest.removingPercentEncoding, decoded.contains("://") {
			return decoded
		}
		return rest
	}
}
