import Foundation

/// Minimal raw DEFLATE (RFC 1951) decoder, enough to read one Info.plist out
/// of an IPA without a zip dependency. Not tuned for speed.
public enum Inflate {
	public enum Error: Swift.Error, Equatable {
		case truncated
		case invalidBlockType
		case invalidStoredLength
		case invalidCode
		case invalidDistance
		case outputTooLarge
	}

	public static func decompress(_ input: Data, maxOutput: Int = 16 * 1024 * 1024) throws -> Data {
		var reader = BitReader(bytes: [UInt8](input))
		var out: [UInt8] = []
		out.reserveCapacity(min(maxOutput, input.count * 4))

		var isFinal = false
		while !isFinal {
			isFinal = try reader.bits(1) == 1
			switch try reader.bits(2) {
			case 0:
				try storedBlock(&reader, &out)
			case 1:
				try huffmanBlock(&reader, &out, lit: fixedLiteral, dist: fixedDistance, maxOutput: maxOutput)
			case 2:
				let (lit, dist) = try dynamicTables(&reader)
				try huffmanBlock(&reader, &out, lit: lit, dist: dist, maxOutput: maxOutput)
			default:
				throw Error.invalidBlockType
			}
			if out.count > maxOutput { throw Error.outputTooLarge }
		}
		return Data(out)
	}

	// MARK: Bit reader

	struct BitReader {
		let bytes: [UInt8]
		var pos = 0
		var bitBuf: UInt32 = 0
		var bitCount = 0

		init(bytes: [UInt8]) { self.bytes = bytes }

		mutating func bits(_ n: Int) throws -> Int {
			while bitCount < n {
				guard pos < bytes.count else { throw Error.truncated }
				bitBuf |= UInt32(bytes[pos]) << UInt32(bitCount)
				pos += 1
				bitCount += 8
			}
			let value = Int(bitBuf & ((1 << UInt32(n)) - 1))
			bitBuf >>= UInt32(n)
			bitCount -= n
			return value
		}

		mutating func alignToByte() {
			bitBuf = 0
			bitCount = 0
		}

		mutating func byte() throws -> UInt8 {
			guard pos < bytes.count else { throw Error.truncated }
			defer { pos += 1 }
			return bytes[pos]
		}
	}

	// MARK: Huffman tables (canonical, decoded bit by bit)

	struct Huffman {
		var counts = [Int](repeating: 0, count: 16)
		var symbols: [Int] = []

		init(lengths: [Int]) throws {
			for len in lengths { counts[len] += 1 }
			counts[0] = 0
			var offsets = [Int](repeating: 0, count: 16)
			for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
			symbols = [Int](repeating: 0, count: lengths.count)
			for (symbol, len) in lengths.enumerated() where len != 0 {
				symbols[offsets[len]] = symbol
				offsets[len] += 1
			}
		}

		func decode(_ reader: inout BitReader) throws -> Int {
			var code = 0, first = 0, index = 0
			for len in 1..<16 {
				code |= try reader.bits(1)
				let count = counts[len]
				if code - count < first {
					return symbols[index + (code - first)]
				}
				index += count
				first += count
				first <<= 1
				code <<= 1
			}
			throw Error.invalidCode
		}
	}

	static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	                         35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
	static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	                          3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
	static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
	                       8193, 12289, 16385, 24577]
	static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

	static let fixedLiteral: Huffman = {
		var lengths = [Int](repeating: 8, count: 288)
		for i in 144..<256 { lengths[i] = 9 }
		for i in 256..<280 { lengths[i] = 7 }
		return try! Huffman(lengths: lengths)
	}()

	static let fixedDistance: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))

	// MARK: Blocks

	static func storedBlock(_ reader: inout BitReader, _ out: inout [UInt8]) throws {
		reader.alignToByte()
		let len = Int(try reader.byte()) | Int(try reader.byte()) << 8
		let nlen = Int(try reader.byte()) | Int(try reader.byte()) << 8
		guard len == (~nlen & 0xFFFF) else { throw Error.invalidStoredLength }
		guard reader.pos + len <= reader.bytes.count else { throw Error.truncated }
		out.append(contentsOf: reader.bytes[reader.pos..<(reader.pos + len)])
		reader.pos += len
	}

	static func huffmanBlock(
		_ reader: inout BitReader,
		_ out: inout [UInt8],
		lit: Huffman,
		dist: Huffman,
		maxOutput: Int
	) throws {
		while true {
			let symbol = try lit.decode(&reader)
			if symbol < 256 {
				out.append(UInt8(symbol))
			} else if symbol == 256 {
				return
			} else {
				let li = symbol - 257
				guard li < lengthBase.count else { throw Error.invalidCode }
				let length = lengthBase[li] + (try reader.bits(lengthExtra[li]))
				let di = try dist.decode(&reader)
				guard di < distBase.count else { throw Error.invalidDistance }
				let distance = distBase[di] + (try reader.bits(distExtra[di]))
				guard distance <= out.count else { throw Error.invalidDistance }
				let start = out.count - distance
				for i in 0..<length { out.append(out[start + i]) }
			}
			if out.count > maxOutput { throw Error.outputTooLarge }
		}
	}

	static func dynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
		let hlit = try reader.bits(5) + 257
		let hdist = try reader.bits(5) + 1
		let hclen = try reader.bits(4) + 4
		let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

		var codeLengths = [Int](repeating: 0, count: 19)
		for i in 0..<hclen { codeLengths[order[i]] = try reader.bits(3) }
		let codeLengthTable = try Huffman(lengths: codeLengths)

		var lengths: [Int] = []
		while lengths.count < hlit + hdist {
			let symbol = try codeLengthTable.decode(&reader)
			switch symbol {
			case 0...15:
				lengths.append(symbol)
			case 16:
				guard let previous = lengths.last else { throw Error.invalidCode }
				lengths += [Int](repeating: previous, count: 3 + (try reader.bits(2)))
			case 17:
				lengths += [Int](repeating: 0, count: 3 + (try reader.bits(3)))
			case 18:
				lengths += [Int](repeating: 0, count: 11 + (try reader.bits(7)))
			default:
				throw Error.invalidCode
			}
		}
		guard lengths.count == hlit + hdist else { throw Error.invalidCode }
		return (
			try Huffman(lengths: Array(lengths[0..<hlit])),
			try Huffman(lengths: Array(lengths[hlit...]))
		)
	}
}
