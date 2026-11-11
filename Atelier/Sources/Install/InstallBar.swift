import CertKit
import InstallKit
import AtelierCore
import SigningKit
import SwiftUI

extension View {
	/// Shows the install bar above the tab bar while an install runs, waits
	/// or has just ended. `front`: the tab is in front, so its bar's sheet
	/// is the one that comes up by itself to say to go to the Home Screen
	/// (#123).
	func installBar(front: Bool) -> some View {
		modifier(InstallBarInset(isFront: front))
	}
}

private struct InstallBarInset: ViewModifier {
	let isFront: Bool
	@Environment(InstallModel.self) private var model

	func body(content: Content) -> some View {
		content
			.safeAreaInset(edge: .bottom, spacing: 0) {
				if !model.isIdle {
					// Once it closes by itself with its details open, it's
					// hidden rather than removed, so the details stay.
					InstallBar(model: model, isFront: isFront)
						.padding(.horizontal, 16)
						.padding(.bottom, model.barHidden ? 0 : 8)
						.frame(height: model.barHidden ? 0 : nil)
						.opacity(model.barHidden ? 0 : 1)
						.allowsHitTesting(!model.barHidden)
						.accessibilityHidden(model.barHidden)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.animation(.snappy, value: model.isIdle)
			.animation(.snappy, value: model.barHidden)
	}
}

/// The current install as a floating bar above the tab bar, like Music's
/// mini player: the app, the step it's at (checking, downloading, signing,
/// installing) and its progress, on every tab. It's there only while
/// there's an install to show. A confirmed or cancelled install closes by
/// itself after a few seconds, and one that couldn't be confirmed after a
/// while longer; a failure stays, with the button that fixes it when there
/// is one. When the iOS alert closes without installing, it offers Try
/// again, which shows the alert again for the app already signed (#51).
/// Once an install has ended, ✕ or a swipe down closes it. A tap
/// opens the details: the log, Cancel and the installs waiting.
///
/// Once iOS has Atelier's own install, or iOS's alert for it closes before
/// iOS asked for the build, a sheet says to go to the Home Screen in place
/// of the details, coming up by itself with a haptic on the tab in front;
/// once iOS has it, the bar turns blue and says so too, until Atelier
/// leaves the screen (#123).
struct InstallBar: View {
	@Bindable var model: InstallModel
	/// Its tab is in front.
	var isFront = false
	@State private var showingDetails = false
	@State private var drag: CGFloat = 0
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		HStack(spacing: 12) {
			icon
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(model.isHandingOver ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
					.lineLimit(1)
				Text(step)
					.font(.caption)
					.foregroundStyle(stepStyle)
					.lineLimit(2)
			}
			Spacer(minLength: 4)
			trailing
		}
		.padding(.leading, 10)
		.padding(.trailing, 14)
		.padding(.vertical, 8)
		.frame(minHeight: 56)
		.contentShape(Capsule())
		.modifier(BarBackground(tint: model.isHandingOver ? .accentColor : nil))
		.offset(y: max(0, drag))
		.onTapGesture { showingDetails = true }
		.gesture(
			DragGesture(minimumDistance: 10)
				.onChanged { value in
					if !model.isRunning || model.alertClosed { drag = value.translation.height }
				}
				.onEnded { value in
					if model.alertClosed, value.translation.height > 40 {
						model.giveUpAlert()
					} else if !model.isRunning, value.translation.height > 40 {
						model.reset()
					}
					withAnimation(.snappy) { drag = 0 }
				}
		)
		.accessibilityAction(named: "Show details") { showingDetails = true }
		.sheet(isPresented: $showingDetails, onDismiss: {
			model.detailsClosed()
			// Import Certificate, from an install that stopped over the app
			// on this iPhone (#99).
			if model.importsAfterDetails {
				model.importsAfterDetails = false
				certificates.beginImport()
			}
		}) {
			InstallBarSheet(model: model)
		}
		// While they're open, an ended install doesn't close by itself.
		.onChange(of: showingDetails) { _, showing in
			if showing { model.detailsOpen = true }
		}
		// Over whatever is on screen, once, from the tab in front (#123).
		.onChange(of: model.leaveStep) { _, step in
			if isFront, step != nil { showingDetails = true }
		}
		.sensoryFeedback(trigger: model.leaveStep) { _, step in
			guard isFront, let step else { return nil }
			return step == .handover ? .success : .warning
		}
		// Nothing left to show details for.
		.onChange(of: model.isIdle) { _, idle in
			if idle { showingDetails = false }
		}
	}

	private var title: String {
		if model.isHandingOver { return "Go to the Home Screen" }
		return switch model.state {
		case .installing(let info, _), .finished(let info, _): info.name
		default: model.shownJob?.title ?? "Install"
		}
	}

	private var step: String {
		// iOS has Atelier's own install (#24, #123).
		if let handover = model.handoverLine { return handover }
		var text: String
		switch model.state {
		// Signing in to Apple and asking iOS, with an Apple ID (#49).
		case nil, .checking: text = model.checkingNote ?? "Preparing…"
		case .downloading: text = "Downloading…"
		// The certificate the app on this iPhone was installed with, when
		// it's another than the default (#99).
		case .signing(.unpacking): text = model.signingNote ?? "Unpacking…"
		case .signing(.signing): text = model.signingNote ?? (model.signsWithAppleID ? "Signing with your Apple ID…" : "Signing with your certificate…")
		case .signing(.packing): text = model.signingNote ?? "Packing the signed app…"
		// Disable deletes the app once its data is copied (#49).
		case .installing(_, .connecting) where model.shownJob?.isDisable == true: text = "Taking it off this \(ThisDevice.name)…"
		case .installing(_, .connecting): text = "Connecting to iOS…"
		case .installing(_, .waitingForApproval): text = "Tap Install in the iOS alert."
		case .installing(_, .alertClosed): text = model.selfAlertClosedText ?? "The iOS alert closed without installing."
		case .installing(_, .downloading): text = "Sending the app to iOS…"
		case .installing(_, .installing): text = "Installing…"
		case .installing(_, .copyingData): text = "Copying its data…"
		case .installing(_, .restoringData): text = "Putting its data back…"
		case .finished(_, .confirmed) where model.shownJob?.isPutBack == true: text = "Data put back"
		case .finished(_, .confirmed) where model.shownJob?.isDisable == true: text = "Offloaded, its data kept"
		case .finished where model.dataNotPutBack: text = "Installed, but its data wasn't put back."
		case .finished(_, .confirmed): text = model.selfNote ?? "Installed"
		case .finished(_, .unconfirmed): text = "Probably installed. Check your Home Screen."
		case .failed(let problem): text = problem.message
		case .cancelled: text = "Cancelled"
		}
		if !model.waiting.isEmpty {
			text += " · \(model.waiting.count) waiting"
		}
		return text
	}

	private var stepStyle: AnyShapeStyle {
		if model.isHandingOver { return AnyShapeStyle(Color.white.opacity(0.85)) }
		return switch model.state {
		case .finished where model.dataNotPutBack: AnyShapeStyle(.orange)
		case .finished(_, .confirmed): AnyShapeStyle(.green)
		case .failed: AnyShapeStyle(.red)
		default: AnyShapeStyle(.secondary)
		}
	}

	/// The step's progress, nil where it isn't known.
	private var fraction: Double? {
		switch model.state {
		case .downloading(let fraction): fraction
		case .signing(.unpacking(let fraction)): fraction
		case .signing(.packing(let fraction)): fraction
		case .installing(_, .downloading(let fraction)): fraction
		case .installing(_, .installing(let fraction)): fraction
		case .installing(_, .copyingData(let fraction)): fraction
		case .installing(_, .restoringData(let fraction)): fraction
		default: nil
		}
	}

	@ViewBuilder
	private var icon: some View {
		if model.isHandingOver {
			Image(systemName: "house.fill")
				.font(.title3)
				.foregroundStyle(.white)
				.frame(width: 40, height: 40)
				.background(Color.white.opacity(0.22), in: Circle())
		} else if let url = model.shownJob?.iconURL {
			SourceIcon(url: url, tint: nil, size: 40)
		} else {
			Image(systemName: symbol)
				.font(.title3)
				.foregroundStyle(.white)
				.frame(width: 40, height: 40)
				.background(symbolColor, in: RoundedRectangle(cornerRadius: 40 * 0.22, style: .continuous))
		}
	}

	private var symbol: String {
		switch model.state {
		case .finished where model.dataNotPutBack: "exclamationmark"
		case .finished(_, .confirmed): "checkmark"
		case .finished(_, .unconfirmed): "questionmark"
		case .failed: "exclamationmark"
		default: "app.badge"
		}
	}

	private var symbolColor: Color {
		switch model.state {
		case .finished where model.dataNotPutBack: .orange
		case .finished(_, .confirmed): .green
		case .failed: .red
		default: .accentColor
		}
	}

	@ViewBuilder
	private var trailing: some View {
		if model.alertClosed {
			HStack(spacing: 8) {
				Button("Try again") { model.retryAlert() }
					.font(.caption.bold())
					.buttonStyle(.bordered)
					.buttonBorderShape(.capsule)
					.controlSize(.small)
				DismissButton { model.giveUpAlert() }
			}
		} else if model.isHandingOver {
			// Nothing to wait for in Atelier: iOS installs it once it closes (#24).
			EmptyView()
		} else if model.isRunning {
			ProgressRing(fraction: fraction)
				.frame(width: 26, height: 26)
		} else {
			HStack(spacing: 8) {
				if case .finished(_, .unconfirmed) = model.state, model.retryJob != nil {
					Button("Install again") { model.installAgain() }
						.font(.caption.bold())
						.buttonStyle(.bordered)
						.buttonBorderShape(.capsule)
						.controlSize(.small)
				} else if case .failed(let problem) = model.state, let fix = problem.fix {
					FixButton(fix: fix, model: model, short: true)
						.labelStyle(.titleOnly)
						.font(.caption.bold())
						.buttonStyle(.bordered)
						.buttonBorderShape(.capsule)
						.controlSize(.small)
				}
				DismissButton { model.reset() }
			}
		}
	}
}

/// The bar's ✕.
private struct DismissButton: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.secondary)
				.frame(width: 28, height: 28)
				.background(.quaternary, in: Circle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Dismiss")
	}
}

