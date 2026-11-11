import Foundation
import XCTest
@testable import InstallKit

@MainActor
final class MockInstaller: Installer {
	let route: InstallRoute
	var health: RouteHealth
	private(set) var healthChecks = 0
	private(set) var installed: [String] = []
	/// Thrown by the install, when set.
	var failure: InstallFailure?

	init(_ route: InstallRoute, health: RouteHealth = .ready) {
		self.route = route
		self.health = health
	}

	func healthCheck() async -> RouteHealth {
		healthChecks += 1
		return health
	}

	func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		if let failure { throw failure }
		installed.append(package.info.bundleID)
		return .confirmed(version: package.info.version)
	}
}

@MainActor
final class RouteSelectorTests: XCTestCase {
	func testAutomaticPrefersAHealthyPairingRoute() async throws {
		let a = MockInstaller(.pairing), b = MockInstaller(.localServer)
		let chosen = try await RouteSelector.select(.automatic, from: [b, a])
		XCTAssertTrue(chosen === a)
		XCTAssertEqual(b.healthChecks, 0)
	}

	func testAutomaticFallsBackToTheLocalServer() async throws {
		let a = MockInstaller(.pairing, health: .unavailable("The VPN is off."))
		let b = MockInstaller(.localServer)
		let chosen = try await RouteSelector.select(.automatic, from: [a, b])
		XCTAssertTrue(chosen === b)
	}

	/// Today's app: route B only.
	func testAutomaticWithOnlyTheLocalServer() async throws {
		let b = MockInstaller(.localServer)
		let chosen = try await RouteSelector.select(.automatic, from: [b])
		XCTAssertTrue(chosen === b)
	}

	/// Route B's reason only: it's the one that works out of the box, and
	/// route A being out of reach is routine.
	func testAutomaticWithNothingHealthyGivesTheFallbacksReason() async {
		let a = MockInstaller(.pairing, health: .unavailable("No pairing file."))
		let b = MockInstaller(.localServer, health: .unavailable("Bad endpoint."))
		do {
			_ = try await RouteSelector.select(.automatic, from: [a, b])
			XCTFail("expected Unavailable")
		} catch let error as RouteSelector.Unavailable {
			XCTAssertEqual(error, RouteSelector.Unavailable(route: nil, reason: "Bad endpoint."))
			XCTAssertEqual(error.description, "Bad endpoint.")
		} catch {
			XCTFail("\(error)")
		}
	}

	func testAnUnavailableRouteSaysWhichWithoutAnInstallMethod() {
		// Route A's reasons say what the install needs, on their own.
		XCTAssertEqual(RouteSelector.Unavailable(route: .pairing, reason: "The VPN is off.").description, "The VPN is off.")
		XCTAssertEqual(RouteSelector.Unavailable(route: .localServer, reason: "Bad endpoint.").description, "iOS's install alert can't be used right now: Bad endpoint.")
	}

	func testAPickedRouteIsUsedEvenWhenTheOtherIsHealthy() async throws {
		let a = MockInstaller(.pairing), b = MockInstaller(.localServer)
		let chosen = try await RouteSelector.select(.localServer, from: [a, b])
		XCTAssertTrue(chosen === b)
		XCTAssertEqual(a.healthChecks, 0)
	}

	func testAPickedRouteThatIsUnhealthyDoesNotFallBack() async {
		let a = MockInstaller(.pairing, health: .unavailable("The VPN is off."))
		let b = MockInstaller(.localServer)
		do {
			_ = try await RouteSelector.select(.pairing, from: [a, b])
			XCTFail("expected Unavailable")
		} catch let error as RouteSelector.Unavailable {
			XCTAssertEqual(error, RouteSelector.Unavailable(route: .pairing, reason: "The VPN is off."))
		} catch {
			XCTFail("\(error)")
		}
		XCTAssertEqual(b.healthChecks, 0)
	}

	func testAPickedRouteThatDoesNotExist() async {
		do {
			_ = try await RouteSelector.select(.pairing, from: [MockInstaller(.localServer)])
			XCTFail("expected Unavailable")
		} catch let error as RouteSelector.Unavailable {
			XCTAssertEqual(error.route, .pairing)
		} catch {
			XCTFail("\(error)")
		}
	}
}

/// Deleting an app iOS won't replace right before installing it (#20).
@MainActor
final class ReplacingInstallerTests: XCTestCase {
	private let package = InstallPackage(url: URL(fileURLWithPath: "/tmp/radiance.ipa"), info: IPAInfo(bundleID: "com.example.radiance", version: "3.0.1", name: "Radiance"))

