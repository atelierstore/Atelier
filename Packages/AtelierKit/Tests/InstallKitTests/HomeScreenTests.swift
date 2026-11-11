import Foundation
import XCTest
@testable import InstallKit

/// Items as SpringBoard's getIconState gives them, formatVersion 2.
private enum Icon {
	static func app(_ id: String, _ name: String? = nil) -> [String: Any] {
		["bundleIdentifier": id, "displayIdentifier": id, "displayName": name ?? id, "bundleVersion": "1"]
	}

	static func folder(_ name: String, _ pages: [[Any]], ids: [String]? = nil) -> [String: Any] {
		var folder: [String: Any] = ["displayName": name, "listType": "folder", "iconLists": pages]
		if let ids { folder["listUniqueIdentifiers"] = ids }
		return folder
	}

	/// A configured widget: iOS gives its identifier as
	/// `userSelectedElementIdentifier` only, and an empty `iconLists`.
	static func widget(_ size: String, id: String) -> [String: Any] {
		[
			"iconType": "custom", "gridSize": size, "elementType": "widget",
			"containerBundleIdentifier": "com.apple.weather", "widgetIdentifier": "com.apple.weather.widget",
			"displayIdentifier": "D-\(id)", "userSelectedElementIdentifier": id, "iconLists": [] as [Any],
		]
	}

	/// A Smart Stack.
	static func stack(id: String) -> [String: Any] {
		[
			"iconType": "custom", "gridSize": "small", "displayIdentifier": id,
			"elements": [["elementType": "widget", "uniqueIdentifier": "E1", "widgetIdentifier": "com.apple.mobilecal.widget"]],
			"iconLists": [] as [Any],
		]
	}
}

private let safari = "com.apple.mobilesafari", messages = "com.apple.MobileSMS", mail = "com.apple.mobilemail"
private let calendar = "com.apple.mobilecal", maps = "com.apple.Maps", calculator = "com.apple.calculator"
private let compass = "com.apple.compass", fitness = "com.apple.Fitness", news = "com.apple.news"
private let twelve = "com.example.twelve", feather = "com.example.feather", sideStore = "com.example.sidestore"
private let atlas = "com.example.atlas", nimbus = "com.example.nimbus", alone = "com.example.alone"

/// The Dock, then 3 pages: a widget, a folder of 2 pages, and an app alone
/// on the last page.
private func iconState() -> [Any] {
	[
		[safari, messages, Icon.app(twelve, "30sec"), mail],
		[Icon.widget("medium", id: "W1"), calendar, maps, Icon.folder("Tools", [[Icon.app(feather, "Feather"), calculator], [compass]]), Icon.app(sideStore, "SideStore")],
		[fitness, Icon.app(atlas, "Atlas"), news],
		[Icon.app(alone, "Alone")],
	]
}

private func layout() -> HomeScreenLayout {
	HomeScreenLayout(iconState: iconState())!
}

/// The icons' identifiers, a folder as its name and pages.
private func ids(_ items: [HomeScreenLayout.Item]) -> [String] {
	items.map { item in
		switch item {
		case .icon(let id, _): id
		case .folder(let name, let pages, _): "\(name)\(pages.map(ids))"
		case .widget: "widget"
		case .other: "other"
		}
	}
}

final class HomeScreenLayoutTests: XCTestCase {
	func testReadsTheDockPagesFoldersAndWidgets() {
		let layout = layout()
		XCTAssertEqual(ids(layout.dock), [safari, messages, twelve, mail])
		XCTAssertEqual(layout.pages.map(ids), [
			["widget", calendar, maps, "Tools[[\"\(feather)\", \"\(calculator)\"], [\"\(compass)\"]]", sideStore],
			[fitness, atlas, news],
			[alone],
		])
		XCTAssertEqual(layout.folderCount, 1)
		XCTAssertEqual(layout.widgetCount, 1)
		XCTAssertTrue(layout.placedIDs.isSuperset(of: [feather, compass, twelve, alone]))
		XCTAssertFalse(layout.placedIDs.contains("D-W1"))
	}

	func testReadsTheBinaryPlistSpringBoardGives() throws {
		let data = try PropertyListSerialization.data(fromPropertyList: iconState(), format: .binary, options: 0)
		XCTAssertEqual(HomeScreenLayout(plist: data), layout())
		XCTAssertNil(HomeScreenLayout(plist: Data("not a plist".utf8)))
		XCTAssertNil(HomeScreenLayout(iconState: ["buttonBar": []]))
	}

	func testAWidgetWithAnEmptyIconListsIsntAFolder() {
		let layout = HomeScreenLayout(iconState: [[], [Icon.widget("small", id: "W2"), Icon.stack(id: "S1")]])!
		XCTAssertEqual(ids(layout.pages[0]), ["widget", "widget"])
		XCTAssertEqual(layout.folderCount, 0)
	}

	// MARK: Spots

	func testFindsAnAppsSpot() {
		let layout = layout()
		XCTAssertEqual(layout.spot(of: twelve), HomeScreenSpot(page: nil, index: 2, previous: messages, next: mail))
		XCTAssertEqual(layout.spot(of: atlas), HomeScreenSpot(page: 1, index: 1, previous: fitness, next: news))
		XCTAssertEqual(layout.spot(of: alone), HomeScreenSpot(page: 2, index: 0))
		XCTAssertNil(layout.spot(of: nimbus))
	}

	func testFindsAnAppInAFolder() {
		let layout = layout()
		XCTAssertEqual(layout.spot(of: feather), HomeScreenSpot(page: 0, folder: .init(name: "Tools", index: 3, page: 0), index: 0, next: calculator))
		XCTAssertEqual(layout.spot(of: compass), HomeScreenSpot(page: 0, folder: .init(name: "Tools", index: 3, page: 1), index: 0))
	}

