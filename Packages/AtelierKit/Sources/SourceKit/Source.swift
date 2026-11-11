import Foundation

// Atelier's models of an AltStore Classic source, written from the public
// spec (https://faq.altstore.io/developers/make-a-source) rather than from
// AltStore's code. `SourceParser` builds them from the JSON.

/// A source: one JSON file listing apps, their versions and news.
public struct Source: Equatable, Sendable {
	public var name: String
	/// The source's own reverse-DNS identifier. Optional in the spec, but
	/// most sources still carry it from the v1 format.
	public var identifier: String?
	public var subtitle: String?
	public var description: String?
	public var iconURL: URL?
	public var headerURL: URL?
	public var website: URL?
	public var patreonURL: URL?
	public var fediUsername: String?
	/// Six hex digits, uppercased, without `#`.
	public var tintColor: String?
	public var isNSFW: Bool
	/// Bundle IDs in the order the source lists them, as written. Use
	/// `featuredApps` for the apps themselves.
	public var featuredAppIDs: [String]
	/// In the source's order. Listings with the same bundle ID and name are
	/// merged into one app (see `AppName`), so IDs are unique; bundle IDs
	/// may repeat.
	public var apps: [SourceApp]
	/// In the source's order; the spec says to show them newest first.
	public var news: [NewsItem]

	public init(
		name: String,
		identifier: String? = nil,
		subtitle: String? = nil,
		description: String? = nil,
		iconURL: URL? = nil,
		headerURL: URL? = nil,
		website: URL? = nil,
		patreonURL: URL? = nil,
		fediUsername: String? = nil,
		tintColor: String? = nil,
		isNSFW: Bool = false,
		featuredAppIDs: [String] = [],
		apps: [SourceApp] = [],
		news: [NewsItem] = []
	) {
		self.name = name
		self.identifier = identifier
		self.subtitle = subtitle
		self.description = description
		self.iconURL = iconURL
		self.headerURL = headerURL
		self.website = website
		self.patreonURL = patreonURL
		self.fediUsername = fediUsername
		self.tintColor = tintColor
		self.isNSFW = isNSFW
		self.featuredAppIDs = featuredAppIDs
		self.apps = apps
		self.news = news
	}

	/// The first app with this bundle ID.
	public func app(bundleID: String) -> SourceApp? {
		apps.first { $0.bundleID == bundleID }
	}

	/// The featured apps the source names that exist in it, without the
	/// first-five fallback.
	public var listedFeaturedApps: [SourceApp] {
		featuredAppIDs.compactMap(app(bundleID:))
	}

	/// The listed featured apps that exist in the source, or the first five
	/// apps when the source names none, as the spec says.
	public var featuredApps: [SourceApp] {
		let listed = featuredAppIDs.compactMap(app(bundleID:))
		return listed.isEmpty ? Array(apps.prefix(5)) : listed
	}

	/// The source's icon, or the first app's when it has none, as the spec says.
	public var effectiveIconURL: URL? { iconURL ?? apps.first?.iconURL }

	/// The source's tint, or the first app's when it has none, as the spec says.
	public var effectiveTintColor: String? { tintColor ?? apps.first?.tintColor }

	/// News newest first. Items without a date go last, in source order.
	public var newsNewestFirst: [NewsItem] {
		news.enumerated()
			.sorted { a, b in
				switch (a.element.date, b.element.date) {
				case let (x?, y?) where x != y: x > y
				case (_?, nil): true
				case (nil, _?): false
				default: a.offset < b.offset
				}
			}
			.map(\.element)
	}
}

extension SourceApp {
	/// A beta (#38): the source flags it with `beta`, as AltStore's own
	/// source does for its separate beta apps, or marks its latest version
	/// as one, as a GitHub repo's pre-release is.
	public var isBetaRelease: Bool {
		isBeta || (latestVersion?.isBeta ?? false)
	}
}

/// An app a source lists.
public struct SourceApp: Equatable, Sendable, Identifiable {
	/// The bundle ID and name: a source can list different apps (tweaked
	/// builds, say) under one bundle ID. See `AppName`.
	public var id: String { AppName.identity(bundleID: bundleID, name: name) }

