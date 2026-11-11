#if canImport(SwiftData)
import Foundation
import InstallKit
import SwiftData
import SigningKit
import XCTest
@testable import AtelierCore

final class PersistenceTests: XCTestCase {
	@MainActor
	func testStoresASourceWithItsApps() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext

		let source = SourceRecord(url: URL(string: "https://example.com/source.json")!, name: "Example")
		context.insert(source)
		let app = AppRecord(bundleID: "com.example.app", name: "App", latestVersion: "1.0")
		context.insert(app)
		app.source = source
		try context.save()

		let sources = try context.fetch(FetchDescriptor<SourceRecord>())
		XCTAssertEqual(sources.map(\.name), ["Example"])
		XCTAssertEqual(sources.first?.apps.map(\.bundleID), ["com.example.app"])
	}

	/// A store saved to a file opens again with its records.
	@MainActor
	func testReopensAStoreFromItsFile() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let storeURL = directory.appendingPathComponent("Atelier.store")

		do {
			let container = try Persistence.makeContainer(at: storeURL)
			let context = container.mainContext
			let source = SourceRecord(url: URL(string: "https://example.com/source.json")!, name: "Example")
			context.insert(source)
			let app = AppRecord(bundleID: "com.example.app", name: "App", latestVersion: "1.0")
			context.insert(app)
			app.source = source
			let install = InstallRecord(bundleID: "com.example.installed", name: "Installed", version: "2.0")
			install.buildVersion = "7"
			context.insert(install)
			try context.save()
		}

		let container = try Persistence.makeContainer(at: storeURL)
		let context = container.mainContext
		let sources = try context.fetch(FetchDescriptor<SourceRecord>())
		XCTAssertEqual(sources.map(\.name), ["Example"])
		XCTAssertEqual(sources.first?.apps.map(\.bundleID), ["com.example.app"])
		XCTAssertEqual(sources.first?.apps.first?.category, "other")
		let installs = try context.fetch(FetchDescriptor<InstallRecord>())
		XCTAssertEqual(installs.map(\.bundleID), ["com.example.installed"])
		XCTAssertEqual(installs.first?.buildVersion, "7")
		XCTAssertNil(installs.first?.sourceURL)
	}

	/// Where Atelier kept its store in an App Group's container, it takes it
	/// into its own, with the data kept in files of their own, and leaves
	/// the shared one to copies still running an older build (#113).
	@MainActor
	func testAdoptsTheStoreItSharedWithItsCopies() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let shared = directory.appending(path: "Group/Library/Application Support/default.store")
		let own = directory.appending(path: "App/Library/Application Support/default.store")
		try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
		// Large enough for Core Data to keep it in a file of its own.
		let json = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
		try saveSource(named: "Shared", json: json, install: "com.example.app.atelier2", in: shared)

		XCTAssertTrue(try Persistence.adopt(storeAt: shared, into: own))

		XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: own.deletingLastPathComponent().appending(path: "Store adoption").path))
		let container = try Persistence.makeContainer(at: own)
		let context = container.mainContext
		let sources = try context.fetch(FetchDescriptor<SourceRecord>())
		XCTAssertEqual(sources.map(\.name), ["Shared"])
		XCTAssertEqual(sources.first?.json, json)
		XCTAssertEqual(try context.fetch(FetchDescriptor<InstallRecord>()).map(\.bundleID), ["com.example.app.atelier2"])
	}

	/// Once it has a store of its own, Atelier keeps it.
	@MainActor
	func testKeepsItsOwnStore() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let shared = directory.appending(path: "Group/default.store")
		let own = directory.appending(path: "App/default.store")
		for url in [shared, own] {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		}
		try saveSource(named: "Shared", in: shared)
		try saveSource(named: "Own", in: own)

		XCTAssertFalse(try Persistence.adopt(storeAt: shared, into: own))

		let container = try Persistence.makeContainer(at: own)
		let sources = try container.mainContext.fetch(FetchDescriptor<SourceRecord>())
		XCTAssertEqual(sources.map(\.name), ["Own"])
	}

	/// No store to take, or the same one: nothing happens.
	func testAdoptsNothingWithoutAnotherStore() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let own = directory.appending(path: "App/default.store")

		XCTAssertFalse(try Persistence.adopt(storeAt: directory.appending(path: "Group/default.store"), into: own))
		XCTAssertFalse(try Persistence.adopt(storeAt: own, into: own))
		XCTAssertFalse(FileManager.default.fileExists(atPath: own.deletingLastPathComponent().path))
	}

	/// A copy cut short, which left a log without its store, is made again
	/// rather than mixed with what's left.
	@MainActor
	func testAdoptsAgainAfterACopyCutShort() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let shared = directory.appending(path: "Group/default.store")
		let own = directory.appending(path: "App/default.store")
		for url in [shared, own] {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		}
		try saveSource(named: "Shared", in: shared)
		try Data("left over".utf8).write(to: own.deletingLastPathComponent().appending(path: "default.store-wal"))
		try FileManager.default.createDirectory(at: own.deletingLastPathComponent().appending(path: "Store adoption"), withIntermediateDirectories: true)

		XCTAssertTrue(try Persistence.adopt(storeAt: shared, into: own))

		let container = try Persistence.makeContainer(at: own)
		let sources = try container.mainContext.fetch(FetchDescriptor<SourceRecord>())
		XCTAssertEqual(sources.map(\.name), ["Shared"])
	}

	/// The store file, its log and its data folder, as Core Data names them.
	func testNamesTheStoresParts() {
		let parts = Persistence.storeParts(of: URL(filePath: "/A/Application Support/default.store"))
		XCTAssertEqual(parts.map(\.path), [
			"/A/Application Support/default.store",
			"/A/Application Support/default.store-wal",
			"/A/Application Support/.default_SUPPORT",
		])
	}

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	/// Saves a source, and an install, to the store at `url`.
	@MainActor
	private func saveSource(named name: String, json: Data? = nil, install bundleID: String? = nil, in url: URL) throws {
		let container = try Persistence.makeContainer(at: url)
		let context = container.mainContext
		let source = SourceRecord(url: URL(string: "https://example.com/\(name).json")!, name: name)
		source.json = json
		context.insert(source)
		if let bundleID {
			context.insert(InstallRecord(bundleID: bundleID, name: "Copy", version: "1.0"))
		}
		try context.save()
	}

	/// Atelier's store starts at version 1, with nothing older to migrate
	/// (#125).
	func testStartsAtVersion1() {
		XCTAssertEqual(AtelierSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
		XCTAssertEqual(AtelierMigrationPlan.schemas.count, 1)
		XCTAssertTrue(AtelierMigrationPlan.stages.isEmpty)
	}

	/// Whether an app is still installed, from its check scheme (#55), and
	/// a scheme passing to a new install once the app that had it is gone.
	@MainActor
	func testTellsWhetherAnAppIsStillInstalled() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let gone = InstallRecord(bundleID: "com.example.gone", name: "Gone", version: "1.0")
		gone.checkScheme = "atelier-check-1"
		let there = InstallRecord(bundleID: "com.example.there", name: "There", version: "1.0")
		there.checkScheme = "atelier-check-2"
		context.insert(gone)
		context.insert(there)
		try context.save()

		let registered: Set<String> = ["atelier-check-2"]
		XCTAssertEqual(gone.presence { registered.contains($0) }, .deleted)
		XCTAssertEqual(there.presence { registered.contains($0) }, .installed)

		// A new install signed with the scheme the deleted app had.
		let next = InstallRecord(bundleID: "com.example.next", name: "Next", version: "1.0")
		context.insert(next)
		InstalledApps.give("atelier-check-1", to: next, in: context)
		XCTAssertEqual(next.checkScheme, "atelier-check-1")
		XCTAssertNil(gone.checkScheme, "the scheme now answers for Next, not Gone")
		XCTAssertEqual(there.checkScheme, "atelier-check-2")
	}

	/// Without a check scheme, a Direct installs scan made since the install
	/// tells whether the app is still there, and its version on the device
	/// (#17).
	@MainActor
	func testScanTellsAboutAppsWithoutACheckScheme() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
		let kept = InstallRecord(bundleID: "com.example.kept", name: "Kept", version: "1.0", installedAt: installedAt)
		let gone = InstallRecord(bundleID: "com.example.gone", name: "Gone", version: "1.0", installedAt: installedAt)
		let checked = InstallRecord(bundleID: "com.example.checked", name: "Checked", version: "1.0", installedAt: installedAt)
		checked.checkScheme = "atelier-check-1"
		for record in [kept, gone, checked] { context.insert(record) }
		try context.save()

		let scan = DeviceScan(scannedAt: installedAt.addingTimeInterval(60), versions: ["com.example.kept": "1.1", "com.example.checked": "1.0"])
		XCTAssertEqual(kept.presence(isRegistered: { _ in false }, scan: scan), .installed)
		XCTAssertEqual(gone.presence(isRegistered: { _ in false }, scan: scan), .deleted)
		XCTAssertEqual(checked.presence(isRegistered: { _ in false }, scan: scan), .deleted, "the check scheme, which answers live, wins")
		let older = DeviceScan(scannedAt: installedAt.addingTimeInterval(-60), versions: [:])
		XCTAssertEqual(gone.presence(isRegistered: { _ in false }, scan: older), .unknown, "a scan from before the install says nothing")

		XCTAssertEqual(InstalledApps.apply(scan, in: context).map(\.bundleID), ["com.example.kept"])
		XCTAssertEqual(kept.version, "1.1")
		XCTAssertEqual(gone.version, "1.0")
	}

	/// A reinstall from the Library shows the icon its source lists.
	@MainActor
	func testFindsAnInstalledAppsIcon() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let one = SourceRecord(url: URL(string: "https://one.example/apps.json")!, name: "One")
		let two = SourceRecord(url: URL(string: "https://two.example/apps.json")!, name: "Two")
		let fromOne = AppRecord(bundleID: "com.example.app", name: "App", latestVersion: "1.0")
		fromOne.iconURL = URL(string: "https://one.example/icon.png")
		fromOne.source = one
		let fromTwo = AppRecord(bundleID: "com.example.app", name: "App", latestVersion: "1.0")
		fromTwo.iconURL = URL(string: "https://two.example/icon.png")
		fromTwo.source = two
		context.insert(one)
		context.insert(two)
		context.insert(fromOne)
		context.insert(fromTwo)
		let copy = InstallRecord(bundleID: "com.example.app.atelier2", name: "App", version: "1.0")
		copy.originalBundleID = "com.example.app"
		copy.sourceURL = two.url
		let picked = InstallRecord(bundleID: "com.example.picked", name: "Picked", version: "1.0")
		context.insert(copy)
		context.insert(picked)
		try context.save()

		XCTAssertEqual(InstalledApps.iconURL(of: copy, in: context), fromTwo.iconURL, "from the source it was installed from")
		XCTAssertNil(InstalledApps.iconURL(of: picked, in: context))
	}

	/// Source app → installed bundle ID → certificate and App ID (#8).
	@MainActor
	func testMapsASourceAppToItsInstalls() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let certificateID = UUID()

		let original = InstallRecord(bundleID: "com.spotify.client", name: "Spotify", version: "9.0")
		original.note(SignedAppIdentity(bundleID: "com.spotify.client", originalBundleID: "com.spotify.client", applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"))
		let copy = InstallRecord(bundleID: "com.spotify.client.atelier2", name: "EeveeSpotify", version: "9.1")
		copy.limits = ["Push notifications won't work. Your profile doesn't include it."]
		copy.certificateID = certificateID
		copy.note(SignedAppIdentity(bundleID: "com.spotify.client.atelier2", originalBundleID: "com.spotify.client", applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"))
		context.insert(original)
		context.insert(copy)
		context.insert(InstallRecord(bundleID: "com.example.other", name: "Other", version: "1.0"))
		try context.save()

		XCTAssertNil(original.originalBundleID, "installed as itself")
		XCTAssertEqual(original.target, .original)
		XCTAssertEqual(copy.target, .copy(2))
		XCTAssertEqual(copy.sourceBundleID, "com.spotify.client")
		XCTAssertEqual(copy.signedIdentity.applicationIdentifier, "TEAMAAAAAA.app.one")

		let installs = InstalledApps.records(ofSourceApp: "com.spotify.client", in: context)
		XCTAssertEqual(installs.map(\.bundleID), ["com.spotify.client", "com.spotify.client.atelier2"], "the original first")
		XCTAssertEqual(installs.last?.limits?.count, 1)
		XCTAssertEqual(InstalledApps.record("com.spotify.client.atelier2", in: context)?.certificateID, certificateID)
		XCTAssertNil(InstalledApps.record("com.example.missing", in: context))
	}

	/// A copy installed under an App ID of the user's choosing is still the
	/// copy it was numbered as (#113), from what `CopyStore` keeps for it.
	@MainActor
	func testTellsACopyInstalledUnderAnIDOfTheUsersChoosing() throws {
		let shared = CopyStore.shared
		let store = CopyStore(folder: try temporaryDirectory())
		CopyStore.shared = store
		defer {
			CopyStore.shared = shared
			try? FileManager.default.removeItem(at: store.folder)
		}
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let app = "com.google.ios.youtube"
		try store.save(CopySettings(bundleID: "com.sam.tube", tint: .green, version: "99.0"), for: "\(app).atelier3")
		let original = InstallRecord(bundleID: app, name: "YouTube", version: "21.43.5")
		let numbered = InstallRecord(bundleID: "\(app).atelier2", name: "YouTube 2", version: "21.43.5")
		numbered.note(SignedAppIdentity(bundleID: "\(app).atelier2", originalBundleID: app, applicationIdentifier: "TEAMAAAAAA.*", teamID: "TEAMAAAAAA"))
		let chosen = InstallRecord(bundleID: "com.sam.tube", name: "YouTube 3", version: "21.43.5")
		chosen.note(SignedAppIdentity(bundleID: "com.sam.tube", originalBundleID: app, applicationIdentifier: "TEAMAAAAAA.*", teamID: "TEAMAAAAAA"))
		for record in [original, numbered, chosen] { context.insert(record) }
		try context.save()

		XCTAssertEqual(chosen.sourceBundleID, app)
		XCTAssertEqual(chosen.numberedBundleID, "\(app).atelier3")
		XCTAssertEqual(chosen.target, .copy(3))
		XCTAssertEqual(chosen.appBundleID, app)
		XCTAssertEqual(chosen.copySettings?.tint, .green)
		XCTAssertEqual(numbered.target, .copy(2))
		XCTAssertNil(numbered.copySettings)
		XCTAssertNil(original.copySettings)

		XCTAssertEqual(InstalledApps.bundleID(of: .copy(3), for: app), "com.sam.tube")
		XCTAssertEqual(InstalledApps.bundleID(of: .copy(2), for: app), "\(app).atelier2")
		XCTAssertEqual(InstalledApps.bundleID(of: .original, for: app), app)
		XCTAssertEqual(InstalledApps.record(listedAs: app, as: .copy(3), in: context)?.bundleID, "com.sam.tube")
		XCTAssertEqual(InstalledApps.records(ofSourceApp: app, in: context).map(\.bundleID), [app, "\(app).atelier2", "com.sam.tube"])
		XCTAssertEqual(InstalledApps.records(ofIPA: app, in: context).map(\.bundleID), [app, "\(app).atelier2", "com.sam.tube"], "an IPA of it installs over any of them (#155)")
		XCTAssertEqual(InstalledApps.newCopy(of: app, in: context), .copy(4), "after the copy whose ID doesn't say its number")

		// The version it says it is isn't taken for an update.
		let scan = DeviceScan(versions: ["com.sam.tube": "99.0", "\(app).atelier2": "21.44.0"])
		XCTAssertEqual(InstalledApps.apply(scan, in: context).map(\.bundleID), ["\(app).atelier2"])
		XCTAssertEqual(chosen.version, "21.43.5")
	}

	/// The apps of a deleted certificate point at the same one imported
	/// again (#126), as the replacement says for each.
	@MainActor
	func testReplacesTheCertificateAppsPointAt() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let deleted = UUID(), kept = UUID(), imported = UUID()

		let one = InstallRecord(bundleID: "com.example.one", name: "One", version: "1.0")
		one.certificateID = deleted
		one.note(SignedAppIdentity(bundleID: "com.example.one", originalBundleID: "com.example.one", applicationIdentifier: "TEAMAAAAAA.*", teamID: "TEAMAAAAAA"))
		let two = InstallRecord(bundleID: "com.example.two", name: "Two", version: "1.0")
		two.certificateID = deleted
		two.note(SignedAppIdentity(bundleID: "com.example.two", originalBundleID: "com.example.two", applicationIdentifier: "TEAMBBBBBB.*", teamID: "TEAMBBBBBB"))
		let three = InstallRecord(bundleID: "com.example.three", name: "Three", version: "1.0")
		three.certificateID = kept
		let unrecorded = InstallRecord(bundleID: "com.example.four", name: "Four", version: "1.0")
		for record in [one, two, three, unrecorded] { context.insert(record) }
		try context.save()

		var asked: [String] = []
		let changed = InstalledApps.replaceCertificates(in: context) { record in
			asked.append(record.bundleID)
			guard record.certificateID == deleted, record.applicationIdentifier == "TEAMAAAAAA.*" else { return record.certificateID == kept ? kept : nil }
			return imported
		}
		XCTAssertEqual(changed.map(\.bundleID), ["com.example.one"])
		XCTAssertEqual(Set(asked), ["com.example.one", "com.example.two", "com.example.three"], "only apps with a certificate noted")
		XCTAssertFalse(context.hasChanges, "saved")
		let saved = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InstallRecord>()).map { ($0.bundleID, $0.certificateID) })
		XCTAssertEqual(saved["com.example.one"], imported)
		XCTAssertEqual(saved["com.example.two"], deleted, "left as it was")
		XCTAssertEqual(saved["com.example.three"], kept)
		XCTAssertEqual(saved.count, 4)
		XCTAssertNil(saved["com.example.four"] ?? nil)
	}

	/// An app signed with an Apple ID, and its copies, have its team ID in
	/// their bundle IDs (#49), and an IPA of the app still installs over
	/// them from Custom Install's sheet (#155).
	@MainActor
	func testFindsAnIPAsInstallsSignedWithAnAppleID() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let app = "com.example.tube", team = "TEAMBBBBBB"
		let original = InstallRecord(bundleID: "\(app).\(team)", name: "Tube", version: "1.0")
		original.note(SignedAppIdentity(bundleID: "\(app).\(team)", originalBundleID: app, applicationIdentifier: "\(team).\(app).\(team)", teamID: team))
		let copy = InstallRecord(bundleID: "\(app).\(team).atelier2", name: "Tube 2", version: "1.0")
		copy.note(SignedAppIdentity(bundleID: "\(app).\(team).atelier2", originalBundleID: app, applicationIdentifier: "\(team).\(app).\(team).atelier2", teamID: team))
		let signed = InstallRecord(bundleID: "\(app).atelier3", name: "Tube 3", version: "1.0")
		signed.note(SignedAppIdentity(bundleID: "\(app).atelier3", originalBundleID: app, applicationIdentifier: "TEAMAAAAAA.*", teamID: "TEAMAAAAAA"))
		for record in [original, copy, signed] { context.insert(record) }
		try context.save()

		XCTAssertEqual(original.target, .original)
		XCTAssertEqual(original.ipaBundleID, app)
		XCTAssertEqual(copy.target, .copy(2))
		XCTAssertEqual(copy.ipaBundleID, app)
		XCTAssertEqual(InstalledApps.records(ofIPA: app, in: context).map(\.bundleID), ["\(app).\(team)", "\(app).\(team).atelier2", "\(app).atelier3"])
		XCTAssertEqual(InstalledApps.records(ofIPA: "\(app).\(team)", in: context).map(\.bundleID), [], "by the IPA's bundle ID, without the team ID")
		XCTAssertEqual(InstalledApps.newCopy(of: app, in: context), .copy(4), "after the Apple ID's copy too")
	}

	/// A source that lists an app under another bundle ID than its IPA's,
	/// as AppTesters lists Wallpapers (#116).
	@MainActor
	func testMapsAnAppListedUnderAnotherBundleID() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let listed = "com.apalonapps.wallpaperspys", own = "com.ispazio.Wallpapers-Central"

		let original = InstallRecord(bundleID: own, name: "Wallpapers", version: "2.8")
		original.note(SignedAppIdentity(bundleID: own, originalBundleID: own, applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"), listedAs: listed)
		let copy = InstallRecord(bundleID: "\(own).atelier3", name: "Wallpapers 3", version: "2.8")
		copy.note(SignedAppIdentity(bundleID: "\(own).atelier3", originalBundleID: own, applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"), listedAs: listed)
		// The source's other app with the IPA's bundle ID.
		let another = InstallRecord(bundleID: "\(own).atelier2", name: "WallpapersCentral", version: "2.0.6")
		another.note(SignedAppIdentity(bundleID: "\(own).atelier2", originalBundleID: own, applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"), listedAs: own)
		context.insert(original)
		context.insert(copy)
		context.insert(another)
		try context.save()

		XCTAssertEqual(original.originalBundleID, listed)
		XCTAssertEqual(original.sourceBundleID, listed)
		XCTAssertEqual(original.target, .original)
		XCTAssertEqual(original.appBundleID, own)
		XCTAssertEqual(copy.sourceBundleID, listed)
		XCTAssertEqual(copy.target, .copy(3), "told by its suffix")
		XCTAssertEqual(copy.appBundleID, own)
		XCTAssertEqual(another.sourceBundleID, own)
		XCTAssertEqual(another.target, .copy(2))

		XCTAssertEqual(InstalledApps.records(ofSourceApp: listed, in: context).map(\.bundleID), [own, "\(own).atelier3"])
		XCTAssertEqual(InstalledApps.records(ofIPA: own, in: context).map(\.bundleID), [own, "\(own).atelier2", "\(own).atelier3"], "whichever source app, as an IPA of it installs over any (#155)")
		XCTAssertEqual(InstalledApps.records(ofIPA: listed, in: context).map(\.bundleID), [], "none of their IPAs has the bundle ID the source lists")
		XCTAssertEqual(InstalledApps.record(listedAs: listed, in: context)?.bundleID, own)
		XCTAssertEqual(InstalledApps.record(listedAs: listed, as: .copy(3), in: context)?.bundleID, "\(own).atelier3")
		XCTAssertNil(InstalledApps.record(listedAs: listed, as: .copy(2), in: context), "the other app's copy")
		XCTAssertEqual(InstalledApps.record(listedAs: own, as: .copy(2), in: context)?.bundleID, "\(own).atelier2")
		XCTAssertEqual(InstalledApps.newCopy(of: original.appBundleID, in: context), .copy(4), "after every copy of the IPA's bundle ID")
		XCTAssertEqual(InstalledApps.newCopy(of: own, in: context, besides: ["\(own).atelier4"]), .copy(5))

		// Installed again from an IPA file, it's no source's app.
		original.note(SignedAppIdentity(bundleID: own, originalBundleID: own, applicationIdentifier: "TEAMAAAAAA.app.one", teamID: "TEAMAAAAAA"))
		XCTAssertNil(original.originalBundleID)
		XCTAssertEqual(original.sourceBundleID, own)
	}

	/// Installs from before Atelier kept the bundle ID their source lists
	/// them under get it from the install history (#116).
	@MainActor
	func testNotesListingsFromTheInstallHistory() throws {
		let container = try Persistence.makeContainer(inMemory: true)
		let context = container.mainContext
		let source = URL(string: "https://repository.apptesters.org/")!
		let listed = "com.apalonapps.wallpaperspys", own = "com.ispazio.Wallpapers-Central"
		func installed(_ bundleID: String, originalBundleID: String? = nil, picked: Bool = false) -> InstallRecord {
			let install = InstallRecord(bundleID: bundleID, name: bundleID, version: "1.0")
			install.originalBundleID = originalBundleID
			install.sourceURL = picked ? nil : source
			context.insert(install)
			return install
		}
		func attempt(_ bundleID: String, _ origin: InstallAttempt.Origin, result: InstallAttempt.Result = .confirmed) -> InstallAttempt {
			InstallAttempt(bundleID: bundleID, name: bundleID, version: "1.0", certificate: nil, route: nil, startedAt: .now, finishedAt: .now, result: result, origin: origin)
		}
		func fromSource(_ appID: String, copy: Int? = nil, url: URL? = nil) -> InstallAttempt.Origin {
			.source(sourceURL: url ?? source, appID: appID, version: "1.0", copy: copy, displayName: nil, certificateID: nil)
		}
		let wallpapers = installed(own)
		let copy = installed("\(own).atelier2", originalBundleID: own)
		let asItself = installed("com.example.app")
		let laterAsItself = installed("com.example.again")
		let fromAnotherSource = installed("com.example.moved")
		let picked = installed("com.example.picked", picked: true)
		try context.save()

		// Newest first.
		let attempts = [
			attempt(own, fromSource("\(listed)#wallpapers")),
			attempt(own, fromSource("\(own)#wallpaperscentral"), result: .failed),
			attempt("\(own).atelier2", fromSource("\(listed)#wallpapers", copy: 2)),
			attempt("com.example.app", fromSource("com.example.app#app")),
			attempt("com.example.again", fromSource("com.example.again#again")),
			attempt("com.example.again", fromSource("com.example.listed#again")),
			attempt("com.example.moved", fromSource("com.example.listed#moved", url: URL(string: "https://other.example/apps.json")!)),
			attempt("com.example.picked", fromSource("com.example.listed#picked")),
		]
		let noted = InstalledApps.noteListings(from: attempts, in: context)

		XCTAssertEqual(Set(noted.map(\.bundleID)), [own, "\(own).atelier2"])
		XCTAssertEqual(wallpapers.sourceBundleID, listed)
		XCTAssertEqual(copy.sourceBundleID, listed)
		XCTAssertEqual(copy.target, .copy(2))
		XCTAssertNil(asItself.originalBundleID)
		XCTAssertNil(laterAsItself.originalBundleID, "its latest install was as itself")
		XCTAssertNil(fromAnotherSource.originalBundleID, "not the install that made the record")
		XCTAssertNil(picked.originalBundleID)
		XCTAssertTrue(InstalledApps.noteListings(from: attempts, in: context).isEmpty, "once")
	}
}
#endif
