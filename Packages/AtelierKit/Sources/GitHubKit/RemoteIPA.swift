import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InstallKit

/// Reads an IPA's `Info.plist` and app icon over HTTP range requests, without
/// downloading the app (#30). An IPA is a ZIP, so its table of contents is
/// at the end: one request for the end, one for the table if it didn't fit,
/// then one per file.
///
/// Ranges are absolute (`bytes=a-b`), from the size GitHub lists: github.com
/// refuses suffix ranges (`bytes=-n`) with HTTP 501, checked on 22 Oct 2026.
public struct RemoteIPA: Sendable {
	public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

	/// What Atelier lists the app by.
	public struct Info: Sendable, Equatable {
		public var bundleID: String
		public var name: String
		public var version: String
		public var build: String?
		public var minimumOSVersion: String?
		/// The app icon's PNG, as stored in the app (Apple's iPhone PNG
		/// variant, which iOS draws). Nil when there's no loose icon file.
		public var icon: Data?
	}

	public enum Problem: Error, Equatable {
		case status(Int)
		case notAZip
		case zip64
		case noInfoPlist
		case invalidInfoPlist
		case unsupportedCompression(UInt16)
		case encrypted
		case tooLarge
	}

	/// How much to read from the end first: enough for the end record and,
	/// for most apps, the whole table of contents.
	static let tailSize: Int64 = 128 * 1024
	/// The table and files Atelier reads are small; anything larger is
	/// either broken or not worth it.
	static let maximumTable: Int64 = 8 * 1024 * 1024
	static let maximumInfoPlist: Int64 = 1024 * 1024
	static let maximumIcon: Int64 = 512 * 1024

	private let load: Load

	public init(load: @escaping Load = { try await URLSession.shared.data(for: $0) }) {
		self.load = load
	}

	/// Reads the IPA at `url`, which must take range requests, and is `size`
	/// bytes long.
	public func read(_ url: URL, size: Int64) async throws -> Info {
		guard size >= 22 else { throw Problem.notAZip }
		let tailStart = max(0, size - Self.tailSize)
		let tail = try await range(url, tailStart, size - 1)
		let table = try await centralDirectory(url, tail: tail, tailStart: tailStart, size: size)
		let entries = try Self.entries(table)

		guard let plistEntry = entries.first(where: { Self.isTopLevel($0.path, file: "Info.plist") }) else {
			throw Problem.noInfoPlist
		}
		let plistData = try await contents(of: plistEntry, in: url, size: size, limit: Self.maximumInfoPlist)
		guard let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
			let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
		else { throw Problem.invalidInfoPlist }

		let appFolder = plistEntry.path.dropLast("Info.plist".count)
		var icon: Data?
		if let iconEntry = Self.iconEntry(plist: plist, appFolder: String(appFolder), entries: entries) {
			// An icon that can't be read just leaves the app without one.
			icon = try? await contents(of: iconEntry, in: url, size: size, limit: Self.maximumIcon)
		}
		let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "1.0"
		let name = [plist["CFBundleDisplayName"], plist["CFBundleName"]]
			.compactMap { $0 as? String }
			.first { !$0.isEmpty } ?? bundleID
		return Info(
			bundleID: bundleID,
			name: name,
			version: version,
			build: plist["CFBundleVersion"] as? String,
			minimumOSVersion: plist["MinimumOSVersion"] as? String,
			icon: icon
		)
	}

	// MARK: ZIP

	struct Entry: Equatable {
		var path: String
		var method: UInt16
		var flags: UInt16
		var compressedSize: Int64
		var size: Int64
		var localOffset: Int64
	}

	/// The central directory, from the tail when it's in there.
	private func centralDirectory(_ url: URL, tail: Data, tailStart: Int64, size: Int64) async throws -> Data {
		let bytes = [UInt8](tail)
		guard let eocd = Self.lastIndex(of: 0x0605_4B50, in: bytes, from: bytes.count - 22) else { throw Problem.notAZip }
		var tableSize = Int64(Self.u32(bytes, eocd + 12))
		var tableOffset = Int64(Self.u32(bytes, eocd + 16))
		if tableSize == 0xFFFF_FFFF || tableOffset == 0xFFFF_FFFF || Self.u16(bytes, eocd + 10) == 0xFFFF {
			// ZIP64: the locator sits just before the end record and points
			// at the ZIP64 end record, which has the real numbers.
			let locator = eocd - 20
			guard locator >= 0, Self.u32(bytes, locator) == 0x0706_4B50 else { throw Problem.zip64 }
			let recordOffset = Int64(Self.u64(bytes, locator + 8))
			let record: [UInt8]
			if recordOffset >= tailStart {
				record = Array(bytes[Int(recordOffset - tailStart)...])
			} else {
				record = [UInt8](try await range(url, recordOffset, min(size - 1, recordOffset + 55)))
			}
			guard record.count >= 56, Self.u32(record, 0) == 0x0606_4B50 else { throw Problem.zip64 }
			tableSize = Int64(Self.u64(record, 40))
			tableOffset = Int64(Self.u64(record, 48))
		}
		guard tableSize <= Self.maximumTable, tableOffset + tableSize <= size else { throw Problem.notAZip }
		if tableOffset >= tailStart {
			let start = Int(tableOffset - tailStart)
			guard start + Int(tableSize) <= bytes.count else { throw Problem.notAZip }
			return Data(bytes[start..<(start + Int(tableSize))])
		}
		guard tableSize > 0 else { return Data() }
		return try await range(url, tableOffset, tableOffset + tableSize - 1)
	}

