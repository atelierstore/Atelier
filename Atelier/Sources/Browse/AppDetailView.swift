import CertKit
import DownloadKit
import InstallKit
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI
import UIKit

/// An app's page (#14), the same from Browse, search, a source's apps and
/// the Library (#81): the app as its source lists it and, once Atelier has
/// installed it, the install on this iPhone. The header has the Install
/// button, the source, while the app is installed the certificate it was
/// installed with, its copies (#113), and the app's description; then what
/// can be done with the install, screenshots, what's new and information
/// from the source, what the app was signed as (#8) and its permissions
/// (#7).
///
/// The Install button shows what it will do (Install, Update, Open or Not
/// Installable). Install and Update run the one-tap install (#16) of the
/// newest version this device can run from the selected source. Once the
/// app is installed, the Library's update rules (#18) decide whether
/// there's an update, and installing goes over the app, as itself or the
/// copy it is. Any version can also be downloaded on its own (#15), here or
/// in Version History, and installed once it's downloaded.
///
/// Without a source listing, for an IPA file or an app its source no longer
/// lists, the page has the header, the actions, the install and its
/// permissions.
struct AppDetailView: View {
	/// How Browse, search or a source's apps linked the app; nil from the
	/// Library.
	private let link: AppLink?
	/// From the Library, how the source it was installed from links the
	/// app, for once it's deleted from another of its pages.
	private let listing: AppLink?
	/// The bundle ID of the install the page shows: the Library's app's, or
	/// from Browse the one its sources list, which its IPA may not have
	/// (#116).
	private let bundleID: String
	/// The bundle ID its sources list it under.
	private let sourceBundleID: String
	/// Opens the apps of the source at a URL on the tab's path, from the
	/// source chip.
	private let openSource: (URL) -> Void
	/// Opens the page of another install of the app on the tab's path, a
	/// copy or the app itself, from the copies in the header (#113).
	private let openInstall: (LibraryLink) -> Void
	@Environment(CatalogModel.self) private var model
	@Environment(CertificatesModel.self) private var certificates
	@Environment(InstallModel.self) private var installer
	@Environment(\.dismiss) private var dismiss
	/// Read so whether the app is still installed is checked again on coming
	/// back to Atelier, after it may have been deleted from the Home Screen.
	@Environment(\.scenePhase) private var scenePhase
	/// The install the page shows: the app itself from Browse, or the
	/// Library's app, which can be a copy (#8).
	@Query private var installs: [InstallRecord]
	/// The app and its copies (#8), for the permissions they were signed
	/// with, and the copies in the header (#113).
	@Query private var installsAndCopies: [InstallRecord]
	@State private var sourceURL: URL?
	/// Set as the page closes after Delete, so nothing reads the record.
	@State private var deleted = false

	init(link: AppLink, openSource: @escaping (URL) -> Void, openInstall: @escaping (LibraryLink) -> Void) {
		// Atelier, from its source, is the one running, whatever bundle ID
		// it runs as (#24).
		let bundleID = SelfUpdate.shared.isOwnApp(link.bundleID) ? SelfUpdate.shared.bundleID : link.bundleID
		self.init(link: link, bundleID: bundleID, sourceBundleID: link.bundleID, openSource: openSource, openInstall: openInstall)
	}

	/// An app in the Library, which can be a copy or an IPA file.
	init(library app: LibraryLink, openSource: @escaping (URL) -> Void, openInstall: @escaping (LibraryLink) -> Void) {
		self.init(link: nil, listing: app.listing, bundleID: app.bundleID, sourceBundleID: app.sourceBundleID, openSource: openSource, openInstall: openInstall)
	}

