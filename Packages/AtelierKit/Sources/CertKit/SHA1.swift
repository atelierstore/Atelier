import Foundation

/// SHA-1, which OCSP uses to name a certificate (RFC 6960 CertID), and
/// which tells a deleted certificate imported again (#126). Only for that:
/// it identifies, it doesn't protect anything. Written out rather than
/// taken from CryptoKit so CertKit keeps building on Linux.
enum SHA1 {
	static func hash<Bytes: Collection>(_ message: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
		var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
		var bytes = Array(message)
		let bitLength = UInt64(bytes.count) * 8
		bytes.append(0x80)
		while bytes.count % 64 != 56 { bytes.append(0) }
		for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

		var w = [UInt32](repeating: 0, count: 80)
		for chunk in stride(from: 0, to: bytes.count, by: 64) {
			for i in 0..<16 {
				let j = chunk + i * 4
				w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
			}
			for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }

			var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
			for i in 0..<80 {
				let f: UInt32, k: UInt32
				switch i {
				case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
				case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
				case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
				default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
				}
				let temp = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
				(a, b, c, d, e) = (temp, a, rotate(b, 30), c, d)
			}
			h[0] &+= a
			h[1] &+= b
			h[2] &+= c
			h[3] &+= d
			h[4] &+= e
		}
		return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * UInt32($0))) } }
	}

	private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
		value << count | value >> (32 - count)
	}
}
