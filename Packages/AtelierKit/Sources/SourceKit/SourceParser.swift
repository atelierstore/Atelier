import Foundation
#if canImport(os)
import os

private let logger = Logger(subsystem: "com.atelier", category: "SourceParser")
#endif

/// Reads an AltStore source's JSON into a `Source`.
///
/// Lenient by design: sources are hand-written and many are years old, so a
/// broken app or version is skipped with a warning instead of failing the
/// whole source. Only input that isn't a JSON object throws.
///
/// Accepts, besides the current spec:
/// - the legacy v1 app shape, with `version`, `versionDate`,
///   `versionDescription`, `downloadURL` and `size` on the app and no
///   `versions` array (used when `versions` is missing or has no usable entry);
/// - `screenshotURLs`, the v1 list of iPhone screenshot URLs;
/// - `appPermissions` written as objects, `entitlements: [{"name": …}]` and
///   `privacy: [{"name": …, "usageDescription": …}]`, as AltStore's own source
///   still does;
/// - trailing commas, which the spec's own examples have;
/// - numbers where strings belong (`"version": 1.5`) and strings where
///   numbers belong (`"size": "1234"`).
public enum SourceParser {
	public struct Result: Sendable {
		public var source: Source
		/// What was skipped or ignored, and why. Also logged.
		public var warnings: [Warning]
	}

	public struct Warning: Equatable, Sendable, CustomStringConvertible {
		/// Where in the JSON, such as `apps[2] (com.example.app).versions[0]`.
		public var path: String
		public var message: String

		public var description: String { "\(path): \(message)" }
	}

	public enum Error: Swift.Error, Equatable, CustomStringConvertible {
		case notJSON(String)
		case notAnObject

		public var description: String {
			switch self {
			case .notJSON(let why): "The source isn't valid JSON: \(why)"
			case .notAnObject: "The source isn't a JSON object."
			}
		}
	}

	public static func parse(_ data: Data) throws -> Result {
		let object = try jsonObject(from: data)
		guard let dictionary = object as? [String: Any] else { throw Error.notAnObject }
		var parser = Parser()
		let source = parser.source(dictionary)
		#if canImport(os)
		for warning in parser.warnings {
			logger.warning("Source \(source.name, privacy: .public): \(warning.description, privacy: .public)")
		}
		#endif
		return Result(source: source, warnings: parser.warnings)
	}

	static func jsonObject(from data: Data) throws -> Any {
		var data = data
		if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
		do {
			return try JSONSerialization.jsonObject(with: data)
		} catch {
			let relaxed = removingTrailingCommas(data)
			if relaxed != data, let object = try? JSONSerialization.jsonObject(with: relaxed) {
				return object
			}
			throw Error.notJSON(String(describing: (error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error.localizedDescription))
		}
	}

	/// Drops each comma that is followed only by whitespace and `]` or `}`,
	/// leaving commas inside strings alone.
	static func removingTrailingCommas(_ data: Data) -> Data {
		let bytes = [UInt8](data)
		var output: [UInt8] = []
		output.reserveCapacity(bytes.count)
		var inString = false
		var escaped = false
		var index = 0
		while index < bytes.count {
			let byte = bytes[index]
			defer { index += 1 }
			if inString {
				if escaped { escaped = false }
				else if byte == UInt8(ascii: "\\") { escaped = true }
				else if byte == UInt8(ascii: "\"") { inString = false }
				output.append(byte)
				continue
			}
			if byte == UInt8(ascii: "\"") { inString = true }
			if byte == UInt8(ascii: ",") {
				var next = index + 1
				while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
				if next < bytes.count, bytes[next] == UInt8(ascii: "]") || bytes[next] == UInt8(ascii: "}") { continue }
			}
			output.append(byte)
		}
		return Data(output)
	}
}

/// One pass over one source, collecting warnings as it goes.
private struct Parser {
	var warnings: [SourceParser.Warning] = []

	/// Versions from several listings of one app, newest first, without
	/// repeats. Equal versions keep the source's order.
	static func newestFirst(_ versions: [AppVersion]) -> [AppVersion] {
		var unique: [AppVersion] = []
		for version in versions where !unique.contains(where: {
			$0.version == version.version && $0.buildVersion == version.buildVersion && $0.downloadURL == version.downloadURL
		}) {
			unique.append(version)
		}
		return unique.enumerated()
			.sorted { a, b in
				switch a.element.compareRelease(to: b.element) {
				case .orderedDescending: true
				case .orderedAscending: false
				case .orderedSame: a.offset < b.offset
				}
			}
			.map(\.element)
	}

