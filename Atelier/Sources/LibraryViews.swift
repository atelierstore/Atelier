import CertKit
import DownloadKit
import InstallKit
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI

/// What the Library and the app's page show about an installed app (#17,
/// #81): whether it's still on this iPhone, how its source lists it now,
/// the certificate it was signed with, and what can be done with it.
struct LibraryItem: Identifiable {
	let install: InstallRecord
	/// From its check scheme (#55), or else the last Direct installs scan.
	let presence: AppPresence
	/// Its source's listing, nil for an IPA file or once the source drops it.
	/// On the app's page, the listing shown, which can be another source's
	/// (#81).
	let listing: Catalog.Offer?
	/// What's installed, for comparing with its source's versions.
	let release: InstalledRelease
	/// Nil when it wasn't recorded or has since been deleted.
	let certificate: StoredCertificate?
	/// The Apple ID it was signed with (#49), while Atelier has it.
	let appleID: StoredAppleID?
	/// Its certificate as it was when deleted from Atelier, so the app
	/// still says it was revoked or when it runs out (#20).
	let retired: RetiredCertificate?
	/// The data Disable kept, while the app is off this iPhone (#49): the
	/// Library lists it under Disabled, with Enable.
	let disabled: KeptAppData?
	/// Whether Custom Install… has something to sign again (#155).
	let canSignAgain: Bool
	/// A newer version its source lists that this device can run (#18):
	/// only releases for an installed release, betas too for a beta, and
	/// not the version the user skipped.
	let update: AppVersion?
	/// The update Skip This Version hid, while it's still the newest.
	let skippedUpdate: AppVersion?
	/// A newer version of the same app in another source, only ever
	/// suggested in its details, never applied by itself (#18).
	let elsewhere: OtherSourceUpdate?
	/// The source it was installed from no longer lists the installed
	/// version, or the app (#104), such as a beta once the source's
	/// pre-releases are hidden.
	let unlisted: Unlisted?
	/// Atelier itself (#24): it updates from its built-in source only, and
	/// can't be deleted, opened or installed as an older version from here.
	let isOwn: Bool
	/// Atelier itself, installed with a free Apple ID that isn't signed in
	/// here (#152): until it is, nothing renews Atelier's own profile, so
	/// its row is in Renew with Sign In.
	let needsAppleID: OwnSignIn?
	/// Atelier's icon as it runs: a copy's tint or picture too (#113).
	private let ownIconURL: URL?

	/// What Atelier's own row says while the free Apple ID that installed
	/// it isn't signed in (#152).
	struct OwnSignIn {
		/// When its profile ends, as its build says; nil once that has
		/// passed with Atelier still opening, as another tool renewed it.
		let expires: Date?
		/// Atelier has Apple IDs, but not that one.
		let hasOthers: Bool
	}

	struct OtherSourceUpdate {
		let offer: Catalog.Offer
		let version: AppVersion
	}

	struct Unlisted {
		let source: Catalog.SourceInfo
		/// It still lists the app, only not the installed version.
		let listsApp: Bool
		/// As the source names it while it lists it.
		let appName: String
	}

	var id: PersistentIdentifier { install.persistentModelID }

	/// Its update's download, started by Update or ahead (#19). It shows in
	/// the app's row in Updates rather than in Downloads, so each app shows
	/// once (26 Oct).
	@MainActor
	func updateDownload(_ downloads: DownloadManager) -> Download? {
		guard let update, let listing else { return nil }
		return downloads.download(of: update, sourceURL: listing.source.url)
	}

	/// `shown` is the listing the app's page shows, when that's another
	/// source's than the one it was installed from (#81): its updates,
	/// older versions and Install are then that listing's.
	@MainActor
	init(_ install: InstallRecord, catalog: Catalog, certificates: CertificatesModel, installer: InstallModel, showing shown: Catalog.Offer? = nil) {
		self.install = install
		isOwn = SelfUpdate.shared.isOwn(install)
		needsAppleID = isOwn ? SelfUpdate.shared.needsAppleID(in: certificates).map { OwnSignIn(expires: $0.expires, hasOthers: $0.hasOthers) } : nil
		ownIconURL = isOwn ? SelfUpdate.shared.iconURL : nil
		presence = InstallModel.presence(of: install)
		let installedFrom = InstallModel.listing(of: install, in: catalog)
		listing = shown ?? installedFrom
		certificate = install.certificateID.flatMap { id in certificates.certificates.first { $0.id == id } }
		appleID = certificate == nil ? certificates.appleID(install.certificateID) : nil
		retired = certificate == nil ? install.certificateID.flatMap { certificates.retired[$0] } : nil
		disabled = presence == .installed ? nil : installer.disabledApps[install.bundleID]
		canSignAgain = installer.canSignAgain(install, in: catalog)
		// A beta by where it was installed from, whichever listing is shown.
		release = InstalledRelease(version: install.version, buildVersion: install.buildVersion, installedAt: install.installedAt, listing: installedFrom?.app)
		let listsInstalled = installedFrom.flatMap { InstallModel.listedVersion(of: install, in: $0.app) } != nil
		// Atelier's too: it still signs itself as it runs (#24), but gets
		// no updates meanwhile (29 Oct).
		if listsInstalled {
			unlisted = nil
		} else if let installedFrom {
			unlisted = Unlisted(source: installedFrom.source, listsApp: true, appName: installedFrom.app.name)
		} else {
			// Not a source the user removed, nor an IPA file.
			unlisted = install.sourceURL.flatMap { catalog.source(url: $0) }.map { Unlisted(source: $0.source, listsApp: false, appName: install.name) }
		}
		// A disabled app's Enable installs its source's newest (#49).
		guard let listing, presence != .deleted, disabled == nil else {
			update = nil
			skippedUpdate = nil
			elsewhere = nil
			return
		}
		update = UpdateCheck.update(for: release, in: listing.app, skipping: install.skippedVersion)
		skippedUpdate = update == nil
			? UpdateCheck.update(for: release, in: listing.app).flatMap { UpdateCheck.key(of: $0) == install.skippedVersion ? $0 : nil }
			: nil
		// Atelier updates from its own source only (#24).
		elsewhere = isOwn ? nil : Self.otherSourceUpdate(for: release, beyond: update ?? skippedUpdate, of: listing, in: catalog)
	}

	/// The newest version another source lists of the same app (same bundle
	/// ID and name) that's newer than both the installed build and its own
	/// source's update.
	private static func otherSourceUpdate(for release: InstalledRelease, beyond ownUpdate: AppVersion?, of listing: Catalog.Offer, in catalog: Catalog) -> OtherSourceUpdate? {
		guard let entry = catalog.entry(id: listing.app.id) else { return nil }
		let baseline = ownUpdate.map {
			InstalledRelease(version: $0.version, buildVersion: $0.buildVersion, installedAt: release.installedAt, fromBetaListing: release.isBeta)
		} ?? release
		var best: OtherSourceUpdate?
		for offer in entry.offers where offer.source.url != listing.source.url {
			guard let version = UpdateCheck.update(for: baseline, in: offer.app) else { continue }
			if let current = best, UpdateCheck.compare(version, current.version) != .orderedDescending { continue }
			best = OtherSourceUpdate(offer: offer, version: version)
		}
		return best
	}

	/// How the install queue knows its source app's install. Atelier's own
	/// installs, from anywhere, go by its built-in source (#24).
	var appKey: InstallModel.AppKey {
		if isOwn { return InstallModel.AppKey(bundleID: SelfUpdate.sourceBundleID, sourceURL: SelfUpdate.sourceURL) }
		return InstallModel.AppKey(bundleID: install.sourceBundleID, sourceURL: listing?.source.url)
	}

	/// Its source's versions older than the installed one that this device
	/// can run, for Install Older Version (#78). None for Atelier, as an
	/// older build may not read the data a newer one saved (#24).
	var olderVersions: [AppVersion] {
		guard !isOwn, let listing, presence != .deleted else { return [] }
		return UpdateCheck.olderVersions(than: release, in: listing.app)
	}

	/// Says its source no longer lists the installed version (#104): while
	/// it's on this iPhone with nothing newer there to update to, so
	/// Atelier can't sign it again. Atelier itself still can, as it signs
	/// itself as it runs (#24).
	var showsUnlisted: Bool {
		unlisted != nil && presence == .installed && update == nil && skippedUpdate == nil
	}

	/// The installed version with its build number, as "9.0.52 (120)".
	var installedDisplayVersion: String { Self.displayVersion(of: install) }

	static func displayVersion(of install: InstallRecord) -> String {
		guard let build = install.buildVersion, build != install.version else { return install.version }
		return "\(install.version) (\(build))"
	}

	/// The update's privacy permissions the installed build wasn't signed
	/// with, by name. Sources list permissions per app, not per version, so
	/// this compares the source's list with what Atelier read from the app
	/// when it signed it; empty when that wasn't recorded.
	var newPermissions: [String] {
		guard update != nil, let listing, let signed = install.signedPermissions else { return [] }
		return listing.app.permissions.privacy.keys
			.filter { signed.privacy[$0] == nil }
			.map(AppPermissions.privacyName(for:))
			.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
	}

	/// The icon iOS shows for it, from the IPA Atelier signed, which can be
	/// another app's than the one its source lists (#118); else its source's.
	@MainActor var iconURL: URL? { installedIconURL ?? listing?.app.iconURL }
	/// The same from the IPA alone, or for Atelier, from itself as it runs,
	/// so a copy shows its own tint or picture rather than its source's
	/// icon (#113); nil when Atelier didn't find one there.
	@MainActor var installedIconURL: URL? { InstalledIcons.shared.url(for: install.bundleID) ?? ownIconURL }
	var tint: String? { listing?.app.tintColor ?? listing?.source.tintColor }

	var attention: CertificateAttention? {
		if let certificate { return CertificateAttention(certificate) }
		if let appleID { return CertificateAttention(appleID) }
		return retired.flatMap { CertificateAttention($0) }
	}

	/// Its certificate was revoked or has expired, so it no longer opens.
	var certificateIsDead: Bool { attention == .revoked || attention == .expired }

	/// The certificate it was signed with, by name, also once deleted; the
	/// Apple ID (#49), or "Apple ID" for Atelier while the one that
	/// installed it isn't signed in (#152).
	var certificateName: String? {
		certificate?.displayName ?? appleID?.displayName ?? retired?.name ?? (needsAppleID == nil ? nil : "Apple ID")
	}

	/// The profile Apple gave it for the Apple ID it was installed with
	/// (#49), which ends long before the Apple ID's certificate: 7 days for
	/// a free Apple ID's.
	var appProfile: AppProfile? { appleID?.profile(for: install.bundleID) }

	/// Signed with an Apple ID, also one signed out of since: it installs
	/// as its bundle ID and the team's (#49).
	var isSignedWithAppleID: Bool { appleID != nil || install.ipaBundleID != install.appBundleID }

	/// Offload can take it off this iPhone (#49): any app but Atelier, as
	/// iOS's Offload App (4 Nov 2026), while it's here. It goes
	/// through Direct installs, so it shows once they're set up, and always
	/// for a free Apple ID's apps, which only install through them, and
	/// whose 3 places it frees one of.
	@MainActor var canDisable: Bool {
		!isOwn && disabled == nil && presence != .deleted && (appleID?.isFree == true || RouteASetup.shared.isPaired)
	}

	/// It holds one of a free Apple ID's 3 places on this iPhone (#49):
	/// signed with one, and here rather than offloaded or deleted, so its
	/// row says so.
	var holdsFreePlace: Bool {
		appleID?.isFree == true && disabled == nil && presence != .deleted
	}

	/// Its certificate was revoked, has expired or runs out within 14 days,
	/// so it's in the Library's Re-sign section while it's on this iPhone
	/// (#20).
	var needsResign: Bool { presence != .deleted && disabled == nil && attention != nil }

	/// By its bundle ID, or the check scheme it was signed with (#55), while
	/// Atelier knows it's on this iPhone; not Atelier itself, which is open
	/// already (#24).
	var canOpen: Bool { presence == .installed && !isOwn }

