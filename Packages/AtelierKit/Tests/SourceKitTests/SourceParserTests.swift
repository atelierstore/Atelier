import XCTest
@testable import SourceKit

final class SourceParserTests: XCTestCase {
	private func parse(_ fixture: String) throws -> SourceParser.Result {
		let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
		return try SourceParser.parse(Data(contentsOf: url))
	}

	private func date(_ string: String) -> Date {
		ISO8601DateFormatter().date(from: string)!
	}

	// MARK: Classic v2

	func testAltStoreClassicSource() throws {
		let result = try parse("altstore-classic")
		let source = result.source
		XCTAssertEqual(source.name, "AltStore")
		XCTAssertEqual(source.identifier, "com.rileytestut.AltStore")
		XCTAssertEqual(source.apps.map(\.bundleID), [
			"com.rileytestut.AltStore", "com.rileytestut.AltStore.Beta", "com.rileytestut.Delta",
			"com.rileytestut.Delta.Beta", "com.rileytestut.Clip", "com.rileytestut.Clip.Beta",
		])
		XCTAssertEqual(source.featuredApps.map(\.bundleID), ["com.rileytestut.Delta", "com.rileytestut.Clip"])
		XCTAssertEqual(source.news.count, 4)
		XCTAssertEqual(source.newsNewestFirst.first?.identifier, "ios-13-4-now-available")
		XCTAssertEqual(source.newsNewestFirst.last?.identifier, "delta-ds-support")

		let delta = try XCTUnwrap(source.app(bundleID: "com.rileytestut.Delta"))
		XCTAssertEqual(delta.category, .games)
		XCTAssertEqual(delta.versions.count, 3)
		let latest = try XCTUnwrap(delta.latestVersion)
		XCTAssertEqual(latest.version, "1.7.1")
		XCTAssertEqual(latest.buildVersion, "139")
		XCTAssertEqual(latest.displayVersion, "1.7.1 (139)")
		XCTAssertEqual(latest.date, date("2025-04-08T14:00:00-05:00"))
		XCTAssertEqual(latest.minOSVersion, OSVersion("14.0"))
		XCTAssertEqual(latest.downloadURL.absoluteString, "https://cdn.altstore.io/file/altstore/apps/delta/1_7_1.ipa")
		XCTAssertEqual(delta.downloadKind(of: latest), .ipa)
		XCTAssertEqual(delta.screenshots.iphone.count, 6)

		// Object-form appPermissions, as AltStore's own source writes them.
		let altStore = try XCTUnwrap(source.app(bundleID: "com.rileytestut.AltStore"))
		XCTAssertEqual(altStore.permissions.entitlements, [
			"get-task-allow", "com.apple.security.application-groups", "aps-environment", "com.apple.developer.siri",
		])
		XCTAssertEqual(
			altStore.permissions.privacy["NSLocalNetworkUsageDescription"],
			"AltStore uses the local network to find and communicate with AltServer."
		)

		// Split screenshots, a marketing version and a Patreon-only download.
		let deltaBeta = try XCTUnwrap(source.app(bundleID: "com.rileytestut.Delta.Beta"))
		XCTAssertEqual(deltaBeta.screenshots.iphone.count, 6)
		XCTAssertEqual(deltaBeta.screenshots.ipad.count, 4)
		XCTAssertTrue(deltaBeta.screenshots.ipad.allSatisfy { $0.width != nil && $0.height != nil })
		XCTAssertEqual(deltaBeta.latestVersion?.displayVersion, "2.0rc (175)")
		XCTAssertEqual(deltaBeta.patreon, PatreonRequirement(pledge: 3, benefit: "1186336"))
		XCTAssertEqual(deltaBeta.availability(on: OSVersion("27.0")!), .notInstallable(.patreonOnly))
	}

