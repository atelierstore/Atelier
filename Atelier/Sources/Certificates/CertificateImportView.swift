import CertKit
import InstallKit
import SwiftUI

/// The import sheet: the .p12 and profile picked so far, the password, and
/// what's wrong if the import fails. Files shared to Atelier land here too.
struct CertificateImportView: View {
	@Environment(CertificatesModel.self) private var model

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Button("Choose Files", systemImage: "folder") {
						DocumentPicker.present(contentTypes: CertificatesModel.contentTypes, allowsMultipleSelection: true) { urls in
							model.add(urls)
						}
					}
				} footer: {
					Text("Pick the .p12 and the .mobileprovision together, or a ZIP holding both. You can also share them to Atelier from Files or Mail.")
				}

				Section("Files") {
					FileRow(title: "Certificate", placeholder: ".p12", file: model.draft?.files.p12)
					FileRow(title: "Profile", placeholder: ".mobileprovision", file: model.draft?.files.profile)
				}

				Section {
					SecureField("Certificate password", text: Binding(
						get: { model.draft?.password ?? "" },
						set: { model.draft?.password = $0 }
					))
					.submitLabel(.done)
					.onSubmit { model.finishImport() }
				} header: {
					Text("Password")
				} footer: {
					Text("The .p12's password. Atelier keeps it in the Keychain, and the files stay on this \(ThisDevice.name), left out of backups.")
				}

				Section {
					TextField("Optional", text: Binding(
						get: { model.draft?.name ?? "" },
						set: { model.draft?.name = $0 }
					))
					.textInputAutocapitalization(.words)
				} header: {
					Text("Name")
				} footer: {
					Text("A name you'll recognise, shown everywhere Atelier mentions this certificate. Left empty, it keeps the certificate's own name. You can change it later.")
				}

				if let error = model.draft?.error {
					Section {
						Label(error, systemImage: "xmark.octagon.fill")
							.foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("Import Certificate")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { model.draft = nil }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Import") { model.finishImport() }
						.disabled(!(model.draft?.files.isComplete ?? false))
				}
			}
		}
		.interactiveDismissDisabled(model.draft?.files.p12 != nil || model.draft?.files.profile != nil)
	}
}

private struct FileRow: View {
	let title: String
	let placeholder: String
	let file: CertificateFiles.File?

	var body: some View {
		LabeledContent(title) {
			if let file {
				Label(file.name, systemImage: "checkmark.circle.fill")
					.labelStyle(.titleAndIcon)
					.foregroundStyle(.primary)
					.lineLimit(1)
					.truncationMode(.middle)
			} else {
				Text("Missing \(placeholder)")
					.foregroundStyle(.secondary)
			}
		}
	}
}
