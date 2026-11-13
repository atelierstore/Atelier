import AppleIDKit
import CertKit
import Foundation
import InstallKit
import Observation

/// Sign In with Apple ID (#49), the sheet Certificates' + opens: a free
/// Apple ID or a paid one, which Atelier tells apart by the team. It signs
/// in through the anisette servers Atelier's worker lists, one at a time
/// and silently (`AnisetteRoute`), or only through the user's own; asks
/// which team when Apple lists more than one; registers this iPhone with
/// the UDID the setup read; then finds this iPhone's development
/// certificate, the one whose key it kept or the one the iPhone-only
/// installer handed over (#152), else has Apple make one. At Apple's limit
/// it lists the team's certificates and asks which one to revoke, never
/// revoking one by itself. The Apple ID, Apple's
/// token from the sign-in (#182) and the certificate are then kept with the
/// certificates (`CertificateStore.saveAppleID`), in use if nothing else
/// is.
///
/// When the installer also handed over its sign-in, Atelier signs in with
/// it by itself as it first opens (`CertificatesModel.signInAsInstaller`),
/// out of sight, as the same machine to Apple and in the same team. The
/// sheet comes up, filled in, once it has something to show: Apple's code,
/// a choice, or why it stopped. Once it's signed in, it doesn't, unless
/// another certificate is in use: Get Ready and the Apple ID's page say so
/// (13 Nov 2026). The installer's version 2
/// hands over Apple's token from its sign-in in place of the password
/// (#182): Atelier signs in with that, unless Apple refuses it, when the
/// sheet asks for the password. New Certificate signs in with the Apple
/// ID's own token first too.
///
/// Atelier keeps no passwords (token only, 13 Nov 2026): a sign-in with
/// one keeps Apple's token from it instead. Once that has expired, Sign In
/// Again on the Apple ID's page asks for the password.
///
/// Installing with it comes with the install PR, and renewing its apps'
/// profiles every week with the one after.
@MainActor
@Observable
final class AppleIDSignIn {
	enum Stage {
		/// The fields, with why the last sign-in stopped under them.
		case form(error: String?)
		/// What's running: "Signing in…".
		case working(String)
		/// Apple lists more than one team for the Apple ID.
		case chooseTeam([AppleIDSession.Team], current: AppleIDSession.Team)
		/// The team has as many development certificates as Apple allows:
		/// what Apple lists, and those revoked in this sign-in that Apple
		/// still counts.
		case revoke([AppleIDSession.Certificate], revoked: [AppleIDSession.Certificate])
		case done(Done)
	}

	/// What You're Signed In shows.
	struct Done {
		var account: StoredAppleID
		/// Whether it went in use, as nothing else was.
		var inUse: Bool
		/// The certificate in use otherwise, which stays in use until Use
		/// for Installs.
		var otherInUse: String?
		var source: CertificateSource
		/// Whether Atelier signed in by itself, with the installer's
		/// sign-in (#152).
		var byInstaller: Bool
	}

	/// The name Apple lists the certificate's machine under, as iloader's is
	/// "iloader" and SideStore's "SideStore".
	static let machineName = "Atelier"

	var email = ""
	var password = ""
	private(set) var stage = Stage.form(error: nil)
	/// Whether Apple refused the token this sheet signs in with first, or
	/// it ended: the password then signs in (#182).
	private var tokenRefused = false
	private(set) var codePrompt: AppleIDCodePrompt?

