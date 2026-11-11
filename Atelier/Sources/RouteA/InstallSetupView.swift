import InstallKit
import SwiftUI

/// Settings › Installs › Setup (#9): route A's one-time setup as three steps
/// that always show (pair this iPhone, enable the local VPN, wrap up), each
/// a card like the pairing Live Activity's (#54, the mockup of 23 Oct
/// 2026). Atelier installs out of the box without it; it's what lets Atelier
/// install in the background (29 Oct 2026). The first step not done is
/// a dark card with what to do, with the later ones greyed below it. A done
/// step turns white with a full green bar, and tapping it opens what's left
/// of it, such as Pair Again and Remove Setup. The pairing log is under the ⋯
/// menu; importing a pairing file made on a computer is in Settings ›
/// Installs › Advanced, except before iOS 27, where it's how step 1 pairs.
///
/// Step 3, Wrapping up, is the check, then automatic updates, which the
/// setup makes possible (#72): recommended once, while they're off, with
/// their switch left to Settings › Updates (3 Nov 2026). It held the
/// switch from 25 Oct.
struct InstallSetupView: View {
	@State private var setup = RouteASetup.shared
	@State private var pairing = PhonePairing.shared
	@AppStorage(AutoUpdates.enabledKey) private var autoUpdate = false
	@AppStorage(AutoUpdates.whileChargingKey) private var autoUpdateWhileCharging = true
	@AppStorage(RouteASetup.autoUpdatesAskedKey) private var autoUpdatesAsked = false
	/// A done step the user tapped open.
	@State private var opened: Step?
	@State private var confirmingRemoval = false
	@State private var showingLog = false
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	enum Step: Int, CaseIterable {
		case pair = 1, vpn, check
	}

	private typealias Pairing = PairingActivityAttributes.ContentState

	var body: some View {
		Form {
			Section {
			} footer: {
				Text(isDone(.check) ? InstallSetup.finished : setup.isSetUp ? InstallSetup.setUp : InstallSetup.intro)
					.font(.subheadline)
			}

			ForEach(Step.allCases, id: \.self) { step in
				Section {
					card(step)
					if isDone(step), opened == step {
						details(step)
					}
				} header: {
					Text(sectionTitle(step))
				} footer: {
					if step == current, !isDone(step) {
						note(step)
					}
				}
			}
		}
		.navigationTitle("Setup")
		.toolbar {
			Menu {
				Button("Pairing Log") { showingLog = true }
					.disabled(pairing.log.isEmpty)
			} label: {
				Label("More", systemImage: "ellipsis.circle")
			}
		}
		.sheet(isPresented: $showingLog) { logSheet }
		.task {
			await setup.refresh()
			await setup.watchNetwork()
		}
		.refreshable { await setup.refresh() }
		.onChange(of: pairing.status) { Task { await setup.refresh() } }
		// Back from LocalDevVPN, the App Store or Settings.
		.onChange(of: scenePhase) { _, phase in
			if phase == .active {
				SetupLiveActivity.shared.state = liveActivityState
				Task { await setup.refresh() }
			}
		}
		.onChange(of: liveActivityState, initial: true) { _, state in
			SetupLiveActivity.shared.state = state
		}
		.onDisappear { SetupLiveActivity.shared.state = nil }
	}

	// MARK: Steps

	/// The check is done only once the steps before it are: the install
	/// service answers with no pairing, which isn't set up. LocalDevVPN
	/// stands on its own. Step 3 then waits for automatic updates' answer,
	/// unless they're on.
	private func isDone(_ step: Step) -> Bool {
		switch step {
		case .pair: setup.isPaired && !pairing.isActive
		case .vpn: setup.isVPNInstalled && vpnOK == true
		case .check: isDone(.pair) && isDone(.vpn) && setup.network == .ready && autoUpdatesAnswered
		}
	}

	/// Automatic updates are on, or Turn On or Not Now was tapped: the
	/// setup doesn't ask again.
	private var autoUpdatesAnswered: Bool {
		autoUpdate || autoUpdatesAsked
	}

	/// The first step not done; the check once all are.
	private var current: Step {
		Step.allCases.first { !isDone($0) } ?? .check
	}

