import AppleIDKit
import AtelierCore
import CertKit
import Foundation
import InstallKit
import Observation
import SwiftData
import UIKit

/// The weekly renewal of the apps installed with an Apple ID (#49). A free
/// Apple ID's profiles last 7 days, so two days before an app's ends,
/// Atelier gets a new one from Apple and puts it on through misagent: no
/// download and no reinstall, as iOS goes by the profile installed on the
/// iPhone (docs/free-apple-id-spike.md). It renews when Atelier comes to
/// the front, in background refreshes and in automatic update runs, while
/// LocalDevVPN is connected; Renew Now renews one app, or all of an Apple
/// ID's, connecting it first and asking for Apple's code when needed.
///
/// When a new profile won't do, as the certificate the app was signed with
/// is gone, the app is signed again and reinstalled, keeping its data: in
/// the background only with automatic updates on. Atelier tells only when
/// renewing needs the user (`RenewalNotifications`).
///
/// Atelier itself is one of these apps when the Apple ID that installed it
/// is signed in (#152, `OwnAppleID`): it renews first, and four days ahead
/// rather than two, as once its own profile has ended it can't open to
/// renew anything. Signing it again closes it, so only Renew does that.
@MainActor
@Observable
final class ProfileRenewals {
	static let shared = ProfileRenewals()

	/// Why an app wasn't renewed, until it is.
	enum Problem: Equatable {
		/// Direct installs couldn't reach iOS, as with LocalDevVPN off.
		case unreachable(String)
		/// Apple asked for its code, with nobody there to enter it.
		case codeNeeded
		/// Its App ID ended, and the Apple ID has no new ones left until
		/// then.
		case noAppIDLeft(until: Date?)
		/// Apple revoked the Apple ID's certificate, or it ended: it has to
		/// sign in again, and its apps be signed again.
		case signInAgain
		/// The certificate it was signed with is gone, so it has to be
		/// signed again, which Renew does.
		case signAgain
		case failed(String)

		/// What it says under the app.
		var message: String {
			switch self {
			case .unreachable(let why): why
			case .codeNeeded: "Apple wanted a code. Renew asks for it."
			case .noAppIDLeft(let until): "Its App ID ended, and your Apple ID has no new ones left \(until.map { "until \(AppProfileDays.describe($0))" } ?? "this week")."
			case .signInAgain: "Sign in with its Apple ID again, whose certificate Apple revoked or that ended. Atelier then signs it again, keeping its data."
			case .signAgain: "Renew signs it again and reinstalls it, keeping its data: a new profile alone won’t do, as the certificate it was signed with is gone."
			case .failed(let why): why
			}
		}

		/// The same under Atelier itself (#152), which installs over itself.
		@MainActor func message(isOwn: Bool) -> String {
			guard isOwn, self == .signAgain else { return message }
			return "Renew signs \(SelfUpdate.shared.name) again and installs it over itself, so it asks you to go to the Home Screen: a new profile alone won’t do."
		}

		/// LocalDevVPN was off, or iOS didn't answer, which the Library's
		/// Renew section says in its footer rather than under each app.
		var isUnreachable: Bool {
			if case .unreachable = self { return true }
			return false
		}
	}

	/// What started a renewal.
	enum Trigger: CustomStringConvertible {
		/// Atelier came to the front, or its installs ended while it was.
		case opened
		/// A background refresh or an automatic update run.
		case background
		/// Renew Now or Renew: connects LocalDevVPN and asks for Apple's
		/// code when needed.
		case user

		var description: String {
			switch self {
			case .opened: "on opening Atelier"
			case .background: "in the background"
			case .user: "Renew Now"
			}
		}
	}

	/// The apps being renewed now, by bundle ID.
	private(set) var renewing: Set<String> = []
	/// Why the last try didn't renew an app, by bundle ID, until one does.
	private(set) var problems: [String: Problem] = [:]
	/// The apps renewed since the Library last showed, which say Renewed
	/// there until it's left.
	private(set) var recentlyRenewed: Set<String> = []