	static func entries(_ table: Data) throws -> [Entry] {
		let b = [UInt8](table)
		var entries: [Entry] = []
		var p = 0
		while p + 46 <= b.count, u32(b, p) == 0x0201_4B50 {
			let nameLength = Int(u16(b, p + 28))
			let extraLength = Int(u16(b, p + 30))
			let commentLength = Int(u16(b, p + 32))
			guard p + 46 + nameLength + extraLength <= b.count else { throw Problem.notAZip }
			var entry = Entry(
				path: String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self),
				method: u16(b, p + 10),
				flags: u16(b, p + 8),
				compressedSize: Int64(u32(b, p + 20)),
				size: Int64(u32(b, p + 24)),
				localOffset: Int64(u32(b, p + 42))
			)
			// ZIP64 sizes and offset, in that order, for the fields that
			// overflowed.
			var extra = p + 46 + nameLength
			let extraEnd = extra + extraLength
			while extra + 4 <= extraEnd {
				let id = u16(b, extra), length = Int(u16(b, extra + 2))
				if id == 0x0001 {
					var q = extra + 4
					func next() -> Int64? {
						guard q + 8 <= extra + 4 + length else { return nil }
						defer { q += 8 }
						return Int64(u64(b, q))
					}
					if entry.size == 0xFFFF_FFFF, let value = next() { entry.size = value }
					if entry.compressedSize == 0xFFFF_FFFF, let value = next() { entry.compressedSize = value }
					if entry.localOffset == 0xFFFF_FFFF, let value = next() { entry.localOffset = value }
				}
				extra += 4 + length
			}
			entries.append(entry)
			p += 46 + nameLength + extraLength + commentLength
		}
		return entries
	}

	private func contents(of entry: Entry, in url: URL, size: Int64, limit: Int64) async throws -> Data {
		if entry.flags & 1 != 0 { throw Problem.encrypted }
		guard entry.compressedSize <= limit, entry.size <= limit else { throw Problem.tooLarge }
		// The local header's name and extra field can differ in length from
		// the central directory's, so read some slack and look.
		let slack: Int64 = 30 + 1024 + 1024
		let end = min(size - 1, entry.localOffset + slack + entry.compressedSize)
		let data = [UInt8](try await range(url, entry.localOffset, end))
		guard data.count >= 30, Self.u32(data, 0) == 0x0403_4B50 else { throw Problem.notAZip }
		let start = 30 + Int(Self.u16(data, 26)) + Int(Self.u16(data, 28))
		guard start + Int(entry.compressedSize) <= data.count else { throw Problem.notAZip }
		let payload = Data(data[start..<(start + Int(entry.compressedSize))])
		switch entry.method {
		case 0: return payload
		case 8:
			do {
				return try Inflate.decompress(payload, maxOutput: Int(limit))
			} catch {
				throw Problem.notAZip
			}
		default: throw Problem.unsupportedCompression(entry.method)
		}
	}

	private func range(_ url: URL, _ first: Int64, _ last: Int64) async throws -> Data {
		var request = URLRequest(url: url, timeoutInterval: 30)
		request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
		let (data, response) = try await load(request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 206
		switch status {
		case 206:
			return data
		case 200:
			// A server that ignores ranges sends the whole file; take the
			// part asked for, which only works for small files.
			guard Int64(data.count) > last else { throw Problem.status(200) }
			return data.subdata(in: Int(first)..<Int(last + 1))
		default:
			throw Problem.status(status)
		}
	}

	// MARK: Picking files

	/// `Payload/<App>.app/<file>`.
	static func isTopLevel(_ path: String, file: String) -> Bool {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == file
	}

	/// The app's icon as `IPAIcon` finds it, among the files small enough to
	/// read.
	static func iconEntry(plist: [String: Any], appFolder: String, entries: [Entry]) -> Entry? {
		let small = entries.filter { $0.size <= maximumIcon }
		let icon = IPAIcon.file(plist: plist, appFolder: appFolder, files: small.map { (path: $0.path, size: $0.size) })
		return small.first { $0.path == icon }
	}

	// MARK: Bytes

	static func lastIndex(of signature: UInt32, in bytes: [UInt8], from start: Int) -> Int? {
		var i = start
		let lowest = max(0, bytes.count - 22 - 0xFFFF)
		while i >= lowest {
			if u32(bytes, i) == signature { return i }
			i -= 1
		}
		return nil
	}

	static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
		UInt16(b[i]) | UInt16(b[i + 1]) << 8
	}

	static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
		UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
	}

	static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
		UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32
	}
}
