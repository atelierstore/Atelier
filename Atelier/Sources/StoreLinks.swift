import CertKit
import DownloadKit
import InstallKit
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI
import UIKit

/// Links and files that open Atelier (#93): sources, installs, apps,
/// searches and certificates, on Atelier's scheme and on AltStore's,
/// SideStore's and Feather's, so their buttons on the web and other apps'
/// requests work with Atelier too, and .ipa and .tipa files opened in it.
/// RootView hands each one over, `StoreLinkHandling` acts on it, and
/// BrowseView goes where a link takes it.
@MainActor
@Observable
final class StoreLinks {
	static let shared = StoreLinks()

	/// Where a link takes Browse.
	enum BrowseRequest: Equatable {
		case search(String)
		case source(SourceRecord)
		case app(AppLink)
	}

	/// Links and files opened and not yet acted on.
	fileprivate(set) var opened: [URL] = []
	/// Set by a link, and cleared by BrowseView once it's there.
	var browseRequest: BrowseRequest?

	private init() {}

	func open(_ url: URL) {
		opened.append(url)
	}
}

/// Acts on what `StoreLinks` hands over (#93), asking first before
/// installing from a link, and before giving a certificate or the pairing
/// file to the app that asked for it, which only ever goes to an app.
/// AltStore installs from a link without asking, and SideStore sends the
/// pairing file without asking. An install link that names a source the
/// user doesn't have shows it to add first, saying the app installs then:
/// adding it is the go-ahead.
///
/// Over the first launch's welcome (#21), a source to add and a certificate
/// to import open their sheets on it; what needs the rest of Atelier, such
/// as an install, Browse or a sheet of its own, sets the welcome aside until
/// the next launch.
struct StoreLinkHandling: ViewModifier {
	@Binding var tab: RootView.Page
	let catalog: CatalogModel
	let certificates: CertificatesModel
	let installer: InstallModel
	@Environment(SourcesModel.self) private var sources
	@Environment(DownloadManager.self) private var downloads
	@Environment(\.modelContext) private var context
	@State private var links = StoreLinks.shared
	@State private var certificateRequest: CertificateRequest?
	@State private var settingUp = false
	/// An app link that came before Browse's apps had loaded, or for an app
	/// they don't list while the sources may still bring it, or whose source
	/// shows to add first; an install link whose source shows to add first,
	/// then waits for Browse's apps to have it.
	@State private var waiting: WaitingLink?
	/// Whether the add sheet shows the source `waiting`'s link names.
	@State private var addingLinkSource = false

	/// An app or install link, and the source it names, if any.
	private struct WaitingLink {
		enum Goal {
			case app(bundleID: String)
			case install(URL)
		}

		let goal: Goal
		let source: String?
		/// Whether that source was shown to add, added or not.
		var offeredSource = false

		/// What the add sheet says the source is needed for.
		var purpose: SourcesModel.LinkPurpose {
			switch goal {
			case .app(let bundleID): .app(bundleID: bundleID)
			case .install(let ipa): .install(ipa)
			}
		}
	}

	/// What a link asks the user, or tells them, in an alert.
	enum Question {
		/// With the added source the link names, which installs the IPA as
		/// it lists it, when it does.
		case install(URL, sourceURL: URL?)
		case exportPairingFile(AppCallback)
		/// A request for the pairing file before the setup made one.
		case noPairingFile(AppCallback)
		case notice(title: String, message: String)

		var title: String {
			switch self {
			case .install: "Install an app from this link?"
			case .exportPairingFile: "Export this \(ThisDevice.name)'s pairing file?"
			case .noPairingFile: "No pairing file yet"
			case .notice(let title, _): title
			}
		}

		var message: String {
			switch self {
			case .install(let ipa, _):
				"Atelier downloads \(Self.fileName(of: ipa)) from \(ipa.host() ?? ipa.absoluteString), then signs and installs it. Only install apps from developers you trust."
			case .exportPairingFile(let callback):
				"An app asked for this \(ThisDevice.name)'s pairing file, to be sent to \(callback.scheme)://. With it, that app can do on this \(ThisDevice.name) what a trusted computer can, such as installing apps. Only export it if you asked for it in that app."
			case .noPairingFile(let callback):
				"An app asked for this \(ThisDevice.name)'s pairing file, to be sent to \(callback.scheme)://. Atelier makes one when you finish setting it up, in Settings › Installs; then ask for it again in that app."
			case .notice(_, let message):
				message
			}
		}

