import InstallKit
@testable import AtelierCore
import XCTest

final class BackgroundRoundTests: XCTestCase {
	private let delta = IPAInfo(bundleID: "com.rileytestut.Delta", version: "1.8", name: "Delta")

	private func updates(_ names: String...) -> BackgroundRound {
		var round = BackgroundRound()
		for name in names { round.add(id: name, name: name, isUpdate: true) }
		return round
	}

	func testTitleNamesOneAppAndCountsSeveral() {
		XCTAssertEqual(updates("Delta").title, "Updating Delta")
		XCTAssertEqual(updates("Delta", "EeveeSpotify", "YTLite").title, "Updating 3 apps")
		var mixed = updates("Delta")
		mixed.add(id: "new", name: "YTLite", isUpdate: false)
		XCTAssertEqual(mixed.title, "Installing 2 apps")
	}

	func testSubtitleSaysTheAppTheStepAndWhichOne() {
		var round = updates("Delta", "EeveeSpotify", "YTLite")
		XCTAssertEqual(round.subtitle(stage: nil), "Starting")
		round.start(id: "Delta")
		XCTAssertEqual(round.subtitle(stage: .downloading(0.15), bytes: (18_000_000, 120_000_000)), "Delta: downloading, 18 of 120 MB (1 of 3)")
		XCTAssertEqual(round.subtitle(stage: .signing(.signing)), "Delta: signing (1 of 3)")
		XCTAssertEqual(round.subtitle(stage: .installing(delta, .downloading(fraction: 0.35))), "Delta: uploading, 35% (1 of 3)")
		round.end(id: "Delta", .installed)
		round.start(id: "EeveeSpotify")
		XCTAssertEqual(round.subtitle(stage: .installing(delta, .installing(fraction: nil))), "EeveeSpotify: installing (2 of 3)")

		var one = updates("Delta")
		one.start(id: "Delta")
		XCTAssertEqual(one.subtitle(stage: .installing(delta, .downloading(fraction: 0.35)), bytes: (42_000_000, 120_000_000)), "Delta: uploading, 42 of 120 MB")
	}

	func testSubtitleSaysWhenAnAppsDataIsCopiedAndPutBack() {
		var round = BackgroundRound()
		round.add(id: "Delta", name: "Delta", isUpdate: false, isResign: true)
		round.start(id: "Delta")
		XCTAssertEqual(round.subtitle(stage: .installing(delta, .copyingData(fraction: nil))), "Delta: copying its data")
		XCTAssertEqual(round.subtitle(stage: .installing(delta, .copyingData(fraction: 0.4))), "Delta: copying its data, 40%")
		XCTAssertEqual(round.subtitle(stage: .installing(delta, .restoringData(fraction: 0.75))), "Delta: putting its data back, 75%")
	}

	func testBetweenTwoAppsTheBarSaysHowTheLastEnded() {
		var round = updates("Delta", "YTLite")
		round.start(id: "Delta")
		round.end(id: "Delta", .installed)
		// Not "Starting", until the next one starts.
		XCTAssertEqual(round.title, "Updating 2 apps")
		XCTAssertEqual(round.subtitle(stage: nil), "Delta: installed (1 of 2)")
		round.start(id: "YTLite")
		XCTAssertEqual(round.subtitle(stage: .checking), "YTLite: checking (2 of 2)")
	}

	func testTheBarEndsOnHowTheRoundWent() {
		var round = updates("Delta", "YTLite")
		round.start(id: "Delta")
		round.end(id: "Delta", .installed)
		XCTAssertFalse(round.isOver)
		round.start(id: "YTLite")
		round.end(id: "YTLite", .installed)
		XCTAssertTrue(round.isOver)
		XCTAssertEqual(round.title, "2 apps updated")
		XCTAssertEqual(round.subtitle(stage: nil), "Delta and YTLite are up to date")

		var failed = updates("Delta", "YTLite")
		failed.end(id: "Delta", .installed)
		failed.end(id: "YTLite", .failed("LocalDevVPN disconnected"))
		XCTAssertEqual(failed.title, "1 app updated, 1 didn't")
		// What to do next is the notification's.
		XCTAssertEqual(failed.subtitle(stage: nil), "YTLite: LocalDevVPN disconnected")

		// Nothing to say when all were cancelled: the last line stays.
		var cancelled = updates("Delta")
		cancelled.start(id: "Delta")
		cancelled.end(id: "Delta", .cancelled)
		XCTAssertEqual(cancelled.title, "Updating Delta")
		XCTAssertEqual(cancelled.subtitle(stage: nil), "Delta: cancelled")
	}