	mutating func warn(_ path: String, _ message: String) {
		warnings.append(.init(path: path, message: message))
	}

	// MARK: Source

	mutating func source(_ json: [String: Any]) -> Source {
		let identifier = string(json["identifier"])
		var name = string(json["name"])
		if name == nil {
			warn("name", "missing; using the identifier instead")
			name = identifier ?? "Untitled Source"
		}

		var apps: [SourceApp] = []
		var seen = Set<String>()
		if let array = json["apps"] as? [Any] {
			// Sources that list each version as its own app: one app per
			// bundle ID and name, with every listing's versions.
			var positions: [String: Int] = [:]
			var merged = Set<Int>()
			for (index, element) in array.enumerated() {
				guard var app = app(element, path: "apps[\(index)]") else { continue }
				app.name = AppName.clean(app.name)
				// Some sources write "Name-1.2.3 x Team" as the developer.
				app.developerName = app.developerName.map(AppName.clean)
				seen.insert(app.bundleID)
				if let position = positions[app.id] {
					apps[position].versions += app.versions
					merged.insert(position)
				} else {
					positions[app.id] = apps.count
					apps.append(app)
				}
			}
			for position in merged {
				apps[position].versions = Self.newestFirst(apps[position].versions)
			}
		} else {
			warn("apps", json["apps"] == nil ? "missing" : "not a list; ignored")
		}

		var featured: [String] = []
		for (index, element) in (json["featuredApps"] as? [Any] ?? []).enumerated() {
			guard let id = string(element) else {
				warn("featuredApps[\(index)]", "not a bundle ID; ignored")
				continue
			}
			if !seen.contains(id) { warn("featuredApps[\(index)]", "no app with bundle ID \(id)") }
			featured.append(id)
		}

		var news: [NewsItem] = []
		var seenNews = Set<String>()
		for (index, element) in (json["news"] as? [Any] ?? []).enumerated() {
			guard let item = newsItem(element, path: "news[\(index)]") else { continue }
			guard seenNews.insert(item.identifier).inserted else {
				warn("news[\(index)] (\(item.identifier))", "skipped: another news item has the same identifier")
				continue
			}
			news.append(item)
		}

		return Source(
			name: name!,
			identifier: identifier,
			subtitle: string(json["subtitle"]),
			description: string(json["description"]),
			iconURL: url(json["iconURL"]),
			headerURL: url(json["headerURL"]),
			website: url(json["website"]),
			patreonURL: url(json["patreonURL"]),
			fediUsername: string(json["fediUsername"]),
			tintColor: color(json["tintColor"]),
			isNSFW: bool(json["nsfw"]) ?? false,
			featuredAppIDs: featured,
			apps: apps,
			news: news
		)
	}

	// MARK: Apps

	mutating func app(_ element: Any, path basePath: String) -> SourceApp? {
		guard let json = element as? [String: Any] else {
			warn(basePath, "skipped: not an object")
			return nil
		}
		guard let bundleID = string(json["bundleIdentifier"]) else {
			warn(basePath, "skipped: no bundleIdentifier")
			return nil
		}
		let path = "\(basePath) (\(bundleID))"
		guard let name = string(json["name"]) else {
			warn(path, "skipped: no name")
			return nil
		}

		var versions: [AppVersion] = []
		if let array = json["versions"] as? [Any] {
			for (index, element) in array.enumerated() {
				if let version = version(element, path: "\(path).versions[\(index)]") {
					versions.append(version)
				}
			}
		}
		if versions.isEmpty, json["downloadURL"] != nil || json["version"] != nil {
			// Legacy v1: the one version lives on the app itself.
			if let version = version(legacyVersion(json), path: "\(path) (v1 version)") {
				versions.append(version)
			}
		}
		guard !versions.isEmpty else {
			warn(path, "skipped: no usable version")
			return nil
		}

		return SourceApp(
			name: name,
			bundleID: bundleID,
			marketplaceID: string(json["marketplaceID"]),
			developerName: string(json["developerName"]),
			subtitle: string(json["subtitle"]),
			localizedDescription: string(json["localizedDescription"]),
			iconURL: url(json["iconURL"]),
			tintColor: color(json["tintColor"]),
			category: string(json["category"]).flatMap { AppCategory(rawValue: $0.lowercased()) } ?? .other,
			screenshots: screenshots(json, path: path),
			versions: versions,
			permissions: permissions(json["appPermissions"], path: "\(path).appPermissions"),
			patreon: patreon(json["patreon"]),
			isBeta: bool(json["beta"]) ?? false
		)
	}

