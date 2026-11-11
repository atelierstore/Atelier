import DownloadKit
import InstallKit
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI

/// App details' Install button (#16). Install or Update runs the one-tap
/// install: checks, download, signing and install, with the install bar
/// showing each step. While it runs, the button is a progress ring across
/// all of them, and tapping it cancels the install; while it waits behind
/// another install, Waiting takes it off the queue. A long press offers to
/// install a copy of the app, named in a prompt that suggests a name to
/// tell the copies apart (#113), or to update a copy (#8, `CopyMenu`).
///
/// When more than one source lists the app, the long press also offers to
/// install it from any of them, each with the version it would install;
/// a tap installs from `sourceURL` (#38).
///
/// When a version comes in several builds (a GitHub release with a debug
/// build, say, #30), the first tap asks which one, with the recommended one
/// first; the choice is kept for updates, and the long press changes it.
///
/// App list rows (#38) use the compact one, where Not Installable is a
/// crossed-out circle; the row's details say why. There, the whole row
/// has the long press's menu instead (`AppMenu`, #113).
///
/// Version History's rows (#78) each install their own version: one shows
/// its install while it runs, and the others wait for it.
///
/// On an app's page, once Atelier installed the app (#81), Install, Update
/// and the long press's other sources install over it, as itself or the
/// copy it is, asking first when iOS can't replace it (#76).
struct InstallButton: View {
	let app: SourceApp
	let action: InstallAction
	let sourceURL: URL
	/// Every source's listing of the app, for the long-press menu.
	var offers: [Catalog.Offer] = []
	var compact = false
	/// Version History's: shows only this version's install.
	var versionOnly = false
	/// The app as Atelier installed it, which can be a copy (#8).
	var installed: InstallRecord?
	/// Off in a list row, whose whole row has the long press's menu (#113).
	var showsMenu = true
	@Environment(InstallModel.self) private var installer
	@Environment(DownloadManager.self) private var downloads
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context
	/// The version whose build the user is choosing.
	@State private var choosingBuild: AppVersion?

	var body: some View {
		button
			.modifier(BuildChoice(app: app, sourceURL: sourceURL, version: $choosingBuild) { install($0, of: app, from: sourceURL) })
	}

	@ViewBuilder
	private var button: some View {
		let appKey = InstallModel.AppKey(bundleID: app.bundleID, sourceURL: sourceURL)
		if let status = installStatus {
			InstallStatusButton(title: action.title, status: status) {}
		} else {
			switch action {
			case .install(let version), .update(let version):
				InstallStatusButton(title: action.title, status: nil) {
					if version.hasBuildChoice, BuildChoices.chosenKind(app.bundleID, sourceURL: sourceURL) == nil {
						choosingBuild = version
					} else {
						install(version, of: app, from: sourceURL)
					}
				}
				// In Version History, while another version installs.
				.disabled(versionOnly && installer.status(of: appKey) != nil)
				.modifier(menu(version))
			case .open where isOwn:
				// Atelier is open already (#24); a copy of it opens (#113).
				EmptyView()
			case .open:
				// By its bundle ID, or the check scheme it was signed with
				// (#55), while Atelier knows it's on this iPhone. Its IPA
				// can have another bundle ID than its source lists (#116).
				let install = installed ?? InstalledApps.record(listedAs: app.bundleID, in: context)
				InstallStatusButton(title: action.title, prominent: false, status: nil) {
					if let install { InstallModel.open(install) }
				}
				.disabled(install.map { InstallModel.presence(of: $0) != .installed } ?? true)
				.modifier(menu(app.availability().version))
			case .notInstallable where compact:
				Button {} label: {
					Image(systemName: "nosign")
						.font(.subheadline.bold())
				}
				.buttonStyle(.bordered)
				.buttonBorderShape(.circle)
				.disabled(true)
				.accessibilityLabel(action.title)
			case .notInstallable:
				InstallStatusButton(title: action.title, status: nil) {}
					.disabled(true)
			}
		}
	}

