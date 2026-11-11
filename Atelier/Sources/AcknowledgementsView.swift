import AtelierCore
import SwiftUI

/// The open source projects Atelier is built on, read from the
/// THIRD_PARTY_NOTICES.md the app ships, with each one's license text (#3).
struct AcknowledgementsView: View {
	private let notices = Self.load()

	var body: some View {
		Form {
			Section {
				ForEach(notices) { notice in
					NavigationLink {
						AcknowledgementView(notice: notice)
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(notice.name)
								Text(notice.usedFor)
									.font(.footnote)
									.foregroundStyle(.secondary)
									.lineLimit(2)
							}
							Spacer()
							Text(notice.license)
								.foregroundStyle(.secondary)
						}
					}
				}
			} header: {
				VStack(alignment: .leading, spacing: 16) {
					Text("Atelier is free software under the GNU General Public License v3.0. It's built on these open source projects; tap one for its copyright and license.")
						.textCase(nil)
					Text("Open source")
				}
			}
		}
		.navigationTitle("Acknowledgements")
		.navigationBarTitleDisplayMode(.inline)
	}

	private static func load() -> [ThirdPartyNotice] {
		guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
			let markdown = try? String(contentsOf: url, encoding: .utf8)
		else { return [] }
		return ThirdPartyNotice.parse(markdown)
	}

	/// The first of these paths that the app bundle has, as text.
	static func licenseText(_ paths: [String]) -> String? {
		guard let resources = Bundle.main.resourceURL else { return nil }
		return paths.lazy
			.compactMap { try? String(contentsOf: resources.appendingPathComponent($0), encoding: .utf8) }
			.first
	}
}

/// One project: what it's used for, its copyright and its license text.
private struct AcknowledgementView: View {
	let notice: ThirdPartyNotice

	var body: some View {
		Form {
			Section {
				LabeledText(label: "Used for", text: notice.usedFor)
				LabeledText(label: "Copyright", text: notice.copyright)
				LabeledContent("License", value: notice.license)
				if let url = notice.url {
					Link(destination: url) {
						HStack {
							Text(url.host().map { $0 + url.path() } ?? url.absoluteString)
							Spacer()
							Image(systemName: "arrow.up.right")
								.foregroundStyle(.secondary)
						}
					}
				}
			}
			LicenseTextSection(text: AcknowledgementsView.licenseText(notice.licensePaths))
		}
		.navigationTitle(notice.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}

/// Atelier's own license, from Settings › About.
struct AtelierLicenseView: View {
	var body: some View {
		Form {
			LicenseTextSection(text: AcknowledgementsView.licenseText(["LICENSE"]))
		}
		.navigationTitle("GPL-3.0")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private struct LabeledText: View {
	let label: String
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
				.textCase(.uppercase)
			Text(text)
		}
	}
}

private struct LicenseTextSection: View {
	let text: String?

	var body: some View {
		Section("License") {
			Text(text ?? "The license text is missing from this build.")
				.font(.caption.monospaced())
				.foregroundStyle(text == nil ? HierarchicalShapeStyle.secondary : .primary)
				.textSelection(.enabled)
		}
	}
}
