import Foundation
import XCTest
@testable import InstallKit

/// A stand-in for idevice's tunnel: records the calls and fails where told.
final class FakeConnection: RouteAConnection {
	var udidResult: Result<String, RouteAError> = .success("00008130-000A1B2C3D4E5F60")
	/// Upload failures, one per attempt, in order.
	var uploadFailures: [RouteAError] = []
	var installFailure: RouteAError?
	var installedVersion: String? = "2.0"
	var lookupFailure: RouteAError?
	/// Calls cancel partway through the upload.
	var onUpload: (() -> Void)?
	private(set) var calls: [String] = []

	func udid() throws -> String {
		calls.append("udid")
		return try udidResult.get()
	}

	func upload(_ ipa: URL, to remotePath: String, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
		calls.append("upload")
		XCTAssertTrue(remotePath.hasPrefix("/PublicStaging/"))
		progress(5)
		onUpload?()
		if isCancelled() { throw CancellationError() }
		if !uploadFailures.isEmpty { throw uploadFailures.removeFirst() }
		progress(10)
	}

	/// Failures opening installd's service, one per attempt, in order.
	var prepareFailures: [RouteAError] = []

	func prepareInstall() throws {
		calls.append("prepare")
		if !prepareFailures.isEmpty { throw prepareFailures.removeFirst() }
	}

	func install(remotePath: String, progress: (Int) -> Void) throws {
		calls.append("install")
		if let installFailure { throw installFailure }
		progress(50)
		progress(100)
	}

	func installedVersion(of bundleID: String) throws -> String? {
		calls.append("lookup \(bundleID)")
		if let lookupFailure { throw lookupFailure }
		return installedVersion
	}

	func uninstall(_ bundleID: String) throws {
		calls.append("uninstall \(bundleID)")
		if let uninstallFailure { throw uninstallFailure }
	}

	var apps: [InstalledApp] = []
	var uninstallFailure: RouteAError?

	func installedApps() throws -> [InstalledApp] {
		calls.append("list")
		return apps
	}

	/// The app data container house_arrest opens, or its refusal.
	var container: Result<FakeContainer, RouteAError> = .failure(RouteAError(step: .appData, code: 15, message: "UnknownErrorType(\"InstallationLookupFailed\")"))

	func appData(of bundleID: String) throws -> any AppDataContainer {
		calls.append("appData \(bundleID)")
		return try container.get()
	}

	/// installd's records (#99), or why they can't be read.
	var records: Result<[InstalledAppRecord], RouteAError> = .success([])

	func appRecord(of bundleID: String) throws -> InstalledAppRecord? {
		calls.append("record \(bundleID)")
		return try records.get().first { $0.bundleID == bundleID }
	}

	/// The profiles put on through misagent (#49), and the UUIDs that
	/// won't come off.
	private(set) var installedProfiles: [Data] = []
	var stuckProfiles: Set<String> = []
	var profileFailure: RouteAError?

	func installProfile(_ profile: Data) throws {
		calls.append("installProfile")
		if let profileFailure { throw profileFailure }
		installedProfiles.append(profile)
	}

	func removeProfile(_ uuid: String) throws {
		calls.append("removeProfile \(uuid)")
		if stuckProfiles.contains(uuid) { throw RouteAError(step: .profiles, code: -1, message: "MisagentFailure") }
	}

	func close() {
		calls.append("close")
	}
}

final class FakeDevice: RouteADevice, @unchecked Sendable {
	let connection: FakeConnection
	var connectFailure: RouteAError?
	private(set) var connects = 0
	private(set) var pairingFiles: [Data] = []

	init(_ connection: FakeConnection = FakeConnection()) {
		self.connection = connection
	}

	func connect(pairingFile: Data) throws -> any RouteAConnection {
		connects += 1
		pairingFiles.append(pairingFile)
		if let connectFailure { throw connectFailure }
		return connection
	}
}

