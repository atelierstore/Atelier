import Foundation

/// A minimal BER/DER reader: enough for X.509 certificates and the CMS
/// envelope around provisioning profiles. Apple encodes profiles with
/// indefinite lengths and chunked OCTET STRINGs, so both are handled.
struct ASN1Node {
	enum Error: Swift.Error {
		case truncated
		case unsupportedLength
		case tooDeep
	}

	/// The identifier octet. Only low tag numbers (< 31) are used here.
	let tag: UInt8
	/// The contents of a primitive node.
	let content: [UInt8]
	/// The nodes inside a constructed one.
	let children: [ASN1Node]
	/// The whole node as it was read: identifier, length and contents. What
	/// hashes and signatures are computed over (#5). Shares the parsed
	/// bytes rather than copying them.
	let encoded: ArraySlice<UInt8>

	init(tag: UInt8, content: [UInt8], children: [ASN1Node], encoded: ArraySlice<UInt8> = []) {
		self.tag = tag
		self.content = content
		self.children = children
		self.encoded = encoded
	}

	var isConstructed: Bool { tag & 0x20 != 0 }

	static let boolean: UInt8 = 0x01
	static let integer: UInt8 = 0x02
	static let bitString: UInt8 = 0x03
	static let octetString: UInt8 = 0x04
	static let null: UInt8 = 0x05
	static let objectIdentifier: UInt8 = 0x06
	static let enumerated: UInt8 = 0x0A
	static let generalizedTime: UInt8 = 0x18
	static let sequence: UInt8 = 0x30
	static let set: UInt8 = 0x31
	static func contextSpecific(_ number: UInt8) -> UInt8 { 0xA0 | number }

	/// Parses the first node in `data`; trailing bytes are ignored.
	static func parse(_ data: Data) throws -> ASN1Node {
		try parse([UInt8](data))
	}

	static func parse(_ bytes: [UInt8]) throws -> ASN1Node {
		var reader = Reader(bytes: bytes)
		return try reader.node(depth: 0)
	}

	/// A BIT STRING's bytes, without its unused-bits octet. Keys and
	/// signatures are whole bytes, so that octet is always 0 for them.
	var bits: [UInt8]? {
		guard tag == Self.bitString, content.first == 0 else { return nil }
		return Array(content.dropFirst())
	}

	subscript(_ index: Int) -> ASN1Node? {
		children.indices.contains(index) ? children[index] : nil
	}

	/// An OCTET STRING's bytes, joining the chunks of a constructed one.
	var octets: [UInt8] {
		isConstructed ? children.flatMap(\.octets) : content
	}

	/// An OBJECT IDENTIFIER in dotted form, such as "2.5.4.3".
	var objectIdentifier: String? {
		guard tag == Self.objectIdentifier, let first = content.first else { return nil }
		var parts = [String(first / 40), String(first % 40)]
		var value: UInt64 = 0
		for byte in content.dropFirst() {
			value = value << 7 | UInt64(byte & 0x7F)
			if byte & 0x80 == 0 {
				parts.append(String(value))
				value = 0
			}
		}
		return parts.joined(separator: ".")
	}

	/// The text of any of the string types X.509 names use.
	var string: String? {
		switch tag {
		case 0x0C, 0x13, 0x16, 0x1A: // UTF8String, PrintableString, IA5String, VisibleString
			return String(decoding: content, as: UTF8.self)
		case 0x14: // T61String: treat as Latin-1, which is what it holds in practice
			return String(content.map { Character(Unicode.Scalar($0)) })
		case 0x1E: // BMPString: UTF-16BE
			guard content.count.isMultiple(of: 2) else { return nil }
			let units = stride(from: 0, to: content.count, by: 2).map { UInt16(content[$0]) << 8 | UInt16(content[$0 + 1]) }
			return String(decoding: units, as: UTF16.self)
		default:
			return nil
		}
	}

