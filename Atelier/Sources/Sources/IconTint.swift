import CoreGraphics
import UIKit

/// A GitHub source's colour from its app's icon (#30), since releases don't
/// name one: the icon at 16×16, without its near-white, near-black and grey
/// pixels, averaged with the more vivid ones counting more, then darkened
/// until white text reads on it.
enum IconTint {
	/// Six hex digits, or nil when the icon is all greys.
	@Sendable static func hex(of png: Data) -> String? {
		// UIImage reads the iPhone PNG variant apps ship their icons in.
		guard let image = UIImage(data: png)?.cgImage else { return nil }
		let side = 16
		var pixels = [UInt8](repeating: 0, count: side * side * 4)
		let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
			guard let context = CGContext(
				data: buffer.baseAddress,
				width: side,
				height: side,
				bitsPerComponent: 8,
				bytesPerRow: side * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.interpolationQuality = .medium
			context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
			return true
		}
		guard drawn else { return nil }

		var total = 0.0, red = 0.0, green = 0.0, blue = 0.0
		for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
			let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
			let high = max(r, g, b), low = min(r, g, b)
			let saturation = high == 0 ? 0 : (high - low) / high
			guard high > 0.15, saturation > 0.15 else { continue }
			let weight = saturation * saturation
			total += weight
			red += r * weight
			green += g * weight
			blue += b * weight
		}
		guard total > 0 else { return nil }
		red /= total
		green /= total
		blue /= total

		// SourceTint switches to black text above 0.7; keep well below, so
		// cards stay white on colour like other sources.
		let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
		let most = 0.45
		if luminance > most {
			let scale = most / luminance
			red *= scale
			green *= scale
			blue *= scale
		}
		return String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
	}
}
