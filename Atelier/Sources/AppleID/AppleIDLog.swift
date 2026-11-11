import AppleIDKit
import Foundation

/// What signing in, installing and renewing with an Apple ID did, line by
/// line (#49), which an Apple ID's page shows under Apple ID Log, with
/// Share. It's for working out what went wrong, such as Apple asking for
/// its code twice (3 Nov 2026), so it never holds the Apple ID, the
/// password or a code.
///
/// The file is Application Support/FreeAppleIDTest's log.txt, where the
/// log has been since the spike's test screen, so its earlier lines stay.
/// Each launch's lines follow one with the date and Atelier's build.
@MainActor
enum AppleIDLog {
	/// The most lines kept; older ones go when Apple ID Log opens.
	static let limit = 1000

	/// Whether this launch has written a line yet.
	private static var started = false

	/// Adds `line`, after this launch's heading the first time, and returns
	/// what it added, for a screen showing the log as it grows.
	@discardableResult
	static func note(_ line: String) -> [String] {
		var lines: [String] = []
		if !started {
			started = true
			lines.append("--- \(date.string(from: .now)), Atelier \(build) ---")
		}
		lines.append("\(time.string(from: .now)) \(line)")
		append(lines)
		return lines
	}

	/// The lines kept from before, the file cut to the last `limit`.
	static func kept() -> [String] {
		guard let url = file, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		let lines = text.split(separator: "\n").map(String.init)
		guard lines.count > limit else { return lines }
		let kept = Array(lines.suffix(limit))
		try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
		return kept
	}

	private static func append(_ lines: [String]) {
		guard let url = file else { return }
		let data = Data(lines.map { $0 + "\n" }.joined().utf8)
		do {
			let handle = try FileHandle(forWritingTo: url)
			defer { try? handle.close() }
			try handle.seekToEnd()
			try handle.write(contentsOf: data)
		} catch {
			// No file yet.
			try? data.write(to: url)
		}
	}

	/// The spike's test screen's folder, left out of backups, as that
	/// screen kept it.
	private static let file: URL? = {
		var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appending(path: "FreeAppleIDTest", directoryHint: .isDirectory)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			try folder.setResourceValues(values)
		} catch {
			return nil
		}
		return folder.appending(path: "log.txt")
	}()

	/// "0.4.0 (439)".
	private static var build: String {
		let info = Bundle.main.infoDictionary
		return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
	}

	private static let time: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "HH:mm:ss"
		return formatter
	}()

	/// "Tue 3 Nov 2026".
	private static let date: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "EEE d MMM yyyy"
		return formatter
	}()

	// MARK: In words

	/// "anisette list of 2026-11-02, from Atelier's worker; trying
	/// mac-ani.jkcoxson.com, ani.iloader.app, …".
	static func describe(_ list: AnisetteList, from origin: AnisetteListSource.Origin, trying servers: [AnisetteList.Server]) -> String {
		let from = switch origin {
		case .worker: "from Atelier's worker"
		case .kept(let date): "the worker's of \(date.formatted(date: .abbreviated, time: .shortened)), as it didn't answer"
		case .builtIn: "the one built in, as the worker didn't answer"
		}
		let clientInfo = list.clientInfo == nil ? "; each server's client info" : ""
		return "anisette list of \(list.updated), \(from); trying \(servers.map(\.host).joined(separator: ", "))\(clientInfo)"
	}

	/// What the log calls the team: "Personal Team" for a free Apple ID's,
	/// as Xcode does. Apple lists that one as "Individual" too, so the type
	/// alone can't tell.
	static func kind(of team: AppleIDSession.Team) -> String {
		switch team.isFree {
		case true?: "Personal Team"
		case false?: team.type.map { "Paid team, \($0)" } ?? "Paid team"
		case nil: team.type.map { "\($0), free or paid unknown" } ?? "Team"
		}
	}

	/// "done, 1 team, using A1B2C3D4E5 (Personal Team; Xcode Free
	/// Provisioning Program), Apple asked for a code".
	static func describe(_ signedIn: AppleIDSession.SignedIn) -> String {
		let teams = signedIn.teams.count == 1 ? "1 team" : "\(signedIn.teams.count) teams"
		let programs = signedIn.team.memberships.isEmpty ? "" : "; \(signedIn.team.memberships.joined(separator: ", "))"
		let code = signedIn.codeAsked ? "Apple asked for a code" : "no code asked"
		return "done, \(teams), using \(signedIn.team.id) (\(kind(of: signedIn.team))\(programs)), \(code)"
	}

	/// What Apple asked for, never the number in full: "Apple asked for a
	/// code, by text to +30 ••• •••• ••12".
	static func describe(_ request: AppleIDSession.CodeRequest) -> String {
		var line: String
		if request.unknown {
			line = "Apple asked which way to send a code, as the last one failed"
		} else if request.sms {
			line = "Apple asked for a code, by text\(request.selectedNumber.map { " to \($0)" } ?? "")"
		} else {
			line = "Apple asked for a code, on your devices"
		}
		if let error = request.lastError, !error.isEmpty {
			line += " (after: \(error))"
		}
		return line
	}

	/// The alert's answer, never the code: "code entered".
	static func describe(_ answer: AppleIDSession.CodeAnswer?, to request: AppleIDSession.CodeRequest) -> String {
		switch answer {
		case .code?: "code entered"
		case .sms(let id)?: "asked for a text to \(request.numbers.first { $0.id == id }?.number ?? "another number")"
		case .devices?: "asked for the code on your devices instead"
		case .resend?: "asked for a new code"
		case nil: "code cancelled"
		}
	}
}
