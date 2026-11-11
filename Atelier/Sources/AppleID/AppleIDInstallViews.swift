import AtelierCore
import CertKit
import InstallKit
import SwiftData
import SwiftUI

/// What installs with an Apple ID show over everything (#49): Apple's
/// request for a code while a sign-in before an install waits for it, the
/// question before an install with a free Apple ID takes a new App ID, the
/// trust sheet after the first install with an Apple ID, and Make Room
/// when a free Apple ID's 3 places on this iPhone are taken. On the tab
/// view and in the install's details, as an alert or sheet can't show over
/// the details sheet from below it: `onDetails` says which one this is, and
/// only the one in front shows them.
struct AppleIDInstallPrompts: ViewModifier {
	@Bindable var installer: InstallModel
	let onDetails: Bool

	/// One sheet for them all, as they never show together.
	private enum Sheet: Identifiable {
		case trust(InstallModel.TrustPrompt)
		case makeRoom(InstallModel.MakeRoomRequest)
		case newAppID(InstallModel.AppIDQuestion)

		var id: UUID {
			switch self {
			case .trust(let prompt): prompt.id
			case .makeRoom(let request): request.id
			case .newAppID(let question): question.id
			}
		}
	}

	func body(content: Content) -> some View {
		let inFront = installer.detailsOpen == onDetails
		let access = AppleIDAccess.shared
		content
			.modifier(AppleIDCodeAlert(prompt: inFront ? access.codePrompt : nil) { access.answerCode($0) })
			.sheet(item: Binding<Sheet?>(
				get: {
					guard inFront else { return nil }
					return installer.appIDQuestion.map(Sheet.newAppID) ?? installer.makeRoom.map(Sheet.makeRoom) ?? installer.trustPrompt.map(Sheet.trust)
				},
				set: { shown in
					guard shown == nil else { return }
					// Swiped away, the question's answer is Close.
					if let question = installer.appIDQuestion {
						installer.answerAppID(question.id, .cancel)
					} else if installer.makeRoom != nil {
						installer.makeRoom = nil
					} else {
						installer.trustPrompt = nil
					}
				}
			)) { sheet in
				switch sheet {
				case .trust(let prompt):
					TrustAppleIDSheet(prompt: prompt)
				case .makeRoom(let request):
					MakeRoomSheet(request: request, installer: installer)
				case .newAppID(let question):
					NewAppIDSheet(question: question) { installer.answerAppID(question.id, $0) }
				}
			}
	}
}

/// Make Room (#49): a free Apple ID's apps have 3 places on this iPhone,
/// all taken, so an install with one, or Enable, picks an app to disable.
/// One tap disables it, keeping its data, then installs. Apps that aren't
/// in the Library, such as SideStore's, are named without a button.
/// The maintainer approved the mockup on 3 Nov 2026.
struct MakeRoomSheet: View {
	let request: InstallModel.MakeRoomRequest
	let installer: InstallModel
	@Environment(\.modelContext) private var context
	@Environment(\.dismiss) private var dismiss
	@Query private var installs: [InstallRecord]

