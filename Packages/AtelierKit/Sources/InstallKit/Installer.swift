import Foundation

/// The install routes (docs/install-routes.md).
public enum InstallRoute: String, Codable, Sendable, CaseIterable {
	/// Route A (#9): a pairing file, LocalDevVPN and installd. Opt-in: used
	/// once Settings › Installs › Setup is finished, while LocalDevVPN is
	/// connected.
	case pairing
	/// Route B (#10): Atelier's loopback server and the iOS install alert.
	/// Works out of the box, and the fallback for everyone.
	case localServer

	/// The name an install's history gives the route. There's no install
	/// method to pick any more, so it says how the app went in.
	public var displayName: String {
		switch self {
		case .pairing: "Pairing"
		case .localServer: "iOS install alert"
		}
	}
}

/// A signed IPA ready to install. SigningKit's `SignedIPA` carries the same.
public struct InstallPackage: Equatable, Sendable {
	public var url: URL
	public var info: IPAInfo

	public init(url: URL, info: IPAInfo) {
		self.url = url
		self.info = info
	}
}

public enum InstallResult: Equatable, Sendable {
	/// The route saw this version installed.
	case confirmed(version: String)
	/// iOS took the app and nothing reported a failure, but nothing confirmed
	/// it either.
	case unconfirmed
}

/// Why an install didn't happen. Its description is what the user is told,
/// in their terms (5 Nov 2026); `technical` keeps what iOS or
/// idevice said, for the install log.
public enum InstallFailure: Error, Equatable, CustomStringConvertible {
	/// The route couldn't start the install.
	case couldNotStart(String)
	/// iOS never asked for the app: the alert was cancelled, or iOS refused
	/// the manifest.
	case notStarted
	/// iOS stopped downloading the app from Atelier.
	case downloadFailed
	/// iOS had the whole app and didn't install it.
	case notInstalled
	/// Route A: the connection to iOS broke off, with idevice's error.
	case connectionLost(String)
	/// Route A: installd refused the app, with its error.
	case rejected(String)
	/// Route A: the provisioning profile doesn't list this iPhone, so iOS
	/// would refuse the app.
	case deviceNotInProfile
	/// Route A: the app iOS can't replace couldn't have its data copied
	/// aside first, so it wasn't deleted (#96).
	case dataNotCopied(AppDataCopyFailure)
	/// Route A: a step around the install failed, such as connecting,
	/// reading which apps are installed or deleting one.
	case routeAStep(RouteAError)

	public var description: String {
		let device = ThisDevice.name
		switch self {
		case .couldNotStart(let why): return why
		case .notStarted: return "The install didn't start. Try again, and tap Install when iOS asks."
		case .downloadFailed: return "The install stopped partway. Keep Atelier open and try again."
		case .notInstalled: return "The app wasn't installed. Your certificate may not be registered for this \(device), or the app may need a newer iOS."
		case .connectionLost: return "The install was interrupted. Check that you're on Wi-Fi with LocalDevVPN connected, then try again."
		case .rejected(let why): return Self.refusal(why)
		case .deviceNotInProfile: return "Your certificate isn't registered for this \(device), so apps signed with it won't open here. Import one that is."
		case .dataNotCopied(let why): return "Couldn't copy the app's data, so it wasn't deleted: \(why)"
		case .routeAStep(let error):
			switch error.step {
			case .connect: return "Atelier couldn't connect to iOS. If this keeps happening, pair this \(device) again in Settings › Installs › Setup."
			case .uninstall: return "iOS didn't delete the app. Try again, or delete it from the Home Screen."
			case .profiles: return "Atelier couldn't manage the profiles on this \(device). Try again."
			case .homeScreen: return "Atelier couldn't read or change the Home Screen. Try again."
			default: return "Atelier couldn't check the apps on this \(device). Try again."
			}
		}
	}

	/// What iOS or idevice said, which the description leaves out, for the
	/// install log.
	public var technical: String? {
		switch self {
		case .connectionLost(let why), .rejected(let why): why
		case .routeAStep(let error): error.description
		case .couldNotStart, .notStarted, .downloadFailed, .notInstalled, .deviceNotInProfile, .dataNotCopied: nil
		}
	}

