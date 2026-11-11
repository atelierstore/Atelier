import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Whether route A can reach iOS's install service right now (#9).
///
/// iOS 27 refuses an app's own connections to the install service, so route
/// A connects to 10.7.0.1, which LocalDevVPN routes back into the phone as if
/// from another computer. On iOS 27.0.1 (docs/install-routes.md):
///
/// - LocalDevVPN gives its tunnel 10.7.1.1, on an interface whose name
///   changes, so the address is what tells it's connected.
/// - Without a Wi-Fi address (`en0`), the phone refuses route A's
///   connections even through LocalDevVPN.
/// - With both, 10.7.0.1 accepts a connection on the port of iOS's
///   RemotePairing service, usually 49152 (`port`).
public enum RouteANetwork {
	/// Where LocalDevVPN routes route A's connections. A setting for it only
	/// lets a user break route A, as the spike's did.
	public static let deviceAddress = "10.7.0.1"
	/// LocalDevVPN's own address on its tunnel.
	public static let tunnelAddress = "10.7.1.1"
	/// The port iOS's RemotePairing service, which route A's pairing file
	/// opens, usually takes, and the one route A tries until it has found
	/// another.
	public static let defaultPort: UInt16 = 49152
	/// The Bonjour type iOS announces its RemotePairing service under, with
	/// its port. Every iPhone, iPad and Apple TV on the network announces one.
	public static let serviceType = "_remotepairing._tcp"

	/// The port route A connects to: where iOS's RemotePairing service last
	/// answered, or the one it announces; `defaultPort` until then. iOS picks
	/// it, and it isn't always 49152: it can be another after a restart, and
	/// it can move while the iPhone runs, so that connections to the old one
	/// are refused (SideStore #1579, StikDebug #480). `checkService` follows
	/// it, and the app keeps it across launches.
	public static var port: UInt16 {
		get { currentPort.value }
		set { currentPort.value = newValue }
	}

	private static let currentPort = LockedPort(defaultPort)

	public enum Status: Equatable, Sendable {
		case ready
		/// No interface has LocalDevVPN's address.
		case vpnOff
		/// LocalDevVPN is on, but the phone has no Wi-Fi address.
		case noWiFi
		/// Both are there, and the install service didn't take the
		/// connection: "refused", or how it failed.
		case unreachable(String)

		/// Why route A can't do what was asked of it: an install, deleting
		/// an app, putting its data back.
		public var problem: String? {
			switch self {
			case .ready: nil
			case .vpnOff: "This needs LocalDevVPN, and it isn't connected. Open LocalDevVPN and tap Connect."
			case .noWiFi: "This needs Wi-Fi. Connect to Wi-Fi, then try again."
			// Settings › Installs › Setup's check offers the fix that fits
			// (`ServiceFix`); turning LocalDevVPN off and on, which this said
			// until 1 Nov 2026, can't help a refusal. How it failed goes in
			// the setup's check.
			case .unreachable: "Atelier couldn't reach iOS through LocalDevVPN. Settings › Installs › Setup says what to try."
			}
		}

		/// What the setup's check says under its headline, which names what
		/// isn't there.
		public var setupProblem: String? {
			switch self {
			case .ready: nil
			case .vpnOff: "Open LocalDevVPN and tap Connect."
			case .noWiFi: "Connect to Wi-Fi. The setup only works on Wi-Fi, even with LocalDevVPN connected."
			case .unreachable(let how): "iOS's install service didn't answer through LocalDevVPN (\(how))."
			}
		}
	}

	public struct Interface: Equatable, Sendable {
		public var name: String
		public var address: String

		public init(name: String, address: String) {
			self.name = name
			self.address = address
		}
	}

	/// What a TCP connection to `deviceAddress:port` did.
	public enum Probe: Equatable, Sendable {
		case open
		/// Refused, timed out or failed otherwise, said briefly.
		case failed(String)

		/// How `failed` says the connection was refused: it got through
		/// LocalDevVPN to the device, and nothing listened on the port.
		public static let refusal = "refused"
	}

	/// The interface that has the Wi-Fi address.
	static let wifiInterface = "en0"

	/// Whether this device has a Wi-Fi address now, without which iOS
	/// refuses route A's connections, so it can't delete an app and install
	/// it again with its data.
	public static var isOnWiFi: Bool {
		interfaces().contains { $0.name == wifiInterface }
	}

