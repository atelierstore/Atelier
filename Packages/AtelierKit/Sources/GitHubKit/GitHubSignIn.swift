import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signing in with GitHub inside Atelier (#30), through GitHub's web
/// sign-in for OAuth apps: the app opens GitHub's "Authorize Atelier" page
/// in a browser sheet, GitHub sends the browser back through Atelier's
/// Worker to `atelier://github-sign-in`, and the Worker turns the code into
/// a token with the app's client secret, which can't live in the app
/// (infra/manifest-worker/src/github.js).
///
/// It asks for the `repo` scope so private repos work (23 Oct 2026).
/// OAuth apps can't ask for read-only access to private repos, so the token
/// could also write, though Atelier only reads. A random state ties the
/// answer to the request, and PKCE makes a code useless to anyone but the
/// phone that asked for it.
public struct GitHubSignIn: Sendable {
	public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	/// The scheme GitHub's answer comes back on, for the browser sheet.
	public static let callbackScheme = "atelier"
	static let callbackHost = "github-sign-in"

	/// One sign-in, from opening GitHub's page to the token.
	public struct Attempt: Sendable, Equatable {
		/// GitHub's page to open in the browser sheet.
		public var authorizeURL: URL
		var state: String
		var verifier: String
	}

	public struct Account: Sendable, Equatable {
		public var token: String
		public var login: String
		public var avatarURL: URL?
	}

	public enum Problem: Error, Equatable, CustomStringConvertible {
		case denied
		case notEnabled
		case mismatchedState
		case unexpected(String)

		public var description: String {
			switch self {
			case .denied: "Sign-in was cancelled on GitHub."
			case .notEnabled: "GitHub sign-in isn't set up for this build of Atelier."
			case .mismatchedState: "GitHub's answer didn't match this sign-in. Try again."
			case .unexpected(let reason): "GitHub sign-in didn't work: \(reason)"
			}
		}
	}

	private let clientID: String
	/// The Worker: `/github/callback` is the OAuth app's callback URL and
	/// `/github/token` exchanges the code.
	private let worker: URL
	private let load: Load
	private let random: @Sendable () -> String

	public init(
		clientID: String,
		worker: URL,
		load: @escaping Load = { try await URLSession.shared.data(for: $0) },
		random: @escaping @Sendable () -> String = GitHubSignIn.randomString
	) {
		self.clientID = clientID
		self.worker = worker
		self.load = load
		self.random = random
	}

	public var isAvailable: Bool { !clientID.isEmpty }

	/// GitHub's page to sign in on, with this attempt's state and challenge.
	/// With `picksAccount`, GitHub's account picker asks which account to use
	/// even when the browser is signed in to one, rather than going on as it.
	public func start(picksAccount: Bool = false) throws -> Attempt {
		guard isAvailable else { throw Problem.notEnabled }
		let state = random()
		let verifier = random() + random()
		var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
		components.queryItems = [
			URLQueryItem(name: "client_id", value: clientID),
			URLQueryItem(name: "redirect_uri", value: worker.appendingPathComponent("github/callback").absoluteString),
			URLQueryItem(name: "scope", value: "repo"),
			URLQueryItem(name: "state", value: state),
			URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
			URLQueryItem(name: "allow_signup", value: "false"),
		]
		if picksAccount {
			components.queryItems?.append(URLQueryItem(name: "prompt", value: "select_account"))
		}
		return Attempt(authorizeURL: components.url!, state: state, verifier: verifier)
	}

	/// Turns GitHub's answer, `atelier://github-sign-in?code=…&state=…`,
	/// into a token, and reads who signed in.
	public func finish(_ attempt: Attempt, callback: URL) async throws -> Account {
		let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
		func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
		guard callback.scheme == Self.callbackScheme, callback.host == Self.callbackHost, value("state") == attempt.state else {
			throw Problem.mismatchedState
		}
		if let error = value("error") { throw error == "access_denied" ? Problem.denied : Problem.unexpected(error) }
		guard let code = value("code") else { throw Problem.unexpected("no code") }

		var request = URLRequest(url: worker.appendingPathComponent("github/token"), timeoutInterval: 30)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": attempt.verifier])
		let (data, response) = try await load(request)
		let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
		guard let token = json["access_token"] as? String, !token.isEmpty else {
			if (response as? HTTPURLResponse)?.statusCode == 503 || json["error"] as? String == "not_configured" { throw Problem.notEnabled }
			throw Problem.unexpected(json["error"] as? String ?? "no token")
		}
		let user: GitHubAPI.User
		do {
			user = try await GitHubAPI(token: { token }, load: load).user()
		} catch {
			throw Problem.unexpected("GitHub didn't say who you are")
		}
		return Account(token: token, login: user.login, avatarURL: user.avatarURL)
	}

	// MARK: PKCE

	/// 32 random bytes as URL-safe base64: 43 characters.
	public static func randomString() -> String {
		var generator = SystemRandomNumberGenerator()
		let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
		return base64URL(Data(bytes))
	}

	/// `BASE64URL(SHA256(verifier))`, RFC 7636's S256.
	static func challenge(for verifier: String) -> String {
		base64URL(SHA256.hash(Data(verifier.utf8)))
	}

	static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}

/// SHA-256 (FIPS 180-4), for the PKCE challenge. Written out rather than
/// from CryptoKit so GitHubKit keeps building and testing on Linux.
enum SHA256 {
	private static let k: [UInt32] = [
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	]

	static func hash(_ data: Data) -> Data {
		var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
		var message = [UInt8](data)
		let bitLength = UInt64(message.count) * 8
		message.append(0x80)
		while message.count % 64 != 56 { message.append(0) }
		for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

		func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
		var w = [UInt32](repeating: 0, count: 64)
		for chunk in stride(from: 0, to: message.count, by: 64) {
			for i in 0..<16 {
				let j = chunk + i * 4
				w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
			}
			for i in 16..<64 {
				let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
				let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
				w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
			}
			var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
			for i in 0..<64 {
				let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
				let ch = (e & f) ^ (~e & g)
				let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
				let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
				let maj = (a & b) ^ (a & c) ^ (b & c)
				let t2 = s0 &+ maj
				(hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
			}
			for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
		}
		var out = Data()
		for value in h { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) } }
		return out
	}
}