	/// Deleted from this iPhone, with its source's newest version to
	/// install again.
	var canInstall: Bool {
		presence == .deleted && listing?.app.availability().version != nil
	}

	/// Whether Custom Install… has something to install (#155): the app to
	/// sign again, or its listing's newest version, for a new copy or in
	/// place of a version its source no longer lists.
	var canCustomInstall: Bool {
		canSignAgain || listing?.app.availability().version != nil
	}

	/// Its status line, most urgent first.
	enum Status {
		case deleted
		case attention(CertificateAttention)
		/// The profile it got for an Apple ID ended, so it doesn't open
		/// (#49).
		case profileEnded
		case update(AppVersion)
		case skipped(AppVersion)
		/// Atelier can't tell whether it's still there.
		case lastInstalled(Date)
		case daysLeft(String)
		case nothing
	}

	var status: Status {
		if presence == .deleted { return .deleted }
		if let attention { return .attention(attention) }
		if let profile = appProfile, profile.expires <= .now { return .profileEnded }
		if let update { return .update(update) }
		if let skippedUpdate { return .skipped(skippedUpdate) }
		if presence == .unknown { return .lastInstalled(install.installedAt) }
		// Its own profile's days, which end first (#49).
		if let profile = appProfile { return .daysLeft(AppProfileDays.text(until: profile.expires)) }
		if let certificate { return .daysLeft(certificate.remainingText()) }
		return .nothing
	}

	/// The button on the right, as in Browse; Re-sign in the Re-sign
	/// section (#20), Put Back when its data wasn't put back (#96), and
	/// Renew in the Renew section (#49), or Sign In there for Atelier
	/// itself, with the free Apple ID that installed it (#152).
	enum Action {
		case open, update, install, resign, putBack, enable, renew, signIn

		var title: String {
			switch self {
			case .open: "Open"
			case .update: "Update"
			case .install: "Install"
			case .resign: "Re-sign"
			case .putBack: "Put Back"
			case .enable: "Reinstall"
			case .renew: "Renew"
			case .signIn: "Sign In"
			}
		}
	}

	var primary: Action? {
		// Disabled, with its data kept (#49).
		if disabled != nil { return .enable }
		if update != nil { return .update }
		if canOpen { return .open }
		if canInstall { return .install }
		return nil
	}

	/// "Version 1.2 is installed." and the like, for its details.
	var versionLine: String {
		let version = install.version
		if let disabled { return disabledLine(disabled) }
		switch presence {
		case .deleted:
			return "Version \(version) was deleted from this \(ThisDevice.name)."
		case .unknown:
			return "Version \(version) was last installed on \(install.installedAt.formatted(date: .abbreviated, time: .omitted))."
		case .installed:
			if let update { return "Version \(installedDisplayVersion) is installed. \(update.displayVersion) is available." }
			if let skippedUpdate { return "Version \(installedDisplayVersion) is installed. You skipped \(skippedUpdate.displayVersion)." }
			// Atelier is open already (#24).
			if isOwn { return "Version \(installedDisplayVersion) is installed." }
			return "Version \(version) is installed."
		}
	}

	/// "Offloaded on Sat 7 Nov. Atelier keeps its data: 48 MB in 1,212
	/// files. Reinstall installs 4.2.1, its source's newest, and puts the
	/// data back." (#49)
	///
	/// With its Home Screen spot kept (9 Nov 2026): "Atelier keeps
	/// its data, 48 MB in 1,212 files, and its spot on page 9 of your Home
	/// Screen. Reinstall installs 4.2.1, its source's newest, and puts both
	/// back."
	private func disabledLine(_ kept: KeptAppData) -> String {
		let day = (kept.disabledAt ?? kept.copiedAt).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
		let files = kept.files == 1 ? "1 file" : "\(kept.files.formatted()) files"
		let size = "\(ByteCountFormatter.string(fromByteCount: kept.bytes, countStyle: .file)) in \(files)"
		let spot = HomeScreenSpots.isOn ? HomeScreenSpots.noted(install.bundleID)?.spot.map(HomeScreenSpots.kept) : nil
		let data = spot.map { "Atelier keeps its data, \(size), and \($0)." } ?? "Atelier keeps its data: \(size)."
		let back = spot == nil ? "puts the data back" : "puts both back"
		let enable = if let version = listing?.app.availability().version {
			"Reinstall installs \(version.displayVersion), its source's newest, and \(back)."
		} else {
			"Reinstall asks for its IPA file, then installs it and \(back)."
		}
		return "Offloaded on \(day). \(data) \(enable)"
	}
}

/// What the Library's rows and details do with an installed app (#17).
@MainActor
struct LibraryActions {
	let installer: InstallModel
	let catalog: Catalog
	let downloads: DownloadManager
	let certificates: CertificatesModel
	let context: ModelContext

	func perform(_ action: LibraryItem.Action, on item: LibraryItem, resign: (LibraryItem) -> Void, putBack: (LibraryItem) -> Void) {
		switch action {
		case .open: InstallModel.open(item.install)
		case .update: update(item)
		case .install: update(item)
		case .resign: resign(item)
		case .putBack: putBack(item)
		case .enable: enable(item)
		case .renew: renew(item)
		case .signIn: certificates.beginSignIn()
		}
	}

	/// Renew and Renew Now (#49): a new profile from Apple, put on without
	/// reinstalling, or the app signed again when a new one won't do.
	func renew(_ item: LibraryItem) {
		let bundleID = item.install.bundleID
		Task { await ProfileRenewals.shared.renew([bundleID]) }
	}

	// MARK: Disable and Enable (#49)

	/// Disable, once asked: takes the app off this iPhone through Direct
	/// installs, keeping its data in Atelier until Enable puts it back.
	func disable(_ item: LibraryItem) {
		installer.disable(item.install, iconURL: item.iconURL ?? InstalledApps.iconURL(of: item.install, in: context), certificates: certificates, into: context)
	}

	/// Enable: installs the app again, its source's newest version, and
	/// puts its data back; asks for its IPA when its source lists none,
	/// as for an app installed from a file.
	func enable(_ item: LibraryItem) {
		if installer.enable(item.install, in: catalog, downloads: downloads, certificates: certificates, into: context) { return }
		let install = item.install
		let installer = installer
		let certificates = certificates
		let context = context
		IPAPicker.present { url in
			installer.enable(install, picked: url, certificates: certificates, into: context)
		}
	}

	/// Installs its update (or, when deleted, its source's newest version),
	/// as the app or the copy it is, from the listing it's compared with.
	/// One whose certificate died is signed with the certificate re-signing
	/// uses, which it puts in use (#20).
	func update(_ item: LibraryItem) {
		guard let listing = item.listing, let version = item.update ?? item.skippedUpdate ?? listing.app.availability().version else { return }
		if item.certificateIsDead, let target = certificates.resignTarget { certificates.useForResigning(target) }
		installer.update(item.install, to: version, from: listing, downloads: downloads, certificates: certificates, into: context)
	}

	/// Every update, leaving out skipped versions (#18): all the downloads
	/// start at once, as the maintainer asked, and the installs queue to run one at a
	/// time, each once its download is done. Returns the group, which keeps
	/// the apps together in the Updates section until the last one is done.
	func updateAll(_ items: [LibraryItem]) -> UpdateGroup {
		var group = UpdateGroup()
		for item in items {
			guard let listing = item.listing, let version = item.update else { continue }
			// Atelier's own update downloads only once a certificate, or its
			// Apple ID, signs for its App ID; Update says why not first (#24,
			// #152).
			if item.isOwn, !SelfUpdate.shared.canSignItself(certificates: certificates, context: context) { continue }
			let download = downloads.download(listing.app, version: version, sourceURL: listing.source.url)
			group.add(item.install.bundleID, version: version, download: download.id)
		}
		for item in items where item.update != nil {
			update(item)
		}
		return group
	}

	/// Cancel All: takes the group's waiting installs off the queue, cancels
	/// the running one and stops downloads that haven't finished.
	func cancel(_ group: UpdateGroup, items: [LibraryItem]) {
		for item in items where group.contains(item.install.bundleID) {
			switch installer.status(of: item.appKey) {
			case .running?: installer.cancel()
			case .waiting(let job)?: installer.remove(job)
			case nil: break
			}
		}
		for id in group.downloadIDs where downloads.download(id: id)?.status == .downloading {
			downloads.remove(id)
		}
	}

	/// Installs the newer version another source lists; that source becomes
	/// the app's source from then on (#18).
	func update(_ item: LibraryItem, from other: LibraryItem.OtherSourceUpdate) {
		installer.update(item.install, to: other.version, from: other.offer, downloads: downloads, certificates: certificates, into: context)
	}

	/// Skip This Version: hides this update until a newer one comes (#18).
	func skip(_ item: LibraryItem) {
		guard let update = item.update else { return }
		// Its download goes too, rather than turn up in Downloads (#19).
		if let download = item.updateDownload(downloads), !installer.isQueued(download) {
			downloads.remove(download.id)
		}
		item.install.skippedVersion = UpdateCheck.key(of: update)
		try? context.save()
	}

	func unskip(_ item: LibraryItem) {
		item.install.skippedVersion = nil
		try? context.save()
	}

	/// Puts the data Atelier copied before reinstalling the app back into
	/// it, once that couldn't be done right after the install (#96).
	func putBack(_ item: LibraryItem) {
		installer.putBackData(of: item.install, iconURL: item.iconURL ?? InstalledApps.iconURL(of: item.install, in: context), in: context, certificates: certificates)
	}

	/// Installs an older version from its source over the installed one
	/// (#78) as an update would: as the app or the copy it is, with the
	/// certificate it was installed with, asking first when iOS can't
	/// replace it (#76).
	func installOlder(_ item: LibraryItem, version: AppVersion) {
		guard let listing = item.listing else { return }
		installer.update(item.install, to: version, from: listing, downloads: downloads, certificates: certificates, into: context)
	}

	// MARK: Re-signing (#20)

	/// Whether re-signing `item` with `target` means deleting it first, as
	/// iOS can't replace it with an app signed for another App ID (#76).
	func needsReinstall(_ item: LibraryItem, resigningWith target: StoredCertificate) -> Bool {
		installer.needsReinstall(item.install, signingWith: target.id, certificates: certificates)
	}

	/// What `item`'s row in the Re-sign section says, with `target` the
	/// certificate re-signing uses, if any, and `failure` why its last
	/// re-sign failed.
	func resignNote(for item: LibraryItem, target: StoredCertificate?, failure: String?) -> ResignNote {
		guard let target else { return ResignNote(kind: .certificate, canResign: false) }
		// Atelier signs itself for the App ID it was installed with, or not
		// at all: it can't delete itself to install again (#24).
		if item.isOwn, !SelfUpdate.shared.canResign(with: target) {
			return ResignNote(kind: .cannot("\(target.displayName) can't update \(item.install.name)"), canResign: false)
		}
		// An app installed from an IPA always can: from its IPA, or one
		// Atelier asks for (#113).
		guard installer.resignSource(of: item.install, in: catalog) != nil else {
			return ResignNote(kind: .cannot("its source no longer lists it"), canResign: false)
		}
		if let failure { return ResignNote(kind: .failed(failure), canResign: true) }
		return ResignNote(kind: needsReinstall(item, resigningWith: target) ? .reinstallRequired : .certificate, canResign: true)
	}

	/// Signs an app whose certificate died again with `target`, and installs
	/// it over the old one, deleting that first through Direct installs when
	/// `deletingFirst`, its data copied aside and put back unless
	/// `keepingData` is false (#96). `target` is put in use, so what's
	/// installed next is signed with it too. Returns the install's ID, nil
	/// when there's nothing to sign.
	@discardableResult
	func resign(_ item: LibraryItem, with target: StoredCertificate, deletingFirst: Bool = false, keepingData: Bool = true) -> String? {
		certificates.useForResigning(target)
		return installer.resign(item.install, with: target.id, deletingFirst: deletingFirst, keepingData: keepingData, in: catalog, downloads: downloads, certificates: certificates, into: context)
	}

