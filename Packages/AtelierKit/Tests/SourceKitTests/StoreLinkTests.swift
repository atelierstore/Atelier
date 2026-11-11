import Foundation
import XCTest
@testable import SourceKit

/// The links AltStore, SideStore and Feather open, as their code reads them
/// (#93).
final class StoreLinkTests: XCTestCase {
	private func link(_ string: String) throws -> StoreLink? {
		try StoreLink(URL(string: string)!)
	}

	private func problem(_ string: String) -> StoreLink.Problem? {
		do {
			_ = try link(string)
			return nil
		} catch {
			return error as? StoreLink.Problem
		}
	}

	func testLeavesOtherLinksAlone() throws {
		XCTAssertNil(try link("https://example.com/apps.json"))
		XCTAssertNil(try StoreLink(URL(fileURLWithPath: "/tmp/app.ipa")))
		XCTAssertNil(try link("localdevvpn://enable"))
		// Just opens the app.
		XCTAssertNil(try link("altstore://"))
		// LocalDevVPN switching back, and the GitHub sign-in's answer, which
		// RootView and the sign-in read.
		XCTAssertNil(try link("atelier://"))
		XCTAssertNil(try link("atelier://github-sign-in?code=c&state=s"))
	}

	func testSourceLinksOnEveryScheme() throws {
		for scheme in ["atelier", "altstore", "altstore-classic", "altstore-pal", "sidestore", "feather", "SideStore"] {
			let string = "\(scheme)://source?url=https://example.com/apps.json"
			XCTAssertEqual(try link(string), .source(link: string), scheme)
		}
		XCTAssertEqual(try link("feather://source/https://example.com/apps.json"), .source(link: "feather://source/https://example.com/apps.json"))
		// The add sheet reads the source and says what's wrong with it.
		XCTAssertEqual(try link("altstore://source"), .source(link: "altstore://source"))
	}

	func testInstallLinks() throws {
		let ipa = URL(string: "https://github.com/user/app/releases/download/v1/Nimbus.ipa")!
		XCTAssertEqual(try link("altstore://install?url=https%3A%2F%2Fgithub.com%2Fuser%2Fapp%2Freleases%2Fdownload%2Fv1%2FNimbus.ipa"), .install(ipa, source: nil))
		XCTAssertEqual(try link("sidestore://install?url=\(ipa.absoluteString)"), .install(ipa, source: nil))
		XCTAssertEqual(try link("altstore-classic://install?URL=\(ipa.absoluteString)"), .install(ipa, source: nil))
		XCTAssertEqual(try link("feather://install/\(ipa.absoluteString)"), .install(ipa, source: nil))
		XCTAssertEqual(try link("atelier://install?url=example.com/app.ipa"), .install(URL(string: "https://example.com/app.ipa")!, source: nil))
		// The IPA's own query stays with it in Feather's form, a source too.
		XCTAssertEqual(try link("feather://install/https://example.com/get?id=3&key=k"), .install(URL(string: "https://example.com/get?id=3&key=k")!, source: nil))
		XCTAssertEqual(try link("feather://install/https://example.com/get?id=3&source=x"), .install(URL(string: "https://example.com/get?id=3&source=x")!, source: nil))
		// The source it comes from, as for an app link.
		XCTAssertEqual(
			try link("atelier://install?url=https%3A%2F%2Fgithub.com%2Fuser%2Fapp%2Freleases%2Fdownload%2Fv1%2FNimbus.ipa&source=user%2Fapp"),
			.install(ipa, source: "user/app")
		)
		XCTAssertEqual(
			try link("atelier://install?source=https%3A%2F%2Fexample.com%2Fapps.json&url=https%3A%2F%2Fgithub.com%2Fuser%2Fapp%2Freleases%2Fdownload%2Fv1%2FNimbus.ipa"),
			.install(ipa, source: "https://example.com/apps.json")
		)
		XCTAssertEqual(try link("atelier://install?url=\(ipa.absoluteString)&source=%20"), .install(ipa, source: nil))

		XCTAssertEqual(problem("altstore://install"), .noApp)
		XCTAssertEqual(problem("altstore://install?url="), .noApp)
		XCTAssertEqual(problem("altstore://install?url=http://example.com/app.ipa"), .notHTTPS(scheme: "http"))
		XCTAssertEqual(problem("altstore://install?url=ftp://example.com/app.ipa"), .notAWebAddress)
		XCTAssertEqual(problem("altstore://install?url=not%20an%20address"), .notAWebAddress)
	}

	func testAppAndSearchLinks() throws {
		XCTAssertEqual(try link("altstore://viewapp?bundleID=com.rileytestut.Delta"), .viewApp(bundleID: "com.rileytestut.Delta", source: nil))
		XCTAssertEqual(problem("altstore://viewapp"), .noBundleID)
		// The source it comes from, to add when no source lists it: an
		// address, a GitHub repo, as a source link names them.
		XCTAssertEqual(
			try link("atelier://viewapp?bundleid=com.rileytestut.Delta&source=https%3A%2F%2Fcdn.altstore.io%2Ffile%2Faltstore%2Fapps.json"),
			.viewApp(bundleID: "com.rileytestut.Delta", source: "https://cdn.altstore.io/file/altstore/apps.json")
		)
		XCTAssertEqual(try link("altstore://viewapp?Source=StikDebug/StikPair&bundleID=com.stik.StikPair"), .viewApp(bundleID: "com.stik.StikPair", source: "StikDebug/StikPair"))
		XCTAssertEqual(try link("atelier://viewapp?bundleid=a.b&source=%20"), .viewApp(bundleID: "a.b", source: nil))
		XCTAssertEqual(problem("atelier://viewapp?source=https://example.com/apps.json"), .noBundleID)
		// AltStore reads `+` as a space.
		XCTAssertEqual(try link("altstore://search?q=retro+games"), .search("retro games"))
		XCTAssertEqual(try link("altstore://search?q=C%2B%2B%20tools"), .search("C++ tools"))
		XCTAssertEqual(problem("altstore://search?q="), .noSearch)
	}

