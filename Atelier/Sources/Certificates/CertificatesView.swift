import CertKit
import InstallKit
import SwiftUI
import UIKit

/// Settings › Installs › Certificates: the imported certificates and the
/// Apple IDs signed in with (#49), the one in use, and importing or signing
/// in, renaming, deleting or signing out, and choosing the one to use, then
/// this iPhone's UDID, which their profiles have to list. Internally the one
/// in use is still the store's default.
///
/// The one in use has a section of its own on top, as Wi-Fi does with the
/// network you're on, with its check mark kept (the pick of 3 Nov 2026).
/// The others follow, Apple IDs first. Use for Installs says the same for
/// both kinds, in a row's menu and on its page.
///
/// Sign In with Apple ID showed only with Test Actions on until Atelier
/// installed with an Apple ID (#49); everyone sees it since.
struct CertificatesView: View {
	@Environment(CertificatesModel.self) private var model
	@AppStorage(TestActions.certificatesKey) private var certificateTests = false
	@State private var pendingDelete: StoredCertificate?
	@State private var pendingSignOut: StoredAppleID?
	@State private var renaming: StoredCertificate?
	@State private var routeA = RouteASetup.shared

	var body: some View {
		List {
			if let error = model.storeError {
				Text(error).foregroundStyle(.red)
			}
			// In the list rather than over it, so This iPhone shows below:
			// the UDID is what a certificate provider asks for first.
			if model.certificates.isEmpty && model.appleIDs.isEmpty {
				ContentUnavailableView {
					Label("No certificates", systemImage: "checkmark.seal")
				} description: {
					Text("Import your signing certificate (.p12) and its provisioning profile (.mobileprovision). Atelier signs apps with them.")
				} actions: {
					Button("Import Certificate") { model.beginImport() }
						.buttonStyle(.borderedProminent)
					// Under Import, as it needs nothing from a provider; for
					// everyone once Atelier installs with it (#49).
					Button("Sign In with Apple ID") { model.beginSignIn() }
						.buttonStyle(.bordered)
				}
				.listRowBackground(Color.clear)
			}
			let inUseAppleID = model.appleIDs.first { $0.id == model.defaultID }
			let inUseCertificate = model.certificates.first { $0.id == model.defaultID }
			if inUseAppleID != nil || inUseCertificate != nil {
				Section {
					if let inUseAppleID {
						appleIDRow(inUseAppleID)
					} else if let inUseCertificate {
						certificateRow(inUseCertificate)
					}
				} header: {
					Text("In use for installs")
				} footer: {
					Text("Atelier signs every app it installs with it. Only one is in use at a time.")
				}
			}
			let otherAppleIDs = model.appleIDs.filter { $0.id != model.defaultID }
			let otherCertificates = model.certificates.filter { $0.id != model.defaultID }
			if !otherAppleIDs.isEmpty || !otherCertificates.isEmpty {
				Section {
					ForEach(otherAppleIDs) { appleIDRow($0) }
					ForEach(otherCertificates) { certificateRow($0) }
				} header: {
					if inUseAppleID != nil || inUseCertificate != nil {
						Text("Other certificates")
					}
				}
			}
			ThisIPhoneSection(routeA: routeA, hasAppleID: !model.appleIDs.isEmpty)
		}
		.renameAlert(for: $renaming, model: model)
		.navigationTitle("Certificates")
		.toolbar {
			// One menu for both ways in.
			Menu("Add", systemImage: "plus") {
				Button {
					model.beginSignIn()
				} label: {
					Label("Sign In with Apple ID", systemImage: "person.badge.key")
					Text("A free Apple ID, or a paid one")
				}
				Button {
					model.beginImport()
				} label: {
					Label("Import Certificate", systemImage: "arrow.down.doc")
					Text("A .p12 and its profile, from a provider")
				}
			}
		}
	}

