import Foundation

/// The anisette state isideload keeps for one server, the machine Apple
/// knows sign-ins through it by, and the client info it was made as.
///
/// Apple makes a machine as the client info sent while it's made, and
/// answers a sign-in that sends another with -22410, "This action could not
/// be completed", until a new machine is made: other tools' users hit it
/// after Apple refused "macOS" on 20 Nov 2026 and they changed theirs, and
/// making the machine again fixed it (iloader #1304, SideStore #1745). So
/// Atelier notes beside each state the client info it was made as, and
/// before a sign-in that sends another, deletes the state, for isideload to
/// make a new machine. A state with no note was made before Atelier kept
/// them, as the client info Apple refuses since then or the server's own
/// before that, so it goes too.
public struct AnisetteMachine: Sendable {
	/// isideload's state file for the server.
	public let state: URL

	public init(server: AnisetteList.Server, storage: URL) {
		state = server.stateFile(in: storage)
	}

	/// The note, beside the state.
	public var noteFile: URL {
		state.deletingLastPathComponent().appendingPathComponent("client_info")
	}

	/// The client info the state was made as, as noted. Nil without a state
	/// or a note.
	public var madeAs: String? {
		guard FileManager.default.fileExists(atPath: state.path),
		      let data = try? Data(contentsOf: noteFile),
		      let note = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
		      !note.isEmpty
		else { return nil }
		return note
	}

	public enum Readiness: Equatable, Sendable {
		/// Made as the client info the sign-in sends.
		case kept
		/// None yet: the sign-in makes one.
		case new
		/// Made as another client info, or one not noted: deleted, so the
		/// sign-in makes a new one.
		case replaced(madeAs: String?)
	}

	/// Gets the state ready for a sign-in that sends `clientInfo`: kept when
	/// it was made as that, deleted otherwise, for the sign-in to make a new
	/// one; and `clientInfo` noted, as what the state is or will be made as.
	@discardableResult
	public func ready(for clientInfo: String) throws -> Readiness {
		let clientInfo = clientInfo.trimmingCharacters(in: .whitespaces)
		let readiness: Readiness
		if !FileManager.default.fileExists(atPath: state.path) {
			readiness = .new
		} else if let madeAs, madeAs == clientInfo {
			return .kept
		} else {
			readiness = .replaced(madeAs: madeAs)
			try FileManager.default.removeItem(at: state)
		}
		try note(clientInfo)
		return readiness
	}

	/// Notes that the state was made as `clientInfo`: for one that came from
	/// elsewhere, as the installer's (#152).
	public func note(_ clientInfo: String) throws {
		try FileManager.default.createDirectory(at: noteFile.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(clientInfo.trimmingCharacters(in: .whitespaces).utf8).write(to: noteFile, options: .atomic)
	}
}