	private let certificates: CertificatesModel
	/// What the iPhone-only installer handed over, when Atelier signs in by
	/// itself with its sign-in (#152).
	private let installer: InstallerCertificate?
	/// Whether the sheet shows it: always, but out of sight while Atelier
	/// signs in by itself, until there's something to show.
	private var revealed: Bool
	/// New Certificate's Apple ID (12 Nov 2026): signed in again, in its own
	/// team, to have Apple make it a new certificate once its own was
	/// revoked or ended. Or Sign In Again's (#182).
	let renewing: StoredAppleID?
	/// Sign In Again (#182), for an Apple ID whose sign-in with Apple's
	/// token alone has expired: it asks for the password, then renews the
	/// Apple ID's apps.
	let signsInAgain: Bool
	/// Whoever waits on the sheet: an install, Renew or Check Now that met
	/// the Apple ID's expired sign-in (#182), told once whether it signed
	/// in or the sheet closed without.
	@ObservationIgnored var onFinish: ((Bool) -> Void)?
	@ObservationIgnored private var task: Task<Void, Never>?
	@ObservationIgnored private var cancelled = false
	@ObservationIgnored private var teamChoice: CheckedContinuation<AppleIDSession.Team?, Never>?
	@ObservationIgnored private var revokeChoice: CheckedContinuation<AppleIDSession.Certificate?, Never>?

	init(certificates: CertificatesModel) {
		self.certificates = certificates
		installer = nil
		revealed = true
		renewing = nil
		signsInAgain = false
	}

	/// New Certificate for `account` (12 Nov 2026), filled in with its kept
	/// password.
	init(certificates: CertificatesModel, newCertificateFor account: StoredAppleID, password: String) {
		self.certificates = certificates
		installer = nil
		revealed = true
		renewing = account
		signsInAgain = false
		email = account.email
		self.password = password
	}

	/// Sign In Again for `account` (#182), filled in with the Apple ID,
	/// waiting for its password.
	init(certificates: CertificatesModel, signInAgainFor account: StoredAppleID) {
		self.certificates = certificates
		installer = nil
		revealed = true
		renewing = account
		signsInAgain = true
		email = account.email
	}

	/// Filled in with the installer's sign-in, to sign in with by itself
	/// (#152).
	init(certificates: CertificatesModel, installer: InstallerCertificate) {
		self.certificates = certificates
		self.installer = installer
		email = installer.signIn?.appleID ?? ""
		password = installer.signIn?.password ?? ""
		revealed = false
		renewing = nil
		signsInAgain = false
	}

	/// Whether the sheet shows: not while Atelier signs in by itself and
	/// has nothing to show yet, nor once that went through.
	var isShown: Bool {
		revealed || !(isWorking || isDoneByItself)
	}

	/// Signed in by itself with the installer's sign-in, out of sight, and
	/// in use. Only You're Signed In offers Use for Installs while another
	/// certificate is in use, so that one still shows.
	private var isDoneByItself: Bool {
		if case .done(let done) = stage { return done.byInstaller && done.inUse && !revealed }
		return false
	}

	/// The sheet comes up for it, as when the user opens it while Atelier
	/// signs in by itself.
	func reveal() {
		revealed = true
	}

	/// Whether Sign In can be tapped: both fields filled, or the Apple ID
	/// and a token to sign in with (#182), and nothing running.
	var canSignIn: Bool {
		guard case .form = stage else { return false }
		let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
		return !email.isEmpty && (!password.isEmpty || token(for: email) != nil)
	}

	var isWorking: Bool {
		if case .working = stage { return true }
		return false
	}

	func signIn() {
		guard canSignIn, task == nil else { return }
		let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
		let password = password
		stage = .working(handedOver(for: email) != nil ? "Signing in with the Apple ID the installer used…" : "Signing in…")
		task = Task { await run(email: email, password: password) }
	}

	/// Stops wherever it is, as the sheet closes: answers Apple's code
	/// prompt and the choices with a cancel. A call to Apple that's under
	/// way finishes first, and what it brings back is dropped.
	func cancel() {
		finish(false)
		cancelled = true
		task?.cancel()
		answerCode(nil)
		choose(nil)
		revoke(nil)
	}

	// MARK: The steps

	/// Back to the fields, saying nothing when the code was cancelled, else
	/// why.
	private typealias Stop = AppleIDRoute.Stop