@MainActor
final class PairingInstallerTests: XCTestCase {
	private var pairing: Data? = Data("pairing".utf8)
	private var statuses: [RouteANetwork.Status] = [.ready]
	private var vpnStarts = 0
	private var vpnOpens = true
	private var devices: ProfileDevices? = .listed(["00008130-000A1B2C3D4E5F60"])
	/// The packages whose profile's devices the installer asked for.
	private var checked: [InstallPackage] = []
	private var noted: [String] = []
	private var unreadable: String?
	private var ipa: URL!

	override func setUp() async throws {
		ipa = FileManager.default.temporaryDirectory.appending(path: "pairing-installer-\(UUID().uuidString).ipa")
		try Data(count: 10).write(to: ipa)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: ipa)
	}

	private func installer(_ device: FakeDevice) -> PairingInstaller {
		let installer = PairingInstaller(.init(
			pairingFile: { self.pairing },
			network: { self.statuses.count > 1 ? self.statuses.removeFirst() : self.statuses[0] },
			startVPN: {
				self.vpnStarts += 1
				return self.vpnOpens
			},
			device: device,
			profileDevices: { package in
				self.checked.append(package)
				return self.devices
			},
			noteUDID: { self.noted.append($0) },
			unreadablePairingFile: { self.unreadable }
		))
		installer.vpnWait = .milliseconds(200)
		installer.vpnPoll = .milliseconds(10)
		return installer
	}

	private var package: InstallPackage {
		InstallPackage(url: ipa, info: IPAInfo(bundleID: "com.example.app", version: "2.0", name: "Example"))
	}

	private func install(_ installer: PairingInstaller) async throws -> (InstallResult, [InstallEvent]) {
		var events: [InstallEvent] = []
		let result = try await installer.install(package) { events.append($0) }
		return (result, events)
	}

	// MARK: Health check

	func testAPairingFileThatCantBeReadSaysWhy() async throws {
		pairing = nil
		unreadable = "The pairing file can't be read while this iPhone is locked."
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .unavailable("The pairing file can't be read while this iPhone is locked."))
		do {
			_ = try await install(installer(FakeDevice()))
			XCTFail("installed without a pairing file")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .couldNotStart("The pairing file can't be read while this iPhone is locked."))
		}
	}

	func testNoPairingFileIsUnavailable() async {
		pairing = nil
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .unavailable(PairingInstaller.noPairingFile))
		XCTAssertEqual(vpnStarts, 0, "no pairing file, so LocalDevVPN isn't opened")
	}

	func testReadyWhenEverythingIsUp() async {
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .ready)
		XCTAssertEqual(vpnStarts, 0)
	}

	func testStartsLocalDevVPNAndWaitsForIt() async {
		statuses = [.vpnOff, .vpnOff, .vpnOff, .ready]
		let installer = installer(FakeDevice())
		// Ready comes on the third poll, which a busy build machine can take
		// longer than 200 ms to reach.
		installer.vpnWait = .seconds(10)
		let health = await installer.healthCheck()
		XCTAssertEqual(health, .ready)
		XCTAssertEqual(vpnStarts, 1)
	}

	func testGivesUpWhenLocalDevVPNNeverConnects() async {
		statuses = [.vpnOff]
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .unavailable(RouteANetwork.Status.vpnOff.problem!))
		XCTAssertEqual(vpnStarts, 1)
	}

	func testLocalDevVPNThatCantBeOpenedIsReportedAtOnce() async {
		statuses = [.vpnOff]
		vpnOpens = false
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .unavailable(RouteANetwork.Status.vpnOff.problem!))
	}

	func testCheckingWithoutStartingTheVPN() async {
		statuses = [.vpnOff]
		let health = await installer(FakeDevice()).check(startingVPN: false)
		XCTAssertEqual(health, .unavailable(RouteANetwork.Status.vpnOff.problem!))
		XCTAssertEqual(vpnStarts, 0)
	}

	func testNoWiFiIsSaid() async {
		statuses = [.noWiFi]
		let health = await installer(FakeDevice()).healthCheck()
		XCTAssertEqual(health, .unavailable(RouteANetwork.Status.noWiFi.problem!))
		XCTAssertEqual(vpnStarts, 0)
	}

	// MARK: Installing

	func testInstallsAndConfirmsTheVersion() async throws {
		let device = FakeDevice()
		let (result, events) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
		XCTAssertEqual(device.connection.calls, ["udid", "prepare", "upload", "install", "lookup com.example.app", "close"])
		XCTAssertEqual(device.pairingFiles, [pairing!])
		XCTAssertEqual(noted, ["00008130-000A1B2C3D4E5F60"])
		let phases = events.compactMap { event -> InstallPhase? in
			if case .phase(let phase) = event { return phase }
			return nil
		}
		XCTAssertEqual(phases.first, .connecting)
		XCTAssertTrue(phases.contains(.downloading(fraction: 0.5)))
		XCTAssertTrue(phases.contains(.downloading(fraction: 1)))
		XCTAssertEqual(phases.last, .installing(fraction: 1))
	}

	func testRetriesABrokenUploadOnce() async throws {
		let device = FakeDevice()
		device.connection.uploadFailures = [RouteAError(step: .upload, code: -1, message: "reset")]
		let (result, events) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
		XCTAssertEqual(device.connects, 2)
		XCTAssertEqual(device.connection.calls, ["udid", "prepare", "upload", "close", "prepare", "upload", "install", "lookup com.example.app", "close"])
		XCTAssertTrue(events.contains(.log("route A: the upload broke off (reset); trying again")))
	}

	/// installd's service opens before the upload, as in the spike; when it
	/// can't, the attempt is tried again like a broken upload (#72).
	func testOpensInstalldBeforeUploadingAndRetriesWhenItCant() async throws {
		let device = FakeDevice()
		device.connection.prepareFailures = [RouteAError(step: .upload, code: -1, message: "Socket(Kind(NotConnected))")]
		let (result, _) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
		XCTAssertEqual(device.connection.calls, ["udid", "prepare", "close", "prepare", "upload", "install", "lookup com.example.app", "close"])
	}

	func testAnUploadThatBreaksTwiceFails() async {
		let device = FakeDevice()
		let broken = RouteAError(step: .upload, code: -1, message: "reset")
		device.connection.uploadFailures = [broken, broken]
		do {
			_ = try await install(installer(device))
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .connectionLost("reset"))
		}
		XCTAssertEqual(device.connects, 2)
	}

	func testAConnectionIOSRefusesSaysToPairAgain() async {
		let device = FakeDevice()
		device.connectFailure = RouteAError(step: .connect, code: -5, message: "pair verify failed")
		do {
			_ = try await install(installer(device))
			XCTFail("expected a failure")
		} catch let failure as InstallFailure {
			XCTAssertEqual(failure, .routeAStep(device.connectFailure!))
			XCTAssertEqual(failure.description, "Atelier couldn't connect to iOS. If this keeps happening, pair this \(ThisDevice.name) again in Settings › Installs › Setup.")
			XCTAssertEqual(failure.technical, "connect failed: pair verify failed (idevice code -5)", "iOS's words, for the log")
		} catch {
			XCTFail("\(error)")
		}
	}

	/// Who signed the app on this iPhone, for the check before an install
	/// (#99), on a connection of its own.
	func testReadsTheRecordOfAnInstalledApp() async throws {
		let device = FakeDevice()
		let record = InstalledAppRecord(bundleID: "com.example.app", signer: InstalledAppRecord.appleSigner, hasAppleAccount: true)
		device.connection.records = .success([record])
		let installer = installer(device)
		let found = try await installer.appRecord(of: "com.example.app")
		XCTAssertEqual(found, record)
		let missing = try await installer.appRecord(of: "com.example.other")
		XCTAssertNil(missing)
		XCTAssertEqual(device.connection.calls, ["record com.example.app", "close", "record com.example.other", "close"])

		device.connection.records = .failure(RouteAError(step: .lookup, code: -1, message: "Socket(Kind(NotConnected))"))
		do {
			_ = try await installer.appRecord(of: "com.example.app")
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .routeAStep(RouteAError(step: .lookup, code: -1, message: "Socket(Kind(NotConnected))")))
			XCTAssertEqual((error as? InstallFailure)?.description, "Atelier couldn't check the apps on this \(ThisDevice.name). Try again.")
		}
	}

	func testAnIPhoneTheProfileDoesntListStopsBeforeUploading() async {
		devices = .listed(["SOME-OTHER-UDID"])
		let device = FakeDevice()
		do {
			_ = try await install(installer(device))
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .deviceNotInProfile)
		}
		XCTAssertEqual(device.connection.calls, ["udid", "close"])
	}

	/// The profile checked is the one signed into the app being installed,
	/// not the default certificate's (#87).
	func testTheProfileCheckedIsTheAppsOwn() async throws {
		let (result, _) = try await install(installer(FakeDevice()))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
		XCTAssertEqual(checked, [package])
	}

	func testUDIDsCompareWithoutCase() async throws {
		devices = .listed(["00008130-000a1b2c3d4e5f60"])
		let (result, _) = try await install(installer(FakeDevice()))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
	}

	func testAnEnterpriseProfileAllowsAnyDevice() async throws {
		devices = .any
		let (result, _) = try await install(installer(FakeDevice()))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
	}

	func testAnUnreadableUDIDDoesntStopTheInstall() async throws {
		let device = FakeDevice()
		device.connection.udidResult = .failure(RouteAError(step: .udid, code: -1, message: "no lockdown"))
		let (result, _) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
		XCTAssertEqual(noted, [])
	}

	func testInstalldsRefusalIsShown() async {
		let device = FakeDevice()
		device.connection.installFailure = RouteAError(step: .install, code: -17, message: "ApplicationVerificationFailed")
		do {
			_ = try await install(installer(device))
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .rejected("ApplicationVerificationFailed"))
		}
	}

	/// installd's own words go in the log, which the failure only sums up:
	/// they name the App ID of the app iOS won't replace (#99).
	func testInstalldsRefusalIsLogged() async {
		let refusal = "MismatchedApplicationIdentifierEntitlement (Upgrade's application-identifier entitlement string (S7GNTEAM42.app.example) does not match installed application's application-identifier string (6XVY5G3U44.com.example.app); rejecting upgrade.)"
		let device = FakeDevice()
		device.connection.installFailure = RouteAError(step: .install, code: 15, message: refusal)
		var events: [InstallEvent] = []
		do {
			_ = try await installer(device).install(package) { events.append($0) }
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .rejected(refusal))
		}
		XCTAssertTrue(events.contains(.log("route A: installd didn't install it: \(refusal) (idevice code 15)")), "\(events)")
	}

	func testTheVersionInstalldListsIsTheOneConfirmed() async throws {
		let device = FakeDevice()
		device.connection.installedVersion = "2.0.1"
		let (result, events) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0.1"))
		XCTAssertTrue(events.contains(.log("installd lists com.example.app at version 2.0.1, not 2.0")))
	}

	func testInstalldsSuccessConfirmsWhenTheLookupFails() async throws {
		let device = FakeDevice()
		device.connection.lookupFailure = RouteAError(step: .lookup, code: -1, message: "timeout")
		let (result, _) = try await install(installer(device))
		XCTAssertEqual(result, .confirmed(version: "2.0"))
	}

	func testCancellingDuringTheUploadStopsBeforeInstalling() async {
		let device = FakeDevice()
		let installer = installer(device)
		let task = Task { try await install(installer) }
		device.connection.onUpload = { task.cancel() }
		do {
			_ = try await task.value
			XCTFail("expected a cancel")
		} catch {
			XCTAssertTrue(error is CancellationError, "\(error)")
		}
		XCTAssertFalse(device.connection.calls.contains("install"))
		XCTAssertEqual(device.connects, 1, "a cancel isn't retried")
	}

	func testNoPairingFileFailsTheInstall() async {
		pairing = nil
		do {
			_ = try await install(installer(FakeDevice()))
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .couldNotStart(PairingInstaller.noPairingFile))
		}
	}

	// MARK: Uninstalling and listing

	func testUninstallsOnAConnectionOfItsOwn() async throws {
		let device = FakeDevice()
		try await installer(device).uninstall("com.example.app")
		XCTAssertEqual(device.connection.calls, ["uninstall com.example.app", "close"])
	}

	func testAnUninstallIOSRefusesSaysSo() async {
		let device = FakeDevice()
		device.connection.uninstallFailure = RouteAError(step: .uninstall, code: -1, message: "not installed")
		do {
			try await installer(device).uninstall("com.example.app")
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .routeAStep(RouteAError(step: .uninstall, code: -1, message: "not installed")))
			XCTAssertEqual((error as? InstallFailure)?.description, "iOS didn't delete the app. Try again, or delete it from the Home Screen.")
		}
	}

	func testListsInstalledApps() async throws {
		let device = FakeDevice()
		let app = InstalledApp(bundleID: "com.example.app", version: "2.0", build: "7", name: "Example")
		device.connection.apps = [app]
		let apps = try await installer(device).installedApps()
		XCTAssertEqual(apps, [app])
	}

	func testPutsANewProfileOnThenTakesTheOldOnesOff() async throws {
		let device = FakeDevice()
		device.connection.stuckProfiles = ["STUCK"]
		let profile = Data("new profile".utf8)
		let removed = try await installer(device).installProfile(profile, replacing: ["OLD", "STUCK", "OLDER"])
		XCTAssertEqual(removed, ["OLD", "OLDER"], "one that won't come off stays, the new one ending last")
		XCTAssertEqual(device.connection.installedProfiles, [profile])
		XCTAssertEqual(device.connection.calls, ["installProfile", "removeProfile OLD", "removeProfile STUCK", "removeProfile OLDER", "close"])
		XCTAssertEqual(device.connects, 1, "on one connection")
	}

	func testTakesProfilesOff() async throws {
		let device = FakeDevice()
		device.connection.stuckProfiles = ["STUCK"]
		let removed = try await installer(device).removeProfiles(["OLD", "STUCK"])
		XCTAssertEqual(removed, ["OLD"])
		XCTAssertEqual(device.connection.calls, ["removeProfile OLD", "removeProfile STUCK", "close"])
	}

	func testANewProfileiOSRefusesLeavesTheOldOnes() async {
		let device = FakeDevice()
		let refusal = RouteAError(step: .profiles, code: -1, message: "MisagentFailure")
		device.connection.profileFailure = refusal
		do {
			_ = try await installer(device).installProfile(Data("new profile".utf8), replacing: ["OLD"])
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .routeAStep(refusal))
		}
		XCTAssertEqual(device.connection.calls, ["installProfile", "close"])
	}

	func testUninstallNeedsAPairingFile() async {
		pairing = nil
		let device = FakeDevice()
		do {
			try await installer(device).uninstall("com.example.app")
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .couldNotStart(PairingInstaller.noPairingFile))
		}
		XCTAssertEqual(device.connects, 0)
	}

	// MARK: App data (#96)

	func testCopiesAnAppsDataOnAConnectionOfItsOwn() async throws {
		let device = FakeDevice()
		let container = FakeContainer.app()
		device.connection.container = .success(container)
		let folder = FileManager.default.temporaryDirectory.appending(path: "app-data-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		var lines: [String] = []
		var fractions: [Double] = []
		let result = try await installer(device).copyAppData(of: "com.example.app", to: folder, freeSpace: nil, log: { lines.append($0) }, progress: { fractions.append($0) })
		XCTAssertEqual(result.files, 4)
		XCTAssertEqual(device.connection.calls, ["appData com.example.app", "close"])
		XCTAssertEqual(container.calls.last, "close")
		XCTAssertTrue(lines.first?.hasPrefix("found 4 files, ") ?? false, "\(lines)")
		XCTAssertEqual(fractions.last, 1)
		XCTAssertEqual(fractions, fractions.sorted())

		let new = FakeContainer.newInstall()
		device.connection.container = .success(new)
		fractions = []
		_ = try await installer(device).restoreAppData(of: "com.example.app", from: folder, log: { _ in }, progress: { fractions.append($0) })
		XCTAssertEqual(new.copied, container.copied)
		XCTAssertEqual(new.calls.last, "close")
		XCTAssertEqual(fractions.last, 1)
	}

	func testAnAppIOSWontOpenIsRefused() async {
		let device = FakeDevice()
		do {
			_ = try await installer(device).copyAppData(of: "com.example.app", to: FileManager.default.temporaryDirectory, freeSpace: nil, log: { _ in }, progress: { _ in })
			XCTFail("expected a refusal")
		} catch {
			XCTAssertEqual(error as? AppDataRefused, AppDataRefused(message: "UnknownErrorType(\"InstallationLookupFailed\") (idevice code 15)"))
		}
		XCTAssertEqual(device.connection.calls, ["appData com.example.app", "close"])
	}

	func testAConnectionThatBreaksDuringACopyIsLost() async {
		let device = FakeDevice()
		let container = FakeContainer.app()
		container.failures["read /Documents/empty"] = RouteAError(step: .appData, code: 1, message: "Socket(Kind(BrokenPipe))")
		device.connection.container = .success(container)
		let folder = FileManager.default.temporaryDirectory.appending(path: "app-data-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		do {
			_ = try await installer(device).copyAppData(of: "com.example.app", to: folder, freeSpace: nil, log: { _ in }, progress: { _ in })
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .connectionLost("Socket(Kind(BrokenPipe))"))
		}
		XCTAssertEqual(container.calls.last, "close")
		XCTAssertEqual(device.connection.calls.last, "close")
	}

	func testAConnectionIOSRefusesStopsTheCopy() async {
		let device = FakeDevice()
		device.connectFailure = RouteAError(step: .connect, code: 1, message: "refused")
		do {
			_ = try await installer(device).copyAppData(of: "com.example.app", to: FileManager.default.temporaryDirectory, freeSpace: nil, log: { _ in }, progress: { _ in })
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, PairingInstaller.failure(device.connectFailure!))
		}
	}

	func testAppDataNeedsAPairingFile() async {
		pairing = nil
		let device = FakeDevice()
		do {
			_ = try await installer(device).copyAppData(of: "com.example.app", to: FileManager.default.temporaryDirectory, freeSpace: nil, log: { _ in }, progress: { _ in })
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .couldNotStart(PairingInstaller.noPairingFile))
		}
		XCTAssertEqual(device.connects, 0)
	}

	func testTellsWhetherAnAppIsInstalled() async {
		let device = FakeDevice()
		device.connection.apps = [InstalledApp(bundleID: "com.example.app", version: "2.0", build: "7", name: "Example")]
		let installer = installer(device)
		let installed = await installer.isInstalled("com.example.app")
		let other = await installer.isInstalled("com.example.other")
		device.connectFailure = RouteAError(step: .connect, code: 1, message: "refused")
		let unknown = await installer.isInstalled("com.example.app")
		XCTAssertEqual(installed, true)
		XCTAssertEqual(other, false)
		XCTAssertNil(unknown)
	}

	func testRouteAShowsConnectingFirst() {
		XCTAssertEqual(installer(FakeDevice()).firstPhase, .connecting)
	}
}

