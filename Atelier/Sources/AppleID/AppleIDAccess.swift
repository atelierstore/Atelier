import AppleIDKit
import AtelierCore
import CertKit
import Foundation
import InstallKit
import Observation

/// Signing in again with a kept Apple ID (#49): for each install with it,
/// and for Check Now on its page. With the password kept in the Keychain,
/// in the team it was signed in with, through the anisette servers Sign In
/// with Apple ID goes through. A sign-in serves the installs after it for
/// a few minutes, so a round of installs signs in once. When Apple asks for
/// its code, an alert over everything asks, unless nobody is there to
/// answer, as for an automatic update.
@MainActor
@Observable
final class AppleIDAccess {
	static let shared = AppleIDAccess()

	/// Why signing in again stopped.
	enum Failure: Error {
		/// The code was cancelled, or the install was.
		case cancelled
		case failed(String)
		/// Apple asked for its code with nobody there to answer.
		case codeNeeded
	}

	/// Apple's request for a code, while the alert shows it.
	private(set) var codePrompt: AppleIDCodePrompt?
	/// The Apple IDs Check Now is checking.
	private(set) var checking: Set<UUID> = []
	/// Why the last Check Now of an Apple ID didn't get everything, until
	/// the next one.
	private(set) var checkFailures: [UUID: String] = [:]

	private struct Kept {
		let session: AppleIDSession
		let teamID: String
		let signedInAt: Date
	}

	@ObservationIgnored private var sessions: [UUID: Kept] = [:]
	/// The Apple IDs whose page is reading iOS's list of apps again.
	@ObservationIgnored private var refreshing: Set<UUID> = []

	/// How long a sign-in serves the installs after it: a round of them,
	/// well within the session Apple gives.
	static let sessionLifetime: TimeInterval = 10 * 60

	private init() {}

	/// A session signed in as `account`, in its team: the one kept from a
	/// sign-in in the last few minutes, else a new sign-in. `purpose` says
	/// what Apple's code is for, should it ask: "To get Atlas's profile,
	/// Apple wants a code." Nil when nobody is there to answer, which stops
	/// with `codeNeeded`.
	func session(for account: StoredAppleID, purpose: String?) async throws -> AppleIDSession {
		if hasSession(for: account), let kept = sessions[account.id] { return kept.session }
		sessions[account.id] = nil
		let password: String
		do {
			guard let kept = try CertificatesModel.shared.appleIDPassword(for: account.id) else {
				throw Failure.failed("Atelier no longer has the Apple ID's password. Sign in with it again in Settings › Installs › Certificates.")
			}
			password = kept
		} catch let failure as Failure {
			throw failure
		} catch {
			throw Failure.failed("Atelier couldn't read the Apple ID's password, which iOS only gives once this \(ThisDevice.name) was unlocked: \(error.localizedDescription)")
		}
		AppleIDLog.note("Signing in again, \(purpose == nil ? "with nobody to ask for a code" : "for an install or Check Now")")
		let asked = CodeAsked()
		let signedIn: AppleIDSession.SignedIn
		do {
			signedIn = try await withTaskCancellationHandler {
				try await AppleIDRoute.signIn(email: account.email, password: password, isCancelled: { false }) { [weak self] request in
					asked.value = true
					guard let purpose else {
						Task { @MainActor in AppleIDLog.note("sign-in: Apple asked for a code, with nobody to ask") }
						return nil
					}
					return self?.waitForCode(request, purpose: purpose)
				}
			} onCancel: {
				Task { @MainActor [weak self] in self?.answerCode(nil) }
			}
		} catch AppleIDRoute.Stop.cancelled {
			throw asked.value && purpose == nil ? Failure.codeNeeded : Failure.cancelled
		} catch AppleIDRoute.Stop.failed(let message) {
			throw Failure.failed(message)
		}
		if Task.isCancelled { throw Failure.cancelled }
		// Its team, which a sign-in may not list first.
		if signedIn.team.id != account.team.id {
			guard let team = signedIn.teams.first(where: { $0.id == account.team.id }) else {
				AppleIDLog.note("sign-in: its team isn't listed any more")
				throw Failure.failed("Apple no longer lists the team the Apple ID was signed in with, \(account.team.name ?? account.team.id). Sign in with it again in Settings › Installs › Certificates.")
			}
			do {
				try await signedIn.session.chooseTeam(team)
			} catch {
				throw Failure.failed(AppleIDRoute.explain(error, "Atelier couldn't switch to the Apple ID's team"))
			}
		}
		sessions[account.id] = Kept(session: signedIn.session, teamID: account.team.id, signedInAt: .now)
		// Someone was there to enter a code, so renewals may sign in by
		// themselves again.
		if purpose != nil { ProfileRenewals.shared.signedIn(account) }
		return signedIn.session
	}

	/// Whether a sign-in in the last few minutes still serves `account`.
	func hasSession(for account: StoredAppleID) -> Bool {
		guard let kept = sessions[account.id] else { return false }
		return kept.teamID == account.team.id && Date.now.timeIntervalSince(kept.signedInAt) < Self.sessionLifetime
	}

	/// Forgets the session kept for `id`, as after signing out.
	func forget(_ id: UUID) {
		sessions[id] = nil
	}

	/// Keeps the session Sign In with Apple ID just signed in with, in the
	/// Apple ID's team, so the installs right after it don't sign in again.
	func keep(_ session: AppleIDSession, for account: StoredAppleID) {
		sessions[account.id] = Kept(session: session, teamID: account.team.id, signedInAt: .now)
		ProfileRenewals.shared.signedIn(account)
	}

