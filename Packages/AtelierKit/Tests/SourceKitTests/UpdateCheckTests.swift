import XCTest
@testable import SourceKit

final class UpdateCheckTests: XCTestCase {
	private let ipa = URL(string: "https://example.com/app.ipa")!
	private let installedAt = Date(timeIntervalSince1970: 1_790_000_000)

	private func version(_ version: String, build: String? = nil, daysAfterInstall: Double? = nil) -> AppVersion {
		AppVersion(version: version, buildVersion: build, date: daysAfterInstall.map { installedAt.addingTimeInterval($0 * 86_400) }, downloadURL: ipa)
	}

	private func app(_ versions: AppVersion...) -> SourceApp {
		SourceApp(name: "Delta", bundleID: "com.example.delta", versions: versions)
	}

	private func installed(_ version: String, build: String? = nil) -> InstalledRelease {
		InstalledRelease(version: version, buildVersion: build, installedAt: installedAt)
	}

	func testNewerVersionNumber() {
		let app = app(version("1.10"), version("1.9.2"))
		XCTAssertEqual(UpdateCheck.update(for: installed("1.9.2"), in: app)?.version, "1.10")
		XCTAssertNil(UpdateCheck.update(for: installed("1.10"), in: app))
		XCTAssertNil(UpdateCheck.update(for: installed("1.10.0"), in: app))
	}