	private func run(email: String, password: String) async {
		defer {
			task = nil
			// Tried once, by itself: from here on, it's the user's to try
			// again, from the sheet filled in.
			if installer != nil { certificates.forgetInstallerSignIn() }
		}
		AppleIDLog.note(installer != nil ? "Sign In with Apple ID, by itself with the installer's (#152)" : signsInAgain ? "Sign In Again" : renewing != nil ? "New Certificate" : "Sign In with Apple ID")
		do {
			let done = try await signInAndSave(email: email, password: password)
			guard !cancelled else { return note("done, after the sheet closed") }
			stage = .done(done)
			finish(true)
			// Out of sight, it ends there, with no You're Signed In.
			if isDoneByItself {
				note("signed in by itself, with no sheet")
				certificates.endSignIn()
			}
		} catch Stop.cancelled {
			note("cancelled")
			guard !cancelled else { return }
			stage = .form(error: nil)
		} catch Stop.failed(let message) {
			note("stopped: \(message)")
			guard !cancelled else { return }
			stage = .form(error: message)
		} catch {
			note("stopped: \(error)")
			guard !cancelled else { return }
			stage = .form(error: error.localizedDescription)
		}
	}

	private func signInAndSave(email: String, password: String) async throws -> Done {
		let installer = handedOver(for: email)
		// Read first, so a sign-in doesn't ask for Apple's code only to stop
		// there. The installer's is the one it registered this iPhone with.
		let udid: String
		do {
			if let handedOver = installer?.signIn?.udid {
				udid = handedOver
			} else {
				udid = try await RouteASetup.shared.readUDID()
			}
		} catch {
			note("register: couldn't read the UDID: \(error)")
			throw Stop.failed("Atelier couldn't read this \(ThisDevice.name)'s UDID, which Apple registers it with. Connect LocalDevVPN on Wi-Fi, then try again.")
		}
		let signedIn = try await signInToApple(email: email, password: password)
		try checkCancelled()

		var team = signedIn.team
		if let installer, let handedOver = signedIn.teams.first(where: { $0.id == installer.teamID }) {
			// The installer's, which its certificate is in.
			if handedOver.id != team.id {
				do {
					try await signedIn.session.chooseTeam(handedOver)
				} catch {
					throw Stop.failed(Self.explain(error, "Atelier couldn’t switch to that team"))
				}
				note("team: the installer's, \(handedOver.id), of \(signedIn.teams.count)")
			}
			team = handedOver
		} else if let renewing, let own = signedIn.teams.first(where: { $0.id == renewing.team.id }) {
			// New Certificate's Apple ID, in the team it was in (12 Nov 2026).
			if own.id != team.id {
				do {
					try await signedIn.session.chooseTeam(own)
				} catch {
					throw Stop.failed(Self.explain(error, "Atelier couldn’t switch to that team"))
				}
				note("team: the Apple ID's own, \(own.id), of \(signedIn.teams.count)")
			}
			team = own
		} else if signedIn.teams.count > 1 {
			stage = .chooseTeam(signedIn.teams, current: team)
			guard let picked = await chooseTeam() else { throw Stop.cancelled }
			stage = .working("Signing in…")
			if picked.id != team.id {
				do {
					try await signedIn.session.chooseTeam(picked)
				} catch {
					throw Stop.failed(Self.explain(error, "Atelier couldn’t switch to that team"))
				}
			}
			team = picked
			note("team: chose \(picked.id) (\(AppleIDLog.kind(of: picked))) of \(signedIn.teams.count)")
		}
		try checkCancelled()

		stage = .working("Registering this \(ThisDevice.name)…")
		do {
			let registered = try await signedIn.session.registerDevice(name: "Atelier \(ThisDevice.name)", udid: udid)
			note("register: this \(ThisDevice.name) \(registered.added ? "added" : "already registered"), \(registered.devices) in the team")
		} catch {
			note("register: failed: \(error)")
			throw Stop.failed(Self.explain(error, "Apple didn’t register this \(ThisDevice.name)"))
		}
		try checkCancelled()

		stage = .working("Making a certificate…")
		let existing = certificates.appleID(email: email, teamID: team.id)
		let id = existing?.id ?? StoredAppleID.id(email: email, teamID: team.id)
		let keys: URL
		do {
			keys = try certificates.keysFolder(forAppleID: id)
		} catch {
			throw Stop.failed("Atelier couldn't make a folder for the certificate's key: \(error.localizedDescription)")
		}
		let p12Password = UUID().uuidString
		let (made, source) = try await findOrMakeCertificate(with: signedIn.session, teamID: team.id, keys: keys, p12Password: p12Password)
		let serial = made.certificate.serialNumber.map { " \($0)" } ?? ""
		let until = made.certificate.expires.map { ", until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
		let machine = made.certificate.machineName ?? "an unnamed machine"
		switch source {
		case .made: note("certificate: Apple made one\(serial)\(until)")
		case .found: note("certificate: found the one made before for \(machine), its key being here\(serial)\(until)")
		case .installer: note("certificate: the installer's, made for \(machine), its key handed over\(serial)\(until)")
		}
		try checkCancelled()

		let certificate: SigningCertificate
		do {
			certificate = try made.certificate.content ?? SigningCertificate(der: PKCS12.certificate(in: made.p12, password: p12Password))
		} catch {
			throw Stop.failed("Atelier couldn't read the certificate Apple made: \(error.localizedDescription)")
		}
		let account = StoredAppleID(
			id: id,
			addedAt: existing?.addedAt ?? .now,
			email: email,
			team: StoredAppleID.Team(id: team.id, name: team.name, isFree: team.isFree),
			certificate: certificate,
			machineName: made.certificate.machineName ?? Self.machineName,
			// A check of the same certificate still stands.
			revocation: existing?.certificate.serialNumber == certificate.serialNumber ? existing?.revocation : nil
		)
		let otherInUse = certificates.defaultID == id ? nil : certificates.inUseName
		let inUse: Bool
		do {
			// Apple's token takes the password's place, which then only went
			// to Apple (#182, token only).
			inUse = try certificates.saveAppleID(account, p12: made.p12, p12Password: p12Password, password: password.isEmpty ? nil : password, token: signedIn.token)
		} catch {
			throw Stop.failed("Atelier couldn't keep the Apple ID: \(error.localizedDescription)")
		}
		// Not the other one's name, which may be an Apple ID.
		note("kept, \(inUse ? "in use" : "another certificate staying in use")")
		if let token = signedIn.token { note("token: kept, \(AppleIDLog.describe(token))") }
		// The installs right after use this sign-in, and its page shows
		// what it allows a moment later, asked with it (#49).
		let access = AppleIDAccess.shared
		access.keep(signedIn.session, for: account)
		let saved = certificates.appleID(id) ?? account
		// Atelier itself becomes one of its apps when it's the Apple ID that
		// installed it (#152), signed with the certificate of the tool that
		// did.
		if let context = AutoUpdates.container?.mainContext {
			SelfUpdate.shared.syncRecord(in: context, certificates: certificates)
		}
		let renewsFirst = renewing != nil
		let signsInAgain = self.signsInAgain
		Task {
			// New Certificate's apps first, which wait in Re-sign meanwhile
			// (12 Nov 2026).
			if renewsFirst { await ProfileRenewals.shared.renewAfterSignIn(certificates.appleID(id) ?? saved) }
			// Sign In Again's, which waited for it (#182).
			if signsInAgain { await ProfileRenewals.shared.renewAfterSignInAgain(certificates.appleID(id) ?? saved) }
			await access.checkLimits(of: saved, using: signedIn.session, startingVPN: false)
			// Its apps signed with a certificate it no longer has, as after
			// Apple revoked it, are renewed or signed again: Atelier itself
			// too, which then tells whether a new profile lists the
			// certificate it was installed with.
			if !renewsFirst { await ProfileRenewals.shared.renewAfterSignIn(certificates.appleID(id) ?? saved) }
		}
		return Done(account: account, inUse: inUse, otherInUse: inUse ? nil : otherInUse, source: source, byInstaller: installer != nil)
	}

	/// Signs in with the token the installer handed over, or New
	/// Certificate's Apple ID's own, when there's one Apple still takes
	/// (#182); else through each anisette server in turn until one works,
	/// as `AnisetteRoute` says: the user's own only, when there's one.
	private func signInToApple(email: String, password: String) async throws -> AppleIDSession.SignedIn {
		if let token = token(for: email), let resumed = try await resume(email: email, token: token, withPassword: !password.isEmpty) {
			return resumed
		}
		// Through the installer's server first, whose machine Apple trusts.
		let server = handedOver(for: email)?.signIn?.anisetteServer.flatMap(AnisetteList.serverURL)
		return try await AppleIDRoute.signIn(email: email, password: password, firstServer: server, appleIDIsSet: renewing != nil, isCancelled: { [weak self] in self?.cancelled ?? true }) { [weak self] request in
			self?.waitForCode(request)
		}
	}

	/// The token to sign in with first, without the password (#182): the
	/// one the installer handed over for `email`, or New Certificate's Apple
	/// ID's own, kept in the Keychain, while it lasts: one that expired
	/// waits for the password. Nil once Apple refused it.
	private func token(for email: String) -> AppleIDToken? {
		guard !tokenRefused else { return nil }
		if let token = handedOver(for: email)?.signIn?.token { return token }
		guard let renewing, renewing.email.caseInsensitiveCompare(email) == .orderedSame,
		      let token = (try? certificates.appleIDToken(for: renewing.id)) ?? nil, token.isUsable()
		else { return nil }
		return token
	}

	/// Signs in with `token`, through the anisette server it came through,
	/// as the same machine. Nil when Apple refused it, which deletes the
	/// Apple ID's own, or it ended, and there's a password to sign in with
	/// instead; without one, the sheet asks for it. When Apple wasn't
	/// reached, it stops, keeping the token to try again, unless there's a
	/// password.
	private func resume(email: String, token: AppleIDToken, withPassword: Bool) async throws -> AppleIDSession.SignedIn? {
		var token = token
		// As Atelier's own sign-ins name it, which its state is kept by.
		if let url = AnisetteList.serverURL(token.server) { token.server = url.absoluteString }
		if !token.isUsable() {
			note("token: Apple says it ended")
		} else if let why = AppleIDAccess.unusableMachine(for: token) {
			note("token: not tried, as \(why)")
		} else {
			note("Signing in with Apple's token, \(AppleIDLog.describe(token))")
			do {
				let resumed = try await AppleIDSession.resume(email: email, token: token, storage: Self.storage())
				note("sign-in with the token: \(AppleIDLog.describe(resumed))")
				return resumed
			} catch let error as AppleIDError where error.kind == .tokenRefused {
				note("token: Apple refused it\(error.appleCode == 0 ? "" : " (\(error.appleCode))"): \(error.message)")
				if let renewing { certificates.setAppleIDToken(nil, for: renewing.id) }
			} catch {
				note("token: Apple wasn't reached with it: \(error)")
				guard withPassword else { throw Stop.failed(Self.explain(error, AppleIDError.couldNotReachApple)) }
				return nil
			}
		}
		tokenRefused = true
		guard withPassword else {
			throw Stop.failed(installer != nil
				? "The installer’s sign-in has expired. Type the Apple ID’s password to sign in."
				: "Atelier’s sign-in with this Apple ID has expired. Type its password to sign in.")
		}
		return nil
	}

	/// What the installer handed over, while the sheet still has the Apple
	/// ID it used (#152): its team, its server and the UDID it registered.
	private func handedOver(for email: String) -> InstallerCertificate? {
		guard let installer, installer.signIn?.appleID.caseInsensitiveCompare(email) == .orderedSame else { return nil }
		return installer
	}

	/// Where this iPhone's certificate came from.
	enum CertificateSource: Equatable {
		/// Apple made it now.
		case made
		/// Apple lists it, and its key is here from an earlier sign-in.
		case found
		/// The one the iPhone-only installer made with this Apple ID to
		/// install Atelier, which handed its key over (#152).
		case installer
	}

	/// This iPhone's development certificate: one Apple lists whose key is
	/// here from an earlier sign-in, whatever app Apple says made it; else
	/// the one the iPhone-only installer made in this team and left its key
	/// for (#152), as a free Apple ID may only have two; else a new one
	/// (`makeCertificate`). The installer's is forgotten once used, once
	/// Apple no longer lists it, or once Atelier has its own in the team.
	private func findOrMakeCertificate(with session: AppleIDSession, teamID: String, keys: URL, p12Password: String) async throws -> (AppleIDSession.MadeCertificate, CertificateSource) {
		let installer = certificates.installerCertificate.flatMap { $0.teamID == teamID ? $0 : nil }
		switch try await adoptCertificate(key: nil, with: session, keys: keys, p12Password: p12Password) {
		case .found(let found) where renewing != nil && (found.certificate.expires ?? .distantFuture) <= .now:
			// New Certificate is for another than the one that ended (12 Nov
			// 2026).
			note("certificate: the one whose key is here has ended")
		case .found(let found):
			if installer != nil {
				note("certificate: leaving the installer's, as the team has the one whose key is here")
				certificates.forgetInstallerCertificate()
			}
			return (found, .found)
		case .unreadableKey:
			note("certificate: the key kept from before can't be read")
		case .noKey, .notListed:
			break
		}
		try checkCancelled()
		if let installer {
			switch try await adoptCertificate(key: installer.privateKey, with: session, keys: keys, p12Password: p12Password) {
			case .found(let adopted):
				certificates.forgetInstallerCertificate()
				return (adopted, .installer)
			case .notListed(let listed):
				note("certificate: Apple no longer lists the installer's, \(listed) listed")
				certificates.forgetInstallerCertificate()
			case .unreadableKey, .noKey:
				note("certificate: the installer's key can't be read")
				certificates.forgetInstallerCertificate()
			}
			try checkCancelled()
		}
		return (try await makeCertificate(with: session, keys: keys, p12Password: p12Password), .made)
	}

	/// The team's certificate made with `key`, or the key kept in `keys`
	/// with `key` nil. A failure stops the sign-in, rather than having
	/// Apple make another certificate when one may be there.
	private func adoptCertificate(key: Data?, with session: AppleIDSession, keys: URL, p12Password: String) async throws -> AppleIDSession.Adoption {
		do {
			return try await session.adoptCertificate(key: key, p12Password: p12Password, keys: keys)
		} catch {
			note("certificate: listing failed: \(error)")
			throw Stop.failed(Self.explain(error, "Apple didn’t list the team’s certificates"))
		}
	}

	/// The most certificates one sign-in revokes, each the user's pick.
	static let maxRevokes = 3

	/// A new development certificate for this iPhone. At Apple's limit, the
	/// team's certificates are listed and the one the user picks is revoked
	/// first. Apple goes on counting a revoked certificate after it leaves
	/// the list, still 27 minutes later, and waiting never freed its place
	/// while revoking another listed one did, at once (Alex's iPhone, 12 Nov
	/// 2026). So while Apple still says 7460 after a revoke, the list comes
	/// again, as Revoke Another?, for up to `maxRevokes` revokes.
	private func makeCertificate(with session: AppleIDSession, keys: URL, p12Password: String) async throws -> AppleIDSession.MadeCertificate {
		var revoked: [AppleIDSession.Certificate] = []
		while true {
			do {
				return try await session.certificate(machineName: Self.machineName, p12Password: p12Password, keys: keys)
			} catch let error as AppleIDError where error.isTooManyCertificates {
				var listed: [AppleIDSession.Certificate]
				do {
					listed = try await session.certificates()
				} catch {
					throw Stop.failed(Self.explain(error, "Apple didn’t list the team’s certificates"))
				}
				try checkCancelled()
				note("certificate: at Apple's limit, \(listed.count) listed\(revoked.isEmpty ? "" : ", \(revoked.count) revoked so far")")
				// One revoked already, if Apple lists it still, isn't
				// offered again.
				let revokedSerials = Set(revoked.compactMap(\.serialNumber))
				listed.removeAll { certificate in certificate.serialNumber.map { revokedSerials.contains($0) } ?? false }
				guard revoked.count < Self.maxRevokes, listed.contains(where: { $0.serialNumber != nil }) else {
					note("certificate: nothing more to revoke")
					if revoked.isEmpty { throw Stop.failed(Self.explain(error, "Apple didn’t make the certificate")) }
					throw Stop.failed(revoked.count == 1
						? "Apple still counts the certificate you revoked, so Atelier can't make its own yet. Try again later."
						: "Apple still counts the certificates you revoked, so Atelier can't make its own yet. Try again later.")
				}
				stage = .revoke(listed, revoked: revoked)
				guard let picked = await chooseRevocation(), let serialNumber = picked.serialNumber else { throw Stop.cancelled }
				stage = .working("Revoking the certificate…")
				do {
					try await session.revokeCertificate(serialNumber: serialNumber)
					note("certificate: revoked \(serialNumber)\(picked.machineName.map { ", made for \($0)" } ?? "")")
				} catch {
					note("certificate: revoking failed: \(error)")
					throw Stop.failed(Self.explain(error, "Apple didn’t revoke the certificate"))
				}
				revoked.append(picked)
				try checkCancelled()
				stage = .working("Making a certificate…")
			} catch {
				note("certificate: failed: \(error)")
				throw Stop.failed(Self.explain(error, "Apple didn’t make the certificate"))
			}
		}
	}

	private func checkCancelled() throws {
		if cancelled || Task.isCancelled { throw Stop.cancelled }
	}

	// MARK: Choices

	private func chooseTeam() async -> AppleIDSession.Team? {
		guard !cancelled else { return nil }
		return await withCheckedContinuation { teamChoice = $0 }
	}

	/// Choose a Team's Continue, or nil to stop.
	func choose(_ team: AppleIDSession.Team?) {
		teamChoice?.resume(returning: team)
		teamChoice = nil
	}

	private func chooseRevocation() async -> AppleIDSession.Certificate? {
		guard !cancelled else { return nil }
		return await withCheckedContinuation { revokeChoice = $0 }
	}

	/// Revoke and Continue, once confirmed, or nil to stop.
	func revoke(_ certificate: AppleIDSession.Certificate?) {
		revokeChoice?.resume(returning: certificate)
		revokeChoice = nil
	}

	// MARK: Apple's code

	/// Shows Apple's request, and waits on the Apple ID queue for the
	/// answer: 10 minutes at most, then the sign-in is cancelled.
	nonisolated private func waitForCode(_ request: AppleIDSession.CodeRequest) -> AppleIDSession.CodeAnswer? {
		AppleIDCodePrompt.wait(for: request) { [weak self] prompt in
			guard let self, !self.cancelled else { return false }
			self.note("sign-in: \(AppleIDLog.describe(request))")
			self.codePrompt = prompt
			// Signing in by itself: the sheet comes up, filled in, with the
			// alert, and stays up.
			self.revealed = true
			return true
		} timedOut: { [weak self] in
			self?.codePrompt = nil
			self?.note("sign-in: no code after 10 minutes")
		}
	}

	/// The alert's answer; nil cancels the sign-in.
	func answerCode(_ answer: AppleIDSession.CodeAnswer?) {
		guard let prompt = codePrompt else { return }
		codePrompt = nil
		note("sign-in: \(AppleIDLog.describe(answer, to: prompt.request))")
		prompt.reply(answer)
	}

	// MARK: Helpers

	private func finish(_ signedIn: Bool) {
		let waiting = onFinish
		onFinish = nil
		waiting?(signedIn)
	}

	/// A line in the Apple ID log, which an Apple ID's page shows.
	private func note(_ line: String) {
		AppleIDLog.note(line)
	}

	/// "Apple didn’t register this iPhone. Apple says: “Your development
	/// team has reached the maximum number of registered iPhone devices.”"
	private static func explain(_ error: Error, _ what: String) -> String {
		AppleIDRoute.explain(error, what)
	}

	/// Where isideload keeps each anisette server's state, and where the
	/// list Atelier's worker gave last and the server that worked last are
	/// kept: Application Support/AppleID, left out of backups. The
	/// certificates' keys are kept with the certificates instead.
	static func storage() throws -> URL {
		var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("AppleID", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try url.setResourceValues(values)
		return url
	}
}
