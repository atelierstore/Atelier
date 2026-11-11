import Foundation
import InstallKit

/// What Get Ready and Status say (#21): each thing Atelier needs to install
/// apps, as a row with a check once it's fine, and as a card with its fix
/// while it isn't. Get Ready shows it on the first launch, and Settings ›
/// Installs › Status any time after. Status was Checkup until 3 Nov 2026.
public struct Checkup: Equatable, Sendable {
	/// Where it shows.
	public enum Place: Sendable {
		/// The first launch's Get Ready page: what to do before installing.
		case getReady
		/// Settings › Installs › Status: everything, checked again.
		case settings
	}

	public enum Kind: String, Sendable {
		case certificate
		/// Whether a certificate can sign Atelier itself, for its own
		/// updates (#24).
		case ownUpdates
		case developerMode
		case sources
		/// Sources kept in private GitHub repos, with no account signed in
		/// (#134).
		case gitHubSignIn
		/// The manifest endpoint iOS reads before each install.
		case installServer
		/// The one-time setup for background installs (#111).
		case setup
	}

	public enum State: Equatable, Sendable {
		/// Fine: a row with a check.
		case ok
		/// Being checked: a row.
		case checking
		/// Worth knowing, but Atelier still installs: a row, such as the
		/// setup with LocalDevVPN off.
		case notice
		/// Nice to have: a card, such as the setup in Get Ready.
		case optional
		/// To do before installing: a card with its fix.
		case todo
		/// Works for now, but needs looking at: a card with its fix.
		case warning
		/// Installs fail, or installed apps won't open: a card with its fix.
		case problem

		/// Shown as a card rather than a row.
		public var isCard: Bool {
			switch self {
			case .ok, .checking, .notice: false
			case .optional, .todo, .warning, .problem: true
			}
		}
	}

	/// A card's buttons.
	public enum Action: Equatable, Sendable {
		case importCertificate
		/// Sign In with Apple ID (#49): Atelier makes a certificate.
		case signInWithAppleID
		case openDeveloperModeSettings
		case confirmDeveloperMode
		case addSource
		case refreshSources
		case signInToGitHub
		case checkInstallServer
		case setUp
	}

	public struct Item: Equatable, Sendable, Identifiable {
		public var kind: Kind
		public var state: State
		/// The row's title, or the card's.
		public var title: String
		/// The row's value, such as the certificate's name.
		public var value: String?
		/// The card's text, or the row's footer.
		public var text: String?
		/// A line under a card's text.
		public var hint: String?
		/// The card's buttons, the first one filled.
		public var actions: [Action]
		/// What Settings' Status row says when this comes first.
		public var summary: String

		public var id: Kind { kind }

		public init(kind: Kind, state: State, title: String, value: String? = nil, text: String? = nil, hint: String? = nil, actions: [Action] = [], summary: String) {
			self.kind = kind
			self.state = state
			self.title = title
			self.value = value
			self.text = text
			self.hint = hint
			self.actions = actions
			self.summary = summary
		}
	}

	public var items: [Item]

	/// What Settings' Status row names: the first problem, else the first
	/// thing to do or look at, else what the setup's check found, such as
	/// LocalDevVPN off. Status comes first in Settings › Installs, so the
	/// Setup row only says Finished (3 Nov 2026). Nil when there's
	/// nothing. A source to add isn't one: apps also install from IPA files.
	public var attention: Item? {
		items.first { $0.state == .problem }
			?? items.first { $0.state == .warning || ($0.state == .todo && $0.kind != .sources) }
			?? items.first { $0.state == .notice }
	}

	/// What Settings' Status row says.
	public var summary: String {
		attention?.summary ?? "All good"
	}
}

/// What Checkup is worked out from, as the app gathers it.
public struct CheckupFacts: Sendable {
	public struct Source: Equatable, Sendable {
		public var name: String
		/// Atelier's own, there from the start (#24): it isn't one the user
		/// added.
		public var isBuiltIn: Bool
		/// Why its last refresh failed; nil when it worked.
		public var refreshError: String?
		/// Kept in a GitHub repo only an account can read, with none
		/// signed in (#134).
		public var needsGitHubSignIn: Bool

