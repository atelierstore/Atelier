import SwiftUI

/// An Apple ID's page › Apple ID Log (#49): what each sign-in, install and
/// renewal with an Apple ID did, the newest last, with Share. It was on the
/// Free Apple ID Test screen, which Test Actions no longer has (10 Nov
/// 2026). It holds no Apple ID, password or code (`AppleIDLog`).
struct AppleIDLogView: View {
	@State private var lines: [String] = []

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 2) {
				ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
					// Each launch's lines follow one with the date and build.
					Text(line)
						.font(.caption.monospaced())
						.fontWeight(line.hasPrefix("---") ? .semibold : .regular)
						.foregroundStyle(line.hasPrefix("---") ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
						.padding(.top, line.hasPrefix("---") ? 10 : 0)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
			.textSelection(.enabled)
			.padding()
		}
		// The newest lines first in view.
		.defaultScrollAnchor(.bottom)
		.overlay {
			if lines.isEmpty {
				ContentUnavailableView(
					"Nothing yet",
					systemImage: "text.alignleft",
					description: Text("Each sign-in, install and renewal with an Apple ID says here what Apple and iOS did, without the password or Apple’s codes.")
				)
			}
		}
		.navigationTitle("Apple ID Log")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ShareLink(item: lines.joined(separator: "\n")) {
				Label("Share", systemImage: "square.and.arrow.up")
			}
			.disabled(lines.isEmpty)
		}
		.onAppear { lines = AppleIDLog.kept() }
	}
}
