import Foundation
import InstallKit
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A colour for a copy's icon (#113), so the copy can be told from its app
/// on the Home Screen: the icon in shades of it, keeping its light and
/// shade. iOS's system colours of the same names.
public enum AppIconTint: String, CaseIterable, Codable, Sendable {
	case red, orange, yellow, green, teal, blue, purple, pink

	/// An sRGB colour, 0 to 255 a channel.
	public struct RGB: Equatable, Hashable, Sendable {
		public var red: UInt8
		public var green: UInt8
		public var blue: UInt8

		public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
			self.red = red
			self.green = green
			self.blue = blue
		}
	}

	public var color: RGB {
		switch self {
		case .red: RGB(255, 59, 48)
		case .orange: RGB(255, 149, 0)
		case .yellow: RGB(255, 204, 0)
		case .green: RGB(52, 199, 89)
		case .teal: RGB(48, 176, 199)
		case .blue: RGB(0, 122, 255)
		case .purple: RGB(175, 82, 222)
		case .pink: RGB(255, 45, 85)
		}
	}

	/// What each lightness of the icon becomes, from black (0) to white
	/// (255): a deep shade of the colour, then the colour itself at its own
	/// lightness, then a pale shade. So the icon keeps its shapes, an icon
	/// in black and white changes too, and one that has the colour already
	/// still looks different.
	public var shades: [RGB] {
		let tint = color
		let own = Self.hls(tint)
		let pivot = min(max(own.lightness, 0.05), 0.95)
		let dark = Self.rgb(hue: own.hue, lightness: 0.16, saturation: own.saturation)
		let light = Self.rgb(hue: own.hue, lightness: 0.93, saturation: own.saturation)
		let middle = [Double(tint.red) / 255, Double(tint.green) / 255, Double(tint.blue) / 255]
		return (0...255).map { level in
			let y = Double(level) / 255
			let (from, to, share) = y < pivot ? (dark, middle, y / pivot) : (middle, light, (y - pivot) / (1 - pivot))
			let mixed = zip(from, to).map { Self.byte($0 + ($1 - $0) * share) }
			return RGB(mixed[0], mixed[1], mixed[2])
		}
	}

	/// A pixel's lightness, 0 to 255, as `shades` is indexed: with Rec.
	/// 601's weights, which the tints were made with.
	public static func lightness(red: UInt8, green: UInt8, blue: UInt8) -> Int {
		(30 * Int(red) + 59 * Int(green) + 11 * Int(blue) + 50) / 100
	}

	private static func byte(_ value: Double) -> UInt8 {
		UInt8((min(max(value, 0), 1) * 255).rounded())
	}

	/// Hue, lightness and saturation, 0 to 1 each, as Python's colorsys
	/// works them out.
	static func hls(_ color: RGB) -> (hue: Double, lightness: Double, saturation: Double) {
		let red = Double(color.red) / 255, green = Double(color.green) / 255, blue = Double(color.blue) / 255
		let high = max(red, green, blue), low = min(red, green, blue)
		let lightness = (high + low) / 2
		guard high != low else { return (0, lightness, 0) }
		let range = high - low
		let saturation = lightness <= 0.5 ? range / (high + low) : range / (2 - high - low)
		let redShare = (high - red) / range, greenShare = (high - green) / range, blueShare = (high - blue) / range
		let sixths = if red == high {
			blueShare - greenShare
		} else if green == high {
			2 + redShare - blueShare
		} else {
			4 + greenShare - redShare
		}
		let hue = sixths / 6
		return (hue - hue.rounded(.down), lightness, saturation)
	}

	/// Red, green and blue, 0 to 1 each, as colorsys works them out.
	static func rgb(hue: Double, lightness: Double, saturation: Double) -> [Double] {
		guard saturation != 0 else { return [lightness, lightness, lightness] }
		let high = lightness <= 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
		let low = 2 * lightness - high
		func channel(_ hue: Double) -> Double {
			let hue = hue - hue.rounded(.down)
			if hue < 1.0 / 6 { return low + (high - low) * hue * 6 }
			if hue < 0.5 { return high }
			if hue < 2.0 / 3 { return low + (high - low) * (2.0 / 3 - hue) * 6 }
			return low
		}
		return [channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3)]
	}
}

/// A copy's own icon (#113): a picture of the user's in place of the app's
/// icon, the icon in a tint, or both.
public struct IconChange: Equatable, Sendable {
	/// PNG, JPEG or HEIC. One that isn't square is cropped to its middle.
	public var picture: Data?
	public var tint: AppIconTint?

