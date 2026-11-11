import AppleIDKit
import Foundation

/// Signing in to Apple with an Apple ID (#49), for Sign In with Apple ID
/// and for every sign-in again with a kept one (`AppleIDAccess`): through
/// each anisette server Atelier's worker lists in turn until one works, as
/// `AnisetteRoute` says, or only through the user's own when there's one.
@MainActor
enum AppleIDRoute {
	/// Why a sign-in stopped.
	enum Stop: Error {
		/// Saying nothing: the code or the sign-in was cancelled.
		case cancelled
		/// Saying why.
		case failed(String)
	}

	/// Signs in as `email`. `askCode` runs on the Apple ID queue when Apple
	/// asks for a verification code, and waits there for the answer; nil
	/// cancels. `isCancelled` is asked before each server.
	static func signIn(
		email: String,
		password: String,
		isCancelled: @escaping @MainActor () -> Bool,
		askCode: @escaping @Sendable (AppleIDSession.CodeRequest) -> AppleIDSession.CodeAnswer?
	) async throws -> AppleIDSession.SignedIn {
		let storage: URL
		do {
			storage = try AppleIDSignIn.storage()
		} catch {
			throw Stop.failed("Atelier couldn't make a folder for signing in: \(error.localizedDescription)")
		}
		let custom: URL?
		switch CustomAnisetteServer.current() {
		case .success(let url): custom = url
		case .failure(let problem):
			throw Stop.failed("Your anisette server in Settings › Installs › Advanced can't be used. \(problem.description)")
		}
		let source = AnisetteListSource(folder: storage)
		// Its client info goes to Apple through the user's server too.
		let (list, origin) = await source.current()
		var route = custom.map(AnisetteRoute.init(custom:)) ?? AnisetteRoute(list: list, lastWorked: source.lastWorked)
		if let custom {
			AppleIDLog.note("sign-in: your own anisette server, \(custom.host ?? custom.absoluteString)")
		} else {
			let most = route.tries < route.servers.count ? ", \(route.tries) at most" : ""
			AppleIDLog.note("sign-in: \(AppleIDLog.describe(list, from: origin, trying: route.servers))\(most)")
		}
		var last = AppleIDError(kind: .other, message: "No anisette server answered.")
		var server = route.start()
		var previous: AnisetteList.Server?
		while let current = server {
			if isCancelled() || Task.isCancelled { throw Stop.cancelled }
			AppleIDLog.note("sign-in: through \(current.host)\(previous == current ? ", once more" : "")")
			previous = current
			do {
				let signedIn = try await AppleIDSession.signIn(
					email: email,
					password: password,
					server: current.url.absoluteString,
					clientInfo: list.clientInfo,
					storage: storage,
					askCode: askCode
				)
				if !route.isCustom { source.setLastWorked(current.url) }
				AppleIDLog.note("sign-in: \(AppleIDLog.describe(signedIn))")
				return signedIn
			} catch let error as AppleIDError {
				AppleIDLog.note("sign-in via \(current.host): \(error)")
				last = error
				// Apple's "Try again" goes through the same server once more,
				// a moment later.
				if error.isTryAgain { try? await Task.sleep(for: .seconds(2)) }
				server = route.next(after: error.routeFailure)
			} catch {
				AppleIDLog.note("sign-in via \(current.host): \(error.localizedDescription)")
				last = AppleIDError(kind: .other, message: error.localizedDescription)
				server = route.next(after: .server)
			}
		}
		guard let explanation = route.explanation(of: last) else { throw Stop.cancelled }
		throw Stop.failed(explanation)
	}

	/// "Apple didn't register this iPhone (35): Your development team has
	/// reached the maximum number of registered iPhone devices."
	static func explain(_ error: Error, _ what: String) -> String {
		guard let error = error as? AppleIDError else { return "\(what): \(error.localizedDescription)" }
		switch error.kind {
		case .developer, .signIn:
			return error.message.isEmpty ? "\(what) (\(error.appleCode))." : "\(what) (\(error.appleCode)): \(error.message)"
		case .cancelled, .noTeam, .other:
			return error.message.isEmpty ? "\(what)." : "\(what): \(error.message)"
		}
	}
}

/// Apple's request for a verification code, while an alert shows it: in the
/// Sign In with Apple ID sheet, or over everything for an install (#49).
struct AppleIDCodePrompt: Identifiable {
	let id = UUID()
	let request: AppleIDSession.CodeRequest
	/// What it's for, said before Apple's request: "To get Atlas's
	/// profile, Apple wants a code." Nil in the sign-in sheet, which says.
	var purpose: String?
	let reply: (AppleIDSession.CodeAnswer?) -> Void

	/// Shows a prompt for `request` through `show`, on the main actor, and
	/// waits on the Apple ID queue for its answer: 10 minutes at most, then
	/// `timedOut` runs there and the answer is nil, which cancels the
	/// sign-in. `show` returns false when there's nobody to ask any more,
	/// which answers nil at once.
	nonisolated static func wait(
		for request: AppleIDSession.CodeRequest,
		purpose: String? = nil,
		show: @escaping @MainActor (AppleIDCodePrompt) -> Bool,
		timedOut: @escaping @MainActor () -> Void
	) -> AppleIDSession.CodeAnswer? {
		let answered = DispatchSemaphore(value: 0)
		let box = CodeAnswerBox()
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				let prompt = AppleIDCodePrompt(request: request, purpose: purpose) { answer in
					box.answer = answer
					answered.signal()
				}
				if !show(prompt) { answered.signal() }
			}
		}
		if answered.wait(timeout: .now() + 600) == .timedOut {
			DispatchQueue.main.async {
				MainActor.assumeIsolated { timedOut() }
			}
			return nil
		}
		return box.answer
	}
}

/// Carries the alert's answer back to the Apple ID queue.
private final class CodeAnswerBox: @unchecked Sendable {
	var answer: AppleIDSession.CodeAnswer?
}
