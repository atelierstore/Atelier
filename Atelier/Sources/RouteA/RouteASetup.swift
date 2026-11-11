import CertKit
import Foundation
import InstallKit
import Network
import Observation
import UIKit
import UniformTypeIdentifiers

/// Route A's setup (#9): the pairing file, LocalDevVPN and Wi-Fi, for
/// Settings › Installs › Setup and for the installer `InstallModel` uses.
@MainActor
@Observable
final class RouteASetup {
	static let shared = RouteASetup()

	/// The URL scheme LocalDevVPN opens to switch back: this Atelier's own,
	/// as a copy of Atelier has `atelier` too (`SwitchBackScheme`, #113).
	/// `atelier` in a build without one.
	static let callbackScheme = SwitchBackScheme.scheme(in: Bundle.main.infoDictionary ?? [:]) ?? "atelier"
	/// Where route A last read this iPhone's UDID, for #45.
	static let udidKey = "deviceUDID"
	/// Whether the UDID kept there came with the certificate this copy of
	/// Atelier came with, from the Atelier that installed it, rather than
	/// from this one's setup (Bool, #113).
	static let udidFromInstallerKey = "deviceUDIDFromInstaller"
	/// The port iOS's pairing service was last found on (Int), so a launch
	/// starts with it rather than 49152 (`RouteANetwork.port`).
	static let portKey = "remotePairingPort"
	/// Whether the setup's check has passed on this iPhone (Bool).
	static let checkPassedKey = "setupCheckPassed"
	/// Whether the setup's last question, automatic updates, has had its
	/// answer (Bool): Turn On Automatic Updates or Not Now. It's asked once,
	/// while they're off (3 Nov 2026).
	static let autoUpdatesAskedKey = "setupAutoUpdatesAsked"
	/// LocalDevVPN on the App Store, the listing SideStore, StikDebug and
	/// Feather link to.
	static let localDevVPNAppStore = URL(string: "https://apps.apple.com/app/id6755608044")!

	private(set) var pairingSavedAt: Date?
	/// As of the last `refresh`; nil before the first.
	private(set) var network: RouteANetwork.Status?
	/// The UDID kept: as the setup read it, or as it came with the
	/// certificate this copy of Atelier came with (#113).
	private var notedUDID: String? = UserDefaults.standard.string(forKey: RouteASetup.udidKey)
	/// `notedUDID` came from the Atelier that installed this copy, until
	/// the setup reads it here (#113).
	private(set) var udidFromInstaller = UserDefaults.standard.bool(forKey: RouteASetup.udidFromInstallerKey)
	/// This iPhone's UDID: the one kept, else the only device the profile
	/// Atelier was installed with lists (#113). iOS doesn't let apps read
	/// it, but a development or ad hoc profile only installs apps on the
	/// devices it lists, so with one listed, that's this iPhone.
	var udid: String? { notedUDID ?? SelfUpdate.shared.installedProfile?.onlyDevice }
	/// `udid` is the only device the profile Atelier was installed with
	/// lists, as nothing has read it here and none came with this copy.
	var udidFromProfile: Bool { notedUDID == nil && udid != nil }
	/// As of launch, the last `refresh` or Atelier last coming to the front.
	private(set) var isVPNInstalled = false
	/// Why the last import failed.
	var importProblem: String?

	private var store: PairingFileStore? { try? PairingFileStore.standard() }
	/// What the last check said about the pairing service's port, so the
	/// log has it once rather than at every check.
	@ObservationIgnored private var lastPortNote: String?
	/// Whether the setup's check has passed since it was set up: the first
	/// setup is over, so its steps no longer get a Live Activity (1 Nov
	/// 2026). Removing the setup starts over.
	private(set) var hasPassedCheck = false
	/// What to try, when the install service didn't answer at its last
	/// probe: the setup check's headline and button (1 Nov 2026).
	private(set) var serviceFix: RouteANetwork.ServiceFix?
	/// Whether the setup check's Try Again is checking.
	private(set) var isCheckingAgain = false
	/// When Try Again last finished, so a tap that changes nothing still
	/// shows that it ran.
	private(set) var checkedAgainAt: Date?

