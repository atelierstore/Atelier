import Foundation
import XCTest
@testable import InstallKit

/// Atelier notes its own install as it goes to iOS, and tells on its next
/// launch how it ended (#24).
final class SelfInstallTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func pending(kind: PendingSelfInstall.Kind = .update) -> PendingSelfInstall {
		PendingSelfInstall(
			token: "B6A1",
			kind: kind,
			fromVersion: "0.1.0",
			fromBuild: "319",
			version: "0.2.0",
			build: "330",
			displayVersion: "0.2.0-alpha",
			certificateID: UUID(),
			certificateName: "Signulous Distribution",
			sourceURL: URL(string: "https://raw.githubusercontent.com/atelierstore/Atelier/source/source.json"),
			limits: ["Push notifications won't work."],
			attempt: InstallAttempt(
				bundleID: "com.atelier.app",
				name: "Atelier 0.2.0-alpha",
				version: "0.2.0",
				certificate: "Signulous Distribution",
				route: .localServer,
				startedAt: Date(timeIntervalSince1970: 1_792_000_000),
				finishedAt: Date(timeIntervalSince1970: 1_792_000_030),
				result: .unconfirmed,
				log: ["signed com.atelier.app 0.2.0", "iOS asked for the app"]
			)
		)
	}

	func testTellsHowItEndedFromTheBuildRunning() {
		let install = pending()
		XCTAssertEqual(install.outcome(runningToken: "B6A1", version: "0.2.0", build: "330"), .installed)
		XCTAssertEqual(install.outcome(runningToken: nil, version: "0.1.0", build: "319"), .notInstalled)
		XCTAssertEqual(install.outcome(runningToken: "OLD", version: "0.1.0", build: "319"), .notInstalled, "a token from an earlier install of itself")
		XCTAssertEqual(install.outcome(runningToken: nil, version: "0.3.0", build: "400"), .superseded)

		// Signing the same build again: only the token tells.
		let again = pending(kind: .signAgain)
		XCTAssertEqual(again.outcome(runningToken: "B6A1", version: "0.1.0", build: "319"), .installed)
		XCTAssertEqual(again.outcome(runningToken: nil, version: "0.1.0", build: "319"), .notInstalled)
	}

	func testEndsTheAttemptForInstallHistory() {
		let install = pending()
		let now = Date(timeIntervalSince1970: 1_792_000_100)
		let installed = install.endedAttempt(.installed, at: now)
		XCTAssertEqual(installed.result, .confirmed)
		XCTAssertEqual(installed.finishedAt, now)
		XCTAssertEqual(installed.log.last, "relaunched as 0.2.0 (330): installed")
		let failed = install.endedAttempt(.notInstalled, at: now)
		XCTAssertEqual(failed.result, .failed)
		XCTAssertEqual(failed.error, "iOS didn't install 0.2.0-alpha.")
		XCTAssertEqual(failed.log.count, 3)
		XCTAssertEqual(install.endedAttempt(.superseded, at: now).result, .unconfirmed)
	}

	func testSaysHowItWentInTheBarAndNotifications() {
		let update = pending()
		XCTAssertEqual(update.installedNote, "Updated to 0.2.0-alpha")
		XCTAssertEqual(update.installedNotification(appName: "Atelier").title, "Updated to 0.2.0-alpha")
		XCTAssertEqual(update.installedNotification(appName: "Atelier").body, "Atelier is ready to open.")
		XCTAssertEqual(update.expectedNotification(appName: "Atelier").title, "Updating Atelier")
		XCTAssertEqual(update.expectedNotification(appName: "Atelier").body, "iOS should have installed 0.2.0-alpha by now. Open Atelier to see how it went.")

		var again = pending(kind: .install)
		again.displayVersion = "0.2.0"
		XCTAssertEqual(again.installedNote, "Installed 0.2.0 again")
		XCTAssertEqual(again.expectedNotification(appName: "Atelier").title, "Installing Atelier again")
		XCTAssertEqual(again.expectedNotification(appName: "Atelier").body, "iOS should have installed 0.2.0 by now. Open Atelier to see how it went.")

		let signAgain = pending(kind: .signAgain)
		XCTAssertEqual(signAgain.installedNote, "Signed again with Signulous Distribution")
		XCTAssertEqual(signAgain.expectedNotification(appName: "Atelier").title, "Signing Atelier again")
		XCTAssertEqual(signAgain.expectedNotification(appName: "Atelier").body, "iOS should have installed it with Signulous Distribution by now. Open Atelier to see how it went.")

		var resign = pending(kind: .resign)
		resign.certificateName = nil
		XCTAssertEqual(resign.installedNote, "Re-signed with another certificate")
		XCTAssertEqual(resign.expectedNotification(appName: "Atelier").title, "Re-signing Atelier")
	}

	/// Once iOS has the build, a sheet and the install bar say to leave
	/// Atelier for iOS to install it (#123).
	func testSaysToLeaveForIOSToInstallIt() {
		let update = pending()
		XCTAssertEqual(update.onceYouLeave(appName: "Atelier"), "iOS installs Atelier 0.2.0-alpha once you leave it.")
		XCTAssertEqual(pending(kind: .install).onceYouLeave(appName: "Atelier"), "iOS installs Atelier 0.2.0-alpha again once you leave it.")
		XCTAssertEqual(pending(kind: .signAgain).onceYouLeave(appName: "Atelier"), "iOS installs Atelier, signed again with Signulous Distribution, once you leave it.")
		var resign = pending(kind: .resign)
		XCTAssertEqual(resign.onceYouLeave(appName: "Atelier"), "iOS installs Atelier, re-signed with Signulous Distribution, once you leave it.")
		resign.certificateName = nil
		XCTAssertEqual(resign.onceYouLeave(appName: "Atelier"), "iOS installs Atelier, re-signed with another certificate, once you leave it.")

		XCTAssertEqual(PendingSelfInstall.afterLeaving(appName: "Atelier", notifies: true), "Atelier closes as you leave, and a notification says how it went within half a minute.")
		XCTAssertEqual(PendingSelfInstall.afterLeaving(appName: "Atelier", notifies: false), "Atelier closes as you leave. Open it again in half a minute to see how it went.")
		XCTAssertEqual(update.afterAlertClosed(appName: "Atelier"), "If you tapped Install, iOS installs Atelier 0.2.0-alpha once you leave it. If you tapped Cancel, Try Again shows iOS's alert again; Atelier is already signed.")

		XCTAssertEqual(PendingSelfInstall.finishing(.update, appName: "Atelier"), "to finish updating Atelier")
		XCTAssertEqual(PendingSelfInstall.finishing(.install, appName: "Atelier"), "to finish installing Atelier")
		XCTAssertEqual(PendingSelfInstall.finishing(.signAgain, appName: "Atelier"), "to finish signing Atelier again")
		XCTAssertEqual(PendingSelfInstall.finishing(.resign, appName: "Atelier"), "to finish re-signing Atelier")
	}

	func testKeptInAFileUntilTheNextLaunch() throws {
		let store = PendingSelfInstallStore(file: folder.appending(path: "PendingSelfInstall.json"))
		XCTAssertNil(store.load())
		let install = pending()
		try store.save(install)
		XCTAssertEqual(store.load(), install)
		store.remove()
		XCTAssertNil(store.load())
		// Something unreadable reads as nothing.
		try Data("{".utf8).write(to: store.file)
		XCTAssertNil(store.load())
	}

	func testNotesTheDownloadToDeleteOnceInstalled() throws {
		let store = PendingSelfInstallStore(file: folder.appending(path: "PendingSelfInstall.json"))
		var install = pending()
		install.downloadID = UUID()
		try store.save(install)
		XCTAssertEqual(store.load()?.downloadID, install.downloadID)

		// A note from a build that didn't note its download reads as having none.
		var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
		json["downloadID"] = nil
		try JSONSerialization.data(withJSONObject: json).write(to: store.file)
		let older = try XCTUnwrap(store.load())
		XCTAssertNil(older.downloadID)
		XCTAssertEqual(older.token, install.token)
	}
}
