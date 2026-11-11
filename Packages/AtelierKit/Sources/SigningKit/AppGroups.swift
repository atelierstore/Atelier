import Foundation
import ZIPFoundation

/// App Groups for apps signed with an Apple ID or a certificate (#49).
/// Apple keeps a group's name unique across every team, as it does an App
/// ID's, so the app's own groups are the developer's: an Apple ID adds them
/// under names of its own, the group with the team ID on the end, as
/// AltStore and SideStore name them, and the app's App ID gets them, so its
/// profile allows them. A certificate's profile has the groups it has, so
/// the app's are kept in folders of their own in one of those.
public enum AppGroups {
	/// The entitlement that lists an app's groups.
	public static let entitlement = "com.apple.security.application-groups"

	/// The groups the app and its extensions ask for, from the entitlements
	/// their executables were signed with, the app's first, each once.
	/// Read from the IPA before it's signed, as the profile has to allow
	/// them first. None when the binaries have no entitlements, as a
	/// decrypted IPA's often don't.
	public static func read(ipaAt url: URL) throws -> [String] {
		let archive: Archive
		do {
			archive = try Archive(url: url, accessMode: .read)
		} catch {
			throw SigningError.corruptArchive("it isn't a ZIP archive")
		}
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppGroups-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		var groups: [String] = []
		for (index, bundle) in bundles(in: archive.map(\.path)).enumerated() {
			guard let plistEntry = archive[bundle + "/Info.plist"] else { continue }
			var plistData = Data()
			_ = try archive.extract(plistEntry, skipCRC32: true) { plistData.append($0) }
			let info = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
			let name = info?["CFBundleExecutable"] as? String
				?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
			guard let executable = archive[bundle + "/" + name], executable.type == .file else { continue }
			let file = folder.appendingPathComponent("\(index)")
			_ = try archive.extract(executable, to: file, skipCRC32: true)
			defer { try? FileManager.default.removeItem(at: file) }
			guard let data = try? MachO.entitlements(file),
			      let entitlements = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
			else { continue }
			for group in entitlements[entitlement] as? [String] ?? [] where !groups.contains(group) {
				groups.append(group)
			}
		}
		return groups
	}

	/// The app's folder in the IPA, then every app and extension in it, as
	/// `IPASigner.entitlementBundles` finds them once unpacked: folders
	/// ending in .app or .appex that have an Info.plist.
	static func bundles(in paths: [String]) -> [String] {
		let folders = paths.compactMap { path -> String? in
			guard IPASigner.isPayload(path), path.hasSuffix("/Info.plist") else { return nil }
			let folder = String(path.dropLast("/Info.plist".count))
			return ["app", "appex"].contains((folder as NSString).pathExtension) ? folder : nil
		}
		// The app itself: the one right under Payload.
		guard let app = folders.filter({ $0.split(separator: "/").count == 2 && $0.hasSuffix(".app") }).sorted().first else { return [] }
		let nested = folders.filter { $0.hasPrefix(app + "/") }.sorted()
		return [app] + nested
	}

	/// The name the Apple ID's team gives each of `groups`, for an app whose
	/// own bundle ID is `appBundleID`, signed as `signedBundleID` with the
	/// team `teamID`. The app itself, signed as its bundle ID and the team's,
	/// has each group with the team ID on the end, as AltStore and SideStore
	/// name them, which is also the name an app that builds its group's from
	/// its bundle ID looks for. A copy has its number on the end too, so its
	/// data stays apart from the app's, and one under an App ID of the
	/// user's has that ID's letters and digits. A group that has the team ID
	/// on the end already, as in an IPA taken from an install of AltStore's,
	/// gets it only once.
	public static func names(for groups: [String], appBundleID: String, signedBundleID: String, teamID: String) -> [String: String] {
		let team = "." + teamID
		var suffix: String
		if signedBundleID.hasPrefix(appBundleID + ".") {
			// ".TEAMID", or ".TEAMID.atelier2" for a copy.
			suffix = String(signedBundleID.dropFirst(appBundleID.count))
		} else if signedBundleID == appBundleID {
			// One whose bundle ID has the team's on the end already.
			suffix = ""
		} else {
			let own = signedBundleID.split(separator: ".").filter { $0.caseInsensitiveCompare(teamID) != .orderedSame }.joined()
			suffix = "." + String(own.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
		}
		if !suffix.lowercased().hasPrefix(team.lowercased()) {
			suffix = team + suffix
		}
		var names: [String: String] = [:]
		for group in groups {
			var base = group
			if base.lowercased().hasSuffix(team.lowercased()) { base.removeLast(team.count) }
			names[group] = base + suffix
		}
		return names
	}

	// MARK: Certificates

	/// The folder, inside the group, that holds the app's groups' folders
	/// with a certificate.
	static let folderRoot = "Atelier"

	/// The group of a certificate's profile that keeps the app's groups,
	/// each in a folder of its own (`folders`), when its profile has none
	/// of them: the first of its groups by name, so it stays the same with
	/// every app and every profile that has it. Nil when it has none, or
	/// only a pattern.
	public static func home(in granted: Any?) -> String? {
		let groups = (granted as? [Any] ?? []).compactMap { $0 as? String }
		return groups.filter { !$0.isEmpty && !$0.contains("*") }.sorted().first
	}

	/// The folder each of `groups` is kept in, inside the certificate's
	/// group (`home(in:)`), for an app whose own bundle ID is
	/// `appBundleID`, signed as `signedBundleID`: one named after the group,
	/// so two apps by one developer that share a group share its folder, as
	/// they would from the App Store. A copy has its number on the end too,
	/// `….atelier2`, so its data stays apart from the app's, and one under
	/// an App ID of the user's has that ID's letters and digits, as with an
	/// Apple ID (`names`).
	public static func folders(for groups: [String], appBundleID: String, signedBundleID: String) -> [String: String] {
		var suffix = ""
		if signedBundleID.hasPrefix(appBundleID + ".") {
			suffix = String(signedBundleID.dropFirst(appBundleID.count))
		} else if signedBundleID != appBundleID {
			suffix = "." + String(signedBundleID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
		}
		var folders: [String: String] = [:]
		for group in groups {
			// Only what a group's name may have, so it stays one folder.
			let name = String((group + suffix).map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" })
			guard !name.isEmpty, !name.allSatisfy({ $0 == "." }) else { continue }
			folders[group] = folderRoot + "/" + name
		}
		return folders
	}
}
