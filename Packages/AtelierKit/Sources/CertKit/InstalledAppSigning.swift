import Foundation
import InstallKit

/// Which certificate signs an app over the one already on this iPhone
/// (#99). iOS only replaces an app with one signed for the same App ID
/// (Apple's TN2319): installd refuses any other with
/// "MismatchedApplicationIdentifierEntitlement", after the download, the
/// signing and the upload. A certificate's profile decides the App ID it
/// signs for, so before any of that, Direct installs read installd's record
/// of the installed app (`InstalledAppRecord`) and match its App ID to the
/// profiles of Atelier's certificates.
public enum InstalledAppSigning: Equatable, Sendable {
	/// Nothing in the way: the same App ID, or a record that doesn't give one.
	case proceed
	/// Sign with this certificate instead: its profile is for the App ID
	/// the app was installed with, so iOS replaces the app, which keeps its
	/// data.
	case switchTo(StoredCertificate)
	/// No certificate Atelier can sign with is for that App ID.
	case conflict(InstalledConflict)

	/// What to do about `installed`, the app on this iPhone under the bundle
	/// ID the install signs `appName` as, when it signs with `certificate`.
	/// `certificates` are Atelier's, in the order to try them: the default
	/// first. With `picked`, the user picked `certificate`, as in Sign Again
	/// With, so no other signs instead.
	public static func decide(
		installed: InstalledAppRecord,
		appName: String,
		certificate: StoredCertificate,
		certificates: [StoredCertificate],
		picked: Bool,
		now: Date = .now
	) -> InstalledAppSigning {
		guard let appID = installed.applicationIdentifier, appID != certificate.profile.applicationIdentifier else { return .proceed }
		let forAppID = certificates.filter { $0.profile.applicationIdentifier == appID }
		let signer: InstalledConflict.Signer
		if let usable = forAppID.first(where: { $0.expiresAt > now && !$0.isRevoked }) {
			guard picked else { return .switchTo(usable) }
			signer = .notPicked(usable.displayName, picked: certificate.displayName)
		} else if let dead = forAppID.first {
			// As a certificate's badge says it: revoked before expired.
			signer = dead.isRevoked ? .revoked(dead.displayName) : .expired(dead.displayName, on: dead.expiresAt)
		} else {
			switch installed.origin {
			case .appStore?: signer = .appStore
			case .testFlight?: signer = .testFlight
			case .marketplace?: signer = .marketplace
			case .certificate(let name)?: signer = .certificate(name)
			case nil: signer = .unknown
			}
		}
		let name = installed.displayName
		return .conflict(InstalledConflict(
			installedName: name.isEmpty ? appName : name,
			appName: appName,
			bundleID: installed.bundleID,
			signer: signer,
			keepsData: installed.dataOpens
		))
	}

	/// What to do about an app iOS refused to replace although installd
	/// lists none under the bundle ID, `bundleID`, which only iOS's refusal
	/// names, by the App ID it was installed for, `appID`. In #99's test,
	/// AltStore Classic, offloaded, was in none of installd's lists, asked
	/// six ways; iOS doesn't say why it lists none, so other causes can't be
	/// ruled out. `installedName` is the name to give it, as it's nowhere to
	/// read: the IPA's own.
	public static func decideUnlisted(
		appID: String,
		bundleID: String,
		installedName: String,
		appName: String,
		certificate: StoredCertificate,
		certificates: [StoredCertificate],
		now: Date = .now
	) -> InstalledAppSigning {
		guard appID != certificate.profile.applicationIdentifier else { return .proceed }
		// Install with Another Certificate offers it, as for any refusal.
		if let usable = certificates.first(where: { $0.profile.applicationIdentifier == appID && $0.expiresAt > now && !$0.isRevoked }) {
			return .switchTo(usable)
		}
		// With no record of the app, Atelier can't tell whether iOS would
		// let it copy its data aside.
		return .conflict(InstalledConflict(
			installedName: installedName.isEmpty ? appName : installedName,
			appName: appName,
			bundleID: bundleID,
			signer: .unlisted,
			keepsData: false
		))
	}
}

/// An app on this iPhone that iOS won't replace with the one being
/// installed (#99), and what can be done about it: the alert before an
/// install asks, and an install iOS refused says it.
public struct InstalledConflict: Equatable, Sendable {
	/// Who signed the installed app, as far as it stops the install.
	public enum Signer: Equatable, Sendable {
		case appStore
		case testFlight
		/// Apple's signature without an Apple Account: an alternative app
		/// marketplace, such as AltStore PAL, or a developer's website.
		case marketplace
		/// A certificate that isn't in Atelier, named as iOS names it, such
		/// as "Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)".
		case certificate(String)
		/// One of Atelier's certificates, by its name there, which has
		/// expired.
		case expired(String, on: Date)
		/// One of Atelier's certificates, which Apple revoked.
		case revoked(String)
		/// One of Atelier's certificates, but not `picked`, the one the
		/// user picked to sign with.
		case notPicked(String, picked: String)
		/// installd's record names no signer.
		case unknown
		/// installd lists no app under the bundle ID, yet iOS refused to
		/// replace one, naming only the App ID it was installed for: an
		/// offloaded app in #99's test, though iOS doesn't say why.
		case unlisted
	}