	@ObservationIgnored private var isBusy = false
	/// When each Apple ID last signed in for a renewal without the user:
	/// at most every 10 minutes, so coming back to Atelier often doesn't
	/// sign in each time.
	@ObservationIgnored private var lastSignIn: [UUID: Date] = [:]
	private static let signInInterval: TimeInterval = 10 * 60
	/// The Apple IDs Apple asked a code of with nobody there: they renew
	/// by themselves again only once the user signed in, as each try can
	/// put Apple's code on their other devices.
	private static let codeNeededKey = "renewalCodeNeeded"

	private init() {}

	// MARK: When

	/// Renews the apps that are due, of every Apple ID: those whose profile
	/// ends within two days, on this iPhone. Nothing while Atelier installs.
	func renewDue(_ trigger: Trigger) async {
		guard !isBusy, let context = AutoUpdates.container?.mainContext else { return }
		let installer = InstallModel.shared
		guard !installer.isRunning, installer.waiting.isEmpty else { return }
		if trigger == .background {
			// The pairing file and the Apple ID's details can't be read while
			// the iPhone is locked, unless they're readable after first unlock.
			guard UIApplication.shared.isProtectedDataAvailable || SecretProtection.readableAfterFirstUnlock else { return }
		}
		isBusy = true
		defer { isBusy = false }
		if trigger == .opened {
			AutoUpdates.applyProtection()
			// For the notifications when a renewal needs the user, asked once:
			// also for Atelier itself, while the free Apple ID that installed
			// it isn't signed in (#152).
			if CertificatesModel.shared.appleIDs.contains(where: { !($0.profiles ?? []).isEmpty }) || SelfUpdate.shared.needsAppleID(in: .shared) != nil {
				Task { await CertificateNotifications.requestAuthorization() }
			}
		}
		for account in accountsInOrder() {
			// Every app of one whose certificate Apple revoked, or that ended,
			// stopped opening: it has to sign in again.
			if AppProfileRenewal.needsSignIn(account) {
				mark(apps(of: account, in: Set((account.profiles ?? []).map(\.bundleID)), context: context), .signInAgain)
				continue
			}
			let due = Set(account.profilesToRenew(own: ownBundleID(of: account)).map(\.bundleID))
			let targets = apps(of: account, in: due, context: context)
			guard !targets.isEmpty else { continue }
			if !AppleIDAccess.shared.hasSession(for: account) {
				if Self.codeNeeded.contains(account.id) {
					mark(targets, .codeNeeded)
					continue
				}
				if let last = lastSignIn[account.id], Date.now.timeIntervalSince(last) < Self.signInInterval { continue }
			}
			await run(targets, of: account, trigger: trigger, context: context)
		}
		await RenewalNotifications.sync(problems: problems, context: context)
	}

	/// Renew Now on an app's page or in its menu, and Renew in the Library:
	/// whether or not it's due.
	func renew(_ bundleIDs: [String]) async {
		guard let context = AutoUpdates.container?.mainContext else { return }
		await waitForTurn()
		isBusy = true
		defer { isBusy = false }
		for account in accountsInOrder() {
			let targets = apps(of: account, in: Set(bundleIDs), context: context)
			guard !targets.isEmpty else { continue }
			await run(targets, of: account, trigger: .user, context: context)
		}
		await RenewalNotifications.sync(problems: problems, context: context)
	}

	/// Renew Now on the Apple ID's page: all its apps on this iPhone.
	func renewAll(of account: StoredAppleID) async {
		await renew((account.profiles ?? []).map(\.bundleID))
	}

	/// Once the Apple ID signed in again with a new certificate, as after
	/// Apple revoked the one before: its apps signed with that one get a new
	/// profile, or are signed again when it no longer lists it.
	func renewAfterSignIn(_ account: StoredAppleID) async {
		let others = (account.profiles ?? []).filter(account.isSignedWithAnother).map(\.bundleID)
		guard !others.isEmpty else { return }
		await renew(others)
	}

	/// Whether Renew Now can renew the app: installed with an Apple ID,
	/// and on this iPhone.
	func canRenew(_ item: LibraryItem) -> Bool {
		item.appleID != nil && item.appProfile != nil && item.presence != .deleted && item.disabled == nil
	}