		/// "Nimbus.ipa", or "the app" when the address doesn't end with the
		/// file's name.
		private static func fileName(of ipa: URL) -> String {
			let name = ipa.lastPathComponent
			return IPAPicker.extensions.contains((name as NSString).pathExtension.lowercased()) ? name : "the app"
		}
	}

	private struct CertificateRequest: Identifiable {
		let id = UUID()
		let callback: AppCallback
	}

	func body(content: Content) -> some View {
		content
			.onChange(of: links.opened, initial: true) { _, opened in
				guard !opened.isEmpty else { return }
				links.opened = []
				for url in opened { act(on: url) }
			}
			.onChange(of: catalog.isBuilding) { continueWaitingLink() }
			.onChange(of: sources.isRefreshing) { continueWaitingLink() }
			// The add sheet closed on the source a link names: the app next,
			// from that source once it's added.
			.onChange(of: sources.draft == nil) { _, closed in
				guard closed, addingLinkSource else { return }
				addingLinkSource = false
				continueWaitingLink()
			}
			.sheet(item: $certificateRequest) { request in
				CertificateExportView(callback: request.callback, certificates: certificates) { certificate in
					certificateRequest = nil
					Task { await export(certificate, to: request.callback) }
				}
			}
			.sheet(isPresented: $settingUp) {
				NavigationStack {
					InstallSetupView()
						.toolbar {
							ToolbarItem(placement: .confirmationAction) {
								Button("Done") { settingUp = false }
							}
						}
				}
			}
	}

	/// Asks or tells the user in an alert, which UIKit shows on top of
	/// whatever is showing, a sheet too. SwiftUI's alert was lost when it
	/// came while a sheet or another alert was closing, as "Couldn't open …"
	/// does after Export, and after that no link's alert showed until
	/// Atelier was quit.
	private func ask(_ question: Question) {
		let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
		switch question {
		case .install(let ipa, let sourceURL):
			let install = UIAlertAction(title: "Install", style: .default) { _ in
				installIPA(ipa, from: sourceURL)
			}
			alert.addAction(install)
			alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
			alert.preferredAction = install
		case .exportPairingFile(let callback):
			alert.addAction(UIAlertAction(title: "Export Pairing File", style: .default) { _ in
				Task { await exportPairingFile(to: callback) }
			})
			alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
		case .noPairingFile:
			alert.addAction(UIAlertAction(title: "Finish Setting Up", style: .default) { _ in
				// The setup's sheet is under the welcome.
				Welcome.shared.stepAside()
				Task {
					_ = await DocumentPicker.settledTop()
					settingUp = true
				}
			})
			alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
		case .notice:
			alert.addAction(UIAlertAction(title: "OK", style: .cancel))
		}
		Task {
			guard let top = await DocumentPicker.settledTop() else { return }
			top.present(alert, animated: true)
		}
	}

	private func act(on url: URL) {
		if url.isFileURL {
			if IPAPicker.extensions.contains(url.pathExtension.lowercased()) {
				// Installs straight away, as Choose IPA File does, and as
				// AltStore and Feather do with these files.
				Welcome.shared.stepAside()
				tab = .library
				installer.install(picked: url, certificates: certificates, into: context)
			} else {
				// A .p12, profile or ZIP shared to Atelier opens the import sheet with it.
				certificates.add([url])
			}
			return
		}
		// LocalDevVPN switching back after connecting (#9).
		if RouteASetup.isCallback(url) { return }
		do {
			guard let link = try StoreLink(url) else { return }
			follow(link)
		} catch {
			ask(.notice(title: "Atelier can't open this link", message: (error as? StoreLink.Problem)?.description ?? error.localizedDescription))
		}
	}

