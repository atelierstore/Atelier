import AppleIDKit
import CertKit
import InstallKit
import SwiftUI

/// The Sign In with Apple ID sheet (#49), as the maintainer approved its mockups on
/// 2 Nov 2026: the two fields and what happens to them, Apple's code when
/// it asks, Choose a Team for an Apple ID in more than one, Revoke a
/// Certificate? at Apple's limit, then You're Signed In. Until the setup
/// is finished, a card to it takes the fields' place, as apps signed with
/// an Apple ID only install through it and Apple needs the UDID it reads.
struct AppleIDSignInView: View {
	@Bindable var signIn: AppleIDSignIn
	@Environment(CertificatesModel.self) private var certificates
	@State private var setup = RouteASetup.shared
	/// Set Up Now was tapped: the setup shows in the sheet, until it's done.
	@State private var settingUp = false

	var body: some View {
		NavigationStack {
			page
				.navigationBarTitleDisplayMode(.inline)
				.navigationDestination(isPresented: $settingUp) {
					InstallSetupView()
				}
		}
		.interactiveDismissDisabled(isBusy)
		.modifier(AppleIDCodeAlert(prompt: signIn.codePrompt) { signIn.answerCode($0) })
		// The sheet comes back once the setup is done.
		.onChange(of: setup.isSetUp) { _, done in
			if done { settingUp = false }
		}
	}

	/// Running, or waiting on a choice that only Cancel or the choice ends.
	private var isBusy: Bool {
		switch signIn.stage {
		case .form, .done: false
		case .working, .chooseTeam, .revoke: true
		}
	}

	@ViewBuilder
	private var page: some View {
		switch signIn.stage {
		case .form, .working:
			SignInForm(signIn: signIn, isSetUp: setup.isSetUp) { settingUp = true }
		case .chooseTeam(let teams, let current):
			ChooseTeam(signIn: signIn, teams: teams, picked: current)
		case .revoke(let listed, let revoked):
			RevokeCertificate(signIn: signIn, email: signIn.email, listed: listed, revoked: revoked)
		case .done(let done):
			SignedInPage(done: done)
		}
	}
}

/// Presents the sheet while `CertificatesModel.signIn` is set, from
/// RootView, as the import sheet is, and over the welcome from Get Ready,
/// where RootView's is `isShown` false as it's under it. A modifier of its
/// own: RootView's body is at the edge of what the compiler type-checks in
/// time.
struct AppleIDSignInSheet: ViewModifier {
	let certificates: CertificatesModel
	var isShown = true

	func body(content: Content) -> some View {
		// Not while Atelier signs in by itself with the installer's, until
		// there's something to show (#152).
		content.sheet(isPresented: Binding(
			get: { isShown && certificates.signIn?.isShown == true },
			set: { if !$0 { certificates.endSignIn() } }
		)) {
			if let signIn = certificates.signIn {
				AppleIDSignInView(signIn: signIn)
					.environment(certificates)
			}
		}
	}
}

/// What the sheet's pages put at their top: a tile, a title and a line.
private struct SheetHeading: View {
	let title: String
	let text: String
	let tile: AnyView

	var body: some View {
		VStack(spacing: 10) {
			tile
			Text(title)
				.font(.title2.weight(.bold))
				.multilineTextAlignment(.center)
			Text(text)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.listRowBackground(Color.clear)
		.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
	}
}

// MARK: Sign in

private struct SignInForm: View {
	@Bindable var signIn: AppleIDSignIn
	let isSetUp: Bool
	let setUp: () -> Void
	@Environment(CertificatesModel.self) private var certificates
	@AppStorage(CustomAnisetteServer.defaultsKey) private var customServer = ""
	@FocusState private var focus: Field?
	@ScaledMetric private var labelWidth = 92.0

	private enum Field {
		case email, password
	}

