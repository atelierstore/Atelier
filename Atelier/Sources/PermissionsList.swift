import SigningKit
import SourceKit
import SwiftUI

/// An app's permissions, the same in Browse and the Library (#7, #8): its
/// privacy permissions, which work whatever the signing, and its
/// capabilities, each with whether the signing supports it. Tapping a
/// capability shows why and its entitlement keys.
struct PermissionsList: View {
	let privacy: [(key: String, name: String, reason: String)]
	let capabilities: [EntitlementsReport.Capability]
	var notes: [String] = []
	/// Where the capabilities and their support come from.
	let checked: String

	/// Why capabilities depend on the signing, wherever they're shown.
	static let why = "Privacy permissions work as usual: iOS asks you the first time the app needs them. Other features depend on your certificate, which decides what a re-signed app keeps."

	var body: some View {
		if !privacy.isEmpty || !capabilities.isEmpty || !notes.isEmpty {
			Section {
				if !privacy.isEmpty {
					Subheading(text: "Privacy")
					ForEach(privacy, id: \.key) { permission in
						VStack(alignment: .leading, spacing: 2) {
							Text(permission.name)
							Text(permission.reason)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				}
				if !capabilities.isEmpty {
					Subheading(text: "Capabilities")
					ForEach(capabilities, id: \.name) { capability in
						CapabilityRow(capability: capability)
					}
				}
				ForEach(notes, id: \.self) { note in
					Text(note)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Permissions")
			} footer: {
				Text(Self.why + " " + checked)
			}
		}
	}
}

private struct Subheading: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.caption.weight(.semibold))
			.foregroundStyle(.secondary)
			.textCase(.uppercase)
	}
}

private struct CapabilityRow: View {
	let capability: EntitlementsReport.Capability

	var body: some View {
		DisclosureGroup {
			if let detail = capability.detail {
				Text(detail)
					.font(.footnote)
			}
			// The names the app asks for, and the ones its signing has (#49).
			ForEach(capability.renamedValues.keys.sorted(), id: \.self) { own in
				VStack(alignment: .leading, spacing: 2) {
					Text(own)
						.foregroundStyle(.secondary)
					Text("→ \(capability.renamedValues[own] ?? own)")
						.foregroundStyle(.green)
				}
				.font(.caption.monospaced())
				.textSelection(.enabled)
			}
			ForEach(capability.keys, id: \.self) { key in
				Text(key)
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}
		} label: {
			HStack {
				Image(systemName: symbol)
					.foregroundStyle(capability.status == .supported ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
				Text(capability.name)
				Spacer()
				Text(label)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		}
	}

	private var symbol: String {
		switch capability.status {
		case .supported: "checkmark.circle.fill"
		case .partly: "circle.lefthalf.filled"
		case .probablyNot: "questionmark.circle"
		case .unsupported: "minus.circle"
		case nil: "circle.dashed"
		}
	}

	private var label: String {
		switch capability.status {
		case .supported: "Supported"
		case .partly: "Partly"
		case .probablyNot: "Probably not"
		case .unsupported: "Not supported"
		case nil: "Not checked"
		}
	}
}

extension SignedPermissions {
	/// Its privacy permissions by name, for `PermissionsList`.
	var namedPrivacy: [(key: String, name: String, reason: String)] {
		AppPermissions(privacy: privacy).namedPrivacy
	}

	/// What `PermissionsList` says the capabilities were checked against.
	var checked: String {
		guard let entitlements else {
			return "These weren't checked against your certificate when the app was signed."
		}
		return entitlements.readFromApp
			? "Checked against the app itself when it was signed."
			: "The app itself lists none, so these come from its source, checked against your certificate when it was signed."
	}
}
