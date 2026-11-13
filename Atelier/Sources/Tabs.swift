import CertKit
import DownloadKit
import InstallKit
import AtelierCore
import SourceKit
import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
	@Query(sort: \InstallRecord.name) private var installs: [InstallRecord]
	@Query private var sourceRecords: [SourceRecord]
	@Environment(\.modelContext) private var context
	@Environment(CertificatesModel.self) private var certificates
	@Environment(CatalogModel.self) private var catalog
	@Environment(DownloadManager.self) private var downloads
	@Environment(InstallModel.self) private var installer
	/// Read so whether apps are still installed is checked again on coming
	/// back to Atelier, after one may have been deleted from the Home Screen.
	@Environment(\.scenePhase) private var scenePhase
	/// The pages open over the Library: an app's, its source's, and the
	/// apps those open, as in Browse.
	@State private var path = NavigationPath()
	/// The app whose Delete is waiting to be confirmed.
	@State private var deleting: InstallRecord?
	/// Whether that app is still on this iPhone, as of the Delete (#55).
	@State private var deletingPresence = AppPresence.unknown
	@State private var scanProblem: String?
	@State private var routeA = RouteASetup.shared
	@State private var askingForURL = false
	@State private var typedURL = ""
	@State private var invalidURL = false
	/// Whether skipped updates show in the Updates section (#18).
	@State private var showingSkipped = false
	/// Update All's apps while they update, kept together (#18).
	@State private var updateGroup: UpdateGroup?
	/// The apps the last Update All updated, which say so until the
	/// Library closes.
	@State private var justUpdated: Set<String> = []
	/// Re-sign All's apps while they're re-signed, kept together (#20).
	@State private var resignGroup: ResignGroup?
	/// Each app's last re-sign, by bundle ID: one that failed says why in
	/// the Re-sign section, one that's done says so in Installed (#20).
	@State private var resignJobs: [String: String] = [:]
	/// Re-signing that would delete apps first, waiting to be confirmed.
	@State private var confirmingResign: ResignConfirmation?
	/// The app whose kept data Put Back asks about first (#96).
	@State private var confirmingPutBack: LibraryItem?
	/// The app Disable asks about first (#49).
	@State private var confirmingDisable: LibraryItem?
	/// What's typed in the Library's search field (#124).
	@State private var query = ""
	/// The certificate or Apple ID whose apps alone the Library shows; nil
	/// for every app (#49).
	@State private var signedWith: UUID?

	private var actions: LibraryActions {
		LibraryActions(installer: installer, catalog: catalog.catalog, downloads: downloads, certificates: certificates, context: context)
	}

	var body: some View {
		let signers = LibrarySigner.all(in: installs, certificates: certificates, installer: installer)
		let showsFilter = LibraryFilterMenu.narrows(signers, total: installs.count)
		// One that no longer signs any app shows every app.
		let shown = signers.first { $0.id == signedWith }?.id
		NavigationStack(path: $path) {
			library(signedWith: showsFilter ? shown : nil)
				.navigationTitle("Library")
				.searchable(text: $query, prompt: "Search Library")
				.navigationDestination(for: LibraryLink.self) { app in
					AppDetailView(library: app, openSource: { path.append(SourceAppsLink(url: $0)) }, openInstall: { path.append($0) })
				}
				// A source's apps, opened from an app's page, and their pages.
				.navigationDestination(for: SourceAppsLink.self) { link in
					SourceAppsLoader(url: link.url)
				}
				.navigationDestination(for: AppLink.self) { link in
					AppDetailView(link: link, openSource: { path.append(SourceAppsLink(url: $0)) }, openInstall: { path.append($0) })
				}
				.onAppear { installer.refreshKeptData() }
				// With the setup finished, pulling down checks which apps are
				// still on this iPhone and their versions (#17).
				.modifier(DeviceScanRefresh(enabled: routeA.isSetUp) {
					scanProblem = await installer.scanDevice(into: context)
				})
				.modifier(PutBackConfirmation(item: $confirmingPutBack, actions: actions))
				.modifier(DisableConfirmation(item: $confirmingDisable, actions: actions))
				.toolbar {
					// One certificate's or Apple ID's apps at a time, so it's
					// plain which hold a free Apple ID's 3 places (#49).
					if showsFilter {
						LibraryFilterMenu(signers: signers, total: installs.count, selection: Binding(get: { shown }, set: { signedWith = $0 }))
					}
					// Every install attempt, by any method (moved from Settings).
					NavigationLink {
						InstallHistoryView()
					} label: {
						Label("Install History", systemImage: "clock")
					}
					// Either way, the IPA is signed with the default certificate,
					// then installed after any installs already waiting. The install
					// shows in the install bar rather than in a sheet, so nothing has
					// to wait for the picker to go away before it starts.
					Menu {
						Button("Choose IPA File", systemImage: "folder") {
							IPAPicker.present { url in installer.install(picked: url, certificates: certificates, into: context) }
						}
						Button("Download from URL", systemImage: "link") {
							typedURL = ""
							askingForURL = true
						}
					} label: {
						Label("Install IPA", systemImage: "plus")
					}
				}
				.alert("Download an IPA", isPresented: $askingForURL) {
					// A String rather than a LocalizedStringKey, whose Markdown
					// would show the URL as a link: blue, not a grey placeholder.
					TextField(String("https://example.com/app.ipa"), text: $typedURL)
						.keyboardType(.URL)
						.textContentType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					Button("Cancel", role: .cancel) {}
					Button("Download") {
						if let url = IPALink.url(from: typedURL) {
							installer.install(url: url, downloads: downloads, certificates: certificates, into: context)
						} else {
							invalidURL = true
						}
					}
				} message: {
					Text("Paste a link that downloads an IPA. Atelier downloads it, then signs and installs it.")
				}
				.alert("Couldn't check this \(ThisDevice.name)'s apps", isPresented: Binding(
					get: { scanProblem != nil },
					set: { if !$0 { scanProblem = nil } }
				)) {
					Button("OK", role: .cancel) {}
				} message: {
					Text(scanProblem ?? "")
				}
				.alert("That isn't a link Atelier can download.", isPresented: $invalidURL) {
					Button("OK", role: .cancel) {}
				} message: {
					Text("Enter a web address starting with https://.")
				}
		}
	}

	/// The Library's sections, apart from `body` so that the compiler can
	/// check each of them in reasonable time. Only the apps of `signer`,
	/// the certificate or Apple ID the filter shows, when it shows one
	/// (#49).
	private func library(signedWith signer: UUID?) -> some View {
		_ = scenePhase
		let actions = actions
		let items = installs.map { LibraryItem($0, catalog: catalog.catalog, certificates: certificates, installer: installer) }
		let group = updateGroup
		// Each app leaves the group for Installed as soon as it's
		// updated; the rest stay until they're done (22 Oct).
		let members = group.map { group in group.bundleIDs.compactMap { id in items.first { $0.install.bundleID == id } } } ?? []
		let updatedIDs = Set(members.filter { $0.update == nil && installer.status(of: $0.appKey) == nil }.map(\.install.bundleID))
		let grouped = members.filter { !updatedIDs.contains($0.install.bundleID) }
		// Re-sign All's apps likewise leave its group once re-signed (#20).
		let resigning = resignGroup
		let resignMembers = resigning.map { group in group.bundleIDs.compactMap { id in items.first { $0.install.bundleID == id } } } ?? []
		let resignedIDs = Set(resignMembers.filter { item in
			if case .resigned? = resigning?.phase(of: item, installer: installer, downloads: downloads) { return true }
			return false
		}.map(\.install.bundleID))
		let resignGrouped = resignMembers.filter { !resignedIDs.contains($0.install.bundleID) }
		let resignGroupedIDs = Set(resignGrouped.map(\.install.bundleID))
		// Apps whose certificate died are in Re-sign rather than Updates or
		// Installed; with an update, re-signing keeps their version. One
		// stays there while it's re-signed, also once it's deleted to be
		// installed again, and while Atelier renews it once New Certificate
		// got its Apple ID a new one (12 Nov 2026).
		let renewals = ProfileRenewals.shared
		let needsResign = { (item: LibraryItem) in
			item.needsResign || installer.isResigning(item.install.bundleID)
				|| (renewals.isRenewing(item.install.bundleID) && item.signedWithOldCertificate)
		}
		let toResign = items.filter { needsResign($0) && !resignGroupedIDs.contains($0.install.bundleID) }
		let inResign = { (item: LibraryItem) in needsResign(item) || resignGroupedIDs.contains(item.install.bundleID) }
		// Apps due to renew that Atelier couldn't renew by itself, or whose
		// profile ended, are in Renew rather than Updates or Installed (#49).
		let dueToRenew = items.filter { renewals.inRenewSection($0) && !inResign($0) }
		// Atelier itself first (#152): once its own profile has ended, it
		// can't open to renew the others.
		let toRenew = dueToRenew.filter(\.isOwn) + dueToRenew.filter { !$0.isOwn }
		let renewIDs = Set(toRenew.map(\.install.bundleID))
		let elsewhere = { (item: LibraryItem) in inResign(item) || renewIDs.contains(item.install.bundleID) }
		let updates = items.filter { $0.update != nil && !elsewhere($0) && !(group?.contains($0.install.bundleID) ?? false) }
		let skipped = items.filter { $0.skippedUpdate != nil && !elsewhere($0) }
		let installed = items.filter { item in
			item.update == nil && !(showingSkipped && item.skippedUpdate != nil) && !elsewhere(item) && item.disabled == nil
				&& (!(group?.contains(item.install.bundleID) ?? false) || updatedIDs.contains(item.install.bundleID))
		}
		// Off this iPhone with their data kept, under Installed (#49).
		let disabled = items.filter { $0.disabled != nil }
		let resignIsDone = resigning?.isDone(installer: installer) ?? false
		// Downloads shown in Update All's and Re-sign All's rows instead,
		// and every update's, in its row (#19), as is that of any install
		// over an app here, such as Re-sign's (12 Nov 2026).
		let updateDownloads = Set(items.compactMap { $0.updateDownload(downloads)?.id })
		let rowDownloads = Set(items.compactMap { installer.downloadID(ofLibraryApp: $0.install.bundleID, key: $0.appKey) })
		let groupDownloads = (group?.downloadIDs ?? []).union(resigning?.downloadIDs ?? []).union(updateDownloads).union(rowDownloads)
		// While searching, only the apps it finds show, each in its section,
		// and no button that acts on a whole section, so none acts on apps
		// that aren't shown (#124). The groups and sections above still go
		// by every app. The same while the filter shows one certificate's or
		// Apple ID's apps, with no downloads, which none signed yet (#49).
		let search = SearchText(query)
		let searching = !search.isEmpty
		let narrowed = searching || signer != nil
		let found = { (list: [LibraryItem]) in
			narrowed ? list.filter { (signer == nil || $0.install.certificateID == signer) && (!searching || matches($0, search)) } : list
		}
		let foundGrouped = found(grouped), foundResignGrouped = found(resignGrouped), foundToResign = found(toResign), foundToRenew = found(toRenew)
		let foundUpdates = found(updates), foundSkipped = found(skipped), foundInstalled = found(installed), foundDisabled = found(disabled)
		let shownSkipped = showingSkipped ? foundSkipped : []
		let foundDownloads = signer != nil ? [] : DownloadsSection.shown(downloads.downloads, installer: installer, hiding: groupDownloads, search: search)
		let foundNothing = [foundGrouped, foundResignGrouped, foundToResign, foundToRenew, foundUpdates, foundSkipped, foundInstalled, foundDisabled].allSatisfy(\.isEmpty) && foundDownloads.isEmpty
		// Installed has a title when other sections come before it.
		let titlesInstalled = !foundUpdates.isEmpty || !foundSkipped.isEmpty || !foundGrouped.isEmpty || !foundToResign.isEmpty || !foundResignGrouped.isEmpty || !foundToRenew.isEmpty
		return List {
			resignSection(foundToResign, grouped: foundResignGrouped, in: resigning, searching: narrowed, actions: actions)
			renewSection(foundToRenew, all: toRenew, narrowed: narrowed, actions: actions)
			if signer == nil {
				DownloadsSection(installer: installer, hiding: groupDownloads, search: search)
			}
			// Update All's apps that are still waiting or installing.
			if let group, !foundGrouped.isEmpty {
				Section {
					ForEach(foundGrouped) { item in
						groupRow(item, in: group, actions: actions)
					}
					ForEach(foundUpdates) { item in
						row(item, showsUpdate: true, actions: actions)
					}
				} header: {
					HStack {
						Text(foundGrouped.count == 1 ? "Updating 1 app" : "Updating \(foundGrouped.count) apps")
						Spacer()
						if !narrowed {
							Button("Cancel All", role: .destructive) { actions.cancel(group, items: items) }
								.font(.subheadline.weight(.semibold))
								.textCase(nil)
						}
					}
				}
			} else if !foundUpdates.isEmpty || !foundSkipped.isEmpty {
				// Apps with an update first, with Update All (#18).
				Section {
					ForEach(foundUpdates + shownSkipped) { item in
						row(item, showsUpdate: true, actions: actions)
					}
				} header: {
					HStack {
						Text(foundUpdates.isEmpty ? "Updates" : "Updates · \(foundUpdates.count)")
						Spacer()
						if updates.count > 1, !narrowed {
							Button("Update All") {
								justUpdated = []
								updateGroup = actions.updateAll(updates)
							}
							.font(.subheadline.weight(.semibold))
							.textCase(nil)
						}
					}
				} footer: {
					if !foundSkipped.isEmpty {
						HStack(spacing: 4) {
							Text(foundSkipped.count == 1 ? "1 skipped update." : "\(foundSkipped.count) skipped updates.")
							Button(showingSkipped ? "Hide" : "Show") { showingSkipped.toggle() }
								.font(.footnote)
						}
					}
				}
			}
			// While searching or filtered, only when it found some.
			if !narrowed || !foundInstalled.isEmpty {
				Section {
					ForEach(foundInstalled) { item in
						row(item, showsUpdate: false, justUpdated: updatedIDs.contains(item.install.bundleID), actions: actions)
					}
				} header: {
					if titlesInstalled || !foundDisabled.isEmpty { Text("Installed") }
				}
			}
			if !foundDisabled.isEmpty {
				Section {
					ForEach(foundDisabled) { item in
						row(item, showsUpdate: false, actions: actions)
					}
				} header: {
					Text("Offloaded · \(foundDisabled.count)")
				} footer: {
					Text("Off this \(ThisDevice.name), with their data kept in Atelier. Reinstall puts one back with its data, as it was.")
				}
			}
		}
		.animation(.default, value: updatedIDs)
		.animation(.default, value: resignedIDs)
		.animation(.default, value: renewIDs)
		// Renewed shows until the Library is left (#49).
		.onDisappear { renewals.forgetRecent() }
		// Once no app of Update All is waiting or installing, the group
		// ends; any that failed go back to Updates with Update to try
		// again.
		.onChange(of: groupIsDone(items)) { _, done in
			if done { endUpdateGroup() }
		}
		// Likewise Re-sign All's; any that failed stay in Re-sign, saying
		// why, with Re-sign to try again (#20).
		.onChange(of: resignIsDone) { _, done in
			if done { endResignGroup() }
		}
		// Use It and Re-sign All, right after importing a certificate.
		.onChange(of: installer.resignRequested, initial: true) { _, requested in
			if requested { resignAllRequested() }
		}
		.modifier(ResignConfirmationAlert(confirmation: $confirmingResign) { items, target, deletingFirst, keepingData in
			startResign(items, with: target, deletingFirst: deletingFirst, keepingData: keepingData)
		})
		.overlay {
			if installs.isEmpty && downloads.downloads.allSatisfy(installer.isHidden) {
				ContentUnavailableView(
					"No apps installed",
					systemImage: "square.stack",
					description: Text("Apps you install with Atelier will show up here.")
				)
			} else if searching, foundNothing {
				ContentUnavailableView.search(text: query)
			}
		}
	}
}

