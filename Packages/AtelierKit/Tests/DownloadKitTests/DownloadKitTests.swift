import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DownloadKit
import SourceKit

/// A stored (uncompressed) ZIP with the given entries, for tests.
enum TestZip {
	static func make(_ entries: [(path: String, contents: Data)]) -> Data {
		var body = Data(), central = Data()
		for entry in entries {
			let name = Data(entry.path.utf8)
			let offset = UInt32(body.count)
			let crc = crc32(entry.contents)
			body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
			body += le32(crc) + le32(UInt32(entry.contents.count)) + le32(UInt32(entry.contents.count))
			body += le16(UInt16(name.count)) + le16(0) + name + entry.contents
			central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
			central += le32(crc) + le32(UInt32(entry.contents.count)) + le32(UInt32(entry.contents.count))
			central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
		}
		let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
			+ le32(UInt32(central.count)) + le32(UInt32(body.count)) + le16(0)
		return body + central + end
	}

	static let ipa = make([
		("Payload/", Data()),
		("Payload/Test.app/", Data()),
		("Payload/Test.app/Info.plist", Data("<plist/>".utf8)),
		("Payload/Test.app/Test", Data(repeating: 7, count: 300)),
	])

	/// An IPA whose Info.plist names the app, for downloads from a pasted URL.
	static let namedIPA = make([
		("Payload/", Data()),
		("Payload/Named.app/", Data()),
		("Payload/Named.app/Info.plist", Data("""
		<?xml version="1.0" encoding="UTF-8"?>
		<plist version="1.0"><dict>
		<key>CFBundleIdentifier</key><string>com.example.named</string>
		<key>CFBundleDisplayName</key><string>Named App</string>
		<key>CFBundleShortVersionString</key><string>2.3</string>
		</dict></plist>
		""".utf8)),
		("Payload/Named.app/Named", Data(repeating: 7, count: 300)),
	])

	private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
	private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

	private static func crc32(_ data: Data) -> UInt32 {
		var crc: UInt32 = 0xFFFF_FFFF
		for byte in data {
			crc ^= UInt32(byte)
			for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
		}
		return ~crc
	}
}

final class DownloadVerifierTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appending(path: "DownloadVerifierTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func file(_ data: Data) throws -> URL {
		let url = folder.appending(path: UUID().uuidString)
		try data.write(to: url)
		return url
	}

	private func problem(_ data: Data, size: Int64? = nil, sha256: String? = nil) throws -> DownloadVerifier.Problem? {
		do {
			try DownloadVerifier.verify(fileAt: try file(data), expectedSize: size, sha256: sha256)
			return nil
		} catch let problem as DownloadVerifier.Problem {
			return problem
		}
	}

	func testAcceptsAnIPA() throws {
		XCTAssertNil(try problem(TestZip.ipa))
		XCTAssertNil(try problem(TestZip.ipa, size: Int64(TestZip.ipa.count)))
	}

	func testRejectsAWebPage() throws {
		XCTAssertEqual(try problem(Data("<!DOCTYPE html><html><body>Not found</body></html>".utf8)), .webPage)
		XCTAssertEqual(try problem(Data("\u{FEFF}\n  <html>".utf8)), .webPage)
	}

	func testRejectsOtherFiles() throws {
		XCTAssertEqual(try problem(Data("{\"error\": \"rate limited\"}".utf8)), .notAnIPA)
		XCTAssertEqual(try problem(Data()), .empty)
	}

	func testRejectsAZipThatIsNotAnApp() throws {
		let zip = TestZip.make([("README.txt", Data("hi".utf8)), ("Payload/notes.txt", Data("x".utf8))])
		XCTAssertEqual(try problem(zip), .notAnIPA)
	}

	func testRejectsATruncatedZip() throws {
		XCTAssertEqual(try problem(TestZip.ipa.prefix(200)), .notAnIPA)
	}

	func testRejectsTheWrongSize() throws {
		let actual = Int64(TestZip.ipa.count)
		XCTAssertEqual(try problem(TestZip.ipa, size: actual + 1), .sizeMismatch(expected: actual + 1, actual: actual))
	}

	func testAppEntries() {
		XCTAssertTrue(DownloadVerifier.isAppEntry("Payload/A.app/"))
		XCTAssertTrue(DownloadVerifier.isAppEntry("Payload/My App.app/Info.plist"))
		XCTAssertFalse(DownloadVerifier.isAppEntry("Payload/.app/"))
		XCTAssertFalse(DownloadVerifier.isAppEntry("Payload/A/Info.plist"))
		XCTAssertFalse(DownloadVerifier.isAppEntry("Other/A.app/Info.plist"))
	}

	func testMalformedHashesAreIgnored() throws {
		XCTAssertNil(DownloadVerifier.normalizedHash("abc"))
		XCTAssertNil(DownloadVerifier.normalizedHash(String(repeating: "g", count: 64)))
		XCTAssertEqual(DownloadVerifier.normalizedHash(String(repeating: "AB", count: 32)), String(repeating: "ab", count: 32))
		XCTAssertNil(try problem(TestZip.ipa, sha256: "not a hash"))
	}

	#if canImport(CryptoKit)
	func testChecksum() throws {
		let url = try file(TestZip.ipa)
		let hash = try XCTUnwrap(DownloadVerifier.sha256Hex(of: url))
		XCTAssertNoThrow(try DownloadVerifier.verify(fileAt: url, expectedSize: nil, sha256: hash.uppercased()))
		let wrong = String(hash.reversed())
		XCTAssertThrowsError(try DownloadVerifier.verify(fileAt: url, expectedSize: nil, sha256: wrong)) {
			XCTAssertEqual($0 as? DownloadVerifier.Problem, .checksumMismatch)
		}
	}
	#endif

	/// What the user is told: what an HTTP code means, not the code.
	func testErrorStatusesSayWhatTheyMean() {
		XCTAssertEqual(DownloadVerifier.Problem.httpStatus(404).description, "The app's file isn't there any more. The source may be out of date.")
		XCTAssertEqual(DownloadVerifier.Problem.httpStatus(401).description, "The server didn't allow the download. The link may have expired or need a login.")
		XCTAssertEqual(DownloadVerifier.Problem.httpStatus(503).description, "The server had a problem. Try again later.")
		XCTAssertEqual(DownloadVerifier.Problem.httpStatus(418).description, "The server refused the download (error 418).")
	}
}

