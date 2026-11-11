import Foundation
import XCTest
@testable import AtelierCore

/// The links apps installed from an IPA link came from, which Install
/// As… and Re-sign download again (#113, #155).
final class IPAOriginsTests: XCTestCase {
	private var file: URL!

	override func setUpWithError() throws {
		file = FileManager.default.temporaryDirectory.appending(path: "IPAOriginsTests-\(UUID().uuidString)/IPA Origins.json")
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
	}

	func testKeepsEachAppsLinkByItsBundleID() throws {
		let origins = IPAOrigins(file: file)
		XCTAssertNil(origins.link(of: "com.x.app"))
		let x = URL(string: "https://github.com/x/app/releases/download/1.0/App.ipa")!
		let y = URL(string: "https://api.codemagic.io/artifacts/y/Y.ipa")!
		origins.save(x, for: "com.x.app")
		origins.save(y, for: "com.y.app")
		XCTAssertEqual(origins.link(of: "com.x.app"), x)
		XCTAssertEqual(origins.link(of: "com.y.app"), y)

		// Read again from the file.
		let again = IPAOrigins(file: file)
		XCTAssertEqual(again.link(of: "com.x.app"), x)
		XCTAssertEqual(again.link(of: "com.y.app"), y)

		// Installed from a source since, or from a file.
		again.save(nil, for: "com.y.app")
		XCTAssertNil(IPAOrigins(file: file).link(of: "com.y.app"))
		again.save(nil, for: "com.x.app")
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
	}

	func testWritesEachLinkUnderLink() throws {
		IPAOrigins(file: file).save(URL(string: "https://a.example/a.ipa")!, for: "com.x.a")
		let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: String]]
		XCTAssertEqual(written, ["com.x.a": ["link": "https://a.example/a.ipa"]])
	}

	func testForgetsAppsNoLongerInTheLibrary() {
		let origins = IPAOrigins(file: file)
		origins.save(URL(string: "https://a.example/a.ipa")!, for: "com.x.a")
		origins.save(URL(string: "https://b.example/b.ipa")!, for: "com.x.b")
		origins.keep(only: ["com.x.b", "com.x.c"])
		XCTAssertNil(origins.link(of: "com.x.a"))
		XCTAssertNotNil(IPAOrigins(file: file).link(of: "com.x.b"))
	}

	func testReadsWhatItDoesntKnowAsNothing() throws {
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		// com.x.c is a bookmark to a file, as test builds kept them.
		try Data(#"{"com.x.a": {"link": "https://a.example/a.ipa"}, "com.x.b": {"shortcut": 3}, "com.x.c": {"bookmark": "AQID", "name": "C.ipa"}, "com.x.d": 4}"#.utf8).write(to: file)
		let origins = IPAOrigins(file: file)
		XCTAssertEqual(origins.link(of: "com.x.a"), URL(string: "https://a.example/a.ipa")!)
		XCTAssertNil(origins.link(of: "com.x.b"))
		XCTAssertNil(origins.link(of: "com.x.c"))
		XCTAssertNil(origins.link(of: "com.x.d"))

		// Saving another drops what it couldn't read.
		origins.save(URL(string: "https://e.example/e.ipa")!, for: "com.x.e")
		let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
		XCTAssertEqual(written.map { Set($0.keys) }, ["com.x.a", "com.x.e"])

		try Data("not JSON".utf8).write(to: file)
		XCTAssertNil(IPAOrigins(file: file).link(of: "com.x.a"))
	}

	func testShortensLongLinksInTheMiddle() {
		let short = URL(string: "https://github.com/x/y/releases/download/1/y.ipa")!
		XCTAssertEqual(IPAOrigins.shortened(short), short.absoluteString)
		let long = URL(string: "https://api.codemagic.io/artifacts/.eJwVwUtygjAAANC7uH9hTvRNM8xFqk0NzRV7qBnx4RFi-BuNOIQ0x3Z7Lq/Atelier.ipa")!
		let shown = IPAOrigins.shortened(long)
		XCTAssertEqual(shown.count, 72)
		XCTAssertTrue(shown.hasPrefix("https://api.codemagic.io/artifacts/.eJwVwUtygjAA"), shown)
		XCTAssertTrue(shown.hasSuffix("…" + long.absoluteString.suffix(23)), shown)
		XCTAssertTrue(shown.hasSuffix("/Atelier.ipa"), shown)
		XCTAssertEqual(shown.filter { $0 == "…" }.count, 1)
		XCTAssertEqual(IPAOrigins.shortened(long, limit: 10), "https:…ipa")
	}

	func testNamesTheLinksSite() {
		XCTAssertEqual(IPAOrigins.site(of: URL(string: "https://github.com/x/y/releases/download/1/y.ipa")!), "github.com")
		XCTAssertEqual(IPAOrigins.site(of: URL(string: "https://www.example.com/y.ipa")!), "example.com")
		XCTAssertEqual(IPAOrigins.site(of: URL(string: "https://api.codemagic.io/artifacts/x/Atelier.ipa")!), "api.codemagic.io")
	}
}
