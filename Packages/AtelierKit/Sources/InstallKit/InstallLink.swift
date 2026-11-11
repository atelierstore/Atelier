import Foundation

/// Builds the manifest URL and the `itms-services://` link for route B.
///
/// The manifest comes from Atelier's own endpoint (`infra/manifest-worker`),
/// which replaces the third-party api.palera.in that Feather uses.
public enum InstallLink {
	public static func manifestURL(endpoint: URL, info: IPAInfo, packageURL: URL) -> URL {
		manifestURL(endpoint: endpoint, apps: [(info, packageURL)])
	}

	/// One manifest for several apps: the four parameters repeat once per app,
	/// in order. iOS then asks once for all of them.
	public static func manifestURL(endpoint: URL, apps: [(info: IPAInfo, packageURL: URL)]) -> URL {
		let query = apps.flatMap { app in
			[
				("bundleid", app.info.bundleID),
				("name", app.info.name),
				("version", app.info.version),
				("url", app.packageURL.absoluteString),
			]
		}
		.map { "\($0.0)=\(strictlyEncoded($0.1))" }
		.joined(separator: "&")

		var string = endpoint.absoluteString
		string += string.contains("?") ? "&" : "?"
		return URL(string: string + query)!
	}

	public static func itmsServicesURL(manifest: URL) -> URL {
		URL(string: "itms-services://?action=download-manifest&url=\(strictlyEncoded(manifest.absoluteString))")!
	}

	/// Percent-encodes everything except RFC 3986 unreserved characters, so
	/// `&`, `=`, `+`, `?` and `/` inside a value cannot be misread.
	public static func strictlyEncoded(_ value: String) -> String {
		var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
		allowed.insert(charactersIn: "-._~")
		return value.addingPercentEncoding(withAllowedCharacters: allowed)!
	}
}