	var body: some View {
		Form {
			Section {
				if signIn.signsInAgain {
					// Sign In Again, once Apple's token has expired (#182).
					SheetHeading(
						title: "Sign In Again",
						text: "Atelier’s sign-in with this Apple ID has expired. Atelier signs in with its password, then renews your apps. They keep their data.",
						tile: AnyView(AppleIDTile(size: 60))
					)
				} else if signIn.renewing != nil {
					// New Certificate (12 Nov 2026), with Apple's token or the
					// password (#182).
					SheetHeading(
						title: "New Certificate",
						text: "Atelier signs in again, has Apple make a new certificate, then signs your apps again with it. They keep their data.",
						tile: AnyView(AppleIDTile(size: 60))
					)
				} else {
					SheetHeading(
						title: "Sign In with Apple ID",
						text: "Atelier makes a certificate for this \(ThisDevice.name) with it, then the profiles your apps need.",
						tile: AnyView(AppleIDTile(size: 60))
					)
				}
			}

			if isSetUp {
				fields
			} else {
				SetupFirstCard(setUp: setUp)
			}

			Section {
				Point(symbol: "key") {
					// Token only, as approved on 13 Nov 2026 (#182).
					Text("\(Text("Your password only goes to Apple.").bold()) Atelier keeps Apple’s sign-in token instead, in this \(ThisDevice.name)’s Keychain and never synced, and renews your apps with it every week.")
				}
				Point(symbol: "checkmark.shield") {
					if let host = (try? CustomAnisetteServer.resolve(customServer).get())?.host {
						Text("\(Text("Your anisette server vouches for the sign-in.").bold()) Apple wants another device’s word for it, which Atelier gets from \(host). It never sees your password.")
					} else {
						Text("\(Text("A public server vouches for the sign-in.").bold()) Apple wants another device’s word for it, which Atelier gets from an anisette server. It never sees your password.")
					}
				}
			}
		}
		.navigationTitle(signIn.signsInAgain ? "Sign In Again" : signIn.renewing == nil ? "Sign In" : "New Certificate")
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel", systemImage: "xmark") { certificates.endSignIn() }
			}
			ToolbarItem(placement: .confirmationAction) {
				Button("Sign In") { signIn.signIn() }
					.disabled(!isSetUp || !signIn.canSignIn)
			}
		}
		.onAppear {
			guard isSetUp else { return }
			// Sign In Again only needs the password (#182).
			if signIn.email.isEmpty { focus = .email } else if signIn.signsInAgain { focus = .password }
		}
	}

	private var fields: some View {
		Section {
			HStack {
				Text("Apple ID")
					.frame(width: labelWidth, alignment: .leading)
				TextField("name@example.com", text: $signIn.email)
					.keyboardType(.emailAddress)
					.textContentType(.username)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.next)
					.focused($focus, equals: .email)
					.onSubmit { focus = .password }
					// New Certificate and Sign In Again are for its Apple ID (12
					// Nov 2026, #182).
					.disabled(signIn.renewing != nil)
			}
			HStack {
				Text("Password")
					.frame(width: labelWidth, alignment: .leading)
				SecureField("Required", text: $signIn.password)
					.textContentType(.password)
					.submitLabel(.go)
					.focused($focus, equals: .password)
					.onSubmit { signIn.signIn() }
			}
			switch signIn.stage {
			case .working(let what):
				HStack(spacing: 8) {
					ProgressView()
					Text(what)
						.foregroundStyle(.secondary)
				}
			case .form(let error?):
				Text(error)
					.foregroundStyle(.red)
			default:
				EmptyView()
			}
		} footer: {
			Text("Free, or in the Apple Developer Program. A spare Apple ID works as well as your own.")
		}
		.disabled(signIn.isWorking)
	}
}

/// One of the sign-in sheet's points: a symbol, then what it says.
private struct Point<Content: View>: View {
	let symbol: String
	@ViewBuilder let content: Content

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Image(systemName: symbol)
				.foregroundStyle(.tint)
				.frame(width: 22)
			content
				.font(.subheadline)
		}
		.padding(.vertical, 4)
	}
}

