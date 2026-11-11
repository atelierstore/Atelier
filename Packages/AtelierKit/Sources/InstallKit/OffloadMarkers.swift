import Foundation

// Marking an offloaded app's spot (9 Nov 2026): iOS shows its own
// offloaded apps greyed with a cloud, but only iOS can make one. A web clip
// can stand in for a free Apple ID's app, as it takes none of its 3
// places, but only a configuration profile makes web clips over Direct
// installs, and iOS asks you to approve each profile in Settings. So the
// markers are generic, a grey cloud named Offloaded, and one profile holds
// a few that any app can borrow: approved once, they last. Each opens its
// own link, `<Atelier's scheme>://marker/<number>`, so Atelier knows which
// was tapped, and which app's spot it holds.
//
// The profile goes to iOS's profile service, MCInstall, as Apple
// Configurator sends one (`com.apple.mobile.MCInstall.shim.remote`):
// HelloHostIdentifier, then InstallProfile with the profile as its
// `Payload`. On an iPhone that isn't supervised, iOS then asks you to
// install it in Settings › General › VPN & Device Management. RemoveProfile
// takes it, and its web clips, away again, by the profile's identifier,
// UUID and version, as GetProfileList gives them.

/// Atelier's markers for offloaded apps' spots on the Home Screen.
public enum OffloadMarkers {
	/// What the markers are called on the Home Screen.
	public static let label = "Offloaded"
	/// The link's host: `<scheme>://marker/<number>`.
	static let host = "marker"

	/// The profile's identifier, from Atelier's bundle ID, so a copy of
	/// Atelier has its own.
	public static func profileIdentifier(bundleID: String) -> String {
		"\(bundleID).offload-markers"
	}

	/// The link marker `number` opens.
	public static func link(_ number: Int, scheme: String) -> URL {
		URL(string: "\(scheme)://\(host)/\(number)")!
	}

	/// The marker a link is from, if it's one of `scheme`'s, or of any
	/// scheme when `scheme` is nil.
	public static func number(of url: URL, scheme: String? = nil) -> Int? {
		guard url.host() == host, scheme.map({ url.scheme?.lowercased() == $0.lowercased() }) ?? true else { return nil }
		return url.pathComponents.dropFirst().first.flatMap { Int($0) }
	}

	// MARK: Stand-ins

	// Any other app's spot gets a stand-in (9 Nov 2026): a small app
	// Atelier carries, signed as the app was, with its name and its icon
	// greyed, under a bundle ID of its own, so Atelier never takes it for
	// the app. Opening it opens `<scheme>://standin/<the app's bundle ID>`,
	// which its Info.plist says.

	/// The stand-in link's host.
	static let standInHost = "standin"
	/// The stand-in's Info.plist key for the link it opens.
	public static let standInLinkKey = "AtelierStandInLink"

	/// The bundle ID of the stand-in for the app `bundleID`.
	public static func standInBundleID(of bundleID: String) -> String {
		"\(bundleID).offloaded"
	}

	/// The link the stand-in for the app `bundleID` opens.
	public static func standInLink(_ bundleID: String, scheme: String) -> URL {
		URL(string: "\(scheme)://\(standInHost)/\(bundleID)")!
	}

	/// The app whose stand-in a link is from, if it's one of `scheme`'s.
	public static func standIn(of url: URL, scheme: String) -> String? {
		guard url.host() == standInHost, url.scheme?.lowercased() == scheme.lowercased() else { return nil }
		return url.pathComponents.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
	}

