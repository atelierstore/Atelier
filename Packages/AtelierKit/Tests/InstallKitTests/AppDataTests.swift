import Foundation
import XCTest
@testable import InstallKit

/// A stand-in for an app's data container through house_arrest: a tree in
/// memory that records the calls and fails where told.
final class FakeContainer: AppDataContainer, @unchecked Sendable {
	enum Node: Equatable {
		case folder
		case file(Data)
		case link(String)
		case other(String)
	}

	var nodes: [String: Node]
	/// Failures, by call as `calls` records it, such as "read /Documents/a".
	var failures: [String: RouteAError] = [:]
	/// Reads that hand out one part, then fail.
	var failingAfterOnePart: [String: RouteAError] = [:]
	/// The size of the parts reads hand out.
	var partSize = 4
	private(set) var calls: [String] = []
	/// The sizes of the parts each write was given, by path.
	private(set) var writtenParts: [String: [Int]] = [:]

	init(_ nodes: [String: Node] = [:]) {
		self.nodes = nodes
		self.nodes["/"] = .folder
	}

	/// An app's container as iOS lays it out, with data in it.
	static func app() -> FakeContainer {
		FakeContainer([
			"/.com.apple.mobile_container_manager.metadata.plist": .file(Data("whose".utf8)),
			"/Documents": .folder,
			"/Documents/notes.txt": .file(Data("Hello, world".utf8)),
			"/Documents/empty": .file(Data()),
			"/Documents/latest": .link("notes.txt"),
			"/Library": .folder,
			"/Library/Application Support": .folder,
			"/Library/Application Support/db.sqlite": .file(Data(repeating: 7, count: 100)),
			"/Library/Caches": .folder,
			"/Library/Caches/images": .file(Data(count: 50)),
			"/Library/Preferences": .folder,
			"/Library/Preferences/com.example.app.plist": .file(Data("prefs".utf8)),
			"/Library/SplashBoard": .folder,
			"/Library/SplashBoard/Snapshots": .folder,
			"/Library/SyncedPreferences": .folder,
			"/Library/SyncedPreferences/com.apple.kvs": .folder,
			"/Library/SyncedPreferences/com.apple.kvs/store": .file(Data("kvs".utf8)),
			"/SystemData": .folder,
			"/tmp": .folder,
			"/tmp/upload": .file(Data(count: 10)),
		])
	}

	/// What a new install's container has before it's first opened.
	static func newInstall() -> FakeContainer {
		FakeContainer([
			"/.com.apple.mobile_container_manager.metadata.plist": .file(Data("new".utf8)),
			"/Documents": .folder,
			"/Library": .folder,
			"/Library/Caches": .folder,
			"/Library/Preferences": .folder,
			"/SystemData": .folder,
			"/tmp": .folder,
		])
	}

	/// The app's data a copy keeps: everything but `AppDataCopy.leftOut`.
	var copied: [String: Node] {
		nodes.filter { path, _ in
			path != "/" && !AppDataCopy.leftOut.contains { path == $0 || path.hasPrefix($0 + "/") }
		}
	}

	static func afc(_ message: String) -> RouteAError {
		RouteAError(step: .appData, code: RouteAError.afcErrorCode, message: message)
	}

	static let brokenConnection = RouteAError(step: .appData, code: 1, message: "Socket(Kind(BrokenPipe))")

	private func record(_ call: String) throws {
		calls.append(call)
		if let failure = failures[call] { throw failure }
	}

	func contents(of path: String) throws -> [String] {
		try record("list \(path)")
		guard nodes[path] == .folder else { throw Self.afc("ObjectNotFound") }
		let prefix = path == "/" ? "/" : path + "/"
		// Out of order, as the copy sorts them.
		return nodes.keys
			.filter { $0.hasPrefix(prefix) && $0 != path && !$0.dropFirst(prefix.count).contains("/") }
			.map { String($0.dropFirst(prefix.count)) }
			.sorted(by: >)
	}

	func item(at path: String) throws -> AppDataItem {
		try record("stat \(path)")
		switch nodes[path] {
		case .folder?: return .folder
		case .file(let data)?: return .file(size: Int64(data.count))
		case .link(let target)?: return .link(target: target)
		case .other(let kind)?: return .other(kind)
		case nil: throw Self.afc("ObjectNotFound")
		}
	}

	func read(_ path: String, chunk: (Data) throws -> Void) throws {
		try record("read \(path)")
		guard case .file(let data)? = nodes[path] else { throw Self.afc("ObjectNotFound") }
		var offset = 0
		while offset < data.count {
			let end = min(offset + partSize, data.count)
			try chunk(Data(data[offset..<end]))
			offset = end
			if let failure = failingAfterOnePart[path] { throw failure }
		}
	}

	func write(_ path: String, from next: () throws -> Data?) throws {
		try record("write \(path)")
		guard nodes[parent(of: path)] == .folder else { throw Self.afc("ObjectNotFound") }
		var data = Data()
		var sizes: [Int] = []
		while let part = try next() {
			sizes.append(part.count)
			data.append(part)
		}
		writtenParts[path] = sizes
		nodes[path] = .file(data)
	}

	func makeFolder(_ path: String) throws {
		try record("mkdir \(path)")
		guard nodes[parent(of: path)] == .folder else { throw Self.afc("ObjectNotFound") }
		switch nodes[path] {
		case nil: nodes[path] = .folder
		case .folder?: break
		default: throw Self.afc("ObjectExists")
		}
	}

