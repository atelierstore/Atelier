import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
	/// The Library's status colours, for its small coloured lines, such as
	/// "36 days left", "Reinstall required" and "Didn't re-sign", and the
	/// BETA tag. In light mode they're darker than the system's green,
	/// orange and red, which reach only 2.2:1, 2.2:1 and 3.6:1 on white,
	/// under the 4.5:1 text this small needs: these are about 5.3:1, iOS's
	/// own Increase Contrast shades for orange and red, and a touch darker
	/// than its green. Dark mode keeps the system's, already 5:1 to 8:1 on
	/// its rows (21 Nov 2026).
	static var statusGreen: Color { StatusColors.green }
	static var statusOrange: Color { StatusColors.orange }
	static var statusRed: Color { StatusColors.red }
}

private enum StatusColors {
	static let green = color(light: 0x1E7B34, dark: .systemGreen)
	static let orange = color(light: 0xC93400, dark: .systemOrange)
	static let red = color(light: 0xD70015, dark: .systemRed)

	/// `light`'s six hex digits in light mode, `dark` in dark mode, with
	/// Increase Contrast's shade when that's on.
	private static func color(light hex: Int, dark: UIColor) -> Color {
		let light = UIColor(
			red: CGFloat((hex >> 16) & 0xFF) / 255,
			green: CGFloat((hex >> 8) & 0xFF) / 255,
			blue: CGFloat(hex & 0xFF) / 255,
			alpha: 1
		)
		return Color(uiColor: UIColor { traits in
			traits.userInterfaceStyle == .dark ? dark.resolvedColor(with: traits) : light
		})
	}
}
