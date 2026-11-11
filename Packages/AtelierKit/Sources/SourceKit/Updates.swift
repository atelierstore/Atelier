import Foundation

/// What Atelier knows about an installed build, for telling whether a
/// source's version is newer (#18).
public struct InstalledRelease: Equatable, Sendable {
	/// `CFBundleShortVersionString`.
	public var version: String
	/// `CFBundleVersion`; nil for installs recorded before it was kept.
	public var buildVersion: String?
	public var installedAt: Date
	/// A beta, as the source it came from marks it (#18, #104), as the
	/// Library's BETA tag says: never by its number (29 Oct 2026).
	public var isBeta: Bool

	public init(version: String, buildVersion: String? = nil, installedAt: Date, fromBetaListing: Bool = false) {
		self.version = version
		self.buildVersion = buildVersion
		self.installedAt = installedAt
		isBeta = fromBetaListing
	}

	/// As `listing`, the app it was installed from, has it: a beta when
	/// that's a beta app, or when it marks the installed build as a beta,
	/// such as a GitHub pre-release whose IPA has a plain version number
	/// (#104).
	public init(version: String, buildVersion: String? = nil, installedAt: Date, listing: SourceApp?) {
		self.init(version: version, buildVersion: buildVersion, installedAt: installedAt, fromBetaListing: listing?.isBeta ?? false)
		if !isBeta, let listing, UpdateCheck.installedEntry(self, in: listing)?.isBeta == true { isBeta = true }
	}
}

/// Whether a source offers a newer build of an installed app (#18).
///
/// Version numbers decide when both read as numbers ("1.10", "2.0b3"); a
/// source that bumps only the build number is caught by comparing build
/// numbers. Versions that don't read as numbers, such as "nightly-a1b2c3",
/// fall back to the source's dates, and then to the source's own order.
///
/// A source's betas are listed only while the user includes its
/// pre-releases (#104), so whatever it lists is offered, beta or release,
/// as the maintainer decided on 29 Oct 2026; the rule of 22 Oct that offered betas
/// only to betas went with it. The same check finds newer versions in
/// other sources, which are only ever suggested.
public enum UpdateCheck {
	/// The listing's newest version this device can run, when it's newer
	/// than the installed build and isn't the version the user skipped.
	public static func update(for installed: InstalledRelease, in app: SourceApp, skipping skipped: String? = nil, on os: OSVersion = .current) -> AppVersion? {
		guard let candidate = newest(in: app, on: os),
		      isNewer(candidate, than: installed, in: app) else { return nil }
		if let skipped, skipped == key(of: candidate) { return nil }
		return candidate
	}

	/// The listing's versions older than the installed build that `os` can
	/// run, in the source's order, for Install Older Version (#78).
	public static func olderVersions(than installed: InstalledRelease, in app: SourceApp, on os: OSVersion = .current) -> [AppVersion] {
		let entry = installedEntry(installed, in: app)
		return app.versions.filter { version in
			app.downloadKind(of: version) == .ipa && version.supports(os)
				&& version != entry
				// Versions that aren't numbers are only ordered against the
				// installed build's own entry; without one, none is older.
				&& (entry != nil || VersionNumber.isNumeric(installed.version) && VersionNumber.isNumeric(version.version))
				&& !isNewer(version, than: installed, in: app)
		}
	}

	/// The newest installable version `os` can run.
	static func newest(in app: SourceApp, on os: OSVersion) -> AppVersion? {
		let eligible = app.versions.filter { version in
			app.downloadKind(of: version) == .ipa && version.supports(os)
		}
		// The source's first, unless a later one is a release of the same
		// version (sources sorted with `compareRelease` put 2.0b2 before 2.0).
		// Versions that aren't numbers keep the source's order.
		guard let first = eligible.first else { return nil }
		return eligible.dropFirst().reduce(first) { best, version in
			VersionNumber.isNumeric(version.version) && VersionNumber.isNumeric(best.version)
				&& compareNumeric(version.version, best.version) == .orderedDescending ? version : best
		}
	}

	/// Which of two listed versions is newer: as `compareNumeric` when both
	/// read as numbers, then by build number; else `compareRelease`.
	public static func compare(_ a: AppVersion, _ b: AppVersion) -> ComparisonResult {
		guard VersionNumber.isNumeric(a.version) && VersionNumber.isNumeric(b.version) else { return a.compareRelease(to: b) }
		let byVersion = compareNumeric(a.version, b.version)
		if byVersion != .orderedSame { return byVersion }
		if let x = a.buildVersion, let y = b.buildVersion { return VersionNumber.compare(x, y) }
		return .orderedSame
	}

	/// Whether a build is older than another, both as their Info.plists say
	/// (`CFBundleShortVersionString` and `CFBundleVersion`): by version when
	/// both read as numbers, then by build number. False when they can't be
	/// told apart. Atelier doesn't install an older build of itself, which
	/// may not read the data a newer one saved (#24).
	public static func isOlder(_ version: String, build: String?, than other: String, build otherBuild: String?) -> Bool {
		guard VersionNumber.isNumeric(version), VersionNumber.isNumeric(other) else { return false }
		switch compareNumeric(version, other) {
		case .orderedAscending: return true
		case .orderedDescending: return false
		case .orderedSame:
			guard let build, let otherBuild else { return false }
			return VersionNumber.compare(build, otherBuild) == .orderedAscending
		}
	}

