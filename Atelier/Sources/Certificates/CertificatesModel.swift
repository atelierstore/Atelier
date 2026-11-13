import AppleIDKit
import CertKit
import CryptoKit
import Foundation
import Observation
import AtelierCore
import SigningKit
import SwiftData
import UniformTypeIdentifiers

/// The user's signing certificates (#4): what's imported, the Apple IDs
/// signed in with (#49), which one is the default, the import or sign-in
/// in progress, and whether Apple revoked them or they're about to expire
/// (#5).
///
/// One instance, shared by the app and its background refresh, so a check
/// in the background isn't overwritten by a stale copy of the store.
@MainActor
@Observable
final class CertificatesModel {
	static let shared = CertificatesModel()

	/// An import being put together in the import sheet.
	struct Draft {
		var files = CertificateFiles()
		var password = ""
		/// Optional; empty keeps the certificate's own name.
		var name = ""
		var error: String?
	}

	private(set) var certificates: [StoredCertificate] = []
	/// Apple IDs signed in with (#49), oldest first.
	private(set) var appleIDs: [StoredAppleID] = []
	/// An imported pair's, or an Apple ID's.
	private(set) var defaultID: UUID?
	/// Set when the store itself can't be opened.
	private(set) var storeError: String?
	/// Non-nil while the import sheet is showing.
	var draft: Draft?
	/// Non-nil while the Sign In with Apple ID sheet is showing (#49).
	var signIn: AppleIDSignIn?
	/// Certificates whose revocation check is running.
	private(set) var checking: Set<UUID> = []
	/// Deleted certificates as they were then, so the apps signed with one
	/// still say it was revoked or when it runs out, and can be re-signed
	/// (#20), until it's imported again (#126).
	private(set) var retired: [UUID: RetiredCertificate] = CertificatesModel.loadRetired()
	/// The certificate just imported, until the import sheet has closed and
	/// RootView has offered it for re-signing (#20).
	var justImported: UUID?
	/// Certificates tested as revoked or expired from the hidden test
	/// actions (#20), until End Test.
	private(set) var tests: [UUID: CertificateTest] = CertificatesModel.loadTests()

	private let store: CertificateStore?
	@ObservationIgnored private let checker = RevocationChecker()

	/// How long a check stands before opening Atelier checks again. Apple's
	/// answers are cached for about 12 hours, so asking more often finds
	/// nothing new.
	static let recheckInterval: TimeInterval = 60 * 60

	private init() {
		do {
			let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
			store = try CertificateStore(
				directory: support.appendingPathComponent("Certificates", isDirectory: true),
				secrets: KeychainCertificateSecrets(),
				appleIDPasswords: KeychainCertificateSecrets.appleIDPasswords()
			)
		} catch {
			store = nil
			storeError = "Atelier couldn't open its certificate storage: \(error.localizedDescription)"
		}
		refresh()
	}

	/// Gives the certificates' files and passwords the current
	/// `SecretProtection` (#72).
	func reprotect() {
		do {
			try store?.reprotect()
		} catch {
			storeError = "Atelier couldn't change how certificates are protected: \(error.localizedDescription)"
		}
	}

	/// The imported pair in use; nil when an Apple ID is.
	var defaultCertificate: StoredCertificate? {
		certificates.first { $0.id == defaultID }
	}

	/// The Apple ID in use (#49); nil when an imported pair is.
	var defaultAppleID: StoredAppleID? {
		appleIDs.first { $0.id == defaultID }
	}

	/// What Settings › Installs says is in use: the pair's name, or the
	/// Apple ID.
	var inUseName: String? {
		defaultCertificate?.displayName ?? defaultAppleID?.displayName
	}

	/// The default certificate as signing needs it (#6), or nil if there's none.
	func defaultSigningIdentity() throws -> SigningIdentity? {
		guard let store, let certificate = store.defaultCertificate else { return nil }
		return try SigningIdentity(certificate, in: store)
	}

	/// The certificate `id` as signing needs it, for signing an app again
	/// with a certificate the user picked (#17); nil if it's gone.
	func signingIdentity(for id: UUID) throws -> SigningIdentity? {
		guard let store, let certificate = store.certificates.first(where: { $0.id == id }) else { return nil }
		return try SigningIdentity(certificate, in: store)
	}