	var body: some View {
		let name = request.appName
		NavigationStack {
			List {
				Section {
					VStack(spacing: 10) {
						appIcon
						Text("Make Room for \(name)")
							.font(.title2.weight(.bold))
							.multilineTextAlignment(.center)
						Text("This \(ThisDevice.name) already has the \(FreeAppleID.appsPerDevice) apps a free Apple ID allows. \(canDisableAny ? "Offload" : "Delete") one to \(request.enabling ? "reinstall" : "install") \(name).")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
				}
				Section {
					ForEach(request.holding) { app in
						row(app)
					}
				} footer: {
					Text(footer)
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close", systemImage: "xmark") { dismiss() }
				}
			}
		}
		.presentationDetents([.large])
	}

	/// The app to make room for, paused when it's a disabled one.
	@ViewBuilder
	private var appIcon: some View {
		let install = request.job.replacesBundleID.flatMap { id in installs.first { $0.bundleID == id } }
		let url = request.job.iconURL ?? install.flatMap { InstalledApps.iconURL(of: $0, in: context) }
		if request.enabling {
			DisabledAppIcon(url: url, tint: nil, size: 64)
		} else {
			SourceIcon(url: url, tint: nil, size: 64)
		}
	}

	private var footer: String {
		let name = request.appName
		// None in the Library, such as the spike's or SideStore's: only the
		// Home Screen deletes them, then the install's details try again.
		guard canDisableAny else {
			return "None of them is in Atelier’s Library, so Atelier can’t offload one. Delete one from the Home Screen, then try again from the install’s details."
		}
		if request.enabling {
			return "One tap does both: Atelier keeps the offloaded app’s data, then installs \(name) and puts its own back."
		}
		return "One tap does both: Atelier keeps the offloaded app’s data, then installs \(name). Close this and the install stops; its details offer Make Room again."
	}

	/// Whether any of the apps holding a place can be disabled.
	private var canDisableAny: Bool {
		request.holding.contains { canDisable(libraryEntry(of: $0)) }
	}

	/// The Library's entry for an app holding a place, if it has one.
	private func libraryEntry(of app: FreeApp) -> InstallRecord? {
		installs.first { $0.bundleID == app.bundleID }
	}

	/// Whether Disable can take it off this iPhone: an app in the Library,
	/// other than Atelier.
	private func canDisable(_ install: InstallRecord?) -> Bool {
		install.map { !SelfUpdate.shared.isOwn($0) } ?? false
	}

	/// An app holding a place: Disable for one in the Library, else only
	/// its name and why it can't be.
	private func row(_ app: FreeApp) -> some View {
		let install = libraryEntry(of: app)
		let offersDisable = canDisable(install)
		return HStack(spacing: 12) {
			SourceIcon(url: install.flatMap { InstalledIcons.shared.url(for: $0.bundleID) ?? InstalledApps.iconURL(of: $0, in: context) }, tint: nil, size: 46)
			VStack(alignment: .leading, spacing: 2) {
				Text(install?.name ?? app.name)
					.font(.headline)
					.foregroundStyle(offersDisable ? .primary : .secondary)
					.lineLimit(1)
				Text(subtitle(app, install: install))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 8)
			if let install, offersDisable {
				Button("Offload") {
					installer.makeRoom(request, disabling: install, iconURL: InstalledIcons.shared.url(for: install.bundleID) ?? InstalledApps.iconURL(of: install, in: context))
					dismiss()
				}
				.buttonStyle(.bordered)
				.buttonBorderShape(.capsule)
				.fontWeight(.semibold)
			}
		}
		.padding(.vertical, 2)
	}

	/// "7 days left", the app's profile's, or why it isn't one to disable.
	private func subtitle(_ app: FreeApp, install: InstallRecord?) -> String {
		guard let install else {
			let mine = CertificatesModel.shared.appleIDs.contains { $0.team.id == app.teamID }
			return mine ? "Signed with your Apple ID, and not in the Library" : "Signed with another Apple ID, and not in the Library"
		}
		if let profile = CertificatesModel.shared.appleID(install.certificateID)?.profile(for: install.bundleID) {
			return AppProfileDays.text(until: profile.expires)
		}
		return "Version \(install.version)"
	}
}

/// Before an install with a free Apple ID takes a new App ID, one of the
/// 10 a week (#49): the Apple ID's row says so and how many are left, as
/// the pattern the maintainer liked on 4 Nov 2026 has it, with nothing on the app's
/// page. Install goes on; for a new app, Install with Another Certificate…
/// lists the others that can sign it, as a page in the sheet (the
/// same evening); closing it stops the install.
struct NewAppIDSheet: View {
	let question: InstallModel.AppIDQuestion
	let answer: (InstallModel.AppIDAnswer) -> Void
	@State private var choosing = false