final class RouteANetworkTests: XCTestCase {
	private let wifi = RouteANetwork.Interface(name: "en0", address: "192.168.1.20")
	private let vpn = RouteANetwork.Interface(name: "utun7", address: "10.7.1.1")

	func testReadyWithTheVPNWiFiAndAnOpenPort() async {
		let status = await RouteANetwork.status(interfaces: [wifi, vpn]) { .open }
		XCTAssertEqual(status, .ready)
	}

	/// The interface's name changes between connections (utun10, then utun7).
	func testFindsLocalDevVPNByItsAddressOnAnyInterface() async {
		let renamed = RouteANetwork.Interface(name: "utun10", address: "10.7.1.1")
		let status = await RouteANetwork.status(interfaces: [wifi, renamed]) { .open }
		XCTAssertEqual(status, .ready)
	}

	func testNoTunnelAddressMeansTheVPNIsOff() async {
		let other = RouteANetwork.Interface(name: "utun3", address: "10.8.0.2")
		var probed = false
		let status = await RouteANetwork.status(interfaces: [wifi, other]) {
			probed = true
			return .open
		}
		XCTAssertEqual(status, .vpnOff)
		XCTAssertFalse(probed)
	}

	func testNoWiFiAddress() async {
		let status = await RouteANetwork.status(interfaces: [vpn]) { .open }
		XCTAssertEqual(status, .noWiFi)
	}

