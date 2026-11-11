import Foundation
import XCTest
@testable import AtelierCore

final class ThirdPartyNoticesTests: XCTestCase {
	private let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	func testReadsTheTable() {
		let markdown = """
		# Third-party notices

		Some text, with a | in it.

		| Project | Used for | License | Copyright |
		|---|---|---|---|
		| [zsign](https://github.com/zhlynn/zsign) | On-device IPA signing | MIT | zhlynn |
		| [Fork](https://example.com/a) | Wraps it; see [our fork](https://example.com/b), `atelier` branch | Apache-2.0 (OpenSSL 3) | A, B |

		## Rules

		| Not | a | notice | row |
		"""
		XCTAssertEqual(ThirdPartyNotice.parse(markdown), [
			ThirdPartyNotice(
				name: "zsign",
				url: URL(string: "https://github.com/zhlynn/zsign"),
				usedFor: "On-device IPA signing",
				license: "MIT",
				copyright: "zhlynn"
			),
			ThirdPartyNotice(
				name: "Fork",
				url: URL(string: "https://example.com/a"),
				usedFor: "Wraps it; see our fork, atelier branch",
				license: "Apache-2.0 (OpenSSL 3)",
				copyright: "A, B"
			),
		])
	}

	/// Every project in the repository's THIRD_PARTY_NOTICES.md has its
	/// license text, which the Acknowledgements screen shows.
	func testEveryNoticeHasItsLicenseText() throws {
		let markdown = try String(contentsOf: repository.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
		let notices = ThirdPartyNotice.parse(markdown)
		XCTAssertFalse(notices.isEmpty)
		for notice in notices {
			XCTAssertNotNil(notice.url, notice.name)
			XCTAssertTrue(
				notice.licensePaths.contains { FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path) },
				"\(notice.name) needs its license text in licenses/\(notice.name).txt"
			)
		}
	}
}
