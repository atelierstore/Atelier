#if canImport(SwiftData)
import Foundation
import InstallKit
import SigningKit
import SourceKit
import SwiftData

// The mapping from a source's app to what's installed (#8): each
// `InstallRecord` is one installed bundle ID, with the source app it is
// (`sourceBundleID` and `sourceURL`), the certificate that signed it
// (`certificateID`) and the App ID and team it was signed for. Updates (#18)
// and re-signing (#20) start from these records: they sign the source app
// again as the record's bundle ID, which `InstallTarget` gives every time.
//
// A source can list an app under another bundle ID than its IPA has, as
// AppTesters lists Wallpapers, whose IPA is com.ispazio.Wallpapers-Central,
// as com.apalonapps.wallpaperspys (#116). The record keeps the IPA's, as
// iOS installed it, and its `originalBundleID` the one the source lists.

extension AtelierSchemaV1.InstallRecord {
	/// The bundle ID its source lists it under: its own, a copy's original,
	/// or another one its IPA doesn't have (#116).
	public var sourceBundleID: String {
		originalBundleID ?? bundleID
	}

	/// The bundle ID it's numbered as (#8): its own, or for a copy installed
	/// under a bundle ID of the user's choosing, the one its copy number
	/// gives it, as `CopyStore` keeps it (#113).
	public var numberedBundleID: String {
		CopyStore.shared.numberedID(installedAs: bundleID) ?? bundleID
	}

	/// The original or the numbered copy it is (#8). One its source lists
	/// under another bundle ID than its own is told by its suffix (#116).
	public var target: InstallTarget {
		let numbered = numberedBundleID
		if let number = InstallTarget.copyNumber(of: numbered, original: sourceBundleID) { return .copy(number) }
		return originalBundleID == nil ? .original : InstallTarget.split(numbered).target
	}

	/// The bundle ID its IPA has, which copies are numbered from (#8): a
	/// copy's without the copy's suffix. Not always the one its source
	/// lists (#116).
	public var appBundleID: String {
		target == .original ? bundleID : InstallTarget.split(numberedBundleID).original
	}

	/// What the user chose for it in Custom Install…, a copy (#113) or the app
	/// itself (#155): what its updates and re-signs keep.
	public var copySettings: CopySettings? {
		CopyStore.shared.settings(for: numberedBundleID)
	}

	/// The bundle ID its IPA has: `appBundleID` without the team ID an
	/// install with an Apple ID adds to it (#49).
	public var ipaBundleID: String {
		let id = appBundleID
		guard let teamID, !teamID.isEmpty, id.hasSuffix(".\(teamID)") else { return id }
		return String(id.dropLast(teamID.count + 1))
	}

	/// What it was last signed as.
	public var signedIdentity: SignedAppIdentity {
		SignedAppIdentity(bundleID: bundleID, originalBundleID: sourceBundleID, applicationIdentifier: applicationIdentifier, teamID: teamID)
	}

	/// Its permissions as last signed.
	public var signedPermissions: SignedPermissions? {
		get { permissions.flatMap(SignedPermissions.decoded(from:)) }
		set { permissions = newValue?.encoded() }
	}

	/// Whether it's still installed, from its check scheme (#55).
	/// `isRegistered` is `canOpenURL` for `<scheme>://`. Without a scheme,
	/// a Direct installs scan made since it was installed says (#17).
	public func presence(isRegistered: (String) -> Bool, scan: DeviceScan? = nil) -> AppPresence {
		if let checkScheme { return isRegistered(checkScheme) ? .installed : .deleted }
		guard let scan, scan.scannedAt >= installedAt else { return .unknown }
		return scan.versions[bundleID] != nil ? .installed : .deleted
	}

	/// Notes what a fresh signing made of the app, installed from a source
	/// that lists it as `listedBundleID`, which can be another bundle ID than
	/// its IPA's (#116); nil for an IPA file.
	public func note(_ identity: SignedAppIdentity, listedAs listedBundleID: String? = nil) {
		let listed = listedBundleID ?? identity.originalBundleID
		originalBundleID = listed == identity.bundleID ? nil : listed
		applicationIdentifier = identity.applicationIdentifier
		teamID = identity.teamID
	}
}

