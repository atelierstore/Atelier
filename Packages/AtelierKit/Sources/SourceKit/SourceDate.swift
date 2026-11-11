import Foundation

/// Reads the ISO 8601 dates sources use, as leniently as they write them:
/// "2023-02-17", "2023-2-17", "2023-02-17T12:00:00-06:00", "…Z",
/// "…T12:00:00.0000000Z" (any number of fractional digits), "…+0200", and
/// "…T12:00" without seconds. Dates without a time zone are taken as UTC.
enum SourceDate {
	static func parse(_ string: String) -> Date? {
		var scanner = Scanner(Array(string.trimmingCharacters(in: .whitespaces).utf8))

		guard let year = scanner.number(digits: 4...4), scanner.take("-"),
		      let month = scanner.number(digits: 1...2), scanner.take("-"),
		      let day = scanner.number(digits: 1...2)
		else { return nil }

		var components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
		var offset = 0

		if scanner.take("T") || scanner.take(" ") {
			guard let hour = scanner.number(digits: 1...2), scanner.take(":"),
			      let minute = scanner.number(digits: 2...2)
			else { return nil }
			components.hour = hour
			components.minute = minute
			if scanner.take(":") {
				guard let second = scanner.number(digits: 2...2) else { return nil }
				components.second = second
				if scanner.take(".") || scanner.take(",") {
					let start = scanner.index
					guard scanner.number(digits: 1...12) != nil else { return nil }
					let digits = String(decoding: scanner.bytes[start..<scanner.index], as: UTF8.self)
					components.nanosecond = Int((Double("0." + digits) ?? 0) * 1_000_000_000)
				}
			}
			if scanner.take("Z") || scanner.take("z") {
				offset = 0
			} else if let sign = scanner.peek, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
				scanner.index += 1
				guard let hours = scanner.number(digits: 2...2) else { return nil }
				_ = scanner.take(":")
				let minutes = scanner.number(digits: 2...2) ?? 0
				offset = (hours * 3600 + minutes * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
			}
		}
		guard scanner.atEnd else { return nil }

		guard (1...12).contains(month), (1...31).contains(day),
		      (0...23).contains(components.hour!), (0...59).contains(components.minute!), (0...60).contains(components.second!),
		      let zone = TimeZone(secondsFromGMT: offset)
		else { return nil }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = zone
		components.timeZone = zone
		guard let date = calendar.date(from: components),
		      // Reject dates the calendar rolled over, like 31 February.
		      calendar.component(.day, from: date) == day
		else { return nil }
		return date
	}

	private struct Scanner {
		let bytes: [UInt8]
		var index = 0

		init(_ bytes: [UInt8]) { self.bytes = bytes }

		var atEnd: Bool { index == bytes.count }
		var peek: UInt8? { atEnd ? nil : bytes[index] }

		mutating func take(_ character: Unicode.Scalar) -> Bool {
			guard peek == UInt8(ascii: character) else { return false }
			index += 1
			return true
		}

		mutating func number(digits allowed: ClosedRange<Int>) -> Int? {
			var value = 0
			var count = 0
			while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9"), count < allowed.upperBound {
				value = value * 10 + Int(byte - UInt8(ascii: "0"))
				count += 1
				index += 1
			}
			return allowed.contains(count) ? value : nil
		}
	}
}