	/// Re-sign All, as Update All: the downloads start at once, and the
	/// installs queue to run one at a time. Those in `deletingFirst`, by
	/// bundle ID, are deleted right before theirs. Returns the group, which
	/// keeps the apps together in the Re-sign section until each is done.
	func resignAll(_ items: [LibraryItem], with target: StoredCertificate, deletingFirst: Set<String>) -> ResignGroup {
		var group = ResignGroup()
		for item in items {
			var version: AppVersion?
			var download: UUID?
			switch installer.resignSource(of: item.install, in: catalog) {
			case .installedVersion(let offer, let listed)?, .newerVersion(let offer, let listed)?:
				version = listed
				download = downloads.download(offer.app, version: listed, sourceURL: offer.source.url).id
			case .runningApp?, .ipa?, nil:
				break
			}
			guard let job = resign(item, with: target, deletingFirst: deletingFirst.contains(item.install.bundleID)) else { continue }
			group.add(item.install.bundleID, job: job, version: version, download: download)
		}
		return group
	}

	/// Cancel All while Re-sign All runs: takes the group's waiting installs
	/// off the queue, cancels the running one and stops downloads that
	/// haven't finished.
	func cancel(_ group: ResignGroup) {
		for job in group.jobIDs.values {
			switch installer.status(ofJob: job) {
			case .running?: installer.cancel()
			case .waiting(let waiting)?: installer.remove(waiting)
			case nil: break
			}
		}
		for id in group.downloadIDs where downloads.download(id: id)?.status == .downloading {
			downloads.remove(id)
		}
	}
}

/// An installed app's row in the Library (#17): icon, version, source and
/// certificate, its status, and Open, Update or Install on the right.
struct LibraryRow: View {
	let item: LibraryItem
	let sourceName: String
	/// In the Updates section (#18): "1.7.2 → 1.8" and the start of What's
	/// New, or the permissions the update newly asks for.
	var showsUpdate = false
	/// Just updated with Update All: says so in place of its status.
	var justUpdated = false
	/// In the Re-sign section (#20): what re-signing does to it, in place
	/// of its status, and Re-sign on the right when it can be re-signed.
	var resign: ResignNote?
	/// Just re-signed: says so in place of its status.
	var justResigned = false
	/// In the Renew section (#49): when its profile ends, why Atelier
	/// didn't renew it by itself, and Renew on the right.
	var renews = false
	let perform: (LibraryItem.Action) -> Void
	@Environment(InstallModel.self) private var installer
	@Environment(DownloadManager.self) private var downloads
	@Environment(SourcesModel.self) private var sources

	var body: some View {
		// An install over it, such as Re-sign's, shows here rather than in
		// Downloads too, and an app deleted for it to be installed again
		// keeps its icon meanwhile (12 Nov 2026).
		let installing = installer.status(ofLibraryApp: item.install.bundleID, key: item.appKey)
		let installLine = LibraryInstallLine(
			status: installing,
			download: installer.downloadID(ofLibraryApp: item.install.bundleID, key: item.appKey).flatMap { downloads.download(id: $0) },
			downloads: downloads
		)
		let deleted = item.presence == .deleted && installing == nil
		HStack(spacing: 12) {
			if item.disabled != nil {
				DisabledAppIcon(url: item.iconURL, tint: item.tint, size: 48)
			} else {
				SourceIcon(url: item.iconURL, tint: item.tint, size: 48)
					.opacity(deleted ? 0.45 : 1)
			}
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(item.install.name)
						.font(.headline)
						.foregroundStyle(deleted ? .secondary : .primary)
						.lineLimit(1)
					// The installed version is a beta, as Browse marks one (#104).
					if item.release.isBeta { BetaTag() }
					// One of the apps a free Apple ID's 3 places hold (#49).
					if item.holdsFreePlace { FreeAppleIDTag() }
				}
				if showsUpdate, let update = item.update ?? item.skippedUpdate {
					Text("\(item.installedDisplayVersion) → \(update.displayVersion) · \(sourceName)")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					if let line = selfInstallLine {
						line
					} else if case .running? = installing, let installLine {
						installLine
					} else if let download = item.updateDownload(downloads), let label = UpdateDownloadLabel(download: download, downloads: downloads) {
						label
						// New permissions still say so.
						if !item.newPermissions.isEmpty { UpdateSummary(item: item, update: update) }
					} else {
						UpdateSummary(item: item, update: update)
					}
				} else {
					Text([item.install.version, sourceName, item.certificateName].compactMap { $0 }.joined(separator: " · "))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
					if let line = selfInstallLine {
						line
					} else if let installLine {
						installLine
					} else if let disabled = item.disabled {
						// Off this iPhone, its data kept (#49). The cloud on its
						// icon says so already (4 Nov 2026).
						Text("Offloaded · data kept, \(ByteCountFormatter.string(fromByteCount: disabled.bytes, countStyle: .file))")
							.font(.caption.weight(.medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)
					} else if let resign {
						ResignNoteLabel(note: resign, attention: item.attention)
					} else if renewals.isRenewing(item.install.bundleID) {
						// In the background, or after Renew: a few seconds, with
						// no install bar (#49).
						HStack(spacing: 5) {
							ProgressView()
								.controlSize(.mini)
							Text("Renewing…")
						}
						.font(.caption.weight(.medium))
						.foregroundStyle(.secondary)
					} else if renews, let need = item.needsAppleID {
						OwnSignInLabel(need: need, name: item.install.name)
					} else if renews, let profile = item.appProfile {
						RenewDueLabel(profile: profile, problem: renewals.problems[item.install.bundleID], isOwn: item.isOwn)
					} else if dataWaits {
						Label("Data not put back", systemImage: "exclamationmark.triangle.fill")
							.font(.caption.weight(.medium))
							.foregroundStyle(.orange)
					} else if needsSignIn {
						NotSignedInToGitHubLabel()
					} else if saysUnlisted {
						// Its source's name is on the line above.
						Label("No longer listed", systemImage: "exclamationmark.triangle.fill")
							.font(.caption.weight(.medium))
							.foregroundStyle(.orange)
					} else if justUpdated, case .daysLeft = item.status {
						JustDoneLabel("Updated just now", short: "Updated", systemImage: "checkmark")
					} else if justResigned, case .daysLeft = item.status {
						JustDoneLabel("Re-signed just now", short: "Re-signed", systemImage: "checkmark")
					} else if renewals.recentlyRenewed.contains(item.install.bundleID), case .daysLeft(let text) = item.status {
						// Until the Library is left (#49).
						JustDoneLabel("Renewed · \(text)", short: "Renewed", systemImage: "checkmark.seal.fill")
					} else {
						LibraryStatusLabel(status: item.status)
					}
				}
			}
			// Icons close to their text, as Browse's, rather than in a
			// column of their own, so a status fits next to Open (12 Nov 2026).
			.labelStyle(InlineLabelStyle())
			Spacer(minLength: 8)
			if installing == nil, let fetching = installer.fetchingIPA(of: item.install.bundleID), downloads.download(id: fetching) != nil {
				// Its IPA downloads, for Re-sign or Custom Install… to install
				// over it: no install to stop yet, but the download (12 Nov 2026).
				Button { installer.cancelIPADownload(of: item.install.bundleID, downloads: downloads) } label: {
					GroupRing(fraction: downloads.progress[fetching]?.fraction)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Cancel download")
			} else if let action {
				LibraryButton(action: action, status: installing) { perform(action) }
					// Put Back waits for no install (#96).
					.disabled(action == .putBack && !installer.canPutBack)
			}
		}
		.padding(.vertical, 2)
	}

	/// Atelier's own install (#24): it waits for every other install, then
	/// iOS installs it once Atelier closes.
	private var selfInstallLine: SelfInstallLine? {
		guard item.isOwn else { return nil }
		if installer.isHandingOver { return SelfInstallLine(text: "Go to the Home Screen to finish", handingOver: true) }
		guard case .waiting(let job)? = installer.status(of: item.appKey), job.isSelf else { return nil }
		let downloaded = item.updateDownload(downloads)?.status == .finished
		return SelfInstallLine(text: InstallModel.goesLast(job.selfKind, downloaded: downloaded), handingOver: false)
	}

	/// Re-sign in the Re-sign section, when it can be re-signed; Renew in
	/// the Renew section, none while it renews; Put Back when its data
	/// wasn't put back; else as in Browse.
	private var action: LibraryItem.Action? {
		if renews, item.needsAppleID != nil { return .signIn }
		if renews { return renewals.isRenewing(item.install.bundleID) ? nil : .renew }
		guard let resign else { return dataWaits ? LibraryItem.Action.putBack : item.primary }
		return resign.canResign ? .resign : nil
	}

	/// Which apps renew, and why one didn't (#49).
	private var renewals: ProfileRenewals { .shared }

	/// The data Atelier copied before reinstalling it wasn't put back
	/// (#96). An update's row says what the update is instead.
	private var dataWaits: Bool {
		!showsUpdate && item.presence != .deleted && installer.dataWaits(for: item.install.bundleID)
	}

	/// Its source needs a GitHub sign-in (#134), so its updates may be
	/// missing, said in place of the days left, ahead of no longer listed,
	/// which may be why; a certificate that needs attention first.
	private var needsSignIn: Bool {
		guard sources.needsGitHubSignIn(item.install.sourceURL) else { return false }
		switch item.status {
		case .daysLeft, .nothing: return true
		default: return false
		}
	}

	/// Its source no longer lists the installed version (#104), said in
	/// place of the days left; a certificate that needs attention first.
	private var saysUnlisted: Bool {
		guard item.showsUnlisted else { return false }
		switch item.status {
		case .daysLeft, .nothing: return true
		default: return false
		}
	}
}

/// What an app's row says while an install over it waits or runs, or its
/// IPA downloads for one, in place of its status, in blue as Update All's
/// rows say it: Re-sign's, Reinstall's, Custom Install's or an update's,
/// rather than a row in Downloads too (12 Nov 2026). Nil when there's
/// none.
struct LibraryInstallLine: View {
	private let text: String
	/// Under way, rather than waiting or paused.
	private let active: Bool

	init?(status: InstallModel.AppStatus?, download: Download?, downloads: DownloadManager) {
		switch status {
		case .running(let stage)?:
			text = UpdateGroupRow.describe(stage)
			active = true
		case .waiting?, nil:
			switch download?.status {
			case .downloading?:
				let fraction = download.flatMap { downloads.progress[$0.id]?.fraction }
				text = fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
				active = true
			case .paused?:
				text = "Download paused"
				active = false
			case .finished? where status != nil:
				text = "Downloaded, waiting"
				active = false
			default:
				guard status != nil else { return nil }
				text = "Waiting"
				active = false
			}
		}
	}

	var body: some View {
		Text(text)
			.font(.caption.weight(.medium))
			.foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
			.lineLimit(1)
	}
}

/// "Re-signed just now", in green on one line, or "Re-signed" alone in a
/// row too narrow for it, rather than on two lines (12 Nov 2026).
struct JustDoneLabel: View {
	let text: String
	let short: String
	let systemImage: String

	init(_ text: String, short: String, systemImage: String) {
		self.text = text
		self.short = short
		self.systemImage = systemImage
	}

	var body: some View {
		ViewThatFits(in: .horizontal) {
			Label(text, systemImage: systemImage)
				.lineLimit(1)
			Label(short, systemImage: systemImage)
				.lineLimit(1)
		}
		.font(.caption.weight(.medium))
		.foregroundStyle(.green)
	}
}

/// What Atelier's own row says while its install waits for every other
/// install, or once iOS has it (#24).
struct SelfInstallLine: View {
	let text: String
	/// iOS has it: what's left is for the user to do.
	let handingOver: Bool