		public init(name: String, isBuiltIn: Bool = false, refreshError: String? = nil, needsGitHubSignIn: Bool = false) {
			self.name = name
			self.isBuiltIn = isBuiltIn
			self.refreshError = refreshError
			self.needsGitHubSignIn = needsGitHubSignIn
		}
	}

	public enum Setup: Equatable, Sendable {
		case notSetUp
		/// Set up, and its check is running.
		case checking
		case checked(RouteANetwork.Status)
	}

	/// The certificate in use.
	public var certificate: StoredCertificate?
	/// The Apple ID in use (#49), when it's one rather than a certificate.
	public var appleID: StoredAppleID?
	/// Whether a certificate can sign Atelier for its own App ID (#24); nil
	/// when that can't be told.
	public var canUpdateAtelier: Bool?
	/// The profile Atelier itself was installed with; nil when it can't be
	/// read.
	public var ownProfile: ProvisioningProfile?
	/// This device's UDID, once the setup read it (#9).
	public var deviceUDID: String?
	/// Developer Mode, as the setup read it.
	public var developerModeRead: Bool?
	/// The user said Developer Mode is on.
	public var developerModeConfirmed: Bool
	/// The manifest endpoint's answer; nil while it's being asked.
	public var installServer: ManifestEndpoint.Reachability?
	/// The endpoint's host, to name it.
	public var installServerHost: String
	public var setup: Setup
	public var sources: [Source]
	public var now: Date
	/// "iPhone" or "iPad" (#61).
	public var device: String

	public init(
		certificate: StoredCertificate? = nil,
		appleID: StoredAppleID? = nil,
		canUpdateAtelier: Bool? = nil,
		ownProfile: ProvisioningProfile? = nil,
		deviceUDID: String? = nil,
		developerModeRead: Bool? = nil,
		developerModeConfirmed: Bool = false,
		installServer: ManifestEndpoint.Reachability? = nil,
		installServerHost: String = ManifestEndpoint.defaultURL.host ?? "",
		setup: Setup = .notSetUp,
		sources: [Source] = [],
		now: Date = .now,
		device: String = ThisDevice.name
	) {
		self.certificate = certificate
		self.appleID = appleID
		self.canUpdateAtelier = canUpdateAtelier
		self.ownProfile = ownProfile
		self.deviceUDID = deviceUDID
		self.developerModeRead = developerModeRead
		self.developerModeConfirmed = developerModeConfirmed
		self.installServer = installServer
		self.installServerHost = installServerHost
		self.setup = setup
		self.sources = sources
		self.now = now
		self.device = device
	}
}

extension Checkup {
	/// Each thing in the order `place` shows them: Get Ready ends with what
	/// can wait, Status with how Atelier installs and what it installs
	/// from. Get Ready only mentions the install server when it fails.
	public init(_ facts: CheckupFacts, for place: Place) {
		let certificate = Self.certificate(facts)
		var items = [certificate]
		// A certificate that can't sign at all says so already.
		if certificate.state == .ok || certificate.state == .warning, let own = Self.ownUpdates(facts) {
			items.append(own)
		}
		if let mode = Self.developerMode(facts) { items.append(mode) }
		let sources = [Self.sources(facts), Self.gitHubSignIn(facts)].compactMap { $0 }
		let server = Self.installServer(facts)
		let setup = Self.setup(facts)
		switch place {
		case .getReady:
			items += sources
			if server.state.isCard { items.append(server) }
			items.append(setup)
		case .settings:
			items += [server, setup] + sources
		}
		self.items = items
	}