	/// Atelier as it runs, rather than a copy of it.
	private var isOwn: Bool {
		installed.map { SelfUpdate.shared.isOwn($0) } ?? SelfUpdate.shared.isOwnApp(app.bundleID)
	}

	/// The app's install from this source, waiting or running; in Version
	/// History, only this version's.
	private var installStatus: InstallModel.AppStatus? {
		switch action {
		case .install(let version) where versionOnly, .update(let version) where versionOnly:
			installer.status(of: app, version: version, sourceURL: sourceURL)
		default:
			installer.status(of: InstallModel.AppKey(bundleID: app.bundleID, sourceURL: sourceURL))
		}
	}

	/// Over the installed app when there is one, as itself or the copy it
	/// is (#81).
	private func install(_ version: AppVersion, of app: SourceApp, from url: URL) {
		installer.install(version, of: app, from: url, over: installed, offers: offers, downloads: downloads, certificates: certificates, into: context)
	}

	/// The long press's menu, with `version` for a copy to install.
	private func menu(_ version: AppVersion?) -> AppMenu {
		AppMenu(app: app, version: version, sourceURL: sourceURL, offers: offers, installed: installed, isEnabled: showsMenu)
	}
}

extension InstallModel {
	/// Installs `version` of `app` from the source at `url`: over
	/// `installed` when there is one and `offers` has that source's
	/// listing, as itself or the copy it is (#81). Also an install link's,
	/// once its source lists its IPA (#93).
	func install(_ version: AppVersion, of app: SourceApp, from url: URL, over installed: InstallRecord?, offers: [Catalog.Offer], downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		if let installed, let offer = offers.first(where: { $0.source.url == url }) {
			update(installed, to: version, from: offer, downloads: downloads, certificates: certificates, into: context)
		} else {
			install(app, version: version, sourceURL: url, downloads: downloads, certificates: certificates, into: context)
		}
	}
}

/// The button every Install, Update and Open shows (#78), from app details,
/// Browse's rows and cards, Version History and the Library: its title in a
/// capsule, which stands out for Install and Update, as they change
/// something; Waiting while the install is queued, which takes it off the
/// queue; and while it runs, a progress ring across all its steps, which
/// cancels it. The install bar shows the steps themselves.
struct InstallStatusButton: View {
	let title: String
	/// False for Open.
	var prominent = true
	/// The install it stands for, waiting or running; nil shows the title.
	let status: InstallModel.AppStatus?
	let perform: () -> Void
	@Environment(InstallModel.self) private var installer
	/// Small on featured cards, where the capsule shares a corner with the icon.
	@Environment(\.controlSize) private var controlSize
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		switch status {
		case .running? where installer.isHandingOver:
			// iOS has Atelier's own install, and installs it once Atelier
			// closes: nothing to cancel or wait for in Atelier (#24).
			EmptyView()
		case .running(let stage)?:
			Button {
				installer.cancel()
			} label: {
				ZStack {
					// Spinning until the checks pass.
					ProgressRing(fraction: stage == .checking ? nil : stage.overallFraction)
					if stage != .checking {
						Image(systemName: "stop.fill")
							.font(.system(size: 9))
							.foregroundStyle(Color.accentColor)
					}
				}
				.frame(width: 30, height: 30)
				.contentShape(Circle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Cancel install")
			.accessibilityValue("\(Int(stage.overallFraction * 100)) percent")
		case .waiting(let job)?:
			capsule("Waiting", prominent: false) { installer.remove(job) }
				.accessibilityHint("Takes the app off the install queue.")
		case nil:
			capsule(title, prominent: prominent, perform: perform)
		}
	}

	@ViewBuilder
	private func capsule(_ title: String, prominent: Bool, perform: @escaping () -> Void) -> some View {
		// Featured cards tint the capsule with the card's colour, which only
		// reads as a filled one.
		let filled = prominent || controlSize == .small
		let label = Text(title)
			.font(controlSize == .small ? .caption.bold() : .subheadline.bold())
			.padding(.horizontal, controlSize == .small ? 2 : 10)
		let button = Button(action: perform) {
			// In dark mode, the lighter capsule's label in the app's colour
			// read as greyed out (29 Oct).
			if !filled, colorScheme == .dark, isEnabled {
				label.foregroundStyle(.white)
			} else {
				label
			}
		}
		.buttonBorderShape(.capsule)
		if filled {
			button.buttonStyle(.borderedProminent)
		} else {
			button.buttonStyle(.bordered)
		}
	}
}

/// The long press's menu of an app from a source, on its Install button or,
/// in lists, its whole row (#113): Choose Build when the version comes in
/// several builds (#30), the sources to install it from (#38), and
/// `CopyMenu` (#8), with Custom Install… (#155). Atelier installs over itself
/// from its own source only (#24), so it has only `CopyMenu`; a copy of it
/// is another app. A row's has Custom Install… also without a version this
/// device can run, once the app is installed, as on its page: the row of
/// Atelier, which has no button, has no other way to it.
struct AppMenu: ViewModifier {
	let app: SourceApp
	/// The version a copy installs; nil when this device can't run one.
	let version: AppVersion?
	let sourceURL: URL
	/// Every source's listing of the app.
	var offers: [Catalog.Offer] = []
	/// The app as Atelier installed it, which can be a copy (#8).
	var installed: InstallRecord?
	/// A row's: whether it's installed, so Custom Install… can sign it again.
	var signsAgain = false
	var isEnabled = true
	@Environment(InstallModel.self) private var installer
	@Environment(DownloadManager.self) private var downloads
	@Environment(CertificatesModel.self) private var certificates
	@Environment(CatalogModel.self) private var catalog
	@Environment(\.modelContext) private var context
	/// The version whose build the user is choosing.
	@State private var choosingBuild: AppVersion?

