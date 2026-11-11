import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import InstallKit

/// Following iOS's RemotePairing service off 49152 (SideStore #1579): which
/// announced service is this device's, and when to look the port up.
final class RemotePairingPortTests: XCTestCase {
	private func service(_ name: String, port: UInt16, _ addresses: String...) -> RouteANetwork.AnnouncedService {
		RouteANetwork.AnnouncedService(name: name, port: port, addresses: addresses)
	}

	// MARK: Which service is this device's

	/// Every Apple device on the network announces one: this device's is the
	/// one at one of its own addresses.
	func testTheOwnPortIsTheServiceAtThisDevicesAddress() {
		let services = [
			service("apple-tv", port: 49152, "192.168.1.30", "fe80::aa:bbff:fecc:dd01%en0"),
			service("this-iphone", port: 52107, "fe80::1c2b:3dff:fe4e:5f60%en0", "192.168.1.20"),
		]
		let local: Set<String> = ["127.0.0.1", "10.7.1.1", "192.168.1.20"]
		XCTAssertEqual(RouteANetwork.ownPort(among: services, localAddresses: local), 52107)
	}

	func testAnIPv6AddressMatchesWithoutItsZoneOrCase() {
		let services = [service("this-iphone", port: 49898, "FE80::1C2B:3DFF:FE4E:5F60%en0")]
		let local: Set<String> = ["fe80::1c2b:3dff:fe4e:5f60"]
		XCTAssertEqual(RouteANetwork.ownPort(among: services, localAddresses: local), 49898)
	}

	func testNoOwnPortAmongOtherDevicesServices() {
		let services = [service("apple-tv", port: 49152, "192.168.1.30")]
		XCTAssertNil(RouteANetwork.ownPort(among: services, localAddresses: ["127.0.0.1", "192.168.1.20"]))
		XCTAssertNil(RouteANetwork.ownPort(among: [], localAddresses: ["192.168.1.20"]))
	}

	// MARK: When to look it up

	/// Answers `open` on the ports given, and records the ports probed.
	private final class Prober: @unchecked Sendable {
		let open: Set<UInt16>
		private(set) var probed: [UInt16] = []

		init(open: Set<UInt16>) {
			self.open = open
		}

		func probe(_ port: UInt16) -> RouteANetwork.Probe {
			probed.append(port)
			return open.contains(port) ? .open : .failed("refused")
		}
	}

	func testAPortThatAnswersIsKeptWithoutLookingUp() async {
		let prober = Prober(open: [49152])
		var lookedUp = false
		let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: {
			lookedUp = true
			return .found(52107)
		}
		XCTAssertEqual(check, RouteANetwork.ServiceCheck(probe: .open, port: 49152))
		XCTAssertFalse(lookedUp)
		XCTAssertEqual(prober.probed, [49152])
	}

	/// An "iOS install service refused" of 1 Nov 2026: nothing on 49152,
	/// and the service answers on the port iOS announces.
	func testARefusedPortFollowsThePortIOSAnnounces() async {
		let prober = Prober(open: [52107])
		let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: { .found(52107) }
		XCTAssertEqual(check.probe, .open)
		XCTAssertEqual(check.port, 52107)
		XCTAssertEqual(prober.probed, [49152, 52107])
		XCTAssertEqual(check.note, "iOS's pairing service moved from port 49152 to 52107, as Bonjour announces it")
	}

	/// After a restart, back on 49152 while 52107 was kept from before.
	func testAKeptPortThatMovedBackIsFollowedToo() async {
		let prober = Prober(open: [49152])
		let check = await RouteANetwork.checkService(on: 52107) { prober.probe($0) } discover: { .found(49152) }
		XCTAssertEqual(check.probe, .open)
		XCTAssertEqual(check.port, 49152)
		XCTAssertEqual(prober.probed, [52107, 49152])
	}

	/// It's where iOS says the service is, so the tunnel tries it next time
	/// even though it didn't answer this time.
	func testTheAnnouncedPortIsKeptWhenItDoesntAnswerEither() async {
		let prober = Prober(open: [])
		let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: { .found(52107) }
		XCTAssertEqual(check.probe, .failed("refused"))
		XCTAssertEqual(check.port, 52107)
		XCTAssertEqual(prober.probed, [49152, 52107])
		XCTAssertEqual(check.note, "iOS's pairing service didn't answer on port 49152 (refused), nor on 52107, which Bonjour announces (refused)")
		XCTAssertEqual(check.fix, .restart)
	}