	private init(link: AppLink?, listing: AppLink? = nil, bundleID: String, sourceBundleID: String, openSource: @escaping (URL) -> Void, openInstall: @escaping (LibraryLink) -> Void) {
		self.link = link
		self.listing = listing
		self.bundleID = bundleID
		self.sourceBundleID = sourceBundleID
		self.openSource = openSource
		self.openInstall = openInstall
		let prefix = "\(sourceBundleID)."
		if link == nil {
			_installs = Query(filter: #Predicate<InstallRecord> { $0.bundleID == bundleID })
		} else {
			// Also the app installed under its IPA's bundle ID, when its
			// source lists it under another (#116).
			_installs = Query(filter: #Predicate<InstallRecord> { $0.bundleID == bundleID || $0.originalBundleID == sourceBundleID })
		}
		_installsAndCopies = Query(filter: #Predicate<InstallRecord> { $0.bundleID == sourceBundleID || $0.bundleID.starts(with: prefix) || $0.originalBundleID == sourceBundleID }, sort: \.installedAt, order: .reverse)
		_sourceURL = State(initialValue: link?.sourceURL)
	}

	/// From the latest install of the app or a copy of it that kept them.
	private var installedPermissions: SignedPermissions? {
		installsAndCopies.lazy
			.filter { $0.sourceBundleID == sourceBundleID }
			.compactMap(\.signedPermissions)
			.first
	}

	var body: some View {
		let _ = scenePhase
		let catalog = model.catalog
		// The app itself, not a copy of it.
		let install = installs.first { $0.bundleID == bundleID } ?? installs.first { $0.target == .original }
		// Where it was installed from, as that source lists it now.
		let installedFrom = install.flatMap { InstallModel.listing(of: $0, in: catalog) }
		// The Library's app once it's deleted from another of its pages, as
		// the source it was installed from lists it: the page then shows it
		// as that one does, with Install, rather than nothing (30 Oct).
		let listed = install == nil ? listing : nil
		let entry = (link ?? listed).flatMap { catalog.entry(id: $0.appID) } ?? installedFrom.flatMap { catalog.entry(id: $0.app.id) }
		// The source picked or linked, else the one it was installed from,
		// also once it's deleted, else the one with the newest version.
		let offer = entry?.offer(from: sourceURL ?? installedFrom?.source.url ?? listed?.sourceURL)
		let item = install.map { LibraryItem($0, catalog: catalog, certificates: certificates, installer: installer, showing: offer) }
		// Its other installs (#113): the app's copies, or a copy's app and
		// its other copies, the app first.
		let otherInstalls = installsAndCopies
			.filter { $0.sourceBundleID == sourceBundleID && $0.bundleID != install?.bundleID }
			.sorted { Self.number($0.target) < Self.number($1.target) }
		if deleted {
			Color.clear
		} else if entry != nil || item != nil {
			AppDetailContent(entry: entry, offer: offer, sourceURL: $sourceURL, item: item, otherInstalls: otherInstalls, installedPermissions: installedPermissions, leaving: leaving, openSource: openSource, openInstall: openInstall)
		} else if link == nil {
			// The Library's app was deleted: a copy, an IPA file, or an app
			// its source no longer lists.
			Color.clear
		} else if model.isLoaded {
			ContentUnavailableView(
				"App not found",
				systemImage: "questionmark.app",
				description: Text("None of your sources lists this app any more.")
			)
		} else {
			ProgressView()
		}
	}

	/// From the Library, the page closes after Delete, before the record
	/// goes; from Browse, it stays, as the page of an app that isn't
	/// installed.
	private var leaving: (() -> Void)? {
		guard link == nil else { return nil }
		return {
			deleted = true
			dismiss()
		}
	}

	/// The app counts as the first, and its copies from 2 (#8).
	private static func number(_ target: InstallTarget) -> Int {
		if case .copy(let number) = target { return number }
		return 1
	}
}

private struct AppDetailContent: View {
	let entry: Catalog.Entry?
	/// The listing shown; nil for an IPA file or an app its source no longer
	/// lists.
	let offer: Catalog.Offer?
	@Binding var sourceURL: URL?
	/// The install, compared with the listing shown; nil when Atelier
	/// hasn't installed the app.
	let item: LibraryItem?
	/// The app's copies, or a copy's app and its other copies (#113).
	let otherInstalls: [InstallRecord]
	let installedPermissions: SignedPermissions?
	/// Closes the page after Delete; nil keeps it open.
	let leaving: (() -> Void)?
	let openSource: (URL) -> Void
	let openInstall: (LibraryLink) -> Void
	@Query private var sourceRecords: [SourceRecord]
	@Environment(CertificatesModel.self) private var certificates
	@Environment(CatalogModel.self) private var catalog
	@Environment(DownloadManager.self) private var downloads
	@Environment(InstallModel.self) private var installer
	@Environment(SourcesModel.self) private var sources
	@Environment(\.modelContext) private var context
	/// Install Older Version's All Versions (#78).
	@State private var showingVersionHistory = false
	/// The certificate whose details "Installed with" opened.
	@State private var shownCertificate: UUID?
	@State private var confirmingDelete = false
	@State private var deletePresence = AppPresence.unknown
	/// Disable, waiting to be confirmed (#49).
	@State private var confirmingDisable: LibraryItem?
	/// The older version Install Older Version asks about (#78).
	@State private var confirmingOlder: AppVersion?

	private var actions: LibraryActions {
		LibraryActions(installer: installer, catalog: catalog.catalog, downloads: downloads, certificates: certificates, context: context)
	}

	/// The source's name for the app, or a copy's own (#8), or the one
	/// chosen for the app in Custom Install… (#155).
	private var name: String {
		if let item, offer == nil || item.install.target != .original || item.install.copySettings?.name != nil { return item.install.name }
		return offer?.app.name ?? ""
	}

	var body: some View {
		List {
			Section {
				header
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
			}
			if let item {
				actionsSection(item)
			}
			if let offer {
				listingSections(offer)
			}
			if let item {
				installedSection(item)
			}
			permissionsSection
		}
		.navigationTitle(name)
		.navigationBarTitleDisplayMode(.inline)
		.navigationDestination(isPresented: $showingVersionHistory) {
			if let offer {
				VersionHistoryView(app: offer.app, source: offer.source)
			}
		}
		.navigationDestination(item: $shownCertificate) { id in
			// An Apple ID has a page of its own (#49).
			if certificates.appleID(id) != nil {
				AppleIDDetailView(accountID: id)
			} else {
				CertificateDetailView(certificateID: id)
			}
		}
		.modifier(DisableConfirmation(item: $confirmingDisable, actions: actions))
		.confirmationDialog(
			olderVersionTitle,
			isPresented: Binding { confirmingOlder != nil } set: { if !$0 { confirmingOlder = nil } },
			titleVisibility: .visible,
			presenting: confirmingOlder
		) { version in
			if let item {
				Button("Install \(version.releaseName)") { actions.installOlder(item, version: version) }
			}
			Button("Cancel", role: .cancel) {}
		} message: { _ in
			if let item {
				Text(olderVersionMessage(item))
			}
		}
	}

	// MARK: Header

	/// A neutral card: the app's colour stays in its icon, and the source's
	/// in its chip on the Source row. The icon is as tall as the name,
	/// developer, two lines of subtitle and the button beside it.
	@ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 118

	private var header: some View {
		let app = offer?.app
		let action = installAction
		let deleted = item?.presence == .deleted
		return VStack(alignment: .leading, spacing: 12) {
			// One line each for the name and developer and up to two for the
			// subtitle, as tall as the icon, so Install sits level with its
			// bottom whatever the source wrote. The long description is at
			// the bottom of the card.
			HStack(alignment: .top, spacing: 16) {
				// The icon iOS shows for the installed app, however the
				// page was opened, which its source may not list (#118).
				// Atelier knows its own icon, also once its source no
				// longer lists it (#24), and a copy's tint or picture
				// (#113).
				if item?.disabled != nil {
					// Off this iPhone, its data kept (#49).
					DisabledAppIcon(url: item?.installedIconURL ?? app?.iconURL ?? item?.iconURL, tint: app?.tintColor, size: iconSize)
				} else {
					SourceIcon(url: item?.installedIconURL ?? app?.iconURL ?? item?.iconURL, tint: app?.tintColor, size: iconSize)
						.opacity(deleted ? 0.45 : 1)
				}
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 6) {
						Text(name)
							.font(.title2.bold())
							.lineLimit(1)
							.minimumScaleFactor(0.8)
						// Also while a beta is installed, as the Library marks it (#104).
						if app?.isBetaRelease == true || item?.release.isBeta == true { BetaTag() }
					}
					if let developer = app?.developerName {
						Text(developer)
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					if let subtitle = app?.subtitle {
						Text(subtitle)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.lineLimit(2)
					}
					Spacer(minLength: 4)
					button(action)
				}
				.frame(minHeight: iconSize, alignment: .topLeading)
			}
			if let item {
				Text(item.versionLine)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			if case .notInstallable(let reason)? = action {
				Label(reason.message, systemImage: "exclamationmark.circle")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Divider()
			sourceRow
			// What its source listed last, as it needs a GitHub sign-in
			// (#134).
			if let source = signInSource {
				GitHubSignInNotice(sourceURL: source.url, sourceName: source.name, page: .app)
					.padding([.horizontal, .top], 12)
					.padding(.bottom, 4)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
			}
			if let item, item.showsUnlisted, let unlisted = item.unlisted {
				unlistedCard(item, unlisted: unlisted)
			}
			if let item, let other = item.elsewhere {
				otherSourceCard(other, item: item)
			}
			// Whenever the app is still on this iPhone (#55), also while an
			// update is offered, and while it's disabled (#49).
			if let item, !deleted || item.disabled != nil {
				Divider()
				InstalledWithCard(install: item.install, disabled: item.disabled != nil, shownCertificate: $shownCertificate)
			}
			// Each opens its own page, on the tab's path as the source chip
			// does (#113).
			if !otherInstalls.isEmpty {
				Divider()
				CopiesCard(installs: otherInstalls) { openInstall(LibraryLink($0, in: catalog.catalog)) }
			}
			// Last, with a label like Installed with's.
			if let description = app?.localizedDescription, !description.isEmpty {
				Divider()
				VStack(alignment: .leading, spacing: 8) {
					Text("About")
						.font(.subheadline)
						.foregroundStyle(.secondary)
					ExpandableText(text: description, lineLimit: 6)
				}
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
	}

	/// What the Install button does with the listing shown: once the app is
	/// installed, the Library's update rules (#18) decide. Nil without a
	/// listing.
	private var installAction: InstallAction? {
		guard let offer else { return nil }
		if let item, item.presence != .deleted {
			if let update = item.update { return .update(update) }
			// Atelier is open already (#24).
			return item.isOwn ? nil : .open
		}
		return InstallAction(availability: offer.app.availability(), installedVersion: nil)
	}

	@ViewBuilder
	private func button(_ action: InstallAction?) -> some View {
		if let item, item.disabled != nil {
			// Where Open was, for an app Disable took off this iPhone (#49).
			LibraryButton(action: .enable, status: installer.status(of: item.appKey)) { actions.enable(item) }
		} else if let action, let entry, let offer {
			InstallButton(app: offer.app, action: action, sourceURL: offer.source.url, offers: entry.offers, installed: item?.install)
		} else if let item, item.presence != .deleted, !item.isOwn {
			// Without a listing, there's only Open (#55).
			LibraryButton(action: .open) { InstallModel.open(item.install) }
				.disabled(!item.canOpen)
		}
	}

	/// Where the app comes from. With several sources, a menu switches between
	/// them, each with its latest version; Atelier starts on the one it was
	/// installed from, else the newest. Without a listing, the source it was
	/// installed from, by name once it's removed; for an IPA from a link,
	/// the link's site (#113), else "IPA file".
	private var sourceRow: some View {
		HStack(spacing: 8) {
			Text("Source")
				.foregroundStyle(.secondary)
			if let source = shownSource {
				// Opens the source's apps, as its card in Browse does, on the
				// tab's path: pushed from this page instead, the source's
				// apps froze Atelier (30 Oct).
				Button { openSource(source.url) } label: {
					SourceChip(source: source)
				}
				.buttonStyle(.borderless)
				.tint(.primary)
				.accessibilityHint("Shows this source's apps.")
				// The source's name before the menu's words.
				.layoutPriority(1)
				Spacer(minLength: 4)
				if source.url == SelfUpdate.sourceURL {
					Text("Built in")
						.font(.footnote)
						.foregroundStyle(.secondary)
				} else if let offer, let entry, entry.offers.count > 1, item?.isOwn != true {
					// Atelier updates from its own source (#24).
					sourceMenu(entry, offer: offer)
				}
			} else if let item {
				if InstallModel.isFromIPA(item.install), let link = installer.ipaLink(of: item.install.bundleID) {
					IPALinkSource(link: link)
				} else {
					Text(sourceName(of: item.install))
				}
			}
		}
		.font(.subheadline)
	}

	/// The listing's source, or the one the app was installed from while
	/// that source no longer lists it (#104): still one of the sources, so
	/// still its chip.
	private var shownSource: Catalog.SourceInfo? {
		offer?.source ?? item?.install.sourceURL.flatMap { catalog.catalog.source(url: $0)?.source }
	}

	/// The source the page shows, or the app was installed from, while it
	/// needs a GitHub sign-in (#134), with its name: one that never loaded
	/// lists nothing yet.
	private var signInSource: (url: URL, name: String)? {
		guard let url = shownSource?.url ?? item?.install.sourceURL, sources.needsGitHubSignIn(url) else { return nil }
		let name = shownSource?.name ?? sourceRecords.first { $0.url == url }?.name ?? url.host ?? "its source"
		return (url, name)
	}

	private func sourceMenu(_ entry: Catalog.Entry, offer: Catalog.Offer) -> some View {
		Menu {
			Picker("Source", selection: Binding(
				get: { offer.source.url },
				set: { sourceURL = $0 }
			)) {
				ForEach(entry.offers) { offer in
					Text("\(offer.source.name) · \(offer.app.latestVersion?.displayVersion ?? "No versions")")
						.tag(offer.source.url)
				}
			}
		} label: {
			HStack(spacing: 4) {
				ViewThatFits(in: .horizontal) {
					Text("Change source (\(entry.offers.count))")
					Text("Change (\(entry.offers.count))")
				}
				Image(systemName: "chevron.right")
					.font(.caption.weight(.semibold))
			}
			.font(.footnote)
			.lineLimit(1)
		}
	}

	/// A newer version in another source: only ever suggested (#18).
	/// Updating from there makes that source the app's source.
	private func otherSourceCard(_ other: LibraryItem.OtherSourceUpdate, item: LibraryItem) -> some View {
		let own = item.update ?? item.skippedUpdate
		let comparison = own.map { "newer than this source's \($0.displayVersion)" } ?? "newer than the installed \(item.installedDisplayVersion)"
		return VStack(alignment: .leading, spacing: 8) {
			Text("\(other.offer.source.name) lists \(name) \(other.version.displayVersion), \(comparison).")
				.font(.subheadline)
			Button("Update from \(other.offer.source.name)") { actions.update(item, from: other) }
				.font(.subheadline.weight(.semibold))
				.buttonStyle(.borderless)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
	}

	/// The source it was installed from no longer lists the installed
	/// version, or the app (#104), so Atelier can't sign it again: said
	/// plainly, after that it still opens while it does (29 Oct).
	/// Atelier itself still signs itself again, but gets no updates (#24).
	private func unlistedCard(_ item: LibraryItem, unlisted: LibraryItem.Unlisted) -> some View {
		let what = unlisted.listsApp ? "\(unlisted.appName) \(item.install.version)" : unlisted.appName
		let effect = "Atelier can't download, sign or install it again."
		return VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
				// Its source is named Atelier too.
				Text(item.isOwn ? "Its source no longer lists \(what)" : "\(unlisted.source.name) no longer lists \(what)")
			}
			.font(.subheadline.weight(.semibold))
			Group {
				if item.isOwn {
					Text(sources.listsPrereleases(unlisted.source.url) ? "You can still sign it again." : "You can still sign it again, but it won't get updates while its source's pre-releases are off.")
				} else {
					Text(item.certificateIsDead ? effect : "You can still open and use it, but \(effect)")
				}
			}
			.font(.footnote)
			.foregroundStyle(.secondary)
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
	}

	/// Where it was installed from, by name.
	private func sourceName(of install: InstallRecord) -> String {
		guard let url = install.sourceURL else { return "IPA file" }
		return sourceRecords.first { $0.url == url }?.name ?? "Removed source"
	}

	// MARK: Actions (#17)

	@ViewBuilder
	private func actionsSection(_ item: LibraryItem) -> some View {
		if item.disabled != nil {
			disabledActions(item)
		} else {
			installedActions(item)
		}
	}

	/// An offloaded app's (#49): Reinstall; Install a Copy…, which leaves
	/// it offloaded, so a copy takes one place on this iPhone rather than
	/// the app's and the copy's (4 Nov 2026); and Delete, which
	/// forgets it and deletes its kept data.
	private func disabledActions(_ item: LibraryItem) -> some View {
		Section {
			Button("Reinstall", systemImage: "icloud.and.arrow.down") { actions.enable(item) }
			InstallCopyButton(item: item)
			Button("Delete", systemImage: "trash", role: .destructive) {
				deletePresence = InstallModel.presence(of: item.install)
				confirmingDelete = true
			}
			.modifier(DeleteAppDialog(install: item.install, presence: deletePresence, isPresented: $confirmingDelete, leaving: leaving))
		} header: {
			Text("Actions")
		} footer: {
			Text(offloadedNotes(item).joined(separator: "\n\n"))
		}
		.labelStyle(.titleOnly)
	}

	/// Under an offloaded app's actions: where Install a Copy… gets an IPA
	/// app's IPA, what a copy is and takes, and what Delete does.
	private func offloadedNotes(_ item: LibraryItem) -> [String] {
		let name = item.install.name
		let copy = copyTakesFreePlace
			? "A copy is another \(name) next to this one, with its own data. It takes one of the \(FreeAppleID.appsPerDevice) apps on this \(ThisDevice.name) and one of the new apps allowed this week, and \(name) stays offloaded."
			: "A copy is another \(name) next to this one, with its own data, and \(name) stays offloaded."
		let notes = [copy, "Delete forgets \(name) and deletes the data Atelier kept."].joined(separator: " ")
		return InstallModel.isFromIPA(item.install) ? [ipaNote(for: item.install, offloaded: true), notes] : [notes]
	}

	/// A new copy is signed with what's in use, rather than with what the
	/// app was installed with: a free Apple ID's takes one of its places
	/// on this iPhone and one of its new apps allowed this week (#49).
	private var copyTakesFreePlace: Bool {
		certificates.defaultAppleID?.isFree == true
	}

	private func installedActions(_ item: LibraryItem) -> some View {
		Section {
			installedActionButtons(item)
		} header: {
			Text("Actions")
		} footer: {
			let notes = actionNotes(item)
			if !notes.isEmpty {
				Text(notes.joined(separator: "\n\n"))
			}
		}
		.labelStyle(.titleOnly)
	}

	@ViewBuilder
	private func installedActionButtons(_ item: LibraryItem) -> some View {
		// At the top, for an app installed with an Apple ID (#49).
		if ProfileRenewals.shared.canRenew(item) {
			if ProfileRenewals.shared.isRenewing(item.install.bundleID) {
				HStack(spacing: 10) {
					ProgressView()
					Text("Renewing…")
						.foregroundStyle(.secondary)
				}
			} else {
				Button("Renew Now", systemImage: "arrow.triangle.2.circlepath") { actions.renew(item) }
					// It has to sign in again first, which the note says.
					.disabled(item.appleID.map { AppProfileRenewal.needsSignIn($0) } ?? true)
			}
		}
		if let update = item.update {
			Button("Skip \(update.displayVersion)", systemImage: "forward.end") { actions.skip(item) }
		} else if let skipped = item.skippedUpdate {
			Button("Update to \(skipped.displayVersion)", systemImage: "arrow.down.circle") { actions.update(item) }
			Button("Don't Skip \(skipped.displayVersion)", systemImage: "arrow.uturn.backward") { actions.unskip(item) }
		}
		olderVersionMenu(item)
		CustomInstallButton(item: item, inMenu: false)
		// Any app but Atelier, as iOS's Offload App (#49).
		if item.canDisable {
			Button("Offload", systemImage: "arrow.down.app") { confirmingDisable = item }
		}
		// Atelier can't delete itself (#24).
		if !item.isOwn {
			Button("Delete", systemImage: "trash", role: .destructive) {
				deletePresence = InstallModel.presence(of: item.install)
				confirmingDelete = true
			}
			// On the button, so on iOS 26 the dialog's popover points at it.
			.modifier(DeleteAppDialog(install: item.install, presence: deletePresence, isPresented: $confirmingDelete, leaving: leaving))
		}
	}

	/// Under the actions: where an app installed from an IPA gets it, and
	/// what Custom Install… needs while there's no certificate to sign with
	/// (#113), as in a copy of Atelier installed without one; and what a
	/// copy takes of a free Apple ID's limits (#49).
	private func actionNotes(_ item: LibraryItem) -> [String] {
		var notes: [String] = []
		if let note = renewNote(item) { notes.append(note) }
		if InstallModel.isFromIPA(item.install) { notes.append(ipaNote(for: item.install)) }
		// An Apple ID signs it too (#49).
		if item.canCustomInstall, certificates.certificates.isEmpty, certificates.appleIDs.isEmpty {
			// Atelier knows which one it was installed with, from its profile.
			let example = item.isOwn && SelfUpdate.shared.installedProfile != nil ? ", such as the one \(item.install.name) was installed with" : ""
			notes.append("Custom Install… needs a certificate. Import one in Settings › Installs › Certificates\(example).")
		}
		if copyTakesFreePlace {
			notes.append("A copy takes another of the \(FreeAppleID.appsPerDevice) apps on this \(ThisDevice.name), and another of the new apps allowed this week.")
		}
		return notes
	}

	/// What Renew Now does (#49): "Renew Now gets Atlas a new 7-day
	/// profile from Apple and puts it on. Nothing downloads, and Atlas
	/// keeps its data." Or why Atelier didn't renew it by itself, when
	/// that's not LocalDevVPN being off.
	private func renewNote(_ item: LibraryItem) -> String? {
		guard ProfileRenewals.shared.canRenew(item), let account = item.appleID else { return nil }
		let name = item.install.name
		if let problem = ProfileRenewals.shared.problems[item.install.bundleID], !problem.isUnreachable {
			return problem.message(isOwn: item.isOwn)
		}
		if AppProfileRenewal.needsSignIn(account) {
			return ProfileRenewals.Problem.signInAgain.message
		}
		let profile = account.isFree ? "a new 7-day profile" : "a new profile"
		// Atelier itself isn't reinstalled either, so it stays open (#152).
		let keeps = item.isOwn ? "stays open" : "keeps its data"
		return "Renew Now gets \(name) \(profile) from Apple and puts it on. Nothing downloads, and \(name) \(keeps)."
	}

	/// Under the actions of an app installed from an IPA (#113): where
	/// Custom Install… gets it, and while its link downloads again for it,
	/// how far it is. An offloaded app has Install a Copy… instead (#49).
	private func ipaNote(for install: InstallRecord, offloaded: Bool = false) -> String {
		let uses = offloaded ? "Install a Copy…" : CustomInstall.title
		if let id = installer.ipaDownloadID(of: install), let download = downloads.download(id: id), download.status == .downloading {
			let site = IPAOrigins.site(of: download.url)
			guard let progress = downloads.progress[id], progress.received > 0 else { return "Downloading its IPA from \(site)…" }
			let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
			guard let expected = progress.expected else { return "Downloading its IPA from \(site): \(received)" }
			return "Downloading its IPA from \(site): \(received) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
		}
		guard let link = installer.ipaLink(of: install.bundleID) else {
			return "Atelier doesn't know where \(install.name)'s IPA is, so \(uses) asks you for it."
		}
		return "\(uses) downloads it again from \(IPAOrigins.site(of: link)) while the link works."
	}

	/// Install Older Version (#78): the listing's versions older than the
	/// installed one that this device can run, newest first, then the rest
	/// in Version History.
	@ViewBuilder
	private func olderVersionMenu(_ item: LibraryItem) -> some View {
		let older = item.olderVersions
		if let listing = item.listing, !older.isEmpty {
			Menu {
				Section("From \(listing.source.name)") {
					ForEach(Array(older.prefix(5).enumerated()), id: \.offset) { _, version in
						Button {
							confirmingOlder = version
						} label: {
							Text(version.releaseName)
							if let date = version.date {
								Text(date, format: .dateTime.day().month(.abbreviated).year())
							}
						}
					}
				}
				Button("All Versions…") { showingVersionHistory = true }
			} label: {
				Label("Install Older Version", systemImage: "clock.arrow.circlepath")
			}
		}
	}

	private var olderVersionTitle: String {
		confirmingOlder.map { "Install \(name) \($0.releaseName)?" } ?? ""
	}

	private func olderVersionMessage(_ item: LibraryItem) -> String {
		// The Apple ID it was installed with too (#49).
		let signer = item.certificateIsDead ? certificates.inUseName : item.certificateName ?? certificates.inUseName
		var message = "It replaces the installed \(item.installedDisplayVersion) and keeps the app's data. Some apps can't read data saved by a newer version."
		if let signer { message += " Signed with \(signer)." }
		return message
	}

	// MARK: From the source

	/// Screenshots, what's new and information, as the listing has them;
	/// the description is in the header.
	@ViewBuilder
	private func listingSections(_ offer: Catalog.Offer) -> some View {
		let app = offer.app
		if !app.screenshots.isEmpty {
			Section {
				ScreenshotsView(app: app, tint: SourceTint(hex: app.tintColor ?? offer.source.tintColor, url: offer.source.url).color)
					.listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
			}
		}
		// An update's notes, then any permission it newly asks for; the
		// update can be older than the newest version, a beta or one this
		// iPhone can't run.
		if let version = item?.update ?? app.latestVersion {
			Section {
				VersionNotes(version: version, isBeta: app.isBeta(version))
				if let item, let update = item.update, !item.newPermissions.isEmpty {
					newPermissionsRow(update, item: item)
				}
				NavigationLink("Version History") {
					VersionHistoryView(app: app, source: offer.source)
				}
			} header: {
				Text("What's New")
			}
		}
		informationSection(offer)
	}

	/// The privacy permissions the update asks for that the installed build
	/// wasn't signed with (#18).
	private func newPermissionsRow(_ update: AppVersion, item: LibraryItem) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Version \(update.displayVersion) asks for permissions version \(item.installedDisplayVersion) didn't:")
				.font(.footnote)
				.foregroundStyle(.secondary)
			// On one line when they fit.
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 6) { capsules(item.newPermissions) }
				VStack(alignment: .leading, spacing: 6) { capsules(item.newPermissions) }
			}
		}
		.padding(.vertical, 2)
	}

	private func capsules(_ names: [String]) -> some View {
		ForEach(names, id: \.self) { name in
			Text(name)
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.orange)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(.orange.opacity(0.15), in: Capsule())
		}
	}

	private func informationSection(_ offer: Catalog.Offer) -> some View {
		let app = offer.app
		let availability = app.availability()
		return Section("Information") {
			LabeledContent("Source", value: offer.source.name)
			if let developer = app.developerName {
				LabeledContent("Developer", value: developer)
			}
			if let latest = app.latestVersion {
				LabeledContent("Version", value: latest.displayVersion)
				if let size = latest.size {
					LabeledContent("Size", value: size.formatted(.byteCount(style: .file)))
				}
			}
			LabeledContent("Compatibility", value: Self.compatibility(availability))
			LabeledContent("Category", value: app.category.title)
			LabeledContent("Bundle ID") {
				Text(app.bundleID)
					.textSelection(.enabled)
			}
			if let version = availability.version {
				DownloadVersionButton(app: app, version: version, sourceURL: offer.source.url)
			}
		}
	}

	private static func compatibility(_ availability: AppAvailability) -> String {
		switch availability {
		case .installable(let version):
			switch (version.minOSVersion, version.maxOSVersion) {
			case let (min?, max?): "iOS \(min) to \(max)"
			case let (min?, nil): "iOS \(min) or later"
			case let (nil, max?): "iOS \(max) or earlier"
			case (nil, nil): "Any iOS version"
			}
		case .notInstallable(let reason):
			switch reason {
			case .unsupportedOS(let min?, _): "Requires iOS \(min) or later"
			case .unsupportedOS(nil, let max?): "Requires iOS \(max) or earlier"
			case .unsupportedOS(nil, nil): "No version for this iOS"
			case .alternativeDistributionOnly: "AltStore PAL only"
			case .patreonOnly: "Patrons only"
			}
		}
	}

	// MARK: The install

	/// What the app was installed and signed as (#8). The Source row says
	/// where it's from, unless it shows another source.
	private func installedSection(_ item: LibraryItem) -> some View {
		let install = item.install
		return Section("Installed") {
			LabeledContent("Version", value: item.installedDisplayVersion)
			LabeledContent("Installed", value: install.installedAt.formatted(date: .abbreviated, time: .shortened))
			if let offer, offer.source.url != install.sourceURL {
				LabeledContent("From", value: sourceName(of: install))
			}
			// Information has the app's own.
			if offer?.app.bundleID != install.bundleID {
				LabeledContent("Bundle ID") {
					Text(install.bundleID).textSelection(.enabled)
				}
			}
			if case .copy(let number) = install.target {
				LabeledContent("Copy", value: "\(number) of \(install.appBundleID)")
			}
			LabeledContent("App ID") {
				Text(install.applicationIdentifier ?? "Not recorded").textSelection(.enabled)
			}
			if let team = install.teamID {
				LabeledContent("Team", value: team)
			}
		}
	}

	/// As the app was signed (#7), else what the source lists; installs from
	/// before their permissions were kept show what won't work in them.
	@ViewBuilder
	private var permissionsSection: some View {
		if let permissions = item?.install.signedPermissions {
			PermissionsList(
				privacy: permissions.namedPrivacy,
				capabilities: permissions.entitlements?.capabilities ?? [],
				notes: permissions.entitlements?.notes ?? [],
				checked: permissions.checked
			)
		} else if let offer {
			PermissionsSection(permissions: offer.app.permissions, installed: installedPermissions)
		} else if let item {
			Section {
				ForEach(oldLimits(of: item.install), id: \.self) { limit in
					Text(limit)
				}
				Text("Install it again to see its permissions here.")
					.foregroundStyle(.secondary)
			} header: {
				Text("Permissions")
			} footer: {
				Text(PermissionsList.why)
			}
		}
	}

	/// What won't work, for installs from before their permissions were
	/// kept: from the record, or the latest install history entry that says.
	private func oldLimits(of install: InstallRecord) -> [String] {
		if let limits = install.limits { return limits }
		let bundleID = install.bundleID
		return (try? InstallHistory.standard())?.attempts()
			.first { $0.bundleID == bundleID && $0.limits != nil }?
			.limits ?? []
	}
}

/// The app's other installs, in the header of its page after the
/// certificate (#113): its copies, or on a copy's page the app and its
/// other copies, each with its version and the certificate it was installed
/// with, as the Library lists them. Tapping one opens its page.
private struct CopiesCard: View {
	let installs: [InstallRecord]
	let open: (InstallRecord) -> Void
	@Environment(CatalogModel.self) private var catalog
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Installed Copies")
				.font(.subheadline)
				.foregroundStyle(.secondary)
			VStack(spacing: 0) {
				ForEach(installs) { install in
					if install.persistentModelID != installs.first?.persistentModelID {
						// Under the names, as in a list.
						Divider()
							.padding(.leading, 68)
					}
					row(install)
				}
			}
			.background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
	}

