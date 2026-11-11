import DownloadKit
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI
import UIKit

/// The Library's list of downloads (#15): progress, pause, resume and retry,
/// and Install for finished ones, which signs and installs the IPA and then
/// deletes the download once the install is confirmed. A finished one can be
/// exported as it was downloaded, unsigned. Swiping a download deletes it.
struct DownloadsSection: View {
	@Bindable var installer: InstallModel
	/// Downloads shown elsewhere: Update All's, in their apps' rows (#18).
	var hiding: Set<UUID> = []
	/// The Library's search (#124): only the downloads of apps it finds.
	var search = SearchText("")
	@Environment(DownloadManager.self) private var downloads
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		let shown = Self.shown(downloads.downloads, installer: installer, hiding: hiding, search: search)
		if !shown.isEmpty {
			Section {
				ForEach(shown) { download in
					// Its Install button shows its install, so it's only kept
					// from being deleted while that waits or runs.
					let installing = installer.isQueued(download) && download.status == .finished
					DownloadRow(download: download) {
						installer.install(download, from: downloads, certificates: certificates, into: context)
					}
					.swipeActions {
						if !installing {
							Button(download.status == .downloading ? "Cancel" : "Delete", role: .destructive) {
								downloads.remove(download.id)
							}
						}
					}
					.swipeActions(edge: .leading) {
						if download.status == .finished {
							exportButton(download)
								.tint(.blue)
						}
					}
					.contextMenu {
						if download.status == .finished {
							exportButton(download)
						}
						if !installing {
							Button(download.status == .downloading ? "Cancel Download" : "Delete", systemImage: "trash", role: .destructive) {
								downloads.remove(download.id)
							}
						}
					}
				}
			} header: {
				Text("Downloads")
			} footer: {
				Text("Downloads keep going when you leave Atelier. Installing one signs it with your certificate, then deletes the download once the install is confirmed. Swipe right on a finished download to export it unsigned.")
			}
		}
	}

	private func exportButton(_ download: Download) -> some View {
		Button("Export IPA", systemImage: "square.and.arrow.up") {
			IPAExport.present(download, from: downloads)
		}
	}

	/// The downloads the section lists, of those `search` finds by app name
	/// or bundle ID. An install that couldn't be confirmed keeps its
	/// download, shown by the install bar instead of here.
	@MainActor
	static func shown(_ downloads: [Download], installer: InstallModel, hiding: Set<UUID>, search: SearchText) -> [Download] {
		downloads.filter { download in
			!installer.isHidden(download) && !hiding.contains(download.id)
				&& (search.isEmpty || search.matches(name: download.name, others: [download.bundleID]))
		}
	}
}

/// Shares a finished download's IPA as it was downloaded, before signing,
/// in the share sheet: Save to Files, AirDrop or another app.
@MainActor
enum IPAExport {
	static func present(_ download: Download, from downloads: DownloadManager) {
		guard let file = downloads.fileURL(for: download.id),
		      let presenter = DocumentPicker.topViewController(),
		      let named = try? namedCopy(of: file, for: download) else { return }
		let sheet = UIActivityViewController(activityItems: [named], applicationActivities: nil)
		sheet.completionWithItemsHandler = { _, _, _, _ in
			try? FileManager.default.removeItem(at: named.deletingLastPathComponent())
		}
		// On iPad the sheet is a popover, which needs somewhere to point.
		sheet.popoverPresentationController?.sourceView = presenter.view
		sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
		sheet.popoverPresentationController?.permittedArrowDirections = []
		presenter.present(sheet, animated: true)
	}

	/// The download under the app's name and version, rather than its ID: a
	/// hard link where possible, so a large IPA isn't copied.
	private static func namedCopy(of file: URL, for download: Download) throws -> URL {
		let folder = FileManager.default.temporaryDirectory.appending(path: "Export/\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let base = [download.name, download.displayVersion].filter { !$0.isEmpty }.joined(separator: " ")
		let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
		let destination = folder.appending(path: "\(safe.isEmpty ? "App" : safe).ipa")
		do {
			try FileManager.default.linkItem(at: file, to: destination)
		} catch {
			try FileManager.default.copyItem(at: file, to: destination)
		}
		return destination
	}
}

/// One download: the app, its version and where it's at.
private struct DownloadRow: View {
	let download: Download
	let install: () -> Void
	@Environment(DownloadManager.self) private var downloads
	@Environment(InstallModel.self) private var installer

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			SourceIcon(url: download.iconURL, tint: nil, size: 44)
			VStack(alignment: .leading, spacing: 4) {
				HStack(alignment: .firstTextBaseline) {
					Text(download.name)
						.font(.headline)
						.lineLimit(1)
					Spacer(minLength: 4)
					Text(download.displayVersion)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				DownloadStatusView(download: download, install: install, installStatus: installer.status(of: download))
			}
		}
		.padding(.vertical, 2)
	}
}

