import AtelierCore
import CertKit
import Foundation
import SwiftData
import UserNotifications

/// Notifications about renewing an Apple ID's apps (#49), only when it
/// needs the user: none when it works. "Atlas stops opening tomorrow" is
/// scheduled a day before each app's profile ends, so it comes even when
/// Atelier doesn't run, and moves on each time the app renews. What a
/// renewal ran into tells at once: Apple's code, no App IDs left, or the
/// Apple ID's certificate gone. Each says it once a day at most. A tap opens
/// the Library.
@MainActor
enum RenewalNotifications {
	static let prefix = "renewal."
	private static let endingPrefix = prefix + "ending."
	/// When each was last told, by identifier.
	private static let toldKey = "renewalNotificationsTold"
	private static let quiet: TimeInterval = 20 * 60 * 60

	/// Schedules each app's "stops opening tomorrow" in place of the one
	/// before, takes back the ones of apps renewed since, and tells what
	/// needs the user in `problems`.
	static func sync(problems: [String: ProfileRenewals.Problem], context: ModelContext, now: Date = .now) async {
		let center = UNUserNotificationCenter.current()
		var apps: [(account: StoredAppleID, name: String, profile: AppProfile)] = []
		for account in CertificatesModel.shared.appleIDs {
			for profile in account.profiles ?? [] {
				guard let record = InstalledApps.record(profile.bundleID, in: context), record.certificateID == account.id,
				      InstallModel.presence(of: record) != .deleted, InstallModel.shared.disabledApps[profile.bundleID] == nil
				else { continue }
				apps.append((account, record.name, profile))
			}
		}

		let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(endingPrefix) }
		center.removePendingNotificationRequests(withIdentifiers: pending)
		for app in apps {
			let date = app.profile.expires.addingTimeInterval(-86_400)
			guard date > now else { continue }
			let content = UNMutableNotificationContent()
			content.title = "\(app.name) stops opening tomorrow"
			content.body = "Its profile ends at \(app.profile.expires.formatted(date: .omitted, time: .shortened)). Open Atelier to renew it, which takes a few seconds."
			content.sound = .default
			let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSince(now), repeats: false)
			try? await center.add(UNNotificationRequest(identifier: endingPrefix + app.profile.bundleID, content: content, trigger: trigger))
		}
		// Shown already, for an app that renewed since.
		let renewed = apps.filter { $0.profile.expires.timeIntervalSince(now) > 86_400 }.map { endingPrefix + $0.profile.bundleID }
		center.removeDeliveredNotifications(withIdentifiers: renewed)

		for account in CertificatesModel.shared.appleIDs {
			let mine = apps.filter { $0.account.id == account.id }
			let code = mine.filter { problems[$0.profile.bundleID] == .codeNeeded }.map(\.name)
			if !code.isEmpty {
				await tell(
					"\(prefix)code.\(account.id.uuidString)",
					title: "\(ProfileRenewals.joined(code)) \(code.count == 1 ? "needs" : "need") renewing",
					body: "Apple wants a code to sign in. Open Atelier to enter it.",
					now: now
				)
			}
			let signIn = mine.filter { problems[$0.profile.bundleID] == .signInAgain }.map(\.name)
			if !signIn.isEmpty {
				let cause = account.isRevoked ? "Apple revoked your Apple ID’s certificate." : "Your Apple ID’s certificate ended."
				await tell(
					"\(prefix)signin.\(account.id.uuidString)",
					title: signIn.count == 1 ? "\(signIn[0]) needs signing again" : "\(signIn.count) apps need signing again",
					body: "\(cause) Sign in with it again in Atelier, which then signs \(ProfileRenewals.joined(signIn)) again, keeping \(signIn.count == 1 ? "its" : "their") data.",
					now: now
				)
			}
			for app in mine {
				switch problems[app.profile.bundleID] {
				case .noAppIDLeft(let until)?:
					let ends = app.profile.expires
					let title = until.map { "\(app.name) can’t be renewed until \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? "\(app.name) can’t be renewed this week"
					let left = until.map { "until \(day($0))" } ?? "this week"
					await tell(
						"\(prefix)appid.\(app.profile.bundleID)",
						title: title,
						body: "Its App ID ended, and your Apple ID has no new ones left \(left). \(app.name) \(ends > now ? "stops opening \(when(ends, now: now))" : "doesn’t open until then").",
						now: now
					)
				case .signAgain?:
					await tell(
						"\(prefix)signagain.\(app.profile.bundleID)",
						title: "\(app.name) needs signing again",
						body: "The certificate it was signed with is gone, so a new profile won’t do. Open Atelier to renew it, which signs it again and keeps its data.",
						now: now
					)
				default:
					break
				}
			}
		}
	}

	/// Shows it now, unless it was told in the last 20 hours.
	private static func tell(_ identifier: String, title: String, body: String, now: Date) async {
		let defaults = UserDefaults.standard
		var told = defaults.dictionary(forKey: toldKey) as? [String: Date] ?? [:]
		told = told.filter { now.timeIntervalSince($0.value) < quiet }
		guard told[identifier] == nil else { return }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
		told[identifier] = now
		defaults.set(told, forKey: toldKey)
	}

	/// "Wed 11 Nov".
	private static func day(_ date: Date) -> String {
		date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
	}

	/// "tonight at 22:14", "tomorrow at 14:39", "on Wed 11 Nov at 14:39".
	private static func when(_ date: Date, now: Date) -> String {
		let time = date.formatted(date: .omitted, time: .shortened)
		let calendar = Calendar.current
		if calendar.isDate(date, inSameDayAs: now) {
			return calendar.component(.hour, from: date) >= 18 ? "tonight at \(time)" : "today at \(time)"
		}
		if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
			return "tomorrow at \(time)"
		}
		return "on \(day(date)) at \(time)"
	}
}