	func makeLink(at path: String, to target: String) throws {
		try record("link \(path) -> \(target)")
		guard nodes[path] == nil else { throw Self.afc("ObjectExists") }
		nodes[path] = .link(target)
	}

	func close() {
		calls.append("close")
	}

	private func parent(of path: String) -> String {
		let parent = (path as NSString).deletingLastPathComponent
		return parent.isEmpty ? "/" : parent
	}
}

/// A new empty folder for a test, deleted in `tearDown`.
private func temporaryFolder() -> URL {
	FileManager.default.temporaryDirectory.appending(path: "app-data-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Copying an app's data out of its container and back (#96).
final class AppDataCopyTests: XCTestCase {
	private var folder: URL!

	override func setUp() {
		folder = temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func contents(_ path: String) -> Data? {
		FileManager.default.contents(atPath: folder.appending(path: path).path)
	}

	private func exists(_ path: String) -> Bool {
		(try? FileManager.default.attributesOfItem(atPath: folder.appending(path: path).path)) != nil
	}

	func testCopiesTheDataButNotCachesOrTemporaryFiles() throws {
		let container = FakeContainer.app()
		let result = try AppDataCopy.copyOut(from: container, to: folder)

		XCTAssertEqual(contents("Documents/notes.txt"), Data("Hello, world".utf8))
		XCTAssertEqual(contents("Documents/empty"), Data())
		XCTAssertEqual(contents("Library/Application Support/db.sqlite"), Data(repeating: 7, count: 100))
		XCTAssertEqual(contents("Library/Preferences/com.example.app.plist"), Data("prefs".utf8))
		XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: "Documents/latest").path), "notes.txt")
		for leftOut in ["tmp", "Library/Caches", "Library/SplashBoard", "Library/SyncedPreferences", "SystemData", ".com.apple.mobile_container_manager.metadata.plist"] {
			XCTAssertFalse(exists(leftOut), leftOut)
		}
		XCTAssertEqual(result.files, 4)
		XCTAssertEqual(result.folders, 4)
		XCTAssertEqual(result.links, 1)
		XCTAssertEqual(result.bytes, 12 + 0 + 100 + 5)
		XCTAssertEqual(result.skipped, [])
		// What's left out isn't even looked at.
		XCTAssertFalse(container.calls.contains { $0.contains("Caches") || $0.contains("/tmp") || $0.contains("SystemData") || $0.contains("SyncedPreferences") }, "\(container.calls)")
	}

	func testFoldersAreListedBeforeWhatsInThem() throws {
		var skipped: [String] = []
		let entries = try AppDataCopy.scan(FakeContainer.app(), skipped: &skipped, isCancelled: { false })
		XCTAssertEqual(entries.map(\.path), [
			"/Documents",
			"/Library",
			"/Documents/empty",
			"/Documents/latest",
			"/Documents/notes.txt",
			"/Library/Application Support",
			"/Library/Preferences",
			"/Library/Application Support/db.sqlite",
			"/Library/Preferences/com.example.app.plist",
		])
	}

	func testSaysWhatItFoundAndHowFarItGot() throws {
		let container = FakeContainer(["/Documents": .folder, "/Documents/big": .file(Data(count: 100))])
		container.partSize = 10
		var lines: [String] = []
		_ = try AppDataCopy.copyOut(from: container, to: folder, log: { lines.append($0) })
		XCTAssertTrue(lines.first?.hasPrefix("found 1 file, ") ?? false, "\(lines)")
		XCTAssertEqual(Array(lines.dropFirst()), (1...10).map { "copied \($0 * 10) %" })
	}

	func testReportsTheFractionCopiedEveryHundredth() throws {
		let container = FakeContainer(["/Documents": .folder, "/Documents/big": .file(Data(count: 1000))])
		container.partSize = 5
		var fractions: [Double] = []
		_ = try AppDataCopy.copyOut(from: container, to: folder, progress: { fractions.append($0) })
		XCTAssertEqual(fractions.count, 100)
		XCTAssertEqual(fractions.first, 0.01)
		XCTAssertEqual(fractions.last, 1)

		let new = FakeContainer.newInstall()
		fractions = []
		_ = try AppDataCopy.copyBack(from: folder, to: new, progress: { fractions.append($0) })
		XCTAssertEqual(fractions, [1])
	}

	func testAFileAFCWontReadIsLeftOutAndListed() throws {
		let container = FakeContainer.app()
		container.failures["read /Documents/notes.txt"] = FakeContainer.afc("PermDenied")
		container.failingAfterOnePart["/Library/Application Support/db.sqlite"] = FakeContainer.afc("ReadError")
		let result = try AppDataCopy.copyOut(from: container, to: folder)
		XCTAssertEqual(result.skipped, [
			"/Documents/notes.txt: PermDenied",
			"/Library/Application Support/db.sqlite: ReadError",
		])
		XCTAssertFalse(exists("Documents/notes.txt"))
		XCTAssertFalse(exists("Library/Application Support/db.sqlite"), "no half-copied file")
		XCTAssertEqual(result.files, 2)
		XCTAssertEqual(result.bytes, 5)
	}

	func testWhatAFCWontListIsLeftOutAndListed() throws {
		let container = FakeContainer.app()
		container.nodes["/Documents/socket"] = .other("S_IFSOCK")
		container.failures["list /Library/Preferences"] = FakeContainer.afc("PermDenied")
		container.failures["stat /Documents/empty"] = FakeContainer.afc("PermDenied")
		let result = try AppDataCopy.copyOut(from: container, to: folder)
		XCTAssertEqual(Set(result.skipped), [
			"/Library/Preferences: PermDenied",
			"/Documents/empty: PermDenied",
			"/Documents/socket: S_IFSOCK",
		])
		XCTAssertEqual(contents("Documents/notes.txt"), Data("Hello, world".utf8))
	}

	func testABrokenConnectionStopsTheCopy() {
		let container = FakeContainer.app()
		container.failures["read /Documents/notes.txt"] = FakeContainer.brokenConnection
		XCTAssertThrowsError(try AppDataCopy.copyOut(from: container, to: folder)) { error in
			XCTAssertEqual(error as? RouteAError, FakeContainer.brokenConnection)
		}
	}

	func testACopyThatWouldFillTheIPhoneStopsBeforeCopying() {
		let container = FakeContainer.app()
		XCTAssertThrowsError(try AppDataCopy.copyOut(from: container, to: folder, freeSpace: AppDataCopy.spareSpace)) { error in
			XCTAssertEqual(error as? AppDataCopy.NotEnoughSpace, AppDataCopy.NotEnoughSpace(needed: 117, free: AppDataCopy.spareSpace))
		}
		XCTAssertFalse(container.calls.contains { $0.hasPrefix("read") })
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
	}

	func testCopiesWhenThereIsRoom() throws {
		let result = try AppDataCopy.copyOut(from: FakeContainer.app(), to: folder, freeSpace: AppDataCopy.spareSpace + 117)
		XCTAssertEqual(result.files, 4)
	}

	func testCancellingStopsBetweenFiles() {
		let container = FakeContainer.app()
		XCTAssertThrowsError(try AppDataCopy.copyOut(from: container, to: folder, isCancelled: {
			container.calls.contains { $0.hasPrefix("read") }
		})) { error in
			XCTAssertTrue(error is CancellationError, "\(error)")
		}
		XCTAssertEqual(container.calls.filter { $0.hasPrefix("read") }.count, 1)
	}

	func testPutsTheDataBackIntoANewInstall() throws {
		let old = FakeContainer.app()
		_ = try AppDataCopy.copyOut(from: old, to: folder)
		let new = FakeContainer.newInstall()
		let result = try AppDataCopy.copyBack(from: folder, to: new)

		XCTAssertEqual(new.copied, old.copied)
		// What iOS keeps up itself is the new install's own.
		XCTAssertEqual(new.nodes["/.com.apple.mobile_container_manager.metadata.plist"], .file(Data("new".utf8)))
		XCTAssertEqual(result.files, 4)
		XCTAssertEqual(result.links, 1)
		XCTAssertEqual(result.bytes, 117)
		XCTAssertEqual(result.skipped, [])
	}

	func testPutsBackFoldersThenFilesThenLinks() throws {
		_ = try AppDataCopy.copyOut(from: FakeContainer.app(), to: folder)
		let new = FakeContainer.newInstall()
		_ = try AppDataCopy.copyBack(from: folder, to: new)
		let kinds = new.calls.map { String($0.split(separator: " ")[0]) }
		XCTAssertEqual(kinds, ["mkdir", "mkdir", "mkdir", "mkdir", "write", "write", "write", "write", "link"])
		XCTAssertLessThan(new.calls.firstIndex(of: "mkdir /Library")!, new.calls.firstIndex(of: "mkdir /Library/Application Support")!)
	}

	func testReplacesWhatTheNewInstallHas() throws {
		_ = try AppDataCopy.copyOut(from: FakeContainer.app(), to: folder)
		let new = FakeContainer.newInstall()
		new.nodes["/Library/Preferences/com.example.app.plist"] = .file(Data("first launch".utf8))
		_ = try AppDataCopy.copyBack(from: folder, to: new)
		XCTAssertEqual(new.nodes["/Library/Preferences/com.example.app.plist"], .file(Data("prefs".utf8)))
	}

	func testWritesLargeFilesInParts() throws {
		let size = 5 << 19
		try FileManager.default.createDirectory(at: folder.appending(path: "Documents"), withIntermediateDirectories: true)
		try Data(count: size).write(to: folder.appending(path: "Documents/video.mov"))
		let new = FakeContainer.newInstall()
		_ = try AppDataCopy.copyBack(from: folder, to: new)
		XCTAssertEqual(new.writtenParts["/Documents/video.mov"], [1 << 20, 1 << 20, 1 << 19])
	}

	func testWhatTheNewInstallRefusesIsListed() throws {
		_ = try AppDataCopy.copyOut(from: FakeContainer.app(), to: folder)
		let new = FakeContainer.newInstall()
		new.failures["write /Documents/notes.txt"] = FakeContainer.afc("PermDenied")
		new.failures["mkdir /Library/Application Support"] = FakeContainer.afc("PermDenied")
		let result = try AppDataCopy.copyBack(from: folder, to: new)
		XCTAssertEqual(result.skipped, [
			"/Library/Application Support: PermDenied",
			"/Documents/notes.txt: PermDenied",
			"/Library/Application Support/db.sqlite: ObjectNotFound",
		])
		XCTAssertEqual(new.nodes["/Library/Preferences/com.example.app.plist"], .file(Data("prefs".utf8)))
	}

	func testABrokenConnectionStopsPuttingBack() throws {
		_ = try AppDataCopy.copyOut(from: FakeContainer.app(), to: folder)
		let new = FakeContainer.newInstall()
		new.failures["write /Documents/empty"] = FakeContainer.brokenConnection
		XCTAssertThrowsError(try AppDataCopy.copyBack(from: folder, to: new)) { error in
			XCTAssertEqual(error as? RouteAError, FakeContainer.brokenConnection)
		}
	}

	func testCachesInTheFolderStayOut() throws {
		for path in ["tmp/upload", "Library/Caches/images", "Documents/notes.txt"] {
			let url = folder.appending(path: path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data("x".utf8).write(to: url)
		}
		let new = FakeContainer.newInstall()
		_ = try AppDataCopy.copyBack(from: folder, to: new)
		XCTAssertEqual(new.calls.filter { $0.hasPrefix("write") }, ["write /Documents/notes.txt"])
	}

	func testSummary() {
		var result = AppDataCopyResult()
		result.files = 1
		XCTAssertTrue(result.summary.hasPrefix("1 file, "), result.summary)
		result.files = 412
		XCTAssertTrue(result.summary.hasPrefix("412 files, "), result.summary)
	}
}

/// The copies Atelier keeps until they're put back (#96).
final class AppDataStoreTests: XCTestCase {
	private var root: URL!
	private var store: AppDataStore!

	override func setUp() {
		root = temporaryFolder()
		store = AppDataStore(root: root)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
	}

	private let info = KeptAppData(copiedAt: Date(timeIntervalSince1970: 1_800_000_000), files: 1, bytes: 3)

	/// A copy holding one file.
	private func newCopy(_ text: String) throws -> URL {
		let folder = try store.newFolder()
		try Data(text.utf8).write(to: folder.appending(path: "notes.txt"))
		return folder
	}

	private func names() throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
	}

	func testKeepsACopyPerApp() throws {
		XCTAssertNil(store.kept("com.example.app"))
		try store.keep(newCopy("old"), for: "com.example.app", info: info)
		XCTAssertEqual(store.kept("com.example.app"), info)
		XCTAssertNil(store.kept("com.example.other"))
		XCTAssertEqual(FileManager.default.contents(atPath: store.containerFolder(for: "com.example.app").appending(path: "notes.txt").path), Data("old".utf8))
		XCTAssertEqual(try names(), ["com.example.app"])
	}

	func testANewCopyReplacesTheOldOne() throws {
		try store.keep(newCopy("old"), for: "com.example.app", info: info)
		var newer = info
		newer.files = 2
		try store.keep(newCopy("new"), for: "com.example.app", info: newer)
		XCTAssertEqual(store.kept("com.example.app"), newer)
		XCTAssertEqual(FileManager.default.contents(atPath: store.containerFolder(for: "com.example.app").appending(path: "notes.txt").path), Data("new".utf8))
		XCTAssertEqual(try names(), ["com.example.app"])
	}

	func testRemovesAndDiscards() throws {
		try store.keep(newCopy("old"), for: "com.example.app", info: info)
		store.remove("com.example.app")
		XCTAssertNil(store.kept("com.example.app"))
		store.discard(try newCopy("unused"))
		XCTAssertEqual(try names(), [])
	}

	func testRemovesWhatAStoppedCopyLeft() throws {
		try store.keep(newCopy("old"), for: "com.example.app", info: info)
		_ = try newCopy("stopped")
		try FileManager.default.createDirectory(at: root.appending(path: ".keeping-1234"), withIntermediateDirectories: true)
		store.removeLeftovers()
		XCTAssertEqual(try names(), ["com.example.app"])
	}

	func testBundleIDsStayInTheStore() {
		for bundleID in ["../../Documents", "", ".hidden", "com.example/../other"] {
			let app = store.containerFolder(for: bundleID).deletingLastPathComponent()
			XCTAssertEqual(app.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path, bundleID)
			XCTAssertFalse(app.lastPathComponent.hasPrefix("."), bundleID)
		}
	}

	func testListsTheAppsWithAKeptCopy() throws {
		XCTAssertEqual(store.keptBundleIDs, [])
		var mine = info
		mine.bundleID = "com.example.app"
		try store.keep(newCopy("old"), for: "com.example.app", info: mine)
		// A copy the test build kept, without its bundle ID.
		try store.keep(newCopy("old"), for: "com.example.other", info: info)
		_ = try newCopy("stopped")
		XCTAssertEqual(store.keptBundleIDs, ["com.example.app", "com.example.other"])
	}

	func testACopyWithoutItsRecordIsntKept() throws {
		try store.keep(newCopy("old"), for: "com.example.app", info: info)
		try FileManager.default.removeItem(at: store.containerFolder(for: "com.example.app").deletingLastPathComponent().appending(path: "copy.json"))
		XCTAssertNil(store.kept("com.example.app"))
	}

	func testACopyMovesToTheBundleIDTheAppInstallsAsNow() throws {
		var mine = info
		mine.bundleID = "com.example.app"
		try store.keep(newCopy("old"), for: "com.example.app", info: mine)
		// One left from before, which the move replaces.
		try store.keep(newCopy("older"), for: "com.example.app.A1B2C3D4E5", info: info)
		try store.move("com.example.app", to: "com.example.app.A1B2C3D4E5")
		XCTAssertNil(store.kept("com.example.app"))
		var moved = mine
		moved.bundleID = "com.example.app.A1B2C3D4E5"
		XCTAssertEqual(store.kept("com.example.app.A1B2C3D4E5"), moved)
		XCTAssertEqual(FileManager.default.contents(atPath: store.containerFolder(for: "com.example.app.A1B2C3D4E5").appending(path: "notes.txt").path), Data("old".utf8))
		XCTAssertEqual(try names(), ["com.example.app.A1B2C3D4E5"])
		XCTAssertEqual(store.keptBundleIDs, ["com.example.app.A1B2C3D4E5"])
	}

	func testMarksADisabledAppsCopy() throws {
		var mine = info
		mine.bundleID = "com.example.app"
		try store.keep(newCopy("old"), for: "com.example.app", info: mine)
		try store.keep(newCopy("old"), for: "com.example.other", info: info)
		let disabled = Date(timeIntervalSince1970: 1_800_100_000)
		try store.markDisabled("com.example.app", at: disabled)
		XCTAssertEqual(store.kept("com.example.app")?.disabledAt, disabled)
		XCTAssertEqual(store.allKept["com.example.app"]?.disabledAt, disabled)
		XCTAssertNil(store.allKept["com.example.other"]?.disabledAt)
		// Its data stays where it was.
		XCTAssertEqual(FileManager.default.contents(atPath: store.containerFolder(for: "com.example.app").appending(path: "notes.txt").path), Data("old".utf8))
		// A move keeps the mark, and enabling clears it.
		try store.move("com.example.app", to: "com.example.app.A1B2C3D4E5")
		XCTAssertEqual(store.kept("com.example.app.A1B2C3D4E5")?.disabledAt, disabled)
		try store.markDisabled("com.example.app.A1B2C3D4E5", at: nil)
		XCTAssertNil(store.kept("com.example.app.A1B2C3D4E5")?.disabledAt)
		XCTAssertThrowsError(try store.markDisabled("com.example.none", at: disabled))
	}

	func testReadsACopyKeptBeforeDisableExisted() throws {
		let folder = root.appending(path: "com.example.app")
		try FileManager.default.createDirectory(at: folder.appending(path: "Container"), withIntermediateDirectories: true)
		try Data(#"{"copiedAt":"2027-01-15T08:00:00Z","files":1,"bytes":3,"bundleID":"com.example.app"}"#.utf8).write(to: folder.appending(path: "copy.json"))
		XCTAssertEqual(store.kept("com.example.app")?.files, 1)
		XCTAssertNil(store.kept("com.example.app")?.disabledAt)
	}

	func testMovingNothingKeptDoesNothing() throws {
		try store.keep(newCopy("old"), for: "com.example.app.A1B2C3D4E5", info: info)
		try store.move("com.example.app", to: "com.example.app.A1B2C3D4E5")
		try store.move("com.example.app.A1B2C3D4E5", to: "com.example.app.A1B2C3D4E5")
		XCTAssertEqual(store.kept("com.example.app.A1B2C3D4E5"), info)
		XCTAssertEqual(try names(), ["com.example.app.A1B2C3D4E5"])
	}
}

/// Copying an app's data aside before it's deleted, and back after (#96).
@MainActor
final class AppDataKeeperTests: XCTestCase {
	private var root: URL!
	private var store: AppDataStore!
	private var installed: Bool? = true
	/// What each copy out does, in order; a copy of one file after these.
	private var copiesOut: [Result<AppDataCopyResult, any Error>] = []
	private var copiesBack: [Result<AppDataCopyResult, any Error>] = []
	private var calls: [String] = []
	private var lines: [String] = []
	private var phases: [InstallPhase] = []

	override func setUp() async throws {
		root = temporaryFolder()
		store = AppDataStore(root: root)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: root)
	}

	private static var oneFile: AppDataCopyResult {
		var result = AppDataCopyResult()
		result.files = 1
		result.bytes = 4
		return result
	}

	private static let refused = AppDataRefused(message: "UnknownErrorType(\"InstallationLookupFailed\") (idevice code 15)")

	private func keeper() -> AppDataKeeper {
		let keeper = AppDataKeeper(.init(
			store: store,
			isInstalled: { _ in self.installed },
			copyOut: { bundleID, folder, log, progress in
				self.calls.append("copy out \(bundleID)")
				log("found 1 file")
				try Data("data".utf8).write(to: folder.appending(path: "notes.txt"))
				progress(0.5)
				progress(1)
				return try (self.copiesOut.isEmpty ? .success(Self.oneFile) : self.copiesOut.removeFirst()).get()
			},
			copyBack: { bundleID, folder, _, progress in
				self.calls.append("copy back \(bundleID) from \(folder.lastPathComponent)")
				XCTAssertEqual(FileManager.default.contents(atPath: folder.appending(path: "notes.txt").path), Data("data".utf8))
				progress(1)
				return try (self.copiesBack.isEmpty ? .success(Self.oneFile) : self.copiesBack.removeFirst()).get()
			}
		))
		keeper.restoreWait = .milliseconds(1)
		return keeper
	}

	private func record(_ event: InstallEvent) {
		switch event {
		case .log(let line): lines.append(line)
		case .phase(let phase): phases.append(phase)
		}
	}

	private func save() async throws {
		try await keeper().save("com.example.app", name: "Example", events: record)
	}

	private func restore() async {
		await keeper().restore("com.example.app", name: "Example", events: record)
	}

	private func putBack() async throws {
		try await keeper().putBack("com.example.app", name: "Example", events: record)
	}

	/// Keeps a copy, as a save before this one did.
	private func keepCopy(files: Int = 1) throws {
		let folder = try store.newFolder()
		try Data("data".utf8).write(to: folder.appending(path: "notes.txt"))
		try store.keep(folder, for: "com.example.app", info: KeptAppData(copiedAt: Date(timeIntervalSince1970: 1_800_000_000), files: files, bytes: 4))
	}

	private func names() throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
	}

	// MARK: Saving

	func testCopiesTheDataAside() async throws {
		try await save()
		XCTAssertEqual(calls, ["copy out com.example.app"])
		XCTAssertEqual(store.kept("com.example.app")?.files, 1)
		XCTAssertEqual(store.kept("com.example.app")?.bundleID, "com.example.app")
		XCTAssertEqual(try names(), ["com.example.app"])
		XCTAssertEqual(phases, [.copyingData(fraction: nil), .copyingData(fraction: 0.5), .copyingData(fraction: 1)])
		XCTAssertEqual(Array(lines.prefix(2)), ["data: copying Example's data through house_arrest", "data: found 1 file"])
		XCTAssertTrue(lines.last?.hasPrefix("data: copied 1 file, ") ?? false, "\(lines)")
	}

	func testANewCopyReplacesOneThatWasntPutBack() async throws {
		try keepCopy(files: 9)
		try await save()
		XCTAssertEqual(store.kept("com.example.app")?.files, 1)
		XCTAssertTrue(lines.contains { $0.hasPrefix("data: this replaces the copy kept from ") && $0.hasSuffix(", which wasn't put back") }, "\(lines)")
	}

	func testAnAppIOSWontOpenIsntDeleted() async throws {
		copiesOut = [.failure(Self.refused)]
		do {
			try await save()
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .dataNotCopied(.refused("UnknownErrorType(\"InstallationLookupFailed\") (idevice code 15)")))
		}
		XCTAssertEqual(calls.count, 1, "not tried again")
		XCTAssertNil(store.kept("com.example.app"))
		XCTAssertEqual(try names(), [])
		XCTAssertEqual(lines.last, "data: iOS doesn't let Atelier read Example's data: UnknownErrorType(\"InstallationLookupFailed\") (idevice code 15)")
	}

	func testARefusalLeavesAKeptCopyAsItWas() async throws {
		try keepCopy(files: 9)
		copiesOut = [.failure(Self.refused)]
		do {
			try await save()
			XCTFail("expected a failure")
		} catch {}
		XCTAssertEqual(store.kept("com.example.app")?.files, 9)
	}

	func testAnAppThatIsntInstalledHasNoDataToCopy() async throws {
		installed = false
		try await save()
		XCTAssertEqual(calls, [])
		XCTAssertEqual(phases, [])
		XCTAssertEqual(lines, ["data: Example isn't on this \(ThisDevice.name), so there's no data to copy"])
	}

	func testAKeptCopyGoesIntoTheNewInstallOfAnAppThatIsntInstalled() async throws {
		try keepCopy(files: 9)
		installed = false
		try await save()
		XCTAssertEqual(store.kept("com.example.app")?.files, 9)
		XCTAssertTrue(lines.last?.hasPrefix("data: the copy kept from ") ?? false, "\(lines)")
		XCTAssertTrue(lines.last?.hasSuffix(" goes into the new install instead") ?? false, "\(lines)")
	}

	func testCopiesWhenItCantTellWhetherTheAppIsInstalled() async throws {
		installed = nil
		try await save()
		XCTAssertEqual(calls, ["copy out com.example.app"])
	}

	func testACopyThatBreaksOffIsTriedOnceMore() async throws {
		copiesOut = [.failure(InstallFailure.connectionLost("Socket"))]
		try await save()
		XCTAssertEqual(calls, ["copy out com.example.app", "copy out com.example.app"])
		XCTAssertNotNil(store.kept("com.example.app"))
		XCTAssertEqual(try names(), ["com.example.app"])
		XCTAssertTrue(lines.contains("data: the copy broke off (Socket); trying again"), "\(lines)")
		XCTAssertTrue(lines.contains("data: copying Example's data through house_arrest, attempt 2"), "\(lines)")
	}

	func testACopyThatBreaksTwiceKeepsTheApp() async throws {
		copiesOut = [.failure(InstallFailure.connectionLost("Socket")), .failure(InstallFailure.connectionLost("Socket"))]
		do {
			try await save()
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .dataNotCopied(.brokeOff("Socket")))
		}
		XCTAssertEqual(calls.count, 2)
		XCTAssertEqual(try names(), [])
	}

	func testACopyThatWouldFillTheIPhoneKeepsTheApp() async throws {
		let full = AppDataCopy.NotEnoughSpace(needed: 5_000_000_000, free: 1_000_000_000)
		copiesOut = [.failure(full)]
		do {
			try await save()
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .dataNotCopied(.notEnoughSpace(needed: full.needed, free: full.free)))
		}
		XCTAssertEqual(calls.count, 1)
		XCTAssertEqual(try names(), [])
	}

	func testACancelledCopyKeepsTheApp() async throws {
		copiesOut = [.failure(CancellationError())]
		do {
			try await save()
			XCTFail("expected a cancel")
		} catch {
			XCTAssertTrue(error is CancellationError, "\(error)")
		}
		XCTAssertEqual(calls.count, 1)
		XCTAssertEqual(try names(), [])
	}

	func testRemovesWhatAStoppedCopyLeft() async throws {
		_ = try store.newFolder()
		installed = false
		try await save()
		XCTAssertEqual(try names(), [])
	}

	func testListsWhatCouldntBeCopied() async throws {
		var result = Self.oneFile
		result.skipped = (1...12).map { "/Documents/\($0): PermDenied" }
		copiesOut = [.success(result)]
		try await save()
		XCTAssertEqual(lines.filter { $0.hasPrefix("data: couldn't copy ") }.count, 10)
		XCTAssertEqual(lines.last, "data: and 2 more")
	}

	// MARK: Putting back

	func testPutsTheDataBackAndDeletesTheCopy() async throws {
		try keepCopy()
		await restore()
		XCTAssertEqual(calls, ["copy back com.example.app from Container"])
		XCTAssertNil(store.kept("com.example.app"))
		XCTAssertEqual(try names(), [])
		XCTAssertTrue(lines.first?.hasPrefix("data: putting back Example's data copied ") ?? false, "\(lines)")
		XCTAssertTrue(lines.last?.hasPrefix("data: put back 1 file, ") ?? false, "\(lines)")
		XCTAssertEqual(phases, [.restoringData(fraction: nil), .restoringData(fraction: 1)])
	}

	func testNothingKeptIsNothingToPutBack() async {
		await restore()
		XCTAssertEqual(calls, [])
		XCTAssertEqual(lines, [])
	}

	func testWhatIOSWontTakeIsOnlyListed() async throws {
		try keepCopy()
		var result = Self.oneFile
		result.skipped = ["/Documents/notes.txt: PermDenied"]
		copiesBack = [.success(result)]
		await restore()
		XCTAssertEqual(calls.count, 1, "trying again wouldn't change it")
		XCTAssertNil(store.kept("com.example.app"))
		XCTAssertEqual(lines.last, "data: couldn't put back /Documents/notes.txt: PermDenied")
	}

	func testWaitsForIOSToOpenTheNewInstall() async throws {
		try keepCopy()
		copiesBack = [.failure(Self.refused)]
		await restore()
		XCTAssertEqual(calls.count, 2)
		XCTAssertNil(store.kept("com.example.app"))
	}

	func testKeepsTheCopyWhenIOSNeverOpensTheNewInstall() async throws {
		try keepCopy()
		copiesBack = Array(repeating: .failure(Self.refused), count: 3)
		await restore()
		XCTAssertEqual(calls.count, 3)
		XCTAssertNotNil(store.kept("com.example.app"))
		XCTAssertEqual(Array(lines.suffix(2)), [
			"data: couldn't put Example's data back: iOS doesn't open the new install's data (UnknownErrorType(\"InstallationLookupFailed\") (idevice code 15))",
			"data: the copy is kept, for Put Back in the Library",
		])
	}

	func testABrokenConnectionIsTriedAgain() async throws {
		try keepCopy()
		copiesBack = [.failure(InstallFailure.connectionLost("Socket"))]
		await restore()
		XCTAssertEqual(calls.count, 2)
		XCTAssertNil(store.kept("com.example.app"))
		XCTAssertTrue(lines.contains("data: the copy broke off (Socket); trying again"), "\(lines)")
	}

	func testAConnectionThatKeepsBreakingKeepsTheCopy() async throws {
		try keepCopy()
		copiesBack = Array(repeating: .failure(InstallFailure.connectionLost("Socket")), count: 3)
		await restore()
		XCTAssertEqual(calls.count, 3)
		XCTAssertNotNil(store.kept("com.example.app"))
		XCTAssertEqual(Array(lines.suffix(2)), [
			"data: couldn't put Example's data back: the copy broke off (Socket)",
			"data: the copy is kept, for Put Back in the Library",
		])
	}

	// MARK: Put Back

	func testPutBackPutsTheDataInAndDeletesTheCopy() async throws {
		try keepCopy()
		try await putBack()
		XCTAssertEqual(calls, ["copy back com.example.app from Container"])
		XCTAssertNil(store.kept("com.example.app"))
	}

	func testPutBackSaysWhyItCouldnt() async throws {
		try keepCopy()
		copiesBack = Array(repeating: .failure(InstallFailure.connectionLost("Socket")), count: 3)
		do {
			try await putBack()
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .connectionLost("Socket"))
		}
		XCTAssertNotNil(store.kept("com.example.app"))
	}

	func testPutBackWithNothingKeptDoesNothing() async throws {
		try await putBack()
		XCTAssertEqual(calls, [])
		XCTAssertEqual(phases, [])
	}

	func testACancelledPutBackKeepsTheCopy() async throws {
		try keepCopy()
		copiesBack = [.failure(CancellationError())]
		do {
			try await putBack()
			XCTFail("expected a cancel")
		} catch {
			XCTAssertTrue(error is CancellationError, "\(error)")
		}
		XCTAssertEqual(calls.count, 1)
		XCTAssertNotNil(store.kept("com.example.app"))
	}
}