/// Liquid Glass on iOS 26 and later, a material capsule before; tinted
/// while it says what's left for the user to do (#123).
private struct BarBackground: ViewModifier {
	let tint: Color?

	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			let glass = tint.map { Glass.regular.tint($0) } ?? .regular
			content.glassEffect(glass.interactive(), in: Capsule())
		} else if let tint {
			content
				.background(tint, in: Capsule())
				.shadow(color: tint.opacity(0.35), radius: 12, y: 4)
		} else {
			content
				.background(.regularMaterial, in: Capsule())
				.overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
				.shadow(color: .black.opacity(0.12), radius: 12, y: 4)
		}
	}
}

/// What fixes a failed install: importing a certificate, the install
/// settings, freeing space, or trying again.
struct FixButton: View {
	let fix: InstallProblem.Fix
	let model: InstallModel
	/// The bar's shorter titles.
	var short = false
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		switch fix {
		case .importCertificate:
			Button(short ? "Import" : "Import Certificate", systemImage: "person.badge.key") {
				certificates.beginImport()
			}
		case .installSettings:
			Button(short ? "Settings" : "Open Install Settings", systemImage: "gearshape") {
				model.settingsRequested = true
			}
		case .freeSpace:
			Button(short ? "Storage" : "Manage Storage", systemImage: "internaldrive") {
				model.settingsRequested = true
			}
		case .tryAgain:
			if model.retryJob != nil {
				Button("Try again", systemImage: "arrow.clockwise") { model.installAgain() }
			}
		case .signInToGitHub:
			// Then the install starts again, its download through the
			// account (#134).
			GitHubSignInButton(title: short ? "Sign In" : "Sign In to GitHub", showsMark: !short) {
				if model.retryJob != nil { model.installAgain() }
			}
		case .anotherCertificate:
			// A free Apple ID that can't add the app's App ID this week
			// (#49): its details list what else can sign it, as the question
			// before a new App ID does, another free Apple ID among them.
			if !short, model.retryJob != nil, !model.otherSigners.isEmpty {
				NavigationLink {
					InstallWithList(appName: appName, choices: model.otherSigners) { choice in
						model.installWithCertificate(choice.id, newAppIDAsked: choice.isFreeAppleID)
					}
				} label: {
					Label("Install with Another Certificate", systemImage: "signature")
				}
			}
		case .makeRoom:
			// The 3 places a free Apple ID's apps have are taken (#49): the
			// sheet that showed by itself, again, and in the details, Try
			// again, for once one of them is deleted from the Home Screen.
			if model.canShowMakeRoom {
				Button(short ? "Make Room" : "Make Room…", systemImage: "arrow.down.app") { model.showMakeRoom() }
			}
			if !short, model.retryJob != nil {
				Button("Try again", systemImage: "arrow.clockwise") { model.installAgain() }
			}
		case .replaceInstalled:
			// Two choices don't fit the bar; its details have them.
			if !short, model.retryJob != nil {
				if !otherCertificates.isEmpty {
					Menu("Install with Another Certificate", systemImage: "signature") {
						Section("Sign \(appName) with") {
							ForEach(otherCertificates) { certificate in
								let attention = CertificateAttention(certificate)
								Button {
									model.installWithCertificate(certificate.id)
								} label: {
									Text(certificate.displayName)
									Text(subtitle(certificate, attention: attention))
								}
								.disabled(attention == .revoked || attention == .expired)
							}
							if let failed = failedCertificate {
								Button {} label: {
									Text(failed.displayName)
									Text("Just failed")
								}
								.disabled(true)
							}
						}
					}
				}
				if model.copyTarget != nil {
					Button("Install as a Copy", systemImage: "plus.square.on.square") { model.installAsCopy() }
				}
			}
		}
	}

	/// The app the failed install was for, as its status names it.
	private var appName: String {
		model.shownJob?.title ?? "the app"
	}

	/// The certificate the failed install signed with, if it signed.
	private var failedCertificate: StoredCertificate? {
		certificates.certificates.first { $0.id == model.failedCertificateID }
	}

	/// The certificates to try instead: the default first, then the rest as
	/// Settings lists them, leaving out the one that just failed.
	private var otherCertificates: [StoredCertificate] {
		let defaultID = certificates.defaultID
		let failedID = model.failedCertificateID
		return (certificates.certificates.filter { $0.id == defaultID } + certificates.certificates.filter { $0.id != defaultID })
			.filter { $0.id != failedID }
	}

	private func subtitle(_ certificate: StoredCertificate, attention: CertificateAttention?) -> String {
		let state = switch attention {
		case .revoked: "Revoked"
		case .expired: "Expired"
		case .expiring, nil: certificate.remainingText()
		}
		let installedWith = certificate.id == model.installedCertificateID ? "Installed with" : nil
		return [installedWith, certificate.id == certificates.defaultID ? "Default" : nil, certificate.profile.kind.title, state]
			.compactMap { $0 }
			.joined(separator: " · ")
	}
}