	func testProgressCountsEndedAppsAndTheRunningOnesStage() {
		var round = updates("Delta", "YTLite")
		XCTAssertEqual(round.progress(stage: nil).total, 2000)
		round.start(id: "Delta")
		XCTAssertEqual(round.progress(stage: .downloading(0.5)).completed, 300)
		// Never full before the app has ended.
		XCTAssertEqual(round.progress(stage: .finished(delta, .confirmed(version: "1.8"))).completed, 990)
		round.end(id: "Delta", .installed)
		round.start(id: "YTLite")
		XCTAssertEqual(round.progress(stage: .checking).completed, 1000)
		round.end(id: "YTLite", .installed)
		XCTAssertEqual(round.progress(stage: nil).completed, 2000)
	}

	func testRemovingAWaitingAppShrinksTheRound() {
		var round = updates("Delta", "YTLite")
		round.start(id: "Delta")
		round.remove(id: "YTLite")
		round.remove(id: "Delta")
		XCTAssertEqual(round.entries.map(\.name), ["Delta"])
	}

	/// The user answered what the running install asked with another
	/// install, which takes its place: Install as a Copy, or Delete and
	/// Install, which keeps its id (#99).
	func testARunningAppCanGiveWayToAnother() {
		var round = updates("Delta", "YTLite")
		round.start(id: "YTLite")
		round.drop(id: "YTLite")
		XCTAssertNil(round.currentID)
		XCTAssertEqual(round.entries.map(\.name), ["Delta"])
		round.add(id: "YTLite", name: "YTLite", isUpdate: true)
		round.start(id: "YTLite")
		round.end(id: "YTLite", .installed)
		round.end(id: "Delta", .installed)
		XCTAssertEqual(round.entries.count, 2)
		XCTAssertEqual(round.summary?.title, "2 apps updated")
	}

	func testSummaryWhenAllInstalled() {
		var round = updates("Delta", "EeveeSpotify", "YTLite")
		for name in ["Delta", "EeveeSpotify", "YTLite"] { round.end(id: name, .installed) }
		XCTAssertEqual(round.summary, .init(title: "3 apps updated", body: "Delta, EeveeSpotify and YTLite are up to date."))

		var one = BackgroundRound()
		one.add(id: "a", name: "Delta", isUpdate: false)
		one.end(id: "a", .installed)
		XCTAssertEqual(one.summary, .init(title: "Delta installed", body: "Delta is ready to open."))
	}

	func testSummaryOfAnAutomaticRound() {
		var round = BackgroundRound()
		round.isAutomatic = true
		round.add(id: "Delta", name: "Delta", isUpdate: true, version: "1.8")
		round.add(id: "YTLite", name: "YTLite", isUpdate: true, version: "5.3")
		round.end(id: "Delta", .installed)
		round.end(id: "YTLite", .installed)
		XCTAssertEqual(round.summary, .init(title: "Updated in the background", body: "Delta 1.8 and YTLite 5.3 were installed."))

		// A failure reads as in any other round.
		round.add(id: "YTLite", name: "YTLite", isUpdate: true, version: "5.3")
		round.end(id: "YTLite", .failed("No Wi-Fi."))
		XCTAssertEqual(round.summary?.title, "1 app updated, 1 didn't")
	}

	func testSummaryWhenOneFailed() {
		var round = updates("Delta", "EeveeSpotify", "YTLite")
		round.end(id: "Delta", .installed)
		round.end(id: "EeveeSpotify", .installed)
		round.end(id: "YTLite", .failed("LocalDevVPN disconnected"))
		XCTAssertEqual(round.summary, .init(title: "2 apps updated, 1 didn't", body: "YTLite: LocalDevVPN disconnected. Open Atelier to try again."))
	}

