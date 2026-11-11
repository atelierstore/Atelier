import XCTest
@testable import SourceKit

final class CatalogTests: XCTestCase {
	private let ipa = URL(string: "https://example.com/app.ipa")!

	private func info(_ name: String) -> Catalog.SourceInfo {
		Catalog.SourceInfo(url: URL(string: "https://\(name.lowercased()).example.com/source.json")!, name: name)
	}

	private func app(
		_ bundleID: String,
		name: String? = nil,
		developer: String? = nil,
		category: AppCategory = .other,
		version: String = "1.0",
		build: String? = nil,
		date: Date? = nil,
		minOS: String? = nil
	) -> SourceApp {
		SourceApp(
			name: name ?? bundleID,
			bundleID: bundleID,
			developerName: developer,
			category: category,
			versions: [AppVersion(version: version, buildVersion: build, date: date, downloadURL: ipa, minOSVersion: minOS.flatMap(OSVersion.init))]
		)
	}

	// MARK: Merging sources

	func testSameBundleIDInSeveralSourcesIsOneEntryPreferringTheNewestVersion() throws {
		let older = Source(name: "Older", apps: [app("com.example.delta", version: "1.9.2"), app("com.example.only")])
		let newer = Source(name: "Newer", apps: [app("com.example.delta", version: "1.10")])
		let catalog = Catalog(sources: [(info("Older"), older), (info("Newer"), newer)])

		XCTAssertEqual(catalog.entries.map(\.bundleID), ["com.example.delta", "com.example.only"])
		let delta = try XCTUnwrap(catalog.entry(bundleID: "com.example.delta"))
		XCTAssertEqual(delta.offers.map(\.source.name), ["Newer", "Older"])
		XCTAssertEqual(delta.preferred.app.latestVersion?.version, "1.10")
		// Picking a source, or one that doesn't list the app.
		XCTAssertEqual(delta.offer(from: info("Older").url).source.name, "Older")
		XCTAssertEqual(delta.offer(from: info("Elsewhere").url).source.name, "Newer")
	}

	func testEqualVersionsKeepTheOrderSourcesWereAddedIn() throws {
		let a = Source(name: "A", apps: [app("com.example.app", version: "2.0")])
		let b = Source(name: "B", apps: [app("com.example.app", version: "2.0.0")])
		let catalog = Catalog(sources: [(info("A"), a), (info("B"), b)])
		XCTAssertEqual(catalog.entry(bundleID: "com.example.app")?.offers.map(\.source.name), ["A", "B"])
	}

	func testBuildNumberThenDateBreakTies() throws {
		let early = Date(timeIntervalSince1970: 1_700_000_000)
		let late = early.addingTimeInterval(86400)
		let byBuild = Catalog(sources: [
			(info("A"), Source(name: "A", apps: [app("com.example.app", version: "2.0", build: "9")])),
			(info("B"), Source(name: "B", apps: [app("com.example.app", version: "2.0", build: "10")])),
		])
		XCTAssertEqual(byBuild.entry(bundleID: "com.example.app")?.preferred.source.name, "B")
		let byDate = Catalog(sources: [
			(info("A"), Source(name: "A", apps: [app("com.example.app", date: early)])),
			(info("B"), Source(name: "B", apps: [app("com.example.app", date: late)])),
		])
		XCTAssertEqual(byDate.entry(bundleID: "com.example.app")?.preferred.source.name, "B")
	}

	func testEntriesAreSortedByNameAndGroupedByCategory() {
		let source = Source(name: "S", apps: [
			app("c", name: "zebra", category: .games),
			app("a", name: "Émulateur", category: .games),
			app("b", name: "App 10", category: .utilities),
			app("d", name: "App 9", category: .utilities),
		])
		let catalog = Catalog(sources: [(info("S"), source)])
		XCTAssertEqual(catalog.entries.map(\.app.name), ["App 9", "App 10", "Émulateur", "zebra"])
		XCTAssertEqual(catalog.categories.map(\.category), [.games, .utilities])
		XCTAssertEqual(catalog.categories.map(\.count), [2, 2])
		XCTAssertEqual(catalog.entries(in: .games).map(\.bundleID), ["a", "c"])
	}

