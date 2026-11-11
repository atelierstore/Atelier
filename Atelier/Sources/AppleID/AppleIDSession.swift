import AppleIDKit
import CertKit
import Foundation
import IDevice

/// Free Apple ID signing's calls to Apple (#49), through isideload in
/// IDevice.xcframework (Packages/IDeviceBridge/src/appleid.rs): sign in, then
/// the developer calls Xcode makes for a Personal Team or a paid team. Which
/// anisette servers to sign in through, and the client info to send Apple,
/// come from Atelier's worker (AnisetteList in AppleIDKit).
///
/// Each call blocks, the sign-in for as long as the user takes to type
/// Apple's code, so they run one at a time on a queue of their own, never on
/// Swift's cooperative threads.
final class AppleIDSession: @unchecked Sendable {
	private static let queue = DispatchQueue(label: "com.atelier.apple-id", qos: .userInitiated)

	private let handle: OpaquePointer

	private init(handle: OpaquePointer) {
		self.handle = handle
	}

	deinit {
		atelier_appleid_session_free(handle)
	}

	// MARK: Sign-in

	struct Team: Equatable {
		var id: String
		var name: String?
		/// "Individual" for a free Apple ID's team too, so it can't tell.
		var type: String?
		var status: String?
		/// Whether it's a free Apple ID's team, which Xcode calls a
		/// Personal Team: nil when Apple's answer didn't say.
		var isFree: Bool?
		/// The names of its developer programs, as Apple lists them.
		var memberships: [String] = []
	}

	struct SignedIn {
		var session: AppleIDSession
		/// The team its calls use: the first one Apple lists, until
		/// `chooseTeam` picks another.
		var team: Team
		var teams: [Team]
		/// Whether Apple asked for a verification code.
		var codeAsked: Bool
	}

	/// What Apple wants when it asks for a verification code.
	struct CodeRequest: Equatable {
		struct Number: Equatable, Identifiable {
			var id: UInt32
			/// Masked, as Apple shows it: "+30 ••• •••• ••12".
			var number: String
		}

		/// The code went to a trusted phone number rather than the user's
		/// devices.
		var sms: Bool
		/// The last way failed, so the user has to pick another.
		var unknown: Bool
		var numbers: [Number]
		/// The number the code went to.
		var selected: UInt32?
		/// Why the last code didn't work.
		var lastError: String?

		init?(xml: Data) {
			guard let request = (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any] else {
				return nil
			}
			sms = request["sms"] as? Bool ?? false
			unknown = request["unknown"] as? Bool ?? false
			numbers = (request["numbers"] as? [[String: Any]] ?? []).compactMap { number in
				guard let id = (number["id"] as? NSNumber)?.uint32Value else { return nil }
				return Number(id: id, number: number["number"] as? String ?? "")
			}
			selected = (request["selected"] as? NSNumber)?.uint32Value
			lastError = request["lastError"] as? String
		}

		/// The number the code went to, as Apple shows it.
		var selectedNumber: String? {
			numbers.first { $0.id == selected }?.number
		}
	}

	enum CodeAnswer: Equatable {
		case code(String)
		/// Sends the code by text to this trusted number instead.
		case sms(UInt32)
		/// Sends the code to the user's devices instead.
		case devices
		case resend

		/// As the bridge reads it.
		var wire: String {
			switch self {
			case .code(let code): "code:\(code)"
			case .sms(let id): "sms:\(id)"
			case .devices: "devices"
			case .resend: "resend"
			}
		}
	}