	/// The certificate in use, or the Apple ID's (#49). Without either, the
	/// card offers both, as the maintainer approved on 2 Nov 2026.
	private static func certificate(_ facts: CheckupFacts) -> Item {
		guard let certificate = facts.certificate else {
			if let account = facts.appleID { return appleID(account, facts) }
			let hint = facts.ownProfile.map { profile in
				profile.teamName.map { "Atelier itself was installed with one from \($0). Import that one, and Atelier can update itself too." }
					?? "Import the certificate Atelier itself was installed with, and it can update itself too."
			}
			return Item(
				kind: .certificate, state: .todo, title: "Your certificate",
				text: "Atelier signs every app with it. Import a .p12 with its profile, or sign in with an Apple ID and Atelier makes one.",
				hint: hint, actions: [.importCertificate, .signInWithAppleID], summary: "No certificate"
			)
		}
		let name = certificate.displayName
		let device = facts.device
		let signAgain = "Apps signed with it won't open until they're signed again with another certificate. Import one, and Atelier offers to re-sign them."
		func problem(_ title: String, _ text: String, summary: String) -> Item {
			Item(kind: .certificate, state: .problem, title: title, text: text, actions: [.importCertificate], summary: summary)
		}

		if case .revoked(let date) = certificate.revocation?.status {
			let when = date.map { " on \(Self.day($0))" } ?? ""
			return problem("Certificate revoked", "Apple revoked \(name)\(when). \(signAgain)", summary: "Certificate revoked")
		}
		let expiry = certificate.expiry
		// The certificate or its profile: people think of them as one.
		if expiry.isExpired(now: facts.now) {
			return problem("Certificate expired", "\(name) expired on \(Self.day(expiry.date)). \(signAgain)", summary: "Certificate expired")
		}
		switch certificate.profile.check(deviceUDID: facts.deviceUDID) {
		case .noDevices:
			return problem("For the App Store only", "\(name) can only sign apps for the App Store and TestFlight, not for this \(device). Import a development, ad hoc or enterprise certificate.", summary: "For the App Store only")
		case .notIncluded:
			return problem("Not registered for this \(device)", "\(name) isn't registered for this \(device), so apps signed with it won't install here. Import one that is.", summary: "Not registered for this \(device)")
		case .included, .unknown, .anyDevice:
			break
		}
		if expiry.warning(now: facts.now) != nil {
			let left = expiry.daysLeft(now: facts.now)
			let when = left == 1 ? "within a day" : "in \(left) days"
			return Item(
				kind: .certificate, state: .warning, title: "Certificate expires soon",
				text: "\(name) expires \(when), on \(Self.day(expiry.date)). Apps signed with it stop opening then. Import a new one, and Atelier offers to re-sign them.",
				actions: [.importCertificate], summary: left == 1 ? "Expires within a day" : "Expires in \(left) days"
			)
		}

		let revocation = switch certificate.revocation?.status {
		case .good?: "not revoked"
		case .unknown?: "unknown to Apple"
		case .revoked?, nil: "not checked with Apple yet"
		}
		let left = expiry.daysLeft(now: facts.now)
		return Item(
			kind: .certificate, state: .ok, title: "Certificate", value: name,
			text: "\(Self.kindName(certificate.profile.kind)), \(revocation), \(left == 1 ? "1 day" : "\(left) days") left. Apple can revoke a certificate at any time, and apps signed with it stop opening. Atelier checks, and tells you if it does.",
			summary: name
		)
	}

	/// The development certificate Atelier made for the Apple ID in use
	/// (#49). Its apps get their own profiles, which the Library and the
	/// Apple ID's page follow, so only the certificate counts here. Apple
	/// lists a revoked or expired one no more, so signing in again makes a
	/// new one; one still listed is found again, so for one running out, the
	/// Apple ID is signed out of first, which takes its key off this device.
	private static func appleID(_ account: StoredAppleID, _ facts: CheckupFacts) -> Item {
		let name = account.displayName
		let device = facts.device
		let signIn = "Apps signed with it won't open until they're signed again. Sign in with the Apple ID again, and Atelier makes a new one."
		func problem(_ title: String, _ text: String, summary: String) -> Item {
			Item(kind: .certificate, state: .problem, title: title, text: text, actions: [.signInWithAppleID], summary: summary)
		}

		if case .revoked(let date) = account.revocation?.status {
			let when = date.map { " on \(Self.day($0))" } ?? ""
			return problem("Certificate revoked", "Apple revoked \(name)'s certificate\(when). \(signIn)", summary: "Certificate revoked")
		}
		let expiry = account.expiry
		if expiry.isExpired(now: facts.now) {
			return problem("Certificate expired", "\(name)'s certificate expired on \(Self.day(expiry.date)). \(signIn)", summary: "Certificate expired")
		}
		if expiry.warning(now: facts.now) != nil {
			let left = expiry.daysLeft(now: facts.now)
			let when = left == 1 ? "within a day" : "in \(left) days"
			return Item(
				kind: .certificate, state: .warning, title: "Certificate expires soon",
				text: "\(name)'s certificate expires \(when), on \(Self.day(expiry.date)), and apps signed with it stop opening then. Sign out of the Apple ID in Certificates and sign in again, and Atelier makes a new one.",
				summary: left == 1 ? "Expires within a day" : "Expires in \(left) days"
			)
		}

		let revocation = switch account.revocation?.status {
		case .good?: "not revoked"
		case .unknown?: "unknown to Apple"
		case .revoked?, nil: "not checked with Apple yet"
		}
		let left = expiry.daysLeft(now: facts.now)
		let days = left == 1 ? "1 day" : "\(left) days"
		let text = account.isFree
			? "A free Apple ID's development certificate, made on this \(device): \(revocation), \(days) left. Its apps install through the setup, \(FreeAppleID.appsPerDevice) at a time on this \(device)."
			: "An Apple ID's development certificate, made on this \(device): \(revocation), \(days) left. Its apps install through the setup."
		return Item(kind: .certificate, state: .ok, title: "Certificate", value: name, text: text, summary: name)
	}