	/// An Apple ID's row: Use, Use for Installs and Sign Out.
	private func appleIDRow(_ account: StoredAppleID) -> some View {
		NavigationLink {
			AppleIDDetailView(accountID: account.id)
		} label: {
			AppleIDRow(account: account, isDefault: account.id == model.defaultID)
		}
		// Sign Out instead of Delete, kept as Delete is.
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") { pendingSignOut = account }
				.tint(.red)
		}
		.swipeActions(edge: .leading) {
			if account.id != model.defaultID {
				Button("Use", systemImage: "checkmark.circle") { use(account.id) }
					.tint(.accentColor)
			}
		}
		.contextMenu {
			if account.id != model.defaultID {
				Button("Use for Installs", systemImage: "checkmark.circle") { use(account.id) }
			}
			Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { pendingSignOut = account }
		}
		.signOutConfirmation(for: Binding(
			get: { pendingSignOut?.id == account.id ? pendingSignOut : nil },
			set: { pendingSignOut = $0 }
		), model: model)
	}

	/// An imported certificate's row: Use, Use for Installs, Rename and
	/// Delete.
	private func certificateRow(_ certificate: StoredCertificate) -> some View {
		NavigationLink {
			CertificateDetailView(certificateID: certificate.id)
		} label: {
			CertificateRow(certificate: certificate, isDefault: certificate.id == model.defaultID)
		}
		// Not role: .destructive, which starts removing the row and
		// closes the confirmation's popover as it opens; nor a full
		// swipe, for the same reason (as Library's Delete).
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			Button("Delete", systemImage: "trash") { pendingDelete = certificate }
				.tint(.red)
		}
		.swipeActions(edge: .leading) {
			if certificate.id != model.defaultID {
				Button("Use", systemImage: "checkmark.circle") { use(certificate.id) }
					.tint(.accentColor)
			}
			Button("Rename", systemImage: "pencil") { renaming = certificate }
		}
		.contextMenu {
			Button("Rename", systemImage: "pencil") { renaming = certificate }
			if certificate.id != model.defaultID {
				Button("Use for Installs", systemImage: "checkmark.circle") { use(certificate.id) }
			}
			if certificateTests {
				testButtons(for: certificate)
			}
			Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = certificate }
		}
		// On the row, so on iOS 26 the dialog's popover points at it.
		.deleteConfirmation(for: Binding(
			get: { pendingDelete?.id == certificate.id ? pendingDelete : nil },
			set: { pendingDelete = $0 }
		), model: model)
	}

	/// Puts it in use, moving its row to the top.
	private func use(_ id: UUID) {
		withAnimation { model.makeDefault(id) }
	}

	/// The hidden test actions (#20): Test Revoked and Test Expired, or End
	/// Test while one runs.
	@ViewBuilder
	private func testButtons(for certificate: StoredCertificate) -> some View {
		if model.tests[certificate.id] == nil {
			Button("Test Revoked", systemImage: "xmark.seal") {
				Task { await model.startTest(.revoked, on: certificate.id) }
			}
			Button("Test Expired", systemImage: "clock.badge.xmark") {
				Task { await model.startTest(.expired, on: certificate.id) }
			}
		} else {
			Button("End Test", systemImage: "arrow.uturn.backward") {
				Task { await model.endTest(on: certificate.id) }
			}
		}
	}
}

/// This iPhone's UDID and Developer Mode, as route A last read them (#45),
/// under the certificates whose profiles have to list it. It took the top of
/// Settings until the maintainer moved it here (29 Oct 2026). Tapping the UDID copies
/// it. In a copy of Atelier, the UDID can also come with the certificate
/// the copy came with, from the Atelier that installed it, and in any
/// Atelier from the profile it was installed with, when that lists only
/// this iPhone (#113).
private struct ThisIPhoneSection: View {
	let routeA: RouteASetup
	/// An Apple ID's team registered this iPhone when it signed in (#49).
	let hasAppleID: Bool
	@State private var copied = false

	var body: some View {
		Section {
			if let udid = routeA.udid {
				Button {
					UIPasteboard.general.string = udid
					copied = true
					Task {
						try? await Task.sleep(for: .seconds(2))
						copied = false
					}
				} label: {
					VStack(alignment: .leading, spacing: 3) {
						HStack {
							Text("UDID").foregroundStyle(.primary)
							if copied {
								Text("Copied").font(.caption).foregroundStyle(.tint)
							}
						}
						Text(udid)
							.font(.subheadline.monospaced())
							.foregroundStyle(.secondary)
					}
				}
				.accessibilityHint("Copies the UDID")
			} else {
				LabeledContent("UDID", value: "Unknown")
			}
			if let developerMode = routeA.developerMode {
				LabeledContent("Developer Mode", value: developerMode ? "On" : "Off")
			}
		} header: {
			Text("This \(ThisDevice.name)")
		} footer: {
			Text(footer)
		}
	}

