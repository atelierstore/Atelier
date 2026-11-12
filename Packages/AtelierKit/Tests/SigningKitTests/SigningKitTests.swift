import CertKit
import Foundation
import InstallKit
import XCTest
import ZIPFoundation
@testable import SigningKit

/// Builds test IPAs and stand-in Mach-O files. The pipeline tests run zsign's
/// place with `FakeEngine`, so they also run on Linux; ZsignSigningTests
/// (macOS only) signs real binaries.
enum Fixture {
	static func url(_ name: String) throws -> URL {
		try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/\(name)")
	}

	static let password = "ownstore"

	static func temporaryFolder() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("SigningKitTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// A thin 64-bit arm64 Mach-O header with no code. With `cryptID`, it
	/// carries an LC_ENCRYPTION_INFO_64 command with that cryptid.
	static func machO(cryptID: UInt32? = nil) -> Data {
		var commands = Data()
		if let cryptID {
			commands.append(le32(0x2C)) // LC_ENCRYPTION_INFO_64
			commands.append(le32(24))
			commands.append(le32(0x4000)) // cryptoff
			commands.append(le32(0x1000)) // cryptsize
			commands.append(le32(cryptID))
			commands.append(le32(0)) // pad
		}
		var data = Data()
		data.append(le32(0xFEED_FACF))
		data.append(le32(0x0100_000C)) // CPU_TYPE_ARM64
		data.append(le32(0))
		data.append(le32(2)) // MH_EXECUTE
		data.append(le32(cryptID == nil ? 0 : 1))
		data.append(le32(UInt32(commands.count)))
		data.append(le32(0))
		data.append(le32(0))
		data.append(commands)
		data.append(Data(count: 64))
		return data
	}

	/// A thin Mach-O with a code signature: a code directory and, with
	/// `cmsBytes` > 0, a CMS blob of that size, the way zsign lays them out.
	/// `directoryBytes` pads the code directory, as a large binary's is.
	/// With `entitlements`, the signature also carries that plist; with
	/// `cms`, its CMS blob is that signature rather than zeros.
	static func signedMachO(cmsBytes: Int, directoryBytes: Int = 0, entitlements: [String: Any]? = nil, cms: Data? = nil) -> Data {
		var blobs: [(slot: UInt32, data: Data)] = [
			(0, be32(0xFADE_0C02) + be32(UInt32(8 + directoryBytes)) + Data(count: directoryBytes)), // CSSLOT_CODEDIRECTORY
		]
		if let entitlements {
			let plist = try! PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
			blobs.append((5, be32(0xFADE_7171) + be32(UInt32(8 + plist.count)) + plist)) // CSSLOT_ENTITLEMENTS
		}
		let cms = cms ?? Data(count: cmsBytes)
		blobs.append((0x10000, be32(0xFADE_0B01) + be32(UInt32(8 + cms.count)) + cms)) // CSSLOT_SIGNATURESLOT
		let headerSize = 12 + blobs.count * 8
		var signature = Data()
		signature.append(be32(0xFADE_0CC0))
		signature.append(be32(UInt32(headerSize + blobs.reduce(0) { $0 + $1.data.count })))
		signature.append(be32(UInt32(blobs.count)))
		var offset = headerSize
		for blob in blobs {
			signature.append(be32(blob.slot))
			signature.append(be32(UInt32(offset)))
			offset += blob.data.count
		}
		for blob in blobs { signature.append(blob.data) }

		let signatureOffset: UInt32 = 0x100
		var data = Data()
		data.append(le32(0xFEED_FACF))
		data.append(le32(0x0100_000C))
		data.append(le32(0))
		data.append(le32(2))
		data.append(le32(1))
		data.append(le32(16))
		data.append(le32(0))
		data.append(le32(0))
		data.append(le32(0x1D)) // LC_CODE_SIGNATURE
		data.append(le32(16))
		data.append(le32(signatureOffset))
		data.append(le32(UInt32(signature.count)))
		data.append(Data(count: Int(signatureOffset) - data.count))
		data.append(signature)
		return data
	}

	/// A fat Mach-O holding the given slices, each at a 4 KB boundary.
	static func fat(_ slices: [Data]) -> Data {
		var data = Data()
		data.append(be32(0xCAFE_BABE))
		data.append(be32(UInt32(slices.count)))
		var offset: UInt32 = 0x1000
		for slice in slices {
			data.append(be32(0x0100_000C))
			data.append(be32(0))
			data.append(be32(offset))
			data.append(be32(UInt32(slice.count)))
			data.append(be32(12))
			offset += 0x1000
		}
		for (index, slice) in slices.enumerated() {
			data.append(Data(count: 0x1000 * (index + 1) - data.count))
			data.append(slice)
		}
		return data
	}

	static func infoPlist(_ bundleID: String, executable: String?, extra: [String: Any] = [:]) throws -> Data {
		var plist: [String: Any] = [
			"CFBundleIdentifier": bundleID,
			"CFBundleShortVersionString": "1.2",
			"CFBundleVersion": "7",
			"CFBundleName": "Test",
		]
		if let executable { plist["CFBundleExecutable"] = executable }
		plist.merge(extra) { $1 }
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
	}

	/// Writes `files` (relative paths to contents) under `root`, as
	/// executables when the contents start with a Mach-O magic.
	static func write(_ files: [String: Data], under root: URL) throws {
		for (path, contents) in files {
			let url = root.appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try contents.write(to: url)
			if contents.prefix(4) == le32(0xFEED_FACF) || contents.prefix(4) == be32(0xCAFE_BABE) {
				try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
			}
		}
	}

	/// An app with an extension, a framework and a dylib, the shapes zsign
	/// has to sign inside out.
	static func appFiles(main: Data = machO()) throws -> [String: Data] {
		[
			"Payload/Test.app/Info.plist": try infoPlist("com.example.test", executable: "Test"),
			"Payload/Test.app/Test": main,
			"Payload/Test.app/Frameworks/Kit.framework/Info.plist": try infoPlist("com.example.kit", executable: "Kit"),
			"Payload/Test.app/Frameworks/Kit.framework/Kit": machO(),
			"Payload/Test.app/Frameworks/libExtra.dylib": machO(),
			"Payload/Test.app/PlugIns/Widget.appex/Info.plist": try infoPlist("com.example.test.widget", executable: "Widget"),
			"Payload/Test.app/PlugIns/Widget.appex/Widget": machO(),
			"Payload/Test.app/Resources.bundle/Info.plist": try infoPlist("com.example.resources", executable: nil),
			"Payload/Test.app/Resources.bundle/image.png": Data([1, 2, 3]),
		]
	}

	/// Zips `files` (plus `symlinks`, path to target) into an IPA.
	static func ipa(_ files: [String: Data], symlinks: [String: String] = [:], in folder: URL) throws -> URL {
		let staging = folder.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
		try write(files, under: staging)
		for (path, target) in symlinks {
			let url = staging.appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
		}
		let ipa = folder.appendingPathComponent("\(UUID().uuidString).ipa")
		let archive = try Archive(url: ipa, accessMode: .create)
		for path in try FileManager.default.subpathsOfDirectory(atPath: staging.path).sorted() {
			try archive.addEntry(with: path, relativeTo: staging, compressionMethod: .deflate)
		}
		try FileManager.default.removeItem(at: staging)
		return ipa
	}

	static func entries(of ipa: URL) throws -> [String: Entry] {
		let archive = try Archive(url: ipa, accessMode: .read)
		return Dictionary(uniqueKeysWithValues: archive.map { ($0.path, $0) })
	}

	static func contents(of path: String, in ipa: URL) throws -> Data {
		let archive = try Archive(url: ipa, accessMode: .read)
		let entry = try XCTUnwrap(archive[path])
		var data = Data()
		_ = try archive.extract(entry) { data.append($0) }
		return data
	}

	static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
	static func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}

/// Stands in for zsign: records the call and leaves a marker in the app, or
/// throws what it's given.
final class FakeEngine: SigningEngine, @unchecked Sendable {
	var error: SigningError?
	private(set) var signedApps: [String] = []
	private(set) var lastOptions: SigningOptions?
	/// The entitlements file it was given, read while it still exists.
	private(set) var lastEntitlements: [String: Any]?
	/// The libraries it had executables load, by the executable's path
	/// inside the app folder, and the executables it said had no room.
	private(set) var loads: [String: [String]] = [:]
	var noRoom: Set<String> = []