	func testUTMSource() throws {
		let result = try parse("utm")
		XCTAssertEqual(result.warnings, [])
		let source = result.source
		XCTAssertEqual(source.name, "UTM Repository")
		XCTAssertEqual(source.apps.map(\.bundleID), ["com.utmapp.UTM", "com.utmapp.UTM-SE"])
		let utm = source.apps[0]
		XCTAssertEqual(utm.screenshots.iphone.count, 7, "screenshotURLs")
		XCTAssertEqual(utm.latestVersion?.size, 150_556_413)
		XCTAssertEqual(utm.latestVersion?.date, date("2026-10-17T02:44:56Z"))
		XCTAssertEqual(utm.availability(on: OSVersion("27.0.1")!).version?.version, "5.0.8")
		XCTAssertEqual(utm.availability(on: OSVersion("13.7")!), .notInstallable(.unsupportedOS(min: OSVersion("14.0"), max: nil)))
	}

	func testQuantumSource() throws {
		let result = try parse("quantum")
		let source = result.source
		XCTAssertEqual(source.apps.count, 5)

		// Seven fractional digits.
		let dolphin = try XCTUnwrap(source.app(bundleID: "me.oatmealdome.DolphiniOS-njb-patreon-beta"))
		XCTAssertEqual(dolphin.latestVersion?.date, date("2025-10-23T02:30:00Z"))
		XCTAssertEqual(dolphin.permissions.entitlements, [])
		XCTAssertEqual(dolphin.permissions.privacy.keys.sorted(), ["NSLocalNetworkUsageDescription"])

		// "2023-2-02T03:00:00-05:00": a month without its leading zero.
		let deltroid = try XCTUnwrap(source.app(bundleID: "com.rileytestut.Deltroid"))
		XCTAssertEqual(deltroid.versions.last?.date, date("2023-02-02T03:00:00-05:00"))

		// Empty lists where the spec has a list and a dictionary.
		let emuThreeDS = try XCTUnwrap(source.app(bundleID: "com.antique.emuThreeDS"))
		XCTAssertEqual(emuThreeDS.permissions, AppPermissions())
		XCTAssertEqual(source.featuredApps.map(\.bundleID), ["com.antique.emuThreeDS"])

		XCTAssertFalse(result.warnings.contains { $0.message.contains("date") }, "\(result.warnings)")
	}

	// MARK: Filtering by iOS version

	func testVersionsAreFilteredByOSVersion() throws {
		let source = try parse("quantum").source

		// Odyssey 1.4.3 is for iOS 13.0 to 13.7; 1.4.2 has no limits.
		let odyssey = try XCTUnwrap(source.app(bundleID: "org.coolstar.odyssey"))
		XCTAssertEqual(odyssey.latestVersion(supporting: OSVersion("13.5")!)?.version, "1.4.3")
		XCTAssertEqual(odyssey.latestVersion(supporting: OSVersion("13.7")!)?.version, "1.4.3")
		XCTAssertEqual(odyssey.latestVersion(supporting: OSVersion("13.7.1")!)?.version, "1.4.3", "the maximum is inclusive of its patch releases")
		XCTAssertEqual(odyssey.latestVersion(supporting: OSVersion("27.0")!)?.version, "1.4.2")
		XCTAssertEqual(odyssey.versions(supporting: OSVersion("12.4")!).map(\.version), ["1.4.2"])

		// One version, for iOS 16.1.2 and earlier.
		let wdb = try XCTUnwrap(source.app(bundleID: "com.worthdoingbadly.WDBRemoveThreeAppLimit"))
		XCTAssertEqual(wdb.availability(on: OSVersion("16.1.2")!).version?.version, "1.0")
		XCTAssertEqual(wdb.availability(on: OSVersion("16.2")!), .notInstallable(.unsupportedOS(min: nil, max: OSVersion("16.1.2"))))
		XCTAssertEqual(NotInstallableReason.unsupportedOS(min: nil, max: OSVersion("16.1.2")).message, "Requires iOS 16.1.2 or earlier.")
	}