/// In place of the fields until the setup is finished.
private struct SetupFirstCard: View {
	let setUp: () -> Void

	var body: some View {
		Section {
			VStack(alignment: .leading, spacing: 12) {
				HStack(spacing: 11) {
					SourceIcon(url: SelfUpdate.shared.iconURL, tint: nil, size: 36)
					Text("Finish the setup first")
						.font(.headline)
				}
				Text("Apps signed with an Apple ID only install through the setup, not iOS’s alert. Apple also needs this \(ThisDevice.name)’s UDID, which the setup reads.")
					.font(.subheadline)
				Button(action: setUp) {
					Text("Set Up Now")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
			}
			.padding(.vertical, 8)
		}
	}
}

/// Apple's request for a verification code: the code Apple texted, or the
/// one shown on the user's other devices. The sign-in sheet's, and the one
/// over everything for an install (#49).
struct AppleIDCodeAlert: ViewModifier {
	let prompt: AppleIDCodePrompt?
	let answer: (AppleIDSession.CodeAnswer?) -> Void
	@State private var code = ""

	init(prompt: AppleIDCodePrompt?, answer: @escaping (AppleIDSession.CodeAnswer?) -> Void) {
		self.prompt = prompt
		self.answer = answer
	}

	func body(content: Content) -> some View {
		// Every button answers, and an alert can't be dismissed otherwise.
		content.alert("Verification Code", isPresented: Binding(get: { prompt != nil }, set: { _ in }), presenting: prompt) { prompt in
			TextField("Code", text: $code)
				.keyboardType(.numberPad)
				.textContentType(.oneTimeCode)
			Button("Cancel", role: .cancel) { reply(nil) }
			// Apple didn't send one by itself: the user picks where it goes.
			if prompt.request.unknown {
				Button("Send to My Devices") { reply(.devices) }
				if let number = prompt.request.numbers.first {
					Button("Text \(number.number)") { reply(.sms(number.id)) }
				}
			}
			Button("Submit") { reply(.code(code.filter(\.isNumber))) }
		} message: { prompt in
			Text(Self.message(for: prompt))
		}
	}

	private func reply(_ answer: AppleIDSession.CodeAnswer?) {
		self.answer(answer)
		code = ""
	}

	private static func message(for prompt: AppleIDCodePrompt) -> String {
		let request = prompt.request
		var text = ""
		if let lastError = request.lastError, !lastError.isEmpty {
			text += "\(lastError)\n\n"
		}
		if let purpose = prompt.purpose {
			text += "\(purpose) "
		}
		if request.unknown {
			text += "Apple didn't send a code by itself. Have it sent to your devices or by text, then enter it."
		} else if request.sms {
			text += prompt.purpose == nil ? "Enter the code Apple texted to your trusted phone number." : "Enter the one Apple texted to your trusted phone number."
		} else {
			text += prompt.purpose == nil ? "Enter the code shown on your other devices." : "Enter the one shown on your other devices."
		}
		return text
	}
}

// MARK: Choose a Team

/// For an Apple ID in more than one team, before the certificate.
private struct ChooseTeam: View {
	let signIn: AppleIDSignIn
	let teams: [AppleIDSession.Team]
	@State var picked: AppleIDSession.Team
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		Form {
			Section {
				ForEach(teams, id: \.id) { team in
					Button {
						picked = team
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 3) {
								Text(team.title)
									.foregroundStyle(.primary)
								Text(team.detail)
									.font(.footnote)
									.foregroundStyle(.secondary)
							}
							Spacer()
							if team.id == picked.id {
								Image(systemName: "checkmark")
									.font(.body.weight(.semibold))
									.foregroundStyle(.tint)
							}
						}
					}
				}
			} footer: {
				Text("\(signIn.email) is in more than one team. Atelier makes its certificate and your apps’ profiles in the one you choose.")
			}
		}
		.navigationTitle("Choose a Team")
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel", systemImage: "xmark") { certificates.endSignIn() }
			}
			ToolbarItem(placement: .confirmationAction) {
				Button("Continue") { signIn.choose(picked) }
			}
		}
	}
}

