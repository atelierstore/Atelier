import Foundation

/// The projects listed in THIRD_PARTY_NOTICES.md, which the app ships and
/// shows on its Acknowledgements screen (#3), so the screen and the file
/// can't drift apart.
public struct ThirdPartyNotice: Equatable, Identifiable, Sendable {
	public let name: String
	public let url: URL?
	/// What Atelier uses it for, as plain text.
	public let usedFor: String
	/// The SPDX identifier, sometimes with a note, such as "Apache-2.0 (OpenSSL 3)".
	public let license: String
	public let copyright: String

	public var id: String { name }

	public init(name: String, url: URL?, usedFor: String, license: String, copyright: String) {
		self.name = name
		self.url = url
		self.usedFor = usedFor
		self.license = license
		self.copyright = copyright
	}

	/// Where its license text is, relative to the repository root, and to
	/// the app bundle's resources: licenses/<name>.txt, or Atelier's own
	/// LICENSE for a GPL-3.0 project, whose license is the same text.
	public var licensePaths: [String] {
		var paths = ["licenses/\(name).txt"]
		if license.hasPrefix("GPL-3.0") { paths.append("LICENSE") }
		return paths
	}

	/// Reads the table of THIRD_PARTY_NOTICES.md: one row per project, with
	/// the columns Project, Used for, License and Copyright. Anything outside
	/// the table is ignored.
	public static func parse(_ markdown: String) -> [ThirdPartyNotice] {
		var notices: [ThirdPartyNotice] = []
		var sawHeader = false
		for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = line.trimmingCharacters(in: .whitespaces)
			guard line.hasPrefix("|") else {
				if sawHeader { break }
				continue
			}
			let cells = line.dropFirst().split(separator: "|", omittingEmptySubsequences: false)
				.dropLast(line.hasSuffix("|") ? 1 : 0)
				.map { $0.trimmingCharacters(in: .whitespaces) }
			guard cells.count >= 4 else { continue }
			if !sawHeader {
				sawHeader = cells[0] == "Project"
				continue
			}
			if cells[0].allSatisfy({ $0 == "-" || $0 == ":" }) { continue }
			let (name, url) = link(cells[0])
			notices.append(ThirdPartyNotice(
				name: name,
				url: url,
				usedFor: plain(cells[1]),
				license: plain(cells[2]),
				copyright: plain(cells[3])
			))
		}
		return notices
	}

	/// `[text](url)` as its text and URL, or the cell as plain text.
	private static func link(_ cell: String) -> (String, URL?) {
		guard cell.hasPrefix("["), let close = cell.range(of: "]("), cell.hasSuffix(")") else {
			return (plain(cell), nil)
		}
		let text = String(cell[cell.index(after: cell.startIndex)..<close.lowerBound])
		let url = String(cell[close.upperBound..<cell.index(before: cell.endIndex)])
		return (plain(text), URL(string: url))
	}

	/// Markdown links turned into their text, and code spans and emphasis
	/// marks removed.
	private static func plain(_ text: String) -> String {
		var result = ""
		var rest = Substring(text)
		while let open = rest.firstIndex(of: "[") {
			result += rest[..<open]
			let after = rest[rest.index(after: open)...]
			guard let close = after.range(of: "]("),
				let end = after[close.upperBound...].firstIndex(of: ")")
			else {
				result += rest[open...]
				rest = ""
				break
			}
			result += after[..<close.lowerBound]
			rest = after[after.index(after: end)...]
		}
		result += rest
		return result.replacingOccurrences(of: "`", with: "")
			.replacingOccurrences(of: "**", with: "")
	}
}
