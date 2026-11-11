import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import InstallKit

final class RouteBTrackerTests: XCTestCase {
	let start = Date(timeIntervalSince1970: 1_000_000)

	func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

	/// The spike's successful runs: HEADs, one GET, progress stuck at 62%, then gone.
	func testSpikeLikeSuccessEndsProbablyInstalled() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.tick(at: at(5))
		XCTAssertEqual(tracker.phase, .waitingForApproval)

		tracker.requestSeen(at: at(6))
		tracker.requestSeen(at: at(6.2))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0))
		tracker.payloadProgress(sent: 50, total: 100, at: at(7))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0.5))
		tracker.systemProgress(0.1, at: at(7))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0.5), "iOS's progress doesn't move the download phase")

		tracker.payloadEnded(complete: true, at: at(8))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil))
		tracker.systemProgress(0.62, at: at(9))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.62))
		tracker.tick(at: at(20))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.62))

		tracker.systemProgress(nil, at: at(25))
		tracker.tick(at: at(27))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.62), "waits for a late signal")
		tracker.tick(at: at(30))
		XCTAssertEqual(tracker.phase, .finished(.probablyInstalled))
	}

	func testConfirmingSignalAfterPayloadMeansInstalled() {
		let name = "com.example.installed"
		var tracker = RouteBTracker(startedAt: start, confirmingSignals: [name])
		tracker.systemSignal(name, at: at(1))
		XCTAssertEqual(tracker.phase, .waitingForApproval, "a signal before iOS has the IPA isn't ours")

		tracker.requestSeen(at: at(2))
		tracker.payloadEnded(complete: true, at: at(3))
		tracker.systemSignal("com.example.other", at: at(4))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil))
		tracker.systemSignal(name, at: at(5))
		XCTAssertEqual(tracker.phase, .finished(.installed(signal: name)))
		XCTAssertEqual(tracker.signals.map(\.name), [name, "com.example.other", name])
	}

	func testUnlistedSignalIsOnlyRecorded() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(2))
		tracker.systemSignal("com.apple.mobile.application_installed", at: at(3))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil))
		XCTAssertEqual(tracker.signals.first?.after, 3)
	}

	func testNoRequestMeansNotStarted() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.tick(at: at(179))
		XCTAssertEqual(tracker.phase, .waitingForApproval)
		tracker.tick(at: at(180))
		XCTAssertEqual(tracker.phase, .alertClosed, "the time limit offers Try again too")
		tracker.tick(at: at(779))
		XCTAssertEqual(tracker.phase, .alertClosed)
		tracker.tick(at: at(780))
		XCTAssertEqual(tracker.phase, .finished(.notStarted))
		tracker.requestSeen(at: at(781))
		XCTAssertEqual(tracker.phase, .finished(.notStarted), "finished stays finished")
	}

	/// #51: Cancel in the alert, inferred from Atelier coming back to the
	/// front with no request for the IPA.
	func testBackInFrontWithoutRequestMeansAlertClosed() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.appBecameActive(at: at(0.5))
		tracker.tick(at: at(4))
		XCTAssertEqual(tracker.phase, .waitingForApproval, "active without having left isn't the alert closing")

		tracker.appResignedActive(at: at(1))
		tracker.appBecameActive(at: at(6))
		tracker.tick(at: at(8.9))
		XCTAssertEqual(tracker.phase, .waitingForApproval)
		tracker.tick(at: at(9))
		XCTAssertEqual(tracker.phase, .alertClosed)
	}

	func testInstallTappedAsksForTheIPABeforeTheGraceEnds() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.appResignedActive(at: at(1))
		tracker.appBecameActive(at: at(3))
		tracker.requestSeen(at: at(4))
		tracker.tick(at: at(10))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0))
	}

	func testLateRequestAfterAlertClosedStillInstalls() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.appResignedActive(at: at(1))
		tracker.appBecameActive(at: at(2))
		tracker.tick(at: at(5))
		XCTAssertEqual(tracker.phase, .alertClosed)
		tracker.requestSeen(at: at(6))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0))
	}

	func testRetryWaitsForTheAlertAgain() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.appResignedActive(at: at(1))
		tracker.appBecameActive(at: at(2))
		tracker.tick(at: at(5))
		XCTAssertEqual(tracker.phase, .alertClosed)

		tracker.retry(at: at(100))
		XCTAssertEqual(tracker.phase, .waitingForApproval)
		tracker.appBecameActive(at: at(101))
		tracker.tick(at: at(110))
		XCTAssertEqual(tracker.phase, .waitingForApproval, "the first visit away doesn't count after a retry")
		tracker.tick(at: at(279))
		XCTAssertEqual(tracker.phase, .waitingForApproval, "the time limit restarts")
		tracker.tick(at: at(280))
		XCTAssertEqual(tracker.phase, .alertClosed)
	}

	func testGivingUpEndsNotStarted() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.tick(at: at(180))
		tracker.giveUp()
		XCTAssertEqual(tracker.phase, .finished(.notStarted))

		var downloading = RouteBTracker(startedAt: start)
		downloading.requestSeen(at: at(1))
		downloading.giveUp()
		XCTAssertEqual(downloading.phase, .downloading(fraction: 0), "only an install waiting for the alert can be given up")
	}

	func testBrokenDownloadFailsUnlessIOSComesBack() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: false, at: at(2))
		tracker.tick(at: at(50))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0))
		tracker.requestSeen(at: at(55))
		tracker.tick(at: at(100))
		XCTAssertEqual(tracker.phase, .downloading(fraction: 0), "a new request resets the clock")
		tracker.tick(at: at(115))
		XCTAssertEqual(tracker.phase, .finished(.downloadFailed))
	}

	func testOnlyHeadRequestsStallIntoDownloadFailed() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.tick(at: at(60.9))
		XCTAssertFalse(tracker.phase.isFinished)
		tracker.tick(at: at(61))
		XCTAssertEqual(tracker.phase, .finished(.downloadFailed))
	}

	func testNoSystemProgressFallsBackAfterTimeout() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(10))
		tracker.systemProgress(nil, at: at(11))
		tracker.tick(at: at(99))
		XCTAssertEqual(tracker.phase, .installing(fraction: nil))
		tracker.tick(at: at(100))
		XCTAssertEqual(tracker.phase, .finished(.probablyInstalled))
	}

	func testStuckSystemProgressStopsAtTheLimit() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(10))
		tracker.systemProgress(0.7, at: at(11))
		tracker.tick(at: at(309))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.7))
		tracker.tick(at: at(310))
		XCTAssertEqual(tracker.phase, .finished(.probablyInstalled))
	}

	func testProgressThatComesBackIsNotGone() {
		var tracker = RouteBTracker(startedAt: start)
		tracker.requestSeen(at: at(1))
		tracker.payloadEnded(complete: true, at: at(2))
		tracker.systemProgress(0.3, at: at(3))
		tracker.systemProgress(nil, at: at(4))
		tracker.systemProgress(0.5, at: at(5))
		tracker.tick(at: at(12))
		XCTAssertEqual(tracker.phase, .installing(fraction: 0.5))
	}
}

