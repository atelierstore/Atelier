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
///
/// Atelier itself has two (#152, decided 11 Nov 2026), three days ahead and
/// the day before, as once its own profile has ended it can't open to renew
/// anything; and one the day before while the free Apple ID that installed
/// it isn't signed in, which says to sign in.
@MainActor
enum RenewalNotifications {
	static let prefix = "renewal."
	private static let endingPrefix = prefix + "ending."
	/// Atelier's own, besides the day before's.
	private static let ownPrefix = prefix + "own."
	private static let ownSoon = ownPrefix + "soon"
	private static let ownSignIn = ownPrefix + "signin"
	private static let ownLead: TimeInterval = 3 * 86_400
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

		let own = SelfUpdate.shared
		let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(endingPrefix) || $0.hasPrefix(ownPrefix) }
		center.removePendingNotificationRequests(withIdentifiers: pending)
		for app in apps {
			let expires = app.profile.expires
			let isOwn = app.profile.bundleID == own.bundleID
			// Atelier itself, three days ahead too (#152).
			if isOwn {
				await schedule(
					ownSoon, at: expires.addingTimeInterval(-ownLead),
					title: "\(app.name) stops opening in 3 days",
					body: "Its own profile ends on \(AppProfileDays.describe(expires)). Open \(app.name) on Wi-Fi to renew it, which takes a few seconds.",
					now: now
				)
			}
			await schedule(
				endingPrefix + app.profile.bundleID, at: expires.addingTimeInterval(-86_400),
				title: "\(app.name) stops opening tomorrow",
				body: isOwn
					? "Open \(app.name) on Wi-Fi to renew it. Once its profile has ended, it has to be installed again."
					: "Its profile ends at \(expires.formatted(date: .omitted, time: .shortened)). Open Atelier to renew it, which takes a few seconds.",
				now: now
			)
		}
		// Atelier itself, while the free Apple ID that installed it isn't
		// signed in: the day before the profile in its build ends.
		if let expires = own.needsAppleID(in: .shared)?.expires {
			await schedule(
				ownSignIn, at: expires.addingTimeInterval(-86_400),
				title: "\(own.name) stops opening tomorrow",
				body: "A free Apple ID installed it. Sign in with it in \(own.name), and \(own.name) renews itself.",
				now: now
			)
		}
		// Shown already, for an app that renewed since.
		var renewed = apps.filter { $0.profile.expires.timeIntervalSince(now) > 86_400 }.map { endingPrefix + $0.profile.bundleID }
		if let mine = apps.first(where: { $0.profile.bundleID == own.bundleID }) {
			if mine.profile.expires.timeIntervalSince(now) > ownLead { renewed.append(ownSoon) }
			// Signed in since.
			renewed.append(ownSignIn)
		}
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

	/// Leaves it with iOS for `date`, so it comes even when Atelier doesn't
	/// run; nothing once `date` has passed.
	private static func schedule(_ identifier: String, at date: Date, title: String, body: String, now: Date) async {
		guard date > now else { return }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSince(now), repeats: false)
		try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
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