	/// The v1 app-level fields, renamed to their v2 version keys.
	func legacyVersion(_ app: [String: Any]) -> [String: Any] {
		var version: [String: Any] = [:]
		let keys = [
			("version", "version"), ("buildVersion", "buildVersion"), ("versionDate", "date"),
			("versionDescription", "localizedDescription"), ("downloadURL", "downloadURL"), ("size", "size"),
			("sha256", "sha256"), ("minOSVersion", "minOSVersion"), ("maxOSVersion", "maxOSVersion"),
		]
		for (from, to) in keys {
			if let value = app[from] { version[to] = value }
		}
		return version
	}

	mutating func version(_ element: Any, path: String) -> AppVersion? {
		guard let json = element as? [String: Any] else {
			warn(path, "skipped: not an object")
			return nil
		}
		guard let version = versionString(json["version"]) else {
			warn(path, "skipped: no version")
			return nil
		}
		guard let downloadURL = url(json["downloadURL"]), ["http", "https"].contains(downloadURL.scheme?.lowercased()) else {
			warn(path, "skipped: no http(s) downloadURL")
			return nil
		}

		var date: Date?
		if let raw = string(json["date"]) {
			date = SourceDate.parse(raw)
			if date == nil { warn(path, "date \"\(raw)\" isn't an ISO 8601 date; ignored") }
		}

		var assetURLs: [String: URL] = [:]
		for (key, value) in json["assetURLs"] as? [String: Any] ?? [:] {
			if let url = url(value) { assetURLs[key] = url }
		}

		var parsed = AppVersion(
			version: version,
			buildVersion: versionString(json["buildVersion"]),
			marketingVersion: versionString(json["marketingVersion"]),
			date: date,
			localizedDescription: string(json["localizedDescription"]),
			downloadURL: downloadURL,
			assetURLs: assetURLs,
			size: int(json["size"]),
			sha256: string(json["sha256"])?.lowercased(),
			minOSVersion: osVersion(json["minOSVersion"], key: "minOSVersion", path: path),
			maxOSVersion: osVersion(json["maxOSVersion"], key: "maxOSVersion", path: path)
		)
		for (index, element) in (json["atelierBuilds"] as? [Any] ?? []).enumerated() {
			guard let build = element as? [String: Any], let name = string(build["name"]),
				let url = url(build["downloadURL"]), ["http", "https"].contains(url.scheme?.lowercased())
			else {
				warn("\(path).atelierBuilds[\(index)]", "skipped: no name or http(s) downloadURL")
				continue
			}
			parsed.builds.append(AppBuild(
				name: name,
				downloadURL: url,
				size: int(build["size"]),
				minOSVersion: osVersion(build["minOSVersion"], key: "minOSVersion", path: path),
				isSpecial: bool(build["special"]) ?? false
			))
		}
		if parsed.builds.count < 2 { parsed.builds = [] }
		parsed.isPrerelease = bool(json["atelierPrerelease"]) ?? false
		parsed.tag = string(json["atelierTag"])
		return parsed
	}

	mutating func osVersion(_ value: Any?, key: String, path: String) -> OSVersion? {
		guard let raw = string(value) else { return nil }
		guard let version = OSVersion(raw) else {
			warn(path, "\(key) \"\(raw)\" isn't a version number; ignored")
			return nil
		}
		return version
	}

	// MARK: Screenshots

	mutating func screenshots(_ app: [String: Any], path: String) -> Screenshots {
		switch app["screenshots"] {
		case let list as [Any]:
			return Screenshots(iphone: screenshotList(list, path: "\(path).screenshots"))
		case let split as [String: Any]:
			return Screenshots(
				iphone: screenshotList(split["iphone"] as? [Any] ?? [], path: "\(path).screenshots.iphone"),
				ipad: screenshotList(split["ipad"] as? [Any] ?? [], path: "\(path).screenshots.ipad")
			)
		default:
			// v1: a plain list of iPhone screenshot URLs.
			return Screenshots(iphone: screenshotList(app["screenshotURLs"] as? [Any] ?? [], path: "\(path).screenshotURLs"))
		}
	}

	mutating func screenshotList(_ list: [Any], path: String) -> [Screenshot] {
		var screenshots: [Screenshot] = []
		for (index, element) in list.enumerated() {
			if let url = (element as? String).flatMap(url) {
				screenshots.append(Screenshot(imageURL: url))
			} else if let json = element as? [String: Any], let url = url(json["imageURL"]) {
				screenshots.append(Screenshot(imageURL: url, width: int(json["width"]).map(Int.init), height: int(json["height"]).map(Int.init)))
			} else {
				warn("\(path)[\(index)]", "not a screenshot URL; ignored")
			}
		}
		return screenshots
	}

