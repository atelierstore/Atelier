#if canImport(Network)
import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.atelier", category: "LoopbackServer")

private func log(_ message: String) {
	logger.info("\(message, privacy: .public)")
}

/// Serves one or more IPAs on 127.0.0.1 only, for route B: iOS's installer
/// fetches them from the URLs in the install manifest.
///
/// Feather's server binds 0.0.0.0, which also exposes the IPA to the local
/// network; binding loopback avoids that.
public final class LoopbackServer: @unchecked Sendable {
	public struct Package: Sendable {
		public let fileURL: URL
		/// Unguessable path, so another app on the device can't fetch the IPA
		/// by guessing the URL while the server runs.
		public let path = "/\(UUID().uuidString).ipa"
	}

	public let packages: [Package]
	/// Package index, bytes sent, bytes total.
	public var onPayloadProgress: ((Int, Int64, Int64) -> Void)?
	/// A request for a package arrived: package index, HTTP method. iOS only
	/// asks once the user has accepted its install alert.
	public var onRequest: ((Int, String) -> Void)?
	/// A GET of a package ended: package index, and whether the whole file was
	/// sent (a range request that ends well reports false).
	public var onPayloadEnded: ((Int, Bool) -> Void)?

	private let queue = DispatchQueue(label: "com.atelier.loopback")
	private var listener: NWListener?

	public init(fileURLs: [URL]) {
		packages = fileURLs.map { Package(fileURL: $0) }
	}

	/// The URL a package is served at once the server listens on `port`.
	public func url(of package: Package, port: UInt16) -> URL {
		URL(string: "http://127.0.0.1:\(port)\(package.path)")!
	}

	/// How a package path appears in the log: the token stays out of it.
	private func logName(_ path: String) -> String {
		guard let index = packages.firstIndex(where: { $0.path == path }) else { return path }
		return packages.count == 1 ? "/<token>.ipa" : "/<token \(index + 1)>.ipa"
	}

	/// Listens on a random port and returns it.
	public func start() async throws -> UInt16 {
		var lastError: Error?
		for _ in 0..<5 {
			let port = UInt16.random(in: 20000...40000)
			do {
				try await listen(on: port)
				return port
			} catch {
				lastError = error
				log("[server] port \(port) failed: \(error)")
			}
		}
		throw lastError ?? NWError.posix(.EADDRINUSE)
	}

	public func stop() {
		listener?.cancel()
		listener = nil
	}

