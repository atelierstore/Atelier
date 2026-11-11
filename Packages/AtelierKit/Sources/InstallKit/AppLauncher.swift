#if canImport(ObjectiveC) && canImport(CoreFoundation)
import Foundation
import ObjectiveC

/// Opens an installed app by its bundle ID, as Feather's Open does: through
/// the private `LSApplicationWorkspace`, so also an app without a URL scheme
/// to open it by (#55). As `SystemInstallSignals` does, it checks the
/// selector first, so on an iOS without it nothing opens instead of Atelier
/// crashing.
public enum AppLauncher {
	/// Asks iOS to open the app installed as `bundleID`: whether iOS took
	/// the request, or nil when this iOS doesn't have the call. iOS can take
	/// a while to bring the app up, and says no to an app it won't open, such
	/// as one from a developer this iPhone doesn't trust yet.
	///
	/// It's made off the main thread. Made on it, in the tap or a moment
	/// after, every Open after the first waited 10 to 20 seconds before its
	/// app came up, though Atelier stayed responsive, and made off it, apps
	/// open at once (5 Nov 2026).
	public static func open(_ bundleID: String) async -> Bool? {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(returning: ask(bundleID))
			}
		}
	}

	private static func ask(_ bundleID: String) -> Bool? {
		guard let workspace = SystemInstallSignals.workspace else { return nil }
		let selector = NSSelectorFromString("openApplicationWithBundleID:")
		guard workspace.responds(to: selector) else { return nil }
		typealias Function = @convention(c) (AnyObject, Selector, NSString) -> Bool
		let function = unsafeBitCast(workspace.method(for: selector), to: Function.self)
		return function(workspace, selector, bundleID as NSString)
	}
}
#endif