	/// The status from the interfaces and, when they look right, a probe of
	/// the install service.
	public static func status(interfaces: [Interface], probe: () async -> Probe) async -> Status {
		guard interfaces.contains(where: { $0.address == tunnelAddress }) else { return .vpnOff }
		guard interfaces.contains(where: { $0.name == wifiInterface }) else { return .noWiFi }
		switch await probe() {
		case .open: return .ready
		case .failed(let how): return .unreachable(how)
		}
	}

	/// The IPv4 addresses of the interfaces that are up.
	public static func interfaces() -> [Interface] {
		var result: [Interface] = []
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0 else { return [] }
		defer { freeifaddrs(head) }
		var pointer = head
		while let current = pointer {
			defer { pointer = current.pointee.ifa_next }
			guard let addr = current.pointee.ifa_addr,
			      addr.pointee.sa_family == sa_family_t(AF_INET),
			      current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
			result.append(Interface(name: String(cString: current.pointee.ifa_name), address: String(cString: host)))
		}
		return result
	}

	// MARK: The RemotePairing service's port

	/// A `_remotepairing._tcp` service Bonjour found and resolved.
	public struct AnnouncedService: Equatable, Sendable {
		/// Its instance name.
		public var name: String
		public var port: UInt16
		/// Its numeric addresses, IPv4 and IPv6, as `numericHost` writes them.
		public var addresses: [String]

		public init(name: String, port: UInt16, addresses: [String]) {
			self.name = name
			self.port = port
			self.addresses = addresses
		}
	}

	/// What looking up the port iOS announces found.
	public enum Discovery: Equatable, Sendable {
		/// This iPhone's own service, on this port.
		case found(UInt16)
		/// Only other devices' services.
		case otherDevices([AnnouncedService])
		/// None, said briefly: nothing announced in time, or why browsing
		/// failed.
		case notFound(String)
		/// iOS didn't let Atelier look: Local Network is off for it
		/// (TN3179's kDNSServiceErr_PolicyDenied).
		case blocked
	}

	/// What the user can do when the install service doesn't answer, from
	/// what `checkService` saw: the Check card's headline and button
	/// (1 Nov 2026). Once one is done, the next check finds the next.
	public enum ServiceFix: Equatable, Sendable {
		/// Refused, and found nowhere else: try again, then restart the
		/// device, which starts the service again (StikDebug #469).
		case restart
		/// Refused, and iOS didn't let Atelier look for where the service
		/// went: Local Network is off for Atelier.
		case allowLocalNetwork
		/// No answer at all, or another error: the connection may not be
		/// getting through LocalDevVPN.
		case reconnectVPN
	}

	/// What `checkService` found.
	public struct ServiceCheck: Equatable, Sendable {
		/// What the last probe of `port` did.
		public var probe: Probe
		/// The port to connect to from now on.
		public var port: UInt16
		/// What happened, for the log, when the port didn't simply answer.
		public var note: String?
		/// What to try, when nothing answered.
		public var fix: ServiceFix?

		public init(probe: Probe, port: UInt16, note: String? = nil, fix: ServiceFix? = nil) {
			self.probe = probe
			self.port = port
			self.note = note
			self.fix = fix
		}
	}

	/// Probes the install service on `port`. When nothing takes the
	/// connection there, looks up the port iOS announces (`discover`) and,
	/// when it's another, probes that one, which is then the port to use
	/// whether it answers or not: it's where iOS says the service is. When
	/// the lookup finds nothing, also tries `defaultPort`, where iOS usually
	/// puts the service back after a restart, and keeps it if it answers.
	public static func checkService(
		on port: UInt16,
		probe: (UInt16) async -> Probe,
		discover: () async -> Discovery
	) async -> ServiceCheck {
		let first = await probe(port)
		guard case .failed(let how) = first else { return ServiceCheck(probe: first, port: port) }
		let device = ThisDevice.name
		let discovery = await discover()
		let lookup: String
		switch discovery {
		case .found(let announced) where announced != port:
			let second = await probe(announced)
			switch second {
			case .open:
				return ServiceCheck(probe: second, port: announced, note: "iOS's pairing service moved from port \(port) to \(announced), as Bonjour announces it")
			case .failed(let again):
				return ServiceCheck(probe: second, port: announced, note: "iOS's pairing service didn't answer on port \(port) (\(how)), nor on \(announced), which Bonjour announces (\(again))", fix: fix(after: again, discovery))
			}
		case .found:
			return ServiceCheck(probe: first, port: port, note: "iOS's pairing service didn't answer on port \(port) (\(how)), though Bonjour announces that port", fix: fix(after: how, discovery))
		case .otherDevices(let services):
			let found = services.map { "port \($0.port) at \($0.addresses.joined(separator: ", "))" }.joined(separator: "; ")
			lookup = "Bonjour found only other devices' (\(found)), not this \(device)'s"
		case .notFound(let why):
			lookup = "Bonjour didn't find this \(device)'s (\(why))"
		case .blocked:
			lookup = "iOS didn't let Atelier look for it with Bonjour, as Local Network is off for Atelier"
		}
		guard port != defaultPort else {
			return ServiceCheck(probe: first, port: port, note: "iOS's pairing service didn't answer on port \(port) (\(how)); \(lookup)", fix: fix(after: how, discovery))
		}
		switch await probe(defaultPort) {
		case .open:
			return ServiceCheck(probe: .open, port: defaultPort, note: "iOS's pairing service didn't answer on port \(port) (\(how)), but did on \(defaultPort); \(lookup)")
		case .failed(let again):
			// The port in use stays: it's where iOS last said the service was.
			return ServiceCheck(probe: first, port: port, note: "iOS's pairing service didn't answer on port \(port) (\(how)), nor on \(defaultPort) (\(again)); \(lookup)", fix: fix(after: how, discovery))
		}
	}

