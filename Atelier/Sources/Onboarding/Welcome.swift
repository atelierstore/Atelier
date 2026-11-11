import AtelierCore
import CertKit
import InstallKit
import SwiftData
import SwiftUI

/// The first launch's welcome, then Get Ready (#21): on the first launch
/// with no certificate, and from Test Actions › Show Welcome.
@MainActor
@Observable
final class Welcome {
	static let shared = Welcome()

	/// Set once the welcome was closed, or on a launch that already had a
	/// certificate, so it never comes up by itself again.
	static let shownKey = "welcomeShown"

	private(set) var isShowing: Bool

	private init() {
		let defaults = UserDefaults.standard
		if defaults.bool(forKey: Self.shownKey) {
			isShowing = false
		} else if !CertificatesModel.shared.certificates.isEmpty || !CertificatesModel.shared.appleIDs.isEmpty {
			// Updated from a build before it, with a certificate already.
			defaults.set(true, forKey: Self.shownKey)
			isShowing = false
		} else {
			isShowing = true
		}
	}

	/// Test Actions › Show Welcome.
	func show() {
		isShowing = true
	}

	/// Later or Start Browsing: for good.
	func close() {
		isShowing = false
		UserDefaults.standard.set(true, forKey: Self.shownKey)
	}

	/// For a link or file that needs the rest of Atelier, such as an
	/// install: it comes back on the next launch while there's still no
	/// certificate.
	func stepAside() {
		isShowing = false
	}
}

/// The welcome, and Get Ready pushed from it, over the whole app.
struct WelcomeFlow: View {
	@Environment(CertificatesModel.self) private var certificates
	@Environment(SourcesModel.self) private var sources
	@State private var gettingReady = false

	var body: some View {
		NavigationStack {
			WelcomePage { gettingReady = true }
				.navigationDestination(isPresented: $gettingReady) {
					GetReadyPage()
				}
		}
		// Import Certificate and Add Source open their sheets here, over the
		// welcome: RootView's own are under it.
		.sheet(isPresented: Binding(
			get: { certificates.draft != nil },
			set: { if !$0 { certificates.draft = nil } }
		)) {
			CertificateImportView()
				.environment(certificates)
		}
		.sheet(isPresented: Binding(
			get: { sources.draft != nil },
			set: { if !$0 { sources.cancelAdd() } }
		)) {
			SourceAddView()
				.environment(sources)
		}
		// Get Ready's Sign In with Apple ID (#49).
		.modifier(AppleIDSignInSheet(certificates: certificates))
	}
}

/// What Atelier is, in three lines, and Get Started.
private struct WelcomePage: View {
	let getStarted: () -> Void

	var body: some View {
		ScrollView {
			VStack(spacing: 0) {
				SourceIcon(url: SelfUpdate.shared.iconURL, tint: nil, size: 100)
					.shadow(color: .black.opacity(0.16), radius: 11, y: 6)
					.accessibilityHidden(true)
				Text("Welcome to Atelier")
					.font(.largeTitle.bold())
					.multilineTextAlignment(.center)
					.padding(.top, 24)
				Text("Install the apps you choose on your \(ThisDevice.name), signed with your own certificate.")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.top, 10)
				VStack(alignment: .leading, spacing: 24) {
					feature(
						"Your certificate stays here", symbol: "checkmark.seal.fill", tint: .green,
						text: "Atelier signs each app on this \(ThisDevice.name). Your certificate and its password never leave it."
					)
					feature(
						"Sources you choose", symbol: "square.grid.2x2.fill", tint: .blue,
						text: "Add AltStore sources and GitHub repos and browse their apps, or install IPA files you have."
					)
					feature(
						"Updates", symbol: "bell.fill", tint: .orange,
						text: "Atelier tells you when your apps have updates, and before your certificate runs out."
					)
				}
				.padding(.top, 40)
			}
			.padding(.horizontal, 32)
			.padding(.top, 48)
			.padding(.bottom, 24)
			.frame(maxWidth: 520)
			.frame(maxWidth: .infinity)
		}
		.safeAreaInset(edge: .bottom) {
			Button(action: getStarted) {
				Text("Get Started")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.buttonBorderShape(.capsule)
			.controlSize(.large)
			.padding(.horizontal, 24)
			.padding(.bottom, 8)
			.frame(maxWidth: 520)
		}
		.toolbar(.hidden, for: .navigationBar)
	}

	private func feature(_ title: String, symbol: String, tint: Color, text: String) -> some View {
		HStack(alignment: .top, spacing: 16) {
			Image(systemName: symbol)
				.font(.title)
				.foregroundStyle(tint)
				.frame(width: 40)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.headline)
				Text(text)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

/// What Atelier needs before the first install: a card with its button for
/// each thing left to do, a row with a check for each one done. Later
/// closes it until a certificate is in; then Start Browsing does.
private struct GetReadyPage: View {
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context
	@Query(sort: \SourceRecord.addedAt) private var records: [SourceRecord]
	@AppStorage(CheckupModel.developerModeConfirmedKey) private var developerModeConfirmed = false
	@State private var model = CheckupModel.shared
	@State private var routeA = RouteASetup.shared
	/// Set Up Now was tapped.
	@State private var settingUp = false

	var body: some View {
		let facts = model.facts(certificates: certificates, records: records, developerModeConfirmed: developerModeConfirmed, context: context)
		let checkup = Checkup(facts, for: .getReady)
		// An Apple ID in use counts (#49).
		let ready = certificates.defaultCertificate != nil || certificates.defaultAppleID != nil
		Form {
			Section {
			} header: {
				Text("Atelier needs your certificate to install apps, and a source to find them.")
					.font(.subheadline)
					.textCase(nil)
			}
			CheckupSections(checkup: checkup, place: .getReady) { settingUp = true }
		}
		.navigationTitle("Get Ready")
		// Large, as in the mockup, after the welcome's page without a bar.
		.navigationBarTitleDisplayMode(.large)
		.navigationDestination(isPresented: $settingUp) {
			InstallSetupView()
		}
		.toolbar {
			// In Later's place once a certificate is in, rather than a big
			// button over the page (2 Nov 2026).
			if ready {
				ToolbarItem(placement: .confirmationAction) {
					Button("Start Browsing") {
						InstallModel.shared.browseRequested = true
						Welcome.shared.close()
					}
				}
			} else {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Later") { Welcome.shared.close() }
				}
			}
		}
		// Only said if it fails.
		.task { await model.checkInstallServer() }
		// The setup's row says whether it can install now, once it's done.
		.task(id: routeA.isSetUp) {
			if routeA.isSetUp { await routeA.refresh() }
		}
	}
}