extension AppleIDSession.Team {
	/// "Personal Team", as Xcode calls a free Apple ID's, or the team's name.
	var title: String {
		isFree == true ? "Personal Team" : name ?? id
	}

	/// "Apple Developer Program, Q1W2E3R4T5", or "Free, A1B2C3D4E5".
	var detail: String {
		switch isFree {
		case true?: "Free, \(id)"
		case false?: "\(memberships.first(where: { !$0.localizedCaseInsensitiveContains("free") }) ?? "Apple Developer Program"), \(id)"
		case nil: id
		}
	}
}

// MARK: Revoke a Certificate?

/// At Apple's limit: the team's development certificates, named after the
/// app or Mac each was made for. Atelier's own made elsewhere is picked to
/// start with, as its key isn't on this iPhone. Revoke and Continue asks
/// once more. The one the Atelier that runs is signed with says so (#152),
/// and is never picked to start with: revoking it makes Atelier sign itself
/// again right after, with the one it makes. When Apple still counts one
/// just revoked, it comes again as Revoke Another?, saying why.
private struct RevokeCertificate: View {
	let signIn: AppleIDSignIn
	let email: String
	let listed: [AppleIDSession.Certificate]
	/// Those revoked in this sign-in, which Apple still counts.
	let revoked: [AppleIDSession.Certificate]
	@State private var picked: AppleIDSession.Certificate.ID?
	@State private var confirming: AppleIDSession.Certificate?
	@Environment(CertificatesModel.self) private var certificates

	init(signIn: AppleIDSignIn, email: String, listed: [AppleIDSession.Certificate], revoked: [AppleIDSession.Certificate]) {
		self.signIn = signIn
		self.email = email
		self.listed = listed
		self.revoked = revoked
		// isideload found none whose key is here, so Atelier's are all from
		// elsewhere.
		_picked = State(initialValue: listed.first { Self.isAteliers($0) && $0.serialNumber != nil && !Self.signsThisAtelier($0) }?.id)
	}

	private static func isAteliers(_ certificate: AppleIDSession.Certificate) -> Bool {
		certificate.machineName == AppleIDSignIn.machineName
	}

	/// Whether the Atelier that runs is signed with it (#152), as when the
	/// tool that installed Atelier made it.
	private static func signsThisAtelier(_ certificate: AppleIDSession.Certificate) -> Bool {
		guard let signer = SelfUpdate.shared.signature.certificate?.serialNumber else { return false }
		if let content = certificate.content { return content.serialNumber == signer }
		guard let serial = certificate.serialNumber else { return false }
		// Apple's list may pad it with zeros.
		return serial.uppercased().drop(while: { $0 == "0" }) == signer.uppercased().drop(while: { $0 == "0" })
	}

	private let dates = Date.FormatStyle.dateTime.day().month().year()

	var body: some View {
		let selected = listed.first { $0.id == picked }
		Form {
			Section {
				SheetHeading(
					title: revoked.isEmpty ? "Revoke a Certificate?" : "Revoke Another?",
					text: revoked.isEmpty
						? "\(email) has as many development certificates as Apple allows. Atelier can make its own once one is revoked."
						: Self.stillCounted(revoked),
					tile: AnyView(WarningTile())
				)
			}

			Section {
				ForEach(listed) { certificate in
					Button {
						picked = certificate.id
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 3) {
								Text(Self.name(of: certificate))
									.foregroundStyle(.primary)
								if let text = line(for: certificate) {
									Text(text)
										.font(.footnote)
										.foregroundStyle(.secondary)
								}
							}
							Spacer()
							if certificate.id == picked {
								Image(systemName: "checkmark")
									.font(.body.weight(.semibold))
									.foregroundStyle(.tint)
							}
						}
					}
					.disabled(certificate.serialNumber == nil)
				}
			} header: {
				Text("Development certificates")
			} footer: {
				Text("Apps signed with it stop opening, whichever app installed them, until that app signs them again.")
			}

