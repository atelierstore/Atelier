import Foundation

/// Apple's token for its developer services, `com.apple.gs.xcode.auth`,
/// which signing in with an Apple ID gets (#182). Every call Atelier makes
/// with an Apple ID goes to those services with it: teams, devices,
/// certificates, App IDs and profiles. With it, Atelier signs in again
/// without the password or Apple's code until Apple says it ends, or
/// refuses it. It goes with the account's ID at Apple, its adsid, and with
/// the machine the sign-in was made as: the anisette server, whose state
/// Atelier keeps, and what the sign-in sent Apple in place of the server's
/// client info.
///
/// Until Apple ends it, it's as good as a sign-in for developer services,
/// so it gets the password's care: the Keychain, this device only, never
/// in a log or a backup (`CertificateStore.setAppleIDToken`). Apple's
/// session itself, which can ask for tokens for Apple's other services,
/// is never kept.
public struct AppleIDToken: Codable, Equatable, Sendable {
	/// Apple's ID for the account, which goes with the token.
	public var adsid: String
	public var token: String
	/// As Apple gave them: how long it lasts, in seconds, and when it ends,
	/// in a unit Apple doesn't say (`endsAt`).
	public var duration: UInt64
	public var expiry: UInt64
	/// When Atelier got it.
	public var receivedAt: Date
	/// The anisette server the sign-in went through, as
	/// "https://ani.example.com": its state is the machine Apple knows the
	/// token by.
	public var server: String
	/// What the sign-in sent Apple in place of the server's client info and
	/// user agent, when it did.
	public var clientInfo: String?
	public var userAgent: String?

	public init(adsid: String, token: String, duration: UInt64, expiry: UInt64, receivedAt: Date = .now, server: String, clientInfo: String? = nil, userAgent: String? = nil) {
		self.adsid = adsid
		self.token = token
		self.duration = duration
		self.expiry = expiry
		self.receivedAt = receivedAt
		self.server = server
		self.clientInfo = clientInfo
		self.userAgent = userAgent
	}

	/// When Apple says it ends. Apple doesn't say in what unit `expiry` is:
	/// it's read as milliseconds since 1970, then as seconds, when it reads
	/// as a time from 2001 on; otherwise the end is when Atelier got it plus
	/// how long it lasts. Nil when Apple said neither.
	public var endsAt: Date? {
		let milliseconds: UInt64 = 1_000_000_000_000
		let seconds: UInt64 = 1_000_000_000
		if expiry >= milliseconds { return Date(timeIntervalSince1970: TimeInterval(expiry) / 1000) }
		if expiry >= seconds { return Date(timeIntervalSince1970: TimeInterval(expiry)) }
		if duration > 0 { return receivedAt.addingTimeInterval(TimeInterval(duration)) }
		return nil
	}

	/// How long before Apple's end for it that it isn't tried any more: a
	/// round of installs takes minutes, and shouldn't find it ended
	/// halfway. The iPhone-only installer's margin too.
	public static let margin: TimeInterval = 15 * 60

	/// Whether it's worth trying at `now`: Apple refuses one that ended, and
	/// one whose end Apple didn't say may still do.
	public func isUsable(at now: Date = .now) -> Bool {
		guard let endsAt else { return true }
		return now.addingTimeInterval(Self.margin) < endsAt
	}

	/// How long it lasts from when Atelier got it, as Apple says: what
	/// decides whether a token can take the password's place for the
	/// weekly renewals (#182). Nil when Apple didn't say.
	public var lifetime: TimeInterval? {
		endsAt.map { $0.timeIntervalSince(receivedAt) }
	}
}

/// Never the token itself, so that it can't end up in a log by way of
/// `String(describing:)` or `print`.
extension AppleIDToken: CustomStringConvertible, CustomDebugStringConvertible {
	public var description: String {
		"Apple's token through \(server)\(endsAt.map { ", ending \($0)" } ?? "")"
	}

	public var debugDescription: String { description }
}