	func testARefusedPort() async {
		let status = await RouteANetwork.status(interfaces: [wifi, vpn]) { .failed("refused") }
		XCTAssertEqual(status, .unreachable("refused"))
		XCTAssertNotNil(status.problem)
	}

	func testReadsThisMachinesInterfaces() {
		XCTAssertTrue(RouteANetwork.interfaces().contains { $0.address == "127.0.0.1" })
	}
}

final class PairingFileStoreTests: XCTestCase {
	private func rpPairing() throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: [
			"identifier": "4F1C6A2E-0000-4000-8000-000000000001",
			"public_key": Data(count: 32),
			"private_key": Data(count: 32),
			"alt_irk": Data(count: 16),
		], format: .xml, options: 0)
	}

	func testSavesAndLoadsAnRPPairingFile() throws {
		let store = PairingFileStore(url: FileManager.default.temporaryDirectory.appending(path: "pairing-\(UUID().uuidString)/pairingFile.plist"))
		defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
		XCTAssertFalse(store.exists)
		let data = try rpPairing()
		try store.save(data)
		XCTAssertTrue(store.exists)
		XCTAssertEqual(try store.load(), data)
		XCTAssertNotNil(store.savedAt)
		store.remove()
		XCTAssertFalse(store.exists)
	}

	func testRefusesALockdownFileAndKeepsTheOldOne() throws {
		let store = PairingFileStore(url: FileManager.default.temporaryDirectory.appending(path: "pairing-\(UUID().uuidString)/pairingFile.plist"))
		defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
		let good = try rpPairing()
		try store.save(good)
		let lockdown = try PropertyListSerialization.data(fromPropertyList: [
			"DeviceCertificate": Data(), "HostCertificate": Data(), "HostPrivateKey": Data(),
			"RootCertificate": Data(), "HostID": "x", "SystemBUID": "y", "UDID": "z",
		], format: .xml, options: 0)
		XCTAssertThrowsError(try store.save(lockdown)) { error in
			XCTAssertEqual(error as? PairingFileInspector.Problem, .lockdownRecord)
		}
		XCTAssertEqual(try store.load(), good)
	}

	func testRefusesDamagedAndUnrelatedFiles() throws {
		let short = try PropertyListSerialization.data(fromPropertyList: [
			"identifier": "x", "public_key": Data(count: 31), "private_key": Data(count: 32),
		], format: .xml, options: 0)
		XCTAssertThrowsError(try PairingFileInspector.check(short)) { error in
			XCTAssertEqual(error as? PairingFileInspector.Problem, .damaged(["public_key is not 32 bytes of data"]))
		}
		XCTAssertThrowsError(try PairingFileInspector.check(Data("nope".utf8))) { error in
			XCTAssertEqual(error as? PairingFileInspector.Problem, .notAPairingFile)
		}
	}
}