			Section {
				Button {
					confirming = selected
				} label: {
					Text("Revoke and Continue")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.tint(.red)
				.controlSize(.large)
				.disabled(selected == nil)
				.listRowBackground(Color.clear)
				.listRowInsets(EdgeInsets())
			}
		}
		.navigationTitle("Revoke")
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel", systemImage: "xmark") { certificates.endSignIn() }
			}
		}
		.confirmationDialog(
			confirming.map { "Revoke “\(Self.name(of: $0))”?" } ?? "",
			isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
			titleVisibility: .visible,
			presenting: confirming
		) { certificate in
			Button("Revoke", role: .destructive) { signIn.revoke(certificate) }
		} message: { certificate in
			let text = "Apps signed with it stop opening, whichever app installed them, until that app signs them again."
			Text(Self.signsThisAtelier(certificate)
				? "\(text) \(SelfUpdate.shared.name) itself is signed with it, so it signs itself again right after, with its own, and asks you to go to the Home Screen."
				: text)
		}
	}

	private static func name(of certificate: AppleIDSession.Certificate) -> String {
		certificate.machineName ?? certificate.name ?? "Development certificate"
	}

	/// "Apple still counts SideStore’s certificate, though it no longer
	/// lists it. Waiting for Apple hasn’t freed its place before, but
	/// revoking another one has."
	private static func stillCounted(_ revoked: [AppleIDSession.Certificate]) -> String {
		guard revoked.count == 1 else {
			return "Apple still counts the certificates you revoked, though it no longer lists them. Waiting for Apple hasn’t freed their places before, but revoking another one has."
		}
		let which = revoked[0].machineName.map { "\($0)’s certificate" } ?? "the certificate you revoked"
		return "Apple still counts \(which), though it no longer lists it. Waiting for Apple hasn’t freed its place before, but revoking another one has."
	}

	/// "Made 30 Oct 2026. Its key isn’t on this iPhone."
	private func line(for certificate: AppleIDSession.Certificate) -> String? {
		var when: String?
		if let made = certificate.made {
			when = "Made \(made.formatted(dates))"
		} else if let expires = certificate.expires {
			when = "Expires \(expires.formatted(dates))"
		}
		// "Made 11 Nov 2026. This Atelier is signed with it."
		if Self.signsThisAtelier(certificate) {
			let signs = "This \(SelfUpdate.shared.name) is signed with it."
			return when.map { "\($0). \(signs)" } ?? signs
		}
		guard Self.isAteliers(certificate) else { return when }
		let key = "Its key isn’t on this \(ThisDevice.name)."
		return when.map { "\($0). \(key)" } ?? key
	}
}

/// An orange tile with a seal and an exclamation mark.
private struct WarningTile: View {
	var body: some View {
		RoundedRectangle(cornerRadius: 60 * 0.26, style: .continuous)
			.fill(LinearGradient(colors: [Color.orange.opacity(0.75), Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing))
			.frame(width: 60, height: 60)
			.overlay {
				ZStack {
					Image(systemName: "seal.fill")
						.font(.system(size: 30, weight: .semibold))
						.foregroundStyle(.white)
					Image(systemName: "exclamationmark")
						.font(.system(size: 15, weight: .heavy))
						.foregroundStyle(.orange)
				}
			}
			.shadow(color: Color.orange.opacity(0.3), radius: 5, y: 2)
			.accessibilityHidden(true)
	}
}

// MARK: You're Signed In

/// What Atelier made, and what the Apple ID allows.
private struct SignedInPage: View {
	let done: AppleIDSignIn.Done
	@Environment(CertificatesModel.self) private var certificates

