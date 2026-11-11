import Foundation
import XCTest
@testable import SourceKit

#if canImport(Darwin)
final class MarkdownNotesTests: XCTestCase {
	func testReleaseNotes() {
		let notes = MarkdownNotes.attributed("""
		First release\r
		\r
		## Highlights\r
		\r
		\r
		- **One-tap installs.** Tap Install.\r
		  - Nested, with a [link](https://example.com).\r
		---\r
		Plain text with 3 * 4 = 12.
		""")
		XCTAssertEqual(String(notes.characters), """
		First release

		Highlights

		• One-tap installs. Tap Install.
		    ◦ Nested, with a link.

		Plain text with 3 * 4 = 12.
		""")
		let heading = notes.runs.first { String(notes[$0.range].characters) == "Highlights" }
		XCTAssertEqual(heading?.inlinePresentationIntent, .stronglyEmphasized)
		let bold = notes.runs.first { String(notes[$0.range].characters) == "One-tap installs." }
		XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
		XCTAssertTrue(notes.runs.contains { $0.link == URL(string: "https://example.com") })
	}
}
#endif
