import DownloadKit
import Foundation
import Network
import AtelierCore
import SourceKit
import SwiftData
import UIKit
import UserNotifications

/// Background checks for updates and news (#19). Each background refresh
/// refreshes the sources, then:
///
/// - On Wi-Fi, downloads the Library's updates ahead, so Update only signs
///   and installs. Those downloads wait for Wi-Fi until the user asks for
///   them (`DownloadManager`), and go once their version is no longer the
///   app's update.
/// - Tells the user about updates once one is new: "3 updates available".
///   Updates seen in Atelier count as told.
/// - Tells the user about news items a source flags with `notify`.
///
/// iOS decides when a refresh runs, usually a few times a day for an app
/// that's used. The automatic updates run (#72) does the same before it
/// installs, and tells about what it couldn't install.
@MainActor
enum UpdateChecks {
	static let notifyUpdatesKey = "notifyUpdates"
	static let notifyNewsKey = "notifyNews"
	/// What `UpdateNotice.told(after:)` remembers.
	private static let toldKey = "updatesTold"
	/// What `NewsNotice.check` remembers; missing before the first check.
	private static let newsSeenKey = "newsSeen"
	/// The downloads started ahead, so the ones no longer needed can go.
	private static let aheadKey = "downloadsAhead"
	/// The identifier of the one updates notification, replaced each time.
	static let updatesNotificationID = "updates.available"
	static let newsNotificationPrefix = "news."

	static var notifiesUpdates: Bool {
		UserDefaults.standard.object(forKey: notifyUpdatesKey) as? Bool ?? true
	}

	static var notifiesNews: Bool {
		UserDefaults.standard.object(forKey: notifyNewsKey) as? Bool ?? true
	}

	/// What started a check, for its report.
	enum Trigger: String, Codable {
		case refresh = "background refresh"
		case automatic = "automatic updates"
		case test
	}

	/// What the last check did, for Settings › Test Actions (#19).
	struct Report: Codable {
		var date: Date
		var trigger: Trigger
		/// Nil until the check ends; iOS may stop it before.
		var updates: [String]?
		var notified = false
		var onWiFi = false
		var downloadsStarted = 0
		/// Updates already in Downloads, and ones left for lack of space.
		var downloadsThere: Int?
		var noRoom: Int?
		var news = 0

		var summary: String {
			let time = date.formatted(date: .abbreviated, time: .shortened)
			guard let updates else { return "Last run \(time) (\(trigger.rawValue)): stopped before it finished." }
			var parts = [updates.isEmpty ? "no updates" : "\(updates.count == 1 ? "1 update" : "\(updates.count) updates") (\(updates.joined(separator: ", ")))"]
			if notified { parts.append("notified") }
			if !onWiFi {
				parts.append("not on Wi-Fi, nothing downloaded ahead")
			} else {
				if downloadsStarted > 0 { parts.append("\(downloadsStarted) downloading ahead") }
				if let downloadsThere, downloadsThere > 0 { parts.append("\(downloadsThere) already in Downloads") }
				if let noRoom, noRoom > 0 { parts.append("\(noRoom) not downloaded for lack of space") }
			}
			parts.append(news == 1 ? "1 news item" : "\(news) news items")
			return "Last run \(time) (\(trigger.rawValue)): \(parts.joined(separator: ", "))."
		}
	}

	private static let reportKey = "updateChecksReport"

	static var lastReport: Report? {
		UserDefaults.standard.data(forKey: reportKey).flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
	}

	private static func save(_ report: Report) {
		UserDefaults.standard.set(try? JSONEncoder().encode(report), forKey: reportKey)
	}