	init(error: SigningError? = nil) {
		self.error = error
	}

	func load(_ path: String, into executable: URL) -> Bool {
		let parts = executable.pathComponents
		let relative = parts.firstIndex { $0.hasSuffix(".app") }.map { parts[($0 + 1)...].joined(separator: "/") } ?? executable.lastPathComponent
		guard !noRoom.contains(relative) else { return false }
		loads[relative, default: []].append(path)
		return true
	}

	func sign(app: URL, identity: SigningIdentity, options: SigningOptions) throws {
		if let error { throw error }
		signedApps.append(app.lastPathComponent)
		lastOptions = options
		lastEntitlements = try options.entitlements.map {
			try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: $0), format: nil) as? [String: Any])
		}
		try Data("signed".utf8).write(to: app.appendingPathComponent("_CodeSignature-fake"))
		if let name = options.displayName {
			let url = app.appendingPathComponent("Info.plist")
			var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
			plist["CFBundleDisplayName"] = name
			try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
		}
	}
}

final class MachOTests: XCTestCase {
	private var folder: URL!

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func inspect(_ data: Data) throws -> MachO.Kind {
		let url = folder.appendingPathComponent(UUID().uuidString)
		try data.write(to: url)
		return try MachO.inspect(url)
	}

	func testThinBinaries() throws {
		XCTAssertEqual(try inspect(Fixture.machO()), .machO(encrypted: false))
		XCTAssertEqual(try inspect(Fixture.machO(cryptID: 0)), .machO(encrypted: false))
		XCTAssertEqual(try inspect(Fixture.machO(cryptID: 1)), .machO(encrypted: true))
	}

