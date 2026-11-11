import AtelierCore
import CertKit
import InstallKit
import PhotosUI
import SigningKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Custom Install's sheet (#155), for any app, in place of Install a
/// Copy's (#113) and Sign Again With's (#17): the app's icon as the Home
/// Screen will show it; the app and its copies installed, which it can
/// install over, keeping their data, or the app itself while it isn't
/// installed, then New Copy, a new app next to them; for the one picked,
/// its name, a tint for its icon and Advanced, with its App ID, which only
/// a new copy can change, a picture as its icon, the version it says it is
/// and its URL schemes; then the certificate or Apple ID it's signed with
/// (#49), and for a copy of Atelier, whether it comes with the
/// certificate. Atelier itself signs itself as it runs, so only its
/// certificate can change (#24). The one it's opened on is picked to start
/// with, with what it has and the certificate it was installed with, so
/// Install alone signs it again; else the app itself while it isn't
/// installed. An offloaded app isn't there to install over (#49).
struct CopySheet: View {
	let request: InstallModel.CopyRequest
	let certificates: CertificatesModel
	/// Whether signing an installed app with a certificate or Apple ID, by
	/// its ID, means deleting it first, as the certificate is for another
	/// App ID (#76), or the Apple ID installs it as another bundle ID (#49).
	let needsReinstall: (InstallRecord, UUID) -> Bool
	/// Whether the question asked then can install a copy instead.
	let canInstallAsCopy: (InstallRecord) -> Bool
	/// Whether an app in the Library has this bundle ID.
	let isTaken: (String) -> Bool
	let cancel: () -> Void
	let install: (InstallModel.CopyAnswer) -> Void

	/// What Install installs: over an app or copy installed, by its bundle
	/// ID; the app itself, while it isn't installed; or a new copy.
	private enum Pick: Equatable {
		case over(String)
		case app
		case newCopy
	}

	/// The app or copy picked, the app itself, or New Copy.
	@State private var picked: Pick
	@State private var name: String
	@State private var tint: AppIconTint?
	@State private var appID: String
	/// Whether a new copy's App ID follows its name: until one's typed in
	/// Advanced that the name doesn't give.
	@State private var idFollowsName = true
	/// A picture as its icon, as a square PNG.
	@State private var picture: Data?
	@State private var version: String
	@State private var removesURLSchemes: Bool
	/// Share App Groups (#49), for an Apple ID.
	@State private var sharesAppGroups: Bool
	/// The certificate or Apple ID picked (#49); nil while there's none to
	/// pick.
	@State private var certificateID: UUID?
	/// Include Certificate, for a copy of Atelier (#113): on to start with.
	@State private var includesCertificate = true
	/// The app's own icon, once it's read.
	@State private var appIcon: Data?
	/// Its icon as the Home Screen will show it.
	@State private var preview: UIImage?
	@State private var routeA = RouteASetup.shared

	init(request: InstallModel.CopyRequest, certificates: CertificatesModel, needsReinstall: @escaping (InstallRecord, UUID) -> Bool, canInstallAsCopy: @escaping (InstallRecord) -> Bool, isTaken: @escaping (String) -> Bool, cancel: @escaping () -> Void, install: @escaping (InstallModel.CopyAnswer) -> Void) {
		self.request = request
		self.certificates = certificates
		self.needsReinstall = needsReinstall
		self.canInstallAsCopy = canInstallAsCopy
		self.isTaken = isTaken
		self.cancel = cancel
		self.install = install
		let picked = Self.firstPick(of: request)
		let start = Self.start(for: picked, of: request, certificates: certificates, needsReinstall: needsReinstall)
		_picked = State(initialValue: picked)
		_name = State(initialValue: start.name)
		_tint = State(initialValue: start.tint)
		_appID = State(initialValue: start.appID)
		_picture = State(initialValue: start.picture)
		_version = State(initialValue: start.version)
		_removesURLSchemes = State(initialValue: start.removesURLSchemes)
		_sharesAppGroups = State(initialValue: start.sharesAppGroups)
		_certificateID = State(initialValue: start.certificateID)
	}

	/// The app or copy picked, of those installed; nil for the app itself
	/// and New Copy.
	private var over: InstallRecord? {
		Self.installed(picked, of: request)
	}

	/// A new copy, whose App ID can change.
	private var isNewCopy: Bool {
		picked == .newCopy
	}

	/// What installs over it.
	private var overInstall: InstallModel.CopyRequest.OverInstall? {
		over.flatMap { request.overInstalls[$0.bundleID] }
	}