	func testSaysWhereASpotIs() {
		let layout = layout()
		XCTAssertEqual(layout.spot(of: twelve)?.description, "Dock, 3rd")
		XCTAssertEqual(layout.spot(of: atlas)?.description, "Page 2, 2nd")
		XCTAssertEqual(layout.spot(of: feather)?.description, "In Tools, 1st")
		XCTAssertEqual(layout.spot(of: compass)?.description, "In Tools, page 2, 1st")
		XCTAssertEqual(layout.spot(of: feather)?.detail, "In Tools (Page 1, 4th), 1st")
		XCTAssertEqual(layout.spot(of: compass)?.detail, "In Tools (Page 1, 4th), page 2, 1st")
		XCTAssertEqual(layout.spot(of: atlas)?.detail, "Page 2, 2nd")
	}

	func testOrdinals() {
		XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 24].map(HomeScreenSpot.ordinal), ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "24th"])
	}

	func testASpotKeepsAsJSON() throws {
		let spot = layout().spot(of: feather)!
		XCTAssertEqual(try JSONDecoder().decode(HomeScreenSpot.self, from: JSONEncoder().encode(spot)), spot)
	}

	// MARK: Putting an app back

	func testPutsAReinstalledAppBackAfterTheIconItWasAfter() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: atlas))
		// iOS put the new install after the last app.
		var reinstalled = before.removing(atlas)
		reinstalled.pages[2].append(.init(atlas))
		let placed = try reinstalled.placing(atlas, at: spot)
		XCTAssertEqual(placed.pages.map(ids)[1...], [[fitness, atlas, news], [alone]])
		XCTAssertEqual(placed.spot(of: atlas), spot)
		XCTAssertEqual(placed.differences(from: before), [])
	}

	func testThePageIOSAddedForTheAppGoes() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: atlas))
		var reinstalled = before.removing(atlas)
		reinstalled.pages.append([.init(atlas)])
		let placed = try reinstalled.placing(atlas, at: spot)
		XCTAssertEqual(placed.pages.map(ids), before.pages.map(ids))
	}

	func testAnAppOnlyInTheAppLibraryNowGoesBackToo() throws {
		// New apps go to the App Library only.
		let before = layout()
		let placed = try before.removing(twelve).placing(twelve, at: XCTUnwrap(before.spot(of: twelve)))
		XCTAssertEqual(ids(placed.dock), [safari, messages, twelve, mail])
	}

	func testGoesBeforeTheIconItWasBeforeOnceTheOneAfterIsGone() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: atlas))
		let placed = try before.removing(atlas).removing(fitness).placing(atlas, at: spot)
		XCTAssertEqual(ids(placed.pages[1]), [atlas, news])
	}

	func testGoesAtItsPlaceOnceBothIconsBesideItAreGone() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: atlas))
		var reinstalled = before.removing(atlas).removing(fitness).removing(news)
		reinstalled.pages.insert([.init("com.example.a"), .init("com.example.b"), .init("com.example.c")], at: 1)
		let placed = try reinstalled.placing(atlas, at: spot)
		XCTAssertEqual(ids(placed.pages[1]), ["com.example.a", atlas, "com.example.b", "com.example.c"])
	}

	func testAnAppAloneOnItsPageGetsItsPageBack() throws {
		let before = HomeScreenLayout(iconState: [[safari], ["com.example.a", "com.example.b"], [alone], ["com.example.c"]])!
		let spot = try XCTUnwrap(before.spot(of: alone))
		var reinstalled = before.removing(alone)
		XCTAssertEqual(reinstalled.pages.count, 2)
		reinstalled.pages[1].append(.init(alone))
		let placed = try reinstalled.placing(alone, at: spot)
		XCTAssertEqual(placed.pages.map(ids), [["com.example.a", "com.example.b"], [alone], ["com.example.c"]])
	}

	func testGoesBackIntoItsFolder() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: feather))
		var reinstalled = before.removing(feather)
		reinstalled.pages[2].append(.init(feather))
		let placed = try reinstalled.placing(feather, at: spot)
		XCTAssertEqual(placed.pages.map(ids), before.pages.map(ids))
		XCTAssertEqual(placed.differences(from: before), [])
	}

	func testGoesBackIntoItsFolderOnceTheFolderMoved() throws {
		let before = layout()
		let spot = try XCTUnwrap(before.spot(of: compass))
		var reinstalled = before.removing(compass)
		// The user moved Tools to the front of the page meanwhile.
		let tools = reinstalled.pages[0].remove(at: 3)
		reinstalled.pages[0].insert(tools, at: 0)
		let placed = try reinstalled.placing(compass, at: spot)
		XCTAssertEqual(placed.spot(of: compass)?.description, "In Tools, page 2, 1st")
		XCTAssertEqual(placed.spot(of: compass)?.folder?.index, 0)
	}

	func testAFolderThatWentWithItsLastAppComesBack() throws {
		let before = HomeScreenLayout(iconState: [[safari], [calendar, Icon.folder("Games", [[Icon.app(alone)]]), maps]])!
		let spot = try XCTUnwrap(before.spot(of: alone))
		// iOS takes away a folder its last app leaves.
		var reinstalled = HomeScreenLayout(iconState: [[safari], [calendar, maps]])!
		reinstalled.pages[0].append(.init(alone))
		let placed = try reinstalled.placing(alone, at: spot)
		XCTAssertEqual(ids(placed.pages[0]), [calendar, "Games[[\"\(alone)\"]]", maps])
		let archived = try XCTUnwrap(placed.archive(appLibrary: [])["iconLists"] as? [[Any]])
		let folder = try XCTUnwrap(archived[0][1] as? [String: Any])
		XCTAssertEqual(folder["displayName"] as? String, "Games")
		XCTAssertEqual(folder["listType"] as? String, "folder")
		XCTAssertEqual(folder["iconLists"] as? [[String]], [[alone]])
	}

	func testAFullDockOrPageOrFolderSaysSo() throws {
		let before = layout()
		var reinstalled = before.removing(twelve)
		reinstalled.dock.append(.init("com.example.new"))
		XCTAssertThrowsError(try reinstalled.placing(twelve, at: XCTUnwrap(before.spot(of: twelve)))) { error in
			XCTAssertEqual(error as? HomeScreenLayout.PlacingProblem, .dockFull)
			XCTAssertEqual((error as? HomeScreenLayout.PlacingProblem)?.description, "the Dock is full")
		}

		// A large widget takes 16 of the page's 24 places.
		let full = HomeScreenLayout(iconState: [[], [Icon.widget("large", id: "W3")] + (1...8).map { "com.example.\($0)" }])!
		XCTAssertThrowsError(try full.placing(atlas, at: HomeScreenSpot(page: 0, index: 3, previous: "com.example.3"))) { error in
			XCTAssertEqual(error as? HomeScreenLayout.PlacingProblem, .pageFull(0))
			XCTAssertEqual((error as? HomeScreenLayout.PlacingProblem)?.description, "page 1 is full")
		}

		let folder = HomeScreenLayout(iconState: [[], [Icon.folder("Tools", [(1...9).map { "com.example.\($0)" }])]])!
		let spot = HomeScreenSpot(page: 0, folder: .init(name: "Tools", index: 0, page: 0), index: 2)
		XCTAssertThrowsError(try folder.placing(atlas, at: spot)) { error in
			XCTAssertEqual(error as? HomeScreenLayout.PlacingProblem, .folderFull("Tools"))
		}
	}

	func testRemovingDropsThePagesItEmpties() {
		let layout = layout()
		XCTAssertEqual(layout.removing(alone).pages.count, 2)
		let tools = layout.removing(compass).pages[0][3]
		XCTAssertEqual(ids([tools]), ["Tools[[\"\(feather)\", \"\(calculator)\"]]"])
		// A page left empty before stays.
		let empty = HomeScreenLayout(iconState: [[], [], [atlas]])!
		XCTAssertEqual(empty.removing(nimbus).pages.count, 2)
	}

	// MARK: Writing it back

	func testTheAppLibraryIsTheInstalledAppsTheLayoutDoesntPlace() {
		let apps = [
			HomeScreenApp(bundleID: atlas, name: "Atlas"),
			HomeScreenApp(bundleID: nimbus, name: "Nimbus"),
			HomeScreenApp(bundleID: "com.example.zebra", name: "zebra"),
			HomeScreenApp(bundleID: "com.example.bear", name: "Bear"),
			HomeScreenApp(bundleID: "com.example.secret", name: "Secret", hidden: true),
			HomeScreenApp(bundleID: "com.apple.TVRemoteApp", name: "Apple TV Remote"),
		]
		XCTAssertEqual(layout().appLibrary(installed: apps), ["com.example.bear", nimbus, "com.example.zebra"])
	}

	func testArchivesTheLayoutAsSpringBoardImportsIt() throws {
		let archive = layout().archive(appLibrary: [nimbus])
		XCTAssertEqual(archive["buttonBar"] as? [String], [safari, messages, twelve, mail])
		XCTAssertEqual(archive["ignored"] as? [String], [nimbus])
		let pages = try XCTUnwrap(archive["iconLists"] as? [[Any]])
		XCTAssertEqual(pages.count, 3)
		let widget = try XCTUnwrap(pages[0][0] as? [String: Any])
		XCTAssertNil(widget["iconLists"])
		// Or the widget loses its settings.
		XCTAssertEqual(widget["uniqueIdentifier"] as? String, "W1")
		XCTAssertEqual(widget["gridSize"] as? String, "medium")
		XCTAssertEqual(pages[0][1] as? String, calendar)
		let folder = try XCTUnwrap(pages[0][3] as? [String: Any])
		XCTAssertEqual(folder["iconLists"] as? [[String]], [[feather, calculator], [compass]])
		XCTAssertEqual(pages[2] as? [String], [alone])
	}

	func testAStackKeepsItsElementsAsTheyWere() throws {
		let layout = HomeScreenLayout(iconState: [[], [Icon.stack(id: "S1")]])!
		let pages = try XCTUnwrap(layout.archive(appLibrary: [])["iconLists"] as? [[Any]])
		let stack = try XCTUnwrap(pages[0][0] as? [String: Any])
		XCTAssertNil(stack["uniqueIdentifier"])
		XCTAssertNil(stack["iconLists"])
		XCTAssertEqual((stack["elements"] as? [[String: Any]])?.first?["uniqueIdentifier"] as? String, "E1")
	}

	func testAFoldersPageIdentifiersKeepInStepWithItsPages() throws {
		let before = HomeScreenLayout(iconState: [[], [Icon.folder("Tools", [[feather], [compass]], ids: ["P1", "P2"])]])!
		let pages = try XCTUnwrap(before.removing(compass).archive(appLibrary: [])["iconLists"] as? [[Any]])
		let folder = try XCTUnwrap(pages[0][0] as? [String: Any])
		XCTAssertEqual(folder["iconLists"] as? [[String]], [[feather]])
		XCTAssertEqual(folder["listUniqueIdentifiers"] as? [String], ["P1"])
	}

	func testTheArchiveReadsBackAsTheSameLayout() throws {
		let layout = layout()
		let archive = layout.archive(appLibrary: [])
		let state = [archive["buttonBar"]!] + (archive["iconLists"] as! [Any])
		let read = try XCTUnwrap(HomeScreenLayout(iconState: state))
		XCTAssertEqual(read.spots, layout.spots)
		XCTAssertEqual(read.differences(from: layout), [])
		let data = try layout.archiveData(appLibrary: [nimbus])
		let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
		XCTAssertEqual(decoded["ignored"] as? [String], [nimbus])
	}

	func testSaysWhatAReadBackPlacesDifferently() {
		let written = layout()
		var read = written.removing(feather)
		read.pages[1].swapAt(0, 1)
		read.pages.append([.init(nimbus)])
		// In the order of the bundle IDs; the apps after a moved one have
		// other places too.
		XCTAssertEqual(read.differences(from: written, names: [atlas: "Atlas", feather: "Feather", nimbus: "Nimbus", fitness: "Fitness"]), [
			"Fitness: Page 2, 2nd, not Page 2, 1st",
			"com.apple.calculator: In Tools, 1st, not In Tools, 2nd",
			"Atlas: Page 2, 1st, not Page 2, 2nd",
			"Feather: gone from In Tools, 1st",
			"Nimbus: added at Page 4, 1st",
			"4 pages, not 3",
		])
	}
}