	/// Atelier as it runs, rather than a copy of it.
	private var isOwn: Bool {
		installed.map { SelfUpdate.shared.isOwn($0) } ?? SelfUpdate.shared.isOwnApp(app.bundleID)
	}

	/// Empty unless more than one source lists the app.
	private var sources: [Catalog.Offer] {
		offers.count > 1 && !isOwn ? offers : []
	}

	@ViewBuilder
	func body(content: Content) -> some View {
		if isEnabled, version != nil || !sources.isEmpty || signsAgain {
			content
				.contextMenu { menu }
				.modifier(BuildChoice(app: app, sourceURL: sourceURL, version: $choosingBuild) { install($0, of: app, from: sourceURL) })
		} else {
			content
		}
	}

	@ViewBuilder
	private var menu: some View {
		if let version, version.hasBuildChoice, !isOwn {
			Button("Choose Build…", systemImage: "square.stack.3d.up") { choosingBuild = version }
		}
		if !sources.isEmpty {
			Section("Install from") {
				ForEach(sources) { offer in
					let version = offer.app.availability().version
					Button {
						if let version { install(version, of: offer.app, from: offer.source.url) }
					} label: {
						if offer.source.url == sourceURL {
							Label(offer.source.name, systemImage: "checkmark")
						} else {
							Text(offer.source.name)
						}
						Text(version.map { $0.displayVersion + (offer.source.url == sourceURL ? " · Default" : "") } ?? "Can't install on this \(ThisDevice.name)")
					}
					.disabled(version == nil)
				}
			}
		}
		if let version {
			CopyMenu(app: app) {
				guard let source = offers.first(where: { $0.source.url == sourceURL })?.source ?? catalog.catalog.source(url: sourceURL)?.source else { return }
				// Opened on the app or copy whose button it is (#155).
				installer.askForCopy(of: app, version: version, from: source, opening: installed, in: catalog.catalog, context: context)
			} update: { target, name in
				// The app's own name is kept as the IPA has it, rather than
				// written in from the source.
				installer.install(app, version: version, sourceURL: sourceURL, as: target, displayName: name == app.name ? nil : name, downloads: downloads, certificates: certificates, into: context)
			}
		} else if signsAgain {
			RowCustomInstallButton(app: app)
		}
	}