	func testOSVersionComparison() {
		XCTAssertEqual(OSVersion("17"), OSVersion("17.0.0"))
		XCTAssertLessThan(OSVersion("16.3")!, OSVersion("16.3.1")!)
		XCTAssertLessThan(OSVersion("9.3")!, OSVersion("10.0")!)
		XCTAssertNil(OSVersion("17.a"))
		XCTAssertNil(OSVersion("1.2.3.4"))
		XCTAssertNil(OSVersion(""))
		XCTAssertEqual(Set([OSVersion("17")!, OSVersion("17.0")!]).count, 1)
	}

	// MARK: Atelier's own source

	/// What scripts/update_source.py writes for two releases (#23), so a change
	/// on either side that Atelier can't read fails here.
	func testAtelierReleaseSource() throws {
		let result = try parse("atelier-release")
		XCTAssertEqual(result.warnings, [])
		let app = try XCTUnwrap(result.source.app(bundleID: "com.atelier.app"))
		XCTAssertEqual(app.category, .utilities)
		XCTAssertEqual(app.versions.map(\.displayVersion), ["0.2.0 (2)", "0.1.0 (1)"])
		let latest = try XCTUnwrap(app.latestVersion)
		XCTAssertEqual(latest.version, "0.2.0")
		XCTAssertEqual(latest.minOSVersion, OSVersion("17.0"))
		XCTAssertEqual(latest.date, date("2026-11-01T12:00:00Z"))
		XCTAssertEqual(latest.size, 1366)
		XCTAssertEqual(latest.sha256?.count, 64)
		XCTAssertEqual(app.permissions.privacy["NSCameraUsageDescription"], "Scans QR codes.")
		// From release/screenshots, with their sizes and a hash of each file.
		XCTAssertEqual(app.screenshots.iphone.map(\.imageURL.lastPathComponent), ["1-browse.png", "2-app.png"])
		XCTAssertEqual(app.screenshots.iphone.first?.imageURL.query, "v=5d41402a")
		XCTAssertEqual(app.screenshots.iphone.map(\.width), [1179, 1179])
		XCTAssertEqual(app.screenshots.iphone.map(\.height), [2556, 2556])
		XCTAssertEqual(app.screenshots.ipad, [])
		XCTAssertEqual(result.source.tintColor, "4B8B65")
		XCTAssertEqual(app.tintColor, "4B8B65")
		// A news item for each release, with its What's New and the app.
		XCTAssertEqual(result.source.newsNewestFirst.map(\.title), ["Atelier 0.2.0 is out", "Atelier 0.1.0 is out"])
		let news = try XCTUnwrap(result.source.newsNewestFirst.first)
		XCTAssertEqual(news.caption, "Second release.")
		XCTAssertEqual(news.date, latest.date)
		XCTAssertEqual(news.appID, app.bundleID)
	}

	// MARK: Legacy v1

	func testLegacyV1Source() throws {
		let result = try parse("flycast-v1")
		XCTAssertEqual(result.warnings, [])
		let flycast = try XCTUnwrap(result.source.apps.first)
		XCTAssertEqual(flycast.bundleID, "com.flyinghead.Flycast")
		XCTAssertEqual(flycast.versions.count, 1)
		let version = try XCTUnwrap(flycast.latestVersion)
		XCTAssertEqual(version.version, "v2.5")
		XCTAssertEqual(version.date, date("2025-05-07T11:36:00+02:00"))
		XCTAssertEqual(version.localizedDescription, "DCNet support, new on-screen gamepad")
		XCTAssertEqual(version.size, 8_161_611)
		XCTAssertEqual(version.downloadURL.absoluteString, "https://github.com/flyinghead/flycast/releases/download/v2.5/Flycast-2.5.ipa")
		XCTAssertEqual(flycast.tintColor, "9B54FD")
		XCTAssertEqual(flycast.screenshots.iphone.count, 3)
		XCTAssertFalse(flycast.isBeta)
		XCTAssertEqual(flycast.availability(on: OSVersion("27.0")!), .installable(version))
	}

	func testTrailingCommasAreAccepted() throws {
		let result = try parse("thatstella-v1-trailing-comma")
		let app = try XCTUnwrap(result.source.apps.first)
		XCTAssertEqual(app.bundleID, "thatstel.la.battery-webhook")
		// The versions list wins over the v1 fields beside it.
		XCTAssertEqual(app.versions.map(\.version), ["1.3", "1.2", "1.1", "1.0"])
		XCTAssertEqual(result.source.tintColor, "E872E2")
	}

