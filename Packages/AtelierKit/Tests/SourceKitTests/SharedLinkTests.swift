import Foundation
import XCTest
@testable import SourceKit

/// Links shared to Atelier from other apps' share sheets (#56), as the
/// Atelier links its share extension opens, and as Atelier reads those back.
final class SharedLinkTests: XCTestCase {
	private func link(_ string: String, scheme: String = "atelier") -> String? {
		SharedLink.link(for: URL(string: string)!, scheme: scheme)?.absoluteString
	}

	private func storeLink(_ string: String?) throws -> StoreLink? {
		try string.flatMap { try StoreLink(URL(string: $0)!) }
	}

	func testIPAsInstall() throws {
		let ipa = "https://github.com/nimbus-app/nimbus/releases/download/v2.4/Nimbus.ipa"
		XCTAssertEqual(
			link(ipa),
			"atelier://install?url=https%3A%2F%2Fgithub.com%2Fnimbus-app%2Fnimbus%2Freleases%2Fdownload%2Fv2.4%2FNimbus.ipa"
		)
		XCTAssertEqual(try storeLink(link(ipa)), .install(URL(string: ipa)!, source: nil))
		// TrollStore's, in any case.
		XCTAssertEqual(try storeLink(link("https://example.com/Apps/Nimbus.TIPA")), .install(URL(string: "https://example.com/Apps/Nimbus.TIPA")!, source: nil))
	}

	func testAnIPAsOwnQueryStaysWithIt() throws {
		let ipa = "https://example.com/get/Nimbus.ipa?token=a%26b&source=x#top"
		XCTAssertEqual(try storeLink(link(ipa)), .install(URL(string: ipa)!, source: nil))
	}

	func testHTTPIPAsSayWhy() {
		// Atelier says it only downloads apps over HTTPS, as for an install link.
		XCTAssertEqual(link("http://example.com/Nimbus.ipa"), "atelier://install?url=http%3A%2F%2Fexample.com%2FNimbus.ipa")
		XCTAssertThrowsError(try storeLink(link("http://example.com/Nimbus.ipa"))) { error in
			XCTAssertEqual(error as? StoreLink.Problem, .notHTTPS(scheme: "http"))
		}
	}

	func testEverythingElseIsASourceToAdd() throws {
		for shared in [
			"https://cdn.altstore.io/file/altstore/apps.json",
			"https://github.com/StikDebug/StikPair",
			"https://example.com/blog/post?id=3&lang=en",
		] {
			let opened = try XCTUnwrap(link(shared), shared)
			XCTAssertEqual(try storeLink(opened), .source(link: opened), shared)
			// What the add sheet reads from it.
			XCTAssertEqual(try SourceLink.sourceURL(from: opened), try SourceLink.sourceURL(from: shared), shared)
		}
	}

	func testTheWebsitesLinkPages() throws {
		XCTAssertEqual(
			link("https://atelierstore.app/install?url=https%3A%2F%2Fexample.com%2FApp.ipa&source=user%2Fapp"),
			"atelier://install?url=https%3A%2F%2Fexample.com%2FApp.ipa&source=user%2Fapp"
		)
		XCTAssertEqual(link("https://atelierstore.app/source?url=StikDebug%2FStikPair"), "atelier://source?url=StikDebug%2FStikPair")
		XCTAssertEqual(link("https://www.atelierstore.app/viewapp.html?bundleid=com.rileytestut.Delta"), "atelier://viewapp?bundleid=com.rileytestut.Delta")
		XCTAssertEqual(link("https://atelierstore.app/search/?q=emulator"), "atelier://search?q=emulator")
		XCTAssertEqual(try storeLink(link("https://atelierstore.app/search?q=emulator")), .search("emulator"))
		// The rest of the site, such as a build's IPA, isn't a link page.
		XCTAssertEqual(
			link("https://atelierstore.app/builds/0123456789abcdef0123456789abcdef/Atelier.ipa"),
			"atelier://install?url=https%3A%2F%2Fatelierstore.app%2Fbuilds%2F0123456789abcdef0123456789abcdef%2FAtelier.ipa"
		)
		XCTAssertEqual(link("https://atelierstore.app/"), "atelier://source?url=https%3A%2F%2Fatelierstore.app%2F")
	}

	func testOnlyWebAddresses() {
		XCTAssertNil(link("altstore://source?url=https://example.com/apps.json"))
		XCTAssertNil(SharedLink.link(for: URL(fileURLWithPath: "/tmp/Nimbus.ipa")))
		XCTAssertNil(link("mailto:someone@example.com"))
	}

	func testACopysOwnScheme() throws {
		let scheme = "atelier-com.atelier.app.ateliertests"
		let opened = try XCTUnwrap(link("https://example.com/Nimbus.ipa", scheme: scheme))
		XCTAssertEqual(opened, "\(scheme)://install?url=https%3A%2F%2Fexample.com%2FNimbus.ipa")
		let read = try XCTUnwrap(SharedLink.atelierLink(URL(string: opened)!, ownScheme: scheme))
		XCTAssertEqual(read.absoluteString, "atelier://install?url=https%3A%2F%2Fexample.com%2FNimbus.ipa")
		XCTAssertEqual(try StoreLink(read), .install(URL(string: "https://example.com/Nimbus.ipa")!, source: nil))
		// LocalDevVPN switching back, and links on other schemes.
		XCTAssertNil(SharedLink.atelierLink(URL(string: "\(scheme)://")!, ownScheme: scheme))
		XCTAssertNil(SharedLink.atelierLink(URL(string: "atelier://install?url=x")!, ownScheme: "atelier"))
		XCTAssertNil(SharedLink.atelierLink(URL(string: "atelier-com.other://install?url=x")!, ownScheme: scheme))
	}
}