final class DownloadStoreTests: XCTestCase {
	private var store: DownloadStore!

	override func setUp() {
		store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "DownloadStoreTests-\(UUID().uuidString)"))
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: store.root)
	}

	func testSavesAndLoadsDownloads() throws {
		let downloads = [
			Download(url: URL(string: "https://example.com/a.ipa")!, appID: "a", bundleID: "com.example.a", name: "A", version: "1.0", displayVersion: "1.0", status: .failed("Nope")),
			Download(url: URL(string: "https://example.com/b.ipa")!, appID: "b", bundleID: "com.example.b", name: "B", version: "2", displayVersion: "2 (5)", sourceURL: URL(string: "https://example.com/source.json"), expectedSize: 10, sha256: "ab", status: .finished, fileSize: 10),
		]
		try store.save(downloads)
		XCTAssertEqual(store.load(), downloads)
	}

	func testDownloadsSavedBeforeAheadReadAsTheUsers() throws {
		let json = #"[{"id":"7D3F5C2A-1B4E-4C8D-9A6F-2E1D3C4B5A69","url":"https://example.com/a.ipa","appID":"a","bundleID":"com.example.a","name":"A","version":"1.0","displayVersion":"1.0","createdAt":0,"status":{"finished":{}}}]"#
		try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
		try Data(json.utf8).write(to: store.root.appending(path: "downloads.json"))
		let loaded = store.load()
		XCTAssertEqual(loaded.count, 1)
		XCTAssertNil(loaded.first?.isAhead)
	}

	func testMissingListLoadsEmpty() {
		XCTAssertEqual(store.load(), [])
	}

	func testRemovesOrphans() throws {
		let kept = Download(url: URL(string: "https://example.com/a.ipa")!, appID: "a", bundleID: "a", name: "A", version: "1", displayVersion: "1")
		let orphan = UUID()
		try store.save([kept])
		try Data([1]).write(to: store.fileURL(for: kept.id))
		try Data([1]).write(to: store.fileURL(for: orphan))
		store.saveResumeData(Data([2]), for: orphan)

		store.removeOrphans(keeping: [kept])
		XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: kept.id).path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: orphan).path))
		XCTAssertNil(store.resumeData(for: orphan))
		XCTAssertEqual(store.load(), [kept])
	}
}