/// A progress ring like the App Store's, spinning while there's no fraction.
struct ProgressRing: View {
	let fraction: Double?

	var body: some View {
		if let fraction {
			ZStack {
				Circle().stroke(.quaternary, lineWidth: 3)
				Circle()
					.trim(from: 0, to: max(0.02, fraction))
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(.linear(duration: 0.2), value: fraction)
			}
		} else {
			ProgressView()
		}
	}
}

/// The install bar's sheet: what's left to do while Atelier's own install
/// waits for Atelier to leave the screen (#123), else the install's
/// details.
private struct InstallBarSheet: View {
	let model: InstallModel

	var body: some View {
		if let step = model.leaveStep {
			HomeScreenSheet(model: model, step: step)
		} else {
			InstallDetailsView(model: model)
				.presentationDetents([.medium, .large])
		}
	}
}

/// The install bar's details, in a sheet: the current or last install with
/// its log, Cancel, and the installs waiting after it.
struct InstallDetailsView: View {
	@Bindable var model: InstallModel
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			List {
				InstallStatusSection(model: model)
			}
			.navigationTitle("Install")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		// What the check before an install asks, while these are open (#99).
		.modifier(InstalledConflictAlert(installer: model, onDetails: true))
		.modifier(AppleIDInstallPrompts(installer: model, onDetails: true))
	}
}