	func testFeaturedAppsAndNewsAcrossSources() throws {
		let first = Source(
			name: "First",
			featuredAppIDs: ["com.example.b", "com.example.missing"],
			apps: [app("com.example.a"), app("com.example.b")],
			news: [
				NewsItem(identifier: "old", title: "Old", date: Date(timeIntervalSince1970: 100)),
				NewsItem(identifier: "undated", title: "Undated"),
			]
		)
		let second = Source(
			name: "Second",
			apps: [app("com.example.c")],
			news: [NewsItem(identifier: "new", title: "New", date: Date(timeIntervalSince1970: 200))]
		)
		let catalog = Catalog(sources: [(info("First"), first), (info("Second"), second)])
		XCTAssertEqual(catalog.sources.map(\.source.name), ["First", "Second"])
		XCTAssertEqual(catalog.sources[0].featured.map(\.bundleID), ["com.example.b"])
		// No featured apps named: none, rather than the spec's first five (#38).
		XCTAssertEqual(catalog.sources[1].featured.map(\.bundleID), [])
		XCTAssertEqual(catalog.news.map(\.item.identifier), ["new", "old", "undated"])
		XCTAssertEqual(catalog.news.map(\.source.name), ["Second", "First", "First"])
	}

	func testPreferredListingIsTheNewestThisDeviceCanRun() throws {
		let newer = Source(name: "Newer", apps: [app("com.example.app", version: "2.0", minOS: "99.0")])
		let older = Source(name: "Older", apps: [app("com.example.app", version: "1.5", minOS: "18.0")])
		let catalog = Catalog(sources: [(info("Newer"), newer), (info("Older"), older)], os: OSVersion("18.0")!)
		XCTAssertEqual(catalog.entry(bundleID: "com.example.app")?.preferred.source.name, "Older")
		// Neither runs: the newest latest version, as before.
		let neither = Catalog(sources: [(info("Older"), older), (info("Newer"), newer)], os: OSVersion("1.0")!)
		XCTAssertEqual(neither.entry(bundleID: "com.example.app")?.preferred.source.name, "Newer")
	}

	func testBetaReleases() {
		for version in ["2.3.1rc", "1.2b2", "2.0-beta.3", "10.0a1", "3.2.1-pre", "2.0RC"] {
			XCTAssertTrue(VersionNumber.isPrerelease(version), version)
		}
		for version in ["2.0.7", "1.0", "1.7.1", "2024.10.21"] {
			XCTAssertFalse(VersionNumber.isPrerelease(version), version)
		}
		var flagged = app("com.example.app.Beta", version: "2.0.7")
		XCTAssertFalse(flagged.isBetaRelease)
		flagged.isBeta = true
		XCTAssertTrue(flagged.isBetaRelease, "AltStore's source flags its betas")
		// Only the source's marks count, never the number (29 Oct 2026).
		XCTAssertFalse(app("com.example.app", version: "1.2rc").isBetaRelease)
	}

	/// A GitHub repo's pre-releases, while the user includes them, are
	/// listed with its releases (#104): the newest may be a beta, and it's
	/// what Install installs.
	func testPrereleasesAmongReleases() {
		var beta = AppVersion(version: "2.0", buildVersion: "5", downloadURL: ipa)
		beta.isPrerelease = true
		let release = AppVersion(version: "1.9", buildVersion: "4", downloadURL: ipa)
		let app = SourceApp(name: "App", bundleID: "com.example.app", versions: [beta, release])
		XCTAssertEqual(app.latestVersion, beta)
		XCTAssertEqual(app.availability(on: OSVersion("18.0")!).version, beta)
		XCTAssertTrue(app.isBetaRelease)
		XCTAssertTrue(beta.isBeta)
		XCTAssertFalse(release.isBeta)

		// A newer release makes it a release again.
		let newer = AppVersion(version: "2.0", buildVersion: "6", downloadURL: ipa)
		XCTAssertFalse(SourceApp(name: "App", bundleID: "com.example.app", versions: [newer, beta, release]).isBetaRelease)
	}

