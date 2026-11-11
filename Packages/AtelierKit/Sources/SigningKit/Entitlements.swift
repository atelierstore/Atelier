import Foundation

/// What re-signing does to an app's entitlements (#7): which ones the
/// user's profile grants, which are signed in with the user's team ID in
/// place of the developer's, and which are lost, with a line for each thing
/// that won't work.
///
/// zsign signs the app and every extension in it with one set of
/// entitlements (`SigningOptions.entitlements`, or the profile's). That set
/// is the profile's, with one change: the app's own keychain groups, moved
/// to the user's team, in place of the profile's `TEAMID.*`, as Feather's
/// entitlement merging does. Everything else the profile grants is signed
/// in as it is, which is what installed in the spike. Because the app and
/// its extensions get the same set, they always share the same keychain and
/// app groups.
public struct EntitlementsReport: Codable, Equatable, Sendable {
	public enum Outcome: String, Codable, Sendable {
		/// The profile grants it.
		case kept
		/// The profile grants it once the developer's team ID in its values
		/// is replaced with the user's.
		case rewritten
		/// The profile grants it, but it works through the developer's own
		/// Apple account (their push service, iCloud containers, websites or
		/// Sign in with Apple), which doesn't know an app signed by another
		/// team.
		case teamBound
		/// The profile doesn't grant it, so it's left out.
		case dropped
	}

	public struct Item: Codable, Equatable, Sendable {
		public var key: String
		public var outcome: Outcome
		/// The bundles asking for it: "" for the app itself, then extensions
		/// by name, such as "Widget".
		public var bundles: [String]
		/// Values the profile doesn't grant, for an entitlement it grants
		/// only some of, such as one of two app groups.
		public var missingValues: [String]
		/// Values the profile grants under other names, by the name the app
		/// asks for: App Groups an Apple ID added under names of its own
		/// (#49), or the certificate's group that keeps them. Nil for none,
		/// as in reports kept before.
		public var renamedValues: [String: String]?
		/// With a certificate, the folder inside the group in
		/// `renamedValues` each of the app's App Groups is kept in, by the
		/// name the app asks for (#49, `AppGroups.folders`). Nil for none,
		/// as with an Apple ID and in reports kept before.
		public var folders: [String: String]?
		/// Whether the app loads Atelier's library that sends its own names
		/// for them to those (#49, `AppGroupRedirect`). Nil when it wasn't
		/// asked to, as in reports kept before.
		public var redirected: Bool?

		public init(key: String, outcome: Outcome, bundles: [String] = [""], missingValues: [String] = [], renamedValues: [String: String]? = nil, folders: [String: String]? = nil, redirected: Bool? = nil) {
			self.key = key
			self.outcome = outcome
			self.bundles = bundles
			self.missingValues = missingValues
			self.renamedValues = renamedValues
			self.folders = folders
			self.redirected = redirected
		}
	}

	/// One per entitlement the app or its extensions ask for, in key order,
	/// leaving out the ones every signature gets from the profile anyway
	/// (`EntitlementsReport.fromProfile`).
	public var items: [Item]
	public var profileTeamID: String
	/// The team the app was signed by before, when its binary says.
	public var appTeamID: String?
	/// Extensions and Watch apps signed with the app's App ID, because the
	/// profile names one App ID rather than a wildcard.
	public var extensionsUnderOneAppID: [String]
	/// Whether any of the app's binaries had entitlements to read. Decrypted
	/// IPAs often lose them, and then only the source can say (`predict`).
	public var readFromApp: Bool

	public init(items: [Item], profileTeamID: String, appTeamID: String?, extensionsUnderOneAppID: [String] = [], readFromApp: Bool = true) {
		self.items = items
		self.profileTeamID = profileTeamID
		self.appTeamID = appTeamID
		self.extensionsUnderOneAppID = extensionsUnderOneAppID
		self.readFromApp = readFromApp
	}

	/// Keys every signature takes from the profile, whatever the app asked
	/// for: they say who signed it and how, not what it can do.
	public static let fromProfile: Set<String> = [
		"application-identifier",
		"com.apple.developer.team-identifier",
		"get-task-allow",
		"beta-reports-active",
	]

	/// Keys that work through the developer's Apple account.
	static let teamBound: Set<String> = [
		"aps-environment",
		"com.apple.developer.applesignin",
		"com.apple.developer.associated-domains",
		"com.apple.developer.icloud-container-development-container-identifiers",
		"com.apple.developer.icloud-container-environment",
		"com.apple.developer.icloud-container-identifiers",
		"com.apple.developer.icloud-services",
		"com.apple.developer.in-app-payments",
		"com.apple.developer.pass-type-identifiers",
		"com.apple.developer.ubiquity-container-identifiers",
		"com.apple.developer.ubiquity-kvstore-identifier",
	]