final class DownloadModelTests: XCTestCase {
	func testMadeFromASourceVersion() {
		let version = AppVersion(version: "1.2", buildVersion: "7", downloadURL: URL(string: "https://example.com/a.ipa")!, size: 1234, sha256: "ff")
		let app = SourceApp(name: "App", bundleID: "com.example.app", versions: [version])
		let source = URL(string: "https://example.com/source.json")!
		let download = Download(app: app, version: version, sourceURL: source)
		XCTAssertEqual(download.appID, app.id)
		XCTAssertEqual(download.version, "1.2")
		XCTAssertEqual(download.displayVersion, "1.2 (7)")
		XCTAssertEqual(download.expectedSize, 1234)
		XCTAssertEqual(download.sha256, "ff")
		XCTAssertTrue(download.matches(version, sourceURL: source))
		XCTAssertFalse(download.matches(version, sourceURL: URL(string: "https://example.org/other.json")!))
	}

	func testNamedAfterAPastedURL() {
		XCTAssertEqual(Download.name(from: URL(string: "https://example.com/a/Some%20App.ipa")!), "Some App")
		XCTAssertEqual(Download.name(from: URL(string: "https://example.com/")!), "example.com")
		XCTAssertFalse(Download(app: SourceApp(name: "App", bundleID: "com.example.app", versions: []), version: AppVersion(version: "1.0", downloadURL: URL(string: "https://example.com/app.ipa")!), sourceURL: nil).isFromURL)
	}

	func testRequestsNameAtelierRatherThanIOS() {
		// Codemagic's artifact links answer iOS's own user agent with an
		// itms-services install link, which a download can't follow.
		let url = URL(string: "https://example.com/app.ipa")!
		let ahead = DownloadManager.request(for: url, ahead: true)
		let agent = ahead.value(forHTTPHeaderField: "User-Agent") ?? ""
		XCTAssertTrue(agent.hasPrefix("Atelier/"), agent)
		XCTAssertFalse(agent.contains("CFNetwork"))
		XCTAssertFalse(agent.contains("Darwin"))
		XCTAssertEqual(ahead.value(forHTTPHeaderField: "Accept"), "application/octet-stream, */*;q=0.8")
		XCTAssertFalse(ahead.allowsCellularAccess)
		XCTAssertTrue(DownloadManager.request(for: url, ahead: false).allowsCellularAccess)
	}

	func testAZeroSizeIsNotChecked() {
		let version = AppVersion(version: "1", downloadURL: URL(string: "https://example.com/a.ipa")!, size: 0)
		let download = Download(app: SourceApp(name: "A", bundleID: "a", versions: [version]), version: version, sourceURL: nil)
		XCTAssertNil(download.expectedSize)
	}

	func testProgress() {
		XCTAssertEqual(DownloadProgress(received: 50, expected: 200).fraction, 0.25)
		XCTAssertNil(DownloadProgress(received: 50, expected: nil).fraction)
		XCTAssertEqual(DownloadProgress(received: 300, expected: 200).fraction, 1)
	}

	func testRetryPolicy() {
		XCTAssertNil(RetryPolicy.delay(beforeAttempt: 0))
		XCTAssertEqual(RetryPolicy.delay(beforeAttempt: 1), 2)
		XCTAssertEqual(RetryPolicy.delay(beforeAttempt: 5), 32)
		XCTAssertNil(RetryPolicy.delay(beforeAttempt: 6))
	}
}

// swift-corelibs-foundation crashes on a URLProtocol answering a download
// task, so the manager is only tested on Apple platforms (CI's Mac build).
#if canImport(Darwin)
/// Serves canned responses to the manager's session.
final class StubProtocol: URLProtocol {
	struct Response {
		var status: Int
		var body: Data
	}

	static var responses: [String: Response] = [:]

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let response = request.url.flatMap { Self.responses[$0.absoluteString] } ?? Response(status: 404, body: Data("<html>gone</html>".utf8))
		let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(response.body.count)"])!
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: response.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

@MainActor
final class DownloadManagerTests: XCTestCase {
	private var store: DownloadStore!

