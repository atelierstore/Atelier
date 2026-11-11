import CertKit
import InstallKit
import SwiftUI

// The rows of a certificate's and an Apple ID's Status (#49), which have
// the same sections on both pages (4 Nov 2026): its apps in a card
// of their own, then Status, drawn as an Apple ID's limits were.

/// A row of Status, and of Apps on this iPhone: what it is, its value, how
/// much of a limit is used, as a row of slots, and a line on what that
/// means. Orange once a limit is full. `tint` colors a value to look at:
/// red for a check that failed, orange for one Apple couldn't answer.
struct LimitRow: View {
	let title: String
	let value: String
	/// How many slots there are, and how many are taken.
	var slots: (total: Int, used: Int)?
	var note: String?
	var full = false
	var tint: Color?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline) {
				Text(title)
				Spacer(minLength: 8)
				Text(value)
					.fontWeight(full || tint != nil ? .semibold : .regular)
					.foregroundStyle(tint ?? (full ? Color.orange : Color.secondary))
			}
			if let slots {
				HStack(spacing: 4) {
					ForEach(0..<max(slots.total, 1), id: \.self) { index in
						Capsule()
							.fill(index < slots.used ? (full ? Color.orange : Color.accentColor) : Color.secondary.opacity(0.2))
							.frame(height: 6)
					}
				}
				.accessibilityHidden(true)
			}
			if let note {
				Text(note)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
	}
}

/// Developer Mode, as Direct installs last read it (#45): apps signed for
/// development or ad hoc, and so with an Apple ID, only open with it on.
struct DeveloperModeRow: View {
	enum Setting {
		case on, off, unknown

		/// Nil before Direct installs has read it.
		init(_ on: Bool?) {
			switch on {
			case true?: self = .on
			case false?: self = .off
			case nil: self = .unknown
			}
		}
	}

	let setting: Setting
	/// What signs the apps that need it: "this certificate", "an Apple ID".
	let signedWith: String

	var body: some View {
		let settings = "Settings › Privacy & Security › Developer Mode"
		switch setting {
		case .on:
			LimitRow(title: "Developer Mode", value: "On", note: "Apps signed with \(signedWith) need it.")
		case .off:
			LimitRow(title: "Developer Mode", value: "Off", note: "Apps signed with \(signedWith) won’t open. Turn it on in \(settings).", tint: .red)
		case .unknown:
			LimitRow(title: "Developer Mode", value: "Needed", note: "Apps signed with \(signedWith) only open with it on, in \(settings).")
		}
	}
}

/// Whether Apple revoked a certificate, as of the last check (#5).
/// `revokedNote` says what to do once it has.
struct RevocationRow: View {
	let revocation: RevocationState?
	let checking: Bool
	let revokedNote: String

	var body: some View {
		if checking {
			LimitRow(title: "Revocation", value: "Checking…")
		} else {
			switch revocation?.status {
			case .good:
				LimitRow(title: "Revocation", value: "Not revoked")
			case .revoked(let date):
				LimitRow(title: "Revocation", value: date.map { "Revoked \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Revoked", note: revokedNote, tint: .red)
			case .unknown:
				LimitRow(title: "Revocation", value: "Unknown to Apple", tint: .orange)
			case nil:
				LimitRow(title: "Revocation", value: revocation?.error == nil ? "Not checked yet" : "Couldn’t check")
			}
		}
	}
}

/// An imported certificate's two checks, as rows, from the notes CertKit
/// makes (#45): whether it's registered for this iPhone, then Developer Mode.
/// They were notes with a symbol each until the maintainer asked for Status's rows
/// (4 Nov 2026). A revoked certificate says so in its Revocation row, and
/// one that expires soon in its header, so they have no rows here.
struct CertificateCheckRows: View {
	let certificate: StoredCertificate

	var body: some View {
		let kinds = certificate.notes(deviceUDID: RouteASetup.shared.udid, developerModeOn: RouteASetup.shared.developerMode).map(\.kind)
		if let row = Self.deviceRow(kinds) {
			row
		}
		if let setting = Self.developerMode(kinds) {
			DeveloperModeRow(setting: setting, signedWith: "this certificate")
		}
	}

	/// This iPhone: whether the certificate is registered for it, not
	/// known yet, or the certificate is for the App Store only, which
	/// installs on none. None for an enterprise certificate, which installs
	/// on any. In the certificate's terms rather than its profile's
	/// (5 Nov 2026).
	static func deviceRow(_ kinds: [CertificateNote.Kind]) -> LimitRow? {
		let title = "This \(ThisDevice.name)"
		if kinds.contains(.appStoreProfile) {
			return LimitRow(title: title, value: "For the App Store only", note: "It can only sign apps for the App Store and TestFlight, not for this \(ThisDevice.name).", tint: .red)
		}
		if kinds.contains(.deviceNotInProfile) {
			return LimitRow(title: title, value: "Not registered", note: "Apps signed with this certificate won’t install here.", tint: .red)
		}
		if kinds.contains(.deviceInProfile) {
			return LimitRow(title: title, value: "Registered")
		}
		if kinds.contains(.deviceUnknown) {
			// iOS doesn't let apps read the device ID; the setup can (#9).
			return LimitRow(title: title, value: "Not checked", note: "Atelier can’t check yet whether this certificate is registered for this \(ThisDevice.name). If it isn’t, installs fail. Finishing the setup lets it check.")
		}
		return nil
	}

	/// None for an enterprise or App Store profile, whose apps don't need
	/// Developer Mode.
	static func developerMode(_ kinds: [CertificateNote.Kind]) -> DeveloperModeRow.Setting? {
		if kinds.contains(.developerModeOn) { return .on }
		if kinds.contains(.developerModeOff) { return .off }
		if kinds.contains(.developerModeNeeded) { return .unknown }
		return nil
	}
}