/// Signing, the iOS alert, the download, the install, and how it ended, with
/// the install log, and the installs waiting after it.
struct InstallStatusSection: View {
	@Bindable var model: InstallModel
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		Section {
			content
			// Right under the message, as the likely way out (#76): for what's
			// on this iPhone, when that's known (#99).
			if !model.isRunning, model.waiting.isEmpty, let problem = failure, problem.fix == .replaceInstalled {
				if let conflict = problem.conflict {
					ConflictButtons(conflict: conflict, model: model) { dismiss() }
				} else {
					FixButton(fix: .replaceInstalled, model: model)
				}
			}
			if !model.log.isEmpty {
				DisclosureGroup("Install log") {
					Text(model.log.joined(separator: "\n"))
						.font(.caption.monospaced())
						.textSelection(.enabled)
				}
				ShareLink(item: model.log.joined(separator: "\n")) {
					Label("Share log", systemImage: "square.and.arrow.up")
				}
			}
			if model.alertClosed {
				Button("Try again", systemImage: "arrow.clockwise") { model.retryAlert() }
				Button("Dismiss") { model.giveUpAlert() }
			} else if model.isRunning {
				Button(cancelTitle, role: .destructive) { model.cancel() }
			} else if model.waiting.isEmpty {
				if case .finished(_, .unconfirmed) = model.state, model.retryJob != nil {
					Button("Install again", systemImage: "arrow.clockwise") { model.installAgain() }
				} else if let fix = failure?.fix, fix != .replaceInstalled {
					FixButton(fix: fix, model: model)
				}
				Button("Dismiss") { model.reset() }
			}
		} footer: {
			// Under Delete … and Install, what it does with the app's data.
			if let conflict = failure?.conflict, model.retryJob != nil {
				Text(conflict.dataNote)
			} else if let detail = failure?.detail {
				Text(detail)
			}
		}
		// The failure already says so, with what to do (#76).
		if let problem = model.upgradeProblem, failure?.fix != .replaceInstalled {
			Section {
				Label(problem, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.orange)
			}
		}
		if let permissions = model.permissions, !permissions.privacy.isEmpty || !(permissions.entitlements?.items.isEmpty ?? true) {
			Section {
				NavigationLink {
					List {
						PermissionsList(
							privacy: permissions.namedPrivacy,
							capabilities: permissions.entitlements?.capabilities ?? [],
							notes: permissions.entitlements?.notes ?? [],
							checked: permissions.checked
						)
					}
					.navigationTitle("Permissions")
					.navigationBarTitleDisplayMode(.inline)
				} label: {
					LabeledContent("Permissions", value: Self.summary(of: permissions))
				}
			}
		}
		if !model.waiting.isEmpty {
			Section("Waiting") {
				ForEach(model.waiting) { job in
					Label(job.title, systemImage: "clock")
						.swipeActions {
							Button("Remove", role: .destructive) { model.remove(job) }
						}
				}
			}
		}
	}

	/// Why the install failed, once it has.
	private var failure: InstallProblem? {
		if case .failed(let problem) = model.state { problem } else { nil }
	}

	/// Put Back in the Library rather than an install (#96).
	private var isPutBack: Bool {
		model.shownJob?.isPutBack == true
	}

	/// Disable in the Library rather than an install (#49).
	private var isDisable: Bool {
		model.shownJob?.isDisable == true
	}

	private var cancelTitle: String {
		if isPutBack { return "Cancel Put Back" }
		return isDisable ? "Cancel Offload" : "Cancel install"
	}

	/// "2 privacy, 4 capabilities".
	private static func summary(of permissions: SignedPermissions) -> String {
		var parts: [String] = []
		if !permissions.privacy.isEmpty { parts.append("\(permissions.privacy.count) privacy") }
		let capabilities = permissions.entitlements?.capabilities.count ?? 0
		if capabilities > 0 { parts.append(capabilities == 1 ? "1 capability" : "\(capabilities) capabilities") }
		return parts.joined(separator: ", ")
	}

	@ViewBuilder
	private var content: some View {
		switch model.state {
		case nil, .checking:
			ProgressView(model.checkingNote ?? "Checking your certificate and free space…")
		case .downloading(let fraction):
			if let fraction {
				ProgressView("Downloading the app…", value: fraction)
			} else {
				ProgressView("Downloading the app…")
			}
		case .signing(let step):
			signing(step)
		case .installing(let info, let phase):
			LabeledContent(info.name, value: info.version)
			running(phase)
		case .finished(let info, let outcome):
			LabeledContent(info.name, value: info.version)
			finished(outcome)
		case .failed(let problem):
			Label(problem.message, systemImage: "exclamationmark.triangle")
				.foregroundStyle(.red)
		case .cancelled:
			Label(isPutBack ? "Put Back cancelled." : isDisable ? "Offload cancelled. The app stays, with its data." : "Install cancelled.", systemImage: "xmark.circle")
		}
	}

	@ViewBuilder
	private func signing(_ step: SigningProgress) -> some View {
		switch step {
		case .unpacking(let fraction):
			// Getting the app's profile from Apple first (#49).
			if model.signsWithAppleID, let note = model.signingNote {
				ProgressView(note)
			} else {
				ProgressView("Unpacking the app…", value: fraction)
			}
		case .signing:
			ProgressView(model.signingNote ?? (model.signsWithAppleID ? "Signing with your Apple ID…" : "Signing with your certificate…"))
		case .packing(let fraction):
			ProgressView("Packing the signed app…", value: fraction)
		}
	}

	@ViewBuilder
	private func running(_ phase: InstallPhase) -> some View {
		switch phase {
		case .connecting:
			ProgressView(isDisable ? "Taking it off this \(ThisDevice.name)…" : "Connecting to iOS…")
		case .waitingForApproval:
			Label("Tap Install in the iOS alert.", systemImage: "hand.tap")
		case .alertClosed:
			Label("The iOS alert closed without installing. Try again to show it again; the app is already signed.", systemImage: "exclamationmark.circle")
		case .downloading(let fraction):
			ProgressView("Sending the app to iOS…", value: fraction)
		case .installing(let fraction):
			if let fraction {
				ProgressView("Installing…", value: fraction)
			} else {
				ProgressView("Installing…")
			}
		case .copyingData(let fraction):
			if let fraction {
				ProgressView("Copying its data…", value: fraction)
			} else {
				ProgressView("Copying its data…")
			}
		case .restoringData(let fraction):
			if let fraction {
				ProgressView("Putting its data back…", value: fraction)
			} else {
				ProgressView("Putting its data back…")
			}
		}
	}

	@ViewBuilder
	private func finished(_ result: InstallResult) -> some View {
		if isPutBack {
			Label("Data put back.", systemImage: "checkmark.circle")
				.foregroundStyle(.green)
		} else if isDisable {
			Label("Offloaded. Atelier keeps its data until you reinstall it.", systemImage: "icloud.and.arrow.down")
				.foregroundStyle(.green)
		} else if model.dataNotPutBack {
			// The install log says why (#96).
			Label("Installed, but its data wasn't put back.", systemImage: "exclamationmark.triangle")
				.foregroundStyle(.orange)
			Text("Atelier kept the data it copied. Put Back in the Library tries again.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		} else {
			finishedInstall(result)
		}
	}

	@ViewBuilder
	private func finishedInstall(_ result: InstallResult) -> some View {
		switch result {
		case .confirmed:
			// "Updated to 0.2.0-alpha.", for Atelier's own install (#24).
			Label(model.selfNote.map { "\($0)." } ?? "Installed.", systemImage: "checkmark.circle")
				.foregroundStyle(.green)
		case .unconfirmed:
			Label("Sent to iOS. Check your Home Screen for the app.", systemImage: "checkmark.circle")
			Text("Atelier couldn't confirm this install. The install log says why. If the app isn't there, install it again.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}
}

/// What won't work in a signed app, from its entitlements (#7), for the
/// install history.
struct LimitsSection: View {
	let limits: [String]

	static let why = "Your certificate decides what a re-signed app can use, not Atelier."

	var body: some View {
		Section {
			ForEach(limits, id: \.self) { limit in
				Label(limit, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.orange)
			}
		} header: {
			Text("What won't work")
		} footer: {
			Text(LimitsSection.why + " The install log has the details.")
		}
	}
}