	private var footer: String {
		let device = ThisDevice.name
		if routeA.udid != nil {
			let developerMode = routeA.developerMode == nil ? "" : ", and apps signed ad hoc or for development need Developer Mode"
			if routeA.udidFromProfile {
				let checks = hasAppleID
					? "It’s registered with your Apple ID’s team, and Atelier checks that each profile lists it"
					: "Atelier checks that each profile lists it"
				return "From the profile Atelier was installed with, which lists only this \(device). \(checks)\(developerMode). Tap the UDID to copy it."
			}
			let registered = hasAppleID ? ", and registered with your Apple ID’s team" : ""
			let from = routeA.udidFromInstaller ? "From the Atelier that installed this copy" : "Read during setup"
			return "\(from)\(registered). Atelier checks that each profile lists this \(device)\(developerMode). Tap the UDID to copy it."
		} else if routeA.isSetUp {
			return "Atelier reads it the next time it connects, on Wi-Fi with LocalDevVPN connected. It then checks that each profile lists this \(device)."
		} else {
			return "iOS doesn't let apps read it. Atelier can once you finish setting it up, in Settings › Installs, and then checks that each profile lists this \(device)."
		}
	}
}

struct CertificateRow: View {
	let certificate: StoredCertificate
	let isDefault: Bool

	var body: some View {
		let health = CertificateHealth(certificate)
		HStack(spacing: 12) {
			CertificateTile(certificate: certificate)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 6) {
					Text(certificate.displayName)
						.font(.headline)
						.lineLimit(1)
					if isDefault {
						Image(systemName: "checkmark.circle.fill")
							.font(.caption)
							.foregroundStyle(.tint)
							.accessibilityLabel("In use")
					}
				}
				// Type and team: profile names are often generic, such as
				// "Created via API".
				Text([certificate.profile.kind.title, certificate.certificate.teamName ?? certificate.profile.teamName].compactMap { $0 }.joined(separator: " · "))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if health == .revoked {
					Label("Revoked by Apple", systemImage: "xmark.seal.fill")
						.labelStyle(InlineLabelStyle())
						.font(.footnote.weight(.medium))
						.foregroundStyle(.red)
				} else {
					HStack(spacing: 8) {
						ValidityBar(fraction: certificate.remainingFraction(), color: health.color)
						Text(certificate.remainingText())
							.font(.caption.weight(.medium))
							.foregroundStyle(health == .valid ? Color.secondary : health.color)
							.fixedSize()
					}
				}
			}
		}
		.padding(.vertical, 4)
	}
}

struct ExpiryText: View {
	let date: Date

	var body: some View {
		let expiry = CertificateExpiry(certificate: date, profile: date)
		if date <= .now {
			Text("Expired \(date, format: .dateTime.day().month().year())")
				.foregroundStyle(.red)
		} else if expiry.warning(now: .now) != nil {
			// Within 14 days (#5).
			let left = expiry.daysLeft(now: .now)
			Text("Expires \(left == 1 ? "within a day" : "in \(left) days"), \(date, format: .dateTime.day().month().year())")
				.foregroundStyle(.orange)
		} else {
			Text("Expires \(date, format: .dateTime.day().month().year())")
				.foregroundStyle(.secondary)
		}
	}
}

