import Foundation

/// Include Pre-releases, each source's switch (#104): off unless the user
/// turns it on, and kept outside the saved data, so sources need no schema
/// change. The same for an AltStore source and a GitHub repo.
public struct PrereleasePreferences: @unchecked Sendable {
	private let defaults: UserDefaults

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	private func key(_ url: URL) -> String { "prereleases.\(url.absoluteString)" }

	/// Whether the source at `url` lists its betas.
	public func includes(_ url: URL) -> Bool {
		defaults.bool(forKey: key(url))
	}

	public func set(_ include: Bool, for url: URL) {
		if include {
			defaults.set(true, forKey: key(url))
		} else {
			defaults.removeObject(forKey: key(url))
		}
	}
}

extension SourceApp {
	/// Whether `version` is a beta, which Include Pre-releases leaves out
	/// when it's off (#104), as the source marks it: the app is a beta, as
	/// AltStore's own source flags its beta apps, or the version is marked
	/// as one, as a GitHub repo's pre-release is. Never by its number
	/// (29 Oct 2026).
	public func isBeta(_ version: AppVersion) -> Bool {
		isBeta || version.isBeta
	}
}

extension Source {
	/// The source as it's listed with Include Pre-releases off (#104): its
	/// beta apps and beta versions left out, and an app left without
	/// versions with them.
	public func withoutPrereleases() -> Source {
		var source = self
		source.apps = apps.compactMap { app in
			guard !app.isBeta else { return nil }
			var listed = app
			listed.versions = app.versions.filter { !$0.isBeta }
			return listed.versions.isEmpty && !app.versions.isEmpty ? nil : listed
		}
		return source
	}

	/// The source as it's listed with Include Pre-releases on or off.
	public func listing(prereleases include: Bool) -> Source {
		include ? self : withoutPrereleases()
	}

	/// Whether it lists a beta, which Include Pre-releases decides on.
	public var listsPrereleases: Bool {
		apps.contains { app in app.isBeta || app.versions.contains(where: \.isBeta) }
	}

	/// Whether all it lists are betas: it's added with them included, as
	/// it would otherwise list nothing.
	public var listsOnlyPrereleases: Bool {
		!apps.isEmpty && withoutPrereleases().apps.isEmpty
	}
}
