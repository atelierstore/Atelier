import Foundation
import InstallKit
import XCTest
@testable import SigningKit
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// What Custom Install's choices do to the app before it's signed (#113):
/// the icon's tint or a picture in its place, the name in every language,
/// and no URL schemes.
final class AppIconTests: XCTestCase {
	private var folder: URL!
	private var work: URL!
	private let identity = SigningIdentity(p12: URL(fileURLWithPath: "/nonexistent.p12"), profile: URL(fileURLWithPath: "/nonexistent.mobileprovision"), password: "")

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
		work = folder.appendingPathComponent("work", isDirectory: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func sign(_ ipa: URL, options: SigningOptions) async throws -> SignedIPA {
		try await IPASigner(engine: FakeEngine(), workRoot: work)
			.sign(ipa: ipa, with: identity, options: options, outputDirectory: folder.appendingPathComponent("out"), progress: nil)
	}

	private func plist(_ path: String, in ipa: URL) throws -> (values: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
		var format = PropertyListSerialization.PropertyListFormat.xml
		let values = try PropertyListSerialization.propertyList(from: Fixture.contents(of: path, in: ipa), options: [], format: &format)
		return (try XCTUnwrap(values as? [String: Any]), format)
	}

	// MARK: Tints

	func testShadesGoFromDeepThroughTheTintToPale() {
		// As the mockup's icons were made, with Python's colorsys.
		let blue = AppIconTint.blue.shades
		XCTAssertEqual(blue.count, 256)
		XCTAssertEqual(blue[0], .init(0, 39, 82))
		XCTAssertEqual(blue[64], .init(0, 81, 169))
		XCTAssertEqual(blue[200], .init(125, 187, 255))
		XCTAssertEqual(blue[255], .init(219, 236, 255))
		let green = AppIconTint.green.shades
		XCTAssertEqual(green[0], .init(17, 65, 29))
		XCTAssertEqual(green[255], .init(227, 248, 232))
		XCTAssertEqual(AppIconTint.purple.shades[128], .init(155, 71, 198))
		XCTAssertEqual(AppIconTint.red.shades[200], .init(255, 135, 128))
	}

	func testEachTintIsItselfAtItsOwnLightness() {
		for tint in AppIconTint.allCases {
			let color = tint.color
			let own = AppIconTint.hls(color).lightness
			let shade = tint.shades[Int((own * 255).rounded())]
			for (made, wanted) in [(shade.red, color.red), (shade.green, color.green), (shade.blue, color.blue)] {
				XCTAssertLessThanOrEqual(abs(Int(made) - Int(wanted)), 1, "\(tint)")
			}
		}
	}

	func testShadesGetLighter() {
		for tint in AppIconTint.allCases {
			let levels = tint.shades.map { AppIconTint.lightness(red: $0.red, green: $0.green, blue: $0.blue) }
			XCTAssertEqual(levels, levels.sorted(), "\(tint)")
			XCTAssertLessThan(levels[0], levels[255], "\(tint)")
		}
	}

	func testLightnessWeighsGreenMost() {
		XCTAssertEqual(AppIconTint.lightness(red: 0, green: 0, blue: 0), 0)
		XCTAssertEqual(AppIconTint.lightness(red: 255, green: 255, blue: 255), 255)
		XCTAssertEqual(AppIconTint.lightness(red: 255, green: 0, blue: 0), 77)
		XCTAssertEqual(AppIconTint.lightness(red: 0, green: 255, blue: 0), 150)
		XCTAssertEqual(AppIconTint.lightness(red: 0, green: 0, blue: 255), 28)
	}

	func testTintsKeepTheirNames() throws {
		XCTAssertEqual(AppIconTint.allCases.map(\.rawValue), ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"])
		let encoded = try JSONEncoder().encode([AppIconTint.teal])
		XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[\"teal\"]")
	}

	// MARK: The Info.plist

	func testNamesTheNewIconForIPhoneAndIPad() {
		var info: [String: Any] = [
			"CFBundleIcons": [
				"CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon", "UIPrerenderedIcon": true],
				"CFBundleAlternateIcons": ["Dark": ["CFBundleIconFiles": ["Dark60x60"]]],
			],
			"CFBundleIconFiles": ["Icon.png", "Icon@2x.png"],
			"CFBundleIconFile": "Icon.png",
			"CFBundleName": "Test",
		]
		AppIconWriter.setIcon(in: &info, named: "AtelierIcon-1a2b3c4d")

		let phone = info["CFBundleIcons"] as? [String: Any]
		let primary = phone?["CFBundlePrimaryIcon"] as? [String: Any]
		XCTAssertEqual(primary?["CFBundleIconFiles"] as? [String], ["AtelierIcon-1a2b3c4d-60x60"])
		XCTAssertEqual(primary?["CFBundleIconName"] as? String, "AtelierIcon-1a2b3c4d")
		XCTAssertEqual(primary?["UIPrerenderedIcon"] as? Bool, true)
		XCTAssertNotNil(phone?["CFBundleAlternateIcons"], "alternate icons stay")
		let pad = (info["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
		XCTAssertEqual(pad?["CFBundleIconFiles"] as? [String], ["AtelierIcon-1a2b3c4d-60x60", "AtelierIcon-1a2b3c4d-76x76", "AtelierIcon-1a2b3c4d-83.5x83.5"])
		XCTAssertEqual(pad?["CFBundleIconName"] as? String, "AtelierIcon-1a2b3c4d")
		XCTAssertNil(info["CFBundleIconFiles"])
		XCTAssertNil(info["CFBundleIconFile"])
		XCTAssertEqual(info["CFBundleName"] as? String, "Test")
	}

	func testTheLargestIconIsTheIPhonesAt3x() {
		XCTAssertEqual(AppIconWriter.files.max { $0.pixels < $1.pixels }?.suffix, "-60x60@3x.png")
		XCTAssertEqual(AppIconWriter.files.map(\.pixels).max(), 180)
	}

	/// So iOS reads an app's new icon afresh rather than show the one it
	/// kept (#155), and the same icon signed again keeps its names.
	func testNamesEachIconByWhatItShows() {
		let icon = AppIconWriter.name(for: Data("one icon".utf8))
		XCTAssertEqual(icon, AppIconWriter.name(for: Data("one icon".utf8)))
		XCTAssertNotEqual(icon, AppIconWriter.name(for: Data("another icon".utf8)))
		XCTAssertTrue(icon.hasPrefix("AtelierIcon-"))
		XCTAssertEqual(icon.count, "AtelierIcon-".count + 8)
		XCTAssertTrue(icon.dropFirst("AtelierIcon-".count).allSatisfy { "0123456789abcdef".contains($0) })
		// FNV-1a's own test values, with the zeros in front kept.
		XCTAssertEqual(AppIconWriter.name(for: Data()), "AtelierIcon-811c9dc5")
		XCTAssertEqual(AppIconWriter.name(for: Data("a".utf8)), "AtelierIcon-e40c292c")
		XCTAssertEqual(AppIconWriter.name(for: Data("foobar".utf8)), "AtelierIcon-bf9cf968")
	}

	/// A copy of Atelier's update keeps its picture from the icon it runs
	/// with (#113), however Atelier named it.
	func testReadsTheIconAtelierWroteIntoACopy() throws {
		let copy = folder.appendingPathComponent("Copy.app", isDirectory: true)
		var info: [String: Any] = ["CFBundleIdentifier": "com.example.test.atelier2"]
		AppIconWriter.setIcon(in: &info, named: "AtelierIcon-1a2b3c4d")
		try Fixture.write([
			"Info.plist": try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
			"AtelierIcon-1a2b3c4d-60x60@2x.png": Data(count: 200),
			"AtelierIcon-1a2b3c4d-60x60@3x.png": Data(count: 300),
			"AppIcon60x60@3x.png": Data(count: 900),
		], under: copy)
		XCTAssertEqual(IconChange.written(inApp: copy)?.count, 300)

		// As Atelier named them before.
		let older = folder.appendingPathComponent("Older.app", isDirectory: true)
		let olderInfo: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AtelierIcon60x60"], "CFBundleIconName": "AtelierIcon"]]]
		try Fixture.write([
			"Info.plist": try PropertyListSerialization.data(fromPropertyList: olderInfo, format: .xml, options: 0),
			"AtelierIcon60x60@2x.png": Data(count: 200),
			"AtelierIcon60x60@3x.png": Data(count: 250),
		], under: older)
		XCTAssertEqual(IconChange.written(inApp: older)?.count, 250)

		// Only the app's own icon: none of Atelier's.
		let app = folder.appendingPathComponent("App.app", isDirectory: true)
		let appInfo: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
		try Fixture.write([
			"Info.plist": try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0),
			"AppIcon60x60@3x.png": Data(count: 300),
		], under: app)
		XCTAssertNil(IconChange.written(inApp: app))
		XCTAssertNil(IconChange.written(inApp: folder.appendingPathComponent("Missing.app", isDirectory: true)))
	}

	func testFindsTheAppsIconAsTheLibraryDoes() throws {
		let app = folder.appendingPathComponent("Test.app", isDirectory: true)
		try Fixture.write([
			"AppIcon60x60@2x.png": Data(count: 200),
			"AppIcon60x60@3x.png": Data(count: 300),
			"Banner.png": Data(count: 900),
			"Assets.car": Data(count: 5000),
		], under: app)
		let info: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
		XCTAssertEqual(AppIconWriter.icon(of: app, info: info)?.count, 300)
		// Without one named, any AppIcon PNG.
		XCTAssertEqual(AppIconWriter.icon(of: app, info: [:])?.count, 300)

		let bare = folder.appendingPathComponent("Bare.app", isDirectory: true)
		try Fixture.write(["Banner.png": Data(count: 900), "Assets.car": Data(count: 5000)], under: bare)
		XCTAssertNil(AppIconWriter.icon(of: bare, info: info))
	}

	// MARK: Signing

	func testNamesTheCopyInEveryLanguage() async throws {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/en.lproj/InfoPlist.strings"] = Data("\"CFBundleDisplayName\" = \"Test\";\n\"NSCameraUsageDescription\" = \"Scans codes\";\n".utf8)
		files["Payload/Test.app/fr.lproj/InfoPlist.strings"] = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Essai"], format: .binary, options: 0)
		files["Payload/Test.app/ja.lproj/InfoPlist.strings"] = try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "テスト"], format: .xml, options: 0)
		files["Payload/Test.app/de.lproj/Localizable.strings"] = Data("\"Hello\" = \"Hallo\";\n".utf8)
		files["Payload/Test.app/PlugIns/Widget.appex/en.lproj/InfoPlist.strings"] = Data("\"CFBundleDisplayName\" = \"Widget\";\n".utf8)
		let ipa = try Fixture.ipa(files, in: folder)

		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), displayName: "Test 2"))

		let english = try plist("Payload/Test.app/en.lproj/InfoPlist.strings", in: signed.url)
		XCTAssertEqual(english.values["CFBundleDisplayName"] as? String, "Test 2")
		XCTAssertEqual(english.values["NSCameraUsageDescription"] as? String, "Scans codes")
		XCTAssertEqual(english.format, .binary, "text is written as Xcode builds it")
		let french = try plist("Payload/Test.app/fr.lproj/InfoPlist.strings", in: signed.url)
		XCTAssertEqual(french.values["CFBundleDisplayName"] as? String, "Test 2")
		XCTAssertEqual(french.values["CFBundleName"] as? String, "Essai")
		XCTAssertEqual(french.format, .binary)
		let japanese = try plist("Payload/Test.app/ja.lproj/InfoPlist.strings", in: signed.url)
		XCTAssertEqual(japanese.values["CFBundleDisplayName"] as? String, "Test 2")
		XCTAssertEqual(japanese.format, .xml)
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/de.lproj/Localizable.strings", in: signed.url), Data("\"Hello\" = \"Hallo\";\n".utf8))
		XCTAssertEqual(
			try Fixture.contents(of: "Payload/Test.app/PlugIns/Widget.appex/en.lproj/InfoPlist.strings", in: signed.url),
			Data("\"CFBundleDisplayName\" = \"Widget\";\n".utf8),
			"only the app's own name"
		)

		// Without a name, the languages keep theirs.
		let unnamed = try await sign(ipa, options: SigningOptions(target: .copy(2)))
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/en.lproj/InfoPlist.strings", in: unnamed.url), files["Payload/Test.app/en.lproj/InfoPlist.strings"])
	}

	func testRemovesURLSchemesButNotTheInstallCheck() async throws {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/Info.plist"] = try Fixture.infoPlist("com.example.test", executable: "Test", extra: [
			"CFBundleURLTypes": [["CFBundleURLName": "com.example.test", "CFBundleURLSchemes": ["example", "fb123"]]],
		])
		let ipa = try Fixture.ipa(files, in: folder)

		let removed = try await sign(ipa, options: SigningOptions(target: .copy(2), installCheckScheme: "atelier-check-4", removesURLSchemes: true))
		XCTAssertEqual(removed.info.urlSchemes, ["atelier-check-4"])
		let none = try await sign(ipa, options: SigningOptions(target: .copy(2), removesURLSchemes: true))
		XCTAssertEqual(none.info.urlSchemes, [])
		XCTAssertNil(try plist("Payload/Test.app/Info.plist", in: none.url).values["CFBundleURLTypes"])

		let kept = try await sign(ipa, options: SigningOptions(target: .copy(2), installCheckScheme: "atelier-check-4"))
		XCTAssertEqual(kept.info.urlSchemes, ["example", "fb123", "atelier-check-4"])
	}

	func testGivesEachAtelierItsOwnWayBackFromLocalDevVPN() async throws {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/Info.plist"] = try Fixture.infoPlist("com.example.test", executable: "Test", extra: [
			"CFBundleURLTypes": [
				["CFBundleURLName": "com.example.test.source", "CFBundleURLSchemes": ["example"]],
				["CFBundleURLName": SwitchBackScheme.urlTypeName, "CFBundleURLSchemes": ["atelier-com.example.test"]],
			],
		])
		let ipa = try Fixture.ipa(files, in: folder)

		let original = try await sign(ipa, options: SigningOptions())
		XCTAssertEqual(original.info.urlSchemes, ["example", "atelier-com.example.test"])
		let copy = try await sign(ipa, options: SigningOptions(target: .copy(2), installCheckScheme: "atelier-check-4"))
		XCTAssertEqual(copy.info.urlSchemes, ["example", "atelier-com.example.test.atelier2", "atelier-check-4"])
		// Under the bundle ID chosen for it, or another tool installed it with.
		let chosen = try await sign(ipa, options: SigningOptions(target: .copy(2), bundleID: "com.example.Tests"))
		XCTAssertEqual(chosen.info.urlSchemes, ["example", "atelier-com.example.tests"])
		// No link is meant for it, so it stays with the copy's URL schemes gone.
		let removed = try await sign(ipa, options: SigningOptions(target: .copy(3), installCheckScheme: "atelier-check-4", removesURLSchemes: true))
		XCTAssertEqual(removed.info.urlSchemes, ["atelier-com.example.test.atelier3", "atelier-check-4"])
	}

	func testLeavesTheIconWithoutAnyChange() async throws {
		let ipa = try Fixture.ipa(try iconApp(), in: folder)
		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange()))
		XCTAssertFalse(signed.iconChanged)
		XCTAssertFalse(try Fixture.entries(of: signed.url).keys.contains { $0.contains("AtelierIcon") })
	}

	/// An app whose icon is a loose PNG named in its Info.plist, as Xcode
	/// builds them: white on its left half, black on its right.
	private func iconApp() throws -> [String: Data] {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/Info.plist"] = try Fixture.infoPlist("com.example.test", executable: "Test", extra: [
			"CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon"]],
		])
		files["Payload/Test.app/AppIcon60x60@2x.png"] = Self.picture(width: 120, height: 120, colors: [(255, 255, 255), (0, 0, 0)]) ?? Data([0x89])
		return files
	}

	#if canImport(CoreGraphics) && canImport(ImageIO)
	func testTintsTheAppsIcon() async throws {
		let ipa = try Fixture.ipa(try iconApp(), in: folder)

		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(tint: .blue)))

		XCTAssertTrue(signed.iconChanged)
		let info = try plist("Payload/Test.app/Info.plist", in: signed.url).values
		let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
		let name = try iconName(in: signed.url)
		XCTAssertTrue(name.hasPrefix("AtelierIcon-"), name)
		XCTAssertEqual(primary?["CFBundleIconFiles"] as? [String], ["\(name)-60x60"])
		for (suffix, pixels) in AppIconWriter.files {
			let png = try Fixture.contents(of: "Payload/Test.app/\(name)\(suffix)", in: signed.url)
			XCTAssertEqual(try Self.size(of: png), pixels, suffix)
		}
		let icon = try Fixture.contents(of: "Payload/Test.app/\(name)-60x60@3x.png", in: signed.url)
		XCTAssertEqual(name, AppIconWriter.name(for: icon), "named by what it shows")
		// White becomes the pale shade, black the deep one.
		assertColor(try Self.color(in: icon, x: 20, y: 90), near: (219, 236, 255))
		assertColor(try Self.color(in: icon, x: 160, y: 90), near: (0, 39, 82))
		// The Library reads the new icon (#118).
		XCTAssertEqual(IPAIcon.read(ipaAt: signed.url), icon)
		// The original stays, as the asset catalog does.
		XCTAssertNotNil(try Fixture.entries(of: signed.url)["Payload/Test.app/AppIcon60x60@2x.png"])
	}

	func testPutsAPictureInTheIconsPlace() async throws {
		// Red, green and blue thirds: the square from its middle is mostly green.
		let picture = try XCTUnwrap(Self.picture(width: 300, height: 200, colors: [(255, 0, 0), (0, 255, 0), (0, 0, 255)]))
		let ipa = try Fixture.ipa(try iconApp(), in: folder)

		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(picture: picture)))

		XCTAssertTrue(signed.iconChanged)
		let icon = try largestIcon(in: signed.url)
		XCTAssertEqual(try Self.size(of: icon), 180)
		assertColor(try Self.color(in: icon, x: 10, y: 90), near: (255, 0, 0))
		assertColor(try Self.color(in: icon, x: 90, y: 90), near: (0, 255, 0))
		assertColor(try Self.color(in: icon, x: 170, y: 90), near: (0, 0, 255))

		// Tinted too, a picture is in the tint's shades.
		let tinted = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(picture: picture, tint: .green)))
		let green = AppIconTint.green.shades[AppIconTint.lightness(red: 0, green: 255, blue: 0)]
		assertColor(try Self.color(in: largestIcon(in: tinted.url), x: 90, y: 90), near: (green.red, green.green, green.blue))
	}

	/// Custom Install… installing a new tint over an app gives its icon new
	/// names (#155).
	func testGivesANewIconNewNames() async throws {
		let ipa = try Fixture.ipa(try iconApp(), in: folder)
		let blue = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(tint: .blue)))
		let green = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(tint: .green)))
		XCTAssertNotEqual(try iconName(in: blue.url), try iconName(in: green.url))
	}

	/// An app with an icon Atelier wrote before, such as one Atelier signed
	/// as a copy, has only the new one's PNGs afterwards.
	func testReplacesAnIconAtelierWroteBefore() async throws {
		var files = try iconApp()
		files["Payload/Test.app/AtelierIcon60x60@3x.png"] = Data(count: 10)
		files["Payload/Test.app/AtelierIcon-0badc0de-60x60@2x.png"] = Data(count: 10)
		let ipa = try Fixture.ipa(files, in: folder)

		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(tint: .blue)))

		let name = try iconName(in: signed.url)
		let written = try Fixture.entries(of: signed.url).keys.filter { $0.contains("AtelierIcon") }
		XCTAssertEqual(Set(written), Set(AppIconWriter.files.map { "Payload/Test.app/\(name)\($0.suffix)" }))
	}

	/// The icon name the signed app's Info.plist gives.
	private func iconName(in ipa: URL) throws -> String {
		let info = try plist("Payload/Test.app/Info.plist", in: ipa).values
		let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
		return try XCTUnwrap(primary?["CFBundleIconName"] as? String)
	}

	/// The iPhone's icon at 3x, as Atelier wrote it into the signed app.
	private func largestIcon(in ipa: URL) throws -> Data {
		try Fixture.contents(of: "Payload/Test.app/\(try iconName(in: ipa))-60x60@3x.png", in: ipa)
	}

	func testDrawsThePreviewAsTheHomeScreenWillShowIt() throws {
		let icon = try XCTUnwrap(Self.picture(width: 120, height: 120, colors: [(255, 255, 255), (0, 0, 0)]))
		let preview = try XCTUnwrap(IconChange(tint: .blue).png(from: icon, pixels: 180))
		XCTAssertEqual(try Self.size(of: preview), 180)
		assertColor(try Self.color(in: preview, x: 20, y: 90), near: (219, 236, 255))
		XCTAssertNil(IconChange(tint: .blue).png(from: nil, pixels: 180))
		XCTAssertNil(IconChange(tint: .blue).png(from: Data("not a picture".utf8), pixels: 180))
	}

	private func assertColor(_ color: (UInt8, UInt8, UInt8), near wanted: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
		let close = [(color.0, wanted.0), (color.1, wanted.1), (color.2, wanted.2)].allSatisfy { abs(Int($0) - Int($1)) <= 3 }
		XCTAssertTrue(close, "\(color) isn't \(wanted)", file: file, line: line)
	}

	/// A PNG in vertical stripes of `colors`, left to right.
	static func picture(width: Int, height: Int, colors: [(UInt8, UInt8, UInt8)]) -> Data? {
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
		      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		let stripe = CGFloat(width) / CGFloat(colors.count)
		for (index, color) in colors.enumerated() {
			context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1)
			context.fill(CGRect(x: CGFloat(index) * stripe, y: 0, width: stripe, height: CGFloat(height)))
		}
		guard let image = context.makeImage() else { return nil }
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}

	private static func image(_ png: Data) throws -> CGImage {
		let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
		return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
	}

	/// The side of a square PNG, in pixels.
	private static func size(of png: Data) throws -> Int {
		let image = try image(png)
		XCTAssertEqual(image.width, image.height)
		return image.width
	}

	/// The colour at `x`, `y` from the top left.
	private static func color(in png: Data, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
		let image = try image(png)
		var bytes = [UInt8](repeating: 0, count: 4)
		let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
		let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
			context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
			return true
		}
		XCTAssertTrue(drawn)
		return (bytes[0], bytes[1], bytes[2])
	}
	#else
	static func picture(width: Int, height: Int, colors: [(UInt8, UInt8, UInt8)]) -> Data? {
		nil
	}

	func testDrawsNoIconWithoutCoreGraphics() async throws {
		let ipa = try Fixture.ipa(try iconApp(), in: folder)
		let signed = try await sign(ipa, options: SigningOptions(target: .copy(2), icon: IconChange(tint: .blue)))
		XCTAssertFalse(signed.iconChanged)
		let info = try plist("Payload/Test.app/Info.plist", in: signed.url).values
		let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
		XCTAssertEqual(primary?["CFBundleIconName"] as? String, "AppIcon")
	}
	#endif
}
