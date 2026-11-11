import XCTest
@testable import SourceKit

final class UpdateNoticeTests: XCTestCase {
	private func update(_ name: String, _ version: String, build: String? = nil) -> UpdateNotice.Update {
		UpdateNotice.Update(bundleID: "com.example.\(name.lowercased())", version: AppVersion(version: version, buildVersion: build, downloadURL: URL(string: "https://example.com/\(name).ipa")!), name: name)
	}

	func testNamesEveryUpdateOnceOneIsNew() throws {
		let delta = update("Delta", "1.7"), utm = update("UTM", "4.6"), feather = update("Feather", "2.1")
		let notice = try XCTUnwrap(UpdateNotice.notice(for: [delta, utm, feather], told: [delta.key]))
		XCTAssertEqual(notice.title, "3 updates available")
		XCTAssertEqual(notice.body, "Delta 1.7, UTM 4.6 and Feather 2.1. Tap to open the Library.")

		let one = try XCTUnwrap(UpdateNotice.notice(for: [utm], told: []))
		XCTAssertEqual(one.title, "Update available")
		XCTAssertEqual(one.body, "UTM 4.6. Tap to open the Library.")
	}

	func testNothingWhenEveryUpdateWasTold() {
		let delta = update("Delta", "1.7"), utm = update("UTM", "4.6")
		XCTAssertNil(UpdateNotice.notice(for: [delta, utm], told: UpdateNotice.told(after: [delta, utm])))
		XCTAssertNil(UpdateNotice.notice(for: [], told: []))
		// A newer version of a told app is new.
		XCTAssertNotNil(UpdateNotice.notice(for: [update("Delta", "1.8"), utm], told: UpdateNotice.told(after: [delta, utm])))
		// So is a new build of the same version.
		XCTAssertNotNil(UpdateNotice.notice(for: [update("Delta", "1.7", build: "2")], told: [delta.key]))
	}

	func testManyUpdatesAreCounted() throws {
		let updates = ["A", "B", "C", "D", "E"].map { update($0, "1.0") }
		let notice = try XCTUnwrap(UpdateNotice.notice(for: updates, told: []))
		XCTAssertEqual(notice.body, "A 1.0, B 1.0, C 1.0 and 2 more. Tap to open the Library.")
	}
}

final class NewsNoticeTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_790_000_000)

	private func item(_ id: String, notify: Bool = true, daysAgo: Double? = 1, caption: String? = nil) -> NewsNotice.Item {
		NewsNotice.Item(
			id: "https://example.com/source.json#\(id)",
			sourceName: "AltStore Classic",
			item: NewsItem(identifier: id, title: "Delta 1.7", caption: caption, date: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, notify: notify)
		)
	}

	func testTheFirstCheckOnlyRemembers() {
		let result = NewsNotice.check([item("a"), item("b")], seen: nil, now: now)
		XCTAssertEqual(result.notify, [])
		XCTAssertEqual(result.seen, [item("a").id, item("b").id])
	}

	func testTellsNewFlaggedRecentItemsOnce() {
		let items = [item("old", daysAgo: 30), item("quiet", notify: false), item("undated", daysAgo: nil), item("new", caption: "Online multiplayer is here.")]
		let result = NewsNotice.check(items, seen: [], now: now)
		XCTAssertEqual(result.notify.map(\.item.identifier), ["undated", "new"])
		XCTAssertEqual(result.notify.last?.title, "AltStore Classic · News")
		XCTAssertEqual(result.notify.last?.body, "Delta 1.7: Online multiplayer is here.")
		XCTAssertEqual(NewsNotice.check(items, seen: result.seen, now: now).notify, [])
	}

	func testAtMostThreeAtOnce() {
		let items = (1...5).map { item("n\($0)", daysAgo: Double($0)) }
		XCTAssertEqual(NewsNotice.check(items, seen: [], now: now).notify.map(\.item.identifier), ["n1", "n2", "n3"])
	}
}