/// Reads the link typed or pasted in the Library's Download from URL.
enum IPALink {
	/// The web address in `text`, or nil when it isn't one. A missing scheme
	/// means https; http isn't allowed, as App Transport Security blocks it.
	static func url(from text: String) -> URL? {
		var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
		if !trimmed.contains("://") { trimmed = "https://" + trimmed }
		guard let url = URL(string: trimmed),
		      let scheme = url.scheme?.lowercased(), scheme == "https",
		      let host = url.host, !host.isEmpty else { return nil }
		return url
	}
}

extension LibraryView {
	/// An app's row, with its swipe actions, menu and Delete dialog. In the
	/// Re-sign section, `resign` says what re-signing does to it (#20).
	private func row(_ item: LibraryItem, showsUpdate: Bool, justUpdated updated: Bool = false, resign: ResignNote? = nil, renews: Bool = false, actions: LibraryActions) -> some View {
		// A hidden link under the row, as in Browse: the button on
		// the right takes its own taps, the rest of the row opens
		// the app's page, the same as from Browse (#81). As in Browse,
		// it's a value on the tab's path, which the page's source chip
		// adds the source's apps to (30 Oct).
		ZStack {
			NavigationLink(value: LibraryLink(item)) { EmptyView() }
				.opacity(0)
			LibraryRow(
				item: item,
				sourceName: sourceName(of: item),
				showsUpdate: showsUpdate,
				// Atelier says so once it opens on the build it installed (#24).
				justUpdated: updated || justUpdated.contains(item.install.bundleID) || SelfUpdate.shared.justInstalled(item.install, as: .update),
				resign: resign,
				justResigned: isJustResigned(item) || SelfUpdate.shared.justInstalled(item.install, as: .resign),
				renews: renews
			) { action in
				actions.perform(action, on: item, resign: requestResign, putBack: { confirmingPutBack = $0 })
			}
		}
		// Swipe left to delete, or touch and hold.
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			// Atelier can't delete itself (#24).
			if !item.isOwn {
				Button("Delete", systemImage: "trash") { confirmDelete(item.install) }
					.tint(.red)
			}
		}
		.contextMenu {
			LibraryMenu(item: item, actions: actions) {
				confirmDelete(item.install)
			} disable: {
				confirmingDisable = item
			}
		}
		// On the row, so on iOS 26 the dialog's popover points at it.
		.modifier(DeleteAppDialog(
			install: item.install,
			presence: deletingPresence,
			isPresented: Binding(
				get: { deleting?.persistentModelID == item.install.persistentModelID },
				set: { if !$0 { deleting = nil } }
			)
		))
	}

	/// An app of Update All's group, with its stage (#18).
	@ViewBuilder
	private func groupRow(_ item: LibraryItem, in group: UpdateGroup, actions: LibraryActions) -> some View {
		if let version = group.versions[item.install.bundleID] {
			UpdateGroupRow(
				item: item,
				version: version,
				phase: group.phase(of: item, installer: installer, downloads: downloads),
				sourceName: sourceName(of: item),
				installer: installer
			) {
				actions.update(item)
			}
		}
	}

	/// Whether no app of Update All's group is waiting or installing.
	private func groupIsDone(_ items: [LibraryItem]) -> Bool {
		guard let group = updateGroup else { return false }
		return items.filter { group.contains($0.install.bundleID) }.allSatisfy { installer.status(of: $0.appKey) == nil }
	}

	/// Ends Update All's group, checked again a moment later, so a handoff
	/// between two installs doesn't end it early.
	private func endUpdateGroup() {
		Task {
			try? await Task.sleep(for: .seconds(1))
			let items = installs.map { LibraryItem($0, catalog: catalog.catalog, certificates: certificates, installer: installer) }
			guard let group = updateGroup, groupIsDone(items) else { return }
			withAnimation {
				justUpdated = Set(group.bundleIDs.filter { id in items.first { $0.install.bundleID == id }?.update == nil })
				updateGroup = nil
			}
		}
	}

	/// The source it was installed from, by name.
	private func sourceName(of item: LibraryItem) -> String {
		if let listing = item.listing { return listing.source.name }
		guard let url = item.install.sourceURL else { return "IPA file" }
		return sourceRecords.first { $0.url == url }?.name ?? "Removed source"
	}

	/// Whether the Library's search finds the app (#124): by its name,
	/// developer or bundle IDs, or the source its row names.
	private func matches(_ item: LibraryItem, _ search: SearchText) -> Bool {
		search.matches(name: item.install.name, others: [item.listing?.app.developerName, item.install.bundleID, item.install.sourceBundleID, sourceName(of: item)])
	}

	// MARK: Renewing (#49)

	/// The apps due to renew that Atelier couldn't renew by itself, or
	/// whose profile ended, rather than every app due (10 Nov 2026),
	/// with Renew All. While narrowed, only the apps found, without Renew
	/// All or the footer.
	@ViewBuilder
	private func renewSection(_ items: [LibraryItem], all: [LibraryItem], narrowed: Bool, actions: LibraryActions) -> some View {
		if !items.isEmpty {
			let renewals = ProfileRenewals.shared
			Section {
				ForEach(items) { item in
					row(item, showsUpdate: false, renews: true, actions: actions)
				}
			} header: {
				HStack {
					Text("Renew · \(items.count)")
					Spacer()
					// Not Atelier itself while it waits for its Apple ID to sign
					// in (#152), which Renew can't do.
					let renewable = all.filter { $0.needsAppleID == nil }
					if renewable.count > 1, !narrowed {
						Button("Renew All") {
							let ids = renewable.map(\.install.bundleID)
							Task { await renewals.renew(ids) }
						}
						.font(.subheadline.weight(.semibold))
						.textCase(nil)
						.disabled(renewable.allSatisfy { renewals.isRenewing($0.install.bundleID) })
					}
				}
			} footer: {
				if !narrowed { Text(Self.renewFooter(all)) }
			}
		}
	}

	/// "Their profiles end within 2 days. Atelier renews them by itself
	/// while LocalDevVPN is connected. Renew connects it, then gets each a
	/// new profile in a few seconds, without reinstalling."
	///
	/// Atelier itself, before the free Apple ID that installed it signs in
	/// (#152): "A free Apple ID installed Atelier, so its profile ends on
	/// Wed 18 Nov at 10:42 and Atelier stops opening then. Sign in with that
	/// Apple ID, and Atelier renews itself every week." And once it's one of
	/// the apps that couldn't renew: "Once Atelier’s own profile has ended,
	/// it can’t open to renew anything, and has to be installed again."
	private static func renewFooter(_ all: [LibraryItem]) -> String {
		var signIn: String?
		if let own = all.first(where: { $0.needsAppleID != nil }), let need = own.needsAppleID {
			let name = own.install.name
			let ends = need.expires.map { "so its profile ends on \(AppProfileDays.describe($0)) and \(name) stops opening then" }
				?? "so its profile lasts 7 days and \(name) stops opening once it has ended"
			signIn = "A free Apple ID installed \(name), \(ends). Sign in with that Apple ID, and \(name) renews itself every week."
		}
		let items = all.filter { $0.needsAppleID == nil }
		guard !items.isEmpty else { return signIn ?? "" }
		let own = items.first(where: \.isOwn).map { "Once \($0.install.name)’s own profile has ended, it can’t open to renew anything, and has to be installed again." }
		return [signIn, renewFooter(due: items), own].compactMap { $0 }.joined(separator: " ")
	}

	private static func renewFooter(due items: [LibraryItem]) -> String {
		let one = items.count == 1
		let ended = items.allSatisfy { ($0.appProfile?.expires ?? .distantFuture) <= .now }
		// A paid team's renew 14 days ahead, Atelier itself 4 (#152).
		let days = items.contains { $0.appleID?.isFree == false } ? 14 : items.contains(where: \.isOwn) ? 4 : 2
		let lead = switch (one, ended) {
		case (true, true): "Its profile ended, so it doesn’t open until it’s renewed."
		case (false, true): "Their profiles ended, so they don’t open until they’re renewed."
		case (true, false): "Its profile ends within \(days) days."
		case (false, false): "Their profiles end within \(days) days."
		}
		let rest = one
			? "Atelier renews it by itself while LocalDevVPN is connected. Renew connects LocalDevVPN, then gets the app a new profile in a few seconds, without reinstalling."
			: "Atelier renews them by itself while LocalDevVPN is connected. Renew connects it, then gets each a new profile in a few seconds, without reinstalling."
		return "\(lead) \(rest)"
	}

	// MARK: Re-signing (#20)

	/// Apps whose certificate died, with Re-sign All, or Re-sign All's apps
	/// while it runs followed by the others; with Import Certificate when
	/// there's no certificate to re-sign them with. While `searching`, only
	/// the apps found, without Re-sign All or Cancel All, nor the footer
	/// that tells what Re-sign All does (#124).
	@ViewBuilder
	private func resignSection(_ items: [LibraryItem], grouped: [LibraryItem], in group: ResignGroup?, searching: Bool, actions: LibraryActions) -> some View {
		let target = certificates.resignTarget
		let notes = Dictionary(items.map { ($0.install.bundleID, actions.resignNote(for: $0, target: target, failure: failure(of: $0))) }, uniquingKeysWith: { first, _ in first })
		if let group, !grouped.isEmpty {
			Section {
				ForEach(grouped) { item in
					resignGroupRow(item, in: group)
				}
				ForEach(items) { item in
					row(item, showsUpdate: false, resign: notes[item.install.bundleID], actions: actions)
				}
			} header: {
				HStack {
					Text(grouped.count == 1 ? "Re-signing 1 app" : "Re-signing \(grouped.count) apps")
					Spacer()
					if !searching {
						Button("Cancel All", role: .destructive) { actions.cancel(group) }
							.font(.subheadline.weight(.semibold))
							.textCase(nil)
					}
				}
			}
		} else if !items.isEmpty {
			// Not one that's being re-signed (12 Nov 2026).
			let resignable = items.filter { (notes[$0.install.bundleID]?.canResign ?? false) && !installer.isResigning($0.install.bundleID) }
			// Apps installed with an Apple ID get it a new certificate, one
			// Apple ID at a time, rather than going with Re-sign All.
			let resignAll = resignable.filter { !$0.resignsWithNewCertificate }
			Section {
				ForEach(items) { item in
					row(item, showsUpdate: false, resign: notes[item.install.bundleID], actions: actions)
				}
				// Not for apps whose Apple ID gets a new certificate.
				if target == nil, items.contains(where: { !$0.resignsWithNewCertificate }) {
					Button("Import Certificate", systemImage: "person.badge.key") { certificates.beginImport() }
				}
			} header: {
				HStack {
					Text("Re-sign · \(items.count)")
					Spacer()
					if resignAll.count > 1, let target, !searching {
						Button("Re-sign All") { requestResignAll(resignAll, with: target) }
							.font(.subheadline.weight(.semibold))
							.textCase(nil)
					}
				}
			} footer: {
				if !searching {
					ResignFooter(
						items: items,
						resignable: resignable,
						reinstalling: resignable.filter { item in
							if case .reinstallRequired? = notes[item.install.bundleID]?.kind { return true }
							return false
						}.count,
						target: target
					)
				}
			}
		}
	}

	/// An app of Re-sign All's group, with its stage.
	@ViewBuilder
	private func resignGroupRow(_ item: LibraryItem, in group: ResignGroup) -> some View {
		if let phase = group.phase(of: item, installer: installer, downloads: downloads) {
			ResignGroupRow(
				item: item,
				phase: phase,
				version: group.versions[item.install.bundleID],
				sourceName: sourceName(of: item),
				installer: installer
			) {
				requestResign(item)
			}
		}
	}

	/// Why the app's last re-sign failed, if it did.
	private func failure(of item: LibraryItem) -> String? {
		resignJobs[item.install.bundleID].flatMap { installer.failures[$0] }
	}

	/// Why the app's data couldn't be copied when it was last re-signed,
	/// if that's what stopped it (#96).
	private func dataFailure(of item: LibraryItem) -> AppDataCopyFailure? {
		resignJobs[item.install.bundleID].flatMap { installer.dataFailures[$0] }
	}

	/// Whether the app's last re-sign is done and didn't fail.
	private func isJustResigned(_ item: LibraryItem) -> Bool {
		guard let job = resignJobs[item.install.bundleID] else { return false }
		return installer.status(ofJob: job) == nil && installer.failures[job] == nil
	}

	/// Re-signs one app, asking first when it has to be deleted first, or
	/// its data couldn't be copied last time (#96).
	private func requestResign(_ item: LibraryItem) {
		// An app installed with an Apple ID whose certificate Apple revoked
		// or that ended: New Certificate gets that Apple ID a new one, then
		// signs its apps again with it, keeping their App IDs (12 Nov 2026).
		if item.resignsWithNewCertificate, let account = item.appleID {
			return certificates.beginNewCertificate(for: account)
		}
		guard let target = certificates.resignTarget else { return }
		if actions.needsReinstall(item, resigningWith: target) {
			confirmingResign = ResignConfirmation(losing: [item], keeping: [], target: target, dataFailure: dataFailure(of: item))
		} else {
			startResign([item], with: target, deletingFirst: [])
		}
	}

	/// Ends Re-sign All's group, checked again a moment later as Update
	/// All's is.
	private func endResignGroup() {
		Task {
			try? await Task.sleep(for: .seconds(1))
			guard resignGroup?.isDone(installer: installer) == true else { return }
			withAnimation { resignGroup = nil }
		}
	}

	/// Re-sign All for every app in Re-sign that can be, when asked for
	/// outside the Library, such as right after a certificate was imported.
	private func resignAllRequested() {
		installer.resignRequested = false
		guard let target = certificates.resignTarget else { return }
		let actions = actions
		let items = installs.map { LibraryItem($0, catalog: catalog.catalog, certificates: certificates, installer: installer) }
		let resignable = items.filter { item in
			item.needsResign && !item.resignsWithNewCertificate && !(resignGroup?.contains(item.install.bundleID) ?? false) && !installer.isResigning(item.install.bundleID)
				&& actions.resignNote(for: item, target: target, failure: nil).canResign
		}
		guard !resignable.isEmpty else { return }
		requestResignAll(resignable, with: target)
	}

	/// Re-sign All, asking first when any app would lose its data.
	private func requestResignAll(_ items: [LibraryItem], with target: StoredCertificate) {
		let losing = items.filter { actions.needsReinstall($0, resigningWith: target) }
		guard !losing.isEmpty else { return startResign(items, with: target, deletingFirst: []) }
		let losingIDs = Set(losing.map(\.install.bundleID))
		confirmingResign = ResignConfirmation(losing: losing, keeping: items.filter { !losingIDs.contains($0.install.bundleID) }, target: target)
	}

	/// Re-signs `items` with `target`, deleting first those whose bundle IDs
	/// are in `deletingFirst`, with their data unless `keepingData` is false
	/// (#96). Several go as a group, as Update All's do.
	private func startResign(_ items: [LibraryItem], with target: StoredCertificate, deletingFirst: Set<String>, keepingData: Bool = true) {
		if items.count == 1, let item = items.first {
			resignJobs[item.install.bundleID] = actions.resign(item, with: target, deletingFirst: deletingFirst.contains(item.install.bundleID), keepingData: keepingData)
		} else {
			let group = actions.resignAll(items, with: target, deletingFirst: deletingFirst)
			resignJobs.merge(group.jobIDs) { _, new in new }
			withAnimation { resignGroup = group }
		}
	}

	/// Asks before deleting, worded by whether the app is still on this
	/// iPhone (#55).
	private func confirmDelete(_ install: InstallRecord) {
		deletingPresence = InstallModel.presence(of: install)
		deleting = install
	}
}

