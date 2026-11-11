import CertKit
import Foundation
import InstallKit

/// On-device IPA signing with zsign (#6).
///
/// A job unpacks the IPA's `Payload` into its own temporary folder, checks
/// the binaries, has zsign sign the app and everything nested in it (app
/// extensions, frameworks, dylibs, Watch apps), and packs the result into a
/// new IPA. The folder is deleted whether the job succeeds or fails.
///
/// Before signing, the app's entitlements are fitted to the profile (#7,
/// `EntitlementsReport`), and the signed IPA says what won't work. The app
/// keeps its bundle ID, as in Feather, unless `SigningOptions.target` is a
/// numbered copy of it (#8, `InstallTarget`).
public enum SigningKit {
	/// Signs `ipa` and writes the signed copy to `outputDirectory` (the
	/// temporary directory by default). The caller owns the returned file.
	///
	/// Jobs run one at a time, off the calling thread. Cancelling the task
	/// stops the job between files and throws `CancellationError`.
	public static func sign(
		ipa: URL,
		with identity: SigningIdentity,
		options: SigningOptions = SigningOptions(),
		outputDirectory: URL? = nil,
		progress: (@Sendable (SigningProgress) -> Void)? = nil
	) async throws -> SignedIPA {
		try await IPASigner().sign(ipa: ipa, with: identity, options: options, outputDirectory: outputDirectory, progress: progress)
	}

	/// Packs `app`, an installed or unpacked `.app`, into an IPA in
	/// `outputDirectory` (the temporary directory by default), stored rather
	/// than compressed: how Atelier signs itself again, from the app that's
	/// running (#24). The caller owns the returned file.
	public static func pack(app: URL, outputDirectory: URL? = nil) async throws -> URL {
		try await IPASigner().pack(app: app, outputDirectory: outputDirectory)
	}
}

/// The certificate and profile to sign with, as files zsign can read.
public struct SigningIdentity: Sendable {
	public var p12: URL
	public var profile: URL
	public var password: String

	public init(p12: URL, profile: URL, password: String) {
		self.p12 = p12
		self.profile = profile
		self.password = password
	}

	/// The identity of a certificate imported into `store` (#4).
	public init(_ certificate: StoredCertificate, in store: CertificateStore) throws {
		guard let password = try store.password(for: certificate.id) else {
			throw SigningError.badCertificate
		}
		self.init(p12: store.p12URL(for: certificate.id), profile: store.profileURL(for: certificate.id), password: password)
	}
}

public struct SigningOptions: Sendable {
	/// Which bundle ID the app is signed with (#8): its own, or a numbered
	/// copy's.
	public var target: InstallTarget
	/// Replaces the name on the home screen, in every language the app
	/// has (#113). Nil keeps it.
	public var displayName: String?
	/// Replaces both version strings. Nil keeps them.
	public var version: String?
	/// An entitlements plist to sign with, as it is. Nil signs with the
	/// profile's, fitted to the app when `fitsEntitlements` is on (#7).
	public var entitlements: URL?
	/// Signs with the app's own keychain groups, moved to the user's team,
	/// in place of the profile's `TEAMID.*` (`EntitlementsReport`). Off, the
	/// profile's entitlements are used as they are, as before #7.
	public var fitsEntitlements: Bool
	/// Stored by default, like Feather: iOS fetches the IPA from the same
	/// device, so compressing it only costs time.
	public var compressed: Bool
	/// The install check scheme to add to the app's Info.plist, so Atelier
	/// can tell that the install worked (`InstallCheck`, #11). Any check
	/// scheme the app already has is removed either way.
	public var installCheckScheme: String?
	/// The bundle ID to sign the app as, in place of `target`'s: Atelier's
	/// own update keeps the bundle ID Atelier was installed with, which
	/// another tool may have changed (#24). Extensions stay children of it.
	public var bundleID: String?
	/// Set in the app's Info.plist before signing, such as the token that
	/// tells Atelier on its next launch that it's the build its own update
	/// installed (#24).
	public var infoPlistValues: [String: String]
	/// A copy's own icon (#113), written into the app before signing. Nil
	/// keeps the app's.
	public var icon: IconChange?
	/// Drops the app's URL schemes (#113), as Feather's option does, so
	/// links open the app rather than the copy. The install check scheme
	/// is added after.
	public var removesURLSchemes: Bool
	/// The certificate a copy of Atelier comes with (#113), written into the
	/// app as `PackagedCertificate.fileName` before signing. Any the app has
	/// already is removed either way, so an IPA can't bring its own.
	public var packagedCertificate: PackagedCertificate?
	/// The names the Apple ID's team gives the app's App Groups, by the
	/// name the app asks for (#49, `AppGroups.names`): the profile allows
	/// these in their place, so its report says so.
	public var appGroups: [String: String]
	/// Atelier's library that sends the app's own names for its App Groups
	/// to `appGroups`' (#49, `AppGroupRedirect`), put in the app and loaded
	/// by it and its extensions when the profile allows any of them. Nil
	/// leaves the app's code as it is.
	public var appGroupsLibrary: URL?

