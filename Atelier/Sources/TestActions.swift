import Foundation
import UIKit

/// The hidden test actions (#20), for trying on an iPhone what Atelier does
/// in cases that are hard to bring about on purpose. Settings shows them in
/// a Test Actions section once About › Version is tapped seven times:
/// testing certificates as revoked or expired (#20), making Setup's check
/// meet a failing install service (1 Nov 2026), and running a
/// background update check on demand (#19).
@MainActor
enum TestActions {
	/// Whether Settings shows the Test Actions section.
	static let shownKey = "testActions"
	/// Whether a certificate can be tested as revoked or expired, from
	/// Settings › Installs › Certificates.
	static let certificatesKey = "testCertificates"
	/// What Setup's check meets instead of iOS's install service: a
	/// `RouteASetup.TestFailure`'s raw value, or none for the real check.
	static let checkKey = "testInstallService"

	/// Shows or hides the section. Hiding it turns every test action off.
	static func setShown(_ shown: Bool) {
		UserDefaults.standard.set(shown, forKey: shownKey)
		if !shown {
			setCertificates(false)
			setCheck(nil)
		}
	}

	/// Runs one background update check (#19) 10 seconds from now, so
	/// there's time to leave Atelier: as a background refresh would, after
	/// forgetting what earlier checks told about, so it's told again. With
	/// Install updates automatically on, it's an automatic updates run
	/// instead (#72), which installs what it can and checks the rest.
	static func runBackgroundCheck() {
		// Keeps Atelier running for the wait and the check once it's left,
		// for as long as iOS allows, about 30 seconds.
		let background = BackgroundTime()
		background.begin()
		Task {
			try? await Task.sleep(for: .seconds(10))
			UpdateChecks.forgetTold()
			if AutoUpdates.isOn {
				await AutoUpdates.installUpdates()
			} else {
				await UpdateChecks.run(from: .test)
			}
			background.end()
		}
	}

	/// Turns certificate tests on or off. Off ends every certificate's test.
	static func setCertificates(_ on: Bool) {
		UserDefaults.standard.set(on, forKey: certificatesKey)
		if !on { Task { await CertificatesModel.shared.endAllTests() } }
	}

	/// Makes Setup's check, and so installs, meet `failure` instead of iOS's
	/// install service, or checks for real again.
	static func setCheck(_ failure: RouteASetup.TestFailure?) {
		let defaults = UserDefaults.standard
		guard defaults.string(forKey: checkKey) != failure?.rawValue else { return }
		defaults.set(failure?.rawValue, forKey: checkKey)
		RouteASetup.shared.testFailureChanged()
	}
}

/// Background time asked of iOS with `beginBackgroundTask`, ended once.
@MainActor
private final class BackgroundTime {
	private var task = UIBackgroundTaskIdentifier.invalid

	func begin() {
		task = UIApplication.shared.beginBackgroundTask(withName: "Test background check") { [weak self] in
			MainActor.assumeIsolated { self?.end() }
		}
	}

	func end() {
		guard task != .invalid else { return }
		UIApplication.shared.endBackgroundTask(task)
		task = .invalid
	}
}
