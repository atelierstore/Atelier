import Foundation

/// Atelier's install of itself, noted as it goes to iOS (#24). iOS closes
/// Atelier to install over it, so Atelier can't see how it ended: on its
/// next launch, it tells from this note whether the build running is the
/// one it installed, by the token it put in that build's Info.plist.
public struct PendingSelfInstall: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// A newer build, from a source or an IPA.
		case update
		/// The build that's running, installed again from a source or an IPA.
		case install
		/// Signed again with the certificate picked in Custom Install… (#17,
		/// #155).
		case signAgain
		/// Re-sign, as its certificate dies (#20).
		case resign
	}

	/// The key of the token in the Info.plist of the build installed.
	public static let tokenKey = "AtelierInstallToken"

	public var token: String
	public var kind: Kind
	/// The build that was running.
	public var fromVersion: String
	public var fromBuild: String?
	/// The build installed, and its version as its source shows it, such as
	/// 0.2.0-alpha.
	public var version: String
	public var build: String?
	public var displayVersion: String
	/// The certificate it was signed with.
	public var certificateID: UUID?
	public var certificateName: String?
	/// The source it was installed from, for the Library; nil for an IPA.
	public var sourceURL: URL?
	/// The download it installed, deleted once it's installed, as any
	/// install's is; nil for a picked IPA, or the build running signed
	/// again. Optional, so notes saved before it read as having none.
	public var downloadID: UUID?
	/// Its permissions and what won't work in it, as signed: for the
	/// Library once it's installed. The permissions are a JSON
	/// `SignedPermissions`.
	public var permissions: Data?
	public var limits: [String]?
	/// The attempt as it stood when Atelier closed, for Install History.
	public var attempt: InstallAttempt

	public init(
		token: String,
		kind: Kind,
		fromVersion: String,
		fromBuild: String?,
		version: String,
		build: String?,
		displayVersion: String,
		certificateID: UUID?,
		certificateName: String?,
		sourceURL: URL?,
		downloadID: UUID? = nil,
		permissions: Data? = nil,
		limits: [String]? = nil,
		attempt: InstallAttempt
	) {
		self.token = token
		self.kind = kind
		self.fromVersion = fromVersion
		self.fromBuild = fromBuild
		self.version = version
		self.build = build
		self.displayVersion = displayVersion
		self.certificateID = certificateID
		self.certificateName = certificateName
		self.sourceURL = sourceURL
		self.downloadID = downloadID
		self.permissions = permissions
		self.limits = limits
		self.attempt = attempt
	}

	public enum Outcome: Equatable, Sendable {
		/// The build running carries this install's token.
		case installed
		/// The build that was running still is: iOS didn't install it.
		case notInstalled
		/// Another build is running, installed some other way since.
		case superseded
	}

	/// How the install ended, from the build running now: its token, and
	/// its version and build number.
	public func outcome(runningToken: String?, version: String, build: String?) -> Outcome {
		if runningToken == token { return .installed }
		if version == fromVersion, build == fromBuild { return .notInstalled }
		return .superseded
	}

	/// What Atelier says once it's installed, in the install bar and the
	/// notification: "Updated to 0.2.0-alpha".
	public var installedNote: String {
		switch kind {
		case .update: "Updated to \(displayVersion)"
		case .install: "Installed \(displayVersion) again"
		case .signAgain: "Signed again with \(certificateName ?? "another certificate")"
		case .resign: "Re-signed with \(certificateName ?? "another certificate")"
		}
	}

	/// The notification the build installed sends when iOS relaunches it in
	/// the background: "Updated to 0.2.0-alpha", "Atelier is ready to open."
	public func installedNotification(appName: String) -> (title: String, body: String) {
		(installedNote, "\(appName) is ready to open.")
	}

	/// The notification Atelier leaves with iOS as it closes, for when the
	/// build installed doesn't send its own. Atelier can't see iOS finish,
	/// so it says what iOS should have done by then: "Updating Atelier",
	/// "iOS should have installed 0.2.0-alpha by now. Open Atelier to see
	/// how it went."
	public func expectedNotification(appName: String) -> (title: String, body: String) {
		let title = switch kind {
		case .update: "Updating \(appName)"
		case .install: "Installing \(appName) again"
		case .signAgain: "Signing \(appName) again"
		case .resign: "Re-signing \(appName)"
		}
		let installed = switch kind {
		case .update, .install: displayVersion
		case .signAgain, .resign: "it with \(certificateName ?? "another certificate")"
		}
		return (title, "iOS should have installed \(installed) by now. Open \(appName) to see how it went.")
	}

	/// What's left for the user once iOS has the build, under "Go to the
	/// Home Screen" in the install bar (#123): "to finish updating Atelier".
	public static func finishing(_ kind: Kind, appName: String) -> String {
		switch kind {
		case .update: "to finish updating \(appName)"
		case .install: "to finish installing \(appName)"
		case .signAgain: "to finish signing \(appName) again"
		case .resign: "to finish re-signing \(appName)"
		}
	}

	/// What iOS does once Atelier is no longer in front, in the sheet that
	/// says to go to the Home Screen (#123): "iOS installs Atelier
	/// 0.3.0-alpha once you leave it."
	public func onceYouLeave(appName: String) -> String {
		let certificate = certificateName ?? "another certificate"
		return switch kind {
		case .update: "iOS installs \(appName) \(displayVersion) once you leave it."
		case .install: "iOS installs \(appName) \(displayVersion) again once you leave it."
		case .signAgain: "iOS installs \(appName), signed again with \(certificate), once you leave it."
		case .resign: "iOS installs \(appName), re-signed with \(certificate), once you leave it."
		}
	}

	/// What the sheet says next, by whether Atelier may send notifications:
	/// the build installed says how it went in one about 15 s after Atelier
	/// closes, else the one Atelier leaves with iOS does at 30 s.
	public static func afterLeaving(appName: String, notifies: Bool) -> String {
		notifies
			? "\(appName) closes as you leave, and a notification says how it went within half a minute."
			: "\(appName) closes as you leave. Open it again in half a minute to see how it went."
	}

	/// What the sheet says when iOS's alert for the install closed before
	/// iOS asked for the build (#123): iOS may wait for Atelier to leave
	/// first, so Atelier can't tell whether Install or Cancel was tapped.
	public func afterAlertClosed(appName: String) -> String {
		"If you tapped Install, \(onceYouLeave(appName: appName)) If you tapped Cancel, Try Again shows iOS's alert again; \(appName) is already signed."
	}

	/// The attempt as it ended, for Install History.
	public func endedAttempt(_ outcome: Outcome, at now: Date = .now) -> InstallAttempt {
		var attempt = attempt
		attempt.finishedAt = now
		switch outcome {
		case .installed:
			attempt.result = .confirmed
			attempt.log.append("relaunched as \(version)\(build.map { " (\($0))" } ?? ""): installed")
		case .notInstalled:
			attempt.result = .failed
			attempt.error = "iOS didn't install \(displayVersion)."
			attempt.log.append("relaunched as the build that was running, \(fromVersion)\(fromBuild.map { " (\($0))" } ?? ""): iOS didn't install it")
		case .superseded:
			attempt.result = .unconfirmed
			attempt.log.append("relaunched as another build, installed some other way")
		}
		return attempt
	}
}

/// Where `PendingSelfInstall` waits for Atelier's next launch: one JSON file.
public struct PendingSelfInstallStore: Sendable {
	public let file: URL

	public init(file: URL) {
		self.file = file
	}

	/// Application Support/PendingSelfInstall.json.
	public static func standard() throws -> PendingSelfInstallStore {
		let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		return PendingSelfInstallStore(file: support.appending(path: "PendingSelfInstall.json"))
	}

	/// Nil when there's none, or it can't be read.
	public func load() -> PendingSelfInstall? {
		guard let data = try? Data(contentsOf: file) else { return nil }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try? decoder.decode(PendingSelfInstall.self, from: data)
	}

	public func save(_ pending: PendingSelfInstall) throws {
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		try encoder.encode(pending).write(to: file, options: .atomic)
	}

	public func remove() {
		try? FileManager.default.removeItem(at: file)
	}
}