/// Whether an app Atelier installed is still on this iPhone (#55).
public enum AppPresence: Equatable, Sendable {
	/// Its check scheme answers.
	case installed
	/// Its check scheme no longer answers: it was deleted outside Atelier.
	case deleted
	/// It has no check scheme: installed with the install check off or no
	/// scheme free.
	case unknown
}

/// The apps installd listed in the last Direct installs scan (#17), by
/// bundle ID, with their versions (`CFBundleShortVersionString`). It tells
/// whether apps without a check scheme are still installed.
public struct DeviceScan: Codable, Equatable, Sendable {
	public var scannedAt: Date
	public var versions: [String: String]

	public init(scannedAt: Date = .now, versions: [String: String]) {
		self.scannedAt = scannedAt
		self.versions = versions
	}
}

public enum InstalledApps {
	/// Notes the check scheme `record`'s new build was signed with, and
	/// takes it off any other record. A scheme is only handed out once no
	/// installed app answers to it, so another record holding it is an app
	/// that has since been deleted.
	@MainActor
	public static func give(_ scheme: String?, to record: InstallRecord, in context: ModelContext) {
		record.checkScheme = scheme
		guard let scheme else { return }
		let bundleID = record.bundleID
		let others = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.checkScheme == scheme && $0.bundleID != bundleID }))) ?? []
		for other in others { other.checkScheme = nil }
	}

	/// Notes what a Direct installs scan found: the version on the device of
	/// each app Atelier installed that's still there, when it was changed
	/// outside Atelier. Returns the apps whose version changed.
	@MainActor
	@discardableResult
	public static func apply(_ scan: DeviceScan, in context: ModelContext) -> [InstallRecord] {
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>())) ?? []
		var changed: [InstallRecord] = []
		for record in records {
			// An app that says it's another version is still the one it was
			// installed as (#113, #155).
			guard let version = scan.versions[record.bundleID], version != record.version, version != record.copySettings?.version else { continue }
			record.version = version
			// The scan reads only the version, so the build number is unknown (#18).
			record.buildVersion = nil
			changed.append(record)
		}
		if !changed.isEmpty { try? context.save() }
		return changed
	}

	/// The record of the app installed as `bundleID`, if Atelier installed it.
	@MainActor
	public static func record(_ bundleID: String, in context: ModelContext) -> InstallRecord? {
		try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.bundleID == bundleID })).first
	}

	/// The bundle ID `target` of the app whose IPA has `bundleID` is
	/// installed as: its own, a copy's numbered one, or the one the user
	/// chose for the copy (#113).
	public static func bundleID(of target: InstallTarget, for bundleID: String) -> String {
		let numbered = target.bundleID(for: bundleID)
		return target == .original ? numbered : CopyStore.shared.installedID(of: numbered)
	}

	/// The record of the source app listed as `bundleID`, as `target`, if
	/// Atelier installed it: under that bundle ID, else under its IPA's
	/// when that's another (#116).
	@MainActor
	public static func record(listedAs bundleID: String, as target: InstallTarget = .original, in context: ModelContext) -> InstallRecord? {
		if let installed = record(Self.bundleID(of: target, for: bundleID), in: context) { return installed }
		let listed = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.originalBundleID == bundleID }))) ?? []
		return listed.first { $0.target == target }
	}

	/// The copy a new copy of the app whose IPA has `bundleID` installs
	/// as: the one after every copy of it Atelier installed, whichever
	/// source app they were (#8, #116), also those installed under a bundle
	/// ID of the user's choosing (#113), and after `others`.
	@MainActor
	public static func newCopy(of bundleID: String, in context: ModelContext, besides others: [String] = []) -> InstallTarget {
		let prefix = "\(bundleID)."
		let installed = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.bundleID.starts(with: prefix) }))) ?? []
		return InstallTarget.newCopy(of: bundleID, installed: installed.map(\.bundleID) + CopyStore.shared.numberedIDs + others)
	}

	/// Notes the bundle ID its source lists each app under, for apps
	/// installed before Atelier kept it, when their IPA has another
	/// (#116). An app's latest install that went through, in `attempts`
	/// (newest first), says which source app it was installed as: the one
	/// that wrote its record. Returns the apps noted.
	@MainActor
	@discardableResult
	public static func noteListings(from attempts: [InstallAttempt], in context: ModelContext) -> [InstallRecord] {
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.sourceURL != nil }))) ?? []
		var noted: [InstallRecord] = []
		for record in records {
			let bundleID = record.bundleID
			let target = record.target
			guard let attempt = attempts.first(where: { $0.bundleID == bundleID && ($0.result == .confirmed || $0.result == .unconfirmed) }),
			      case .source(let sourceURL, let appID, _, let copy, _, _)? = attempt.origin,
			      sourceURL == record.sourceURL, (copy.map(InstallTarget.copy) ?? .original) == target
			else { continue }
			let listed = AppName.bundleID(ofIdentity: appID)
			guard !listed.isEmpty, listed != record.sourceBundleID else { continue }
			record.originalBundleID = listed == bundleID ? nil : listed
			noted.append(record)
		}
		if !noted.isEmpty { try? context.save() }
		return noted
	}

	/// Points apps at another certificate than the one that signed them:
	/// the apps of a deleted certificate at the same one imported again
	/// (#126). `replacement` names the one for each app signed with a
	/// certificate Atelier noted; nil leaves it. Returns the apps changed.
	@MainActor
	@discardableResult
	public static func replaceCertificates(in context: ModelContext, with replacement: (InstallRecord) -> UUID?) -> [InstallRecord] {
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.certificateID != nil }))) ?? []
		var changed: [InstallRecord] = []
		for record in records {
			guard let id = replacement(record), id != record.certificateID else { continue }
			record.certificateID = id
			changed.append(record)
		}
		if !changed.isEmpty { try? context.save() }
		return changed
	}

	/// The app's icon, from its source's listing, for the install bar when
	/// it's reinstalled from the Library. Any source listing it will do
	/// when the one it came from no longer does.
	@MainActor
	public static func iconURL(of record: InstallRecord, in context: ModelContext) -> URL? {
		let bundleID = record.sourceBundleID
		let apps = (try? context.fetch(FetchDescriptor<AppRecord>(predicate: #Predicate { $0.bundleID == bundleID }))) ?? []
		let fromSource = apps.first { $0.source?.url == record.sourceURL && $0.iconURL != nil }
		return (fromSource ?? apps.first { $0.iconURL != nil })?.iconURL
	}

	/// Every install of a source's app: the app itself and its copies, the
	/// original first, then the copies in order. Also when their IPA has
	/// another bundle ID than the one the source lists (#116).
	@MainActor
	public static func records(ofSourceApp bundleID: String, in context: ModelContext) -> [InstallRecord] {
		let prefix = "\(bundleID)."
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.bundleID == bundleID || $0.bundleID.starts(with: prefix) || $0.originalBundleID == bundleID }))) ?? []
		return records
			.filter { $0.sourceBundleID == bundleID }
			.sorted { order($0.target) < order($1.target) }
	}

	/// Every install of the app whose IPA has `bundleID`, which an IPA of it
	/// can install over (#155): the app itself and its copies, the original
	/// first, then the copies in order, whichever source app they were
	/// (#116), also those installed under a bundle ID of the user's
	/// choosing (#113), and those signed with an Apple ID, whose bundle ID
	/// has its team ID (#49).
	@MainActor
	public static func records(ofIPA bundleID: String, in context: ModelContext) -> [InstallRecord] {
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>())) ?? []
		return records
			.filter { $0.ipaBundleID == bundleID }
			.sorted { order($0.target) < order($1.target) }
	}

	private static func order(_ target: InstallTarget) -> Int {
		switch target {
		case .original: 0
		case .copy(let number): number
		}
	}
}
#endif