	private func follow(_ link: StoreLink) {
		switch link {
		case .source(let link):
			// It takes over the add sheet from an app or install link's
			// source, and that link is done.
			if addingLinkSource {
				addingLinkSource = false
				waiting = nil
			}
			// Sources are in Browse (#38).
			tab = .browse
			if let source = sources.addedSource(link) {
				// Rather than saying it's already added.
				Welcome.shared.stepAside()
				links.browseRequest = .source(source)
			} else {
				// Shows the source and asks before adding it (#13, #83), on
				// its own tab.
				sources.add(link: link, for: .source)
			}
		case .install(let ipa, let source):
			if let source, sources.addedSource(source) == nil {
				// Its source to add first; it takes over from another link's,
				// as a source link does.
				addingLinkSource = false
				waiting = WaitingLink(goal: .install(ipa), source: source)
				continueWaitingLink()
			} else {
				ask(.install(ipa, sourceURL: source.flatMap { sources.addedSource($0) }?.url))
			}
		case .viewApp(let bundleID, let source):
			// It takes over from a link whose source the add sheet shows, as
			// a source link does.
			addingLinkSource = false
			waiting = WaitingLink(goal: .app(bundleID: bundleID), source: source)
			continueWaitingLink()
		case .search(let text):
			Welcome.shared.stepAside()
			tab = .browse
			links.browseRequest = .search(text)
		case .importCertificate(let p12, let profile, let password):
			// Import saves it, as with files from the Files app.
			let files = CertificateFiles(
				p12: CertificateFiles.File(name: "Certificate.p12", data: p12),
				profile: CertificateFiles.File(name: "Profile.mobileprovision", data: profile)
			)
			certificates.draft = CertificatesModel.Draft(files: files, password: password)
		case .exportCertificate(let callback):
			if Self.exportable(certificates).isEmpty {
				ask(.notice(
					title: "No certificate to export",
					message: "An app asked for a certificate, to be sent to \(callback.scheme)://, but Atelier has none that can still sign. Import one in Settings › Installs › Certificates, then ask for it again in that app."
				))
			} else {
				// Its sheet is under the welcome.
				Welcome.shared.stepAside()
				certificateRequest = CertificateRequest(callback: callback)
			}
		case .exportPairingFile(let callback):
			ask(RouteASetup.shared.isPaired ? .exportPairingFile(callback) : .noPairingFile(callback))
		case .unsupported(let store):
			let what = store == "Atelier" ? "this version of Atelier doesn't do" : "only \(store) does"
			ask(.notice(
				title: "Atelier can't open this link",
				message: "It's for something \(what). Atelier opens links that add a source, install an app, show an app or search."
			))
		}
	}

	/// Goes on with a link to an app or an install. It can name the source
	/// the app comes from: when the user doesn't have it, it shows to add
	/// first, as a link to it would, saying why, so one link works for
	/// someone without the source too; then the app, from that source.
	private func continueWaitingLink() {
		guard let link = waiting, !addingLinkSource else { return }
		if let source = link.source, !link.offeredSource, sources.addedSource(source) == nil {
			waiting?.offeredSource = true
			addingLinkSource = true
			// Sources are in Browse (#38), where the app opens; an install
			// shows in the Library once it starts.
			if case .app = link.goal { tab = .browse }
			sources.add(link: source, for: link.purpose)
			return
		}
		switch link.goal {
		case .app(let bundleID): showApp(bundleID, for: link)
		case .install(let ipa): installLinked(ipa, for: link)
		}
	}

	/// Opens the page of the app a link asked for in Browse, as AltStore's
	/// links to an app do, once Browse's apps have loaded, or says that no
	/// source lists it. That waits for the sources to refresh: Browse first
	/// shows them as saved, which may not list a new app yet.
	private func showApp(_ bundleID: String, for link: WaitingLink) {
		guard catalog.isLoaded else { return }
		// The source the link names, when the user has it.
		let named = link.source.flatMap { sources.addedSource($0) }
		let namedURL = named?.url
		let entry = Self.entry(bundleID, in: catalog.catalog, preferring: namedURL)
		if let entry, named == nil || entry.offers.contains(where: { $0.source.url == namedURL }) {
			show(entry, from: namedURL)
			return
		}
		// From another source than the one named, or that none lists it, only
		// once Browse's apps are current: they may not have the named one's
		// yet, such as one just added.
		guard appsAreCurrent else { return }
		if let entry {
			show(entry, from: nil)
			return
		}
		waiting = nil
		if let named {
			ask(.notice(
				title: "No source lists this app",
				message: "The link opens \(bundleID) from \(named.name), which doesn't list it now."
			))
		} else if !link.offeredSource {
			ask(.notice(
				title: "No source lists this app",
				message: "The link opens \(bundleID), and none of your sources list it. Add the source it comes from, then open the link again."
			))
		}
		// Otherwise the user didn't add the source the link names, and the add
		// sheet said why it couldn't be added, if it couldn't.
	}

