import Foundation

/// A GitHub repository added as a source (#30): its releases with `.ipa`
/// assets are the source's apps and versions. Kept as the source URL
/// `https://github.com/<owner>/<repo>`, lowercased, so the same repo added
/// twice compares equal.
public struct GitHubRepo: Hashable, Sendable, CustomStringConvertible {
	public var owner: String
	public var name: String

	public init(owner: String, name: String) {
		self.owner = owner.lowercased()
		self.name = name.lowercased()
	}

	/// `owner/repo`, lowercased. GitHub's own spelling comes from its API.
	public var description: String { "\(owner)/\(name)" }

	/// The source URL Atelier keeps for this repo.
	public var sourceURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

	/// The repo a source URL names, or nil when it's an ordinary source.
	/// Only the repo's own address counts: `github.com/<owner>/<repo>`,
	/// optionally followed by `/releases…` or `.git`. Any other GitHub path
	/// (a raw file, say) is fetched as an AltStore source.
	public init?(sourceURL url: URL) {
		guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
			host == "github.com" || host == "www.github.com"
		else { return nil }
		let parts = url.path.split(separator: "/").map(String.init)
		guard parts.count == 2 || (parts.count >= 3 && parts[2].lowercased() == "releases") else { return nil }
		var name = parts[1]
		if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
		guard Self.isOwner(parts[0]), Self.isName(name) else { return nil }
		self.init(owner: parts[0], name: name)
	}

	/// `owner/repo` as typed, without `github.com`. Owners can't contain a
	/// dot, which tells this apart from `example.com/apps.json`.
	public init?(shorthand text: String) {
		let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard parts.count == 2, Self.isOwner(parts[0]), Self.isName(parts[1]) else { return nil }
		self.init(owner: parts[0], name: parts[1])
	}

	/// GitHub user and organization names: letters, digits and single
	/// hyphens, up to 39 characters.
	static func isOwner(_ text: String) -> Bool {
		!text.isEmpty && text.count <= 39 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
	}

	/// Repository names: letters, digits, `.`, `-` and `_`, up to 100
	/// characters, and not `.` or `..`.
	static func isName(_ text: String) -> Bool {
		!text.isEmpty && text.count <= 100 && text != "." && text != ".."
			&& text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
	}
}

/// A file in a GitHub repository, as raw.githubusercontent.com serves it:
/// an AltStore source kept in a repo, or an image it lists. While the repo
/// is private, raw.githubusercontent.com answers 404, so Atelier reads the
/// file through GitHub's API instead (#24).
public struct GitHubFile: Hashable, Sendable {
	public var repo: GitHubRepo
	/// The branch or tag.
	public var ref: String
	public var path: String

	public init(repo: GitHubRepo, ref: String, path: String) {
		self.repo = repo
		self.ref = ref
		self.path = path
	}

	/// `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`, the
	/// ref a branch or tag name without a slash, or `refs/heads/<branch>` or
	/// `refs/tags/<tag>` as GitHub's own Raw links write it.
	public init?(rawURL url: URL) {
		guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "raw.githubusercontent.com" else { return nil }
		var parts = url.path.split(separator: "/").map(String.init)
		guard parts.count >= 4, GitHubRepo.isOwner(parts[0]), GitHubRepo.isName(parts[1]) else { return nil }
		let repo = GitHubRepo(owner: parts[0], name: parts[1])
		parts.removeFirst(2)
		if parts[0] == "refs", ["heads", "tags"].contains(parts[1]) {
			guard parts.count >= 4 else { return nil }
			parts.removeFirst(2)
		}
		self.init(repo: repo, ref: parts[0], path: parts.dropFirst().joined(separator: "/"))
	}
}

/// A file in a GitHub release, by its link on github.com, as a pasted URL
/// or a source gives it. github.com answers 404 for it while the repo is
/// private, so Atelier downloads it through GitHub's API instead, with an
/// account that can see the repo (#134).
public struct GitHubReleaseLink: Hashable, Sendable {
	public var repo: GitHubRepo
	/// The release's tag; nil for the repo's latest release.
	public var tag: String?
	/// The file's name in the release.
	public var name: String

	public init(repo: GitHubRepo, tag: String?, name: String) {
		self.repo = repo
		self.tag = tag
		self.name = name
	}

	/// `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`,
	/// or `…/releases/latest/download/<name>` for the latest release.
	public init?(url: URL) {
		guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
			host == "github.com" || host == "www.github.com"
		else { return nil }
		// Decoded, so a tag with an encoded slash comes back whole.
		let parts = url.path.split(separator: "/").map(String.init)
		guard parts.count >= 6, GitHubRepo.isOwner(parts[0]), GitHubRepo.isName(parts[1]), parts[2] == "releases" else { return nil }
		let repo = GitHubRepo(owner: parts[0], name: parts[1])
		if parts[3] == "download" {
			self.init(repo: repo, tag: parts[4..<(parts.count - 1)].joined(separator: "/"), name: parts[parts.count - 1])
		} else if parts.count == 6, parts[3] == "latest", parts[4] == "download" {
			self.init(repo: repo, tag: nil, name: parts[5])
		} else {
			return nil
		}
	}
}