struct SettingsView: View {
	@AppStorage(AutoUpdates.enabledKey) private var autoUpdate = false
	@AppStorage(AutoUpdates.whileChargingKey) private var autoUpdateWhileCharging = true
	@AppStorage(UpdateChecks.notifyUpdatesKey) private var notifyUpdates = true
	@AppStorage(UpdateChecks.notifyNewsKey) private var notifyNews = true
	@AppStorage(HomeScreenSpots.onKey) private var keepsSpots = true
	/// Open Spaces, for its row's count.
	@AppStorage(YourGaps.key) private var markedGaps: Data?
	@State private var routeA = RouteASetup.shared
	/// Finish Setting Up was tapped on the Installs card.
	@State private var settingUp = false
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.scenePhase) private var scenePhase

	private var version: String {
		let info = Bundle.main.infoDictionary
		let short = info?["CFBundleShortVersionString"] as? String ?? "?"
		let build = info?["CFBundleVersion"] as? String ?? "?"
		return "\(short) (\(build))"
	}

	var body: some View {
		NavigationStack {
			Form {
				// Everything about installing comes first (29 Oct 2026):
				// whether anything needs you, the certificate apps are signed
				// with, then the one way to install, with iOS's alert out of
				// the box and in the background once the setup is finished.
				Section {
					// Get Ready's page, any time (#21): All good, or the first
					// thing to fix, the setup's check included. It comes
					// first, so the rows under it only say what they hold
					// (3 Nov 2026).
					NavigationLink {
						CheckupView()
					} label: {
						LabeledContent("Status") {
							CheckupSummary()
						}
					}
					NavigationLink {
						CertificatesView()
					} label: {
						// Under the one in use, what the Settings tab's badge
						// counts, so it shows where the badge comes from
						// (13 Nov 2026).
						let attention = certificates.needingAttention
						VStack(alignment: .leading, spacing: 3) {
							HStack {
								Text("Certificates")
									.layoutPriority(1)
								Spacer()
								Text(certificates.inUseName ?? "None")
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}
							if !attention.isEmpty {
								CertificatesAttentionLine(attention: attention)
							}
						}
					}
					if routeA.isSetUp {
						// Finished once its check has passed, whatever the
						// check finds since: Status says that.
						NavigationLink {
							InstallSetupView()
						} label: {
							LabeledContent("Setup", value: routeA.hasPassedCheck ? "Finished" : "Not finished")
						}
					} else {
						// With an Apple ID in use, Atelier doesn't install
						// without it (#49).
						InstallSetupCard(lead: certificates.defaultAppleID == nil ? nil : InstallSetupCard.appleIDLead) { settingUp = true }
					}
					NavigationLink("Advanced") {
						AdvancedInstallsView()
					}
				} header: {
					Text("Installs")
				} footer: {
					if routeA.isSetUp {
						Text("On Wi-Fi with LocalDevVPN connected, Atelier installs in the background and keeps apps' data when it signs them again. Elsewhere, it can still install apps, but can't install updates on its own.")
					} else {
						Text("A few minutes, once. It needs LocalDevVPN, a free App Store app, and works on Wi-Fi.")
					}
				}
				// Updates installed through route A (#72), which only the
				// setup makes possible, so they show once it's finished.
				if routeA.isSetUp {
					Section {
						AutoUpdatesToggle()
						Toggle("Only while charging", isOn: $autoUpdateWhileCharging)
							.disabled(!autoUpdate)
					} header: {
						Text("Updates")
					} footer: {
						Text("On Wi-Fi, Atelier downloads updates ahead, so Update only signs and installs. With this on, it installs them by itself, in the background, on Wi-Fi with LocalDevVPN connected.")
					}
					// Keeping apps' spots (9 Nov 2026), which reads and
					// moves icons through Direct installs.
					Section {
						Toggle("Keep apps’ spots", isOn: $keepsSpots)
						// Open Spaces: an iPhone's pages only, as Offload's
						// empty spots are.
						if keepsSpots, ThisDevice.name == "iPhone" {
							NavigationLink {
								YourGapsView()
							} label: {
								LabeledContent("Open Spaces", value: YourGaps.summary(YourGaps.decode(markedGaps)))
							}
						}
					} header: {
						Text("Home Screen")
					} footer: {
						if ThisDevice.name == "iPhone" {
							Text("When Atelier offloads an app, its spot stays empty until you reinstall it. When an app has to be deleted and installed again, it also retains its spot. Open spaces you’ve intentionally left between apps stay if you mark them here.")
						} else {
							Text("When Atelier offloads an app, or deletes it to install it again, it goes back where it was once it’s installed.")
						}
					}
				}
				// What background checks find (#19).
				Section {
					Toggle("Updates", isOn: $notifyUpdates)
					Toggle("News from sources", isOn: $notifyNews)
				} header: {
					Text("Notifications")
				} footer: {
					Text("Atelier checks your sources from time to time. It tells you when your apps have updates, and when a source marks news as important.")
				}
				Section("About") {
					VersionRow(version: version)
					NavigationLink {
						AtelierLicenseView()
					} label: {
						LabeledContent("License", value: "GPL-3.0")
					}
					NavigationLink("Acknowledgements") {
						AcknowledgementsView()
					}
				}
				TestActionsSection()
			}
			.navigationTitle("Settings")
			.navigationDestination(isPresented: $settingUp) {
				InstallSetupView()
			}
			// The setup counts as done once LocalDevVPN is installed, and
			// Status says whether it can install now: read again as the
			// network changes, such as LocalDevVPN connecting, and back in
			// Atelier.
			.task {
				await routeA.refresh()
				await routeA.watchNetwork()
			}
			// Status says when the install server doesn't answer.
			.task { await CheckupModel.shared.checkInstallServer() }
			.onChange(of: scenePhase) { _, phase in
				if phase == .active, routeA.isSetUp { Task { await routeA.refresh() } }
			}
			.onChange(of: autoUpdateWhileCharging) { AutoUpdates.schedule() }
			// Turned on, each asks to show notifications, if it hasn't yet.
			.onChange(of: notifyUpdates) { _, on in
				if on { Task { await CertificateNotifications.requestAuthorization() } }
			}
			.onChange(of: notifyNews) { _, on in
				if on { Task { await CertificateNotifications.requestAuthorization() } }
			}
		}
	}
}

