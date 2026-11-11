import AtelierCore
import CertKit
import InstallKit
import SigningKit
import SourceKit
import SwiftData
import SwiftUI

// An Apple ID signed in with (#49), in Settings › Installs › Certificates:
// a row like an imported certificate's, named after the Apple ID, and its
// page, with the team rather than one profile, as each app gets its own.
// The maintainer approved the mockups on 2 Nov 2026.

extension StoredAppleID.Team {
	/// "Personal Team", as Xcode calls a free Apple ID's team, or the
	/// team's name.
	var title: String {
		isFree == true ? "Personal Team" : name ?? id
	}

	/// "Free Apple ID · Personal Team", under the Apple ID.
	var summary: String {
		switch isFree {
		case true?: "Free Apple ID · Personal Team"
		case false?: "Apple Developer Program · \(title)"
		case nil: "Apple ID · \(title)"
		}
	}

	/// "A free Apple ID’s team, A1B2C3D4E5".
	var detail: String {
		switch isFree {
		case true?: "A free Apple ID’s team, \(id)"
		case false?: "Apple Developer Program, \(id)"
		case nil: "Team ID \(id)"
		}
	}

	/// How long an app signed with it opens once Atelier stops renewing its
	/// profile: ", 7 days at most".
	var profileLimit: String {
		switch isFree {
		case true?: ", 7 days at most"
		case false?: ", a year at most"
		case nil: ""
		}
	}
}

extension StoredAppleID {
	/// What Sign Out says it does.
	var signOutNote: String {
		"Atelier deletes your password and the certificate’s key from this \(ThisDevice.name). Apps signed with it open until their profiles run out\(team.profileLimit)."
	}
}

/// The rounded square at the start of an Apple ID's row: a person with a
/// key.
struct AppleIDTile: View {
	var isRevoked = false
	var size: CGFloat = 44

	var body: some View {
		let color = isRevoked ? Color.red : Color.blue
		RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
			.fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .topLeading, endPoint: .bottomTrailing))
			.frame(width: size, height: size)
			.overlay {
				Image(systemName: isRevoked ? "xmark.seal.fill" : "person.badge.key.fill")
					.font(.system(size: size * 0.42, weight: .semibold))
					.foregroundStyle(.white)
			}
			.shadow(color: color.opacity(0.3), radius: size * 0.08, y: size * 0.04)
			.accessibilityHidden(true)
	}
}

struct AppleIDRow: View {
	let account: StoredAppleID
	let isDefault: Bool

	var body: some View {
		let health = CertificateHealth(account)
		HStack(spacing: 12) {
			AppleIDTile(isRevoked: health == .revoked)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 6) {
					Text(account.displayName)
						.font(.headline)
						.lineLimit(1)
					if isDefault {
						Image(systemName: "checkmark.circle.fill")
							.font(.caption)
							.foregroundStyle(.tint)
							.accessibilityLabel("In use")
					}
				}
				Text(account.team.summary)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if health == .revoked {
					Label("Revoked by Apple", systemImage: "xmark.seal.fill")
						.labelStyle(InlineLabelStyle())
						.font(.footnote.weight(.medium))
						.foregroundStyle(.red)
				} else {
					HStack(spacing: 8) {
						ValidityBar(fraction: account.remainingFraction(), color: health.color)
						Text(account.remainingText())
							.font(.caption.weight(.medium))
							.foregroundStyle(health == .valid ? Color.secondary : health.color)
							.fixedSize()
					}
				}
			}
		}
		.padding(.vertical, 4)
	}
}

/// An Apple ID's page: the team, the certificate Atelier made, and Sign
/// Out.
struct AppleIDDetailView: View {
	let accountID: UUID
	@Environment(CertificatesModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var pendingSignOut: StoredAppleID?
	/// Sign Out from the More menu, kept apart so its dialog points at the
	/// menu rather than at the button at the bottom of the form.
	@State private var pendingMenuSignOut: StoredAppleID?

	var body: some View {
		if let account = model.appleIDs.first(where: { $0.id == accountID }) {
			form(account)
				.navigationTitle(account.displayName)
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					Menu("More", systemImage: "ellipsis.circle") {
						if account.id != model.defaultID {
							Button("Use for Installs", systemImage: "checkmark.circle") { model.makeDefault(account.id) }
						}
						Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { pendingMenuSignOut = account }
					}
					.signOutConfirmation(for: $pendingMenuSignOut, model: model) { dismiss() }
				}
		} else {
			ContentUnavailableView("Signed out", systemImage: "person.badge.key")
		}
	}

