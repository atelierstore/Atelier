import Foundation
import InstallKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Checks that a finished download is the IPA the source describes. The
/// AltStore spec has no checksum, so this is the size the source gives, an
/// archive that looks like an app, and a `sha256` when a source adds one.
public enum DownloadVerifier {
	public enum Problem: Error, Equatable, CustomStringConvertible {
		/// The server answered with an error status.
		case httpStatus(Int)
		case empty
		/// The server sent a web page (an error or login page, say) instead.
		case webPage
		/// Not a ZIP, or a ZIP without `Payload/<App>.app/`.
		case notAnIPA
		case sizeMismatch(expected: Int64, actual: Int64)
		case checksumMismatch

		public var description: String {
			switch self {
			case .httpStatus(let code):
				switch code {
				case 404: "The app's file isn't there any more. The source may be out of date."
				case 401, 403: "The server didn't allow the download. The link may have expired or need a login."
				case 500...599: "The server had a problem. Try again later."
				default: "The server refused the download (error \(code))."
				}
			case .empty:
				"The server sent an empty file."
			case .webPage:
				"The server sent a web page instead of the app. The link may have expired or need a login."
			case .notAnIPA:
				"The downloaded file isn't an app (IPA)."
			case .sizeMismatch:
				"The downloaded file isn't the size the source lists. The source may be out of date, or the file was changed."
			case .checksumMismatch:
				"The downloaded file doesn't match what the source lists, so it may have been changed."
			}
		}
	}

	/// Checks the file at `url`. Hashing streams the file, so a large IPA isn't
	/// read into memory.
	public static func verify(fileAt url: URL, expectedSize: Int64?, sha256: String?) throws {
		let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		guard size > 0 else { throw Problem.empty }

		let head = try FileHandle(forReadingFrom: url).readPrefix(512)
		if looksLikeWebPage(head) { throw Problem.webPage }
		guard head.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw Problem.notAnIPA }

		if let expectedSize, expectedSize != size {
			throw Problem.sizeMismatch(expected: expectedSize, actual: size)
		}

		let data = try Data(contentsOf: url, options: .alwaysMapped)
		do {
			guard try ZipReader(data: data).containsEntry(where: isAppEntry) else { throw Problem.notAnIPA }
		} catch IPAInfo.Error.zip64Unsupported {
			// Over 65,535 files or 4 GB: too big for InstallKit's reader to
			// check, but signing's reader handles it and will say if it's broken.
		} catch let problem as Problem {
			throw problem
		} catch {
			throw Problem.notAnIPA
		}

		if let expected = normalizedHash(sha256), let actual = try sha256Hex(of: url), actual != expected {
			throw Problem.checksumMismatch
		}
	}

	/// `Payload/<App>.app/…`, the layout every IPA has.
	static func isAppEntry(_ path: String) -> Bool {
		let parts = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
		return parts.count >= 2 && parts[0] == "Payload" && parts[1].count > 4 && parts[1].hasSuffix(".app")
	}

	/// HTML or XML, possibly after a byte-order mark and whitespace.
	static func looksLikeWebPage(_ head: Data) -> Bool {
		var bytes = head[...]
		if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
		guard let first = bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return false }
		return first == UInt8(ascii: "<")
	}

	/// Lowercase hex of 64 digits, or nil for a missing or malformed value,
	/// which is ignored like any other field Atelier doesn't know.
	static func normalizedHash(_ hash: String?) -> String? {
		guard let hash = hash?.trimmingCharacters(in: .whitespaces).lowercased(),
		      hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
		return hash
	}

	/// Nil where CryptoKit isn't available (Linux, for the package tests).
	static func sha256Hex(of url: URL) throws -> String? {
		#if canImport(CryptoKit)
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
		#else
		return nil
		#endif
	}
}

private extension FileHandle {
	func readPrefix(_ count: Int) throws -> Data {
		defer { try? close() }
		return try read(upToCount: count) ?? Data()
	}
}