	func testDeletesTheAppThenInstalls() async throws {
		let base = MockInstaller(.pairing)
		var order: [String] = []
		var lines: [String] = []
		let installer = ReplacingInstaller(base) { bundleID in
			XCTAssertTrue(base.installed.isEmpty, "deleted before the install")
			order.append("delete \(bundleID)")
			return nil
		}
		XCTAssertEqual(installer.route, .pairing)
		let result = try await installer.install(package) { event in
			if case .log(let line) = event { lines.append(line) }
		}
		order += base.installed.map { "install \($0)" }
		XCTAssertEqual(order, ["delete com.example.radiance", "install com.example.radiance"])
		XCTAssertEqual(result, .confirmed(version: "3.0.1"))
		XCTAssertTrue(lines.first?.hasPrefix("deleting com.example.radiance first") ?? false, "\(lines)")
	}

	func testAFailedDeleteInstallsNothingAndSaysWhy() async {
		let base = MockInstaller(.pairing)
		let installer = ReplacingInstaller(base) { _ in "LocalDevVPN isn't connected." }
		do {
			_ = try await installer.install(package) { _ in }
			XCTFail("expected a failure")
		} catch let failure as InstallFailure {
			XCTAssertEqual(failure, .couldNotStart("Couldn't delete Radiance first: LocalDevVPN isn't connected."))
		} catch {
			XCTFail("\(error)")
		}
		XCTAssertTrue(base.installed.isEmpty)
	}

	func testHealthIsTheRoutesOwn() async {
		let base = MockInstaller(.pairing, health: .unavailable("No pairing file."))
		let installer = ReplacingInstaller(base) { _ in nil }
		let health = await installer.healthCheck()
		XCTAssertEqual(health, .unavailable("No pairing file."))
		XCTAssertEqual(base.healthChecks, 1)
	}
}

struct TestJob: Identifiable {
	var id: String
}

@MainActor
final class InstallQueueTests: XCTestCase {
	func testRunsJobsOneAtATimeInOrder() async {
		var log: [String] = []
		var running = 0
		let queue = InstallQueue<TestJob> { job in
			running += 1
			XCTAssertEqual(running, 1, "only one job at a time")
			log.append("start \(job.id)")
			try? await Task.sleep(nanoseconds: 10_000_000)
			log.append("end \(job.id)")
			running -= 1
		}
		queue.enqueue(TestJob(id: "a"))
		queue.enqueue(TestJob(id: "b"))
		queue.enqueue(TestJob(id: "c"))
		XCTAssertEqual(queue.pending.map(\.id), ["a", "b", "c"])
		await queue.waitUntilEmpty()
		XCTAssertEqual(log, ["start a", "end a", "start b", "end b", "start c", "end c"])
		XCTAssertTrue(queue.isEmpty)
	}

