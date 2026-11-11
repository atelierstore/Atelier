import Foundation
import XCTest
@testable import InstallKit

final class OffloadMarkersTests: XCTestCase {
	private let scheme = "atelier-com.example.atelier"

	func testEachMarkerOpensItsOwnLink() throws {
		let link = OffloadMarkers.link(2, scheme: scheme)
		XCTAssertEqual(link.absoluteString, "atelier-com.example.atelier://marker/2")
		XCTAssertEqual(OffloadMarkers.number(of: link, scheme: scheme), 2)
		XCTAssertEqual(OffloadMarkers.number(of: link), 2)
		XCTAssertNil(OffloadMarkers.number(of: link, scheme: "atelier"))
		XCTAssertNil(OffloadMarkers.number(of: URL(string: "atelier://source?url=x")!))
	}

	func testAStandInOpensItsAppsLink() throws {
		XCTAssertEqual(OffloadMarkers.standInBundleID(of: "com.example.feather"), "com.example.feather.offloaded")
		let link = OffloadMarkers.standInLink("com.example.feather", scheme: scheme)
		XCTAssertEqual(link.absoluteString, "atelier-com.example.atelier://standin/com.example.feather")
		XCTAssertEqual(OffloadMarkers.standIn(of: link, scheme: scheme), "com.example.feather")
		XCTAssertNil(OffloadMarkers.standIn(of: link, scheme: "atelier"))
		XCTAssertNil(OffloadMarkers.number(of: link, scheme: scheme))
		XCTAssertNil(OffloadMarkers.standIn(of: OffloadMarkers.link(1, scheme: scheme), scheme: scheme))
		XCTAssertNil(OffloadMarkers.standIn(of: URL(string: "\(scheme)://standin")!, scheme: scheme))
	}

	func testTheProfileHoldsAWebClipPerMarker() throws {
		let icon = Data([0x89, 0x50, 0x4E, 0x47])
		let data = try OffloadMarkers.profile(count: 3, scheme: scheme, bundleID: "com.example.atelier", icon: icon)
		let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
		XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
		XCTAssertEqual(profile["PayloadIdentifier"] as? String, "com.example.atelier.offload-markers")
		let clips = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
		XCTAssertEqual(clips.count, 3)
		XCTAssertEqual(clips.map { $0["URL"] as? String }, (1 ... 3).map { "\(scheme)://marker/\($0)" })
		XCTAssertEqual(Set(clips.compactMap { $0["Label"] as? String }), ["Offloaded"])
		XCTAssertEqual(clips[0]["PayloadType"] as? String, "com.apple.webClip.managed")
		XCTAssertEqual(clips[0]["Icon"] as? Data, icon)
		XCTAssertEqual(Set(clips.compactMap { $0["PayloadUUID"] as? String }).count, 3)
	}

	func testRemovingNamesTheProfileAsTheListGivesIt() throws {
		let list = OffloadMarkers.Answer([
			"Status": "Acknowledged",
			"OrderedIdentifiers": ["com.example.atelier.offload-markers"],
			"ProfileMetadata": ["com.example.atelier.offload-markers": ["PayloadUUID": "U-1", "PayloadVersion": 1, "PayloadDisplayName": "Atelier Markers"]],
		])
		XCTAssertTrue(list.isAcknowledged)
		XCTAssertNil(list.error)
		let profile = try XCTUnwrap(list.profiles.first)
		XCTAssertEqual(profile, .init(identifier: "com.example.atelier.offload-markers", uuid: "U-1", version: 1, name: "Atelier Markers"))
		let remove = try OffloadMarkers.Request.remove(identifier: profile.identifier, uuid: profile.uuid, version: profile.version)
		XCTAssertEqual(remove.type, "RemoveProfile")
		let named = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(remove.values["ProfileIdentifier"] as? Data), options: [], format: nil) as? [String: Any])
		XCTAssertEqual(named["PayloadIdentifier"] as? String, profile.identifier)
		XCTAssertEqual(named["PayloadUUID"] as? String, "U-1")

		let refused = OffloadMarkers.Answer(["Status": "Error", "ErrorChain": [["LocalizedDescription": "The profile couldn’t be installed.", "ErrorDomain": "MCInstallationErrorDomain", "ErrorCode": 4001]]])
		XCTAssertEqual(refused.error, "The profile couldn’t be installed. (MCInstallationErrorDomain 4001)")
	}

	func testFindsTheMarkersByTheirLinks() throws {
		let clip = { (id: String, number: Int) -> [String: Any] in
			["displayIdentifier": id, "displayName": "Offloaded", "webClipURL": "\(self.scheme)://marker/\(number)"]
		}
		let layout = try XCTUnwrap(HomeScreenLayout(iconState: [
			["com.apple.mobilesafari"],
			["com.example.a", clip("W2", 2), "com.example.b"],
			[["displayName": "Markers", "listType": "folder", "iconLists": [[clip("W1", 1)]]]],
		] as [Any]))
		let markers = layout.markers(scheme: scheme)
		XCTAssertEqual(markers.map(\.number), [1, 2])
		XCTAssertEqual(markers.map(\.id), ["W1", "W2"])
		XCTAssertTrue(markers.allSatisfy(\.byLink))
		XCTAssertEqual(markers[1].spot?.description, "Page 1, 2nd")
		XCTAssertEqual(markers[0].spot?.folder?.name, "Markers")
		XCTAssertEqual(Set(layout.webClipKeys.keys), ["W1", "W2"])
	}

	func testWithoutLinksMarkersAreNumberedInOrder() throws {
		let layout = try XCTUnwrap(HomeScreenLayout(iconState: [
			[] as [Any],
			["com.example.a", ["displayIdentifier": "W7", "displayName": "Offloaded"], ["displayIdentifier": "W3", "displayName": "Offloaded"], ["bundleIdentifier": "com.example.offloaded", "displayIdentifier": "com.example.offloaded", "displayName": "Offloaded"]],
		] as [Any]))
		let markers = layout.markers(scheme: scheme)
		XCTAssertEqual(markers.map(\.id), ["W7", "W3"])
		XCTAssertEqual(markers.map(\.number), [1, 2])
		XCTAssertFalse(markers[0].byLink)
	}

	func testFolderingPutsThemInAFolderOnTheLastPage() throws {
		let layout = HomeScreenLayout(dock: [], pages: [
			["com.example.a", "W1", "com.example.b"].map(HomeScreenLayout.Item.init),
			["com.example.c", "W2"].map(HomeScreenLayout.Item.init),
		])
		let foldered = layout.foldering(["W1", "W2", "W3"], named: "Markers")
		XCTAssertEqual(foldered.pages[0].map(\.key), ["com.example.a", "com.example.b"])
		XCTAssertEqual(foldered.pages[1].map(\.key), ["com.example.c", "folder:Markers"])
		XCTAssertEqual(foldered.spot(of: "W3")?.folder?.name, "Markers")
		let archived = try XCTUnwrap(foldered.archive(appLibrary: [])["iconLists"] as? [[Any]])
		let folder = try XCTUnwrap(archived[1][1] as? [String: Any])
		XCTAssertEqual(folder["iconLists"] as? [[String]], [["W1", "W2", "W3"]])

		// Again, the folder they leave goes, and a new one takes them.
		let again = foldered.foldering(["W1", "W2", "W3"], named: "Markers")
		XCTAssertEqual(again.pages[1].map(\.key), ["com.example.c", "folder:Markers"])
		XCTAssertEqual(again.raw(of: "W1")?.values["displayIdentifier"] as? String, "W1")
	}
}
