import GitHubKit
import AtelierCore
import SourceKit
import SwiftUI

/// The add sheet: an AltStore source's address (typed, pasted or scanned) or
/// a GitHub repo. What it names loads under the field, with who runs it, so
/// the user decides with that in front of them before tapping Add Source
/// (#83). Links from the web open the sheet with their source loading, on
/// its own tab only, as what kind of source it is is known (3 Nov), and
/// links to an app or an install say first why the source is needed (#93).
struct SourceAddView: View {
	@Environment(SourcesModel.self) private var model

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				if let link = model.draft?.link {
					if link != .source {
						LinkNote(link: link, app: model.draft?.linkedApp)
							.padding(.horizontal)
							.padding(.top, 8)
					}
				} else {
					Picker("Kind", selection: Binding(
						get: { model.draft?.tab ?? .altStore },
						set: { model.select($0) }
					)) {
						Text("AltStore Source").tag(SourcesModel.Draft.Tab.altStore)
						Text("GitHub").tag(SourcesModel.Draft.Tab.gitHub)
					}
					.pickerStyle(.segmented)
					.padding(.horizontal)
					.padding(.vertical, 8)
				}
				switch model.draft?.tab ?? .altStore {
				case .altStore: AltStoreSourceForm()
				case .gitHub: GitHubRepoPicker()
				}
			}
			.background(Color(.systemGroupedBackground))
			.navigationTitle("Add Source")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { model.cancelAdd() }
				}
			}
		}
	}
}

/// Why the add sheet shows a source a link to an app or an install names,
/// which the user doesn't have (#93): first, so adding it isn't a surprise
/// (3 Nov). The app as the source lists it, once it loads.
private struct LinkNote: View {
	let link: SourcesModel.LinkPurpose
	let app: SourceApp?

	var body: some View {
		HStack(spacing: 14) {
			if let app {
				SourceIcon(url: app.iconURL, tint: app.tintColor, size: 52)
			} else {
				Image(systemName: "app.dashed")
					.font(.title)
					.foregroundStyle(.secondary)
					.frame(width: 52, height: 52)
			}
			VStack(alignment: .leading, spacing: 3) {
				Text(app.map { "\($0.name) needs this source" } ?? "The app needs this source")
					.font(.headline)
				Text(message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(14)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.tint, lineWidth: 2))
		.accessibilityElement(children: .combine)
	}

	private var message: String {
		let name = app?.name
		switch link {
		case .install:
			if let name {
				return "The link installs \(name), which comes from a source you haven't added. Add it, and \(name) installs, with its updates from there."
			}
			return "The link installs an app and names this source, which you haven't added. Add it, and Atelier asks before installing the app."
		case .app, .source:
			if let name {
				return "The link opens \(name), which comes from a source you haven't added. Add it, and \(name) opens."
			}
			return "The link opens an app from a source you haven't added. Add it, and the app opens."
		}
	}
}

/// The AltStore Source tab: the address, with Paste and Scan QR Code in the
/// field, and the source under it once it loads (#83).
private struct AltStoreSourceForm: View {
	@Environment(SourcesModel.self) private var model
	@State private var isScanning = false
	@FocusState private var isFocused: Bool

	var body: some View {
		let draft = model.draft
		let preview = draft?.preview(on: .altStore)
		let isChecking = draft?.isChecking ?? false
		VStack(spacing: 0) {
			Form {
				Section {
					HStack(spacing: 8) {
						TextField("example.com/apps.json", text: Binding(
							get: { model.draft?.input ?? "" },
							set: { model.setInput($0) }
						))
						.keyboardType(.URL)
						.textContentType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.submitLabel(.go)
						.onSubmit { model.check() }
						.focused($isFocused)
						.disabled(isChecking)
						if isChecking {
							ProgressView()
						} else if (draft?.input ?? "").isEmpty {
							// PasteButton reads the clipboard without iOS asking for permission.
							PasteButton(payloadType: String.self) { strings in
								guard let text = strings.first else { return }
								Task { @MainActor in
									isFocused = false
									model.add(link: text)
								}
							}
							.labelStyle(.iconOnly)
							.buttonBorderShape(.circle)
						} else {
							ClearButton { model.setInput("") }
						}
						Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
							isFocused = false
							isScanning = true
						}
						.labelStyle(.iconOnly)
						.buttonStyle(.borderedProminent)
						.buttonBorderShape(.circle)
						.disabled(isChecking)
					}
				} header: {
					Text("Source URL")
				} footer: {
					if preview == nil {
						Text("AltStore, SideStore and Feather sources work.")
					}
				}

				if let error = draft?.error {
					Section {
						Label(error, systemImage: "xmark.octagon.fill")
							.foregroundStyle(.red)
					}
				}

				if let preview {
					SourceToAdd(preview: preview)
				}
			}
			.listSectionSpacing(preview == nil ? .default : .compact)
			if preview != nil {
				AddSourceButton()
			}
		}
		.onAppear {
			// The keyboard comes up with the tab, unless a source is loading.
			if let draft = model.draft, draft.input.isEmpty, !draft.isChecking {
				isFocused = true
			}
		}
		.sheet(isPresented: $isScanning) {
			QRScannerSheet { code in
				isScanning = false
				model.add(link: code)
			}
		}
	}
}

/// The × at the end of a field, which empties it.
struct ClearButton: View {
	let action: () -> Void