/// Offload keeps an app's spot empty with a gap until Reinstall
/// (6 Nov 2026): iOS keeps a gap by pinning the icons after it to their
/// places, as homescreen-mcp writes them.
final class HomeScreenGapTests: XCTestCase {
	/// Atlas's spot on page 2, between Fitness and News, after Offload.
	private let atlasSpot = HomeScreenSpot(page: 1, index: 1, previous: fitness, next: news)

	/// The page identifiers and each page's pins, by page.
	private func pins(_ archive: [String: Any]) throws -> [Int: [String: Int]] {
		guard let pageIDs = archive["listUniqueIdentifiers"] as? [String] else { return [:] }
		let metadata = try XCTUnwrap(archive["listMetadata"] as? [String: [String: Any]])
		var pins: [Int: [String: Int]] = [:]
		for (page, id) in pageIDs.enumerated() {
			guard let entry = metadata[id] else { continue }
			XCTAssertEqual(entry["fixedLocationsGridColumns"] as? Int, 4)
			XCTAssertEqual(entry["fixedLocationsGridRows"] as? Int, 6)
			pins[page] = try XCTUnwrap(entry["fixedLocations"] as? [String: Int])
		}
		return pins
	}

	func testWithoutGapsTheArchiveHasNoPageIdentifiers() throws {
		let archive = layout().archive(appLibrary: [])
		XCTAssertNil(archive["listUniqueIdentifiers"])
		XCTAssertNil(archive["listMetadata"])
	}