	func testTheSamePortAnnouncedIsntProbedAgain() async {
		let prober = Prober(open: [])
		let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: { .found(49152) }
		XCTAssertEqual(check.probe, .failed("refused"))
		XCTAssertEqual(check.port, 49152)
		XCTAssertEqual(prober.probed, [49152])
		XCTAssertEqual(check.note, "iOS's pairing service didn't answer on port 49152 (refused), though Bonjour announces that port")
		XCTAssertEqual(check.fix, .restart)
	}

	func testThePortStaysWhenBonjourDoesntFindThisDevices() async {
		let device = ThisDevice.name
		let cases: [(RouteANetwork.Discovery, String)] = [
			(.notFound("Bonjour error -72008"), "iOS's pairing service didn't answer on port 49152 (refused); Bonjour didn't find this \(device)'s (Bonjour error -72008)"),
			(.otherDevices([service("apple-tv", port: 49152, "192.168.1.30")]), "iOS's pairing service didn't answer on port 49152 (refused); Bonjour found only other devices' (port 49152 at 192.168.1.30), not this \(device)'s"),
			(
				.otherDevices([service("apple-tv", port: 49152, "192.168.1.30"), service("ipad", port: 50311, "192.168.1.31", "fe80::1%en0")]),
				"iOS's pairing service didn't answer on port 49152 (refused); Bonjour found only other devices' (port 49152 at 192.168.1.30; port 50311 at 192.168.1.31, fe80::1%en0), not this \(device)'s"
			),
		]
		for (discovery, note) in cases {
			let prober = Prober(open: [])
			let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: { discovery }
			XCTAssertEqual(check, RouteANetwork.ServiceCheck(probe: .failed("refused"), port: 49152, note: note, fix: .restart))
			XCTAssertEqual(prober.probed, [49152])
		}
	}

	// MARK: Back to 49152

	/// After a restart iOS usually puts the service back on 49152, which a
	/// blocked or empty lookup can't say.
	func testWhenTheLookupFindsNothingThePortGoesBackTo49152IfItAnswers() async {
		let device = ThisDevice.name
		let prober = Prober(open: [49152])
		let check = await RouteANetwork.checkService(on: 52107) { prober.probe($0) } discover: { .notFound("nothing announced in time") }
		XCTAssertEqual(check, RouteANetwork.ServiceCheck(
			probe: .open,
			port: 49152,
			note: "iOS's pairing service didn't answer on port 52107 (refused), but did on 49152; Bonjour didn't find this \(device)'s (nothing announced in time)"
		))
		XCTAssertEqual(prober.probed, [52107, 49152])
	}

	func testThePortInUseStaysWhen49152DoesntAnswerEither() async {
		let prober = Prober(open: [])
		let check = await RouteANetwork.checkService(on: 52107) { prober.probe($0) } discover: { .blocked }
		XCTAssertEqual(check, RouteANetwork.ServiceCheck(
			probe: .failed("refused"),
			port: 52107,
			note: "iOS's pairing service didn't answer on port 52107 (refused), nor on 49152 (refused); iOS didn't let Atelier look for it with Bonjour, as Local Network is off for Atelier",
			fix: .allowLocalNetwork
		))
		XCTAssertEqual(prober.probed, [52107, 49152])
	}

	/// Bonjour says the service is on the port in use, so 49152 isn't tried.
	func testAnAnnouncedPortThatRefusesIsntLeftFor49152() async {
		let prober = Prober(open: [49152])
		let check = await RouteANetwork.checkService(on: 52107) { prober.probe($0) } discover: { .found(52107) }
		XCTAssertEqual(check.port, 52107)
		XCTAssertEqual(check.fix, .restart)
		XCTAssertEqual(prober.probed, [52107])
	}

	// MARK: What to try

	func testABlockedLookupAsksForLocalNetwork() async {
		let prober = Prober(open: [])
		let check = await RouteANetwork.checkService(on: 49152) { prober.probe($0) } discover: { .blocked }
		XCTAssertEqual(check, RouteANetwork.ServiceCheck(
			probe: .failed("refused"),
			port: 49152,
			note: "iOS's pairing service didn't answer on port 49152 (refused); iOS didn't let Atelier look for it with Bonjour, as Local Network is off for Atelier",
			fix: .allowLocalNetwork
		))
	}