	private static func ownUpdates(_ facts: CheckupFacts) -> Item? {
		guard facts.certificate != nil || facts.appleID != nil, facts.canUpdateAtelier == false else { return nil }
		let which = facts.ownProfile?.teamName.map { "Import the one from \($0) that Atelier was installed with." }
			?? "Import the one Atelier was installed with."
		return Item(
			kind: .ownUpdates, state: .warning, title: "Atelier can't update itself",
			text: "None of your certificates can update Atelier, as it was installed with one from another account. \(which)",
			actions: [.importCertificate], summary: "Can't update Atelier"
		)
	}

	/// Developer Mode can't be read without the setup, but Atelier itself
	/// tells when it was signed for development or ad hoc: iOS wouldn't open
	/// it with Developer Mode off (Apple's rule for development; seen for ad
	/// hoc on iOS 27.0.1, 2026-10-18). Enterprise and App Store certificates
	/// don't need it, and before there's a certificate, it isn't known
	/// whether it's needed.
	private static func developerMode(_ facts: CheckupFacts) -> Item? {
		// An Apple ID's certificate is a development one (#49).
		let kind = facts.certificate?.profile.kind ?? (facts.appleID == nil ? nil : .development)
		if let kind, kind != .development, kind != .adHoc { return nil }
		let signer = { (kind: ProvisioningProfile.Kind) in
			facts.certificate == nil ? "your Apple ID" : "your \(Self.kindName(kind).lowercased()) certificate"
		}
		let title = "Developer Mode"
		let path = "Settings › Privacy & Security › Developer Mode"
		if let own = facts.ownProfile?.kind, own == .development || own == .adHoc {
			return Item(kind: .developerMode, state: .ok, title: title, value: "On", text: "Development and ad hoc apps need it. It's on, or Atelier itself wouldn't open.", summary: "On")
		}
		if let read = facts.developerModeRead {
			if read {
				return Item(kind: .developerMode, state: .ok, title: title, value: "On", text: "Read by the setup.", summary: "On")
			}
			guard let kind else { return nil }
			return Item(
				kind: .developerMode, state: .problem, title: "Developer Mode is off",
				text: "Apps signed with \(signer(kind)) won't open until it's on, in \(path). Your \(facts.device) restarts.",
				actions: [.openDeveloperModeSettings], summary: "Developer Mode off"
			)
		}
		if facts.developerModeConfirmed {
			return Item(kind: .developerMode, state: .ok, title: title, value: "On", text: "You said it's on. Development and ad hoc apps need it.", summary: "On")
		}
		guard let kind else { return nil }
		return Item(
			kind: .developerMode, state: .todo, title: "Turn on Developer Mode",
			text: "Apps signed with \(signer(kind)) only open with it on. It's in \(path), and your \(facts.device) restarts.",
			actions: [.openDeveloperModeSettings, .confirmDeveloperMode], summary: "Check Developer Mode"
		)
	}