	/// Set up, but this step has stopped working, such as LocalDevVPN
	/// disconnecting.
	private func needsAttention(_ step: Step) -> Bool {
		setup.isSetUp && step == current && !isDone(step)
	}

	private func sectionTitle(_ step: Step) -> String {
		switch step {
		case .pair: "Step 1: \(ThisDevice.name) pairing"
		case .vpn: "Step 2: Enable Local VPN"
		case .check: "Step 3: Wrapping up"
		}
	}

	@ViewBuilder
	private func card(_ step: Step) -> some View {
		if isDone(step) {
			doneCard(step)
		} else if step == current {
			VStack(alignment: .leading, spacing: 12) {
				switch step {
				case .pair: pairCard
				case .vpn: vpnCard
				case .check: checkCard
				}
			}
			.padding(.vertical, 6)
			.environment(\.colorScheme, .dark)
			.listRowBackground(Color.black)
		} else {
			laterCard(step)
		}
	}

	private func doneCard(_ step: Step) -> some View {
		Button {
			withAnimation { opened = opened == step ? nil : step }
		} label: {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Label(doneTitle(step), systemImage: "checkmark")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.green)
					Spacer()
					Text("Done")
						.font(.footnote)
						.foregroundStyle(.secondary)
					Image(systemName: opened == step ? "chevron.up" : "chevron.down")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.tertiary)
				}
				ProgressView(value: 1)
					.tint(.green)
			}
			.padding(.vertical, 4)
		}
		.tint(.primary)
	}

	private func doneTitle(_ step: Step) -> String {
		switch step {
		case .pair: "\(ThisDevice.name) paired"
		case .vpn: "LocalDevVPN connected"
		case .check: "Ready to install"
		}
	}

	/// A step after the current one, greyed.
	private func laterCard(_ step: Step) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Label(step == .vpn ? "Connect LocalDevVPN" : "Wrapping up", systemImage: symbol(step))
				.font(.footnote.weight(.semibold))
			Text(step == .vpn ? "After pairing" : "After the local VPN")
				.font(.subheadline)
			ProgressView(value: 0)
		}
		.foregroundStyle(.secondary)
		.opacity(0.6)
		.padding(.vertical, 4)
	}

	private func symbol(_ step: Step) -> String {
		switch step {
		case .pair: "link"
		case .vpn: "shield"
		case .check: "wifi"
		}
	}

	/// The top line of a dark card: what it is, and how far along.
	private func cardTop(_ title: String, symbol: String, tint: Color, status: String? = nil) -> some View {
		HStack {
			Label(title, systemImage: symbol)
				.font(.footnote.weight(.semibold))
				.foregroundStyle(tint)
			Spacer()
			if let status {
				Text(status)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func cardText(_ headline: String, _ detail: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(headline)
				.font(.headline)
			Text(detail)
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}
	}

	/// Below the current step's card.
	@ViewBuilder
	private func note(_ step: Step) -> some View {
		switch (step, pairing.status) {
		case (.pair, .ready):
			Text("If Settings opens somewhere else, follow the path above. Don't see Pair with Atelier? Turn on Developer Mode first; the \(ThisDevice.name) restarts.")
		case (.pair, .enterCode):
			Text("The code also shows in the Dynamic Island while you're in Settings.")
		default:
			EmptyView()
		}
	}

	// MARK: Step 1

	@ViewBuilder
	private var pairCard: some View {
		switch pairing.status {
		case .starting:
			cardTop("Pairing this \(ThisDevice.name)", symbol: "link", tint: .pink, status: "Getting ready")
			HStack {
				ProgressView()
				Text("Starting the pairing service…")
					.font(.subheadline)
			}
			ProgressView(value: 0)
				.tint(.pink)
			cancelButton
		case .ready:
			cardTop("Pairing this \(ThisDevice.name)", symbol: "link", tint: .pink, status: "Step 1 of 3")
			cardText(Pairing.settingsPath, Pairing.settingsTap)
			ProgressView(value: 1, total: 3)
				.tint(.pink)
			settingsButtons
		case .enterCode(let code):
			cardTop("Pairing this \(ThisDevice.name)", symbol: "link", tint: .pink, status: "Step 2 of 3")
			Text("Enter this code in Settings")
				.font(.subheadline)
			Text(code)
				.font(.system(size: 40, weight: .bold, design: .monospaced))
				.frame(maxWidth: .infinity)
				.textSelection(.enabled)
			ProgressView(value: 2, total: 3)
				.tint(.pink)
			settingsButtons
		case .idle, .paired, .failed:
			cardTop("Pair this \(ThisDevice.name)", symbol: "link", tint: .pink)
			if PhonePairing.isSupported {
				Text("Atelier shows a 6-digit code, and you enter it once in Settings. Your \(ThisDevice.name) then lets Atelier use its install service.")
					.font(.subheadline)
				if case .failed(let why) = pairing.status {
					Text(why)
						.font(.subheadline)
						.foregroundStyle(.red)
				}
				ProgressView(value: 0)
					.tint(.pink)
				Button("Pair This \(ThisDevice.name)") { pairing.start() }
					.buttonStyle(CardButtonStyle(fill: .pink))
			} else {
				Text("Pairing on the \(ThisDevice.name) itself needs iOS 27. On this iOS, import a pairing file made on a computer.")
					.font(.subheadline)
				ProgressView(value: 0)
					.tint(.pink)
				Button("Import Pairing File") { setup.pickPairingFile() }
					.buttonStyle(CardButtonStyle(fill: .pink))
			}
			if let problem = setup.importProblem {
				Text(problem)
					.font(.subheadline)
					.foregroundStyle(.red)
			}
		}
	}

	private var settingsButtons: some View {
		HStack(spacing: 10) {
			Button("Open Settings") { Task { await setup.openDeveloperModeSettings() } }
				.buttonStyle(CardButtonStyle(fill: .pink))
			cancelButton
		}
	}

	private var cancelButton: some View {
		Button("Cancel", role: .cancel) { pairing.cancel() }
			.buttonStyle(CardButtonStyle(fill: CardButtonStyle.grey))
	}

	/// Step 1 done and opened: what it was before the cards (#54).
	@ViewBuilder
	private var pairDetails: some View {
		if let date = setup.pairingSavedAt {
			LabeledContent("Paired", value: date.formatted(date: .abbreviated, time: .omitted))
		}
		if let udid = setup.udid {
			LabeledContent("This \(ThisDevice.name)'s UDID", value: udid)
				.textSelection(.enabled)
		}
		if PhonePairing.isSupported {
			Button("Pair Again") { pairing.start() }
		} else {
			Button("Import a New Pairing File") { setup.pickPairingFile() }
		}
		VStack(alignment: .leading, spacing: 6) {
			// Attached to the button, so iOS anchors the dialog's popover to it.
			Button("Remove Setup", role: .destructive) { confirmingRemoval = true }
				.confirmationDialog("Remove Atelier's setup?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
					Button("Remove", role: .destructive) {
						setup.removeSetup()
						opened = nil
					}
				} message: {
					Text(InstallSetup.removal)
				}
			Text("Removing it deletes the pairing. Atelier can still install apps, but can't install updates on its own.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		if let problem = setup.importProblem {
			Text(problem).foregroundStyle(.red)
		}
	}

	@ViewBuilder
	private func details(_ step: Step) -> some View {
		switch step {
		case .pair:
			pairDetails
		case .vpn:
			Text("LocalDevVPN is connected. It switches back to Atelier by itself when an install needs it.")
			Button("Open LocalDevVPN") { Task { _ = await setup.openLocalDevVPN() } }
		case .check:
			checkRow("Wi-Fi", ok: wifiOK, value: wifiText)
			checkRow("iOS install service", ok: serviceOK, value: serviceText)
			LabeledContent("Automatic updates", value: autoUpdate ? "On" : "Off")
			explanation(checkDone)
		}
	}

	/// Step 3 opened once it's done: what its readings mean, and what
	/// automatic updates do, or would.
	private var checkDone: String {
		if !autoUpdate {
			return "Everything answers. On Wi-Fi, Atelier downloads your updates ahead, so Update only signs and installs them. To have it install them by itself, turn on Install updates automatically in Settings › Updates."
		}
		if autoUpdateWhileCharging {
			return "Everything answers. Atelier installs your updates by itself while this \(ThisDevice.name) charges, on Wi-Fi with LocalDevVPN connected. Settings › Updates has the switch."
		}
		return "Everything answers. Atelier installs your updates by itself, in the background, on Wi-Fi with LocalDevVPN connected. Settings › Updates has the switch."
	}

	// MARK: Step 2

	@ViewBuilder
	private var vpnCard: some View {
		if !setup.isVPNInstalled {
			cardTop("Connect LocalDevVPN", symbol: "shield", tint: .blue, status: "Step 1 of 2")
			cardText("Get LocalDevVPN from the App Store", "then come back here and tap Connect")
			Text("LocalDevVPN is a free App Store app. It lets Atelier reach iOS's install service on this \(ThisDevice.name), without sending anything off it.")
				.font(.footnote)
				.foregroundStyle(.secondary)
			ProgressView(value: 1, total: 2)
				.tint(.blue)
			HStack(spacing: 10) {
				Button("Get LocalDevVPN") { openURL(RouteASetup.localDevVPNAppStore) }
					.buttonStyle(CardButtonStyle(fill: .blue))
				Button("Connect") {}
					.buttonStyle(CardButtonStyle(fill: CardButtonStyle.grey))
					.disabled(true)
			}
		} else if needsAttention(.vpn) {
			cardTop("LocalDevVPN", symbol: "exclamationmark.triangle.fill", tint: .orange, status: "Not connected")
			Text("LocalDevVPN isn't connected, so Atelier can't reach iOS's install service. Until it is, Atelier can still install apps, but can't install updates on its own.")
				.font(.subheadline)
			ProgressView(value: 0)
				.tint(.orange)
			Button("Connect") { Task { _ = await setup.openLocalDevVPN() } }
				.buttonStyle(CardButtonStyle(fill: .orange))
		} else {
			cardTop("Connect LocalDevVPN", symbol: "shield", tint: .blue, status: "Step 2 of 2")
			cardText("Tap Connect", "The first time, allow its VPN configuration when iOS asks. LocalDevVPN then switches back to Atelier.")
			ProgressView(value: 2, total: 2)
				.tint(.blue)
			Button("Connect") { Task { _ = await setup.openLocalDevVPN() } }
				.buttonStyle(CardButtonStyle(fill: .blue))
		}
	}

	// MARK: Step 3

	/// Wrapping up, in two parts as step 2 is: the check, then automatic
	/// updates once it passes. The check's readings come first, then what
	/// they mean, so the rows don't read as steps of their own. When the
	/// install service doesn't answer, what to try and a button for it,
	/// rather than only an explanation (1 Nov 2026).
	@ViewBuilder
	private var checkCard: some View {
		if let network = setup.network, let problem = network.setupProblem {
			cardTop("Wrapping up", symbol: "wifi", tint: .orange, status: "Problem")
			checkRow("Wi-Fi", ok: wifiOK, value: wifiText)
			checkRow("iOS install service", ok: serviceOK, value: serviceText)
			if case .unreachable = network, let fix = setup.serviceFix {
				fixContent(fix)
			} else {
				explanation(problem)
			}
			ProgressView(value: 0)
				.tint(.orange)
		} else if setup.network == .ready {
			autoUpdatesCard
		} else {
			cardTop("Wrapping up", symbol: "wifi", tint: .blue, status: "Step 1 of 2")
			HStack {
				ProgressView()
				Text("Checking Wi-Fi and the install service…")
					.font(.subheadline)
			}
			ProgressView(value: 1, total: 2)
				.tint(.blue)
		}
	}

	/// Wrapping up's second part, once the check passes: automatic updates,
	/// recommended with one big button (3 Nov 2026). Turn On turns on
	/// Settings › Updates' switch, and Not Now leaves it off; either one
	/// finishes the setup, and the card doesn't come back.
	@ViewBuilder
	private var autoUpdatesCard: some View {
		cardTop("Wrapping up", symbol: "arrow.triangle.2.circlepath", tint: .blue, status: "Step 2 of 2")
		VStack(alignment: .leading, spacing: 9) {
			StatusPill(title: "Recommended", symbol: "checkmark", color: .green)
			cardText("Install updates automatically", "Atelier installs your apps' updates by itself, in the background, as the App Store does, on Wi-Fi with LocalDevVPN connected.")
		}
		VStack(alignment: .leading, spacing: 9) {
			ForEach(autoUpdateGains, id: \.self) { gain in
				Label {
					Text(gain.text)
				} icon: {
					Image(systemName: gain.symbol)
						.foregroundStyle(.green)
				}
			}
		}
		.font(.subheadline)
		ProgressView(value: 2, total: 2)
			.tint(.blue)
		Button("Turn On Automatic Updates") {
			AutoUpdates.setEnabled(true)
			autoUpdatesAsked = true
		}
		.buttonStyle(CardButtonStyle(fill: .blue))
		Button("Not Now") { autoUpdatesAsked = true }
			.buttonStyle(CardTextButtonStyle())
	}

	/// What automatic updates are like, on their card. Only while charging
	/// is Settings › Updates' own switch, on unless it was turned off.
	private var autoUpdateGains: [InstallSetup.Gain] {
		var gains: [InstallSetup.Gain] = []
		if autoUpdateWhileCharging {
			gains.append(.init(text: "Only while this \(ThisDevice.name) charges", symbol: "bolt.fill"))
		}
		gains.append(.init(text: "A notification says what it updated", symbol: "bell.fill"))
		gains.append(.init(text: "Settings › Updates has the switch", symbol: "gearshape.fill"))
		return gains
	}

	/// What to try when the install service doesn't answer: the fix that
	/// fits what the check saw, with its button, and Try Again. Once it's
	/// done, the next check finds the next fix, if any.
	@ViewBuilder
	private func fixContent(_ fix: RouteANetwork.ServiceFix) -> some View {
		cardText(Self.headline(fix), Self.detail(fix))
		switch fix {
		case .restart:
			tryAgainButton(fill: .orange)
		case .allowLocalNetwork:
			HStack(spacing: 10) {
				Button("Open Settings") { setup.openOwnSettings() }
					.buttonStyle(CardButtonStyle(fill: .orange))
				tryAgainButton(fill: CardButtonStyle.grey)
			}
		case .reconnectVPN:
			HStack(spacing: 10) {
				Button("Open LocalDevVPN") { setup.openLocalDevVPNApp() }
					.buttonStyle(CardButtonStyle(fill: .orange))
				tryAgainButton(fill: CardButtonStyle.grey)
			}
		}
		if let checkedAt = setup.checkedAgainAt, !setup.isCheckingAgain {
			Text("Checked at \(checkedAt.formatted(date: .omitted, time: .shortened))")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
		}
		explanation(fix == .reconnectVPN ? "Still no answer? Restart this \(ThisDevice.name). \(Self.meanwhile)" : Self.meanwhile)
	}

	/// Checks again, looking longer for where the service went.
	private func tryAgainButton(fill: Color) -> some View {
		Button {
			Task { await setup.checkAgain() }
		} label: {
			if setup.isCheckingAgain {
				HStack(spacing: 8) {
					ProgressView()
					Text("Checking…")
				}
			} else {
				Text("Try Again")
			}
		}
		.buttonStyle(CardButtonStyle(fill: fill))
		.disabled(setup.isCheckingAgain)
	}

	/// What still works while the install service doesn't answer, in the
	/// words the maintainer asked for over "installs as it does out of the box" (1 Nov
	/// 2026), as on the LocalDevVPN card, Remove Setup and Settings › Installs.
	private static let meanwhile = "Until it answers, Atelier can still install apps, but can't install updates on its own."

	private static func headline(_ fix: RouteANetwork.ServiceFix) -> String {
		switch fix {
		case .restart: "Try again, then restart this \(ThisDevice.name)"
		case .allowLocalNetwork: "Turn on Local Network for Atelier"
		case .reconnectVPN: "Reconnect LocalDevVPN"
		}
	}

	private static func detail(_ fix: RouteANetwork.ServiceFix) -> String {
		switch fix {
		case .restart:
			"iOS's install service isn't answering, and Atelier couldn't find it on another port. Restarting the \(ThisDevice.name) starts it again. Then come back here."
		case .allowLocalNetwork:
			"iOS's install service isn't answering where it was, and without Local Network Atelier can't look for it elsewhere. Turn it on in Settings, then come back here."
		case .reconnectVPN:
			"Nothing answered Atelier's connection, so LocalDevVPN may not be passing it. In LocalDevVPN, tap Disconnect, then Connect, then come back here."
		}
	}

	/// The island's second line for a fix, away from Atelier.
	private static func islandDetail(_ fix: RouteANetwork.ServiceFix) -> String {
		switch fix {
		case .restart: "Come back to Atelier and tap Try Again"
		case .allowLocalNetwork: "In Settings, then come back to Atelier"
		case .reconnectVPN: "In LocalDevVPN, tap Disconnect, then Connect"
		}
	}

	private func checkRow(_ title: String, ok: Bool?, value: String) -> some View {
		LabeledContent(title) {
			Text(value).foregroundStyle(ok == false ? Color.orange : Color.secondary)
		}
	}

	private func explanation(_ text: String) -> some View {
		Text(text)
			.font(.footnote)
			.foregroundStyle(.secondary)
	}

	// MARK: Live Activity

	/// Steps 2 and 3 while they wait on the user in the first setup, for
	/// SetupLiveActivity; nil otherwise. Pairing has its own. Once the check
	/// has passed, a step that stops working, such as LocalDevVPN
	/// disconnecting, gets none: the Setup row says so (1 Nov 2026).
	private var liveActivityState: SetupLiveActivity.State? {
		guard !setup.hasPassedCheck, !isDone(current) else { return nil }
		switch current {
		case .pair:
			return nil
		case .vpn where !setup.isVPNInstalled:
			return .init(title: "LocalDevVPN", symbol: "shield", tint: .blue, status: "Step 1 of 2",
			             headline: "Get LocalDevVPN from the App Store", detail: "then come back to Atelier and tap Connect",
			             progress: 0.5, compact: "1/2")
		case .vpn where needsAttention(.vpn):
			return .init(title: "LocalDevVPN", symbol: "exclamationmark.triangle.fill", tint: .orange, status: "Not connected",
			             headline: "LocalDevVPN isn't connected", detail: "Come back to Atelier and tap Connect",
			             progress: 0, compact: "Off")
		case .vpn:
			return .init(title: "LocalDevVPN", symbol: "shield", tint: .blue, status: "Step 2 of 2",
			             headline: "Tap Connect", detail: "The first time, allow its VPN configuration when iOS asks",
			             progress: 1, compact: "2/2")
		case .check:
			guard let network = setup.network, let problem = network.setupProblem else { return nil }
			var headline = "The install service didn't answer"
			var detail = problem
			switch network {
			case .noWiFi:
				headline = "Wi-Fi isn't connected"
			case .vpnOff:
				headline = "LocalDevVPN isn't connected"
			case .unreachable, .ready:
				// The card's headline, and what to do away from Atelier.
				if let fix = setup.serviceFix {
					headline = Self.headline(fix)
					detail = Self.islandDetail(fix)
				}
			}
			return .init(title: "Wrapping up", symbol: "wifi", tint: .orange, status: "Problem",
			             headline: headline, detail: detail, progress: 0, compact: "!")
		}
	}

	// Each check depends on the one before: RouteANetwork stops at the first
	// that fails, so the later ones are unknown (nil) then.

	private var vpnOK: Bool? {
		guard let network = setup.network else { return nil }
		return network != .vpnOff
	}

	private var wifiOK: Bool? {
		switch setup.network {
		case nil, .vpnOff?: nil
		case .noWiFi?: false
		default: true
		}
	}

	private var wifiText: String {
		switch wifiOK {
		case true?: "On"
		case false?: "Off"
		case nil: "–"
		}
	}

	private var serviceOK: Bool? {
		switch setup.network {
		case .ready?: true
		case .unreachable?: false
		default: nil
		}
	}

	private var serviceText: String {
		switch setup.network {
		case .ready?: "Answering"
		case .unreachable(let how)?: how.prefix(1).uppercased() + how.dropFirst()
		default: "–"
		}
	}

	// MARK: Pairing log

	private var logSheet: some View {
		NavigationStack {
			Form {
				Section {
					Text(pairing.log.joined(separator: "\n"))
						.font(.caption.monospaced())
						.textSelection(.enabled)
					ShareLink(item: pairing.log.joined(separator: "\n")) {
						Label("Share log", systemImage: "square.and.arrow.up")
					}
				}
			}
			.navigationTitle("Pairing Log")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { showingLog = false }
				}
			}
		}
	}
}

