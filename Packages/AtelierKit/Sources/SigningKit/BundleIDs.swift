import CertKit
import Foundation
import InstallKit

/// Which bundle ID an app is signed with (#8).
///
/// An app keeps its own bundle ID, whatever the profile's App ID: a profile
/// for a single App ID signs apps with other bundle IDs and they install
/// (docs/install-routes.md), and keeping the ID is what makes an update
/// install over the app and keep its data. Apart from that, the user can
/// install as many copies of an app as they like, next to the original
/// (such as the App Store version) and each other, each with its own data:
/// copy 2 is signed as `<bundle ID>.atelier2`, and so on, the same every
/// time, so updating a copy installs over it. A copy keeps the app's name
/// unless the user gives it another (`SigningOptions.displayName`).
public enum InstallTarget: Codable, Hashable, Sendable {
	/// The app as itself.
	case original
	/// A numbered copy, from 2: the original counts as the first.
	case copy(Int)

	static let copyPrefix = "atelier"

	/// The bundle ID to sign the app with. One more component, so the
	/// extensions' IDs stay children of the app's.
	public func bundleID(for original: String) -> String {
		switch self {
		case .original: original
		case .copy(let number): "\(original).\(Self.copyPrefix)\(number)"
		}
	}

	/// Which copy of `original` an installed bundle ID is, if it's one.
	public static func copyNumber(of bundleID: String, original: String) -> Int? {
		let prefix = "\(original).\(copyPrefix)"
		guard bundleID.hasPrefix(prefix), let number = Int(bundleID.dropFirst(prefix.count)), number >= 2,
		      bundleID == InstallTarget.copy(number).bundleID(for: original)
		else { return nil }
		return number
	}

	/// The copy after the highest one among `installed` bundle IDs: copies
	/// are numbered one after another, and a number isn't reused while its
	/// copy may still be installed.
	public static func newCopy(of original: String, installed: [String]) -> InstallTarget {
		let numbers = installed.compactMap { bundleID -> Int? in
			if let number = copyNumber(of: bundleID, original: original) { return number }
			// A copy signed with an Apple ID has the team ID before the
			// copy's suffix, "com.example.app.A1B2C3D4E5.atelier2" (#49).
			let parts = Self.split(bundleID)
			guard case .copy(let number) = parts.target, parts.original.hasPrefix("\(original)."),
			      !parts.original.dropFirst(original.count + 1).contains(".")
			else { return nil }
			return number
		}
		return .copy((numbers.max() ?? 1) + 1)
	}

	/// The app's own bundle ID and which copy of it `bundleID` is, told by
	/// a copy's suffix alone, for an app whose source lists it under
	/// another bundle ID than its own (#116). Without the suffix, it's the
	/// original.
	public static func split(_ bundleID: String) -> (original: String, target: InstallTarget) {
		guard let dot = bundleID.lastIndex(of: ".") else { return (bundleID, .original) }
		let original = String(bundleID[..<dot])
		guard let number = copyNumber(of: bundleID, original: original) else { return (bundleID, .original) }
		return (original, .copy(number))
	}
}

/// The bundle IDs an app was signed with, and the App ID it was signed for,
/// which together decide whether iOS installs it over an app it already has.
public struct SignedAppIdentity: Codable, Equatable, Sendable {
	/// What the app is installed as.
	public var bundleID: String
	/// The app's own bundle ID, before any change: the source's app.
	public var originalBundleID: String
	/// The `application-identifier` entitlement it was signed with, such as
	/// `TEAMID.com.example.app` or `TEAMID.*`. Nil when it can't be read.
	public var applicationIdentifier: String?
	/// The profile's team.
	public var teamID: String?

	public init(bundleID: String, originalBundleID: String, applicationIdentifier: String?, teamID: String?) {
		self.bundleID = bundleID
		self.originalBundleID = originalBundleID
		self.applicationIdentifier = applicationIdentifier
		self.teamID = teamID
	}