	func testAGapPinsTheIconsAfterIt() throws {
		let offloaded = layout().removing(atlas)
		let archive = offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: atlasSpot]))
		XCTAssertEqual((archive["listUniqueIdentifiers"] as? [String])?.count, 3)
		XCTAssertEqual(try pins(archive), [1: [news: 2]])
		// The icons go in the same order.
		XCTAssertEqual((archive["iconLists"] as? [[Any]])?[1] as? [String], [fitness, news])
	}

	func testAGapAfterAPagesLastIconNeedsNothing() throws {
		let offloaded = layout().removing(news)
		let spot = HomeScreenSpot(page: 1, index: 2, previous: atlas)
		XCTAssertEqual(offloaded.gapPlaces(HomeScreenGaps(held: [news: spot])), [:])
		XCTAssertNil(offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [news: spot]))["listMetadata"])
	}

	func testTwoGapsSideBySide() throws {
		let page = [calendar, atlas, nimbus, maps, compass]
		let offloaded = HomeScreenLayout(iconState: [[], page])!.removing(atlas).removing(nimbus)
		let gaps = HomeScreenGaps(held: [
			atlas: HomeScreenSpot(page: 0, index: 1, previous: calendar, next: nimbus),
			nimbus: HomeScreenSpot(page: 0, index: 2, previous: atlas, next: maps),
		])
		XCTAssertEqual(offloaded.gapPlaces(gaps), [0: [1, 1]])
		XCTAssertEqual(try pins(offloaded.archive(appLibrary: [], gaps: gaps)), [0: [maps: 3, compass: 4]])
	}

	func testAFolderAfterAGapIsPinnedByAnIdentifierItGets() throws {
		let offloaded = HomeScreenLayout(iconState: [[], [fitness, atlas, Icon.folder("Games", [[Icon.app(nimbus)]])]])!.removing(atlas)
		let archive = offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 0, index: 1, previous: fitness, next: "folder:Games")]))
		let folder = try XCTUnwrap((archive["iconLists"] as? [[Any]])?[0][1] as? [String: Any])
		let id = try XCTUnwrap(folder["uniqueIdentifier"] as? String)
		XCTAssertEqual(try pins(archive), [0: [id: 2]])
		XCTAssertEqual(folder["iconLists"] as? [[String]], [[nimbus]])
	}

	func testAFolderKeepsTheIdentifierItHas() throws {
		var games = Icon.folder("Games", [[Icon.app(nimbus)]])
		games["uniqueIdentifier"] = "F1"
		let offloaded = HomeScreenLayout(iconState: [[], [fitness, atlas, games]])!.removing(atlas)
		let archive = offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 0, index: 1, previous: fitness, next: "folder:Games")]))
		XCTAssertEqual(try pins(archive), [0: ["F1": 2]])
	}

	func testNoGapOnAPageWithAWidget() {
		let offloaded = layout().removing(maps)
		let spot = HomeScreenSpot(page: 0, index: 2, previous: calendar, next: "folder:Tools")
		XCTAssertEqual(offloaded.gapPlaces(HomeScreenGaps(held: [maps: spot])), [:])
		XCTAssertNil(offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [maps: spot]))["listMetadata"])
	}

	func testNoGapOnAFullPage() {
		let page = (0..<24).map { "com.example.app\($0)" }
		let full = HomeScreenLayout(iconState: [[], page])!
		XCTAssertEqual(full.gapPlaces(HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 0, index: 6, previous: "com.example.app5", next: "com.example.app6")])), [:])
		let room = full.removing("com.example.app23")
		XCTAssertEqual(room.gapPlaces(HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 0, index: 6, previous: "com.example.app5", next: "com.example.app6")])), [0: [6]])
	}

	func testNoGapWithoutTheIconsBesideIt() {
		// Alone on its page, which iOS took away with it: page 3 is now the
		// next one, if any.
		XCTAssertEqual(layout().gapPlaces(HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 2, index: 0)])), [:])
		XCTAssertEqual(layout().gapPlaces(HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 1, index: 1, previous: "com.example.gone", next: "com.example.gone2")])), [:])
	}

	func testNoGapInTheDockOrAFolder() {
		let layout = layout()
		XCTAssertEqual(layout.gapPlaces(HomeScreenGaps(held: ["com.example.gone": HomeScreenSpot(page: nil, index: 1, previous: safari, next: twelve)])), [:])
		var inFolder = HomeScreenSpot(page: 0, index: 1, previous: feather)
		inFolder.folder = HomeScreenSpot.Folder(name: "Tools", index: 3, page: 0)
		XCTAssertEqual(layout.gapPlaces(HomeScreenGaps(held: ["com.example.gone": inFolder])), [:])
	}

	func testTheGapGoesBeforeTheIconItWasBeforeOnceTheOneAfterMoved() throws {
		// Fitness moved to page 3 meanwhile.
		var moved = layout().removing(atlas)
		moved.pages[1].removeFirst()
		moved.pages[2].append(.init(fitness))
		XCTAssertEqual(try pins(moved.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: atlasSpot]))), [1: [news: 1]])
	}

	func testTheGapFollowsTheIconItWasAfter() throws {
		// Compass came in after Fitness meanwhile.
		var moved = layout().removing(atlas)
		moved.pages[1].insert(.init(compass), at: 0)
		XCTAssertEqual(try pins(moved.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: atlasSpot]))), [1: [news: 3]])
	}

	func testTheArchiveWithAGapReadsBackAsTheSameLayout() throws {
		let offloaded = layout().removing(atlas)
		let archive = offloaded.archive(appLibrary: [], gaps: HomeScreenGaps(held: [atlas: atlasSpot]))
		let state = [archive["buttonBar"]!] + (archive["iconLists"] as! [Any])
		let read = try XCTUnwrap(HomeScreenLayout(iconState: state))
		XCTAssertEqual(read.differences(from: offloaded), [])
	}
}