/// Records what `ReplacingInstaller` asks of the app's data.
@MainActor
final class FakeKeeper: AppDataKeeping {
	var saveFailure: (any Error)?
	private let record: @MainActor (String) -> Void

	init(_ record: @escaping @MainActor (String) -> Void) {
		self.record = record
	}

	func save(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async throws {
		record("save \(bundleID)")
		events(.phase(.copyingData(fraction: 1)))
		if let saveFailure { throw saveFailure }
	}

	func restore(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		record("restore \(bundleID)")
	}

	func move(_ bundleID: String, to newBundleID: String, events: @escaping @MainActor (InstallEvent) -> Void) {
		record("move \(bundleID) to \(newBundleID)")
	}
}

/// Keeping the app's data across `ReplacingInstaller`'s delete (#96).
@MainActor
final class ReplacingInstallerDataTests: XCTestCase {
	private let package = InstallPackage(url: URL(fileURLWithPath: "/tmp/radiance.ipa"), info: IPAInfo(bundleID: "com.example.radiance", version: "3.0.1", name: "Radiance"))
	private var order: [String] = []

	/// Records each step, and whether the app was installed by then.
	private func installer(_ base: MockInstaller, deleting: String? = nil, saveFailure: InstallFailure? = nil) -> ReplacingInstaller {
		let keeper = FakeKeeper { self.order.append($0 + (base.installed.isEmpty ? "" : " after the install")) }
		keeper.saveFailure = saveFailure
		return ReplacingInstaller(base, deleting: deleting, keeping: keeper) { bundleID in
			self.order.append("delete \(bundleID)" + (base.installed.isEmpty ? "" : " after the install"))
			return nil
		}
	}