	private func install(_ version: AppVersion, of app: SourceApp, from url: URL) {
		installer.install(version, of: app, from: url, over: installed, offers: offers, downloads: downloads, certificates: certificates, into: context)
	}
}

/// Custom Install… in the menu of an installed app's row without a
/// version this device can run (#155), which signs it again: for the app
/// as Atelier installed it, or Atelier as it runs (#24), looked up as the
/// menu opens. Install a Copy… for an offloaded one, as in the Library
/// (#49).
private struct RowCustomInstallButton: View {
	let app: SourceApp
	@Environment(InstallModel.self) private var installer
	@Environment(CatalogModel.self) private var catalog
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		// Its IPA can have another bundle ID than its source lists (#116).
		let install = SelfUpdate.shared.isOwnApp(app.bundleID)
			? InstalledApps.record(SelfUpdate.shared.bundleID, in: context)
			: InstalledApps.record(listedAs: app.bundleID, in: context)
		if let install {
			let item = LibraryItem(install, catalog: catalog.catalog, certificates: certificates, installer: installer)
			if item.disabled != nil {
				InstallCopyButton(item: item)
			} else {
				CustomInstallButton(item: item, inMenu: true)
			}
		}
	}
}

/// Asks which build of a version to install while `version` is set (#30),
/// and installs the one picked, which is kept for updates.
private struct BuildChoice: ViewModifier {
	let app: SourceApp
	let sourceURL: URL
	@Binding var version: AppVersion?
	let install: (AppVersion) -> Void
	@Environment(CatalogModel.self) private var catalog

	func body(content: Content) -> some View {
		content
			.sheet(isPresented: Binding(get: { version != nil }, set: { if !$0 { version = nil } })) {
				if let version {
					BuildChoiceSheet(app: app, version: version, chosenKind: BuildChoices.chosenKind(app.bundleID, sourceURL: sourceURL)) { build in
						self.version = nil
						BuildChoices.choose(build, for: app.bundleID, sourceURL: sourceURL)
						catalog.buildChoicesChanged()
						install(version.using(build))
					}
				}
			}
	}
}

/// Which build of a version to install (#30): the recommended one first,
/// each with what sets it apart; builds this device can't run are shown but
/// can't be picked.
private struct BuildChoiceSheet: View {
	let app: SourceApp
	let version: AppVersion
	let chosenKind: String?
	let choose: (AppBuild) -> Void
	@Environment(\.dismiss) private var dismiss

	/// The recommended build first, then the others as the release lists them.
	private var builds: [AppBuild] {
		guard let recommended = version.recommendedBuild() else { return version.builds }
		return [recommended] + version.builds.filter { $0 != recommended }
	}

	var body: some View {
		NavigationStack {
			List {
				Section {
					ForEach(builds) { build in
						let canRun = build.minOSVersion.map { OSVersion.current >= $0 } ?? true
						Button {
							choose(build)
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								HStack(spacing: 6) {
									Text(build.name)
										.foregroundStyle(.primary)
									if build == version.recommendedBuild() {
										Text("Recommended")
											.font(.caption.bold())
											.padding(.horizontal, 6)
											.padding(.vertical, 1)
											.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
											.foregroundStyle(.white)
									}
									Spacer()
									if build.kind == chosenKind {
										Image(systemName: "checkmark")
											.foregroundStyle(.tint)
									}
								}
								Text([build.note(), build.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
									.compactMap { $0 }
									.joined(separator: " · "))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
						.disabled(!canRun)
					}
				} footer: {
					Text("\(version.displayVersion) has \(version.builds.count) builds of \(app.name). Atelier remembers your choice for updates; touch and hold Install to change it.")
				}
			}
			.navigationTitle("Choose a Build")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
		.presentationDetents([.medium, .large])
	}
}