/// Gaps you mark in Open Spaces (7 Nov 2026).
final class HomeScreenMarkedGapTests: XCTestCase {
	/// A gap between Fitness and Atlas, on page 2.
	private let beforeAtlas = HomeScreenGap(page: 1, after: fitness, before: atlas)

	private func pins(_ archive: [String: Any]) throws -> [Int: [String: Int]] {
		guard let pageIDs = archive["listUniqueIdentifiers"] as? [String] else { return [:] }
		let metadata = try XCTUnwrap(archive["listMetadata"] as? [String: [String: Any]])
		var pins: [Int: [String: Int]] = [:]
		for (page, id) in pageIDs.enumerated() {
			guard let entry = metadata[id] else { continue }
			pins[page] = try XCTUnwrap(entry["fixedLocations"] as? [String: Int])
		}
		return pins
	}

	func testAMarkedGapPinsTheIconsAfterIt() throws {
		let gaps = HomeScreenGaps(marked: [beforeAtlas])
		XCTAssertEqual(layout().gapPlaces(gaps), [1: [1]])
		XCTAssertEqual(try pins(layout().archive(appLibrary: [], gaps: gaps)), [1: [atlas: 2, news: 3]])
		XCTAssertEqual(layout().plan(gaps).kept, [beforeAtlas])
	}

	func testAGapOfTwoPlaces() throws {
		var two = beforeAtlas
		two.count = 2
		XCTAssertEqual(try pins(layout().archive(appLibrary: [], gaps: HomeScreenGaps(marked: [two]))), [1: [atlas: 3, news: 4]])
	}

	func testAGapAtTheStartOfAPage() throws {
		let first = HomeScreenGap(page: 1, after: nil, before: fitness)
		XCTAssertEqual(try pins(layout().archive(appLibrary: [], gaps: HomeScreenGaps(marked: [first]))), [1: [fitness: 1, atlas: 2, news: 3]])
	}

	func testAnAppThatCameBetweenFillsTheGap() {
		var filled = layout()
		filled.pages[1].insert(.init(nimbus), at: 1)
		let plan = filled.plan(HomeScreenGaps(marked: [beforeAtlas]))
		XCTAssertEqual(plan.marked.map(\.state), [.filled(by: [nimbus])])
		XCTAssertEqual(plan.kept, [])
		XCTAssertNil(filled.archive(appLibrary: [], gaps: HomeScreenGaps(marked: [beforeAtlas]))["listMetadata"])
	}

	func testAnAppInAGapsFirstPlaceLeavesTheRest() throws {
		// A new app goes in the first free place, the first of the two.
		var two = beforeAtlas
		two.count = 2
		var filled = layout()
		filled.pages[1].insert(.init(nimbus), at: 1)
		let plan = filled.plan(HomeScreenGaps(marked: [two]))
		let rest = HomeScreenGap(page: 1, after: nimbus, before: atlas)
		XCTAssertEqual(plan.marked.map(\.state), [.shrank(to: rest, by: [nimbus])])
		XCTAssertEqual(plan.kept, [rest])
		XCTAssertEqual(try pins(filled.archive(appLibrary: [], gaps: HomeScreenGaps(marked: [two]))), [1: [atlas: 3, news: 4]])
	}

	func testAnAppAtThePagesStartLeavesTheRestOfItsGap() {
		// Page 11 of a test iPhone, 8 Nov 2026: two places before an app, and
		// another went in the first.
		let start = HomeScreenGap(page: 1, after: nil, before: fitness, count: 2)
		var filled = layout()
		filled.pages[1].insert(.init(nimbus), at: 0)
		let plan = filled.plan(HomeScreenGaps(marked: [start]))
		let rest = HomeScreenGap(page: 1, after: nimbus, before: fitness)
		XCTAssertEqual(plan.marked.map(\.state), [.shrank(to: rest, by: [nimbus])])
		XCTAssertEqual(plan.gapPlaces, [1: [1]])
	}

	func testAppsInEveryPlaceFillTheGap() {
		var two = beforeAtlas
		two.count = 2
		var filled = layout()
		filled.pages[1].insert(contentsOf: [.init(nimbus), .init(news)], at: 1)
		filled.pages[1].removeLast()
		XCTAssertEqual(filled.plan(HomeScreenGaps(marked: [two])).marked.map(\.state), [.filled(by: [nimbus, news])])
	}

	func testTheGapMovesWithItsIcons() throws {
		// Fitness and Atlas moved to the last page.
		var moved = layout()
		moved.pages[1].removeFirst(2)
		moved.pages[2] += [.init(fitness), .init(atlas)]
		let plan = moved.plan(HomeScreenGaps(marked: [beforeAtlas]))
		XCTAssertEqual(plan.marked.map(\.state), [.kept(page: 2)])
		XCTAssertEqual(plan.kept, [HomeScreenGap(page: 2, after: fitness, before: atlas)])
		XCTAssertEqual(try pins(moved.archive(appLibrary: [], gaps: HomeScreenGaps(marked: [beforeAtlas]))), [2: [atlas: 3]])
	}

