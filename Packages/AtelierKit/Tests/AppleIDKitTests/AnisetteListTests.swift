import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppleIDKit

final class AnisetteListTests: XCTestCase {
	private func list(_ json: String) throws -> AnisetteList {
		try AnisetteList(json: Data(json.utf8))
	}

	private func server(_ url: String) -> String {
		#"{"url": "\#(url)", "name": "\#(url)"}"#
	}

	// MARK: The built-in copy

	func testBuiltInCopyReadsWithIloadersDefaultFirst() throws {
		let url = builtInFile()
		let read = try AnisetteList(json: Data(contentsOf: url))
		// What the app gets, through the resource bundle.
		XCTAssertEqual(AnisetteList.builtIn, read)
		XCTAssertEqual(read.servers.first?.url.absoluteString, "https://mac-ani.jkcoxson.com")
		XCTAssertEqual(read.servers.first?.kind, "mac")
		XCTAssertEqual(read.tries, 4)
		XCTAssertNotNil(read.clientInfo)
		XCTAssertFalse(read.updated.isEmpty)
		// Nothing was dropped reading it: every server is one Atelier can use.
		let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
		XCTAssertEqual(read.servers.count, (raw?["servers"] as? [Any])?.count)
	}

	/// The copy in the package's sources.
	private func builtInFile() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Sources/AppleIDKit/anisette.json")
	}

	// MARK: Reading

	func testReadsServersClientInfoAndTries() throws {
		let read = try list(#"""
		{"version": 1, "updated": "2026-11-02", "tries": 3,
		 "clientInfo": {"clientInfo": "<Mac15,7> <macOS;27.0;26A5378j>", "userAgent": "akd/1.0"},
		 "servers": [{"url": "https://a.example", "name": "A", "kind": "mac"}, {"url": "https://b.example:8443"}],
		 "somethingNew": true}
		"""#)
		XCTAssertEqual(read.updated, "2026-11-02")
		XCTAssertEqual(read.tries, 3)
		XCTAssertEqual(read.clientInfo, AnisetteList.ClientInfo(clientInfo: "<Mac15,7> <macOS;27.0;26A5378j>", userAgent: "akd/1.0"))
		XCTAssertEqual(read.servers, [
			AnisetteList.Server(url: URL(string: "https://a.example")!, name: "A", kind: "mac"),
			// No name: its host.
			AnisetteList.Server(url: URL(string: "https://b.example:8443")!, name: "b.example"),
		])
	}

	func testKeepsOnlyHTTPSServersWithNothingButAHostEachOnce() throws {
		let servers = [
			"http://plain.example",
			"https://ok.example/",
			"https://OK.example",
			"https://Upper.Example",
			"https://path.example/v3",
			"https://query.example?x=1",
			"https://user:pass@secret.example",
			"ftp://other.example",
			"not a url",
			"https://",
		].map(server).joined(separator: ",")
		let read = try list(#"{"version": 1, "servers": [\#(servers)]}"#)
		XCTAssertEqual(read.servers.map(\.url.absoluteString), ["https://ok.example", "https://upper.example"])
	}

	func testTriesStayBetweenOneAndEight() throws {
		let one = server("https://a.example")
		XCTAssertEqual(try list(#"{"version": 1, "servers": [\#(one)]}"#).tries, 4)
		XCTAssertEqual(try list(#"{"version": 1, "tries": 0, "servers": [\#(one)]}"#).tries, 1)
		XCTAssertEqual(try list(#"{"version": 1, "tries": 50, "servers": [\#(one)]}"#).tries, 8)
	}

	func testDropsAClientInfoThatCantGoInAHeader() throws {
		let one = server("https://a.example")
		for info in [#"{"clientInfo": "", "userAgent": "akd"}"#, #"{"clientInfo": "<Mac>", "userAgent": "akd\n"}"#, #"{"clientInfo": "Mac ✓", "userAgent": "akd"}"#] {
			XCTAssertNil(try list(#"{"version": 1, "clientInfo": \#(info), "servers": [\#(one)]}"#).clientInfo, info)
		}
	}

	func testRefusesWhatItCantUse() {
		XCTAssertThrowsError(try list("<html>")) { XCTAssertEqual($0 as? AnisetteList.Problem, .unreadable) }
		XCTAssertThrowsError(try list(#"{"servers": []}"#)) { XCTAssertEqual($0 as? AnisetteList.Problem, .unreadable) }
		XCTAssertThrowsError(try list(#"{"version": 2, "servers": [\#(server("https://a.example"))]}"#)) {
			XCTAssertEqual($0 as? AnisetteList.Problem, .version(2))
		}
		XCTAssertThrowsError(try list(#"{"version": 1, "servers": [\#(server("http://a.example"))]}"#)) {
			XCTAssertEqual($0 as? AnisetteList.Problem, .noServers)
		}
	}

	// MARK: Signing in

	private let five = AnisetteList(
		updated: "2026-11-02",
		tries: 3,
		clientInfo: nil,
		servers: ["a", "b", "c", "d", "e"].map { AnisetteList.Server(url: URL(string: "https://\($0).example")!, name: $0) }
	)

	func testTriesTheListsFirstServersInOrder() {
		XCTAssertEqual(five.serversToTry(lastWorked: nil).map(\.name), ["a", "b", "c"])
	}

	func testStartsWithTheServerThatWorkedLast() {
		XCTAssertEqual(five.serversToTry(lastWorked: URL(string: "https://d.example")).map(\.name), ["d", "a", "b"])
		XCTAssertEqual(five.serversToTry(lastWorked: URL(string: "https://b.example")).map(\.name), ["b", "a", "c"])
	}

	func testForgetsAServerTheListNoLongerHas() {
		XCTAssertEqual(five.serversToTry(lastWorked: URL(string: "https://gone.example")).map(\.name), ["a", "b", "c"])
	}

	// MARK: Where the list comes from

	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("AnisetteListTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: folder)
	}

	private let builtIn = AnisetteList(updated: "2026-11-02", tries: 4, clientInfo: nil, servers: [AnisetteList.Server(url: URL(string: "https://built-in.example")!, name: "built in")])

	private func source(answering status: Int = 200, _ body: String? = nil, asked: AskedURLs? = nil) -> AnisetteListSource {
		AnisetteListSource(folder: folder, url: URL(string: "https://worker.example/anisette")!, builtIn: builtIn) { request in
			asked?.append(request)
			guard let body else { throw URLError(.notConnectedToInternet) }
			let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
			return (Data(body.utf8), response)
		}
	}

	private func workerList(updated: String, host: String) -> String {
		#"{"version": 1, "updated": "\#(updated)", "servers": [\#(server("https://\(host)"))]}"#
	}

	func testTakesTheWorkersListAndKeepsIt() async {
		let asked = AskedURLs()
		let fetched = await source(workerList(updated: "2026-11-05", host: "new.example"), asked: asked).current()
		XCTAssertEqual(fetched.origin, .worker)
		XCTAssertEqual(fetched.list.servers.map(\.host), ["new.example"])
		XCTAssertEqual(asked.requests.map { $0.url?.absoluteString }, ["https://worker.example/anisette"])
		XCTAssertEqual(asked.requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)

		// The worker away, the list it gave is kept.
		let offline = await source().current()
		XCTAssertEqual(offline.list, fetched.list)
		guard case .kept(let date) = offline.origin else { return XCTFail("\(offline.origin)") }
		XCTAssertLessThan(abs(date.timeIntervalSinceNow), 60)
	}

	func testUsesTheBuiltInCopyWithNothingKept() async {
		let offline = await source().current()
		XCTAssertEqual(offline.origin, .builtIn)
		XCTAssertEqual(offline.list, builtIn)
	}

	func testAnErrorOrAnUnreadableAnswerIsntKept() async {
		_ = await source(workerList(updated: "2026-11-05", host: "kept.example")).current()
		for answer in [source(answering: 500, workerList(updated: "2026-11-06", host: "error.example")), source("<html>")] {
			let result = await answer.current()
			XCTAssertEqual(result.list.servers.map(\.host), ["kept.example"])
		}
	}

	func testANewerBuiltInCopyBeatsAnOlderKeptList() async {
		_ = await source(workerList(updated: "2026-10-30", host: "old.example")).current()
		let offline = await source().current()
		XCTAssertEqual(offline.origin, .builtIn)
	}

	func testRemembersTheServerThatWorked() {
		XCTAssertNil(source().lastWorked)
		source().setLastWorked(URL(string: "https://b.example")!)
		XCTAssertEqual(source().lastWorked, URL(string: "https://b.example"))
	}
}

/// The requests a test's worker was sent.
private final class AskedURLs: @unchecked Sendable {
	private let lock = NSLock()
	private var asked: [URLRequest] = []

	func append(_ request: URLRequest) {
		lock.lock()
		asked.append(request)
		lock.unlock()
	}

	var requests: [URLRequest] {
		lock.lock()
		defer { lock.unlock() }
		return asked
	}
}