	/// The fix for a probe of the port in use that failed `how`, after a
	/// lookup that found `discovery`. Anything but a refusal may mean the
	/// connection didn't get through LocalDevVPN, which comes first: until
	/// it does, the device can't answer wherever the service is.
	static func fix(after how: String, _ discovery: Discovery) -> ServiceFix {
		guard how == Probe.refusal else { return .reconnectVPN }
		return discovery == .blocked ? .allowLocalNetwork : .restart
	}

	/// The port of this device's own service among `services`: the one at
	/// one of its own addresses, `localAddresses`, as every Apple device on
	/// the network announces one. nil when none is.
	public static func ownPort(among services: [AnnouncedService], localAddresses: Set<String>) -> UInt16? {
		let local = Set(localAddresses.map(normalized))
		return services.first { service in
			service.port > 0 && service.addresses.contains { local.contains(normalized($0)) }
		}?.port
	}

	/// The numeric addresses, IPv4 and IPv6, of the interfaces that are up,
	/// which tell this device's own announced service from other devices'.
	public static func localAddresses() -> Set<String> {
		var result: Set<String> = []
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0 else { return [] }
		defer { freeifaddrs(head) }
		var pointer = head
		while let current = pointer {
			defer { pointer = current.pointee.ifa_next }
			guard let addr = current.pointee.ifa_addr,
			      current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
			      let host = numericHost(UnsafePointer(addr)) else { continue }
			result.insert(normalized(host))
		}
		return result
	}

	/// A socket address as text, such as "192.168.1.20" or "fe80::1%en0";
	/// nil for families other than IPv4 and IPv6.
	public static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
		let length: Int
		switch Int32(address.pointee.sa_family) {
		case AF_INET: length = MemoryLayout<sockaddr_in>.size
		case AF_INET6: length = MemoryLayout<sockaddr_in6>.size
		default: return nil
		}
		var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
		guard getnameinfo(address, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
		return String(cString: host)
	}

	/// The same for an address given as data, as NetService gives them.
	public static func numericHost(_ data: Data) -> String? {
		guard data.count >= MemoryLayout<sockaddr>.size, data.count <= MemoryLayout<sockaddr_storage>.size else { return nil }
		// Copied first, so the address is aligned as getnameinfo expects.
		var storage = sockaddr_storage()
		_ = withUnsafeMutableBytes(of: &storage) { data.copyBytes(to: $0) }
		return withUnsafePointer(to: &storage) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { numericHost($0) }
		}
	}

	/// An address without its IPv6 zone ("%en0"), in lower case, so that
	/// the same address always reads the same.
	static func normalized(_ address: String) -> String {
		String(address.prefix { $0 != "%" }).lowercased()
	}
}

/// `RouteANetwork.port`: set on the main actor, read on the tunnel's thread.
private final class LockedPort: @unchecked Sendable {
	private let lock = NSLock()
	private var port: UInt16

	init(_ port: UInt16) {
		self.port = port
	}

	var value: UInt16 {
		get {
			lock.lock()
			defer { lock.unlock() }
			return port
		}
		set {
			lock.lock()
			port = newValue
			lock.unlock()
		}
	}
}