	/// Signs in to Apple through the anisette server at `server`, keeping
	/// that server's state under `storage`, and sending Apple `clientInfo`
	/// in place of the server's when there is one. `askCode` runs on the
	/// Apple ID queue when Apple asks for a verification code, and waits
	/// there for the answer; nil cancels the sign-in.
	static func signIn(
		email: String,
		password: String,
		server: String,
		clientInfo: AnisetteList.ClientInfo?,
		storage: URL,
		askCode: @escaping @Sendable (CodeRequest) -> CodeAnswer?
	) async throws -> SignedIn {
		try await run {
			let prompter = Unmanaged.passRetained(CodePrompter(ask: askCode))
			defer { prompter.release() }
			var handle: OpaquePointer?
			var info: UnsafeMutablePointer<CChar>?
			try withOptionalCString(clientInfo?.clientInfo) { clientInfoString in
				try withOptionalCString(clientInfo?.userAgent) { userAgent in
					try check(atelier_appleid_sign_in(
						email,
						password,
						server,
						clientInfoString,
						userAgent,
						storage.path,
						{ context, request, response, capacity in
							AppleIDSession.answer(context: context, request: request, response: response, capacity: capacity)
						},
						prompter.toOpaque(),
						&handle,
						&info
					))
				}
			}
			defer { atelier_appleid_string_free(info) }
			guard let handle else { throw AppleIDError.unreadable("the sign-in") }
			let session = AppleIDSession(handle: handle)
			let answer = try dictionary(info)
			let teams = (answer["teams"] as? [[String: Any]] ?? []).compactMap { team -> Team? in
				guard let id = team["teamId"] as? String else { return nil }
				return Team(
					id: id,
					name: team["name"] as? String,
					type: team["type"] as? String,
					status: team["status"] as? String,
					isFree: team["free"] as? Bool,
					memberships: team["memberships"] as? [String] ?? []
				)
			}
			guard let teamID = answer["teamId"] as? String else { throw AppleIDError.unreadable("the sign-in") }
			let team = teams.first { $0.id == teamID }
				?? Team(id: teamID, name: answer["teamName"] as? String, type: answer["teamType"] as? String)
			return SignedIn(session: session, team: team, teams: teams, codeAsked: answer["codeAsked"] as? Bool ?? false)
		}
	}

	/// Carries `askCode` through the bridge's context pointer.
	private final class CodePrompter {
		let ask: @Sendable (CodeRequest) -> CodeAnswer?

		init(ask: @escaping @Sendable (CodeRequest) -> CodeAnswer?) {
			self.ask = ask
		}
	}

	/// The bridge's code callback: reads Apple's request, asks, and writes
	/// the answer NUL-terminated into `response`. False cancels.
	private static func answer(
		context: UnsafeMutableRawPointer?,
		request: UnsafePointer<CChar>?,
		response: UnsafeMutablePointer<CChar>?,
		capacity: Int
	) -> Bool {
		guard let context, let request, let response, capacity > 1 else { return false }
		let prompter = Unmanaged<CodePrompter>.fromOpaque(context).takeUnretainedValue()
		guard
			let parsed = CodeRequest(xml: Data(bytes: request, count: strlen(request))),
			let answer = prompter.ask(parsed)
		else { return false }
		let bytes = Array(answer.wire.utf8.prefix(capacity - 1))
		for (index, byte) in bytes.enumerated() {
			response[index] = CChar(bitPattern: byte)
		}
		response[bytes.count] = 0
		return true
	}

	// MARK: Developer calls

	/// Makes the session's calls use `team`, one of those the sign-in
	/// listed, rather than the first.
	func chooseTeam(_ team: Team) async throws {
		try await Self.run { [self] in
			try Self.check(atelier_appleid_choose_team(handle, team.id))
		}
	}

	/// Registers the iPhone with `udid` in the team under `name`, unless it's
	/// there already. `devices` is how many the team has now.
	func registerDevice(name: String, udid: String) async throws -> (added: Bool, devices: Int) {
		try await Self.run { [self] in
			var info: UnsafeMutablePointer<CChar>?
			try Self.check(atelier_appleid_register_device(handle, name, udid, &info))
			defer { atelier_appleid_string_free(info) }
			let answer = try Self.dictionary(info)
			return (answer["added"] as? Bool ?? false, (answer["devices"] as? NSNumber)?.intValue ?? 0)
		}
	}