	var body: some View {
		Button("Clear", systemImage: "xmark.circle.fill", action: action)
			.labelStyle(.iconOnly)
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
	}
}

/// What a source being added shows under the field (#83): its card, some of
/// its apps, its pre-release switch (#104) with a GitHub repo's account, and
/// who the user trusts with what they install from it.
struct SourceToAdd: View {
	let preview: SourceLibrary.Preview
	@Environment(SourcesModel.self) private var model

	var body: some View {
		let includes = model.draft?.includesPrereleases ?? false
		// As it will be listed: its betas only with the switch on.
		let source = preview.source.listing(prereleases: includes)
		Section {
			SourceCard(preview: preview, listing: source, includesPrereleases: includes)
				.listRowInsets(EdgeInsets())
				.listRowBackground(Color.clear)
		}

		if showsApps(of: source) {
			Section("Includes") {
				IncludedApps(source: source)
					.listRowInsets(EdgeInsets())
					.listRowBackground(Color.clear)
			}
		}

		Section {
			// The account that could see a repo, when there's more than one (#74).
			if let repo = preview.gitHubRepo, GitHubAccess.accounts.all.count > 1, let account = GitHubAccess.accounts.account(for: repo) {
				LabeledContent("GitHub account", value: account.handle)
			}
			Toggle("Include Pre-releases", isOn: Binding(
				get: { model.draft?.includesPrereleases ?? false },
				set: { model.setIncludesPrereleases($0) }
			))
		} footer: {
			Text(footer(includes: includes))
		}

		Section {
			Label {
				Text(warning)
			} icon: {
				Image(systemName: "exclamationmark.shield.fill")
					.foregroundStyle(.orange)
			}
			.font(.subheadline)
		}
	}

	/// Whether to show some of its apps: not for a repo with one app, which
	/// the card already shows.
	private func showsApps(of source: Source) -> Bool {
		preview.gitHubRepo == nil ? !source.apps.isEmpty : source.apps.count > 1
	}

	/// What the switch does, in the terms of the source's kind: a repo marks
	/// its pre-releases on GitHub or in their tags, an AltStore source only
	/// its beta apps.
	private func footer(includes: Bool) -> String {
		if includes {
			return "On: pre-releases are listed as betas. You can change this later from the source's menu."
		}
		if preview.gitHubRepo != nil {
			return "Off: only full releases are listed. A release whose tag says alpha, beta or rc counts as a pre-release. You can change this later from the source's menu."
		}
		return "Off: only full releases are listed. An app the source marks as a beta counts as a pre-release. You can change this later from the source's menu."
	}

	/// Whoever decides what the user installs from it: the site's owner, or
	/// for a GitHub repo, whoever can publish its releases.
	private var warning: String {
		if let repo = preview.gitHubRepo {
			let name = preview.gitHubSummary?.fullName ?? repo.description
			return "Whoever can publish releases in \(name) decides what you install from it, including updates. Only add repos from developers you trust."
		}
		return "Whoever runs \(preview.domain) decides what you install from it, including updates. Only add sources from developers you trust."
	}
}

/// A few of a source's apps, featured ones first, then how many more there
/// are (#83).
private struct IncludedApps: View {
	let source: Source
	private let places = 5

	/// Featured apps first, then the rest in the source's order.
	private var apps: [SourceApp] {
		var seen = Set<String>()
		return (source.listedFeaturedApps + source.apps).filter { seen.insert($0.id).inserted }
	}

	var body: some View {
		let apps = self.apps
		// The last place says how many more there are, unless one app fits there.
		let shown = apps.count <= places ? apps : Array(apps.prefix(places - 1))
		let more = apps.count - shown.count
		HStack(alignment: .top, spacing: 4) {
			ForEach(shown) { app in
				VStack(spacing: 6) {
					SourceIcon(url: app.iconURL, tint: app.tintColor, size: 56)
					Text(app.name)
						.font(.caption)
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity)
			}
			if more > 0 {
				VStack(spacing: 6) {
					Text("+\(more)")
						.font(.headline)
						.foregroundStyle(.secondary)
						.frame(width: 56, height: 56)
						.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 56 * 0.22, style: .continuous))
					Text("more")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity)
				.accessibilityElement(children: .combine)
			}
			// Empty places keep the apps at their width, from the left.
			ForEach(0..<(places - shown.count - (more > 0 ? 1 : 0)), id: \.self) { _ in
				Color.clear
					.frame(maxWidth: .infinity, maxHeight: 0)
			}
		}
	}
}

/// Add Source, at the bottom of the sheet under a source being added (#83),
/// saying what follows for a link to an app or an install (#93).
struct AddSourceButton: View {
	@Environment(SourcesModel.self) private var model

	var body: some View {
		Button {
			model.confirmAdd()
		} label: {
			Text(title)
				.bold()
				.lineLimit(1)
				.minimumScaleFactor(0.8)
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.borderedProminent)
		.buttonBorderShape(.capsule)
		.controlSize(.large)
		.padding(.horizontal)
		.padding(.vertical, 8)
	}

	private var title: String {
		guard let app = model.draft?.linkedApp else { return "Add Source" }
		switch model.draft?.link {
		case .install?: return "Add Source and Install \(app.name)"
		default: return "Add Source and Open \(app.name)"
		}
	}
}