	override func setUp() async throws {
		store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "DownloadManagerTests-\(UUID().uuidString)"))
		StubProtocol.responses = [
			"https://example.com/app.ipa": .init(status: 200, body: TestZip.ipa),
			"https://example.com/page.ipa": .init(status: 200, body: Data("<!doctype html><title>Sign in</title>".utf8)),
			"https://example.com/files/My%20App.ipa": .init(status: 200, body: TestZip.namedIPA),
		]
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: store.root)
	}

	private func manager() -> DownloadManager {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubProtocol.self]
		return DownloadManager(store: store, configuration: configuration)
	}

	private func app(_ url: String, size: Int64? = nil) -> (SourceApp, AppVersion) {
		let version = AppVersion(version: "1.0", downloadURL: URL(string: url)!, size: size)
		return (SourceApp(name: "App", bundleID: "com.example.app", versions: [version]), version)
	}

	private func waitUntil(_ manager: DownloadManager, _ id: UUID, timeout: TimeInterval = 10, _ done: (Download.Status) -> Bool) async throws -> Download {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if let download = manager.download(id: id), done(download.status) { return download }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		return try XCTUnwrap(manager.download(id: id))
	}

	func testDownloadsAndChecksAnIPA() async throws {
		let manager = manager()
		let (app, version) = app("https://example.com/app.ipa", size: Int64(TestZip.ipa.count))
		let started = manager.download(app, version: version, sourceURL: nil)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .finished)
		XCTAssertEqual(download.fileSize, Int64(TestZip.ipa.count))
		let file = try XCTUnwrap(manager.fileURL(for: started.id))
		XCTAssertEqual(try Data(contentsOf: file), TestZip.ipa)

		// The same version again reuses the finished download.
		XCTAssertEqual(manager.download(app, version: version, sourceURL: nil).id, started.id)

		// It's still there after a relaunch.
		let relaunched = self.manager()
		XCTAssertEqual(relaunched.download(id: started.id)?.status, .finished)
		XCTAssertNotNil(relaunched.fileURL(for: started.id))

		relaunched.remove(started.id)
		XCTAssertNil(relaunched.download(id: started.id))
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
	}

	func testADownloadAskedForTakesOverOneStartedAhead() async throws {
		let manager = manager()
		let (app, version) = app("https://example.com/app.ipa", size: Int64(TestZip.ipa.count))
		let ahead = manager.download(app, version: version, sourceURL: nil, ahead: true)
		XCTAssertEqual(ahead.isAhead, true)
		// Started ahead again, it's the same one, still ahead.
		XCTAssertEqual(manager.download(app, version: version, sourceURL: nil, ahead: true).isAhead, true)
		let asked = manager.download(app, version: version, sourceURL: nil)
		XCTAssertEqual(asked.id, ahead.id)
		XCTAssertNil(asked.isAhead)
		let download = try await waitUntil(manager, ahead.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .finished)
	}

	func testDownloadsFromAPastedURL() async throws {
		let manager = manager()
		let url = URL(string: "https://example.com/files/My%20App.ipa")!
		let started = manager.download(url: url)
		// Named after the file until the app itself can be read.
		XCTAssertEqual(started.name, "My App")
		XCTAssertTrue(started.isFromURL)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .finished)
		XCTAssertEqual(download.name, "Named App")
		XCTAssertEqual(download.bundleID, "com.example.named")
		XCTAssertEqual(download.displayVersion, "2.3")
		XCTAssertTrue(download.isFromURL)
		// The same URL again reuses it.
		XCTAssertEqual(manager.download(url: url).id, started.id)
	}

	func testRejectsAWebPage() async throws {
		let manager = manager()
		let (app, version) = app("https://example.com/page.ipa")
		let started = manager.download(app, version: version, sourceURL: nil)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .failed(DownloadVerifier.Problem.webPage.description))
		XCTAssertNil(manager.fileURL(for: started.id))
	}

	func testRejectsAnErrorStatus() async throws {
		let manager = manager()
		let (app, version) = app("https://example.com/missing.ipa")
		let started = manager.download(app, version: version, sourceURL: nil)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .failed(DownloadVerifier.Problem.httpStatus(404).description))
	}

	/// A download whose address couldn't be resolved, such as a private
	/// repo's asset no GitHub account can see, says why with
	/// `startFailure`, which the app recognises to offer a sign-in (#134).
	func testSaysWhyItCouldNotStart() async throws {
		struct Refused: Error, CustomStringConvertible {
			var description: String { "Nobody can see it." }
		}
		let manager = manager()
		manager.resolveURL = { _ in throw Refused() }
		let (app, version) = app("https://example.com/app.ipa")
		let started = manager.download(app, version: version, sourceURL: nil)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .failed("Couldn't start the download: Nobody can see it."))
		XCTAssertEqual(DownloadManager.startFailure(Refused()), "Couldn't start the download: Nobody can see it.")
	}

	func testRejectsTheWrongSize() async throws {
		let manager = manager()
		let (app, version) = app("https://example.com/app.ipa", size: 5)
		let started = manager.download(app, version: version, sourceURL: nil)
		let download = try await waitUntil(manager, started.id) { $0 != .downloading }
		XCTAssertEqual(download.status, .failed(DownloadVerifier.Problem.sizeMismatch(expected: 5, actual: Int64(TestZip.ipa.count)).description))
	}
}
#endif
