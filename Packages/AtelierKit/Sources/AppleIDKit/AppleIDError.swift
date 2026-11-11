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
		/// Anything else: no network, an anisette server that doesn't answer.
		case other
	}

	public var kind: Kind
	/// Apple's code, such as -20101 for a wrong password; 0 when there's none.
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

	public var isWrongPassword: Bool { kind == .signIn && appleCode == -20101 }
	public var isLocked: Bool { kind == .signIn && appleCode == -20209 }
	/// "This action cannot be completed at this time": what Apple answered
	/// iloader's servers in October 2026 until each was fixed.
	public var isTryLater: Bool { appleCode == -80045 }
	/// Apple's "This action could not be completed. Try again." (-22421).
	public var isTryAgain: Bool { kind == .signIn && appleCode == -22421 }
	/// The team has the most development certificates Apple allows.
	public var isTooManyCertificates: Bool { kind == .developer && appleCode == 7460 }

	/// What it means for the anisette servers a sign-in goes through: a
	/// wrong password, a locked Apple ID, a cancelled code or a refusal of
	/// Apple's developer services is the same through any of them.
	public var routeFailure: AnisetteRoute.Failure {
		if isTryLater { return .refused }
		if isTryAgain { return .tryAgain }
		switch kind {
		case .cancelled, .developer, .noTeam: return .final
		case .signIn: return isWrongPassword || isLocked ? .final : .server
		case .other: return .server
		}
	}

	public var description: String {
		switch kind {
		case .signIn: "Apple's sign-in said \(appleCode): \(message)"
		case .developer: "Apple's developer services said \(appleCode): \(message)"
		case .cancelled: "Cancelled at the verification code"
		case .noTeam, .other: message
		}
	}
}