	/// What the picker accepts: certificates, profiles and ZIPs.
	static var contentTypes: [UTType] {
		DocumentPicker.types(
			["com.rsa.pkcs-12", "com.atelier.app.mobileprovision", "public.zip-archive"],
			extensions: ["p12", "pfx", "mobileprovision", "zip"]
		)
	}

	func beginImport() {
		if draft == nil { draft = Draft() }
	}

	/// Adds picked or shared files to the import, opening the sheet if needed.
	func add(_ urls: [URL]) {
		var draft = self.draft ?? Draft()
		draft.error = nil
		for url in urls {
			let scoped = url.startAccessingSecurityScopedResource()
			defer {
				if scoped { url.stopAccessingSecurityScopedResource() }
				// Files shared to Atelier are copied into Documents/Inbox, and
				// picked ones into the temporary folder; don't keep them there (#22).
				if url.pathComponents.suffix(2).first == "Inbox" || Self.isTemporaryCopy(url) { try? FileManager.default.removeItem(at: url) }
			}
			do {
				try draft.files.add(name: url.lastPathComponent, data: Data(contentsOf: url))
			} catch let error as CertificateImportError {
				draft.error = error.description
			} catch {
				draft.error = "\(url.lastPathComponent) can't be read: \(error.localizedDescription)"
			}
		}
		self.draft = draft
	}

	/// Whether `url` is in Atelier's temporary folder, where the document
	/// picker puts its copies.
	private static func isTemporaryCopy(_ url: URL) -> Bool {
		let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
		return url.resolvingSymlinksInPath().path.hasPrefix(temporary + "/")
	}

	/// Checks the draft and saves it. Returns whether it was imported; if not,
	/// the draft's error says why.
	@discardableResult
	func finishImport() -> Bool {
		guard var draft else { return false }
		guard let store else {
			draft.error = storeError
			self.draft = draft
			return false
		}
		do {
			let validated = try CertificateImporter.validate(draft.files, password: draft.password)
			let stored = try save(validated, files: draft.files, password: draft.password, name: draft.name, in: store)
			justImported = stored.id
			self.draft = nil
			refresh()
			Task {
				await CertificateNotifications.requestAuthorization()
				await check(stored.id)
				await CertificateNotifications.sync(certificates)
			}
			return true
		} catch let error as CertificateImportError {
			draft.error = error.description
		} catch {
			draft.error = error.localizedDescription
		}
		self.draft = draft
		return false
	}

	/// Saves a checked pair. One deleted earlier comes back under its ID, so
	/// the apps signed with it find it again (#126).
	private func save(_ validated: ValidatedCertificate, files: CertificateFiles, password: String, name: String?, in store: CertificateStore) throws -> StoredCertificate {
		let deleted = retired.first { $0.value.isPair(validated.certificate, validated.profile) }
		let stored = try store.add(validated, files: files, password: password, name: name, id: deleted?.key)
		if let deleted, deleted.key == stored.id {
			if let confirmed = deleted.value.deviceConfirmedAt { try? store.setDeviceConfirmed(for: stored.id, at: confirmed) }
			retired[stored.id] = nil
			saveRetired()
		}
		return stored
	}

	// MARK: The certificate a copy of Atelier came with (#113)

	/// The SHA-256 of the last certificate file this copy imported, or
	/// tried to: each is imported once, so a certificate deleted here stays
	/// deleted until the copy is installed again with one.
	static let packagedImportKey = "packagedCertificateImported"

