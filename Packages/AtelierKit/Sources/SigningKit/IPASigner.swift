import CertKit
import Foundation
import InstallKit
import ZIPFoundation
#if canImport(Glibc)
import Glibc
#endif

/// Signs an unpacked .app folder in place.
protocol SigningEngine: Sendable {
	func sign(app: URL, identity: SigningIdentity, options: SigningOptions) throws
	/// Has `executable` load the library at `path` (weakly, so it still
	/// opens without it), before it's signed (#49). False when it couldn't,
	/// as when the executable has no room for another load command.
	func load(_ path: String, into executable: URL) -> Bool
}

/// The signing job behind `SigningKit.sign`: unpack, check, sign, repack.
/// The engine, work folder and free-space check can be swapped in tests.
struct IPASigner: Sendable {
	var engine: any SigningEngine = ZsignEngine()
	var workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Signing", isDirectory: true)
	var freeSpace: @Sendable (URL) throws -> Int64? = IPASigner.availableCapacity

	/// Room kept free beyond the unpacked app and the new IPA.
	static let margin: Int64 = 64 << 20

	/// One job at a time: zsign keeps global state, and two unpacked apps
	/// would need twice the disk space.
	private static let queue = DispatchQueue(label: "Atelier.SigningKit", qos: .userInitiated)

