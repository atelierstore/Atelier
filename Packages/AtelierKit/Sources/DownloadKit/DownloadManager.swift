import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InstallKit
import Observation
import SourceKit

/// Downloads IPAs through a background `URLSession`, so a download keeps
/// going while Atelier is in the background or suspended, waits out network
/// loss, and survives Atelier being killed by iOS (#15).
///
/// - Pausing keeps the session's resume data on disk; resuming continues
///   from it when the server supports ranges, and starts again otherwise.
/// - A download the connection drops is retried with its resume data
///   (`RetryPolicy`), then left for the user to retry.
/// - A finished download is checked (`DownloadVerifier`) before it counts.
///
/// One manager per app, made at launch, so the system can hand it events for
/// downloads that finished while Atelier wasn't running.
@MainActor
@Observable
public final class DownloadManager {
	/// Newest first.
	public private(set) var downloads: [Download] = []
	/// Running downloads' progress, by download ID.
	public private(set) var progress: [UUID: DownloadProgress] = [:]
	/// What a running download is waiting for, such as a retry.
	public private(set) var notes: [UUID: String] = [:]

	public let store: DownloadStore

	/// Called after every change, for the system's progress UI.
	@ObservationIgnored public var onChange: (() -> Void)?
	/// Turns a download's URL into the one to fetch, for links that need a
	/// step first: a private GitHub repo's asset answers with a short-lived
	/// address only to a request with the user's token (#30). Nil from it
	/// leaves the URL as it is.
	@ObservationIgnored public var resolveURL: (@Sendable (URL) async throws -> URL?)?

	@ObservationIgnored private var session: URLSession!
	@ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
	@ObservationIgnored private var attempts: [UUID: Int] = [:]
	/// Downloads being paused or removed, whose cancellation isn't a failure.
	@ObservationIgnored private var stopping: Set<UUID> = []
	@ObservationIgnored private var lastProgressUpdate: [UUID: Date] = [:]
	@ObservationIgnored private var pendingChecks = 0
	@ObservationIgnored private var backgroundEventsCompletion: (() -> Void)?
	@ObservationIgnored private var eventsFinished = false

	/// The background session's identifier. iOS relaunches Atelier with it
	/// when downloads finish while it isn't running.
	public static let sessionIdentifier = "com.atelier.app.downloads"

	/// Downloads into `store` through a background session, or through
	/// `configuration` (tests).
	public init(store: DownloadStore, configuration: URLSessionConfiguration? = nil) {
		self.store = store
		try? store.prepare()
		downloads = store.load()
			.filter { $0.status != .finished || FileManager.default.fileExists(atPath: store.fileURL(for: $0.id).path) }
			.sorted { $0.createdAt > $1.createdAt }
		store.removeOrphans(keeping: downloads)

		let delegate = SessionDelegate(store: store)
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		queue.name = "Atelier downloads"
		session = URLSession(configuration: configuration ?? Self.backgroundConfiguration(), delegate: delegate, delegateQueue: queue)
		delegate.forward = { [weak self] event in
			Task { @MainActor in self?.handle(event) }
		}
		session.getAllTasks { tasks in
			let downloadTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
			Task { @MainActor [weak self] in self?.reattach(downloadTasks) }
		}
	}

	public static func backgroundConfiguration() -> URLSessionConfiguration {
		#if canImport(Darwin)
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		#else
		// Background sessions only exist on Apple platforms; this keeps the
		// package building on Linux, where only the tests run.
		let configuration = URLSessionConfiguration.default
		#endif
		#if os(iOS)
		// Started by a tap, so iOS shouldn't hold it back for a better moment.
		configuration.isDiscretionary = false
		configuration.sessionSendsLaunchEvents = true
		#endif
		configuration.allowsCellularAccess = true
		return configuration
	}

	// MARK: What the app asks