	/// The sources the user added; Atelier's own doesn't count.
	private static func sources(_ facts: CheckupFacts) -> Item {
		let added = facts.sources.filter { !$0.isBuiltIn }
		guard let first = added.first else {
			return Item(
				kind: .sources, state: .todo, title: "Add a source",
				text: "An AltStore source's address or a GitHub repo. Its apps show up in Browse, next to Atelier's own.",
				actions: [.addSource], summary: "No sources"
			)
		}
		let failed = facts.sources.filter { $0.refreshError != nil && !$0.needsGitHubSignIn }
		if let unread = failed.first {
			let one = failed.count == 1
			return Item(
				kind: .sources, state: .warning,
				title: one ? "\(unread.name) couldn't be read" : "\(failed.count) sources couldn't be read",
				text: one ? "\(unread.refreshError ?? "") Browse shows its apps as they were." : "Browse shows their apps as they were.",
				actions: [.refreshSources], summary: one ? "Source not read" : "Sources not read"
			)
		}
		let one = added.count == 1
		return Item(kind: .sources, state: .ok, title: one ? "Source" : "Sources", value: one ? first.name : "\(added.count) added", summary: one ? first.name : "\(added.count) added")
	}

	private static func gitHubSignIn(_ facts: CheckupFacts) -> Item? {
		let locked = facts.sources.filter(\.needsGitHubSignIn)
		guard let first = locked.first else { return nil }
		// GitHub only says it can't find a source without an account (#134).
		// Atelier's own repo is public, so its source is never one of them.
		let text = locked.count == 1
			? "GitHub can't find it without an account. If it's in a private repo, sign in with an account that can see it."
			: "GitHub can't find them without an account. If they're in private repos, sign in with an account that can see them."
		return Item(
			kind: .gitHubSignIn, state: .warning,
			title: locked.count == 1 ? "\(first.name) needs a GitHub sign-in" : "\(locked.count) sources need a GitHub sign-in",
			text: text, actions: [.signInToGitHub], summary: "GitHub sign-in needed"
		)
	}

	private static func installServer(_ facts: CheckupFacts) -> Item {
		let title = "Install server"
		switch facts.installServer {
		case nil:
			return Item(kind: .installServer, state: .checking, title: title, value: "Checking…", summary: "Checking…")
		case .reachable?:
			return Item(kind: .installServer, state: .ok, title: title, value: "Answers", summary: "Answers")
		case .unexpected?:
			return Item(
				kind: .installServer, state: .warning, title: "The install server didn't answer",
				text: "Installs through the iOS alert go through \(facts.installServerHost), and it answered with an error. Try again later. If you use your own server, check it in Settings › Installs › Advanced.",
				actions: [.checkInstallServer], summary: "Install server failed"
			)
		case .unreachable?:
			return Item(
				kind: .installServer, state: .warning, title: "The install server didn't answer",
				text: "Installs through the iOS alert go through \(facts.installServerHost). Check your connection, then try again.",
				actions: [.checkInstallServer], summary: "Install server failed"
			)
		}
	}

	/// Status names what the check found, as the Setup row only says
	/// Finished; the setup's page says the rest. With an Apple ID in use,
	/// it's a to-do rather than optional, as its apps only install through
	/// it (#49).
	private static func setup(_ facts: CheckupFacts) -> Item {
		let title = "Setup"
		switch facts.setup {
		case .notSetUp where facts.appleID != nil:
			return Item(
				kind: .setup, state: .todo, title: title,
				text: "Apps signed with an Apple ID only install once this one-time setup is done.",
				actions: [.setUp], summary: "Not set up"
			)
		case .notSetUp:
			return Item(kind: .setup, state: .optional, title: title, actions: [.setUp], summary: "Not set up")
		case .checking:
			return Item(kind: .setup, state: .checking, title: title, value: "Checking…", summary: "Checking…")
		case .checked(.ready):
			return Item(kind: .setup, state: .ok, title: title, value: "Finished", summary: "Finished")
		case .checked(.vpnOff):
			return Item(kind: .setup, state: .notice, title: title, value: "LocalDevVPN off", summary: "LocalDevVPN off")
		case .checked(.noWiFi):
			return Item(kind: .setup, state: .notice, title: title, value: "No Wi-Fi", summary: "No Wi-Fi")
		case .checked(.unreachable):
			return Item(kind: .setup, state: .notice, title: title, value: "Check failed", summary: "Check failed")
		}
	}

	static func kindName(_ kind: ProvisioningProfile.Kind) -> String {
		switch kind {
		case .development: "Development"
		case .adHoc: "Ad hoc"
		case .enterprise: "Enterprise"
		case .appStore: "App Store"
		}
	}

	private static func day(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .omitted)
	}
}
