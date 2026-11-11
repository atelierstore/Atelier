#if canImport(ObjectiveC) && canImport(CoreFoundation)
import CoreFoundation
import Foundation
import ObjectiveC

/// What iOS itself lets slip about an install in progress.
///
/// Both sources are unofficial. The progress comes from the private
/// `LSApplicationWorkspace`, as in Feather; every lookup checks the selector
/// first, so a missing one returns nil instead of crashing. The notifications
/// are Darwin notifications the system is known to post around installs
/// (public API to listen, undocumented names); they carry no payload, so they
/// say "an app changed", not which one.
public enum SystemInstallSignals {
	/// Darwin notifications that may mark an install. Which of these reach a
	/// sandboxed app on iOS 27, and whether any stays quiet when an install
	/// fails, is what Atelier's install log is there to find out on a device.
	public static let notificationNames = [
		"com.apple.mobile.application_installed",
		"com.apple.LaunchServices.ApplicationsChanged",
		"com.apple.LaunchServices.applicationRegistered",
	]

	/// iOS's install progress for `bundleID` (0...1), or nil when there is no
	/// progress object or the private API isn't there.
	public static func installProgress(for bundleID: String) -> Double? {
		guard let workspace else { return nil }
		let selector = NSSelectorFromString("installProgressForBundleID:makeSynchronous:")
		guard workspace.responds(to: selector) else { return nil }
		typealias Function = @convention(c) (AnyObject, Selector, NSString, Bool) -> AnyObject?
		let function = unsafeBitCast(workspace.method(for: selector), to: Function.self)
		return (function(workspace, selector, bundleID as NSString, true) as? Progress)?.fractionCompleted
	}

	/// iOS's `LSApplicationWorkspace`, also for `AppLauncher`; nil when this
	/// iOS doesn't have it.
	static var workspace: NSObject? {
		guard let cls = NSClassFromString("LSApplicationWorkspace") else { return nil }
		let selector = NSSelectorFromString("defaultWorkspace")
		let object = cls as AnyObject
		guard object.responds(to: selector) else { return nil }
		return object.perform(selector)?.takeUnretainedValue() as? NSObject
	}

	/// Calls `handler` on the main queue with the name of each notification in
	/// `names` that arrives, until the returned listener is released.
	public static func listen(to names: [String] = notificationNames, handler: @escaping @Sendable (String) -> Void) -> Listener {
		Listener(names: names, handler: handler)
	}

	public final class Listener {
		fileprivate let handler: @Sendable (String) -> Void

		fileprivate init(names: [String], handler: @escaping @Sendable (String) -> Void) {
			self.handler = handler
			let center = CFNotificationCenterGetDarwinNotifyCenter()
			let observer = Unmanaged.passUnretained(self).toOpaque()
			for name in names {
				CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
					guard let observer, let name = name.map({ $0.rawValue as String }) else { return }
					let listener = Unmanaged<Listener>.fromOpaque(observer).takeUnretainedValue()
					let handler = listener.handler
					DispatchQueue.main.async { handler(name) }
				}, name as CFString, nil, .deliverImmediately)
			}
		}

		deinit {
			CFNotificationCenterRemoveEveryObserver(
				CFNotificationCenterGetDarwinNotifyCenter(),
				Unmanaged.passUnretained(self).toOpaque()
			)
		}
	}
}
#endif
