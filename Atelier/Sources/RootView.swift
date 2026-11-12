import CertKit
import DownloadKit
import InstallKit
import AtelierCore
import SourceKit
import SwiftData
import SwiftUI

struct RootView: View {
	enum Page {
		case browse, library, settings
	}

	@State private var certificates = CertificatesModel.shared
	@State private var catalog = CatalogModel()
	@State private var installer = InstallModel.shared
	@Query(sort: \SourceRecord.addedAt) private var sourceRecords: [SourceRecord]
	@Query private var installs: [InstallRecord]
	@State private var tab = Page.browse
	/// A certificate just imported, offered for installs (#20).
	@State private var importOffer: ImportOffer?
	/// The first launch's welcome (#21), which opens its own sheets.
	@State private var welcome = Welcome.shared
	@Environment(SourcesModel.self) private var sources
	@Environment(DownloadManager.self) private var downloads
	@Environment(\.modelContext) private var context
	@Environment(\.scenePhase) private var scenePhase

	private var items: [LibraryItem] {
		installs.map { LibraryItem($0, catalog: catalog.catalog, certificates: certificates, installer: installer) }
	}

	/// The certificates and the Apple IDs there are, which Atelier's own
	/// Library entry follows (#24, #152). Apart from the body, which is as
	/// long as the compiler type-checks.
	private var signerIDs: [UUID] {
		let imported = certificates.certificates.map(\.id)
		let signedIn = certificates.appleIDs.map(\.id)
		return imported + signedIn
	}

	/// What Atelier shows while it's in front, which then counts as told
	/// (#19).
	private struct Shown: Hashable {
		var updates: [String]
		var news: [String]
		var active: Bool
	}

	/// A certificate imported while the one in use was revoked, had expired
	/// or ran out within 14 days (#20).
	struct ImportOffer {
		let certificate: StoredCertificate
		/// The one in use.
		let replacing: StoredCertificate
		let attention: CertificateAttention
		/// The apps signed with the one in use that are still installed.
		let apps: Int

		/// "Signulous Development, the certificate in use, was revoked. 4
		/// apps signed with it won't open until they're re-signed."
		var message: String {
			let name = replacing.displayName
			let cause = switch attention {
			case .revoked: "\(name), the certificate in use, was revoked."
			case .expired: "\(name), the certificate in use, has expired."
			case .expiring(let days): "\(name), the certificate in use, expires \(days == 1 ? "within a day" : "in \(days) days")."
			}
			guard apps > 0 else { return cause }
			let effect = switch attention {
			case .revoked, .expired:
				apps == 1 ? "1 app signed with it won't open until it's re-signed." : "\(apps) apps signed with it won't open until they're re-signed."
			case .expiring:
				apps == 1 ? "1 app signed with it stops opening then unless it's re-signed." : "\(apps) apps signed with it stop opening then unless they're re-signed."
			}
			return "\(cause) \(effect)"
		}
	}