final class ManifestEndpointTests: XCTestCase {
	func testEmptyMeansDefault() {
		XCTAssertEqual(try ManifestEndpoint.resolve("").get(), ManifestEndpoint.defaultURL)
		XCTAssertEqual(try ManifestEndpoint.resolve("  \n").get(), ManifestEndpoint.defaultURL)
		XCTAssertEqual(ManifestEndpoint.defaultURL.scheme, "https")
	}

	func testOwnEndpoint() {
		XCTAssertEqual(
			try ManifestEndpoint.resolve(" https://m.example.workers.dev/manifest ").get(),
			URL(string: "https://m.example.workers.dev/manifest")!
		)
	}

	/// Atelier's install of itself waits on `/relaunch` next to the
	/// manifest (#24).
	func testRelaunchIsNextToTheManifest() {
		XCTAssertEqual(ManifestEndpoint.relaunchURL(for: ManifestEndpoint.defaultURL, delay: 15), URL(string: "https://api.atelierstore.app/relaunch?delay=15"))
		XCTAssertEqual(ManifestEndpoint.relaunchURL(for: URL(string: "https://m.example:8443/atelier/genPlist?x=1")!, delay: 20), URL(string: "https://m.example:8443/atelier/relaunch?delay=20"))
		XCTAssertEqual(ManifestEndpoint.relaunchURL(for: URL(string: "https://m.example")!, delay: 15), URL(string: "https://m.example/relaunch?delay=15"))
	}

	func testRejectsNonHTTPS() {
		XCTAssertEqual(ManifestEndpoint.resolve("http://m.example/manifest"), .failure(.notHTTPS))
		XCTAssertEqual(ManifestEndpoint.resolve("m.example/manifest"), .failure(.notAURL))
		XCTAssertEqual(ManifestEndpoint.resolve("https:///manifest"), .failure(.noHost))
	}

	func testReachabilityFromStatus() {
		// The worker answers a request with no app with 400.
		XCTAssertEqual(ManifestEndpoint.reachability(status: 400), .reachable)
		XCTAssertEqual(ManifestEndpoint.reachability(status: 200), .reachable)
		XCTAssertEqual(ManifestEndpoint.reachability(status: 404), .unexpected(status: 404))
		XCTAssertEqual(ManifestEndpoint.reachability(status: 503), .unexpected(status: 503))
	}

	func testCheckSendsAHead() async {
		let url = ManifestEndpoint.defaultURL
		let result = await ManifestEndpoint.check(url) { request in
			XCTAssertEqual(request.httpMethod, "HEAD")
			XCTAssertEqual(request.url, url)
			return (Data(), HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
		}
		XCTAssertEqual(result, .reachable)
	}

	func testCheckOffline() async {
		let result = await ManifestEndpoint.check(ManifestEndpoint.defaultURL) { _ in
			throw URLError(.notConnectedToInternet)
		}
		guard case .unreachable = result else { return XCTFail("\(result)") }
	}
}