	/// Starts downloading `version` of `app` from the source at `sourceURL`.
	/// A download of the same version from the same source is reused: a
	/// running or finished one as it is, a paused or failed one resumed.
	/// `ahead` marks one Atelier starts by itself, to have an update ready
	/// (#19): it only downloads over Wi-Fi, and only until a download of the
	/// same version is asked for without `ahead`, which takes it over.
	@discardableResult
	public func download(_ app: SourceApp, version: AppVersion, sourceURL: URL?, ahead: Bool = false) -> Download {
		if let existing = download(of: version, sourceURL: sourceURL) {
			if !ahead, existing.isAhead == true {
				update(existing.id) { $0.isAhead = nil }
			}
			switch existing.status {
			case .downloading, .finished: return self.download(id: existing.id) ?? existing
			case .paused, .failed:
				resume(existing.id)
				return self.download(id: existing.id) ?? existing
			}
		}
		var download = Download(app: app, version: version, sourceURL: sourceURL)
		if ahead { download.isAhead = true }
		downloads.insert(download, at: 0)
		save()
		startTask(for: download.id)
		return download
	}

	/// Starts downloading the IPA at a URL the user pasted. The same URL
	/// already downloading or downloaded is reused, as for a source version.
	@discardableResult
	public func download(url: URL) -> Download {
		if let existing = downloads.first(where: { $0.isFromURL && $0.url == url }) {
			switch existing.status {
			case .downloading, .finished: return existing
			case .paused, .failed:
				resume(existing.id)
				return self.download(id: existing.id) ?? existing
			}
		}
		let download = Download(url: url)
		downloads.insert(download, at: 0)
		save()
		startTask(for: download.id)
		return download
	}

	/// Adds and starts a download made elsewhere (tests, and later, updates).
	public func start(_ download: Download) {
		var download = download
		download.status = .downloading
		downloads.removeAll { $0.id == download.id }
		downloads.insert(download, at: 0)
		save()
		startTask(for: download.id)
	}

	/// Lets a download started ahead (#19) use mobile data, for an install
	/// that waits on it while Wi-Fi isn't there: a running one starts again,
	/// as its request can't be changed.
	public func allowMobileData(_ id: UUID) {
		guard let download = download(id: id), download.isAhead == true || tasks[id]?.originalRequest?.allowsCellularAccess == false else { return }
		update(id) { $0.isAhead = nil }
		guard download.status == .downloading, let task = tasks.removeValue(forKey: id) else { return }
		stopping.insert(id)
		task.cancel()
		// Its resume data would carry the Wi-Fi-only request along.
		store.removeResumeData(for: id)
		progress[id] = DownloadProgress(received: 0, expected: download.expectedSize)
		startTask(for: id)
	}

	public func download(id: UUID) -> Download? {
		downloads.first { $0.id == id }
	}

	/// The newest download of `version` from the source at `sourceURL`.
	public func download(of version: AppVersion, sourceURL: URL?) -> Download? {
		downloads.first { $0.matches(version, sourceURL: sourceURL) }
	}