	/// The installed app's name, as iOS has it.
	public var installedName: String
	/// The name of the app being installed.
	public var appName: String
	/// The bundle ID both have.
	public var bundleID: String
	public var signer: Signer
	/// Whether deleting the installed app to install this one keeps its
	/// data: iOS lets Atelier copy it aside (#96).
	public var keepsData: Bool

	public init(installedName: String, appName: String, bundleID: String, signer: Signer, keepsData: Bool) {
		self.installedName = installedName
		self.appName = appName
		self.bundleID = bundleID
		self.signer = signer
		self.keepsData = keepsData
	}

	/// Whether importing a certificate would do: the one the app was signed
	/// with, or a new one for its App ID.
	public var canImport: Bool {
		switch signer {
		case .certificate, .expired, .revoked: true
		case .appStore, .testFlight, .marketplace, .notPicked, .unknown, .unlisted: false
		}
	}

	/// The alert's title: that the app is already there, rather than what
	/// iOS checks (5 Nov 2026).
	public var title: String {
		"\(installedName) is already on this \(ThisDevice.name)"
	}

	/// What the alert before an install says: where the app on this iPhone
	/// came from, then what the user can do.
	public var question: String {
		let second = "a second \(appName) next to it"
		switch signer {
		case .appStore, .testFlight, .marketplace:
			return "It's from \(origin), so Atelier can't install over it. Install \(second), or \(deleteAndInstall)."
		case .certificate(let name):
			return "It was installed with “\(name)”, a certificate Atelier doesn't have, so Atelier can't install over it. Import that certificate, install \(second), or \(deleteAndInstall)."
		case .expired(let name, let date):
			return "It was installed with \(name), which expired on \(Self.day(date)), so Atelier can't install over it. Import a new certificate for it, install \(second), or \(deleteAndInstall)."
		case .revoked(let name):
			return "It was installed with \(name), which Apple revoked, so Atelier can't install over it. Import a new certificate for it, install \(second), or \(deleteAndInstall)."
		case .notPicked(let name, let picked):
			return "It was installed with \(name), so Atelier can't install over it with \(picked). Install \(second), or \(deleteAndInstall)."
		case .unknown:
			return "It was installed with a different certificate, so Atelier can't install over it. Install \(second), or \(deleteAndInstall)."
		case .unlisted:
			return "It's hidden from Atelier, maybe offloaded, and was installed with a different certificate, so Atelier can't install over it. Install \(second), or \(deleteAndInstall)."
		}
	}

	/// What an install that stopped over it says: before anything was
	/// downloaded, or once iOS refused it.
	public var failure: String {
		let installed = installedName == appName ? "the one" : "the \(installedName)"
		let what: String = switch signer {
		case .appStore, .testFlight, .marketplace: "is from \(origin)"
		case .certificate(let name): "was installed with “\(name)”, a certificate Atelier doesn't have"
		case .expired(let name, let date): "was installed with \(name), which expired on \(Self.day(date))"
		case .revoked(let name): "was installed with \(name), which Apple revoked"
		case .notPicked(let name, let picked): "was installed with \(name), not \(picked)"
		case .unknown: "was installed with a different certificate"
		case .unlisted: "is hidden from Atelier, maybe offloaded, and was installed with a different certificate"
		}
		return "\(appName) wasn't installed: \(installed) on this \(ThisDevice.name) \(what)."
	}

	/// The button that deletes the installed app and installs this one.
	public var deleteTitle: String {
		"Delete \(installedName) and Install"
	}

	/// What that button does with the installed app's data, under the
	/// buttons of an install that stopped. For an app iOS doesn't list, it
	/// first says so, naming no cause, as iOS gives none (#99).
	public var dataNote: String {
		if signer == .unlisted { return "iOS doesn't show this \(installedName) to Atelier. \(deleteTitle) deletes it and its data." }
		return keepsData
			? "\(deleteTitle) keeps its data. You may need to sign in to it again."
			: "\(deleteTitle) deletes its data."
	}

	private var origin: String {
		switch signer {
		case .appStore: "the App Store"
		case .testFlight: "TestFlight"
		default: "an alternative app marketplace"
		}
	}

	/// The end of the question, on deleting the installed app first.
	private var deleteAndInstall: String {
		guard keepsData else { return "delete it first, which erases its data" }
		let install = installedName == appName ? "delete it and install this one in its place" : "delete it and install \(appName) in its place"
		return "\(install), keeping its data (you may need to sign in again)"
	}

	private static func day(_ date: Date) -> String {
		date.formatted(date: .long, time: .omitted)
	}
}
