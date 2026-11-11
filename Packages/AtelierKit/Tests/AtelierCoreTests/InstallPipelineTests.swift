import CertKit
import Foundation
import InstallKit
import SigningKit
import XCTest
@testable import AtelierCore

final class InstallStateMachineTests: XCTestCase {
	private let info = IPAInfo(bundleID: "com.example.app", version: "1.0", name: "Example")

	func testRunsForwardThroughEveryStage() {
		var machine = InstallStateMachine()
		XCTAssertEqual(machine.stage, .checking)
		XCTAssertTrue(machine.handle(.downloading(nil)))
		XCTAssertTrue(machine.handle(.downloading(0.5)))
		XCTAssertTrue(machine.handle(.signing(.unpacking(0))))
		XCTAssertTrue(machine.handle(.signing(.signing)))
		XCTAssertTrue(machine.handle(.signing(.packing(1))))
		XCTAssertTrue(machine.handle(.installing(info, .waitingForApproval)))
		XCTAssertTrue(machine.handle(.installing(info, .downloading(fraction: 1))))
		XCTAssertTrue(machine.handle(.installed(info, .confirmed(version: "1.0"))))
		XCTAssertEqual(machine.stage, .finished(info, .confirmed(version: "1.0")))
	}

	func testSkipsStagesAPayloadDoesntNeed() {
		var picked = InstallStateMachine()
		XCTAssertTrue(picked.handle(.signing(.unpacking(0))), "A picked file has no download")
		var kept = InstallStateMachine()
		XCTAssertTrue(kept.handle(.installing(info, .waitingForApproval)), "An IPA that's already signed isn't signed again")
	}

	func testNeverMovesBack() {
		var machine = InstallStateMachine()
		machine.handle(.signing(.packing(0.5)))
		XCTAssertFalse(machine.handle(.downloading(1)), "A late download update")
		machine.handle(.installing(info, .waitingForApproval))
		XCTAssertFalse(machine.handle(.signing(.packing(1))), "A late signing update")
		XCTAssertEqual(machine.stage, .installing(info, .waitingForApproval))
	}

	func testInstalledOnlyFollowsInstalling() {
		var machine = InstallStateMachine()
		XCTAssertFalse(machine.handle(.installed(info, .unconfirmed)))
		machine.handle(.signing(.signing))
		XCTAssertFalse(machine.handle(.installed(info, .unconfirmed)))
		XCTAssertEqual(machine.stage, .signing(.signing))
	}

	func testFailsOrCancelsFromEveryActiveStage() {
		let stages: [InstallStateMachine.Event?] = [nil, .downloading(0.2), .signing(.signing), .installing(info, .installing(fraction: nil))]
		for start in stages {
			var failing = InstallStateMachine()
			if let start { failing.handle(start) }
			XCTAssertTrue(failing.handle(.failed(InstallProblem("no"))))
			XCTAssertEqual(failing.stage, .failed(InstallProblem("no")))

			var cancelling = InstallStateMachine()
			if let start { cancelling.handle(start) }
			XCTAssertTrue(cancelling.handle(.cancelled))
			XCTAssertEqual(cancelling.stage, .cancelled)
		}
	}

	func testEndsOnce() {
		var machine = InstallStateMachine()
		machine.handle(.cancelled)
		XCTAssertFalse(machine.handle(.failed(InstallProblem("late"))))
		XCTAssertFalse(machine.handle(.downloading(1)))
		XCTAssertEqual(machine.stage, .cancelled)

		var failed = InstallStateMachine()
		failed.handle(.failed(InstallProblem("first")))
		XCTAssertFalse(failed.handle(.cancelled))
		XCTAssertEqual(failed.stage, .failed(InstallProblem("first")))
	}