	var body: some View {
		let account = done.account
		let dates = Date.FormatStyle.dateTime.day().month().year()
		Form {
			Section {
				VStack(spacing: 6) {
					Text("You’re Signed In")
						.font(.title2.weight(.bold))
					Text(account.email)
						.font(.subheadline)
						.foregroundStyle(.secondary)
					// Atelier signed in by itself after the installer (#152).
					if done.byInstaller {
						Text("\(SelfUpdate.shared.name) signed in with the Apple ID the installer used, so it’s ready to install your apps.")
							.font(.subheadline)
							.multilineTextAlignment(.center)
							.padding(.top, 4)
					}
				}
				.frame(maxWidth: .infinity)
				.listRowBackground(Color.clear)
			}

			Section {
				Made(title: "Team", value: account.team.title, detail: account.team.detail)
				certificateRow(until: account.expiresAt.formatted(dates))
				Made(title: "This \(ThisDevice.name)", value: "Registered", detail: "With the UDID the setup read")
			}

			// The Apple ID that installed Atelier itself (#152).
			if SelfUpdate.shared.appleID(in: certificates)?.id == account.id {
				let name = SelfUpdate.shared.name
				Section {
					VStack(alignment: .leading, spacing: 4) {
						Text("\(name) is one of its apps")
							.font(.headline)
						Text(account.isFree
							? "This Apple ID installed \(name), so \(name) now renews itself every week and signs its own updates with it. It holds one of the \(FreeAppleID.appsPerDevice) places on this \(ThisDevice.name)."
							: "This Apple ID installed \(name), so \(name) now renews itself before its profile ends and signs its own updates with it.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.vertical, 2)
				}
			}

			switch account.team.isFree {
			case true?:
				Section("A free Apple ID") {
					Allowance(badge: "3", lead: "3 apps at a time", rest: " on this \(ThisDevice.name). A fourth needs one of them deleted first.")
					Allowance(badge: "10", lead: "10 new apps allowed a week.", rest: " Each app’s first install takes one; updates don’t.")
					Allowance(badge: "7d", lead: "Profiles last 7 days,", rest: " and Atelier renews them every week, without reinstalling.")
				}
			case false?:
				Section("Apple Developer Program") {
					Allowance(badge: "1y", lead: "Profiles last a year,", rest: " with no limit on how many apps.")
				}
			case nil:
				EmptyView()
			}

			if !done.inUse {
				Section {
					Button {
						certificates.makeDefault(account.id)
						certificates.endSignIn()
					} label: {
						Text("Use for Installs")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets())
				} footer: {
					if let other = done.otherInUse {
						Text("\(other) stays in use until you choose this one.")
					}
				}
			}
		}
		.navigationTitle("Signed In")
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				Button("Done") { certificates.endSignIn() }
			}
		}
	}
}

extension SignedInPage {
	/// Where the certificate came from (#152): Apple made it now, an earlier
	/// sign-in did, or the installer.
	fileprivate func certificateRow(until: String) -> Made {
		switch done.source {
		case .made: Made(title: "Certificate", value: "Made", detail: "On this \(ThisDevice.name), valid until \(until)")
		case .found: Made(title: "Certificate", value: "Found", detail: "Made at an earlier sign-in, valid until \(until)")
		case .installer: Made(title: "Certificate", value: "From the installer", detail: "The one it installed \(SelfUpdate.shared.name) with, valid until \(until)")
		}
	}
}

/// One of the things the sign-in made: a tick, what, and how.
private struct Made: View {
	let title: String
	let value: String
	let detail: String

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Image(systemName: "checkmark.circle.fill")
				.foregroundStyle(.white, .green)
			VStack(alignment: .leading, spacing: 2) {
				HStack {
					Text(title)
					Spacer()
					Text(value)
						.foregroundStyle(.secondary)
				}
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
	}
}

/// What a team allows: a badge with the number, then what it means.
private struct Allowance: View {
	let badge: String
	let lead: String
	let rest: String

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Text(badge)
				.font(.subheadline.weight(.bold))
				.foregroundStyle(.blue)
				.frame(width: 30, height: 30)
				.background(Color.blue.opacity(0.12), in: .rect(cornerRadius: 7))
			Text("\(Text(lead).bold())\(rest)")
				.font(.subheadline)
		}
		.padding(.vertical, 2)
	}
}
