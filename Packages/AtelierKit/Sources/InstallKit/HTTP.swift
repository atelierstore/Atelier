import Foundation

/// Just enough HTTP/1.1 for iOS's installer to fetch one IPA from loopback.
public struct HTTPRequestHead: Equatable, Sendable {
	public var method: String
	public var path: String
	public var headers: [String: String]

	/// Parses the request head if `buffer` holds a complete one. Returns nil
	/// while more bytes are needed; throws on garbage.
	public static func parse(_ buffer: Data) throws -> HTTPRequestHead? {
		guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
			if buffer.count > 16 * 1024 { throw ParseError.headTooLarge }
			return nil
		}
		guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
			throw ParseError.malformed
		}
		var lines = text.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ")
		guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw ParseError.malformed }

		var headers: [String: String] = [:]
		for line in lines where !line.isEmpty {
			guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
			let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			headers[name] = value
		}
		let target = String(requestLine[1])
		let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
		return HTTPRequestHead(method: String(requestLine[0]), path: path, headers: headers)
	}

	public enum ParseError: Error, Equatable {
		case malformed
		case headTooLarge
	}
}

/// A single `Range: bytes=` request, resolved against the file size.
public struct ByteRange: Equatable, Sendable {
	public var start: Int
	public var end: Int // inclusive

	public var length: Int { end - start + 1 }

	/// Returns nil for a missing or unsupported header (serve the whole file),
	/// and throws `unsatisfiable` when the range is outside the file.
	public static func parse(_ header: String?, fileSize: Int) throws -> ByteRange? {
		guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
		let spec = header.dropFirst("bytes=".count)
		let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.count == 2 else { return nil }

		if parts[0].isEmpty {
			guard let suffix = Int(parts[1]), suffix > 0 else { throw RangeError.unsatisfiable }
			return ByteRange(start: max(0, fileSize - suffix), end: fileSize - 1)
		}
		guard let start = Int(parts[0]), start < fileSize else { throw RangeError.unsatisfiable }
		let end = parts[1].isEmpty ? fileSize - 1 : min(Int(parts[1]) ?? -1, fileSize - 1)
		guard end >= start else { throw RangeError.unsatisfiable }
		return ByteRange(start: start, end: end)
	}

	public enum RangeError: Error, Equatable {
		case unsatisfiable
	}
}

public enum HTTPResponseHead {
	public static func make(status: Int, reason: String, headers: [(String, String)]) -> Data {
		var text = "HTTP/1.1 \(status) \(reason)\r\n"
		for (name, value) in headers + [("Connection", "close")] {
			text += "\(name): \(value)\r\n"
		}
		text += "\r\n"
		return Data(text.utf8)
	}
}