	/// What the app at `app`, an unpacked or installed `.app`, is signed as:
	/// its bundle ID, and the App ID and team its executable's entitlements
	/// say, else its embedded profile's. Atelier reads its own this way, as
	/// iOS only updates it with a build signed for the same App ID (#24).
	/// Nil when its Info.plist has no bundle ID.
	public static func read(app: URL, originalBundleID: String? = nil) -> SignedAppIdentity? {
		guard let bundleID = try? IPASigner.bundleID(in: app.appendingPathComponent("Info.plist")) else { return nil }
		var identity = SignedAppIdentity(bundleID: bundleID, originalBundleID: originalBundleID ?? bundleID, applicationIdentifier: nil, teamID: nil)
		if let executable = IPASigner.executable(of: app),
		   let data = try? MachO.entitlements(executable),
		   let entitlements = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
			identity.applicationIdentifier = entitlements["application-identifier"] as? String
			identity.teamID = entitlements["com.apple.developer.team-identifier"] as? String
		}
		if identity.applicationIdentifier == nil || identity.teamID == nil,
		   let data = try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")),
		   let profile = try? ProvisioningProfile(data: data) {
			identity.applicationIdentifier = identity.applicationIdentifier ?? profile.applicationIdentifier
			identity.teamID = identity.teamID ?? profile.teamID
		}
		return identity
	}

	/// Whether signing this app again for `applicationIdentifier`, a
	/// certificate's profile's App ID, means deleting it first: iOS can't
	/// replace an app with one signed for another App ID (TN2319, #76).
	/// False when the App ID it was signed for isn't known.
	public func needsReinstall(signingFor applicationIdentifier: String) -> Bool {
		guard let current = self.applicationIdentifier else { return false }
		return current != applicationIdentifier
	}

	/// What's wrong with installing an app signed as `self` over `installed`,
	/// the same bundle ID signed earlier, or nil when nothing is.
	///
	/// iOS refuses an update whose `application-identifier` differs from the
	/// installed app's ("rejecting upgrade", Apple's TN2319). With a profile
	/// for one App ID, every app is signed for that App ID, so it changes
	/// for every app when the profile does, even within the same team.
	public func upgradeProblem(over installed: SignedAppIdentity?) -> String? {
		guard
			let installed, installed.bundleID == bundleID,
			let old = installed.applicationIdentifier, let new = applicationIdentifier,
			old != new
		else { return nil }
		// The App IDs go in the install log, not here.
		let why = installed.teamID != nil && teamID != nil && installed.teamID != teamID
			? "it was installed with a certificate from another account"
			: "it was installed with a different certificate"
		return "If the app is still on this \(ThisDevice.name), this won't update it: \(why). Delete the app first; its data will be lost."
	}
}

/// Renames an unpacked app's bundle ID before it's signed, with its
/// extensions and Watch apps renamed to stay children of the new ID. Done by
/// Atelier rather than zsign, whose rename replaces the old ID anywhere in
/// a nested ID, not only as its start.
enum BundleIDRewriter {
	/// One bundle's change, for the log and tests.
	struct Change: Equatable {
		/// The bundle's path inside the app, "" for the app itself.
		var bundle: String
		var old: String
		var new: String
	}

	/// `id` moved from under `old` to under `new`: `old` itself or one of its
	/// children (`old.widget`), else nil.
	static func renamed(_ id: String, from old: String, to new: String) -> String? {
		if id == old { return new }
		guard id.hasPrefix(old + ".") else { return nil }
		return new + id.dropFirst(old.count)
	}

	/// Renames `app` from `old` to `new`, and every nested app and extension
	/// whose ID is `old` or a child of it, keeping each plist's format.
	/// Nested bundles with other IDs are left alone.
	@discardableResult
	static func rewrite(app: URL, from old: String, to new: String) throws -> [Change] {
		guard old != new else { return [] }
		var changes: [Change] = []
		let manager = FileManager.default
		let nested = ((try? manager.subpathsOfDirectory(atPath: app.path)) ?? [])
			.filter { ["app", "appex"].contains(($0 as NSString).pathExtension) }
			.sorted()
		for relative in [""] + nested {
			let plist = (relative.isEmpty ? app : app.appendingPathComponent(relative)).appendingPathComponent("Info.plist")
			guard manager.fileExists(atPath: plist.path) else { continue }
			var format = PropertyListSerialization.PropertyListFormat.xml
			guard var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
				throw SigningError.corruptArchive("\(relative.isEmpty ? "its" : relative + "'s") Info.plist can't be read")
			}
			var changed = false
			if let id = info["CFBundleIdentifier"] as? String, let moved = renamed(id, from: old, to: new) {
				info["CFBundleIdentifier"] = moved
				changes.append(Change(bundle: relative, old: id, new: moved))
				changed = true
			}
			// A Watch app names its iPhone app, and a WatchKit extension its
			// Watch app.
			if let id = info["WKCompanionAppBundleIdentifier"] as? String, let moved = renamed(id, from: old, to: new) {
				info["WKCompanionAppBundleIdentifier"] = moved
				changed = true
			}
			if var ext = info["NSExtension"] as? [String: Any],
			   var attributes = ext["NSExtensionAttributes"] as? [String: Any],
			   let id = attributes["WKAppBundleIdentifier"] as? String,
			   let moved = renamed(id, from: old, to: new) {
				attributes["WKAppBundleIdentifier"] = moved
				ext["NSExtensionAttributes"] = attributes
				info["NSExtension"] = ext
				changed = true
			}
			if changed {
				try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
			}
		}
		return changes
	}
}