	struct Certificate: Equatable, Identifiable {
		var name: String?
		var machineName: String?
		var serialNumber: String?
		var status: String?
		var expires: Date?
		/// The certificate itself, when Apple's list has it.
		var content: SigningCertificate?

		init(_ entry: [String: Any]) {
			name = entry["name"] as? String
			machineName = entry["machineName"] as? String
			serialNumber = entry["serialNumber"] as? String
			status = entry["status"] as? String
			expires = entry["expires"] as? Date
			content = (entry["content"] as? Data).flatMap { try? SigningCertificate(der: $0) }
		}

		var id: String { serialNumber ?? name ?? machineName ?? "" }

		/// When Apple made it.
		var made: Date? { content?.notBefore }
	}

	/// The team's iOS development certificates.
	func certificates() async throws -> [Certificate] {
		try await Self.run { [self] in
			var info: UnsafeMutablePointer<CChar>?
			try Self.check(atelier_appleid_certificates(handle, &info))
			defer { atelier_appleid_string_free(info) }
			return (try Self.plist(info) as? [[String: Any]] ?? []).map(Certificate.init)
		}
	}

	struct MadeCertificate {
		/// The certificate and its key, locked with the password given.
		var p12: Data
		var certificate: Certificate
		/// Whether Apple made it now, rather than Atelier finding the one
		/// whose key it kept.
		var made: Bool
		/// How many the team has now.
		var count: Int
	}

	/// This iPhone's development certificate: the one whose key Atelier
	/// kept in `keys`, or a new one Apple makes under `machineName`, with a
	/// key made then and kept there. It never revokes one: at the most the
	/// team may have it throws Apple's 7460
	/// (`AppleIDError.isTooManyCertificates`).
	func certificate(machineName: String, p12Password: String, keys: URL) async throws -> MadeCertificate {
		try await Self.run { [self] in
			var p12: UnsafeMutablePointer<UInt8>?
			var length = 0
			var info: UnsafeMutablePointer<CChar>?
			try Self.check(atelier_appleid_certificate(handle, machineName, p12Password, keys.path, &p12, &length, &info))
			defer {
				atelier_appleid_data_free(p12, length)
				atelier_appleid_string_free(info)
			}
			guard let p12 else { throw AppleIDError.unreadable("the certificate") }
			let answer = try Self.dictionary(info)
			return MadeCertificate(
				p12: Data(bytes: p12, count: length),
				certificate: Certificate(answer),
				made: answer["made"] as? Bool ?? false,
				count: (answer["certificates"] as? NSNumber)?.intValue ?? 0
			)
		}
	}

	/// Revokes the team's development certificate with `serialNumber`: one
	/// the user picked at Apple's limit. Apps signed with it stop opening,
	/// whichever app signed them.
	func revokeCertificate(serialNumber: String) async throws {
		try await Self.run { [self] in
			try Self.check(atelier_appleid_revoke_certificate(handle, serialNumber))
		}
	}

	struct Profile {
		/// The profile as Apple sent it.
		var data: Data
		/// Whether the App ID was added now.
		var added: Bool
		/// As Apple counted them before: a free team may add 10 App IDs in
		/// 7 days.
		var available: Int?
		var max: Int?
		var uuid: String?
		var expires: Date?
		var appIDExpires: Date?
		/// The App Groups asked for that the App ID has now, as the team
		/// names them, and those the team added for it.
		var groups: [String] = []
		var groupsAdded: [String] = []
		/// Why the App ID didn't get the groups asked for, which the
		/// profile then doesn't allow.
		var groupsError: String?
	}