	/// Every older version the source lists, numbered like a beta or not:
	/// only the source's marks make one a beta (#104).
	func testOlderVersions() {
		let app = app(version("3.0.1"), version("2.6.8"), version("2.6.8b1"), version("2.6.7"))
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("3.0.1"), in: app).map(\.version), ["2.6.8", "2.6.8b1", "2.6.7"])
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("2.6.8"), in: app).map(\.version), ["2.6.8b1", "2.6.7"])
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("2.6.7"), in: app), [])
	}

	func testOlderBuildsOfTheInstalledVersion() {
		let app = app(version("2.0", build: "12"), version("2.0", build: "11"))
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("2.0", build: "12"), in: app).map(\.buildVersion), ["11"])
	}

	func testOlderVersionsThatAreNotNumbers() {
		let app = app(version("nightly-9c3d", daysAfterInstall: 2), version("nightly-1f2e", daysAfterInstall: -2))
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("nightly-9c3d"), in: app).map(\.version), ["nightly-1f2e"])
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("nightly-7e5f"), in: app), [])
	}

	/// Atelier doesn't install an older build of itself (#24).
	func testOlderBuilds() {
		XCTAssertTrue(UpdateCheck.isOlder("0.1.0", build: "3", than: "0.2.0", build: "323"))
		XCTAssertTrue(UpdateCheck.isOlder("0.2.0", build: "323", than: "0.2.0", build: "330"))
		XCTAssertFalse(UpdateCheck.isOlder("0.2.0", build: "330", than: "0.2.0", build: "330"), "the same build")
		XCTAssertFalse(UpdateCheck.isOlder("0.3.0", build: "1", than: "0.2.0", build: "330"))
		XCTAssertTrue(UpdateCheck.isOlder("2.0b2", build: nil, than: "2.0", build: nil))
		XCTAssertFalse(UpdateCheck.isOlder("0.2.0", build: nil, than: "0.2.0", build: "330"), "without both build numbers")
		XCTAssertFalse(UpdateCheck.isOlder("nightly-1f2e", build: nil, than: "0.2.0", build: nil), "not numbers")
	}

	func testInstalledNewerThanTheSourceIsNoUpdate() {
		XCTAssertNil(UpdateCheck.update(for: installed("2.0"), in: app(version("1.9"))))
	}

	func testPrereleases() {
		XCTAssertEqual(UpdateCheck.update(for: installed("2.0b3"), in: app(version("2.0b10")))?.version, "2.0b10")
		XCTAssertNil(UpdateCheck.update(for: installed("2.0b10"), in: app(version("2.0b3"))))
	}

	/// A source lists its betas only while the user includes them (#104),
	/// so a release is offered whatever it lists, beta or not (29 Oct 2026);
	/// the rule of 22 Oct offered betas only to betas.
	func testAReleaseIsOfferedWhatTheSourceLists() {
		var beta = version("2.0b2")
		beta.isPrerelease = true
		let app = app(beta, version("1.9"), version("1.8"))
		XCTAssertEqual(UpdateCheck.update(for: installed("1.8"), in: app)?.version, "2.0b2")
		XCTAssertEqual(UpdateCheck.update(for: installed("1.9"), in: app)?.version, "2.0b2")
		let releases = Source(name: "Source", apps: [app]).withoutPrereleases().apps[0]
		XCTAssertEqual(UpdateCheck.update(for: installed("1.8"), in: releases)?.version, "1.9")
		XCTAssertNil(UpdateCheck.update(for: installed("1.9"), in: releases))
	}

	func testABetaIsOfferedBetasAndReleases() {
		XCTAssertEqual(UpdateCheck.update(for: installed("2.0b1"), in: app(version("2.0b2"), version("1.9")))?.version, "2.0b2")
		XCTAssertEqual(UpdateCheck.update(for: installed("2.0b2"), in: app(version("2.0"), version("2.0b2")))?.version, "2.0")
		XCTAssertNil(UpdateCheck.update(for: installed("2.0b2"), in: app(version("1.9"))))
		// Sorted by compareRelease, a source lists 2.0b2 before 2.0.
		XCTAssertEqual(UpdateCheck.update(for: installed("2.0b1"), in: app(version("2.0b2"), version("2.0")))?.version, "2.0")
	}

	func testBetaListings() {
		let beta = SourceApp(name: "Delta", bundleID: "com.example.delta", versions: [version("2.0")], isBeta: true)
		// Listed, as another source's beta app is while its pre-releases are.
		XCTAssertEqual(UpdateCheck.update(for: installed("1.9"), in: beta)?.version, "2.0")
		let fromBeta = InstalledRelease(version: "1.9", installedAt: installedAt, fromBetaListing: true)
		XCTAssertEqual(UpdateCheck.update(for: fromBeta, in: beta)?.version, "2.0")
		XCTAssertEqual(UpdateCheck.update(for: fromBeta, in: app(version("2.0b1")))?.version, "2.0b1")
	}

	/// A GitHub pre-release's IPA has a plain version number: the source
	/// says it's a beta (#104). It's listed only while the user includes the
	/// repo's pre-releases, so a release is offered it too (29 Oct 2026).
	func testBetasTheSourceMarks() {
		var beta = version("2.0", build: "5")
		beta.isPrerelease = true
		let app = app(beta, version("1.9", build: "4"))
		XCTAssertEqual(UpdateCheck.update(for: installed("1.9", build: "4"), in: app), beta, "a release is offered an included pre-release")
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed("2.1"), in: app).map(\.version), ["2.0", "1.9"])
		XCTAssertEqual(Source(name: "Repo", apps: [app]).withoutPrereleases().apps[0].versions.map(\.version), ["1.9"])

		// Installed as that pre-release, it's a beta, offered newer betas
		// and releases.
		let installedBeta = InstalledRelease(version: "2.0", buildVersion: "5", installedAt: installedAt, listing: app)
		XCTAssertTrue(installedBeta.isBeta)
		XCTAssertFalse(InstalledRelease(version: "1.9", buildVersion: "4", installedAt: installedAt, listing: app).isBeta)
		var newerBeta = version("2.1", build: "6")
		newerBeta.isPrerelease = true
		XCTAssertEqual(UpdateCheck.update(for: installedBeta, in: self.app(newerBeta, beta, version("1.9", build: "4")))?.version, "2.1")
		XCTAssertEqual(UpdateCheck.update(for: installedBeta, in: self.app(version("2.0", build: "7"), beta))?.buildVersion, "7")

		// Atelier's own source shows its alpha as 0.2.0-alpha, and flags
		// Atelier as a beta: the flag makes it one, never the number.
		var alpha = version("0.2.0", build: "330")
		alpha.marketingVersion = "0.2.0-alpha"
		XCTAssertFalse(InstalledRelease(version: "0.2.0", buildVersion: "330", installedAt: installedAt, listing: self.app(alpha)).isBeta)
		XCTAssertTrue(InstalledRelease(version: "0.2.0", buildVersion: "330", installedAt: installedAt, listing: SourceApp(name: "Atelier", bundleID: "com.atelier.app", versions: [alpha], isBeta: true)).isBeta)
		XCTAssertFalse(installed("2.0b3").isBeta)
	}

	/// A GitHub pre-release whose IPA Atelier didn't read lists its tag as
	/// its version (#104): an installed 0.6.3 is its 0.6.3-beta.
	func testInstalledBetaListedByItsTag() {
		var tagged = version("0.6.3-beta")
		tagged.isPrerelease = true
		var newer = version("0.6.4", build: "150")
		newer.isPrerelease = true
		let app = app(newer, tagged, version("0.4.21", build: "126"))
		let installed = InstalledRelease(version: "0.6.3", buildVersion: "149", installedAt: installedAt, listing: app)
		XCTAssertEqual(UpdateCheck.installedEntry(installed, in: app), tagged)
		XCTAssertTrue(installed.isBeta)
		XCTAssertEqual(UpdateCheck.update(for: installed, in: app), newer)
		XCTAssertEqual(UpdateCheck.olderVersions(than: installed, in: app).map(\.version), ["0.4.21"], "not itself")

		// Only a pre-release without a build number, which wasn't read.
		var read = version("0.6.3-beta", build: "149")
		read.isPrerelease = true
		XCTAssertNil(UpdateCheck.installedEntry(installed, in: self.app(read)))
		XCTAssertNil(UpdateCheck.installedEntry(installed, in: self.app(version("0.6.3-beta"))), "an AltStore source's own version")
	}

	func testTags() {
		XCTAssertTrue(UpdateCheck.isTag("0.6.3-beta", of: "0.6.3"))
		XCTAssertTrue(UpdateCheck.isTag("2.0b3", of: "2.0"))
		XCTAssertTrue(UpdateCheck.isTag("1.0-rc.1", of: "1.0"))
		XCTAssertFalse(UpdateCheck.isTag("0.6.3", of: "0.6.3"))
		XCTAssertFalse(UpdateCheck.isTag("0.6.30-beta", of: "0.6.3"))
		XCTAssertFalse(UpdateCheck.isTag("0.6.3.1-beta", of: "0.6.3"))
		XCTAssertFalse(UpdateCheck.isTag("nightly-148", of: "0.6.3"))
		XCTAssertFalse(UpdateCheck.isTag("0.6.3-beta", of: ""))
	}

	func testBuildOnlyBump() {
		let app = app(version("9.0.52", build: "124"), version("9.0.52", build: "120"))
		XCTAssertEqual(UpdateCheck.update(for: installed("9.0.52", build: "120"), in: app)?.buildVersion, "124")
		XCTAssertNil(UpdateCheck.update(for: installed("9.0.52", build: "124"), in: app))
		// Build numbers compare as numbers.
		XCTAssertEqual(UpdateCheck.update(for: installed("9.0.52", build: "99"), in: app)?.buildVersion, "124")
	}

	func testSameVersionWithoutBuildNumbersIsNoUpdate() {
		XCTAssertNil(UpdateCheck.update(for: installed("1.2", build: "5"), in: app(version("1.2"))))
		XCTAssertNil(UpdateCheck.update(for: installed("1.2"), in: app(version("1.2"))))
	}

	func testBuildBumpForAnInstallWithoutItsBuildNumberGoesByDate() {
		let dated = app(version("1.2", build: "7", daysAfterInstall: 3))
		XCTAssertEqual(UpdateCheck.update(for: installed("1.2"), in: dated)?.buildVersion, "7")
		let before = app(version("1.2", build: "7", daysAfterInstall: -3))
		XCTAssertNil(UpdateCheck.update(for: installed("1.2"), in: before))
		XCTAssertNil(UpdateCheck.update(for: installed("1.2"), in: app(version("1.2", build: "7"))))
	}

	func testVersionsThatArentNumbersGoByDate() {
		let app = app(version("nightly-b2", daysAfterInstall: 5), version("nightly-a9", daysAfterInstall: -1))
		XCTAssertEqual(UpdateCheck.update(for: installed("nightly-a9"), in: app)?.version, "nightly-b2")
		XCTAssertNil(UpdateCheck.update(for: installed("nightly-b2"), in: app))
		// Lexically "nightly-z1" sorts after "nightly-b2", but its date is older.
		let reversed = SourceApp(name: "Delta", bundleID: "com.example.delta", versions: [
			version("nightly-b2", daysAfterInstall: 5), version("nightly-z1", daysAfterInstall: -10),
		])
		XCTAssertEqual(UpdateCheck.update(for: installed("nightly-z1"), in: reversed)?.version, "nightly-b2")
	}

	func testVersionsThatArentNumbersWithoutDatesGoBySourceOrder() {
		let app = app(version("abc123"), version("def456"))
		XCTAssertEqual(UpdateCheck.update(for: installed("def456"), in: app)?.version, "abc123")
		XCTAssertNil(UpdateCheck.update(for: installed("abc123"), in: app))
		// A version the source doesn't list can't be placed.
		XCTAssertNil(UpdateCheck.update(for: installed("zzz999"), in: app))
	}

	func testSkippedVersion() {
		let app = app(version("1.3", build: "40"), version("1.2"))
		XCTAssertNil(UpdateCheck.update(for: installed("1.2"), in: app, skipping: "1.3 (40)"))
		// A new build of the skipped version shows again.
		let rebuilt = self.app(version("1.3", build: "41"), version("1.2"))
		XCTAssertEqual(UpdateCheck.update(for: installed("1.2"), in: rebuilt, skipping: "1.3 (40)")?.buildVersion, "41")
		XCTAssertEqual(UpdateCheck.key(of: version("1.3")), "1.3")
	}

	func testOnlyVersionsThisDeviceCanRun() {
		let tooNew = AppVersion(version: "2.0", downloadURL: ipa, minOSVersion: OSVersion("99.0"))
		let app = SourceApp(name: "Delta", bundleID: "com.example.delta", versions: [tooNew, version("1.5"), version("1.0")])
		XCTAssertEqual(UpdateCheck.update(for: installed("1.0"), in: app, on: OSVersion("27.0")!)?.version, "1.5")
	}

	func testReleaseIsNewerThanItsPrereleases() {
		XCTAssertEqual(UpdateCheck.compareNumeric("2.0", "2.0b2"), .orderedDescending)
		XCTAssertEqual(UpdateCheck.compareNumeric("2.0-beta.3", "2.0"), .orderedAscending)
		XCTAssertEqual(UpdateCheck.compareNumeric("2.0rc1", "2.0b9"), .orderedDescending)
		XCTAssertEqual(UpdateCheck.compareNumeric("2.0b3", "2.0b10"), .orderedAscending)
		XCTAssertEqual(UpdateCheck.compareNumeric("2.1b1", "2.0"), .orderedDescending)
	}

	func testNumericVersions() {
		XCTAssertTrue(VersionNumber.isNumeric("26.40.0"))
		XCTAssertTrue(VersionNumber.isNumeric("2.0b3"))
		XCTAssertTrue(VersionNumber.isNumeric("2.0-beta.3"))
		XCTAssertFalse(VersionNumber.isNumeric("nightly-a9"))
		XCTAssertFalse(VersionNumber.isNumeric("v1.2"))
		XCTAssertFalse(VersionNumber.isNumeric(""))
	}
}
