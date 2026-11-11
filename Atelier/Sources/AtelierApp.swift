import DownloadKit
import AtelierCore
import SwiftData
import SwiftUI

@main
struct AtelierApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@Environment(\.scenePhase) private var scenePhase
	let container: ModelContainer
	@State private var sources: SourcesModel

	init() {
		do {
			// Atelier takes the store it shared with its copies until now;
			// a copy starts with its own (#113).
			container = try Persistence.makeContainer(adoptingSharedStore: !SelfUpdate.runsAsCopy)
		} catch {
			// Nothing works without the store, and a failed migration should be
			// caught in development, not hidden.
			fatalError("Couldn't open Atelier's store: \(error)")
		}
		// Before anything lists the sources, also in the background.
		Prereleases.adopt(container.mainContext)
		_sources = State(initialValue: SourcesModel(library: SourceLibrary(context: container.mainContext, gitHub: GitHubAccess.source())))
		AutoUpdates.container = container
		// The setup's Live Activity from a run that quit while the setup
		// waited (1 Nov 2026).
		SetupLiveActivity.endLeftovers()
		HomeScreenSpots.forgetTestBuild()
	}

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(sources)
				.environment(BackgroundDownloads.shared.manager)
		}
		// The system's download and install progress can only be asked for in front.
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			// LocalDevVPN may have been installed meanwhile, which decides
			// whether installs can be direct and so get the system's bar.
			RouteASetup.shared.checkVPNInstalled()
			BackgroundInstalls.shared.becameActive()
			BackgroundDownloads.shared.update()
		}
		.modelContainer(container)
	}
}
