import Foundation
import XCTest
@testable import CertKit

/// Apple's token for its developer services, kept to sign in again
/// without the password (#182).
final class AppleIDTokenTests: XCTestCase {
	private let now: UInt64 = 1_794_500_000
	private var received: Date { Date(timeIntervalSince1970: TimeInterval(now)) }

	private func token(expiry: UInt64, duration: UInt64) -> AppleIDToken {
		AppleIDToken(adsid: "000123-45-6789", token: "a token", duration: duration, expiry: expiry, receivedAt: received, server: "https://ani.example.com")
	}

	func testReadsApplesEndInEitherUnit() {
		let day: UInt64 = 86_400
		let tomorrow = received.addingTimeInterval(86_400)
		XCTAssertEqual(token(expiry: (now + day) * 1000, duration: 0).endsAt, tomorrow, "milliseconds")
		XCTAssertEqual(token(expiry: now + day, duration: 0).endsAt, tomorrow, "seconds")
		XCTAssertEqual(token(expiry: 0, duration: day).endsAt, tomorrow, "how long it lasts, from when it came")
		XCTAssertNil(token(expiry: 0, duration: 0).endsAt)
		XCTAssertEqual(token(expiry: (now + day) * 1000, duration: day).lifetime, 86_400)
		XCTAssertNil(token(expiry: 0, duration: 0).lifetime)
	}

	func testIsTriedUntilShortlyBeforeItsEnd() {
		XCTAssertTrue(token(expiry: now + 3600, duration: 0).isUsable(at: received))
		XCTAssertFalse(token(expiry: now + 15 * 60, duration: 0).isUsable(at: received))
		XCTAssertFalse(token(expiry: now - 1, duration: 0).isUsable(at: received))
		XCTAssertTrue(token(expiry: 0, duration: 0).isUsable(at: received), "an end Apple didn't say is Apple's to tell")
	}

	func testNeverShowsTheTokenItself() {
		let kept = token(expiry: (now + 3600) * 1000, duration: 3600)
		XCTAssertFalse(String(describing: kept).contains("a token"))
		XCTAssertFalse(String(reflecting: kept).contains("a token"))
		XCTAssertFalse("\(kept)".contains("a token"))
		XCTAssertTrue("\(kept)".contains("https://ani.example.com"))
	}

	func testComesBackFromTheKeychainAsKept() throws {
		var kept = token(expiry: (now + 3600) * 1000, duration: 3600)
		kept.clientInfo = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
		kept.userAgent = "akd/1.0 CFNetwork/808.1.4"
		XCTAssertEqual(try JSONDecoder().decode(AppleIDToken.self, from: JSONEncoder().encode(kept)), kept)
	}
}