	var body: some View {
		let name = question.appName
		let verb = question.verb
		NavigationStack {
			List {
				Section {
					VStack(spacing: 10) {
						SourceIcon(url: question.iconURL, tint: nil, size: 64)
						Text("\(verb.title) \(name)?")
							.font(.title2.weight(.bold))
							.multilineTextAlignment(.center)
						Text("\(verb.gerund) it with your free Apple ID takes a new App ID.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
				}
				Section {
					HStack(spacing: 12) {
						AppleIDTile(isRevoked: question.appleID.isRevoked)
						VStack(alignment: .leading, spacing: 2) {
							Text(question.appleID.displayName)
								.font(.headline)
								.lineLimit(1)
							Text(appIDLine)
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
					}
					.padding(.vertical, 4)
					.accessibilityElement(children: .combine)
				} footer: {
					Text("\(name) then has its App ID until \(question.until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), so reinstalling or updating it takes no other until then.")
				}
				Section {
					Button { answer(.install) } label: {
						Text(verb.title)
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
					.listRowSeparator(.hidden)
					if !question.others.isEmpty {
						Button { choosing = true } label: {
							Text("\(verb.title) with Another Certificate…")
								.lineLimit(1)
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.bordered)
						.controlSize(.large)
						.listRowBackground(Color.clear)
						.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
						.listRowSeparator(.hidden)
					}
				} footer: {
					Text(footer)
						.frame(maxWidth: .infinity)
						.multilineTextAlignment(.center)
				}
			}
			.navigationDestination(isPresented: $choosing) {
				InstallWithList(appName: name, choices: question.others) { answer(.installWith($0.id)) }
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close", systemImage: "xmark") { answer(.cancel) }
				}
			}
		}
		.presentationDetents([.large])
	}

	/// "Free Apple ID · new App ID: 4 of 10 left this week".
	private var appIDLine: String {
		guard let left = question.left else { return "Free Apple ID · new App ID: one of the \(question.max) allowed this week" }
		return "Free Apple ID · new App ID: \(left) of \(question.max) left this week"
	}

	/// What closing it does.
	private var footer: String {
		"Closing this stops the install."
	}
}

/// What Install with Another Certificate… lists (#49), as a page in the
/// question's sheet: what can sign the app instead of the free Apple ID, as
/// Settings lists them, the way Sign Again With showed them (4 Nov
/// 2026), and Custom Install's sheet does now (#155). Another free Apple ID
/// says how many of its own 10 App IDs a week are left, as it last said, so
/// one helps when the first runs low; the 3 places on this iPhone are the same
/// whichever free Apple ID signs, as iOS counts them. Tapping one installs the
/// app with it.
struct InstallWithList: View {
	let appName: String
	let choices: [SigningChoice]
	let choose: (SigningChoice) -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		List {
			Section {
				ForEach(choices) { choice in
					Button {
						choose(choice)
						// Back to the install's details; the question's sheet
						// goes as it's answered.
						dismiss()
					} label: {
						HStack(spacing: 12) {
							tile(choice)
							VStack(alignment: .leading, spacing: 2) {
								Text(choice.displayName)
									.font(.headline)
									.foregroundStyle(.primary)
									.lineLimit(1)
								Text(subtitle(choice))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
						.padding(.vertical, 2)
					}
				}
			} footer: {
				Text(footer)
			}
		}
		.modifier(TitleWithSubtitle(title: "Install \(appName) With", subtitle: "Instead of your free Apple ID"))
		.navigationBarTitleDisplayMode(.inline)
	}

	@ViewBuilder
	private func tile(_ choice: SigningChoice) -> some View {
		switch choice {
		case .certificate(let certificate): CertificateTile(certificate: certificate, size: 40)
		case .appleID(let account): AppleIDTile(isRevoked: account.isRevoked, size: 40)
		}
	}

	/// "Free Apple ID · new App ID: 9 of 10 left this week"; "Development ·
	/// 43 days left".
	private func subtitle(_ choice: SigningChoice) -> String {
		guard case .appleID(let account) = choice, account.isFree else { return "\(choice.kind) · \(choice.remainingText)" }
		guard let appIDs = account.limits?.appIDs, let left = appIDs.left() else { return "Free Apple ID · takes a new App ID" }
		return "Free Apple ID · new App ID: \(left) of \(appIDs.max ?? FreeAppleID.appIDsPerWeek) left this week"
	}

	/// What they take, which only a free Apple ID's App IDs count.
	private var footer: String {
		guard choices.contains(where: \.isFreeAppleID) else { return "None of these takes one of your free Apple ID’s App IDs." }
		return "Only a free Apple ID takes one of its 10 App IDs a week. With any free Apple ID, \(appName) takes one of this \(ThisDevice.name)’s 3 places."
	}
}

/// After the first install with an Apple ID on this iPhone: iOS opens the
/// app once the user trusts the Apple ID, in Settings, which no link opens.
struct TrustAppleIDSheet: View {
	let prompt: InstallModel.TrustPrompt
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 10) {
						Image(systemName: "checkmark.shield.fill")
							.font(.system(size: 34))
							.foregroundStyle(.white)
							.frame(width: 64, height: 64)
							.background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
							.accessibilityHidden(true)
						Text("Trust Your Apple ID")
							.font(.title2.weight(.bold))
							.multilineTextAlignment(.center)
						Text("\(prompt.appName) is installed. iOS opens it once you trust the Apple ID it’s signed with, once on this \(ThisDevice.name).")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
				}
				Section {
					TrustStep(number: 1, text: "Open Settings › General › VPN & Device Management.")
					TrustStep(number: 2, text: "Under Developer App, tap \(prompt.appleID).")
					TrustStep(number: 3, text: "Tap Trust “\(prompt.appleID)”, then Trust in iOS’s alert.")
				} footer: {
					Text("iOS asks again once every app signed with it has been deleted from this \(ThisDevice.name), and Atelier then shows this again.")
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
		.presentationDetents([.large])
	}
}

/// One of the trust sheet's steps: its number in a circle, then what to do.
private struct TrustStep: View {
	let number: Int
	let text: String

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text("\(number)")
				.font(.subheadline.weight(.bold))
				.foregroundStyle(.white)
				.frame(width: 24, height: 24)
				.background(Circle().fill(.tint))
				.accessibilityHidden(true)
			Text(text)
				.font(.subheadline)
		}
		.padding(.vertical, 4)
	}
}
