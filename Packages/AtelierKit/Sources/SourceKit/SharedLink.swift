import Foundation

/// A web link shared to Atelier from another app's share sheet (#56), as the
/// Atelier link its share extension opens for it:
///
/// - a link to an .ipa or .tipa installs it, as `atelier://install?url=…`
///   does, which asks first;
/// - one of the website's link pages (`https://atelierstore.app/install?url=…`
///   and the rest) does what the `atelier://` link it stands for does;
/// - anything else opens the Add Source sheet with it, as
///   `atelier://source?url=…` does, which reads sources and GitHub repos and
///   says when the link is neither.
///
/// Files shared to Atelier don't come this way: iOS hands those to the app
/// itself (`CFBundleDocumentTypes`, #93).
public enum SharedLink {
	/// The website whose link pages stand for Atelier's links.
	public static let website = "atelierstore.app"

	/// The website's link pages, each the `atelier://` link of its name.
	static let linkPages: Set<String> = ["install", "source", "viewapp", "search"]

	/// What an IPA's address ends with, as Choose IPA File picks them.
	static let ipaExtensions: Set<String> = ["ipa", "tipa"]

	/// The link for `shared`, on `scheme`: `atelier`, or a copy of Atelier's
	/// own (`atelier-<bundle ID>`, `SwitchBackScheme`), since every copy also
	/// answers `atelier://` and iOS picks which one opens it (`atelierLink`
	/// reads it back). Nil for what isn't a web address.
	public static func link(for shared: URL, scheme: String = "atelier") -> URL? {
		guard
			let sharedScheme = shared.scheme?.lowercased(), ["https", "http"].contains(sharedScheme),
			let components = URLComponents(url: shared, resolvingAgainstBaseURL: false),
			let host = components.host?.lowercased(), !host.isEmpty
		else { return nil }

		if host == website || host == "www." + website, let page = linkPage(components.path) {
			let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
			return URL(string: "\(scheme)://\(page)\(query)")
		}
		let page = ipaExtensions.contains(shared.pathExtension.lowercased()) ? "install" : "source"
		return URL(string: "\(scheme)://\(page)?url=\(encoded(shared.absoluteString))")
	}

	/// `link` as the `atelier://` link it is, when it came on a copy of
	/// Atelier's own scheme, `ownScheme`, which a copy's share extension opens
	/// it on; nil otherwise. A link without a host, such as `atelier-<bundle
	/// ID>://` alone, is LocalDevVPN switching back (#9), not one of these.
	public static func atelierLink(_ link: URL, ownScheme: String) -> URL? {
		guard
			let scheme = link.scheme?.lowercased(), scheme == ownScheme.lowercased(), scheme != "atelier",
			let host = link.host, !host.isEmpty
		else { return nil }
		return URL(string: "atelier" + link.absoluteString.dropFirst(scheme.count))
	}

	/// The link page at `path`, such as `/install` or `/install.html`.
	private static func linkPage(_ path: String) -> String? {
		var name = path.lowercased()
		while name.hasSuffix("/") { name.removeLast() }
		if name.hasSuffix(".html") { name.removeLast(5) }
		guard name.hasPrefix("/") else { return nil }
		name.removeFirst()
		return linkPages.contains(name) ? name : nil
	}

	/// Everything but RFC 3986's unreserved characters percent-encoded, so
	/// the link's own `&`, `=`, `?` and `#` stay in it.
	private static func encoded(_ value: String) -> String {
		var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
		allowed.insert(charactersIn: "-._~")
		return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
	}
}