	func testAGapWhoseIconLeftThePageIsNoLongerThere() {
		var moved = layout()
		moved.pages[1].removeFirst()
		moved.pages[2].append(.init(fitness))
		XCTAssertEqual(moved.plan(HomeScreenGaps(marked: [beforeAtlas])).marked.map(\.state), [.moved])
		XCTAssertEqual(layout().removing(atlas).plan(HomeScreenGaps(marked: [beforeAtlas])).marked.map(\.state), [.moved])
	}

	func testGapsBesideAnOffloadedAppsSpot() throws {
		let offloaded = layout().removing(atlas)
		let held = [atlas: HomeScreenSpot(page: 1, index: 1, previous: fitness, next: news)]
		// One before its spot, one after it.
		let gaps = HomeScreenGaps(held: held, marked: [beforeAtlas, HomeScreenGap(page: 1, after: atlas, before: news)])
		let plan = offloaded.plan(gaps)
		XCTAssertEqual(plan.pages[1], [.item(.init(fitness)), .gap, .held(atlas), .gap, .item(.init(news))])
		XCTAssertEqual(plan.marked.map(\.state), [.kept(page: 1), .kept(page: 1)])
		XCTAssertEqual(try pins(offloaded.archive(appLibrary: [], gaps: gaps)), [1: [news: 4]])
	}

	func testNoGapOnAPageWithAWidget() {
		let gap = HomeScreenGap(page: 0, after: calendar, before: maps)
		let plan = layout().plan(HomeScreenGaps(marked: [gap]))
		XCTAssertEqual(plan.marked.map(\.state), [.noRoom(page: 0)])
		XCTAssertEqual(plan.noGaps, [0])
		XCTAssertNil(layout().archive(appLibrary: [], gaps: HomeScreenGaps(marked: [gap]))["listMetadata"])
	}

	func testNoGapOnAFullPage() {
		let full = HomeScreenLayout(iconState: [[], (0..<24).map { "com.example.app\($0)" }])!
		let gap = HomeScreenGap(page: 0, after: "com.example.app5", before: "com.example.app6")
		XCTAssertEqual(full.plan(HomeScreenGaps(marked: [gap])).marked.map(\.state), [.noRoom(page: 0)])
		XCTAssertEqual(full.removing("com.example.app23").gapPlaces(HomeScreenGaps(marked: [gap])), [0: [6]])
	}

	func testTheGapsAPageShows() {
		let slots: [HomeScreenSlot] = [.item(.init(fitness)), .gap, .gap, .item(.init(atlas)), .gap, .held(twelve), .item(.init(news)), .gap]
		XCTAssertEqual(HomeScreenPlan.marked(in: slots, page: 4), [
			HomeScreenGap(page: 4, after: fitness, before: atlas, count: 2),
			HomeScreenGap(page: 4, after: atlas, before: twelve),
		])
		XCTAssertEqual(HomeScreenPlan.marked(in: [.gap, .item(.init(fitness))], page: 0), [HomeScreenGap(page: 0, after: nil, before: fitness)])
	}

	func testAFolderKeepsAGapByItsName() throws {
		let gap = HomeScreenGap(page: 0, after: "folder:Games", before: nimbus)
		let page = HomeScreenLayout(iconState: [[], [fitness, Icon.folder("Games", [[Icon.app(atlas)]]), nimbus]])!
		XCTAssertEqual(try pins(page.archive(appLibrary: [], gaps: HomeScreenGaps(marked: [gap]))), [0: [nimbus: 3]])
	}

	/// 8 Nov 2026: Offload kept 30sec's spot empty, an icon was moved
	/// into it, and Reinstall put 30sec back, pushing that icon and the
	/// ones after it along.
	func testAnOffloadedAppsSpotSomethingCameIntoIsNoLongerKeptEmpty() {
		let spot = HomeScreenSpot(page: 0, index: 1, previous: fitness, next: news)
		let moved = HomeScreenLayout(iconState: [[], [fitness, compass, news]])!
		let gaps = HomeScreenGaps(held: [atlas: spot])
		let plan = moved.plan(gaps)
		XCTAssertEqual(plan.taken, [atlas: [compass]])
		XCTAssertEqual(plan.pages[0], [.item(.init(fitness)), .item(.init(compass)), .item(.init(news))])
		XCTAssertNil(moved.archive(appLibrary: [], gaps: gaps)["listMetadata"])
		// Nothing came: still kept.
		let empty = HomeScreenLayout(iconState: [[], [fitness, news, compass]])!
		XCTAssertEqual(empty.plan(gaps).taken, [:])
		XCTAssertEqual(empty.gapPlaces(gaps), [0: [1]])
	}

	func testWhatCameIntoASpot() {
		let reinstalled = HomeScreenLayout(iconState: [[], [fitness, compass, news, atlas]])!.removing(atlas)
		XCTAssertEqual(reinstalled.taken(HomeScreenSpot(page: 0, index: 1, previous: fitness, next: news)), [compass])
		XCTAssertEqual(reinstalled.taken(HomeScreenSpot(page: 0, index: 2, previous: compass, next: news)), [])
		// First on its page, and last.
		XCTAssertEqual(reinstalled.taken(HomeScreenSpot(page: 0, index: 0, next: compass)), [fitness])
		XCTAssertEqual(reinstalled.taken(HomeScreenSpot(page: 0, index: 3, previous: news)), [])
		// Its icons gone, swapped, or its page gone: nothing to tell by.
		XCTAssertNil(reinstalled.taken(HomeScreenSpot(page: 0, index: 1, previous: maps, next: news)))
		XCTAssertNil(reinstalled.taken(HomeScreenSpot(page: 0, index: 1, previous: news, next: fitness)))
		XCTAssertNil(reinstalled.taken(HomeScreenSpot(page: 3, index: 0, previous: fitness)))
	}

