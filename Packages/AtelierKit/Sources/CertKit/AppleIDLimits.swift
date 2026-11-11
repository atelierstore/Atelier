import Foundation
import InstallKit

/// A free Apple ID's limits (#49), as Apple sets them, and how Atelier
/// tells the apps that hold them on a device.
public enum FreeAppleID {
	/// Apps signed with a free Apple ID on one device at a time, whichever
	/// Apple ID signed them: iOS refuses a fourth.
	public static let appsPerDevice = 3
	/// New App IDs a free Apple ID's team may add in 7 days. Each comes back
	/// 7 days after it was added.
	public static let appIDsPerWeek = 10

	/// Whether `profile` is a free Apple ID's: a development profile that
	/// lasts 7 days, where Apple gives a paid team's a year.
	public static func isFree(_ profile: ProvisioningProfile) -> Bool {
		guard profile.kind == .development, let created = profile.creationDate else { return false }
		return profile.expirationDate.timeIntervalSince(created) <= 8 * 86_400
	}

	/// The apps that hold the places on a device: those installd lists
	/// (`installed`) with a free profile for their own App ID among
	/// misagent's (`profiles`), in installd's order. iOS keeps a deleted
	/// app's profile, so a profile alone doesn't count.
	public static func apps(installed: [InstalledApp], profiles: [ProvisioningProfile]) -> [FreeApp] {
		var teams: [String: String] = [:]
		for profile in profiles where isFree(profile) && !profile.isWildcard {
			teams[profile.bundleIDPattern] = profile.teamID
		}
		return installed.compactMap { app in
			teams[app.bundleID].map { FreeApp(bundleID: app.bundleID, name: app.name, teamID: $0) }
		}
	}

	/// The same from the profiles' files, leaving out any that can't be
	/// read.
	public static func apps(installed: [InstalledApp], profileFiles: [Data]) -> [FreeApp] {
		apps(installed: installed, profiles: profileFiles.compactMap { try? ProvisioningProfile(data: $0) })
	}
}

/// An app on a device that runs with a free Apple ID's profile, so it holds
/// one of the 3 places (#49): one Atelier installed with an Apple ID, or
/// another tool's, such as SideStore with another Apple ID.
public struct FreeApp: Codable, Equatable, Sendable, Identifiable {
	/// As installd lists it.
	public var bundleID: String
	public var name: String
	/// The team of the profile it runs with.
	public var teamID: String

	public var id: String { bundleID }

	public init(bundleID: String, name: String, teamID: String) {
		self.bundleID = bundleID
		self.name = name
		self.teamID = teamID
	}
}

/// What an Apple ID allows, as Apple and this iPhone last said (#49), kept
/// with it (`StoredAppleID.limits`) so its page shows the counts without
/// signing in, which can mean Apple's code. Atelier asks at each install
/// with it, and with Check Now on its page.
public struct AppleIDLimits: Codable, Equatable, Sendable {
	/// The team's App IDs, as Apple last listed them.
	public struct AppIDs: Codable, Equatable, Sendable {
		public var checkedAt: Date
		/// 10 for a free Apple ID; nil when Apple doesn't say, as for a paid
		/// team.
		public var max: Int?
		/// How many more the team could add then.
		public var available: Int?
		/// When each of the team's App IDs expires, which gives its place
		/// back: a free Apple ID's last 7 days.
		public var expiries: [Date]
		/// The team's App IDs themselves, each with the app it's for, so the
		/// Apple ID's page lists the apps that install again without a new
		/// one (3 Nov 2026). Nil when kept before Atelier kept them.
		public var entries: [AppleIDAppIDList.Entry]?

		public init(checkedAt: Date, max: Int?, available: Int?, expiries: [Date], entries: [AppleIDAppIDList.Entry]? = nil) {
			self.checkedAt = checkedAt
			self.max = max
			self.available = available
			self.expiries = expiries
			self.entries = entries
		}

		/// How many more the team can add now: as many as Apple said, and
		/// one for each App ID that expired since. Nil when Apple doesn't
		/// count them.
		public func left(now: Date = .now) -> Int? {
			guard let available else { return nil }
			let back = expiries.filter { $0 > checkedAt && $0 <= now }.count
			return Swift.min(available + back, max ?? Int.max)
		}

		/// When the next place comes back: the soonest expiry still to come.
		public func nextReturn(now: Date = .now) -> Date? {
			expiries.filter { $0 > now }.min()
		}

		/// Whether Apple counts the team's App IDs, as for a free Apple ID.
		public var isLimited: Bool { max != nil && available != nil }