	/// The configuration profile with `count` markers, each a web clip with
	/// `icon`, a PNG, named `label`, that opens its link. They can be
	/// removed, as an app can, and open the link as Safari would, rather
	/// than full screen.
	public static func profile(count: Int, scheme: String, bundleID: String, icon: Data, label: String = label) throws -> Data {
		let identifier = profileIdentifier(bundleID: bundleID)
		let clips: [[String: Any]] = (1 ... max(count, 1)).map { number in
			[
				"PayloadType": "com.apple.webClip.managed",
				"PayloadVersion": 1,
				"PayloadIdentifier": "\(identifier).\(number)",
				"PayloadUUID": UUID().uuidString,
				"PayloadDisplayName": "Marker \(number)",
				"URL": link(number, scheme: scheme).absoluteString,
				"Label": label,
				"Icon": icon,
				"IsRemovable": true,
				"Precomposed": true,
				"FullScreen": false,
			]
		}
		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadVersion": 1,
			"PayloadIdentifier": identifier,
			"PayloadUUID": UUID().uuidString,
			"PayloadDisplayName": "Atelier Markers",
			"PayloadDescription": "Markers Atelier puts in offloaded apps’ spots on your Home Screen. Tapping one opens Atelier.",
			"PayloadOrganization": "Atelier",
			"PayloadRemovalDisallowed": false,
			"PayloadContent": clips,
		]
		return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
	}

	// MARK: Talking to iOS's profile service

	/// A request to iOS's profile service.
	public struct Request: @unchecked Sendable {
		public var values: [String: Any]

		/// Says who's asking, as Apple Configurator does first.
		public static let hello = Request(values: ["RequestType": "HelloHostIdentifier"])
		/// The installed profiles: `ProfileMetadata` by identifier, and
		/// `OrderedIdentifiers`.
		public static let list = Request(values: ["RequestType": "GetProfileList"])

		/// Hands iOS `profile` to install, which you then approve in
		/// Settings.
		public static func install(_ profile: Data) -> Request {
			Request(values: ["RequestType": "InstallProfile", "Payload": profile])
		}

		/// Removes the installed profile `identifier`, as GetProfileList
		/// describes it.
		public static func remove(identifier: String, uuid: String, version: Int) throws -> Request {
			let profile: [String: Any] = [
				"PayloadType": "Configuration",
				"PayloadIdentifier": identifier,
				"PayloadUUID": uuid,
				"PayloadVersion": version,
			]
			let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
			return Request(values: ["RequestType": "RemoveProfile", "ProfileIdentifier": data])
		}

		/// Its type, for the log.
		public var type: String {
			values["RequestType"] as? String ?? "?"
		}
	}

	/// What iOS's profile service said to a request.
	public struct Answer: @unchecked Sendable {
		public var values: [String: Any]

		public init(_ values: [String: Any]) {
			self.values = values
		}

		/// "Acknowledged" when it did as asked.
		public var status: String? {
			values["Status"] as? String
		}

		public var isAcknowledged: Bool {
			status == "Acknowledged"
		}

		/// Why it didn't: each `ErrorChain` entry's description, or the
		/// status.
		public var error: String? {
			guard !isAcknowledged else { return nil }
			let chain = (values["ErrorChain"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
				let text = entry["LocalizedDescription"] as? String ?? entry["USEnglishDescription"] as? String
				let code = (entry["ErrorCode"] as? NSNumber).map { " (\(entry["ErrorDomain"] as? String ?? "error") \($0))" } ?? ""
				return text.map { $0 + code }
			}
			if !chain.isEmpty { return chain.joined(separator: ": ") }
			return status.map { "iOS said \($0)" } ?? "iOS gave no status"
		}

		/// An installed profile, as GetProfileList describes it.
		public struct Profile: Equatable, Sendable {
			public var identifier: String
			public var uuid: String
			public var version: Int
			public var name: String?
		}

		/// The installed profiles, from GetProfileList's answer.
		public var profiles: [Profile] {
			let metadata = values["ProfileMetadata"] as? [String: Any] ?? [:]
			let order = values["OrderedIdentifiers"] as? [String] ?? metadata.keys.sorted()
			return order.compactMap { identifier in
				guard let meta = metadata[identifier] as? [String: Any] else { return nil }
				return Profile(
					identifier: identifier,
					uuid: meta["PayloadUUID"] as? String ?? "",
					version: (meta["PayloadVersion"] as? NSNumber)?.intValue ?? 1,
					name: meta["PayloadDisplayName"] as? String
				)
			}
		}
	}
}

