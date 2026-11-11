import Foundation
#if canImport(Zsign)
import Zsign
#endif

/// Signs with zsign through Feather's Zsign package, the same call Feather's
/// ZsignHandler makes.
struct ZsignEngine: SigningEngine {
	func sign(app: URL, identity: SigningIdentity, options: SigningOptions) throws {
		#if canImport(Zsign)
		// zsign calls the completion only once it has loaded the certificate,
		// so a failure without it means the certificate was the problem.
		var finished: Bool?
		let signed = Zsign.sign(
			appPath: app.path,
			provisionPath: identity.profile.path,
			p12Path: identity.p12.path,
			p12Password: identity.password,
			entitlementsPath: options.entitlements?.path ?? "",
			// IPASigner renames the app itself (#8, BundleIDRewriter).
			customIdentifier: "",
			customName: options.displayName ?? "",
			customVersion: options.version ?? "",
			adhoc: false,
			// Keep the profile in the app as embedded.mobileprovision, which
			// development and ad hoc installs need. (Before our fork's fix,
			// zsign never kept it, whatever this said.)
			removeProvision: false,
			completion: { finished = $0 }
		)
		guard signed else {
			throw finished == nil ? SigningError.badCertificate : SigningError.signingFailed
		}
		// zsign reports success even when it couldn't build the CMS signature.
		// For the main executable that's the certificate; for anything else,
		// a file zsign skipped.
		for (index, binary) in try IPASigner.binaries(in: app).enumerated() where try !MachO.hasCMSSignature(binary) {
			guard index > 0 else { throw SigningError.unsupportedCertificate }
			throw SigningError.unsignedBinary(String(binary.path.dropFirst(app.path.count + 1)))
		}
		#else
		throw SigningError.unsupportedPlatform
		#endif
	}

	func load(_ path: String, into executable: URL) -> Bool {
		#if canImport(Zsign)
		// True as well when it loads it already, from an earlier signing.
		Zsign.injectDyLib(appExecutable: executable.path, with: path, weak: true)
		#else
		false
		#endif
	}
}