	/// Whether the app goes in the Library's Renew section: it's due, and
	/// Atelier couldn't renew it by itself, or its profile ended (10
	/// Nov 2026). One Atelier is renewing stays in its section until it's
	/// done.
	func inRenewSection(_ item: LibraryItem, now: Date = .now) -> Bool {
		// Atelier itself, from its first day, until the free Apple ID that
		// installed it signs in (#152, decided 11 Nov 2026).
		if item.needsAppleID != nil { return true }
		guard canRenew(item), let account = item.appleID, let profile = item.appProfile else { return false }
		guard AppProfileRenewal.isDue(profile, isFree: account.isFree, isOwn: item.isOwn, now: now) || profile.expires <= now else { return false }
		return problems[item.install.bundleID] != nil || profile.expires <= now
	}

	/// When Atelier renews the app by itself: two days before its profile
	/// ends, four for Atelier's own (`isOwn`, #152), or once its App ID
	/// ended, when it waits for that.
	nonisolated static func date(toRenew profile: AppProfile, of account: StoredAppleID, isOwn: Bool = false) -> Date {
		max(AppProfileRenewal.date(toRenew: profile, isFree: account.isFree, isOwn: isOwn), profile.waitsUntil ?? .distantPast)
	}

	/// The Apple IDs, the one Atelier itself is an app of first (#152): its
	/// own profile renews before any other app's.
	private func accountsInOrder() -> [StoredAppleID] {
		let all = CertificatesModel.shared.appleIDs
		guard let own = SelfUpdate.shared.appleID(in: .shared)?.id else { return all }
		return all.filter { $0.id == own } + all.filter { $0.id != own }
	}

	/// The bundle ID Atelier runs as, when it's one of `account`'s apps.
	private func ownBundleID(of account: StoredAppleID) -> String? {
		let own = SelfUpdate.shared
		return own.appleID(in: .shared)?.id == account.id ? own.bundleID : nil
	}

	/// Once the Library is left, its rows no longer say Renewed.
	func forgetRecent() {
		recentlyRenewed = []
	}

	/// What a Renew Now would do now, for its button.
	func isRenewing(_ bundleID: String) -> Bool {
		renewing.contains(bundleID)
	}

	private func waitForTurn() async {
		while isBusy || InstallModel.shared.isRunning, !Task.isCancelled {
			try? await Task.sleep(for: .milliseconds(500))
		}
	}

	// MARK: Which

	/// An app of the Apple ID's to renew.
	private struct Target {
		let record: InstallRecord
		let profile: AppProfile
		var bundleID: String { profile.bundleID }
		var name: String { record.name }
		/// Atelier itself (#152).
		@MainActor var isOwn: Bool { profile.bundleID == SelfUpdate.shared.bundleID }
	}

	/// The Apple ID's apps among `bundleIDs` that Atelier installed with it
	/// and are still here: not deleted from the Home Screen or offloaded.
	/// Atelier itself comes first (#152), then the one whose profile ends
	/// first.
	private func apps(of account: StoredAppleID, in bundleIDs: Set<String>, context: ModelContext) -> [Target] {
		let own = SelfUpdate.shared.bundleID
		return (account.profiles ?? [])
			.filter { bundleIDs.contains($0.bundleID) }
			.sorted { first, second in
				let isOwn = first.bundleID == own
				return isOwn != (second.bundleID == own) ? isOwn : first.expires < second.expires
			}
			.compactMap { profile in
				guard let record = InstalledApps.record(profile.bundleID, in: context), record.certificateID == account.id,
				      InstallModel.presence(of: record) != .deleted, InstallModel.shared.disabledApps[profile.bundleID] == nil
				else { return nil }
				return Target(record: record, profile: profile)
			}
	}

	// MARK: How