	// MARK: Apple's code

	/// Shows Apple's request over everything, and waits on the Apple ID
	/// queue for the answer: 10 minutes at most, then the sign-in stops.
	nonisolated private func waitForCode(_ request: AppleIDSession.CodeRequest, purpose: String) -> AppleIDSession.CodeAnswer? {
		AppleIDCodePrompt.wait(for: request, purpose: purpose) { [weak self] prompt in
			guard let self else { return false }
			AppleIDLog.note("sign-in: \(AppleIDLog.describe(request))")
			self.codePrompt = prompt
			return true
		} timedOut: { [weak self] in
			self?.codePrompt = nil
			AppleIDLog.note("sign-in: no code after 10 minutes")
		}
	}

	/// The alert's answer; nil cancels the sign-in, and the install or the
	/// check with it.
	func answerCode(_ answer: AppleIDSession.CodeAnswer?) {
		guard let prompt = codePrompt else { return }
		codePrompt = nil
		AppleIDLog.note("sign-in: \(AppleIDLog.describe(answer, to: prompt.request))")
		prompt.reply(answer)
	}

	// MARK: Its limits

	/// Check Now on the Apple ID's page, and right after signing in: which
	/// apps on this iPhone hold a free Apple ID's 3 places, as iOS lists
	/// them, and the team's App IDs, as Apple lists them, kept with the
	/// Apple ID. With `session`, the one just signed in with. Connects
	/// LocalDevVPN first when `startingVPN` and it's off.
	func checkLimits(of account: StoredAppleID, using session: AppleIDSession? = nil, startingVPN: Bool = true) async {
		guard !checking.contains(account.id) else { return }
		checking.insert(account.id)
		defer { checking.remove(account.id) }
		checkFailures[account.id] = nil
		AppleIDLog.note("Check Now")
		var limits = account.limits ?? AppleIDLimits()
		var failures: [String] = []
		if account.isFree {
			do {
				limits.apps = try await freeApps(startingVPN: startingVPN)
			} catch {
				AppleIDLog.note("Check Now: iOS didn't list the apps: \(InstallProblem(error).message)")
				failures.append("This \(ThisDevice.name) didn't list its apps: \(InstallProblem(error).message)")
			}
		}
		do {
			let signedIn: AppleIDSession
			if let session {
				signedIn = session
			} else {
				signedIn = try await self.session(for: account, purpose: "To check the Apple ID's limits, Apple wants a code.")
			}
			let list = try await signedIn.appIDs()
			limits.appIDs = list.limits(checkedAt: .now)
			AppleIDLog.note("Check Now: \(list.appIDs.count) App IDs, \(list.available.map { "\($0)" } ?? "no count") left")
		} catch Failure.cancelled {
			AppleIDLog.note("Check Now: cancelled")
		} catch Failure.failed(let message) {
			failures.append(message)
		} catch {
			AppleIDLog.note("Check Now: Apple didn't list the App IDs: \(error)")
			failures.append(AppleIDRoute.explain(error, "Apple didn't list the App IDs"))
		}
		if limits != (account.limits ?? AppleIDLimits()) {
			CertificatesModel.shared.updateAppleID(account.id) { $0.limits = limits }
		}
		if !failures.isEmpty { checkFailures[account.id] = failures.joined(separator: "\n") }
	}

	/// The apps on this iPhone again, as the Apple ID's page opens (#49), so
	/// it doesn't count apps deleted from the Home Screen since the last
	/// check (4 Nov 2026). Only iOS's list, so no sign-in to Apple,
	/// and only when Direct installs reach iOS without connecting LocalDevVPN
	/// and nothing installs. Check Now asks Apple too, as before.
	func refreshApps(of account: StoredAppleID) async {
		guard account.isFree, RouteASetup.shared.isPaired, !checking.contains(account.id), !refreshing.contains(account.id), !InstallModel.shared.isRunning else { return }
		// Once in a while: the page's rows may each ask.
		if let checked = account.limits?.apps?.checkedAt, Date.now.timeIntervalSince(checked) < 30 { return }
		refreshing.insert(account.id)
		defer { refreshing.remove(account.id) }
		guard let apps = try? await freeApps(startingVPN: false) else { return }
		let names = apps.apps.map(\.bundleID).joined(separator: ", ")
		AppleIDLog.note("Apple ID page: \(apps.apps.count) of \(FreeAppleID.appsPerDevice) apps signed with a free Apple ID on this \(ThisDevice.name)\(names.isEmpty ? "" : ": \(names)")")
		CertificatesModel.shared.updateAppleID(account.id) { stored in
			var limits = stored.limits ?? AppleIDLimits()
			limits.apps = apps
			stored.limits = limits
		}
	}

	/// The apps on this iPhone that hold a free Apple ID's places: those
	/// iOS lists with a free Apple ID's profile, through Direct installs.
	func freeApps(startingVPN: Bool) async throws -> AppleIDLimits.Apps {
		let read = try await InstallModel.shared.appsAndProfiles(startingVPN: startingVPN)
		return AppleIDLimits.Apps(checkedAt: .now, apps: FreeAppleID.apps(installed: read.apps, profileFiles: read.profiles))
	}
}

/// Whether Apple asked for a code during a sign-in, from the Apple ID
/// queue.
private final class CodeAsked: @unchecked Sendable {
	var value = false
}