	/// Imports the certificate this copy of Atelier came with (#113): the
	/// one it's signed with, which Custom Install… put in its app with its
	/// password (#155), so the copy can install apps and update itself from
	/// its first launch, however it's opened. Only the certificate the profile
	/// it was installed with lists. Notes the UDID that came with it as
	/// this iPhone's, when that profile lists it too, for the checks that
	/// each profile lists this iPhone. Called once the welcome has decided
	/// to come up, so it still does, with Get Ready's certificate done.
	func importPackagedCertificate() {
		let file = Bundle.main.bundleURL.appending(path: PackagedCertificate.fileName)
		guard let data = try? Data(contentsOf: file) else { return }
		let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		let defaults = UserDefaults.standard
		guard defaults.string(forKey: Self.packagedImportKey) != digest, let store else { return }
		do {
			let packaged = try PackagedCertificate(file: data)
			let installedProfile = SelfUpdate.shared.installedProfile
			let validated = try packaged.validated(installedWith: installedProfile)
			if let udid = packaged.deviceUDID(installedWith: installedProfile) { RouteASetup.shared.noteInstallerUDID(udid) }
			let stored = try save(validated, files: packaged.files, password: packaged.password, name: packaged.name, in: store)
			refresh()
			Task {
				await check(stored.id)
				await CertificateNotifications.sync(certificates)
			}
		} catch CertificateImportError.alreadyImported(_) {
			// Imported already, by hand.
		} catch CertificateImportError.storageFailed(_) {
			// Saving it failed: tried again on the next launch.
			return
		} catch {
			// It can't be imported, and the file stays as it is until the
			// copy is installed again, so it isn't tried again.
		}
		defaults.set(digest, forKey: Self.packagedImportKey)
	}

	func delete(_ id: UUID) {
		// Its apps still need re-signing once it's gone (#20), and get it
		// back if it's imported again (#126).
		if let certificate = certificates.first(where: { $0.id == id }) {
			retired[id] = RetiredCertificate(certificate)
			saveRetired()
		}
		do {
			try store?.delete(id)
		} catch {
			storeError = "Couldn't delete the certificate: \(error.localizedDescription)"
		}
		if tests.removeValue(forKey: id) != nil { saveTests() }
		refresh()
		Task { await CertificateNotifications.sync(certificates) }
	}

	/// Puts an imported pair or an Apple ID in use for installs.
	func makeDefault(_ id: UUID) {
		do {
			try store?.setDefault(id)
		} catch {
			let name = certificates.first { $0.id == id }?.displayName ?? appleIDs.first { $0.id == id }?.displayName ?? "the certificate"
			storeError = "Couldn't switch to “\(name)”: \(error.localizedDescription)"
		}
		refresh()
	}

	/// Points the apps still signed with a deleted certificate at the same
	/// one imported again (#126): one deleted or imported again before
	/// Atelier gave a deleted pair its ID back on import. On launch and
	/// whenever a certificate is imported or deleted.
	func relinkInstalls(in context: ModelContext) {
		guard let store, !retired.isEmpty else { return }
		let current = store.certificates
		let ids = Set(current.map(\.id))
		InstalledApps.replaceCertificates(in: context) { install in
			guard let id = install.certificateID, !ids.contains(id), let deleted = retired[id] else { return nil }
			return deleted.reimported(among: current, signedFor: install.applicationIdentifier, at: install.installedAt)?.id
		}
	}

	/// Names a certificate; an empty name goes back to its own.
	func rename(_ id: UUID, to name: String) {
		do {
			try store?.setName(name, for: id)
		} catch {
			storeError = "Couldn't rename the certificate: \(error.localizedDescription)"
		}
		refresh()
		Task { await CertificateNotifications.sync(certificates) }
	}

	// MARK: Revocation and expiry (#5)

	/// Checks every certificate not checked within `recheckInterval` (all of
	/// them with `force`), Apple IDs' too, then brings the notifications up
	/// to date: on launch, on returning to Atelier and in the background
	/// refresh.
	func refreshStatus(force: Bool = false) async {
		// Tests run only while their switch is on, even if Atelier was
		// ended while it was turned off and they were ending (#20).
		if !UserDefaults.standard.bool(forKey: TestActions.certificatesKey) { await endAllTests() }
		for certificate in certificates {
			if !force, let last = certificate.revocation?.attemptedAt, Date.now.timeIntervalSince(last) < Self.recheckInterval { continue }
			await check(certificate.id)
		}
		for account in appleIDs {
			if !force, let last = account.revocation?.attemptedAt, Date.now.timeIntervalSince(last) < Self.recheckInterval { continue }
			await check(account.id)
		}
		// iOS only asks once; later calls return the user's answer.
		if !certificates.isEmpty { await CertificateNotifications.requestAuthorization() }
		await CertificateNotifications.sync(certificates)
	}

