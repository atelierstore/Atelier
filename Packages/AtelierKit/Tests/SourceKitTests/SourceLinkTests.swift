import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SourceKit

final class SourceLinkTests: XCTestCase {
	private func url(_ input: String) throws -> String {
		try SourceLink.sourceURL(from: input).absoluteString
	}

	private func problem(_ input: String) -> SourceLink.Problem? {
		do {
			_ = try SourceLink.sourceURL(from: input)
			return nil
		} catch {
			return error as? SourceLink.Problem
		}
	}

	func testPastedURLs() throws {
		XCTAssertEqual(try url("https://example.com/apps.json"), "https://example.com/apps.json")
		XCTAssertEqual(try url("  https://Example.COM:443/apps.json#top \n"), "https://example.com/apps.json")
		XCTAssertEqual(try url("example.com/apps.json"), "https://example.com/apps.json")
		XCTAssertEqual(try url("https://example.com"), "https://example.com/")
		XCTAssertEqual(try url("https://example.com/apps.json?token=a"), "https://example.com/apps.json?token=a")
		XCTAssertEqual(try url("HTTPS://example.com/Apps.json"), "https://example.com/Apps.json")
	}

	func testRejectsWhatIsNotAnHTTPSSource() {
		XCTAssertEqual(problem(""), .empty)
		XCTAssertEqual(problem("   "), .empty)
		XCTAssertEqual(problem("http://example.com/apps.json"), .notHTTPS(scheme: "http"))
		XCTAssertEqual(problem("ftp://example.com/apps.json"), .notHTTPS(scheme: "ftp"))
		XCTAssertEqual(problem("not a url"), .notAURL)
		XCTAssertEqual(problem("https://"), .notAURL)
	}

	func testDeepLinks() throws {
		let encoded = "https%3A%2F%2Fexample.com%2Fapps.json"
		XCTAssertEqual(try url("atelier://source?url=\(encoded)"), "https://example.com/apps.json")
		XCTAssertEqual(try url("altstore://source?url=\(encoded)"), "https://example.com/apps.json")
		// Many "Add to AltStore" buttons don't encode the URL.
		XCTAssertEqual(try url("altstore://source?url=https://example.com/apps.json"), "https://example.com/apps.json")
		XCTAssertEqual(try url("AltStore://Source?url=example.com/apps.json"), "https://example.com/apps.json")
		// SideStore's, AltStore Classic's and PAL's (#93).
		XCTAssertEqual(try url("sidestore://source?url=\(encoded)"), "https://example.com/apps.json")
		XCTAssertEqual(try url("altstore-classic://source?URL=\(encoded)"), "https://example.com/apps.json")
		XCTAssertEqual(try url("altstore-pal://source?url=https://example.com/apps.json"), "https://example.com/apps.json")
		// Feather's: the address after the host, its own query included.
		XCTAssertEqual(try url("feather://source/https://example.com/apps.json"), "https://example.com/apps.json")
		XCTAssertEqual(try url("feather://source/https://example.com/apps.json?token=a"), "https://example.com/apps.json?token=a")
		XCTAssertEqual(try url("feather://source/\(encoded)"), "https://example.com/apps.json")

		XCTAssertEqual(problem("altstore://source?url=http://example.com/apps.json"), .notHTTPS(scheme: "http"))
		XCTAssertEqual(problem("altstore://source"), .noSourceInLink)
		XCTAssertEqual(problem("altstore://install?url=\(encoded)"), .noSourceInLink)
		XCTAssertEqual(problem("atelier://source?url=altstore://source?url=\(encoded)"), .noSourceInLink)
	}

	func testTellsSourceLinksFromFiles() {
		XCTAssertTrue(SourceLink.isSourceLink(URL(string: "altstore://source?url=x")!))
		XCTAssertTrue(SourceLink.isSourceLink(URL(string: "atelier://source?url=x")!))
		XCTAssertTrue(SourceLink.isSourceLink(URL(string: "feather://source/https://x")!))
		XCTAssertFalse(SourceLink.isSourceLink(URL(fileURLWithPath: "/tmp/cert.p12")))
		XCTAssertFalse(SourceLink.isSourceLink(URL(string: "https://example.com/apps.json")!))
	}
}