	public var name: String
	public var bundleID: String
	/// Set for apps notarized for AltStore PAL. See `availability(on:)`.
	public var marketplaceID: String?
	public var developerName: String?
	public var subtitle: String?
	public var localizedDescription: String?
	public var iconURL: URL?
	/// Six hex digits, uppercased, without `#`.
	public var tintColor: String?
	public var category: AppCategory
	public var screenshots: Screenshots
	/// Newest first: the spec makes the source's order decide which version
	/// is the latest, whatever the dates or version numbers say.
	public var versions: [AppVersion]
	public var permissions: AppPermissions
	/// Set when only the developer's patrons may download the app.
	public var patreon: PatreonRequirement?
	/// The v1 `beta` flag, which some sources still set.
	public var isBeta: Bool

	public init(
		name: String,
		bundleID: String,
		marketplaceID: String? = nil,
		developerName: String? = nil,
		subtitle: String? = nil,
		localizedDescription: String? = nil,
		iconURL: URL? = nil,
		tintColor: String? = nil,
		category: AppCategory = .other,
		screenshots: Screenshots = Screenshots(),
		versions: [AppVersion],
		permissions: AppPermissions = AppPermissions(),
		patreon: PatreonRequirement? = nil,
		isBeta: Bool = false
	) {
		self.name = name
		self.bundleID = bundleID
		self.marketplaceID = marketplaceID
		self.developerName = developerName
		self.subtitle = subtitle
		self.localizedDescription = localizedDescription
		self.iconURL = iconURL
		self.tintColor = tintColor
		self.category = category
		self.screenshots = screenshots
		self.versions = versions
		self.permissions = permissions
		self.patreon = patreon
		self.isBeta = isBeta
	}

	/// The source's latest version, whether or not this device can run it.
	/// A source lists its betas only while the user includes them, and then
	/// with its releases, so the newest may be a beta (#104).
	public var latestVersion: AppVersion? { versions.first }

	/// The versions that support `os`, newest first.
	public func versions(supporting os: OSVersion) -> [AppVersion] {
		versions.filter { $0.supports(os) }
	}

	/// The newest version that supports `os`.
	public func latestVersion(supporting os: OSVersion) -> AppVersion? {
		versions.first { $0.supports(os) }
	}
}

/// The store categories the spec allows. Anything else reads as `.other`.
public enum AppCategory: String, CaseIterable, Sendable {
	case developer
	case entertainment
	case games
	case lifestyle
	case other
	case photoVideo = "photo-video"
	case social
	case utilities
}

/// One published version of an app.
public struct AppVersion: Equatable, Sendable {
	/// `CFBundleShortVersionString`.
	public var version: String
	/// `CFBundleVersion`, when the source gives it.
	public var buildVersion: String?
	/// What the store shows, when it differs from `version` and `buildVersion`.
	public var marketingVersion: String?
	public var date: Date?
	/// What's new.
	public var localizedDescription: String?
	public var downloadURL: URL
	/// Per-file URLs for an AltStore PAL package, keyed by file name.
	public var assetURLs: [String: URL]
	/// In bytes.
	public var size: Int64?
	/// Lowercase hex, when the source gives it. Not in the spec, but common.
	public var sha256: String?
	public var minOSVersion: OSVersion?
	/// Inclusive.
	public var maxOSVersion: OSVersion?
	/// Other builds of this version to choose from, such as a GitHub
	/// release with a debug build next to the usual one (#30). Empty, or
	/// two or more with this version's own download among them.
	public var builds: [AppBuild] = []
	/// The source lists it as a pre-release: a GitHub pre-release (#104),
	/// whose IPA usually has a plain version number. Not in the spec; see
	/// `isBeta`.
	public var isPrerelease = false
	/// The tag of the GitHub release it's from, without a leading v, such
	/// as 0.6.5-beta for an IPA that says 0.6.5 (#104). Not in the spec;
	/// see `releaseName`.
	public var tag: String?

	public init(
		version: String,
		buildVersion: String? = nil,
		marketingVersion: String? = nil,
		date: Date? = nil,
		localizedDescription: String? = nil,
		downloadURL: URL,
		assetURLs: [String: URL] = [:],
		size: Int64? = nil,
		sha256: String? = nil,
		minOSVersion: OSVersion? = nil,
		maxOSVersion: OSVersion? = nil
	) {
		self.version = version
		self.buildVersion = buildVersion
		self.marketingVersion = marketingVersion
		self.date = date
		self.localizedDescription = localizedDescription
		self.downloadURL = downloadURL
		self.assetURLs = assetURLs
		self.size = size
		self.sha256 = sha256
		self.minOSVersion = minOSVersion
		self.maxOSVersion = maxOSVersion
	}