	/// Whether its name and icon can change: not Atelier's itself (#24).
	private var changesLook: Bool {
		over.map { InstallModel.canChangeLook(of: $0) } ?? true
	}

	private var copyNumber: Int {
		if case .copy(let number) = over?.target ?? request.target { return number }
		return 2
	}

	/// The bundle ID its copy number gives it (`InstallTarget`): the app's
	/// own for the app itself.
	private var numberedID: String {
		if picked == .app { return request.appBundleID }
		return over?.numberedBundleID ?? request.target.bundleID(for: request.appBundleID)
	}

	private var trimmedID: String {
		appID.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var trimmedVersion: String {
		version.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The version that installs, for Advanced's.
	private var installedVersion: String {
		overInstall?.version ?? request.version
	}

	/// The certificate or Apple ID picked, while it's there and can sign.
	private var certificate: SigningChoice? {
		SigningChoice.all(certificates).first { $0.id == certificateID }.flatMap { Self.canSign($0) ? $0 : nil }
	}

	/// An Apple ID signs it, so its App Groups have the Apple ID's names
	/// (#49), and Advanced has Share App Groups. Not for Atelier, which has
	/// none.
	private var signsWithAppleID: Bool {
		guard !request.isOwn, case .appleID = certificate else { return false }
		return true
	}

	/// A copy of Atelier comes with the certificate it's signed with (#113),
	/// never an Apple ID's, whose profile is for the copy alone (#49).
	private var comesWithCertificate: Bool {
		showsIncludeCertificate && includesCertificate
	}

	private var idProblem: String? {
		Self.idProblem(appID, isNewCopy: isNewCopy, copy: copyNumber, of: request, isTaken: isTaken)
	}

	private var versionProblem: String? {
		Self.versionProblem(version, example: installedVersion)
	}

	private var canInstall: Bool {
		guard certificate != nil, Self.canPick(picked, in: request) else { return false }
		return !changesLook || (idProblem == nil && versionProblem == nil)
	}

	/// The App ID a new copy gets from `name`: the numbered one for the
	/// name it's suggested with (`CopySettings.bundleID(named:)`).
	private func nameID(_ name: String) -> String {
		CopySettings.bundleID(named: name, suggestedName: request.suggestedName, copy: copyNumber, of: request.appBundleID, taken: isTaken)
	}

	/// The App ID as Advanced types it: one the name doesn't give stops it
	/// following the name.
	private var typedAppID: Binding<String> {
		Binding(
			get: { appID },
			set: { id in
				appID = id
				idFollowsName = id.trimmingCharacters(in: .whitespacesAndNewlines) == nameID(name)
			}
		)
	}

	/// What's wrong with `id` as the App ID of new copy `number`; nil when
	/// nothing is. An app or copy it installs over keeps its own, as does
	/// the app itself.
	static func idProblem(_ id: String, isNewCopy: Bool, copy number: Int, of request: InstallModel.CopyRequest, isTaken: (String) -> Bool) -> String? {
		guard isNewCopy else { return nil }
		return CopySettings.problem(with: id.trimmingCharacters(in: .whitespacesAndNewlines), copy: number, of: request.appBundleID, taken: isTaken)
	}

	/// What's wrong with `version` as the version an app says it is; nil
	/// when nothing is, and for none, which keeps the app's. One is
	/// numbers and full stops, as iOS reads them, like `example`.
	static func versionProblem(_ version: String, example: String) -> String? {
		let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !version.isEmpty, !isVersion(version) else { return nil }
		return "A version is numbers and full stops, like \(isVersion(example) ? example : "1.0")."
	}

	private static func isVersion(_ text: String) -> Bool {
		text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
			!part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
		}
	}

	private var answer: InstallModel.CopyAnswer? {
		guard canInstall, let certificate else { return nil }
		let settings = CopySettings(
			// An app or copy installed over keeps its own, as does the app
			// itself (#155).
			bundleID: isNewCopy && trimmedID != numberedID ? trimmedID : nil,
			tint: tint,
			hasPicture: picture != nil,
			version: request.isOwn || trimmedVersion.isEmpty ? nil : trimmedVersion,
			removesURLSchemes: removesURLSchemes,
			sharesAppGroups: sharesAppGroups
		)
		let choice = InstallModel.CopyChoice(settings: settings, picture: picture, includesCertificate: comesWithCertificate)
		return InstallModel.CopyAnswer(over: over, installsApp: picked == .app, name: name, choice: choice, certificateID: certificate.id)
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 10) {
						previewIcon
							.shadow(color: .black.opacity(0.16), radius: 9, y: 6)
						Text(overInstall?.what ?? request.what)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
				}
				if showsTargets {
					targetsSection
				}
				if changesLook {
					Section {
						TextField("Name", text: $name)
							.textInputAutocapitalization(.words)
							.submitLabel(.done)
					} footer: {
						// Under the apps to pick from, when there are any.
						if !showsTargets {
							Text(newCopyNote)
						}
					}
					Section {
						TintPicker(selection: $tint)
					} header: {
						Text("Icon Tint")
					} footer: {
						Text("So you can tell it apart on the Home Screen.")
					}
					Section {
						NavigationLink {
							AdvancedCopyView(
								request: request,
								over: over,
								installsApp: picked == .app,
								copyNumber: copyNumber,
								installedVersion: installedVersion,
								hasCertificate: certificate != nil,
								isTaken: isTaken,
								appID: typedAppID,
								picture: $picture,
								version: $version,
								removesURLSchemes: $removesURLSchemes,
								sharesAppGroups: $sharesAppGroups,
								signsWithAppleID: signsWithAppleID,
								appIcon: $appIcon,
								install: { if let answer { install(answer) } }
							)
						} label: {
							LabeledContent("Advanced") {
								if idProblem != nil || versionProblem != nil {
									Text("Check the \(idProblem != nil ? "App ID" : "version")")
										.foregroundStyle(.red)
								} else {
									Text(advancedSummary)
								}
							}
						}
					}
				}
				certificateSections
			}
			.scrollDismissesKeyboard(.interactively)
			// A new copy's App ID follows its name.
			.onChange(of: name) { _, name in
				if isNewCopy, idFollowsName { appID = nameID(name) }
			}
			.navigationTitle("Custom Install")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel", action: cancel)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Install") { if let answer { install(answer) } }
						.disabled(answer == nil)
				}
			}
		}
		// The app's icon, from its IPA, else as the Library or its source
		// shows it.
		.task {
			if let file = request.ipaFile {
				appIcon = await Task.detached(priority: .userInitiated) { IPAIcon.read(ipaAt: file) }.value
			} else if let url = request.iconURL, let image = await ImagePipeline.shared.image(url, maxPixels: 512) {
				appIcon = image.pngData()
			}
		}
		.task(id: PreviewInput(icon: appIcon, picture: picture, tint: tint)) {
			let change = IconChange(picture: picture, tint: tint)
			let icon = appIcon
			let png = await Task.detached(priority: .userInitiated) { change.png(from: icon, pixels: 288) }.value
			// A later tint or picture's is on its way.
			guard !Task.isCancelled else { return }
			preview = png.flatMap { UIImage(data: $0) }
		}
	}

	/// The icon as the Home Screen will show it: Atelier itself's as it is
	/// (#24).
	@ViewBuilder
	private var previewIcon: some View {
		if let over, !changesLook {
			CachedImage(url: Self.iconURL(of: over), maxPoints: 96) {
				CopyIcon(image: nil, size: 96)
			}
			.frame(width: 96, height: 96)
			.clipShape(RoundedRectangle(cornerRadius: 96 * 0.225, style: .continuous))
			.accessibilityHidden(true)
		} else {
			CopyIcon(image: preview, size: 96)
		}
	}

	/// Whether there's more than New Copy to pick: an app or copy
	/// installed, or the app itself.
	private var showsTargets: Bool {
		!request.installed.isEmpty || request.offersApp
	}

	/// The app itself while it isn't installed, or the app and its copies
	/// installed, then New Copy: picking one starts from what it has. One
	/// with nothing to install over it can't be picked.
	private var targetsSection: some View {
		Section {
			if request.offersApp {
				Button {
					pick(.app)
				} label: {
					HStack(spacing: 12) {
						thumbnail(request.iconURL)
						Text(request.appName)
							.foregroundStyle(Color.primary)
						Spacer()
						if picked == .app { checkmark }
					}
				}
			}
			ForEach(request.installed) { installed in
				let canPick = Self.canPick(.over(installed.bundleID), in: request)
				Button {
					pick(.over(installed.bundleID))
				} label: {
					HStack(spacing: 12) {
						thumbnail(Self.iconURL(of: installed))
						Text(installed.name)
							.foregroundStyle(canPick ? Color.primary : Color.secondary)
						Spacer()
						if picked == .over(installed.bundleID) { checkmark }
					}
				}
				.disabled(!canPick)
			}
			if request.offersNewCopy {
				Button {
					pick(.newCopy)
				} label: {
					HStack(spacing: 12) {
						Image(systemName: "plus.square.dashed")
							.font(.title2)
							.foregroundStyle(.secondary)
							.frame(width: 30, height: 30)
						Text("New Copy")
							.foregroundStyle(Color.primary)
						Spacer()
						if picked == .newCopy { checkmark }
					}
				}
			}
		} footer: {
			Text(targetNote)
		}
	}

	/// An app's icon in the list of apps to pick from.
	private func thumbnail(_ url: URL?) -> some View {
		CachedImage(url: url, maxPoints: 30) {
			RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(.tertiarySystemFill))
		}
		.frame(width: 30, height: 30)
		.clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
	}

	private var checkmark: some View {
		Image(systemName: "checkmark")
			.fontWeight(.semibold)
			.foregroundStyle(Color.accentColor)
	}

	/// What installing over the one picked does, or the app itself, or what
	/// a new copy is.
	private var targetNote: String {
		if picked == .app { return "Installs \(request.appName) with this name and icon." }
		guard let over else { return newCopyNote }
		if SelfUpdate.shared.isOwn(over) {
			return "\(over.name) signs itself again as it runs, as it is, so only its certificate can change."
		}
		if !changesLook { return "\(over.name) is signed as it is, so only its certificate can change." }
		let note = "Installs over \(over.name) and keeps its data."
		return overInstall?.note.map { "\(note) \($0)" } ?? note
	}

	/// What a new copy is.
	private var newCopyNote: String {
		guard request.isOwn else { return "A separate app next to \(request.appName), with its own data." }
		return comesWithCertificate
			? "A second app next to this one, with its own sources and settings, so it starts without yours."
			: "A second app next to this one. It has its own sources, certificates and settings, so it starts without yours."
	}

	/// What Advanced changes, else what it has: an App ID only for a new
	/// copy, and no version for Atelier, which goes by its own (#113).
	private var advancedSummary: String {
		var changed: [String] = []
		if isNewCopy, trimmedID != numberedID { changed.append("App ID") }
		if picture != nil { changed.append("Picture") }
		if !request.isOwn, !trimmedVersion.isEmpty { changed.append("Version") }
		if removesURLSchemes { changed.append("No URL Schemes") }
		if signsWithAppleID, !sharesAppGroups { changed.append("App Groups Not Shared") }
		guard changed.isEmpty else { return changed.joined(separator: ", ") }
		return ((isNewCopy ? ["App ID"] : []) + ["Icon"] + (request.isOwn ? [] : ["Version"])).joined(separator: ", ")
	}

	// MARK: Certificates

	/// The certificates and Apple IDs for the one picked, in order (#49):
	/// those that sign it, for Atelier itself only certificates for its App
	/// ID, then the rest, which it can't sign itself with (#24), as an
	/// Apple ID would sign it as another bundle ID; for any other app
	/// installed, those that need a reinstall last (#76).
	private var certificateGroups: (signing: [SigningChoice], otherAppID: [SigningChoice], reinstall: [SigningChoice]) {
		let all = Self.ordered(certificates, installedWith: over?.certificateID)
		guard let over else { return (all, [], []) }
		if SelfUpdate.shared.isOwn(over) {
			return (all.filter(Self.signsAtelier), all.filter { !Self.signsAtelier($0) }, [])
		}
		return (all.filter { !needsReinstall(over, $0.id) }, [], all.filter { needsReinstall(over, $0.id) })
	}

	/// Include Certificate, for a copy of Atelier (#113), signed with a
	/// certificate rather than an Apple ID (#49).
	private var showsIncludeCertificate: Bool {
		guard request.isOwn, changesLook, case .certificate? = certificate else { return false }
		return true
	}

	@ViewBuilder
	private var certificateSections: some View {
		let groups = certificateGroups
		if !groups.signing.isEmpty || !CustomInstall.canSign(with: certificates) || showsIncludeCertificate {
			Section {
				ForEach(groups.signing) { certificateRow($0) }
				if showsIncludeCertificate {
					Toggle("Include Certificate", isOn: $includesCertificate)
				}
			} header: {
				Text("Certificate")
			} footer: {
				if !CustomInstall.canSign(with: certificates) {
					Text("There's no certificate to sign with. Import one in Settings › Installs › Certificates.")
				} else if showsIncludeCertificate {
					Text(includeNote)
				}
			}
		}
		if let over, !groups.otherAppID.isEmpty {
			Section {
				ForEach(groups.otherAppID) { certificateRow($0, canPick: false) }
			} header: {
				Text("Can't sign \(over.name)")
			} footer: {
				Text("\(over.name) would have to be deleted and installed again to use these, and it can't do that to itself.")
			}
		}
		if let over, !groups.reinstall.isEmpty {
			Section {
				ForEach(groups.reinstall) { certificateRow($0) }
			} header: {
				Label {
					Text("Reinstall required")
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
				}
			} footer: {
				Text(reinstallNote(over))
			}
		}
	}

	/// A certificate's or Apple ID's name, with "Installed with · Default ·
	/// Ad hoc · 45 days left" under it, as applies, "Free Apple ID" for one
	/// (#49), ticked when it's the one picked. Revoked and expired ones
	/// can't be picked.
	private func certificateRow(_ certificate: SigningChoice, canPick: Bool = true) -> some View {
		let attention = certificate.attention
		let isUsable = canPick && Self.canSign(certificate)
		return Button {
			certificateID = certificate.id
		} label: {
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(certificate.displayName)
						.foregroundStyle(isUsable ? Color.primary : Color.secondary)
					Text(subtitle(certificate, attention: attention))
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				Spacer()
				if certificate.id == certificateID, isUsable { checkmark }
			}
		}
		.disabled(!isUsable)
	}

	private func subtitle(_ certificate: SigningChoice, attention: CertificateAttention?) -> String {
		let state = switch attention {
		case .revoked: "Revoked"
		case .expired: "Expired"
		case .expiring, nil: certificate.remainingText
		}
		return [
			certificate.id == over?.certificateID ? "Installed with" : nil,
			certificate.id == certificates.defaultID ? "Default" : nil,
			certificate.kind,
			state,
		]
		.compactMap { $0 }
		.joined(separator: " · ")
	}

	/// Include Certificate's (#113): a new copy of Atelier can install apps
	/// and update itself from its first launch, and one installed over adds
	/// it to its certificates when it next opens.
	private var includeNote: String {
		guard let over else {
			return includesCertificate
				? "Atelier signs the copy with it, and puts it in the copy with its password\(udidNote), so the copy can install apps and update itself from its first launch."
				: "Atelier signs the copy with it. The copy starts without a certificate, until one is imported in it."
		}
		let name = over.name
		return includesCertificate
			? "Atelier signs \(name) with it, and puts it in \(name) with its password\(udidNote), for \(name) to add to its certificates when it next opens."
			: "Atelier signs \(name) with it. \(name) keeps the certificates it has."
	}

	/// This iPhone's UDID goes in the copy with the certificate, once the
	/// setup has read it.
	private var udidNote: String {
		routeA.udid == nil ? "" : " and this \(ThisDevice.name)'s UDID"
	}

	/// What those certificates mean for the app, and that installing with
	/// one asks first: once the setup is done, the app keeps its data (#96).
	/// As Sign Again With said it (#159).
	private func reinstallNote(_ over: InstallRecord) -> String {
		let name = over.name
		let reinstall = routeA.isSetUp
			? "With one of these, \(name) has to be deleted and installed again. It keeps its data."
			: "With one of these, \(name) has to be deleted and installed again, which erases its data."
		return canInstallAsCopy(over)
			? "\(reinstall) Atelier asks first, and can install a second \(name) instead."
			: "\(reinstall) Atelier asks first."
	}

	// MARK: Picking

	/// Picking the app, a copy, the app itself or New Copy starts from what
	/// it has.
	private func pick(_ pick: Pick) {
		guard pick != picked else { return }
		picked = pick
		let start = Self.start(for: pick, of: request, certificates: certificates, needsReinstall: needsReinstall)
		name = start.name
		tint = start.tint
		appID = start.appID
		idFollowsName = true
		picture = start.picture
		version = start.version
		removesURLSchemes = start.removesURLSchemes
		sharesAppGroups = start.sharesAppGroups
		certificateID = start.certificateID
		includesCertificate = true
	}

	/// The one it's opened on, else the app itself while it isn't
	/// installed (#155), else New Copy, else the first that can be picked.
	private static func firstPick(of request: InstallModel.CopyRequest) -> Pick {
		if let opened = request.opened, canPick(.over(opened.bundleID), in: request) { return .over(opened.bundleID) }
		if request.offersApp { return .app }
		if request.offersNewCopy { return .newCopy }
		return request.installed.first { canPick(.over($0.bundleID), in: request) }.map { Pick.over($0.bundleID) } ?? .newCopy
	}

	/// Whether `pick` has something to install: over an app installed, the
	/// app itself while it isn't, or a new copy.
	private static func canPick(_ pick: Pick, in request: InstallModel.CopyRequest) -> Bool {
		switch pick {
		case .over(let bundleID): request.overInstalls[bundleID] != nil
		case .app: request.offersApp
		case .newCopy: request.offersNewCopy
		}
	}

	/// The app or copy installed that `pick` is; nil for the app itself and
	/// New Copy.
	private static func installed(_ pick: Pick, of request: InstallModel.CopyRequest) -> InstallRecord? {
		guard case .over(let bundleID) = pick else { return nil }
		return request.installed.first { $0.bundleID == bundleID }
	}

	/// What the sheet starts with for the one picked.
	private struct Start {
		var name: String
		var tint: AppIconTint?
		var appID: String
		var picture: Data?
		var version = ""
		var removesURLSchemes = false
		var sharesAppGroups = true
		var certificateID: UUID?
	}

	/// What the app or copy picked has, the name and icon chosen for it too
	/// (#113, #155); the app itself as it comes, under its own App ID; or
	/// what New Copy is suggested with.
	private static func start(for pick: Pick, of request: InstallModel.CopyRequest, certificates: CertificatesModel, needsReinstall: (InstallRecord, UUID) -> Bool) -> Start {
		let over = installed(pick, of: request)
		let certificateID = startingCertificate(for: over, certificates: certificates, needsReinstall: needsReinstall)
		guard let over else {
			if pick == .app {
				return Start(name: request.appName, appID: request.appBundleID, certificateID: certificateID)
			}
			return Start(name: request.suggestedName, appID: request.target.bundleID(for: request.appBundleID), certificateID: certificateID)
		}
		let settings = over.copySettings ?? CopySettings()
		return Start(
			name: over.name,
			tint: settings.tint,
			appID: over.bundleID,
			picture: settings.hasPicture ? CopyStore.shared.picture(for: over.numberedBundleID) : nil,
			version: settings.version ?? "",
			removesURLSchemes: settings.removesURLSchemes,
			sharesAppGroups: settings.sharesAppGroups,
			certificateID: certificateID
		)
	}

	/// The certificate or Apple ID picked to start with: for an app
	/// installed, the one it was installed with while it can sign, else one
	/// that signs it without a reinstall, the default first, for Atelier
	/// itself a certificate for its App ID (#24); for New Copy, the default;
	/// else any that can sign.
	private static func startingCertificate(for over: InstallRecord?, certificates: CertificatesModel, needsReinstall: (InstallRecord, UUID) -> Bool) -> UUID? {
		let usable = ordered(certificates, installedWith: over?.certificateID).filter(canSign)
		guard let over else { return usable.first?.id }
		if SelfUpdate.shared.isOwn(over) { return usable.first(where: signsAtelier)?.id }
		return (usable.first { !needsReinstall(over, $0.id) } ?? usable.first)?.id
	}

	/// The one it was installed with first, then the default, then the rest
	/// as Settings lists them, Apple IDs too (#49).
	private static func ordered(_ certificates: CertificatesModel, installedWith: UUID?) -> [SigningChoice] {
		let all = SigningChoice.all(certificates)
		let defaultID = certificates.defaultID
		return all.filter { $0.id == installedWith }
			+ all.filter { $0.id == defaultID && $0.id != installedWith }
			+ all.filter { $0.id != installedWith && $0.id != defaultID }
	}

	/// Not revoked or expired.
	private static func canSign(_ certificate: SigningChoice) -> Bool {
		switch certificate.attention {
		case .revoked, .expired: false
		case .expiring, nil: true
		}
	}

	/// Signs Atelier itself as it runs (#24): a certificate for the App ID
	/// it was installed with, never an Apple ID, which would sign it as
	/// another bundle ID (#49).
	private static func signsAtelier(_ certificate: SigningChoice) -> Bool {
		guard case .certificate(let certificate) = certificate else { return false }
		return SelfUpdate.shared.signs(with: certificate)
	}

	/// Its icon as the Home Screen shows it: Atelier's as it runs (#24), else
	/// the one it was installed with (#118).
	private static func iconURL(of install: InstallRecord) -> URL? {
		SelfUpdate.shared.isOwn(install) ? SelfUpdate.shared.iconURL : InstalledIcons.shared.url(for: install.bundleID)
	}

	private struct PreviewInput: Equatable {
		let icon: Data?
		let picture: Data?
		let tint: AppIconTint?
	}
}