	private init() {
		if let saved = UserDefaults.standard.object(forKey: Self.portKey) as? Int, let port = UInt16(exactly: saved), port > 0 {
			RouteANetwork.port = port
		}
		hasPassedCheck = Self.readPassedCheck()
		pairingSavedAt = store.flatMap { $0.exists ? $0.savedAt ?? .now : nil }
		// Read now, not only once Settings refreshes: installs, Update All
		// and background update runs ask isSetUp without Settings ever
		// opening. Until then it read false, so no install got the
		// system's bar or kept its secrets for a locked iPhone (#72).
		isVPNInstalled = Self.vpnAppInstalled
		PhonePairing.shared.onPaired = { [weak self] in self?.pairingChanged() }
	}

	var isPaired: Bool { pairingSavedAt != nil }
	/// Paired and LocalDevVPN installed: the setup is finished, and installs
	/// go through route A whenever it can install.
	var isSetUp: Bool { isPaired && isVPNInstalled }

	/// Re-reads the pairing file and checks LocalDevVPN, Wi-Fi and the
	/// install service, looking up its port for up to `seconds` when it
	/// doesn't answer.
	func refresh(lookingFor seconds: TimeInterval = 3) async {
		pairingChanged()
		isVPNInstalled = Self.vpnAppInstalled
		network = await Self.networkStatus(lookingFor: seconds)
		notePassedCheck()
		if isPaired, network == .ready,
		   lastDeveloperModeRead.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
			lastDeveloperModeRead = .now
			await readDeveloperMode()
		}
	}

	/// The setup check's Try Again: checks again, looking for where the
	/// install service went for longer than a usual check, in case Bonjour
	/// was slow to answer.
	func checkAgain() async {
		guard !isCheckingAgain else { return }
		isCheckingAgain = true
		await refresh(lookingFor: 10)
		isCheckingAgain = false
		checkedAgainAt = .now
	}

	/// Refreshes whenever the network changes, such as Wi-Fi or LocalDevVPN
	/// coming back, until the calling task is cancelled. The screen's check
	/// otherwise kept the reading from before Wi-Fi had rejoined.
	func watchNetwork() async {
		let monitor = NWPathMonitor()
		let changes = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
			monitor.pathUpdateHandler = { _ in continuation.yield() }
			continuation.onTermination = { _ in monitor.cancel() }
			monitor.start(queue: DispatchQueue(label: "com.atelier.app.routeA.path"))
		}
		for await _ in changes {
			// Lets the interfaces settle; changes come in bursts.
			try? await Task.sleep(for: .seconds(1))
			if Task.isCancelled { return }
			await refresh()
		}
	}

	func pairingChanged() {
		pairingSavedAt = store.flatMap { $0.exists ? $0.savedAt ?? .now : nil }
	}

	/// Checks again whether LocalDevVPN is installed, as when Atelier comes
	/// to the front: it may have been installed or deleted meanwhile.
	func checkVPNInstalled() {
		isVPNInstalled = Self.vpnAppInstalled
	}

	private static var vpnAppInstalled: Bool {
		vpnURL.map { UIApplication.shared.canOpenURL($0) } ?? false
	}

	// MARK: The pairing file

	/// Picks a pairing file made elsewhere, such as on a computer.
	func pickPairingFile() {
		let types = DocumentPicker.types(["com.apple.property-list"], extensions: ["plist", "mobiledevicepairing"])
		DocumentPicker.present(contentTypes: types) { [weak self] urls in
			guard let url = urls.first else { return }
			self?.importPairingFile(at: url)
		}
	}

	func importPairingFile(at url: URL) {
		defer { try? FileManager.default.removeItem(at: url) }
		do {
			guard let store else { throw CocoaError(.fileWriteUnknown) }
			try store.save(Data(contentsOf: url))
			importProblem = nil
		} catch let problem as PairingFileInspector.Problem {
			importProblem = problem.description
		} catch {
			importProblem = "Couldn't import that file: \(error.localizedDescription)"
		}
		pairingChanged()
	}

	/// Removes the setup: the pairing file. Atelier then installs with the
	/// iOS alert, as it does out of the box. Setting it up again asks about
	/// automatic updates again, if they're off.
	func removeSetup() {
		store?.remove()
		pairingChanged()
		hasPassedCheck = false
		UserDefaults.standard.set(false, forKey: Self.checkPassedKey)
		UserDefaults.standard.set(false, forKey: Self.autoUpdatesAskedKey)
	}

	/// As kept; for a setup finished before it was kept, whether route A has
	/// read Developer Mode or the UDID, which took a working setup.
	private static func readPassedCheck() -> Bool {
		let defaults = UserDefaults.standard
		if let passed = defaults.object(forKey: checkPassedKey) as? Bool { return passed }
		return defaults.object(forKey: developerModeCheckedAtKey) != nil || defaults.string(forKey: udidKey) != nil
	}

	/// Keeps that the check passed, once it has with the iPhone paired.
	private func notePassedCheck() {
		guard !hasPassedCheck, isPaired, network == .ready else { return }
		hasPassedCheck = true
		UserDefaults.standard.set(true, forKey: Self.checkPassedKey)
	}

	/// Opens iOS Settings on its main page, where the path to Developer Mode
	/// starts, as AltStore's pairing does; Atelier's own page if iOS
	/// refuses that. The screen gives the path. iOS has no public link to
	/// Developer Mode, and `App-Prefs:` links are unsupported: on iOS 27,
	/// `App-prefs:Privacy&path=DEVELOPER_MODE`,
	/// `App-prefs:root=Privacy&path=DEVELOPER_MODE` and `App-prefs:Privacy`
	/// all landed on Settings › Apps, off the path (22 Oct 2026).
	func openDeveloperModeSettings() async {
		for link in ["App-Prefs:", UIApplication.openSettingsURLString] {
			if let url = URL(string: link), await UIApplication.shared.open(url) {
				PhonePairing.shared.note("Opened Settings with \(link)")
				return
			}
		}
	}

	// MARK: Developer Mode

	/// Where the last Developer Mode reading is kept (Bool), and when it was
	/// read (Date), for the certificate notes (#45).
	static let developerModeKey = "developerModeEnabled"
	static let developerModeCheckedAtKey = "developerModeCheckedAt"

	/// Whether Developer Mode is on, as last read over the tunnel; nil until
	/// then. Logged, and kept for #45: it isn't yet known whether route A's
	/// installs need it.
	@ObservationIgnored private var lastDeveloperModeRead: Date?
	/// Changes when a reading starts and ends, for its watchdog.
	@ObservationIgnored private var readingDeveloperMode = 0
	private(set) var developerMode: Bool? = UserDefaults.standard.object(forKey: RouteASetup.developerModeKey) as? Bool

	/// Reads Developer Mode through LocalDevVPN and logs it when it changes.
	/// Reads the UDID through the same tunnel, so the certificate notes can
	/// check the profile once the setup is finished, before any install
	/// (#45).
	private func readDeveloperMode() async {
		guard let store, store.exists, let pairingFile = try? store.load() else {
			PhonePairing.shared.note("Couldn't read Developer Mode: the pairing file can't be read")
			return
		}
		PhonePairing.shared.note("Reading Developer Mode over LocalDevVPN…")
		// The tunnel calls block with no timeout of their own; say so in the
		// log if one hangs.
		readingDeveloperMode += 1
		let reading = readingDeveloperMode
		Task {
			try? await Task.sleep(for: .seconds(15))
			if reading == readingDeveloperMode { PhonePairing.shared.note("Developer Mode: no answer after 15 s") }
		}
		defer { readingDeveloperMode += 1 }
		let result: Result<(developerMode: Bool, udid: String?), Error> = await Task.detached {
			Result {
				let tunnel = try IDeviceRouteA().connect(pairingFile: pairingFile)
				defer { tunnel.close() }
				guard let connection = tunnel as? IDeviceRouteA.Connection else { throw CocoaError(.featureUnsupported) }
				let on = try connection.developerMode()
				// Developer Mode is what this reading is for; the UDID is a bonus.
				return (on, try? connection.udid())
			}
		}.value
		switch result {
		case .success(let reading):
			let on = reading.developerMode
			PhonePairing.shared.note("Developer Mode is \(on ? "on" : "off")")
			developerMode = on
			UserDefaults.standard.set(on, forKey: Self.developerModeKey)
			UserDefaults.standard.set(Date.now, forKey: Self.developerModeCheckedAtKey)
			if let udid = reading.udid, !udid.isEmpty, udid != notedUDID || udidFromInstaller {
				PhonePairing.shared.note("Read this iPhone's UDID")
				noteUDID(udid)
			}
		case .failure(let error):
			PhonePairing.shared.note("Couldn't read Developer Mode: \(error)")
		}
	}

	// MARK: LocalDevVPN

	private static let vpnURL = URL(string: "localdevvpn://")

	/// Opens LocalDevVPN, which connects and switches back to Atelier: after
	/// one tap the first time, by itself after that. Only while Atelier is
	/// in front. Returns false when LocalDevVPN couldn't be opened.
	func openLocalDevVPN() async -> Bool {
		guard UIApplication.shared.applicationState == .active,
		      let url = URL(string: "localdevvpn://enable?scheme=\(Self.callbackScheme)") else { return false }
		return await UIApplication.shared.open(url)
	}

	/// Opens LocalDevVPN without connecting it, to reconnect it there:
	/// the apps that use LocalDevVPN only link to connecting it, which can't
	/// help while it's connected.
	func openLocalDevVPNApp() {
		guard let url = Self.vpnURL else { return }
		UIApplication.shared.open(url)
	}

	/// Opens Atelier's own page in Settings, which has its Local Network
	/// switch.
	func openOwnSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
	}

	/// Whether a link is LocalDevVPN switching back, which needs nothing done:
	/// through this Atelier's own scheme, or `atelier`, which it opened for
	/// builds before it.
	static func isCallback(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), (url.host ?? "").isEmpty else { return false }
		return scheme == callbackScheme.lowercased() || scheme == "atelier"
	}

	static func networkStatus(lookingFor seconds: TimeInterval = 3) async -> RouteANetwork.Status {
		await RouteANetwork.status(interfaces: RouteANetwork.interfaces()) {
			await shared.probeService(lookingFor: seconds)
		}
	}

	/// Probes iOS's install service on the port its pairing service was last
	/// found on. When nothing answers there, looks up the port iOS announces
	/// through Bonjour for up to `seconds`, as it can move off 49152
	/// (SideStore #1579), and keeps that one for route A's tunnel, in this
	/// launch and the next. Notes what to try when nothing answers.
	private func probeService(lookingFor seconds: TimeInterval) async -> RouteANetwork.Probe {
		let test = Self.testFailure
		let check = await RouteANetwork.checkService(on: RouteANetwork.port) { port in
			if let test {
				return await Self.probe(host: test.host, port: test.port ?? port)
			}
			return await Self.probe(host: RouteANetwork.deviceAddress, port: port)
		} discover: {
			await RemotePairingDiscovery.find(within: seconds)
		}
		if check.port != RouteANetwork.port {
			RouteANetwork.port = check.port
			UserDefaults.standard.set(Int(check.port), forKey: Self.portKey)
		}
		if let note = check.note, note != lastPortNote {
			PhonePairing.shared.note(note)
		}
		lastPortNote = check.note
		serviceFix = check.fix
		return check.probe
	}

	// MARK: Testing the setup check

	/// Settings › Test Actions' Install service failures (#20's hidden test
	/// actions; 1 Nov 2026), to see the setup check's fixes on an
	/// iPhone whose install service answers. The real check runs, with the
	/// real lookup and the real fix; only where each probe connects changes,
	/// to where nothing answers. Installs meet the same failure, as they run
	/// the check first. Picking `refused` with Local Network off for Atelier
	/// shows the Local Network fix for real.
	enum TestFailure: String, CaseIterable {
		/// Port 1 through LocalDevVPN, where nothing listens, so the iPhone
		/// refuses, as when its pairing service has moved or stopped.
		case refused
		/// 192.0.2.1, an address kept for documentation that nothing answers
		/// on, as when LocalDevVPN doesn't pass the connection.
		case noAnswer

		var title: String {
			switch self {
			case .refused: "Refused"
			case .noAnswer: "No Answer"
			}
		}

		var host: String {
			switch self {
			case .refused: RouteANetwork.deviceAddress
			case .noAnswer: "192.0.2.1"
			}
		}

		/// nil keeps the port the check would use.
		var port: UInt16? {
			switch self {
			case .refused: 1
			case .noAnswer: nil
			}
		}
	}

	/// What every probe of the install service meets instead, picked in
	/// Settings › Test Actions and kept across launches, like the
	/// certificate tests, until Off or until the section is hidden; nil
	/// checks for real.
	static var testFailure: TestFailure? {
		let defaults = UserDefaults.standard
		guard defaults.bool(forKey: TestActions.shownKey) else { return nil }
		return defaults.string(forKey: TestActions.checkKey).flatMap(TestFailure.init(rawValue:))
	}

	/// Notes the test failure in use, or that there's none, and checks
	/// again.
	func testFailureChanged() {
		if let failure = Self.testFailure {
			let target = failure.port.map { "\(failure.host):\($0)" } ?? failure.host
			PhonePairing.shared.note("test: every probe of iOS's install service now goes to \(target), where nothing answers")
		} else {
			PhonePairing.shared.note("test: off, checking for real")
		}
		if isSetUp { Task { await refresh() } }
	}

	/// Opens a TCP connection to the install service and closes it again.
	nonisolated private static func probe(host: String, port: UInt16, timeout: TimeInterval = 3) async -> RouteANetwork.Probe {
		await withCheckedContinuation { continuation in
			let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
			let queue = DispatchQueue(label: "com.atelier.app.routeA.probe")
			var finished = false
			func finish(_ result: RouteANetwork.Probe) {
				guard !finished else { return }
				finished = true
				connection.cancel()
				continuation.resume(returning: result)
			}
			connection.stateUpdateHandler = { state in
				switch state {
				case .ready: finish(.open)
				case .waiting(let error), .failed(let error): finish(.failed(Self.brief(error)))
				default: break
				}
			}
			connection.start(queue: queue)
			queue.asyncAfter(deadline: .now() + timeout) { finish(.failed("no answer")) }
		}
	}

	nonisolated private static func brief(_ error: NWError) -> String {
		if case .posix(let code) = error {
			switch code {
			case .ECONNREFUSED: return RouteANetwork.Probe.refusal
			case .EPERM: return "blocked by iOS"
			default: break
			}
		}
		return error.localizedDescription
	}

	// MARK: The installer

	/// Route A's installer, for `RouteSelector`.
	func makeInstaller() -> PairingInstaller {
		PairingInstaller(.init(
			pairingFile: { [weak self] in
				// Read when the install was queued, in case the iPhone has locked since (#72).
				if let held = HeldSecrets.shared.pairingFile { return held }
				guard let store = self?.store, store.exists else { return nil }
				return try? store.load()
			},
			network: { [weak self] in
				let status = await Self.networkStatus()
				self?.network = status
				self?.notePassedCheck()
				return status
			},
			startVPN: { [weak self] in await self?.openLocalDevVPN() ?? false },
			device: IDeviceRouteA(),
			profileDevices: { package in
				// The profile signed into the app, which is the one iOS checks.
				// It isn't always the default certificate's: an update signs
				// with the certificate the app was installed with (#76), and
				// Custom Install… signs with the one picked.
				(try? ProvisioningProfile.embedded(inIPAAt: package.url))?.devices
			},
			noteUDID: { [weak self] udid in self?.noteUDID(udid) },
			unreadablePairingFile: { [weak self] in
				// It's there, but iOS keeps it closed while the iPhone is locked.
				guard let store = self?.store, store.exists, !UIApplication.shared.isProtectedDataAvailable else { return nil }
				return "The pairing file can't be read while this \(ThisDevice.name) is locked. Unlock it, then try again."
			}
		))
	}

	private func noteUDID(_ udid: String) {
		UserDefaults.standard.set(udid, forKey: Self.udidKey)
		UserDefaults.standard.removeObject(forKey: Self.udidFromInstallerKey)
		notedUDID = udid
		udidFromInstaller = false
	}

	/// Notes the UDID that came with the certificate this copy of Atelier
	/// came with (#113), which the Atelier that installed it read during
	/// its setup, unless this one has a UDID already. The setup's own
	/// reading replaces it. Whether the setup's check has passed is kept
	/// first, as a UDID otherwise says so for setups from before it was.
	func noteInstallerUDID(_ udid: String) {
		guard notedUDID == nil else { return }
		let defaults = UserDefaults.standard
		if defaults.object(forKey: Self.checkPassedKey) == nil { defaults.set(hasPassedCheck, forKey: Self.checkPassedKey) }
		defaults.set(udid, forKey: Self.udidKey)
		defaults.set(true, forKey: Self.udidFromInstallerKey)
		notedUDID = udid
		udidFromInstaller = true
	}

	/// This iPhone's UDID, which an Apple ID's team registers it with
	/// (#49): `udid`, or read now through LocalDevVPN.
	func readUDID() async throws -> String {
		if let udid, !udid.isEmpty { return udid }
		let pairingFile = try PairingFileStore.standard().load()
		let read = try await Task.detached {
			let tunnel = try IDeviceRouteA().connect(pairingFile: pairingFile)
			defer { tunnel.close() }
			guard let connection = tunnel as? IDeviceRouteA.Connection else { throw CocoaError(.featureUnsupported) }
			return try connection.udid()
		}.value
		noteUDID(read)
		return read
	}
}
