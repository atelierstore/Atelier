#if canImport(SwiftData)
import Foundation
import GitHubKit
import SourceKit
import SwiftData
import XCTest
@testable import AtelierCore

@MainActor
final class SourceLibraryTests: XCTestCase {
	private let url = URL(string: "https://example.com/apps.json")!
	private var container: ModelContainer!
	private var server: FakeServer!
	private var library: SourceLibrary!
	private var prereleases: PrereleasePreferences!

	override func setUp() async throws {
		container = try Persistence.makeContainer(inMemory: true)
		server = FakeServer()
		prereleases = PrereleasePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: "SourceLibraryTests.\(UUID().uuidString)")))
		library = SourceLibrary(context: container.mainContext, fetcher: SourceFetcher(load: server.load), prereleases: prereleases)
	}

	private func source(name: String, apps: [(String, String)]) -> Data {
		let apps = apps.map { bundleID, version in
			#"{"name": "\#(bundleID)", "bundleIdentifier": "\#(bundleID)", "versions": [{"version": "\#(version)", "downloadURL": "https://example.com/\#(bundleID).ipa"}]}"#
		}
		return Data(#"{"name": "\#(name)", "apps": [\#(apps.joined(separator: ","))]}"#.utf8)
	}

	private func added() async throws -> SourceRecord {
		server.respond(200, source(name: "Example", apps: [("com.example.a", "1.0"), ("com.example.b", "2.0")]), etag: "\"v1\"")
		return try library.add(try await library.preview("example.com/apps.json"))
	}

	func testPreviewsThenAdds() async throws {
		server.respond(200, source(name: "Example", apps: [("com.example.a", "1.0")]))
		let preview = try await library.preview("altstore://source?url=https%3A%2F%2Fexample.com%2Fapps.json")
		XCTAssertEqual(preview.url, url)
		XCTAssertEqual(preview.domain, "example.com")
		XCTAssertEqual(preview.source.name, "Example")
		XCTAssertTrue(try library.sources().isEmpty, "Previewing must not add the source")

		let record = try library.add(preview)
		XCTAssertEqual(record.name, "Example")
		XCTAssertEqual(record.apps.map(\.bundleID), ["com.example.a"])
		XCTAssertNotNil(record.json)
		XCTAssertNotNil(record.lastRefreshedAt)
		XCTAssertNotNil(try record.parsed())
	}

	func testRefusesASourceAddedTwice() async throws {
		_ = try await added()
		do {
			_ = try await library.preview("https://EXAMPLE.com/apps.json")
			XCTFail("Expected the source to be refused")
		} catch {
			XCTAssertEqual(error as? SourceLibrary.Problem, .alreadyAdded(name: "Example"))
		}
	}

	func testRefreshAsksWhetherTheSourceChanged() async throws {
		let record = try await added()
		server.respond(304, Data())
		await library.refresh(record)
		XCTAssertEqual(server.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
		XCTAssertEqual(record.apps.count, 2)
		XCTAssertNil(record.refreshError)
	}

	func testRefreshUpdatesAppsInPlace() async throws {
		let record = try await added()
		let a = try XCTUnwrap(record.apps.first { $0.bundleID == "com.example.a" })
		server.respond(200, source(name: "Renamed", apps: [("com.example.c", "1.0"), ("com.example.a", "1.1")]), etag: "\"v2\"")
		await library.refresh(record)

		XCTAssertEqual(record.name, "Renamed")
		XCTAssertEqual(record.etag, "\"v2\"")
		let apps = record.apps.sorted { $0.position < $1.position }
		XCTAssertEqual(apps.map(\.bundleID), ["com.example.c", "com.example.a"])
		XCTAssertTrue(apps[1] === a, "An app still listed keeps its record")
		XCTAssertEqual(a.latestVersion, "1.1")
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<AppRecord>()), 2)
	}

	func testAFailedRefreshKeepsWhatTheSourceHad() async throws {
		let record = try await added()
		server.fail(URLError(.notConnectedToInternet))
		await library.refresh(record)
		XCTAssertEqual(record.apps.count, 2)
		XCTAssertNotNil(record.refreshError)

		server.respond(304, Data())
		await library.refresh(record)
		XCTAssertNil(record.refreshError)
	}

	/// A source kept in a private GitHub repo, which raw.githubusercontent.com
	/// and GitHub's API both answer 404 for without a GitHub account to read
	/// it with: it asks to sign in (#134). Adding one still says what the
	/// server said, and a 404 elsewhere is the server's, as before.
	func testASourceInAGitHubRepoAsksToSignInWithoutAnAccount() async throws {
		// Signed out, GitHub's API is asked too, without a token, so the
		// fake server answers for GitHub as well.
		library = SourceLibrary(
			context: container.mainContext,
			fetcher: SourceFetcher(load: server.load),
			gitHub: GitHubSource(api: GitHubAPI(load: server.load)),
			prereleases: prereleases
		)
		let raw = URL(string: "https://raw.githubusercontent.com/owner/repo/main/source.json")!
		server.respond(404, Data())
		do {
			_ = try await library.preview(raw.absoluteString)
			XCTFail("previewed a source the server didn't send")
		} catch {
			XCTAssertEqual(error as? SourceFetcher.Problem, .status(404))
		}

		let builtIn = try library.addBuiltIn(at: raw, name: "Atelier")
		await library.refresh(builtIn)
		XCTAssertEqual(builtIn.refreshError, "Sign in to GitHub to load it.")
		XCTAssertTrue(builtIn.needsGitHubSignIn)
		XCTAssertEqual(server.lastRequest?.url?.path, "/repos/owner/repo", "it asked GitHub's API whether the repo is there")
		XCTAssertNil(server.lastRequest?.value(forHTTPHeaderField: "Authorization"))

		let other = try library.addBuiltIn(at: url, name: "Example")
		await library.refresh(other)
		XCTAssertEqual(other.refreshError, "Nothing was found at this address. Check it and try again.")
		XCTAssertFalse(other.needsGitHubSignIn)
	}

	/// A GitHub repo added as a source, which GitHub's API answers 404 for
	/// while it's private, without an account: it asks to sign in too
	/// (#134). Adding one still says GitHub can't find it, as before.
	func testAPrivateRepoAddedAsASourceAsksToSignInWithoutAnAccount() async throws {
		library = SourceLibrary(
			context: container.mainContext,
			fetcher: SourceFetcher(load: server.load),
			gitHub: GitHubSource(api: GitHubAPI(load: server.load)),
			prereleases: prereleases
		)
		let repo = GitHubRepo(owner: "owner", name: "repo")
		server.respond(404, Data())
		do {
			_ = try await library.preview("https://github.com/owner/repo")
			XCTFail("previewed a repo GitHub didn't find")
		} catch {
			XCTAssertEqual(error as? GitHubAPI.Problem, .notFound(repo, accounts: 0))
		}

		let record = try library.addBuiltIn(at: repo.sourceURL, name: "Repo")
		await library.refresh(record)
		XCTAssertEqual(record.refreshError, "Sign in to GitHub to load it.")
		XCTAssertTrue(record.needsGitHubSignIn)
		XCTAssertEqual(server.lastRequest?.url?.path, "/repos/owner/repo", "it asked GitHub's API")
	}

	func testRemovingASourceKeepsItsInstalls() async throws {
		let record = try await added()
		let install = InstallRecord(bundleID: "com.example.a", name: "A", version: "1.0")
		install.sourceURL = url
		container.mainContext.insert(install)
		try container.mainContext.save()
		XCTAssertFalse(library.hasRemovedSource(install))

		try library.remove(record)
		XCTAssertTrue(try library.sources().isEmpty)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<AppRecord>()), 0)
		XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<InstallRecord>()).map(\.bundleID), ["com.example.a"])
		XCTAssertTrue(library.hasRemovedSource(install))
	}

	/// A source's betas are among its apps only while the user includes
	/// them (#104), and switching reads nothing again.
	func testBetasAreListedOnlyWhileIncluded() async throws {
		server.respond(200, Data(#"""
			{"name": "Example", "apps": [
				{"name": "A", "bundleIdentifier": "com.example.a", "versions": [
					{"version": "2.0b1", "atelierPrerelease": true, "downloadURL": "https://example.com/a-2.0b1.ipa"},
					{"version": "1.0", "downloadURL": "https://example.com/a-1.0.ipa"}
				]},
				{"name": "B", "bundleIdentifier": "com.example.b", "beta": true, "versions": [
					{"version": "1.0", "downloadURL": "https://example.com/b.ipa"}
				]}
			]}
			"""#.utf8))
		let record = try library.add(try await library.preview("example.com/apps.json"))
		XCTAssertEqual(record.apps.map(\.bundleID), ["com.example.a"])
		XCTAssertEqual(record.apps.first?.latestVersion, "1.0")
		XCTAssertFalse(prereleases.includes(url))

		server.fail(URLError(.notConnectedToInternet))
		library.setIncludesPrereleases(true, for: record)
		XCTAssertEqual(record.apps.sorted { $0.position < $1.position }.map(\.bundleID), ["com.example.a", "com.example.b"])
		XCTAssertEqual(record.apps.first { $0.bundleID == "com.example.a" }?.latestVersion, "2.0b1")
		XCTAssertTrue(prereleases.includes(url))

		try library.remove(record)
		XCTAssertFalse(prereleases.includes(url), "added again, it starts off")
	}

	/// The source that's there without the user adding it, Atelier's own,
	/// starts with its betas listed, as Atelier's releases are alphas for
	/// now (#104, #24). Turned off, it hides them as any source does, and
	/// keeps its switch the next time it's put in.
	func testABuiltInSourceStartsWithItsBetas() async throws {
		server.respond(200, Data(#"""
			{"name": "Atelier", "apps": [
				{"name": "Atelier", "bundleIdentifier": "com.atelier.app", "beta": true, "versions": [
					{"version": "0.2.0", "buildVersion": "323", "marketingVersion": "0.2.0-alpha", "downloadURL": "https://example.com/atelier.ipa"}
				]}
			]}
			"""#.utf8))
		let builtIn = try library.addBuiltIn(at: url, name: "Atelier")
		XCTAssertTrue(prereleases.includes(url))
		await library.refresh(builtIn)
		XCTAssertEqual(builtIn.apps.map(\.latestVersion), ["0.2.0-alpha"])

		library.setIncludesPrereleases(false, for: builtIn)
		XCTAssertTrue(builtIn.apps.isEmpty)
		XCTAssertTrue(try library.addBuiltIn(at: url, name: "Atelier") === builtIn)
		XCTAssertFalse(prereleases.includes(url), "it keeps its switch")
	}
}

/// Answers every request with the last response it was given.
final class FakeServer: @unchecked Sendable {
	private let lock = NSLock()
	private var response: Result<(Int, Data, [String: String]), Error> = .success((404, Data(), [:]))
	private(set) var lastRequest: URLRequest?

	func respond(_ status: Int, _ body: Data, etag: String? = nil) {
		lock.withLock { response = .success((status, body, etag.map { ["ETag": $0] } ?? [:])) }
	}

	func fail(_ error: Error) {
		lock.withLock { response = .failure(error) }
	}

	var load: SourceFetcher.Load {
		{ [self] request in
			let response = lock.withLock {
				lastRequest = request
				return self.response
			}
			let (status, body, headers) = try response.get()
			return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
		}
	}
}
#endif