	private func run(_ targets: [Target], of account: StoredAppleID, trigger: Trigger, context: ModelContext) async {
		let ids = targets.map(\.bundleID)
		renewing.formUnion(ids)
		defer { renewing.subtract(ids) }
		let names = Self.joined(targets.map(\.name))
		AppleIDLog.note("renewal: \(names), \(trigger)")

		if AppProfileRenewal.needsSignIn(account) {
			AppleIDLog.note("renewal: the Apple ID's certificate was revoked or ended, so it has to sign in again")
			mark(targets, .signInAgain)
			return
		}

		// What iOS has: the apps, and their profiles.
		let read: AppsAndProfiles
		do {
			read = try await InstallModel.shared.appsAndProfiles(startingVPN: trigger == .user)
		} catch {
			let message = InstallProblem(error).message
			AppleIDLog.note("renewal: iOS couldn't be reached: \(message)")
			mark(targets, .unreachable(message))
			return
		}
		let listed = Set(read.apps.map(\.bundleID))
		for target in targets where !listed.contains(target.bundleID) {
			// Deleted from the Home Screen since Atelier last looked.
			AppleIDLog.note("renewal: \(target.name) isn't on this \(ThisDevice.name), so it's left")
			problems[target.bundleID] = nil
		}
		var here = targets.filter { listed.contains($0.bundleID) }
		guard !here.isEmpty else { return }
		let installed = read.profiles.compactMap { try? ProvisioningProfile(data: $0) }
		here = here.map { $0.isOwn ? ownTarget($0, of: account, installed: installed) : $0 }

		let session: AppleIDSession
		do {
			if trigger != .user, !AppleIDAccess.shared.hasSession(for: account) { lastSignIn[account.id] = .now }
			let purpose = trigger == .user ? "To renew \(Self.joined(here.map(\.name))), Apple wants a code." : nil
			session = try await AppleIDAccess.shared.session(for: account, purpose: purpose)
		} catch AppleIDAccess.Failure.codeNeeded {
			AppleIDLog.note("renewal: Apple wants a code, with nobody to ask")
			Self.codeNeeded.insert(account.id)
			mark(here, .codeNeeded)
			return
		} catch AppleIDAccess.Failure.cancelled {
			AppleIDLog.note("renewal: cancelled")
			return
		} catch AppleIDAccess.Failure.failed(let message) {
			AppleIDLog.note("renewal: signing in failed: \(message)")
			mark(here, .failed(message))
			return
		} catch {
			mark(here, .failed(InstallProblem(error).message))
			return
		}
		Self.codeNeeded.remove(account.id)

		// Which App IDs the team still has: one that ended is added again,
		// taking one of the week's 10.
		var appIDs: AppleIDAppIDList?
		if account.isFree {
			do {
				let list = try await session.appIDs()
				appIDs = list
				CertificatesModel.shared.updateAppleID(account.id) { stored in
					var limits = stored.limits ?? AppleIDLimits()
					limits.appIDs = list.limits(checkedAt: .now)
					stored.limits = limits
				}
			} catch {
				AppleIDLog.note("renewal: Apple didn't list the App IDs: \(error)")
			}
		}

		var toSignAgain: [Target] = []
		for target in here {
			guard !Task.isCancelled else { break }
			if let appIDs {
				switch AppleIDRoom.appID(for: target.bundleID, in: appIDs) {
				case .has(let expires):
					AppleIDLog.note("renewal: \(target.name)'s App ID is there\(expires.map { " until \(Self.logDate($0))" } ?? "")")
				case .adds(let left):
					AppleIDLog.note("renewal: \(target.name)'s App ID ended, so Apple adds it again\(left.map { ", \($0) left" } ?? "")")
				case .noneLeft(let next):
					AppleIDLog.note("renewal: \(target.name)'s App ID ended, and none are left\(next.map { " until \(Self.logDate($0))" } ?? "")")
					problems[target.bundleID] = .noAppIDLeft(until: next)
					continue
				}
			}
			switch await renew(target, of: account, session: session, installed: installed) {
			case .newProfile:
				problems[target.bundleID] = nil
				recentlyRenewed.insert(target.bundleID)
			case .signAgain:
				toSignAgain.append(target)
			case .signInAgain:
				problems[target.bundleID] = .signInAgain
			case nil:
				break
			}
		}
		if !toSignAgain.isEmpty { await signAgain(toSignAgain, of: account, trigger: trigger, context: context) }
	}

