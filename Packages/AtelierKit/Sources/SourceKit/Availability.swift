import Foundation

/// What a version's `downloadURL` points at.
public enum DownloadKind: Equatable, Sendable {
	/// An IPA, which Atelier can sign and install (AltStore Classic).
	case ipa
	/// An Apple Alternative Distribution Package (AltStore PAL). Only Apple's
	/// marketplace system can install those, so Atelier can't.
	case alternativeDistributionPackage
	/// A file attached to a Patreon post, which AltStore downloads through
	/// the user's Patreon login. Atelier has no Patreon login.
	case patreon
}

extension AppVersion {
	/// What `downloadURL` points at, judged from the listing alone.
	///
	/// The spec has an ADP's URL point at its `manifest.json` or at its root
	/// directory, optionally with `assetURLs`. Anything else is taken to be an
	/// IPA, including URLs without an `.ipa` extension (download scripts,
	/// redirects): the download itself shows whether it is one.
	public var downloadKind: DownloadKind {
		downloadKind(marketplaceID: nil)
	}

	func downloadKind(marketplaceID: String?) -> DownloadKind {
		let path = downloadURL.path.lowercased()
		let host = downloadURL.host?.lowercased() ?? ""
		if !assetURLs.isEmpty || path.hasSuffix("/manifest.json") || downloadURL.absoluteString.hasSuffix("/") {
			return .alternativeDistributionPackage
		}
		if host == "patreon.com" || host.hasSuffix(".patreon.com") {
			return .patreon
		}
		// A notarized app's URL that doesn't name an IPA is an ADP directory
		// written without its trailing slash.
		if marketplaceID != nil, !path.hasSuffix(".ipa") {
			return .alternativeDistributionPackage
		}
		return .ipa
	}
}

/// Whether Atelier can install an app on this device, and which version.
public enum AppAvailability: Equatable, Sendable {
	case installable(AppVersion)
	case notInstallable(NotInstallableReason)

	public var version: AppVersion? {
		if case .installable(let version) = self { return version }
		return nil
	}
}

public enum NotInstallableReason: Equatable, Sendable {
	/// An AltStore PAL app: its versions are Alternative Distribution Packages.
	case alternativeDistributionOnly
	/// A Patreon-only app whose downloads need a Patreon login.
	case patreonOnly
	/// No version supports this iOS version. Carries the latest version's
	/// limits, so the app can say what it needs.
	case unsupportedOS(min: OSVersion?, max: OSVersion?)

	/// For the app's detail screen.
	public var message: String {
		switch self {
		case .alternativeDistributionOnly:
			"Not installable with Atelier. This app is distributed through AltStore PAL, which only Apple's marketplace system can install."
		case .patreonOnly:
			"Not installable with Atelier. This app is only available to the developer's patrons through AltStore."
		case .unsupportedOS(let min?, _):
			"Requires iOS \(min) or later."
		case .unsupportedOS(nil, let max?):
			"Requires iOS \(max) or earlier."
		case .unsupportedOS(nil, nil):
			"No version supports this iOS version."
		}
	}
}

extension SourceApp {
	/// The newest version Atelier can install on `os`, or why there is none.
	///
	/// PAL apps are reported as not installable rather than hidden, so the
	/// user sees why an app they know from AltStore can't be installed.
	public func availability(on os: OSVersion = .current) -> AppAvailability {
		let installable = versions.filter { downloadKind(of: $0) == .ipa }
		guard !installable.isEmpty else {
			let kinds = Set(versions.map(downloadKind(of:)))
			if kinds.contains(.alternativeDistributionPackage) { return .notInstallable(.alternativeDistributionOnly) }
			if kinds.contains(.patreon) { return .notInstallable(.patreonOnly) }
			return .notInstallable(.unsupportedOS(min: nil, max: nil))
		}
		if let version = installable.first(where: { $0.supports(os) }) {
			return .installable(version)
		}
		let latest = installable[0]
		return .notInstallable(.unsupportedOS(min: latest.minOSVersion, max: latest.maxOSVersion))
	}

	/// What a version's `downloadURL` points at, taking the app's
	/// `marketplaceID` into account.
	public func downloadKind(of version: AppVersion) -> DownloadKind {
		version.downloadKind(marketplaceID: marketplaceID)
	}
}
