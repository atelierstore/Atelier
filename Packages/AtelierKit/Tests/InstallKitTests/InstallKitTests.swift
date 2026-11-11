import Foundation
import XCTest
@testable import InstallKit

final class InflateTests: XCTestCase {
	private func data(_ base64: String) -> Data { Data(base64Encoded: base64)! }

	func testFixedHuffman() throws {
		XCTAssertEqual(try Inflate.decompress(data(Fixtures.fixedHuffman)), data(Fixtures.text))
	}

	func testDynamicHuffman() throws {
		XCTAssertEqual(try Inflate.decompress(data(Fixtures.dynamicHuffman)), data(Fixtures.text))
	}

	func testStoredBlocks() throws {
		XCTAssertEqual(try Inflate.decompress(data(Fixtures.storedBlocks)), data(Fixtures.text).prefix(1000))
	}

	func testTruncatedInputThrows() {
		let input = data(Fixtures.dynamicHuffman).prefix(20)
		XCTAssertThrowsError(try Inflate.decompress(Data(input)))
	}

	func testOutputLimit() {
		XCTAssertThrowsError(try Inflate.decompress(data(Fixtures.dynamicHuffman), maxOutput: 100)) {
			XCTAssertEqual($0 as? Inflate.Error, .outputTooLarge)
		}
	}
}

final class IPAInfoTests: XCTestCase {
	func testStoredBinaryPlist() throws {
		let info = try IPAInfo.read(ipaData: Data(base64Encoded: Fixtures.storedIPA)!)
		XCTAssertEqual(info, IPAInfo(bundleID: "com.example.spike", version: "2.1", name: "Spike & Co", buildVersion: "42"))
	}

	func testDeflatedXMLPlistFallsBackToBundleVersionAndName() throws {
		let info = try IPAInfo.read(ipaData: Data(base64Encoded: Fixtures.deflatedIPA)!)
		XCTAssertEqual(info, IPAInfo(bundleID: "com.example.xml", version: "7", name: "XML App"))
	}

	func testReadsPrivacyPermissions() throws {
		let plist = try PropertyListSerialization.data(fromPropertyList: [
			"CFBundleIdentifier": "com.example.app",
			"NSCameraUsageDescription": "Scans codes.",
			"NFCReaderUsageDescription": "Reads tags.",
			"NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
		], format: .xml, options: 0)
		let info = try IPAInfo.parse(infoPlist: plist)
		XCTAssertEqual(info.privacy, ["NSCameraUsageDescription": "Scans codes.", "NFCReaderUsageDescription": "Reads tags."])
	}

	func testReadsWhetherItTakesACertificate() throws {
		func info(_ extra: [String: Any]) throws -> IPAInfo {
			try IPAInfo.parse(infoPlist: PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.atelier.app"].merging(extra) { $1 }, format: .xml, options: 0))
		}
		// Builds of Atelier from #113 on say so; others, and other apps, don't.
		XCTAssertTrue(try info([IPAInfo.takesCertificateKey: true]).takesCertificate)
		XCTAssertFalse(try info([IPAInfo.takesCertificateKey: false]).takesCertificate)
		XCTAssertFalse(try info([IPAInfo.takesCertificateKey: "YES"]).takesCertificate)
		XCTAssertFalse(try info([:]).takesCertificate)
	}

	func testIgnoresNestedInfoPlists() {
		XCTAssertTrue(IPAInfo.isTopLevelInfoPlist("Payload/A.app/Info.plist"))
		XCTAssertFalse(IPAInfo.isTopLevelInfoPlist("Payload/A.app/Frameworks/X.framework/Info.plist"))
		XCTAssertFalse(IPAInfo.isTopLevelInfoPlist("Payload/A/Info.plist"))
	}

	func testNotAZip() {
		XCTAssertThrowsError(try IPAInfo.read(ipaData: Data("hello".utf8))) {
			XCTAssertEqual($0 as? IPAInfo.Error, .notAZip)
		}
	}

	func testDataSliceWithNonZeroStartIndex() throws {
		let full = Data([0, 0, 0]) + Data(base64Encoded: Fixtures.storedIPA)!
		let slice = full[3...]
		XCTAssertEqual(try IPAInfo.read(ipaData: slice).bundleID, "com.example.spike")
	}

	func testSizesAreTheDecompressedOnes() throws {
		let zip = ZipReader(data: Data(base64Encoded: Fixtures.deflatedIPA)!)
		let sizes = try zip.sizes { $0.hasSuffix("Info.plist") }
		let entries = try zip.entries { $0.hasSuffix("Info.plist") }
		XCTAssertEqual(sizes.count, 2)
		XCTAssertEqual(sizes.map { $0.path }, entries.map { $0.path })
		XCTAssertEqual(sizes.map { $0.size }, entries.map { Int64($0.data.count) })
	}
}

final class PairingFileTests: XCTestCase {
	private func plist(_ dict: [String: Any]) -> Data {
		try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
	}

	func testLockdownRecord() {
		let info = PairingFileInspector.inspect(plist([
			"DeviceCertificate": Data([1]), "HostCertificate": Data([1]), "HostPrivateKey": Data([1]),
			"RootCertificate": Data([1]), "HostID": "H", "SystemBUID": "B",
			"UDID": "0000-1111", "WiFiMACAddress": "aa:bb",
		]))
		XCTAssertEqual(info.kind, .lockdown)
		XCTAssertEqual(info.udid, "0000-1111")
		XCTAssertEqual(info.problems, [])
	}