	/// Asks Apple whether the certificate is revoked and keeps the answer.
	/// A failed check keeps the last answer and says why it failed.
	func check(_ id: UUID) async {
		if appleIDs.contains(where: { $0.id == id }) { return await checkAppleID(id) }
		guard let store, !checking.contains(id), let certificate = store.certificates.first(where: { $0.id == id }) else { return }
		checking.insert(id)
		defer { checking.remove(id) }
		let state: RevocationState
		do {
			let status = try await revocationStatus(of: certificate)
			state = .checked(status, at: .now)
		} catch is CancellationError {
			return
		} catch {
			let message = (error as? RevocationCheckError)?.description ?? error.localizedDescription
			state = (certificate.revocation ?? RevocationState(attemptedAt: .now)).failed(message, at: .now)
		}
		try? store.setRevocation(state, for: id)
		refresh()
	}

	/// Records that an app signed with a certificate installed on this
	/// iPhone, so its profile's device warning goes away (#45).
	func deviceConfirmed(by id: UUID) {
		guard let store, store.certificates.first(where: { $0.id == id })?.deviceConfirmedAt == nil else { return }
		try? store.setDeviceConfirmed(for: id)
		refresh()
	}

	/// What an app signed with a certificate should warn about, if anything.
	func attention(for id: UUID?) -> CertificateAttention? {
		guard let id, let certificate = certificates.first(where: { $0.id == id }) else { return nil }
		return CertificateAttention(certificate)
	}

	/// A certificate or Apple ID that's revoked, expired or about to
	/// expire, by the name Certificates lists it under.
	struct Attention: Equatable {
		var name: String
		var health: CertificateHealth
	}

	/// Certificates that are revoked, expired or about to expire, Apple
	/// IDs' included: what the Settings tab's badge counts. Worst first, as
	/// Settings › Installs › Certificates names the first (13 Nov 2026):
	/// revoked, then expired, then the one that runs out soonest; between
	/// equals, the one in use, then as Certificates lists them.
	var needingAttention: [Attention] {
		// As Certificates lists them: Apple IDs, then imported pairs.
		let listed = appleIDs.map { (inUse: $0.id == defaultID, item: Attention(name: $0.displayName, health: CertificateHealth($0))) }
			+ certificates.map { (inUse: $0.id == defaultID, item: Attention(name: $0.displayName, health: CertificateHealth($0))) }
		func order(_ index: Int) -> (Int, Int, Int, Int) {
			let (inUse, item) = listed[index]
			let (rank, days) = switch item.health {
			case .revoked: (0, 0)
			case .expired: (1, 0)
			case .expiring(let days): (2, days)
			case .valid: (3, 0)
			}
			return (rank, days, inUse ? 0 : 1, index)
		}
		return listed.indices
			.filter { listed[$0].item.health != .valid }
			.sorted { order($0) < order($1) }
			.map { listed[$0].item }
	}

	private func refresh() {
		certificates = (store?.certificates ?? []).map { applyingTest($0) }
		appleIDs = store?.appleIDs ?? []
		defaultID = store?.defaultID
	}

	// MARK: Apple IDs (#49)

	/// Opens the Sign In with Apple ID sheet, or brings up the sign-in
	/// Atelier is making by itself with the installer's (#152).
	func beginSignIn() {
		if let signIn {
			signIn.reveal()
		} else {
			signIn = AppleIDSignIn(certificates: self)
		}
	}

	/// New Certificate (12 Nov 2026), on an Apple ID's page and from
	/// Re-sign on one of its apps, once Apple revoked its certificate or
	/// that ended: the Sign In sheet for that Apple ID, signing in at once
	/// with the password in the Keychain, as signing out and in again
	/// would. Apple makes a new certificate, and the Apple ID's apps are
	/// signed again with it (`ProfileRenewals.renewAfterSignIn`), keeping
	/// their App IDs. Without a kept password, or before the setup is
	/// done, the sheet waits for the user. One already open comes up.
	func beginNewCertificate(for account: StoredAppleID) {
		if let signIn { return signIn.reveal() }
		let password = (try? appleIDPassword(for: account.id)) ?? nil
		let signIn = AppleIDSignIn(certificates: self, newCertificateFor: account, password: password ?? "")
		self.signIn = signIn
		if RouteASetup.shared.isSetUp { signIn.signIn() }
	}

	/// Closes it, stopping a sign-in that's running.
	func endSignIn() {
		signIn?.cancel()
		signIn = nil
	}

	/// The one kept for the Apple ID `email` in the team `teamID`.
	func appleID(email: String, teamID: String) -> StoredAppleID? {
		appleIDs.first { $0.isSame(email: email, teamID: teamID) }
	}

