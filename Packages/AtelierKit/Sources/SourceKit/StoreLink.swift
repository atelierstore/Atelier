import Foundation

/// A link that opens Atelier from a web page or another app (#93): what
/// AltStore, SideStore and Feather open, on their schemes or on Atelier's
/// own (`SourceLink.schemes`). Read from their code on 26 Oct 2026:
/// AltStore's `SceneDelegate` (its `classic` and `marketplace` branches),
/// SideStore's `URLHandler` and Feather's `FeatherApp`.
public enum StoreLink: Equatable, Sendable {
	/// Adds a source, once the user has seen it. The link as it came, which
	/// `SourceLink.sourceURL(from:)` reads, so the add sheet can say what's
	/// wrong with it.
	case source(link: String)
	/// Downloads, signs and installs the IPA at an HTTPS address. `source`,
	/// as for `viewApp`, is the source the app comes from: added first, the
	/// IPA installs as it lists it, so the app's updates come from there.
	case install(URL, source: String?)
	/// Opens the page of the app with this bundle ID: AltStore's `viewapp`.
	/// `source` is Atelier's own addition, which AltStore's links don't have:
	/// the source the app comes from, as a source link's `url` names it.
	/// Atelier shows it to add first when the user doesn't have it, then the
	/// app from it, so one link works for someone without the source too.
	case viewApp(bundleID: String, source: String?)
	/// Searches Browse: AltStore's `search`.
	case search(String)
	/// Imports a certificate: Feather's `import-certificate`.
	case importCertificate(p12: Data, profile: Data, password: String)
	/// Gives a certificate (the .p12 and its password) to the app that asked
	/// for it: AltStore Classic's and SideStore's `certificate`, and Feather's
	/// `export-certificate`. LiveContainer asks this way.
	case exportCertificate(AppCallback)
	/// Gives the pairing file to the app that asked for it: SideStore's
	/// `pairing`.
	case exportPairingFile(AppCallback)
	/// A link for something Atelier doesn't do, such as AltStore's Patreon
	/// sign-in or a backup app's answer. `store` names the app it's for.
	case unsupported(store: String)

	public enum Problem: Error, Equatable, CustomStringConvertible {
		/// An install link without the IPA's address.
		case noApp
		/// An install link to an address Atelier can't download from.
		case notAWebAddress
		/// `http://` and other schemes: App Transport Security only lets
		/// Atelier download over HTTPS.
		case notHTTPS(scheme: String)
		/// An app link without a bundle ID.
		case noBundleID
		/// A search link without anything to search for.
		case noSearch
		/// A certificate link whose files or password can't be read.
		case unreadableCertificate
		/// A request for a certificate or the pairing file that doesn't say
		/// where to send it.
		case noCallback
		/// A request whose answer would go to a web page or another place
		/// that isn't an app.
		case callbackNotAnApp(scheme: String)

		public var description: String {
			switch self {
			case .noApp: "This link doesn't name an app to install."
			case .notAWebAddress: "This link's app isn't at a web address Atelier can download from."
			case .notHTTPS: "Atelier only downloads apps whose address starts with https://."
			case .noBundleID: "This link doesn't say which app to show."
			case .noSearch: "This link doesn't say what to search for."
			case .unreadableCertificate: "This link's certificate, profile or password can't be read."
			case .noCallback: "This link doesn't say which app to send it to."
			case .callbackNotAnApp(let scheme): "Atelier only sends these to apps, and this link would send it to \(scheme)."
			}
		}
	}

	/// The app a store link's scheme stands for.
	public static func store(of url: URL) -> String? {
		switch url.scheme?.lowercased() {
		case "altstore", "altstore-classic": "AltStore"
		case "altstore-pal": "AltStore PAL"
		case "sidestore": "SideStore"
		case "feather": "Feather"
		case "atelier": "Atelier"
		default: nil
		}
	}

