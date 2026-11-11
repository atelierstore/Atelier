import DownloadKit
import Foundation
import AtelierCore
import SourceKit
import UIKit

/// The download behind a one-tap install from a source (#16), through the
/// download manager (#15), or a download of the same version that's
/// already running or finished, so it also shows in the Library's
/// Downloads.
///
/// It starts as the install is queued, while Atelier is in front, rather
/// than once the install's checks pass: iOS puts off a background
/// session's download that an app starts while it's in the background
/// (Apple's `isDiscretionary` documentation). Reinstall's checks ask iOS
/// about the app through Direct installs first, which takes a few seconds,
/// and when the maintainer went to the Home Screen right after tapping Reinstall, its
/// download didn't start at all, the bar staying on "downloading, 0 of …"
/// (build 567, 6 Nov 2026).
@MainActor
final class SourceDownload: PipelineDownload {
	let app: SourceApp
	let version: AppVersion
	let sourceURL: URL?
	let downloads: DownloadManager
	/// The download, once started or found.
	private(set) var downloadID: UUID?
	/// Whether this install started the download, so cancelling deletes it.
	private var startedHere = false
	/// Whether Atelier was in front when this install started its download,
	/// for the install's log; nil until it starts one.
	private var startedInFront: Bool?
	/// Whether what comes after the download needs Atelier in front: iOS's
	/// install alert does, a direct install doesn't (#72). Set once the
	/// route is picked.
	var needsFront: @MainActor () -> Bool = { true }

	init(app: SourceApp, version: AppVersion, sourceURL: URL?, downloads: DownloadManager) {
		self.app = app
		self.version = version
		self.sourceURL = sourceURL
		self.downloads = downloads
	}

	var expectedSize: Int64? { version.size }

	var isFinished: Bool {
		downloads.download(of: version, sourceURL: sourceURL)?.status == .finished
	}

	/// Starts the download, or picks up the one already running or
	/// finished, and resumes it if it was paused or failed: as the install
	/// is queued while Atelier is in front, and again once its checks pass.
	@discardableResult
	func start() -> UUID {
		if downloads.download(of: version, sourceURL: sourceURL) == nil {
			startedHere = true
			startedInFront = UIApplication.shared.applicationState == .active
		}
		let id = downloads.download(app, version: version, sourceURL: sourceURL).id
		downloadID = id
		// One started ahead only used Wi-Fi (#19); taken over by an install,
		// it may use mobile data, and is started again for that now, while
		// Atelier may still be in front.
		if NetworkPath.shared.isWiFiNow == false { downloads.allowMobileData(id) }
		return id
	}

	/// The install log's line on how this install started its download,
	/// once: none when it picked up one already there.
	func takeStartNote() -> String? {
		guard let startedInFront else { return nil }
		self.startedInFront = nil
		return startedInFront
			? "download: started with Atelier in front"
			: "download: started with Atelier in the background, which iOS can put off until later"
	}

	func file(progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
		let id = start()
		// The manager has no per-download callback, so its state is read a
		// few times a second; the sleep also ends the wait on cancel.
		while true {
			guard let download = downloads.download(id: id) else {
				throw InstallProblem("The download of \(app.name) was deleted.", fix: .tryAgain)
			}
			switch download.status {
			case .finished:
				guard let file = downloads.fileURL(for: id) else {
					throw InstallProblem("The download of \(app.name) is gone.", fix: .tryAgain)
				}
				progress(1)
				// Signing and the iOS install alert wait for Atelier to be in
				// front: the alert can't show from the background. A direct
				// install carries on (#72).
				if !needsFront() || UIApplication.shared.applicationState == .active { return file }
			case .failed(let why):
				// A private repo's file, as Atelier's own while its repo is
				// private: signing in tries again (#134).
				if GitHubAccess.downloadNeedsSignIn(url: download.url, failure: why) {
					throw InstallProblem(
						"Couldn't download \(app.name) without a GitHub account.",
						detail: "GitHub can't find it. If it's in a private repo, sign in to download it.",
						fix: .signInToGitHub
					)
				}
				throw InstallProblem("Couldn't download \(app.name): \(why)", fix: .tryAgain)
			case .downloading, .paused:
				// One started ahead only used Wi-Fi (#19); waited on, it may
				// now use mobile data.
				if NetworkPath.shared.isWiFiNow == false { downloads.allowMobileData(id) }
				progress(downloads.progress[id]?.fraction)
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	func discard() {
		guard startedHere, let downloadID else { return }
		downloads.remove(downloadID)
	}
}
