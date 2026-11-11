import Foundation

/// An iOS version such as 17.4 or 16.3.1, for `minOSVersion` and
/// `maxOSVersion`. Missing parts count as zero when comparing, so 17 == 17.0.
public struct OSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
	/// As written, without trailing zeros dropped: "16.3" has two.
	public var components: [Int]

	public init(_ components: [Int]) {
		self.components = components
	}

	/// Reads "17", "17.4" or "16.3.1". Nil for anything else.
	public init?(_ string: String) {
		let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
		guard !parts.isEmpty, parts.count <= 3 else { return nil }
		var components: [Int] = []
		for part in parts {
			guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
			components.append(value)
		}
		self.components = components
	}

	init(_ version: OperatingSystemVersion) {
		self.components = [version.majorVersion, version.minorVersion, version.patchVersion]
	}

	/// The OS this process runs on.
	public static var current: OSVersion {
		OSVersion(ProcessInfo.processInfo.operatingSystemVersion)
	}

	public var description: String {
		components.map(String.init).joined(separator: ".")
	}

	/// The first `count` parts, so 16.3.1 truncated to 2 is 16.3.
	func truncated(to count: Int) -> OSVersion {
		OSVersion(Array(components.prefix(count)))
	}

	private func padded(to count: Int) -> [Int] {
		components + Array(repeating: 0, count: max(0, count - components.count))
	}

	public static func == (a: OSVersion, b: OSVersion) -> Bool {
		let count = max(a.components.count, b.components.count)
		return a.padded(to: count) == b.padded(to: count)
	}

	public func hash(into hasher: inout Hasher) {
		var trimmed = components
		while trimmed.last == 0 { trimmed.removeLast() }
		hasher.combine(trimmed)
	}

	public static func < (a: OSVersion, b: OSVersion) -> Bool {
		let count = max(a.components.count, b.components.count)
		return a.padded(to: count).lexicographicallyPrecedes(b.padded(to: count))
	}
}
