import UIKit
import UniformTypeIdentifiers

/// Picks an IPA, with every file but .ipa and .tipa greyed out.
///
/// The types follow Feather, whose picker works on the same phone: Atelier
/// exports its own .ipa and .tipa types (project.yml) conforming to
/// `com.apple.itunes.ipa`.
@MainActor
enum IPAPicker {
	/// The files Atelier installs. TrollStore's .tipa is an .ipa by another
	/// name, which Feather installs too (#93).
	nonisolated static let extensions = ["ipa", "tipa"]

	static var contentTypes: [UTType] {
		DocumentPicker.types(["com.atelier.app.ipa", "com.atelier.app.tipa", "com.apple.itunes.ipa"], extensions: extensions)
	}

	/// A copy of the IPA, so Atelier can't find a picked file again (#113):
	/// asked for the file itself, the picker ignored the tap on the test
	/// iPhone, with Atelier still answering (3 Nov 2026).
	static func present(onCancel: @escaping () -> Void = {}, onPick: @escaping (URL) -> Void) {
		DocumentPicker.present(contentTypes: contentTypes, onCancel: onCancel) { urls in
			if let url = urls.first { onPick(url) }
		}
	}
}