	func testTrailingCommaRemovalLeavesStringsAlone() throws {
		let json = #"{"name": "a, ]", "apps": [{"name": "x,}", "bundleIdentifier": "b", "versions": [{"version": "1", "downloadURL": "https://e.com/a.ipa",},],},],}"#
		let source = try SourceParser.parse(Data(json.utf8)).source
		XCTAssertEqual(source.name, "a, ]")
		XCTAssertEqual(source.apps.first?.name, "x,}")
	}

	// MARK: AltStore PAL

	func testPALAppsAreListedButNotInstallable() throws {
		let source = try parse("pal").source
		XCTAssertEqual(source.apps.count, 2, "PAL apps are kept, not hidden")
		for app in source.apps {
			XCTAssertNotNil(app.marketplaceID)
			XCTAssertEqual(app.availability(on: OSVersion("27.0")!), .notInstallable(.alternativeDistributionOnly))
			XCTAssertTrue(app.versions.allSatisfy { app.downloadKind(of: $0) == .alternativeDistributionPackage })
		}
		let another = try XCTUnwrap(source.app(bundleID: "com.example.anotherapp"))
		XCTAssertEqual(another.latestVersion?.assetURLs.count, 3)
		XCTAssertEqual(another.screenshots.ipad.count, 2)
		XCTAssertTrue(NotInstallableReason.alternativeDistributionOnly.message.hasPrefix("Not installable with Atelier."))
	}

	func testDownloadKind() throws {
		func kind(_ url: String, marketplaceID: String? = nil, assets: Bool = false) -> DownloadKind {
			let version = AppVersion(version: "1", downloadURL: URL(string: url)!, assetURLs: assets ? ["manifest": URL(string: url)!] : [:])
			return SourceApp(name: "A", bundleID: "a", marketplaceID: marketplaceID, versions: [version]).downloadKind(of: version)
		}
		XCTAssertEqual(kind("https://example.com/app.ipa"), .ipa)
		XCTAssertEqual(kind("https://dl.pokemmo.com/PokeMMO-Client.ipa?r=32920"), .ipa)
		XCTAssertEqual(kind("https://example.com/download.php?id=4"), .ipa, "an unknown URL is tried as an IPA")
		XCTAssertEqual(kind("https://example.com/app.ipa", marketplaceID: "123"), .ipa)
		XCTAssertEqual(kind("https://example.com/adp/manifest.json"), .alternativeDistributionPackage)
		XCTAssertEqual(kind("https://example.com/adp/"), .alternativeDistributionPackage)
		XCTAssertEqual(kind("https://example.com/adp", marketplaceID: "123"), .alternativeDistributionPackage)
		XCTAssertEqual(kind("https://example.com/x", assets: true), .alternativeDistributionPackage)
		XCTAssertEqual(kind("https://www.patreon.com/file?h=1&m=2"), .patreon)
	}

	// MARK: Malformed input

