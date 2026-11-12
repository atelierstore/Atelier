import Foundation
import XCTest
@testable import InstallKit

final class InstallCheckTests: XCTestCase {
	func testAddsItsSchemeInATypeOfItsOwn() {
		let info: [String: Any] = [
			"CFBundleIdentifier": "com.example.app",
			"CFBundleURLTypes": [["CFBundleURLName": "app", "CFBundleURLSchemes": ["example"]]],
		]
		let updated = InstallCheck.apply("atelier-check-3", to: info)
		let types = updated["CFBundleURLTypes"] as? [[String: Any]]
		XCTAssertEqual(types?.count, 2)
		XCTAssertEqual(types?[0]["CFBundleURLSchemes"] as? [String], ["example"])
		XCTAssertEqual(types?[1]["CFBundleURLName"] as? String, InstallCheck.urlTypeName)
		XCTAssertEqual(types?[1]["CFBundleURLSchemes"] as? [String], ["atelier-check-3"])
		XCTAssertEqual(updated["CFBundleIdentifier"] as? String, "com.example.app")
	}

	func testReplacesAnOldSchemeAndKeepsTheAppsOwn() {
		let info: [String: Any] = [
			"CFBundleURLTypes": [
				["CFBundleURLSchemes": ["example", "atelier-check-1"]],
				["CFBundleURLName": InstallCheck.urlTypeName, "CFBundleURLSchemes": ["atelier-check-2"]],
				["CFBundleURLName": "no schemes"],
			],
		]
		let types = InstallCheck.apply("atelier-check-5", to: info)["CFBundleURLTypes"] as? [[String: Any]]
		XCTAssertEqual(types?.map { $0["CFBundleURLSchemes"] as? [String] ?? [] }, [["example"], [], ["atelier-check-5"]])
	}

	func testNilOnlyRemoves() {
		let info: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["Atelier-Check-4"]]]]
		XCTAssertNil(InstallCheck.apply(nil, to: info)["CFBundleURLTypes"])
	}

	func testFreeSchemeSkipsRegisteredOnes() {
		let taken: Set = ["atelier-check-1", "atelier-check-2"]
		XCTAssertEqual(InstallCheck.freeScheme { taken.contains($0) }, "atelier-check-3")
		XCTAssertNil(InstallCheck.freeScheme { _ in true })
	}

	/// Nuvio's re-sign took the scheme offloaded Bazaart still held, which
	/// then read as installed (12 Nov 2026).
	func testFreeSchemeLeavesHeldAndOffloadedOnes() {
		let taken: Set = ["atelier-check-1"]
		let isRegistered = { (scheme: String) in taken.contains(scheme) }
		// A deleted app's entry holds 2, an offloaded app's 3: 4 comes first.
		XCTAssertEqual(InstallCheck.freeScheme(isRegistered: isRegistered, held: ["atelier-check-2", "atelier-check-3"], kept: ["atelier-check-3"]), "atelier-check-4")
		// With every other scheme held, a deleted app's goes, never an offloaded one's.
		let others = Set(InstallCheck.schemes.dropFirst(3))
		XCTAssertEqual(InstallCheck.freeScheme(isRegistered: isRegistered, held: others.union(["atelier-check-2", "atelier-check-3"]), kept: ["atelier-check-3"]), "atelier-check-2")
		XCTAssertNil(InstallCheck.freeScheme(isRegistered: { $0 != "atelier-check-3" }, kept: ["atelier-check-3"]))
	}

	func testFindsTheSchemeAnAppCarries() {
		XCTAssertEqual(InstallCheck.scheme(of: IPAInfo(bundleID: "a", version: "1", name: "A", urlSchemes: ["fb123", "atelier-check-9"])), "atelier-check-9")
		XCTAssertNil(InstallCheck.scheme(of: IPAInfo(bundleID: "a", version: "1", name: "A", urlSchemes: ["atelier-check-99"])))
	}

	func testIPAInfoReadsURLSchemes() throws {
		let plist: [String: Any] = [
			"CFBundleIdentifier": "com.example.app",
			"CFBundleURLTypes": [["CFBundleURLSchemes": ["one", "two"]], ["CFBundleURLSchemes": ["atelier-check-1"]]],
		]
		let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
		XCTAssertEqual(try IPAInfo.parse(infoPlist: data).urlSchemes, ["one", "two", "atelier-check-1"])
	}

	/// canOpenURL answers only for schemes the app declares, so project.yml
	/// must list exactly these, and iOS 27 allows 25 at most.
	func testTheAppDeclaresEveryCheckScheme() throws {
		let projectYML = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("project.yml")
		let text = try String(contentsOf: projectYML, encoding: .utf8)
		let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("LSApplicationQueriesSchemes:") })
		let list = try XCTUnwrap(line.split(separator: "[").last?.split(separator: "]").first)
		let declared = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
		// Plus localdevvpn, which direct installs ask about (#9).
		XCTAssertEqual(declared.filter { $0 != "localdevvpn" }, InstallCheck.schemes)
		XCTAssertLessThanOrEqual(declared.count, 25)
	}
}

