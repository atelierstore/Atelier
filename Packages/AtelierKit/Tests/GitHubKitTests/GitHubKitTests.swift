import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import GitHubKit
import SourceKit

/// A stored (uncompressed) ZIP, enough to stand in for an IPA.
func makeZip(_ files: [(String, Data)]) -> Data {
	var out = Data()
	var central = Data()
	func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
	func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
	func append(_ target: inout Data, _ parts: [Data]) { for part in parts { target.append(part) } }
	for (path, data) in files {
		let offset = out.count
		let name = Data(path.utf8)
		append(&out, [le32(0x0403_4B50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
		append(&out, [le32(data.count), le32(data.count), le16(name.count), le16(0), name, data])
		append(&central, [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0)])
		append(&central, [le32(data.count), le32(data.count), le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name])
	}
	let tableOffset = out.count
	out.append(central)
	append(&out, [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(tableOffset), le16(0)])
	return out
}

func infoPlist(_ bundleID: String, name: String, version: String, build: String = "1", minOS: String = "15.0") -> Data {
	let plist: [String: Any] = [
		"CFBundleIdentifier": bundleID,
		"CFBundleDisplayName": name,
		"CFBundleShortVersionString": version,
		"CFBundleVersion": build,
		"MinimumOSVersion": minOS,
		"CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]],
	]
	return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

func ipa(_ bundleID: String, name: String, version: String, build: String = "1", padding: Int = 0) -> Data {
	makeZip([
		("Payload/", Data()),
		("Payload/\(name).app/Info.plist", infoPlist(bundleID, name: name, version: version, build: build)),
		("Payload/\(name).app/AppIcon60x60@2x.png", Data("png-\(bundleID)".utf8)),
		("Payload/\(name).app/\(name)", Data(repeating: 7, count: 1000 + padding)),
	])
}

/// GitHub's API and asset storage, from memory, counting requests.
final class FakeGitHub: @unchecked Sendable {
	var repo: [String: Any] = ["full_name": "Owner/Repo", "name": "Repo", "private": false, "html_url": "https://github.com/Owner/Repo", "description": "An app"]
	var releases: [[String: Any]] = []
	var files: [String: Data] = [:]
	/// Files in the repo, as `<path>@<ref>`.
	var contents: [String: Data] = [:]
	var requests: [URLRequest] = []
	var etag = "\"abc\""
	var remaining = "59"
	/// The tokens that can see the repo, when it's private to some (#74);
	/// GitHub answers 404 to the rest.
	var canSee: Set<String>?
	/// Tokens GitHub refuses.
	var refused: Set<String> = []
	/// Whose each token is.
	var logins: [String: String] = [:]
	var ownerType = "User"
	/// What GitHub answers about the repo with 403, when set.
	var forbidden: String?
	private let lock = NSLock()

	func addRelease(id: Int, tag: String, prerelease: Bool = false, date: String, assets: [(id: Int, name: String, data: Data)]) {
		for asset in assets { files["/storage/\(asset.id)"] = asset.data }
		releases.append([
			"id": id, "tag_name": tag, "name": tag, "body": "Notes for \(tag)", "draft": false, "prerelease": prerelease,
			"published_at": date,
			"assets": assets.map { asset in [
				"id": asset.id, "name": asset.name, "size": asset.data.count, "state": "uploaded",
				"browser_download_url": "https://github.com/Owner/Repo/releases/download/\(tag)/\(asset.name)",
				"url": "https://api.github.com/repos/Owner/Repo/releases/assets/\(asset.id)",
			] as [String: Any] },
		])
	}

	func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
		lock.withLock { requests.append(request) }
		let url = request.url!
		func respond(_ status: Int, _ data: Data = Data(), _ headers: [String: String] = [:]) -> (Data, URLResponse) {
			(data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
		}
		if url.host == "api.github.com" {
			let token = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
			if let token, refused.contains(token) { return respond(401) }
			if remaining == "0" { return respond(403, Data(), ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1792710820"]) }
			if url.path.lowercased().hasPrefix("/repos/owner/repo") {
				if let forbidden { return respond(403, try JSONSerialization.data(withJSONObject: ["message": forbidden])) }
				if let canSee, !canSee.contains(token ?? "") { return respond(404) }
			}
			if url.path == "/user" {
				guard let token, let login = logins[token] else { return respond(401) }
				return respond(200, try JSONSerialization.data(withJSONObject: ["login": login, "avatar_url": "https://avatars.example/\(login)"]))
			}
			if let range = url.path.range(of: "/contents/") {
				let ref = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ref" }?.value ?? ""
				guard request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json",
				      let data = contents["\(url.path[range.upperBound...])@\(ref)"]
				else { return respond(404) }
				let tag = "\"file-\(data.reduce(0) { $0 &* 31 &+ Int($1) })\""
				if request.value(forHTTPHeaderField: "If-None-Match") == tag { return respond(304) }
				return respond(200, data, ["ETag": tag])
			}
			if url.path.hasSuffix("/releases") {
				if request.value(forHTTPHeaderField: "If-None-Match") == etag { return respond(304) }
				return respond(200, try JSONSerialization.data(withJSONObject: releases), ["ETag": etag])
			}
			if let range = url.path.range(of: "/releases/tags/") {
				let tag = String(url.path[range.upperBound...])
				guard let release = releases.first(where: { $0["tag_name"] as? String == tag }) else { return respond(404) }
				return respond(200, try JSONSerialization.data(withJSONObject: release))
			}
			if url.path.hasSuffix("/releases/latest") {
				// The newest release that isn't a pre-release, as GitHub's.
				let latest = releases.filter { $0["prerelease"] as? Bool != true }
					.max { ($0["published_at"] as? String ?? "") < ($1["published_at"] as? String ?? "") }
				guard let latest else { return respond(404) }
				return respond(200, try JSONSerialization.data(withJSONObject: latest))
			}
			if url.path.contains("/releases/assets/") {
				return respond(302, Data(), ["Location": "https://storage.example/storage/\(url.lastPathComponent)"])
			}
			if url.path == "/repos/owner/repo" {
				let tag = "\"repo-\(repo["description"] as? String ?? "")\""
				if request.value(forHTTPHeaderField: "If-None-Match") == tag { return respond(304) }
				return respond(200, try JSONSerialization.data(withJSONObject: repo), ["ETag": tag])
			}
			if url.path == "/user/repos" || url.path == "/user/starred" {
				return respond(200, try JSONSerialization.data(withJSONObject: [["full_name": "Owner/Repo", "private": true], ["full_name": "Other/Thing", "private": false]]))
			}
			if url.path == "/users/owner" { return respond(200, try JSONSerialization.data(withJSONObject: ["login": "Owner", "name": "Olive Owner", "type": ownerType])) }
			return respond(404)
		}
		if url.host == "github.com" {
			// releases/download/<tag>/<name> → the asset with that name.
			let name = url.lastPathComponent
			for release in releases {
				for asset in release["assets"] as! [[String: Any]] where asset["name"] as? String == name && (url.path.contains("/\(release["tag_name"]!)/")) {
					return respond(302, Data(), ["Location": "https://storage.example/storage/\(asset["id"]!)"])
				}
			}
			return respond(404)
		}
		guard let data = files[url.path] else { return respond(404) }
		guard let range = request.value(forHTTPHeaderField: "Range") else { return respond(200, data) }
		let bounds = range.dropFirst("bytes=".count).split(separator: "-").map { Int($0)! }
		let last = min(bounds[1], data.count - 1)
		return respond(206, data.subdata(in: bounds[0]..<(last + 1)))
	}

	var storageRequests: Int { requests.filter { $0.url?.host == "storage.example" }.count }

	/// The tokens that asked GitHub's API, in order; "" for none.
	var apiTokens: [String] {
		lock.withLock { requests }
			.filter { $0.url?.host == "api.github.com" }
			.map { $0.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) } ?? "" }
	}

	func clearRequests() {
		lock.withLock { requests = [] }
	}
}

final class GitHubRepoTests: XCTestCase {
	private func url(_ input: String) throws -> String {
		try SourceLink.sourceURL(from: input).absoluteString
	}

	func testRepoLinks() throws {
		XCTAssertEqual(try url("Owner/Repo"), "https://github.com/owner/repo")
		XCTAssertEqual(try url("https://github.com/Owner/Repo"), "https://github.com/owner/repo")
		XCTAssertEqual(try url("github.com/Owner/Repo.git"), "https://github.com/owner/repo")
		XCTAssertEqual(try url("https://www.github.com/owner/repo/releases/latest"), "https://github.com/owner/repo")
		XCTAssertEqual(try url("atelier://source?url=github.com/owner/my.repo"), "https://github.com/owner/my.repo")
		// Not a repo: ordinary sources, as before.
		XCTAssertEqual(try url("example.com/apps.json"), "https://example.com/apps.json")
		XCTAssertEqual(try url("https://github.com/owner/repo/raw/main/apps.json"), "https://github.com/owner/repo/raw/main/apps.json")
		XCTAssertNil(GitHubRepo(sourceURL: URL(string: "https://raw.githubusercontent.com/o/r/main/a.json")!))
		XCTAssertEqual(GitHubRepo(sourceURL: URL(string: "https://github.com/owner/repo")!), GitHubRepo(owner: "Owner", name: "Repo"))
	}

	/// Files in a repo, as sources kept in one are (#24).
	func testRawFiles() {
		func file(_ url: String) -> GitHubFile? { GitHubFile(rawURL: URL(string: url)!) }
		XCTAssertEqual(
			file("https://raw.githubusercontent.com/atelierstore/Atelier/source/source.json"),
			GitHubFile(repo: GitHubRepo(owner: "atelierstore", name: "Atelier"), ref: "source", path: "source.json")
		)
		// As GitHub's Raw button links them, and in a folder.
		XCTAssertEqual(
			file("https://raw.githubusercontent.com/owner/repo/refs/heads/main/apps/source.json"),
			GitHubFile(repo: GitHubRepo(owner: "owner", name: "repo"), ref: "main", path: "apps/source.json")
		)
		XCTAssertEqual(file("https://raw.githubusercontent.com/owner/repo/refs/tags/v1/a.json")?.ref, "v1")
		XCTAssertNil(file("https://raw.githubusercontent.com/owner/repo/main"))
		XCTAssertNil(file("https://raw.githubusercontent.com/owner/repo/refs/heads/main"))
		XCTAssertNil(file("https://example.com/owner/repo/main/a.json"))
		XCTAssertNil(file("http://raw.githubusercontent.com/owner/repo/main/a.json"))
	}

	/// Links to a file in a GitHub release, as a pasted URL or a source
	/// gives them (#134).
	func testReleaseLinks() {
		func link(_ url: String) -> GitHubReleaseLink? { GitHubReleaseLink(url: URL(string: url)!) }
		XCTAssertEqual(
			link("https://github.com/atelierstore/Atelier/releases/download/v0.4.0-alpha/Atelier-0.4.0-alpha.ipa"),
			GitHubReleaseLink(repo: GitHubRepo(owner: "atelierstore", name: "Atelier"), tag: "v0.4.0-alpha", name: "Atelier-0.4.0-alpha.ipa")
		)
		XCTAssertEqual(
			link("https://github.com/owner/repo/releases/latest/download/App.ipa"),
			GitHubReleaseLink(repo: GitHubRepo(owner: "owner", name: "repo"), tag: nil, name: "App.ipa")
		)
		// A tag with a slash in it, and a name with a space.
		XCTAssertEqual(link("https://www.github.com/owner/repo/releases/download/app/v1.0/App.ipa")?.tag, "app/v1.0")
		XCTAssertEqual(link("https://github.com/owner/repo/releases/download/v1/My%20App.ipa")?.name, "My App.ipa")
		// Not a file in a release.
		XCTAssertNil(link("https://github.com/owner/repo/releases/tag/v1"))
		XCTAssertNil(link("https://github.com/owner/repo/releases/download/v1"))
		XCTAssertNil(link("https://github.com/owner/repo/releases/latest/download/a/App.ipa"))
		XCTAssertNil(link("https://github.com/owner/repo/raw/main/App.ipa"))
		XCTAssertNil(link("https://api.github.com/repos/owner/repo/releases/assets/10"))
		XCTAssertNil(link("https://example.com/owner/repo/releases/download/v1/App.ipa"))
		XCTAssertNil(link("http://github.com/owner/repo/releases/download/v1/App.ipa"))
	}

	func testKindsAndBuilds() {
		XCTAssertEqual(GitHubSource.kind(of: "Feather_v2.9.0.ipa"), GitHubSource.kind(of: "Feather_v2.8.1.ipa"))
		XCTAssertNotEqual(GitHubSource.kind(of: "Feather_v2.9.0.ipa"), GitHubSource.kind(of: "Feather-debug-2.9.0.ipa"))
		XCTAssertTrue(GitHubSource.isSpecialBuild("Feather-debug.ipa"))
		XCTAssertFalse(GitHubSource.isSpecialBuild("Feather.ipa"))
		XCTAssertEqual(GitHubSource.tagVersion("v2.9.0"), "2.9.0")
		XCTAssertEqual(GitHubSource.tagVersion("nightly"), "nightly")
		XCTAssertEqual(GitHubSource.developer(login: "claration", name: nil), "@claration")
		XCTAssertEqual(GitHubSource.developer(login: "claration", name: "CLARATION"), "CLARATION (@claration)")
		XCTAssertEqual(GitHubSource.developer(login: "sample-user", name: "Sam Sample"), "Sam Sample (@sample-user)")
	}
}

final class RemoteIPATests: XCTestCase {
	func testReadsInfoPlistAndIconWithRanges() async throws {
		let fake = FakeGitHub()
		let data = ipa("com.example.app", name: "Example", version: "1.2", padding: 300_000)
		fake.files["/storage/1"] = data
		let reader = RemoteIPA(load: fake.load)
		let info = try await reader.read(URL(string: "https://storage.example/storage/1")!, size: Int64(data.count))
		XCTAssertEqual(info.bundleID, "com.example.app")
		XCTAssertEqual(info.name, "Example")
		XCTAssertEqual(info.version, "1.2")
		XCTAssertEqual(info.minimumOSVersion, "15.0")
		XCTAssertEqual(info.icon, Data("png-com.example.app".utf8))
		// The end, then Info.plist and the icon: never the whole app.
		XCTAssertEqual(fake.requests.count, 3)
		XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") != nil })
	}

	func testRejectsWhatIsNotAnApp() async {
		let fake = FakeGitHub()
		let data = Data(repeating: 1, count: 5000)
		fake.files["/storage/1"] = data
		do {
			_ = try await RemoteIPA(load: fake.load).read(URL(string: "https://storage.example/storage/1")!, size: 5000)
			XCTFail("read a file that isn't a ZIP")
		} catch {
			XCTAssertEqual(error as? RemoteIPA.Problem, .notAZip)
		}
	}
}

final class GitHubSourceTests: XCTestCase {
	private func source(_ fake: FakeGitHub, token: String? = nil) -> GitHubSource {
		GitHubSource(
			api: GitHubAPI(token: { token }, load: fake.load, loadWithoutRedirects: fake.load),
			ipa: RemoteIPA(load: fake.load),
			tint: { icon in String(decoding: icon, as: UTF8.self).hasSuffix("widget") ? "336699" : nil }
		)
	}

	private let repo = GitHubRepo(owner: "owner", name: "repo")

	private func fetched(_ outcome: SourceFetcher.Outcome) throws -> SourceFetcher.Fetched {
		guard case .fetched(let fetched) = outcome else { throw XCTSkip("not modified") }
		return fetched
	}

	func testReleasesBecomeVersionsAndApps() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 2, tag: "v1.1", date: "2026-10-10T10:00:00Z", assets: [
			(20, "App_1.1.ipa", ipa("com.example.app", name: "App", version: "1.1")),
			(21, "App-debug_1.1.ipa", ipa("com.example.app", name: "App", version: "1.1", padding: 5000)),
			(22, "Widget.ipa", ipa("com.example.widget", name: "Widget", version: "3.0")),
			(23, "App.tipa", Data()),
		])
		fake.addRelease(id: 1, tag: "v1.0", date: "2026-10-01T10:00:00Z", assets: [(10, "App_1.0.ipa", ipa("com.example.app", name: "App", version: "1.0"))])

		let result = try fetched(try await source(fake).fetch(repo))
		let parsed = result.parsed.source
		XCTAssertEqual(parsed.name, "Repo")
		XCTAssertEqual(parsed.subtitle, "Owner/Repo")
		XCTAssertEqual(parsed.apps.map(\.bundleID), ["com.example.app", "com.example.widget"])
		let app = parsed.apps[0]
		XCTAssertEqual(app.name, "App")
		XCTAssertEqual(app.developerName, "Olive Owner (@Owner)")
		XCTAssertNotNil(app.iconURL)
		// The usual build rather than the larger debug one; the older
		// release takes its app from the newer and its version from the
		// tag, without being read.
		XCTAssertEqual(app.versions.map(\.version), ["1.1", "1.0"])
		XCTAssertEqual(app.versions[0].downloadURL.absoluteString, "https://github.com/Owner/Repo/releases/download/v1.1/App_1.1.ipa")
		XCTAssertEqual(app.versions[0].localizedDescription, "Notes for v1.1")
		// Both builds of 1.1 to choose from, the usual one recommended.
		let builds = app.versions[0].builds
		XCTAssertEqual(builds.map(\.name), ["App_1.1.ipa", "App-debug_1.1.ipa"])
		XCTAssertEqual(builds.map(\.isSpecial), [false, true])
		XCTAssertEqual(builds[1].note(on: OSVersion("26.0")!), "debug build")
		XCTAssertEqual(app.versions[0].recommendedBuild(on: OSVersion("26.0")!)?.name, "App_1.1.ipa")
		XCTAssertEqual(app.versions[0].build(ofKind: builds[1].kind, on: OSVersion("26.0")!)?.name, "App-debug_1.1.ipa")
		XCTAssertEqual(app.versions[0].using(builds[1]).downloadURL, builds[1].downloadURL)
		XCTAssertTrue(app.versions[1].builds.isEmpty)
		XCTAssertEqual(parsed.apps[1].versions.map(\.version), ["3.0"])
		// Colours from the icons: the widget's, and GitHub's for the source
		// when its newest app's icon gives none.
		XCTAssertEqual(parsed.apps[1].tintColor, "336699")
		XCTAssertNil(app.tintColor)
		XCTAssertEqual(parsed.tintColor, GitHubSource.defaultTint)
		XCTAssertEqual(result.etag, fake.etag)
		XCTAssertEqual(GitHubSource.summary(of: result.data)?.releaseCount, 2)

		// A refresh with nothing new is two free requests: the repo, and
		// its releases.
		let before = fake.requests.count
		let again = try await source(fake).fetch(repo, etag: result.etag, previous: result.data)
		guard case .notModified = again else { return XCTFail("expected not modified") }
		XCTAssertEqual(fake.requests.count, before + 2)

		// A new description is picked up, though the releases are the same.
		fake.repo["description"] = "A better app"
		let described = try fetched(try await source(fake).fetch(repo, etag: result.etag, previous: result.data))
		XCTAssertEqual(described.parsed.source.apps[0].localizedDescription, "A better app")
		fake.repo["description"] = "An app"

		// A new release: only its IPA is read, the rest comes from the notes.
		fake.addRelease(id: 4, tag: "v1.2", date: "2026-10-21T10:00:00Z", assets: [(40, "App_1.2.ipa", ipa("com.example.app", name: "App", version: "1.2"))])
		fake.etag = "\"def\""
		let storageBefore = fake.storageRequests
		let refreshed = try fetched(try await source(fake).fetch(repo, etag: result.etag, previous: result.data))
		XCTAssertEqual(refreshed.parsed.source.apps[0].versions.map(\.version), ["1.2", "1.1", "1.0"])
		XCTAssertEqual(fake.storageRequests - storageBefore, 3)
		XCTAssertNotNil(refreshed.parsed.source.apps[1].iconURL, "keeps the icons it read before")
	}

	/// Feather's history: the app changed its bundle ID at 2.0, and 2.0.1
	/// came as two apps that are both called Feather.
	func testAppThatChangedItsBundleID() async throws {
		let fake = FakeGitHub()
		var day = 0, id = 0
		func release(_ version: String, _ assets: [(String, String)]) {
			day += 1
			fake.addRelease(id: day, tag: "v\(version)", date: String(format: "2026-01-%02dT00:00:00Z", day), assets: assets.map { name, bundleID in
				id += 1
				return (id, name, ipa(bundleID, name: "Feather", version: version))
			})
		}
		for version in ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6"] {
			release(version, [("feather_v\(version).ipa", "kh.crysalis.feather")])
		}
		release("2.0.1", [("Feather-default.ipa", "thewonderofyou.Feather"), ("Feather-pairing.ipa", "thewonderofyou.Feather-idevice")])
		for version in ["2.1", "2.2", "2.3", "2.4", "2.5", "2.6", "2.7", "2.8", "2.9"] {
			release(version, [("Feather.ipa", "thewonderofyou.Feather")])
		}
		fake.releases.reverse()

		let parsed = try fetched(try await source(fake).fetch(repo)).parsed.source
		XCTAssertEqual(parsed.apps.map(\.bundleID), ["thewonderofyou.Feather", "thewonderofyou.Feather-idevice", "kh.crysalis.feather"])
		// Named as the developer named them, even when that's the same.
		XCTAssertEqual(parsed.apps.map(\.name), ["Feather", "Feather", "Feather"])
		XCTAssertEqual(parsed.apps[0].versions.map(\.version), ["2.9", "2.8", "2.7", "2.6", "2.5", "2.4", "2.3", "2.2", "2.1", "2.0.1"])
		XCTAssertEqual(parsed.apps[1].versions.map(\.version), ["2.0.1"])
		XCTAssertEqual(parsed.apps[2].versions.map(\.version), ["1.6", "1.5", "1.4", "1.3", "1.2", "1.1", "1.0"])
		// Not every IPA: the ends of each kind, and halving to the change.
		let read = Set(fake.requests.compactMap { $0.url?.host == "storage.example" ? $0.url?.lastPathComponent : nil })
		XCTAssertLessThanOrEqual(read.count, 8)
	}

	/// Pre-releases are read with the releases, and Include Pre-releases
	/// hides them as it hides any source's betas (#104).
	func testPrereleasesAreRead() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 2, tag: "v2.0b1", prerelease: true, date: "2026-10-20T10:00:00Z", assets: [(20, "App.ipa", ipa("com.example.app", name: "App", version: "2.0b1"))])
		fake.addRelease(id: 1, tag: "v1.0", date: "2026-10-01T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "1.0"))])
		let parsed = try fetched(try await source(fake).fetch(repo)).parsed.source
		XCTAssertEqual(parsed.name, "Repo")
		XCTAssertEqual(parsed.apps[0].versions.map(\.version), ["2.0b1", "1.0"])
		XCTAssertEqual(parsed.apps[0].versions.map(\.isPrerelease), [true, false])
		// One list, whose newest is the beta.
		XCTAssertEqual(parsed.apps[0].latestVersion?.version, "2.0b1")
		XCTAssertTrue(parsed.apps[0].isBetaRelease)
		XCTAssertFalse(parsed.apps[0].isBeta, "not a beta app: it has a release")
		XCTAssertTrue(parsed.listsPrereleases)
		XCTAssertFalse(parsed.listsOnlyPrereleases)

		let releases = parsed.withoutPrereleases()
		XCTAssertEqual(releases.name, "Repo", "the same name without pre-releases")
		XCTAssertEqual(releases.apps[0].versions.map(\.version), ["1.0"])
		XCTAssertFalse(releases.apps[0].isBetaRelease)
	}

	/// NimbusMobile's releases (#104): a beta GitHub doesn't mark, and an
	/// earlier pre-release of another app that its developer numbered 1.0.0.
	func testBetasByTagAndPrereleaseOnlyApps() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 5, tag: "v0.6.5", date: "2026-10-27T10:00:00Z", assets: [(50, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.5"))])
		fake.addRelease(id: 4, tag: "v0.6.4", date: "2026-10-24T10:00:00Z", assets: [(40, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.4"))])
		fake.addRelease(id: 3, tag: "v0.6.3-beta", date: "2026-10-21T10:00:00Z", assets: [(30, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.3"))])
		fake.addRelease(id: 2, tag: "v0.6.2", date: "2026-10-15T10:00:00Z", assets: [(20, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.2"))])
		fake.addRelease(id: 1, tag: "v1.0.0", prerelease: true, date: "2026-09-01T10:00:00Z", assets: [(10, "Nimbus-iOS.ipa", ipa("com.nimbus.mobile", name: "Nimbus", version: "1.0.0"))])

		let withPrereleases = try fetched(try await source(fake).fetch(repo))
		let all = withPrereleases.parsed.source
		let releases = all.withoutPrereleases()
		XCTAssertEqual(releases.name, "Repo")
		XCTAssertEqual(releases.apps.map(\.bundleID), ["com.nimbus.app"])
		XCTAssertEqual(releases.apps[0].versions.map(\.version), ["0.6.5", "0.6.4", "0.6.2"], "the beta by its tag isn't listed")

		XCTAssertEqual(all.apps.map(\.bundleID), ["com.nimbus.app", "com.nimbus.mobile"])
		let nimbus = all.apps[0]
		XCTAssertEqual(nimbus.versions.map(\.isPrerelease), [false, false, true, false])
		// Not read: its version is its tag's.
		XCTAssertEqual(nimbus.versions.filter(\.isPrerelease).map(\.version), ["0.6.3-beta"])
		XCTAssertEqual(nimbus.latestVersion?.version, "0.6.5")
		XCTAssertFalse(nimbus.isBetaRelease, "its newest is a release")
		// Only in pre-releases: a beta app.
		let other = all.apps[1]
		XCTAssertTrue(other.isBeta)
		XCTAssertTrue(other.isBetaRelease)
		XCTAssertEqual(other.latestVersion?.version, "1.0.0")
		XCTAssertEqual(GitHubSource.summary(of: withPrereleases.data)?.releaseCount, 5)
	}

	/// An app found only in pre-releases comes after the apps with releases,
	/// even when its pre-release is newer, so the source's colour is the same
	/// with pre-releases hidden (#104).
	func testAppsWithReleasesComeFirst() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 2, tag: "v2.0-beta.1", date: "2026-10-20T10:00:00Z", assets: [(20, "Widget.ipa", ipa("com.example.widget", name: "Widget", version: "2.0"))])
		fake.addRelease(id: 1, tag: "v1.0", date: "2026-10-01T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "1.0"))])
		let parsed = try fetched(try await source(fake).fetch(repo)).parsed.source
		XCTAssertEqual(parsed.apps.map(\.bundleID), ["com.example.app", "com.example.widget"])
		XCTAssertEqual(parsed.apps.map(\.isBeta), [false, true])
		XCTAssertEqual(parsed.tintColor, GitHubSource.defaultTint, "the first app's, which has none")
	}

	/// Version History names every version by its tag (#104), releases and
	/// betas alike, whether its IPA was read or not; elsewhere a version is
	/// what its IPA says, and updates go by that.
	func testVersionsKeepTheirTags() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 3, tag: "v0.6.5-beta", date: "2026-10-27T10:00:00Z", assets: [(30, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.5", build: "148"))])
		fake.addRelease(id: 2, tag: "v0.6.4-beta", date: "2026-10-24T10:00:00Z", assets: [(20, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.6.4", build: "147"))])
		fake.addRelease(id: 1, tag: "v0.4.21", date: "2026-09-15T10:00:00Z", assets: [(10, "Nimbus.ipa", ipa("com.nimbus.app", name: "Nimbus", version: "0.4.21", build: "126"))])
		let nimbus = try fetched(try await source(fake).fetch(repo)).parsed.source.apps[0]
		XCTAssertEqual(nimbus.versions.map(\.version), ["0.6.5", "0.6.4-beta", "0.4.21"], "the IPAs' own versions, and the tag of the one between, which isn't read")
		XCTAssertEqual(nimbus.versions.map(\.displayVersion), ["0.6.5 (148)", "0.6.4-beta", "0.4.21 (126)"])
		XCTAssertEqual(nimbus.versions.map(\.releaseName), ["0.6.5-beta", "0.6.4-beta", "0.4.21"])
		XCTAssertTrue(nimbus.versions[0].isBeta)
		// One list: the newest is the beta (#104).
		XCTAssertEqual(nimbus.latestVersion?.displayVersion, "0.6.5 (148)")
		XCTAssertTrue(nimbus.isBetaRelease)

		// Installed from the one that isn't read, the app says 0.6.4: that's
		// its 0.6.4-beta, a beta.
		let installed = InstalledRelease(version: "0.6.4", buildVersion: "147", installedAt: .now, listing: nimbus)
		XCTAssertEqual(UpdateCheck.installedEntry(installed, in: nimbus)?.releaseName, "0.6.4-beta")
		XCTAssertTrue(installed.isBeta)
		XCTAssertEqual(UpdateCheck.update(for: installed, in: nimbus, on: OSVersion("26.0")!)?.displayVersion, "0.6.5 (148)")

		// Installed as the release, it's offered the newest beta too.
		let release = InstalledRelease(version: "0.4.21", buildVersion: "126", installedAt: .now, listing: nimbus)
		XCTAssertFalse(release.isBeta)
		XCTAssertEqual(UpdateCheck.update(for: release, in: nimbus, on: OSVersion("26.0")!)?.displayVersion, "0.6.5 (148)")
	}

	func testTagNames() {
		XCTAssertEqual(GitHubSource.tagName("v0.6.5-beta"), "0.6.5-beta")
		XCTAssertEqual(GitHubSource.tagName("v0.4.21"), "0.4.21")
		XCTAssertEqual(GitHubSource.tagName("2026.10.28"), "2026.10.28")
		XCTAssertNil(GitHubSource.tagName("nightly"), "no number to name a version by")
	}

	func testPrereleaseTags() {
		for tag in ["v0.6.3-beta", "0.2.0-alpha", "2.0b3", "v1.0-rc.1", "v1.0.0-RC2", "v2.0-preview", "nightly", "v1.4-dev", "1.0-pre", "canary-2026-10-28", "v3.0.0-beta.2"] {
			XCTAssertTrue(GitHubSource.isPrereleaseTag(tag), tag)
		}
		for tag in ["v0.6.5", "1.0", "v1.2-hotfix", "devtools-1.0", "release-2.1", "v2.0.0-ios", "build-45", "2024.10.21"] {
			XCTAssertFalse(GitHubSource.isPrereleaseTag(tag), tag)
		}
	}

	func testListsTheUsersReposWithTheirNewestApp() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 2, tag: "v2.0", date: "2026-10-20T10:00:00Z", assets: [(20, "Notes.txt", Data("x".utf8))])
		fake.addRelease(id: 1, tag: "v1.0-beta", prerelease: true, date: "2026-10-01T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "1.0"))])
		let api = GitHubAPI(token: { "t" }, load: fake.load, loadWithoutRedirects: fake.load)
		let mine = try await api.myRepos()
		XCTAssertEqual(mine.map(\.fullName), ["Owner/Repo", "Other/Thing"])
		XCTAssertEqual(mine.map(\.isPrivate), [true, false])
		XCTAssertEqual(mine[0].repo, repo)
		let newest = try await api.newestAppRelease(repo)
		XCTAssertEqual(newest?.tag, "v1.0-beta")
		XCTAssertEqual(newest?.isPrerelease, true)
	}

	/// A repo with only pre-releases is read as one beta app, which it's
	/// added with listed (#104).
	func testARepoWithOnlyPrereleases() async throws {
		let fake = FakeGitHub()
		fake.addRelease(id: 1, tag: "v0.1-alpha", prerelease: true, date: "2026-10-20T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "0.1"))])
		let parsed = try fetched(try await source(fake).fetch(repo)).parsed.source
		XCTAssertEqual(parsed.apps[0].versions.map(\.version), ["0.1"])
		XCTAssertTrue(parsed.apps[0].isBeta)
		XCTAssertTrue(parsed.listsOnlyPrereleases)
		XCTAssertTrue(parsed.withoutPrereleases().apps.isEmpty)
	}

	func testPrivateReposDownloadThroughTheAPIWithTheToken() async throws {
		let fake = FakeGitHub()
		fake.repo["private"] = true
		fake.addRelease(id: 1, tag: "v1.0", date: "2026-10-01T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "1.0"))])
		let parsed = try fetched(try await source(fake, token: "secret").fetch(repo)).parsed.source
		XCTAssertEqual(parsed.apps[0].versions[0].downloadURL.absoluteString, "https://api.github.com/repos/Owner/Repo/releases/assets/10")
		let apiRequests = fake.requests.filter { $0.url?.host == "api.github.com" }
		XCTAssertTrue(apiRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
		// The token never goes to the storage the asset redirects to.
		XCTAssertTrue(fake.requests.filter { $0.url?.host == "storage.example" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
		XCTAssertTrue(GitHubAPI.isAPIAsset(parsed.apps[0].versions[0].downloadURL))
	}

	func testProblems() async throws {
		let fake = FakeGitHub()
		do {
			_ = try await source(fake).fetch(repo)
			XCTFail("a repo without IPAs")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .noReleases(repo))
		}
		fake.remaining = "0"
		do {
			_ = try await source(fake).fetch(repo)
			XCTFail("over the limit")
		} catch let problem as GitHubAPI.Problem {
			guard case .rateLimited(let reset, hasToken: false) = problem else { return XCTFail("\(problem)") }
			XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_792_710_820))
			XCTAssertTrue(problem.description.contains("sign in to GitHub in Browse › Manage Sources"))
		}
		XCTAssertEqual(
			GitHubAPI.Problem.notFound(repo, accounts: 0).description,
			"GitHub can't find owner/repo. If it's private, sign in to GitHub in Browse › Manage Sources."
		)
		XCTAssertEqual(
			GitHubAPI.Problem.notFound(repo, accounts: 1).description,
			"Your GitHub account can't see owner/repo, or it doesn't exist."
		)
		XCTAssertEqual(
			GitHubAPI.Problem.notFound(repo, accounts: 2, organization: "owner").description,
			"None of your GitHub accounts can see owner/repo, or it doesn't exist. If owner limits which apps can read its repos, an owner has to approve Atelier first."
		)
		XCTAssertEqual(
			GitHubAPI.Problem.badToken(account: "sample-acme").description,
			"GitHub didn't accept the sign-in of @sample-acme. Sign in to it again in Browse › Manage Sources."
		)
	}

	/// An HTTP code says what it means; an unusual one stays at the end.
	func testStatusCodesSayWhatTheyMean() {
		XCTAssertEqual(GitHubAPI.Problem.status(502).description, "GitHub had a problem. Try again later.")
		XCTAssertEqual(GitHubAPI.Problem.status(422).description, "GitHub refused the request (error 422).")
	}
}

final class GitHubSignInTests: XCTestCase {
	private let worker = URL(string: "https://worker.example")!

	func testWebSignIn() async throws {
		final class Server: @unchecked Sendable { var tokenBody: [String: Any] = [:] }
		let server = Server()
		let signIn = GitHubSignIn(clientID: "Ov23test", worker: worker, load: { request in
			let url = request.url!
			func json(_ object: [String: Any]) -> (Data, URLResponse) {
				(try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
			}
			if url.path == "/github/token" {
				server.tokenBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
				return json(["access_token": "gho_abc", "scope": "repo"])
			}
			XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_abc")
			return json(["login": "sample-user"])
		}, random: { "r" + String(repeating: "x", count: 42) })

		let attempt = try signIn.start()
		let query = Dictionary(uniqueKeysWithValues: URLComponents(url: attempt.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
		XCTAssertEqual(attempt.authorizeURL.host, "github.com")
		XCTAssertEqual(query["client_id"], "Ov23test")
		XCTAssertEqual(query["redirect_uri"], "https://worker.example/github/callback")
		XCTAssertEqual(query["scope"], "repo")
		XCTAssertEqual(query["code_challenge"], GitHubSignIn.challenge(for: attempt.verifier))
		XCTAssertNil(query["prompt"])

		let wrong = URL(string: "atelier://github-sign-in?state=other&code=c")!
		do {
			_ = try await signIn.finish(attempt, callback: wrong)
			XCTFail("took another sign-in's answer")
		} catch {
			XCTAssertEqual(error as? GitHubSignIn.Problem, .mismatchedState)
		}

		let callback = URL(string: "atelier://github-sign-in?state=\(query["state"]!)&code=c0de")!
		let account = try await signIn.finish(attempt, callback: callback)
		XCTAssertEqual(account, GitHubSignIn.Account(token: "gho_abc", login: "sample-user"))
		XCTAssertEqual(server.tokenBody["code"] as? String, "c0de")
		XCTAssertEqual(server.tokenBody["code_verifier"] as? String, attempt.verifier)
	}

	func testPKCEChallenge() {
		// RFC 7636, appendix B.
		XCTAssertEqual(GitHubSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
		XCTAssertEqual(GitHubSignIn.randomString().count, 43)
	}

	func testPickingAnAccount() throws {
		let attempt = try GitHubSignIn(clientID: "Ov23test", worker: worker).start(picksAccount: true)
		let items = URLComponents(url: attempt.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
		XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "select_account")
	}

	func testWithoutAClientID() {
		XCTAssertThrowsError(try GitHubSignIn(clientID: "", worker: worker).start()) { error in
			XCTAssertEqual(error as? GitHubSignIn.Problem, .notEnabled)
		}
	}
}

final class AppBuildTests: XCTestCase {
	func testRecommendsABuildThisDeviceCanRun() {
		let url = URL(string: "https://example.com/a.ipa")!
		var version = AppVersion(version: "1.0", downloadURL: url)
		version.builds = [
			AppBuild(name: "App-iOS28.ipa", downloadURL: URL(string: "https://example.com/28.ipa")!, size: 300, minOSVersion: OSVersion("28.0")),
			AppBuild(name: "App.ipa", downloadURL: url, size: 200, minOSVersion: OSVersion("16.0")),
			AppBuild(name: "App-debug.ipa", downloadURL: URL(string: "https://example.com/d.ipa")!, size: 400, isSpecial: true),
		]
		let os = OSVersion("26.0")!
		XCTAssertEqual(version.recommendedBuild(on: os)?.name, "App.ipa")
		XCTAssertEqual(version.builds[0].note(on: os), "requires iOS 28.0")
		XCTAssertEqual(version.build(ofKind: "nothing", on: os)?.name, "App.ipa")
	}

	func testDownloadsALinkedIPA() {
		let url = URL(string: "https://example.com/a.ipa")!
		let debug = URL(string: "https://example.com/d.ipa")!
		var version = AppVersion(version: "1.0", downloadURL: url, size: 200)
		XCTAssertEqual(version.downloading(url), version)
		XCTAssertNil(version.downloading(debug))
		version.builds = [
			AppBuild(name: "App.ipa", downloadURL: url, size: 200),
			AppBuild(name: "App-debug.ipa", downloadURL: debug, size: 400, isSpecial: true),
		]
		XCTAssertEqual(version.downloading(url), version)
		XCTAssertEqual(version.downloading(debug)?.downloadURL, debug)
		XCTAssertEqual(version.downloading(debug)?.size, 400)
		XCTAssertNil(version.downloading(URL(string: "https://example.com/other.ipa")!))
	}
}

/// Tokens in memory, for the Keychain.
final class MemoryTokens: GitHubTokenStore, @unchecked Sendable {
	private let lock = NSLock()
	private var tokens: [UUID: String] = [:]
	private var legacy: String?
	/// Like the Keychain while the iPhone is locked.
	var isLocked: Bool {
		get { lock.withLock { locked } }
		set { lock.withLock { locked = newValue } }
	}
	private var locked = false

	struct Locked: Error {}

	init(legacy: String? = nil) {
		self.legacy = legacy
	}

	func token(for account: UUID) -> String? { lock.withLock { locked ? nil : tokens[account] } }
	func save(_ token: String, for account: UUID) throws { lock.withLock { tokens[account] = token } }
	func delete(_ account: UUID) { lock.withLock { tokens[account] = nil } }
	func legacyToken() throws -> String? {
		try lock.withLock {
			if locked { throw Locked() }
			return legacy
		}
	}
	func deleteLegacyToken() { lock.withLock { legacy = nil } }
	var count: Int { lock.withLock { tokens.count } }
	/// The accounts whose tokens `reprotect` was last asked for.
	private(set) var reprotected: [UUID] = []
	func reprotect(_ accounts: [UUID]) throws {
		try lock.withLock {
			if locked { throw Locked() }
			reprotected = accounts
		}
	}
}

final class GitHubAccountsTests: XCTestCase {
	private let repo = GitHubRepo(owner: "owner", name: "repo")
	private var defaults: UserDefaults!

	override func setUp() {
		defaults = UserDefaults(suiteName: "GitHubAccountsTests.\(UUID().uuidString)")
	}

	private func accounts(_ fake: FakeGitHub, tokens: MemoryTokens = MemoryTokens()) -> GitHubAccounts {
		GitHubAccounts(defaults: defaults, tokens: tokens, makeAPI: { token in
			GitHubAPI(token: token, load: fake.load, loadWithoutRedirects: fake.load)
		})
	}

	/// A personal account, then a work one.
	private func twoAccounts(_ fake: FakeGitHub) throws -> (GitHubAccounts, personal: GitHubAccount, work: GitHubAccount) {
		let accounts = accounts(fake)
		let personal = try accounts.add(token: "personal", login: "sample-user", kind: .signedIn)
		let work = try accounts.add(token: "work", login: "sample-acme", kind: .signedIn)
		return (accounts, personal, work)
	}

	private func releaseWithAnApp(_ fake: FakeGitHub) {
		fake.repo["private"] = true
		fake.addRelease(id: 1, tag: "v1.0", date: "2026-10-01T10:00:00Z", assets: [(10, "App.ipa", ipa("com.example.app", name: "App", version: "1.0"))])
	}

	func testSigningInAgainRenewsTheAccount() throws {
		let tokens = MemoryTokens()
		let accounts = accounts(FakeGitHub(), tokens: tokens)
		let personal = try accounts.add(token: "t1", login: "sample-user", kind: .signedIn)
		let work = try accounts.add(token: "t2", login: "sample-acme", kind: .signedIn, avatarURL: URL(string: "https://avatars.example/w"))
		let again = try accounts.add(token: "t3", login: "Sample-User", kind: .signedIn)
		XCTAssertEqual(again.id, personal.id)
		XCTAssertEqual(accounts.all.map(\.id), [personal.id, work.id])
		XCTAssertEqual(tokens.token(for: personal.id), "t3")
		XCTAssertEqual(accounts.all[1].avatarURL, URL(string: "https://avatars.example/w"))
		// A pasted token is an account of its own, even for the same person.
		let pasted = try accounts.add(token: "t4", login: "sample-user", kind: .token)
		XCTAssertEqual(accounts.all.map(\.id), [personal.id, work.id, pasted.id])

		accounts.remove(work)
		XCTAssertEqual(accounts.all.map(\.id), [personal.id, pasted.id])
		XCTAssertNil(tokens.token(for: work.id))
		accounts.remove(personal)
		accounts.remove(pasted)
		XCTAssertTrue(accounts.all.isEmpty)
		XCTAssertEqual(tokens.count, 0)
	}

	func testReprotectsEveryAccountsToken() throws {
		let tokens = MemoryTokens()
		let accounts = accounts(FakeGitHub(), tokens: tokens)
		let personal = try accounts.add(token: "t1", login: "sample-user", kind: .signedIn)
		let pasted = try accounts.add(token: "t2", login: nil, kind: .token)
		try accounts.reprotect()
		XCTAssertEqual(tokens.reprotected, [personal.id, pasted.id])
		// While the iPhone is locked it can't, and says so.
		tokens.isLocked = true
		XCTAssertThrowsError(try accounts.reprotect())
	}

	func testARepoKeepsTheAccountThatCanSeeIt() async throws {
		let fake = FakeGitHub()
		releaseWithAnApp(fake)
		fake.canSee = ["work"]
		let (accounts, _, work) = try twoAccounts(fake)
		let source = GitHubSource(credentials: accounts, ipa: RemoteIPA(load: fake.load))

		let parsed = try await source.fetch(repo)
		guard case .fetched(let fetched) = parsed else { return XCTFail("not fetched") }
		XCTAssertEqual(fetched.parsed.source.apps.map(\.bundleID), ["com.example.app"])
		XCTAssertEqual(accounts.account(for: repo), work)
		// The personal account asked first, and GitHub said 404; then the
		// work account read everything, the app's IPA included.
		XCTAssertEqual(fake.apiTokens.first, "personal")
		XCTAssertEqual(Set(fake.apiTokens.dropFirst()), ["work"])

		// Next time, only the work account asks.
		fake.clearRequests()
		_ = try await source.fetch(repo)
		XCTAssertEqual(Set(fake.apiTokens), ["work"])

		// Its downloads too.
		let asset = URL(string: "https://api.github.com/repos/Owner/Repo/releases/assets/10")!
		fake.clearRequests()
		let download = try await accounts.first(for: try XCTUnwrap(GitHubAPI.repo(ofAsset: asset))) { try await $0.downloadURL(for: asset) }
		XCTAssertEqual(download.value, URL(string: "https://storage.example/storage/10"))
		XCTAssertEqual(fake.apiTokens, ["work"])

		// Signed out of it, the repo tries the others again, which can't see it.
		accounts.remove(work)
		do {
			_ = try await source.fetch(repo)
			XCTFail("read a repo no account can see")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 1))
		}
		XCTAssertNil(accounts.account(for: repo))
	}

	/// A source.json kept in a private repo, as Atelier's own is while
	/// its repo is private (#24): read as the account that can see the
	/// repo, with its downloads moved to GitHub's API and its icon written
	/// in, as neither loads from github.com.
	func testASourceKeptInAPrivateRepo() async throws {
		let fake = FakeGitHub()
		fake.canSee = ["work"]
		let json = """
		{"name": "Atelier", "identifier": "com.atelier.source", "iconURL": "https://raw.githubusercontent.com/Owner/Repo/source/icon.png", "apps": [{"name": "Atelier", "bundleIdentifier": "com.atelier.app", "iconURL": "https://raw.githubusercontent.com/owner/repo/source/icon.png", "versions": [
			{"version": "0.2.0", "marketingVersion": "0.2.0-alpha", "buildVersion": "340", "downloadURL": "https://github.com/owner/repo/releases/download/v0.2.0-alpha/Atelier-0.2.0-alpha.ipa"},
			{"version": "0.1.0", "downloadURL": "https://example.com/Atelier-0.1.0.ipa"}
		]}]}
		"""
		fake.contents["source.json@source"] = Data(json.utf8)
		fake.addRelease(id: 1, tag: "v0.2.0-alpha", prerelease: true, date: "2026-10-27T10:00:00Z", assets: [(id: 11, name: "Atelier-0.2.0-alpha.ipa", data: Data("ipa".utf8))])
		let (accounts, _, work) = try twoAccounts(fake)
		let source = GitHubSource(credentials: accounts, ipa: RemoteIPA(load: fake.load))
		let file = try XCTUnwrap(GitHubFile(rawURL: URL(string: "https://raw.githubusercontent.com/Owner/Repo/source/source.json")!))

		guard case .fetched(let fetched) = try await source.fetch(file) else { return XCTFail("not read") }
		let app = fetched.parsed.source.apps[0]
		XCTAssertEqual(app.versions.map(\.downloadURL.absoluteString), [
			"https://api.github.com/repos/Owner/Repo/releases/assets/11",
			"https://example.com/Atelier-0.1.0.ipa",
		])
		XCTAssertEqual(app.versions[0].marketingVersion, "0.2.0-alpha", "the rest stays")
		// Images stay as they are: the app loads them through an account.
		XCTAssertEqual(app.iconURL?.absoluteString, "https://raw.githubusercontent.com/owner/repo/source/icon.png")
		// The first account can't see the repo, the second reads the source
		// and its releases, and nothing else.
		XCTAssertEqual(fake.requests.compactMap { $0.url?.path }, ["/repos/owner/repo/contents/source.json", "/repos/owner/repo/contents/source.json", "/repos/owner/repo/releases"])
		XCTAssertEqual(fake.apiTokens, ["personal", "work", "work"])
		XCTAssertEqual(fake.requests.first?.url?.absoluteString, "https://api.github.com/repos/owner/repo/contents/source.json?ref=source")
		XCTAssertEqual(accounts.account(for: file.repo), work)

		// Read again unchanged, it's one request.
		fake.clearRequests()
		guard case .notModified = try await source.fetch(file, etag: fetched.etag) else { return XCTFail("read again") }
		XCTAssertEqual(fake.apiTokens, ["work"])

		// Without an account, GitHub's API isn't asked: it can't see a private repo.
		fake.clearRequests()
		do {
			let none = GitHubAccounts(defaults: UserDefaults(suiteName: "GitHubAccountsTests.\(UUID().uuidString)")!, tokens: MemoryTokens()) { token in
				GitHubAPI(token: token, load: fake.load, loadWithoutRedirects: fake.load)
			}
			_ = try await GitHubSource(credentials: none, ipa: RemoteIPA(load: fake.load)).fetch(file)
			XCTFail("read without an account")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(file.repo, accounts: 0))
		}
		XCTAssertTrue(fake.requests.isEmpty)
	}

	/// A link to a file in a private repo's release, pasted in the Library
	/// or given by a source, downloads through an account that can see the
	/// repo, as github.com answers 404 for it (#134).
	func testAReleaseLinkDownloadsThroughAnAccountThatCanSeeTheRepo() async throws {
		let fake = FakeGitHub()
		releaseWithAnApp(fake)
		fake.addRelease(id: 2, tag: "app/v2.0", prerelease: true, date: "2026-10-20T10:00:00Z", assets: [(20, "App.ipa", ipa("com.example.app", name: "App", version: "2.0"))])
		fake.canSee = ["work"]
		let (accounts, _, work) = try twoAccounts(fake)
		func download(_ url: String) async throws -> URL? {
			let link = try XCTUnwrap(GitHubReleaseLink(url: URL(string: url)!))
			return try await accounts.first(for: link.repo) { try await $0.downloadURL(for: link) }.value
		}

		let first = try await download("https://github.com/Owner/Repo/releases/download/v1.0/App.ipa")
		XCTAssertEqual(first, URL(string: "https://storage.example/storage/10"))
		// The personal account can't see the repo, nor the release; the work
		// account finds the release by its tag, then where its file is.
		XCTAssertEqual(fake.requests.compactMap { $0.url?.path }, [
			"/repos/owner/repo/releases/tags/v1.0", "/repos/owner/repo",
			"/repos/owner/repo/releases/tags/v1.0", "/repos/Owner/Repo/releases/assets/10",
		])
		XCTAssertEqual(fake.apiTokens, ["personal", "personal", "work", "work"])
		XCTAssertEqual(accounts.account(for: repo), work)
		// The token never goes to the storage the file is in.
		XCTAssertFalse(fake.requests.contains { $0.url?.host == "storage.example" })

		// A tag with a slash in it, the latest release (which isn't a
		// pre-release), and a name in other capitals.
		fake.clearRequests()
		let slashed = try await download("https://github.com/owner/repo/releases/download/app/v2.0/App.ipa")
		XCTAssertEqual(slashed, URL(string: "https://storage.example/storage/20"))
		XCTAssertEqual(fake.requests.first?.url?.path, "/repos/owner/repo/releases/tags/app/v2.0")
		let latest = try await download("https://github.com/owner/repo/releases/latest/download/app.ipa")
		XCTAssertEqual(latest, URL(string: "https://storage.example/storage/10"))
		XCTAssertEqual(Set(fake.apiTokens), ["work"])

		// A release or file the repo doesn't have: the link as it is, for
		// github.com to answer.
		let noRelease = try await download("https://github.com/owner/repo/releases/download/v9/App.ipa")
		XCTAssertNil(noRelease)
		let noFile = try await download("https://github.com/owner/repo/releases/download/v1.0/Other.ipa")
		XCTAssertNil(noFile)

		// No account can see the repo: said so.
		fake.canSee = []
		do {
			_ = try await download("https://github.com/owner/repo/releases/download/v1.0/App.ipa")
			XCTFail("downloaded from a repo no account can see")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 2))
		}
	}

	func testAccountThatLostAccessHandsOver() async throws {
		let fake = FakeGitHub()
		releaseWithAnApp(fake)
		let (accounts, personal, work) = try twoAccounts(fake)
		accounts.remember(work, for: repo)
		fake.canSee = ["personal"]
		_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
		XCTAssertEqual(fake.apiTokens, ["work", "personal"])
		XCTAssertEqual(accounts.account(for: repo), personal)
		accounts.forget(repo)
		XCTAssertNil(accounts.account(for: repo))
	}

	func testPublicReposUseTheFirstAccount() async throws {
		let fake = FakeGitHub()
		let (accounts, personal, _) = try twoAccounts(fake)
		_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
		XCTAssertEqual(fake.apiTokens, ["personal"])
		XCTAssertEqual(accounts.account(for: repo), personal)
	}

	func testWithoutAccountsGitHubIsAskedWithoutAToken() async throws {
		let fake = FakeGitHub()
		let accounts = accounts(fake)
		_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
		XCTAssertEqual(fake.apiTokens, [""])
		XCTAssertNil(accounts.account(for: repo))
		fake.canSee = []
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a private repo without a token")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 0))
		}
	}

	func testNoAccountCanSeeAnOrganizationsRepo() async throws {
		let fake = FakeGitHub()
		fake.canSee = []
		let (accounts, _, _) = try twoAccounts(fake)
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a repo no account can see")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 2))
		}
		fake.ownerType = "Organization"
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a repo no account can see")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 2, organization: "owner"))
		}
	}

	func testAnOrganizationThatLimitsApps() async throws {
		let fake = FakeGitHub()
		fake.forbidden = "Although you appear to have the correct authorization credentials, the `owner` organization has enabled OAuth App access restrictions, meaning that data access to third-parties is limited."
		let accounts = accounts(fake)
		try accounts.add(token: "personal", login: "sample-user", kind: .signedIn)
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a repo the organization keeps from Atelier")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 1, organization: "owner"))
		}
	}

	func testARefusedSignInIsNamed() async throws {
		let fake = FakeGitHub()
		fake.canSee = []
		fake.refused = ["work"]
		let (accounts, _, _) = try twoAccounts(fake)
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a repo no account can see")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .badToken(account: "sample-acme"))
		}
	}

	func testOverTheLimitTriesAnotherAccount() async throws {
		let fake = FakeGitHub()
		fake.refused = ["personal"]
		let (accounts, _, work) = try twoAccounts(fake)
		_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
		XCTAssertEqual(accounts.account(for: repo), work)
		fake.refused = []
		fake.remaining = "0"
		do {
			_ = try await accounts.first(for: repo) { try await $0.repository(repo) }
			XCTFail("read a repo over the limit")
		} catch let problem as GitHubAPI.Problem {
			guard case .rateLimited(_, hasToken: true) = problem else { return XCTFail("\(problem)") }
		}
		XCTAssertEqual(fake.apiTokens.suffix(2), ["work", "personal"])
	}

	func testAdoptsTheTokenFromBefore() throws {
		let tokens = MemoryTokens(legacy: "old")
		let accounts = accounts(FakeGitHub(), tokens: tokens)
		tokens.isLocked = true
		XCTAssertThrowsError(try accounts.adoptLegacyToken(login: "sample-user"), "tried again once unlocked")
		XCTAssertEqual(accounts.all, [])

		tokens.isLocked = false
		let adopted = try XCTUnwrap(accounts.adoptLegacyToken(login: "sample-user"))
		XCTAssertEqual(adopted.kind, .signedIn)
		XCTAssertEqual(accounts.all, [adopted])
		XCTAssertEqual(tokens.token(for: adopted.id), "old")
		XCTAssertNil(try tokens.legacyToken())
		XCTAssertNil(try accounts.adoptLegacyToken(login: "sample-user"), "only once")

		let pasted = MemoryTokens(legacy: "github_pat_x")
		defaults = UserDefaults(suiteName: "GitHubAccountsTests.\(UUID().uuidString)")
		let fromToken = self.accounts(FakeGitHub(), tokens: pasted)
		let account = try XCTUnwrap(fromToken.adoptLegacyToken(login: nil))
		XCTAssertEqual(account.kind, .token)
		XCTAssertNil(account.login)
	}

	func testWhoseTokenItIs() async throws {
		let fake = FakeGitHub()
		fake.logins = ["github_pat_x": "sample-user"]
		let user = try await GitHubAPI(token: { "github_pat_x" }, load: fake.load).user()
		XCTAssertEqual(user, GitHubAPI.User(login: "sample-user", avatarURL: URL(string: "https://avatars.example/sample-user")))
		do {
			_ = try await GitHubAPI(token: { "nobody" }, load: fake.load).user()
			XCTFail("a token GitHub doesn't know")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .badToken())
		}
	}

	func testAssetsRepo() {
		XCTAssertEqual(GitHubAPI.repo(ofAsset: URL(string: "https://api.github.com/repos/Owner/Repo/releases/assets/10")!), repo)
		XCTAssertNil(GitHubAPI.repo(ofAsset: URL(string: "https://github.com/Owner/Repo/releases/download/v1/App.ipa")!))
		XCTAssertNil(GitHubAPI.repo(ofAsset: URL(string: "https://api.github.com/repos/Owner/Repo/releases/assets")!))
	}
}
