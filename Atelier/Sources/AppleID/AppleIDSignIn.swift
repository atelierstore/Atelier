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
/// revoking one by itself. The Apple ID, its
/// password and the certificate are then kept with the certificates
/// (`CertificateStore.saveAppleID`), in use if nothing else is.
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
		/// The team has as many development certificates as Apple allows.
		case revoke([AppleIDSession.Certificate])
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
	}

	/// The name Apple lists the certificate's machine under, as iloader's is
	/// "iloader" and SideStore's "SideStore".
	static let machineName = "Atelier"

	var email = ""
	var password = ""
	private(set) var stage = Stage.form(error: nil)
	private(set) var codePrompt: AppleIDCodePrompt?

	private let certificates: CertificatesModel
	@ObservationIgnored private var task: Task<Void, Never>?
	@ObservationIgnored private var cancelled = false
	@ObservationIgnored private var teamChoice: CheckedContinuation<AppleIDSession.Team?, Never>?
	@ObservationIgnored private var revokeChoice: CheckedContinuation<AppleIDSession.Certificate?, Never>?

	init(certificates: CertificatesModel) {
		self.certificates = certificates
	}

	/// Whether Sign In can be tapped: both fields filled, and nothing
	/// running.
	var canSignIn: Bool {
		guard case .form = stage else { return false }
		return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
	}

	var isWorking: Bool {
		if case .working = stage { return true }
		return false
	}

	func signIn() {
		guard canSignIn, task == nil else { return }
		let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
		let password = password
		stage = .working("Signing in…")
		task = Task { await run(email: email, password: password) }
	}

	/// Stops wherever it is, as the sheet closes: answers Apple's code
	/// prompt and the choices with a cancel. A call to Apple that's under
	/// way finishes first, and what it brings back is dropped.
	func cancel() {
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
		defer { task = nil }
		AppleIDLog.note("Sign In with Apple ID")
		do {
			let done = try await signInAndSave(email: email, password: password)
			guard !cancelled else { return note("done, after the sheet closed") }
			stage = .done(done)
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
		// Read first, so a sign-in doesn't ask for Apple's code only to stop
		// there.
		let udid: String
		do {
			udid = try await RouteASetup.shared.readUDID()
		} catch {
			note("register: couldn't read the UDID: \(error)")
			throw Stop.failed("Atelier couldn't read this \(ThisDevice.name)'s UDID, which Apple registers it with. Connect LocalDevVPN on Wi-Fi, then try again.")
		}
		let signedIn = try await signInToApple(email: email, password: password)
		try checkCancelled()

		var team = signedIn.team
		if signedIn.teams.count > 1 {
			stage = .chooseTeam(signedIn.teams, current: team)
			guard let picked = await chooseTeam() else { throw Stop.cancelled }
			stage = .working("Signing in…")
			if picked.id != team.id {
				do {
					try await signedIn.session.chooseTeam(picked)
				} catch {
					throw Stop.failed(Self.explain(error, "Atelier couldn't switch to that team"))
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
			throw Stop.failed(Self.explain(error, "Apple didn't register this \(ThisDevice.name)"))
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
			inUse = try certificates.saveAppleID(account, p12: made.p12, p12Password: p12Password, password: password)
		} catch {
			throw Stop.failed("Atelier couldn't keep the Apple ID: \(error.localizedDescription)")
		}
		// Not the other one's name, which may be an Apple ID.
		note("kept, \(inUse ? "in use" : "another certificate staying in use")")
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
		Task {
			await access.checkLimits(of: saved, using: signedIn.session, startingVPN: false)
			// Its apps signed with a certificate it no longer has, as after
			// Apple revoked it, are renewed or signed again: Atelier itself
			// too, which then tells whether a new profile lists the
			// certificate it was installed with.
			await ProfileRenewals.shared.renewAfterSignIn(certificates.appleID(id) ?? saved)
		}
		return Done(account: account, inUse: inUse, otherInUse: inUse ? nil : otherInUse)
	}

	/// Signs in through each anisette server in turn until one works, as
	/// `AnisetteRoute` says: the user's own only, when there's one.
	private func signInToApple(email: String, password: String) async throws -> AppleIDSession.SignedIn {
		try await AppleIDRoute.signIn(email: email, password: password, isCancelled: { [weak self] in self?.cancelled ?? true }) { [weak self] request in
			self?.waitForCode(request)
		}
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
			throw Stop.failed(Self.explain(error, "Apple didn't list the team's certificates"))
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
	/// again, for up to `maxRevokes` revokes.
	private func makeCertificate(with session: AppleIDSession, keys: URL, p12Password: String) async throws -> AppleIDSession.MadeCertificate {
		var revoked = 0
		while true {
			do {
				return try await session.certificate(machineName: Self.machineName, p12Password: p12Password, keys: keys)
			} catch let error as AppleIDError where error.isTooManyCertificates {
				let listed: [AppleIDSession.Certificate]
				do {
					listed = try await session.certificates()
				} catch {
					throw Stop.failed(Self.explain(error, "Apple didn't list the team's certificates"))
				}
				try checkCancelled()
				note("certificate: at Apple's limit, \(listed.count) listed\(revoked > 0 ? ", \(revoked) revoked so far" : "")")
				guard revoked < Self.maxRevokes, listed.contains(where: { $0.serialNumber != nil }) else {
					note("certificate: nothing more to revoke")
					throw Stop.failed(Self.explain(error, "Apple didn't make the certificate"))
				}
				stage = .revoke(listed)
				guard let picked = await chooseRevocation(), let serialNumber = picked.serialNumber else { throw Stop.cancelled }
				stage = .working("Revoking the certificate…")
				do {
					try await session.revokeCertificate(serialNumber: serialNumber)
					note("certificate: revoked \(serialNumber)\(picked.machineName.map { ", made for \($0)" } ?? "")")
				} catch {
					note("certificate: revoking failed: \(error)")
					throw Stop.failed(Self.explain(error, "Apple didn't revoke the certificate"))
				}
				revoked += 1
				try checkCancelled()
				stage = .working("Making a certificate…")
			} catch {
				note("certificate: failed: \(error)")
				throw Stop.failed(Self.explain(error, "Apple didn't make the certificate"))
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

	/// A line in the Apple ID log, which an Apple ID's page shows.
	private func note(_ line: String) {
		AppleIDLog.note(line)
	}

	/// "Apple didn't register this iPhone (35): Your development team has
	/// reached the maximum number of registered iPhone devices."
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
