import Foundation

// Foundation on Linux has no Markdown parsing; the app is iOS only.
#if canImport(Darwin)
/// Release notes and descriptions as sources write them: often Markdown,
/// GitHub's releases always (#30). Turned into one attributed string, so a
/// line limit still cuts it, with what fits in running text: headings in
/// bold, list items with bullets, and bold, italics, code and links inside
/// lines. Anything else is left as written.
public enum MarkdownNotes {
	public static func attributed(_ text: String) -> AttributedString {
		let lines = text
			.replacingOccurrences(of: "\r\n", with: "\n")
			.split(separator: "\n", omittingEmptySubsequences: false)
			.map(String.init)
		var result = AttributedString()
		var previousBlank = false
		for (index, line) in lines.enumerated() {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			// Runs of blank lines are one paragraph break.
			if trimmed.isEmpty {
				if previousBlank { continue }
				previousBlank = true
			} else {
				previousBlank = false
			}
			if index > 0 { result += AttributedString("\n") }
			result += attributedLine(line)
		}
		return result
	}

	private static func attributedLine(_ line: String) -> AttributedString {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		let hashes = trimmed.prefix { $0 == "#" }.count
		if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
			let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
			var text = inline(title.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
			text.inlinePresentationIntent = .stronglyEmphasized
			return text
		}
		if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
			// Two levels: a nested item is indented with a hollow bullet.
			let indent = line.prefix { $0 == " " || $0 == "\t" }.count
			let item = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
			return AttributedString(indent >= 2 ? "    ◦ " : "• ") + inline(item)
		}
		let compact = trimmed.filter { $0 != " " }
		if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) {
			// A rule: nothing to draw in running text.
			return AttributedString()
		}
		return inline(line)
	}

	/// Bold, italics, code and links in one line; the line as written when
	/// it isn't Markdown.
	private static func inline(_ text: String) -> AttributedString {
		let options = AttributedString.MarkdownParsingOptions(
			allowsExtendedAttributes: false,
			interpretedSyntax: .inlineOnlyPreservingWhitespace,
			failurePolicy: .returnPartiallyParsedIfPossible
		)
		return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
	}
}
#endif