	/// Gets the app a new profile and, when it lists the certificate the
	/// app was signed with, puts it on in place of the old one. Returns
	/// how the app renews, nil when it failed, its problem noted.
	private func renew(_ target: Target, of account: StoredAppleID, session: AppleIDSession, installed: [ProvisioningProfile]) async -> AppProfileRenewal.Way? {
		let started = Date.now
		let profile: AppleIDSession.Profile
		let parsed: ProvisioningProfile
		// The App Groups the app was signed with, which an App ID Apple added
		// again has to get back for the new profile to allow them (#49).
		let groups = target.profile.appGroups ?? []
		do {
			profile = try await session.profile(bundleID: target.bundleID, name: target.name, groups: groups)
			parsed = try ProvisioningProfile(data: profile.data)
		} catch {
			AppleIDLog.note("renewal: Apple didn't give \(target.name) a profile: \(error)")
			problems[target.bundleID] = .failed(AppleIDRoute.explain(error, "Apple didn't give \(target.name) a profile"))
			return nil
		}
		if profile.added {
			CertificatesModel.shared.updateAppleID(account.id) { stored in
				var limits = stored.limits ?? AppleIDLimits()
				let counts = limits.appIDs ?? AppleIDLimits.AppIDs(checkedAt: .now, max: profile.max, available: profile.available, expiries: [])
				limits.appIDs = counts.adding(expires: profile.appIDExpires, available: profile.available, max: profile.max, identifier: target.bundleID, name: target.name)
				stored.limits = limits
			}
		}
		if !groups.isEmpty {
			let allowed = (try? ProvisioningProfile.entitlements(in: profile.data)) ?? [:]
			let missing = AppProfileRenewal.missingGroups(of: target.profile, allowedBy: allowed)
			guard missing.isEmpty else {
				// Its old profile stays on, so it opens until that one ends.
				AppleIDLog.note("renewal: \(target.name)'s new profile doesn't allow its App Groups \(missing.joined(separator: ", "))\(profile.groupsError.map { ": \($0)" } ?? "")")
				problems[target.bundleID] = .failed("Apple didn't give \(target.name)'s App ID its App Groups again. Try again later.")
				return nil
			}
			if !profile.groupsAdded.isEmpty {
				AppleIDLog.note("renewal: \(target.name)'s App Groups added to the team again: \(profile.groupsAdded.joined(separator: ", "))")
			}
		}
		let way = AppProfileRenewal.way(for: target.profile, account: account, new: parsed, installed: installed)
		guard way == .newProfile else {
			AppleIDLog.note("renewal: \(target.name)'s new profile doesn't list the certificate it was signed with")
			return way
		}
		let replaced = AppProfileRenewal.replaced(by: parsed, among: installed)
		let removed: [String]
		do {
			removed = try await InstallModel.shared.installProfile(profile.data, replacing: replaced)
		} catch {
			let message = InstallProblem(error).message
			AppleIDLog.note("renewal: iOS didn't take \(target.name)'s new profile: \(message)")
			problems[target.bundleID] = .failed(message)
			return nil
		}
		let expires = profile.expires ?? parsed.expirationDate
		CertificatesModel.shared.updateAppleID(account.id) { stored in
			stored.note(stored.renewed(target.bundleID, uuid: profile.uuid ?? parsed.uuid, expires: expires, appIDEnds: profile.appIDExpires))
		}
		AppleIDLog.note(String(
			format: "renewal: %@ renewed in %.1f s, until %@, its App ID until %@, %d old profile%@ taken off",
			target.name, Date.now.timeIntervalSince(started), Self.logDate(expires), profile.appIDExpires.map(Self.logDate) ?? "?", removed.count, removed.count == 1 ? "" : "s"
		))
		if !AppProfileRenewal.extends(target.profile, to: expires) {
			AppleIDLog.note("renewal: \(target.name)'s new profile ends no later than the one before, so Atelier waits for its App ID to end")
		}
		return .newProfile
	}

	/// Atelier's own profile as iOS has it (#152): another tool may have
	/// put a later one on than the build or the last renewal says, as
	/// AltStore's refresh does, which only the iPhone's list tells.
	private func ownTarget(_ target: Target, of account: StoredAppleID, installed: [ProvisioningProfile]) -> Target {
		let appID = "\(account.team.id).\(target.bundleID)"
		guard let later = OwnAppleID.later(than: target.profile, applicationIdentifier: appID, among: installed) else { return target }
		AppleIDLog.note("renewal: iOS has a later profile for \(target.name) than noted, until \(Self.logDate(later.expires))")
		CertificatesModel.shared.updateAppleID(account.id) { $0.note(later) }
		return Target(record: target.record, profile: later)
	}

