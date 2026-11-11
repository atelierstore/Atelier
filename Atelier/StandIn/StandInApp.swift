import SwiftUI
import UIKit

/// A stand-in for an offloaded app (9 Nov 2026): Atelier signs a copy
/// of this app as it signed the app, with the app's name and its icon
/// greyed, and puts it in the app's spot on the Home Screen while the app
/// is away. Opening it opens Atelier, at the link Atelier wrote into its
/// Info.plist, `OffloadMarkers.standInLinkKey`.
@main
struct StandInApp: App {
	@Environment(\.scenePhase) private var scenePhase

	var body: some Scene {
		WindowGroup {
			Text("Opening Atelier…")
				.foregroundStyle(.secondary)
		}
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active,
			      let text = Bundle.main.object(forInfoDictionaryKey: "AtelierStandInLink") as? String,
			      let url = URL(string: text)
			else { return }
			UIApplication.shared.open(url)
		}
	}
}