	func testCopiesTheDataBeforeTheDeleteAndPutsItBackAfterTheInstall() async throws {
		let base = MockInstaller(.pairing)
		let result = try await installer(base).install(package) { _ in }
		XCTAssertEqual(result, .confirmed(version: "3.0.1"))
		XCTAssertEqual(order, ["save com.example.radiance", "delete com.example.radiance", "restore com.example.radiance after the install"])
	}

	func testAnAppThatInstallsAsAnotherBundleIDNowTakesItsDataAlong() async throws {
		// Installed with an Apple ID before, with a certificate now (#49).
		let base = MockInstaller(.pairing)
		let result = try await installer(base, deleting: "com.example.radiance.A1B2C3D4E5").install(package) { _ in }
		XCTAssertEqual(result, .confirmed(version: "3.0.1"))
		XCTAssertEqual(order, [
			"save com.example.radiance.A1B2C3D4E5",
			"delete com.example.radiance.A1B2C3D4E5",
			"move com.example.radiance.A1B2C3D4E5 to com.example.radiance",
			"restore com.example.radiance after the install",
		])
	}

	func testACopyThatFailsDeletesNothing() async {
		let base = MockInstaller(.pairing)
		do {
			_ = try await installer(base, saveFailure: .dataNotCopied(.brokeOff("The connection to iOS broke off: Socket."))).install(package) { _ in }
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .dataNotCopied(.brokeOff("The connection to iOS broke off: Socket.")))
		}
		XCTAssertEqual(order, ["save com.example.radiance"])
		XCTAssertEqual(base.installed, [])
	}