/// What the setup adds, said alike in Settings › Installs, on the setup's
/// screen and when removing it, with nothing about the iOS alert (29
/// Oct 2026). Installs only keep going once Atelier is left from iOS 26
/// (`BackgroundInstalls`).
enum InstallSetup {
	struct Gain: Hashable {
		let text: String
		let symbol: String
	}

	/// The lines of Settings › Installs' card.
	static var gains: [Gain] {
		var gains = [Gain(text: "Update your apps in the background", symbol: "arrow.triangle.2.circlepath")]
		if keepsInstalling {
			gains.append(Gain(text: "Keep installing when you leave it", symbol: "arrow.down.app"))
		}
		gains.append(Gain(text: "Keep apps' data when it signs them again", symbol: "folder"))
		return gains
	}

	static let intro = "Atelier already installs your apps. Once this one-time setup is done, on Wi-Fi with LocalDevVPN connected, it can also install in the background and keep apps' data when it signs them again."

	/// Once set up, while a step doesn't pass, such as LocalDevVPN
	/// disconnecting: the step's card says which.
	static var setUp: String {
		keepsInstalling
			? "On Wi-Fi with LocalDevVPN connected, Atelier can update your apps by itself in the background, keep installing when you leave it, and keep apps' data when it signs them again."
			: "On Wi-Fi with LocalDevVPN connected, Atelier can update your apps by itself in the background and keep apps' data when it signs them again."
	}