	/// Where the certificate's key is kept for the Apple ID `id`, before
	/// it's saved.
	func keysFolder(forAppleID id: UUID) throws -> URL {
		guard let store else { throw CertificateImportError.storageFailed(storeError ?? "") }
		return try store.keysFolder(for: id)
	}

	// MARK: The installer's certificate (#152)

	/// Moves the certificate the iPhone-only installer left in Atelier's
	/// Caches, with its key and its sign-in, into the certificate storage
	/// and the Keychain, as Atelier comes to the front: an Apple ID of its
	/// team uses it once it signs in, rather than having Apple make another.
	/// The machine Apple saw the installer sign in as goes where Atelier's
	/// sign-in through the same server finds it, unless Atelier already has
	/// one there.
	func keepInstallerCertificate() {
		guard
			let store,
			let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
		else { return }
		let url = InstallerCertificate.handoffURL(in: caches)
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		do {
			guard let kept = try store.keepInstallerCertificate(from: url) else { return }
			let made = [kept.machineName, kept.serialNumber].compactMap { $0 }.joined(separator: " ")
			let with = kept.signIn == nil ? "" : ", with its sign-in"
			AppleIDLog.note("Installer: kept the certificate it left for team \(kept.teamID)\(made.isEmpty ? "" : ", \(made)")\(with)")
			if let signIn = kept.signIn { keepAnisetteState(of: signIn) }
		} catch {
			AppleIDLog.note("Installer: couldn't keep the certificate it left: \(error)")
		}
	}

	private func keepAnisetteState(of signIn: InstallerCertificate.SignIn) {
		guard let state = signIn.anisetteState, let url = signIn.anisetteServer.flatMap(AnisetteList.serverURL) else { return }
		let server = AnisetteList.Server(url: url, name: url.host ?? url.absoluteString)
		do {
			let file = try server.stateFile(in: AppleIDSignIn.storage())
			guard !FileManager.default.fileExists(atPath: file.path) else {
				AppleIDLog.note("Installer: keeping Atelier's own machine for \(server.host)")
				return
			}
			try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try state.write(to: file, options: .atomic)
			AppleIDLog.note("Installer: its machine for \(server.host) is Atelier's now")
		} catch {
			AppleIDLog.note("Installer: couldn't keep its machine for \(server.host): \(error)")
		}
	}

	/// Signs in by itself with the Apple ID the installer used, as Atelier
	/// first opens after it (#152), out of sight until it has something to
	/// show. Tried once: the sheet then has it, filled in.
	func signInAsInstaller() {
		guard signIn == nil, let installer = store?.installerCertificate, installer.signIn != nil else { return }
		let signIn = AppleIDSignIn(certificates: self, installer: installer)
		self.signIn = signIn
		signIn.signIn()
	}

	/// Once Atelier has tried the installer's sign-in.
	func forgetInstallerSignIn() {
		store?.forgetInstallerSignIn()
	}

	/// The certificate the installer left, until an Apple ID of its team
	/// signs in.
	var installerCertificate: InstallerCertificate? { store?.installerCertificate }

	func forgetInstallerCertificate() {
		store?.forgetInstallerCertificate()
	}

	/// Keeps an Apple ID once signed in, in use if nothing else is, and
	/// checks its certificate. Returns whether it's in use.
	func saveAppleID(_ account: StoredAppleID, p12: Data, p12Password: String, password: String) throws -> Bool {
		guard let store else { throw CertificateImportError.storageFailed(storeError ?? "") }
		try store.saveAppleID(account, p12: p12, p12Password: p12Password, password: password)
		refresh()
		Task { await check(account.id) }
		return store.defaultID == account.id
	}

	/// Signs out of an Apple ID: its password, and its certificate's key
	/// and .p12, leave this iPhone. Apple keeps the certificate, so apps
	/// signed with it open until their profiles run out.
	func signOut(_ id: UUID) {
		AppleIDAccess.shared.forget(id)
		do {
			try store?.deleteAppleID(id)
		} catch {
			let name = appleIDs.first { $0.id == id }?.displayName ?? "the Apple ID"
			storeError = "Couldn't sign out of \(name): \(error.localizedDescription)"
		}
		refresh()
	}