	func testFatBinaries() throws {
		XCTAssertEqual(try inspect(Fixture.fat([Fixture.machO(), Fixture.machO(cryptID: 0)])), .machO(encrypted: false))
		XCTAssertEqual(try inspect(Fixture.fat([Fixture.machO(), Fixture.machO(cryptID: 1)])), .machO(encrypted: true))
	}

	func testFindsTheCMSSignature() throws {
		func signed(_ data: Data) throws -> Bool {
			let url = folder.appendingPathComponent(UUID().uuidString)
			try data.write(to: url)
			return try MachO.hasCMSSignature(url)
		}
		XCTAssertTrue(try signed(Fixture.signedMachO(cmsBytes: 64)))
		// What zsign writes when it can't build the CMS: an empty wrapper.
		XCTAssertFalse(try signed(Fixture.signedMachO(cmsBytes: 0)))
		XCTAssertFalse(try signed(Fixture.machO()))
		XCTAssertFalse(try signed(Data("text".utf8)))
		XCTAssertTrue(try signed(Fixture.fat([Fixture.signedMachO(cmsBytes: 64), Fixture.signedMachO(cmsBytes: 32)])))
		XCTAssertFalse(try signed(Fixture.fat([Fixture.signedMachO(cmsBytes: 64), Fixture.machO()])))
		// A ~100 MB binary's code directories put the CMS blob megabytes in.
		XCTAssertTrue(try signed(Fixture.signedMachO(cmsBytes: 64, directoryBytes: 3 << 20)))
	}

	func testOtherFiles() throws {
		XCTAssertEqual(try inspect(Data("#!/bin/sh\necho hi\n".utf8)), .notMachO)
		XCTAssertEqual(try inspect(Data()), .notMachO)
		// A Mach-O header whose load commands run past the end of the file.
		XCTAssertEqual(try inspect(Fixture.machO(cryptID: 1).prefix(40)), .notMachO)
		// A Java class file shares the fat magic.
		XCTAssertEqual(try inspect(Fixture.be32(0xCAFE_BABE) + Fixture.be32(0x0000_0034) + Data(count: 64)), .notMachO)
	}
}

final class IPASignerTests: XCTestCase {
	private var folder: URL!
	private var work: URL!
	private let identity = SigningIdentity(p12: URL(fileURLWithPath: "/nonexistent.p12"), profile: URL(fileURLWithPath: "/nonexistent.mobileprovision"), password: "")