	/// The version as the store shows it: `marketingVersion`, or else
	/// `version (build)` as the spec describes, or just `version`.
	public var displayVersion: String {
		if let marketingVersion { return marketingVersion }
		if let buildVersion, buildVersion != version { return "\(version) (\(buildVersion))" }
		return version
	}

	/// The version as Version History names it, a view of the source's
	/// releases (#104): a GitHub release's tag, else `displayVersion`. The
	/// app's page and the Library show the app as Atelier sees it, with
	/// `displayVersion`.
	public var releaseName: String { tag ?? displayVersion }

	/// A beta (#18, #104), as the source marks it: Atelier marks a GitHub
	/// repo's pre-releases, by GitHub's mark or their tags. An AltStore
	/// source only marks its beta apps (`SourceApp.isBeta`), so there a
	/// version's number, such as 2.0b3, never makes it one (29 Oct
	/// 2026).
	public var isBeta: Bool { isPrerelease }

	/// Whether this version supports `os`.
	///
	/// `maxOSVersion` only compares the parts the source wrote, so a maximum of
	/// "16.3" still includes 16.3.1. The spec calls the maximum inclusive and
	/// doesn't say more; this is the reading that doesn't hide a version from
	/// a device the developer most likely meant to include.
	public func supports(_ os: OSVersion) -> Bool {
		if let minOSVersion, os < minOSVersion { return false }
		if let maxOSVersion, os.truncated(to: maxOSVersion.components.count) > maxOSVersion { return false }
		return true
	}
}

/// An app's screenshots, split by device as the spec allows. A source that
/// doesn't split them lists them all under `iphone`.
public struct Screenshots: Equatable, Sendable {
	public var iphone: [Screenshot]
	public var ipad: [Screenshot]

	public init(iphone: [Screenshot] = [], ipad: [Screenshot] = []) {
		self.iphone = iphone
		self.ipad = ipad
	}

	public var isEmpty: Bool { iphone.isEmpty && ipad.isEmpty }
}

public struct Screenshot: Equatable, Sendable {
	public var imageURL: URL
	/// In pixels. When missing, the spec says to assume a 393 × 852 point
	/// portrait iPhone screenshot.
	public var width: Int?
	public var height: Int?

	public init(imageURL: URL, width: Int? = nil, height: Int? = nil) {
		self.imageURL = imageURL
		self.width = width
		self.height = height
	}
}

/// What the source says the app uses. AltStore checks these against the IPA;
/// Atelier shows them and uses them when reconciling entitlements (#7).
public struct AppPermissions: Equatable, Sendable {
	/// Entitlement keys, in the source's order.
	public var entitlements: [String]
	/// Info.plist `…UsageDescription` keys and their text.
	public var privacy: [String: String]

	public init(entitlements: [String] = [], privacy: [String: String] = [:]) {
		self.entitlements = entitlements
		self.privacy = privacy
	}
}

/// Who may download a Patreon-only app. Any one condition is enough.
public struct PatreonRequirement: Equatable, Sendable {
	public var pledge: Double?
	/// ISO currency code; USD when missing.
	public var currency: String?
	public var benefit: String?
	public var tiers: [String]

	public init(pledge: Double? = nil, currency: String? = nil, benefit: String? = nil, tiers: [String] = []) {
		self.pledge = pledge
		self.currency = currency
		self.benefit = benefit
		self.tiers = tiers
	}
}

public struct NewsItem: Equatable, Sendable, Identifiable {
	public var id: String { identifier }

	public var identifier: String
	public var title: String
	public var caption: String?
	public var date: Date?
	/// Six hex digits, uppercased, without `#`.
	public var tintColor: String?
	public var imageURL: URL?
	public var notify: Bool
	public var url: URL?
	/// The bundle ID of an app the item is about.
	public var appID: String?

	public init(
		identifier: String,
		title: String,
		caption: String? = nil,
		date: Date? = nil,
		tintColor: String? = nil,
		imageURL: URL? = nil,
		notify: Bool = false,
		url: URL? = nil,
		appID: String? = nil
	) {
		self.identifier = identifier
		self.title = title
		self.caption = caption
		self.date = date
		self.tintColor = tintColor
		self.imageURL = imageURL
		self.notify = notify
		self.url = url
		self.appID = appID
	}
}
