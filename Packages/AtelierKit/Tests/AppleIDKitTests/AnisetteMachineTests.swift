import Foundation
import XCTest
@testable import AppleIDKit

final class AnisetteMachineTests: XCTestCase {
	private var storage: URL!
	private let server = AnisetteList.Server(url: URL(string: "https://mac-ani.jkcoxson.com")!, name: "jkcoxson (Mac)")
	private let macOSX = "<MacBookPro18,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
	private let macOS = "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

	override func setUpWithError() throws {
		storage = FileManager.default.temporaryDirectory.appendingPathComponent("AnisetteMachineTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: storage)
	}

	private var machine: AnisetteMachine { AnisetteMachine(server: server, storage: storage) }

	/// isideload's state for the server, as it writes it.
	private func makeState() throws {
		let state = server.stateFile(in: storage)
		try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("state".utf8).write(to: state)
	}

	private var hasState: Bool { FileManager.default.fileExists(atPath: server.stateFile(in: storage).path) }

	func testTheNoteIsBesideIsideloadsState() {
		XCTAssertEqual(machine.state, server.stateFile(in: storage))
		XCTAssertEqual(machine.noteFile.deletingLastPathComponent(), machine.state.deletingLastPathComponent())
		XCTAssertEqual(machine.noteFile.lastPathComponent, "client_info")
	}

	func testWithNoStateTheSignInMakesOneAsItsClientInfo() throws {
		XCTAssertEqual(try machine.ready(for: macOSX), .new)
		// What isideload then makes.
		try makeState()
		XCTAssertEqual(machine.madeAs, macOSX)
		XCTAssertEqual(try machine.ready(for: macOSX), .kept)
		XCTAssertTrue(hasState)
	}

	func testAStateMadeAsAnotherClientInfoGoes() throws {
		try makeState()
		try machine.note(macOS)
		XCTAssertEqual(try machine.ready(for: macOSX), .replaced(madeAs: macOS))
		XCTAssertFalse(hasState)
		// The new one will be made as the new client info.
		try makeState()
		XCTAssertEqual(machine.madeAs, macOSX)
	}

	func testAStateWithNoNoteGoes() throws {
		// As every Atelier up to 0.8.0-alpha left it.
		try makeState()
		XCTAssertNil(machine.madeAs)
		XCTAssertEqual(try machine.ready(for: macOSX), .replaced(madeAs: nil))
		XCTAssertFalse(hasState)
	}

	func testANoteWithoutAStateSaysNothing() throws {
		try machine.note(macOS)
		XCTAssertNil(machine.madeAs)
		XCTAssertEqual(try machine.ready(for: macOSX), .new)
	}

	func testTheInstallersStateKeepsTheClientInfoItWasMadeAs() throws {
		try makeState()
		try machine.note(" \(macOSX)")
		XCTAssertEqual(try machine.ready(for: macOSX), .kept)
	}
}
