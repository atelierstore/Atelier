import Foundation

/// Installs over an app iOS won't replace (#20): one signed for another App
/// ID than the one it was installed with, which iOS refuses as an upgrade
/// (Apple's TN2319, #76). It deletes the app installed under the package's
/// bundle ID, with its data, right before handing the package to the
/// route, so an install that fails before then, in its download or its
/// signing, leaves the app as it was. With `keeping`, the app's data is
/// copied aside first and put back into the new install (#96); an app whose
/// data couldn't be copied isn't deleted.
///
/// Only route A can delete an app, so `base` is route A's installer and
/// `delete` its uninstall.
///
/// With `deleting`, the app deleted is another than the package's: one that
/// installs under another bundle ID now, signed with an Apple ID or no
/// longer with one (#49). Its data goes into the new one.
@MainActor
public final class ReplacingInstaller: Installer {
	private let base: any Installer
	private let deleting: String?
	private let keeping: (any AppDataKeeping)?
	private let homeScreen: (any HomeScreenKeeping)?
	private let delete: @MainActor (_ bundleID: String) async -> String?

	/// `delete` removes the app with that bundle ID and returns why it
	/// couldn't, or nil once it's gone or wasn't there. With `homeScreen`,
	/// the new install goes back in the app's spot on the Home Screen.
	public init(_ base: any Installer, deleting: String? = nil, keeping: (any AppDataKeeping)? = nil, homeScreen: (any HomeScreenKeeping)? = nil, delete: @escaping @MainActor (_ bundleID: String) async -> String?) {
		self.base = base
		self.deleting = deleting
		self.keeping = keeping
		self.homeScreen = homeScreen
		self.delete = delete
	}

	public var route: InstallRoute { base.route }

	public func healthCheck() async -> RouteHealth {
		await base.healthCheck()
	}

	public func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		let info = package.info
		let old = deleting ?? info.bundleID
		if let keeping {
			try await keeping.save(old, name: info.name, events: events)
			// Deleting it talks to iOS too.
			events(.phase(.connecting))
		}
		if old == info.bundleID {
			events(.log("deleting \(old) first, as iOS can't replace it with an app signed for another App ID"))
		} else {
			events(.log("deleting \(old) first, as it installs as \(info.bundleID) now"))
		}
		await homeScreen?.note(old, name: info.name, events: events)
		if let why = await delete(old) {
			throw InstallFailure.couldNotStart("Couldn't delete \(info.name) first: \(why)")
		}
		events(.log("deleted \(old)"))
		if old != info.bundleID { keeping?.move(old, to: info.bundleID, events: events) }
		let result = try await base.install(package, events: events)
		await keeping?.restore(info.bundleID, name: info.name, events: events)
		await homeScreen?.putBack(info.bundleID, notedAs: old, name: info.name, events: events)
		return result
	}
}

/// Installs an app that Disable took off the device with its data kept,
/// and puts the data back into the new install (#49): Enable. Nothing is
/// deleted first, as the app isn't there. `from` is the bundle ID the app
/// had, when it installs as another now, signed with another Apple ID or
/// none: its data goes into the new one, once that's installed, so a
/// failed install leaves the app disabled as it was.
@MainActor
public final class RestoringInstaller: Installer {
	private let base: any Installer
	private let keeping: any AppDataKeeping
	private let from: String?
	private let homeScreen: (any HomeScreenKeeping)?

	/// With `homeScreen`, the app goes back in the spot it had on the Home
	/// Screen when it was offloaded.
	public init(_ base: any Installer, keeping: any AppDataKeeping, from: String? = nil, homeScreen: (any HomeScreenKeeping)? = nil) {
		self.base = base
		self.keeping = keeping
		self.from = from
		self.homeScreen = homeScreen
	}

	public var route: InstallRoute { base.route }

	public func healthCheck() async -> RouteHealth {
		await base.healthCheck()
	}

	public func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		let info = package.info
		let result = try await base.install(package, events: events)
		if let from, from != info.bundleID { keeping.move(from, to: info.bundleID, events: events) }
		await keeping.restore(info.bundleID, name: info.name, events: events)
		await homeScreen?.putBack(info.bundleID, notedAs: from ?? info.bundleID, name: info.name, events: events)
		return result
	}
}
