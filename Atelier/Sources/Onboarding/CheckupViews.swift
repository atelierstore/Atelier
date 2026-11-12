import AtelierCore
import CertKit
import InstallKit
import SwiftData
import SwiftUI

/// Runs what Get Ready and Settings › Installs › Status check (#21), and
/// gathers the rest from what Atelier already knows.
@MainActor
@Observable
final class CheckupModel {
	static let shared = CheckupModel()

	/// Set by It's On, when Atelier can't tell whether Developer Mode is on.
	static let developerModeConfirmedKey = "developerModeConfirmed"

	/// The install server's last answer; nil while it's being asked, and
	/// before.
	private(set) var installServer: ManifestEndpoint.Reachability?
	/// When the last check finished, for Status's "checked at".
	private(set) var checkedAt: Date?
	/// Check Again is running.
	private(set) var isChecking = false
	@ObservationIgnored private var serverAnsweredAt: Date?

	private init() {}

	/// The manifest endpoint installs use: the custom one in Advanced when
	/// it's valid, else Atelier's.
	static var endpoint: URL {
		let setting = UserDefaults.standard.string(forKey: InstallModel.endpointKey) ?? ""
		return (try? ManifestEndpoint.resolve(setting).get()) ?? ManifestEndpoint.defaultURL
	}

	/// Asks the install server, unless it answered in the last five minutes.
	func checkInstallServer(force: Bool = false) async {
		if !force, installServer == .reachable, let serverAnsweredAt, Date.now.timeIntervalSince(serverAnsweredAt) < 5 * 60 { return }
		installServer = nil
		let answer = await ManifestEndpoint.check(Self.endpoint)
		installServer = answer
		if answer == .reachable { serverAnsweredAt = .now }
		checkedAt = .now
	}

	/// Check Again: asks Apple about the certificates, the install server,
	/// the setup's check and the sources, all at once.
	func checkAll(certificates: CertificatesModel, sources: SourcesModel) async {
		guard !isChecking else { return }
		isChecking = true
		async let revocation: Void = certificates.refreshStatus(force: true)
		async let server: Void = checkInstallServer(force: true)
		async let setup: Void = refreshSetup()
		async let read: Void = sources.refreshAll()
		_ = await (revocation, server, setup, read)
		isChecking = false
		checkedAt = .now
	}

	private func refreshSetup() async {
		guard RouteASetup.shared.isSetUp else { return }
		await RouteASetup.shared.refresh()
	}

	/// What's checked, from what Atelier knows now.
	func facts(certificates: CertificatesModel, records: [SourceRecord], developerModeConfirmed: Bool, context: ModelContext) -> CheckupFacts {
		let routeA = RouteASetup.shared
		let setup: CheckupFacts.Setup
		if !routeA.isSetUp {
			setup = .notSetUp
		} else if let network = routeA.network {
			setup = .checked(network)
		} else {
			setup = .checking
		}
		let own = SelfUpdate.shared
		// An Apple ID signs apps for App IDs of its own, so not Atelier's,
		// unless it's the one that installed Atelier (#49, #152).
		let canUpdateAtelier = certificates.certificates.isEmpty && certificates.appleIDs.isEmpty
			? nil
			: own.canSignItself(certificates: certificates, context: context)
		return CheckupFacts(
			certificate: certificates.defaultCertificate,
			appleID: certificates.defaultAppleID,
			canUpdateAtelier: canUpdateAtelier,
			ownProfile: own.installedProfile,
			deviceUDID: routeA.udid,
			developerModeRead: routeA.developerMode,
			developerModeConfirmed: developerModeConfirmed,
			installServer: installServer,
			installServerHost: Self.endpoint.host() ?? "",
			setup: setup,
			sources: records.map {
				CheckupFacts.Source(name: $0.name, isBuiltIn: $0.isBuiltIn, refreshError: $0.refreshError, needsGitHubSignIn: $0.needsGitHubSignIn)
			}
		)
	}
}

/// Settings › Installs › Status (#21): Get Ready's page, any time, with the
/// install server and every source added. It was Checkup until the maintainer renamed
/// it, putting it first (3 Nov 2026).
struct CheckupView: View {
	@Environment(CertificatesModel.self) private var certificates
	@Environment(SourcesModel.self) private var sources
	@Environment(\.modelContext) private var context
	@Query(sort: \SourceRecord.addedAt) private var records: [SourceRecord]
	@AppStorage(CheckupModel.developerModeConfirmedKey) private var developerModeConfirmed = false
	@State private var model = CheckupModel.shared
	/// Set Up Now was tapped.
	@State private var settingUp = false