/// Where a download is at, with what can be done about it.
struct DownloadStatusView: View {
	let download: Download
	/// Nil where installing isn't offered.
	var install: (() -> Void)?
	/// Its install, waiting or running, which the Install button shows (#78).
	var installStatus: InstallModel.AppStatus?
	@Environment(DownloadManager.self) private var downloads

	var body: some View {
		switch download.status {
		case .downloading:
			let progress = downloads.progress[download.id]
			VStack(alignment: .leading, spacing: 4) {
				if let fraction = progress?.fraction {
					ProgressView(value: fraction)
				} else {
					ProgressView(value: 0).opacity(0.4)
				}
				HStack {
					Text(downloads.notes[download.id] ?? Self.describe(progress))
						.font(.caption)
						.foregroundStyle(.secondary)
					Spacer(minLength: 4)
					Button("Pause", systemImage: "pause.fill") { downloads.pause(download.id) }
						.labelStyle(.iconOnly)
				}
			}
			.buttonStyle(.borderless)
		case .paused:
			HStack {
				Text("Paused")
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer(minLength: 4)
				Button("Resume", systemImage: "play.fill") { downloads.resume(download.id) }
			}
			.buttonStyle(.borderless)
		case .failed(let message):
			VStack(alignment: .leading, spacing: 4) {
				if GitHubAccess.downloadNeedsSignIn(url: download.url, failure: message) {
					Label("GitHub can't find this file. If it's in a private repo, sign in to download it.", systemImage: "exclamationmark.triangle")
						.font(.caption)
						.foregroundStyle(.red)
					// Then it downloads through the account (#134).
					GitHubSignInButton { downloads.resume(download.id) }
						.font(.subheadline)
				} else {
					Label(message, systemImage: "exclamationmark.triangle")
						.font(.caption)
						.foregroundStyle(.red)
					Button("Try again", systemImage: "arrow.clockwise") { downloads.resume(download.id) }
						.font(.subheadline)
				}
			}
			.buttonStyle(.borderless)
		case .finished:
			HStack {
				Label(download.fileSize.map { "Downloaded, \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Downloaded", systemImage: "checkmark.circle")
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer(minLength: 4)
				if let install {
					InstallStatusButton(title: "Install", status: installStatus, perform: install)
				}
			}
		}
	}

	private static func describe(_ progress: DownloadProgress?) -> String {
		guard let progress, progress.received > 0 else { return "Starting…" }
		let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
		guard let expected = progress.expected else { return received }
		return "\(received) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
	}
}

/// Downloads one version of an app from one source, for app details: a
/// Download button, then the download's progress, then Install, which signs
/// and installs it like the Install button (#16, #78).
struct DownloadVersionButton: View {
	let app: SourceApp
	let version: AppVersion
	let sourceURL: URL?
	@Environment(DownloadManager.self) private var downloads
	@Environment(InstallModel.self) private var installer
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	var body: some View {
		if let download = downloads.download(of: version, sourceURL: sourceURL) {
			let status = installer.status(of: app, version: version, sourceURL: sourceURL) ?? installer.status(of: download)
			DownloadStatusView(download: download, install: download.status == .finished ? install : nil, installStatus: status)
				// Its install will use it.
				.disabled(download.status != .finished && installer.isQueued(download))
		} else {
			Button {
				downloads.download(app, version: version, sourceURL: sourceURL)
			} label: {
				Label("Download \(version.displayVersion)", systemImage: "arrow.down.circle")
			}
			.buttonStyle(.borderless)
		}
	}

	private func install() {
		installer.install(app, version: version, sourceURL: sourceURL, downloads: downloads, certificates: certificates, into: context)
	}
}

/// Installs one version of an app from one source, for Version History
/// (#78), with app details' Install button: no Download step, as installing
/// downloads it, and the install bar shows the steps. The version that's
/// installed from this source says so instead.
struct InstallVersionButton: View {
	let app: SourceApp
	let version: AppVersion
	let sourceURL: URL
	@Query private var installs: [InstallRecord]

	var body: some View {
		if isInstalled {
			Label("Installed", systemImage: "checkmark.circle")
				.labelStyle(InlineLabelStyle())
				.font(.caption.weight(.semibold))
				.foregroundStyle(.green)
		} else {
			InstallButton(app: app, action: .install(version), sourceURL: sourceURL, versionOnly: true)
		}
	}

	/// This version is the app itself, as installed from this source and
	/// still on this device.
	private var isInstalled: Bool {
		installs.contains { install in
			guard install.target == .original, install.sourceBundleID == app.bundleID, install.sourceURL == sourceURL,
			      InstallModel.presence(of: install) != .deleted else { return false }
			let release = InstalledRelease(version: install.version, buildVersion: install.buildVersion, installedAt: install.installedAt)
			return UpdateCheck.installedEntry(release, in: app) == version
		}
	}
}
