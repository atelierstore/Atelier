import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where Atelier's anisette list comes from (#49): the worker, asked before
/// each sign-in; else the list it gave last, kept in a folder; else the copy
/// built into Atelier, or that one if it's newer than the kept one. It also
/// remembers the server the last sign-in worked through, so the next one
/// starts there.
public struct AnisetteListSource: Sendable {
	public enum Origin: Equatable, Sendable {
		/// Just now, from the worker.
		case worker
		/// The worker's answer from that date, as it didn't answer now.
		case kept(Date)
		/// The copy built into Atelier.
		case builtIn
	}

	/// Atelier's worker, the one that serves its install manifests.
	public static let defaultURL = URL(string: "https://api.atelierstore.app/anisette")!

	public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	private let folder: URL
	private let url: URL
	private let fetch: Fetch
	private let builtIn: AnisetteList

	/// Keeps the worker's last answer and the last server that worked in
	/// `folder`, which has to exist.
	public init(
		folder: URL,
		url: URL = defaultURL,
		builtIn: AnisetteList = .builtIn,
		fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
	) {
		self.folder = folder
		self.url = url
		self.builtIn = builtIn
		self.fetch = fetch
	}

	private var listFile: URL { folder.appendingPathComponent("anisette-list.json") }
	private var lastWorkedFile: URL { folder.appendingPathComponent("anisette-last-worked.txt") }

	/// The list to sign in with, and where it came from. The worker gets a
	/// few seconds; a sign-in waits for this.
	public func current() async -> (list: AnisetteList, origin: Origin) {
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let (data, response) = try? await fetch(request),
		   (response as? HTTPURLResponse)?.statusCode == 200,
		   let list = try? AnisetteList(json: data) {
			try? data.write(to: listFile, options: .atomic)
			return (list, .worker)
		}
		if let data = try? Data(contentsOf: listFile),
		   let list = try? AnisetteList(json: data),
		   list.updated >= builtIn.updated {
			let saved = (try? FileManager.default.attributesOfItem(atPath: listFile.path)[.modificationDate]) as? Date
			return (list, .kept(saved ?? .distantPast))
		}
		return (builtIn, .builtIn)
	}

	/// The server the last sign-in worked through.
	public var lastWorked: URL? {
		guard let data = try? Data(contentsOf: lastWorkedFile),
		      let string = String(data: data, encoding: .utf8)
		else { return nil }
		return AnisetteList.serverURL(string)
	}

	public func setLastWorked(_ server: URL) {
		try? Data(server.absoluteString.utf8).write(to: lastWorkedFile, options: .atomic)
	}
}