	override func setUpWithError() throws {
		folder = try Fixture.temporaryFolder()
		work = folder.appendingPathComponent("work", isDirectory: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: folder)
	}

	private func signer(_ engine: FakeEngine = FakeEngine(), freeSpace: Int64? = nil) -> IPASigner {
		var signer = IPASigner(engine: engine, workRoot: work)
		if let freeSpace { signer.freeSpace = { _ in freeSpace } }
		return signer
	}

	private func sign(_ ipa: URL, with signer: IPASigner, options: SigningOptions = SigningOptions(), progress: (@Sendable (SigningProgress) -> Void)? = nil) async throws -> SignedIPA {
		try await signer.sign(ipa: ipa, with: identity, options: options, outputDirectory: folder.appendingPathComponent("out"), progress: progress)
	}

	private func assertThrows(_ expected: SigningError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
		do {
			try await body()
			XCTFail("expected \(expected)", file: file, line: line)
		} catch let error as SigningError {
			XCTAssertEqual(error, expected, file: file, line: line)
		} catch {
			XCTFail("expected \(expected), got \(error)", file: file, line: line)
		}
	}

	/// The work folder is empty after every job, whatever happened.
	private func assertCleanedUp(file: StaticString = #filePath, line: UInt = #line) {
		let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
		XCTAssertEqual(left, [], file: file, line: line)
	}