	/// What won't work, one line per feature, the lost ones first.
	public var limits: [String] {
		var lines: [String] = []
		var named: Set<String> = []
		func add(_ item: Item, _ line: (String) -> String) {
			let name = Self.name(for: item.key)
			guard named.insert(name).inserted else { return }
			lines.append(line(name))
		}
		for item in items where item.outcome == .dropped {
			add(item) { name in
				if item.key == "com.apple.security.application-groups", item.bundles.count > 1 {
					return "The app and its extensions can't share data: your certificate doesn't allow App Groups."
				}
				return "\(name) won't work: your certificate doesn't allow it."
			}
		}
		for item in items where item.outcome != .dropped && !item.missingValues.isEmpty {
			add(item) { "\($0) may only partly work: your certificate doesn't allow all of it." }
		}
		for item in items where item.outcome == .teamBound {
			add(item) { "\($0) probably won't work: it only works in the developer's own copy of the app." }
		}
		if !extensionsUnderOneAppID.isEmpty {
			lines.append(Self.oneAppIDNote(extensions: extensionsUnderOneAppID.count))
		}
		return lines
	}

	/// What `limits` would say, from the entitlement keys a source lists
	/// for the app (AltStore's `appPermissions.entitlements`) and the keys
	/// the profile grants: for app details, before anything is downloaded.
	/// Values can't be checked, and the app's team isn't known, so features
	/// that go through the developer's account count as team-bound.
	public static func predict(sourceKeys: [String], profileKeys: Set<String>, profileTeamID: String) -> EntitlementsReport {
		let items = Set(sourceKeys).subtracting(fromProfile).sorted().map { key -> Item in
			if !profileKeys.contains(key) { return Item(key: key, outcome: .dropped) }
			return Item(key: key, outcome: teamBound.contains(key) ? .teamBound : .kept)
		}
		return EntitlementsReport(items: items, profileTeamID: profileTeamID, appTeamID: nil, readFromApp: false)
	}

	/// The feature an entitlement stands for, as the limits name it.
	public static func name(for key: String) -> String {
		names[key] ?? key
	}

	private static let names: [String: String] = [
		"aps-environment": "Push notifications",
		"com.apple.developer.applesignin": "Sign in with Apple",
		"com.apple.developer.associated-domains": "Universal links and password AutoFill",
		"com.apple.developer.carplay-audio": "CarPlay",
		"com.apple.developer.carplay-communication": "CarPlay",
		"com.apple.developer.carplay-maps": "CarPlay",
		"com.apple.developer.default-data-protection": "Data protection",
		"com.apple.developer.family-controls": "Screen Time",
		"com.apple.developer.game-center": "Game Center",
		"com.apple.developer.healthkit": "HealthKit",
		"com.apple.developer.healthkit.access": "HealthKit",
		"com.apple.developer.healthkit.background-delivery": "HealthKit background updates",
		"com.apple.developer.homekit": "HomeKit",
		"com.apple.developer.icloud-container-development-container-identifiers": "iCloud",
		"com.apple.developer.icloud-container-environment": "iCloud",
		"com.apple.developer.icloud-container-identifiers": "iCloud",
		"com.apple.developer.icloud-services": "iCloud",
		"com.apple.developer.in-app-payments": "Apple Pay",
		"com.apple.developer.kernel.extended-virtual-addressing": "Extended virtual addressing",
		"com.apple.developer.kernel.increased-memory-limit": "The increased memory limit",
		"com.apple.developer.networking.multicast": "Multicast networking",
		"com.apple.developer.networking.networkextension": "Network extensions (VPN, content filters)",
		"com.apple.developer.networking.vpn.api": "Personal VPN",
		"com.apple.developer.networking.wifi-info": "Wi-Fi network info",
		"com.apple.developer.nfc.readersession.formats": "NFC tag reading",
		"com.apple.developer.pass-type-identifiers": "Wallet passes",
		"com.apple.developer.siri": "Siri",
		"com.apple.developer.ubiquity-container-identifiers": "iCloud",
		"com.apple.developer.ubiquity-kvstore-identifier": "iCloud",
		"com.apple.developer.usernotifications.communication": "Communication notifications",
		"com.apple.developer.usernotifications.time-sensitive": "Time-sensitive notifications",
		"com.apple.developer.weatherkit": "WeatherKit",
		"com.apple.external-accessory.wireless-configuration": "Wireless accessory setup",
		"com.apple.security.application-groups": "App Groups",
		"inter-app-audio": "Inter-App Audio",
		"keychain-access-groups": "Keychain sharing",
	]
}

/// Works out the entitlements to sign with and the report (#7). Pure, so
/// the cases are tested without zsign.
enum EntitlementReconciler {
	/// The app or one bundle inside it, with what its binary asks for.
	struct Bundle {
		/// "" for the app itself, else the bundle's folder name without its
		/// extension, such as "Widget".
		var name: String
		var entitlements: [String: Any]
	}

	struct Result {
		/// What zsign signs every bundle with.
		var entitlements: [String: Any]
		var report: EntitlementsReport
	}