	var body: some View {
		let facts = model.facts(certificates: certificates, records: records, developerModeConfirmed: developerModeConfirmed, context: context)
		Form {
			Section {
			} header: {
				Text(intro)
					.font(.subheadline)
					.textCase(nil)
			}
			CheckupSections(checkup: Checkup(facts, for: .settings), place: .settings) { settingUp = true }
		}
		.navigationTitle("Status")
		.navigationBarTitleDisplayMode(.large)
		.navigationDestination(isPresented: $settingUp) {
			InstallSetupView()
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button("Check Again") {
					Task { await model.checkAll(certificates: certificates, sources: sources) }
				}
				.disabled(model.isChecking)
			}
		}
		.refreshable { await model.checkAll(certificates: certificates, sources: sources) }
		.task { await model.checkInstallServer() }
	}

	private var intro: String {
		if model.isChecking { return "Checking what Atelier needs to install…" }
		guard let checkedAt = model.checkedAt else { return "What Atelier needs to install." }
		return "What Atelier needs to install, checked at \(checkedAt.formatted(date: .omitted, time: .shortened))."
	}
}

/// Settings › Installs' Status row: All good, or the first thing to fix or
/// look at, such as LocalDevVPN off, which the Setup row said until it only
/// said Finished (3 Nov 2026).
struct CheckupSummary: View {
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context
	@Query(sort: \SourceRecord.addedAt) private var records: [SourceRecord]
	@AppStorage(CheckupModel.developerModeConfirmedKey) private var developerModeConfirmed = false
	@State private var model = CheckupModel.shared

	var body: some View {
		let facts = model.facts(certificates: certificates, records: records, developerModeConfirmed: developerModeConfirmed, context: context)
		let attention = Checkup(facts, for: .settings).attention
		HStack(spacing: 4) {
			switch attention?.state {
			case nil:
				Image(systemName: "checkmark")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.green)
				Text("All good")
			case .problem?:
				Image(systemName: "exclamationmark.circle.fill")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.red)
				Text(attention?.summary ?? "")
			default:
				Image(systemName: "exclamationmark.triangle.fill")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.orange)
				Text(attention?.summary ?? "")
			}
		}
		.lineLimit(1)
	}
}

/// The things Get Ready and Status list, a section each: a row with a check
/// once it's fine, a card with its fix while it isn't.
struct CheckupSections: View {
	let checkup: Checkup
	let place: Checkup.Place
	/// Set Up Now: opens the setup.
	let setUp: () -> Void
	@Environment(CertificatesModel.self) private var certificates
	@Environment(SourcesModel.self) private var sources
	@AppStorage(CheckupModel.developerModeConfirmedKey) private var developerModeConfirmed = false

	var body: some View {
		ForEach(sections, id: \.first?.kind) { section in
			Section {
				ForEach(section) { item in
					if item.state.isCard {
						card(item)
					} else {
						row(item)
					}
				}
			} header: {
				if section.first?.state == .optional {
					Text("Optional")
				}
			} footer: {
				if let text = footerText(of: section) {
					Text(text)
				}
			}
		}
	}

	/// A section each, but for the install server and the setup, which
	/// share one while both are rows.
	private var sections: [[Checkup.Item]] {
		var sections: [[Checkup.Item]] = []
		for item in checkup.items {
			if item.kind == .setup, !item.state.isCard,
			   let last = sections.last?.last, last.kind == .installServer, !last.state.isCard {
				sections[sections.count - 1].append(item)
			} else {
				sections.append([item])
			}
		}
		return sections
	}

	private func footerText(of section: [Checkup.Item]) -> String? {
		guard section.count == 1, let item = section.first else { return nil }
		let needs = "A few minutes, once. It needs LocalDevVPN, a free App Store app, and works on Wi-Fi."
		let setupNote = place == .getReady ? "\(needs) It's also in Settings › Installs." : needs
		switch item.state {
		case .optional:
			return setupNote
		case .todo where item.kind == .setup:
			// With an Apple ID in use (#49).
			return setupNote
		case .ok, .checking, .notice:
			return item.text
		case .todo, .warning, .problem:
			return nil
		}
	}

	@ViewBuilder
	private func row(_ item: Checkup.Item) -> some View {
		switch item.kind {
		case .certificate:
			NavigationLink {
				CertificatesView()
			} label: {
				rowLabel(item)
			}
		case .setup:
			NavigationLink {
				InstallSetupView()
			} label: {
				rowLabel(item)
			}
		case .sources:
			// Browse's Sources page, here, so Back comes back (2 Nov
			// 2026).
			NavigationLink {
				ManageSourcesView(isInBrowse: false)
			} label: {
				rowLabel(item)
			}
		default:
			rowLabel(item)
		}
	}

	private func rowLabel(_ item: Checkup.Item) -> some View {
		LabeledContent {
			Text(item.value ?? "")
		} label: {
			Label {
				Text(item.title)
			} icon: {
				CheckupMark(state: item.state)
			}
		}
	}