	/// installd's refusal in a sentence, for its common causes; the rest
	/// say the install log has iOS's reason.
	static func refusal(_ why: String) -> String {
		let matches = { (marks: [String]) in marks.contains { why.localizedCaseInsensitiveContains($0) } }
		if matches(["DeviceOSVersionTooLow", "minimum OS version"]) {
			return "The app needs a newer iOS."
		}
		// 0xe8008018: "The identity used to sign the executable is no longer valid."
		if matches(["0xe8008018", "no longer valid"]) {
			return "iOS wouldn't install the app: the certificate was revoked or has expired."
		}
		// 0xe8008015: "A valid provisioning profile for this executable was not found."
		if matches(["0xe8008015", "valid provisioning profile"]) {
			return "iOS wouldn't install the app: your certificate isn't valid for this \(ThisDevice.name)."
		}
		return "iOS wouldn't install the app. The install log has iOS's reason."
	}
}

/// What an install is doing, whatever the route.
public enum InstallPhase: Equatable, Sendable {
	/// Route A: opening the connection to iOS's install service.
	case connecting
	/// Waiting for the user to accept iOS's install alert.
	case waitingForApproval
	/// Route B: iOS's alert closed and iOS didn't ask for the app. Waits for
	/// Try again (`RouteBInstaller.retryAlert`) or for the user to give up.
	case alertClosed
	/// iOS is fetching the app from Atelier, or route A is sending it.
	case downloading(fraction: Double)
	/// iOS is installing it, with its own progress when known.
	case installing(fraction: Double?)
	/// Route A, before deleting an app iOS can't replace: copying its data
	/// aside, with the fraction copied once there's any to copy (#96).
	case copyingData(fraction: Double?)
	/// Route A, once the new install is in: putting that data back.
	case restoringData(fraction: Double?)
}

public enum InstallEvent: Equatable, Sendable {
	case phase(InstallPhase)
	/// A line for the install log.
	case log(String)
}

/// Whether a route can install right now.
public enum RouteHealth: Equatable, Sendable {
	case ready
	case unavailable(String)
}

/// One install route. The rest of the app goes through `RouteSelector` and
/// never cares which route it got (#11).
@MainActor
public protocol Installer: AnyObject {
	var route: InstallRoute { get }
	/// Route A checks its pairing file and the VPN; route B its manifest
	/// endpoint setting.
	func healthCheck() async -> RouteHealth
	/// Installs the package. Throws `InstallFailure`, or `CancellationError`
	/// when the task is cancelled.
	func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult
}

extension Installer {
	/// What an install shows before the route's first event: route A
	/// connects to iOS; route B waits for the iOS install alert.
	public var firstPhase: InstallPhase {
		route == .pairing ? .connecting : .waitingForApproval
	}
}

/// Which route an install takes. Atelier has one way to install, with no
/// setting for it (29 Oct 2026): every install the user starts is
/// `automatic`, and the ones only route A can do, such as deleting the app
/// first (#20) and automatic updates (#72), are `pairing`.
public enum RoutePreference: String, Codable, Sendable {
	/// Route A when it's set up and healthy, otherwise route B.
	case automatic
	case pairing
	case localServer
}

public enum RouteSelector {
	public struct Unavailable: Error, Equatable, CustomStringConvertible {
		public var route: InstallRoute?
		public var reason: String

		public var description: String {
			switch route {
			// Route A's reasons say what's missing for the install.
			case .pairing?, nil: reason
			case .localServer?: "iOS's install alert can't be used right now: \(reason)"
			}
		}
	}

	/// The installer to use. `automatic` prefers route A and falls back to
	/// route B, which works out of the box; when neither can install, it
	/// gives route B's reason, as route A being out of reach is routine,
	/// such as off Wi-Fi. A route an install needs is used only when it's
	/// healthy, so it says why instead of quietly installing another way.
	@MainActor
	public static func select(_ preference: RoutePreference, from installers: [any Installer]) async throws -> any Installer {
		func installer(_ route: InstallRoute) -> (any Installer)? {
			installers.first { $0.route == route }
		}
		switch preference {
		case .pairing, .localServer:
			let route: InstallRoute = preference == .pairing ? .pairing : .localServer
			guard let chosen = installer(route) else {
				throw Unavailable(route: route, reason: route == .pairing ? "This version of Atelier can't install through its setup." : "it isn't available in this version of Atelier.")
			}
			if case .unavailable(let why) = await chosen.healthCheck() {
				throw Unavailable(route: route, reason: why)
			}
			return chosen
		case .automatic:
			var reason: String?
			for route in [InstallRoute.pairing, .localServer] {
				guard let candidate = installer(route) else { continue }
				switch await candidate.healthCheck() {
				case .ready: return candidate
				case .unavailable(let why): reason = why
				}
			}
			throw Unavailable(route: nil, reason: reason ?? "No install route is available.")
		}
	}
}