/// An icon as the Home Screen draws it, or a blank one until it's there.
private struct CopyIcon: View {
	let image: UIImage?
	let size: CGFloat

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
		Group {
			if let image {
				Image(uiImage: image)
					.resizable()
					.interpolation(.high)
			} else {
				shape.fill(Color(.tertiarySystemFill))
			}
		}
		.frame(width: size, height: size)
		.clipShape(shape)
		.accessibilityHidden(true)
	}
}

/// An icon from a PNG, decoded again only when the PNG changes, rather
/// than as the App ID is typed.
private struct PNGIcon: View, Equatable {
	let png: Data?
	let size: CGFloat

	var body: some View {
		CopyIcon(image: png.flatMap { UIImage(data: $0) }, size: size)
	}
}

/// None, then iOS's eight colours, in a row of circles.
private struct TintPicker: View {
	@Binding var selection: AppIconTint?

	var body: some View {
		HStack(spacing: 0) {
			swatch(nil)
			ForEach(AppIconTint.allCases, id: \.self) { tint in
				swatch(tint)
			}
		}
		.padding(.vertical, 8)
	}

	private func swatch(_ tint: AppIconTint?) -> some View {
		let picked = selection == tint
		let ring = tint.map(Self.color) ?? Color(.systemGray)
		return Button {
			selection = tint
		} label: {
			ZStack {
				if let tint {
					Circle().fill(Self.color(tint))
				} else {
					// White, struck through in red.
					Circle().fill(Color.white)
					Rectangle()
						.fill(Color(.systemRed))
						.frame(width: 2, height: 34)
						.rotationEffect(.degrees(45))
					Circle().strokeBorder(Color(.systemGray3), lineWidth: 1.5)
				}
			}
			.frame(width: 30, height: 30)
			.clipShape(Circle())
			.padding(5)
			.overlay {
				if picked { Circle().strokeBorder(ring, lineWidth: 2.5) }
			}
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(tint.map { $0.rawValue.capitalized } ?? "None")
		.accessibilityAddTraits(picked ? .isSelected : [])
	}

	static func color(_ tint: AppIconTint) -> Color {
		let color = tint.color
		return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
	}
}

/// Advanced, pushed in the same sheet: the App ID, which only a new copy
/// can change (#155), a picture as its icon, the version it says it is,
/// its URL schemes (#113), and with an Apple ID, Share App Groups (#49).
private struct AdvancedCopyView: View {
	let request: InstallModel.CopyRequest
	/// The app or copy it installs over; nil for a new copy, or the app
	/// itself while it isn't installed.
	let over: InstallRecord?
	/// The app itself, which isn't installed, rather than a new copy.
	let installsApp: Bool
	let copyNumber: Int
	/// The version that installs.
	let installedVersion: String
	let hasCertificate: Bool
	let isTaken: (String) -> Bool
	@Binding var appID: String
	@Binding var picture: Data?
	@Binding var version: String
	@Binding var removesURLSchemes: Bool
	@Binding var sharesAppGroups: Bool
	let signsWithAppleID: Bool
	/// The app's own icon, once it's read.
	@Binding var appIcon: Data?
	let install: () -> Void