	func testRemovesWhatFeatherRemovesBeforeSigning() async throws {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/Info.plist"] = try Fixture.infoPlist("com.example.test", executable: "Test", extra: ["UISupportedDevices": ["iPhone15,2"]])
		files["Payload/Test.app/_CodeSignature/CodeResources"] = Data("old".utf8)
		files["Payload/Test.app/PlugIns/Widget.appex/_CodeSignature/CodeResources"] = Data("old".utf8)
		files["Payload/Test.app/Frameworks/Kit.framework/_CodeSignature/CodeResources"] = Data("old".utf8)
		files["Payload/Test.app/embedded.mobileprovision"] = Data("old".utf8)
		files["Payload/Test.app/PlugIns/Widget.appex/embedded.mobileprovision"] = Data("kept".utf8)
		files["Payload/Test.app/SignedByEsign"] = Data()
		files["Payload/Test.app/com.apple.WatchPlaceholder/Placeholder"] = Data()
		files["Payload/Test.app/Watch/Stub.app/Stub"] = Data()
		let ipa = try Fixture.ipa(files, in: folder)

		let signed = try await sign(ipa, with: signer())

		let paths = try Fixture.entries(of: signed.url).keys
		let left = paths.filter { $0.contains("_CodeSignature/") || $0.contains("SignedByEsign") || $0.contains("WatchPlaceholder") || $0.contains("Stub.app") || $0.hasSuffix("Test.app/embedded.mobileprovision") }
		XCTAssertEqual(left, [], "\(paths.sorted())")
		XCTAssertTrue(paths.contains("Payload/Test.app/PlugIns/Widget.appex/embedded.mobileprovision"))
		let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Fixture.contents(of: "Payload/Test.app/Info.plist", in: signed.url), format: nil) as? [String: Any])
		XCTAssertNil(info["UISupportedDevices"])
		XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.test")
		assertCleanedUp()
	}

	func testSignsAndRepacksOnlyThePayload() async throws {
		var files = try Fixture.appFiles()
		files["SwiftSupport/iphoneos/libswiftCore.dylib"] = Fixture.machO()
		files["iTunesMetadata.plist"] = Data("<plist/>".utf8)
		files["__MACOSX/Payload/._Test.app"] = Data([0])
		let ipa = try Fixture.ipa(files, symlinks: ["Payload/Test.app/Frameworks/Kit.framework/Current": "Kit"], in: folder)
		let engine = FakeEngine()

		let signed = try await sign(ipa, with: signer(engine), options: SigningOptions(displayName: "Renamed"))

		XCTAssertEqual(engine.signedApps, ["Test.app"])
		XCTAssertEqual(engine.lastOptions?.displayName, "Renamed")
		XCTAssertEqual(signed.info, IPAInfo(bundleID: "com.example.test", version: "1.2", name: "Renamed", buildVersion: "7"))
		XCTAssertEqual(signed.url.deletingLastPathComponent().lastPathComponent, "out")
		XCTAssertEqual(try IPAInfo.read(ipaAt: signed.url), signed.info)

		let entries = try Fixture.entries(of: signed.url)
		XCTAssertTrue(entries.keys.allSatisfy { $0.hasPrefix("Payload") }, "\(entries.keys.sorted())")
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/_CodeSignature-fake", in: signed.url), Data("signed".utf8))
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/PlugIns/Widget.appex/Widget", in: signed.url), Fixture.machO())
		XCTAssertEqual(entries["Payload/Test.app/Frameworks/Kit.framework/Current"]?.type, .symlink)
		XCTAssertEqual(entries["Payload/Test.app/Test"]?.type, .file)
		XCTAssertEqual(entries["Payload/Test.app/Test"].map { $0.compressedSize == $0.uncompressedSize }, true, "stored, not compressed")
		XCTAssertNotNil(entries["Payload/"] ?? entries["Payload"])

		// Executables stay executable.
		let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
		try FileManager.default.unzipItem(at: signed.url, to: unpacked)
		let permissions = try FileManager.default.attributesOfItem(atPath: unpacked.appendingPathComponent("Payload/Test.app/Test").path)[.posixPermissions] as? NSNumber
		XCTAssertEqual(permissions?.intValue, 0o755)
		assertCleanedUp()
	}

	func testAddsTheInstallCheckSchemeBeforeSigning() async throws {
		var files = try Fixture.appFiles()
		files["Payload/Test.app/Info.plist"] = try Fixture.infoPlist("com.example.test", executable: "Test", extra: [
			"CFBundleURLTypes": [["CFBundleURLSchemes": ["example", "atelier-check-1"]]],
		])
		let ipa = try Fixture.ipa(files, in: folder)

		let signed = try await sign(ipa, with: signer(), options: SigningOptions(installCheckScheme: "atelier-check-4"))

		XCTAssertEqual(signed.info.urlSchemes, ["example", "atelier-check-4"])
		XCTAssertEqual(try IPAInfo.read(ipaAt: signed.url).urlSchemes, ["example", "atelier-check-4"])

		// Signing again without one drops it.
		let again = try await sign(signed.url, with: signer())
		XCTAssertEqual(again.info.urlSchemes, ["example"])
		assertCleanedUp()
	}

	func testPutsInTheCertificateACopyOfAtelierComesWith() async throws {
		var files = try Fixture.appFiles()
		// One the IPA brought, which no Atelier put there.
		files["Payload/Test.app/AtelierCertificate.plist"] = Data("someone else's".utf8)
		let ipa = try Fixture.ipa(files, in: folder)
		let certificate = PackagedCertificate(p12: Data([1, 2, 3]), profile: Data([4, 5]), password: "secret", name: "Team")

		let signed = try await sign(ipa, with: signer(), options: SigningOptions(target: .copy(2), packagedCertificate: certificate))
		let written = try Fixture.contents(of: "Payload/Test.app/\(PackagedCertificate.fileName)", in: signed.url)
		XCTAssertEqual(try PackagedCertificate(file: written), certificate)

		// Without one, the IPA's goes.
		let without = try await sign(ipa, with: signer(), options: SigningOptions(target: .copy(2)))
		XCTAssertFalse(try Fixture.entries(of: without.url).keys.contains("Payload/Test.app/AtelierCertificate.plist"))
		assertCleanedUp()
	}

	func testRemovesALinkInPlaceOfTheCertificate() throws {
		let app = folder.appendingPathComponent("Test.app", isDirectory: true)
		try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
		let outside = folder.appendingPathComponent("outside.plist")
		try Data("left alone".utf8).write(to: outside)
		let link = app.appendingPathComponent(PackagedCertificate.fileName)
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside.plist")

		let certificate = PackagedCertificate(p12: Data([1]), profile: Data([2]), password: "")
		try IPASigner.setPackagedCertificate(certificate, in: app)
		XCTAssertEqual(try Data(contentsOf: outside), Data("left alone".utf8))
		XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
		XCTAssertEqual(try PackagedCertificate(file: Data(contentsOf: link)), certificate)

		// And a dangling one, without a certificate.
		try FileManager.default.removeItem(at: link)
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../gone.plist")
		try IPASigner.setPackagedCertificate(nil, in: app)
		XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: link.path))
	}

	func testCompressesWhenAsked() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(main: Fixture.machO() + Data(count: 100_000)), in: folder)
		let signed = try await sign(ipa, with: signer(), options: SigningOptions(compressed: true))
		let entry = try XCTUnwrap(Fixture.entries(of: signed.url)["Payload/Test.app/Test"])
		XCTAssertLessThan(entry.compressedSize, entry.uncompressedSize)
	}

	func testPacksAnInstalledAppToSignItAgain() async throws {
		// An app as iOS keeps it installed: signed, with its profile.
		var files = try Fixture.appFiles()
		files["Payload/Test.app/_CodeSignature/CodeResources"] = Data("old".utf8)
		files["Payload/Test.app/embedded.mobileprovision"] = Data("old".utf8)
		let installed = folder.appendingPathComponent("installed", isDirectory: true)
		try Fixture.write(files, under: installed)
		let app = installed.appendingPathComponent("Payload/Test.app")
		try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Frameworks/Kit.framework/Current").path, withDestinationPath: "Kit")

		let ipa = try await signer().pack(app: app, outputDirectory: folder.appendingPathComponent("out"))

		XCTAssertEqual(ipa.deletingLastPathComponent().lastPathComponent, "out")
		XCTAssertEqual(try IPAInfo.read(ipaAt: ipa), IPAInfo(bundleID: "com.example.test", version: "1.2", name: "Test", buildVersion: "7"))
		let entries = try Fixture.entries(of: ipa)
		XCTAssertEqual(entries["Payload/Test.app/Frameworks/Kit.framework/Current"]?.type, .symlink)
		XCTAssertEqual(try Fixture.contents(of: "Payload/Test.app/PlugIns/Widget.appex/Widget", in: ipa), Fixture.machO())
		XCTAssertEqual(entries["Payload/Test.app/Test"].map { $0.compressedSize == $0.uncompressedSize }, true, "stored, not compressed")
		XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path), "the app itself is left alone")
		assertCleanedUp()

		// It signs like any other IPA, without the old signature and profile.
		let signed = try await sign(ipa, with: signer(), options: SigningOptions(infoPlistValues: ["AtelierInstallToken": "abc"]))
		let paths = try Fixture.entries(of: signed.url).keys
		XCTAssertFalse(paths.contains("Payload/Test.app/_CodeSignature/CodeResources"))
		XCTAssertFalse(paths.contains("Payload/Test.app/embedded.mobileprovision"))
		let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Fixture.contents(of: "Payload/Test.app/Info.plist", in: signed.url), format: nil) as? [String: Any])
		XCTAssertEqual(info["AtelierInstallToken"] as? String, "abc")

		// Not without room for the copy and the IPA, or without an Info.plist.
		await assertThrows(.outOfSpace(needed: Int64(IPASigner.size(of: app)) * 2 + IPASigner.margin, available: 1000)) {
			_ = try await signer(freeSpace: 1000).pack(app: app, outputDirectory: folder)
		}
		await assertThrows(.corruptArchive("the app has no Info.plist")) {
			_ = try await signer().pack(app: installed, outputDirectory: folder)
		}
		assertCleanedUp()
	}

	func testReportsProgressInOrder() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let recorder = ProgressRecorder()
		_ = try await sign(ipa, with: signer(), progress: { recorder.append($0) })
		let steps = recorder.steps
		XCTAssertEqual(steps.first, .unpacking(0))
		XCTAssertEqual(steps.last, .packing(1))
		XCTAssertTrue(steps.contains(.unpacking(1)))
		let signing = try XCTUnwrap(steps.firstIndex(of: .signing))
		XCTAssertTrue(steps[..<signing].allSatisfy { if case .unpacking = $0 { true } else { false } })
		XCTAssertTrue(steps[(signing + 1)...].allSatisfy { if case .packing = $0 { true } else { false } })
	}

	func testRefusesWhatIsNotAnIPA() async throws {
		let text = folder.appendingPathComponent("notes.ipa")
		try Data("not a zip".utf8).write(to: text)
		await assertThrows(.corruptArchive("it isn't a ZIP archive")) { _ = try await sign(text, with: signer()) }

		let noPayload = try Fixture.ipa(["Test.app/Info.plist": try Fixture.infoPlist("a.b", executable: "Test")], in: folder)
		await assertThrows(.corruptArchive("there's no Payload folder")) { _ = try await sign(noPayload, with: signer()) }

		let noApp = try Fixture.ipa(["Payload/readme.txt": Data()], in: folder)
		await assertThrows(.corruptArchive("there's no app in its Payload folder")) { _ = try await sign(noApp, with: signer()) }

		var twoApps = try Fixture.appFiles()
		twoApps["Payload/Other.app/Info.plist"] = try Fixture.infoPlist("a.b", executable: "Other")
		await assertThrows(.corruptArchive("its Payload folder holds more than one app")) {
			_ = try await sign(try Fixture.ipa(twoApps, in: folder), with: signer())
		}
		assertCleanedUp()
	}

	func testRefusesEntriesOutsideTheApp() async throws {
		let ipa = folder.appendingPathComponent("evil.ipa")
		let archive = try Archive(url: ipa, accessMode: .create)
		let payload = Data("x".utf8)
		try archive.addEntry(with: "Payload/../../escaped", type: .file, uncompressedSize: Int64(payload.count)) { position, size in
			payload.subdata(in: Int(position)..<Int(position) + size)
		}
		await assertThrows(.corruptArchive("an entry points outside the app (Payload/../../escaped)")) { _ = try await sign(ipa, with: signer()) }
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("escaped").path))
		assertCleanedUp()
	}

	func testRefusesLinksOutsideTheApp() async throws {
		for (name, target) in [("up", "../../../.."), ("absolute", "/private")] {
			let ipa = folder.appendingPathComponent("\(name).ipa")
			let archive = try Archive(url: ipa, accessMode: .create)
			let link = Data(target.utf8)
			try archive.addEntry(with: "Payload/Test.app/out", type: .symlink, uncompressedSize: Int64(link.count)) { position, size in
				link.subdata(in: Int(position)..<Int(position) + size)
			}
			let payload = Data("x".utf8)
			try archive.addEntry(with: "Payload/Test.app/out/escaped", type: .file, uncompressedSize: Int64(payload.count)) { position, size in
				payload.subdata(in: Int(position)..<Int(position) + size)
			}
			await assertThrows(.corruptArchive("a link points outside the app (Payload/Test.app/out)")) { _ = try await sign(ipa, with: signer()) }
			assertCleanedUp()
		}
	}

	func testLeadsInsideFollowsLinks() throws {
		let root = try XCTUnwrap(IPASigner.realPath(folder.path))
		let manager = FileManager.default
		try manager.createDirectory(atPath: root + "/app/Frameworks", withIntermediateDirectories: true)
		try manager.createSymbolicLink(atPath: root + "/app/inside", withDestinationPath: "Frameworks")
		try manager.createSymbolicLink(atPath: root + "/app/outside", withDestinationPath: "../..")
		XCTAssertTrue(IPASigner.leadsInside(root + "/app/inside/new/file", root: root))
		XCTAssertTrue(IPASigner.leadsInside(root + "/app/../app/not-yet", root: root))
		XCTAssertFalse(IPASigner.leadsInside(root + "/app/outside/file", root: root))
		XCTAssertFalse(IPASigner.leadsInside(root + "/app/not-yet/../../..", root: root))
		XCTAssertFalse(IPASigner.leadsInside(root + "/..", root: root))
	}

	func testContainmentIsDecidedByThePathAlone() {
		XCTAssertTrue(IPASigner.isContained("Payload/"))
		XCTAssertTrue(IPASigner.isContained("Payload/Test.app/Info.plist"))
		XCTAssertTrue(IPASigner.isContained("Payload/Test.app/a..b"))
		XCTAssertFalse(IPASigner.isContained("Payload/../x"))
		XCTAssertFalse(IPASigner.isContained("/etc/passwd"))
	}

	func testRefusesBinariesZsignCantUse() async throws {
		let encrypted = try Fixture.ipa(try Fixture.appFiles(main: Fixture.machO(cryptID: 1)), in: folder)
		await assertThrows(.encryptedBinary("Test")) { _ = try await sign(encrypted, with: signer()) }

		let script = try Fixture.ipa(try Fixture.appFiles(main: Data("#!/bin/sh".utf8)), in: folder)
		await assertThrows(.unsupportedBinary("Test")) { _ = try await sign(script, with: signer()) }

		var encryptedFramework = try Fixture.appFiles()
		encryptedFramework["Payload/Test.app/Frameworks/Kit.framework/Kit"] = Fixture.fat([Fixture.machO(cryptID: 1)])
		await assertThrows(.encryptedBinary("Frameworks/Kit.framework/Kit")) {
			_ = try await sign(try Fixture.ipa(encryptedFramework, in: folder), with: signer())
		}

		var missingExtension = try Fixture.appFiles()
		missingExtension["Payload/Test.app/PlugIns/Widget.appex/Widget"] = nil
		await assertThrows(.unsupportedBinary("PlugIns/Widget.appex")) {
			_ = try await sign(try Fixture.ipa(missingExtension, in: folder), with: signer())
		}

		var missingMain = try Fixture.appFiles()
		missingMain["Payload/Test.app/Test"] = nil
		await assertThrows(.unsupportedBinary("Test.app")) {
			_ = try await sign(try Fixture.ipa(missingMain, in: folder), with: signer())
		}
		assertCleanedUp()
	}

	func testChecksFreeSpaceFirst() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let engine = FakeEngine()
		do {
			_ = try await sign(ipa, with: signer(engine, freeSpace: 1000))
			XCTFail("expected outOfSpace")
		} catch SigningError.outOfSpace(let needed, let available) {
			XCTAssertEqual(available, 1000)
			XCTAssertGreaterThan(needed, IPASigner.margin)
		}
		XCTAssertEqual(engine.signedApps, [])
		assertCleanedUp()
	}

	func testPassesEngineErrorsThroughAndCleansUp() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		await assertThrows(.badCertificate) { _ = try await sign(ipa, with: signer(FakeEngine(error: .badCertificate))) }
		await assertThrows(.signingFailed) { _ = try await sign(ipa, with: signer(FakeEngine(error: .signingFailed))) }
		XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("out").path)) ?? [], [])
		assertCleanedUp()
	}

	func testStopsWhenCancelled() async throws {
		let ipa = try Fixture.ipa(try Fixture.appFiles(), in: folder)
		let engine = FakeEngine()
		let signer = signer(engine)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await sign(ipa, with: signer)
		}
		do {
			_ = try await task.value
			XCTFail("expected cancellation")
		} catch is CancellationError {}
		XCTAssertEqual(engine.signedApps, [])
		assertCleanedUp()
	}

	func testErrorsExplainThemselves() {
		XCTAssertEqual(
			SigningError.encryptedBinary("Frameworks/Kit.framework/Kit").description,
			"This IPA is still locked by the App Store, so it can't be signed. Look for a decrypted IPA of the app."
		)
		XCTAssertTrue(SigningError.outOfSpace(needed: 300_000_000, available: 100_000_000).description.contains("300"))
		XCTAssertEqual(
			SigningError.unsignedBinary("Frameworks/libExtra.dylib").description,
			"Part of the app (libExtra.dylib) couldn't be signed, so it wouldn't open. Try again."
		)
	}

	func testErrorsKeepZsignsWordsAndPathsForTheLog() {
		XCTAssertEqual(SigningError.encryptedBinary("Frameworks/Kit.framework/Kit").technical, "Frameworks/Kit.framework/Kit is encrypted by the App Store.")
		XCTAssertEqual(SigningError.unsignedBinary("Frameworks/libExtra.dylib").technical, "zsign signed the app but left Frameworks/libExtra.dylib unsigned.")
		XCTAssertFalse(SigningError.unsupportedCertificate.description.contains("zsign"))
		XCTAssertNil(SigningError.outOfSpace(needed: 1, available: 0).technical)
	}
}

final class ProgressRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var recorded: [SigningProgress] = []

	func append(_ step: SigningProgress) {
		lock.lock()
		recorded.append(step)
		lock.unlock()
	}

	var steps: [SigningProgress] {
		lock.lock()
		defer { lock.unlock() }
		return recorded
	}
}