	/// Opens an app link's app in Browse, from the source at `sourceURL`, or
	/// from the one with the newest version.
	private func show(_ entry: Catalog.Entry, from sourceURL: URL?) {
		waiting = nil
		Welcome.shared.stepAside()
		tab = .browse
		links.browseRequest = .app(AppLink(entry, sourceURL: sourceURL))
	}

	/// Installs an install link's IPA once the user added the source the
	/// link names, from the sheet that said the app installs then: as the
	/// source lists it, once Browse's apps have it. Otherwise it asks first,
	/// as for any install link: when the user didn't add the source, changed
	/// it in the sheet, or it doesn't list the IPA.
	private func installLinked(_ ipa: URL, for link: WaitingLink) {
		let named = link.source.flatMap { sources.addedSource($0) }
		if let named, sources.lastAddedLink == link.purpose {
			guard catalog.isLoaded else { return }
			if Self.listing(of: ipa, from: named.url, in: catalog.catalog) != nil {
				waiting = nil
				installIPA(ipa, from: named.url)
				return
			}
			// They may not have the added source's apps yet.
			guard appsAreCurrent else { return }
		}
		waiting = nil
		ask(.install(ipa, sourceURL: named?.url))
	}

	/// Downloads, signs and installs an install link's IPA, as the source at
	/// `sourceURL` lists it when it does, so the app's updates come from
	/// there, as its Install button would; otherwise as Download from URL
	/// does. Either way, the download shows in the Library, then the
	/// install in the install bar.
	private func installIPA(_ ipa: URL, from sourceURL: URL?) {
		Welcome.shared.stepAside()
		tab = .library
		guard let sourceURL,
		      let listed = Self.listing(of: ipa, from: sourceURL, in: catalog.catalog),
		      let version = listed.version.downloading(ipa)
		else {
			installer.install(url: ipa, downloads: downloads, certificates: certificates, into: context)
			return
		}
		let app = listed.offer.app
		// Another of the version's builds than Browse installs (#30): the one
		// the link names, kept for updates, as when the user picks it.
		if listed.version.downloadURL != ipa, let build = listed.version.builds.first(where: { $0.downloadURL == ipa }) {
			BuildChoices.choose(build, for: app.bundleID, sourceURL: sourceURL)
			catalog.buildChoicesChanged()
		}
		// Over the app when it's installed, as itself (#81).
		let installed = InstalledApps.record(listedAs: app.bundleID, in: context)
		installer.install(version, of: app, from: sourceURL, over: installed, offers: [listed.offer], downloads: downloads, certificates: certificates, into: context)
	}

	/// The app and version of it that the source at `sourceURL` lists with
	/// the IPA at `ipa`, as Browse shows the source's apps, with or without
	/// its betas (#104): the version's own IPA or one of its builds' (#30).
	private static func listing(of ipa: URL, from sourceURL: URL, in apps: Catalog) -> (offer: Catalog.Offer, version: AppVersion)? {
		for entry in apps.source(url: sourceURL)?.apps ?? [] {
			let offer = entry.offer(from: sourceURL)
			if let version = offer.app.versions.first(where: { $0.downloading(ipa) != nil }) {
				return (offer, version)
			}
		}
		return nil
	}