		/// The App IDs the team still has at `now`, the one that ends
		/// soonest first; nil when they weren't kept.
		public func current(now: Date = .now) -> [AppleIDAppIDList.Entry]? {
			entries.map { list in
				list
					.filter { $0.expires.map { $0 > now } ?? true }
					.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
			}
		}
	}

	/// The apps on this iPhone signed with a free Apple ID, as it last said.
	public struct Apps: Codable, Equatable, Sendable {
		public var checkedAt: Date
		public var apps: [FreeApp]

		public init(checkedAt: Date, apps: [FreeApp]) {
			self.checkedAt = checkedAt
			self.apps = apps
		}

		/// Whether another app can be signed with a free Apple ID now.
		public var hasRoom: Bool { apps.count < FreeAppleID.appsPerDevice }
	}

	public var appIDs: AppIDs?
	public var apps: Apps?

	public init(appIDs: AppIDs? = nil, apps: Apps? = nil) {
		self.appIDs = appIDs
		self.apps = apps
	}
}

/// The profile an app installed with an Apple ID got (#49): it lasts 7 days
/// for a free Apple ID, and the app stops opening once it ends, unless
/// Atelier renews it first (`AppProfileRenewal`).
public struct AppProfile: Codable, Equatable, Sendable {
	/// The bundle ID the app is installed as: its own and the team ID.
	public var bundleID: String
	public var uuid: String?
	public var expires: Date
	/// The serial of the certificate the app was signed with, which a new
	/// profile has to list for the app to keep opening without signing it
	/// again. Nil when noted before Atelier kept it.
	public var certificateSerial: String?
	/// When Atelier last put a new profile on without reinstalling; nil
	/// when the app still has the one it was installed with.
	public var renewedAt: Date?
	/// The soonest Atelier renews it by itself again, after Apple gave a
	/// profile that ended no later than the one it had: when its App ID
	/// ends, should Apple end its profiles with it.
	public var waitsUntil: Date?
	/// The App Groups the app was signed with, as the team names them,
	/// which each new profile has to allow for the app to keep opening:
	/// renewing gives them to its App ID again once Apple added it again.
	/// Nil for none, as for apps signed before Atelier added them (#49).
	public var appGroups: [String]?

	public init(bundleID: String, uuid: String?, expires: Date, certificateSerial: String? = nil, renewedAt: Date? = nil, waitsUntil: Date? = nil, appGroups: [String]? = nil) {
		self.bundleID = bundleID
		self.uuid = uuid
		self.expires = expires
		self.certificateSerial = certificateSerial
		self.renewedAt = renewedAt
		self.waitsUntil = waitsUntil
		self.appGroups = appGroups
	}
}

extension StoredAppleID {
	/// A free Apple ID's, which Apple limits.
	public var isFree: Bool { team.isFree == true }

	/// The bundle ID an app whose own is `appBundleID` installs as with this
	/// Apple ID: its own and the team ID, as an App ID is unique across all
	/// of Apple and the app's own may be taken, as AltStore, SideStore and
	/// iloader do. One that has it already keeps it.
	public func bundleID(for appBundleID: String) -> String {
		appBundleID.hasSuffix(".\(team.id)") ? appBundleID : "\(appBundleID).\(team.id)"
	}

	/// The app's own bundle ID for one of the team's App IDs that Atelier
	/// signs as (`bundleID(for:)`): the App ID without the team ID on the
	/// end, as AltStore and SideStore make them too. Nil for one made
	/// another way, such as Xcode's, which Atelier never signs as.
	public func appBundleID(forAppID identifier: String) -> String? {
		let suffix = ".\(team.id)"
		guard identifier.count > suffix.count, identifier.lowercased().hasSuffix(suffix.lowercased()) else { return nil }
		return String(identifier.dropLast(suffix.count))
	}

	/// The profile the app installed as `bundleID` last got.
	public func profile(for bundleID: String) -> AppProfile? {
		profiles?.first { $0.bundleID == bundleID }
	}

	/// Notes the profile an app just got, in place of the one before.
	public mutating func note(_ profile: AppProfile) {
		var list = (profiles ?? []).filter { $0.bundleID != profile.bundleID }
		list.append(profile)
		profiles = list
	}
}

/// The team's App IDs as Apple lists them (#49), with how many more it may
/// add.
public struct AppleIDAppIDList: Equatable, Sendable {
	/// One App ID, also kept with the Apple ID (`AppleIDLimits.AppIDs`).
	public struct Entry: Codable, Equatable, Sendable {
		/// The bundle ID it's for.
		public var identifier: String
		/// The name it was added under: the app's, when Atelier added it.
		public var name: String?
		/// A free Apple ID's last 7 days; nil for a paid team's.
		public var expires: Date?

