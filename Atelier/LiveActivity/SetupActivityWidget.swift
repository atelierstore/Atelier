import ActivityKit
import SwiftUI
import WidgetKit

/// Route A's Enable Local VPN and Check steps (#54), drawn like the pairing
/// card: the step on the Lock Screen and, on a long press, in the Dynamic
/// Island.
struct SetupActivityWidget: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: SetupActivityAttributes.self) { context in
			SetupCard(state: context.state)
				.padding(16)
				.environment(\.colorScheme, .dark)
				.activityBackgroundTint(Color.black.opacity(0.75))
				.activitySystemActionForegroundColor(.white)
		} dynamicIsland: { context in
			let state = context.state
			return DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					SetupTitle(state: state)
						.lineLimit(1)
						.padding(.leading, 6)
						.padding(.top, 4)
						.dynamicIsland(verticalPlacement: .belowIfTooWide)
				}
				DynamicIslandExpandedRegion(.trailing) {
					Text(state.status)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.padding(.trailing, 6)
						.padding(.top, 4)
				}
				DynamicIslandExpandedRegion(.bottom) {
					SetupLines(state: state)
						.padding(.horizontal, 8)
						.padding(.bottom, 8)
				}
			} compactLeading: {
				Image(systemName: state.symbol)
					.foregroundStyle(state.color)
			} compactTrailing: {
				Text(state.compact)
					.foregroundStyle(state.color)
			} minimal: {
				Image(systemName: state.symbol)
					.foregroundStyle(state.color)
			}
		}
	}
}

private struct SetupCard: View {
	let state: SetupActivityAttributes.ContentState

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				SetupTitle(state: state)
				Spacer()
				Text(state.status)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			SetupLines(state: state)
		}
	}
}

private struct SetupTitle: View {
	let state: SetupActivityAttributes.ContentState

	var body: some View {
		Label(state.title, systemImage: state.symbol)
			.font(.footnote.weight(.semibold))
			.foregroundStyle(state.color)
	}
}

private struct SetupLines: View {
	let state: SetupActivityAttributes.ContentState

	var body: some View {
		VStack(spacing: 6) {
			VStack(alignment: .leading, spacing: 2) {
				Text(state.headline)
					.font(.headline)
				Text(state.detail)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			ProgressView(value: state.progress)
				.tint(state.color)
		}
	}
}

private extension SetupActivityAttributes.ContentState {
	var color: Color {
		switch tint {
		case .blue: .blue
		case .orange: .orange
		}
	}
}