	@ViewBuilder
	private func card(_ item: Checkup.Item) -> some View {
		if item.kind == .setup {
			// A to-do with an Apple ID in use, whose apps only install
			// through it (#49).
			InstallSetupCard(buttonTitle: "Set Up Now", lead: item.state == .todo ? item.text : nil, start: setUp)
		} else {
			VStack(alignment: .leading, spacing: 12) {
				HStack(spacing: 11) {
					CheckupTile(item: item)
					Text(item.title)
						.font(.headline)
				}
				if let text = item.text {
					Text(text)
						.font(.subheadline)
						.fixedSize(horizontal: false, vertical: true)
				}
				if let hint = item.hint {
					HStack(alignment: .top, spacing: 10) {
						SourceIcon(url: SelfUpdate.shared.iconURL, tint: nil, size: 22)
						Text(hint)
							.font(.footnote)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
				}
				if !item.actions.isEmpty {
					// Side by side, or one under the other when their
					// titles don't fit, as Import Certificate and Sign In
					// with Apple ID don't (#49).
					ViewThatFits(in: .horizontal) {
						HStack(spacing: 10) { buttons(item) }
						VStack(spacing: 10) { buttons(item) }
					}
				}
			}
			.padding(.vertical, 8)
		}
	}

	private func buttons(_ item: Checkup.Item) -> some View {
		ForEach(Array(item.actions.enumerated()), id: \.offset) { index, action in
			button(action, filled: index == 0)
		}
	}

	@ViewBuilder
	private func button(_ action: Checkup.Action, filled: Bool) -> some View {
		if action == .signInToGitHub {
			GitHubSignInButton(isProminent: true)
		} else if filled {
			Button { perform(action) } label: {
				Text(title(of: action))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
		} else {
			Button { perform(action) } label: {
				Text(title(of: action))
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
		}
	}

	private func title(of action: Checkup.Action) -> String {
		switch action {
		case .importCertificate: "Import Certificate"
		case .signInWithAppleID: "Sign In with Apple ID"
		case .openDeveloperModeSettings: "Open Settings"
		case .confirmDeveloperMode: "It's On"
		case .addSource: "Add Source"
		case .refreshSources: "Try Again"
		case .signInToGitHub: "Sign In to GitHub"
		case .checkInstallServer: "Check Again"
		case .setUp: "Set Up Now"
		}
	}

	private func perform(_ action: Checkup.Action) {
		switch action {
		case .importCertificate:
			certificates.beginImport()
		case .signInWithAppleID:
			certificates.beginSignIn()
		case .openDeveloperModeSettings:
			Task { await RouteASetup.shared.openDeveloperModeSettings() }
		case .confirmDeveloperMode:
			developerModeConfirmed = true
		case .addSource:
			sources.beginAdd()
		case .refreshSources:
			Task { await sources.refreshAll() }
		case .signInToGitHub:
			// GitHubSignInButton signs in itself.
			break
		case .checkInstallServer:
			Task { await CheckupModel.shared.checkInstallServer(force: true) }
		case .setUp:
			setUp()
		}
	}
}

/// A row's mark: a check once it's fine, a spinner while it's checked, a
/// warning sign for what's worth knowing.
private struct CheckupMark: View {
	let state: Checkup.State

	var body: some View {
		switch state {
		case .checking:
			ProgressView()
		case .notice:
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
		default:
			Image(systemName: "checkmark.circle.fill")
				.symbolRenderingMode(.palette)
				.foregroundStyle(.white, .green)
		}
	}
}

/// A card's tile: what it's about, in red for a problem and orange for a
/// warning. Atelier's own updates show its icon.
private struct CheckupTile: View {
	let item: Checkup.Item

	var body: some View {
		if item.kind == .ownUpdates {
			SourceIcon(url: SelfUpdate.shared.iconURL, tint: nil, size: 36)
		} else {
			Image(systemName: symbol)
				.font(.system(size: 18, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 36, height: 36)
				.background(color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
				.accessibilityHidden(true)
		}
	}

	private var symbol: String {
		switch item.kind {
		case .certificate: item.state == .problem ? "xmark.seal.fill" : "checkmark.seal.fill"
		case .ownUpdates: "arrow.triangle.2.circlepath"
		case .developerMode: "hammer.fill"
		case .sources: item.state == .todo ? "square.grid.2x2.fill" : "exclamationmark.triangle.fill"
		case .gitHubSignIn: "lock.fill"
		case .installServer: "exclamationmark.icloud.fill"
		case .setup: "gearshape.fill"
		}
	}

	private var color: Color {
		switch item.state {
		case .problem: .red
		case .warning: .orange
		default:
			switch item.kind {
			case .certificate: .indigo
			case .developerMode: .gray
			default: .blue
			}
		}
	}
}