	func testLockdownRecordWithoutUDIDOrMAC() {
		let info = PairingFileInspector.inspect(plist([
			"DeviceCertificate": Data([1]), "HostCertificate": Data([1]), "HostPrivateKey": Data([1]),
			"RootCertificate": Data([1]), "HostID": "H", "SystemBUID": "B",
		]))
		XCTAssertEqual(info.kind, .lockdown)
		XCTAssertEqual(info.problems.count, 2)
	}

	func testRemotePairingRecord() {
		let info = PairingFileInspector.inspect(plist([
			"public_key": Data(repeating: 1, count: 32),
			"private_key": Data(repeating: 2, count: 32),
			"identifier": "abc",
		]))
		XCTAssertEqual(info.kind, .remotePairing)
		XCTAssertEqual(info.problems, [])
	}

	func testRemotePairingRecordWithBadKey() {
		let info = PairingFileInspector.inspect(plist([
			"public_key": Data(repeating: 1, count: 31),
			"private_key": Data(repeating: 2, count: 32),
			"identifier": "abc",
		]))
		XCTAssertEqual(info.kind, .remotePairing)
		XCTAssertEqual(info.problems, ["public_key is not 32 bytes of data"])
	}

	func testGarbage() {
		XCTAssertEqual(PairingFileInspector.inspect(Data("nope".utf8)).kind, .unknown)
		XCTAssertEqual(PairingFileInspector.inspect(plist(["foo": "bar"])).kind, .unknown)
	}
}

final class InstallLinkTests: XCTestCase {
	let info = IPAInfo(bundleID: "com.example.app", version: "1.0", name: "A&B Pro+")
	let package = URL(string: "http://127.0.0.1:4567/abc.ipa")!

	func testAtelierManifestURL() {
		let url = InstallLink.manifestURL(
			endpoint: URL(string: "https://m.example.workers.dev/manifest")!,
			info: info,
			packageURL: package
		)
		XCTAssertEqual(
			url.absoluteString,
			"https://m.example.workers.dev/manifest?bundleid=com.example.app&name=A%26B%20Pro%2B&version=1.0&url=http%3A%2F%2F127.0.0.1%3A4567%2Fabc.ipa"
		)
	}

	func testMultiAppManifestURLRepeatsParametersInOrder() {
		let other = IPAInfo(bundleID: "org.example.other", version: "2.0", name: "Other")
		let url = InstallLink.manifestURL(
			endpoint: URL(string: "https://m.example.workers.dev/manifest")!,
			apps: [(info, package), (other, URL(string: "http://127.0.0.1:4567/def.ipa")!)]
		)
		XCTAssertEqual(
			url.absoluteString,
			"https://m.example.workers.dev/manifest?bundleid=com.example.app&name=A%26B%20Pro%2B&version=1.0&url=http%3A%2F%2F127.0.0.1%3A4567%2Fabc.ipa"
				+ "&bundleid=org.example.other&name=Other&version=2.0&url=http%3A%2F%2F127.0.0.1%3A4567%2Fdef.ipa"
		)
	}

	func testITMSURLEncodesWholeManifestURL() {
		let manifest = URL(string: "https://m.example/manifest?a=1&b=2")!
		XCTAssertEqual(
			InstallLink.itmsServicesURL(manifest: manifest).absoluteString,
			"itms-services://?action=download-manifest&url=https%3A%2F%2Fm.example%2Fmanifest%3Fa%3D1%26b%3D2"
		)
	}
}

final class HTTPTests: XCTestCase {
	func testParsesCompleteHead() throws {
		let head = try HTTPRequestHead.parse(Data("GET /abc.ipa?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\n\r\n".utf8))
		XCTAssertEqual(head, HTTPRequestHead(method: "GET", path: "/abc.ipa", headers: ["host": "127.0.0.1", "range": "bytes=0-9"]))
	}

	func testIncompleteHeadReturnsNil() throws {
		XCTAssertNil(try HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
	}

	func testMalformedHeadThrows() {
		XCTAssertThrowsError(try HTTPRequestHead.parse(Data("NOPE\r\n\r\n".utf8)))
	}

	func testRanges() throws {
		XCTAssertNil(try ByteRange.parse(nil, fileSize: 100))
		XCTAssertEqual(try ByteRange.parse("bytes=0-9", fileSize: 100), ByteRange(start: 0, end: 9))
		XCTAssertEqual(try ByteRange.parse("bytes=90-", fileSize: 100), ByteRange(start: 90, end: 99))
		XCTAssertEqual(try ByteRange.parse("bytes=-10", fileSize: 100), ByteRange(start: 90, end: 99))
		XCTAssertEqual(try ByteRange.parse("bytes=50-500", fileSize: 100), ByteRange(start: 50, end: 99))
		XCTAssertNil(try ByteRange.parse("bytes=0-1,5-6", fileSize: 100))
		XCTAssertThrowsError(try ByteRange.parse("bytes=100-", fileSize: 100))
		XCTAssertThrowsError(try ByteRange.parse("bytes=9-3", fileSize: 100))
	}
}