	/// One check, from a background refresh: refreshes the sources first.
	static func run(from trigger: Trigger) async {
		guard let container = AutoUpdates.container else { return }
		save(Report(date: .now, trigger: trigger))
		let context = container.mainContext
		await SourceLibrary(context: context, gitHub: GitHubAccess.source()).refreshAll()
		guard !Task.isCancelled else { return }
		let records = (try? context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
		let catalog = await CatalogModel.build(from: records)
		guard !Task.isCancelled else { return }
		await check(catalog, context: context, from: trigger)
	}

	/// Downloads ahead and tells about updates and news in `catalog`, its
	/// sources already refreshed.
	static func check(_ catalog: Catalog, context: ModelContext, from trigger: Trigger) async {
		var report = Report(date: .now, trigger: trigger)
		let items = updates(in: catalog, context: context)
		// Atelier's own update downloads only once a certificate, or its
		// Apple ID, signs for the App ID it was installed with (#24, #152).
		let downloadable = items.filter { !$0.isOwn || SelfUpdate.shared.canSignItself(certificates: .shared, context: context) }
		let ahead = await downloadAhead(downloadable, downloads: BackgroundDownloads.shared.manager)
		report.onWiFi = ahead.onWiFi
		report.downloadsStarted = ahead.started
		report.downloadsThere = ahead.there
		report.noRoom = ahead.noRoom
		report.notified = await notify(items)
		report.news = await notifyNews(catalog.news)
		report.updates = notices(items).map { "\($0.name) \($0.displayVersion)" }
		save(report)
	}

	/// Settings › Test Actions: the next check tells about every update and
	/// recent flagged news item again.
	static func forgetTold() {
		UserDefaults.standard.set([String](), forKey: toldKey)
		UserDefaults.standard.set([String](), forKey: newsSeenKey)
	}

	/// The Library's updates, leaving out skipped versions.
	static func updates(in catalog: Catalog, context: ModelContext) -> [LibraryItem] {
		let installs = (try? context.fetch(FetchDescriptor<InstallRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
		return installs
			.map { LibraryItem($0, catalog: catalog, certificates: .shared, installer: .shared) }
			.filter { $0.update != nil }
	}

	// MARK: Telling

	/// While Atelier is in front: the updates and news it shows count as
	/// told, so a later check doesn't bring them up again.
	static func markSeen(updates items: [LibraryItem], news: [Catalog.News]) {
		UserDefaults.standard.set(Array(UpdateNotice.told(after: notices(items))), forKey: toldKey)
		var seen = Set(UserDefaults.standard.stringArray(forKey: newsSeenKey) ?? [])
		seen.formUnion(news.map(\.id))
		UserDefaults.standard.set(Array(seen), forKey: newsSeenKey)
	}

	private static func notices(_ items: [LibraryItem]) -> [UpdateNotice.Update] {
		items.compactMap { item in
			item.update.map { UpdateNotice.Update(bundleID: item.install.bundleID, version: $0, name: item.install.name) }
		}
	}

	/// Whether it notified.
	private static func notify(_ items: [LibraryItem]) async -> Bool {
		let updates = notices(items)
		let told = Set(UserDefaults.standard.stringArray(forKey: toldKey) ?? [])
		UserDefaults.standard.set(Array(UpdateNotice.told(after: updates)), forKey: toldKey)
		let center = UNUserNotificationCenter.current()
		if updates.isEmpty {
			center.removeDeliveredNotifications(withIdentifiers: [updatesNotificationID])
			return false
		}
		guard notifiesUpdates, let notice = UpdateNotice.notice(for: updates, told: told), await canNotify() else { return false }
		let content = UNMutableNotificationContent()
		content.title = notice.title
		content.body = notice.body
		content.sound = .default
		do {
			try await center.add(UNNotificationRequest(identifier: updatesNotificationID, content: content, trigger: nil))
			return true
		} catch {
			return false
		}
	}

	/// How many it told about.
	private static func notifyNews(_ news: [Catalog.News]) async -> Int {
		let stored = UserDefaults.standard.stringArray(forKey: newsSeenKey).map(Set.init)
		let items = news.map { NewsNotice.Item(id: $0.id, sourceName: $0.source.name, item: $0.item) }
		let result = NewsNotice.check(items, seen: stored, now: .now)
		UserDefaults.standard.set(Array(result.seen), forKey: newsSeenKey)
		guard notifiesNews, !result.notify.isEmpty, await canNotify() else { return 0 }
		for item in result.notify {
			let content = UNMutableNotificationContent()
			content.title = item.title
			content.body = item.body
			content.sound = .default
			try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: newsNotificationPrefix + item.id, content: content, trigger: nil))
		}
		return result.notify.count
	}

	/// Whether notifications may show. Before the user has been asked,
	/// asks for provisional ones, which need no prompt and arrive quietly in
	/// Notification Center until the user keeps them.
	private static func canNotify() async -> Bool {
		let center = UNUserNotificationCenter.current()
		switch await center.notificationSettings().authorizationStatus {
		case .authorized, .provisional, .ephemeral: return true
		case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
		case .denied: return false
		@unknown default: return false
		}
	}

	// MARK: Downloading ahead

	/// Starts the downloads of `items`' updates that aren't there yet, on
	/// Wi-Fi only, after deleting those started ahead that are no longer
	/// needed.
	static func downloadAhead(_ items: [LibraryItem], downloads: DownloadManager) async -> (onWiFi: Bool, started: Int, there: Int, noRoom: Int) {
		removeUnneeded(items, downloads: downloads)
		guard await NetworkPath.shared.isWiFi() else { return (false, 0, 0, 0) }
		var ahead = Set(UserDefaults.standard.stringArray(forKey: aheadKey) ?? [])
		var room = freeSpace
		var started = 0, there = 0, noRoom = 0
		for item in items {
			guard let update = item.update, let listing = item.listing else { continue }
			if let existing = downloads.download(of: update, sourceURL: listing.source.url) {
				// The user's own, paused or failed, is left to them; one
				// started ahead that failed is tried again.
				guard existing.isAhead == true, case .failed = existing.status else {
					there += 1
					continue
				}
			} else {
				// Leaves room for signing, which needs about as much again.
				let size = update.size ?? 0
				if let space = room {
					guard space > 2 * size + minimumFreeSpace else {
						noRoom += 1
						continue
					}
					room = space - size
				}
			}
			let download = downloads.download(listing.app, version: update, sourceURL: listing.source.url, ahead: true)
			ahead.insert(download.id.uuidString)
			started += 1
		}
		UserDefaults.standard.set(Array(ahead), forKey: aheadKey)
		return (true, started, there, noRoom)
	}

	/// Deletes downloads started ahead whose version is no longer an update
	/// the Library shows: skipped, superseded or installed some other way.
	/// One the user has asked for is theirs and stays.
	static func removeUnneeded(_ items: [LibraryItem], downloads: DownloadManager) {
		var ahead = Set(UserDefaults.standard.stringArray(forKey: aheadKey) ?? [])
		for string in ahead {
			guard let id = UUID(uuidString: string), let download = downloads.download(id: id), download.isAhead == true else {
				ahead.remove(string)
				continue
			}
			let needed = items.contains { item in
				guard let update = item.update, let listing = item.listing else { return false }
				return download.matches(update, sourceURL: listing.source.url)
			}
			if !needed, !InstallModel.shared.isQueued(download) {
				downloads.remove(id)
				ahead.remove(string)
			}
		}
		UserDefaults.standard.set(Array(ahead), forKey: aheadKey)
	}

	private static let minimumFreeSpace: Int64 = 1_000_000_000

	/// The space iOS would make for a download. The capacity for
	/// opportunistic usage, meant for downloads that can wait, is often far
	/// below what Settings shows as free, so nothing would download ahead;
	/// the margin above keeps room instead.
	private static var freeSpace: Int64? {
		let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		return values?.volumeAvailableCapacityForImportantUsage
	}
}

/// The network Atelier is on, followed for as long as it runs, for
/// downloads started ahead (#19): they only start on Wi-Fi, and one an
/// install waits on uses mobile data once Wi-Fi is gone.
final class NetworkPath: @unchecked Sendable {
	static let shared = NetworkPath()

	private let monitor = NWPathMonitor()
	private let lock = NSLock()
	/// Nil until the first report, which comes soon after the monitor starts.
	private var wifi: Bool?
	private var waiting: [CheckedContinuation<Bool, Never>] = []

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			// Wi-Fi or wired, not Low Data Mode or a personal hotspot.
			self?.changed(path.status == .satisfied && !path.isExpensive && !path.isConstrained)
		}
		monitor.start(queue: DispatchQueue(label: "com.atelier.app.network"))
	}

	/// Whether Atelier is on Wi-Fi, once the first report is in.
	func isWiFi() async -> Bool {
		await withCheckedContinuation { continuation in
			lock.lock()
			if let wifi {
				lock.unlock()
				continuation.resume(returning: wifi)
			} else {
				waiting.append(continuation)
				lock.unlock()
			}
		}
	}

	/// The last report, nil before the first.
	var isWiFiNow: Bool? {
		lock.withLock { wifi }
	}

	private func changed(_ wifi: Bool) {
		lock.lock()
		self.wifi = wifi
		let resumed = waiting
		waiting = []
		lock.unlock()
		for continuation in resumed { continuation.resume(returning: wifi) }
	}
}