	var body: some View {
		let items = items
		// The Library's updates, leaving out skipped versions (#18),
		// downloaded or not (#19).
		let updates = items.filter { $0.update != nil }
		// Updates, and apps to re-sign (#20).
		let libraryCount = items.filter { $0.needsResign || $0.update != nil }.count
		TabView(selection: $tab) {
			// The sheet that says to go to the Home Screen comes up on the
			// tab in front (#123).
			BrowseView()
				.installBar(front: tab == .browse)
				.tabItem { Label("Browse", systemImage: "square.grid.2x2") }
				.tag(Page.browse)
			LibraryView()
				.installBar(front: tab == .library)
				.tabItem { Label("Library", systemImage: "square.stack") }
				.tag(Page.library)
				// Updates, leaving out skipped versions (#18), and apps to
				// re-sign (#20).
				.badge(libraryCount)
			SettingsView()
				.installBar(front: tab == .settings)
				.tabItem { Label("Settings", systemImage: "gearshape") }
				.tag(Page.settings)
				// Revoked, expired or soon expiring certificates (#5).
				.badge(certificates.needingAttention)
		}
		.environment(certificates)
		.environment(catalog)
		.environment(installer)
		// Signing an app for another App ID asks first, wherever it starts (#76).
		.modifier(ReplaceConfirmation(installer: installer, catalog: catalog, certificates: certificates, downloads: downloads))
		// So does an install over an app on this iPhone that iOS won't
		// replace with it, once Direct installs have checked (#99).
		.modifier(InstalledConflictAlert(installer: installer, onDetails: false))
		// Apple's code, and the trust sheet, for installs with an Apple ID (#49).
		.modifier(AppleIDInstallPrompts(installer: installer, onDetails: false))
		// So does Atelier's install over itself, which closes it (#24).
		.modifier(SelfInstallConfirmation(installer: installer, certificates: certificates))
		// Custom Install's sheet (#155), and an IPA of an installed app, which
		// installs over it or as a copy (#113).
		.modifier(CopyPrompts(installer: installer, catalog: catalog, certificates: certificates, downloads: downloads))
		// Links and files from web pages and other apps, and what they ask
		// first (#93).
		.modifier(StoreLinkHandling(tab: $tab, catalog: catalog, certificates: certificates, installer: installer))
		// Open, when iOS didn't open an app Atelier can't tell is still here (#55).
		.modifier(OpenFailedAlert())
		// A download from a pasted URL, or one a one-tap install was waiting
		// on when Atelier was ended, installs once it's finished and
		// Atelier is in front.
		.onChange(of: downloads.downloads) {
			installer.installFinishedDownloads(downloads, certificates: certificates, into: context)
		}
		// Those carried over from before Atelier was opened wait while what
		// the user asked for is under way, and go once it's done.
		.onChange(of: installer.carriedOverMayStart) { _, mayStart in
			if mayStart { installer.installFinishedDownloads(downloads, certificates: certificates, into: context) }
		}
		.onChange(of: scenePhase, initial: true) { _, phase in
			// Once Atelier leaves the screen, its row no longer says it was
			// just updated (#24).
			if phase == .background { SelfUpdate.shared.forgetRelaunch() }
			guard phase == .active else { return }
			// The certificate the iPhone-only installer left with its key,
			// for its Apple ID's sign-in, out of the folder it wrote to; then
			// that sign-in, which Atelier makes by itself once (#152).
			certificates.keepInstallerCertificate()
			certificates.signInAsInstaller()
			// Atelier in the Library as it runs, and how the install of
			// itself that closed it ended (#24).
			SelfUpdate.shared.launched(in: context, certificates: certificates, downloads: downloads)
			// What that install left with iOS to say how it went, as the
			// install bar says it now, once its log says what iOS still had.
			SelfInstallNotice.shared.withdraw()
			installer.installFinishedDownloads(downloads, certificates: certificates, into: context)
			// Revocation checks on launch and on coming back, at most hourly
			// (#5), then the Apple ID apps whose profile ends within two days
			// (#49).
			Task {
				await certificates.refreshStatus()
				await ProfileRenewals.shared.renewDue(.opened)
			}
			// The sources, when they weren't read for a while, for Atelier's
			// own update too (#24).
			Task { await sources.refreshIfStale() }
			// The next automatic update run, unless one is waiting (#72).
			AutoUpdates.scheduleIfNeeded()
		}
		// The Apple ID apps a renewal waited on installs for (#49).
		.onChange(of: installer.isRunning) { _, running in
			guard !running, installer.waiting.isEmpty, scenePhase == .active else { return }
			Task { await ProfileRenewals.shared.renewDue(.opened) }
		}
		// Said in the install bar once the sources are there for Try again.
		.onChange(of: catalog.isLoaded, initial: true) { _, loaded in
			guard loaded else { return }
			SelfUpdate.shared.launched(in: context, certificates: certificates, downloads: downloads)
			installer.reportRelaunch(catalog: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
		}
		// The certificate Atelier was installed with, once it's imported
		// (#24), and the apps of a deleted certificate imported again (#126).
		// Atelier becomes one of the apps of the Apple ID that installed it
		// once that one signs in too, and stops being one once it signs out
		// (#152).
		.onChange(of: signerIDs) {
			SelfUpdate.shared.syncRecord(in: context, certificates: certificates)
			certificates.relinkInstalls(in: context)
		}
		// A failed install's fix can lead to Settings: the install settings
		// or storage.
		.onChange(of: installer.settingsRequested) { _, requested in
			guard requested else { return }
			installer.settingsRequested = false
			tab = .settings
		}
		// A tapped installs or updates notification (#72, #19).
		.onChange(of: installer.libraryRequested, initial: true) { _, requested in
			guard requested else { return }
			installer.libraryRequested = false
			tab = .library
		}
		// A tapped news notification (#19).
		.onChange(of: installer.browseRequested, initial: true) { _, requested in
			guard requested else { return }
			installer.browseRequested = false
			tab = .browse
		}
		// Updates and news seen here aren't told about later, and downloads
		// started ahead for updates that went are deleted (#19).
		.task(id: Shown(
			updates: updates.compactMap { item in item.update.map { "\(item.install.bundleID) \(UpdateCheck.key(of: $0))" } },
			news: catalog.catalog.news.map(\.id),
			active: scenePhase == .active && catalog.isLoaded
		)) {
			guard scenePhase == .active, catalog.isLoaded else { return }
			UpdateChecks.markSeen(updates: updates, news: catalog.catalog.news)
			UpdateChecks.removeUnneeded(updates, downloads: downloads)
		}
		// Browse's catalog follows the sources: added, refreshed or removed.
		.task(id: CatalogModel.stamps(sourceRecords)) { catalog.update(from: sourceRecords) }
		// So does what says a source needs a GitHub sign-in (#134).
		.modifier(SignInNeededTracking(records: sourceRecords, sources: sources))
		.onOpenURL { url in
			// Sources, installs, certificates and the rest, on AltStore's,
			// SideStore's and Feather's schemes too, and files shared to
			// Atelier: StoreLinkHandling acts on them (#93).
			StoreLinks.shared.open(url)
		}
		// Sources refresh on launch, and in the background (#19).
		.task { await sources.refreshAll() }
		// Apps installed before Atelier kept the bundle ID their source
		// lists them under, when their IPA has another (#116), from the
		// install history, read off the main thread.
		.task {
			let attempts = await Task.detached { (try? InstallHistory.standard())?.attempts() ?? [] }.value
			InstalledApps.noteListings(from: attempts, in: context)
		}
		// Apps whose certificate was deleted and imported again before
		// Atelier gave it back its ID (#126).
		.task { certificates.relinkInstalls(in: context) }
		// The certificate a copy of Atelier came with (#113), now that the
		// welcome, made with this view, has decided to come up: it still
		// does, with Get Ready's certificate done.
		.task { certificates.importPackagedCertificate() }
		// The icons of apps that are no longer in the Library (#118), their
		// own ones too, what was chosen for them, and where their IPAs are
		// (#113, #155).
		.task {
			guard let records = try? context.fetch(FetchDescriptor<InstallRecord>()) else { return }
			let installed = Set(records.map(\.bundleID))
			InstalledIcons.shared.keep(only: installed)
			InstalledIcons.own.keep(only: installed)
			CopyStore.shared.keep(only: installed)
			IPAOrigins.shared.keep(only: installed)
		}
		// Adding a source, from Browse's + button or a source link; over the
		// welcome, the welcome opens it (#21).
		.sheet(isPresented: Binding(
			get: { sources.draft != nil && !welcome.isShowing },
			set: { if !$0 { sources.cancelAdd() } }
		)) {
			SourceAddView()
				.environment(sources)
		}
		.alert("Couldn't remove the source", isPresented: Binding(
			get: { sources.error != nil },
			set: { if !$0 { sources.error = nil } }
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(sources.error ?? "")
		}
		.sheet(isPresented: Binding(
			get: { certificates.draft != nil && !welcome.isShowing },
			set: { if !$0 { certificates.draft = nil } }
		), onDismiss: offerImported) {
			CertificateImportView()
				.environment(certificates)
		}
		// On the first launch with no certificate, and from Test Actions:
		// the welcome, then Get Ready (#21). A certificate imported there is
		// offered once it closes.
		.modifier(WelcomeCover(welcome: welcome, certificates: certificates, onDismiss: offerImported))
		// Sign In with Apple ID, from Certificates' + (#49); over the
		// welcome, the welcome opens it, from Get Ready.
		.modifier(AppleIDSignInSheet(certificates: certificates, isShown: !welcome.isShowing))
		.alert(
			importOffer.map { "Use “\($0.certificate.displayName)” for installs?" } ?? "",
			isPresented: Binding(get: { importOffer != nil }, set: { if !$0 { importOffer = nil } }),
			presenting: importOffer
		) { offer in
			if offer.apps > 0 {
				Button("Use It and Re-sign All") { use(offer, resigning: true) }
			}
			Button("Use It") { use(offer, resigning: false) }
			Button("Not Now", role: .cancel) {}
		} message: { offer in
			Text(offer.message)
		}
	}

	/// Once a certificate is imported, offers it for installs when the one
	/// in use was revoked, has expired or runs out within 14 days, and to
	/// re-sign the apps signed with that one (#20). Until now, an imported
	/// certificate was only used when none was.
	private func offerImported() {
		guard let id = certificates.justImported else { return }
		certificates.justImported = nil
		guard let imported = certificates.certificates.first(where: { $0.id == id }),
		      CertificatesModel.canResign(with: imported),
		      let current = certificates.defaultCertificate, current.id != id,
		      let attention = CertificateAttention(current)
		else { return }
		let apps = installs.filter { $0.certificateID == current.id && InstallModel.presence(of: $0) != .deleted }.count
		importOffer = ImportOffer(certificate: imported, replacing: current, attention: attention, apps: apps)
	}

	/// Use It, and with `resigning`, Re-sign All in the Library.
	private func use(_ offer: ImportOffer, resigning: Bool) {
		certificates.makeDefault(offer.certificate.id)
		guard resigning else { return }
		tab = .library
		installer.resignRequested = true
	}
}

/// Keeps `SourcesModel.signInNeeded` to the sources whose last refresh
/// found them in a GitHub repo that only an account can read, while there's
/// none (#134), for the warnings on every screen. A modifier of its own:
/// in `RootView`'s body, the compiler couldn't type-check it in time.
private struct SignInNeededTracking: ViewModifier {
	let records: [SourceRecord]
	let sources: SourcesModel

	func body(content: Content) -> some View {
		content.onChange(of: Set(records.filter(\.needsGitHubSignIn).map(\.url)), initial: true) { _, urls in
			sources.signInNeeded = urls
		}
	}
}

/// The welcome and Get Ready over the whole app (#21). A modifier of its
/// own, so `RootView`'s body still type-checks in time. What it shows only
/// gets the environment from above `RootView`, so the certificates are
/// passed on.
private struct WelcomeCover: ViewModifier {
	let welcome: Welcome
	let certificates: CertificatesModel
	let onDismiss: () -> Void

	func body(content: Content) -> some View {
		// Read here rather than in the binding, so the cover surely follows it.
		let isShowing = welcome.isShowing
		content.fullScreenCover(isPresented: Binding(
			get: { isShowing },
			set: { if !$0 { welcome.stepAside() } }
		), onDismiss: onDismiss) {
			WelcomeFlow()
				.environment(certificates)
		}
	}
}

#Preview {
	let container = try! Persistence.makeContainer(inMemory: true)
	return RootView()
		.environment(SourcesModel(library: SourceLibrary(context: container.mainContext, gitHub: GitHubAccess.source())))
		.environment(BackgroundDownloads.shared.manager)
		.modelContainer(container)
}