	func testImportCertificateLinks() throws {
		let p12 = Data([0x30, 0x82, 0x01, 0xFB, 0xFF])
		let profile = Data("<plist/>".utf8)
		let password = Data("pa&ss word".utf8)
		var components = URLComponents(string: "feather://import-certificate")!
		components.queryItems = [
			URLQueryItem(name: "p12", value: p12.base64EncodedString()),
			URLQueryItem(name: "mobileprovision", value: profile.base64EncodedString()),
			URLQueryItem(name: "password", value: password.base64EncodedString()),
		]
		XCTAssertEqual(try StoreLink(components.url!), .importCertificate(p12: p12, profile: profile, password: "pa&ss word"))

		// Unpadded, URL-safe base64, and an empty password.
		let unpadded = p12.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
		XCTAssertEqual(
			try link("feather://import-certificate?p12=\(unpadded)&mobileprovision=\(profile.base64EncodedString())&password="),
			.importCertificate(p12: p12, profile: profile, password: "")
		)
		XCTAssertEqual(problem("feather://import-certificate?p12=@@@@&mobileprovision=AAAA&password="), .unreadableCertificate)
		XCTAssertEqual(problem("feather://import-certificate?mobileprovision=AAAA"), .unreadableCertificate)
	}

	func testCertificateRequests() throws {
		// LiveContainer's request, as Feather's code documents it.
		let template = "livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)"
		let encoded = "livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29"
		for request in ["sidestore://certificate?callback_template=", "altstore://certificate?callback_template=", "feather://export-certificate?callback_template="] {
			guard case .exportCertificate(let callback)? = try link(request + encoded) else { return XCTFail(request) }
			XCTAssertEqual(callback.template, template)
			XCTAssertEqual(callback.scheme, "livecontainer")
		}

		XCTAssertEqual(problem("sidestore://certificate"), .noCallback)
		XCTAssertEqual(problem("sidestore://certificate?callback_template=livecontainer%3A%2F%2Fcertificate"), .noCallback)
		// Never to a web page, a browser or another store.
		XCTAssertEqual(problem("sidestore://certificate?callback_template=https%3A%2F%2Fexample.com%2F%3Fc%3D%24%28BASE64_CERT%29"), .callbackNotAnApp(scheme: "https"))
		XCTAssertEqual(problem("feather://export-certificate?callback_template=googlechromes%3A%2F%2Fexample.com%2F%3Fc%3D%24%28BASE64_CERT%29"), .callbackNotAnApp(scheme: "googlechromes"))
		XCTAssertEqual(problem("feather://export-certificate?callback_template=sidestore%3A%2F%2Fsource%3Furl%3D%24%28BASE64_CERT%29"), .callbackNotAnApp(scheme: "sidestore"))
	}

	func testFillsInTheCertificate() throws {
		guard case .exportCertificate(let callback)? = try link("sidestore://certificate?callback_template=livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
			return XCTFail()
		}
		// Base64 with `+` and `/`, and a password that would break the link
		// as it is.
		let p12 = Data([0xFB, 0xEF, 0xFF, 0x00])
		let url = try XCTUnwrap(callback.url(certificate: p12, password: "a&b#c d"))
		XCTAssertEqual(url.scheme, "livecontainer")
		let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		XCTAssertEqual(items.first { $0.name == "cert" }?.value, p12.base64EncodedString())
		XCTAssertEqual(items.first { $0.name == "password" }?.value, "a&b#c d")
	}

	func testPairingFileRequests() throws {
		guard case .exportPairingFile(let callback)? = try link("sidestore://pairing?urlname=debugtool") else { return XCTFail() }
		XCTAssertEqual(callback.scheme, "debugtool")
		let file = Data("<?xml version=\"1.0\"?><plist/>".utf8)
		let url = try XCTUnwrap(callback.url(pairingFile: file))
		XCTAssertEqual(url.host, "pairingFile")
		XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, file.base64EncodedString())

		XCTAssertEqual(problem("sidestore://pairing"), .noCallback)
		// Only a plain scheme name: SideStore puts it in front of
		// `://pairingFile?data=…` as it is.
		XCTAssertEqual(problem("sidestore://pairing?urlname=https%3A%2F%2Fexample.com%2F%3F"), .callbackNotAnApp(scheme: "https://example.com/?"))
		XCTAssertEqual(problem("sidestore://pairing?urlname=https"), .callbackNotAnApp(scheme: "https"))
	}

	func testLinksForThingsAtelierDoesNotDo() throws {
		XCTAssertEqual(try link("altstore://patreon"), .unsupported(store: "AltStore"))
		XCTAssertEqual(try link("sidestore://appbackupresponse/success"), .unsupported(store: "SideStore"))
		XCTAssertEqual(try link("altstore-pal://pal-promo?session=s&email=e"), .unsupported(store: "AltStore PAL"))
		XCTAssertEqual(try link("atelier://something-new"), .unsupported(store: "Atelier"))
	}
}