	/// What `url` asks for, or nil when it isn't a store link (a web address,
	/// a shared file) or asks for nothing: `altstore://` alone just opens the
	/// app, and Atelier's own GitHub sign-in answer is read elsewhere.
	public init?(_ url: URL) throws {
		guard
			SourceLink.isSourceLink(url),
			let store = Self.store(of: url),
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let host = components.host?.lowercased(), !host.isEmpty
		else { return nil }
		let query = Self.queryItems(components)

		switch host {
		case "source":
			self = .source(link: url.absoluteString)

		case "install":
			guard let value = SourceLink.linkTarget(components, query: "url") else { throw Problem.noApp }
			// Not in Feather's form, where the rest of the link is the IPA's
			// address, its own query included.
			let source = components.percentEncodedPath.count > 1 ? nil : Self.source(in: query)
			self = .install(try Self.ipaURL(from: value), source: source)

		case "viewapp":
			guard let bundleID = query["bundleid"]?.trimmingCharacters(in: .whitespaces), !bundleID.isEmpty else {
				throw Problem.noBundleID
			}
			self = .viewApp(bundleID: bundleID, source: Self.source(in: query))

		case "search":
			// As AltStore reads it: `+` is a space, then the rest is decoded.
			let raw = components.percentEncodedQueryItems?.first { $0.name.lowercased() == "q" }?.value
			guard
				let text = raw.flatMap({ $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding })?
					.trimmingCharacters(in: .whitespaces),
				!text.isEmpty
			else { throw Problem.noSearch }
			self = .search(text)

		case "import-certificate":
			guard
				let p12 = query["p12"].flatMap(Self.base64), !p12.isEmpty,
				let profile = query["mobileprovision"].flatMap(Self.base64), !profile.isEmpty,
				// A .p12 can have an empty password, which is empty base64.
				let passwordData = Self.base64(query["password"] ?? ""),
				let password = String(data: passwordData, encoding: .utf8)
			else { throw Problem.unreadableCertificate }
			self = .importCertificate(p12: p12, profile: profile, password: password)

		case "certificate", "export-certificate":
			// AltStore, SideStore and Feather decode the template once more.
			guard let template = query["callback_template"].map({ $0.removingPercentEncoding ?? $0 }), !template.isEmpty else {
				throw Problem.noCallback
			}
			self = .exportCertificate(try AppCallback(template: template, needs: AppCallback.certificate))

		case "pairing":
			// SideStore answers at `<urlname>://pairingFile?data=…`.
			guard let name = query["urlname"].map({ $0.removingPercentEncoding ?? $0 }), !name.isEmpty else {
				throw Problem.noCallback
			}
			guard AppCallback.isAppScheme(name) else { throw Problem.callbackNotAnApp(scheme: name) }
			self = .exportPairingFile(try AppCallback(template: "\(name)://pairingFile?data=\(AppCallback.pairingFile)", needs: AppCallback.pairingFile))

		case "github-sign-in" where store == "Atelier":
			return nil

		default:
			self = .unsupported(store: store)
		}
	}

	/// The source an app or install link names, `source`, as it came: read
	/// once it's needed, by the add sheet, which says what's wrong with it.
	private static func source(in query: [String: String]) -> String? {
		let source = query["source"]?.trimmingCharacters(in: .whitespacesAndNewlines)
		return source?.isEmpty == false ? source : nil
	}

	/// The query's items by name, in lower case as AltStore and SideStore
	/// read them, already percent-decoded.
	private static func queryItems(_ components: URLComponents) -> [String: String] {
		var items: [String: String] = [:]
		for item in components.queryItems ?? [] {
			if let value = item.value { items[item.name.lowercased()] = value }
		}
		return items
	}