	/// The checked IPA of a finished download.
	public func fileURL(for id: UUID) -> URL? {
		guard download(id: id)?.status == .finished else { return nil }
		let url = store.fileURL(for: id)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	/// Pauses a running download, keeping what it has.
	public func pause(_ id: UUID) {
		guard download(id: id)?.status == .downloading else { return }
		update(id) { $0.status = .paused }
		notes[id] = nil
		progress[id] = nil
		guard let task = tasks.removeValue(forKey: id) else { return }
		stopping.insert(id)
		let store = store
		task.cancel(byProducingResumeData: { data in
			if let data { store.saveResumeData(data, for: id) }
		})
	}

	/// Resumes a paused download or retries a failed one, from its resume
	/// data when there is some.
	public func resume(_ id: UUID) {
		guard let download = download(id: id), download.status != .finished, tasks[id] == nil else { return }
		attempts[id] = 0
		update(id) { $0.status = .downloading }
		startTask(for: id)
	}

	/// Stops a download if it's running and deletes it and its file: to
	/// cancel it, or once its app is installed.
	public func remove(_ id: UUID) {
		if let task = tasks.removeValue(forKey: id) {
			stopping.insert(id)
			task.cancel()
		}
		downloads.removeAll { $0.id == id }
		progress[id] = nil
		notes[id] = nil
		attempts[id] = nil
		store.removeFiles(for: id)
		save()
	}

	/// Whether any download is running or waiting to be retried.
	public var isActive: Bool {
		downloads.contains { $0.status == .downloading }
	}

	/// The running downloads' combined progress, for the system's progress UI.
	public var activeProgress: DownloadProgress {
		var received: Int64 = 0, expected: Int64 = 0
		for download in downloads where download.status == .downloading {
			let current = progress[download.id]
			received += current?.received ?? 0
			expected += current?.expected ?? download.expectedSize ?? 0
		}
		return DownloadProgress(received: received, expected: expected > 0 ? expected : nil)
	}

	/// Hands over the completion handler iOS passes when it relaunches
	/// Atelier for this session's events. It's called once they've all been
	/// handled, including checking finished files.
	public func handleBackgroundEvents(completion: @escaping () -> Void) {
		backgroundEventsCompletion = completion
		// The events may already have been delivered: the session exists
		// from launch, before iOS hands over the handler.
		callBackgroundCompletionIfDone()
	}

	// MARK: Tasks

	private func startTask(for id: UUID) {
		guard let download = download(id: id) else { return }
		let ahead = download.isAhead == true
		if let data = store.resumeData(for: id) {
			run(session.downloadTask(withResumeData: data), for: id)
		} else if let resolveURL {
			// Resolved every time a download starts afresh, since the address
			// it resolves to expires.
			let url = download.url
			Task { [weak self] in
				do {
					let resolved = try await resolveURL(url)
					// Paused or removed meanwhile.
					guard let self, self.download(id: id)?.status == .downloading, self.tasks[id] == nil else { return }
					self.run(self.downloadTask(resolved ?? url, ahead: ahead), for: id)
				} catch {
					self?.fail(id, DownloadManager.startFailure(error))
				}
			}
		} else {
			run(downloadTask(download.url, ahead: ahead), for: id)
		}
	}

	private func downloadTask(_ url: URL, ahead: Bool) -> URLSessionDownloadTask {
		session.downloadTask(with: Self.request(for: url, ahead: ahead))
	}

	/// What a download asks for. Atelier names itself rather than going by
	/// iOS's own user agent, as some hosts answer that with an itms-services
	/// install link in place of the IPA, which a download can't follow
	/// ("unsupported URL"): Codemagic's artifact links do.
	nonisolated static func request(for url: URL, ahead: Bool) -> URLRequest {
		var request = URLRequest(url: url)
		request.setValue("application/octet-stream, */*;q=0.8", forHTTPHeaderField: "Accept")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		// One started ahead waits for Wi-Fi rather than use mobile data (#19).
		if ahead { request.allowsCellularAccess = false }
		return request
	}

	/// "Atelier/0.2.0", without iOS's CFNetwork and Darwin versions.
	nonisolated static let userAgent = "Atelier/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"

	private func run(_ task: URLSessionDownloadTask, for id: UUID) {
		guard let download = download(id: id) else { return }
		task.taskDescription = id.uuidString
		tasks[id] = task
		notes[id] = nil
		if progress[id] == nil {
			progress[id] = DownloadProgress(received: 0, expected: download.expectedSize)
		}
		task.resume()
		onChange?()
	}

	/// After a launch: tasks the system still runs are matched back to their
	/// downloads, and downloads with no task left are resumed. Those wait a
	/// moment first, because the system may still be delivering a finish
	/// from while Atelier wasn't running.
	private func reattach(_ running: [URLSessionDownloadTask]) {
		for task in running {
			guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
			      download(id: id)?.status == .downloading, tasks[id] == nil else {
				task.cancel()
				continue
			}
			tasks[id] = task
			let expected = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : download(id: id)?.expectedSize
			progress[id] = DownloadProgress(received: task.countOfBytesReceived, expected: expected)
		}
		onChange?()
		Task { [weak self] in
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			guard let self else { return }
			for download in self.downloads where download.status == .downloading && self.tasks[download.id] == nil {
				self.startTask(for: download.id)
			}
		}
	}

	private func handle(_ event: SessionDelegate.Event) {
		switch event {
		case let .progress(id, taskID, received, expected):
			guard tasks[id]?.taskIdentifier == taskID else { return }
			let now = Date()
			let done = expected > 0 && received >= expected
			if !done, let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.25 { return }
			lastProgressUpdate[id] = now
			progress[id] = DownloadProgress(received: received, expected: expected > 0 ? expected : download(id: id)?.expectedSize)
			notes[id] = nil
			onChange?()

		case let .transferred(id, taskID, result):
			if tasks[id]?.taskIdentifier == taskID {
				tasks[id] = nil
			} else if let other = tasks.removeValue(forKey: id) {
				// A finish from before a relaunch, after the download was
				// already started again: the finished file wins.
				stopping.insert(id)
				other.cancel()
			}
			guard let download = download(id: id), download.status == .downloading else {
				try? FileManager.default.removeItem(at: store.partialURL(for: id))
				return
			}
			switch result {
			case .failure(let problem):
				fail(id, problem.description)
			case .success(let partial):
				check(download, at: partial)
			}

		case let .interrupted(id, taskID, interruption):
			if stopping.remove(id) != nil, tasks[id]?.taskIdentifier != taskID { return }
			guard tasks[id]?.taskIdentifier == taskID || tasks[id] == nil else { return }
			tasks[id] = nil
			guard download(id: id)?.status == .downloading else { return }
			if !interruption.hasResumeData {
				// What was saved before can't be used any more, or the server
				// doesn't support ranges: the next attempt starts again.
				store.removeResumeData(for: id)
			}
			if interruption.forceQuit {
				// iOS cancels a force-quit app's downloads, and the user
				// presumably meant that.
				update(id) { $0.status = .paused }
				progress[id] = nil
				return
			}
			let attempt = (attempts[id] ?? 0) + 1
			attempts[id] = attempt
			guard let delay = RetryPolicy.delay(beforeAttempt: attempt) else {
				fail(id, interruption.message)
				return
			}
			notes[id] = "\(interruption.message) Retrying in \(Int(delay)) s."
			onChange?()
			Task { [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				guard let self, self.download(id: id)?.status == .downloading, self.tasks[id] == nil else { return }
				self.startTask(for: id)
			}

		case .eventsFinished:
			eventsFinished = true
			callBackgroundCompletionIfDone()
		}
	}

	/// Checks a transferred file off the main thread, then keeps or rejects it.
	private func check(_ download: Download, at partial: URL) {
		pendingChecks += 1
		notes[download.id] = "Checking the download…"
		onChange?()
		let id = download.id, expectedSize = download.expectedSize, sha256 = download.sha256
		let readInfo = download.isFromURL
		let destination = store.fileURL(for: id)
		Task.detached(priority: .utility) {
			let result: Result<Checked, Error> = Result {
				try DownloadVerifier.verify(fileAt: partial, expectedSize: expectedSize, sha256: sha256)
				try? FileManager.default.removeItem(at: destination)
				try FileManager.default.moveItem(at: partial, to: destination)
				let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
				// A pasted URL says nothing about the app, so it's read from the IPA.
				let info = readInfo ? try? IPAInfo.read(ipaAt: destination) : nil
				return Checked(size: size, info: info)
			}
			if case .failure = result { try? FileManager.default.removeItem(at: partial) }
			await MainActor.run { [weak self] in self?.checked(id, result) }
		}
	}

	/// A download that passed its check.
	private struct Checked: Sendable {
		var size: Int64
		/// The app's details, for a download from a pasted URL.
		var info: IPAInfo?
	}

	private func checked(_ id: UUID, _ result: Result<Checked, Error>) {
		pendingChecks -= 1
		defer { callBackgroundCompletionIfDone() }
		guard let current = download(id: id) else {
			// Removed while it was checked.
			store.removeFiles(for: id)
			return
		}
		switch result {
		case .success(let checked):
			// Kept even if it was paused meanwhile: the file is complete.
			store.removeResumeData(for: id)
			update(id) {
				$0.status = .finished
				$0.fileSize = checked.size
				if let info = checked.info {
					$0.bundleID = info.bundleID
					$0.name = info.name
					$0.version = info.version
					$0.displayVersion = info.version
				}
			}
			progress[id] = nil
			notes[id] = nil
			attempts[id] = nil
		case .failure(let error):
			guard current.status == .downloading else { return }
			fail(id, (error as? DownloadVerifier.Problem)?.description ?? "Couldn't keep the download: \(error.localizedDescription)")
		}
	}

	/// What a download says when `resolveURL` threw `error`, so it couldn't
	/// start: such as when no GitHub account can see a private repo's asset,
	/// which the app recognises to offer a sign-in (#134).
	public nonisolated static func startFailure(_ error: Error) -> String {
		"Couldn't start the download: \(error)"
	}

	private func fail(_ id: UUID, _ message: String) {
		update(id) { $0.status = .failed(message) }
		progress[id] = nil
		notes[id] = nil
	}

	private func callBackgroundCompletionIfDone() {
		guard eventsFinished, pendingChecks == 0, let completion = backgroundEventsCompletion else { return }
		backgroundEventsCompletion = nil
		eventsFinished = false
		completion()
	}

	private func update(_ id: UUID, _ change: (inout Download) -> Void) {
		guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
		change(&downloads[index])
		save()
	}

	private func save() {
		try? store.save(downloads)
		onChange?()
	}
}

/// The session's delegate. Runs on the session's queue; everything but
/// moving a finished file out of the system's temporary location goes to
/// the manager on the main actor.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	struct Interruption: Sendable {
		var message: String
		var hasResumeData: Bool
		var forceQuit: Bool
	}