	func sign(
		ipa: URL,
		with identity: SigningIdentity,
		options: SigningOptions,
		outputDirectory: URL?,
		progress: (@Sendable (SigningProgress) -> Void)?
	) async throws -> SignedIPA {
		let cancellation = Cancellation()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				Self.queue.async {
					continuation.resume(with: Result {
						try run(ipa: ipa, identity: identity, options: options, outputDirectory: outputDirectory, progress: progress ?? { _ in }, cancellation: cancellation)
					})
				}
			}
		} onCancel: {
			cancellation.cancel()
		}
	}

	func pack(app: URL, outputDirectory: URL?) async throws -> URL {
		let cancellation = Cancellation()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				Self.queue.async {
					continuation.resume(with: Result {
						try pack(app: app, outputDirectory: outputDirectory, cancellation: cancellation)
					})
				}
			}
		} onCancel: {
			cancellation.cancel()
		}
	}

	private func pack(app: URL, outputDirectory: URL?, cancellation: Cancellation) throws -> URL {
		try cancellation.check()
		let manager = FileManager.default
		guard manager.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else {
			throw SigningError.corruptArchive("the app has no Info.plist")
		}
		let job = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let payload = job.appendingPathComponent("Payload", isDirectory: true)
		try manager.createDirectory(at: payload, withIntermediateDirectories: true)
		defer { try? manager.removeItem(at: job) }

		// A copy of the app, and the IPA. The copy is a clone on APFS.
		let size = Self.size(of: app)
		let needed = size * 2 + Self.margin
		if let available = try? freeSpace(job), available < needed {
			throw SigningError.outOfSpace(needed: needed, available: available)
		}
		try manager.copyItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
		let packed = job.appendingPathComponent("App.ipa")
		try Self.pack(payload, to: packed, compressed: false, progress: { _ in }, cancellation: cancellation)

		let destinationFolder = outputDirectory ?? manager.temporaryDirectory
		try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
		let destination = destinationFolder.appendingPathComponent("\(UUID().uuidString).ipa")
		try manager.moveItem(at: packed, to: destination)
		return destination
	}

	/// The bytes of the regular files in `folder` and below.
	static func size(of folder: URL) -> Int64 {
		let manager = FileManager.default
		return ((try? manager.subpathsOfDirectory(atPath: folder.path)) ?? []).reduce(Int64(0)) { total, relative in
			let attributes = try? manager.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)
			guard attributes?[.type] as? FileAttributeType == .typeRegular else { return total }
			return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
		}
	}

	private func run(
		ipa: URL,
		identity: SigningIdentity,
		options: SigningOptions,
		outputDirectory: URL?,
		progress: (SigningProgress) -> Void,
		cancellation: Cancellation
	) throws -> SignedIPA {
		try cancellation.check()
		let manager = FileManager.default
		let job = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try manager.createDirectory(at: job, withIntermediateDirectories: true)
		defer { try? manager.removeItem(at: job) }

		let archive: Archive
		do {
			archive = try Archive(url: ipa, accessMode: .read)
		} catch {
			throw SigningError.corruptArchive("it isn't a ZIP archive")
		}
		let entries = archive.filter { Self.isPayload($0.path) }
		guard !entries.isEmpty else { throw SigningError.corruptArchive("there's no Payload folder") }

		// The unpacked app, plus a stored (uncompressed) copy of it in the new IPA.
		let unpackedSize = entries.reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) }
		let needed = unpackedSize * 2 + Self.margin
		if let available = try? freeSpace(job), available < needed {
			throw SigningError.outOfSpace(needed: needed, available: available)
		}

		progress(.unpacking(0))
		try Self.unpack(entries, from: archive, into: job, totalBytes: unpackedSize, progress: progress, cancellation: cancellation)

		let payload = job.appendingPathComponent("Payload", isDirectory: true)
		let app = try Self.findApp(in: payload)
		try Self.prepare(app)
		let infoPlist = app.appendingPathComponent("Info.plist")
		let originalBundleID = try Self.bundleID(in: infoPlist)
		let bundleID = options.bundleID ?? options.target.bundleID(for: originalBundleID)
		try BundleIDRewriter.rewrite(app: app, from: originalBundleID, to: bundleID)
		// An Atelier's own way back from LocalDevVPN, which a copy of it
		// doesn't share (#9, #113).
		try Self.setSwitchBack(for: bundleID, in: infoPlist)
		// Before the install check scheme, which goes back in after (#113).
		if options.removesURLSchemes { try Self.removeURLSchemes(from: infoPlist) }
		try Self.setInstallCheck(options.installCheckScheme, in: infoPlist)
		try Self.set(options.infoPlistValues, in: infoPlist)
		// zsign names it in the Info.plist; the languages' names are left to
		// Atelier (#113).
		if let name = options.displayName { try Self.setLocalizedName(name, in: app) }
		let iconChanged = try options.icon.map { try AppIconWriter.write($0, into: app) } ?? false
		try Self.setPackagedCertificate(options.packagedCertificate, in: app)
		try Self.checkBinaries(in: app)

		var options = options
		// What the binaries were signed with, read before the library goes in.
		let found = try Self.entitlementBundles(in: app)
		let kept = try keepAppGroupsInFolders(in: app, asking: found.bundles, profile: identity.profile, options: options, appBundleID: originalBundleID, signedBundleID: bundleID)
		var entitlements = try Self.fitEntitlements(found, to: identity.profile, options: &options, in: job, renamedGroups: kept.names, groupFolders: kept.folders)
		try redirectAppGroups(in: app, report: &entitlements, options: options, keptInFolders: kept.loaded)
		let signedFor = Self.applicationIdentifier(entitlements: options.entitlements, profile: identity.profile)

		try cancellation.check()
		progress(.signing)
		try engine.sign(app: app, identity: identity, options: options)

		let info: IPAInfo
		do {
			info = try IPAInfo.parse(infoPlist: Data(contentsOf: app.appendingPathComponent("Info.plist")))
		} catch {
			throw SigningError.corruptArchive("its Info.plist can't be read after signing")
		}

		progress(.packing(0))
		let packed = job.appendingPathComponent("Signed.ipa")
		try Self.pack(payload, to: packed, compressed: options.compressed, progress: progress, cancellation: cancellation)

		let destinationFolder = outputDirectory ?? manager.temporaryDirectory
		try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
		let destination = destinationFolder.appendingPathComponent("\(UUID().uuidString).ipa")
		try manager.moveItem(at: packed, to: destination)
		let identity = SignedAppIdentity(
			bundleID: info.bundleID,
			originalBundleID: originalBundleID,
			applicationIdentifier: signedFor?.applicationIdentifier,
			teamID: signedFor?.teamID
		)
		return SignedIPA(url: destination, info: info, identity: identity, entitlements: entitlements, iconChanged: iconChanged)
	}

	// MARK: Unpacking

	/// Only the app is unpacked. Other top-level folders (SwiftSupport,
	/// Symbols, iTunesMetadata.plist) are for the App Store, not installs.
	static func isPayload(_ path: String) -> Bool {
		path.hasPrefix("Payload/") && !path.contains("__MACOSX")
	}

	private static func unpack(
		_ entries: [Entry],
		from archive: Archive,
		into folder: URL,
		totalBytes: Int64,
		progress: (SigningProgress) -> Void,
		cancellation: Cancellation
	) throws {
		var throttle = Throttle()
		var done: Int64 = 0
		guard let root = realPath(folder.path) else { throw CocoaError(.fileNoSuchFile) }
		for entry in entries {
			try cancellation.check()
			// ZIPFoundation's own unzip refuses "../" paths; this loop has to as well.
			// A link unpacked earlier could also lead an entry out (#22).
			let destination = folder.appendingPathComponent(entry.path)
			guard isContained(entry.path), leadsInside(destination.deletingLastPathComponent().path, root: root) else {
				throw SigningError.corruptArchive("an entry points outside the app (\(entry.path))")
			}
			do {
				let checksum = try archive.extract(entry, to: destination)
				if entry.type == .file, checksum != entry.checksum {
					throw SigningError.corruptArchive("\(entry.path) is damaged")
				}
				// zsign follows links when it signs, and later entries are
				// written through them, so they must stay in the app (#22),
				// whatever ZIPFoundation's own check allows.
				if entry.type == .symlink {
					let target = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
					let parent = destination.deletingLastPathComponent().path
					guard !target.hasPrefix("/"), leadsInside(parent + "/" + target, root: root) else {
						throw SigningError.corruptArchive("a link points outside the app (\(entry.path))")
					}
				}
			} catch let error as SigningError {
				throw error
			} catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
				throw SigningError.outOfSpace(needed: totalBytes * 2 + margin, available: 0)
			} catch let error as Archive.ArchiveError {
				// ZIPFoundation refuses most such links itself.
				if case .uncontainedSymlink = error {
					throw SigningError.corruptArchive("a link points outside the app (\(entry.path))")
				}
				throw SigningError.corruptArchive("\(entry.path) can't be unpacked (\(error))")
			}
			done += Int64(clamping: entry.uncompressedSize)
			if let fraction = throttle.fraction(done: done, of: totalBytes) { progress(.unpacking(fraction)) }
		}
	}

	/// Whether an entry's path stays inside the folder it's unpacked into.
	/// Checked on the path itself, not the file system: Foundation drops a
	/// leading /private from paths that exist and keeps it on ones that
	/// don't, so comparing standardized URLs fails for every new file under
	/// iOS's /private/var temporary folder.
	static func isContained(_ path: String) -> Bool {
		!path.hasPrefix("/") && !path.split(separator: "/").contains("..")
	}

	/// Whether `path` really leads to `root` or inside it, following links:
	/// the real path of its longest existing part, plus the rest. A rest
	/// that goes up a level counts as outside, as where it leads isn't known
	/// until it exists. `root` must be a real path.
	static func leadsInside(_ path: String, root: String) -> Bool {
		var current = path
		var rest: [String] = []
		while true {
			if let real = realPath(current) {
				guard !rest.contains("..") else { return false }
				let full = ([real] + rest.reversed()).joined(separator: "/")
				return full == root || full.hasPrefix(root.hasSuffix("/") ? root : root + "/")
			}
			let parent = (current as NSString).deletingLastPathComponent
			guard !parent.isEmpty, parent != current else { return false }
			rest.append((current as NSString).lastPathComponent)
			current = parent
		}
	}

	/// The path with every link resolved, or nil if it doesn't exist.
	static func realPath(_ path: String) -> String? {
		guard let resolved = realpath(path, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	/// The one `.app` folder in Payload.
	static func findApp(in payload: URL) throws -> URL {
		let apps = ((try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.pathExtension == "app" }
		guard apps.count == 1, let app = apps.first else {
			throw SigningError.corruptArchive(apps.isEmpty ? "there's no app in its Payload folder" : "its Payload folder holds more than one app")
		}
		guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else {
			throw SigningError.corruptArchive("the app has no Info.plist")
		}
		return app
	}

	// MARK: Preparing

	/// What Feather does to every app before zsign signs it, with its default
	/// options. Without it iOS can refuse an app that was signed fine: stale
	/// signatures and profiles from the original signer are left beside the
	/// new ones, and `UISupportedDevices` lists device models iOS checks
	/// against. Feather's arm64e slice fixup (for iOS 26) isn't done here.
	static func prepare(_ app: URL) throws {
		let manager = FileManager.default
		try removeSupportedDevices(from: app.appendingPathComponent("Info.plist"))

		for name in ["embedded.mobileprovision", "com.apple.WatchPlaceholder", "SignedByEsign"] {
			let url = app.appendingPathComponent(name)
			if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
		}
		// Old signatures in every bundle; zsign writes new ones.
		let signatures = ((try? manager.subpathsOfDirectory(atPath: app.path)) ?? [])
			.filter { ($0 as NSString).lastPathComponent == "_CodeSignature" }
			.sorted { $0.count > $1.count }
		for relative in ["_CodeSignature"] + signatures {
			let url = app.appendingPathComponent(relative)
			if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
		}
		// Watch app placeholders without an Info.plist can't be signed or installed.
		let watch = app.appendingPathComponent("Watch", isDirectory: true)
		for bundle in (try? manager.contentsOfDirectory(at: watch, includingPropertiesForKeys: nil)) ?? []
		where bundle.pathExtension == "app" && !manager.fileExists(atPath: bundle.appendingPathComponent("Info.plist").path) {
			try manager.removeItem(at: bundle)
		}
	}

	/// Drops `UISupportedDevices`, keeping the plist's format.
	private static func removeSupportedDevices(from plist: URL) throws {
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard
			var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any],
			info.removeValue(forKey: "UISupportedDevices") != nil
		else { return }
		try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
	}

	/// Adds the install check scheme to the main app's Info.plist (or only
	/// removes an old one), keeping the plist's format. Done before signing,
	/// so the signature covers it.
	static func setInstallCheck(_ scheme: String?, in plist: URL) throws {
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("its Info.plist can't be read")
		}
		let hasCheck = ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? []).contains { type in
			(type["CFBundleURLSchemes"] as? [String] ?? []).contains(where: InstallCheck.isCheckScheme)
		}
		guard scheme != nil || hasCheck else { return }
		try PropertyListSerialization.data(fromPropertyList: InstallCheck.apply(scheme, to: info), format: format, options: 0).write(to: plist)
	}

	/// Sets `values` in the main app's Info.plist, keeping its format (#24).
	/// Done before signing, so the signature covers them.
	static func set(_ values: [String: String], in plist: URL) throws {
		guard !values.isEmpty else { return }
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("its Info.plist can't be read")
		}
		info.merge(values) { _, new in new }
		try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
	}

	/// Writes the certificate a copy of Atelier comes with into the app,
	/// next to its Info.plist (#113), after removing any the app had, also
	/// without one: a link is removed, not written through (#22). Done
	/// before signing, so the signature seals it.
	static func setPackagedCertificate(_ certificate: PackagedCertificate?, in app: URL) throws {
		let file = app.appendingPathComponent(PackagedCertificate.fileName)
		let manager = FileManager.default
		if (try? manager.attributesOfItem(atPath: file.path)) != nil { try manager.removeItem(at: file) }
		guard let certificate else { return }
		try certificate.encoded().write(to: file, options: .withoutOverwriting)
	}

	/// Drops the main app's URL schemes (#113), keeping its plist's format,
	/// and an Atelier's switch-back one, which no link is meant for: it's the
	/// copy's own (`SwitchBackScheme`, #9).
	static func removeURLSchemes(from plist: URL) throws {
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("its Info.plist can't be read")
		}
		guard info["CFBundleURLTypes"] != nil else { return }
		let kept = ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? []).filter(SwitchBackScheme.isSwitchBack)
		if kept.isEmpty {
			info.removeValue(forKey: "CFBundleURLTypes")
		} else {
			info["CFBundleURLTypes"] = kept
		}
		try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
	}

	/// Gives an Atelier the switch-back scheme of the bundle ID it's signed
	/// as (`SwitchBackScheme`, #9), keeping the plist's format. Any other
	/// app, without that URL type, is left alone.
	static func setSwitchBack(for bundleID: String, in plist: URL) throws {
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("its Info.plist can't be read")
		}
		guard let scheme = SwitchBackScheme.scheme(in: info), scheme != SwitchBackScheme.scheme(for: bundleID) else { return }
		try PropertyListSerialization.data(fromPropertyList: SwitchBackScheme.apply(bundleID: bundleID, to: info), format: format, options: 0).write(to: plist)
	}

	/// Names the app `name` in each language it has an InfoPlist.strings
	/// for (#113), as Feather does, so a copy's name shows whatever
	/// language the iPhone is in. Each file keeps its format, but for text,
	/// which Foundation can't write, so it's written as a binary plist, as
	/// Xcode builds them. A file that can't be read is left alone.
	static func setLocalizedName(_ name: String, in app: URL) throws {
		let manager = FileManager.default
		let languages = ((try? manager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.pathExtension == "lproj" }
		for language in languages {
			let strings = language.appendingPathComponent("InfoPlist.strings")
			var format = PropertyListSerialization.PropertyListFormat.xml
			guard
				let data = try? Data(contentsOf: strings),
				var values = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
			else { continue }
			values["CFBundleDisplayName"] = name
			try PropertyListSerialization.data(fromPropertyList: values, format: format == .openStep ? .binary : format, options: 0).write(to: strings)
		}
	}

	// MARK: Bundle ID

	/// The app's bundle ID, before any change.
	static func bundleID(in plist: URL) throws -> String {
		guard
			let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil) as? [String: Any],
			let id = info["CFBundleIdentifier"] as? String, !id.isEmpty
		else { throw SigningError.corruptArchive("its Info.plist has no bundle ID") }
		return id
	}

	/// The App ID the app is signed for, and the profile's team: zsign signs
	/// with the entitlements file when there is one, else the profile's, and
	/// takes `application-identifier` from it as it is. Nil when neither can
	/// be read.
	static func applicationIdentifier(entitlements: URL?, profile: URL) -> (applicationIdentifier: String?, teamID: String?)? {
		guard
			let data = try? Data(contentsOf: profile),
			let parsed = try? ProvisioningProfile(data: data)
		else { return nil }
		if let entitlements,
		   let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: entitlements), options: [], format: nil) as? [String: Any] {
			return (plist["application-identifier"] as? String, parsed.teamID)
		}
		return (parsed.applicationIdentifier, parsed.teamID)
	}

	// MARK: Entitlements

	/// Reconciles what the app and its extensions ask for (`found`, from
	/// `entitlementBundles`) with the profile (#7) and, unless the caller
	/// gave an entitlements file or turned fitting off, has zsign sign with
	/// the result. Nil when the profile can't be read; zsign then says
	/// what's wrong with it.
	///
	/// The app's App Groups count as granted under `renamedGroups`' names,
	/// else `SigningOptions.appGroups`', kept in `groupFolders` (#49).
	static func fitEntitlements(_ found: (bundles: [EntitlementReconciler.Bundle], readAny: Bool), to profile: URL, options: inout SigningOptions, in job: URL, renamedGroups: [String: String] = [:], groupFolders: [String: String] = [:]) throws -> EntitlementsReport? {
		guard
			let data = try? Data(contentsOf: profile),
			let parsed = try? ProvisioningProfile(data: data),
			let granted = try? ProvisioningProfile.entitlements(in: data)
		else { return nil }
		let result = EntitlementReconciler.reconcile(
			profile: granted,
			teamID: parsed.teamID,
			isWildcard: parsed.isWildcard,
			bundles: found.bundles,
			readFromApp: found.readAny,
			renamedGroups: renamedGroups.isEmpty ? options.appGroups : renamedGroups,
			groupFolders: groupFolders
		)
		if options.entitlements == nil, options.fitsEntitlements {
			let url = job.appendingPathComponent("Entitlements.plist")
			try PropertyListSerialization.data(fromPropertyList: result.entitlements, format: .xml, options: 0).write(to: url)
			options.entitlements = url
		}
		return result.report
	}

	/// Has the app and its extensions send their own names for the App
	/// Groups the profile allows under the team's to those (#49,
	/// `AppGroupRedirect`), and notes in the report whether the app does,
	/// or with a certificate, whether it sends them to their folders
	/// (`keptInFolders`).
	private func redirectAppGroups(in app: URL, report: inout EntitlementsReport?, options: SigningOptions, keptInFolders: Bool?) throws {
		guard let index = report?.items.firstIndex(where: { $0.key == AppGroups.entitlement }) else { return }
		if let keptInFolders {
			report?.items[index].redirected = keptInFolders
			return
		}
		guard let library = options.appGroupsLibrary, let names = report?.items[index].renamedValues, !names.isEmpty else { return }
		let loaded = try AppGroupRedirect.apply(names, library: library, to: app) { engine.load($0, into: $1) }
		report?.items[index].redirected = loaded
	}

	/// With a certificate whose profile has App Groups of its own but not
	/// all of the app's, keeps those in folders of their own in one of its
	/// groups (#49, `AppGroups.home(in:)`, `AppGroups.folders`): puts
	/// Atelier's library in the app, which sends the app and its extensions
	/// there. Returns the group and folder each is kept in, by the app's
	/// name, and whether the app loads the library, nil when there was
	/// nothing to keep: with an Apple ID, which renames them instead
	/// (`SigningOptions.appGroups`), without the library, with an
	/// entitlements file of the caller's, or when the profile has all of
	/// the app's groups, or none of its own.
	private func keepAppGroupsInFolders(in app: URL, asking bundles: [EntitlementReconciler.Bundle], profile: URL, options: SigningOptions, appBundleID: String, signedBundleID: String) throws -> (names: [String: String], folders: [String: String], loaded: Bool?) {
		guard
			let library = options.appGroupsLibrary, options.appGroups.isEmpty, options.entitlements == nil,
			let data = try? Data(contentsOf: profile),
			let granted = (try? ProvisioningProfile.entitlements(in: data))?[AppGroups.entitlement],
			let home = AppGroups.home(in: granted)
		else { return ([:], [:], nil) }
		var missing: [String] = []
		for bundle in bundles {
			for group in bundle.entitlements[AppGroups.entitlement] as? [String] ?? []
			where !missing.contains(group) && !EntitlementReconciler.covers(granted, group, key: AppGroups.entitlement) {
				missing.append(group)
			}
		}
		let folders = AppGroups.folders(for: missing, appBundleID: appBundleID, signedBundleID: signedBundleID)
		guard !folders.isEmpty else { return ([:], [:], nil) }
		let names = folders.mapValues { _ in home }
		guard try AppGroupRedirect.apply(names, folders: folders, library: library, to: app, load: { engine.load($0, into: $1) }) else {
			return ([:], [:], false)
		}
		return (names, folders, true)
	}

	/// The app, then its extensions and Watch apps, with the entitlements
	/// their executables were signed with (none for an unsigned one), and
	/// whether any had some.
	static func entitlementBundles(in app: URL) throws -> (bundles: [EntitlementReconciler.Bundle], readAny: Bool) {
		var readAny = false
		func bundle(_ url: URL, name: String) -> EntitlementReconciler.Bundle {
			var entitlements: [String: Any] = [:]
			if let executable = executable(of: url),
			   let data = try? MachO.entitlements(executable),
			   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
				entitlements = plist
				readAny = true
			}
			return EntitlementReconciler.Bundle(name: name, entitlements: entitlements)
		}
		var bundles = [bundle(app, name: "")]
		let manager = FileManager.default
		for relative in ((try? manager.subpathsOfDirectory(atPath: app.path)) ?? []).sorted() {
			let url = app.appendingPathComponent(relative)
			guard ["appex", "app"].contains(url.pathExtension),
			      manager.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
			else { continue }
			bundles.append(bundle(url, name: url.deletingPathExtension().lastPathComponent))
		}
		return (bundles, readAny)
	}

	// MARK: Checks

	/// Every bundle's executable and every dylib must be a Mach-O that isn't
	/// App Store-encrypted. zsign would fail on the first, and sign the second
	/// into an app that never launches.
	static func checkBinaries(in app: URL) throws {
		for binary in try binaries(in: app) {
			let relative = String(binary.path.dropFirst(app.path.count + 1))
			let kind: MachO.Kind
			do {
				kind = try MachO.inspect(binary)
			} catch {
				throw SigningError.unsupportedBinary(relative)
			}
			switch kind {
			case .notMachO: throw SigningError.unsupportedBinary(relative)
			case .machO(encrypted: true): throw SigningError.encryptedBinary(relative)
			case .machO(encrypted: false): break
			}
		}
	}

	/// The main executable first, then nested bundles' executables and dylibs.
	static func binaries(in app: URL) throws -> [URL] {
		guard let main = executable(of: app) else {
			throw SigningError.unsupportedBinary(app.lastPathComponent)
		}
		var result = [main]
		let manager = FileManager.default
		for relative in (try? manager.subpathsOfDirectory(atPath: app.path)) ?? [] {
			let url = app.appendingPathComponent(relative)
			switch url.pathExtension {
			case "dylib":
				result.append(url)
			case "app", "appex", "framework", "xpc":
				guard manager.fileExists(atPath: url.appendingPathComponent("Info.plist").path) else { continue }
				if let executable = executable(of: url) {
					result.append(executable)
				} else if url.pathExtension != "framework" {
					// Apps and extensions always have one; a framework can be resources only.
					throw SigningError.unsupportedBinary(relative)
				}
			default:
				continue
			}
		}
		return result
	}

	/// A bundle's executable, if it exists: CFBundleExecutable, or the
	/// bundle's name when the Info.plist doesn't say.
	static func executable(of bundle: URL) -> URL? {
		let plist = try? PropertyListSerialization.propertyList(
			from: Data(contentsOf: bundle.appendingPathComponent("Info.plist")), options: [], format: nil
		) as? [String: Any]
		let name = plist?["CFBundleExecutable"] as? String ?? bundle.deletingPathExtension().lastPathComponent
		let url = bundle.appendingPathComponent(name)
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
		return url
	}

	// MARK: Packing

	private static func pack(
		_ payload: URL,
		to destination: URL,
		compressed: Bool,
		progress: (SigningProgress) -> Void,
		cancellation: Cancellation
	) throws {
		let manager = FileManager.default
		let base = payload.deletingLastPathComponent()
		let paths = ["Payload"] + (try manager.subpathsOfDirectory(atPath: payload.path)).sorted().map { "Payload/\($0)" }
		let sizes = paths.map { path -> Int64 in
			let attributes = try? manager.attributesOfItem(atPath: base.appendingPathComponent(path).path)
			guard attributes?[.type] as? FileAttributeType == .typeRegular else { return 0 }
			return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
		}
		let total = sizes.reduce(0, +)

		let archive = try Archive(url: destination, accessMode: .create)
		var throttle = Throttle()
		var done: Int64 = 0
		for (path, size) in zip(paths, sizes) {
			try cancellation.check()
			do {
				try archive.addEntry(with: path, relativeTo: base, compressionMethod: compressed ? .deflate : .none)
			} catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
				throw SigningError.outOfSpace(needed: total + margin, available: 0)
			}
			done += size
			if let fraction = throttle.fraction(done: done, of: total) { progress(.packing(fraction)) }
		}
	}

	// MARK: Disk space

	@Sendable
	static func availableCapacity(at url: URL) throws -> Int64? {
		#if os(iOS) || os(macOS)
		// What iOS would free up for a user-started task, purgeable files included.
		let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
		if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
		return values.volumeAvailableCapacity.map(Int64.init)
		#else
		let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
		return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
		#endif
	}
}

/// Passes progress on in steps of at least 1%, and always the end, so an app
/// of thousands of files doesn't flood the UI.
private struct Throttle {
	private var last = 0.0

	/// The fraction to report, or nil to skip this one.
	mutating func fraction(done: Int64, of total: Int64) -> Double? {
		let fraction = total > 0 ? min(Double(done) / Double(total), 1) : 1
		guard fraction - last >= 0.01 || (fraction == 1 && last < 1) else { return nil }
		last = fraction
		return fraction
	}
}

/// Set from the task's cancellation handler, checked between files.
final class Cancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false

	func cancel() {
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	func check() throws {
		lock.lock()
		defer { lock.unlock() }
		if cancelled { throw CancellationError() }
	}
}
