import Foundation
import IDevice
import InstallKit

/// Route A's calls to the phone (#9), through idevice's C API: the RPPairing
/// tunnel to 10.7.0.1 through LocalDevVPN, on the port of iOS's pairing
/// service (`RouteANetwork.port`, usually 49152), AFC for the upload and
/// installation_proxy for the install. The same calls, in the same order, as
/// the install spike's route A, which installed on iOS 27.0.1
/// (spike/InstallSpike/Sources/RouteA.swift). house_arrest opens an app's
/// data container (#96), misagent installs and removes provisioning
/// profiles (#49), and SpringBoard reads and writes the Home Screen's
/// layout, to keep an app's spot when Atelier reinstalls it. idevice is
/// built from source with Atelier's pairing host and helpers
/// (Packages/IDeviceBridge).
struct IDeviceRouteA: RouteADevice {
	/// The name the phone's logs give this host.
	static let label = "Atelier"

	func connect(pairingFile: Data) throws -> any RouteAConnection {
		var pairing: OpaquePointer?
		try pairingFile.withUnsafeBytes { buffer in
			try check(rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count), &pairing), .connect)
		}
		defer { rp_pairing_file_free(pairing) }

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = RouteANetwork.port.bigEndian
		_ = inet_pton(AF_INET, RouteANetwork.deviceAddress, &address.sin_addr)

		var adapter: OpaquePointer?
		var handshake: OpaquePointer?
		let error = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
				tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), Self.label, pairing, nil, nil, &adapter, &handshake)
			}
		}
		try check(error, .connect)
		return Connection(adapter: adapter, handshake: handshake)
	}

	/// One RemoteXPC tunnel, with AFC, installation_proxy and misagent
	/// connected when first needed.
	final class Connection: RouteAConnection {
		private let adapter: OpaquePointer?
		private let handshake: OpaquePointer?
		private var installer: OpaquePointer?
		private var profileAgent: OpaquePointer?

		init(adapter: OpaquePointer?, handshake: OpaquePointer?) {
			self.adapter = adapter
			self.handshake = handshake
		}

		func udid() throws -> String {
			var udid: UnsafeMutablePointer<CChar>?
			try check(atelier_device_udid(adapter, handshake, &udid), .udid)
			defer { atelier_device_string_free(udid) }
			return udid.map { String(cString: $0) } ?? ""
		}

		/// Whether Developer Mode is on, for the pairing log.
		func developerMode() throws -> Bool {
			var enabled = false
			try check(atelier_developer_mode(adapter, handshake, &enabled), .connect)
			return enabled
		}

		func upload(_ ipa: URL, to remotePath: String, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
			var afc: OpaquePointer?
			try check(afc_client_connect_rsd(adapter, handshake, &afc), .upload)
			defer { afc_client_free(afc) }
			// Fails harmlessly when the folder is already there.
			if let error = afc_make_directory(afc, "PublicStaging") { idevice_error_free(error) }

			var file: OpaquePointer?
			try check(afc_file_open(afc, remotePath, AfcWrOnly, &file), .upload)
			let handle = try FileHandle(forReadingFrom: ipa)
			defer { try? handle.close() }
			var written: Int64 = 0
			do {
				while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
					if isCancelled() { throw CancellationError() }
					let error = chunk.withUnsafeBytes { buffer in
						afc_file_write(file, buffer.bindMemory(to: UInt8.self).baseAddress, chunk.count)
					}
					try check(error, .upload)
					written += Int64(chunk.count)
					progress(written)
				}
			} catch {
				if let error = afc_file_close(file) { idevice_error_free(error) }
				if let error = afc_remove_path(afc, remotePath) { idevice_error_free(error) }
				throw error
			}
			try check(afc_file_close(file), .upload)
		}

		func prepareInstall() throws {
			// Counted as the upload's, so a failure is tried again with it.
			_ = try installationProxy(.upload)
		}

		func install(remotePath: String, progress: (Int) -> Void) throws {
			let installer = try installationProxy(.install)
			try withoutActuallyEscaping(progress) { progress in
				let box = ProgressBox(progress)
				let context = Unmanaged.passRetained(box)
				defer { context.release() }
				let error = installation_proxy_install_with_callback(installer, remotePath, nil, { percent, context in
					guard let context else { return }
					Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(Int(percent))
				}, context.toOpaque())
				try check(error, .install)
			}
		}

		func installedVersion(of bundleID: String) throws -> String? {
			let installer = try installationProxy(.lookup)
			var version: UnsafeMutablePointer<CChar>?
			try check(atelier_installed_version(installer, bundleID, &version), .lookup)
			defer { atelier_device_string_free(version) }
			guard let version else { return nil }
			// "short version\tbuild"; the build when there's no short version.
			let parts = String(cString: version).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			if let short = parts.first, !short.isEmpty { return short }
			return parts.count > 1 ? parts[1] : ""
		}

		func uninstall(_ bundleID: String) throws {
			let installer = try installationProxy(.uninstall)
			try check(installation_proxy_uninstall(installer, bundleID, nil), .uninstall)
		}

		func installedApps() throws -> [InstalledApp] {
			let installer = try installationProxy(.list)
			var text: UnsafeMutablePointer<CChar>?
			try check(atelier_installed_apps(installer, &text), .list)
			defer { atelier_device_string_free(text) }
			guard let text else { return [] }
			return String(cString: text).split(separator: "\n").compactMap { line in
				let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
				guard fields.count == 4 else { return nil }
				return InstalledApp(bundleID: fields[0], version: fields[1], build: fields[2], name: fields[3])
			}
		}

		/// installd's record of the app, which says who signed it (#99).
		func appRecord(of bundleID: String) throws -> InstalledAppRecord? {
			let installer = try installationProxy(.lookup)
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try check(atelier_app_records(installer, bundleID, &plist, &length), .lookup)
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { return nil }
			guard let records = InstalledAppRecord.records(from: Data(bytes: plist, count: length)) else {
				throw RouteAError(step: .lookup, code: 0, message: "installd's record couldn't be read")
			}
			return records.first { $0.bundleID == bundleID }
		}

		func appData(of bundleID: String) throws -> any AppDataContainer {
			var client: OpaquePointer?
			try check(house_arrest_client_connect_rsd(adapter, handshake, &client), .appData)
			var afc: OpaquePointer?
			// Takes the client, whether or not iOS opens the container.
			try check(house_arrest_vend_container(client, bundleID, &afc), .appData)
			return AppData(afc: afc)
		}

		/// The provisioning profiles installed on the phone, each as its
		/// whole file, as misagent lists them (#49).
		func profiles() throws -> [Data] {
			let agent = try misagent()
			var profiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
			var lengths: UnsafeMutablePointer<Int>?
			var count = 0
			try check(misagent_copy_all(agent, &profiles, &lengths, &count), .profiles)
			defer { misagent_free_profiles(profiles, lengths, count) }
			guard let profiles, let lengths else { return [] }
			return (0..<count).compactMap { index in
				profiles[index].map { Data(bytes: $0, count: lengths[index]) }
			}
		}

		/// Installs a provisioning profile, as Xcode does before an app
		/// signed with it can open (#49). One with the same UUID is replaced.
		func installProfile(_ profile: Data) throws {
			let agent = try misagent()
			try profile.withUnsafeBytes { buffer in
				try check(misagent_install(agent, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count), .profiles)
			}
		}

		/// Removes the provisioning profile with this UUID (#49).
		func removeProfile(_ uuid: String) throws {
			let agent = try misagent()
			try check(misagent_remove(agent, uuid), .profiles)
		}

		/// The Home Screen's layout, from SpringBoard over the tunnel.
		func homeScreen() throws -> Data {
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try check(atelier_home_screen(adapter, handshake, &plist, &length), .homeScreen)
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard gave no layout") }
			return Data(bytes: plist, count: length)
		}

		/// Has SpringBoard import `layout`, then reads the layout back.
		func setHomeScreen(_ layout: Data) throws -> Data {
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try layout.withUnsafeBytes { buffer in
				try check(atelier_set_home_screen(adapter, handshake, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &plist, &length), .homeScreen)
			}
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard gave no layout back") }
			return Data(bytes: plist, count: length)
		}

		/// The apps' Home Screen icons, from SpringBoard over the tunnel.
		func homeScreenIcons(_ bundleIDs: [String]) throws -> Data {
			let ids = try PropertyListSerialization.data(fromPropertyList: bundleIDs, format: .binary, options: 0)
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try ids.withUnsafeBytes { buffer in
				try check(atelier_home_screen_icons(adapter, handshake, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &plist, &length), .homeScreen)
			}
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { throw RouteAError(step: .homeScreen, code: 0, message: "SpringBoard gave no icons") }
			return Data(bytes: plist, count: length)
		}

		/// What iOS's profile service said to each of `requests`, a plist
		/// list of MCInstall requests, sent in turn on one connection.
		func profileRequests(_ requests: Data) throws -> Data {
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try requests.withUnsafeBytes { buffer in
				try check(atelier_profile_requests(adapter, handshake, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &plist, &length), .homeScreen)
			}
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { throw RouteAError(step: .homeScreen, code: 0, message: "iOS's profile service gave no answer") }
			return Data(bytes: plist, count: length)
		}

		/// Every app installd knows, for the App Library.
		func homeScreenApps() throws -> Data {
			let installer = try installationProxy(.homeScreen)
			var plist: UnsafeMutablePointer<UInt8>?
			var length = 0
			try check(atelier_home_screen_apps(installer, &plist, &length), .homeScreen)
			defer { atelier_device_data_free(plist, length) }
			guard let plist else { throw RouteAError(step: .homeScreen, code: 0, message: "installd listed no apps") }
			return Data(bytes: plist, count: length)
		}

		func close() {
			installation_proxy_client_free(installer)
			installer = nil
			misagent_client_free(profileAgent)
			profileAgent = nil
			rsd_handshake_free(handshake)
			adapter_free(adapter)
		}

		private func installationProxy(_ step: RouteAError.Step) throws -> OpaquePointer? {
			if let installer { return installer }
			var client: OpaquePointer?
			try check(installation_proxy_connect_rsd(adapter, handshake, &client), step)
			installer = client
			return client
		}

		private func misagent() throws -> OpaquePointer? {
			if let profileAgent { return profileAgent }
			var client: OpaquePointer?
			try check(misagent_connect_rsd(adapter, handshake, &client), .profiles)
			profileAgent = client
			return client
		}
	}

	/// An app's data container (#96): AFC on the connection house_arrest
	/// opened for it, with paths from the container's root.
	final class AppData: AppDataContainer {
		private var afc: OpaquePointer?

		init(afc: OpaquePointer?) {
			self.afc = afc
		}

		func contents(of path: String) throws -> [String] {
			var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
			var count = 0
			try check(afc_list_directory(afc, path, &entries, &count), .appData)
			guard let entries else { return [] }
			defer { free(entries) }
			var names: [String] = []
			for index in 0..<count {
				guard let entry = entries[index] else { continue }
				let name = String(cString: entry)
				idevice_string_free(entry)
				if name != ".", name != ".." { names.append(name) }
			}
			return names
		}

		func item(at path: String) throws -> AppDataItem {
			var info = AfcFileInfo()
			try check(afc_get_file_info(afc, path, &info), .appData)
			defer { afc_file_info_free(&info) }
			let kind = info.st_ifmt.map { String(cString: $0) } ?? ""
			switch kind {
			case "S_IFDIR": return .folder
			case "S_IFREG": return .file(size: Int64(info.size))
			case "S_IFLNK": return .link(target: info.st_link_target.map { String(cString: $0) } ?? "")
			default: return .other(kind)
			}
		}

		func read(_ path: String, chunk: (Data) throws -> Void) throws {
			var file: OpaquePointer?
			try check(afc_file_open(afc, path, AfcRdOnly, &file), .appData)
			do {
				while true {
					var data: UnsafeMutablePointer<UInt8>?
					var count = 0
					try check(afc_file_read(file, &data, 1 << 20, &count), .appData)
					guard let data else { break }
					let part = Data(bytes: data, count: count)
					afc_file_read_data_free(data, count)
					if part.isEmpty { break }
					try chunk(part)
				}
			} catch {
				if let error = afc_file_close(file) { idevice_error_free(error) }
				throw error
			}
			try check(afc_file_close(file), .appData)
		}

		func write(_ path: String, from next: () throws -> Data?) throws {
			var file: OpaquePointer?
			try check(afc_file_open(afc, path, AfcWrOnly, &file), .appData)
			do {
				while let part = try next(), !part.isEmpty {
					let error = part.withUnsafeBytes { buffer in
						afc_file_write(file, buffer.bindMemory(to: UInt8.self).baseAddress, part.count)
					}
					try check(error, .appData)
				}
			} catch {
				// No half-written file for the app to find.
				if let error = afc_file_close(file) { idevice_error_free(error) }
				if let error = afc_remove_path(afc, path) { idevice_error_free(error) }
				throw error
			}
			try check(afc_file_close(file), .appData)
		}

		func makeFolder(_ path: String) throws {
			do {
				try check(afc_make_directory(afc, path), .appData)
			} catch let error as RouteAError where error.isAFCError {
				// One that's there already is fine.
				guard (try? item(at: path)) == .folder else { throw error }
			}
		}

		func makeLink(at path: String, to target: String) throws {
			try check(afc_make_link(afc, target, path, Symbolic), .appData)
		}

		func close() {
			afc_client_free(afc)
			afc = nil
		}
	}

	/// Carries installd's progress callback through idevice's C context.
	private final class ProgressBox {
		let report: (Int) -> Void

		init(_ report: @escaping (Int) -> Void) {
			self.report = report
		}
	}
}

/// Turns idevice's error, if any, into a `RouteAError` for the step, and
/// frees it.
private func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ step: RouteAError.Step) throws {
	guard let error else { return }
	let failure = RouteAError(
		step: step,
		code: error.pointee.code,
		message: error.pointee.message.map { String(cString: $0) } ?? ""
	)
	idevice_error_free(error)
	throw failure
}
