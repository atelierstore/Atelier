import Foundation

// What an app asks for and what its signing lets it have, one list for the
// app's details in Browse and its Library page (#7, #8): its privacy
// permissions, which work with any signing, and its capabilities, which
// depend on the profile it's signed with.

extension EntitlementsReport {
	/// A feature an app's entitlements stand for, such as iCloud, with
	/// whether its signing supports it.
	public struct Capability: Equatable, Sendable {
		public enum Status: Equatable, Sendable {
			case supported
			/// The profile grants it, but not every value the app asks for.
			case partly
			/// The profile grants it, but it goes through the developer's
			/// Apple account.
			case probablyNot
			case unsupported
		}

		/// As the limits name it: "iCloud" for its several keys.
		public var name: String
		/// Nil when no profile was there to check it against.
		public var status: Status?
		/// Why, for anything but supported.
		public var detail: String?
		/// The entitlement keys behind it.
		public var keys: [String]
		/// What the app asks for that its signing has under other names, by
		/// the app's name: App Groups an Apple ID added under its own (#49).
		public var renamedValues: [String: String]

		public init(name: String, status: Status?, detail: String? = nil, keys: [String], renamedValues: [String: String] = [:]) {
			self.name = name
			self.status = status
			self.detail = detail
			self.keys = keys
			self.renamedValues = renamedValues
		}
	}

	/// One per feature, by name, with the least support any of its keys
	/// gets.
	public var capabilities: [Capability] {
		let byName = Dictionary(grouping: items) { Self.name(for: $0.key) }
		return byName.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
			let group = byName[name]!
			let keys = group.map(\.key)
			if let dropped = group.first(where: { $0.outcome == .dropped }) {
				let detail = dropped.key == "com.apple.security.application-groups" && dropped.bundles.count > 1
					? "Your certificate doesn't allow App Groups, so the app and its extensions can't share data."
					: "Your certificate doesn't allow it."
				return Capability(name: name, status: .unsupported, detail: detail, keys: keys)
			}
			let missing = group.flatMap(\.missingValues)
			if !missing.isEmpty {
				return Capability(name: name, status: .partly, detail: "Your certificate doesn't allow all of it.", keys: keys)
			}
			if group.contains(where: { $0.outcome == .teamBound }) {
				return Capability(name: name, status: .probablyNot, detail: "Your certificate allows it, but it only works in the developer's own copy of the app.", keys: keys)
			}
			let renamed = group.compactMap(\.renamedValues).reduce(into: [String: String]()) { $0.merge($1) { first, _ in first } }
			if !renamed.isEmpty {
				let shared = group.contains { $0.bundles.count > 1 } ? ", which the app and its extensions share" : ""
				let sent = group.contains { $0.redirected == true } ? " Atelier sends the app's own names to them." : ""
				return Capability(name: name, status: .supported, detail: "Your Apple ID added them under names of its own\(shared).\(sent)", keys: keys, renamedValues: renamed)
			}
			return Capability(name: name, status: .supported, keys: keys)
		}
	}

	/// What applies to the whole app rather than one capability.
	public var notes: [String] {
		extensionsUnderOneAppID.isEmpty ? [] : [Self.oneAppIDNote(extensions: extensionsUnderOneAppID.count)]
	}

	/// A profile for a single App ID signs the extensions with the app's,
	/// which they may not work with: said in the certificate's terms.
	static func oneAppIDNote(extensions count: Int) -> String {
		"Your certificate only covers the app itself, so its \(count == 1 ? "extension" : "extensions") may not work."
	}

	/// The capabilities a source lists for an app, when there's no profile
	/// to check them against.
	public static func unchecked(sourceKeys: [String]) -> [Capability] {
		let keys = Set(sourceKeys).subtracting(fromProfile)
		let byName = Dictionary(grouping: keys.sorted()) { name(for: $0) }
		return byName.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map {
			Capability(name: $0, status: nil, keys: byName[$0]!)
		}
	}
}

/// What an installed app asks for, as signed: kept with its install for its
/// Library page.
public struct SignedPermissions: Codable, Equatable, Sendable {
	/// Its privacy permissions (`NS…UsageDescription`) with its reasons.
	public var privacy: [String: String]
	/// Nil when the profile couldn't be read.
	public var entitlements: EntitlementsReport?

	public init(privacy: [String: String], entitlements: EntitlementsReport?) {
		self.privacy = privacy
		self.entitlements = entitlements
	}

	public func encoded() -> Data? {
		try? JSONEncoder().encode(self)
	}

	public static func decoded(from data: Data) -> SignedPermissions? {
		try? JSONDecoder().decode(SignedPermissions.self, from: data)
	}
}