	/// What Skip This Version records: the version, with its build number
	/// when there is one, so a new build of a skipped version shows again.
	public static func key(of version: AppVersion) -> String {
		version.buildVersion.map { "\(version.version) (\($0))" } ?? version.version
	}

	/// Whether `candidate` is newer than what's installed.
	public static func isNewer(_ candidate: AppVersion, than installed: InstalledRelease, in app: SourceApp) -> Bool {
		if VersionNumber.isNumeric(candidate.version) && VersionNumber.isNumeric(installed.version) {
			switch compareNumeric(candidate.version, installed.version) {
			case .orderedDescending: return true
			case .orderedAscending: return false
			case .orderedSame: return isNewerBuild(candidate, than: installed, in: app)
			}
		}
		if candidate.version == installed.version {
			return isNewerBuild(candidate, than: installed, in: app)
		}
		// Not comparable as numbers: by date, then by the source's order.
		let entry = installedEntry(installed, in: app)
		if let date = candidate.date, let installedDate = entry?.date {
			return date > installedDate
		}
		guard let entry, let entryIndex = app.versions.firstIndex(of: entry),
		      let candidateIndex = app.versions.firstIndex(of: candidate) else { return false }
		return candidateIndex < entryIndex
	}

	/// Compares versions that read as numbers, with a release newer than its
	/// own pre-releases: 2.0 is newer than 2.0b2, which `VersionNumber`
	/// alone would put the other way round ("0" before "0b2").
	static func compareNumeric(_ a: String, _ b: String) -> ComparisonResult {
		let (baseA, preA) = VersionNumber.splitPrerelease(a)
		let (baseB, preB) = VersionNumber.splitPrerelease(b)
		let byBase = VersionNumber.compare(baseA, baseB)
		if byBase != .orderedSame { return byBase }
		switch (preA, preB) {
		case (nil, nil): return .orderedSame
		case (nil, _?): return .orderedDescending
		case (_?, nil): return .orderedAscending
		case let (x?, y?): return x.compare(y, options: [.numeric, .caseInsensitive])
		}
	}

	/// The same version: newer only by build number, or, when the installed
	/// build number wasn't recorded, when the source dates it after the
	/// install.
	private static func isNewerBuild(_ candidate: AppVersion, than installed: InstalledRelease, in app: SourceApp) -> Bool {
		guard let build = candidate.buildVersion else { return false }
		if let installedBuild = installed.buildVersion {
			return VersionNumber.compare(build, installedBuild) == .orderedDescending
		}
		// Installed before build numbers were kept: a listing of the same
		// version without a build number, or an older one, is what was
		// installed.
		guard let date = candidate.date else { return false }
		return date > installed.installedAt
	}

	/// The source's entry for the installed build, matched by version and,
	/// when both have one, build number. A GitHub pre-release whose IPA
	/// Atelier didn't read lists its tag as its version (#104), so an
	/// installed 0.6.3 is its 0.6.3-beta.
	public static func installedEntry(_ installed: InstalledRelease, in app: SourceApp) -> AppVersion? {
		let sameVersion = app.versions.filter { $0.version == installed.version }
		if let build = installed.buildVersion, let exact = sameVersion.first(where: { $0.buildVersion == build }) {
			return exact
		}
		return sameVersion.first ?? app.versions.first { version in
			version.isPrerelease && version.buildVersion == nil && isTag(version.version, of: installed.version)
		}
	}

	/// Whether `tag` is `version` and then what makes it a beta: 0.6.3-beta
	/// or 0.6.3b1 for 0.6.3, not 0.6.30-beta or 0.6.3.1-beta.
	static func isTag(_ tag: String, of version: String) -> Bool {
		guard !version.isEmpty, tag.hasPrefix(version) else { return false }
		let rest = tag.dropFirst(version.count)
		guard let next = rest.first, !next.isNumber else { return false }
		return !(next == "." && rest.dropFirst().first?.isNumber == true)
	}
}

extension VersionNumber {
	/// "2.0b3" → ("2.0", "b3"); "2.0" → ("2.0", nil).
	static func splitPrerelease(_ version: String) -> (base: String, tag: String?) {
		let trimmed = version.trimmingCharacters(in: .whitespaces)
		guard let range = trimmed.range(of: #"[-.]?(a|alpha|b|beta|rc|pre)[-.]?\d*$"#, options: [.regularExpression, .caseInsensitive]),
		      range.lowerBound > trimmed.startIndex else { return (trimmed, nil) }
		return (String(trimmed[..<range.lowerBound]), String(trimmed[range]))
	}

	/// Whether the version reads as numbers: digits separated by dots, with
	/// an optional pre-release tag, as in 1.10, 26.40.0 or 2.0b3.
	public static func isNumeric(_ version: String) -> Bool {
		version.trimmingCharacters(in: .whitespaces)
			.range(of: #"^\d+(\.\d+)*([-.]?(a|alpha|b|beta|rc|pre)[-.]?\d*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
	}
}
