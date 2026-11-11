import InstallKit
import SwiftUI
import UIKit

/// Atelier leaving for the Home Screen as a swipe up from the bottom edge
/// does, for iOS to install Atelier over itself (#123): iOS installs over
/// an app only once it's no longer in front, and has no public way for an
/// app to leave. UIApplication's private `suspend` does, which apps outside
/// the App Store have long used. Atelier sends it only while UIApplication
/// answers to it, as `SystemInstallSignals` checks what it reads (#72); if
/// Atelier is still in front a moment later, it did nothing on this iOS,
/// so the sheet's button goes and only the swipe is left.
@MainActor
@Observable
final class HomeScreen {
	static let shared = HomeScreen()

	private static let suspend = NSSelectorFromString("suspend")

	/// Whether Atelier can leave for the Home Screen itself.
	private(set) var canGo: Bool
	/// How many times Atelier stopped being in front, which tells whether
	/// `go` did anything.
	@ObservationIgnored private var resigned = 0

	private init() {
		canGo = UIApplication.shared.responds(to: Self.suspend)
		_ = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { HomeScreen.shared.resigned += 1 }
		}
	}

	/// Leaves for the Home Screen. Once iOS has Atelier's own install,
	/// Atelier then closes as it leaves the screen, as after a swipe up
	/// (`InstallModel.handOver`).
	func go() {
		guard canGo else { return }
		let before = resigned
		UIControl().sendAction(Self.suspend, to: UIApplication.shared, for: nil)
		Task {
			try? await Task.sleep(for: .seconds(1.5))
			if resigned == before { canGo = false }
		}
	}

	/// An iPhone with a Home button, whose screen has no inset at its
	/// bottom edge for the home indicator.
	static var hasHomeButton: Bool {
		let window = UIApplication.shared.connectedScenes
			.compactMap { ($0 as? UIWindowScene)?.keyWindow }
			.first
		return (window?.safeAreaInsets.bottom ?? 0) == 0
	}
}

/// Says to go to the Home Screen for iOS to install Atelier over itself
/// (#123), over whatever is on screen: as iOS gets the build, or as iOS's
/// alert for it closes before iOS asked for the build, when Atelier can't
/// tell whether Install or Cancel was tapped. It's the install bar's
/// sheet, in place of the install's details, and comes up by itself with a
/// haptic; once it's closed, the bar brings it back.
struct HomeScreenSheet: View {
	let model: InstallModel
	let step: InstallModel.LeaveStep
	@State private var home = HomeScreen.shared
	/// The content's height, which the sheet takes.
	@State private var height: CGFloat = 0
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ScrollView {
			VStack(spacing: 0) {
				Image(systemName: "house.fill")
					.font(.system(size: 30, weight: .semibold))
					.foregroundStyle(.tint)
					.frame(width: 72, height: 72)
					.background(Color.accentColor.opacity(0.18), in: Circle())
					.accessibilityHidden(true)
				Text("Go to the Home Screen")
					.font(.title2.bold())
					.multilineTextAlignment(.center)
					.padding(.top, 16)
				Text(message)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.top, 8)
				buttons
					.padding(.top, 24)
				LeaveHint(only: !home.canGo)
					.padding(.top, 20)
			}
			.padding(.horizontal, 24)
			.padding(.top, 32)
			.padding(.bottom, 12)
			.frame(maxWidth: .infinity)
			.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
		}
		.scrollBounceBehavior(.basedOnSize)
		.overlay(alignment: .topTrailing) {
			Button { dismiss() } label: {
				Image(systemName: "xmark")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
					.frame(width: 30, height: 30)
					.background(.quaternary, in: Circle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Close")
			.padding(16)
		}
		.presentationDetents(Set([height > 0 ? PresentationDetent.height(height) : .medium]))
	}

	@ViewBuilder
	private var buttons: some View {
		VStack(spacing: 10) {
			if home.canGo {
				Button { home.go() } label: {
					Text("Go to Home Screen")
						.font(.headline)
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
			}
			if step == .alertClosed {
				// Shows iOS's alert again: the sheet comes back as it closes.
				Button {
					dismiss()
					model.retryAlert()
				} label: {
					Text("Try Again")
						.font(.headline)
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
			}
		}
		.controlSize(.large)
		.buttonBorderShape(.capsule)
	}

	/// "iOS installs Atelier 0.3.0-alpha once you leave it. Atelier closes
	/// as you leave, and a notification says how it went within half a
	/// minute."
	private var message: String {
		let name = SelfUpdate.shared.name
		guard let pending = model.selfPending else { return "iOS installs \(name) once you leave it." }
		switch step {
		case .handover:
			return "\(pending.onceYouLeave(appName: name)) \(PendingSelfInstall.afterLeaving(appName: name, notifies: model.selfNotifies))"
		case .alertClosed:
			return pending.afterAlertClosed(appName: name)
		}
	}
}

/// How to leave without the sheet's button: a swipe up from the bottom
/// edge, with an arrow that bounces toward it, or the Home button.
private struct LeaveHint: View {
	/// Without Go to Home Screen, it's the only way.
	let only: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		let homeButton = HomeScreen.hasHomeButton
		VStack(spacing: 6) {
			if !homeButton { arrow }
			Text(text(homeButton: homeButton))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
	}

	private func text(homeButton: Bool) -> String {
		switch (homeButton, only) {
		case (false, false): "Or swipe up from the bottom edge."
		case (false, true): "Swipe up from the bottom edge."
		case (true, false): "Or press the Home button."
		case (true, true): "Press the Home button."
		}
	}

	@ViewBuilder
	private var arrow: some View {
		let image = Image(systemName: "arrow.up")
			.font(.body.weight(.semibold))
			.foregroundStyle(.secondary)
			.accessibilityHidden(true)
		if reduceMotion {
			image
		} else {
			image.phaseAnimator([false, true]) { view, up in
				view.offset(y: up ? -6 : 0)
			} animation: { up in
				up ? Animation.easeOut(duration: 0.3).delay(0.8) : Animation.spring(duration: 0.5, bounce: 0.5)
			}
		}
	}
}