	func testOverallProgressOnlyGrows() {
		let stages: [InstallStage] = [
			.checking, .downloading(nil), .downloading(0.5), .downloading(1),
			.signing(.unpacking(0)), .signing(.unpacking(1)), .signing(.signing), .signing(.packing(1)),
			.installing(info, .waitingForApproval), .installing(info, .downloading(fraction: 1)),
			.installing(info, .installing(fraction: nil)), .installing(info, .installing(fraction: 1)),
			.finished(info, .unconfirmed),
		]
		let fractions = stages.map(\.overallFraction)
		XCTAssertEqual(fractions, fractions.sorted())
		XCTAssertEqual(fractions.first, 0)
		XCTAssertEqual(fractions.last, 1)
	}
}

@MainActor
final class InstallPipelineTests: XCTestCase {
	private var folder: URL!
	private var stages: [InstallStage] = []
	private var certificate = CertificateCheck.ready(name: "Example Team")
	private var installer: FakeInstaller!
	private var freeSpace: Int64? = 10 << 30
	private var signError: Error?
	private var signedFiles: [URL] = []
	private let info = IPAInfo(bundleID: "com.example.app", version: "1.0", name: "Example")
	/// How many times the certificate was checked.
	private var certificateChecks = 0
	/// The IPAs the check of the installed app was given (#99), in order:
	/// nil before a download.
	private var checked: [URL?] = []
	/// What that check does: whether it switched certificates.
	private var checkInstalled: () throws -> Bool = { false }

