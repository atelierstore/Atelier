import Foundation
import SigningKit
import XCTest
@testable import AtelierCore

/// What Custom Install's choices leave for an app's updates and re-signs: a
/// copy's (#113), or the app's itself (#155).
final class CopyStoreTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = FileManager.default.temporaryDirectory.appending(path: "CopyStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	func testKeepsEachCopysSettingsByItsNumberedID() throws {
		let store = CopyStore(folder: folder)
		XCTAssertNil(store.settings(for: "com.x.atelier2"))
		let settings = CopySettings(bundleID: "com.me.x", tint: .teal, version: "9.0", removesURLSchemes: true)
		try store.save(settings, for: "com.x.atelier2")

		XCTAssertEqual(store.settings(for: "com.x.atelier2"), settings)
		XCTAssertEqual(store.installedID(of: "com.x.atelier2"), "com.me.x")
		XCTAssertEqual(store.installedID(of: "com.x.atelier3"), "com.x.atelier3")
		XCTAssertEqual(store.numberedID(installedAs: "com.me.x"), "com.x.atelier2")
		XCTAssertNil(store.numberedID(installedAs: "com.x.atelier2"))
		XCTAssertEqual(store.numberedIDs, ["com.x.atelier2"])

		// Read again from the file.
		let again = CopyStore(folder: folder)
		XCTAssertEqual(again.settings(for: "com.x.atelier2"), settings)
		XCTAssertEqual(again.numberedID(installedAs: "com.me.x"), "com.x.atelier2")
	}

	func testForgetsWhatChangesNothing() throws {
		let store = CopyStore(folder: folder)
		try store.save(CopySettings(bundleID: "com.x.atelier2"), for: "com.x.atelier2")
		XCTAssertNil(store.settings(for: "com.x.atelier2"), "its own numbered ID is no other")
		try store.save(CopySettings(tint: .red), for: "com.x.atelier2")
		try store.save(CopySettings(), for: "com.x.atelier2")
		XCTAssertNil(store.settings(for: "com.x.atelier2"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Copies.json").path))
	}

	func testKeepsThePictureNextToTheSettings() throws {
		let store = CopyStore(folder: folder)
		let picture = Data([1, 2, 3])
		try store.save(CopySettings(tint: .blue, hasPicture: true), picture: picture, for: "com.x.atelier2")
		XCTAssertEqual(store.picture(for: "com.x.atelier2"), picture)
		XCTAssertEqual(store.settings(for: "com.x.atelier2")?.icon(picture: picture), IconChange(picture: picture, tint: .blue))

		// Saved again without one, it keeps the picture it has.
		try store.save(CopySettings(tint: .green, hasPicture: true), for: "com.x.atelier2")
		XCTAssertEqual(store.picture(for: "com.x.atelier2"), picture)

		// Without a picture, it goes.
		try store.save(CopySettings(tint: .green), for: "com.x.atelier2")
		XCTAssertNil(store.picture(for: "com.x.atelier2"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "com.x.atelier2.png").path))
		XCTAssertEqual(store.settings(for: "com.x.atelier2")?.icon(picture: picture), IconChange(tint: .green))
		XCTAssertNil(CopySettings(version: "2.0").icon(picture: picture))
	}

	func testOneCopyForEachInstalledID() throws {
		let store = CopyStore(folder: folder)
		try store.save(CopySettings(bundleID: "com.me.x", hasPicture: true), picture: Data([1]), for: "com.x.atelier2")
		// Copy 2 was deleted outside Atelier, and copy 3 took its ID.
		try store.save(CopySettings(bundleID: "com.me.x"), for: "com.x.atelier3")
		XCTAssertNil(store.settings(for: "com.x.atelier2"))
		XCTAssertNil(store.picture(for: "com.x.atelier2"))
		XCTAssertEqual(store.numberedID(installedAs: "com.me.x"), "com.x.atelier3")
	}

	func testForgetsCopiesNoLongerInTheLibrary() throws {
		let store = CopyStore(folder: folder)
		try store.save(CopySettings(bundleID: "com.me.x", hasPicture: true), picture: Data([1]), for: "com.x.atelier2")
		try store.save(CopySettings(tint: .red), for: "com.x.atelier3")
		try store.save(CopySettings(tint: .blue), for: "com.y.atelier2")
		store.keep(only: ["com.me.x", "com.y.atelier2", "com.x"])
		XCTAssertEqual(store.numberedIDs.sorted(), ["com.x.atelier2", "com.y.atelier2"])
		XCTAssertEqual(store.picture(for: "com.x.atelier2"), Data([1]))
		store.remove("com.x.atelier2")
		XCTAssertNil(store.settings(for: "com.x.atelier2"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "com.x.atelier2.png").path))
	}

	/// What Custom Install… chose for an app itself (#155), by its own
	/// bundle ID: its name too, and never another App ID.
	func testKeepsAnAppsOwnSettingsByItsBundleID() throws {
		let store = CopyStore(folder: folder)
		let settings = CopySettings(name: "Emu", tint: .purple, version: "9.0")
		try store.save(settings, for: "com.x")
		XCTAssertEqual(store.settings(for: "com.x"), settings)
		XCTAssertEqual(store.installedID(of: "com.x"), "com.x")
		XCTAssertNil(store.numberedID(installedAs: "com.x"))
		XCTAssertEqual(CopyStore(folder: folder).settings(for: "com.x")?.name, "Emu")

		// Numbering copies goes by copies' IDs alone.
		try store.save(CopySettings(tint: .red), for: "com.x.atelier3")
		XCTAssertEqual(InstallTarget.newCopy(of: "com.x", installed: store.numberedIDs), .copy(4))

		// Its own name again, and nothing else, is nothing to keep.
		try store.save(CopySettings(), for: "com.x")
		XCTAssertNil(store.settings(for: "com.x"))
		store.keep(only: ["com.x", "com.x.atelier3"])
		XCTAssertEqual(store.numberedIDs, ["com.x.atelier3"])
	}

	/// Share App Groups (#49) is on unless it was turned off, which is
	/// kept for the app's updates.
	func testSharesAppGroupsUnlessTurnedOff() throws {
		XCTAssertTrue(CopySettings().sharesAppGroups)
		let store = CopyStore(folder: folder)
		try store.save(CopySettings(sharesAppGroups: false), for: "com.x")
		XCTAssertEqual(CopyStore(folder: folder).settings(for: "com.x")?.sharesAppGroups, false)
		try store.save(CopySettings(sharesAppGroups: true), for: "com.x")
		XCTAssertNil(store.settings(for: "com.x"), "on is nothing to keep")

		// Kept before the setting was there.
		let old = try JSONDecoder().decode(CopySettings.self, from: Data(#"{"removesURLSchemes": true}"#.utf8))
		XCTAssertTrue(old.sharesAppGroups)
	}

	func testKnowsWhichSettingsChangeTheIcon() {
		XCTAssertFalse(CopySettings().changesIcon)
		XCTAssertFalse(CopySettings(bundleID: "com.me.x", name: "Emu", version: "2.0", removesURLSchemes: true).changesIcon)
		XCTAssertTrue(CopySettings(tint: .blue).changesIcon)
		XCTAssertTrue(CopySettings(hasPicture: true).changesIcon)
	}

	/// The name Custom Install… signs with (#155): the app itself keeps
	/// its IPA's name, in every language, unless another is typed.
	func testSignsAnAppAgainWithTheNameTyped() {
		// The app itself, with its IPA's name.
		XCTAssertNil(CopySettings.signingName(typed: "Provenance", current: "Provenance", chosen: nil, isCopy: false))
		XCTAssertNil(CopySettings.signingName(typed: "  Provenance ", current: "Provenance", chosen: nil, isCopy: false))
		XCTAssertNil(CopySettings.signingName(typed: "", current: "Provenance", chosen: nil, isCopy: false))
		XCTAssertEqual(CopySettings.signingName(typed: "Emu ", current: "Provenance", chosen: nil, isCopy: false), "Emu")
		// With one chosen for it, which stays until it's emptied.
		XCTAssertEqual(CopySettings.signingName(typed: "Emu", current: "Emu", chosen: "Emu", isCopy: false), "Emu")
		XCTAssertEqual(CopySettings.signingName(typed: "Retro", current: "Emu", chosen: "Emu", isCopy: false), "Retro")
		XCTAssertNil(CopySettings.signingName(typed: " ", current: "Emu", chosen: "Emu", isCopy: false))
		// A copy's is written in, as its updates do, unless it's emptied.
		XCTAssertEqual(CopySettings.signingName(typed: "Provenance 2", current: "Provenance 2", chosen: nil, isCopy: true), "Provenance 2")
		XCTAssertEqual(CopySettings.signingName(typed: "Emu", current: "Provenance 2", chosen: nil, isCopy: true), "Emu")
		XCTAssertNil(CopySettings.signingName(typed: "", current: "Provenance 2", chosen: nil, isCopy: true))
	}

	func testReadsWhatItDoesntKnowAsNothing() throws {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try Data(#"{"com.x.atelier2": {"tint": "indigo", "version": "3.0", "glow": true}, "com.x.atelier3": {"removesURLSchemes": true}, "com.x": {"name": 7, "tint": "teal"}}"#.utf8)
			.write(to: folder.appending(path: "Copies.json"))
		let store = CopyStore(folder: folder)
		XCTAssertEqual(store.settings(for: "com.x.atelier2"), CopySettings(version: "3.0"))
		XCTAssertEqual(store.settings(for: "com.x.atelier3"), CopySettings(removesURLSchemes: true))
		XCTAssertEqual(store.settings(for: "com.x"), CopySettings(tint: .teal))

		try Data("not JSON".utf8).write(to: folder.appending(path: "Copies.json"))
		XCTAssertEqual(CopyStore(folder: folder).numberedIDs, [])
	}

	func testSaysWhatsWrongWithAnAppID() {
		func problem(_ id: String, taken: Set<String> = []) -> String? {
			CopySettings.problem(with: id, copy: 3, of: "com.google.ios.youtube") { taken.contains($0) }
		}
		XCTAssertNil(problem("com.google.ios.youtube.atelier3"))
		XCTAssertNil(problem("com.sam.Tube-3"))
		XCTAssertNil(problem("tube"))
		XCTAssertEqual(problem(""), "A copy needs an App ID.")
		XCTAssertEqual(problem("com.sam.tube 3"), "An App ID can only have letters, digits, hyphens (-) and full stops (.).")
		XCTAssertEqual(problem("com.sam.tübe"), "An App ID can only have letters, digits, hyphens (-) and full stops (.).")
		XCTAssertEqual(problem("com.sam_tube"), "An App ID can only have letters, digits, hyphens (-) and full stops (.).")
		XCTAssertEqual(problem(".com.sam"), "An App ID can't start or end with a full stop, or have two in a row.")
		XCTAssertEqual(problem("com..sam"), "An App ID can't start or end with a full stop, or have two in a row.")
		XCTAssertEqual(problem("com.sam."), "An App ID can't start or end with a full stop, or have two in a row.")
		XCTAssertEqual(problem("com.google.ios.youtube"), "That's the app's own ID. A copy needs another one.")
		XCTAssertEqual(problem("com.Google.iOS.YouTube"), "That's the app's own ID. A copy needs another one.")
		XCTAssertEqual(problem("com.google.ios.youtube.atelier2"), "IDs ending in .atelier2 are kept for Atelier's numbered copies.")
		XCTAssertEqual(problem("com.sam.atelier4"), "IDs ending in .atelier4 are kept for Atelier's numbered copies.")
		XCTAssertEqual(problem("com.sam.tube", taken: ["com.sam.tube"]), "An app in your Library has that ID already.")
	}

	func testGivesANewCopyAnAppIDFromItsName() {
		func id(_ name: String, suggested: String = "YouTube 2", copy number: Int = 2, of app: String = "com.google.ios.youtube", taken: Set<String> = []) -> String {
			CopySettings.bundleID(named: name, suggestedName: suggested, copy: number, of: app) { taken.contains($0) }
		}
		XCTAssertEqual(id("Atelier Tests", suggested: "Atelier 2", of: "com.atelier.app"), "com.atelier.app.ateliertests")
		XCTAssertEqual(id("Work"), "com.google.ios.youtube.work")
		XCTAssertEqual(id("  Kids' Tube 2 "), "com.google.ios.youtube.kidstube2")
		XCTAssertEqual(id("Café Δοκιμή"), "com.google.ios.youtube.cafedokime")
		XCTAssertEqual(id(String(repeating: "Tube", count: 20)), "com.google.ios.youtube." + String(repeating: "tube", count: 10))
		// The name it was suggested with keeps the numbered one, however
		// it's written.
		XCTAssertEqual(id("YouTube 2"), "com.google.ios.youtube.atelier2")
		XCTAssertEqual(id("youtube2"), "com.google.ios.youtube.atelier2")
		XCTAssertEqual(id("Atelier 3", suggested: "Atelier 3", copy: 3, of: "com.atelier.app"), "com.atelier.app.atelier3")
		// As do names without letters or digits, and IDs that can't be used.
		XCTAssertEqual(id(""), "com.google.ios.youtube.atelier2")
		XCTAssertEqual(id("🚀 !"), "com.google.ios.youtube.atelier2")
		XCTAssertEqual(id("Work", taken: ["com.google.ios.youtube.work"]), "com.google.ios.youtube.atelier2")
		XCTAssertEqual(id("Atelier 5"), "com.google.ios.youtube.atelier2")
	}
}