	/// No answer may mean the connection never got through LocalDevVPN, so
	/// that comes first, even when Local Network is off too.
	func testNoAnswerAsksToReconnectLocalDevVPN() async {
		for discovery in [RouteANetwork.Discovery.notFound("nothing announced in time"), .blocked, .found(49152)] {
			let check = await RouteANetwork.checkService(on: 49152) { _ in .failed("no answer") } discover: { discovery }
			XCTAssertEqual(check.fix, .reconnectVPN, "\(discovery)")
		}
		let other = await RouteANetwork.checkService(on: 49152) { _ in .failed("blocked by iOS") } discover: { .notFound("nothing announced in time") }
		XCTAssertEqual(other.fix, .reconnectVPN)
	}

	/// The fix follows the port in use: here the announced one, which got no
	/// answer, though the old one refused.
	func testTheFixFollowsThePortInUse() async {
		let check = await RouteANetwork.checkService(on: 49152) { $0 == 49152 ? .failed("refused") : .failed("no answer") } discover: { .found(52107) }
		XCTAssertEqual(check.port, 52107)
		XCTAssertEqual(check.fix, .reconnectVPN)
	}

	func testAServiceThatAnswersNeedsNoFix() async {
		let moved = await RouteANetwork.checkService(on: 49152) { $0 == 52107 ? .open : .failed("refused") } discover: { .found(52107) }
		XCTAssertNil(moved.fix)
		let open = await RouteANetwork.checkService(on: 49152) { _ in .open } discover: { .blocked }
		XCTAssertNil(open.fix)
	}

	/// The app's probe says "refused" for ECONNREFUSED, which the fix reads.
	func testTheRefusalIsTheProbesWord() {
		XCTAssertEqual(RouteANetwork.Probe.refusal, "refused")
		XCTAssertEqual(RouteANetwork.fix(after: "refused", .notFound("x")), .restart)
		XCTAssertEqual(RouteANetwork.fix(after: "Refused", .notFound("x")), .reconnectVPN)
	}

	/// What installs say when route A's check fails points to the card,
	/// which says what the check found.
	func testTheProblemPointsToTheSetupScreen() {
		XCTAssertEqual(
			RouteANetwork.Status.unreachable("refused").problem,
			"Atelier couldn't reach iOS through LocalDevVPN. Settings › Installs › Setup says what to try."
		)
		XCTAssertEqual(RouteANetwork.Status.unreachable("refused").setupProblem, "iOS's install service didn't answer through LocalDevVPN (refused).")
		XCTAssertEqual(RouteANetwork.Status.noWiFi.problem, "This needs Wi-Fi. Connect to Wi-Fi, then try again.")
		XCTAssertEqual(RouteANetwork.Status.noWiFi.setupProblem, "Connect to Wi-Fi. The setup only works on Wi-Fi, even with LocalDevVPN connected.")
		XCTAssertNil(RouteANetwork.Status.ready.setupProblem)
	}

	// MARK: Addresses

	func testReadsAnIPv4AddressAsNetServiceGivesIt() {
		var address = sockaddr_in()
		#if canImport(Darwin)
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		#endif
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = UInt16(52107).bigEndian
		XCTAssertEqual(inet_pton(AF_INET, "192.168.1.20", &address.sin_addr), 1)
		let data = withUnsafeBytes(of: &address) { Data($0) }
		XCTAssertEqual(RouteANetwork.numericHost(data), "192.168.1.20")
	}

	func testReadsAnIPv6Address() {
		var address = sockaddr_in6()
		#if canImport(Darwin)
		address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
		#endif
		address.sin6_family = sa_family_t(AF_INET6)
		XCTAssertEqual(inet_pton(AF_INET6, "2a01:e0a:1f:2c40::17", &address.sin6_addr), 1)
		let data = withUnsafeBytes(of: &address) { Data($0) }
		XCTAssertEqual(RouteANetwork.numericHost(data), "2a01:e0a:1f:2c40::17")
	}

	func testDataThatIsntAnAddressReadsAsNothing() {
		XCTAssertNil(RouteANetwork.numericHost(Data([1, 2])))
		XCTAssertNil(RouteANetwork.numericHost(Data(count: 200)))
	}

	func testThisMachinesAddressesIncludeLoopback() {
		XCTAssertTrue(RouteANetwork.localAddresses().contains("127.0.0.1"))
	}
}