	/// A UTCTime or GeneralizedTime in UTC ("Z") form, the only form X.509 allows.
	var date: Date? {
		let text = String(decoding: content, as: UTF8.self)
		guard text.hasSuffix("Z") else { return nil }
		var digits = String(text.dropLast())
		if tag == 0x17 { // UTCTime: two-digit year, 50...99 meaning 19xx (RFC 5280)
			guard let yy = Int(digits.prefix(2)) else { return nil }
			digits = (yy >= 50 ? "19" : "20") + digits
		} else if tag != 0x18 {
			return nil
		}
		// Ignore fractional seconds, which DER certificates don't use anyway.
		if let dot = digits.firstIndex(of: ".") { digits = String(digits[..<dot]) }
		guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
		let n = Array(digits).map { Int(String($0))! }
		func value(_ from: Int, _ count: Int) -> Int { n[from..<from + count].reduce(0) { $0 * 10 + $1 } }
		var components = DateComponents()
		components.calendar = Calendar(identifier: .gregorian)
		components.timeZone = TimeZone(identifier: "UTC")
		components.year = value(0, 4)
		components.month = value(4, 2)
		components.day = value(6, 2)
		components.hour = value(8, 2)
		components.minute = value(10, 2)
		components.second = value(12, 2)
		return components.date
	}

	private struct Reader {
		let bytes: [UInt8]
		var position = 0

		mutating func byte() throws -> UInt8 {
			guard position < bytes.count else { throw Error.truncated }
			defer { position += 1 }
			return bytes[position]
		}

		mutating func node(depth: Int) throws -> ASN1Node {
			guard depth < 32 else { throw Error.tooDeep }
			let start = position
			let tag = try byte()
			if tag & 0x1F == 0x1F {
				// High tag number: skip its continuation octets. Nothing read here uses them.
				while try byte() & 0x80 != 0 {}
			}
			let constructed = tag & 0x20 != 0

			let first = try byte()
			var length: Int?
			if first < 0x80 {
				length = Int(first)
			} else if first == 0x80 {
				guard constructed else { throw Error.unsupportedLength }
				length = nil
			} else {
				let count = Int(first & 0x7F)
				guard count <= 4 else { throw Error.unsupportedLength }
				var value = 0
				for _ in 0..<count { value = value << 8 | Int(try byte()) }
				length = value
			}

			guard constructed else {
				let length = length!
				guard length <= bytes.count - position else { throw Error.truncated }
				defer { position += length }
				return ASN1Node(
					tag: tag,
					content: Array(bytes[position..<position + length]),
					children: [],
					encoded: bytes[start..<position + length]
				)
			}

			var children: [ASN1Node] = []
			if let length {
				guard length <= bytes.count - position else { throw Error.truncated }
				let end = position + length
				while position < end { children.append(try node(depth: depth + 1)) }
				guard position == end else { throw Error.truncated }
			} else {
				// Indefinite length: children run until an end-of-contents marker (00 00).
				while true {
					guard position + 2 <= bytes.count else { throw Error.truncated }
					if bytes[position] == 0, bytes[position + 1] == 0 {
						position += 2
						break
					}
					children.append(try node(depth: depth + 1))
				}
			}
			return ASN1Node(tag: tag, content: [], children: children, encoded: bytes[start..<position])
		}
	}
}

/// Writes the little DER that Atelier sends: an OCSP request (#5).
enum DER {
	static func node(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
		var length: [UInt8]
		if content.count < 0x80 {
			length = [UInt8(content.count)]
		} else {
			var count = content.count
			length = []
			while count > 0 {
				length.insert(UInt8(count & 0xFF), at: 0)
				count >>= 8
			}
			length.insert(0x80 | UInt8(length.count), at: 0)
		}
		return [tag] + length + content
	}

	static func sequence(_ children: [UInt8]...) -> [UInt8] {
		node(ASN1Node.sequence, children.flatMap { $0 })
	}

	static func octetString(_ bytes: [UInt8]) -> [UInt8] { node(ASN1Node.octetString, bytes) }

	static let null: [UInt8] = [ASN1Node.null, 0]

	/// An INTEGER from its content octets, as read from a certificate.
	static func integer(_ content: [UInt8]) -> [UInt8] { node(ASN1Node.integer, content) }

	/// An OBJECT IDENTIFIER from its dotted form.
	static func objectIdentifier(_ dotted: String) -> [UInt8] {
		let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
		precondition(parts.count >= 2, "not an OID: \(dotted)")
		var content = [UInt8(parts[0] * 40 + parts[1])]
		for var part in parts.dropFirst(2) {
			var chunk = [UInt8(part & 0x7F)]
			part >>= 7
			while part > 0 {
				chunk.insert(UInt8(part & 0x7F) | 0x80, at: 0)
				part >>= 7
			}
			content += chunk
		}
		return node(ASN1Node.objectIdentifier, content)
	}
}
