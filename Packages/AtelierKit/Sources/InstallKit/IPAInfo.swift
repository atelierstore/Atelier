import Foundation

/// The metadata an install manifest needs, read from `Payload/<App>.app/Info.plist`.
public struct IPAInfo: Equatable, Sendable {
	public var bundleID: String
	public var version: String
	/// `CFBundleVersion`, when the app has one besides its version (#18).
	public var buildVersion: String?
	public var name: String
	/// Every URL scheme the app registers (`CFBundleURLTypes`), which is where
	/// Atelier's install check scheme sits (`InstallCheck`).
	public var urlSchemes: [String]
	/// Its privacy permissions (`NSCameraUsageDescription` and the like)
	/// with the reasons it gives.
	public var privacy: [String: String]
	/// Whether it's a build of Atelier that imports the certificate it
	/// comes with as a copy (#113): `AtelierTakesCertificate` in its
	/// Info.plist. Custom Install… only puts one in a copy of such a build,
	/// as builds before it don't look for one.
	public var takesCertificate: Bool

	public static let takesCertificateKey = "AtelierTakesCertificate"

	public init(bundleID: String, version: String, name: String, urlSchemes: [String] = [], privacy: [String: String] = [:], buildVersion: String? = nil, takesCertificate: Bool = false) {
		self.bundleID = bundleID
		self.version = version
		self.buildVersion = buildVersion
		self.name = name
		self.urlSchemes = urlSchemes
		self.privacy = privacy
		self.takesCertificate = takesCertificate
	}

	public enum Error: Swift.Error, Equatable, CustomStringConvertible {
		case notAZip
		case zip64Unsupported
		case infoPlistNotFound
		case unsupportedCompression(UInt16)
		case encrypted
		case invalidInfoPlist(String)

		public var description: String {
			switch self {
			case .notAZip: "File is not a zip archive"
			case .zip64Unsupported: "ZIP64 archives are not supported"
			case .infoPlistNotFound: "No Payload/<App>.app/Info.plist in the archive"
			case .unsupportedCompression(let m): "Unsupported zip compression method \(m)"
			case .encrypted: "Encrypted zip entries are not supported"
			case .invalidInfoPlist(let why): "Info.plist is invalid: \(why)"
			}
		}
	}

	public static func read(ipaAt url: URL) throws -> IPAInfo {
		let data = try Data(contentsOf: url, options: .alwaysMapped)
		return try read(ipaData: data)
	}

	public static func read(ipaData data: Data) throws -> IPAInfo {
		let plistData = try ZipReader(data: data).extract(where: isTopLevelInfoPlist)
		return try parse(infoPlist: plistData)
	}

	static func isTopLevelInfoPlist(_ path: String) -> Bool {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		return parts.count == 3
			&& parts[0] == "Payload"
			&& parts[1].hasSuffix(".app")
			&& parts[2] == "Info.plist"
	}

	public static func parse(infoPlist data: Data) throws -> IPAInfo {
		let object: Any
		do {
			object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
		} catch {
			throw Error.invalidInfoPlist("not a property list")
		}
		guard let dict = object as? [String: Any] else {
			throw Error.invalidInfoPlist("root is not a dictionary")
		}
		guard let bundleID = dict["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
			throw Error.invalidInfoPlist("missing CFBundleIdentifier")
		}
		let shortVersion = dict["CFBundleShortVersionString"] as? String
		let bundleVersion = dict["CFBundleVersion"] as? String
		let version = shortVersion ?? bundleVersion ?? "1.0"
		// Only a build number when it isn't standing in for the version.
		let buildVersion = shortVersion == nil ? nil : bundleVersion
		let name = (dict["CFBundleDisplayName"] as? String)
			?? (dict["CFBundleName"] as? String)
			?? bundleID
		let urlSchemes = ((dict["CFBundleURLTypes"] as? [[String: Any]]) ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
		let privacy = dict.compactMapValues { $0 as? String }.filter { $0.key.hasSuffix("UsageDescription") }
		let takesCertificate = dict[takesCertificateKey] as? Bool ?? false
		return IPAInfo(bundleID: bundleID, version: version, name: name, urlSchemes: urlSchemes, privacy: privacy, buildVersion: buildVersion, takesCertificate: takesCertificate)
	}
}

/// Reads entries from a zip's central directory. Handles stored and deflated
/// entries; no ZIP64, no encryption. Errors are `IPAInfo.Error`s.
public struct ZipReader {
	let data: Data

	public init(data: Data) {
		self.data = data
	}

	/// The first entry whose path matches.
	func extract(where matches: (String) -> Bool) throws -> Data {
		var found: Data?
		try forEachEntry { path, _ in
			guard matches(path) else { return nil }
			return { found = $0; return true }
		}
		guard let found else { throw IPAInfo.Error.infoPlistNotFound }
		return found
	}