	func testWhatCameIntoASpotInAFolderOrTheDock() {
		var inTools = HomeScreenSpot(page: 0, index: 1, previous: feather, next: calculator)
		inTools.folder = HomeScreenSpot.Folder(name: "Tools", index: 3, page: 0)
		XCTAssertEqual(layout().taken(inTools), [])
		let crowded = HomeScreenLayout(iconState: [[safari, messages, mail], [Icon.folder("Tools", [[Icon.app(feather), nimbus, calculator]])]])!
		XCTAssertEqual(crowded.taken(inTools), [nimbus])
		XCTAssertEqual(crowded.taken(HomeScreenSpot(page: nil, index: 2, previous: messages, next: mail)), [])
	}

	func testAGapKeepsItsFieldsAsJSON() throws {
		let data = try JSONEncoder().encode([beforeAtlas, HomeScreenGap(page: 0, after: nil, before: news, count: 2)])
		XCTAssertEqual(try JSONDecoder().decode([HomeScreenGap].self, from: data), [beforeAtlas, HomeScreenGap(page: 0, after: nil, before: news, count: 2)])
	}
}

final class HomeScreenAppTests: XCTestCase {
	func testReadsInstalldsApps() throws {
		let records: [String: Any] = [
			atlas: ["CFBundleIdentifier": atlas, "CFBundleDisplayName": "Atlas", "CFBundleName": "AtlasApp"],
			nimbus: ["CFBundleIdentifier": nimbus, "CFBundleDisplayName": "", "CFBundleName": "Nimbus"],
			"com.example.bare": ["CFBundleIdentifier": "com.example.bare"],
			"com.example.secret": ["CFBundleName": "Secret", "SBAppTags": ["hidden"]],
		]
		let data = try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0)
		let apps = try XCTUnwrap(HomeScreenApp.apps(from: data)).sorted { $0.bundleID < $1.bundleID }
		XCTAssertEqual(apps, [
			HomeScreenApp(bundleID: atlas, name: "Atlas"),
			HomeScreenApp(bundleID: "com.example.bare", name: "com.example.bare"),
			HomeScreenApp(bundleID: nimbus, name: "Nimbus"),
			HomeScreenApp(bundleID: "com.example.secret", name: "Secret", hidden: true),
		])
		XCTAssertNil(HomeScreenApp.apps(from: Data("nope".utf8)))
	}

	func testTheNamesAndAppLibraryOfARead() {
		let screen = HomeScreenState(layout: layout(), apps: [HomeScreenApp(bundleID: atlas, name: "Atlas"), HomeScreenApp(bundleID: nimbus, name: "Nimbus")])
		XCTAssertEqual(screen.names, [atlas: "Atlas", nimbus: "Nimbus"])
		XCTAssertEqual(screen.appLibrary, [nimbus])
	}
}

/// A tunnel whose SpringBoard and installd answer from memory.
private final class HomeScreenConnection: RouteAConnection {
	var state: [Any] = iconState()
	var apps: [String: Any] = [atlas: ["CFBundleDisplayName": "Atlas"], nimbus: ["CFBundleDisplayName": "Nimbus"]]
	/// What setIconState was sent.
	private(set) var written: [String: Any]?

	func homeScreen() throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
	}

	func setHomeScreen(_ layout: Data) throws -> Data {
		written = try PropertyListSerialization.propertyList(from: layout, options: [], format: nil) as? [String: Any]
		state = [written?["buttonBar"] ?? []] + (written?["iconLists"] as? [Any] ?? [])
		return try homeScreen()
	}

	func homeScreenApps() throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: apps, format: .binary, options: 0)
	}

	/// SpringBoard's icons, by bundle ID.
	var icons: [String: Data] = [atlas: Data([0x89, 0x50, 0x4E, 0x47])]
	private(set) var iconsAskedFor: [[String]] = []

	func homeScreenIcons(_ bundleIDs: [String]) throws -> Data {
		iconsAskedFor.append(bundleIDs)
		return try PropertyListSerialization.data(fromPropertyList: icons.filter { bundleIDs.contains($0.key) }, format: .binary, options: 0)
	}

	func udid() throws -> String { "00008130-000A1B2C3D4E5F60" }
	func upload(_ ipa: URL, to remotePath: String, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {}
	func install(remotePath: String, progress: (Int) -> Void) throws {}
	func installedVersion(of bundleID: String) throws -> String? { nil }
	func uninstall(_ bundleID: String) throws {}
	func installedApps() throws -> [InstalledApp] { [] }
	func close() {}
}

private struct HomeScreenDevice: RouteADevice, @unchecked Sendable {
	let connection: HomeScreenConnection

	func connect(pairingFile: Data) throws -> any RouteAConnection {
		connection
	}
}

@MainActor
final class PairingInstallerHomeScreenTests: XCTestCase {
	private func installer(_ connection: HomeScreenConnection) -> PairingInstaller {
		PairingInstaller(.init(
			pairingFile: { Data("pairing".utf8) },
			network: { .ready },
			startVPN: { true },
			device: HomeScreenDevice(connection: connection),
			profileDevices: { _ in nil }
		))
	}

	func testReadsTheLayoutAndTheInstalledApps() async throws {
		let connection = HomeScreenConnection()
		let screen = try await installer(connection).homeScreen()
		XCTAssertEqual(screen.layout, layout())
		XCTAssertEqual(screen.names, [atlas: "Atlas", nimbus: "Nimbus"])
		XCTAssertEqual(screen.appLibrary, [nimbus])
		XCTAssertNotNil(screen.plist.flatMap(HomeScreenLayout.init(plist:)))
	}

	func testWritesTheLayoutWithTheAppLibraryAndReadsItBack() async throws {
		let connection = HomeScreenConnection()
		let installer = installer(connection)
		let screen = try await installer.homeScreen()
		let moved = try screen.layout.placing(atlas, at: HomeScreenSpot(page: 2, index: 1, previous: alone))
		let after = try await installer.writeHomeScreen(moved, appLibrary: screen.appLibrary)
		XCTAssertEqual(connection.written?["ignored"] as? [String], [nimbus])
		XCTAssertEqual(after.spot(of: atlas)?.description, "Page 3, 2nd")
		XCTAssertEqual(after.differences(from: moved), [])
	}