	/// Include Pre-releases off (#104), in AltStore's own source: its beta
	/// apps go, and its news stays.
	func testAltStoresBetaAppsGoWithoutPrereleases() throws {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "altstore-classic", withExtension: "json", subdirectory: "Fixtures"))
		let source = try SourceParser.parse(Data(contentsOf: url)).source
		XCTAssertEqual(source.apps.count, 6)
		XCTAssertTrue(source.listsPrereleases)
		XCTAssertFalse(source.listsOnlyPrereleases)
		XCTAssertEqual(source.listing(prereleases: true), source)

		let releases = source.listing(prereleases: false)
		XCTAssertEqual(releases.apps.map(\.bundleID), ["com.rileytestut.AltStore", "com.rileytestut.Delta", "com.rileytestut.Clip"])
		XCTAssertEqual(releases.apps.map { $0.versions.count }, source.apps.filter { !$0.isBeta }.map { $0.versions.count }, "its releases' versions stay")
		XCTAssertFalse(releases.listsPrereleases)
		XCTAssertEqual(releases.name, source.name)
		XCTAssertEqual(releases.news, source.news)
	}

	/// A version the source marks as a beta goes from a release app's list,
	/// and an app with only betas goes with them (#104). One numbered like
	/// a beta, unmarked, is a version like any other (29 Oct 2026).
	func testBetaVersionsGoWithoutPrereleases() {
		var marked = AppVersion(version: "2.0", downloadURL: ipa)
		marked.isPrerelease = true
		let app = SourceApp(name: "App", bundleID: "com.example.app", versions: [marked, AppVersion(version: "2.0b1", downloadURL: ipa), AppVersion(version: "1.0", downloadURL: ipa)])
		var markedAlpha = AppVersion(version: "0.1", downloadURL: ipa)
		markedAlpha.isPrerelease = true
		let alpha = SourceApp(name: "Alpha", bundleID: "com.example.alpha", versions: [markedAlpha])
		let source = Source(name: "Source", featuredAppIDs: ["com.example.alpha"], apps: [app, alpha])
		let releases = source.withoutPrereleases()
		XCTAssertEqual(releases.apps.map(\.bundleID), ["com.example.app"])
		XCTAssertEqual(releases.apps[0].versions.map(\.version), ["2.0b1", "1.0"])
		XCTAssertTrue(releases.listedFeaturedApps.isEmpty)
		XCTAssertTrue(app.isBeta(app.versions[0]))
		XCTAssertFalse(app.isBeta(app.versions[1]))
		XCTAssertFalse(Source(name: "Numbers", apps: [SourceApp(name: "App", bundleID: "com.example.app", versions: [AppVersion(version: "2.0b1", downloadURL: ipa)])]).listsPrereleases)

		// Every version of a beta app is a beta, whatever its number says.
		let betaApp = SourceApp(name: "App", bundleID: "com.example.app.beta", versions: [AppVersion(version: "2.0", downloadURL: ipa)], isBeta: true)
		XCTAssertTrue(betaApp.isBeta(betaApp.versions[0]))
		XCTAssertTrue(Source(name: "Betas", apps: [betaApp, alpha]).listsOnlyPrereleases)
		XCTAssertFalse(Source(name: "Empty").listsOnlyPrereleases)
	}

	/// Each source's switch, off until it's turned on (#104).
	func testPrereleasePreferences() throws {
		let preferences = PrereleasePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: "PrereleasePreferencesTests.\(UUID().uuidString)")))
		let url = URL(string: "https://example.com/apps.json")!
		XCTAssertFalse(preferences.includes(url))
		preferences.set(true, for: url)
		XCTAssertTrue(preferences.includes(url))
		XCTAssertFalse(preferences.includes(URL(string: "https://example.com/other.json")!))
		preferences.set(false, for: url)
		XCTAssertFalse(preferences.includes(url))
	}

	func testEachSourceListsItsAppsInItsOwnOrder() throws {
		let first = Source(name: "First", apps: [app("com.example.z"), app("com.example.a", version: "1.0")])
		let second = Source(name: "Second", apps: [app("com.example.a", version: "2.0"), app("com.example.b")])
		let catalog = Catalog(sources: [(info("First"), first), (info("Second"), second)])

		let section = try XCTUnwrap(catalog.source(url: info("First").url))
		XCTAssertEqual(section.apps.map(\.bundleID), ["com.example.z", "com.example.a"])
		// The entry is shared across sources; the source's own listing is its offer.
		XCTAssertEqual(section.apps[1].offer(from: section.source.url).app.latestVersion?.version, "1.0")
		XCTAssertEqual(catalog.source(url: info("Second").url)?.apps.map(\.bundleID), ["com.example.a", "com.example.b"])
		XCTAssertNil(catalog.source(url: info("Missing").url))
	}

	func testRealSourcesMerge() throws {
		func load(_ fixture: String) throws -> Source {
			let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
			return try SourceParser.parse(Data(contentsOf: url)).source
		}
		let altstore = try load("altstore-classic"), quantum = try load("quantum"), utm = try load("utm")
		let catalog = Catalog(sources: [(info("AltStore"), altstore), (info("Quantum"), quantum), (info("UTM"), utm)])
		let ids = Set(altstore.apps.map(\.id) + quantum.apps.map(\.id) + utm.apps.map(\.id))
		XCTAssertEqual(catalog.entries.count, ids.count)
		XCTAssertFalse(catalog.search("delta").isEmpty)
	}

	func testSameBundleIDWithAnotherNameIsAnotherEntry() throws {
		let a = Source(name: "A", apps: [app("com.spotify.client", name: "Spotify", version: "9.1.28"), app("com.spotify.client", name: "EeveeSpotify", version: "9.1.56")])
		let b = Source(name: "B", apps: [app("com.spotify.client", name: "EeveeSpotify", version: "9.0.36")])
		let catalog = Catalog(sources: [(info("A"), a), (info("B"), b)])
		XCTAssertEqual(catalog.entries.map(\.app.name), ["EeveeSpotify", "Spotify"])
		let eevee = try XCTUnwrap(catalog.entry(id: AppName.identity(bundleID: "com.spotify.client", name: "eeveespotify")))
		XCTAssertEqual(eevee.offers.map(\.source.name), ["A", "B"])
		XCTAssertEqual(catalog.entry(bundleID: "com.spotify.client")?.app.name, "EeveeSpotify")
		XCTAssertEqual(AppName.bundleID(ofIdentity: eevee.id), "com.spotify.client")
		XCTAssertEqual(AppName.bundleID(ofIdentity: AppName.identity(bundleID: "com.x", name: "App #1")), "com.x")
	}

	// MARK: Names

	func testNamesLoseTheirVersions() {
		XCTAssertEqual(AppName.clean("Alarmy_6.68.0+Satella"), "Alarmy +Satella")
		XCTAssertEqual(AppName.clean("DuolingoMax_7.37.1"), "DuolingoMax")
		XCTAssertEqual(AppName.clean("EeveeSpotify-5.9.5-9.0.36"), "EeveeSpotify")
		XCTAssertEqual(AppName.clean("Spotify++8.6.94_CyPwn"), "Spotify++ CyPwn")
		XCTAssertEqual(AppName.clean("Regram_1.0-b7_335.0.8"), "Regram")
		XCTAssertEqual(AppName.clean("YTMusicUltimate_v1.4.1_YTM6.03.1"), "YTMusicUltimate YTM")
		XCTAssertEqual(AppName.clean("Delta (1.7.1)"), "Delta")
		XCTAssertEqual(AppName.clean("Deltarune v727"), "Deltarune")
		XCTAssertEqual(AppName.clean("EeveeSpotify-5.9.5-9.0.36 x CyPwn"), "EeveeSpotify x CyPwn")
		XCTAssertEqual(AppName.clean("Violyn_1_4_4-2"), "Violyn")
		XCTAssertEqual(AppName.clean("Infuse 7"), "Infuse 7")
		XCTAssertEqual(AppName.clean("2048"), "2048")
		XCTAssertEqual(AppName.clean("1.2.3"), "1.2.3")
	}

	func testListingsOfOneAppMergeIntoItsVersionHistory() throws {
		let json = #"""
		{"name": "S", "apps": [
			{"name": "Spotify_9.1.50", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.50", "date": "2026-06-12", "downloadURL": "https://e.com/50.ipa"}]},
			{"name": "EeveeSpotify", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.56", "date": "2026-06-16", "downloadURL": "https://e.com/e56.ipa"}]},
			{"name": "Spotify 9.1.56", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.56", "date": "2026-06-16", "downloadURL": "https://e.com/56.ipa"}]},
			{"name": "spotify", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.50", "date": "2026-06-12", "downloadURL": "https://e.com/50.ipa"}]}
		]}
		"""#
		let source = try SourceParser.parse(Data(json.utf8)).source
		XCTAssertEqual(source.apps.map(\.name), ["Spotify", "EeveeSpotify"])
		XCTAssertEqual(source.apps[0].versions.map(\.version), ["9.1.56", "9.1.50"])
		XCTAssertEqual(source.apps[1].versions.map(\.version), ["9.1.56"])
	}

	// MARK: Search

	func testSearchByNameDeveloperAndBundleID() {
		let source = Source(name: "S", apps: [
			app("com.rileytestut.Delta", name: "Delta", developer: "Riley Testut"),
			app("com.rileytestut.Clip", name: "Clip", developer: "Riley Testut"),
			app("com.example.deltaworks", name: "Works", developer: "Someone"),
			app("com.example.emu", name: "Émulateur Delta", developer: "Café"),
		])
		let catalog = Catalog(sources: [(info("S"), source)])

		// Name prefix first, then other name matches, then the rest.
		XCTAssertEqual(catalog.search("delta").map(\.bundleID), ["com.rileytestut.Delta", "com.example.emu", "com.example.deltaworks"])
		XCTAssertEqual(catalog.search("RILEY").map(\.bundleID), ["com.rileytestut.Clip", "com.rileytestut.Delta"])
		XCTAssertEqual(catalog.search("com.rileytestut.clip").map(\.bundleID), ["com.rileytestut.Clip"])
		// Accents ignored, every word must match somewhere.
		XCTAssertEqual(catalog.search("emulateur cafe").map(\.bundleID), ["com.example.emu"])
		XCTAssertTrue(catalog.search("clip delta").isEmpty)
		XCTAssertTrue(catalog.search("   ").isEmpty)
	}

	func testSearchInOneListKeepsItsOrderWithinEachRank() throws {
		// A source lists its apps in its own order, not by name (#124).
		let source = Source(name: "S", apps: [
			app("com.example.wallpapers", name: "Wallpapers"),
			app("com.example.lyfta", name: "Lyfta"),
			app("com.example.wallcraft", name: "Wallcraft"),
			app("com.example.walls", name: "HD Walls", developer: "Studio"),
			app("com.example.paint", name: "Paint", developer: "Wall Street Apps"),
		])
		let other = Source(name: "O", apps: [app("com.example.wallet", name: "Wallet")])
		let catalog = Catalog(sources: [(info("S"), source), (info("O"), other)])
		let apps = try XCTUnwrap(catalog.source(url: info("S").url)).apps

		// Names that start with it first, in the source's order; then other
		// names; then the rest. Another source's apps aren't in the list.
		XCTAssertEqual(Catalog.search(SearchText("wall"), in: apps).map(\.bundleID), ["com.example.wallpapers", "com.example.wallcraft", "com.example.walls", "com.example.paint"])
		// Browse's search over every app is by name within each rank.
		XCTAssertEqual(catalog.search("wall").map(\.bundleID), ["com.example.wallcraft", "com.example.wallet", "com.example.wallpapers", "com.example.walls", "com.example.paint"])
		XCTAssertTrue(Catalog.search(SearchText("  "), in: apps).isEmpty)
		XCTAssertTrue(Catalog.search(SearchText("wallet"), in: apps).isEmpty)
	}

	func testSearchTextMatchesAsBrowseDoes() {
		let youtube = SearchText("YOUTUBE")
		XCTAssertEqual(youtube.rank(name: "YouTube Music", others: ["YouMod", "com.google.ios.youtubemusic"]), .namePrefix)
		XCTAssertEqual(SearchText("music").rank(name: "YouTube Music", others: []), .name)
		XCTAssertEqual(SearchText("youmod music").rank(name: "YouTube Music", others: ["YouMod"]), .other)
		// Accents and case don't count; every word has to be somewhere.
		XCTAssertTrue(SearchText("cafe").matches(name: "Café Créme", others: []))
		XCTAssertTrue(SearchText("com.nimbus").matches(name: "Nimbus", others: [nil, "com.nimbus.media"]))
		XCTAssertFalse(SearchText("nimbus feather").matches(name: "Nimbus", others: ["com.nimbus.media"]))
		// Nothing typed matches nothing: a list shows everything instead.
		XCTAssertTrue(SearchText(" \n ").isEmpty)
		XCTAssertFalse(SearchText("").matches(name: "Nimbus", others: []))
		XCTAssertEqual(SearchText("  two   words ").words, ["two", "words"])
	}

	func testSearchStaysFastWithLargeSources() {
		let apps = (0..<2000).map { app("com.example.app\($0)", name: "App \($0)", developer: "Developer \($0 % 50)") }
		let catalog = Catalog(sources: [(info("Big"), Source(name: "Big", apps: apps))])
		XCTAssertEqual(catalog.search("app 1999").first?.bundleID, "com.example.app1999")
		measure { _ = catalog.search("app 1") }
	}

	// MARK: Versions and the Install button

	func testVersionNumbers() {
		XCTAssertEqual(VersionNumber.compare("1.10", "1.9.2"), .orderedDescending)
		XCTAssertEqual(VersionNumber.compare("1.7", "1.7.0"), .orderedSame)
		XCTAssertEqual(VersionNumber.compare("2.0", "10.0"), .orderedAscending)
		XCTAssertEqual(VersionNumber.compare("2.0b3", "2.0b10"), .orderedAscending)
	}

	func testInstallAction() {
		let version = AppVersion(version: "1.2", downloadURL: ipa)
		let installable = AppAvailability.installable(version)
		XCTAssertEqual(InstallAction(availability: installable, installedVersion: nil), .install(version))
		XCTAssertEqual(InstallAction(availability: installable, installedVersion: "1.1.9"), .update(version))
		XCTAssertEqual(InstallAction(availability: installable, installedVersion: "1.2.0"), .open)
		XCTAssertEqual(InstallAction(availability: installable, installedVersion: "1.3"), .open)
		let tooOld = AppAvailability.notInstallable(.unsupportedOS(min: OSVersion("26.0"), max: nil))
		XCTAssertEqual(InstallAction(availability: tooOld, installedVersion: nil), .notInstallable(.unsupportedOS(min: OSVersion("26.0"), max: nil)))
		XCTAssertEqual(InstallAction(availability: tooOld, installedVersion: "1.0"), .open)
		XCTAssertEqual(InstallAction(availability: .notInstallable(.alternativeDistributionOnly), installedVersion: nil), .notInstallable(.alternativeDistributionOnly))
	}

	// MARK: Permission names

	func testPermissionNames() {
		XCTAssertEqual(AppPermissions.privacyName(for: "NSCameraUsageDescription"), "Camera")
		XCTAssertEqual(AppPermissions.privacyName(for: "NSLocalNetworkUsageDescription"), "Local Network")
		XCTAssertEqual(AppPermissions.privacyName(for: "NSFooBarUsageDescription"), "Foo Bar")
		XCTAssertEqual(AppPermissions.privacyName(for: "NSGKAccessUsageDescription"), "GK Access")
		XCTAssertEqual(AppPermissions.privacyName(for: "NS"), "NS")
		XCTAssertEqual(AppPermissions.entitlementName(for: "aps-environment"), "Push Notifications")
		XCTAssertNil(AppPermissions.entitlementName(for: "com.example.private"))
		let permissions = AppPermissions(privacy: ["NSMicrophoneUsageDescription": "To record", "NSCameraUsageDescription": "To scan"])
		XCTAssertEqual(permissions.namedPrivacy.map(\.name), ["Camera", "Microphone"])
	}
}
