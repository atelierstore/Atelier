import Foundation
@testable import InstallKit
import XCTest

final class IPAIconTests: XCTestCase {
	/// A stored (uncompressed) ZIP, enough to stand in for an IPA.
	private func makeZip(_ files: [(String, Data)]) -> Data {
		var out = Data()
		var central = Data()
		func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
		func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
		func append(_ target: inout Data, _ parts: [Data]) { for part in parts { target.append(part) } }
		for (path, data) in files {
			let offset = out.count
			let name = Data(path.utf8)
			append(&out, [le32(0x0403_4B50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
			append(&out, [le32(data.count), le32(data.count), le16(name.count), le16(0), name, data])
			append(&central, [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
			append(&central, [le32(data.count), le32(data.count), le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name])
		}
		let tableOffset = out.count
		out.append(central)
		append(&out, [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(tableOffset), le16(0)])
		return out
	}

	private func plist(_ values: [String: Any]) -> Data {
		var all = values
		all["CFBundleIdentifier"] = "com.ispazio.Wallpapers-Central"
		return try! PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
	}

	private func png(_ name: String, size: Int) -> Data {
		Data((name + String(repeating: ".", count: size)).utf8)
	}

	/// Laid out as Wallpapers 2.8's IPA from AppTesters (#116): an Icon
	/// Composer icon with loose PNGs for iPhone and iPad, and alternate
	/// icons, which iOS doesn't show until the app picks one.
	func testReadsTheLargestPrimaryIcon() throws {
		let app = "Payload/WallpapersCentral.app/"
		let ipa = makeZip([
			(app + "Info.plist", plist([
				"CFBundleIcons": [
					"CFBundlePrimaryIcon": ["CFBundleIconFiles": ["Wallpapers_Central_IconComposer60x60"], "CFBundleIconName": "Wallpapers_Central_IconComposer"],
					"CFBundleAlternateIcons": ["AppIcon-1": ["CFBundleIconFiles": ["andy-room", "andy-room-ipad"]]],
				],
				"CFBundleIcons~ipad": [
					"CFBundlePrimaryIcon": ["CFBundleIconFiles": ["Wallpapers_Central_IconComposer60x60", "Wallpapers_Central_IconComposer76x76"]],
				],
			])),
			(app + "andy-room@3x.png", png("alternate", size: 900)),
			(app + "Wallpapers_Central_IconComposer60x60@2x.png", png("iphone", size: 300)),
			(app + "Wallpapers_Central_IconComposer76x76@2x~ipad.png", png("ipad", size: 400)),
			(app + "Assets.car", Data(count: 2000)),
			(app + "Frameworks/Kit.framework/AppIcon60x60@3x.png", png("framework", size: 1000)),
		])
		XCTAssertEqual(try IPAIcon.read(ipaData: ipa), png("ipad", size: 400))
	}

	func testFallsBackToAnAppIconFile() throws {
		let app = "Payload/Old.app/"
		let ipa = makeZip([
			(app + "Info.plist", plist([:])),
			(app + "LaunchImage.png", png("launch", size: 500)),
			(app + "AppIcon60x60@2x.png", png("icon", size: 100)),
		])
		XCTAssertEqual(try IPAIcon.read(ipaData: ipa), png("icon", size: 100))
	}

	func testNamedTopLevelIconFiles() throws {
		let app = "Payload/Old.app/"
		let ipa = makeZip([
			(app + "Info.plist", plist(["CFBundleIconFiles": ["Icon.png", "Icon@2x.png"]])),
			(app + "Icon.png", png("small", size: 50)),
			(app + "Icon@2x.png", png("large", size: 150)),
			(app + "AppIcon-Unused.png", png("unused", size: 600)),
		])
		XCTAssertEqual(try IPAIcon.read(ipaData: ipa), png("large", size: 150))
	}

	func testNoIcon() throws {
		let app = "Payload/Plain.app/"
		let ipa = makeZip([
			(app + "Info.plist", plist([:])),
			(app + "Background.png", png("background", size: 100)),
		])
		XCTAssertNil(try IPAIcon.read(ipaData: ipa))
		XCTAssertNil(IPAIcon.read(ipaAt: URL(fileURLWithPath: "/nonexistent/App.ipa")))
	}
}