	@State private var photo: PhotosPickerItem?
	@State private var pictureProblem: String?
	@State private var readingPicture = false

	/// A new copy, whose App ID can change.
	private var isNewCopy: Bool {
		over == nil && !installsApp
	}

	private var idProblem: String? {
		CopySheet.idProblem(appID, isNewCopy: isNewCopy, copy: copyNumber, of: request, isTaken: isTaken)
	}

	private var versionProblem: String? {
		CopySheet.versionProblem(version, example: installedVersion)
	}

	private var canInstall: Bool {
		hasCertificate && idProblem == nil && versionProblem == nil
	}

	var body: some View {
		Form {
			Section {
				TextField(request.target.bundleID(for: request.appBundleID), text: $appID)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.asciiCapable)
					.foregroundStyle(isNewCopy ? Color.primary : Color.secondary)
					.disabled(!isNewCopy)
			} header: {
				Text("App ID")
			} footer: {
				if let over {
					Text("\(over.name)'s ID, which stays, so it keeps its data. Only a new copy can have another.")
				} else if installsApp {
					Text("\(request.appName)'s own ID. Only a new copy can have another.")
				} else if let idProblem {
					Text(idProblem).foregroundStyle(.red)
				} else {
					Text("This copy's ID, which follows its name until you change it here. Any ID works that no other app on this iPhone has. Its extensions get IDs under it, and its updates keep it.")
				}
			}
			Section {
				Button {
					picture = nil
				} label: {
					HStack(spacing: 12) {
						thumbnail(appIcon)
						Text("\(request.appName)'s Icon")
							.foregroundStyle(Color.primary)
						Spacer()
						if picture == nil { checkmark }
					}
				}
				if let picture {
					HStack(spacing: 12) {
						thumbnail(picture)
						Text("Your Picture")
						Spacer()
						checkmark
					}
				}
				PhotosPicker(selection: $photo, matching: .images) {
					Label("Choose from Photos…", systemImage: "photo")
				}
				Button {
					DocumentPicker.present(contentTypes: [.image]) { urls in
						guard let url = urls.first else { return }
						let data = try? Data(contentsOf: url)
						try? FileManager.default.removeItem(at: url)
						Task { await use(data) }
					}
				} label: {
					Label("Choose from Files…", systemImage: "folder")
				}
			} header: {
				HStack {
					Text("Icon")
					if readingPicture { ProgressView().controlSize(.small) }
				}
			} footer: {
				if let pictureProblem {
					Text(pictureProblem).foregroundStyle(.red)
				} else {
					Text("A picture that isn't square is cropped to its middle. The tint applies to it too.")
				}
			}
			// Atelier goes by its own version for its updates.
			if !request.isOwn {
				Section {
					TextField(installedVersion, text: $version)
						.keyboardType(.numbersAndPunctuation)
						.autocorrectionDisabled()
				} header: {
					Text("Version")
				} footer: {
					if let versionProblem {
						Text(versionProblem).foregroundStyle(.red)
					} else {
						Text("Empty keeps the app's. Another one is the version \(isNewCopy ? "the copy" : "it") says it is, for apps that won't run older versions. Atelier still offers its updates.")
					}
				}
			}
			Section {
				Toggle("Remove URL Schemes", isOn: $removesURLSchemes)
			} footer: {
				Text(urlSchemesNote)
			}
			if signsWithAppleID {
				Section {
					Toggle("Share App Groups", isOn: $sharesAppGroups)
				} footer: {
					Text(appGroupsNote)
				}
			}
		}
		.scrollDismissesKeyboard(.interactively)
		.navigationTitle("Advanced")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				Button("Install", action: install)
					.disabled(!canInstall)
			}
		}
		.onChange(of: photo) { _, item in
			guard let item else { return }
			photo = nil
			Task { await use(try? await item.loadTransferable(type: Data.self)) }
		}
	}

	/// What Share App Groups does (#49), for the app or copy that installs,
	/// and when to turn it off (10 Nov 2026: say when).
	private var appGroupsNote: String {
		let app = over?.name ?? (installsApp ? request.appName : "the copy")
		return "Lets \(app) share its data with its widgets and extensions. Turn it off if \(app) stops working."
	}

	/// What removing its URL schemes does: links meant for the app open the
	/// app, not a copy, and the app itself no longer opens from them.
	private var urlSchemesNote: String {
		let app = request.appName
		if installsApp {
			return "Links meant for \(app) won't open it."
		}
		guard let over else {
			return "So links meant for \(app) open \(app), not the copy."
		}
		if over.target == .original {
			return "Links meant for \(over.name) no longer open it."
		}
		return "So links meant for \(app) open \(app), not \(over.name)."
	}

	private var checkmark: some View {
		Image(systemName: "checkmark")
			.fontWeight(.semibold)
			.foregroundStyle(Color.accentColor)
	}

	private func thumbnail(_ png: Data?) -> some View {
		PNGIcon(png: png, size: 30).equatable()
	}

	/// The picked picture, as a square PNG of 1024 pixels a side, cropped
	/// to its middle.
	private func use(_ data: Data?) async {
		guard let data else {
			pictureProblem = "That picture couldn't be read. Try another one."
			return
		}
		readingPicture = true
		let png = await Task.detached(priority: .userInitiated) { IconChange(picture: data).png(from: nil, pixels: 1024) }.value
		readingPicture = false
		if let png {
			picture = png
			pictureProblem = nil
		} else {
			pictureProblem = "That picture couldn't be read. Try another one."
		}
	}
}