	private func form(_ account: StoredAppleID) -> some View {
		let dates = Date.FormatStyle.dateTime.day().month().year()
		let health = CertificateHealth(account)
		return Form {
			Section {
				AppleIDHeader(account: account, isDefault: account.id == model.defaultID) {
					model.makeDefault(account.id)
				}
			}

			// Its apps, which it lists when tapped, in a card of their own,
			// then its Status, the same sections as a certificate's page
			// (4 Nov 2026).
			Section {
				SignedAppsRow(signerID: account.id, appleID: account)
			}
			// The apps on this iPhone as iOS lists them now, without Apple.
			.task(id: account.id) { await AppleIDAccess.shared.refreshApps(of: account) }

			AppleIDStatusSection(account: account)

			Section {
				LabeledContent("Team", value: account.team.title)
				LabeledContent("Team ID", value: account.team.id)
				// Moved here from the Free Apple ID Test screen (#49).
				NavigationLink("Apple ID Log") { AppleIDLogView() }
			} header: {
				Text("Apple ID")
			} footer: {
				Text("Your password is in this \(ThisDevice.name)’s Keychain, for renewing your apps every week.")
			}

			Section("Certificate") {
				LabeledContent("Made", value: "On this \(ThisDevice.name), \(account.certificate.notBefore.formatted(dates))")
				LabeledContent("Expires") {
					Text(account.expiresAt, format: dates)
						.foregroundStyle(health == .expired || health == .revoked ? Color.red : health == .valid ? Color.secondary : Color.orange)
				}
			}

			Section {
				Button(role: .destructive) {
					pendingSignOut = account
				} label: {
					Text("Sign Out")
						.frame(maxWidth: .infinity)
				}
				.signOutConfirmation(for: $pendingSignOut, model: model) { dismiss() }
			} footer: {
				Text(account.signOutNote)
			}
		}
	}
}

/// The top of an Apple ID's page: the Apple ID, its team, whether it's in
/// use, or a button to use it, and its certificate's days, as a
/// certificate's page has them (4 Nov 2026). Its apps end sooner,
/// with their own profiles, which Status's Next to expire says.
private struct AppleIDHeader: View {
	let account: StoredAppleID
	let isDefault: Bool
	let use: () -> Void

