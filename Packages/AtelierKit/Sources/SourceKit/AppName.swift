import Foundation

/// App names as Atelier shows them, and what makes two listings the same
/// app.
///
/// Many sources put the version in the name ("Alarmy_6.68.0+Satella",
/// "DuolingoMax_7.37.1") and list every version as its own app with the
/// same bundle ID. Atelier shows names without version numbers and treats
/// listings with the same bundle ID and the same cleaned name as one app,
/// whose versions are all of theirs. Listings that share a bundle ID but not
/// a name ("EeveeSpotify" and "Spotify") stay separate apps.
public enum AppName {
	/// `raw` without version numbers such as "6.68.0", "v1.4.1" or
	/// "1.0-b7", with underscores as spaces. The raw name when nothing but a
	/// version would be left.
	public static func clean(_ raw: String) -> String {
		var name = raw.replacingOccurrences(of: "_", with: " ")
		// Numbers glued to a word first, as in "YTM6.03.1".
		name = name.replacingOccurrences(of: #"(?<=[A-Za-z]{2})\d+(?:\.\d+)+"#, with: "", options: .regularExpression)
		name = name.replacingOccurrences(
			of: #"[\s\-]*\(?\b[vV]?\d+(?:\.\d+)+(?:[\-.]?(?:b|beta|rc|alpha)\d*)?\)?"#,
			with: " ",
			options: .regularExpression
		)
		// "v727", and "1 4 4-2" from "1_4_4-2".
		name = name.replacingOccurrences(of: #"\b[vV]\d+\b"#, with: " ", options: .regularExpression)
		name = name.replacingOccurrences(of: #"(?:\s+\d+){2,}(?:-\d+)?\s*$"#, with: "", options: .regularExpression)
		name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -+·|"))
		return name.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : name
	}

	/// Identifies an app: its bundle ID and its name, ignoring case and
	/// accents.
	public static func identity(bundleID: String, name: String) -> String {
		"\(bundleID)#\(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
	}

	/// The bundle ID in an app's `identity`: what comes before the #, which
	/// bundle IDs can't contain.
	public static func bundleID(ofIdentity identity: String) -> String {
		String(identity.prefix { $0 != "#" })
	}
}