final class RouteBInstallCheckTests: XCTestCase {
	let start = Date(timeIntervalSince1970: 1_000_000)

	func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

	private func sentTracker() -> RouteBTracker {
		var tracker = RouteBTracker(startedAt: start, checksInstall: true)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(2))
		return tracker
	}

	/// Oxford Dictionary's run: progress for a few seconds, then the scheme.
	func testSchemeAfterProgressConfirms() {
		var tracker = sentTracker()
		tracker.systemProgress(0.62, at: at(2.5))
		tracker.installCheck(registered: true, at: at(3))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.62), "doesn't count while iOS's progress shows")
		tracker.systemProgress(nil, at: at(8))
		tracker.installCheck(registered: true, at: at(8))
		XCTAssertEqual(tracker.phase, .finished(.installed(signal: "install check")))
	}

	/// The unsigned spike's run: progress gone in 0.3 s, and nothing answers.
	func testSilenceAfterProgressMeansNotInstalled() {
		var tracker = sentTracker()
		tracker.systemProgress(0.6, at: at(2.1))
		tracker.systemProgress(nil, at: at(2.4))
		tracker.installCheck(registered: false, at: at(2.4))
		tracker.tick(at: at(15))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.6), "waits past the 5 s an unchecked install waits")
		tracker.tick(at: at(22.4))
		XCTAssertEqual(tracker.phase, .finished(.notInstalled))
	}

	func testWithoutProgressTheSchemeStillConfirms() {
		var tracker = sentTracker()
		tracker.tick(at: at(100))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil), "doesn't give up at 90 s like an unchecked install")
		tracker.installCheck(registered: true, at: at(120))
		XCTAssertEqual(tracker.phase, .finished(.installed(signal: "install check")))
	}

	func testWithoutProgressSilenceEndsAtTheLimit() {
		var tracker = sentTracker()
		tracker.tick(at: at(302))
		XCTAssertEqual(tracker.phase, .finished(.notInstalled))
	}

	func testProgressStillShowingAtTheLimitStaysUnknown() {
		var tracker = sentTracker()
		tracker.systemProgress(0.7, at: at(3))
		tracker.tick(at: at(302))
		XCTAssertEqual(tracker.phase, .finished(.probablyInstalled))
	}

	func testSchemeBeforeTheIPAIsSentDoesNotCount() {
		var tracker = RouteBTracker(startedAt: start, checksInstall: true)
		tracker.installCheck(registered: true, at: at(1))
		XCTAssertEqual(tracker.phase, .waitingForApproval)
	}

	func testWithoutTheCheckNothingChanges() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(2))
		tracker.installCheck(registered: true, at: at(3))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil))
		tracker.systemProgress(0.6, at: at(3))
		tracker.systemProgress(nil, at: at(4))
		tracker.tick(at: at(9))
		XCTAssertEqual(tracker.phase, .finished(.probablyInstalled))
	}
}