	func testSaysItsConnectingWhileTheOldAppIsDeleted() async throws {
		let base = MockInstaller(.pairing)
		var phases: [InstallPhase] = []
		_ = try await installer(base).install(package) { event in
			if case .phase(let phase) = event { phases.append(phase) }
		}
		XCTAssertEqual(phases, [.copyingData(fraction: 1), .connecting])
	}

	func testWithoutKeepingTheDataItOnlyDeletes() async throws {
		let base = MockInstaller(.pairing)
		var phases: [InstallPhase] = []
		let installer = ReplacingInstaller(base) { bundleID in
			self.order.append("delete \(bundleID)")
			return nil
		}
		_ = try await installer.install(package) { event in
			if case .phase(let phase) = event { phases.append(phase) }
		}
		XCTAssertEqual(order, ["delete com.example.radiance"])
		XCTAssertEqual(phases, [])
	}

	func testAFailedInstallPutsNothingBack() async {
		let base = MockInstaller(.pairing)
		base.failure = .rejected("ApplicationVerificationFailed")
		do {
			_ = try await installer(base).install(package) { _ in }
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .rejected("ApplicationVerificationFailed"))
		}
		XCTAssertEqual(order, ["save com.example.radiance", "delete com.example.radiance"])
	}
}

/// Enable: installing a disabled app and putting its data back (#49).
@MainActor
final class RestoringInstallerTests: XCTestCase {
	private let package = InstallPackage(url: URL(fileURLWithPath: "/tmp/radiance.ipa"), info: IPAInfo(bundleID: "com.example.radiance.A1B2C3D4E5", version: "3.0.1", name: "Radiance"))
	private var order: [String] = []

