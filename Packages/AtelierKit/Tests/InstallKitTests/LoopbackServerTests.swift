#if canImport(Network)
import Foundation
import XCTest
@testable import InstallKit

private final class Events: @unchecked Sendable {
	private let lock = NSLock()
	private var events: [String] = []

	var all: [String] {
		lock.lock()
		defer { lock.unlock() }
		return events
	}

	func append(_ event: String) {
		lock.lock()
		defer { lock.unlock() }
		events.append(event)
	}
}

final class LoopbackServerTests: XCTestCase {
	private var fileURL: URL!
	private let body = Data((0..<10_000).map { UInt8($0 % 251) })

	override func setUpWithError() throws {
		fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
		try body.write(to: fileURL)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: fileURL)
	}

	func testServesWholeFileAndRanges() async throws {
		let server = LoopbackServer(fileURLs: [fileURL])
		let port = try await server.start()
		defer { server.stop() }
		let url = server.url(of: server.packages[0], port: port)
		XCTAssertEqual(url.host, "127.0.0.1")

		let (whole, response) = try await URLSession.shared.data(from: url)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
		XCTAssertEqual(whole, body)

		var request = URLRequest(url: url)
		request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
		let (part, partResponse) = try await URLSession.shared.data(for: request)
		XCTAssertEqual((partResponse as? HTTPURLResponse)?.statusCode, 206)
		XCTAssertEqual(part, body[100...199])
	}

	func testReportsRequestsAndWholePayloads() async throws {
		let server = LoopbackServer(fileURLs: [fileURL])
		let events = Events()
		server.onRequest = { index, method in events.append("\(index) \(method)") }
		server.onPayloadEnded = { index, whole in events.append("\(index) ended whole=\(whole)") }
		let port = try await server.start()
		defer { server.stop() }
		let url = server.url(of: server.packages[0], port: port)

		var head = URLRequest(url: url)
		head.httpMethod = "HEAD"
		_ = try await URLSession.shared.data(for: head)
		_ = try await URLSession.shared.data(from: url)
		var range = URLRequest(url: url)
		range.setValue("bytes=0-9", forHTTPHeaderField: "Range")
		_ = try await URLSession.shared.data(for: range)

		// The end of a payload is reported just before the connection closes.
		for _ in 0..<50 where events.all.count < 5 {
			try await Task.sleep(nanoseconds: 20_000_000)
		}
		// The end of one payload and the next request can race, so order isn't checked.
		XCTAssertEqual(events.all.sorted(), ["0 GET", "0 GET", "0 HEAD", "0 ended whole=false", "0 ended whole=true"])
	}

	func testUnknownPathIsNotFound() async throws {
		let server = LoopbackServer(fileURLs: [fileURL])
		let port = try await server.start()
		defer { server.stop() }

		let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/other.ipa")!)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
	}
}
#endif
