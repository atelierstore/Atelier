import Foundation
import XCTest
@testable import InstallKit

final class SwitchBackSchemeTests: XCTestCase {
	private func info(_ schemes: [String: [String]]) -> [String: Any] {
		["CFBundleURLTypes": schemes.sorted { $0.key < $1.key }.map { ["CFBundleURLName": $0.key, "CFBundleURLSchemes": $0.value] }]
	}

	func testIsMadeFromTheBundleID() {
		XCTAssertEqual(SwitchBackScheme.scheme(for: "com.atelier.app"), "atelier-com.atelier.app")
		// A copy's, also signed with an Apple ID's team ID (#49, #113).
		XCTAssertEqual(SwitchBackScheme.scheme(for: "com.atelier.app.A1B2C3D4E5.atelier2"), "atelier-com.atelier.app.a1b2c3d4e5.atelier2")
		// LocalDevVPN opens it as "<scheme>://".
		XCTAssertEqual(URL(string: "\(SwitchBackScheme.scheme(for: "com.atelier.app.atelier-tests"))://")?.scheme, "atelier-com.atelier.app.atelier-tests")
	}

	func testReadsItsOwnTypeOnly() {
		let atelier = info(["com.atelier.app.source": ["atelier", "altstore"], SwitchBackScheme.urlTypeName: ["atelier-com.atelier.app"]])
		XCTAssertEqual(SwitchBackScheme.scheme(in: atelier), "atelier-com.atelier.app")
		// Builds before it.
		XCTAssertNil(SwitchBackScheme.scheme(in: info(["com.atelier.app.source": ["atelier"]])))
		XCTAssertNil(SwitchBackScheme.scheme(in: [:]))
	}

	func testGivesACopyItsOwnAndLeavesTheRest() {
		let atelier = info(["com.atelier.app.source": ["atelier", "altstore"], SwitchBackScheme.urlTypeName: ["atelier-com.atelier.app"]])
		let copy = SwitchBackScheme.apply(bundleID: "com.atelier.app.atelier2", to: atelier)
		XCTAssertEqual(SwitchBackScheme.scheme(in: copy), "atelier-com.atelier.app.atelier2")
		let types = copy["CFBundleURLTypes"] as? [[String: Any]]
		XCTAssertEqual(types?.map { $0["CFBundleURLSchemes"] as? [String] ?? [] }, [["atelier", "altstore"], ["atelier-com.atelier.app.atelier2"]])

		// Another app, or an Atelier before it, gets none.
		let other = info(["com.example.app": ["example"]])
		XCTAssertEqual(SwitchBackScheme.apply(bundleID: "com.example.app.atelier2", to: other) as NSDictionary, other as NSDictionary)
	}
}
