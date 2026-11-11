import CertKit
import AtelierCore
import SwiftUI

/// Asks what to do when the check before an install finds an app on this
/// iPhone that iOS won't replace with the one being installed (#99): an
/// app from the App Store, TestFlight or an alternative marketplace, or
/// one signed with a certificate that isn't in Atelier, or has expired.
/// The install waits for the answer, before anything is signed.
/// Install as a Copy and Delete … and Install run right away in its place;
/// Import Certificate and Cancel end it.
///
/// It sits both on the tab view and in the install's details, as an alert
/// can't show over the details sheet from below it: `onDetails` says which
/// one this is, and only the one in front shows the question.
struct InstalledConflictAlert: ViewModifier {
	let installer: InstallModel
	let onDetails: Bool
	/// Closes the install's details, when it's on them.
	@Environment(\.dismiss) private var dismiss

	func body(content: Content) -> some View {
		let question = installer.detailsOpen == onDetails ? installer.conflictQuestion : nil
		content
			.alert(
				question?.conflict.title ?? "",
				// Only its buttons answer: the install waits until one does,
				// or until it's cancelled.
				isPresented: Binding(get: { question != nil }, set: { _ in }),
				presenting: question
			) { question in
				if question.conflict.canImport {
					Button("Import Certificate") {
						installer.answerConflict(question.id, .importCertificate)
						// The import can't show over the details: it opens
						// once they're closed.
						if onDetails { dismiss() }
					}
				}
				if question.canCopy {
					Button("Install as a Copy") { installer.answerConflict(question.id, .copy) }
				}
				Button(question.conflict.deleteTitle, role: .destructive) { installer.answerConflict(question.id, .deleteAndInstall) }
				Button("Cancel", role: .cancel) { installer.answerConflict(question.id, .cancel) }
			} message: { question in
				Text(question.conflict.question)
			}
	}
}

/// Under an install that stopped over the app on this iPhone that iOS
/// won't replace (#99), the alert's choices: importing a certificate,
/// installing as a copy, or deleting the app and installing this one in
/// its place, without signing it again.
struct ConflictButtons: View {
	let conflict: InstalledConflict
	let model: InstallModel
	/// Closes the install's details, which the certificate import can't
	/// show over: it opens once they're closed.
	let closeDetails: () -> Void

	var body: some View {
		if model.retryJob != nil {
			if conflict.canImport {
				Button("Import Certificate", systemImage: "person.badge.key") {
					model.importsAfterDetails = true
					closeDetails()
				}
			}
			if model.copyTarget != nil {
				Button("Install as a Copy", systemImage: "plus.square.on.square") { model.installAsCopy() }
			}
			Button(conflict.deleteTitle, systemImage: "trash", role: .destructive) { model.deleteAndInstall() }
		}
	}
}