final class SourceFetcherTests: XCTestCase {
	private let sourceURL = URL(string: "https://example.com/apps.json")!
	private let json = Data(#"{"name": "Example", "apps": [{"name": "App", "bundleIdentifier": "com.example.app", "versions": [{"version": "1.0", "downloadURL": "https://example.com/app.ipa"}]}]}"#.utf8)

	private func fetcher(
		status: Int,
		body: Data = Data(),
		headers: [String: String] = [:],
		finalURL: URL? = nil,
		seen: RequestBox? = nil
	) -> SourceFetcher {
		let url = finalURL ?? sourceURL
		return SourceFetcher { request in
			seen?.request = request
			let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
			return (body, response)
		}
	}

	func testFetchesAndKeepsTheValidators() async throws {
		let seen = RequestBox()
		let outcome = try await fetcher(
			status: 200, body: json, headers: ["ETag": "\"abc\"", "Last-Modified": "Sat, 17 Oct 2026 10:00:00 GMT"], seen: seen
		).fetch(sourceURL)
		guard case .fetched(let fetched) = outcome else { return XCTFail("Expected a fetched source, got \(outcome)") }
		XCTAssertEqual(fetched.parsed.source.name, "Example")
		XCTAssertEqual(fetched.parsed.source.apps.map(\.bundleID), ["com.example.app"])
		XCTAssertEqual(fetched.etag, "\"abc\"")
		XCTAssertEqual(fetched.lastModified, "Sat, 17 Oct 2026 10:00:00 GMT")
		XCTAssertEqual(fetched.data, json)
		XCTAssertNil(seen.request?.value(forHTTPHeaderField: "If-None-Match"))
		XCTAssertNil(seen.request?.value(forHTTPHeaderField: "If-Modified-Since"))
	}

	func testAsksWhetherTheSourceChanged() async throws {
		let seen = RequestBox()
		let outcome = try await fetcher(status: 304, seen: seen)
			.fetch(sourceURL, etag: "\"abc\"", lastModified: "Sat, 17 Oct 2026 10:00:00 GMT")
		guard case .notModified = outcome else { return XCTFail("Expected not modified, got \(outcome)") }
		XCTAssertEqual(seen.request?.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
		XCTAssertEqual(seen.request?.value(forHTTPHeaderField: "If-Modified-Since"), "Sat, 17 Oct 2026 10:00:00 GMT")
		XCTAssertEqual(seen.request?.cachePolicy, .reloadIgnoringLocalCacheData)
	}

	func testFailures() async {
		await assertProblem(.status(404), fetcher(status: 404))
		await assertProblem(.notHTTPS, fetcher(status: 200, body: json, finalURL: URL(string: "http://example.com/apps.json")!))
		await assertProblem(.notASource("The source isn't a JSON object."), fetcher(status: 200, body: Data("[]".utf8)))
	}

	/// What the user is told: what an HTTP code means, not the code.
	func testFailuresSayWhatTheyMean() {
		XCTAssertEqual(SourceFetcher.Problem.status(404).description, "Nothing was found at this address. Check it and try again.")
		XCTAssertEqual(SourceFetcher.Problem.status(403).description, "This source isn't public.")
		XCTAssertEqual(SourceFetcher.Problem.status(503).description, "The source's server had a problem. Try again later.")
		XCTAssertEqual(SourceFetcher.Problem.status(418).description, "The source's server refused the request (error 418).")
		XCTAssertEqual(SourceFetcher.Problem.notASource("The source isn't a JSON object.").description, "This address doesn't lead to an app source. Check that you copied the whole address.")
		XCTAssertEqual(SourceLink.Problem.notHTTPS(scheme: "http").description, "Atelier only adds sources whose address starts with https://.")
	}

	private func assertProblem(_ expected: SourceFetcher.Problem, _ fetcher: SourceFetcher, line: UInt = #line) async {
		do {
			let outcome = try await fetcher.fetch(sourceURL)
			XCTFail("Expected \(expected), got \(outcome)", line: line)
		} catch {
			XCTAssertEqual(error as? SourceFetcher.Problem, expected, line: line)
		}
	}
}

final class RequestBox: @unchecked Sendable {
	var request: URLRequest?
}