	private func row(_ install: InstallRecord) -> some View {
		let deleted = InstallModel.presence(of: install) == .deleted
		return Button { open(install) } label: {
			HStack(spacing: 12) {
				SourceIcon(url: iconURL(of: install), tint: nil, size: 44)
					.opacity(deleted ? 0.45 : 1)
				VStack(alignment: .leading, spacing: 2) {
					Text(install.name)
						.font(.headline)
						.foregroundStyle(deleted ? .secondary : .primary)
						.lineLimit(1)
					Text(detail(install, deleted: deleted))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.tertiary)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	/// "3.3.0 · Signulous Development", or once it's deleted, says so.
	private func detail(_ install: InstallRecord, deleted: Bool) -> String {
		let certificate = install.certificateID.flatMap { id in
			certificates.certificates.first { $0.id == id }?.displayName ?? certificates.retired[id]?.name
		}
		let state = deleted ? "Deleted from this \(ThisDevice.name)" : certificate
		return [install.version, state].compactMap { $0 }.joined(separator: " · ")
	}

	/// The icon iOS shows for it, from the IPA Atelier signed (#118), else
	/// its source's. Atelier knows its own (#24), a copy's tint or picture
	/// too, which its source doesn't have (#113).
	private func iconURL(of install: InstallRecord) -> URL? {
		InstalledIcons.shared.url(for: install.bundleID)
			?? (SelfUpdate.shared.isOwn(install) ? SelfUpdate.shared.iconURL : nil)
			?? InstallModel.listing(of: install, in: catalog.catalog)?.app.iconURL
	}
}

/// A version's number, date, size and release notes. What's New names it
/// as its app does, with the tag it was released as when that says more;
/// Version History, a view of the releases, by that tag (#104).
private struct VersionNotes: View {
	let version: AppVersion
	/// Whether BETA follows the number: the version is a beta, or its app
	/// is, as Include Pre-releases sees it (#104).
	let isBeta: Bool
	/// The notes' lines before More.
	var lineLimit = 4
	/// Named as Version History names it.
	var byRelease = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			VStack(alignment: .leading, spacing: 2) {
				HStack {
					Text("Version \(byRelease ? version.releaseName : version.displayVersion)")
						.font(.subheadline.bold())
					// Also a pre-release whose tag doesn't say so (#104).
					if isBeta { BetaTag() }
					Spacer()
					if let date = version.date {
						Text(date, format: .dateTime.day().month(.abbreviated).year())
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				if !byRelease, let tag = version.tag, tag != version.version {
					Label("Released as \(tag)", systemImage: "tag")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			if let notes = version.localizedDescription, !notes.isEmpty {
				ExpandableText(text: notes, lineLimit: lineLimit)
			}
		}
		.padding(.vertical, 2)
	}
}

/// Every version from the selected source, newest first, with its notes,
/// size and required iOS, and an Install button for each one this device
/// can install (#78). A source's betas, while its pre-releases are listed,
/// are among its releases, each with BETA (#104).
struct VersionHistoryView: View {
	let app: SourceApp
	let source: Catalog.SourceInfo
	@Environment(SourcesModel.self) private var sources

	var body: some View {
		List {
			// What the source listed last, as it needs a GitHub sign-in
			// (#134).
			if sources.needsGitHubSignIn(source.url) {
				Section {
					GitHubSignInNotice(sourceURL: source.url, sourceName: source.name, page: .versions)
						.listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
						.listRowBackground(ZStack {
							Color(.secondarySystemGroupedBackground)
							Color.orange.opacity(0.12)
						})
				}
			}
			Section {
				ForEach(Array(app.versions.enumerated()), id: \.offset) { row($0.element) }
			}
		}
		.listSectionSpacing(.compact)
		.navigationTitle("Version History")
	}

	/// Notes cut to two lines, as AltStore's, then the size line with
	/// Install or Installed on it, their bottoms aligned.
	private func row(_ version: AppVersion) -> some View {
		let installable = app.downloadKind(of: version) == .ipa && version.supports(.current)
		return VStack(alignment: .leading, spacing: 6) {
			VersionNotes(version: version, isBeta: app.isBeta(version), lineLimit: 2, byRelease: true)
			HStack(alignment: .bottom, spacing: 8) {
				VStack(alignment: .leading, spacing: 4) {
					if let details = Self.details(of: version) {
						Text(details)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if app.downloadKind(of: version) != .ipa {
						Label("Not an IPA Atelier can install", systemImage: "xmark.circle")
							.labelStyle(InlineLabelStyle())
							.font(.caption)
							.foregroundStyle(.secondary)
					} else if !version.supports(.current) {
						Label("Doesn't support this iOS version", systemImage: "xmark.circle")
							.labelStyle(InlineLabelStyle())
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer(minLength: 8)
				if installable {
					InstallVersionButton(app: app, version: version, sourceURL: source.url)
						.font(.subheadline)
				}
			}
		}
	}

	private static func details(of version: AppVersion) -> String? {
		var parts: [String] = []
		if let size = version.size { parts.append(size.formatted(.byteCount(style: .file))) }
		if let min = version.minOSVersion { parts.append("iOS \(min)+") }
		if let max = version.maxOSVersion { parts.append("up to iOS \(max)") }
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}

/// What the app says it uses, from its source: privacy permissions with its
/// reasons, and capabilities, with whether the default certificate's profile
/// supports each (#7). That's a forecast from the keys the source lists;
/// signing checks the app's own entitlements again. Many sources list
/// none, and then it's what the app had when Atelier last signed it, if
/// it's installed, checked again against the default certificate's profile,
/// which may not be the one it was signed with.
private struct PermissionsSection: View {
	let permissions: AppPermissions
	let installed: SignedPermissions?
	@Environment(CertificatesModel.self) private var certificates

	private var forecast: EntitlementsReport? {
		guard !permissions.entitlements.isEmpty, let profile = certificates.defaultCertificate?.profile else { return nil }
		return EntitlementsReport.predict(sourceKeys: permissions.entitlements, profileKeys: Set(profile.entitlements.keys), profileTeamID: profile.teamID)
	}

	private var sourceListsNone: Bool {
		permissions.privacy.isEmpty && EntitlementsReport.unchecked(sourceKeys: permissions.entitlements).isEmpty
	}

	var body: some View {
		if sourceListsNone {
			if let installed {
				let keys = installed.entitlements?.items.map(\.key) ?? []
				if let profile = certificates.defaultCertificate?.profile {
					PermissionsList(
						privacy: installed.namedPrivacy,
						capabilities: EntitlementsReport.predict(sourceKeys: keys, profileKeys: Set(profile.entitlements.keys), profileTeamID: profile.teamID).capabilities,
						checked: "The source doesn't list them, so these are from the installed app, checked against your certificate. Atelier checks the app again when it signs it."
					)
				} else {
					PermissionsList(
						privacy: installed.namedPrivacy,
						capabilities: EntitlementsReport.unchecked(sourceKeys: keys),
						checked: "The source doesn't list them, so these are from the installed app. Add a certificate to see which of these it allows."
					)
				}
			} else {
				Section {
					Text("The source doesn't list this app's permissions. Atelier reads them from the app when it signs it, and shows them here and in the Library once it's installed.")
						.foregroundStyle(.secondary)
				} header: {
					Text("Permissions")
				} footer: {
					Text(PermissionsList.why)
				}
			}
		} else if let forecast {
			PermissionsList(
				privacy: permissions.namedPrivacy,
				capabilities: forecast.capabilities,
				checked: "From what the source lists, checked against your certificate. Atelier checks the app itself again when it signs it."
			)
		} else {
			PermissionsList(
				privacy: permissions.namedPrivacy,
				capabilities: EntitlementsReport.unchecked(sourceKeys: permissions.entitlements),
				checked: "From what the source lists. Add a certificate to see which of these it allows."
			)
		}
	}
}

/// Text cut to `lineLimit` lines, its Markdown shown, with More at the end
/// of the last line when the limit cuts it, as AltStore's notes have it
/// (#104).
private struct ExpandableText: View {
	let text: String
	let lineLimit: Int
	@State private var expanded = false
	@State private var shownHeight: CGFloat = 0
	@State private var fullHeight: CGFloat = 0

	var body: some View {
		let notes = Text(MarkdownNotes.attributed(text))
		notes
			.font(.subheadline)
			.lineLimit(expanded ? nil : lineLimit)
			// More at the row's edge.
			.frame(maxWidth: .infinity, alignment: .leading)
			.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
			// The whole text, unseen, to tell whether the limit cuts it.
			.background(alignment: .topLeading) {
				notes
					.font(.subheadline)
					.fixedSize(horizontal: false, vertical: true)
					.hidden()
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
			}
			.overlay(alignment: .bottomTrailing) {
				if !expanded, fullHeight > shownHeight + 1 {
					Button("More") { expanded = true }
						.font(.subheadline)
						.buttonStyle(.borderless)
						// The cut line fades out under it.
						.padding(.leading, 28)
						.background {
							LinearGradient(
								stops: [.init(color: rowBackground.opacity(0), location: 0), .init(color: rowBackground, location: 0.45)],
								startPoint: .leading,
								endPoint: .trailing
							)
						}
				}
			}
	}

	private var rowBackground: Color { Color(.secondarySystemGroupedBackground) }
}

/// The apps of the source at `url`, from the source chip in app details.
struct SourceAppsLoader: View {
	let url: URL
	@Query private var sources: [SourceRecord]

	var body: some View {
		if let source = sources.first(where: { $0.url == url }) {
			SourceAppsView(source: source)
		} else {
			ContentUnavailableView("Source not found", systemImage: "tray", description: Text("This source has been removed."))
		}
	}
}

/// An app's page pushed where it's opened from, in any stack, such as
/// Settings' from an Apple ID's new apps (#49), with its source's apps and
/// its other installs pushed after it, so Back goes back there (4 Nov
/// 2026: from the new apps, the page opened in Browse, and Back went to
/// Browse). All of them are pushed as views, as the stack's own pages may
/// be, so the source's apps open their pages that way too
/// (`pushesAppPages`).
struct PushedAppPage: View {
	enum Page {
		/// As a source lists it.
		case listing(AppLink)
		/// As the Library has it.
		case library(LibraryLink)
	}

	let page: Page
	@State private var source: SourceAppsLink?
	@State private var install: LibraryLink?

	init(_ page: Page) {
		self.page = page
	}

	var body: some View {
		detail
			.navigationDestination(item: $source) { link in
				SourceAppsLoader(url: link.url)
					.environment(\.pushesAppPages, true)
			}
			.navigationDestination(item: $install) { app in
				PushedAppPage(.library(app))
			}
	}

	@ViewBuilder
	private var detail: some View {
		switch page {
		case .listing(let link):
			AppDetailView(link: link, openSource: { source = SourceAppsLink(url: $0) }, openInstall: { install = $0 })
		case .library(let app):
			AppDetailView(library: app, openSource: { source = SourceAppsLink(url: $0) }, openInstall: { install = $0 })
		}
	}
}

/// A source's icon and name in a capsule lightly tinted with its colour.
struct SourceChip: View {
	let source: Catalog.SourceInfo
	@Environment(SourcesModel.self) private var sources

	var body: some View {
		HStack(spacing: 6) {
			SourceIcon(url: source.iconURL, tint: source.tintColor, size: 18)
			Text(source.name)
				.font(.footnote.weight(.semibold))
				.lineLimit(1)
			// As tall as the icon: the chip's height already.
			if GitHubRepo(sourceURL: source.url) != nil { GitHubMark(size: 18) }
			if sources.listsPrereleases(source.url) { PrereleaseMark(size: 18) }
		}
		.padding(.leading, 3)
		.padding(.trailing, 9)
		.padding(.vertical, 3)
		.background(SourceTint(hex: source.tintColor, url: source.url).color.opacity(0.18), in: Capsule())
	}
}

/// The Source of an app installed from a link (#113): the link's site as a
/// button, as a source's chip is, whose menu shows the link, shortened in
/// the middle, to copy or share, with "Link" at the end, as "Built in" is,
/// which reads "Copied" for 2 seconds after Copy Link, as in the mockup
/// The maintainer approved (3 Nov 2026). The site gives way first.
private struct IPALinkSource: View {
	let link: URL
	/// When Copy Link was last tapped, while "Copied" shows.
	@State private var copiedAt: Date?

	var body: some View {
		HStack(spacing: 8) {
			Menu {
				Section {
					Button("Copy Link", systemImage: "doc.on.doc") {
						UIPasteboard.general.url = link
						copiedAt = .now
					}
					ShareLink(item: link) {
						Label("Share…", systemImage: "square.and.arrow.up")
					}
				} header: {
					Text(IPAOrigins.shortened(link))
				}
			} label: {
				HStack(spacing: 5) {
					Image(systemName: "link")
						.imageScale(.small)
					Text(IPAOrigins.site(of: link))
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.font(.footnote.weight(.semibold))
				.padding(.leading, 8)
				.padding(.trailing, 10)
				.padding(.vertical, 4)
				.background(Color(.tertiarySystemFill), in: Capsule())
			}
			.buttonStyle(.borderless)
			.tint(.primary)
			.accessibilityLabel("Link: \(IPAOrigins.site(of: link))")
			.accessibilityHint("Shows the link, to copy or share.")
			Spacer(minLength: 4)
			Group {
				if copiedAt != nil {
					Text("Copied")
						.fontWeight(.semibold)
						.foregroundStyle(.tint)
				} else {
					Text("Link")
						.foregroundStyle(.secondary)
				}
			}
			.font(.footnote)
			.lineLimit(1)
			.fixedSize()
		}
		// "Link" again 2 seconds after the last Copy Link.
		.task(id: copiedAt) {
			guard copiedAt != nil else { return }
			do {
				try await Task.sleep(for: .seconds(2))
				copiedAt = nil
			} catch {}
		}
	}
}

/// What a screenshot shows while it loads, or when it can't be loaded: the
/// app's icon and name on a light wash of its tint.
private struct ScreenshotPlaceholder: View {
	let app: SourceApp
	let tint: Color

	var body: some View {
		ZStack {
			tint.opacity(0.12)
			VStack(spacing: 10) {
				SourceIcon(url: app.iconURL, tint: app.tintColor, size: 64)
					.shadow(color: .black.opacity(0.12), radius: 6, y: 2)
				Text(app.name)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 12)
			}
		}
	}
}

/// The app's screenshots in a horizontal row, with an iPhone and iPad switch
/// when it has both.
private struct ScreenshotsView: View {
	let app: SourceApp
	let tint: Color

	private var screenshots: Screenshots { app.screenshots }
	@State private var device = Device.iphone

	enum Device: Hashable { case iphone, ipad }

	private var shown: [Screenshot] {
		switch device {
		case .iphone: screenshots.iphone.isEmpty ? screenshots.ipad : screenshots.iphone
		case .ipad: screenshots.ipad.isEmpty ? screenshots.iphone : screenshots.ipad
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if !screenshots.iphone.isEmpty && !screenshots.ipad.isEmpty {
				Picker("Device", selection: $device) {
					Text("iPhone").tag(Device.iphone)
					Text("iPad").tag(Device.ipad)
				}
				.pickerStyle(.segmented)
				.padding(.horizontal, 16)
			}
			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(spacing: 10) {
					ForEach(Array(shown.enumerated()), id: \.offset) { _, screenshot in
						let size = frame(for: screenshot)
						// Under 300 pixels, it's an icon rather than a screenshot.
						CachedImage(url: screenshot.imageURL, maxPoints: max(size.width, size.height), minimumPixels: 300) {
							ScreenshotPlaceholder(app: app, tint: tint)
						}
						.scaledToFill()
						.frame(width: size.width, height: size.height)
						.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
						.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary))
					}
				}
				.padding(.horizontal, 16)
			}
			.frame(height: 400)
		}
	}

	/// 400 points tall for portrait screenshots, narrower than the screen for
	/// landscape ones. The spec says to assume 393 × 852 when no size is given.
	private func frame(for screenshot: Screenshot) -> CGSize {
		let width = CGFloat(screenshot.width ?? 393), height = CGFloat(screenshot.height ?? 852)
		let aspect = width / max(height, 1)
		let shownHeight = aspect > 1 ? min(400, 320 / aspect) : 400
		return CGSize(width: shownHeight * aspect, height: shownHeight)
	}
}
