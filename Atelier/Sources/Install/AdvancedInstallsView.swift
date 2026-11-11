import AppleIDKit
import InstallKit
import SwiftUI

/// Settings › Installs › Advanced (the mockup of 29 Oct 2026): a custom
/// manifest endpoint for the iOS alert route (#10), and a pairing file made
/// on a computer for route A (#9). The endpoint field stays out of sight
/// until Use custom manifest is on; turning it off goes back to Atelier's.
/// The install check that confirms installs with the alert is always on and
/// has no setting, so it isn't described here (docs/route-b.md explains it).
///
/// A custom anisette server for signing in with an Apple ID (#49) follows
/// the custom manifest's pattern. Like Sign In with Apple ID, it showed
/// only with Test Actions on until Atelier installed with an Apple ID.
///
/// Each switch is on while its address is set. Until 3 Nov 2026 each was
/// state of its own, read when this screen was made, which is when Settings
/// draws its row rather than when the screen opens: after setting a server
/// and coming back, the switch showed off while the server was still in use.
struct AdvancedInstallsView: View {
	@AppStorage(InstallModel.endpointKey) private var manifestEndpoint = ""
	/// Use custom manifest was turned on, with no address typed yet.
	@State private var addingManifest = false
	@AppStorage(CustomAnisetteServer.defaultsKey) private var anisetteServer = ""
	/// Use custom anisette server was turned on, with no address typed yet.
	@State private var addingAnisette = false
	@State private var setup = RouteASetup.shared
	@State private var pairing = PhonePairing.shared
	/// A pairing file was imported while this screen showed.
	@State private var imported = false

	private var endpointProblem: String? {
		if case .failure(let problem) = ManifestEndpoint.resolve(manifestEndpoint) { return problem.description }
		return nil
	}

	private var anisetteProblem: String? {
		if case .failure(let problem) = CustomAnisetteServer.resolve(anisetteServer) { return problem.description }
		return nil
	}

	private var customManifest: Bool { addingManifest || !manifestEndpoint.isEmpty }
	private var customAnisette: Bool { addingAnisette || !anisetteServer.isEmpty }

	/// Off empties the address, which goes back to Atelier's own.
	private func toggle(adding: Binding<Bool>, address: Binding<String>) -> Binding<Bool> {
		Binding(
			get: { adding.wrappedValue || !address.wrappedValue.isEmpty },
			set: { on in
				adding.wrappedValue = on
				if !on { address.wrappedValue = "" }
			}
		)
	}

	var body: some View {
		Form {
			Section {
				Toggle("Use custom manifest", isOn: toggle(adding: $addingManifest, address: $manifestEndpoint))
				if customManifest {
					TextField("https://", text: $manifestEndpoint)
						.keyboardType(.URL)
						.textContentType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					if let endpointProblem {
						Text(endpointProblem)
							.foregroundStyle(.red)
					}
				}
			} header: {
				Text("Custom manifest")
			} footer: {
				Text("Before an install you approve in iOS's alert, iOS reads a small manifest about the app. Use your own deployment of infra/manifest-worker instead of Atelier's: it receives each app's name, bundle ID and version, never the app itself or your certificate, and the alert shows its host.")
			}

			Section {
				Button {
					setup.pickPairingFile()
				} label: {
					HStack {
						Text("Import Pairing File…")
						Spacer()
						if imported {
							Text("Imported")
								.foregroundStyle(.secondary)
						}
					}
				}
				.disabled(pairing.isActive)
				if let problem = setup.importProblem {
					Text(problem)
						.foregroundStyle(.red)
				}
			} header: {
				Text("Custom pairing")
			} footer: {
				Text("Already paired this \(ThisDevice.name) with a computer? Import that pairing file instead of pairing in the setup, then finish its other steps. It replaces Atelier's pairing, if there is one.")
			}

			Section {
				Toggle("Use custom anisette server", isOn: toggle(adding: $addingAnisette, address: $anisetteServer))
				if customAnisette {
					TextField("https://ani.example.com", text: $anisetteServer)
						.keyboardType(.URL)
						.textContentType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					if let anisetteProblem {
						Text(anisetteProblem)
							.foregroundStyle(.red)
					}
				}
			} header: {
				Text("Custom anisette server")
			} footer: {
				Text("Signing in with an Apple ID needs an anisette server. Atelier tries public ones from its list, one at a time. Use your own instead, such as one on your Mac: it never sees your password.")
			}
		}
		.navigationTitle("Advanced")
		// A file the picker saved; one that failed leaves the date as it was.
		.onChange(of: setup.pairingSavedAt) { _, saved in
			imported = saved != nil && setup.importProblem == nil
		}
	}
}