	private func installer(_ base: MockInstaller, from: String? = nil) -> RestoringInstaller {
		let keeper = FakeKeeper { self.order.append($0 + (base.installed.isEmpty ? "" : " after the install")) }
		return RestoringInstaller(base, keeping: keeper, from: from)
	}

	func testPutsTheDataBackAfterTheInstall() async throws {
		let base = MockInstaller(.pairing)
		let result = try await installer(base, from: "com.example.radiance.A1B2C3D4E5").install(package) { _ in }
		XCTAssertEqual(result, .confirmed(version: "3.0.1"))
		XCTAssertEqual(base.installed, ["com.example.radiance.A1B2C3D4E5"])
		XCTAssertEqual(order, ["restore com.example.radiance.A1B2C3D4E5 after the install"])
	}

	func testTheDataGoesIntoTheBundleIDTheAppInstallsAsNow() async throws {
		// Disabled with one Apple ID, enabled with another's team.
		let base = MockInstaller(.pairing)
		_ = try await installer(base, from: "com.example.radiance.F6G7H8I9J0").install(package) { _ in }
		XCTAssertEqual(order, [
			"move com.example.radiance.F6G7H8I9J0 to com.example.radiance.A1B2C3D4E5 after the install",
			"restore com.example.radiance.A1B2C3D4E5 after the install",
		])
	}

	func testAFailedInstallLeavesTheDataWhereItWas() async {
		let base = MockInstaller(.pairing)
		base.failure = .rejected("ApplicationVerificationFailed")
		do {
			_ = try await installer(base, from: "com.example.radiance.F6G7H8I9J0").install(package) { _ in }
			XCTFail("expected a failure")
		} catch {
			XCTAssertEqual(error as? InstallFailure, .rejected("ApplicationVerificationFailed"))
		}
		XCTAssertEqual(order, [])
	}
}
