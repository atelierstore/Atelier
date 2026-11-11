import Foundation

// Route A (#9): the pairing file, LocalDevVPN and installd, through idevice.
// The steps that talk to the phone are behind `RouteADevice`, which the app
// implements with idevice's C API (the calls the install spike made); the
// order, retries, checks and errors are here, tested with a stand-in.

/// Why a step that talks to the phone failed, with idevice's own error.
public struct RouteAError: Error, Equatable, CustomStringConvertible {
	public enum Step: String, Equatable, Sendable {
		/// Reading the pairing file and opening the tunnel with it.
		case connect
		case udid
		case upload
		case install
		case lookup
		case uninstall
		case list
		/// Opening an app's data container through house_arrest, and the
		/// AFC calls on it (#96).
		case appData
		/// Listing, installing or removing provisioning profiles through
		/// misagent (#49).
		case profiles
		/// Reading or writing the Home Screen's layout through SpringBoard,
		/// to keep an app's spot when Atelier reinstalls it.
		case homeScreen
	}

	public var step: Step
	public var code: Int32
	public var message: String

	public init(step: Step, code: Int32, message: String) {
		self.step = step
		self.code = code
		self.message = message
	}

	public var description: String {
		"\(step.rawValue) failed: \(message.isEmpty ? "no message" : message) (idevice code \(code))"
	}
}

/// One tunnel to iOS's install services. Its calls block, so they run off
/// the main actor, one at a time.
public protocol RouteAConnection: AnyObject {
	/// This iPhone's UDID, as provisioning profiles list it.
	func udid() throws -> String
	/// Copies the IPA into iOS's staging folder over AFC. `progress` gets
	/// the bytes sent so far; `isCancelled` is asked between chunks, and the
	/// upload throws `CancellationError` once it says yes.
	func upload(_ ipa: URL, to remotePath: String, progress: (Int64) -> Void, isCancelled: () -> Bool) throws
	/// Has installd install the staged IPA; `progress` gets installd's
	/// percentage. Replaces an installed app with the same bundle ID.
	func install(remotePath: String, progress: (Int) -> Void) throws
	/// The installed app's version (CFBundleShortVersionString), or nil
	/// when it isn't installed.
	func installedVersion(of bundleID: String) throws -> String?
	func uninstall(_ bundleID: String) throws
	/// The user's installed apps.
	func installedApps() throws -> [InstalledApp]
	/// Ends the tunnel.
	func close()
	/// Opens installd's service before the upload, as the install spike
	/// did: with Atelier in the background, opening it after a long upload
	/// failed with `Socket(Kind(NotConnected))` (#72).
	func prepareInstall() throws
	/// Opens the data container of the app installed as `bundleID` through
	/// house_arrest (#96). Its own connection, which the caller closes.
	func appData(of bundleID: String) throws -> any AppDataContainer
	/// installd's record of the app installed as `bundleID`, which says who
	/// signed it (#99); nil when there's none.
	func appRecord(of bundleID: String) throws -> InstalledAppRecord?
	/// The provisioning profiles installed on the phone, each as its whole
	/// file, as misagent lists them (#49).
	func profiles() throws -> [Data]
	/// Installs a provisioning profile through misagent, as Xcode does: an
	/// app signed with a free Apple ID opens with a new one without being
	/// reinstalled (#49). One with the same UUID is replaced.
	func installProfile(_ profile: Data) throws
	/// Removes the provisioning profile with this UUID.
	func removeProfile(_ uuid: String) throws
	/// The Home Screen's layout, as SpringBoard's getIconState gives it
	/// (formatVersion 2), as a property list.
	func homeScreen() throws -> Data
	/// Has SpringBoard import `layout`, a property list of the form
	/// `HomeScreenLayout.archive` makes, then returns the layout read back
	/// right after, as `homeScreen` does.
	func setHomeScreen(_ layout: Data) throws -> Data
	/// Every app installd knows, system apps and iOS's offloaded ones
	/// too, as a property list of bundle ID → name and SBAppTags: what the
	/// App Library is worked out from.
	func homeScreenApps() throws -> Data
	/// Each of `bundleIDs`' Home Screen icon, as SpringBoard gives it, as a
	/// property list of bundle ID → PNG data, without the ones it has no
	/// icon for.
	func homeScreenIcons(_ bundleIDs: [String]) throws -> Data
}