	func testIgnoresAJobAlreadyQueuedOrRunning() async {
		var ran: [String] = []
		let queue = InstallQueue<TestJob> { job in
			ran.append(job.id)
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTAssertTrue(queue.enqueue(TestJob(id: "a")))
		XCTAssertTrue(queue.enqueue(TestJob(id: "b")))
		XCTAssertFalse(queue.enqueue(TestJob(id: "b")))
		await Task.yield()
		XCTAssertEqual(queue.current?.id, "a")
		XCTAssertFalse(queue.enqueue(TestJob(id: "a")), "a is running")
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "b"])
	}

	func testRemovingAWaitingJob() async {
		var ran: [String] = []
		let queue = InstallQueue<TestJob> { job in
			ran.append(job.id)
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		queue.enqueue(TestJob(id: "a"))
		queue.enqueue(TestJob(id: "b"))
		queue.enqueue(TestJob(id: "c"))
		queue.remove("b")
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "c"])
	}

	func testCancellingTheCurrentJobMovesOn() async {
		var outcomes: [String] = []
		let queue = InstallQueue<TestJob> { job in
			do {
				try await Task.sleep(nanoseconds: job.id == "slow" ? 10_000_000_000 : 1_000_000)
				outcomes.append("\(job.id) done")
			} catch {
				outcomes.append("\(job.id) cancelled")
			}
		}
		queue.enqueue(TestJob(id: "slow"))
		queue.enqueue(TestJob(id: "next"))
		await Task.yield()
		queue.cancelCurrent()
		await queue.waitUntilEmpty()
		XCTAssertEqual(outcomes, ["slow cancelled", "next done"])
	}

	func testCancelAllDropsTheRest() async {
		var outcomes: [String] = []
		let queue = InstallQueue<TestJob> { job in
			do {
				try await Task.sleep(nanoseconds: 10_000_000_000)
				outcomes.append("\(job.id) done")
			} catch {
				outcomes.append("\(job.id) cancelled")
			}
		}
		queue.enqueue(TestJob(id: "a"))
		queue.enqueue(TestJob(id: "b"))
		await Task.yield()
		queue.cancelAll()
		await queue.waitUntilEmpty()
		XCTAssertEqual(outcomes, ["a cancelled"])
	}

	/// Atelier's own update waits behind every other install, also those
	/// queued after it (#24).
	func testJobsThatRunLastWaitBehindLaterOnes() async {
		var ran: [String] = []
		let queue = InstallQueue<TestJob> { job in
			ran.append(job.id)
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		queue.runsLast = { $0.id.hasPrefix("self") }
		queue.enqueue(TestJob(id: "a"))
		queue.enqueue(TestJob(id: "self"))
		queue.enqueue(TestJob(id: "b"))
		queue.enqueue(TestJob(id: "c"))
		XCTAssertEqual(queue.pending.map(\.id), ["a", "b", "c", "self"])
		// Another that runs last goes after it.
		queue.enqueue(TestJob(id: "self-again"))
		queue.enqueue(TestJob(id: "d"))
		XCTAssertEqual(queue.pending.map(\.id), ["a", "b", "c", "d", "self", "self-again"])
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "b", "c", "d", "self", "self-again"])
	}

	/// Atelier's own install, reaching iOS while installs queued after it
	/// wait, goes back behind them rather than close Atelier first (#24).
	func testTheRunningJobCanGoBackBehindLaterOnes() async {
		var ran: [String] = []
		var queue: InstallQueue<TestJob>!
		queue = InstallQueue<TestJob> { job in
			ran.append(job.id)
			if job.id == "self", ran.filter({ $0 == "self" }).count == 1 {
				queue.enqueue(TestJob(id: "a"))
				queue.enqueue(TestJob(id: "b"))
				queue.requeueCurrent()
			}
			try? await Task.sleep(nanoseconds: 1_000_000)
		}
		queue.runsLast = { $0.id == "self" }
		queue.enqueue(TestJob(id: "self"))
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["self", "a", "b", "self"])
		XCTAssertTrue(queue.isEmpty)

		// Only the running job, and only once.
		queue.requeueCurrent()
		queue.enqueue(TestJob(id: "c"))
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["self", "a", "b", "self", "c"])
	}

	/// An install the user's answer turned into another runs next, in its
	/// place, ahead of those waiting, and may keep its id (#99).
	func testAJobCanBeFollowedRightAwayByWhatItTurnedInto() async {
		var ran: [String] = []
		var queue: InstallQueue<TestJob>!
		queue = InstallQueue<TestJob> { job in
			ran.append(job.id)
			if job.id == "a", ran.count == 1 {
				XCTAssertTrue(queue.enqueueNext(TestJob(id: "a")), "the running job's id")
				XCTAssertFalse(queue.enqueueNext(TestJob(id: "a")), "only once")
			}
			try? await Task.sleep(nanoseconds: 1_000_000)
		}
		queue.enqueue(TestJob(id: "a"))
		queue.enqueue(TestJob(id: "b"))
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "a", "b"])

		// It starts the queue when nothing runs.
		XCTAssertTrue(queue.enqueueNext(TestJob(id: "c")))
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "a", "b", "c"])
	}

	func testStartsAgainAfterEmptying() async {
		var ran: [String] = []
		let queue = InstallQueue<TestJob> { ran.append($0.id) }
		queue.enqueue(TestJob(id: "a"))
		await queue.waitUntilEmpty()
		queue.enqueue(TestJob(id: "b"))
		await queue.waitUntilEmpty()
		XCTAssertEqual(ran, ["a", "b"])
	}

	/// Queued installs go through the selected installer one after another.
	func testQueuedInstallsUseTheSelectedRoute() async throws {
		let b = MockInstaller(.localServer)
		var results: [InstallResult] = []
		let queue = InstallQueue<TestJob> { job in
			guard let installer = try? await RouteSelector.select(.automatic, from: [b]) else { return }
			let package = InstallPackage(url: URL(fileURLWithPath: "/tmp/\(job.id).ipa"), info: IPAInfo(bundleID: job.id, version: "1.0", name: job.id))
			if let result = try? await installer.install(package, events: { _ in }) { results.append(result) }
		}
		queue.enqueue(TestJob(id: "com.example.one"))
		queue.enqueue(TestJob(id: "com.example.two"))
		await queue.waitUntilEmpty()
		XCTAssertEqual(b.installed, ["com.example.one", "com.example.two"])
		XCTAssertEqual(results, [.confirmed(version: "1.0"), .confirmed(version: "1.0")])
	}
}