	/// `renamedGroups` are the names the profile has the app's App Groups
	/// under, by the name the app asks for (#49): those count as granted
	/// when the profile has the new name. `groupFolders` are the folders,
	/// inside those, a certificate keeps them in.
	static func reconcile(profile: [String: Any], teamID: String, isWildcard: Bool, bundles: [Bundle], readFromApp: Bool = true, renamedGroups: [String: String] = [:], groupFolders: [String: String] = [:]) -> Result {
		let main = bundles.first?.entitlements ?? [:]
		let appTeamID = (main["com.apple.developer.team-identifier"] as? String)
			?? (main["application-identifier"] as? String).flatMap(teamPrefix)
		let sameTeam = appTeamID == teamID

		var signed = profile
		var items: [EntitlementsReport.Item] = []
		let keys = Set(bundles.flatMap(\.entitlements.keys)).subtracting(EntitlementsReport.fromProfile).sorted()
		for key in keys {
			let asking = bundles.filter { $0.entitlements[key] != nil }
			let names = asking.map(\.name)
			guard let granted = profile[key] else {
				items.append(.init(key: key, outcome: .dropped, bundles: names))
				continue
			}
			// Every value asked for, the developer's team ID swapped for the
			// user's. Lists (groups, domains, containers) are merged across
			// bundles; anything else is taken from the first bundle asking.
			var values: [Any] = []
			var rewrote = false
			// The names the profile has values under, by the app's own: with a
			// certificate, several of the app's groups have the same one.
			var renamed: [String: String] = [:]
			for bundle in asking {
				let value = bundle.entitlements[key]!
				let elements = (value as? [Any]) ?? [value]
				for element in elements {
					var rebased = rebase(element, to: teamID)
					if key == AppGroups.entitlement, let own = element as? String, let name = renamedGroups[own], covers(granted, name, key: key) {
						renamed[own] = name
						rebased = name
					}
					if !same(rebased, element) { rewrote = true }
					if !values.contains(where: { same($0, rebased) }) { values.append(rebased) }
				}
				if !(value is [Any]) { break }
			}
			let covered = values.filter { covers(granted, $0, key: key) }
			let missing = values.filter { !covers(granted, $0, key: key) }.map { "\($0)" }
			if covered.isEmpty {
				items.append(.init(key: key, outcome: .dropped, bundles: names, missingValues: missing.count < values.count ? missing : []))
				continue
			}
			let folders = groupFolders.filter { renamed[$0.key] != nil }
			if key == "keychain-access-groups" {
				// The app's own groups in place of the profile's wildcard, so
				// its default keychain group (the first) is its own.
				signed[key] = covered
			}
			let outcome: EntitlementsReport.Outcome
			if EntitlementsReport.teamBound.contains(key), !sameTeam {
				outcome = .teamBound
			} else {
				outcome = rewrote ? .rewritten : .kept
			}
			items.append(.init(key: key, outcome: outcome, bundles: names, missingValues: missing, renamedValues: renamed.isEmpty ? nil : renamed, folders: folders.isEmpty ? nil : folders))
		}

		let nested = bundles.dropFirst().map(\.name)
		let report = EntitlementsReport(
			items: items,
			profileTeamID: teamID,
			appTeamID: appTeamID,
			extensionsUnderOneAppID: isWildcard ? [] : Array(nested),
			readFromApp: readFromApp
		)
		return Result(entitlements: signed, report: report)
	}

	/// `ABCDE12345` from `ABCDE12345.com.example`: ten capitals and digits,
	/// then a dot, the way Apple's team IDs prefix App IDs and groups.
	static func teamPrefix(_ value: String) -> String? {
		let parts = value.split(separator: ".", maxSplits: 1)
		guard parts.count == 2, parts[0].count == 10,
		      parts[0].allSatisfy({ ($0.isUppercase || $0.isNumber) && $0.isASCII })
		else { return nil }
		return String(parts[0])
	}

	/// Plist values compare by their text: entitlement values are strings,
	/// booleans and lists of strings.
	private static func same(_ a: Any, _ b: Any) -> Bool {
		String(describing: a) == String(describing: b)
	}

	/// A team-prefixed string moved to `teamID`; anything else as it is.
	private static func rebase(_ value: Any, to teamID: String) -> Any {
		guard let string = value as? String, let prefix = teamPrefix(string), prefix != teamID else { return value }
		return teamID + string.dropFirst(prefix.count)
	}

	/// Whether the profile's value for `key` allows `asked`, one value of
	/// what the app asks for. A profile string ending in `*` allows any
	/// string it starts; a list allows what any of its values allows.
	static func covers(_ granted: Any, _ asked: Any, key: String) -> Bool {
		// Development and production push differ only in the server the
		// app registers with; the profile decides which.
		if key == "aps-environment" { return true }
		switch (granted, asked) {
		case (let list as [Any], _):
			return list.contains { covers($0, asked, key: key) }
		case (let pattern as String, let value as String):
			if pattern.hasSuffix("*") { return value.hasPrefix(pattern.dropLast()) }
			return pattern == value
		case (let allowed as Bool, let value as Bool):
			return allowed || !value
		case (_ as Bool, _), (_, _ as Bool):
			return false
		default:
			// Dictionaries and numbers: the profile having the key is enough.
			return true
		}
	}
}
