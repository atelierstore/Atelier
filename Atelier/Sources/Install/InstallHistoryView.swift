import DownloadKit
import InstallKit
import SourceKit
import SwiftUI

/// Every install attempt, newest first (#11), with each one's log to share.
/// Failed ones can be tried again while what they installed is still there
/// (#17). Its search field finds an app's attempts (#124).
struct InstallHistoryView: View {
	@State private var attempts: [InstallAttempt] = []
	@State private var confirmingClear = false
	/// What's typed in the search field.
	@State private var query = ""
	@Environment(InstallModel.self) private var installer
	@Environment(CatalogModel.self) private var catalog
	@Environment(DownloadManager.self) private var downloads
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		let search = SearchText(query)
		// By the app's name and version, or its bundle ID.
		let shown = search.isEmpty ? attempts : attempts.filter { search.matches(name: $0.name, others: [$0.version, $0.bundleID]) }
		List(shown) { attempt in
			let retry = tryAgain(attempt)
			// A hidden link under the row, so Try Again takes its own taps.
			ZStack {
				NavigationLink {
					InstallAttemptView(attempt: attempt, tryAgain: retry)
				} label: {
					EmptyView()
				}
				.opacity(0)
				HStack(spacing: 8) {
					VStack(alignment: .leading, spacing: 2) {
						Text(attempt.title)
						Label(attempt.result.title, systemImage: attempt.result.symbol)
							.font(.footnote)
							.foregroundStyle(attempt.result.color)
						Text([attempt.startedAt.formatted(.dateTime), attempt.automatic == true ? "Installed automatically" : nil, retry == nil ? attempt.originGone : nil].compactMap { $0 }.joined(separator: " · "))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					if let retry {
						Button("Try Again", action: retry)
							.font(.subheadline.bold())
							.buttonStyle(.bordered)
							.buttonBorderShape(.capsule)
					}
				}
			}
		}
		.overlay {
			if attempts.isEmpty {
				ContentUnavailableView("No installs yet", systemImage: "clock")
			} else if shown.isEmpty {
				ContentUnavailableView.search(text: query)
			}
		}
		.navigationTitle("Install history")
		.searchable(text: $query, prompt: "Search Install History")
		.toolbar {
			// Not while searching, as it clears every attempt, not only
			// those shown.
			if !attempts.isEmpty, search.isEmpty {
				Button("Clear", role: .destructive) { confirmingClear = true }
					// On the button, so on iOS 26 the dialog's popover points at it.
					.confirmationDialog("Clear the install history?", isPresented: $confirmingClear, titleVisibility: .visible) {
						Button("Clear", role: .destructive) {
							(try? InstallHistory.standard())?.removeAll()
							attempts = []
						}
					}
			}
		}
		.onAppear { attempts = (try? InstallHistory.standard())?.attempts() ?? [] }
		// A new attempt goes into the history when it ends.
		.onChange(of: installer.isRunning) { _, running in
			if !running { attempts = (try? InstallHistory.standard())?.attempts() ?? [] }
		}
	}

	/// Tries a failed attempt again, nil when it can't be.
	private func tryAgain(_ attempt: InstallAttempt) -> (() -> Void)? {
		guard installer.canTryAgain(attempt, catalog: catalog.catalog, downloads: downloads, certificates: certificates, context: context) else { return nil }
		return {
			installer.tryAgain(attempt, catalog: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
		}
	}
}

private extension InstallAttempt {
	/// Why a failed attempt can't be tried again, when it says where it
	/// came from.
	var originGone: String? {
		guard result == .failed, let origin else { return nil }
		switch origin {
		case .source: return "no longer in its source"
		case .download: return "the download is gone"
		case .picked: return "the file is gone"
		case .signed, .signedAgain: return "no signed copy kept"
		}
	}

	/// The certificate it signed with. None for a kept signed copy, which
	/// Atelier installed as it was until it stopped keeping them (29 Oct
	/// 2026).
	var certificateName: String {
		if let certificate { return certificate }
		if case .signed? = origin { return "None (kept signed copy)" }
		return "None"
	}
}

private struct InstallAttemptView: View {
	let attempt: InstallAttempt
	/// Nil when it can't be tried again.
	let tryAgain: (() -> Void)?

	var body: some View {
		Form {
			Section {
				LabeledContent("Result", value: attempt.result.title)
				if let error = attempt.error {
					Text(error)
						.foregroundStyle(.red)
				}
				if let tryAgain {
					Button("Try Again", systemImage: "arrow.clockwise", action: tryAgain)
				}
				if let bundleID = attempt.bundleID {
					LabeledContent("Bundle ID", value: bundleID)
				}
				if let version = attempt.version {
					LabeledContent("Version", value: version)
				}
				LabeledContent("Certificate", value: attempt.certificateName)
				LabeledContent("Route", value: attempt.route?.displayName ?? "None")
				LabeledContent("Started", value: attempt.startedAt.formatted(date: .abbreviated, time: .standard))
				LabeledContent("Took", value: Duration.seconds(attempt.finishedAt.timeIntervalSince(attempt.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
			}
			if let limits = attempt.limits, !limits.isEmpty {
				LimitsSection(limits: limits)
			}
			if !attempt.log.isEmpty {
				Section("Install log") {
					Text(attempt.log.joined(separator: "\n"))
						.font(.caption.monospaced())
						.textSelection(.enabled)
					ShareLink(item: attempt.log.joined(separator: "\n")) {
						Label("Share log", systemImage: "square.and.arrow.up")
					}
				}
			}
		}
		.navigationTitle(attempt.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}

private extension InstallAttempt.Result {
	var title: String {
		switch self {
		case .confirmed: "Installed"
		case .unconfirmed: "Sent to iOS, not confirmed"
		case .failed: "Failed"
		case .cancelled: "Cancelled"
		}
	}

	var symbol: String {
		switch self {
		case .confirmed: "checkmark.circle"
		case .unconfirmed: "questionmark.circle"
		case .failed: "xmark.circle"
		case .cancelled: "minus.circle"
		}
	}

	var color: Color {
		switch self {
		case .confirmed: .green
		case .unconfirmed: .secondary
		case .failed: .red
		case .cancelled: .secondary
		}
	}
}