/// Settings › About › Version. Tapped seven times, it shows or hides the
/// Test Actions section (#20).
private struct VersionRow: View {
	let version: String
	@AppStorage(TestActions.shownKey) private var testActionsShown = false
	@State private var taps = 0
	@State private var lastTap = Date.distantPast

	var body: some View {
		LabeledContent("Version", value: version)
			.contentShape(Rectangle())
			.onTapGesture {
				// Taps more than a second apart start the count again.
				taps = Date.now.timeIntervalSince(lastTap) < 1 ? taps + 1 : 1
				lastTap = .now
				guard taps == 7 else { return }
				taps = 0
				withAnimation { TestActions.setShown(!testActionsShown) }
			}
	}
}

/// Settings › Test Actions (#20), hidden until About › Version is tapped
/// seven times.
private struct TestActionsSection: View {
	@AppStorage(TestActions.shownKey) private var shown = false
	@AppStorage(TestActions.certificatesKey) private var certificateTests = false
	/// What Setup's check meets instead of iOS's install service, if anything.
	@AppStorage(TestActions.checkKey) private var checkTest = ""
	/// When the background check started from here runs (#19).
	@State private var startsAt: Date?
	/// What the last background check did.
	@State private var report: String?

	var body: some View {
		if shown {
			Section {
				Toggle(isOn: Binding(get: { certificateTests }, set: { TestActions.setCertificates($0) })) {
					Text("Certificate revocations and expirations")
					Text("Touch and hold a certificate in Certificates to test it as revoked or expired. Turning this off ends every test.")
				}
				// The setup check's fixes, on an iPhone whose install service
				// answers (1 Nov 2026).
				Picker(selection: Binding(get: { RouteASetup.TestFailure(rawValue: checkTest) }, set: { TestActions.setCheck($0) })) {
					Text("Off").tag(RouteASetup.TestFailure?.none)
					ForEach(RouteASetup.TestFailure.allCases, id: \.self) { failure in
						Text(failure.title).tag(Optional(failure))
					}
				} label: {
					Text("Install service failures")
					Text("Setup's check then meets a refusal (port 1) or no answer (192.0.2.1) instead of iOS's install service, and so do installs. The rest of the check runs for real, so Setup shows the fix it would offer.")
				}
				// A background update check on demand (#19).
				Button {
					TestActions.runBackgroundCheck()
					startsAt = .now.addingTimeInterval(10)
				} label: {
					VStack(alignment: .leading, spacing: 2) {
						Text("Run Background Check in 10 Seconds")
						if let startsAt, startsAt > .now {
							Text("Starts at \(startsAt.formatted(date: .omitted, time: .standard)). You can leave Atelier now.")
								.font(.footnote)
								.foregroundStyle(.secondary)
						} else if let report {
							Text(report)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				}
				// Picks up what a run did, also one in the background.
				.task {
					while !Task.isCancelled {
						report = UpdateChecks.lastReport?.summary
						try? await Task.sleep(for: .seconds(1))
					}
				}
				// Renewing an app's profile without waiting a week (#49).
				NavigationLink("End an App’s Profile") {
					RenewalTestView()
				}
				// The first launch's welcome and Get Ready, again (#21).
				Button("Show Welcome") { Welcome.shared.show() }
			} header: {
				Text("Test Actions")
			} footer: {
				Text("For Setup's Local Network fix, pick Refused and turn Local Network off for Atelier. Run Background Check does what iOS's background refresh does: refreshes your sources, downloads updates ahead on Wi-Fi, and notifies. With Install updates automatically on, it runs automatic updates instead, which install what they can by themselves. It forgets which updates and news it already told you about first, so they're told again. Show Welcome opens the welcome and Get Ready as on the first launch. Tapping Version seven times again hides this section and turns everything in it off.")
			}
		}
	}
}

/// Install updates automatically (#72), in Settings › Updates. Step 3 of
/// Settings › Installs › Setup, which makes it possible, held it too until
/// it only recommended turning it on (3 Nov 2026).
struct AutoUpdatesToggle: View {
	@AppStorage(AutoUpdates.enabledKey) private var on = false

	var body: some View {
		Toggle("Install updates automatically", isOn: Binding(get: { on }, set: { AutoUpdates.setEnabled($0) }))
	}
}
