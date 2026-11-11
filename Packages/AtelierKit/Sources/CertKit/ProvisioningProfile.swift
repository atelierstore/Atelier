import Foundation
import InstallKit

/// A provisioning profile (`.mobileprovision`): the plist inside Apple's CMS
/// envelope. The envelope's signature isn't checked; iOS checks it when it
/// installs an app signed with the profile.
public struct ProvisioningProfile: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// Lists devices and allows debugging (get-task-allow).
		case development
		/// Lists devices, no debugging.
		case adHoc
		/// In-house: any device (ProvisionsAllDevices).
		case enterprise
		/// No devices: only the App Store and TestFlight can install with it.
		case appStore
	}

	public var name: String
	public var uuid: String
	public var teamID: String
	public var teamName: String?
	public var appIDName: String?
	/// `TEAMID.bundle.id`, or `TEAMID.*` for a wildcard App ID.
	public var applicationIdentifier: String
	public var creationDate: Date?
	public var expirationDate: Date
	public var kind: Kind
	public var provisionedDevices: [String]
	/// The certificates (DER) allowed to sign with this profile.
	public var developerCertificates: [Data]
	/// Entitlement values as text, for display. Signing (#6, #7) reads the
	/// profile file itself for the real values (`entitlements(in:)`).
	public var entitlements: [String: String]

	public enum Error: Swift.Error, Equatable {
		case notAProfile
		case missing(String)
	}

	public init(data: Data) throws {
		let object: Any
		do {
			object = try PropertyListSerialization.propertyList(from: Self.plistData(in: data), options: [], format: nil)
		} catch {
			throw Error.notAProfile
		}
		guard let plist = object as? [String: Any] else { throw Error.notAProfile }
		try self.init(plist: plist)
	}

	init(plist: [String: Any]) throws {
		func require<T>(_ key: String, as type: T.Type = T.self) throws -> T {
			guard let value = plist[key] as? T else { throw Error.missing(key) }
			return value
		}
		let entitlements: [String: Any] = try require("Entitlements")
		guard let applicationIdentifier = entitlements["application-identifier"] as? String else {
			throw Error.missing("application-identifier")
		}

		self.name = try require("Name")
		self.uuid = try require("UUID")
		self.teamID = (plist["TeamIdentifier"] as? [String])?.first
			?? applicationIdentifier.split(separator: ".").first.map(String.init)
			?? ""
		self.teamName = plist["TeamName"] as? String
		self.appIDName = plist["AppIDName"] as? String
		self.applicationIdentifier = applicationIdentifier
		self.creationDate = plist["CreationDate"] as? Date
		self.expirationDate = try require("ExpirationDate")
		self.developerCertificates = try require("DeveloperCertificates")
		self.provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []

		if plist["ProvisionsAllDevices"] as? Bool == true {
			self.kind = .enterprise
		} else if !provisionedDevices.isEmpty {
			self.kind = entitlements["get-task-allow"] as? Bool == true ? .development : .adHoc
		} else {
			self.kind = .appStore
		}

		self.entitlements = entitlements.mapValues(Self.describe)
	}

	/// The bundle ID part of the App ID, such as `com.example.app` or `*`.
	public var bundleIDPattern: String {
		let prefix = teamID + "."
		return applicationIdentifier.hasPrefix(prefix)
			? String(applicationIdentifier.dropFirst(prefix.count))
			: applicationIdentifier
	}

	/// Whether the App ID is a wildcard (`*` or `com.example.*`). Shown only:
	/// in the spike, a profile with an explicit App ID signed apps with other
	/// bundle IDs too, and they installed (docs/install-routes.md).
	public var isWildcard: Bool { bundleIDPattern.hasSuffix("*") }

	/// The App Groups the profile has, each by its name, leaving out
	/// patterns: with a certificate, the app's own are kept in folders in
	/// one of them (#49, SigningKit's `AppGroups.home(in:)`).
	public var appGroups: [String] {
		(entitlements["com.apple.security.application-groups"] ?? "")
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && !$0.contains("*") }
	}

	/// Whether apps signed with this profile can run on a given device.
	public enum DeviceCheck: Equatable, Sendable {
		/// Enterprise: no device list.
		case anyDevice
		case included
		case notIncluded
		/// The device's UDID isn't known. Apps can't read it; a pairing file
		/// (#9) can provide it.
		case unknown
		/// App Store profiles install nothing outside the App Store.
		case noDevices
	}

	public func check(deviceUDID udid: String?) -> DeviceCheck {
		switch kind {
		case .enterprise: return .anyDevice
		case .appStore: return .noDevices
		case .development, .adHoc:
			guard let udid else { return .unknown }
			return provisionedDevices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame } ? .included : .notIncluded
		}
	}

	/// The device an app running with this profile runs on, when it lists
	/// only one (#113): development and ad hoc profiles install apps only on
	/// the devices they list. Nil when it lists several or none, and for
	/// enterprise and App Store profiles. iOS doesn't let apps read the
	/// UDID, so it's how Atelier knows this iPhone's without the setup.
	public var onlyDevice: String? {
		guard kind == .development || kind == .adHoc else { return nil }
		let devices = Set(provisionedDevices.map { $0.uppercased() })
		return devices.count == 1 ? provisionedDevices.first : nil
	}

	/// The devices route A checks this iPhone against before installing an
	/// app signed with it (#9): any for an enterprise profile, otherwise the
	/// ones it lists, which for an App Store profile is none.
	public var devices: ProfileDevices {
		kind == .enterprise ? .any : .listed(provisionedDevices)
	}

	/// Whether the profile lists this certificate.
	public func allows(_ certificate: SigningCertificate) -> Bool {
		developerCertificates.contains(certificate.der)
	}

	// MARK: Reading the file

	/// The profile signed into an IPA's app (its embedded.mobileprovision),
	/// which is the one iOS checks when it installs the app; nil when the
	/// app has none. Throws when the IPA or the profile can't be read.
	public static func embedded(inIPAAt url: URL) throws -> ProvisioningProfile? {
		try embedded(inIPAData: Data(contentsOf: url, options: .alwaysMapped))
	}

	static func embedded(inIPAData data: Data) throws -> ProvisioningProfile? {
		guard let file = try ZipReader(data: data).entries(where: isEmbeddedProfile).first else { return nil }
		return try ProvisioningProfile(data: file.data)
	}

	/// The app's own profile, not one of its extensions'.
	static func isEmbeddedProfile(_ path: String) -> Bool {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		return parts.count == 3
			&& parts[0] == "Payload"
			&& parts[1].hasSuffix(".app")
			&& parts[2] == "embedded.mobileprovision"
	}

	/// The entitlements in a profile file, with their real values (#7).
	public static func entitlements(in data: Data) throws -> [String: Any] {
		let object: Any
		do {
			object = try PropertyListSerialization.propertyList(from: plistData(in: data), options: [], format: nil)
		} catch {
			throw Error.notAProfile
		}
		guard let entitlements = (object as? [String: Any])?["Entitlements"] as? [String: Any] else {
			throw Error.missing("Entitlements")
		}
		return entitlements
	}

	/// The plist bytes: the CMS SignedData's content, or the data itself if
	/// it's already a bare plist.
	static func plistData(in data: Data) throws -> Data {
		if data.starts(with: Array("<?xml".utf8)) || data.starts(with: Array("bplist".utf8)) {
			return data
		}
		// ContentInfo ::= SEQUENCE { contentType, [0] EXPLICIT SignedData }
		// SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, ... }
		// EncapsulatedContentInfo ::= SEQUENCE { eContentType, [0] EXPLICIT OCTET STRING }
		guard
			let contentInfo = try? ASN1Node.parse(data),
			contentInfo[0]?.objectIdentifier == "1.2.840.113549.1.7.2",
			let signedData = contentInfo[1]?[0],
			let encapsulated = signedData[2], encapsulated.tag == ASN1Node.sequence,
			let content = encapsulated[1]?[0], content.tag & 0x1F == ASN1Node.octetString
		else { throw Error.notAProfile }
		return Data(content.octets)
	}

	private static func describe(_ value: Any) -> String {
		switch value {
		case let bool as Bool: return bool ? "true" : "false"
		case let string as String: return string
		case let array as [Any]: return array.map(describe).joined(separator: ", ")
		case let number as NSNumber: return number.stringValue
		default: return String(describing: value)
		}
	}
}