	override func setUp() async throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("InstallPipelineTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		installer = FakeInstaller()
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: folder)
	}

	private func pipeline() -> InstallPipeline {
		let dependencies = InstallPipeline.Dependencies(
			certificate: { [unowned self] in
				certificateChecks += 1
				return certificate
			},
			installer: { [unowned self] in try await RouteSelector.select(.automatic, from: [installer]) },
			freeSpace: { [unowned self] in freeSpace },
			checkInstalled: { [unowned self] installer, ipa in
				XCTAssertEqual(installer.route, .localServer, "the route picked")
				checked.append(ipa)
				return try checkInstalled()
			},
			sign: { [unowned self] ipa, progress in
				progress(.unpacking(1))
				progress(.signing)
				try await Task.sleep(nanoseconds: 1_000_000)
				if let signError { throw signError }
				let signed = folder.appendingPathComponent("signed-\(UUID().uuidString).ipa")
				try Data("signed \(ipa.lastPathComponent)".utf8).write(to: signed)
				signedFiles.append(signed)
				progress(.packing(1))
				return InstallPackage(url: signed, info: info)
			}
		)
		return InstallPipeline(dependencies, onStage: { [unowned self] in stages.append($0) })
	}

	private func ipa(size: Int = 1024) throws -> URL {
		let url = folder.appendingPathComponent("\(UUID().uuidString).ipa")
		try Data(count: size).write(to: url)
		return url
	}

	private func problem(_ run: () async throws -> InstallPipeline.Completed) async -> InstallProblem? {
		do {
			_ = try await run()
			XCTFail("The install should have failed")
			return nil
		} catch let problem as InstallProblem {
			return problem
		} catch {
			XCTFail("Unexpected \(error)")
			return nil
		}
	}

	// MARK: Installs that go through

	func testDownloadsSignsAndInstalls() async throws {
		let download = FakeDownload(file: try ipa(), size: 1024)
		let completed = try await pipeline().run(.download(download))

		XCTAssertEqual(completed.result, .confirmed(version: "1.0"))
		XCTAssertTrue(completed.freshlySigned)
		XCTAssertEqual(installer.installed.map(\.url), signedFiles)
		XCTAssertTrue(FileManager.default.fileExists(atPath: completed.package.url.path), "The signed IPA is the caller's to keep or delete")
		XCTAssertEqual(stages, [
			.checking,
			.downloading(nil), .downloading(0.5), .downloading(1),
			.signing(.unpacking(0)), .signing(.unpacking(1)), .signing(.signing), .signing(.packing(1)),
			.installing(info, .waitingForApproval), .installing(info, .downloading(fraction: 1)),
			.finished(info, .confirmed(version: "1.0")),
		])
		XCTAssertFalse(download.discarded)
	}

	func testSignsAPickedFileWithoutDownloading() async throws {
		let completed = try await pipeline().run(.file(try ipa()))
		XCTAssertTrue(completed.freshlySigned)
		XCTAssertFalse(stages.contains { if case .downloading = $0 { true } else { false } })
		XCTAssertEqual(stages.last, .finished(info, .confirmed(version: "1.0")))
	}

	func testInstallsAKeptCopyWithoutSigningOrACertificate() async throws {
		certificate = .missing
		let kept = InstallPackage(url: try ipa(), info: info)
		let pipeline = pipeline()
		let completed = try await pipeline.run(.signed(kept))
		XCTAssertFalse(completed.freshlySigned)
		XCTAssertTrue(signedFiles.isEmpty)
		XCTAssertEqual(installer.installed, [kept])
		XCTAssertEqual(stages.first, .checking)
		XCTAssertEqual(stages[1], .installing(info, .waitingForApproval))
		XCTAssertNil(pipeline.certificateName)
		XCTAssertEqual(pipeline.route, .localServer)
	}

	func testReportsAnUnconfirmedInstall() async throws {
		installer.result = .unconfirmed
		let completed = try await pipeline().run(.file(try ipa()))
		XCTAssertEqual(completed.result, .unconfirmed)
		XCTAssertEqual(stages.last, .finished(info, .unconfirmed))
	}

	// MARK: Checks before anything is downloaded

	func testNeedsACertificate() async throws {
		certificate = .missing
		let download = FakeDownload(file: try ipa(), size: 1024)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.download(download)) }
		XCTAssertEqual(problem, .noCertificate)
		XCTAssertEqual(problem?.fix, .importCertificate)
		XCTAssertFalse(download.started, "Nothing is downloaded before the checks pass")
		XCTAssertEqual(pipeline.stage, .failed(.noCertificate))
	}

	func testRefusesAnExpiredCertificate() async throws {
		let expiry = Date(timeIntervalSince1970: 1_700_000_000)
		certificate = .expired(name: "Old Team", on: expiry)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem, .certificateExpired("Old Team", on: expiry))
		XCTAssertEqual(problem?.fix, .importCertificate)
		XCTAssertTrue(signedFiles.isEmpty)
	}

	func testRefusesARevokedCertificate() async throws {
		certificate = .revoked(name: "Shared Team")
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem, .certificateRevoked("Shared Team"))
		XCTAssertEqual(problem?.fix, .importCertificate)
		XCTAssertEqual(pipeline.certificateName, "Shared Team")
		XCTAssertTrue(signedFiles.isEmpty)
	}

	func testRefusesAnUnusableCertificate() async throws {
		certificate = .unusable(name: "Shared Team", why: "the Keychain is locked")
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem?.fix, .importCertificate)
		XCTAssertEqual(problem?.message, "Can't sign with “Shared Team”: the Keychain is locked")
	}

	func testNeedsARoute() async throws {
		installer.health = .unavailable("The manifest endpoint isn't a valid URL.")
		let download = FakeDownload(file: try ipa(), size: 1024)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.download(download)) }
		XCTAssertEqual(problem?.fix, .installSettings)
		XCTAssertEqual(problem?.message, "The manifest endpoint isn't a valid URL.")
		XCTAssertFalse(download.started)
	}

	func testNeedsSpaceForTheDownloadAndSigning() async throws {
		let size: Int64 = 500 << 20
		freeSpace = 1 << 30
		let download = FakeDownload(file: try ipa(), size: size)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.download(download)) }
		let needed = InstallPipeline.requiredSpace(ipaSize: size, download: true, sign: true)
		XCTAssertEqual(problem, .notEnoughSpace(needed: needed, available: 1 << 30))
		XCTAssertEqual(problem?.fix, .freeSpace)
		XCTAssertFalse(download.started)
	}

	func testAFinishedDownloadOnlyNeedsSpaceForSigning() async throws {
		let size: Int64 = 400 << 20
		freeSpace = 900 << 20
		let download = FakeDownload(file: try ipa(), size: size, finished: true)
		_ = try await pipeline().run(.download(download))
		XCTAssertEqual(InstallPipeline.requiredSpace(ipaSize: size, download: false, sign: true), 800 << 20 + InstallPipeline.spaceMargin)
	}

	func testSkipsTheSpaceCheckWhenItCantBeTold() async throws {
		freeSpace = nil
		_ = try await pipeline().run(.download(FakeDownload(file: try ipa(), size: 1 << 40)))
		XCTAssertEqual(InstallPipeline.requiredSpace(ipaSize: 1 << 30, download: false, sign: false), 0)
	}

	// MARK: What's on this iPhone already (#99)

	func testChecksTheInstalledAppBeforeTheDownloadAndAgainWithItsIPA() async throws {
		let file = try ipa()
		checkInstalled = { [unowned self] in
			if checked.count == 1 {
				XCTAssertEqual(stages, [.checking], "before the download")
			} else {
				XCTAssertEqual(stages.last, .downloading(1), "once downloaded, before signing")
				XCTAssertTrue(signedFiles.isEmpty)
			}
			return false
		}
		_ = try await pipeline().run(.download(FakeDownload(file: file, size: 1024)))
		XCTAssertEqual(checked, [nil, file])
		XCTAssertEqual(certificateChecks, 1)
	}

	func testChecksAPickedFileBeforeSigningIt() async throws {
		let file = try ipa()
		checkInstalled = { [unowned self] in
			XCTAssertTrue(signedFiles.isEmpty)
			return false
		}
		_ = try await pipeline().run(.file(file))
		XCTAssertEqual(checked, [file])
	}

	func testDoesntCheckForAKeptCopy() async throws {
		_ = try await pipeline().run(.signed(InstallPackage(url: try ipa(), info: info)))
		XCTAssertEqual(checked, [])
	}

	func testStopsBeforeTheDownloadWhenIOSWontReplaceTheApp() async throws {
		let conflict = InstalledConflict(installedName: "YouTube", appName: "YTLite", bundleID: "com.google.ios.youtube", signer: .appStore, keepsData: false)
		checkInstalled = { throw InstallProblem.cantReplace(conflict) }
		let download = FakeDownload(file: try ipa(), size: 1024)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.download(download)) }
		XCTAssertEqual(problem, .cantReplace(conflict))
		XCTAssertEqual(problem?.conflict, conflict)
		XCTAssertEqual(problem?.fix, .replaceInstalled)
		XCTAssertEqual(problem?.message, conflict.failure)
		XCTAssertFalse(download.started)
		XCTAssertTrue(signedFiles.isEmpty)
		XCTAssertEqual(pipeline.stage, .failed(.cantReplace(conflict)))
	}

	func testChecksTheCertificateItSwitchedTo() async throws {
		checkInstalled = { [unowned self] in
			certificate = .ready(name: "Feather cert")
			return true
		}
		let switched = pipeline()
		_ = try await switched.run(.file(try ipa()))
		XCTAssertEqual(certificateChecks, 2)
		XCTAssertEqual(switched.certificateName, "Feather cert")

		// One that can't sign stops the install before signing.
		let expiry = Date(timeIntervalSince1970: 1_700_000_000)
		certificate = .ready(name: "Example Team")
		signedFiles = []
		checkInstalled = { [unowned self] in
			certificate = .expired(name: "Feather cert", on: expiry)
			return true
		}
		let expired = pipeline()
		let problem = await problem { try await expired.run(.file(try ipa())) }
		XCTAssertEqual(problem, .certificateExpired("Feather cert", on: expiry))
		XCTAssertTrue(signedFiles.isEmpty)
	}

	func testCancellingDuringTheCheckStopsEverything() async throws {
		let download = FakeDownload(file: try ipa(), size: 1024)
		checkInstalled = {
			withUnsafeCurrentTask { $0?.cancel() }
			return false
		}
		let pipeline = pipeline()
		let task = Task { try await pipeline.run(.download(download)) }
		await assertCancelled(task)
		XCTAssertFalse(download.started)
		XCTAssertEqual(pipeline.stage, .cancelled)
	}

	// MARK: Failures along the way

	func testADownloadFailureKeepsTheDownload() async throws {
		let download = FakeDownload(file: try ipa(), size: 1024)
		download.failure = InstallProblem("The server said 404.", fix: .tryAgain)
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.download(download)) }
		XCTAssertEqual(problem, InstallProblem("The server said 404.", fix: .tryAgain))
		XCTAssertFalse(download.discarded, "Kept, so Try again can resume it")
		XCTAssertTrue(signedFiles.isEmpty)
	}

	func testSigningFailuresSayWhatToDo() async throws {
		let cases: [(SigningError, InstallProblem.Fix?)] = [
			(.badCertificate, .importCertificate),
			(.unsupportedCertificate, .importCertificate),
			(.outOfSpace(needed: 2 << 30, available: 1 << 30), .freeSpace),
			(.encryptedBinary("Example"), nil),
		]
		for (error, fix) in cases {
			signError = error
			let pipeline = pipeline()
			let problem = await problem { try await pipeline.run(.file(try ipa())) }
			XCTAssertEqual(problem?.fix, fix, "\(error)")
		}
		XCTAssertEqual(InstallProblem(SigningError.outOfSpace(needed: 2, available: 1)), .notEnoughSpace(needed: 2, available: 1))
		XCTAssertTrue(installer.installed.isEmpty)
	}

	func testAnInstallFailureDeletesTheSignedIPA() async throws {
		installer.failure = InstallFailure.notStarted
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem?.fix, .tryAgain)
		XCTAssertEqual(signedFiles.count, 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: signedFiles[0].path))
		XCTAssertEqual(pipeline.info, info)
	}

	/// So Delete and Install doesn't sign it again (#99).
	func testKeepsTheSignedAppIOSWouldntPutOverTheOneItHas() async throws {
		installer.failure = InstallFailure.rejected("MismatchedApplicationIdentifierEntitlement")
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem?.fix, .replaceInstalled)
		XCTAssertEqual(pipeline.refusedPackage, InstallPackage(url: signedFiles[0], info: info))
		XCTAssertTrue(FileManager.default.fileExists(atPath: signedFiles[0].path), "the caller's to delete")

		installer.failure = InstallFailure.notStarted
		let other = self.pipeline()
		_ = await self.problem { try await other.run(.file(try ipa())) }
		XCTAssertNil(other.refusedPackage)
	}

	func testInstallFailuresSayWhatToDo() async {
		XCTAssertEqual(InstallProblem(InstallFailure.downloadFailed).fix, .tryAgain)
		XCTAssertEqual(InstallProblem(InstallFailure.notInstalled).fix, .replaceInstalled)
		XCTAssertNil(InstallProblem(InstallFailure.rejected("no")).fix)
		XCTAssertEqual(InstallProblem(InstallFailure.couldNotStart("No server.")), InstallProblem("No server."))
	}

	func testANotInstalledAppIsNamedWithWhatToDo() async throws {
		installer.failure = InstallFailure.notInstalled
		let pipeline = pipeline()
		let problem = await problem { try await pipeline.run(.file(try ipa())) }
		XCTAssertEqual(problem?.fix, .replaceInstalled)
		XCTAssertEqual(problem, .notInstalled(info.name))
		XCTAssertTrue(problem?.message.hasPrefix("\(info.name) wasn't installed. If it's already on this") ?? false)
		XCTAssertTrue(problem?.detail?.hasPrefix("Otherwise your certificate may not be registered") ?? false)
		XCTAssertTrue(InstallProblem(InstallFailure.notInstalled).message.hasPrefix("The app wasn't installed."))
	}

	func testAnAppIDMismatchSaysSoForCertain() {
		let why = #"UnknownErrorType("MismatchedApplicationIdentifierEntitlement (Upgrade's application-identifier entitlement string (T.a) does not match installed application's application-identifier string (T.b); rejecting upgrade.)")"#
		let problem = InstallProblem(InstallFailure.rejected(why), appName: "Radiance")
		var expected = InstallProblem.appIDMismatch("Radiance")
		expected.installedAppID = "T.b"
		expected.technical = why
		XCTAssertEqual(problem, expected)
		XCTAssertEqual(problem.fix, .replaceInstalled)
		XCTAssertTrue(problem.message.hasPrefix("Radiance wasn't installed: the one on this"))
		XCTAssertFalse(problem.message.contains("App ID"), "iOS's words stay in the install log")
	}

	/// The installed app's App ID, which iOS names only in its refusal for
	/// an app it lists nowhere (#99), such as your test's AltStore Classic,
	/// offloaded.
	func testReadsTheInstalledAppIDFromInstalldsRefusal() {
		let why = #"UnknownErrorType("MismatchedApplicationIdentifierEntitlement (Upgrade's application-identifier entitlement string (S7GNTEAM42.app.heron2265.lime9140) does not match installed application's application-identifier string (6XVY5G3U44.com.rileytestut.AltStore); rejecting upgrade.)")"#
		XCTAssertEqual(InstallProblem(InstallFailure.rejected(why)).installedAppID, "6XVY5G3U44.com.rileytestut.AltStore")
		XCTAssertNil(InstallProblem(InstallFailure.rejected("MismatchedApplicationIdentifierEntitlement")).installedAppID, "a refusal that doesn't name it")
		XCTAssertNil(InstallProblem.installedAppID(inRefusal: "installed application's application-identifier string (); rejecting"))
		XCTAssertNil(InstallProblem(InstallFailure.rejected("ApplicationVerificationFailed")).installedAppID)
	}

	func testDataThatCouldntBeCopiedSaysWhyAndWhatToDo() {
		let brokeOff = InstallProblem(InstallFailure.dataNotCopied(.brokeOff("The connection to iOS broke off: Socket.")))
		XCTAssertEqual(brokeOff.message, "Couldn't copy its data, so it wasn't deleted.")
		XCTAssertEqual(brokeOff.detail, "Copying it was interrupted. Check that you're on Wi-Fi with LocalDevVPN connected, then try again.")
		XCTAssertEqual(brokeOff.technical, "The connection to iOS broke off: Socket.", "for the install log")
		XCTAssertEqual(brokeOff.fix, .tryAgain)
		XCTAssertEqual(brokeOff.dataFailure, .brokeOff("The connection to iOS broke off: Socket."))
		XCTAssertNil(InstallProblem(InstallFailure.notStarted).dataFailure)

		let refused = InstallProblem(InstallFailure.dataNotCopied(.refused("InstallationLookupFailed")))
		XCTAssertEqual(refused.detail, "iOS doesn't let Atelier copy this app's data.")
		XCTAssertEqual(refused.technical, "iOS doesn't let Atelier open its data: InstallationLookupFailed.")
		XCTAssertNil(refused.fix, "trying again wouldn't change it")

		let full = InstallProblem(InstallFailure.dataNotCopied(.notEnoughSpace(needed: 5_000_000_000, free: 1_000_000_000)))
		XCTAssertEqual(full.fix, .freeSpace)
		XCTAssertTrue(full.detail?.hasPrefix("Its data takes ") ?? false, full.detail ?? "")
	}

	func testCopyingAndPuttingBackDataFitTheWholeInstallsProgress() {
		XCTAssertEqual(InstallStage.installing(info, .copyingData(fraction: 0.5)).overallFraction, 0.8)
		XCTAssertEqual(InstallStage.installing(info, .restoringData(fraction: nil)).overallFraction, 0.95)
		XCTAssertEqual(InstallStage.installing(info, .restoringData(fraction: 1)).overallFraction, 1)
	}

	func testAFailedKeptCopyStays() async throws {
		installer.failure = InstallFailure.notStarted
		let kept = InstallPackage(url: try ipa(), info: info)
		let pipeline = pipeline()
		_ = await problem { try await pipeline.run(.signed(kept)) }
		XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path))
	}

	// MARK: Cancelling

	func testCancellingTheDownloadDiscardsIt() async throws {
		let download = FakeDownload(file: try ipa(), size: 1024)
		download.waits = true
		let pipeline = pipeline()
		let task = Task { try await pipeline.run(.download(download)) }
		while !download.started { await Task.yield() }
		task.cancel()
		await assertCancelled(task)
		XCTAssertTrue(download.discarded)
		XCTAssertEqual(pipeline.stage, .cancelled)
		XCTAssertTrue(signedFiles.isEmpty)
	}

	func testCancellingTheInstallDeletesTheSignedIPA() async throws {
		installer.waits = true
		let download = FakeDownload(file: try ipa(), size: 1024)
		let pipeline = pipeline()
		let task = Task { try await pipeline.run(.download(download)) }
		while !installer.started { await Task.yield() }
		task.cancel()
		await assertCancelled(task)
		XCTAssertEqual(stages.last, .cancelled)
		XCTAssertFalse(FileManager.default.fileExists(atPath: signedFiles[0].path))
		XCTAssertTrue(download.discarded)
	}

	func testCancellingBeforeTheChecksStopsEverything() async throws {
		let download = FakeDownload(file: try ipa(), size: 1024)
		let pipeline = pipeline()
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await pipeline.run(.download(download))
		}
		await assertCancelled(task)
		XCTAssertFalse(download.started)
		XCTAssertTrue(installer.installed.isEmpty)
	}

	private func assertCancelled(_ task: Task<InstallPipeline.Completed, Error>, file: StaticString = #filePath, line: UInt = #line) async {
		do {
			_ = try await task.value
			XCTFail("The install should have been cancelled", file: file, line: line)
		} catch {
			XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
		}
	}
}

