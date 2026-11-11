import Foundation
import InstallKit
import Network

/// Looks up the port of this iPhone's RemotePairing service, the one route
/// A's tunnel opens through LocalDevVPN. iOS picks the port, usually 49152
/// but not always, and announces it through Bonjour as `_remotepairing._tcp`
/// (SideStore #1579, StikDebug #480). Every iPhone, iPad and Apple TV on the
/// network announces one, so this iPhone's is the one at one of its own
/// addresses (`RouteANetwork.ownPort`). Browsing needs Local Network access
/// and the type in NSBonjourServices.
///
/// NWBrowser browses, as it says when iOS doesn't let Atelier look because
/// Local Network is off for it (TN3179), where NetServiceBrowser just finds
/// nothing; the setup check then asks to turn it on (1 Nov 2026).
/// NetService resolves each service found, for its port and addresses.
@MainActor
final class RemotePairingDiscovery: NSObject {
	/// Browses for up to `seconds`, resolving each service found, and ends as
	/// soon as this iPhone's is resolved, or iOS says Local Network is off.
	static func find(within seconds: TimeInterval = 3) async -> RouteANetwork.Discovery {
		// Kept alive by the call, which its handlers need.
		await RemotePairingDiscovery().run(seconds)
	}

	/// kDNSServiceErr_PolicyDenied, which TN3179 says a browse waits with
	/// when Local Network is off for the app.
	private static let policyDenied = -65570

	private var browser: NWBrowser?
	/// Being resolved: NetService needs them kept until they answer.
	private var services: [NetService] = []
	private var resolved: [RouteANetwork.AnnouncedService] = []
	/// Why browsing or resolving failed, when it did.
	private var problem: String?
	private var continuation: CheckedContinuation<RouteANetwork.Discovery, Never>?

	private func run(_ seconds: TimeInterval) async -> RouteANetwork.Discovery {
		await withCheckedContinuation { continuation in
			self.continuation = continuation
			let browser = NWBrowser(for: .bonjour(type: RouteANetwork.serviceType, domain: "local."), using: NWParameters())
			// Started on the main queue, so its handlers run on the main actor.
			browser.stateUpdateHandler = { [weak self] state in
				MainActor.assumeIsolated { self?.browserChanged(state) }
			}
			browser.browseResultsChangedHandler = { [weak self] results, _ in
				MainActor.assumeIsolated { self?.didFind(results) }
			}
			self.browser = browser
			browser.start(queue: .main)
			Task { [weak self] in
				try? await Task.sleep(for: .seconds(seconds))
				self?.finish(nil)
			}
		}
	}

	private func browserChanged(_ state: NWBrowser.State) {
		switch state {
		case .waiting(let error), .failed(let error):
			if case .dns(let code) = error, Int(code) == Self.policyDenied {
				finish(.blocked)
				return
			}
			problem = "\(error)"
			// Nothing more comes once the browse itself has failed.
			if case .failed = state, services.isEmpty { finish(nil) }
		default:
			break
		}
	}

	private func didFind(_ results: Set<NWBrowser.Result>) {
		guard continuation != nil else { return }
		for result in results {
			// The same service can come once per interface.
			guard case let .service(name, _, domain, _) = result.endpoint,
			      !services.contains(where: { $0.name == name }) else { continue }
			let service = NetService(domain: domain.isEmpty ? "local." : domain, type: RouteANetwork.serviceType + ".", name: name)
			services.append(service)
			service.delegate = self
			// On the main run loop in every mode, so a scrolling list doesn't
			// hold the answers back.
			service.remove(from: .current, forMode: .default)
			service.schedule(in: .main, forMode: .common)
			service.resolve(withTimeout: 2)
		}
	}

	/// Called again as more of a service's addresses arrive.
	private func didResolve(_ service: NetService) {
		guard continuation != nil, let port = UInt16(exactly: service.port), port > 0 else { return }
		let addresses = (service.addresses ?? []).compactMap { RouteANetwork.numericHost($0) }
		guard !addresses.isEmpty else { return }
		resolved.removeAll { $0.name == service.name }
		resolved.append(.init(name: service.name, port: port, addresses: addresses))
		if let own = RouteANetwork.ownPort(among: resolved, localAddresses: RouteANetwork.localAddresses()) {
			finish(.found(own))
		}
	}

	/// Ends with `result`, or with what was found when it's nil.
	private func finish(_ result: RouteANetwork.Discovery?) {
		guard let continuation else { return }
		self.continuation = nil
		browser?.stateUpdateHandler = nil
		browser?.browseResultsChangedHandler = nil
		browser?.cancel()
		browser = nil
		for service in services {
			service.delegate = nil
			service.stop()
		}
		let found = services.count
		services = []
		let outcome: RouteANetwork.Discovery
		if let result {
			outcome = result
		} else if !resolved.isEmpty {
			outcome = .otherDevices(resolved)
		} else if let problem {
			outcome = .notFound(problem)
		} else {
			outcome = .notFound(found == 0 ? "nothing announced in time" : "\(found) found, none resolved in time")
		}
		continuation.resume(returning: outcome)
	}

	/// Bonjour's error code, from a delegate's error dictionary.
	nonisolated private static func code(_ errors: [String: NSNumber]) -> String {
		errors[NetService.errorCode].map { "Bonjour error \($0.intValue)" } ?? "Bonjour error"
	}
}

// The services are scheduled on the main run loop, so their delegate methods
// are called on the main thread.
extension RemotePairingDiscovery: NetServiceDelegate {
	nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
		MainActor.assumeIsolated { didResolve(sender) }
	}

	nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
		let why = "\(sender.name): \(Self.code(errorDict))"
		MainActor.assumeIsolated { problem = problem ?? why }
	}
}
