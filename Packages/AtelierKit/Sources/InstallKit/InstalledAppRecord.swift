import Foundation

/// What installd's record says about an app on this iPhone (#99): who signed
/// it, and for which App ID, which decide whether iOS lets an app Atelier
/// signs replace it (TN2319). Direct installs read it
/// (`RouteAConnection.appRecord(of:)`).
public struct InstalledAppRecord: Equatable, Sendable {
	public var bundleID: String
	public var name: String
	public var version: String
	public var build: String
	/// The signing certificate's name as iOS gives it, such as
	/// "Apple Development: Jane Doe (AB12CD34EF)", or Apple's own,
	/// `appleSigner`, for App Store apps. Nil when the record has none.
	public var signer: String?
	/// Whether iOS checked the app against a provisioning profile, which
	/// App Store apps don't have. Nil when the record doesn't say.
	public var profileValidated: Bool?
	/// The `application-identifier` entitlement, such as
	/// "TEAMID.com.example.app": iOS only replaces the app with one signed
	/// for the same.
	public var applicationIdentifier: String?
	/// The `com.apple.developer.team-identifier` entitlement.
	public var teamID: String?
	/// The `beta-reports-active` entitlement, which TestFlight builds have.
	public var betaReports: Bool
	/// The `get-task-allow` entitlement, which development signing gives.
	public var debuggable: Bool
	/// Whether the record names an Apple Account (`ApplicationDSID`), as an
	/// app from the App Store's does. Only whether: the number isn't kept.
	public var hasAppleAccount: Bool
	/// The record's keys, sorted, for the log.
	public var keys: [String]

	/// The name Apple signs App Store apps with, and those of alternative
	/// marketplaces.
	public static let appleSigner = "Apple iPhone OS Application Signing"
	/// The name Apple signs TestFlight builds with.
	public static let testFlightSigner = "TestFlight Beta Distribution"

	/// Where an installed app came from, as its signature says. #99's test
	/// on iOS 27 told them apart this way across 108 apps.
	public enum Origin: Equatable, Sendable {
		/// The App Store: Apple's signature, and the Apple Account the app
		/// was downloaded with.
		case appStore
		case testFlight
		/// Apple's signature without an Apple Account: an alternative app
		/// marketplace, such as AltStore PAL, or a developer's website.
		case marketplace
		/// A certificate, named as iOS gives it, such as
		/// "Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)".
		case certificate(String)
	}

	public init(
		bundleID: String,
		name: String = "",
		version: String = "",
		build: String = "",
		signer: String? = nil,
		profileValidated: Bool? = nil,
		applicationIdentifier: String? = nil,
		teamID: String? = nil,
		betaReports: Bool = false,
		debuggable: Bool = false,
		hasAppleAccount: Bool = false,
		keys: [String] = []
	) {
		self.bundleID = bundleID
		self.name = name
		self.version = version
		self.build = build
		self.signer = signer
		self.profileValidated = profileValidated
		self.applicationIdentifier = applicationIdentifier
		self.teamID = teamID
		self.betaReports = betaReports
		self.debuggable = debuggable
		self.hasAppleAccount = hasAppleAccount
		self.keys = keys
	}

	/// Reads one app's record from installd's answer to a Lookup.
	public init(bundleID: String, record: [String: Any]) {
		func text(_ key: String, in dictionary: [String: Any] = record) -> String? {
			(dictionary[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
		}
		let entitlements = record["Entitlements"] as? [String: Any] ?? [:]
		self.init(
			bundleID: bundleID,
			name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? "",
			version: text("CFBundleShortVersionString") ?? "",
			build: text("CFBundleVersion") ?? "",
			signer: text("SignerIdentity"),
			profileValidated: Self.flag(record["ProfileValidated"]),
			applicationIdentifier: text("application-identifier", in: entitlements),
			teamID: text("com.apple.developer.team-identifier", in: entitlements),
			betaReports: Self.flag(entitlements["beta-reports-active"]) ?? false,
			debuggable: Self.flag(entitlements["get-task-allow"]) ?? false,
			hasAppleAccount: Self.isSet(record["ApplicationDSID"]),
			keys: record.keys.sorted()
		)
	}

	/// The records in the plist `atelier_app_records` gives: bundle ID →
	/// installd's record, sorted by bundle ID. Nil when it isn't one.
	public static func records(from plist: Data) -> [InstalledAppRecord]? {
		let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
		guard let records = object as? [String: Any] else { return nil }
		return records
			.compactMap { bundleID, record in (record as? [String: Any]).map { InstalledAppRecord(bundleID: bundleID, record: $0) } }
			.sorted { $0.bundleID < $1.bundleID }
	}

	/// The name to show: line breaks and runs of spaces as one space,
	/// without the direction marks some names carry. iOS 27 gave
	/// "Shirabe Jisho\nJapanese", and names starting with a left-to-right
	/// mark, in #99's test.
	public var displayName: String {
		let marks: Set<Unicode.Scalar> = ["\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
		var scalars = String.UnicodeScalarView()
		scalars.append(contentsOf: name.unicodeScalars.filter { !marks.contains($0) })
		return String(scalars)
			.split(whereSeparator: { $0.isWhitespace })
			.joined(separator: " ")
	}

	/// Where the app came from; nil when the record names no signer.
	public var origin: Origin? {
		guard let signer else { return nil }
		switch signer {
		case Self.appleSigner: return hasAppleAccount ? .appStore : .marketplace
		case Self.testFlightSigner: return .testFlight
		default: return .certificate(signer)
		}
	}

	/// Whether iOS lets Atelier open the app's data, so deleting it to
	/// install another keeps its data (#96). In #99's test it did for
	/// TestFlight apps and apps signed with a certificate, and refused App
	/// Store and marketplace apps ("InstallationLookupFailed").
	public var dataOpens: Bool {
		switch origin {
		case .appStore?, .marketplace?: false
		case .testFlight?, .certificate?, nil: true
		}
	}

	/// Who signed the app and for which App ID, for the log.
	public var signing: String {
		var parts = ["signer " + (signer.map { "“\($0)”" } ?? "not given")]
		parts.append("profile validated " + (profileValidated.map { $0 ? "yes" : "no" } ?? "not given"))
		parts.append("App ID " + (applicationIdentifier ?? "not given"))
		parts.append("team " + (teamID ?? "not given"))
		if betaReports { parts.append("beta-reports-active") }
		if debuggable { parts.append("get-task-allow") }
		if hasAppleAccount { parts.append("an Apple Account (ApplicationDSID)") }
		return parts.joined(separator: ", ")
	}

	/// A plist boolean, which iOS sometimes gives as a number or a string.
	private static func flag(_ value: Any?) -> Bool? {
		switch value {
		case let value as Bool: value
		case let value as Int: value != 0
		case let value as String: ["true", "yes", "1"].contains(value.lowercased())
		default: nil
		}
	}

	/// Whether a record's value is there and not zero or empty.
	private static func isSet(_ value: Any?) -> Bool {
		switch value {
		case nil: false
		case let value as Int: value != 0
		case let value as String: !value.isEmpty
		default: true
		}
	}
}
