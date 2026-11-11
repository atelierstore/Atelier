import Foundation

/// What's typed in a search field, matched as Browse's search matches it
/// (#14): every word has to be in one of the fields, ignoring case and
/// accents. Every list with a search field matches this way (#124).
public struct SearchText: Sendable, Equatable {
	/// How well something matches, best first.
	public enum Rank: Int, Comparable, Sendable {
		/// Its name starts with what's typed.
		case namePrefix
		/// Its name has every word.
		case name
		/// The words are spread over its name and other fields.
		case other

		public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
	}

	/// The words typed, folded.
	public let words: [String]
	/// The words with one space between them, to compare with a name's
	/// start.
	private let whole: String

	public init(_ text: String) {
		words = Self.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
		whole = words.joined(separator: " ")
	}

	/// Nothing but spaces: there's nothing to search for, so a list shows
	/// everything.
	public var isEmpty: Bool { words.isEmpty }

	/// How well `name` and `others` match, or nil when some word is in none
	/// of them.
	public func rank(name: String, others: [String?]) -> Rank? {
		rank(foldedName: Self.fold(name), foldedOthers: others.compactMap { $0.map(Self.fold) })
	}

	/// Whether every word is in `name` or one of `others`.
	public func matches(name: String, others: [String?]) -> Bool {
		rank(name: name, others: others) != nil
	}

	/// `rank(name:others:)` for fields folded with `fold(_:)`, which lists
	/// that are searched often work out once.
	func rank(foldedName: String, foldedOthers: [String]) -> Rank? {
		guard !isEmpty, words.allSatisfy({ word in foldedName.contains(word) || foldedOthers.contains { $0.contains(word) } }) else { return nil }
		if foldedName.hasPrefix(whole) { return .namePrefix }
		if words.allSatisfy(foldedName.contains) { return .name }
		return .other
	}

	/// Lowercased, without accents.
	public static func fold(_ string: String) -> String {
		string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
	}
}