public extension RouteAConnection {
	func prepareInstall() throws {}

	func appData(of bundleID: String) throws -> any AppDataContainer {
		throw RouteAError(step: .appData, code: 0, message: "this connection can't open app data")
	}

	func appRecord(of bundleID: String) throws -> InstalledAppRecord? {
		throw RouteAError(step: .lookup, code: 0, message: "this connection can't read installd's records")
	}

	func profiles() throws -> [Data] {
		throw RouteAError(step: .profiles, code: 0, message: "this connection can't list profiles")
	}

	func installProfile(_ profile: Data) throws {
		throw RouteAError(step: .profiles, code: 0, message: "this connection can't install profiles")
	}

	func removeProfile(_ uuid: String) throws {
		throw RouteAError(step: .profiles, code: 0, message: "this connection can't remove profiles")
	}

	func homeScreen() throws -> Data {
		throw RouteAError(step: .homeScreen, code: 0, message: "this connection can't read the Home Screen")
	}

	func setHomeScreen(_ layout: Data) throws -> Data {
		throw RouteAError(step: .homeScreen, code: 0, message: "this connection can't write the Home Screen")
	}

	func homeScreenApps() throws -> Data {
		throw RouteAError(step: .homeScreen, code: 0, message: "this connection can't list every app")
	}

	func homeScreenIcons(_ bundleIDs: [String]) throws -> Data {
		throw RouteAError(step: .homeScreen, code: 0, message: "this connection can't get icons")
	}
}

/// The user's apps and the provisioning profiles on the phone, read on one
/// connection: which apps run with a free Apple ID's profile (#49).
public struct AppsAndProfiles: Sendable {
	public var apps: [InstalledApp]
	/// Each as its whole file.
	public var profiles: [Data]

	public init(apps: [InstalledApp], profiles: [Data]) {
		self.apps = apps
		self.profiles = profiles
	}
}

/// What `RouteAConnection.installedApps` lists.
public struct InstalledApp: Equatable, Sendable {
	public var bundleID: String
	public var version: String
	public var build: String
	public var name: String

	public init(bundleID: String, version: String, build: String, name: String) {
		self.bundleID = bundleID
		self.version = version
		self.build = build
		self.name = name
	}
}

/// Opens route A's tunnel: to 10.7.0.1 through LocalDevVPN, verified with
/// the pairing file.
public protocol RouteADevice: Sendable {
	func connect(pairingFile: Data) throws -> any RouteAConnection
}

/// Which devices a provisioning profile lets apps run on.
public enum ProfileDevices: Equatable, Sendable {
	/// An enterprise profile: any device.
	case any
	case listed([String])

	func contains(_ udid: String) -> Bool {
		switch self {
		case .any: true
		case .listed(let devices): devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
		}
	}
}

@MainActor
public final class PairingInstaller: Installer {
	public let route = InstallRoute.pairing

	public struct Dependencies {
		/// The saved pairing file, nil when there's none.
		public var pairingFile: @MainActor () -> Data?
		/// LocalDevVPN, Wi-Fi and the install service (`RouteANetwork`).
		public var network: @MainActor () async -> RouteANetwork.Status
		/// Asks LocalDevVPN to connect, through its URL scheme. Returns
		/// false when it couldn't be opened: not installed, or Atelier isn't
		/// in front.
		public var startVPN: @MainActor () async -> Bool
		public var device: any RouteADevice
		/// The devices of the profile signed into the package's app, which
		/// iOS checks; nil when unknown. Not the default certificate's: an
		/// update signs with the certificate the app was installed with (#76).
		public var profileDevices: @MainActor (InstallPackage) -> ProfileDevices?
		/// Hears this iPhone's UDID each time route A reads it.
		public var noteUDID: @MainActor (String) -> Void
		/// Why a saved pairing file can't be read now, such as the iPhone
		/// being locked (#72); nil when there's none to read, which
		/// `noPairingFile` says.
		public var unreadablePairingFile: @MainActor () -> String?

