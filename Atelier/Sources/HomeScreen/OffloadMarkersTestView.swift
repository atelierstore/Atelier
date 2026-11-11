import AtelierCore
import CertKit
import InstallKit
import SourceKit
import SwiftData
import SwiftUI

/// Settings › Test Actions › Offload Markers Test (9 Nov 2026): one
/// row per step, each with its result under it, what tapping a marker or a
/// stand-in opened, where each one is, and the log. Their links open it too.
struct OffloadMarkersTestView: View {
	private var test: OffloadMarkersTest { .shared }
	@Query private var installs: [InstallRecord]
	@Environment(CertificatesModel.self) private var certificates
	@Environment(CatalogModel.self) private var catalog
	@Environment(\.scenePhase) private var scenePhase

	var body: some View {
		Form {
			Section {
				step(.make, "Make Markers", hint: "Hands iOS one profile with \(OffloadMarkersTest.count) markers, a grey cloud named Offloaded, that any app can borrow. Approve it in Settings › General › VPN & Device Management.")
				step(.hide, "Hide Them in the App Library", hint: "Writes your Home Screen without them, then reads it back to see where iOS put them.")
				step(.folder, "Put Them in a Folder Instead", hint: "In a folder named \(OffloadMarkersTest.folderName) on the last page, if the App Library doesn’t keep them.")
				step(.fill, "Fill Held Spots", hint: "Puts a marker in the spot Atelier keeps for each offloaded free Apple ID app, as Offload would.")
				step(.name, "Name It After the App", hint: "Tries giving a marker in an app’s spot that app’s name, through the same layout write. iOS will probably keep Offloaded.")
				step(.putAway, "Put Them Away", hint: "Back out of sight, as Reinstall would before putting the app back.")
				step(.remove, "Remove Markers", hint: "Asks iOS to remove the profile, and the markers with it.")
			} header: {
				Text("Free Apple ID Apps: Markers")
			} footer: {
				Text("Put Them Away before reinstalling an app whose spot has a marker, as Reinstall doesn’t move markers yet. An Offload or Reinstall meanwhile may bring hidden markers back to your last page.")
			}

			Section("Other Apps: Stand-ins") {
				step(.makeStandIns, "Make Stand-ins", hint: "Installs a small app for each other offloaded app, with its name and icon greyed, signed as it was, in the spot Atelier keeps for it.")
				step(.removeStandIns, "Remove Stand-ins", hint: "Deletes them, as Reinstall would before putting the app back.")
			}

			Section {
				if let opened = test.state.opened {
					VStack(alignment: .leading, spacing: 2) {
						Text(opened)
						if let link = test.state.openedLink {
							Text(link)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				} else {
					Text("No marker has opened Atelier yet.")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("When You Tap One")
			} footer: {
				Text("Tap one on your Home Screen. Atelier opens here, says which, and installs nothing.")
			}

			if !test.state.ids.isEmpty || !test.state.standIns.isEmpty {
				Section("Where They Are") {
					ForEach(test.state.ids.keys.sorted(), id: \.self) { number in
						LabeledContent("Marker \(number)", value: test.state.places[number] ?? "Unknown")
					}
					ForEach(test.standInRows) { row in
						LabeledContent("\(row.name)’s stand-in", value: row.place)
					}
				}
			}

			Section {
				if test.state.log.isEmpty {
					Text("Each step logs what iOS and SpringBoard said.")
						.foregroundStyle(.secondary)
				} else {
					Text(test.logText)
						.font(.caption.monospaced())
						.textSelection(.enabled)
				}
				ShareLink(item: test.logText) {
					Label("Share Log", systemImage: "square.and.arrow.up")
				}
				.disabled(test.state.log.isEmpty)
				Button("Clear Log", role: .destructive) { test.clearLog() }
					.disabled(test.state.log.isEmpty || test.running != nil)
			} header: {
				Text("Log")
			} footer: {
				Text("The log has bundle IDs, app names and the layout’s web clip identifiers, and no Apple ID.")
			}
		}
		.navigationTitle("Offload Markers Test")
		.navigationBarTitleDisplayMode(.inline)
		// Once the profile is approved in Settings, its markers show up.
		.task { await test.refresh() }
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			Task { await test.refresh() }
		}
	}

	/// A step's row: its title, what it does, and its last result.
	private func step(_ step: OffloadMarkersTest.Step, _ title: String, hint: String) -> some View {
		Button {
			test.run(step, apps: apps)
		} label: {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
					Text(hint)
						.font(.footnote)
						.foregroundStyle(.secondary)
					if let result = test.result(step) {
						Text(result)
							.font(.footnote)
							.foregroundStyle(.primary)
					}
				}
				if test.running == step {
					Spacer()
					ProgressView()
				}
			}
		}
		.disabled(test.running != nil && test.running != step)
	}

	/// The apps Atelier installed, which a free Apple ID signed, what signed
	/// each, and its icon.
	private var apps: [String: OffloadMarkersTest.App] {
		var apps: [String: OffloadMarkersTest.App] = [:]
		for install in installs {
			apps[install.bundleID] = OffloadMarkersTest.App(
				name: install.name,
				isFreeAppleID: certificates.appleID(install.certificateID)?.isFree == true,
				certificateID: install.certificateID,
				iconURL: InstallModel.listing(of: install, in: catalog.catalog)?.app.iconURL
			)
		}
		return apps
	}
}