@MainActor
private final class FakeInstaller: Installer {
	let route = InstallRoute.localServer
	var result = InstallResult.confirmed(version: "1.0")
	var failure: Error?
	/// Waits until cancelled.
	var waits = false
	private(set) var started = false
	private(set) var installed: [InstallPackage] = []

	var health = RouteHealth.ready

	func healthCheck() async -> RouteHealth { health }

	func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		started = true
		events(.log("installing"))
		if waits {
			while true { try await Task.sleep(nanoseconds: 1_000_000) }
		}
		if let failure { throw failure }
		events(.phase(.downloading(fraction: 1)))
		installed.append(package)
		return result
	}
}

@MainActor
private final class FakeDownload: PipelineDownload {
	let expectedSize: Int64?
	let isFinished: Bool
	private let url: URL
	var failure: InstallProblem?
	/// Waits until cancelled.
	var waits = false
	private(set) var started = false
	private(set) var discarded = false

	init(file: URL, size: Int64?, finished: Bool = false) {
		url = file
		expectedSize = size
		isFinished = finished
	}

	func file(progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
		started = true
		if waits {
			while true { try await Task.sleep(nanoseconds: 1_000_000) }
		}
		if let failure { throw failure }
		progress(0.5)
		progress(1)
		return url
	}

	func discard() {
		discarded = true
	}
}