	/// Every entry whose path matches, in archive order. Directories are
	/// skipped.
	public func entries(where matches: (String) -> Bool) throws -> [(path: String, data: Data)] {
		var result: [(path: String, data: Data)] = []
		try forEachEntry { path, _ in
			guard !path.hasSuffix("/"), matches(path) else { return nil }
			return { result.append((path, $0)); return false }
		}
		return result
	}

	/// The path and decompressed size of every entry whose path matches, in
	/// archive order, read from the central directory alone, so nothing is
	/// decompressed. Directories are skipped.
	public func sizes(where matches: (String) -> Bool) throws -> [(path: String, size: Int64)] {
		var result: [(path: String, size: Int64)] = []
		try forEachEntry { path, size in
			if !path.hasSuffix("/"), matches(path) { result.append((path, Int64(size))) }
			return nil
		}
		return result
	}

	/// Whether any entry's path matches, read from the central directory
	/// alone, so nothing is decompressed.
	public func containsEntry(where matches: (String) -> Bool) throws -> Bool {
		var found = false
		try forEachEntry { path, _ in
			if matches(path) { found = true }
			return nil
		}
		return found
	}

	/// Walks the central directory. For each path and decompressed size,
	/// `visit` returns nil to skip the entry, or a closure that receives its
	/// decompressed contents and returns true to stop the walk.
	private func forEachEntry(_ visit: (_ path: String, _ size: Int) -> ((Data) -> Bool)?) throws {
		// Read through Data rather than copying it: an IPA can be hundreds of MB.
		let bytes = ByteView(data: data)
		guard let eocd = findEndOfCentralDirectory(bytes) else { throw IPAInfo.Error.notAZip }

		let entryCount = Int(u16(bytes, eocd + 10))
		let cdOffset = Int(u32(bytes, eocd + 16))
		if entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw IPAInfo.Error.zip64Unsupported }

		var p = cdOffset
		for _ in 0..<entryCount {
			guard p + 46 <= bytes.count, u32(bytes, p) == 0x0201_4b50 else { throw IPAInfo.Error.notAZip }
			let flags = u16(bytes, p + 8)
			let method = u16(bytes, p + 10)
			let compressedSize = Int(u32(bytes, p + 20))
			let size = Int(u32(bytes, p + 24))
			let nameLength = Int(u16(bytes, p + 28))
			let extraLength = Int(u16(bytes, p + 30))
			let commentLength = Int(u16(bytes, p + 32))
			let localOffset = Int(u32(bytes, p + 42))
			guard p + 46 + nameLength <= bytes.count else { throw IPAInfo.Error.notAZip }
			let name = String(decoding: bytes.slice(p + 46, nameLength), as: UTF8.self)

			if let receive = visit(name, size) {
				if flags & 1 != 0 { throw IPAInfo.Error.encrypted }
				if compressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
					throw IPAInfo.Error.zip64Unsupported
				}
				guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else {
					throw IPAInfo.Error.notAZip
				}
				let localNameLength = Int(u16(bytes, localOffset + 26))
				let localExtraLength = Int(u16(bytes, localOffset + 28))
				let start = localOffset + 30 + localNameLength + localExtraLength
				guard start + compressedSize <= bytes.count else { throw IPAInfo.Error.notAZip }
				let payload = bytes.slice(start, compressedSize)
				let contents: Data
				switch method {
				case 0: contents = payload
				case 8: contents = try Inflate.decompress(payload)
				default: throw IPAInfo.Error.unsupportedCompression(method)
				}
				if receive(contents) { return }
			}
			p += 46 + nameLength + extraLength + commentLength
		}
	}

	private func findEndOfCentralDirectory(_ bytes: ByteView) -> Int? {
		guard bytes.count >= 22 else { return nil }
		let lowest = max(0, bytes.count - 22 - 0xFFFF)
		var i = bytes.count - 22
		while i >= lowest {
			if u32(bytes, i) == 0x0605_4b50 { return i }
			i -= 1
		}
		return nil
	}

	private func u16(_ b: ByteView, _ i: Int) -> UInt16 {
		UInt16(b[i]) | UInt16(b[i + 1]) << 8
	}

	private func u32(_ b: ByteView, _ i: Int) -> UInt32 {
		UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
	}
}

/// Zero-based, bounds-checked view over Data (whose indices may not start at 0).
struct ByteView {
	let data: Data
	var count: Int { data.count }

	subscript(i: Int) -> UInt8 { data[data.startIndex + i] }

	func slice(_ start: Int, _ length: Int) -> Data {
		Data(data[(data.startIndex + start)..<(data.startIndex + start + length)])
	}
}