	public init(picture: Data? = nil, tint: AppIconTint? = nil) {
		self.picture = picture
		self.tint = tint
	}

	/// Whether it leaves the app's icon as it is.
	public var isEmpty: Bool {
		picture == nil && tint == nil
	}

	/// The icon Atelier wrote into the app at `app`, a copy as installed:
	/// the largest of the PNGs its Info.plist names, which has the copy's
	/// picture and tint in it already. Nil when the app has none of
	/// Atelier's.
	public static func written(inApp app: URL) -> Data? {
		guard let info = AppIconWriter.info(of: app),
		      let file = AppIconWriter.iconFile(of: app, info: info),
		      file.hasPrefix(AppIconWriter.prefix)
		else { return nil }
		return try? Data(contentsOf: app.appendingPathComponent(file))
	}

	/// The icon it makes of `icon`, the app's own, at `pixels` a side, as
	/// PNG: what the Home Screen will show, for Custom Install's sheet. Nil
	/// when there's nothing to draw, or it can't be drawn.
	public func png(from icon: Data?, pixels: Int) -> Data? {
		guard let base = picture ?? icon, let image = AppIconWriter.image(from: base) else { return nil }
		return AppIconWriter.png(image, tint: tint, pixels: pixels)
	}
}

/// Writes a copy's icon into its app before it's signed (#113), as Feather
/// does for custom icons: PNGs next to its Info.plist, which then names
/// them as its icon in place of its asset catalog's. The name it gives is
/// in no asset catalog, so iOS draws the PNGs.
///
/// Each icon has its own name, from what it shows, as "AtelierIcon-1a2b3c4d":
/// iOS sometimes goes on showing an app's old icon once a new one is
/// installed over it under the same names, until the iPhone restarts
/// (Apple Developer Forums 842674), so an app's new tint or picture, which
/// Custom Install… installs over it (#155), comes with new names for iOS
/// to read afresh.
enum AppIconWriter {
	/// What every name it gives starts with.
	static let prefix = "AtelierIcon"

	/// The PNGs it writes, by the end of their names and side in pixels:
	/// the iPhone's at 2x and 3x, and the iPad's.
	static let files: [(suffix: String, pixels: Int)] = [
		("-60x60@2x.png", 120),
		("-60x60@3x.png", 180),
		("-76x76@2x~ipad.png", 152),
		("-83.5x83.5@2x~ipad.png", 167),
	]

	/// The name of the icon whose largest PNG is `png`: the prefix, then
	/// the PNG's FNV-1a hash, so another icon has another name.
	static func name(for png: Data) -> String {
		var hash: UInt32 = 0x811C_9DC5
		for byte in png {
			hash ^= UInt32(byte)
			hash = hash &* 0x0100_0193
		}
		let hex = String(hash, radix: 16)
		return "\(prefix)-\(String(repeating: "0", count: 8 - hex.count))\(hex)"
	}

