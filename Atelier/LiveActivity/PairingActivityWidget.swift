import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AtelierLiveActivityBundle: WidgetBundle {
	var body: some Widget {
		PairingActivityWidget()
		SetupActivityWidget()
	}
}

/// Route A's pairing steps and code (#54): every step on the Lock Screen, the
/// step and code in the Dynamic Island, and the current step in full on a long
/// press.
struct PairingActivityWidget: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: PairingActivityAttributes.self) { context in
			PairingCard(state: context.state, deviceName: context.attributes.deviceName)
				.activityBackgroundTint(Color.black.opacity(0.75))
				.activitySystemActionForegroundColor(.white)
		} dynamicIsland: { context in
			let state = context.state
			let total = PairingActivityAttributes.ContentState.steps.count
			return DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					Title(state: state, deviceName: context.attributes.deviceName)
						.lineLimit(1)
						.padding(.leading, 6)
						.padding(.top, 4)
						// "iPhone paired" wrapped onto two lines beside the camera.
						.dynamicIsland(verticalPlacement: .belowIfTooWide)
				}
				DynamicIslandExpandedRegion(.trailing) {
					if state.phase == .openSettings || state.phase == .enterCode {
						Text("Step \(state.step) of \(total)")
							.font(.footnote)
							.foregroundStyle(.secondary)
							.padding(.trailing, 6)
							.padding(.top, 4)
					}
				}
				DynamicIslandExpandedRegion(.bottom) {
					VStack(spacing: 6) {
						if state.phase == .openSettings {
							VStack(alignment: .leading, spacing: 2) {
								Text(PairingActivityAttributes.ContentState.settingsPath)
									.font(.headline)
								Text(PairingActivityAttributes.ContentState.settingsTap)
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
							.frame(maxWidth: .infinity, alignment: .leading)
						} else {
							Text(state.currentStepText)
								.font(.subheadline)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
						if let code = state.code, state.phase == .enterCode {
							CodeText(code: code)
						}
						ProgressView(value: Double(state.step), total: Double(total))
							.tint(.pink)
					}
					// Off the rounded edges, which cropped the text and the bar.
					.padding(.horizontal, 8)
					.padding(.bottom, 8)
				}
			} compactLeading: {
				Image(systemName: state.phase == .paired ? "checkmark.circle.fill" : "link")
					.foregroundStyle(state.phase == .paired ? Color.green : Color.pink)
			} compactTrailing: {
				switch state.phase {
				case .enterCode:
					Text(state.code ?? "")
						.font(.system(.body, design: .monospaced).weight(.bold))
				case .paired:
					Text("Paired")
				case .starting, .openSettings:
					Text("\(max(state.step, 1))/\(total)")
						.foregroundStyle(.pink)
				}
			} minimal: {
				Image(systemName: state.phase == .paired ? "checkmark.circle.fill" : "link")
					.foregroundStyle(state.phase == .paired ? Color.green : Color.pink)
			}
		}
	}
}

/// Every step, with the code under its step: the Lock Screen.
private struct PairingCard: View {
	let state: PairingActivityAttributes.ContentState
	let deviceName: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Title(state: state, deviceName: deviceName)
				Spacer()
				if state.phase != .paired {
					Text(timerInterval: Date()...max(Date(), state.endDate), countsDown: true)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.trailing)
						.frame(width: 60)
				}
			}
			ForEach(Array(PairingActivityAttributes.ContentState.steps.enumerated()), id: \.offset) { index, title in
				let number = index + 1
				let current = number == state.step && state.phase != .paired
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Image(systemName: number < state.step || state.phase == .paired ? "checkmark.circle.fill" : "\(number).circle")
					Text(title)
				}
				.font(.footnote.weight(current ? .semibold : .regular))
				.foregroundStyle(current ? Color.primary : Color.secondary)
				if number == 2, let code = state.code, state.phase == .enterCode {
					CodeText(code: code)
				}
			}
		}
		.padding(16)
		.environment(\.colorScheme, .dark)
	}
}

private struct Title: View {
	let state: PairingActivityAttributes.ContentState
	let deviceName: String

	var body: some View {
		Label(text, systemImage: state.phase == .paired ? "checkmark.circle.fill" : "link")
			.font(.footnote.weight(.semibold))
			.foregroundStyle(state.phase == .paired ? Color.green : Color.pink)
	}

	private var text: String {
		switch state.phase {
		case .starting: "Getting ready"
		case .openSettings, .enterCode: "Pairing this \(deviceName)"
		case .paired: "\(deviceName) paired"
		}
	}
}

private struct CodeText: View {
	let code: String

	var body: some View {
		Text(code)
			.font(.system(size: 34, weight: .bold, design: .monospaced))
			.frame(maxWidth: .infinity)
	}
}

private extension PairingActivityAttributes.ContentState {
	var currentStepText: String {
		switch phase {
		case .starting: "Getting the pairing service ready…"
		case .openSettings, .enterCode: Self.steps[step - 1]
		case .paired: "Tap to return to Atelier"
		}
	}
}