	func testMalformedSourceKeepsWhatItCan() throws {
		let result = try parse("malformed")
		let source = result.source
		XCTAssertNil(source.tintColor)
		// Same bundle ID, another name: another app.
		XCTAssertEqual(source.apps.map(\.bundleID), ["com.example.good", "com.example.good"])
		XCTAssertEqual(source.apps.map(\.name), ["Good App", "Duplicate Good App"])
		XCTAssertEqual(source.featuredAppIDs, ["com.example.good", "com.example.missing"])
		XCTAssertEqual(source.featuredApps.map(\.bundleID), ["com.example.good"])
		XCTAssertEqual(source.news.map(\.identifier), ["fine"])

		let app = source.apps[0]
		XCTAssertEqual(app.category, .other)
		XCTAssertEqual(app.tintColor, "F54F32")
		XCTAssertEqual(app.versions.map(\.version), ["2.0", "1.5", "1.0"])
		XCTAssertNil(app.versions[0].date)
		XCTAssertEqual(app.versions[0].size, 1234)
		XCTAssertEqual(app.versions[1].size, 1000)
		XCTAssertEqual(app.versions[1].date, date("2024-01-02T00:00:00Z"))
		XCTAssertEqual(app.screenshots.iphone.map(\.imageURL.absoluteString), ["https://example.com/1.png", "https://example.com/2.png"])
		XCTAssertNil(app.screenshots.iphone[1].width)
		XCTAssertEqual(app.permissions, AppPermissions())

		// 2.0 needs iOS 99; 1.5 has no limits.
		XCTAssertEqual(app.availability(on: OSVersion("27.0")!).version?.version, "1.5")
		// 1.0 stops at 16.3, but 1.5 still covers older devices.
		XCTAssertEqual(app.availability(on: OSVersion("12.0")!).version?.version, "1.5")

		let messages = result.warnings.map(\.description)
		for expected in [
			"apps[0] (com.example.good).versions[0]: date \"not a date\" isn't an ISO 8601 date; ignored",
			"apps[0] (com.example.good).versions[2]: skipped: no http(s) downloadURL",
			"apps[0] (com.example.good).versions[3]: skipped: not an object",
			"apps[1]: skipped: no bundleIdentifier",
			"apps[2] (com.example.noversions): skipped: no usable version",
			"apps[3] (com.example.brokenversions): skipped: no usable version",
			"apps[5]: skipped: not an object",
			"apps[6] (com.example.noname): skipped: no name",
			"featuredApps[1]: no app with bundle ID com.example.missing",
			"featuredApps[2]: not a bundle ID; ignored",
			"news[1]: skipped: no identifier",
			"news[2] (fine): skipped: another news item has the same identifier",
		] {
			XCTAssertTrue(messages.contains(expected), "missing warning: \(expected)\nall: \(messages)")
		}
	}

	func testInputThatIsNotASourceThrows() {
		XCTAssertThrowsError(try SourceParser.parse(Data("<html>Not found</html>".utf8))) { error in
			guard case SourceParser.Error.notJSON = error else { return XCTFail("\(error)") }
		}
		XCTAssertThrowsError(try SourceParser.parse(Data("[]".utf8))) { error in
			XCTAssertEqual(error as? SourceParser.Error, .notAnObject)
		}
		XCTAssertThrowsError(try SourceParser.parse(Data()))
	}

	func testSourceWithoutNameOrApps() throws {
		let result = try SourceParser.parse(Data(#"{"identifier": "com.example.empty"}"#.utf8))
		XCTAssertEqual(result.source.name, "com.example.empty")
		XCTAssertEqual(result.source.apps, [])
		XCTAssertEqual(result.warnings.map(\.path), ["name", "apps"])
	}

	// MARK: Dates

	func testDates() {
		XCTAssertEqual(SourceDate.parse("2023-02-17"), date("2023-02-17T00:00:00Z"))
		XCTAssertEqual(SourceDate.parse("2023-2-7"), date("2023-02-07T00:00:00Z"))
		XCTAssertEqual(SourceDate.parse("2023-02-17T12:00:00-06:00"), date("2023-02-17T18:00:00Z"))
		XCTAssertEqual(SourceDate.parse("2023-02-17T12:00:00+0200"), date("2023-02-17T10:00:00Z"))
		XCTAssertEqual(SourceDate.parse("2023-02-17T12:00Z"), date("2023-02-17T12:00:00Z"))
		XCTAssertEqual(SourceDate.parse("2023-02-17T12:00:00.5Z")?.timeIntervalSince(date("2023-02-17T12:00:00Z")) ?? 0, 0.5, accuracy: 0.001)
		XCTAssertNil(SourceDate.parse("2023-02-31"))
		XCTAssertNil(SourceDate.parse("17 Feb 2023"))
		XCTAssertNil(SourceDate.parse("2023-02-17T25:00:00Z"))
		XCTAssertNil(SourceDate.parse("2023-02-17garbage"))
	}
}
