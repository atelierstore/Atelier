import Foundation

/// Just enough of a Mach-O reader to refuse what zsign can't usefully sign:
/// files that aren't Mach-O at all, and App Store binaries that are still
/// encrypted (they'd sign fine and then never launch). It also checks zsign's
/// output, which can be missing its CMS signature without zsign failing,
/// and reads the entitlements a binary was signed with (#7).
enum MachO {
	enum Kind: Equatable {
		case notMachO
		case machO(encrypted: Bool)
	}

	private static let magic32: UInt32 = 0xFEED_FACE
	private static let magic64: UInt32 = 0xFEED_FACF
	private static let fatMagic: UInt32 = 0xCAFE_BABE
	private static let fatMagic64: UInt32 = 0xCAFE_BABF
	private static let encryptionInfo: UInt32 = 0x21
	private static let encryptionInfo64: UInt32 = 0x2C
	private static let codeSignatureCommand: UInt32 = 0x1D
	private static let superBlobMagic: UInt32 = 0xFADE_0CC0
	private static let blobWrapperMagic: UInt32 = 0xFADE_0B01
	private static let cmsSlot: UInt32 = 0x10000
	private static let entitlementsSlot: UInt32 = 5
	private static let entitlementsMagic: UInt32 = 0xFADE_7171

	private struct Slice {
		var offset: UInt64
		var encrypted = false
		/// LC_CODE_SIGNATURE's dataoff and datasize, relative to the slice.
		var codeSignature: (offset: UInt32, size: UInt32)?
	}

	static func inspect(_ url: URL) throws -> Kind {
		try withReader(url) { reader in
			guard let slices = try slices(reader) else { return .notMachO }
			return .machO(encrypted: slices.contains { $0.encrypted })
		}
	}

	/// Whether every slice carries a code signature with a CMS blob, which is
	/// what makes it signed by a certificate rather than ad hoc.
	static func hasCMSSignature(_ url: URL) throws -> Bool {
		try withReader(url) { reader in
			guard let slices = try slices(reader), !slices.isEmpty else { return false }
			for slice in slices {
				// Only the SuperBlob's index and the CMS blob's header are read:
				// a large binary's whole signature runs to megabytes.
				guard let signature = slice.codeSignature else { return false }
				let base = slice.offset + UInt64(signature.offset)
				guard let header = try reader.read(at: base, count: 12),
				      header.count == 12,
				      header.uint32(at: 0, bigEndian: true) == superBlobMagic
				else { return false }
				let count = Int(header.uint32(at: 8, bigEndian: true))
				guard count < 64, let index = try reader.read(at: base + 12, count: count * 8), index.count == count * 8 else { return false }
				var found = false
				for entry in stride(from: 0, to: index.count, by: 8) where index.uint32(at: entry, bigEndian: true) == cmsSlot {
					let offset = UInt64(index.uint32(at: entry + 4, bigEndian: true))
					guard offset + 8 <= UInt64(signature.size),
					      let wrapper = try reader.read(at: base + offset, count: 8),
					      wrapper.count == 8
					else { return false }
					found = wrapper.uint32(at: 0, bigEndian: true) == blobWrapperMagic
						&& wrapper.uint32(at: 4, bigEndian: true) > 8
				}
				if !found { return false }
			}
			return true
		}
	}

	/// The entitlements plist (XML) the first slice is signed with, or nil
	/// when it has no code signature or no entitlements in it. Slices of one
	/// binary are signed with the same entitlements.
	static func entitlements(_ url: URL) throws -> Data? {
		try withReader(url) { reader in
			guard let slice = try slices(reader)?.first, let signature = slice.codeSignature else { return nil }
			let base = slice.offset + UInt64(signature.offset)
			guard let header = try reader.read(at: base, count: 12),
			      header.count == 12,
			      header.uint32(at: 0, bigEndian: true) == superBlobMagic
			else { return nil }
			let count = Int(header.uint32(at: 8, bigEndian: true))
			guard count < 64, let index = try reader.read(at: base + 12, count: count * 8), index.count == count * 8 else { return nil }
			for entry in stride(from: 0, to: index.count, by: 8) where index.uint32(at: entry, bigEndian: true) == entitlementsSlot {
				let offset = UInt64(index.uint32(at: entry + 4, bigEndian: true))
				guard offset + 8 <= UInt64(signature.size),
				      let blob = try reader.read(at: base + offset, count: 8),
				      blob.count == 8,
				      blob.uint32(at: 0, bigEndian: true) == entitlementsMagic
				else { return nil }
				let length = UInt64(blob.uint32(at: 4, bigEndian: true))
				// Entitlements are a few kilobytes; a length past the
				// signature, or one of megabytes, is a damaged blob.
				guard length > 8, offset + length <= UInt64(signature.size), length <= 1 << 20,
				      let plist = try reader.read(at: base + offset + 8, count: Int(length - 8)),
				      plist.count == Int(length - 8)
				else { return nil }
				return Data(plist)
			}
			return nil
		}
	}

