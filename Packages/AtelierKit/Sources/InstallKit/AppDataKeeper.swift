import Foundation

/// Copies an app's data aside before `ReplacingInstaller` deletes it, and
/// back into its new install (#96).
@MainActor
public protocol AppDataKeeping: AnyObject {
	/// Copies the app's data aside. When it can't, it throws
	/// `InstallFailure.dataNotCopied`, so the app isn't deleted.
	func save(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async throws
	/// Puts the kept copy back into the new install. Doesn't throw: the
	/// install itself worked, and a copy that couldn't be put back is kept
	/// for the Library's Put Back.
	func restore(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async
	/// Makes the copy kept of `bundleID`'s data the app's under
	/// `newBundleID`, which its new install has: signed with an Apple ID, or
	/// no longer with one (#49).
	func move(_ bundleID: String, to newBundleID: String, events: @escaping @MainActor (InstallEvent) -> Void)
}

public extension AppDataKeeping {
	func move(_ bundleID: String, to newBundleID: String, events: @escaping @MainActor (InstallEvent) -> Void) {}
}

/// Keeps an app's data in `AppDataStore` across its reinstall, through
/// Direct installs (#96). A copy is kept until it's been put back: by the
/// install that deleted the app, by Put Back in the Library when that
/// couldn't, or by the app's next install when the app was deleted and its
/// install failed.
@MainActor
public final class AppDataKeeper: AppDataKeeping {
	public struct Dependencies {
		public var store: AppDataStore
		/// Whether the app is on this iPhone; nil when that can't be told.
		public var isInstalled: @MainActor (_ bundleID: String) async -> Bool?
		/// Copies the app's container into a folder, with the fraction
		/// copied as it goes (`PairingInstaller.copyAppData`).
		public var copyOut: @MainActor (_ bundleID: String, _ folder: URL, _ log: @escaping @MainActor (String) -> Void, _ progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult
		/// Copies a folder into the app's container, likewise
		/// (`PairingInstaller.restoreAppData`).
		public var copyBack: @MainActor (_ bundleID: String, _ folder: URL, _ log: @escaping @MainActor (String) -> Void, _ progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult

		public init(
			store: AppDataStore,
			isInstalled: @escaping @MainActor (_ bundleID: String) async -> Bool?,
			copyOut: @escaping @MainActor (_ bundleID: String, _ folder: URL, _ log: @escaping @MainActor (String) -> Void, _ progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult,
			copyBack: @escaping @MainActor (_ bundleID: String, _ folder: URL, _ log: @escaping @MainActor (String) -> Void, _ progress: @escaping @MainActor (Double) -> Void) async throws -> AppDataCopyResult
		) {
			self.store = store
			self.isInstalled = isInstalled
			self.copyOut = copyOut
			self.copyBack = copyBack
		}
	}

	private let dependencies: Dependencies
	/// A copy that breaks off is tried once more, as uploads are (#9).
	nonisolated static let saveAttempts = 2
	/// iOS may not open a new install's container at once, and a broken
	/// connection may come back, so putting the data back is tried a few
	/// times, a moment apart.
	var restoreAttempts = 3
	var restoreWait: Duration = .seconds(1)

	public init(_ dependencies: Dependencies) {
		self.dependencies = dependencies
	}

	private var store: AppDataStore { dependencies.store }

	public func save(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async throws {
		let say: @MainActor (String) -> Void = { events(.log("data: \($0)")) }
		store.removeLeftovers()
		if await dependencies.isInstalled(bundleID) == false {
			say("\(name) isn't on this \(ThisDevice.name), so there's no data to copy")
			noteKept(bundleID, say)
			return
		}
		events(.phase(.copyingData(fraction: nil)))
		var attempt = 1
		while true {
			say("copying \(name)'s data through house_arrest" + (attempt > 1 ? ", attempt \(attempt)" : ""))
			let started = Date.now
			var folder: URL?
			do {
				let into = try store.newFolder()
				folder = into
				let result = try await dependencies.copyOut(bundleID, into, say) { events(.phase(.copyingData(fraction: $0))) }
				if let waiting = store.kept(bundleID) {
					say("this replaces the copy kept from \(Self.date(waiting.copiedAt)), which wasn't put back")
				}
				try store.keep(into, for: bundleID, info: KeptAppData(copiedAt: .now, files: result.files, bytes: result.bytes, bundleID: bundleID))
				say(String(format: "copied %@ in %.1f s", result.summary, Date.now.timeIntervalSince(started)))
				note(result.skipped, "couldn't copy", say)
				return
			} catch let refused as AppDataRefused {
				folder.map(store.discard)
				say("iOS doesn't let Atelier read \(name)'s data: \(refused.message)")
				throw InstallFailure.dataNotCopied(.refused(refused.message))
			} catch is CancellationError {
				folder.map(store.discard)
				throw CancellationError()
			} catch let full as AppDataCopy.NotEnoughSpace {
				folder.map(store.discard)
				say("not enough space: \(full)")
				throw InstallFailure.dataNotCopied(.notEnoughSpace(needed: full.needed, free: full.free))
			} catch {
				folder.map(store.discard)
				if attempt < Self.saveAttempts {
					say("the copy broke off (\(Self.describe(error))); trying again")
					attempt += 1
					continue
				}
				say("the copy broke off again (\(Self.describe(error)))")
				throw InstallFailure.dataNotCopied(.brokeOff(Self.describe(error)))
			}
		}
	}

	public func restore(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		do {
			try await putBack(bundleID, name: name, events: events)
		} catch {
			events(.log("data: the copy is kept, for Put Back in the Library"))
		}
	}

	/// Puts the app's kept copy into its install, trying a few times, and
	/// deletes the copy once it's in; items iOS won't take are only logged,
	/// as trying again wouldn't change that. Throws when it couldn't, and
	/// the copy is kept: `AppDataRefused` when iOS won't open the app's
	/// container, else what broke the copy off. Nothing to do without one.
	public func putBack(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async throws {
		let say: @MainActor (String) -> Void = { events(.log("data: \($0)")) }
		guard let kept = store.kept(bundleID) else { return }
		say("putting back \(name)'s data copied \(Self.date(kept.copiedAt)): \(AppDataCopyResult.describe(files: kept.files, bytes: kept.bytes))")
		events(.phase(.restoringData(fraction: nil)))
		var attempt = 1
		while true {
			let started = Date.now
			do {
				let result = try await dependencies.copyBack(bundleID, store.containerFolder(for: bundleID), say) { events(.phase(.restoringData(fraction: $0))) }
				say(String(format: "put back %@ in %.1f s", result.summary, Date.now.timeIntervalSince(started)))
				note(result.skipped, "couldn't put back", say)
				store.remove(bundleID)
				return
			} catch is CancellationError {
				say("stopped putting \(name)'s data back")
				throw CancellationError()
			} catch {
				let why = (error as? AppDataRefused).map { "iOS doesn't open the new install's data (\($0.message))" } ?? "the copy broke off (\(Self.describe(error)))"
				if attempt < restoreAttempts {
					say("\(why); trying again")
					attempt += 1
					try? await Task.sleep(for: restoreWait)
					continue
				}
				say("couldn't put \(name)'s data back: \(why)")
				throw error
			}
		}
	}

	public func move(_ bundleID: String, to newBundleID: String, events: @escaping @MainActor (InstallEvent) -> Void) {
		do {
			try store.move(bundleID, to: newBundleID)
			events(.log("data: the copy goes into \(newBundleID), which it installs as now"))
		} catch {
			events(.log("data: couldn't make the copy \(newBundleID)'s: \(error)"))
		}
	}

	/// Says that a kept copy goes into the new install instead.
	private func noteKept(_ bundleID: String, _ say: @MainActor (String) -> Void) {
		guard let kept = store.kept(bundleID) else { return }
		say("the copy kept from \(Self.date(kept.copiedAt)) goes into the new install instead")
	}

	/// The first few items that weren't copied, and how many more.
	private func note(_ skipped: [String], _ verb: String, _ say: @MainActor (String) -> Void) {
		for item in skipped.prefix(10) { say("\(verb) \(item)") }
		if skipped.count > 10 { say("and \(skipped.count - 10) more") }
	}

	/// What broke a copy off, in the words of whatever failed, for the log
	/// and the install's details.
	private static func describe(_ error: Error) -> String {
		switch error {
		case let failure as InstallFailure: failure.technical ?? failure.description
		case let error as CocoaError: error.localizedDescription
		default: "\(error)"
		}
	}

	private static func date(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .shortened)
	}
}