	/// The IPA's address in an install link. Without a scheme it's read as
	/// HTTPS, as Library › Download from URL reads it.
	static func ipaURL(from value: String) throws -> URL {
		var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw Problem.noApp }
		// URL(string:) would encode the spaces rather than refuse them.
		guard !text.contains(where: \.isWhitespace) else { throw Problem.notAWebAddress }
		if !text.contains("://") { text = "https://" + text }
		guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { throw Problem.notAWebAddress }
		guard scheme == "https" else {
			if scheme == "http" { throw Problem.notHTTPS(scheme: scheme) }
			throw Problem.notAWebAddress
		}
		guard let host = url.host, !host.isEmpty else { throw Problem.notAWebAddress }
		return url
	}

	/// Base64 as these links carry it: standard or URL-safe, with or without
	/// padding, and with a `+` that a form encoder turned into a space.
	static func base64(_ text: String) -> Data? {
		var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: " ", with: "+")
			.replacingOccurrences(of: "-", with: "+")
			.replacingOccurrences(of: "_", with: "/")
		if text.count % 4 != 0 { text += String(repeating: "=", count: 4 - text.count % 4) }
		return Data(base64Encoded: text)
	}
}

/// Where a certificate or the pairing file goes when another app asks for
/// it: a link back to that app, with placeholders Atelier fills in, such as
/// LiveContainer's
/// `livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)`.
public struct AppCallback: Equatable, Sendable {
	/// The .p12, as base64.
	public static let certificate = "$(BASE64_CERT)"
	/// The .p12's password.
	public static let password = "$(PASSWORD)"
	/// The pairing file, as base64.
	public static let pairingFile = "$(BASE64_PAIRING)"

	public let template: String
	/// The scheme the link opens, which stands for the app: `livecontainer`.
	public let scheme: String

	/// Schemes that would send what's filled in to a web page, a message or
	/// back to a store, rather than to the app that asked: browsers' and
	/// the system's. Atelier's own and the stores' are left out too, as an
	/// answer there would only come back as another request.
	static let notApps: Set<String> = [
		"http", "https", "file", "ftp", "data", "javascript", "about", "blob",
		"x-safari-http", "x-safari-https", "googlechrome", "googlechromes", "firefox", "firefox-focus",
		"microsoft-edge-http", "microsoft-edge-https", "opera-http", "opera-https", "brave", "ddgquicklink",
		"x-web-search", "mailto", "sms", "tel", "facetime", "facetime-audio", "itms", "itms-apps",
		"itms-services", "shortcuts", "workflow",
	]

	/// Whether `scheme` is a plain scheme name for an app to answer on.
	public static func isAppScheme(_ scheme: String) -> Bool {
		let name = scheme.lowercased()
		guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
		guard name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
		return !notApps.contains(name) && !SourceLink.schemes.contains(name)
	}

	/// A callback to an app, which must hold `needs`.
	init(template: String, needs placeholder: String) throws {
		guard template.contains(placeholder), let colon = template.firstIndex(of: ":") else {
			throw StoreLink.Problem.noCallback
		}
		let scheme = String(template[..<colon])
		guard Self.isAppScheme(scheme) else { throw StoreLink.Problem.callbackNotAnApp(scheme: scheme.lowercased()) }
		self.template = template
		self.scheme = scheme.lowercased()
	}

	/// The link to open, with the .p12 and its password filled in.
	public func url(certificate p12: Data, password: String) -> URL? {
		url(filling: [Self.certificate: p12.base64EncodedString(), Self.password: password])
	}

	/// The link to open, with the pairing file filled in.
	public func url(pairingFile: Data) -> URL? {
		url(filling: [Self.pairingFile: pairingFile.base64EncodedString()])
	}

	/// Each placeholder replaced by its value, percent-encoded so the app
	/// reads it back exactly. AltStore, SideStore and Feather encode the
	/// .p12 the same way; they put the password in as it is, which breaks
	/// the link for a password with `&` or `#` in it.
	private func url(filling values: [String: String]) -> URL? {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: ";/?:@&=+$, ")
		var link = template
		for (placeholder, value) in values {
			guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
			link = link.replacingOccurrences(of: placeholder, with: encoded)
		}
		guard let url = URL(string: link), url.scheme?.lowercased() == scheme else { return nil }
		return url
	}
}