	private static func withReader<T>(_ url: URL, _ body: (Reader) throws -> T) throws -> T {
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		return try body(Reader(handle: handle))
	}

	/// The file's thin Mach-O slices, or nil if it isn't Mach-O.
	private static func slices(_ reader: Reader) throws -> [Slice]? {
		guard let head = try reader.read(at: 0, count: 8), head.count == 8 else { return nil }

		switch head.uint32(at: 0, bigEndian: true) {
		case fatMagic, fatMagic64:
			let is64 = head.uint32(at: 0, bigEndian: true) == fatMagic64
			let count = head.uint32(at: 4, bigEndian: true)
			// Java class files share the fat magic; they have a large "count".
			guard count > 0, count < 32 else { return nil }
			let stride = is64 ? 32 : 20
			guard let table = try reader.read(at: 8, count: Int(count) * stride), table.count == Int(count) * stride else { return nil }
			var result: [Slice] = []
			for index in 0..<Int(count) {
				let base = index * stride
				let offset = is64 ? table.uint64(at: base + 8, bigEndian: true) : UInt64(table.uint32(at: base + 8, bigEndian: true))
				guard let slice = try slice(reader, at: offset) else { return nil }
				result.append(slice)
			}
			return result
		default:
			return try slice(reader, at: 0).map { [$0] }
		}
	}

	/// The thin Mach-O at `offset`, or nil if it isn't Mach-O.
	private static func slice(_ reader: Reader, at offset: UInt64) throws -> Slice? {
		guard let header = try reader.read(at: offset, count: 32), header.count >= 28 else { return nil }
		let magic = header.uint32(at: 0, bigEndian: false)
		guard magic == magic32 || magic == magic64 else { return nil }
		let headerSize: UInt64 = magic == magic64 ? 32 : 28
		let commandCount = header.uint32(at: 16, bigEndian: false)
		let commandsSize = header.uint32(at: 20, bigEndian: false)
		guard
			commandsSize <= 16 << 20,
			let commands = try reader.read(at: offset + headerSize, count: Int(commandsSize)),
			commands.count == Int(commandsSize)
		else { return nil }

		var slice = Slice(offset: offset)
		var position = 0
		for _ in 0..<commandCount {
			guard position + 8 <= commands.count else { return nil }
			let command = commands.uint32(at: position, bigEndian: false)
			let size = Int(commands.uint32(at: position + 4, bigEndian: false))
			guard size >= 8, position + size <= commands.count else { return nil }
			switch command {
			case encryptionInfo, encryptionInfo64:
				// encryption_info_command: cmd, cmdsize, cryptoff, cryptsize, cryptid
				if size >= 20, commands.uint32(at: position + 16, bigEndian: false) != 0 { slice.encrypted = true }
			case codeSignatureCommand:
				// linkedit_data_command: cmd, cmdsize, dataoff, datasize
				if size >= 16 {
					slice.codeSignature = (commands.uint32(at: position + 8, bigEndian: false), commands.uint32(at: position + 12, bigEndian: false))
				}
			default:
				break
			}
			position += size
		}
		return slice
	}

	private struct Reader {
		let handle: FileHandle

		func read(at offset: UInt64, count: Int) throws -> [UInt8]? {
			guard count > 0 else { return [] }
			try handle.seek(toOffset: offset)
			guard let data = try handle.read(upToCount: count) else { return nil }
			return [UInt8](data)
		}
	}
}

private extension Array where Element == UInt8 {
	func uint32(at offset: Int, bigEndian: Bool) -> UInt32 {
		let bytes = self[offset..<offset + 4]
		return bigEndian
			? bytes.reduce(0) { $0 << 8 | UInt32($1) }
			: bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
	}

	func uint64(at offset: Int, bigEndian: Bool) -> UInt64 {
		let bytes = self[offset..<offset + 8]
		return bigEndian
			? bytes.reduce(0) { $0 << 8 | UInt64($1) }
			: bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
	}
}