	var body: some View {
		Text(text)
			.font(.caption.weight(.medium))
			.foregroundStyle(handingOver ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
			.lineLimit(1)
	}
}

/// What an app's row in the Library's Re-sign section says (#20).
struct ResignNote {
	enum Kind {
		/// Its certificate's state: re-signing keeps its data.
		case certificate
		/// The certificate re-signing uses signs for another App ID, so iOS
		/// can't replace the app: it's deleted first, and its data with it
		/// (#76), unless Direct installs copy it aside and put it back (#96).
		case reinstallRequired
		/// Its last re-sign failed, with why when that's known.
		case failed(String?)
		/// Why there's nothing to sign.
		case cannot(String)
	}

	let kind: Kind
	/// Whether Re-sign shows: there's a certificate to re-sign with and
	/// something to sign.
	let canResign: Bool
}

/// The status line of an app in the Re-sign section (#20).
struct ResignNoteLabel: View {
	let note: ResignNote
	let attention: CertificateAttention?

	var body: some View {
		switch note.kind {
		case .certificate:
			if let attention { CertificateAttentionLabel(attention: attention) }
		case .reinstallRequired:
			Label("Reinstall required", systemImage: "exclamationmark.triangle.fill")
				.font(.caption.weight(.medium))
				.foregroundStyle(.orange)
		case .failed(let why):
			Text(why.map { "Didn't re-sign: \($0)" } ?? "Didn't re-sign")
				.font(.caption.weight(.medium))
				.foregroundStyle(.red)
				.lineLimit(2)
		case .cannot(let why):
			Text("Can't re-sign: \(why)")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
	}
}

/// Under the Library's Re-sign section (#20): why its apps are there, and
/// what re-signing does to them.
struct ResignFooter: View {
	/// The section's apps.
	let items: [LibraryItem]
	/// Those Re-sign shows for.
	let resignable: [LibraryItem]
	/// How many of those iOS can't replace, so they're deleted first:
	/// with their data copied aside and put back through Direct installs
	/// (#96), else losing it.
	let reinstalling: Int
	/// The certificate re-signing uses; nil when there's none to use.
	let target: StoredCertificate?
	@State private var routeA = RouteASetup.shared

	var body: some View {
		Text([cause, effect].compactMap { $0 }.joined(separator: " "))
	}

	/// "Signulous Development was revoked, so these apps won't open."
	private var cause: String {
		let apps = items.count == 1 ? items[0].install.name : "these apps"
		let attentions = items.compactMap(\.attention)
		let names = Set(items.compactMap(\.certificateName))
		if names.count == 1, let name = names.first, let attention = attentions.first, attentions.allSatisfy({ $0 == attention }) {
			switch attention {
			case .revoked: return "\(name) was revoked, so \(apps) won't open."
			case .expired: return "\(name) has expired, so \(apps) won't open."
			case .expiring(let days): return "\(name) expires \(days == 1 ? "within a day" : "in \(days) days"), so \(apps) will stop opening then."
			}
		}
		return attentions.allSatisfy { $0 == .revoked || $0 == .expired }
			? "The certificates these apps were signed with were revoked or have expired, so they won't open."
			: "The certificates these apps were signed with were revoked, have expired or expire within 14 days."
	}

	/// What Re-sign or Re-sign All does, or what to import first. Atelier
	/// goes last, as it closes for iOS to install it (#24), which it asks
	/// for (#123).
	private var effect: String? {
		guard let effect = resignEffect else { return nil }
		guard let own = resignable.first(where: \.isOwn) else { return effect }
		let name = own.install.name
		return resignable.count == 1
			? "\(effect) Then \(name) asks you to go to the Home Screen, for iOS to install it."
			: "\(effect) \(name) goes last, then asks you to go to the Home Screen, for iOS to install it."
	}

	private var resignEffect: String? {
		guard let target else {
			return items.count == 1
				? "Import a new certificate, and Atelier signs \(items[0].install.name) again with it and installs it over the old one."
				: "Import a new certificate, and Atelier signs them again with it and installs them over the old ones."
		}
		guard !resignable.isEmpty else { return nil }
		if routeA.isPaired, reinstalling > 0 {
			return keepingData(target)
		}
		if resignable.count == 1 {
			let name = resignable[0].install.name
			let data = reinstalling > 0 ? "It has to be deleted and installed again, so it loses its data." : "It keeps its data."
			return "Re-sign signs \(name) again with \(target.displayName) and installs it over the old one. \(data)"
		}
		let data = switch reinstalling {
		case 0: "They keep their data."
		case resignable.count: "They have to be deleted and installed again, so they lose their data."
		default: "They keep their data, apart from those marked Reinstall required."
		}
		return "Re-sign All signs them again with \(target.displayName) and installs them over the old ones. \(data)"
	}

	/// With Direct installs, those iOS can't replace are deleted and
	/// installed again with their data (#96).
	private func keepingData(_ target: StoredCertificate) -> String {
		if resignable.count == 1 {
			return "Re-sign signs \(resignable[0].install.name) again with \(target.displayName). It's deleted and installed again, and keeps its data."
		}
		if reinstalling == resignable.count {
			return "Re-sign All signs them again with \(target.displayName). They're deleted and installed again, and keep their data."
		}
		return "Re-sign All signs them again with \(target.displayName). Those marked Reinstall required are deleted and installed again. All of them keep their data."
	}
}

/// Under an update in the Updates section, while its download runs or
/// once it's done (#19): Update then only signs and installs. Nil when
/// there's nothing to say about it, such as a failed download started
/// ahead, which is tried again at the next check.
struct UpdateDownloadLabel: View {
	let download: Download
	let downloads: DownloadManager

	init?(download: Download, downloads: DownloadManager) {
		if case .failed = download.status { return nil }
		self.download = download
		self.downloads = downloads
	}

	var body: some View {
		switch download.status {
		case .downloading:
			let fraction = downloads.progress[download.id]?.fraction
			Text(fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .paused:
			Text("Download paused")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .finished:
			Label("Downloaded", systemImage: "arrow.down")
				.font(.caption.weight(.medium))
				.foregroundStyle(.green)
		case .failed:
			EmptyView()
		}
	}
}

/// Under an update in the Updates section: the permissions it newly asks
/// for, which matter most; else the start of What's New.
struct UpdateSummary: View {
	let item: LibraryItem
	let update: AppVersion
	@Environment(SourcesModel.self) private var sources

	var body: some View {
		let permissions = item.newPermissions
		if item.update == nil {
			Text("Skipped")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		} else if !permissions.isEmpty {
			Label(
				permissions.count == 1 ? "Asks for a new permission: \(permissions[0])" : "Asks for new permissions: \(permissions.formatted(.list(type: .and)))",
				systemImage: "exclamationmark.triangle.fill"
			)
			.font(.caption.weight(.medium))
			.foregroundStyle(.orange)
			.lineLimit(2)
		} else if sources.needsGitHubSignIn(item.install.sourceURL) {
			// Its source needs a GitHub sign-in (#134): a newer version may
			// be missing, and this one may not download without it.
			NotSignedInToGitHubLabel()
		} else if let notes = notes {
			Text(notes)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
	}

	/// What's New, after "New build of the same version." for a build-only
	/// update.
	private var notes: String? {
		let whatsNew = update.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
		let sameVersion = update.version == item.install.version ? "New build of the same version." : nil
		let parts = [sameVersion, whatsNew].compactMap { $0 }.filter { !$0.isEmpty }
		return parts.isEmpty ? nil : parts.joined(separator: " ")
	}
}

/// An installed app's status line.
struct LibraryStatusLabel: View {
	let status: LibraryItem.Status

	var body: some View {
		switch status {
		case .deleted:
			Text("Deleted from this \(ThisDevice.name)")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .attention(let attention):
			CertificateAttentionLabel(attention: attention)
		case .profileEnded:
			Label("Profile ended", systemImage: "clock.badge.xmark")
				.font(.caption.weight(.medium))
				.foregroundStyle(.red)
		case .update(let version):
			Label("Update to \(version.displayVersion)", systemImage: "arrow.up.circle.fill")
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .skipped(let version):
			Text("Skipped \(version.displayVersion)")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .lastInstalled(let date):
			Text("Last installed \(date.formatted(.dateTime.day().month(.abbreviated)))")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .daysLeft(let text):
			Label(text, systemImage: "checkmark.seal.fill")
				.font(.caption.weight(.medium))
				.foregroundStyle(.green)
		case .nothing:
			EmptyView()
		}
	}
}

/// What an app's row in the Library's Renew section says (#49): when its
/// profile ends, orange, or that it ended, red, then why Atelier didn't
/// renew it by itself, unless it's that LocalDevVPN was off, which the
/// section's footer says.
struct RenewDueLabel: View {
	let profile: AppProfile
	let problem: ProfileRenewals.Problem?
	/// Atelier itself, which signing again installs over itself (#152).
	var isOwn = false

