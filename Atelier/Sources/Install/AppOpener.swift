import AtelierCore
import InstallKit
import SwiftUI
import UIKit

/// Open, for an app Atelier installed (#55): by its bundle ID, as Feather's
/// Open does, so also an app signed without a check scheme. Once iOS takes
/// the request, the rest is up to iOS, which can take a while to bring the
/// app up. When it says no to an app that's here, such as one from a
/// developer this iPhone doesn't trust yet, it says why in an alert of its
/// own, which leaves Atelier in front, so Open stops there: the check scheme
/// only brought that alert up again (5 Nov 2026). Atelier only says it
/// couldn't open an app without a check scheme, which it can't tell is still
/// here. On an iOS without the call, Open uses the check scheme the app was
/// signed with, which is public API.
@MainActor
@Observable
final class AppOpener {
	static let shared = AppOpener()

	/// The app Open couldn't open, by name, for `OpenFailedAlert`.
	var failed: String?

	func open(_ install: InstallRecord) {
		let name = install.name
		let bundleID = install.bundleID
		let url = install.checkScheme.flatMap { URL(string: "\($0)://") }
		Task {
			switch await AppLauncher.open(bundleID) {
			case true?:
				return
			case false?:
				// The check scheme it answers to says it's here.
				if url == nil { failed = name }
			case nil:
				// The app gets a bare `<scheme>://` URL, which apps ignore
				// apart from opening.
				if let url, await UIApplication.shared.open(url) { return }
				failed = name
			}
		}
	}
}

/// "Couldn't Open YouTube", when iOS didn't open an app Atelier can't tell
/// is still here, or no way to open it was left (`AppOpener`).
struct OpenFailedAlert: ViewModifier {
	@State private var opener = AppOpener.shared

	func body(content: Content) -> some View {
		content.alert(
			opener.failed.map { "Couldn't Open \($0)" } ?? "",
			isPresented: Binding(get: { opener.failed != nil }, set: { if !$0 { opener.failed = nil } }),
			presenting: opener.failed
		) { _ in
			Button("OK", role: .cancel) {}
		} message: { name in
			Text("iOS didn't open it. If \(name) is still on this \(ThisDevice.name), open it from the Home Screen.")
		}
	}
}