		public init(identifier: String, name: String?, expires: Date?) {
			self.identifier = identifier
			self.name = name
			self.expires = expires
		}
	}

	public var appIDs: [Entry]
	/// 10 for a free Apple ID; nil when Apple doesn't say.
	public var max: Int?
	public var available: Int?

	public init(appIDs: [Entry], max: Int?, available: Int?) {
		self.appIDs = appIDs
		self.max = max
		self.available = available
	}

	/// The counts kept with the Apple ID, and the App IDs themselves.
	public func limits(checkedAt: Date) -> AppleIDLimits.AppIDs {
		AppleIDLimits.AppIDs(checkedAt: checkedAt, max: max, available: available, expiries: appIDs.compactMap(\.expires), entries: appIDs)
	}

	/// The team's App ID for `bundleID`, unless it expired by `now`. App IDs
	/// are told apart whatever their case.
	public func appID(for bundleID: String, now: Date = .now) -> Entry? {
		appIDs.first { entry in
			entry.identifier.caseInsensitiveCompare(bundleID) == .orderedSame && (entry.expires.map { $0 > now } ?? true)
		}
	}
}

/// Whether an app installing with an Apple ID fits in its limits (#49),
/// checked before Apple is asked for its profile: a refused install then
/// costs neither a place on the iPhone nor one of the week's App IDs.
public enum AppleIDRoom {
	/// A place among the 3 apps a free Apple ID's profiles run on.
	public enum Place: Equatable, Sendable {
		/// It holds one already: it's installed with a free profile, or the
		/// app it replaces is.
		case holds
		/// One is free.
		case free
		/// Every place is taken, by these apps.
		case full([FreeApp])
	}

	/// The app installs as `bundleID`, over `replacing` when that's
	/// another app it deletes first; `apps` hold the places now.
	public static func place(for bundleID: String, replacing: String? = nil, apps: [FreeApp]) -> Place {
		if apps.contains(where: { $0.bundleID == bundleID || $0.bundleID == replacing }) { return .holds }
		return apps.count < FreeAppleID.appsPerDevice ? .free : .full(apps)
	}

	/// The App ID it's signed for.
	public enum AppID: Equatable, Sendable {
		/// The team has it, until `expires`.
		case has(expires: Date?)
		/// Apple adds it with the profile, taking one of the `left` this
		/// week; nil when Apple doesn't count them, as for a paid team.
		case adds(left: Int?)
		/// None left this week: the next one comes back at `nextReturn`.
		case noneLeft(nextReturn: Date?)
	}

	public static func appID(for bundleID: String, in list: AppleIDAppIDList, now: Date = .now) -> AppID {
		if let entry = list.appID(for: bundleID, now: now) { return .has(expires: entry.expires) }
		guard list.max != nil, let available = list.available else { return .adds(left: nil) }
		if available > 0 { return .adds(left: available) }
		return .noneLeft(nextReturn: list.limits(checkedAt: now).nextReturn(now: now))
	}
}

extension AppleIDLimits.AppIDs {
	/// The counts once Apple added an App ID lasting until `expires`, with
	/// `available` left before it as Apple said then: `identifier`, under
	/// `name`, joins the App IDs when they're kept.
	public func adding(expires: Date?, available: Int?, max: Int?, identifier: String? = nil, name: String? = nil, at now: Date = .now) -> Self {
		var counts = Self(checkedAt: now, max: max ?? self.max, available: nil, expiries: expiries, entries: entries)
		if let left = available ?? self.left(now: now) { counts.available = Swift.max(left - 1, 0) }
		if let expires { counts.expiries.append(expires) }
		// Not a list of one when the rest weren't kept: the next check
		// lists them all.
		if let identifier, counts.entries != nil {
			counts.entries?.removeAll { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
			counts.entries?.append(AppleIDAppIDList.Entry(identifier: identifier, name: name, expires: expires))
		}
		return counts
	}
}

extension AppleIDLimits.Apps {
	/// The places once `app` was installed, over `replacing` when that was
	/// another app deleted first.
	public func installing(_ app: FreeApp, replacing: String? = nil, at now: Date = .now) -> Self {
		var apps = self.apps.filter { $0.bundleID != app.bundleID && $0.bundleID != replacing }
		apps.append(app)
		return Self(checkedAt: now, apps: apps)
	}
}
