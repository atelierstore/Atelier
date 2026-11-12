import CertKit
import Foundation

/// What an installed app's signature says besides its App ID
/// (`SignedAppIdentity`): the certificate it was signed with, and the App
/// Groups it asks for. Atelier reads its own (#152): installed with a free
/// Apple ID by another tool, it was signed with that tool's certificate,
/// and each new profile has to list that one and allow those groups for
/// Atelier to keep opening.
public struct AppSignature: Equatable, Sendable {
	/// The certificate it was signed with; nil when its signature can't be
	/// read, or carries none the profile is for.
	public var certificate: SigningCertificate?
	/// The App Groups its entitlements ask for.
	public var appGroups: [String]

	public init(certificate: SigningCertificate?, appGroups: [String]) {
		self.certificate = certificate
		self.appGroups = appGroups
	}

	/// Reads the app at `app`, an unpacked or installed `.app`. `profile`
	/// is the one it was installed with, which tells the signer from Apple's
	/// certificates above it.
	public static func read(app: URL, profile: ProvisioningProfile?) -> AppSignature {
		var signature = AppSignature(certificate: nil, appGroups: [])
		guard let executable = IPASigner.executable(of: app) else { return signature }
		if let cms = try? MachO.cmsSignature(executable) {
			signature.certificate = CodeSigner.signer(inCMS: cms, profile: profile)
		}
		if let data = try? MachO.entitlements(executable),
		   let entitlements = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
			signature.appGroups = entitlements[AppGroups.entitlement] as? [String] ?? []
		}
		return signature
	}
}