	/// Whether Browse's apps are those of the sources as they are now, all
	/// refreshed.
	private var appsAreCurrent: Bool {
		!sources.isRefreshing && catalog.isCurrent(for: (try? context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.addedAt)]))) ?? [])
	}

	/// The app with this bundle ID, or with it in another case when none has
	/// it as the link writes it: as the source at `sourceURL` lists it, when
	/// that one does.
	private static func entry(_ bundleID: String, in apps: Catalog, preferring sourceURL: URL?) -> Catalog.Entry? {
		var matches = apps.entries.filter { $0.bundleID == bundleID }
		if matches.isEmpty {
			matches = apps.entries.filter { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
		}
		return matches.first { entry in entry.offers.contains { $0.source.url == sourceURL } } ?? matches.first
	}

	/// The certificates another app can be given, the one in use first:
	/// not revoked or expired.
	static func exportable(_ certificates: CertificatesModel) -> [StoredCertificate] {
		let usable = certificates.certificates.filter { certificate in
			switch CertificateAttention(certificate) {
			case .revoked, .expired: false
			case .expiring, nil: true
			}
		}
		return usable.filter { $0.id == certificates.defaultID } + usable.filter { $0.id != certificates.defaultID }
	}

	/// Opens the app that asked with the certificate's .p12 and password.
	private func export(_ certificate: StoredCertificate, to callback: AppCallback) async {
		let p12: Data
		let password: String
		do {
			guard let identity = try certificates.signingIdentity(for: certificate.id) else {
				throw CocoaError(.fileNoSuchFile)
			}
			p12 = try Data(contentsOf: identity.p12)
			password = identity.password
		} catch {
			ask(.notice(title: "Couldn't export the certificate", message: error.localizedDescription))
			return
		}
		await send(callback.url(certificate: p12, password: password), to: callback)
	}

	/// Opens the app that asked with the pairing file.
	private func exportPairingFile(to callback: AppCallback) async {
		let file: Data
		do {
			file = try PairingFileStore.standard().load()
		} catch {
			ask(.notice(title: "Couldn't export the pairing file", message: error.localizedDescription))
			return
		}
		await send(callback.url(pairingFile: Self.xmlPropertyList(file)), to: callback)
	}

	private func send(_ url: URL?, to callback: AppCallback) async {
		if let url, await UIApplication.shared.open(url) { return }
		ask(.notice(
			title: "Couldn't open \(callback.scheme)://",
			message: "No app on this \(ThisDevice.name) opens \(callback.scheme):// links, so nothing was sent."
		))
	}

	/// The pairing file as an XML property list, the way SideStore keeps and
	/// sends its own, whichever way it was saved.
	private static func xmlPropertyList(_ data: Data) -> Data {
		guard
			let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
			let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
		else { return data }
		return xml
	}
}

/// Export Certificate (#93): an app such as LiveContainer asked for a
/// certificate. The one in use is picked; Export gives that app the .p12
/// and its password.
private struct CertificateExportView: View {
	let callback: AppCallback
	let certificates: CertificatesModel
	let export: (StoredCertificate) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var picked: UUID?

	var body: some View {
		let exportable = StoreLinkHandling.exportable(certificates)
		NavigationStack {
			VStack(spacing: 0) {
				Form {
					Section {
						Label {
							Text("An app asked for a certificate, to be sent to \(Text(verbatim: "\(callback.scheme)://").bold()). It gets the .p12 and its password, and can sign apps with it until the certificate expires or is revoked. Only export one if you asked for it in that app.")
								.font(.subheadline)
						} icon: {
							Image(systemName: "exclamationmark.shield.fill")
								.foregroundStyle(.orange)
						}
					}
					Section {
						ForEach(exportable) { certificate in
							Button {
								picked = certificate.id
							} label: {
								row(certificate)
							}
						}
					} header: {
						Text("Certificate")
					} footer: {
						Text("The one in use is picked. Revoked and expired certificates aren't listed.")
					}
				}
				Button {
					if let certificate = exportable.first(where: { $0.id == picked }) { export(certificate) }
				} label: {
					Text("Export")
						.bold()
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.large)
				.disabled(!exportable.contains { $0.id == picked })
				.padding(.horizontal)
				.padding(.vertical, 8)
			}
			.background(Color(.systemGroupedBackground))
			.navigationTitle("Export Certificate")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
		.onAppear {
			if picked == nil { picked = exportable.first?.id }
		}
	}

	private func row(_ certificate: StoredCertificate) -> some View {
		let inUse = certificate.id == certificates.defaultID
		return HStack(spacing: 12) {
			CertificateTile(certificate: certificate)
			VStack(alignment: .leading, spacing: 2) {
				Text(certificate.displayName)
					.font(.headline)
					.lineLimit(1)
				Text([inUse ? "In use" : nil, certificate.profile.kind.title, certificate.remainingText()].compactMap { $0 }.joined(separator: " · "))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 8)
			if certificate.id == picked {
				Image(systemName: "checkmark")
					.font(.body.weight(.semibold))
					.foregroundStyle(.tint)
			}
		}
		.foregroundStyle(.primary)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(certificate.id == picked ? .isSelected : [])
	}
}