final class InstallHistoryTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func attempt(_ name: String, _ result: InstallAttempt.Result, at seconds: TimeInterval = 0) -> InstallAttempt {
		let date = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
		return InstallAttempt(bundleID: "com.example.\(name)", name: name, version: "1.0", certificate: "Signulous", route: .localServer, startedAt: date, finishedAt: date, result: result, error: result == .failed ? "iOS didn't install the app." : nil, log: ["line"])
	}

	func testKeepsAttemptsNewestFirst() throws {
		let history = InstallHistory(file: folder.appendingPathComponent("history.json"))
		XCTAssertEqual(history.attempts(), [])
		let first = attempt("one", .confirmed)
		let second = attempt("two", .failed, at: 10)
		try history.record(first)
		try history.record(second)
		XCTAssertEqual(history.attempts(), [second, first])
		XCTAssertEqual(history.attempts().first?.route, .localServer)
		XCTAssertEqual(history.attempts().first?.error, "iOS didn't install the app.")
	}

	/// Atelier's install of itself adds to its log after it's recorded
	/// (#24).
	func testChangesAnAttemptInPlace() throws {
		let history = InstallHistory(file: folder.appendingPathComponent("history.json"))
		let first = attempt("one", .confirmed)
		let second = attempt("two", .failed, at: 10)
		try history.record(first)
		try history.record(second)
		try history.update(first.id) { $0.log.append("opened 41 s after closing") }
		XCTAssertEqual(history.attempts().map(\.log), [["line"], ["line", "opened 41 s after closing"]])
		XCTAssertEqual(history.attempts().first, second)

		// One no longer kept stays gone.
		try history.update(UUID()) { $0.log.append("lost") }
		XCTAssertEqual(history.attempts().count, 2)
		XCTAssertFalse(history.attempts().contains { $0.log.contains("lost") })
	}

	func testKeepsOnlyTheLimit() throws {
		let history = InstallHistory(file: folder.appendingPathComponent("history.json"), limit: 2)
		for (index, name) in ["a", "b", "c"].enumerated() {
			try history.record(attempt(name, .unconfirmed, at: Double(index)))
		}
		XCTAssertEqual(history.attempts().map(\.name), ["c", "b"])
	}

	/// Where an attempt came from is kept for Try again (#17), and entries
	/// written before it read with none.
	func testKeepsWhereAnAttemptCameFrom() throws {
		let history = InstallHistory(file: folder.appendingPathComponent("history.json"))
		var fromSource = attempt("one", .failed)
		fromSource.origin = .source(sourceURL: URL(string: "https://example.com/source.json"), appID: "com.example.one|one", version: "1.0", copy: 2, displayName: "One 2", certificateID: nil)
		var picked = attempt("two", .failed, at: 10)
		picked.origin = .picked("ABC.ipa")
		var again = attempt("three", .failed, at: 20)
		again.origin = .signedAgain(bundleID: "com.example.three.2", originalBundleID: "com.example.three", certificateID: UUID())
		try history.record(fromSource)
		try history.record(picked)
		try history.record(again)
		XCTAssertEqual(history.attempts().map(\.origin), [again.origin, picked.origin, fromSource.origin])

		let old = Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","startedAt":"2026-10-01T10:00:00Z","finishedAt":"2026-10-01T10:00:05Z","result":"failed","log":[]}]"#.utf8)
		try old.write(to: history.file)
		XCTAssertEqual(history.attempts().count, 1)
		XCTAssertNil(history.attempts().first?.origin)
		XCTAssertNil(history.attempts().first?.automatic)
	}

	/// A background update says so in Install history (#72).
	func testKeepsWhetherAtelierInstalledItByItself() throws {
		let history = InstallHistory(file: folder.appendingPathComponent("history.json"))
		var automatic = attempt("one", .confirmed)
		automatic.automatic = true
		try history.record(automatic)
		try history.record(attempt("two", .confirmed, at: 10))
		XCTAssertEqual(history.attempts().map(\.automatic), [nil, true])
	}

	/// An install from a source names its version already.
	func testTitleNamesTheVersionOnce() {
		XCTAssertEqual(attempt("Delta", .confirmed).title, "Delta 1.0")
		var fromSource = attempt("Across 1.12.8", .confirmed)
		fromSource.version = "1.12.8"
		XCTAssertEqual(fromSource.title, "Across 1.12.8")
		fromSource.name = "Across 1.12.8 (120) (copy 2)"
		XCTAssertEqual(fromSource.title, "Across 1.12.8 (120) (copy 2)")
		var unread = attempt("Delta", .failed)
		unread.version = nil
		XCTAssertEqual(unread.title, "Delta")
	}

	func testUnreadableFileReadsAsEmpty() throws {
		let file = folder.appendingPathComponent("history.json")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data("not json".utf8).write(to: file)
		let history = InstallHistory(file: file)
		XCTAssertEqual(history.attempts(), [])
		try history.record(attempt("a", .cancelled))
		XCTAssertEqual(history.attempts().count, 1)
		history.removeAll()
		XCTAssertEqual(history.attempts(), [])
	}
}