		public init(
			pairingFile: @escaping @MainActor () -> Data?,
			network: @escaping @MainActor () async -> RouteANetwork.Status,
			startVPN: @escaping @MainActor () async -> Bool,
			device: any RouteADevice,
			profileDevices: @escaping @MainActor (InstallPackage) -> ProfileDevices?,
			noteUDID: @escaping @MainActor (String) -> Void = { _ in },
			unreadablePairingFile: @escaping @MainActor () -> String? = { nil }
		) {
			self.pairingFile = pairingFile
			self.network = network
			self.startVPN = startVPN
			self.device = device
			self.profileDevices = profileDevices
			self.noteUDID = noteUDID
			self.unreadablePairingFile = unreadablePairingFile
		}
	}

	private let dependencies: Dependencies
	/// How long to wait for LocalDevVPN to connect after opening it. It came
	/// back in 4.5 s with a tap the first time, 1.1 s after that.
	var vpnWait: Duration = .seconds(20)
	var vpnPoll: Duration = .milliseconds(500)
	/// One upload in ten lost its connection in the spike; the retry worked.
	nonisolated static let uploadAttempts = 2

	public static let noPairingFile = "This needs Atelier's setup. Finish it in Settings › Installs."

	/// Why there's no pairing file to use now.
	private var missingPairingFile: String {
		dependencies.unreadablePairingFile() ?? Self.noPairingFile
	}

	public init(_ dependencies: Dependencies) {
		self.dependencies = dependencies
	}

	public func healthCheck() async -> RouteHealth {
		await check(startingVPN: true)
	}

	/// The pairing file, then LocalDevVPN, Wi-Fi and the install service.
	/// With `startingVPN`, a disconnected LocalDevVPN is asked to connect
	/// first, which switches to LocalDevVPN and back.
	public func check(startingVPN: Bool) async -> RouteHealth {
		guard dependencies.pairingFile() != nil else { return .unavailable(missingPairingFile) }
		var status = await dependencies.network()
		if status == .vpnOff, startingVPN, await dependencies.startVPN() {
			let clock = ContinuousClock()
			let deadline = clock.now + vpnWait
			while status == .vpnOff, clock.now < deadline {
				try? await Task.sleep(for: vpnPoll)
				status = await dependencies.network()
			}
		}
		if let problem = status.problem { return .unavailable(problem) }
		return .ready
	}

