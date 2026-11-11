import Foundation
import SourceKit

/// Which build the user chose for an app whose versions come in several
/// builds, such as a GitHub release with a debug build next to the usual one
/// (#30). Kept by the build's kind (its file name without versions), so the
/// choice carries over to updates. Applied when the catalog is built, so
/// installs, updates and downloads all see the chosen build.
enum BuildChoices {
	private static let key = "buildChoices"

	private static func id(_ bundleID: String, _ sourceURL: URL) -> String {
		"\(sourceURL.absoluteString)|\(bundleID)"
	}

	/// Every choice, by source and bundle ID.
	static func all() -> [String: String] {
		UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
	}

	static func chosenKind(_ bundleID: String, sourceURL: URL) -> String? {
		all()[id(bundleID, sourceURL)]
	}

	static func choose(_ build: AppBuild, for bundleID: String, sourceURL: URL) {
		var choices = all()
		choices[id(bundleID, sourceURL)] = build.kind
		UserDefaults.standard.set(choices, forKey: key)
	}

	/// `source` with each version that has builds downloading the chosen
	/// one, or the recommended one when there's no choice yet.
	static func apply(_ choices: [String: String], to source: Source, at sourceURL: URL) -> Source {
		var source = source
		for index in source.apps.indices where source.apps[index].versions.contains(where: \.hasBuildChoice) {
			let kind = choices[id(source.apps[index].bundleID, sourceURL)]
			source.apps[index].versions = source.apps[index].versions.map { version in
				version.build(ofKind: kind).map(version.using) ?? version
			}
		}
		return source
	}
}
