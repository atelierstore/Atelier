import SwiftUI

extension View {
	/// Takes taps up to `length` points around the view as well, without
	/// changing its layout or look: for controls drawn smaller than the
	/// 44 points a finger needs, such as the install rings (19 Nov 2026).
	func tapArea(_ length: CGFloat) -> some View {
		tapArea(EdgeInsets(top: length, leading: length, bottom: length, trailing: length))
	}

	/// Takes taps up to `insets` around the view as well, without changing
	/// its layout or look.
	func tapArea(_ insets: EdgeInsets) -> some View {
		padding(insets)
			.contentShape(Rectangle())
			.padding(EdgeInsets(top: -insets.top, leading: -insets.leading, bottom: -insets.bottom, trailing: -insets.trailing))
	}
}
