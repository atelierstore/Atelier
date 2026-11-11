import Foundation
import GitHubKit
import AtelierCore
import SourceKit
import SwiftData

/// Include Pre-releases (#104): each source's switch, AltStore source or
/// GitHub repo, for whether its betas are listed.
enum Prereleases {
	static let preferences = PrereleasePreferences()

	/// Set once the sources added before every source had the switch have
	/// theirs.
	private static let adoptedKey = "prereleases.adopted"

	/// Once, as every source gets the switch (#104): a GitHub repo keeps
	/// the setting it had, and an AltStore source that lists betas goes on
	/// listing them, as Atelier's own does, so nothing disappears with the
	/// update.
	@MainActor
	static func adopt(_ context: ModelContext) {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: adoptedKey) else { return }
		let records = (try? context.fetch(FetchDescriptor<SourceRecord>())) ?? []
		for record in records {
			if let repo = GitHubRepo(sourceURL: record.url) {
				// Where #30 kept a repo's switch.
				let gitHubKey = "github.prereleases.\(repo)"
				preferences.set(defaults.bool(forKey: gitHubKey), for: record.url)
				defaults.removeObject(forKey: gitHubKey)
			} else if record.isBuiltIn || (try? record.parsed())?.listsPrereleases == true {
				preferences.set(true, for: record.url)
			}
		}
		defaults.set(true, forKey: adoptedKey)
	}
}