	/// Once every step passes.
	static var finished: String { "Finished. \(setUp)" }

	static var removal: String {
		let stops = keepsInstalling ? "installs updates by itself or keeps installing when you leave it" : "installs updates by itself"
		return "Atelier deletes its pairing. It then no longer \(stops). To also make this \(ThisDevice.name) forget Atelier, reset the pairings in Settings › Privacy & Security › Developer Mode."
	}

	private static var keepsInstalling: Bool {
		if #available(iOS 26, *) { return true }
		return false
	}
}

/// Settings › Installs until the setup is finished (the mockup of 29 Oct
/// 2026): Atelier already installs, what the setup adds, and one button to
/// it, which calls `start`. SettingsView opens the setup itself, as a
/// navigation destination doesn't belong in a Form's rows.
struct InstallSetupCard: View {
	/// Get Ready's says Set Up Now (#21).
	var buttonTitle = "Finish Setting Up"
	/// Why it's needed, in bold, where Atelier doesn't install without it:
	/// with an Apple ID in use (#49).
	var lead: String?
	let start: () -> Void

	/// Status's to-do says the same (#49).
	static let appleIDLead = "Apps signed with an Apple ID only install once this one-time setup is done."

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 11) {
				SourceIcon(url: SelfUpdate.shared.iconURL, tint: nil, size: 36)
				if let lead {
					Text("\(Text(lead).bold()) It also lets Atelier:")
				} else {
					Text("**Atelier already installs your apps.** A one-time setup also lets it:")
				}
			}
			VStack(alignment: .leading, spacing: 9) {
				ForEach(InstallSetup.gains, id: \.self) { gain in
					Label {
						Text(gain.text)
					} icon: {
						Image(systemName: gain.symbol)
							.foregroundStyle(.tint)
					}
				}
			}
			Button(action: start) {
				Text(buttonTitle)
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
		}
		.font(.subheadline)
		.padding(.vertical, 8)
	}
}

/// A card's other choice, as text under its filled button: Not Now. A style
/// of its own, as `CardButtonStyle`'s, so a tap runs only this button.
private struct CardTextButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 4)
			.contentShape(.rect)
			.opacity(configuration.isPressed ? 0.6 : 1)
	}
}

/// A filled button inside a setup card. A style of its own also keeps a
/// Form row with two buttons from running both on a tap.
private struct CardButtonStyle: ButtonStyle {
	static let grey = Color(white: 0.17)

	var fill: Color
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.lineLimit(1)
			.minimumScaleFactor(0.8)
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(isEnabled ? Color.white : Color.secondary)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 11)
			.background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: .rect(cornerRadius: 14))
	}
}