	/// Writes `change` into `app`'s icon, in place of any Atelier wrote
	/// before. False, with nothing changed, when there's nothing to draw:
	/// no picture, and no icon PNG in the app to tint, or no way to draw on
	/// this platform.
	@discardableResult
	static func write(_ change: IconChange, into app: URL) throws -> Bool {
		guard !change.isEmpty else { return false }
		let plist = app.appendingPathComponent("Info.plist")
		var format = PropertyListSerialization.PropertyListFormat.xml
		guard var info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any] else {
			throw SigningError.corruptArchive("its Info.plist can't be read")
		}
		guard let base = change.picture ?? icon(of: app, info: info), let image = image(from: base) else { return false }
		var pngs: [(suffix: String, pixels: Int, data: Data)] = []
		for file in files {
			guard let data = png(image, tint: change.tint, pixels: file.pixels) else { return false }
			pngs.append((file.suffix, file.pixels, data))
		}
		guard let largest = pngs.max(by: { $0.pixels < $1.pixels }) else { return false }
		let iconName = Self.name(for: largest.data)
		for old in pngFiles(of: app) where old.path.hasPrefix(prefix) {
			try? FileManager.default.removeItem(at: app.appendingPathComponent(old.path))
		}
		for png in pngs {
			try png.data.write(to: app.appendingPathComponent(iconName + png.suffix))
		}
		setIcon(in: &info, named: iconName)
		try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: plist)
		return true
	}

	/// The app's Info.plist; nil when it can't be read.
	static func info(of app: URL) -> [String: Any]? {
		let plist = app.appendingPathComponent("Info.plist")
		return (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil)) as? [String: Any]
	}

	/// The app's icon as it is, as the Library reads it from an IPA
	/// (`IPAIcon`): the largest PNG next to its Info.plist that the
	/// Info.plist names as its icon.
	static func icon(of app: URL, info: [String: Any]) -> Data? {
		iconFile(of: app, info: info).flatMap { try? Data(contentsOf: app.appendingPathComponent($0)) }
	}

	/// That PNG's name.
	static func iconFile(of app: URL, info: [String: Any]) -> String? {
		IPAIcon.file(plist: info, appFolder: "", files: pngFiles(of: app))
	}

	/// The PNGs next to the app's Info.plist, by name, with their sizes.
	private static func pngFiles(of app: URL) -> [(path: String, size: Int64)] {
		let manager = FileManager.default
		return ((try? manager.contentsOfDirectory(atPath: app.path)) ?? []).compactMap { name -> (path: String, size: Int64)? in
			guard name.lowercased().hasSuffix(".png") else { return nil }
			let attributes = try? manager.attributesOfItem(atPath: app.appendingPathComponent(name).path)
			guard attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
			return (name, (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
		}
	}

	/// Names the PNGs of the icon `name` as the app's icon, for iPhone and
	/// iPad, keeping the rest of its icon keys, such as alternate icons.
	/// iOS 3's keys go, as the Library's icon reader would also go by them.
	static func setIcon(in info: inout [String: Any], named name: String) {
		let names = [
			("CFBundleIcons", ["\(name)-60x60"]),
			("CFBundleIcons~ipad", ["\(name)-60x60", "\(name)-76x76", "\(name)-83.5x83.5"]),
		]
		for (key, files) in names {
			var icons = info[key] as? [String: Any] ?? [:]
			var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
			primary["CFBundleIconFiles"] = files
			primary["CFBundleIconName"] = name
			icons["CFBundlePrimaryIcon"] = primary
			info[key] = icons
		}
		info.removeValue(forKey: "CFBundleIconFiles")
		info.removeValue(forKey: "CFBundleIconFile")
	}

	#if canImport(CoreGraphics) && canImport(ImageIO)
	/// A picture or icon, the right way up, at most 2048 pixels a side,
	/// which is plenty for an icon's 180.
	static func image(from data: Data) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: 2048,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
			?? CGImageSourceCreateImageAtIndex(source, 0, nil)
	}

	/// `image` at `pixels` a side, as PNG: cropped to a square from its
	/// middle, scaled, then in `tint`'s shades when there's one.
	static func png(_ image: CGImage, tint: AppIconTint?, pixels: Int) -> Data? {
		guard pixels > 0, image.width > 0, image.height > 0,
		      let space = CGColorSpace(name: CGColorSpace.sRGB),
		      let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		context.interpolationQuality = .high
		let side = CGFloat(pixels)
		let scale = side / CGFloat(min(image.width, image.height))
		let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
		context.draw(image, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
		if let tint, let data = context.data {
			let shades = tint.shades
			let rowBytes = context.bytesPerRow
			let bytes = data.bindMemory(to: UInt8.self, capacity: rowBytes * pixels)
			for row in 0..<pixels {
				for column in 0..<pixels {
					let pixel = bytes + row * rowBytes + column * 4
					let alpha = Int(pixel[3])
					guard alpha > 0 else { continue }
					// The colour without its alpha, which the context
					// multiplied in, then multiplied in again.
					func plain(_ value: UInt8) -> UInt8 { UInt8(min(255, (Int(value) * 255 + alpha / 2) / alpha)) }
					let shade = shades[AppIconTint.lightness(red: plain(pixel[0]), green: plain(pixel[1]), blue: plain(pixel[2]))]
					pixel[0] = UInt8((Int(shade.red) * alpha + 127) / 255)
					pixel[1] = UInt8((Int(shade.green) * alpha + 127) / 255)
					pixel[2] = UInt8((Int(shade.blue) * alpha + 127) / 255)
				}
			}
		}
		guard let drawn = context.makeImage() else { return nil }
		let output = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
		CGImageDestinationAddImage(destination, drawn, nil)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return output as Data
	}
	#else
	/// Icons are only drawn on Apple platforms.
	struct Image {}

	static func image(from data: Data) -> Image? {
		nil
	}

	static func png(_ image: Image, tint: AppIconTint?, pixels: Int) -> Data? {
		nil
	}
	#endif
}