/// A marker on the Home Screen, as getIconState gives it.
public struct OffloadMarker: Equatable, Sendable {
	/// Its number, from its link; or, when iOS doesn't give the link, from
	/// the order the markers come in.
	public var number: Int
	/// The web clip's identifier, which a layout places it by.
	public var id: String
	/// Where it is.
	public var spot: HomeScreenSpot?
	/// Its name, as iOS shows it.
	public var name: String?
	/// Whether its number came from its link.
	public var byLink: Bool
	/// The keys iOS gives for it, for the log.
	public var keys: [String]
}

extension HomeScreenLayout {
	/// Atelier's markers that `scheme` opens: web clips whose link is a
	/// marker's, or, when iOS gives no link, named `label` and not an app,
	/// numbered in the order they come after the ones with a link.
	public func markers(scheme: String, label: String = OffloadMarkers.label) -> [OffloadMarker] {
		var found: [OffloadMarker] = []
		var unnumbered: [(id: String, raw: PlistDictionary)] = []
		func look(_ items: [Item]) {
			for item in items {
				switch item {
				case .icon(let id, let raw):
					if let number = Self.markerNumber(raw, scheme: scheme) {
						found.append(OffloadMarker(number: number, id: id, spot: spot(of: id), name: raw.string("displayName"), byLink: true, keys: raw.values.keys.sorted()))
					} else if raw.string("displayName") == label, raw.string("bundleIdentifier") == nil {
						unnumbered.append((id, raw))
					}
				case .folder(_, let pages, _):
					pages.forEach(look)
				default:
					break
				}
			}
		}
		look(dock)
		pages.forEach(look)
		var next = (found.map(\.number).max() ?? 0) + 1
		for (id, raw) in unnumbered {
			found.append(OffloadMarker(number: next, id: id, spot: spot(of: id), name: raw.string("displayName"), byLink: false, keys: raw.values.keys.sorted()))
			next += 1
		}
		return found.sorted { $0.number < $1.number }
	}

	/// The marker number in any of a web clip's links that `scheme` opens.
	static func markerNumber(_ raw: PlistDictionary, scheme: String) -> Int? {
		for case let text as String in raw.values.values {
			if let url = URL(string: text), let number = OffloadMarkers.number(of: url, scheme: scheme) {
				return number
			}
		}
		return nil
	}

	/// The web clips it places that aren't apps, with the keys iOS gives
	/// for each, for the log.
	public var webClipKeys: [String: [String]] {
		var keys: [String: [String]] = [:]
		func look(_ items: [Item]) {
			for item in items {
				switch item {
				case .icon(let id, let raw) where raw.string("bundleIdentifier") == nil && raw.values.count > 2:
					keys[id] = raw.values.keys.sorted()
				case .folder(_, let pages, _):
					pages.forEach(look)
				default:
					break
				}
			}
		}
		look(dock)
		pages.forEach(look)
		return keys
	}

	/// What iOS gives for the app or web clip `id`, as it gives it.
	public func raw(of id: String) -> PlistDictionary? {
		guard case .icon(_, let raw)? = item(id) else { return nil }
		return raw
	}

	/// The layout with `ids` in a folder named `name` at the end of the last
	/// page, or of a new one when it's full, out of wherever they were, and
	/// without a folder of that name they leave empty.
	public func foldering(_ ids: [String], named name: String) -> HomeScreenLayout {
		var layout = self
		var items: [Item] = []
		for id in ids {
			items.append(item(id) ?? .icon(id: id, raw: PlistDictionary(["displayIdentifier": id])))
			layout = layout.removing(id)
		}
		layout.pages = layout.pages.compactMap { page in
			let left = page.filter { !($0.key == "folder:\(name)" && $0.ids.isEmpty) }
			return left.isEmpty && !page.isEmpty ? nil : left
		}
		guard !items.isEmpty else { return layout }
		let folder = Item.folder(name: name, pages: [items], raw: PlistDictionary(["displayName": name, "listType": "folder"]))
		if let last = layout.pages.indices.last, Self.places(layout.pages[last]) < Self.pagePlaces {
			layout.pages[last].append(folder)
		} else {
			layout.pages.append([folder])
		}
		return layout
	}
}