	func testWritesTheGapsItKeeps() async throws {
		let connection = HomeScreenConnection()
		let installer = installer(connection)
		let offloaded = try await installer.homeScreen().layout.removing(atlas)
		let after = try await installer.writeHomeScreen(offloaded, appLibrary: [], gaps: HomeScreenGaps(held: [atlas: HomeScreenSpot(page: 1, index: 1, previous: fitness, next: news)]))
		let pageIDs = try XCTUnwrap(connection.written?["listUniqueIdentifiers"] as? [String])
		let metadata = try XCTUnwrap(connection.written?["listMetadata"] as? [String: [String: Any]])
		XCTAssertEqual(metadata[pageIDs[1]]?["fixedLocations"] as? [String: Int], [news: 2])
		XCTAssertEqual(after.differences(from: offloaded), [])
	}

	func testWritesTheGapsYouMarked() async throws {
		let connection = HomeScreenConnection()
		let installer = installer(connection)
		let layout = try await installer.homeScreen().layout
		_ = try await installer.writeHomeScreen(layout, appLibrary: [], gaps: HomeScreenGaps(marked: [HomeScreenGap(page: 1, after: fitness, before: atlas)]))
		let pageIDs = try XCTUnwrap(connection.written?["listUniqueIdentifiers"] as? [String])
		let metadata = try XCTUnwrap(connection.written?["listMetadata"] as? [String: [String: Any]])
		XCTAssertEqual(metadata[pageIDs[1]]?["fixedLocations"] as? [String: Int], [atlas: 2, news: 3])
	}

	func testGetsTheIconsSpringBoardHas() async throws {
		let connection = HomeScreenConnection()
		let icons = try await installer(connection).homeScreenIcons([atlas, nimbus])
		XCTAssertEqual(icons, [atlas: Data([0x89, 0x50, 0x4E, 0x47])])
		XCTAssertEqual(connection.iconsAskedFor, [[atlas, nimbus]])
		// None asked for, no connection.
		let none = try await installer(connection).homeScreenIcons([])
		XCTAssertEqual(none, [:])
		XCTAssertEqual(connection.iconsAskedFor.count, 1)
	}

	func testAConnectionThatCantReadTheHomeScreenSaysWhichStep() async {
		let connection = HomeScreenConnection()
		connection.state = []
		do {
			_ = try await installer(connection).homeScreen()
			XCTFail("expected a failure")
		} catch {
			guard case .routeAStep(let step)? = error as? InstallFailure else { return XCTFail("\(error)") }
			XCTAssertEqual(step.step, .homeScreen)
			XCTAssertEqual((error as? InstallFailure)?.description, "Atelier couldn't read or change the Home Screen. Try again.")
		}
	}
}

/// Records what the installers ask of the Home Screen.
@MainActor
private final class FakeSpots: HomeScreenKeeping {
	private let record: @MainActor (String) -> Void

	init(_ record: @escaping @MainActor (String) -> Void) {
		self.record = record
	}

	func note(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		record("note \(bundleID)")
	}

	func putBack(_ bundleID: String, notedAs noted: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		record("put back \(bundleID) as noted for \(noted)")
	}
}

/// Keeping the app's Home Screen spot across a delete and an install.
@MainActor
final class HomeScreenInstallerTests: XCTestCase {
	private let package = InstallPackage(url: URL(fileURLWithPath: "/tmp/radiance.ipa"), info: IPAInfo(bundleID: "com.example.radiance", version: "3.0.1", name: "Radiance"))
	private var order: [String] = []

	private func replacing(_ base: MockInstaller, deleting: String? = nil) -> ReplacingInstaller {
		let after = { base.installed.isEmpty ? "" : " after the install" }
		let keeper = FakeKeeper { self.order.append($0 + after()) }
		let spots = FakeSpots { self.order.append($0 + after()) }
		return ReplacingInstaller(base, deleting: deleting, keeping: keeper, homeScreen: spots) { bundleID in
			self.order.append("delete \(bundleID)")
			return nil
		}
	}

	func testNotesTheSpotRightBeforeTheDeleteAndPutsTheAppBackLast() async throws {
		_ = try await replacing(MockInstaller(.pairing)).install(package) { _ in }
		XCTAssertEqual(order, [
			"save com.example.radiance",
			"note com.example.radiance",
			"delete com.example.radiance",
			"restore com.example.radiance after the install",
			"put back com.example.radiance as noted for com.example.radiance after the install",
		])
	}

	func testAnAppThatInstallsAsAnotherBundleIDTakesTheSpotOfTheOneItReplaces() async throws {
		_ = try await replacing(MockInstaller(.pairing), deleting: "com.example.radiance.A1B2C3D4E5").install(package) { _ in }
		XCTAssertEqual(order.filter { !$0.hasPrefix("save") && !$0.hasPrefix("move") && !$0.hasPrefix("restore") }, [
			"note com.example.radiance.A1B2C3D4E5",
			"delete com.example.radiance.A1B2C3D4E5",
			"put back com.example.radiance as noted for com.example.radiance.A1B2C3D4E5 after the install",
		])
	}

	func testAFailedInstallPutsNothingBack() async {
		let base = MockInstaller(.pairing)
		base.failure = .rejected("ApplicationVerificationFailed")
		_ = try? await replacing(base).install(package) { _ in }
		XCTAssertFalse(order.contains { $0.hasPrefix("put back") })
		XCTAssertTrue(order.contains("note com.example.radiance"))
	}

	func testReinstallPutsTheAppBackWhereOffloadNotedIt() async throws {
		let base = MockInstaller(.pairing)
		let keeper = FakeKeeper { self.order.append($0) }
		let spots = FakeSpots { self.order.append($0) }
		_ = try await RestoringInstaller(base, keeping: keeper, homeScreen: spots).install(package) { _ in }
		_ = try await RestoringInstaller(base, keeping: keeper, from: "com.example.radiance.F6G7H8I9J0", homeScreen: spots).install(package) { _ in }
		XCTAssertEqual(order.filter { $0.hasPrefix("put back") }, [
			"put back com.example.radiance as noted for com.example.radiance",
			"put back com.example.radiance as noted for com.example.radiance.F6G7H8I9J0",
		])
	}
}