	var body: some View {
		if profile.expires <= .now {
			LibraryStatusLabel(status: .profileEnded)
		} else {
			Label("Ends \(AppProfileDays.relative(profile.expires))", systemImage: "exclamationmark.circle.fill")
				.font(.caption.weight(.medium))
				.foregroundStyle(.orange)
				.lineLimit(1)
		}
		if let problem, !problem.isUnreachable {
			Text(problem.message(isOwn: isOwn))
				.font(.caption)
				.foregroundStyle(.red)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

/// What Atelier's own row in the Library's Renew section says while the
/// free Apple ID that installed it isn't signed in (#152): when its
/// profile ends, orange, and that another Apple ID's can't renew it.
struct OwnSignInLabel: View {
	let need: LibraryItem.OwnSignIn
	let name: String

	var body: some View {
		Label(Self.ends(need.expires), systemImage: "exclamationmark.circle.fill")
			.font(.caption.weight(.medium))
			.foregroundStyle(.orange)
			.lineLimit(1)
		if need.hasOthers {
			Text("Another Apple ID installed \(name), so yours can’t renew it. Sign in with that one too.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	/// "Ends in 7 days", "Ends tomorrow at 10:42", "Ends today at 10:42";
	/// without a date, as another tool renewed it since: "Not renewed by
	/// Atelier".
	static func ends(_ expires: Date?, now: Date = .now) -> String {
		guard let expires else { return "Not renewed by Atelier" }
		let days = AppProfileDays.days(until: expires, now: now)
		return days > 2 ? "Ends in \(days) days" : "Ends \(AppProfileDays.relative(expires, now: now))"
	}
}

/// Open, Update or Install, as Browse's Install button (#78): the progress
/// ring while the app installs from its source, and Waiting while it's
/// queued.
struct LibraryButton: View {
	let action: LibraryItem.Action
	/// The app's install, waiting or running.
	var status: InstallModel.AppStatus?
	let perform: () -> Void

	var body: some View {
		InstallStatusButton(title: action.title, prominent: action != .open, status: status, perform: perform)
	}
}

/// An installed app's touch-and-hold menu (#17). Only what applies shows.
struct LibraryMenu: View {
	let item: LibraryItem
	let actions: LibraryActions
	let delete: () -> Void
	/// Asks before Disable (#49).
	var disable: (() -> Void)?

	var body: some View {
		// Off this iPhone with its data kept (#49): Reinstall, Install a
		// Copy…, which leaves it offloaded (4 Nov 2026), or Delete.
		if item.disabled != nil {
			Button("Reinstall", systemImage: "icloud.and.arrow.down") { actions.enable(item) }
			InstallCopyButton(item: item)
			Divider()
			Button("Delete", systemImage: "trash", role: .destructive, action: delete)
		} else {
			installedItems
		}
	}

	@ViewBuilder
	private var installedItems: some View {
		if item.canOpen {
			Button("Open", systemImage: "arrow.up.forward.app") { InstallModel.open(item.install) }
		}
		// Right under Open, as it takes the app off the Home Screen (#49).
		if item.canDisable, let disable {
			Button("Offload", systemImage: "arrow.down.app", action: disable)
		}
		// A new profile now, whether or not it's due (#49).
		if ProfileRenewals.shared.canRenew(item) {
			Button("Renew Now", systemImage: "arrow.triangle.2.circlepath") { actions.renew(item) }
				.disabled(ProfileRenewals.shared.isRenewing(item.install.bundleID))
		}
		if let update = item.update {
			Button("Update to \(update.displayVersion)", systemImage: "arrow.down.circle") { actions.update(item) }
			Button("Skip \(update.displayVersion)", systemImage: "forward.end") { actions.skip(item) }
			// Its download shows in the row rather than in Downloads (#19).
			if let download = item.updateDownload(actions.downloads), !actions.installer.isQueued(download) {
				Button(download.status == .finished ? "Delete Download" : "Cancel Download", systemImage: "xmark.circle", role: .destructive) {
					actions.downloads.remove(download.id)
				}
			}
		} else if let skipped = item.skippedUpdate {
			Button("Update to \(skipped.displayVersion)", systemImage: "arrow.down.circle") { actions.update(item) }
			Button("Don't Skip \(skipped.displayVersion)", systemImage: "arrow.uturn.backward") { actions.unskip(item) }
		}
		CustomInstallButton(item: item, inMenu: true)
		// Atelier can't delete itself (#24).
		if !item.isOwn {
			Divider()
			Button("Delete", systemImage: "trash", role: .destructive, action: delete)
		}
	}
}

/// Custom Install… (#155), in an installed app's page and its
/// touch-and-hold menu in the Library, in place of Install a Copy… (#113)
/// and Sign Again With… (#17), with a line under it that says so: its
/// sheet, opened on the app, to sign it again, change it, or install a new
/// copy next to it, of the newest version its listing offers, or of its
/// IPA, from where Atelier last saw it, or one it asks for. Disabled while
/// there's no certificate or Apple ID to sign with (#49), and when there's
/// nothing to install: its source no longer lists it, and it wasn't
/// installed from an IPA.
struct CustomInstallButton: View {
	let item: LibraryItem
	/// In a menu, where the line goes under the item's title; else in a
	/// list, under the button's.
	let inMenu: Bool
	@Environment(InstallModel.self) private var installer
	@Environment(CatalogModel.self) private var catalog
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		Button {
			installer.askForCustomInstall(item.install, listing: item.listing, in: catalog.catalog, context: context)
		} label: {
			if inMenu {
				Label(CustomInstall.title, systemImage: CustomInstall.systemImage)
				Text(CustomInstall.line(installed: true))
			} else {
				VStack(alignment: .leading, spacing: 2) {
					Text(CustomInstall.title)
					Text(CustomInstall.line(installed: true))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
		}
		.disabled(!item.canCustomInstall || !CustomInstall.canSign(with: certificates))
	}
}

/// Install a Copy… on an offloaded app (#49), which stays offloaded
/// (4 Nov 2026): Custom Install's sheet (#155) on New Copy, as the app isn't
/// there to install over, with its copies that are. A copy of the newest
/// version its listing offers, or of its IPA, from where Atelier last saw
/// it, or one it asks for. Disabled while there's no certificate or Apple
/// ID to sign with, and when there's nothing to copy: its listing has no
/// version this device can run, and it wasn't installed from an IPA.
struct InstallCopyButton: View {
	let item: LibraryItem
	@Environment(InstallModel.self) private var installer
	@Environment(CatalogModel.self) private var catalog
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		Button("Install a Copy…", systemImage: "plus.square.on.square") {
			installer.askForCustomInstall(item.install, listing: item.listing, in: catalog.catalog, context: context)
		}
		.disabled(!canCopy || !CustomInstall.canSign(with: certificates))
	}

	private var canCopy: Bool {
		item.listing?.app.availability().version != nil || InstallModel.isFromIPA(item.install)
	}
}

/// A sheet's title with a line under it: iOS 26's subtitle, or a title view
/// before.
struct TitleWithSubtitle: ViewModifier {
	let title: String
	let subtitle: String

	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			content
				.navigationTitle(title)
				.navigationSubtitle(Text(subtitle))
		} else {
			content
				.navigationTitle(title)
				.toolbar {
					ToolbarItem(placement: .principal) {
						VStack(spacing: 0) {
							Text(title)
								.font(.headline)
							Text(subtitle)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
		}
	}
}

/// Asks before Disable (#49), as it takes the app off the Home Screen. Make
/// Room doesn't ask again: its tap is the answer. The first time, it asks
/// about gaps too (`GapsQuestion`).
struct DisableConfirmation: ViewModifier {
	@Binding var item: LibraryItem?
	let actions: LibraryActions
	/// Mark Spaces to Keep's Open Spaces, which then offloads.
	@State private var marking: MarkGapsFirst?

	func body(content: Content) -> some View {
		content
			.alert(
				"Offload \(item?.install.name ?? "the app")?",
				isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
				presenting: item
			) { item in
				GapsQuestion.buttons("Offload", then: "Offload then keeps \(item.install.name)’s spot empty, and your open spaces too.", marking: $marking) {
					actions.disable(item)
				}
				Button("Cancel", role: .cancel) {}
			} message: { item in
				// Only a free Apple ID's apps hold one of its places (#49).
				let frees = item.appleID?.isFree == true ? " That frees one of the \(FreeAppleID.appsPerDevice) apps your free Apple ID can have here." : ""
				// An iPhone's pages keep the spot empty (6 Nov 2026).
				let spot = HomeScreenSpots.isOn && ThisDevice.name == "iPhone" ? " Its Home Screen spot stays empty meanwhile." : ""
				Text(GapsQuestion.adding(to: "Atelier takes it off this \(ThisDevice.name) and keeps its data until you reinstall it.\(frees)\(spot)", offload: true))
			}
			.yourGapsSheet($marking)
	}
}

/// Asks before signing an app for another App ID than the one it was
/// installed with (#76), from Custom Install… or an update whose
/// certificate is gone: iOS can't replace the app, so it's deleted first,
/// through Direct installs when set up, right before the install and with
/// its data kept (#96), or installed as a copy instead. Takes the models
/// rather than the environment, as it sits on the tab view that provides
/// them.
///
/// It says what happens to the app and its data rather than the App IDs
/// (5 Nov 2026). When Atelier can't delete the app itself, the user
/// deletes it first, losing its data, and the message ends with how
/// Atelier could keep it: finishing the setup, or trying again on Wi-Fi.
struct ReplaceConfirmation: ViewModifier {
	let installer: InstallModel
	let catalog: CatalogModel
	let certificates: CertificatesModel
	let downloads: DownloadManager
	@Environment(\.modelContext) private var context
	@State private var routeA = RouteASetup.shared
	/// Mark Spaces to Keep's Open Spaces, which then deletes and reinstalls.
	@State private var marking: MarkGapsFirst?

	func body(content: Content) -> some View {
		let request = installer.replaceRequests.first
		// Direct installs delete the app and install it again, keeping its
		// data, only on Wi-Fi: without it, iOS refuses their connection, and
		// Delete and Reinstall would fail.
		let keepsData = routeA.isSetUp && RouteANetwork.isOnWiFi
		let name = request?.install.name ?? "the app"
		content
			.alert(
				keepsData ? "Reinstall \(name)?" : "Delete \(name) first",
				// Only the request shown leaves the queue, however often the
				// alert reports its dismissal.
				isPresented: Binding(get: { request != nil }, set: { shown in
					if !shown, let request, installer.replaceRequests.first?.id == request.id { installer.replaceRequests.removeFirst() }
				}),
				presenting: request
			) { request in
				if keepsData {
					// The first time, it asks about gaps too (9 Nov 2026).
					GapsQuestion.buttons("Delete and Reinstall", role: .destructive, then: "Delete and Reinstall then puts \(request.install.name) back in its spot, and keeps your open spaces.", marking: $marking, cancel: { installer.dismiss(request) }) {
						installer.deleteAndReinstall(request, in: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
					}
				} else {
					Button(request.isFallback ? "Update" : "Sign Again") {
						installer.reinstall(request, in: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
					}
				}
				if installer.canInstallAsCopy(request, in: catalog.catalog) {
					Button("Install as a Copy") {
						installer.installAsCopy(request, in: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
					}
				}
				Button("Cancel", role: .cancel) { installer.dismiss(request) }
			} message: { request in
				Text(message(for: request, keepsData: keepsData))
			}
			.yourGapsSheet($marking)
	}

	private func message(for request: InstallModel.ReplaceRequest, keepsData: Bool) -> String {
		let name = request.install.name
		let certificate = request.certificateName
		// Not Custom Install's, which can install a newer version too (#155).
		let isUpdate = request.isFallback
		var text = isUpdate
			? "\(name)'s certificate can't be used any more, so the update is signed with \(certificate), which means deleting \(name) and installing it again."
			: "Signing \(name) with \(certificate) means deleting it and installing it again."
		text += keepsData
			? " It keeps its data, though you may need to sign in again."
			: " Delete it from the Home Screen first, which erases its data, then \(isUpdate ? "update it" : "sign it again")."
		let copy = installer.canInstallAsCopy(request, in: catalog.catalog)
			? (isUpdate ? "Or install the update as a second \(name) next to this one." : "Or install a second \(name) next to this one.")
			: nil
		// The gaps question goes before the copy, next to its button, the
		// first time (9 Nov 2026).
		if keepsData { return GapsQuestion.adding(to: text, last: copy) }
		if let copy { text += " \(copy)" }
		return text + (routeA.isSetUp
			? "\n\nTo keep its data, try again on Wi-Fi, where Atelier can reinstall it for you."
			: "\n\nTo keep its data, finish the setup in Settings › Installs, and Atelier can reinstall it for you.")
	}
}

/// Asks before Atelier installs over itself (#24), wherever that starts:
/// Update, Update All, Custom Install…, Re-sign or an IPA of Atelier,
/// saying it'll ask to go to the Home Screen, as iOS installs it only once
/// Atelier is no longer in front (#123). Says so instead, before anything
/// downloads, when none of the certificates signs for the App ID it was
/// installed with, or when the build is older than the one running. An IPA
/// of Atelier can install as a copy instead, in any case (#113).
///
/// When Atelier is one of an Apple ID's apps (#152), the question names the
/// Apple ID that signs it and what that takes of its App IDs, in place of
/// the sheet other apps get for a new one (decided 11 Nov 2026). When a free
/// Apple ID installed it and isn't signed in, it offers to sign in rather
/// than ask for a certificate nobody can export.
struct SelfInstallConfirmation: ViewModifier {
	let installer: InstallModel
	let certificates: CertificatesModel

	func body(content: Content) -> some View {
		let request = installer.selfRequests.first
		content
			.alert(
				request.map { title($0) } ?? "",
				// Only the request shown leaves the queue, however often the
				// alert reports its dismissal.
				isPresented: Binding(get: { request != nil }, set: { shown in
					if !shown, let request, installer.selfRequests.first?.id == request.id { installer.dismissSelf(request) }
				}),
				presenting: request
			) { request in
				switch request.kind {
				case .confirm:
					Button(Self.action(request.job.selfKind)) { installer.confirmSelf(request) }
					copyButton(request)
					Button("Cancel", role: .cancel) { installer.dismissSelf(request) }
				case .noCertificate:
					Button("Import Certificate") {
						installer.dismissSelf(request)
						certificates.beginImport()
					}
					copyButton(request)
					Button("OK", role: .cancel) { installer.dismissSelf(request) }
				case .needsAppleID:
					Button("Sign In with Apple ID") {
						installer.dismissSelf(request)
						certificates.beginSignIn()
					}
					copyButton(request)
					Button("OK", role: .cancel) { installer.dismissSelf(request) }
				case .older, .noAppIDLeft:
					copyButton(request)
					Button("OK", role: .cancel) { installer.dismissSelf(request) }
				}
			} message: { request in
				Text(message(for: request))
			}
	}

	private var name: String { SelfUpdate.shared.name }

	/// An IPA of Atelier can install as a copy, a second app next to it,
	/// instead (#113): also one it can't install over itself.
	@ViewBuilder
	private func copyButton(_ request: InstallModel.SelfRequest) -> some View {
		if request.copyJob != nil {
			Button("Install a Copy…") { installer.askForCopy(request) }
		}
	}

	/// "Update Atelier to 0.2.0-alpha?", "Can't update Atelier".
	private func title(_ request: InstallModel.SelfRequest) -> String {
		let job = request.job
		let version = job.selfVersion?.display ?? ""
		let certificate = request.certificateName ?? request.appleID ?? "another certificate"
		switch request.kind {
		case .confirm:
			switch job.selfKind {
			case .update: return "Update \(name) to \(version)?"
			case .install: return "Install \(name) \(version) again?"
			case .signAgain: return "Sign \(name) again with \(certificate)?"
			case .resign: return "Re-sign \(name) with \(certificate)?"
			}
		case .noCertificate, .needsAppleID, .noAppIDLeft:
			let yet = if case .noAppIDLeft = request.kind { " yet" } else { "" }
			switch job.selfKind {
			case .update: return "Can't update \(name)\(yet)"
			case .install: return "Can't install \(name) again\(yet)"
			case .signAgain: return "Can't sign \(name) again\(yet)"
			case .resign: return "Can't re-sign \(name)\(yet)"
			}
		case .older:
			return "Can't install \(name) \(version)"
		}
	}

	private static func action(_ kind: PendingSelfInstall.Kind) -> String {
		switch kind {
		case .update: "Update"
		case .install: "Install"
		case .signAgain: "Sign Again"
		case .resign: "Re-sign"
		}
	}

	private func message(for request: InstallModel.SelfRequest) -> String {
		let own = SelfUpdate.shared
		switch request.kind {
		case .confirm:
			var text = "Once it's ready, \(name) asks you to go to the Home Screen, as iOS only installs it after you leave. Your sources, certificates and Library stay as they are."
			switch installer.installsAhead {
			case 0: break
			case 1: text += " It starts once the install in progress has finished."
			case let count: text += " It starts once the \(count) installs in progress have finished."
			}
			// What signs it, first, when that's its Apple ID (#152).
			return appleIDLine(request).map { "\($0)\n\n\(text)" } ?? text
		case .needsAppleID:
			let verb = request.job.selfKind == .update ? "update itself" : "sign itself again"
			let text = "A free Apple ID installed \(name). Sign in with it, and \(name) can \(verb)."
			return request.copyJob == nil ? text : "\(text) Or install it as a copy, a second app next to this one."
		case .noAppIDLeft(let until):
			let left = until.map { "until \(AppProfileDays.describe($0))" } ?? "this week"
			let text = "\(name) signs itself with \(request.appleID ?? "its Apple ID"). Its App ID ended, and that Apple ID has no new ones left \(left)."
			return request.copyJob == nil ? text : "\(text) You can install it as a copy, a second app next to this one, instead."
		case .noCertificate:
			let verb = request.job.selfKind == .update ? "update itself" : "install over itself"
			let other = request.job.selfKind == .update ? "install the update" : "install it again"
			let text = "\(name) can only \(verb) with a certificate from the account it was installed with, and none of yours is. Import that certificate, or delete \(name) and \(other) another way, which erases its sources, certificates and Library."
			return request.copyJob == nil ? text : "\(text) Or install it as a copy, a second app next to this one."
		case .older:
			let running = own.build.map { "\(own.version) (\($0))" } ?? own.version
			let text = "It's older than the \(running) running now, and an older build may not read the data this one saved."
			return request.copyJob == nil ? text : "\(text) You can install it as a copy, a second app next to this one, instead."
		}
	}

	/// "Atelier signs it with name@example.com, using its App ID again.":
	/// the Apple ID that signs Atelier's own install (#152), and whether
	/// that takes one of the week's new App IDs, as it last said. Sign Again
	/// and Re-sign name the Apple ID in their title already.
	private func appleIDLine(_ request: InstallModel.SelfRequest) -> String? {
		guard let appleID = request.appleID else { return nil }
		let named = request.job.selfKind == .signAgain || request.job.selfKind == .resign
		switch request.appIDUse {
		case .again?:
			return named ? "It uses its App ID again." : "\(name) signs it with \(appleID), using its App ID again."
		case .new(let left)?:
			let takes = "Its App ID ended, so this takes \(left == 1 ? "the last new app" : "one of the \(left) new apps") left this week."
			return named ? takes : "\(name) signs it with \(appleID). \(takes)"
		case .noneLeft?, .unknown?, nil:
			return named ? nil : "\(name) signs it with \(appleID)."
		}
	}
}

/// Delete's confirmation for an installed app, worded by whether it's still
/// on this iPhone (#55). With Direct installs set up, it can also remove
/// the app, as the Home Screen does. `presence` is as of the Delete tap.
/// From a screen showing the app, `leaving` closes it before the record
/// goes.
struct DeleteAppDialog: ViewModifier {
	let install: InstallRecord
	let presence: AppPresence
	@Binding var isPresented: Bool
	var leaving: (() -> Void)?
	@Environment(\.modelContext) private var context
	@Environment(InstallModel.self) private var installer
	@State private var routeA = RouteASetup.shared
	@State private var uninstallProblem: String?

	func body(content: Content) -> some View {
		content
			.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) {
				buttons
			} message: {
				Text(message)
			}
			.alert("Couldn't delete the app", isPresented: Binding(
				get: { uninstallProblem != nil },
				set: { if !$0 { uninstallProblem = nil } }
			)) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(uninstallProblem ?? "")
			}
	}

	/// Route A can remove the app itself, as the Home Screen does, when it
	/// may still be there.
	private var offersUninstall: Bool {
		routeA.isPaired && presence != .deleted && !isDisabled
	}

	/// Off this iPhone with its data kept (#49).
	private var isDisabled: Bool {
		presence != .installed && installer.disabledApps[install.bundleID] != nil
	}

	private var title: String {
		offersUninstall || isDisabled ? "Delete \(install.name)?" : "Delete \(install.name) from the Library?"
	}

	private var message: String {
		if isDisabled { return "Atelier forgets \(install.name) and deletes the data it kept." }
		return switch (presence, routeA.isPaired) {
		case (.installed, true):
			"It's still on this \(ThisDevice.name). Delete the app and its data, as the Home Screen does, or only forget it in Atelier."
		case (.installed, false):
			"It's still on this \(ThisDevice.name). Atelier forgets it; to remove the app, delete it from the Home Screen."
		case (.deleted, _):
			"It's no longer on this \(ThisDevice.name). Atelier forgets it."
		case (.unknown, true):
			"Atelier can't tell whether it's still on this \(ThisDevice.name). Delete the app and its data, as the Home Screen does, or only forget it in Atelier."
		case (.unknown, false):
			"Atelier forgets it. If the app is still on your \(ThisDevice.name), it stays there; delete it from the Home Screen to remove it."
		}
	}

	@ViewBuilder
	private var buttons: some View {
		if offersUninstall {
			Button("Delete App and Data", role: .destructive) { uninstall() }
			Button("Delete from Library Only", role: .destructive) { delete() }
		} else if presence == .deleted || isDisabled {
			Button("Delete", role: .destructive) { delete() }
		} else {
			Button("Delete from Library", role: .destructive) { delete() }
		}
	}

	/// Removes the app from this iPhone through route A, then forgets it.
	private func uninstall() {
		let bundleID = install.bundleID
		Task {
			if let problem = await installer.uninstall(bundleID: bundleID) {
				uninstallProblem = problem
			} else {
				delete(removed: true)
			}
		}
	}

	/// Forgets an installed app and deletes its kept data (#96). Without
	/// route A, Atelier can't remove the app from the device. A screen
	/// showing it closes first, so nothing reads the deleted record.
	/// `removed` when route A just removed it.
	private func delete(removed: Bool = false) {
		let install = install
		let context = context
		let installer = installer
		// Off this iPhone, it no longer holds a free Apple ID's place (#49).
		let left = removed || presence == .deleted || isDisabled
		let forget = {
			if left { CertificatesModel.shared.appLeft(install.bundleID) }
			// The data kept for Put Back (#96).
			installer.deleteKeptData(of: install.bundleID)
			// What was chosen for it (#113, #155), and where its IPA is
			// (#113).
			CopyStore.shared.remove(install.numberedBundleID)
			IPAOrigins.shared.save(nil, for: install.bundleID)
			context.delete(install)
			try? context.save()
		}
		guard let leaving else { return forget() }
		leaving()
		Task {
			try? await Task.sleep(for: .milliseconds(600))
			forget()
		}
	}
}

/// The certificate that signed an installed app, as its row in Settings ›
/// Installs › Certificates looks; tapping it opens that certificate (#55).
/// An Apple ID shows the app's own profile's days, with when it ends, as
/// they end long before the Apple ID's certificate (#49). Atelier itself
/// without either shows the one in the profile it was installed with
/// (#113): a copy installed without its certificate, or Atelier installed
/// by another tool.
struct InstalledWithCard: View {
	let install: InstallRecord
	/// Off this iPhone with its data kept (#49), so no profile runs it.
	var disabled = false
	@Binding var shownCertificate: UUID?
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Installed with")
				.font(.subheadline)
				.foregroundStyle(.secondary)
			if let id = install.certificateID, let certificate = certificates.certificates.first(where: { $0.id == id }) {
				card(id) {
					CertificateRow(certificate: certificate, isDefault: certificates.defaultID == certificate.id)
				}
			} else if let account = certificates.appleID(install.certificateID) {
				let profile = account.profile(for: install.bundleID)
				card(account.id) {
					AppleIDInstalledRow(account: account, profile: profile, disabled: disabled)
				}
				if !disabled, let profile {
					Text(Self.profileNote(profile, of: account, name: install.name, isOwn: SelfUpdate.shared.isOwn(install)))
						.font(.footnote)
						.foregroundStyle(.secondary)
						// Its whole height once it grows longer, as when the
						// profile ends while the page shows (10 Nov 2026).
						.fixedSize(horizontal: false, vertical: true)
				}
			} else if SelfUpdate.shared.isOwn(install), let profile = SelfUpdate.shared.installedProfile {
				// A free Apple ID that isn't signed in here (#152): nothing
				// renews Atelier until it is.
				let need = SelfUpdate.shared.needsAppleID(in: certificates)
				InstalledProfileRow(profile: profile, isFreeAppleID: need != nil)
					.padding(.horizontal, 12)
					.padding(.vertical, 8)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
				if let need {
					Text(Self.signInNote(need.expires, hasOthers: need.hasOthers, name: install.name))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					Button("Sign In with Apple ID") { certificates.beginSignIn() }
						.font(.subheadline.weight(.semibold))
						.buttonStyle(.borderless)
				}
			} else if install.ipaBundleID != install.appBundleID {
				// Its Apple ID was signed out of (#49).
				Text("An Apple ID you signed out of")
					.font(.subheadline)
			} else {
				Text(install.certificateID == nil ? "Not recorded" : "A certificate that has since been deleted")
					.font(.subheadline)
			}
		}
	}

	/// "Its profile ends on Sun 15 Nov at 18:05. Atelier renews it on Fri
	/// 13 Nov, without reinstalling. Last renewed on Sun 8 Nov." (#49)
	///
	/// `isOwn` for Atelier itself (#152), which renews four days ahead.
	static func profileNote(_ profile: AppProfile, of account: StoredAppleID, name: String, isOwn: Bool = false, now: Date = .now) -> String {
		let signIn = AppProfileRenewal.needsSignIn(account, now: now)
		var lines: [String] = []
		if profile.expires <= now {
			let until = signIn ? "you sign in with its Apple ID again" : "it’s renewed"
			lines.append("Its profile ended on \(AppProfileDays.describe(profile.expires)), so \(name) doesn’t open until \(until).")
		} else {
			lines.append("Its profile ends on \(AppProfileDays.describe(profile.expires)).")
			let renews = ProfileRenewals.date(toRenew: profile, of: account, isOwn: isOwn)
			if signIn {
				lines.append("It renews once you sign in with its Apple ID again.")
			} else if renews > now {
				lines.append("Atelier renews it \(AppProfileDays.day(renews, now: now)), without reinstalling.")
			} else {
				lines.append("Atelier renews it while LocalDevVPN is connected, without reinstalling.")
			}
		}
		if let renewed = profile.renewedAt {
			lines.append("Last renewed \(AppProfileDays.day(renewed, now: now)).")
		}
		return lines.joined(separator: " ")
	}

	/// Atelier's own page, while the free Apple ID that installed it isn't
	/// signed in (#152): "A free Apple ID installed Atelier, so its profile
	/// ends on Wed 18 Nov at 10:42 and Atelier stops opening then. Sign in
	/// with that Apple ID, and Atelier renews itself every week."
	static func signInNote(_ expires: Date?, hasOthers: Bool, name: String) -> String {
		let ends = expires.map { "so its profile ends on \(AppProfileDays.describe($0)) and \(name) stops opening then" }
			?? "so its profile lasts 7 days and \(name) stops opening once it has ended"
		let which = hasOthers ? "Another Apple ID than yours installed \(name)" : "A free Apple ID installed \(name)"
		return "\(which), \(ends). Sign in with that Apple ID\(hasOthers ? " too" : ""), and \(name) renews itself every week."
	}

	/// A card that opens the certificate's or Apple ID's page.
	private func card<Row: View>(_ id: UUID, @ViewBuilder row: () -> Row) -> some View {
		Button { shownCertificate = id } label: {
			HStack(spacing: 8) {
				row()
					// The card's whole width, also without a validity bar to stretch it (#104).
					.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.tertiary)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
		.buttonStyle(.plain)
	}
}

/// The certificate Atelier was installed with, from the profile in its app,
/// while it isn't imported here (#113): its name when the profile lists only
/// that one, else its team's, and how long it has left.
private struct InstalledProfileRow: View {
	let profile: ProvisioningProfile
	/// A free Apple ID's profile (#152), whose certificate can't be
	/// imported: signing in with it is what's left.
	var isFreeAppleID = false

	/// The certificate the profile lists, when it lists only one.
	private var listed: SigningCertificate? {
		guard profile.developerCertificates.count == 1 else { return nil }
		return try? SigningCertificate(der: profile.developerCertificates[0])
	}

	var body: some View {
		let single = listed
		let expiry = CertificateExpiry(certificate: single?.notAfter ?? profile.expirationDate, profile: profile.expirationDate)
		HStack(spacing: 12) {
			RoundedRectangle(cornerRadius: 44 * 0.26, style: .continuous)
				.fill(Color(.systemGray3))
				.frame(width: 44, height: 44)
				.overlay {
					Image(systemName: profile.kind.symbol)
						.font(.system(size: 44 * 0.45, weight: .semibold))
						.foregroundStyle(.white)
				}
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 4) {
				Text(single.map { Self.name(of: $0) } ?? profile.teamName ?? profile.name)
					.font(.headline)
					.lineLimit(1)
				Text("\(isFreeAppleID ? "A free Apple ID" : "Not imported here") · \(Self.remaining(expiry))")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.accessibilityElement(children: .combine)
	}

	/// Its name without Apple's "Apple Development: " style prefix, as
	/// `StoredCertificate.originalName` has it.
	private static func name(of certificate: SigningCertificate) -> String {
		let name = certificate.commonName
		guard let colon = name.firstIndex(of: ":") else { return name }
		return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
	}

	/// "287 days left", "Less than a day left", "Expired".
	private static func remaining(_ expiry: CertificateExpiry) -> String {
		switch expiry.daysLeft(now: .now) {
		case 0: "Expired"
		case 1: "Less than a day left"
		case let days: "\(days) days left"
		}
	}
}

/// Pull to refresh lists this iPhone's apps through Direct installs, once
/// it's set up (#17).
struct DeviceScanRefresh: ViewModifier {
	let enabled: Bool
	let scan: () async -> Void

	@ViewBuilder
	func body(content: Content) -> some View {
		if enabled {
			content.refreshable { await scan() }
		} else {
			content
		}
	}
}

/// Update All's apps (#18), kept together in the Updates section while
/// they download and install, so they move into Installed at once when
/// the last is done, as the maintainer asked.
struct UpdateGroup: Equatable {
	/// Installs' bundle IDs, in the order they were queued.
	private(set) var bundleIDs: [String] = []
	/// The version each is updating to.
	private(set) var versions: [String: AppVersion] = [:]
	/// The downloads Update All started, shown in the rows rather than
	/// in Downloads.
	private(set) var downloadIDs: Set<UUID> = []

	mutating func add(_ bundleID: String, version: AppVersion, download: UUID) {
		bundleIDs.append(bundleID)
		versions[bundleID] = version
		downloadIDs.insert(download)
	}

	func contains(_ bundleID: String) -> Bool { versions[bundleID] != nil }

	/// Where one app of the group is at.
	enum Phase {
		case running(InstallStage)
		/// Queued; its download's fraction while it's still downloading.
		case waiting(InstallModel.Job, downloading: Double?, downloaded: Bool)
		case updated
		case failed
	}

	@MainActor
	func phase(of item: LibraryItem, installer: InstallModel, downloads: DownloadManager) -> Phase {
		switch installer.status(of: item.appKey) {
		case .running(let stage)?:
			return .running(stage)
		case .waiting(let job)?:
			let download = versions[item.install.bundleID].flatMap { version in
				item.listing.flatMap { downloads.download(of: version, sourceURL: $0.source.url) }
			}
			let finished = download?.status == .finished
			let fraction = download.flatMap { $0.status == .downloading ? (downloads.progress[$0.id]?.fraction ?? 0) : nil }
			return .waiting(job, downloading: fraction, downloaded: finished)
		case nil:
			return item.update == nil ? .updated : .failed
		}
	}
}

/// An app's row while Update All runs (#18): "1.7.2 → 1.8", its stage, and
/// on the right its progress ring (tap to cancel it), Waiting (tap to take
/// it off the queue), a tick once updated, or Update to try again.
struct UpdateGroupRow: View {
	let item: LibraryItem
	let version: AppVersion
	let phase: UpdateGroup.Phase
	let sourceName: String
	let installer: InstallModel
	let tryAgain: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			SourceIcon(url: item.iconURL, tint: item.tint, size: 48)
			VStack(alignment: .leading, spacing: 2) {
				Text(item.install.name)
					.font(.headline)
					.lineLimit(1)
				Text("\(versions) · \(sourceName)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				stageLine
			}
			Spacer(minLength: 8)
			trailing
		}
		.padding(.vertical, 2)
	}

	/// "1.7.2 → 1.8" until it's updated, then the version it's on.
	private var versions: String {
		if case .updated = phase { return item.installedDisplayVersion }
		return "\(item.installedDisplayVersion) → \(version.displayVersion)"
	}

	@ViewBuilder
	private var stageLine: some View {
		switch phase {
		case .running where item.isOwn && installer.isHandingOver:
			// iOS has Atelier's own update (#24).
			SelfInstallLine(text: "Go to the Home Screen to finish", handingOver: true)
		case .running(let stage):
			Text(Self.describe(stage))
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .waiting(_, let fraction?, _):
			Text("Downloading… \(Int(fraction * 100))%")
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .waiting(let job, nil, let downloaded) where job.isSelf:
			// After every other install (#24).
			SelfInstallLine(text: InstallModel.goesLast(job.selfKind, downloaded: downloaded), handingOver: false)
		case .waiting(_, nil, let downloaded):
			Text(downloaded ? "Downloaded, waiting" : "Waiting")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .updated:
			Label("Updated", systemImage: "checkmark")
				.font(.caption.weight(.medium))
				.foregroundStyle(.green)
		case .failed:
			Text("Didn't update")
				.font(.caption.weight(.medium))
				.foregroundStyle(.red)
		}
	}

	@ViewBuilder
	private var trailing: some View {
		switch phase {
		case .running where item.isOwn && installer.isHandingOver:
			// Nothing to stop: iOS has it (#24).
			EmptyView()
		case .running(let stage):
			Button { installer.cancel() } label: {
				GroupRing(fraction: stage == .checking ? nil : stage.overallFraction)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Cancel update")
		case .waiting(let job, let fraction?, _):
			Button { installer.remove(job) } label: { GroupRing(fraction: fraction) }
				.buttonStyle(.plain)
				.accessibilityLabel("Take off the install queue")
		case .waiting(let job, nil, _):
			Button("Waiting") { installer.remove(job) }
				.font(.subheadline.bold())
				.buttonStyle(.bordered)
				.buttonBorderShape(.capsule)
				.accessibilityHint("Takes the app off the install queue.")
		case .updated:
			Image(systemName: "checkmark")
				.font(.body.bold())
				.foregroundStyle(.green)
				.frame(width: 30, height: 30)
		case .failed:
			LibraryButton(action: .update, perform: tryAgain)
		}
	}

	/// The stage of an app's install, as its row says it; also Re-sign
	/// All's (#20).
	static func describe(_ stage: InstallStage) -> String {
		switch stage {
		case .checking: "Checking…"
		case .downloading(let fraction?): "Downloading… \(Int(fraction * 100))%"
		case .downloading(nil): "Downloading…"
		case .signing: "Signing…"
		// Around a reinstall that keeps the app's data (#96).
		case .installing(_, .copyingData(let fraction?)): "Copying its data… \(Int(fraction * 100))%"
		case .installing(_, .copyingData(nil)): "Copying its data…"
		case .installing(_, .restoringData(let fraction?)): "Putting its data back… \(Int(fraction * 100))%"
		case .installing(_, .restoringData(nil)): "Putting its data back…"
		case .installing: "Installing…"
		case .finished: "Finishing…"
		case .failed: "Didn't update"
		case .cancelled: "Cancelled"
		}
	}
}

/// The progress ring of an app in Update All's or Re-sign All's group, with
/// a stop sign: tapping it stops the app's install or download.
struct GroupRing: View {
	let fraction: Double?

	var body: some View {
		ZStack {
			ProgressRing(fraction: fraction)
			Image(systemName: "stop.fill")
				.font(.system(size: 9))
				.foregroundStyle(Color.accentColor)
		}
		.frame(width: 30, height: 30)
		.contentShape(Circle())
	}
}

/// Re-sign All's apps (#20), kept together in the Re-sign section while
/// they download and install, as Update All's are (#18). Each moves into
/// Installed once it's re-signed; one that failed stays, with why.
struct ResignGroup: Equatable {
	/// Installs' bundle IDs, in the order they were queued.
	private(set) var bundleIDs: [String] = []
	/// Each app's install, by bundle ID.
	private(set) var jobIDs: [String: String] = [:]
	/// The version each downloads from its source; none for Atelier, which
	/// signs itself as it runs (#24).
	private(set) var versions: [String: AppVersion] = [:]
	/// The download Re-sign All started for each app, shown in its row
	/// rather than in Downloads.
	private(set) var downloadsByApp: [String: UUID] = [:]

	var downloadIDs: Set<UUID> { Set(downloadsByApp.values) }

	mutating func add(_ bundleID: String, job: String, version: AppVersion?, download: UUID?) {
		bundleIDs.append(bundleID)
		jobIDs[bundleID] = job
		versions[bundleID] = version
		downloadsByApp[bundleID] = download
	}

	func contains(_ bundleID: String) -> Bool { jobIDs[bundleID] != nil }

	/// Where one app of the group is at.
	enum Phase {
		case running(InstallStage)
		/// Queued; its download's fraction while it's still downloading.
		case waiting(InstallModel.Job, downloading: Double?, downloaded: Bool)
		case resigned
		/// Why, when that's known; not when it was cancelled.
		case failed(String?)
	}

	@MainActor
	func phase(of item: LibraryItem, installer: InstallModel, downloads: DownloadManager) -> Phase? {
		guard let job = jobIDs[item.install.bundleID] else { return nil }
		switch installer.status(ofJob: job) {
		case .running(let stage)?:
			return .running(stage)
		case .waiting(let waiting)?:
			let download = downloadsByApp[item.install.bundleID].flatMap { downloads.download(id: $0) }
			let fraction = download.flatMap { $0.status == .downloading ? (downloads.progress[$0.id]?.fraction ?? 0) : nil }
			return .waiting(waiting, downloading: fraction, downloaded: download?.status == .finished)
		case nil:
			if let why = installer.failures[job] { return .failed(why) }
			return item.needsResign ? .failed(nil) : .resigned
		}
	}

	/// Whether no app of the group is waiting or installing.
	@MainActor
	func isDone(installer: InstallModel) -> Bool {
		jobIDs.values.allSatisfy { installer.status(ofJob: $0) == nil }
	}
}

/// An app's row while Re-sign All runs (#20), as Update All's: its version
/// and source, its stage, and on the right its progress ring (tap to cancel
/// it), Waiting (tap to take it off the queue), a tick once re-signed, or
/// Re-sign to try again.
struct ResignGroupRow: View {
	let item: LibraryItem
	let phase: ResignGroup.Phase
	/// The version it downloads; none for Atelier, which signs itself as
	/// it runs (#24).
	let version: AppVersion?
	let sourceName: String
	let installer: InstallModel
	let tryAgain: () -> Void

	var body: some View {
		HStack(spacing: 12) {
			SourceIcon(url: item.iconURL, tint: item.tint, size: 48)
			VStack(alignment: .leading, spacing: 2) {
				Text(item.install.name)
					.font(.headline)
					.lineLimit(1)
				Text("\(versions) · \(sourceName)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				stageLine
			}
			Spacer(minLength: 8)
			trailing
		}
		.padding(.vertical, 2)
	}

	/// The installed version, or "0.6.4 → 0.7" when its source no longer
	/// lists it, so it gets the newest.
	private var versions: String {
		if case .resigned = phase { return item.installedDisplayVersion }
		guard let version, version.version != item.install.version else { return item.installedDisplayVersion }
		return "\(item.installedDisplayVersion) → \(version.displayVersion)"
	}

	@ViewBuilder
	private var stageLine: some View {
		switch phase {
		case .running where item.isOwn && installer.isHandingOver:
			// iOS has Atelier, re-signed (#24).
			SelfInstallLine(text: "Go to the Home Screen to finish", handingOver: true)
		case .running(let stage):
			Text(UpdateGroupRow.describe(stage))
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .waiting(_, let fraction?, _):
			Text("Downloading… \(Int(fraction * 100))%")
				.font(.caption.weight(.medium))
				.foregroundStyle(.tint)
		case .waiting(let job, nil, _) where job.isSelf:
			// After every other install (#24).
			SelfInstallLine(text: InstallModel.goesLast(job.selfKind, downloaded: false), handingOver: false)
		case .waiting(_, nil, let downloaded):
			Text(downloaded ? "Downloaded, waiting" : "Waiting")
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
		case .resigned:
			Label("Re-signed", systemImage: "checkmark")
				.font(.caption.weight(.medium))
				.foregroundStyle(.green)
		case .failed(let why):
			ResignNoteLabel(note: ResignNote(kind: .failed(why), canResign: true), attention: nil)
		}
	}

	@ViewBuilder
	private var trailing: some View {
		switch phase {
		case .running where item.isOwn && installer.isHandingOver:
			// Nothing to stop: iOS has it (#24).
			EmptyView()
		case .running(let stage):
			Button { installer.cancel() } label: {
				GroupRing(fraction: stage == .checking ? nil : stage.overallFraction)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Cancel re-signing")
		case .waiting(let job, let fraction?, _):
			Button { installer.remove(job) } label: { GroupRing(fraction: fraction) }
				.buttonStyle(.plain)
				.accessibilityLabel("Take off the install queue")
		case .waiting(let job, nil, _):
			Button("Waiting") { installer.remove(job) }
				.font(.subheadline.bold())
				.buttonStyle(.bordered)
				.buttonBorderShape(.capsule)
				.accessibilityHint("Takes the app off the install queue.")
		case .resigned:
			Image(systemName: "checkmark")
				.font(.body.bold())
				.foregroundStyle(.green)
				.frame(width: 30, height: 30)
		case .failed:
			LibraryButton(action: .resign, perform: tryAgain)
		}
	}
}

/// Re-signing that would delete apps first, asked about before it starts
/// (#20): the certificate re-signing uses signs for other App IDs than
/// theirs, so iOS can't replace them (#76).
struct ResignConfirmation {
	/// The apps that are deleted first: with their data copied aside and
	/// put back through Direct installs (#96), else losing it.
	let losing: [LibraryItem]
	/// The others of Re-sign All, which are installed over the old ones.
	let keeping: [LibraryItem]
	let target: StoredCertificate
	/// Why one app's data couldn't be copied when it was last re-signed,
	/// so it wasn't deleted (#96): Re-sign then asks about that instead.
	var dataFailure: AppDataCopyFailure?

	/// From Re-sign All rather than one app's Re-sign.
	var isAll: Bool { losing.count + keeping.count > 1 }
}

/// Asks before re-signing apps that are deleted first (#20). With Direct
/// installs, each is deleted right before its install, once it's signed
/// and its data copied aside, and the data is put back (#96); without,
/// they're to be deleted from the Home Screen first, and lose their data.
/// After an app's data couldn't be copied, it asks whether to try again
/// or go on without its data. `start` re-signs the apps given with the
/// certificate given, deleting first those whose bundle IDs it's given,
/// and keeping their data unless told not to.
struct ResignConfirmationAlert: ViewModifier {
	@Binding var confirmation: ResignConfirmation?
	let start: (_ items: [LibraryItem], _ target: StoredCertificate, _ deletingFirst: Set<String>, _ keepingData: Bool) -> Void
	@State private var routeA = RouteASetup.shared
	/// Mark Spaces to Keep's Open Spaces, which then deletes and re-signs.
	@State private var marking: MarkGapsFirst?

	func body(content: Content) -> some View {
		content
			.alert(
				title,
				isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
				presenting: confirmation
			) { confirmation in
				let target = confirmation.target
				let deleting = Set(confirmation.losing.map(\.install.bundleID))
				if routeA.isPaired, let failure = confirmation.dataFailure {
					switch failure {
					case .brokeOff, .notEnoughSpace:
						Button("Try Again") { start(confirmation.losing, target, deleting, true) }
					case .refused:
						EmptyView()
					}
					Button("Delete and Re-sign", role: .destructive) { start(confirmation.losing, target, deleting, false) }
				} else if routeA.isPaired {
					// The first time, it asks about gaps too (9 Nov 2026).
					let one = confirmation.losing.count == 1
					GapsQuestion.buttons(
						confirmation.isAll ? "Delete and Re-sign All" : "Delete and Re-sign",
						role: .destructive,
						then: one ? "Re-sign then puts \(confirmation.losing[0].install.name) back in its spot, and keeps your open spaces." : "Re-sign then puts them back in their spots, and keeps your open spaces.",
						marking: $marking
					) {
						start(confirmation.losing + confirmation.keeping, target, deleting, true)
					}
				} else if !confirmation.isAll {
					// Once it's been deleted from the Home Screen.
					Button("Re-sign") { start(confirmation.losing, target, [], true) }
				}
				if !confirmation.keeping.isEmpty {
					Button(confirmation.keeping.count == 1 ? "Re-sign the Other App" : "Re-sign the Other \(confirmation.keeping.count)") {
						start(confirmation.keeping, target, [], true)
					}
				}
				if !routeA.isPaired, confirmation.isAll, confirmation.keeping.isEmpty {
					Button("OK", role: .cancel) {}
				} else {
					Button("Cancel", role: .cancel) {}
				}
			} message: { confirmation in
				let text = message(for: confirmation)
				Text(routeA.isPaired && confirmation.dataFailure == nil ? GapsQuestion.adding(to: text, count: confirmation.losing.count) : text)
			}
			.yourGapsSheet($marking)
	}

	/// "Radiance will be reinstalled", "2 apps will be reinstalled" with
	/// Direct installs (#96); "Radiance will lose its data", "2 apps will
	/// lose their data" without; "Radiance's data couldn't be copied".
	private var title: String {
		guard let confirmation else { return "" }
		let losing = confirmation.losing
		let one = losing.count == 1
		guard routeA.isPaired else {
			return one ? "\(losing[0].install.name) will lose its data" : "\(losing.count) apps will lose their data"
		}
		if confirmation.dataFailure != nil, one { return "\(losing[0].install.name)'s data couldn't be copied" }
		return one ? "\(losing[0].install.name) will be reinstalled" : "\(losing.count) apps will be reinstalled"
	}

	private func message(for confirmation: ResignConfirmation) -> String {
		let losing = confirmation.losing
		let target = confirmation.target.displayName
		let one = losing.count == 1
		let names = losing.map(\.install.name).formatted(.list(type: .and))
		if routeA.isPaired, one, let failure = confirmation.dataFailure {
			return Self.message(for: failure, name: names)
		}
		if routeA.isPaired {
			// Every app keeps its data, so the others aren't named (#96).
			return one
				? "To re-sign it with \(target), Atelier deletes \(names) and installs it again. It keeps its data, though you may need to sign in again."
				: "To re-sign them with \(target), Atelier deletes \(names) and installs them again. They keep their data, though you may need to sign in again."
		}
		var text = one
			? "To re-sign it with \(target), \(names) has to be deleted and installed again."
			: "To re-sign them with \(target), \(names) have to be deleted and installed again."
		if confirmation.isAll {
			text += one
				? " Delete it from the Home Screen first, then install it again from the Library."
				: " Delete them from the Home Screen first, then install them again from the Library."
		} else {
			text += " Delete it from the Home Screen first, then re-sign it."
		}
		switch confirmation.keeping.count {
		case 0: break
		case 1: text += " \(confirmation.keeping[0].install.name) keeps its data."
		case let count: text += " The other \(count) apps keep their data."
		}
		return text
	}

	/// Why the app's data couldn't be copied last time, and what's left.
	private static func message(for failure: AppDataCopyFailure, name: String) -> String {
		switch failure {
		case .brokeOff:
			"Copying \(name)'s data was interrupted, so it wasn't deleted. Try again, or delete it and install it again without its data."
		case .refused:
			"iOS doesn't let Atelier copy \(name)'s data, so it wasn't deleted. Delete it and install it again without its data?"
		case .notEnoughSpace:
			"Copying it would leave less than \(ByteCountFormatter.string(fromByteCount: AppDataCopy.spareSpace, countStyle: .file)) free on this \(ThisDevice.name), so \(name) wasn't deleted. Free up some space and try again, or delete it and install it again without its data."
		}
	}
}

/// Asks before putting an app's kept data back into it (#96), as it
/// replaces whatever the app has saved since it was reinstalled; Delete
/// Kept Data deletes it instead.
struct PutBackConfirmation: ViewModifier {
	@Binding var item: LibraryItem?
	let actions: LibraryActions

	func body(content: Content) -> some View {
		content
			.alert(
				title,
				isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
				presenting: item
			) { item in
				Button("Put Back") { actions.putBack(item) }
				Button("Delete Kept Data", role: .destructive) { actions.installer.deleteKeptData(of: item.install.bundleID) }
				Button("Cancel", role: .cancel) {}
			} message: { item in
				Text(message(for: item))
			}
	}

	/// "Put back Accountit's data?"
	private var title: String {
		item.map { "Put back \($0.install.name)'s data?" } ?? ""
	}

	/// "Atelier kept the data it copied on 27 Oct at 10:42. …"
	private func message(for item: LibraryItem) -> String {
		let name = item.install.name
		let copied: String = actions.installer.keptDataInfo(of: item.install.bundleID).map { copy in
			"Atelier kept the data it copied on \(copy.copiedAt.formatted(.dateTime.day().month(.abbreviated))) at \(copy.copiedAt.formatted(date: .omitted, time: .shortened))."
		} ?? "Atelier kept the data it copied."
		return "\(copied) Putting it back replaces whatever \(name) has saved since it was reinstalled, so close \(name) first if it's open."
	}
}
