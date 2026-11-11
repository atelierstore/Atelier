import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads and parses a source, asking the server whether it changed first
/// (ETag / If-Modified-Since) so a refresh of an unchanged source costs one
/// small request (#13).
public struct SourceFetcher: Sendable {
	public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	/// A source as the server sent it.
	public struct Fetched: Sendable {
		public var data: Data
		public var parsed: SourceParser.Result
		/// Validators for the next refresh, when the server sent them.
		public var etag: String?
		public var lastModified: String?

		public init(data: Data, parsed: SourceParser.Result, etag: String? = nil, lastModified: String? = nil) {
			self.data = data
			self.parsed = parsed
			self.etag = etag
			self.lastModified = lastModified
		}
	}

	public enum Outcome: Sendable {
		case fetched(Fetched)
		/// The server says the copy Atelier has is current (HTTP 304).
		case notModified
	}

	public enum Problem: Error, Equatable, CustomStringConvertible {
		/// The server redirected to a URL that isn't HTTPS.
		case notHTTPS
		case status(Int)
		case tooLarge
		case notASource(String)

		public var description: String {
			switch self {
			case .notHTTPS: "This source sends Atelier to an address that isn't secure, so Atelier stopped."
			case .status(let code):
				switch code {
				case 404: "Nothing was found at this address. Check it and try again."
				case 401, 403: "This source isn't public."
				case 500...599: "The source's server had a problem. Try again later."
				default: "The source's server refused the request (error \(code))."
				}
			case .tooLarge: "The source is too large."
			case .notASource: "This address doesn't lead to an app source. Check that you copied the whole address."
			}
		}
	}

	/// Sources are JSON metadata; even AltStore's own is a few megabytes.
	public static let maximumSize = 50_000_000

	private let load: Load

	public init(load: @escaping Load = { try await URLSession.shared.data(for: $0) }) {
		self.load = load
	}

	/// Fetches `url`, conditionally when `etag` or `lastModified` are given.
	public func fetch(_ url: URL, etag: String? = nil, lastModified: String? = nil) async throws -> Outcome {
		var request = URLRequest(url: url, timeoutInterval: 30)
		// Atelier keeps the source and its validators itself, so a cached
		// response must not stand in for the server's 304.
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
		if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

		let (data, response) = try await load(request)
		if let final = response.url, final.scheme?.lowercased() != "https" { throw Problem.notHTTPS }
		let http = response as? HTTPURLResponse
		let status = http?.statusCode ?? 200
		if status == 304 { return .notModified }
		guard (200..<300).contains(status) else { throw Problem.status(status) }
		guard data.count <= Self.maximumSize else { throw Problem.tooLarge }

		let parsed: SourceParser.Result
		do {
			parsed = try SourceParser.parse(data)
		} catch {
			throw Problem.notASource(String(describing: error))
		}
		return .fetched(Fetched(
			data: data,
			parsed: parsed,
			etag: http?.value(forHTTPHeaderField: "ETag"),
			lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
		))
	}
}
