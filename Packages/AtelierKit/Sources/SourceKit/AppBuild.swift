import Foundation

/// One of several builds of an app version, as a GitHub release can carry
/// (#30): written by Atelier under the `atelierBuilds` key of a version,
/// which other AltStore source readers ignore.
public struct AppBuild: Equatable, Sendable, Identifiable {
	/// The file name, such as `Feather-debug.ipa`.
	public var name: String
	public var downloadURL: URL
	public var size: Int64?
	public var minOSVersion: OSVersion?
	/// Its name marks a build most people don't want (debug, no extensions).
	public var isSpecial: Bool

	/// Words in a file name that mark a build most people don't want.
	public static let specialWords = ["debug", "noext", "noextension", "dev", "test", "beta", "nightly"]

	/// The word in `fileName` that marks it as a special build.
	public static func specialWord(in fileName: String) -> String? {
		let words = fileName.lowercased().split { !$0.isLetter }.map(String.init)
		return words.first { specialWords.contains($0) }
	}

	public var id: URL { downloadURL }

	public init(name: String, downloadURL: URL, size: Int64? = nil, minOSVersion: OSVersion? = nil, isSpecial: Bool = false) {
		self.name = name
		self.downloadURL = downloadURL
		self.size = size
		self.minOSVersion = minOSVersion
		self.isSpecial = isSpecial
	}

	/// What sets it apart, for the choice: "requires iOS 28", "debug build".
	public func note(on os: OSVersion = .current) -> String? {
		if let minOSVersion, os < minOSVersion { return "requires iOS \(minOSVersion)" }
		guard isSpecial else { return nil }
		return "\(Self.specialWord(in: name) ?? "special") build"
	}

	/// A file name without numbers, versions and its extension, so the same
	/// build in another release has the same kind: `Feather_v2.9.0.ipa` and
	/// `Feather_v2.8.1.ipa` match, `Feather-debug.ipa` doesn't.
	public static func kind(of fileName: String) -> String {
		var name = fileName.lowercased()
		if name.hasSuffix(".ipa") { name = String(name.dropLast(4)) }
		name = name.replacingOccurrences(of: #"v?\d+"#, with: "", options: .regularExpression)
		name = name.replacingOccurrences(of: #"[\s._\-+()]+"#, with: "", options: .regularExpression)
		return name
	}

	public var kind: String { Self.kind(of: name) }
}

extension AppVersion {
	/// Whether the user has a build to choose.
	public var hasBuildChoice: Bool { builds.count > 1 }

	/// The build to suggest: one this device can run, not a special build,
	/// then the largest.
	public func recommendedBuild(on os: OSVersion = .current) -> AppBuild? {
		builds.max { a, b in
			let aRuns = a.minOSVersion.map { os >= $0 } ?? true, bRuns = b.minOSVersion.map { os >= $0 } ?? true
			if aRuns != bRuns { return !aRuns }
			if a.isSpecial != b.isSpecial { return a.isSpecial }
			return (a.size ?? 0) < (b.size ?? 0)
		}
	}

	/// The build of the kind the user chose before, or the recommended one.
	public func build(ofKind kind: String?, on os: OSVersion = .current) -> AppBuild? {
		if let kind, let chosen = builds.first(where: { $0.kind == kind }) { return chosen }
		return recommendedBuild(on: os)
	}

	/// This version downloading the IPA at `url`, when that's its own or one
	/// of its builds': as a link to that IPA installs it (#93).
	public func downloading(_ url: URL) -> AppVersion? {
		if downloadURL == url { return self }
		return builds.first { $0.downloadURL == url }.map(using)
	}

	/// This version downloading `build` instead.
	public func using(_ build: AppBuild) -> AppVersion {
		var version = self
		version.downloadURL = build.downloadURL
		version.size = build.size
		version.minOSVersion = build.minOSVersion ?? minOSVersion
		version.sha256 = nil
		return version
	}
}