	/// The Apple ID `id`, when it's one (#49).
	func appleID(_ id: UUID?) -> StoredAppleID? {
		guard let id else { return nil }
		return appleIDs.first { $0.id == id }
	}

	/// The Apple ID's certificate as signing needs it, with `profile`, the
	/// one Apple just gave the app (#49); nil if it was signed out of.
	func appleIDSigningIdentity(for id: UUID, profile: URL) throws -> SigningIdentity? {
		guard let store, store.appleIDs.contains(where: { $0.id == id }), let password = try store.password(for: id) else { return nil }
		return SigningIdentity(p12: store.p12URL(for: id), profile: profile, password: password)
	}

	/// The Apple ID's own password, for signing in again (#49).
	func appleIDPassword(for id: UUID) throws -> String? {
		try store?.appleIDPassword(for: id)
	}

	/// Keeps what changed about an Apple ID: an app's new profile, or what
	/// Apple and this iPhone said about its limits (#49). Nothing happens
	/// if it was signed out of meanwhile.
	func updateAppleID(_ id: UUID, _ change: (inout StoredAppleID) -> Void) {
		do {
			try store?.updateAppleID(id, change)
		} catch {
			AppleIDLog.note("couldn't keep what changed about an Apple ID: \(error.localizedDescription)")
		}
		refresh()
	}

	/// An app Atelier deleted from this iPhone, or one that was gone when it
	/// was deleted from the Library (#49): it holds none of a free Apple
	/// ID's 3 places any more, so the Apple ID's page stops listing it then
	/// rather than at the next check (4 Nov 2026).
	func appLeft(_ bundleID: String) {
		for account in appleIDs where account.limits?.apps?.apps.contains(where: { $0.bundleID == bundleID }) == true {
			updateAppleID(account.id) { stored in
				guard let apps = stored.limits?.apps else { return }
				stored.limits?.apps = AppleIDLimits.Apps(checkedAt: apps.checkedAt, apps: apps.apps.filter { $0.bundleID != bundleID })
			}
		}
	}

	/// `check` for an Apple ID's certificate.
	private func checkAppleID(_ id: UUID) async {
		guard let store, !checking.contains(id), let account = store.appleIDs.first(where: { $0.id == id }) else { return }
		checking.insert(id)
		defer { checking.remove(id) }
		let state: RevocationState
		do {
			state = .checked(try await checker.check(account.certificate), at: .now)
		} catch is CancellationError {
			return
		} catch {
			let message = (error as? RevocationCheckError)?.description ?? error.localizedDescription
			state = (account.revocation ?? RevocationState(attemptedAt: .now)).failed(message, at: .now)
		}
		try? store.setAppleIDRevocation(state, for: id)
		refresh()
	}

	// MARK: Re-signing (#20)

	/// The certificate apps whose certificate died are re-signed with: the
	/// one in use while nothing is wrong with it, otherwise the one with the
	/// most time left of those nothing is wrong with. Nil when there's none,
	/// so one has to be imported first.
	var resignTarget: StoredCertificate? {
		if let current = defaultCertificate, Self.canResign(with: current) { return current }
		return certificates.filter(Self.canResign(with:)).max { $0.expiresAt < $1.expiresAt }
	}

	/// Not revoked, expired or expiring within 14 days, and apps signed with
	/// it install on this iPhone as far as Atelier can tell.
	static func canResign(with certificate: StoredCertificate) -> Bool {
		CertificateAttention(certificate) == nil && canSign(with: certificate)
	}

	/// Not revoked or expired, and apps signed with it install on this
	/// iPhone as far as Atelier can tell: what installing with it takes,
	/// where re-signing leaves out one that ends within 14 days too.
	static func canSign(with certificate: StoredCertificate) -> Bool {
		switch CertificateAttention(certificate) {
		case .revoked?, .expired?: return false
		case .expiring?, nil: break
		}
		return !certificate.notes(deviceUDID: RouteASetup.shared.udid).contains { $0.kind == .appStoreProfile || $0.kind == .deviceNotInProfile }
	}

	/// An Apple ID's certificate that isn't revoked or expired (#49).
	static func canSign(with account: StoredAppleID) -> Bool {
		switch CertificateAttention(account) {
		case .revoked?, .expired?: false
		case .expiring?, nil: true
		}
	}

