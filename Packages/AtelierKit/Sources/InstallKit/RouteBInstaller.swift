#if canImport(Network) && canImport(ObjectiveC)
import Foundation

/// Route B behind `Installer`: one `RouteBSession` per install.
@MainActor
public final class RouteBInstaller: Installer {
	public let route = InstallRoute.localServer

	private let endpointSetting: () -> String
	private let open: (URL) async -> Bool
	private let isRegistered: (@MainActor (String) -> Bool)?
	/// The install running now, for Try again after its alert closed.
	private weak var current: RouteBSession?

	/// `endpointSetting` is the manifest endpoint the user entered (empty for
	/// Atelier's own), `open` opens a URL (`UIApplication.open`), and
	/// `isRegistered` is `canOpenURL` for a scheme, for the install check.
	public init(endpointSetting: @escaping () -> String, open: @escaping (URL) async -> Bool, isRegistered: (@MainActor (String) -> Bool)?) {
		self.endpointSetting = endpointSetting
		self.open = open
		self.isRegistered = isRegistered
	}

	public func healthCheck() async -> RouteHealth {
		switch ManifestEndpoint.resolve(endpointSetting()) {
		case .success: .ready
		case .failure(let problem): .unavailable("The custom manifest in Settings › Installs › Advanced isn't usable. \(problem)")
		}
	}

	public func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		let endpoint: URL
		switch ManifestEndpoint.resolve(endpointSetting()) {
		case .success(let url): endpoint = url
		case .failure(let problem): throw InstallFailure.couldNotStart("The custom manifest in Settings › Installs › Advanced isn't usable. \(problem)")
		}

		let session = RouteBSession(ipa: package.url, info: package.info, endpoint: endpoint, isRegistered: isRegistered)
		current = session
		var logged = 0
		var lastPhase: InstallPhase?
		session.onChange = { [weak session] in
			guard let session else { return }
			for line in session.log.dropFirst(logged) { events(.log(line)) }
			logged = session.log.count
			if let phase = Self.phase(session.phase), phase != lastPhase {
				lastPhase = phase
				events(.phase(phase))
			}
		}
		events(.phase(.waitingForApproval))

		let outcome: RouteBTracker.Outcome
		do {
			outcome = try await session.run(open: open)
		} catch let error as RouteBSession.StartError {
			events(.log(error.description))
			let custom = endpointSetting().isEmpty ? nil : endpoint.host ?? endpoint.absoluteString
			throw InstallFailure.couldNotStart(Self.message(for: error, customServer: custom))
		}
		switch outcome {
		case .installed: return .confirmed(version: package.info.version)
		case .probablyInstalled: return .unconfirmed
		case .notStarted: throw InstallFailure.notStarted
		case .downloadFailed: throw InstallFailure.downloadFailed
		case .notInstalled: throw InstallFailure.notInstalled
		}
	}

	/// Why the install couldn't start, for the user: Atelier's install
	/// server, or the one set in Settings › Installs › Advanced, by its
	/// host, rather than the manifest endpoint and its HTTP status, which
	/// the log keeps (5 Nov 2026).
	static func message(for error: RouteBSession.StartError, customServer host: String?) -> String {
		let fix = "Check it in Settings › Installs › Advanced."
		switch error {
		case .manifestUnreachable:
			if let host { return "Couldn't reach your install server, \(host). \(fix)" }
			return "Couldn't reach Atelier's install server. Check your connection, then try again."
		case .manifestRejected:
			if let host { return "Your install server, \(host), turned this app down. \(fix)" }
			return "Atelier's install server turned this app down. Try again later."
		case .manifestInvalid:
			if let host { return "Your install server, \(host), didn't answer as expected. \(fix)" }
			return "Atelier's install server didn't answer as expected. Try again later."
		case .linkNotOpened:
			return "iOS didn't show the install alert. Try again."
		}
	}

	/// Shows the iOS alert again for the running install, whose alert closed
	/// without installing (`InstallPhase.alertClosed`).
	public func retryAlert() async {
		await current?.retry()
	}

	/// Ends the running install, whose alert closed, as not started.
	public func giveUpAlert() {
		current?.giveUp()
	}

	private static func phase(_ phase: RouteBTracker.Phase) -> InstallPhase? {
		switch phase {
		case .waitingForApproval: .waitingForApproval
		case .alertClosed: .alertClosed
		case .downloading(let fraction): .downloading(fraction: fraction)
		case .installing(let fraction): .installing(fraction: fraction)
		case .finished: nil
		}
	}
}
#endif
