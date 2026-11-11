import Foundation
import XCTest
@testable import InstallKit

final class InstalledAppRecordTests: XCTestCase {
	/// What `atelier_app_records` returns for one development-signed app,
	/// as idevice's plist crate writes it (Packages/IDeviceBridge), with a
	/// date, data and a real number besides installd's keys.
	private let writtenByRust = "YnBsaXN0MDDRAQJfEA9jb20uZXhhbXBsZS5hcHDaAwQFBgcICQoLDA0ODxAREhMUFRZfEBNDRkJ1bmRsZURpc3BsYXlOYW1lXxAaQ0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmdfEA9DRkJ1bmRsZVZlcnNpb25eU2lnbmVySWRlbnRpdHlfEBBQcm9maWxlVmFsaWRhdGVkXxAPQXBwbGljYXRpb25EU0lEXEVudGl0bGVtZW50c1hTb21lRGF0YVhTb21lRGF0ZVhTb21lUmVhbGkARQB4AOQAbQBwAGwAZQAgJxNTMi4wUTdfEChBcHBsZSBEZXZlbG9wbWVudDogSmFuZSBEb2UgKEFCMTJDRDM0RUYpCRJJlgLS1BcYGRobHBEdXxAWYXBwbGljYXRpb24taWRlbnRpZmllcl8QI2NvbS5hcHBsZS5kZXZlbG9wZXIudGVhbS1pZGVudGlmaWVyXmdldC10YXNrLWFsbG93XxAWa2V5Y2hhaW4tYWNjZXNzLWdyb3Vwc18QGkFCQ0RFMTIzNDUuY29tLmV4YW1wbGUuYXBwWkFCQ0RFMTIzNDWhHlxBQkNERTEyMzQ1LipEAAEC/zNByH0EwAAAACM/+AAAAAAAAAAIAAsAHQAyAEgAZQB3AIYAmQCrALgAwQDKANMA5gDqAOwBFwEYAR0BxAHJAdIBJgE/AWUBdAGNAaoBtQG3AAAAAAAAAgEAAAAAAAAAHwAAAAAAAAAAAAAAAAAAAds="

	func testReadsTheRecordsRustWrites() throws {
		let records = try XCTUnwrap(InstalledAppRecord.records(from: XCTUnwrap(Data(base64Encoded: writtenByRust))))
		XCTAssertEqual(records, [
			InstalledAppRecord(
				bundleID: "com.example.app",
				name: "Exämple ✓",
				version: "2.0",
				build: "7",
				signer: "Apple Development: Jane Doe (AB12CD34EF)",
				profileValidated: true,
				applicationIdentifier: "ABCDE12345.com.example.app",
				teamID: "ABCDE12345",
				debuggable: true,
				hasAppleAccount: true,
				keys: ["ApplicationDSID", "CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion", "Entitlements", "ProfileValidated", "SignerIdentity", "SomeData", "SomeDate", "SomeReal"]
			),
		])
		XCTAssertEqual(records[0].origin, .certificate("Apple Development: Jane Doe (AB12CD34EF)"))
		XCTAssertTrue(records[0].dataOpens)
	}

	func testReadsAnAppStoreApp() throws {
		let record: [String: Any] = [
			"CFBundleName": "YouTube",
			"CFBundleShortVersionString": "20.1",
			"CFBundleVersion": "20.1.3",
			"SignerIdentity": "Apple iPhone OS Application Signing",
			"ApplicationDSID": 0,
			"Entitlements": [
				"application-identifier": "EQHXZ8M8AV.com.google.ios.youtube",
				"com.apple.developer.team-identifier": "EQHXZ8M8AV",
				"beta-reports-active": true,
				"get-task-allow": false,
			] as [String: Any],
		]
		let answer: [String: Any] = ["com.google.ios.youtube": record, "not.a.record": "text"]
		let data = try PropertyListSerialization.data(fromPropertyList: answer, format: .binary, options: 0)
		let records = try XCTUnwrap(InstalledAppRecord.records(from: data))
		XCTAssertEqual(records.map(\.bundleID), ["com.google.ios.youtube"], "a value that isn't a record is left out")
		let app = records[0]
		XCTAssertEqual(app.name, "YouTube", "CFBundleName when there's no display name")
		XCTAssertEqual(app.origin, .marketplace, "Apple's signature without an Apple Account")
		XCTAssertFalse(app.dataOpens)
		XCTAssertNil(app.profileValidated)
		XCTAssertTrue(app.betaReports)
		XCTAssertFalse(app.debuggable)
		XCTAssertFalse(app.hasAppleAccount, "an ApplicationDSID of 0 names no account")
		XCTAssertEqual(app.signing, "signer “Apple iPhone OS Application Signing”, profile validated not given, App ID EQHXZ8M8AV.com.google.ios.youtube, team EQHXZ8M8AV, beta-reports-active")
	}

	func testARecordWithoutSigningSaysSo() {
		let app = InstalledAppRecord(bundleID: "com.example.bare", record: ["ProfileValidated": "1"])
		XCTAssertEqual(app.signing, "signer not given, profile validated yes, App ID not given, team not given")
		XCTAssertEqual(app.keys, ["ProfileValidated"])
	}

	func testAnAnswerThatIsntAPlistIsNil() throws {
		XCTAssertNil(InstalledAppRecord.records(from: Data("not a plist".utf8)))
		let none = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
		XCTAssertEqual(InstalledAppRecord.records(from: none), [])
	}

	func testShowsANameOnOneLine() {
		XCTAssertEqual(InstalledAppRecord(bundleID: "a", name: "Shirabe Jisho\nJapanese").displayName, "Shirabe Jisho Japanese")
		XCTAssertEqual(InstalledAppRecord(bundleID: "a", name: "\u{200E}WhatsApp\u{200E}").displayName, "WhatsApp")
		XCTAssertEqual(InstalledAppRecord(bundleID: "a", name: "  Two   Spaces \t").displayName, "Two Spaces")
		XCTAssertEqual(InstalledAppRecord(bundleID: "a", name: "\u{200F}").displayName, "")
		XCTAssertEqual(InstalledAppRecord(bundleID: "a", name: "Exämple ✓").displayName, "Exämple ✓")
	}

	/// As iOS 27 gave them in #99's test.
	func testTellsWhereAnAppCameFrom() {
		let store = InstalledAppRecord(bundleID: "com.spotify.client", signer: InstalledAppRecord.appleSigner, applicationIdentifier: "8W66MEA7DD.com.spotify.client", hasAppleAccount: true)
		XCTAssertEqual(store.origin, .appStore)
		XCTAssertFalse(store.dataOpens)
		let marketplace = InstalledAppRecord(bundleID: "com.stremio.pal", signer: InstalledAppRecord.appleSigner)
		XCTAssertEqual(marketplace.origin, .marketplace)
		XCTAssertFalse(marketplace.dataOpens)
		let testFlight = InstalledAppRecord(bundleID: "nl.wethr.app", signer: "TestFlight Beta Distribution", profileValidated: true, betaReports: true, hasAppleAccount: true)
		XCTAssertEqual(testFlight.origin, .testFlight)
		XCTAssertTrue(testFlight.dataOpens)
		let signed = InstalledAppRecord(bundleID: "com.Beacon.BeaconStore-iOS", signer: "Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)", profileValidated: true)
		XCTAssertEqual(signed.origin, .certificate("Apple Distribution: Kestrel Labs Ltd (K7X2M9Q4PL)"))
		XCTAssertTrue(signed.dataOpens)
		XCTAssertNil(InstalledAppRecord(bundleID: "com.example.bare").origin)
	}
}
