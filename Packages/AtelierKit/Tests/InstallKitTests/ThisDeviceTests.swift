import XCTest
@testable import InstallKit

final class ThisDeviceTests: XCTestCase {
	func testNamesFromModels() {
		XCTAssertEqual(ThisDevice.displayName(forModel: "iPad13,1"), "iPad")
		XCTAssertEqual(ThisDevice.displayName(forModel: "iPad16,3"), "iPad")
		XCTAssertEqual(ThisDevice.displayName(forModel: "iPhone16,1"), "iPhone")
		// Anything else, like a Mac running the tests or a model Atelier
		// doesn't know, is called an iPhone.
		XCTAssertEqual(ThisDevice.displayName(forModel: "arm64"), "iPhone")
		XCTAssertEqual(ThisDevice.displayName(forModel: ""), "iPhone")
	}

	func testReadsAModel() {
		XCTAssertFalse(ThisDevice.model.isEmpty)
		XCTAssertEqual(ThisDevice.name, ThisDevice.displayName(forModel: ThisDevice.model))
	}
}