	private func listen(on port: UInt16) async throws {
		let params = NWParameters.tcp
		params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
		params.allowLocalEndpointReuse = true
		let listener = try NWListener(using: params)
		listener.newConnectionHandler = { [weak self] connection in
			self?.accept(connection)
		}

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			var resumed = false
			listener.stateUpdateHandler = { state in
				guard !resumed else {
					if case .failed(let error) = state { log("[server] listener failed: \(error)") }
					return
				}
				switch state {
				case .ready:
					resumed = true
					continuation.resume()
				case .failed(let error):
					resumed = true
					continuation.resume(throwing: error)
				default:
					break
				}
			}
			listener.start(queue: queue)
		}
		self.listener = listener
		log("[server] listening on 127.0.0.1:\(port)")
	}

	// MARK: Connections

	private func accept(_ connection: NWConnection) {
		connection.start(queue: queue)
		receiveHead(connection, buffer: Data())
	}

	private func receiveHead(_ connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
			guard let self else { return }
			var buffer = buffer
			if let data { buffer.append(data) }
			do {
				if let head = try HTTPRequestHead.parse(buffer) {
					self.respond(to: head, on: connection)
				} else if isComplete || error != nil {
					connection.cancel()
				} else {
					self.receiveHead(connection, buffer: buffer)
				}
			} catch {
				self.sendSimple(connection, status: 400, reason: "Bad Request")
			}
		}
	}

	private func respond(to head: HTTPRequestHead, on connection: NWConnection) {
		let agent = head.headers["user-agent"] ?? "-"
		let range = head.headers["range"].map { " range=\($0)" } ?? ""
		log("[server] \(head.method) \(logName(head.path))\(range) ua=\(agent)")

		guard head.method == "GET" || head.method == "HEAD" else {
			sendSimple(connection, status: 405, reason: "Method Not Allowed")
			return
		}

		if let index = packages.firstIndex(where: { $0.path == head.path }) {
			onRequest?(index, head.method)
			servePackage(index, head, on: connection)
		} else {
			sendSimple(connection, status: 404, reason: "Not Found")
		}
	}

	private func servePackage(_ index: Int, _ head: HTTPRequestHead, on connection: NWConnection) {
		let fileURL = packages[index].fileURL
		guard
			let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
			let size = (attributes[.size] as? NSNumber)?.intValue,
			let handle = try? FileHandle(forReadingFrom: fileURL)
		else {
			sendSimple(connection, status: 500, reason: "Internal Server Error")
			return
		}

		let range: ByteRange?
		do {
			range = try ByteRange.parse(head.headers["range"], fileSize: size)
		} catch {
			try? handle.close()
			send(connection, HTTPResponseHead.make(status: 416, reason: "Range Not Satisfiable", headers: [("Content-Range", "bytes */\(size)")]), close: true)
			return
		}

		let start = range?.start ?? 0
		let length = range?.length ?? size
		var headers = [
			("Content-Type", "application/octet-stream"),
			("Content-Length", "\(length)"),
			("Accept-Ranges", "bytes"),
		]
		if let range {
			headers.append(("Content-Range", "bytes \(range.start)-\(range.end)/\(size)"))
		}
		let status = range == nil ? (200, "OK") : (206, "Partial Content")
		// A HEAD response is only the head: close once it has gone out, not
		// before, or the client may never see it.
		let headOnly = head.method != "GET"
		send(connection, HTTPResponseHead.make(status: status.0, reason: status.1, headers: headers), close: headOnly)

		guard !headOnly else {
			try? handle.close()
			return
		}

		do {
			try handle.seek(toOffset: UInt64(start))
		} catch {
			try? handle.close()
			onPayloadEnded?(index, false)
			connection.cancel()
			return
		}
		sendChunks(connection, index: index, handle: handle, remaining: length, sent: 0, total: Int64(length), whole: length == size)
	}

	private func sendChunks(_ connection: NWConnection, index: Int, handle: FileHandle, remaining: Int, sent: Int64, total: Int64, whole: Bool) {
		guard remaining > 0 else {
			try? handle.close()
			log("[server] payload sent: \(total) bytes\(packages.count == 1 ? "" : " (app \(index + 1))")")
			onPayloadEnded?(index, whole)
			connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
			return
		}
		let chunk = (try? handle.read(upToCount: min(remaining, 1 << 20))) ?? Data()
		guard !chunk.isEmpty else {
			try? handle.close()
			onPayloadEnded?(index, false)
			connection.cancel()
			return
		}
		connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
			if let error {
				try? handle.close()
				log("[server] payload send failed after \(sent) bytes: \(error)")
				self?.onPayloadEnded?(index, false)
				connection.cancel()
				return
			}
			let newSent = sent + Int64(chunk.count)
			self?.onPayloadProgress?(index, newSent, total)
			self?.sendChunks(connection, index: index, handle: handle, remaining: remaining - chunk.count, sent: newSent, total: total, whole: whole)
		})
	}

	private func sendSimple(_ connection: NWConnection, status: Int, reason: String) {
		send(connection, HTTPResponseHead.make(status: status, reason: reason, headers: [("Content-Length", "0")]), close: true)
	}

	private func send(_ connection: NWConnection, _ data: Data, close: Bool) {
		connection.send(content: data, completion: .contentProcessed { _ in
			if close { connection.cancel() }
		})
	}
}
#endif