	enum Event: Sendable {
		case progress(UUID, taskID: Int, received: Int64, expected: Int64)
		/// The partial file, or why the server's answer was rejected.
		case transferred(UUID, taskID: Int, Result<URL, DownloadVerifier.Problem>)
		case interrupted(UUID, taskID: Int, Interruption)
		case eventsFinished
	}

	let store: DownloadStore
	/// Set once, right after the session is made and before any task runs.
	var forward: (@Sendable (Event) -> Void)?

	init(store: DownloadStore) {
		self.store = store
	}

	private func id(of task: URLSessionTask) -> UUID? {
		task.taskDescription.flatMap(UUID.init(uuidString:))
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let id = id(of: downloadTask) else { return }
		forward?(.progress(id, taskID: downloadTask.taskIdentifier, received: totalBytesWritten, expected: totalBytesExpectedToWrite))
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
		guard let id = id(of: downloadTask) else { return }
		forward?(.progress(id, taskID: downloadTask.taskIdentifier, received: fileOffset, expected: expectedTotalBytes))
	}

	/// The file at `location` is deleted when this returns, so it's moved now.
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let id = id(of: downloadTask) else { return }
		let taskID = downloadTask.taskIdentifier
		// A 404 page still arrives as a finished download.
		if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
			forward?(.transferred(id, taskID: taskID, .failure(.httpStatus(response.statusCode))))
			return
		}
		let partial = store.partialURL(for: id)
		do {
			try? store.prepare()
			try? FileManager.default.removeItem(at: partial)
			try FileManager.default.moveItem(at: location, to: partial)
			forward?(.transferred(id, taskID: taskID, .success(partial)))
		} catch {
			forward?(.interrupted(id, taskID: taskID, Interruption(message: "Couldn't save the download.", hasResumeData: false, forceQuit: false)))
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let error, let id = id(of: task) else { return }
		let nsError = error as NSError
		var resumeData = nsError.userInfo[Self.resumeDataKey] as? Data
		if resumeData?.isEmpty == true { resumeData = nil }
		if let resumeData { store.saveResumeData(resumeData, for: id) }
		var forceQuit = false
		#if canImport(Darwin)
		if let reason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int {
			forceQuit = reason == NSURLErrorCancelledReasonUserForceQuitApplication
		}
		#endif
		forward?(.interrupted(id, taskID: task.taskIdentifier, Interruption(
			message: Self.message(for: nsError),
			hasResumeData: resumeData != nil,
			forceQuit: forceQuit
		)))
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		forward?(.eventsFinished)
	}

	#if canImport(Darwin)
	private static let resumeDataKey = NSURLSessionDownloadTaskResumeData
	#else
	private static let resumeDataKey = "NSURLSessionDownloadTaskResumeData"
	#endif

	private static func message(for error: NSError) -> String {
		guard error.domain == NSURLErrorDomain else { return "The download stopped: \(error.localizedDescription)" }
		switch error.code {
		case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
			return "The connection was lost."
		case NSURLErrorTimedOut:
			return "The server stopped responding."
		case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
			return "Couldn't reach the server."
		case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate:
			return "Couldn't connect to the server securely."
		default:
			return "The download stopped: \(error.localizedDescription)"
		}
	}
}