	// MARK: Permissions, Patreon, news

	mutating func permissions(_ value: Any?, path: String) -> AppPermissions {
		guard let json = value as? [String: Any] else { return AppPermissions() }

		var entitlements: [String] = []
		switch json["entitlements"] {
		case let list as [Any]:
			for element in list {
				if let name = string(element) ?? string((element as? [String: Any])?["name"]) {
					entitlements.append(name)
				}
			}
		case nil:
			break
		default:
			warn("\(path).entitlements", "not a list; ignored")
		}

		var privacy: [String: String] = [:]
		switch json["privacy"] {
		case let dictionary as [String: Any]:
			for (key, value) in dictionary {
				if let text = string(value) { privacy[key] = text }
			}
		case let list as [Any]:
			for element in list {
				guard let item = element as? [String: Any], let name = string(item["name"]) else { continue }
				privacy[Self.usageDescriptionKey(name)] = string(item["usageDescription"]) ?? ""
			}
		case nil:
			break
		default:
			warn("\(path).privacy", "not a dictionary; ignored")
		}

		return AppPermissions(entitlements: entitlements, privacy: privacy)
	}

	/// The object form names privacy permissions by their middle part
	/// ("LocalNetwork"); the spec keys them by the full Info.plist key
	/// ("NSLocalNetworkUsageDescription"). The mapping is inferred from the
	/// names in AltStore's own source, not documented.
	static func usageDescriptionKey(_ name: String) -> String {
		if name.hasSuffix("UsageDescription") { return name }
		return "NS\(name)UsageDescription"
	}

	func patreon(_ value: Any?) -> PatreonRequirement? {
		guard let json = value as? [String: Any] else { return nil }
		return PatreonRequirement(
			pledge: double(json["pledge"]),
			currency: string(json["currency"]),
			benefit: string(json["benefit"]),
			tiers: (json["tiers"] as? [Any] ?? []).compactMap(string)
		)
	}

	mutating func newsItem(_ element: Any, path: String) -> NewsItem? {
		guard let json = element as? [String: Any] else {
			warn(path, "skipped: not an object")
			return nil
		}
		guard let identifier = string(json["identifier"]) else {
			warn(path, "skipped: no identifier")
			return nil
		}
		guard let title = string(json["title"]) else {
			warn("\(path) (\(identifier))", "skipped: no title")
			return nil
		}
		return NewsItem(
			identifier: identifier,
			title: title,
			caption: string(json["caption"]),
			date: string(json["date"]).flatMap(SourceDate.parse),
			tintColor: color(json["tintColor"]),
			imageURL: url(json["imageURL"]),
			notify: bool(json["notify"]) ?? false,
			url: url(json["url"]),
			appID: string(json["appID"])
		)
	}

	// MARK: Values

	/// A non-empty string, trimmed.
	func string(_ value: Any?) -> String? {
		guard let text = value as? String else { return nil }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	/// Like `string`, but numbers are written out too, so a version given as
	/// 1.5 reads as "1.5".
	func versionString(_ value: Any?) -> String? {
		switch value {
		case let int as Int: String(int)
		case let double as Double: String(double)
		default: string(value)
		}
	}

	func int(_ value: Any?) -> Int64? {
		switch value {
		case let int as Int: return Int64(int)
		case let double as Double where double.isFinite && double >= Double(Int64.min) && double <= Double(Int64.max): return Int64(double)
		case let string as String: return Int64(string.trimmingCharacters(in: .whitespaces))
		default: return nil
		}
	}

	func double(_ value: Any?) -> Double? {
		switch value {
		case let double as Double: return double
		case let int as Int: return Double(int)
		case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
		default: return nil
		}
	}

	func bool(_ value: Any?) -> Bool? {
		switch value {
		case let bool as Bool: return bool
		case let string as String: return ["true", "yes", "1"].contains(string.lowercased()) ? true : ["false", "no", "0"].contains(string.lowercased()) ? false : nil
		default: return nil
		}
	}

	/// An absolute URL. Spaces, which some sources leave in, are encoded.
	func url(_ value: Any?) -> URL? {
		guard let text = value as? String else { return nil }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let url = URL(string: trimmed) ?? URL(string: trimmed.replacingOccurrences(of: " ", with: "%20"))
		guard let url, url.scheme != nil else { return nil }
		return url
	}

	/// "#F54F32" or "c9b632" as "F54F32". Nil for anything else.
	func color(_ value: Any?) -> String? {
		guard var text = string(value) else { return nil }
		if text.hasPrefix("#") { text.removeFirst() }
		guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
		return text.uppercased()
	}
}