	public func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		events(.phase(.connecting))
		guard let pairing = dependencies.pairingFile() else { throw InstallFailure.couldNotStart(missingPairingFile) }
		let job = Job(
			device: dependencies.device,
			pairing: pairing,
			package: package,
			devices: dependencies.profileDevices(package)
		)
		let (stream, continuation) = AsyncStream.makeStream(of: Job.Event.self)
		let flag = job.cancelled
		let worker = Task.detached { () throws -> String? in
			defer { continuation.finish() }
			return try job.run { continuation.yield($0) }
		}
		return try await withTaskCancellationHandler {
			for await event in stream {
				switch event {
				case .log(let line): events(.log(line))
				case .phase(let phase): events(.phase(phase))
				case .udid(let udid): dependencies.noteUDID(udid)
				}
			}
			let installed: String?
			do {
				installed = try await worker.value
			} catch let error as RouteAError {
				throw Self.failure(error)
			}
			guard let installed else {
				events(.log("installd reported success, and its list of apps doesn't have \(package.info.bundleID) yet"))
				return .confirmed(version: package.info.version)
			}
			if installed != package.info.version {
				events(.log("installd lists \(package.info.bundleID) at version \(installed), not \(package.info.version)"))
			}
			return .confirmed(version: installed)
		} onCancel: {
			flag.set()
		}
	}

	/// Removes an app from this iPhone, with its data, as deleting it from
	/// the Home Screen does. Throws `InstallFailure` or `RouteAError`.
	public func uninstall(_ bundleID: String) async throws {
		try await withConnection { try $0.uninstall(bundleID) }
	}

	/// The user's apps installd lists, for the Library (#17).
	public func installedApps() async throws -> [InstalledApp] {
		try await withConnection { try $0.installedApps() }
	}

	/// installd's record of the app installed as `bundleID`, which says who
	/// signed it and for which App ID (#99); nil when there's none. Assumes
	/// LocalDevVPN is connected, as `installedApps` does.
	public func appRecord(of bundleID: String) async throws -> InstalledAppRecord? {
		try await withConnection { try $0.appRecord(of: bundleID) }
	}

	/// The user's apps and the provisioning profiles misagent has, on one
	/// connection: which apps hold a free Apple ID's 3 places (#49).
	/// Assumes LocalDevVPN is connected, as `installedApps` does.
	public func appsAndProfiles() async throws -> AppsAndProfiles {
		try await withConnection { connection in
			AppsAndProfiles(apps: try connection.installedApps(), profiles: try connection.profiles())
		}
	}

	/// Takes the profiles with these UUIDs off the phone, returning those
	/// that came off: Test Actions' End an App's Profile (#49), which stops
	/// the app opening as an ended profile does. Assumes LocalDevVPN is
	/// connected.
	public func removeProfiles(_ uuids: [String]) async throws -> [String] {
		try await withConnection { connection in
			uuids.filter { uuid in (try? connection.removeProfile(uuid)) != nil }
		}
	}

	/// Puts `profile` on the phone, then takes off the ones with `replacing`
	/// UUIDs that it takes the place of (#49): an app signed with a free
	/// Apple ID keeps opening without being reinstalled. Returns the UUIDs
	/// it took off; one that won't come off stays, as iOS goes by the
	/// profile that ends last. Assumes LocalDevVPN is connected.
	public func installProfile(_ profile: Data, replacing uuids: [String]) async throws -> [String] {
		try await withConnection { connection in
			try connection.installProfile(profile)
			return uuids.filter { uuid in
				do {
					try connection.removeProfile(uuid)
					return true
				} catch {
					return false
				}
			}
		}
	}

	// MARK: The Home Screen

	/// The Home Screen's layout and the installed apps the App Library is
	/// worked out from, read on one connection. Assumes LocalDevVPN is
	/// connected, as `installedApps` does.
	public func homeScreen() async throws -> HomeScreenState {
		try await withConnection { connection in
			let plist = try connection.homeScreen()
			guard let layout = HomeScreenLayout(plist: plist) else {
				throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard's layout couldn't be read")
			}
			guard let apps = HomeScreenApp.apps(from: try connection.homeScreenApps()) else {
				throw RouteAError(step: .homeScreen, code: 0, message: "installd's list of apps couldn't be read")
			}
			return HomeScreenState(layout: layout, apps: apps, plist: plist)
		}
	}

	/// Writes `layout`, with `appLibrary` as the apps only in the App
	/// Library and the gaps of `gaps` it can keep, and returns the layout
	/// SpringBoard gives right after, which doesn't show the gaps. Assumes
	/// LocalDevVPN is connected.
	public func writeHomeScreen(_ layout: HomeScreenLayout, appLibrary: [String], gaps: HomeScreenGaps = HomeScreenGaps()) async throws -> HomeScreenLayout {
		let archive = try layout.archiveData(appLibrary: appLibrary, gaps: gaps)
		return try await withConnection { connection in
			guard let after = HomeScreenLayout(plist: try connection.setHomeScreen(archive)) else {
				throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard's layout couldn't be read back")
			}
			return after
		}
	}

	/// Each of `bundleIDs`' Home Screen icon as PNG data, for Open Spaces'
	/// pages: none for an app SpringBoard has no icon for. Assumes
	/// LocalDevVPN is connected.
	public func homeScreenIcons(_ bundleIDs: [String]) async throws -> [String: Data] {
		guard !bundleIDs.isEmpty else { return [:] }
		return try await withConnection { connection in
			let plist = try connection.homeScreenIcons(bundleIDs)
			guard let icons = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Data] else {
				throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard's icons couldn't be read")
			}
			return icons
		}
	}

	/// Runs `body` on a connection of its own, off the main actor. Assumes
	/// LocalDevVPN is connected; `check` says whether it is.
	private func withConnection<T: Sendable>(_ body: @escaping @Sendable (any RouteAConnection) throws -> T) async throws -> T {
		guard let pairing = dependencies.pairingFile() else { throw InstallFailure.couldNotStart(missingPairingFile) }
		let device = dependencies.device
		do {
			return try await Task.detached {
				let connection = try device.connect(pairingFile: pairing)
				defer { connection.close() }
				return try body(connection)
			}.value
		} catch let error as RouteAError {
			throw Self.failure(error)
		}
	}

	/// The failure to show for a step that failed.
	static func failure(_ error: RouteAError) -> InstallFailure {
		switch error.step {
		case .connect, .uninstall, .lookup, .list, .profiles, .homeScreen:
			.routeAStep(error)
		case .udid, .upload:
			.connectionLost(error.message)
		case .install:
			.rejected(error.message)
		case .appData:
			.connectionLost(error.message)
		}
	}

	// MARK: App data (#96)

	/// Whether the app is on this iPhone, as installd lists it; nil when
	/// installd can't be asked.
	public func isInstalled(_ bundleID: String) async -> Bool? {
		guard let apps = try? await installedApps() else { return nil }
		return apps.contains { $0.bundleID == bundleID }
	}

	/// Copies the data of the app installed as `bundleID` into `folder`,
	/// leaving out `AppDataCopy.leftOut`, with `progress` getting the
	/// fraction copied. Throws `AppDataRefused` when iOS won't open its
	/// container, `AppDataCopy.NotEnoughSpace`, or `InstallFailure` when
	/// the connection breaks.
	public func copyAppData(of bundleID: String, to folder: URL, freeSpace: Int64?, log: @escaping @MainActor (String) -> Void, progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult {
		try await withAppData(of: bundleID, log: log, progress: progress) { container, say, advance, isCancelled in
			try AppDataCopy.copyOut(from: container, to: folder, freeSpace: freeSpace, log: say, progress: advance, isCancelled: isCancelled)
		}
	}

	/// Copies the data `copyAppData` left in `folder` into the container of
	/// the app installed as `bundleID`. Throws as `copyAppData` does.
	public func restoreAppData(of bundleID: String, from folder: URL, log: @escaping @MainActor (String) -> Void, progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult {
		try await withAppData(of: bundleID, log: log, progress: progress) { container, say, advance, isCancelled in
			try AppDataCopy.copyBack(from: folder, to: container, log: say, progress: advance, isCancelled: isCancelled)
		}
	}

	/// What a copy off the main actor reports as it goes.
	private enum AppDataNote: Sendable {
		case log(String)
		case progress(Double)
	}

	/// Runs `body` on the app's data container, on a connection of its own
	/// off the main actor, passing its log lines to `log` and how far it
	/// has got to `progress` as they come. A cancel stops it between files.
	private func withAppData<T: Sendable>(
		of bundleID: String,
		log: @escaping @MainActor (String) -> Void,
		progress: @escaping @MainActor (Double) -> Void,
		_ body: @escaping @Sendable (any AppDataContainer, (String) -> Void, (Double) -> Void, () -> Bool) throws -> T
	) async throws -> T {
		guard let pairing = dependencies.pairingFile() else { throw InstallFailure.couldNotStart(missingPairingFile) }
		let device = dependencies.device
		let flag = CancelFlag()
		let (stream, continuation) = AsyncStream.makeStream(of: AppDataNote.self)
		let worker = Task.detached { () throws -> T in
			defer { continuation.finish() }
			let connection = try device.connect(pairingFile: pairing)
			defer { connection.close() }
			// Any answer but the container counts as iOS's refusal, such as
			// for an app iOS won't open to a computer, so the app isn't
			// deleted unless the user says to go on without its data.
			let container: any AppDataContainer
			do {
				container = try connection.appData(of: bundleID)
			} catch let error as RouteAError {
				throw AppDataRefused(message: "\(error.message.isEmpty ? "no message" : error.message) (idevice code \(error.code))")
			}
			defer { container.close() }
			return try body(container, { continuation.yield(.log($0)) }, { continuation.yield(.progress($0)) }, { flag.isSet })
		}
		return try await withTaskCancellationHandler {
			for await note in stream {
				switch note {
				case .log(let line): log(line)
				case .progress(let fraction): progress(fraction)
				}
			}
			do {
				return try await worker.value
			} catch let error as RouteAError {
				throw Self.failure(error)
			}
		} onCancel: {
			flag.set()
		}
	}

	// MARK: The blocking part

	final class CancelFlag: @unchecked Sendable {
		private let lock = NSLock()
		private var value = false

		func set() {
			lock.lock(); value = true; lock.unlock()
		}

		var isSet: Bool {
			lock.lock(); defer { lock.unlock() }
			return value
		}
	}

	/// One install, run on a thread of its own.
	final class Job: @unchecked Sendable {
		enum Event {
			case log(String)
			case phase(InstallPhase)
			case udid(String)
		}

		let device: any RouteADevice
		let pairing: Data
		let package: InstallPackage
		let devices: ProfileDevices?
		let cancelled = CancelFlag()

		init(device: any RouteADevice, pairing: Data, package: InstallPackage, devices: ProfileDevices?) {
			self.device = device
			self.pairing = pairing
			self.package = package
			self.devices = devices
		}

		/// Connects, checks the device, uploads (once more if the upload
		/// breaks off), installs and reads back the installed version.
		func run(_ report: (Event) -> Void) throws -> String? {
			let started = Date.now
			let size = (try? package.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
			var attempt = 1
			while true {
				report(.log("route A: connecting to \(RouteANetwork.deviceAddress):\(RouteANetwork.port)" + (attempt > 1 ? ", attempt \(attempt)" : "")))
				let connection = try device.connect(pairingFile: pairing)
				defer { connection.close() }
				if attempt == 1 { try checkDevice(connection, report) }
				try checkCancelled()

				let remotePath = "/PublicStaging/atelier-\(UUID().uuidString).ipa"
				report(.phase(.downloading(fraction: 0)))
				var lastTenth = -1
				do {
					try connection.prepareInstall()
					try connection.upload(package.url, to: remotePath, progress: { sent in
						let fraction = size > 0 ? min(Double(sent) / Double(size), 1) : 0
						report(.phase(.downloading(fraction: fraction)))
						let tenth = Int(fraction * 10)
						if tenth != lastTenth {
							lastTenth = tenth
							report(.log("route A: uploaded \(tenth * 10) %"))
						}
					}, isCancelled: { cancelled.isSet })
				} catch let error as RouteAError where attempt < PairingInstaller.uploadAttempts && !cancelled.isSet {
					report(.log("route A: the upload broke off (\(error.message)); trying again"))
					attempt += 1
					continue
				}
				try checkCancelled()
				report(.log(String(format: "route A: uploaded %@ in %.1f s", ByteCountFormatter.string(fromByteCount: size, countStyle: .file), Date.now.timeIntervalSince(started))))

				// installd can't be stopped once it has started, so a cancel
				// from here on only ends the wait.
				report(.phase(.installing(fraction: 0)))
				var lastPercent = -1
				do {
					try connection.install(remotePath: remotePath) { percent in
						guard percent != lastPercent else { return }
						lastPercent = percent
						report(.phase(.installing(fraction: Double(min(max(percent, 0), 100)) / 100)))
					}
				} catch let error as RouteAError {
					// installd's own words, which the failure only sums up, such
					// as the App ID of the app iOS won't replace (#99).
					report(.log("route A: installd didn't install it: \(error.message.isEmpty ? "no message" : error.message) (idevice code \(error.code))"))
					throw error
				}
				report(.log(String(format: "route A: installd reported success after %.1f s", Date.now.timeIntervalSince(started))))
				do {
					return try connection.installedVersion(of: package.info.bundleID)
				} catch let error as RouteAError {
					report(.log("route A: couldn't read back the installed version: \(error.message)"))
					return nil
				}
			}
		}

		/// Reads the UDID and stops when the profile doesn't list it, since
		/// iOS would refuse the app anyway.
		private func checkDevice(_ connection: any RouteAConnection, _ report: (Event) -> Void) throws {
			let udid: String
			do {
				udid = try connection.udid()
			} catch let error as RouteAError {
				// The install itself doesn't need it.
				report(.log("route A: couldn't read this iPhone's UDID: \(error.message)"))
				return
			}
			report(.udid(udid))
			guard let devices else {
				report(.log("route A: this iPhone's UDID is known, but not which devices the profile lists"))
				return
			}
			if devices.contains(udid) {
				report(.log(devices == .any ? "route A: the profile allows any device" : "route A: the profile lists this iPhone"))
			} else {
				throw InstallFailure.deviceNotInProfile
			}
		}

		private func checkCancelled() throws {
			if cancelled.isSet { throw CancellationError() }
		}
	}
}