	var body: some View {
		let health = CertificateHealth(account)
		VStack(spacing: 14) {
			AppleIDTile(isRevoked: health == .revoked, size: 72)
			VStack(spacing: 4) {
				Text(account.displayName)
					.font(.title3.weight(.semibold))
					.multilineTextAlignment(.center)
				Text(account.team.summary)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			// Not an empty row of pills, which would still take its spacing.
			if health != .valid || isDefault {
				HStack(spacing: 6) {
					if health != .valid {
						StatusPill(title: health.title, symbol: health.symbol, color: health.color)
					}
					if isDefault {
						StatusPill(title: "In use for installs", symbol: "checkmark", color: .green)
					}
				}
			}
			if !isDefault {
				Button("Use for Installs", action: use)
					.buttonStyle(.bordered)
					.controlSize(.small)
			}
			if health != .revoked {
				VStack(spacing: 6) {
					ValidityBar(fraction: account.remainingFraction(), color: health.color, height: 8)
					HStack {
						Text(account.remainingText())
							.fontWeight(.semibold)
							.foregroundStyle(health.color)
						Spacer()
						Text(account.expiresAt, format: .dateTime.day().month().year())
							.foregroundStyle(.secondary)
					}
					.font(.footnote)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 8)
	}
}

extension View {
	/// Asks before signing out of an Apple ID.
	func signOutConfirmation(for item: Binding<StoredAppleID?>, model: CertificatesModel, onSignOut: @escaping () -> Void = {}) -> some View {
		confirmationDialog(
			"Sign Out of \(item.wrappedValue?.displayName ?? "the Apple ID")?",
			isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
			titleVisibility: .visible,
			presenting: item.wrappedValue
		) { account in
			Button("Sign Out", role: .destructive) {
				model.signOut(account.id)
				onSignOut()
			}
		} message: { account in
			Text(account.signOutNote)
		}
	}
}

/// An Apple ID's Status (#49), on its page under its apps, as Apple and
/// this iPhone last said: for a free Apple ID, the new apps it can add
/// this week, of 10, which it lists when tapped, and its next app to
/// expire, as its apps' profiles last 7 days. A paid team's last a year,
/// with no limits. Then Developer Mode, which its apps need, and whether
/// Apple revoked its certificate, as a certificate's Status ends (4
/// Nov 2026; it was Limits, as the maintainer approved on 3 Nov). Check Now asks
/// again, which signs in to Apple, so can mean Apple's code: the page
/// doesn't ask Apple by itself, only iOS for its apps, as it opens.
private struct AppleIDStatusSection: View {
	let account: StoredAppleID
	@State private var access = AppleIDAccess.shared
	@Environment(CertificatesModel.self) private var model
	@Query private var installs: [InstallRecord]
	/// For the apps' names; not there over the welcome, whose Get Ready
	/// opens Certificates.
	@Environment(CatalogModel.self) private var catalog: CatalogModel?

	/// Which apps are disabled; not from the environment, which a page
	/// opened from a sheet may not have.
	private var installer: InstallModel { .shared }

	@ViewBuilder
	var body: some View {
		if account.isFree {
			freeSection(account.limits)
		} else {
			// Its apps' profiles last a year: a paid team has no limits.
			Section {
				expiryRow
				lastRenewedRow
				developerModeRow
				revocationRow
				renewRow
				Button("Check Now", systemImage: "arrow.clockwise") {
					Task { await model.check(account.id) }
				}
				.disabled(model.checking.contains(account.id))
			} header: {
				Text("Status")
			} footer: {
				Text("No limit on apps on this \(ThisDevice.name), or on new apps a week.")
			}
		}
	}

	private func freeSection(_ limits: AppleIDLimits?) -> some View {
		Section {
			appIDsRow(limits?.appIDs)
			expiryRow
			lastRenewedRow
			developerModeRow
			revocationRow
			if let failure = access.checkFailures[account.id] {
				Label(failure, systemImage: "exclamationmark.triangle.fill")
					.font(.footnote)
					.foregroundStyle(.orange)
			}
			renewRow
			if access.checking.contains(account.id) {
				HStack(spacing: 10) {
					ProgressView()
					Text("Checking…")
						.foregroundStyle(.secondary)
				}
			} else {
				Button("Check Now", systemImage: "arrow.clockwise") {
					// Its certificate too, as a certificate's Check Now asks.
					Task { await model.check(account.id) }
					Task { await access.checkLimits(of: account) }
				}
			}
		} header: {
			Text("Status")
		} footer: {
			Text(footer(limits))
		}
	}

	/// Apps signed with an Apple ID are signed for development, so only
	/// open with Developer Mode on, as a development certificate's.
	private var developerModeRow: some View {
		DeveloperModeRow(setting: .init(RouteASetup.shared.developerMode), signedWith: "an Apple ID")
	}

	private var revocationRow: some View {
		RevocationRow(
			revocation: account.revocation,
			checking: model.checking.contains(account.id),
			revokedNote: "Apps signed with it won’t open until they’re signed again. Sign in with the Apple ID again, and Atelier makes a new one."
		)
	}

	/// The new apps allowed this week that are left, and when the next
	/// comes back, with the apps that have the rest, which it lists when
	/// tapped (3 Nov 2026).
	@ViewBuilder
	private func appIDsRow(_ appIDs: AppleIDLimits.AppIDs?) -> some View {
		if let appIDs, let left = appIDs.left() {
			let max = appIDs.max ?? FreeAppleID.appIDsPerWeek
			let held = appIDs.current()
			let row = LimitRow(
				title: "New apps allowed this week",
				value: "\(left) of \(max) left",
				slots: (max, max - left),
				note: appIDsNote(appIDs, held: held, left: left, max: max),
				full: left == 0
			)
			if let held, !held.isEmpty {
				NavigationLink {
					AppleIDAppIDsView(accountID: account.id)
				} label: {
					row
				}
			} else {
				row
			}
		} else {
			LimitRow(title: "New apps allowed this week", value: "Not checked yet")
		}
	}

	/// "Atlas, 30sec, Scanner and 3 more have the other 6, and install
	/// again without a new one. The next one comes back on Mon 9 Nov."
	private func appIDsNote(_ appIDs: AppleIDLimits.AppIDs, held: [AppleIDAppIDList.Entry]?, left: Int, max: Int) -> String? {
		var notes: [String] = []
		if let held {
			let names = held
				.map { AppIDApp($0, account: account, installs: installs, catalog: catalog?.catalog) }
				.filter(\.canReuse)
				.map(\.name)
			if !names.isEmpty {
				let who = Self.firstNames(names)
				let verbs = names.count == 1 ? (has: "has", installs: "installs") : (has: "have", installs: "install")
				// "The other 6" only when they're all of them.
				if names.count == held.count, held.count == max - left {
					let other = held.count == 1 ? "the other one" : "the other \(held.count)"
					notes.append("\(who) \(verbs.has) \(other), and \(verbs.installs) again without a new one.")
				} else {
					notes.append("\(who) \(verbs.installs) again without a new one.")
				}
			}
		} else if left < max {
			// Kept by a build before Atelier kept the App IDs themselves.
			notes.append("Check Now to see which apps have the other \(max - left).")
		}
		if let date = appIDs.nextReturn() {
			notes.append(left == 0
				? "The next one comes back on \(AppProfileDays.describe(date)). Updates still install."
				: "The next one comes back on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).")
		}
		return notes.isEmpty ? nil : notes.joined(separator: " ")
	}

	/// The Apple ID's apps on this iPhone, with their profiles: offloaded
	/// and deleted apps are left out, as nothing of them on this iPhone
	/// stops opening.
	private var running: [(name: String, profile: AppProfile)] {
		(account.profiles ?? []).compactMap { profile -> (name: String, profile: AppProfile)? in
			guard let install = installs.first(where: { $0.bundleID == profile.bundleID }),
			      InstallModel.presence(of: install) != .deleted,
			      installer.disabledApps[install.bundleID] == nil
			else { return nil }
			return (install.name, profile)
		}
	}

	/// Next to expire, in place of Profiles, which always said 7 days each
	/// (5 Nov 2026: obscure): the days left of the app on this iPhone
	/// whose profile ends first, as the Library says them, its name and day,
	/// then when Atelier renews it, as the 5 Nov mockup promised (#49). Red
	/// once one has ended.
	private var expiryRow: some View {
		let title = "Next to expire"
		guard let first = running.min(by: { $0.profile.expires < $1.profile.expires }) else {
			let note = account.isFree
				? "Each app’s profile lasts 7 days, and Atelier renews it 2 days before it ends, so it keeps opening."
				: "Each app’s profile lasts a year, and Atelier renews it 2 weeks before it ends, so it keeps opening."
			return LimitRow(title: title, value: "None", note: note)
		}
		let expires = first.profile.expires
		let day = account.isFree
			? expires.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
			: expires.formatted(.dateTime.day().month(.abbreviated).year())
		let signIn = AppProfileRenewal.needsSignIn(account)
		guard AppProfileDays.days(until: expires) > 0 else {
			let until = signIn ? "until you sign in with this Apple ID again" : "until it’s renewed. Renew Now renews it"
			return LimitRow(title: title, value: "Expired", note: "\(first.name) stopped opening on \(day), \(until).", tint: .red)
		}
		let renews = ProfileRenewals.date(toRenew: first.profile, of: account)
		let renewal = if signIn {
			"It renews once you sign in with this Apple ID again."
		} else if renews > .now {
			"Atelier renews it \(AppProfileDays.day(renews)), so it keeps opening."
		} else {
			"Atelier renews it while LocalDevVPN is connected, so it keeps opening."
		}
		return LimitRow(title: title, value: AppProfileDays.text(until: expires), note: "\(first.name), on \(day). \(renewal)")
	}

	/// Last renewed (#49): when Atelier last put a new profile on one of
	/// its apps, and which it renewed then, without reinstalling. None
	/// before the first.
	@ViewBuilder
	private var lastRenewedRow: some View {
		let renewed = running.compactMap { app in app.profile.renewedAt.map { (name: app.name, at: $0) } }
		if let last = renewed.map(\.at).max() {
			// Those of the same round, a few minutes apart at most.
			let names = renewed.filter { last.timeIntervalSince($0.at) < 10 * 60 }.sorted { $0.at < $1.at }.map(\.name)
			LimitRow(title: "Last renewed", value: Self.renewedAt(last), note: "\(Self.joined(names)), without reinstalling.")
		}
	}

	/// Renew Now (#49): all its apps on this iPhone, whether or not they're
	/// due, connecting LocalDevVPN first, and asking for Apple's code when
	/// Apple wants it. Renewing… while any of them renews.
	@ViewBuilder
	private var renewRow: some View {
		let apps = running
		if !apps.isEmpty {
			let renewals = ProfileRenewals.shared
			if apps.contains(where: { renewals.isRenewing($0.profile.bundleID) }) {
				HStack(spacing: 10) {
					ProgressView()
					Text("Renewing…")
						.foregroundStyle(.secondary)
				}
			} else {
				Button("Renew Now", systemImage: "arrow.triangle.2.circlepath") {
					Task { await renewals.renewAll(of: account) }
				}
				// It has to sign in again first, which Revocation says.
				.disabled(AppProfileRenewal.needsSignIn(account))
			}
		}
	}

	/// "Today, 09:21", "Yesterday, 09:21", "Sun 8 Nov, 09:21".
	private static func renewedAt(_ date: Date) -> String {
		let time = date.formatted(date: .omitted, time: .shortened)
		let calendar = Calendar.current
		if calendar.isDateInToday(date) { return "Today, \(time)" }
		if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
		return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
	}

	/// "As Apple and this iPhone said at 14:40. Each app’s first install
	/// takes one of the 10, and so does renewing it once its App ID has
	/// ended, 7 days after Apple added it. Updates don’t." Apple ends each
	/// App ID 7 days after it added it, whatever the app (a Check Now,
	/// 9 Nov 2026).
	private func footer(_ limits: AppleIDLimits?) -> String {
		// More free Apple IDs, more new apps a week; the 3 places on this
		// iPhone stay 3 whichever signs (4 Nov 2026).
		let rule = "Each app’s first install takes one of the \(FreeAppleID.appIDsPerWeek), and so does renewing it once its App ID has ended, 7 days after Apple added it. Updates don’t. Another free Apple ID has \(FreeAppleID.appIDsPerWeek) of its own, for more new apps a week."
		let apps = limits?.apps?.checkedAt
		let appIDs = limits?.appIDs?.checkedAt
		let said: String? = switch (apps, appIDs) {
		case let (apps?, appIDs?) where abs(apps.timeIntervalSince(appIDs)) < 60:
			"As Apple and this \(ThisDevice.name) said \(Self.when(max(apps, appIDs)))."
		case let (apps?, appIDs?):
			"As this \(ThisDevice.name) said \(Self.when(apps)), and Apple \(Self.when(appIDs))."
		case let (apps?, nil):
			"As this \(ThisDevice.name) said \(Self.when(apps))."
		case let (nil, appIDs?):
			"As Apple said \(Self.when(appIDs))."
		case (nil, nil):
			"Atelier asks at each install with it. Check Now signs in to ask, which can mean Apple’s code."
		}
		return [said, rule].compactMap { $0 }.joined(separator: " ")
	}

	/// "at 14:40", or "on Mon 2 Nov at 14:40" before today.
	fileprivate static func when(_ date: Date) -> String {
		let time = date.formatted(date: .omitted, time: .shortened)
		guard !Calendar.current.isDateInToday(date) else { return "at \(time)" }
		return "on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
	}

	/// "30sec, Mosaic and SideStore".
	private static func joined(_ names: [String]) -> String {
		guard let last = names.last else { return "" }
		guard names.count > 1 else { return last }
		return names.dropLast().joined(separator: ", ") + " and " + last
	}

	/// "Atlas, 30sec, Scanner and 3 more": the first 3, and how many more.
	private static func firstNames(_ names: [String]) -> String {
		names.count <= 4 ? joined(names) : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
	}
}

/// One of an Apple ID's App IDs as its pages show it (#49): the app it's
/// for, as the Library or a source knows it.
private struct AppIDApp {
	let entry: AppleIDAppIDList.Entry
	/// The app's own bundle ID; nil for an App ID that Atelier never signs
	/// an app as, such as one Xcode made, and for a copy's.
	let appBundleID: String?
	/// Its install in the Library, signed as the App ID with this Apple ID:
	/// a copy's too, whose App ID has its number or the name chosen for it
	/// after the team ID (#113).
	let install: InstallRecord?
	/// The app as a source lists it.
	let listing: Catalog.Entry?
	/// For a copy Atelier installed with the Apple ID, "com.example.app.
	/// A1B2C3D4E5.atelier2", the name of the app it's a copy of, rather
	/// than another app's App ID (10 Nov 2026).
	let copyOf: String?

	var id: String { entry.identifier }
	/// Whether it installs again without a new App ID.
	var canReuse: Bool { install != nil || appBundleID != nil }
	var name: String { install?.name ?? listing?.app.name ?? entry.name ?? appBundleID ?? entry.identifier }

	init(_ entry: AppleIDAppIDList.Entry, account: StoredAppleID, installs: [InstallRecord], catalog: Catalog?) {
		self.entry = entry
		install = installs.first { $0.certificateID == account.id && $0.bundleID.caseInsensitiveCompare(entry.identifier) == .orderedSame }
		let appBundleID = account.appBundleID(forAppID: entry.identifier)
		self.appBundleID = appBundleID
		// A numbered copy has the team ID before its number (#8).
		let parts = InstallTarget.split(entry.identifier)
		if case .copy = parts.target, let own = account.appBundleID(forAppID: parts.original) {
			copyOf = installs.first { $0.ipaBundleID.caseInsensitiveCompare(own) == .orderedSame }?.name
				?? catalog?.entries.first { $0.bundleID.caseInsensitiveCompare(own) == .orderedSame }?.app.name
				?? (own == SelfUpdate.sourceBundleID ? "Atelier" : own)
		} else {
			copyOf = nil
		}
		guard let appBundleID else {
			listing = nil
			return
		}
		// An app whose own bundle ID ends with the team ID is listed under
		// that.
		listing = catalog?.entries.first { $0.bundleID.caseInsensitiveCompare(appBundleID) == .orderedSame }
			?? catalog?.entries.first { $0.bundleID.caseInsensitiveCompare(entry.identifier) == .orderedSame }
	}
}

/// The apps with one of an Apple ID's App IDs now (#49), from New apps
/// this week on its page, the one whose App ID ends soonest first. Until
/// it ends, each installs again, updates and enables without taking one of
/// the week's 10. Tapping one opens its page over the list, as the Library
/// has it when it's there, else as its source lists it, to install it
/// from. The maintainer approved the mockup on 3 Nov 2026.
struct AppleIDAppIDsView: View {
	let accountID: UUID
	@Environment(CertificatesModel.self) private var certificates
	/// For the apps' names, icons and pages; not there over the welcome.
	@Environment(CatalogModel.self) private var catalog: CatalogModel?
	@Environment(\.modelContext) private var context
	@Query private var installs: [InstallRecord]

	/// Which apps are disabled; not from the environment, as for the
	/// Status section.
	private var installer: InstallModel { .shared }

	var body: some View {
		if let account = certificates.appleIDs.first(where: { $0.id == accountID }) {
			form(account)
				.navigationTitle("New Apps Allowed This Week")
				.navigationBarTitleDisplayMode(.inline)
		} else {
			ContentUnavailableView("Signed out", systemImage: "person.badge.key")
		}
	}

	private func form(_ account: StoredAppleID) -> some View {
		let appIDs = account.limits?.appIDs
		let apps = (appIDs?.current() ?? []).map { AppIDApp($0, account: account, installs: installs, catalog: catalog?.catalog) }
		let reusable = apps.filter(\.canReuse)
		let others = apps.filter { !$0.canReuse }
		return Form {
			if let appIDs, let left = appIDs.left() {
				let max = appIDs.max ?? FreeAppleID.appIDsPerWeek
				Section {
					LimitRow(
						title: "Left this week",
						value: "\(left) of \(max)",
						slots: (max, max - left),
						note: appIDs.nextReturn().map { "The next one comes back on \(AppProfileDays.describe($0))." },
						full: left == 0
					)
				}
			}
			if !reusable.isEmpty {
				Section {
					ForEach(reusable, id: \.id) { app in
						row(app)
					}
				} header: {
					Text("Installs again without a new one · \(reusable.count)")
				} footer: {
					Text(footer(appIDs))
				}
			}
			if !others.isEmpty {
				Section {
					ForEach(others, id: \.id) { app in
						if let original = app.copyOf {
							AppIDRow(name: app.name, detail: until(app.entry, "A copy of \(original), deleted"))
						} else {
							AppIDRow(name: app.name, detail: until(app.entry, "Atelier can’t reuse it"), identifier: app.entry.identifier)
						}
					}
				} header: {
					Text("Other App IDs · \(others.count)")
				} footer: {
					Text(others.contains { $0.copyOf != nil }
						? "Copies Atelier installed and has since deleted, and App IDs another app made, such as Xcode. Atelier reuses a copy’s only if it installs that copy again. Apple ends each 7 days after it added it."
						: "Another app made these with this Apple ID, such as Xcode for its own bundle IDs. Atelier signs apps as their bundle ID with the team ID on the end, so it can’t use them.")
				}
			}
			if apps.isEmpty {
				Text(appIDs?.entries == nil ? "Check Now on the Apple ID’s page to list them." : "None this week.")
					.foregroundStyle(.secondary)
			}
		}
	}

	/// The app's row, which opens its page when Atelier has one.
	@ViewBuilder
	private func row(_ app: AppIDApp) -> some View {
		let label = AppIDRow(
			name: app.name,
			detail: until(app.entry, place(app)),
			identifier: app.install == nil && app.listing == nil ? app.appBundleID : nil,
			iconURL: iconURL(app),
			tint: app.listing?.app.tintColor
		)
		if let page = page(app) {
			NavigationLink {
				PushedAppPage(page)
			} label: {
				label
			}
		} else {
			label
		}
	}

	/// Where the app is: on this iPhone, disabled, its source, or not in
	/// your sources.
	private func place(_ app: AppIDApp) -> String {
		if let install = app.install {
			let presence = InstallModel.presence(of: install)
			if installer.disabledApps[install.bundleID] != nil, presence != .installed { return "Offloaded, its data kept" }
			if presence == .installed { return "On this \(ThisDevice.name)" }
		}
		if let listing = app.listing { return listing.preferred.source.name }
		if app.install != nil { return "In the Library" }
		return "Not in your sources: its IPA installs without a new one"
	}

	/// "Atlas Repo · until Mon 9 Nov".
	private func until(_ entry: AppleIDAppIDList.Entry, _ text: String) -> String {
		guard let expires = entry.expires else { return text }
		return "\(text) · until \(expires.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
	}

	/// The icon iOS shows for it, from the IPA Atelier signed, else its
	/// source's.
	private func iconURL(_ app: AppIDApp) -> URL? {
		if let install = app.install {
			return InstalledIcons.shared.url(for: install.bundleID) ?? InstalledApps.iconURL(of: install, in: context) ?? app.listing?.app.iconURL
		}
		return app.listing?.app.iconURL
	}

	/// Its page, as the Library has it when it's there, else as its source
	/// lists it. Over the welcome, with no catalog, none.
	private func page(_ app: AppIDApp) -> PushedAppPage.Page? {
		guard let catalog else { return nil }
		if let install = app.install { return .library(LibraryLink(install, in: catalog.catalog)) }
		if let listing = app.listing { return .listing(AppLink(listing)) }
		return nil
	}

	/// "Tap one to install it again from its page. … As Apple said at
	/// 22:58."
	private func footer(_ appIDs: AppleIDLimits.AppIDs?) -> String {
		var lines = ["Tap one to install it again from its page. Each keeps its App ID for 7 days from its first install with this Apple ID, and Apple doesn’t let one go sooner."]
		if let checked = appIDs?.checkedAt { lines.append("As Apple said \(AppleIDStatusSection.when(checked)).") }
		return lines.joined(separator: " ")
	}
}

/// A row for one of an Apple ID's App IDs: the app's icon and name, where
/// it is and when its App ID ends, and a bundle ID where Atelier has no
/// page for the app.
private struct AppIDRow: View {
	let name: String
	let detail: String
	var identifier: String?
	var iconURL: URL?
	var tint: String?

	var body: some View {
		HStack(spacing: 12) {
			if iconURL != nil || tint != nil {
				SourceIcon(url: iconURL, tint: tint, size: 44)
			} else {
				RoundedRectangle(cornerRadius: 44 * 0.22, style: .continuous)
					.fill(Color.secondary.opacity(0.15))
					.frame(width: 44, height: 44)
					.overlay {
						Image(systemName: "app.dashed")
							.font(.title3)
							.foregroundStyle(.secondary)
					}
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(name)
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
				if let identifier {
					Text(identifier)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
		}
		.padding(.vertical, 2)
		.accessibilityElement(children: .combine)
	}
}
