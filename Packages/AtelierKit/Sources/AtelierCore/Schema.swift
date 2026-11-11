#if canImport(SwiftData)
import Foundation
import SourceKit
import SwiftData

// What Atelier keeps on the device. Only metadata: imported certificates
// live in CertKit's CertificateStore (protected files, password in the
// keychain, #4), pairing files in the keychain (#9), IPAs in files (#15).
//
// The schema is versioned from the start, so later changes come with a new
// version and a migration stage in AtelierMigrationPlan instead of a wiped
// store.

public typealias SourceRecord = AtelierSchemaV1.SourceRecord
public typealias AppRecord = AtelierSchemaV1.AppRecord
public typealias InstallRecord = AtelierSchemaV1.InstallRecord
public typealias CertificateRecord = AtelierSchemaV1.CertificateRecord

/// The first schema: the sources the user added, the apps they list, the
/// apps Atelier installed, and a certificate record installs don't use.
public enum AtelierSchemaV1: VersionedSchema {
	public static let versionIdentifier = Schema.Version(1, 0, 0)

	public static var models: [any PersistentModel.Type] {
		[SourceRecord.self, AppRecord.self, InstallRecord.self, CertificateRecord.self]
	}

	/// A source the user added, by its JSON URL, as of its last refresh.
	@Model
	public final class SourceRecord {
		/// Normalized by `SourceLink.sourceURL(from:)`.
		@Attribute(.unique) public var url: URL
		public var name: String
		public var addedAt: Date
		/// When Atelier last heard from the server, including "not modified".
		public var lastRefreshedAt: Date?
		public var subtitle: String?
		public var iconURL: URL?
		/// Six hex digits, without `#`.
		public var tintColor: String?
		/// The source's JSON as last downloaded. The records below hold what
		/// lists need; the full app details (versions, screenshots,
		/// permissions, news) come from parsing this with `parsed()`.
		@Attribute(.externalStorage) public var json: Data?
		/// Validators from the last download, sent with the next refresh.
		public var etag: String?
		public var lastModified: String?
		/// Why the last refresh failed. Nil after a refresh that worked. The
		/// source keeps showing what it had.
		public var refreshError: String?
		@Relationship(deleteRule: .cascade, inverse: \AppRecord.source)
		public var apps: [AppRecord] = []

		public init(url: URL, name: String, addedAt: Date = .now) {
			self.url = url
			self.name = name
			self.addedAt = addedAt
		}

		/// The source from its stored JSON, or nil if there's none yet.
		public func parsed() throws -> Source? {
			guard let json else { return nil }
			return try SourceParser.parse(json).source
		}
	}

	/// An app a source lists, as of the source's last refresh.
	@Model
	public final class AppRecord {
		public var bundleID: String
		public var name: String
		/// The latest version's `displayVersion`, whatever iOS it needs.
		public var latestVersion: String
		public var latestVersionDate: Date?
		public var developerName: String?
		public var subtitle: String?
		public var iconURL: URL?
		/// Six hex digits, without `#`.
		public var tintColor: String?
		/// `AppCategory`'s raw value.
		public var category: String = "other"
		/// Where the source lists it, from 0.
		public var position: Int = 0
		public var source: SourceRecord?

		public init(bundleID: String, name: String, latestVersion: String) {
			self.bundleID = bundleID
			self.name = name
			self.latestVersion = latestVersion
		}
	}

	/// An app Atelier installed, and what it was signed with.
	@Model
	public final class InstallRecord {
		@Attribute(.unique) public var bundleID: String
		public var name: String
		public var version: String
		public var installedAt: Date
		/// The source it was installed from, nil for an IPA the user picked.
		/// Kept when the user removes the source, so the app can show
		/// "Source removed" (see `SourceLibrary.hasRemovedSource(_:)`).
		/// Installing from a source (#16) sets it.
		public var sourceURL: URL?
		/// The `StoredCertificate` it was signed with (CertKit's
		/// CertificateStore). Once that certificate is deleted it points at
		/// nothing.
		public var certificateID: UUID?
		public var certificate: CertificateRecord?
		/// The bundle ID its source lists it under, when it's installed
		/// under another: a numbered copy (`InstallTarget`), or an app whose
		/// IPA has another bundle ID than its source lists (#116). Nil when
		/// it's installed as itself.
		public var originalBundleID: String?
		/// The `application-identifier` entitlement it was signed with.
		public var applicationIdentifier: String?
		/// The team of the profile it was signed with.
		public var teamID: String?
		/// What won't work in it, from its entitlements (#7), as of its last
		/// signing.
		public var limits: [String]?
		/// Its privacy permissions and what became of its entitlements, as of
		/// its last signing: a JSON `SignedPermissions`.
		public var permissions: Data?
		/// The install check scheme it was signed with (`InstallCheck`), for
		/// telling whether it's still installed and for opening it (#55).
		/// Nil for installs signed with the install check off or with no
		/// scheme free.
		public var checkScheme: String?
		/// Its `CFBundleVersion`, for telling a new build of the same version
		/// from the one installed (#18).
		public var buildVersion: String?
		/// The update Skip This Version hid, as `UpdateCheck.key(of:)` writes
		/// it; a newer version shows as usual (#18).
		public var skippedVersion: String?

		public init(bundleID: String, name: String, version: String, installedAt: Date = .now) {
			self.bundleID = bundleID
			self.name = name
			self.version = version
			self.installedAt = installedAt
		}
	}

	/// Not written: installs point at CertKit's certificates by
	/// `InstallRecord.certificateID` instead.
	@Model
	public final class CertificateRecord {
		public var name: String
		public var teamID: String
		public var expiresAt: Date
		public var addedAt: Date
		@Relationship(deleteRule: .nullify, inverse: \InstallRecord.certificate)
		public var installs: [InstallRecord] = []