	/// What a new app can install with instead of the free Apple ID
	/// `account`, when that would take a new App ID (#49), as Settings
	/// lists them, the one in use first: the other free Apple IDs with an
	/// App ID left this week as they last said, each of which takes one of
	/// its own 10, paid Apple IDs, and the certificates that can sign on
	/// this iPhone (4 Nov 2026).
	func choices(insteadOf account: StoredAppleID) -> [SigningChoice] {
		let others = appleIDs.filter { other in
			guard other.id != account.id, Self.canSign(with: other) else { return false }
			return !other.isFree || (other.limits?.appIDs?.left() ?? 1) > 0
		}
		let all = others.map(SigningChoice.appleID) + certificates.filter { Self.canSign(with: $0) }.map(SigningChoice.certificate)
		return all.filter { $0.id == defaultID } + all.filter { $0.id != defaultID }
	}

	/// Puts `target` in use when re-signing with it, so what's installed
	/// next is signed with it too: it's only another one than the one in use
	/// when that one is dead or dying.
	func useForResigning(_ target: StoredCertificate) {
		guard defaultID != target.id else { return }
		makeDefault(target.id)
	}

	// MARK: Test actions (#20)

	/// Starts testing the certificate `id` as revoked or expired. As for a
	/// real one, a revocation is found by a check, and either is announced.
	func startTest(_ kind: CertificateTest.Kind, on id: UUID) async {
		guard tests[id] == nil else { return }
		tests[id] = CertificateTest(kind: kind, since: .now)
		saveTests()
		refresh()
		if kind == .revoked { await check(id) }
		await CertificateNotifications.sync(certificates)
	}

	/// Ends the certificate's test: Apple is asked again, and the end date is
	/// its own again.
	func endTest(on id: UUID) async {
		guard let test = tests.removeValue(forKey: id) else { return }
		saveTests()
		if test.kind == .revoked {
			// Drops the test's answer, so a check that fails doesn't keep it.
			try? store?.setRevocation(RevocationState(attemptedAt: .distantPast), for: id)
		}
		refresh()
		if test.kind == .revoked { await check(id) }
		// So that a real revocation or expiry is announced later.
		CertificateNotifications.forgetShown(for: id)
		await CertificateNotifications.sync(certificates)
	}

	/// Ends every certificate's test, once certificate tests are turned off.
	func endAllTests() async {
		for id in Array(tests.keys) { await endTest(on: id) }
	}

	/// The revocation check's answer: Apple's, or with Test Revoked, revoked
	/// since the test started.
	private func revocationStatus(of certificate: StoredCertificate) async throws -> RevocationStatus {
		if let test = tests[certificate.id], test.kind == .revoked { return .revoked(at: test.since) }
		return try await checker.check(certificate.certificate)
	}

	/// With Test Expired, the certificate ran out when the test started.
	private func applyingTest(_ certificate: StoredCertificate) -> StoredCertificate {
		guard let test = tests[certificate.id], test.kind == .expired else { return certificate }
		var tested = certificate
		tested.certificate.notAfter = min(certificate.certificate.notAfter, test.since)
		return tested
	}

	private static let testsKey = "certificateTests"

	private static func loadTests() -> [UUID: CertificateTest] {
		guard let data = UserDefaults.standard.data(forKey: testsKey),
		      let saved = try? JSONDecoder().decode([String: CertificateTest].self, from: data)
		else { return [:] }
		return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
	}

	private func saveTests() {
		let saved = Dictionary(uniqueKeysWithValues: tests.map { ($0.key.uuidString, $0.value) })
		if let data = try? JSONEncoder().encode(saved) {
			UserDefaults.standard.set(data, forKey: Self.testsKey)
		}
	}

	private static let retiredKey = "retiredCertificates"

	private static func loadRetired() -> [UUID: RetiredCertificate] {
		guard let data = UserDefaults.standard.data(forKey: retiredKey),
		      let saved = try? JSONDecoder().decode([String: RetiredCertificate].self, from: data)
		else { return [:] }
		return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
	}

	private func saveRetired() {
		let saved = Dictionary(uniqueKeysWithValues: retired.map { ($0.key.uuidString, $0.value) })
		if let data = try? JSONEncoder().encode(saved) {
			UserDefaults.standard.set(data, forKey: Self.retiredKey)
		}
	}
}