	/// Signs the apps again with the Apple ID's certificate and reinstalls
	/// them, keeping their data, from their source or their IPA's link: in
	/// the background only with automatic updates on, which installs
	/// already. Atelier itself only with Renew (#152), as installing over
	/// itself closes it.
	private func signAgain(_ targets: [Target], of account: StoredAppleID, trigger: Trigger, context: ModelContext) async {
		var targets = targets
		if trigger != .user {
			mark(targets.filter { $0.isOwn }, .signAgain)
			targets.removeAll { $0.isOwn }
		}
		guard !targets.isEmpty else { return }
		guard trigger == .user || AutoUpdates.isOn else {
			mark(targets, .signAgain)
			return
		}
		let records = (try? context.fetch(FetchDescriptor<SourceRecord>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
		let catalog = await CatalogModel.build(from: records)
		let installer = InstallModel.shared
		for target in targets {
			let source = installer.resignSource(of: target.record, in: catalog)
			// An IPA the user may have to point to waits for them.
			guard let source, trigger == .user || !Self.isIPA(source) else {
				AppleIDLog.note("renewal: \(target.name) has to be signed again, which waits for Renew")
				problems[target.bundleID] = .signAgain
				continue
			}
			AppleIDLog.note("renewal: signing \(target.name) again, keeping its data")
			installer.resign(target.record, with: account.id, deletingFirst: false, in: catalog, downloads: BackgroundDownloads.shared.manager, certificates: .shared, into: context)
			// Atelier asks first, as it closes to install over itself (#152):
			// its next launch tells whether it did.
			if !target.isOwn { problems[target.bundleID] = nil }
		}
	}

	private static func isIPA(_ source: InstallModel.ResignSource) -> Bool {
		if case .ipa = source { return true }
		return false
	}

	// MARK: Test Actions

	/// End an App's Profile in Test Actions: takes the app's profiles off
	/// this iPhone, so it stops opening as it does once its profile ended,
	/// and notes its profile as ended, so the Library says so and Atelier
	/// renews it as it comes back to the front. Connects LocalDevVPN first
	/// when it's off. Returns why it couldn't, nil when it did.
	func endProfileForTest(_ bundleID: String) async -> String? {
		guard let account = CertificatesModel.shared.appleIDs.first(where: { $0.profile(for: bundleID) != nil }),
		      let profile = account.profile(for: bundleID)
		else { return "Atelier has no profile noted for this app." }
		// Kept before its date changes, which would hide it.
		let serial = AppProfileRenewal.signingSerial(of: profile, account: account)
		do {
			let read = try await InstallModel.shared.appsAndProfiles(startingVPN: true)
			let appID = "\(account.team.id).\(bundleID)"
			let uuids = read.profiles.compactMap { try? ProvisioningProfile(data: $0) }.filter { $0.applicationIdentifier == appID }.map(\.uuid)
			let removed = try await InstallModel.shared.removeProfiles(uuids)
			AppleIDLog.note("test: took \(removed.count) of \(uuids.count) profiles off for \(bundleID)")
			guard !removed.isEmpty || uuids.isEmpty else { return "iOS didn't take its profile off." }
		} catch {
			return InstallProblem(error).message
		}
		CertificatesModel.shared.updateAppleID(account.id) { stored in
			stored.note(AppProfile(bundleID: bundleID, uuid: profile.uuid, expires: .now, certificateSerial: serial, renewedAt: profile.renewedAt, appGroups: profile.appGroups))
		}
		problems[bundleID] = nil
		return nil
	}

	/// After an install with the Apple ID: the app has a new profile, and
	/// the certificate it lists.
	func installed(_ bundleID: String) {
		problems[bundleID] = nil
	}

	/// Forgets that Apple wanted a code, once the user signed in.
	func signedIn(_ account: StoredAppleID) {
		Self.codeNeeded.remove(account.id)
	}

	private func mark(_ targets: [Target], _ problem: Problem) {
		for target in targets { problems[target.bundleID] = problem }
	}

	private static var codeNeeded: Set<UUID> {
		get { Set((UserDefaults.standard.stringArray(forKey: codeNeededKey) ?? []).compactMap(UUID.init(uuidString:))) }
		set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: codeNeededKey) }
	}

	/// "30sec, Mosaic and Atlas".
	static func joined(_ names: [String]) -> String {
		guard let last = names.last else { return "" }
		return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
	}

	/// "9 Nov 2026 at 14:39", as the install log says it.
	private static func logDate(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .shortened)
	}
}