struct CertificateDetailView: View {
	let certificateID: UUID
	@Environment(CertificatesModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var pendingDelete: StoredCertificate?
	/// Delete from the More menu, kept apart so its dialog points at the
	/// menu rather than at the button at the bottom of the form.
	@State private var pendingMenuDelete: StoredCertificate?
	@State private var renaming: StoredCertificate?

	var body: some View {
		if let certificate = model.certificates.first(where: { $0.id == certificateID }) {
			form(certificate)
				.navigationTitle(certificate.displayName)
				.navigationBarTitleDisplayMode(.inline)
				.renameAlert(for: $renaming, model: model)
				.toolbar {
					Menu("More", systemImage: "ellipsis.circle") {
						Button("Rename", systemImage: "pencil") { renaming = certificate }
						if certificate.id != model.defaultID {
							Button("Use for Installs", systemImage: "checkmark.circle") { model.makeDefault(certificate.id) }
						}
						Button("Delete", systemImage: "trash", role: .destructive) { pendingMenuDelete = certificate }
					}
					.deleteConfirmation(for: $pendingMenuDelete, model: model) { dismiss() }
				}
		} else {
			ContentUnavailableView("Certificate deleted", systemImage: "checkmark.seal")
		}
	}

	private func form(_ certificate: StoredCertificate) -> some View {
		let cert = certificate.certificate
		let profile = certificate.profile
		let dates = Date.FormatStyle.dateTime.day().month().year()
		return Form {
			// Use for Installs is under the name, as on an Apple ID's page
			// (3 Nov 2026). It had a section of its own here before.
			Section {
				CertificateHeader(
					certificate: certificate,
					isDefault: certificate.id == model.defaultID,
					rename: { renaming = certificate },
					use: { model.makeDefault(certificate.id) }
				)
			}

			// Its apps on this iPhone, which it lists when tapped, in a card
			// of their own, then its Status, the same sections as an Apple
			// ID's page (#49, 4 Nov 2026).
			Section {
				SignedAppsRow(signerID: certificate.id)
			}

			CertificateStatusSection(certificate: certificate)

			Section("Certificate") {
				LabeledContent("Name", value: cert.commonName)
				LabeledContent("Team", value: cert.teamName ?? "Unknown")
				LabeledContent("Team ID", value: cert.teamID ?? "Unknown")
				LabeledContent("Valid from", value: cert.notBefore.formatted(dates))
				LabeledContent("Expires") { ExpiryText(date: cert.notAfter) }
				LabeledContent("Serial number", value: cert.serialNumber)
			}

			Section("Provisioning profile") {
				LabeledContent("Name", value: profile.name)
				LabeledContent("Type", value: profile.kind.title)
				LabeledContent("App ID", value: profile.isWildcard ? "\(profile.bundleIDPattern) (wildcard)" : profile.bundleIDPattern)
				LabeledContent("Team", value: [profile.teamName, profile.teamID].compactMap { $0 }.joined(separator: " · "))
				if profile.kind == .enterprise || profile.provisionedDevices.isEmpty {
					LabeledContent("Devices", value: profile.kind == .enterprise ? "All devices" : "0")
				} else {
					NavigationLink {
						ProfileDevicesView(devices: profile.provisionedDevices, thisDevice: RouteASetup.shared.udid)
					} label: {
						LabeledContent("Devices", value: Self.devicesSummary(profile, thisDevice: RouteASetup.shared.udid))
					}
				}
				if let created = profile.creationDate {
					LabeledContent("Created", value: created.formatted(dates))
				}
				LabeledContent("Expires") { ExpiryText(date: profile.expirationDate) }
				LabeledContent("UUID", value: profile.uuid)
			}

			Section {
				ForEach(profile.entitlements.keys.sorted(), id: \.self) { key in
					VStack(alignment: .leading, spacing: 2) {
						Text(key).font(.subheadline)
						Text(profile.entitlements[key] ?? "")
							.font(.subheadline.monospaced())
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
				}
			} header: {
				Text("Entitlements")
			} footer: {
				Text("Signed apps can only use what the profile grants.")
			}

			Section {
				Button("Delete Certificate", role: .destructive) { pendingDelete = certificate }
					.deleteConfirmation(for: $pendingDelete, model: model) { dismiss() }
			}
		}
	}
}

/// A certificate's Status (#49), drawn as an Apple ID's (4 Nov
/// 2026): whether this iPhone is in its profile and Developer Mode is on,
/// as Direct installs last read them (#45), then whether Apple revoked it
/// (#5). A check that fails turns its value red, with what to do under it.
private struct CertificateStatusSection: View {
	let certificate: StoredCertificate
	@Environment(CertificatesModel.self) private var model

	var body: some View {
		let revocation = certificate.revocation
		Section {
			CertificateCheckRows(certificate: certificate)
			RevocationRow(
				revocation: revocation,
				checking: model.checking.contains(certificate.id),
				revokedNote: "Apps signed with it won’t open. Sign them again with another certificate in the Library."
			)
			Button("Check Now", systemImage: "arrow.clockwise") {
				Task { await model.check(certificate.id) }
			}
			.disabled(model.checking.contains(certificate.id))
		} header: {
			Text("Status")
		} footer: {
			VStack(alignment: .leading, spacing: 4) {
				if let error = revocation?.error {
					Text("The last check failed: \(error)")
				}
				if let checked = revocation?.checkedAt {
					Text("Apple answered \(checked.formatted(.relative(presentation: .named))). Atelier asks again when it's opened, at most hourly, and in the background.")
				} else {
					Text("Atelier asks Apple whether the certificate was revoked when you open Atelier, at most once an hour, and in the background.")
				}
			}
		}
	}
}

extension CertificateDetailView {
	/// "3, including this iPhone" once Direct installs has read the UDID (#45).
	static func devicesSummary(_ profile: ProvisioningProfile, thisDevice udid: String?) -> String {
		let count = String(profile.provisionedDevices.count)
		switch profile.check(deviceUDID: udid) {
		case .included: return "\(count), including this \(ThisDevice.name)"
		case .notIncluded: return "\(count), not this \(ThisDevice.name)"
		default: return count
		}
	}
}

/// A profile's device list, with this iPhone first when it's known (#45).
private struct ProfileDevicesView: View {
	let devices: [String]
	let thisDevice: String?
	@State private var copied: String?

	private func isThisDevice(_ udid: String) -> Bool {
		thisDevice.map { udid.caseInsensitiveCompare($0) == .orderedSame } ?? false
	}

	var body: some View {
		let sorted = devices.filter(isThisDevice) + devices.filter { !isThisDevice($0) }
		List {
			Section {
				ForEach(sorted, id: \.self) { udid in
					Button {
						UIPasteboard.general.string = udid
						copied = udid
					} label: {
						VStack(alignment: .leading, spacing: 3) {
							if isThisDevice(udid) {
								Label("This \(ThisDevice.name)", systemImage: "checkmark.circle.fill")
									.foregroundStyle(.primary)
							}
							HStack {
								Text(udid)
									.font(.subheadline.monospaced())
									.foregroundStyle(.secondary)
								if copied == udid {
									Text("Copied").font(.caption).foregroundStyle(.tint)
								}
							}
						}
					}
				}
			} footer: {
				Text("The profile lists UDIDs only, not device names. Tap one to copy it.")
			}
		}
		.navigationTitle("Devices")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private extension View {
	/// Asks for a certificate's new name; an empty one goes back to its own.
	func renameAlert(for item: Binding<StoredCertificate?>, model: CertificatesModel) -> some View {
		modifier(RenameAlert(item: item, model: model))
	}

	func deleteConfirmation(for item: Binding<StoredCertificate?>, model: CertificatesModel, onDelete: @escaping () -> Void = {}) -> some View {
		confirmationDialog(
			"Delete \(item.wrappedValue?.displayName ?? "certificate")?",
			isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
			titleVisibility: .visible,
			presenting: item.wrappedValue
		) { certificate in
			Button("Delete", role: .destructive) {
				model.delete(certificate.id)
				onDelete()
			}
		} message: { _ in
			Text("Atelier removes the .p12, the profile and the saved password from this \(ThisDevice.name). Apps already signed with it keep working until it expires.")
		}
	}
}

extension ProvisioningProfile.Kind {
	var title: String {
		switch self {
		case .development: "Development"
		case .adHoc: "Ad hoc"
		case .enterprise: "Enterprise"
		case .appStore: "App Store"
		}
	}
}

private struct RenameAlert: ViewModifier {
	@Binding var item: StoredCertificate?
	let model: CertificatesModel
	@State private var name = ""

	func body(content: Content) -> some View {
		content
			.alert(
				"Rename Certificate",
				isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
				presenting: item
			) { certificate in
				TextField("Name", text: $name)
					.textInputAutocapitalization(.words)
				Button("Cancel", role: .cancel) {}
				Button("Save") { model.rename(certificate.id, to: name) }
			} message: { certificate in
				Text("Leave empty to use its own name, “\(certificate.originalName)”.")
			}
			.onChange(of: item?.id) {
				name = item?.customName ?? ""
			}
	}
}
