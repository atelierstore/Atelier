import UIKit
import UniformTypeIdentifiers

/// UIKit's document picker, presented straight from UIKit on top of whatever
/// is showing. Files of other types are greyed out.
///
/// What failed on the test iPhone (iOS 27): SwiftUI's `fileImporter` greyed out
/// .ipa files, or showed them but ignored the tap. The UIKit picker hosted in
/// a SwiftUI sheet closes itself behind SwiftUI's back, so the sheet's state
/// went stale and nothing followed until the next tap. Presenting it from
/// UIKit leaves no SwiftUI state to go stale. Asked for the files themselves
/// rather than copies, as `fileImporter` does, the UIKit picker ignored the
/// tap on IPAs in Feather's folder too, while its X still closed it and
/// Atelier read nothing on the main thread (3 Nov 2026): iOS doesn't hand
/// them over in place, so it picks copies.
@MainActor
enum DocumentPicker {
	private static var delegate: Delegate?

	/// Picks copies of files, so no security-scoped access is needed.
	/// `onCancel` is told when nothing is picked.
	static func present(contentTypes: [UTType], allowsMultipleSelection: Bool = false, onCancel: @escaping () -> Void = {}, onPick: @escaping ([URL]) -> Void) {
		guard let presenter = topViewController() else { return onCancel() }
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
		picker.allowsMultipleSelection = allowsMultipleSelection
		let delegate = Delegate(onPick: onPick, onCancel: onCancel)
		Self.delegate = delegate
		picker.delegate = delegate
		presenter.present(picker, animated: true)
	}

	/// The given types and the types iOS may give files with these extensions,
	/// without duplicates. Which type iOS gives a file depends on the apps
	/// installed, so the picker accepts all of them.
	static func types(_ identifiers: [String], extensions: [String]) -> [UTType] {
		var types = identifiers.compactMap { UTType($0) }
		for ext in extensions {
			types += [UTType(filenameExtension: ext), UTType(filenameExtension: ext, conformingTo: .data)].compactMap { $0 }
		}
		var seen = Set<String>()
		types.removeAll { !seen.insert($0.identifier).inserted }
		return types
	}

	/// What's showing on top, to present UIKit controllers from.
	static func topViewController() -> UIViewController? {
		let scene = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.first { $0.activationState == .foregroundActive }
		var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
		while let presented = top?.presentedViewController {
			top = presented
		}
		return top
	}

	/// What's on top once Atelier is in front with nothing opening or
	/// closing, as UIKit drops a presentation that starts during another.
	/// Nil after ten seconds.
	static func settledTop() async -> UIViewController? {
		for _ in 0..<200 {
			if let top = topViewController(), top.transitionCoordinator == nil, !top.isBeingPresented, !top.isBeingDismissed {
				return top
			}
			try? await Task.sleep(for: .milliseconds(50))
		}
		return nil
	}

	@MainActor
	private final class Delegate: NSObject, UIDocumentPickerDelegate {
		let onPick: ([URL]) -> Void
		let onCancel: () -> Void

		init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
			self.onPick = onPick
			self.onCancel = onCancel
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			if urls.isEmpty { onCancel() } else { onPick(urls) }
			DocumentPicker.delegate = nil
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			onCancel()
			DocumentPicker.delegate = nil
		}
	}
}