	func testSummaryWhenAllFailedOrCancelled() {
		var round = updates("Delta", "YTLite")
		round.end(id: "Delta", .failed("No Wi-Fi."))
		round.end(id: "YTLite", .failed("No Wi-Fi."))
		XCTAssertEqual(round.summary, .init(title: "2 apps weren't updated", body: "Delta and YTLite didn't install. Open Atelier to try again."))

		var cancelled = updates("Delta")
		cancelled.end(id: "Delta", .cancelled)
		XCTAssertNil(cancelled.summary)
	}

	func testPausedSaysWhatsDoneAndWhatsLeft() {
		var round = updates("Accountit", "Across")
		XCTAssertEqual(round.paused, .init(title: "Updates paused", body: "Open Atelier to finish updating Accountit and Across."))
		round.start(id: "Accountit")
		round.end(id: "Accountit", .installed)
		round.start(id: "Across")
		XCTAssertEqual(round.paused, .init(title: "Updates paused", body: "Accountit is up to date. Open Atelier to finish updating Across."))
		round.end(id: "Across", .installed)
		XCTAssertNil(round.paused)

		var failed = updates("YTLite", "Delta")
		failed.end(id: "YTLite", .failed("No Wi-Fi."))
		XCTAssertEqual(failed.paused?.body, "YTLite didn't install. Open Atelier to finish updating Delta.")

		var new = BackgroundRound()
		new.add(id: "a", name: "Delta", isUpdate: false)
		XCTAssertEqual(new.paused, .init(title: "Installs paused", body: "Open Atelier to finish installing Delta."))
	}

	func testPausedNamesAnAppQueuedAgainOnlyAsLeft() {
		var round = updates("Across")
		round.end(id: "Across", .installed)
		round.add(id: "Across 1.12.8", name: "Across", isUpdate: true)
		XCTAssertEqual(round.paused?.body, "Open Atelier to finish updating Across.")
	}

	/// Re-sign All, after a certificate died (#20).
	private func resigns(_ names: String...) -> BackgroundRound {
		var round = BackgroundRound()
		for name in names { round.add(id: name, name: name, isUpdate: false, isResign: true) }
		return round
	}

	func testAReSignRoundSaysSo() {
		XCTAssertEqual(resigns("Delta").title, "Re-signing Delta")
		var round = resigns("Delta", "YTLite", "Radiance")
		XCTAssertEqual(round.title, "Re-signing 3 apps")
		XCTAssertEqual(round.paused, .init(title: "Re-signing paused", body: "Open Atelier to finish re-signing Delta, YTLite and Radiance."))
		round.end(id: "Delta", .installed)
		round.end(id: "YTLite", .failed("No Wi-Fi."))
		XCTAssertEqual(round.paused?.body, "Delta is ready to open. YTLite didn't re-sign. Open Atelier to finish re-signing Radiance.")
		round.end(id: "Radiance", .installed)
		XCTAssertEqual(round.summary, .init(title: "2 apps re-signed, 1 didn't", body: "YTLite: No Wi-Fi. Open Atelier to try again."))

		var done = resigns("Delta", "YTLite")
		done.end(id: "Delta", .installed)
		done.end(id: "YTLite", .installed)
		XCTAssertEqual(done.summary, .init(title: "2 apps re-signed", body: "Delta and YTLite are ready to open."))

		var failed = resigns("Delta", "YTLite")
		failed.end(id: "Delta", .failed("No Wi-Fi."))
		failed.end(id: "YTLite", .failed("No Wi-Fi."))
		XCTAssertEqual(failed.summary, .init(title: "2 apps weren't re-signed", body: "Delta and YTLite didn't re-sign. Open Atelier to try again."))

		// With an update queued too, it's installing.
		var mixed = resigns("Delta")
		mixed.add(id: "YTLite", name: "YTLite", isUpdate: true)
		XCTAssertEqual(mixed.title, "Installing 2 apps")
	}

	func testTryingAgainReplacesTheFailedTry() {
		var round = updates("Delta")
		round.end(id: "Delta", .failed("No Wi-Fi."))
		round.add(id: "Delta", name: "Delta", isUpdate: true)
		round.end(id: "Delta", .installed)
		XCTAssertEqual(round.entries.count, 1)
		XCTAssertEqual(round.summary?.title, "Delta updated")
	}
}
