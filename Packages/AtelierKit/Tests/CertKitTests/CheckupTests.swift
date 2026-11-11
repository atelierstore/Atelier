import Foundation
import InstallKit
import XCTest
@testable import CertKit

/// Get Ready and Status (#21): what each thing says, in which order, and
/// what Settings' Status row names.
final class CheckupTests: XCTestCase {
	/// The fixtures' certificate runs to 2036 and their profiles to
	/// 1 Jan 2027, so the profile is what runs out first.
	private let now = Fixture.utc(2026, 11, 1)

	private func stored(_ profile: String, revocation: RevocationStatus? = .good) throws -> StoredCertificate {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file(profile))
		let validated = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: profile))
		var stored = StoredCertificate(id: UUID(), addedAt: now, certificate: validated.certificate, profile: validated.profile)
		stored.revocation = revocation.map { .checked($0, at: now) }
		return stored
	}

	private func profile(_ name: String) throws -> ProvisioningProfile {
		try ProvisioningProfile(data: Fixture.data(name))
	}

	/// An Apple ID signed in with (#49), its certificate the fixtures'.
	private func appleID(isFree: Bool? = true, revocation: RevocationStatus? = .good) throws -> StoredAppleID {
		let files = CertificateFiles(p12: try Fixture.file("signing.p12"), profile: try Fixture.file("development.mobileprovision"))
		let certificate = try CertificateImporter.validate(files, password: Fixture.password, openP12: Fixture.opener(certificateFrom: "development.mobileprovision")).certificate
		return StoredAppleID(
			email: "sam.test@icloud.com", team: .init(id: "A1B2C3D4E5", name: nil, isFree: isFree), certificate: certificate,
			machineName: "Atelier", revocation: revocation.map { .checked($0, at: now) }
		)
	}

	private func facts(
		certificate: StoredCertificate? = nil,
		appleID: StoredAppleID? = nil,
		canUpdateAtelier: Bool? = nil,
		ownProfile: ProvisioningProfile? = nil,
		deviceUDID: String? = nil,
		developerModeRead: Bool? = nil,
		developerModeConfirmed: Bool = false,
		installServer: ManifestEndpoint.Reachability? = .reachable,
		setup: CheckupFacts.Setup = .notSetUp,
		sources: [CheckupFacts.Source] = [CheckupFacts.Source(name: "Atelier", isBuiltIn: true)],
		now: Date? = nil
	) -> CheckupFacts {
		CheckupFacts(
			certificate: certificate, appleID: appleID, canUpdateAtelier: canUpdateAtelier, ownProfile: ownProfile, deviceUDID: deviceUDID,
			developerModeRead: developerModeRead, developerModeConfirmed: developerModeConfirmed, installServer: installServer,
			installServerHost: "api.atelierstore.app", setup: setup, sources: sources, now: now ?? self.now, device: "iPhone"
		)
	}

	private func item(_ kind: Checkup.Kind, in checkup: Checkup) throws -> Checkup.Item {
		try XCTUnwrap(checkup.items.first { $0.kind == kind }, "no \(kind) in \(checkup.items.map(\.kind))")
	}

	private let added = CheckupFacts.Source(name: "TfourJ's Apps")

	// MARK: Get Ready

	func testOutOfTheBox() throws {
		let checkup = Checkup(facts(installServer: nil), for: .getReady)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .sources, .setup], "the install server only shows when it fails, and Developer Mode once there's a certificate")
		let certificate = try item(.certificate, in: checkup)
		XCTAssertEqual(certificate.state, .todo)
		XCTAssertEqual(certificate.title, "Your certificate")
		XCTAssertEqual(certificate.text, "Atelier signs every app with it. Import a .p12 with its profile, or sign in with an Apple ID and Atelier makes one.")
		XCTAssertEqual(certificate.actions, [.importCertificate, .signInWithAppleID])
		XCTAssertNil(certificate.hint, "Atelier's own profile couldn't be read")
		XCTAssertEqual(try item(.sources, in: checkup).state, .todo)
		XCTAssertEqual(try item(.setup, in: checkup).state, .optional)
		XCTAssertEqual(checkup.summary, "No certificate")
	}

	func testNamesWhoAtelierWasInstalledWith() throws {
		let checkup = Checkup(facts(ownProfile: try profile("adhoc.mobileprovision")), for: .getReady)
		let hint = try XCTUnwrap(try item(.certificate, in: checkup).hint)
		XCTAssertEqual(hint, "Atelier itself was installed with one from OwnStore Test. Import that one, and Atelier can update itself too.")
		// Signed ad hoc, Atelier wouldn't open with Developer Mode off.
		let mode = try item(.developerMode, in: checkup)
		XCTAssertEqual(mode.state, .ok)
		XCTAssertEqual(mode.value, "On")
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .developerMode, .sources, .setup])
	}

	func testDone() throws {
		let certificate = try stored("adhoc.mobileprovision")
		let checkup = Checkup(facts(certificate: certificate, canUpdateAtelier: true, ownProfile: try profile("adhoc.mobileprovision"), sources: [CheckupFacts.Source(name: "Atelier", isBuiltIn: true), added]), for: .getReady)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .developerMode, .sources, .setup])
		let row = try item(.certificate, in: checkup)
		XCTAssertEqual(row.state, .ok)
		XCTAssertEqual(row.value, "OwnStore Test (TESTTEAM01)")
		XCTAssertEqual(row.text, "Ad hoc, not revoked, 61 days left. Apple can revoke a certificate at any time, and apps signed with it stop opening. Atelier checks, and tells you if it does.")
		let sources = try item(.sources, in: checkup)
		XCTAssertEqual(sources.state, .ok)
		XCTAssertEqual(sources.title, "Source")
		XCTAssertEqual(sources.value, "TfourJ's Apps")
		XCTAssertNil(checkup.attention, "the setup can wait")
		XCTAssertEqual(checkup.summary, "All good")
	}

	func testNotCheckedWithAppleYet() throws {
		let checkup = Checkup(facts(certificate: try stored("enterprise.mobileprovision", revocation: nil)), for: .getReady)
		XCTAssertTrue(try XCTUnwrap(try item(.certificate, in: checkup).text).hasPrefix("Enterprise, not checked with Apple yet, 61 days left."))
	}

	// MARK: Checkup in Settings

	func testSettingsShowsEverything() throws {
		let checkup = Checkup(facts(certificate: try stored("adhoc.mobileprovision"), ownProfile: try profile("adhoc.mobileprovision"), installServer: nil, setup: .checking, sources: [added]), for: .settings)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .developerMode, .installServer, .setup, .sources])
		XCTAssertEqual(try item(.installServer, in: checkup).state, .checking)
		XCTAssertEqual(try item(.setup, in: checkup).value, "Checking…")
		let answered = Checkup(facts(certificate: try stored("adhoc.mobileprovision"), ownProfile: try profile("adhoc.mobileprovision"), setup: .checked(.ready), sources: [added]), for: .settings)
		XCTAssertEqual(try item(.installServer, in: answered).value, "Answers")
		XCTAssertEqual(try item(.setup, in: answered).value, "Finished")
		XCTAssertEqual(answered.summary, "All good")
	}

	// MARK: The certificate

	func testRevoked() throws {
		let revokedOn = Fixture.utc(2026, 10, 30)
		let certificate = try stored("adhoc.mobileprovision", revocation: .revoked(at: revokedOn))
		let checkup = Checkup(facts(certificate: certificate, canUpdateAtelier: false, sources: [added]), for: .settings)
		let card = try item(.certificate, in: checkup)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.title, "Certificate revoked")
		XCTAssertEqual(card.text, "Apple revoked OwnStore Test (TESTTEAM01) on \(revokedOn.formatted(date: .abbreviated, time: .omitted)). Apps signed with it won't open until they're signed again with another certificate. Import one, and Atelier offers to re-sign them.")
		XCTAssertEqual(card.actions, [.importCertificate])
		XCTAssertFalse(checkup.items.contains { $0.kind == .ownUpdates }, "the revoked card says it all")
		XCTAssertEqual(checkup.summary, "Certificate revoked")
	}

	func testExpired() throws {
		let checkup = Checkup(facts(certificate: try stored("adhoc.mobileprovision"), now: Fixture.utc(2027, 1, 2)), for: .settings)
		let card = try item(.certificate, in: checkup)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.title, "Certificate expired", "its profile expired, which people see as the certificate")
		XCTAssertTrue(try XCTUnwrap(card.text).hasPrefix("OwnStore Test (TESTTEAM01) expired on "))
		XCTAssertEqual(checkup.summary, "Certificate expired")
	}

	func testExpiringSoon() throws {
		let checkup = Checkup(facts(certificate: try stored("adhoc.mobileprovision"), canUpdateAtelier: false, sources: [added], now: Fixture.utc(2026, 12, 25)), for: .settings)
		let card = try item(.certificate, in: checkup)
		XCTAssertEqual(card.state, .warning)
		XCTAssertEqual(card.title, "Certificate expires soon")
		XCTAssertTrue(try XCTUnwrap(card.text).hasPrefix("OwnStore Test (TESTTEAM01) expires in 7 days, on "))
		XCTAssertEqual(checkup.summary, "Expires in 7 days")
		XCTAssertTrue(checkup.items.contains { $0.kind == .ownUpdates }, "it still signs, just not Atelier")
	}

	func testAppStoreProfile() throws {
		let checkup = Checkup(facts(certificate: try stored("appstore.mobileprovision"), now: Fixture.utc(2026, 11, 1)), for: .settings)
		let card = try item(.certificate, in: checkup)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.title, "For the App Store only")
		XCTAssertFalse(checkup.items.contains { $0.kind == .developerMode }, "Developer Mode doesn't come into it")
	}

	func testThisDeviceInTheProfile() throws {
		let certificate = try stored("adhoc.mobileprovision")
		let elsewhere = Checkup(facts(certificate: certificate, deviceUDID: "00008120-FFFFFFFFFFFFFFFF"), for: .settings)
		let card = try item(.certificate, in: elsewhere)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.title, "Not registered for this iPhone")
		XCTAssertEqual(card.text, "OwnStore Test (TESTTEAM01) isn't registered for this iPhone, so apps signed with it won't install here. Import one that is.")
		XCTAssertEqual(elsewhere.summary, "Not registered for this iPhone")
		let here = Checkup(facts(certificate: certificate, deviceUDID: "00008120-0011223344556677"), for: .settings)
		XCTAssertEqual(try item(.certificate, in: here).state, .ok)
	}

	func testAteliersOwnUpdates() throws {
		let certificate = try stored("development.mobileprovision")
		let checkup = Checkup(facts(certificate: certificate, canUpdateAtelier: false, ownProfile: try profile("adhoc.mobileprovision"), sources: [added]), for: .getReady)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .ownUpdates, .developerMode, .sources, .setup])
		let card = try item(.ownUpdates, in: checkup)
		XCTAssertEqual(card.state, .warning)
		XCTAssertEqual(card.text, "None of your certificates can update Atelier, as it was installed with one from another account. Import the one from OwnStore Test that Atelier was installed with.")
		XCTAssertEqual(checkup.summary, "Can't update Atelier")
		// Unknown isn't a warning.
		XCTAssertFalse(Checkup(facts(certificate: certificate), for: .getReady).items.contains { $0.kind == .ownUpdates })
	}

	// MARK: Developer Mode

	func testDeveloperModeWhenAtelierCantTell() throws {
		let adHoc = try stored("adhoc.mobileprovision")
		let enterpriseSigned = try profile("enterprise.mobileprovision")
		let unknown = Checkup(facts(certificate: adHoc, ownProfile: enterpriseSigned), for: .getReady)
		let card = try item(.developerMode, in: unknown)
		XCTAssertEqual(card.state, .todo)
		XCTAssertEqual(card.title, "Turn on Developer Mode")
		XCTAssertEqual(card.text, "Apps signed with your ad hoc certificate only open with it on. It's in Settings › Privacy & Security › Developer Mode, and your iPhone restarts.")
		XCTAssertEqual(card.actions, [.openDeveloperModeSettings, .confirmDeveloperMode])

		let confirmed = Checkup(facts(certificate: adHoc, ownProfile: enterpriseSigned, developerModeConfirmed: true), for: .getReady)
		XCTAssertEqual(try item(.developerMode, in: confirmed).state, .ok)
		XCTAssertEqual(try item(.developerMode, in: confirmed).text, "You said it's on. Development and ad hoc apps need it.")
	}

	func testDeveloperModeAsTheSetupReadIt() throws {
		let development = try stored("development.mobileprovision")
		let on = Checkup(facts(certificate: development, developerModeRead: true), for: .settings)
		XCTAssertEqual(try item(.developerMode, in: on).text, "Read by the setup.")

		let off = Checkup(facts(certificate: development, developerModeRead: false, sources: []), for: .settings)
		let card = try item(.developerMode, in: off)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.text, "Apps signed with your development certificate won't open until it's on, in Settings › Privacy & Security › Developer Mode. Your iPhone restarts.")
		XCTAssertEqual(off.summary, "Developer Mode off", "a problem comes before a source to add")

		// Running now says more than the setup's last reading.
		let running = Checkup(facts(certificate: development, ownProfile: try profile("adhoc.mobileprovision"), developerModeRead: false), for: .settings)
		XCTAssertEqual(try item(.developerMode, in: running).state, .ok)
	}

	func testDeveloperModeNotNeeded() throws {
		let enterprise = Checkup(facts(certificate: try stored("enterprise.mobileprovision"), ownProfile: try profile("adhoc.mobileprovision")), for: .settings)
		XCTAssertFalse(enterprise.items.contains { $0.kind == .developerMode })
		// Before there's a certificate, whether it's needed isn't known.
		XCTAssertFalse(Checkup(facts(developerModeRead: false), for: .getReady).items.contains { $0.kind == .developerMode })
	}

	// MARK: Sources

	func testSourcesThatFailed() throws {
		let broken = CheckupFacts.Source(name: "CyPwn IPA Library", refreshError: "The server didn't answer.")
		let one = Checkup(facts(sources: [added, broken]), for: .settings)
		let card = try item(.sources, in: one)
		XCTAssertEqual(card.state, .warning)
		XCTAssertEqual(card.title, "CyPwn IPA Library couldn't be read")
		XCTAssertEqual(card.text, "The server didn't answer. Browse shows its apps as they were.")
		XCTAssertEqual(card.actions, [.refreshSources])

		let two = Checkup(facts(sources: [broken, CheckupFacts.Source(name: "AltStore", refreshError: "Not found.")]), for: .settings)
		XCTAssertEqual(try item(.sources, in: two).title, "2 sources couldn't be read")

		let fine = Checkup(facts(sources: [added, CheckupFacts.Source(name: "AltStore"), CheckupFacts.Source(name: "Atelier", isBuiltIn: true)]), for: .settings)
		XCTAssertEqual(try item(.sources, in: fine).title, "Sources")
		XCTAssertEqual(try item(.sources, in: fine).value, "2 added", "Atelier's own doesn't count")
	}

	func testGitHubSignIn() throws {
		let atelier = CheckupFacts.Source(name: "Atelier", isBuiltIn: true, refreshError: "Sign in to GitHub to load it.", needsGitHubSignIn: true)
		let checkup = Checkup(facts(sources: [atelier]), for: .getReady)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .sources, .gitHubSignIn, .setup])
		XCTAssertEqual(try item(.sources, in: checkup).state, .todo, "Atelier's own source isn't one you added")
		let card = try item(.gitHubSignIn, in: checkup)
		XCTAssertEqual(card.title, "Atelier needs a GitHub sign-in")
		XCTAssertEqual(card.text, "Its source is in a private GitHub repo, so Atelier can't see its own updates until you sign in.")
		XCTAssertEqual(card.actions, [.signInToGitHub])

		// Of another's, GitHub only says it can't find it.
		let other = CheckupFacts.Source(name: "Private Builds", refreshError: "Sign in to GitHub to load it.", needsGitHubSignIn: true)
		let theirs = Checkup(facts(sources: [other]), for: .settings)
		XCTAssertEqual(try item(.gitHubSignIn, in: theirs).text, "GitHub can't find it without an account. If it's in a private repo, sign in with an account that can see it.")
		XCTAssertEqual(try item(.sources, in: theirs).state, .ok, "it's added, and the sign-in card says the rest")
		let both = Checkup(facts(sources: [atelier, other]), for: .settings)
		XCTAssertEqual(try item(.gitHubSignIn, in: both).title, "2 sources need a GitHub sign-in")
	}

	// MARK: How Atelier installs

	func testInstallServer() throws {
		let offline = Checkup(facts(installServer: .unreachable("The Internet connection appears to be offline.")), for: .getReady)
		XCTAssertEqual(offline.items.map(\.kind), [.certificate, .sources, .installServer, .setup], "Get Ready says so when it fails")
		let card = try item(.installServer, in: offline)
		XCTAssertEqual(card.state, .warning)
		XCTAssertEqual(card.text, "Installs through the iOS alert go through api.atelierstore.app. Check your connection, then try again.")
		XCTAssertEqual(card.actions, [.checkInstallServer])

		let failing = Checkup(facts(installServer: .unexpected(status: 503)), for: .settings)
		XCTAssertEqual(try item(.installServer, in: failing).text, "Installs through the iOS alert go through api.atelierstore.app, and it answered with an error. Try again later. If you use your own server, check it in Settings › Installs › Advanced.")
	}

	func testSetupWithLocalDevVPNOff() throws {
		let checkup = Checkup(facts(certificate: try stored("enterprise.mobileprovision"), setup: .checked(.vpnOff), sources: [added]), for: .settings)
		let row = try item(.setup, in: checkup)
		XCTAssertEqual(row.state, .notice)
		XCTAssertEqual(row.value, "LocalDevVPN off")
		XCTAssertEqual(checkup.summary, "LocalDevVPN off", "Status names it, as the Setup row only says Finished")
		XCTAssertEqual(checkup.attention?.state, .notice)
	}

	func testAProblemComesBeforeTheSetup() throws {
		let revoked = try stored("enterprise.mobileprovision", revocation: .revoked(at: nil))
		let checkup = Checkup(facts(certificate: revoked, setup: .checked(.noWiFi), sources: [added]), for: .settings)
		XCTAssertEqual(checkup.summary, "Certificate revoked")
		let unchecked = Checkup(facts(certificate: try stored("enterprise.mobileprovision"), setup: .checking, sources: [added]), for: .settings)
		XCTAssertEqual(unchecked.summary, "All good", "nothing found yet")
	}

	func testWhatSettingsNamesFirst() throws {
		// Nothing to sign with comes before a server that didn't answer.
		let checkup = Checkup(facts(installServer: .unreachable("Offline.")), for: .settings)
		XCTAssertEqual(checkup.summary, "No certificate")
		// Apps also install from IPA files, so no source isn't something to fix.
		let noSources = Checkup(facts(certificate: try stored("enterprise.mobileprovision")), for: .settings)
		XCTAssertEqual(try item(.sources, in: noSources).state, .todo)
		XCTAssertNil(noSources.attention)
		XCTAssertEqual(noSources.summary, "All good")
	}

	// MARK: An Apple ID (#49)

	func testAnAppleIDInUse() throws {
		let account = try appleID()
		let days = account.expiry.daysLeft(now: now)
		let checkup = Checkup(facts(appleID: account, ownProfile: try profile("development.mobileprovision"), sources: [added]), for: .getReady)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .developerMode, .sources, .setup])
		let row = try item(.certificate, in: checkup)
		XCTAssertEqual(row.state, .ok, "an Apple ID in use counts as the certificate")
		XCTAssertEqual(row.value, "sam.test@icloud.com")
		XCTAssertEqual(row.text, "A free Apple ID's development certificate, made on this iPhone: not revoked, \(days) days left. Its apps install through the setup, 3 at a time on this iPhone.")
		let setup = try item(.setup, in: checkup)
		XCTAssertEqual(setup.state, .todo, "its apps only install through the setup")
		XCTAssertEqual(setup.text, "Apps signed with an Apple ID only install once this one-time setup is done.")
		XCTAssertEqual(setup.actions, [.setUp])
		XCTAssertEqual(checkup.summary, "Not set up")

		let setUp = Checkup(facts(appleID: account, ownProfile: try profile("development.mobileprovision"), setup: .checked(.ready), sources: [added]), for: .settings)
		XCTAssertEqual(try item(.setup, in: setUp).value, "Finished")
		XCTAssertEqual(setUp.summary, "All good")
		// An imported certificate in use doesn't need the setup.
		XCTAssertEqual(try item(.setup, in: Checkup(facts(certificate: try stored("enterprise.mobileprovision")), for: .getReady)).state, .optional)
	}

	func testAPaidAppleID() throws {
		let account = try appleID(isFree: false, revocation: nil)
		let days = account.expiry.daysLeft(now: now)
		let row = try item(.certificate, in: Checkup(facts(appleID: account), for: .settings))
		XCTAssertEqual(row.text, "An Apple ID's development certificate, made on this iPhone: not checked with Apple yet, \(days) days left. Its apps install through the setup.")
	}

	func testAnAppleIDsCertificateRevoked() throws {
		let revokedOn = Fixture.utc(2026, 10, 30)
		let checkup = Checkup(facts(appleID: try appleID(revocation: .revoked(at: revokedOn)), canUpdateAtelier: false, sources: [added]), for: .settings)
		let card = try item(.certificate, in: checkup)
		XCTAssertEqual(card.state, .problem)
		XCTAssertEqual(card.title, "Certificate revoked")
		XCTAssertEqual(card.text, "Apple revoked sam.test@icloud.com's certificate on \(revokedOn.formatted(date: .abbreviated, time: .omitted)). Apps signed with it won't open until they're signed again. Sign in with the Apple ID again, and Atelier makes a new one.")
		XCTAssertEqual(card.actions, [.signInWithAppleID], "Apple lists it no more, so signing in again makes another")
		XCTAssertFalse(checkup.items.contains { $0.kind == .ownUpdates }, "the revoked card says it all")
		XCTAssertEqual(checkup.summary, "Certificate revoked")
	}

	func testAnAppleIDsCertificateRunningOut() throws {
		let account = try appleID()
		let end = account.expiry.date
		let expired = try item(.certificate, in: Checkup(facts(appleID: account, now: end.addingTimeInterval(86_400)), for: .settings))
		XCTAssertEqual(expired.state, .problem)
		XCTAssertEqual(expired.title, "Certificate expired")
		XCTAssertEqual(expired.actions, [.signInWithAppleID])

		let soon = Checkup(facts(appleID: account, now: end.addingTimeInterval(-5 * 86_400)), for: .settings)
		let card = try item(.certificate, in: soon)
		XCTAssertEqual(card.state, .warning)
		XCTAssertEqual(card.title, "Certificate expires soon")
		XCTAssertTrue(try XCTUnwrap(card.text).hasPrefix("sam.test@icloud.com's certificate expires in 5 days, on "))
		XCTAssertTrue(try XCTUnwrap(card.text).hasSuffix("Sign out of the Apple ID in Certificates and sign in again, and Atelier makes a new one."))
		XCTAssertEqual(card.actions, [], "signing in again would find the same one, still listed")
		XCTAssertEqual(soon.summary, "Expires in 5 days")
	}

	func testDeveloperModeWithAnAppleID() throws {
		let off = Checkup(facts(appleID: try appleID(), developerModeRead: false, sources: [added]), for: .settings)
		let card = try item(.developerMode, in: off)
		XCTAssertEqual(card.state, .problem, "an Apple ID's certificate is a development one")
		XCTAssertEqual(card.text, "Apps signed with your Apple ID won't open until it's on, in Settings › Privacy & Security › Developer Mode. Your iPhone restarts.")
		let unknown = Checkup(facts(appleID: try appleID(), sources: [added]), for: .getReady)
		XCTAssertEqual(try item(.developerMode, in: unknown).text, "Apps signed with your Apple ID only open with it on. It's in Settings › Privacy & Security › Developer Mode, and your iPhone restarts.")
	}

	func testAteliersOwnUpdatesWithAnAppleID() throws {
		let checkup = Checkup(facts(appleID: try appleID(), canUpdateAtelier: false, ownProfile: try profile("development.mobileprovision"), setup: .checked(.ready), sources: [added]), for: .settings)
		XCTAssertEqual(checkup.items.map(\.kind), [.certificate, .ownUpdates, .developerMode, .installServer, .setup, .sources])
		XCTAssertEqual(checkup.summary, "Can't update Atelier", "an Apple ID signs apps for App IDs of its own, not Atelier's")
	}
}