	public init(
		target: InstallTarget = .original,
		displayName: String? = nil,
		version: String? = nil,
		entitlements: URL? = nil,
		fitsEntitlements: Bool = true,
		compressed: Bool = false,
		installCheckScheme: String? = nil,
		bundleID: String? = nil,
		infoPlistValues: [String: String] = [:],
		icon: IconChange? = nil,
		removesURLSchemes: Bool = false,
		packagedCertificate: PackagedCertificate? = nil,
		appGroups: [String: String] = [:],
		appGroupsLibrary: URL? = nil
	) {
		self.target = target
		self.displayName = displayName
		self.version = version
		self.entitlements = entitlements
		self.fitsEntitlements = fitsEntitlements
		self.compressed = compressed
		self.installCheckScheme = installCheckScheme
		self.bundleID = bundleID
		self.infoPlistValues = infoPlistValues
		self.icon = icon
		self.removesURLSchemes = removesURLSchemes
		self.packagedCertificate = packagedCertificate
		self.appGroups = appGroups
		self.appGroupsLibrary = appGroupsLibrary
	}
}

public enum SigningProgress: Equatable, Sendable {
	/// Fraction of the app's bytes unpacked.
	case unpacking(Double)
	/// zsign doesn't report progress.
	case signing
	/// Fraction of the app's bytes packed.
	case packing(Double)
}

/// A signed IPA, what its Info.plist says after signing, what it was
/// signed as, and what became of its entitlements.
public struct SignedIPA: Equatable, Sendable {
	public var url: URL
	public var info: IPAInfo
	/// Its bundle ID before and after signing, and the App ID it was signed
	/// for (#8).
	public var identity: SignedAppIdentity
	/// Nil when the profile couldn't be read for it.
	public var entitlements: EntitlementsReport?
	/// Whether `SigningOptions.icon` went into it: false when it had no
	/// picture, and the app no icon PNG to tint (#113).
	public var iconChanged: Bool

	public init(url: URL, info: IPAInfo, identity: SignedAppIdentity? = nil, entitlements: EntitlementsReport? = nil, iconChanged: Bool = false) {
		self.url = url
		self.info = info
		self.identity = identity ?? SignedAppIdentity(bundleID: info.bundleID, originalBundleID: info.bundleID, applicationIdentifier: nil, teamID: nil)
		self.entitlements = entitlements
		self.iconChanged = iconChanged
	}
}

public enum SigningError: Error, Equatable, CustomStringConvertible {
	/// zsign couldn't load the certificate: a wrong password, a .p12 that
	/// doesn't match the profile, or an unreadable file.
	case badCertificate
	/// Not a ZIP, a damaged one, or no `Payload/<App>.app` with an Info.plist.
	case corruptArchive(String)
	/// A bundle's executable is missing or isn't a Mach-O file. The path is
	/// relative to the .app.
	case unsupportedBinary(String)
	/// The binary is still encrypted by the App Store, so it can't run once
	/// re-signed. The path is relative to the .app.
	case encryptedBinary(String)
	/// Unpacking and repacking need about `needed` bytes.
	case outOfSpace(needed: Int64, available: Int64)
	/// zsign builds a real signature only for certificates issued by Apple's
	/// developer CAs it knows (WWDR G1 and G3); for any other, it leaves the
	/// code without one and still reports success.
	case unsupportedCertificate
	/// zsign signed the app but left this file, relative to the .app,
	/// without a signature.
	case unsignedBinary(String)
	/// zsign loaded the certificate but failed to sign the app.
	case signingFailed
	/// zsign only builds for Apple platforms.
	case unsupportedPlatform

	/// What the user is told, in their terms (5 Nov 2026): no zsign,
	/// and no paths inside the app, which `technical` keeps for the log.
	public var description: String {
		switch self {
		case .badCertificate:
			"Your certificate couldn't sign the app. Its password may be wrong, or its .p12 and profile don't belong together. Import it again."
		case .corruptArchive:
			"This file is damaged or isn't an app. Download it again, or try another file."
		case .unsupportedBinary(let path):
			"Part of this app (\(Self.part(path))) isn't made for \(ThisDevice.name), so Atelier can't sign it."
		case .encryptedBinary:
			"This IPA is still locked by the App Store, so it can't be signed. Look for a decrypted IPA of the app."
		case .outOfSpace(let needed, let available):
			"Signing this app needs about \(Self.megabytes(needed)) free, and only \(Self.megabytes(available)) is available."
		case .unsupportedCertificate:
			"Atelier can't sign with this certificate: Apple didn't issue it for signing apps. Import a development, ad hoc or enterprise certificate."
		case .unsignedBinary(let path):
			"Part of the app (\(Self.part(path))) couldn't be signed, so it wouldn't open. Try again."
		case .signingFailed:
			"The app couldn't be signed. Try again."
		case .unsupportedPlatform:
			"Signing isn't available on this platform."
		}
	}

	/// What went wrong in zsign's and the archive's terms, with paths
	/// inside the app, for the install log.
	public var technical: String? {
		switch self {
		case .badCertificate: "zsign couldn't load the certificate."
		case .corruptArchive(let why): "The IPA is damaged or isn't an app: \(why)."
		case .unsupportedBinary(let path): "\(path) isn't an iOS binary."
		case .encryptedBinary(let path): "\(path) is encrypted by the App Store."
		case .unsupportedCertificate: "zsign only signs with certificates issued by Apple's developer CAs (WWDR G1 or G3); it would have left the app unsigned."
		case .unsignedBinary(let path): "zsign signed the app but left \(path) unsigned."
		case .signingFailed: "zsign couldn't sign the app."
		case .outOfSpace, .unsupportedPlatform: nil
		}
	}

	/// The name of a part of the app from its path inside it: "Foo" for
	/// "Frameworks/Foo.framework/Foo".
	private static func part(_ path: String) -> String {
		path.split(separator: "/").last.map(String.init) ?? path
	}

	private static func megabytes(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
