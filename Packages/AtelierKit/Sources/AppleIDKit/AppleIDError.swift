import Foundation

/// What went wrong talking to Apple for an Apple ID (#49), with Apple's code
/// when it gave one. The app makes it from the bridge's errors
/// (Packages/IDeviceBridge/src/appleid.rs).
public struct AppleIDError: Error, Equatable, Sendable, CustomStringConvertible {
	public enum Kind: Equatable, Sendable {
		/// Apple's sign-in refused, with its code.
		case signIn
		/// Apple's developer services refused, with their code.
		case developer
		/// The verification code was cancelled.
		case cancelled
		/// The Apple ID signed in, but isn't in any developer team.
		case noTeam
		/// Apple refused the token a sign-in again went with, as once it
		/// ended (#182), with Apple's code when it gave one.
		case tokenRefused
		/// Anything else: no network, an anisette server that doesn't answer.
		case other
	}

	public var kind: Kind
	/// Apple's code, such as -22406 for a wrong password; 0 when there's none.
	public var appleCode: Int32
	public var message: String

	public init(kind: Kind, appleCode: Int32 = 0, message: String) {
		self.kind = kind
		self.appleCode = appleCode
		self.message = message
	}

	public static func unreadable(_ what: String) -> AppleIDError {
		AppleIDError(kind: .other, message: "Atelier couldn't read \(what)")
	}

	/// A wrong Apple ID or password: -20101, or -22406, "Enter the correct
	/// password for this Apple Account.", as Apple answered on 13 Nov 2026.
	/// Final, so it isn't tried again through another server.
	public var isWrongPassword: Bool { kind == .signIn && (appleCode == -20101 || appleCode == -22406) }
	public var isLocked: Bool { kind == .signIn && appleCode == -20209 }
	/// "This action cannot be completed at this time": what Apple answered
	/// iloader's servers in October 2026 until each was fixed.
	public var isTryLater: Bool { appleCode == -80045 }
	/// Apple's "This action could not be completed. Try again." (-22421).
	public var isTryAgain: Bool { kind == .signIn && appleCode == -22421 }
	/// The team has the most development certificates Apple allows.
	public var isTooManyCertificates: Bool { kind == .developer && appleCode == 7460 }

	/// Apple's own sentence, as isideload ends the bridge's message with
	/// it: what follows "Auth error <code>: " or "Developer error <code>: ".
	/// Nil when there's none.
	public var applesWords: String? {
		for marker in ["Auth error \(appleCode): ", "Developer error \(appleCode): "] {
			guard let range = message.range(of: marker, options: .backwards) else { continue }
			let words = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
			if !words.isEmpty { return words }
		}
		return nil
	}

	/// Whether Apple wasn't reached: no network, or no answer in time.
	public var isUnreached: Bool {
		guard kind == .other else { return false }
		let message = message.lowercased()
		return ["error sending request", "timed out", "dns error", "connection", "offline", "network"].contains { message.contains($0) }
	}

	/// What a step with Apple says when it failed (#182, as approved on 13
	/// Nov 2026): `what`, the step, then Apple's own sentence, that Apple
	/// wasn't reached, or that Atelier can't tell why. No code: Apple ID
	/// Log keeps it, with the rest of the message.
	public func explained(_ what: String) -> String {
		if let words = applesWords { return "\(what). Apple says: “\(words)”" }
		switch kind {
		case .other where isUnreached:
			return what == Self.couldNotReachApple
				? "\(what). Check your connection, then try again."
				: "\(what), as Atelier couldn’t reach Apple. Check your connection, then try again."
		case .cancelled, .noTeam:
			return message.isEmpty ? "\(what)." : "\(what): \(message)"
		case .signIn, .developer, .tokenRefused, .other:
			return "\(what), and Atelier can’t tell why. Apple ID Log, on the Apple ID’s page, has what Apple answered."
		}
	}

	/// The step that signs in again with Apple's token, which says only
	/// what to do when Apple wasn't reached.
	public static let couldNotReachApple = "Atelier couldn’t reach Apple"

	/// Apple's note on the last verification code, in plain words, for the
	/// code alert (#182, 13 Nov 2026): isideload words a wrong code
	/// "-21669 - Incorrect verification code.", and Apple not texting one
	/// "<title> - <Apple's sentence>".
	public static func plainCodeNote(_ note: String) -> String {
		if note.hasPrefix("-21669 ") { return "That code wasn’t right." }
		guard let range = note.range(of: " - ", options: .backwards) else { return note }
		let words = note[range.upperBound...].trimmingCharacters(in: .whitespaces)
		return words.isEmpty ? note : words
	}

	/// What it means for the anisette servers a sign-in goes through: a
	/// wrong password, a locked Apple ID, a cancelled code or a refusal of
	/// Apple's developer services is the same through any of them.
	public var routeFailure: AnisetteRoute.Failure {
		if isTryLater { return .refused }
		if isTryAgain { return .tryAgain }
		switch kind {
		case .cancelled, .developer, .noTeam, .tokenRefused: return .final
		case .signIn: return isWrongPassword || isLocked ? .final : .server
		case .other: return .server
		}
	}

	public var description: String {
		switch kind {
		case .signIn: "Apple's sign-in said \(appleCode): \(message)"
		case .developer: "Apple's developer services said \(appleCode): \(message)"
		case .cancelled: "Cancelled at the verification code"
		case .tokenRefused: "Apple refused the token\(appleCode == 0 ? "" : " (\(appleCode))"): \(message)"
		case .noTeam, .other: message
		}
	}
}