	/// The provisioning profile for the App ID `bundleID`, which is added to
	/// the team first, under `name`, when it isn't there. With `groups`, App
	/// Groups as the team names them, each is added to the team when it
	/// isn't there and assigned to the App ID first, so the profile allows
	/// them; that failing doesn't stop the profile (`groupsError`).
	func profile(bundleID: String, name: String, groups: [String] = []) async throws -> Profile {
		let list = groups.isEmpty ? nil : try PropertyListSerialization.data(fromPropertyList: groups, format: .xml, options: 0)
		return try await Self.run { [self] in
			var data: UnsafeMutablePointer<UInt8>?
			var length = 0
			var info: UnsafeMutablePointer<CChar>?
			try Self.withOptionalCString(list.flatMap { String(data: $0, encoding: .utf8) }) { groups in
				try Self.check(atelier_appleid_profile(handle, bundleID, name, groups, &data, &length, &info))
			}
			defer {
				atelier_appleid_data_free(data, length)
				atelier_appleid_string_free(info)
			}
			guard let data else { throw AppleIDError.unreadable("the profile") }
			let answer = try Self.dictionary(info)
			return Profile(
				data: Data(bytes: data, count: length),
				added: answer["added"] as? Bool ?? false,
				available: (answer["available"] as? NSNumber)?.intValue,
				max: (answer["max"] as? NSNumber)?.intValue,
				uuid: answer["uuid"] as? String,
				expires: answer["expires"] as? Date,
				appIDExpires: answer["appIdExpires"] as? Date,
				groups: answer["groups"] as? [String] ?? [],
				groupsAdded: answer["groupsAdded"] as? [String] ?? [],
				groupsError: answer["groupsError"] as? String
			)
		}
	}

	/// The team's App IDs, and how many more it may add this week: a free
	/// Apple ID's 10 in 7 days.
	func appIDs() async throws -> AppleIDAppIDList {
		try await Self.run { [self] in
			var info: UnsafeMutablePointer<CChar>?
			try Self.check(atelier_appleid_app_ids(handle, &info))
			defer { atelier_appleid_string_free(info) }
			let answer = try Self.dictionary(info)
			let appIDs = (answer["appIds"] as? [[String: Any]] ?? []).compactMap { entry -> AppleIDAppIDList.Entry? in
				guard let identifier = entry["identifier"] as? String else { return nil }
				return AppleIDAppIDList.Entry(identifier: identifier, name: entry["name"] as? String, expires: entry["expires"] as? Date)
			}
			return AppleIDAppIDList(
				appIDs: appIDs,
				max: (answer["max"] as? NSNumber)?.intValue,
				available: (answer["available"] as? NSNumber)?.intValue
			)
		}
	}

	// MARK: Plumbing

	private static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			queue.async {
				continuation.resume(with: Result { try body() })
			}
		}
	}

	/// `string` as a C string for `body`, or NULL.
	private static func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
		guard let string else { return try body(nil) }
		return try string.withCString(body)
	}

	private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
		guard let error else { return }
		let failure = AppleIDError(
			bridgeCode: error.pointee.code,
			appleCode: error.pointee.sub_code,
			message: error.pointee.message.map { String(cString: $0) } ?? ""
		)
		idevice_error_free(error)
		throw failure
	}

	private static func plist(_ text: UnsafeMutablePointer<CChar>?) throws -> Any {
		guard
			let text,
			let value = try? PropertyListSerialization.propertyList(from: Data(bytes: text, count: strlen(text)), format: nil)
		else { throw AppleIDError.unreadable("Apple's answer") }
		return value
	}

	private static func dictionary(_ text: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
		guard let dictionary = try plist(text) as? [String: Any] else { throw AppleIDError.unreadable("Apple's answer") }
		return dictionary
	}
}

extension AppleIDError {
	/// The bridge's error: `bridgeCode` says whose it is, `appleCode` is
	/// Apple's.
	init(bridgeCode: Int32, appleCode: Int32, message: String) {
		let kind: Kind = switch bridgeCode {
		case ATELIER_APPLEID_SIGN_IN_ERROR: .signIn
		case ATELIER_APPLEID_DEVELOPER_ERROR: .developer
		case ATELIER_APPLEID_CANCELLED: .cancelled
		case ATELIER_APPLEID_NO_TEAM: .noTeam
		default: .other
		}
		self.init(kind: kind, appleCode: kind == .signIn || kind == .developer ? appleCode : 0, message: message)
	}
}