		public init(name: String, teamID: String, expiresAt: Date, addedAt: Date = .now) {
			self.name = name
			self.teamID = teamID
			self.expiresAt = expiresAt
			self.addedAt = addedAt
		}
	}
}

public enum AtelierMigrationPlan: SchemaMigrationPlan {
	public static var schemas: [any VersionedSchema.Type] { [AtelierSchemaV1.self] }
	/// None until there's a second version.
	public static var stages: [MigrationStage] { [] }
}

// Where the store lives (#113). SwiftData's defaults put it in the first App
// Group of the app's entitlements, and Atelier signs itself and every app
// with its profile's entitlements, App Groups included. So Atelier, its
// copies and any app signed with that profile that uses SwiftData's defaults
// opened the same store: a copy of Atelier saw Atelier's sources and Library,
// and wiped its own Open button and certificate there on launch. The store
// is now in the app's own container, and kept out of iCloud too, which a
// profile listing iCloud containers would otherwise turn on. Atelier takes
// the store it had with it, once; its copies start with an empty one, as
// Custom Install… says.
public enum Persistence {
	/// Atelier's store. `adoptingSharedStore`: whether this is Atelier
	/// itself, not a copy, which then takes the store builds before this one
	/// kept in an App Group's container, the first time.
	public static func makeContainer(inMemory: Bool = false, adoptingSharedStore: Bool = false) throws -> ModelContainer {
		let schema = Schema(versionedSchema: AtelierSchemaV1.self)
		if inMemory {
			return try open(schema, ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .none))
		}
		let own = ModelConfiguration(schema: schema, groupContainer: .none, cloudKitDatabase: .none)
		guard adoptingSharedStore else { return try open(schema, own) }
		// Where builds before this one kept it: SwiftData's default.
		let shared = ModelConfiguration(schema: schema).url
		let adopted: Bool
		do {
			adopted = try adopt(storeAt: shared, into: own.url)
		} catch {
			// Copying failed, as when the iPhone is full: Atelier keeps the
			// store it had until a later launch takes it.
			return try openShared(schema, at: shared, else: own)
		}
		guard adopted else { return try open(schema, own) }
		do {
			return try open(schema, own)
		} catch {
			// The copy doesn't open: the same.
			removeStore(at: own.url)
			return try openShared(schema, at: shared, else: own)
		}
	}

	/// A store in a given file, for the tests.
	static func makeContainer(at url: URL) throws -> ModelContainer {
		let schema = Schema(versionedSchema: AtelierSchemaV1.self)
		return try open(schema, ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
	}

	private static func open(_ schema: Schema, _ configuration: ModelConfiguration) throws -> ModelContainer {
		try ModelContainer(for: schema, migrationPlan: AtelierMigrationPlan.self, configurations: [configuration])
	}

	/// The store builds before this one kept, else, when that one doesn't
	/// open either, the app's own: Atelier opens with an empty store rather
	/// than not at all.
	private static func openShared(_ schema: Schema, at shared: URL, else own: ModelConfiguration) throws -> ModelContainer {
		if let container = try? open(schema, ModelConfiguration(schema: schema, url: shared, cloudKitDatabase: .none)) {
			return container
		}
		return try open(schema, own)
	}

	/// Copies the store at `source`, with its write-ahead log and the data it
	/// keeps in files of their own (`SourceRecord.json`), to `destination`,
	/// unless a store is there already or there's none to copy. True when
	/// it copied. The store file goes last: its being there says the store
	/// was taken, so a copy cut short is made again on the next launch.
	@discardableResult
	static func adopt(storeAt source: URL, into destination: URL, fileManager: FileManager = .default) throws -> Bool {
		guard source.standardizedFileURL.path != destination.standardizedFileURL.path,
		      fileManager.fileExists(atPath: source.path),
		      !fileManager.fileExists(atPath: destination.path)
		else { return false }
		let folder = destination.deletingLastPathComponent()
		try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
		// What a copy cut short left.
		removeStore(at: destination, fileManager: fileManager)
		let staging = folder.appending(path: "Store adoption", directoryHint: .isDirectory)
		try? fileManager.removeItem(at: staging)
		try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: staging) }
		let parts = zip(storeParts(of: source), storeParts(of: destination)).filter { fileManager.fileExists(atPath: $0.0.path) }
		for (from, to) in parts {
			try fileManager.copyItem(at: from, to: staging.appending(path: to.lastPathComponent))
		}
		// The log and the data files first, the store file last.
		for (_, to) in parts.reversed() {
			try fileManager.moveItem(at: staging.appending(path: to.lastPathComponent), to: to)
		}
		return true
	}

	/// The store file, then its write-ahead log and the folder of data it
	/// keeps in files of their own, as Core Data names them. The log's index
	/// (`-shm`) isn't needed: SQLite makes it again from the log.
	static func storeParts(of store: URL) -> [URL] {
		let folder = store.deletingLastPathComponent()
		let name = store.lastPathComponent
		return [
			store,
			folder.appending(path: name + "-wal"),
			folder.appending(path: ".\(store.deletingPathExtension().lastPathComponent)_SUPPORT", directoryHint: .isDirectory),
		]
	}

	/// Removes a store and everything that goes with it.
	static func removeStore(at store: URL, fileManager: FileManager = .default) {
		let index = store.deletingLastPathComponent().appending(path: store.lastPathComponent + "-shm")
		for part in storeParts(of: store) + [index] {
			try? fileManager.removeItem(at: part)
		}
	}
}
#endif
