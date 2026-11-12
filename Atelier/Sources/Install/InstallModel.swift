import CertKit
import DownloadKit
import Foundation
import InstallKit
import Observation
import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import UIKit
import UserNotifications

/// Installs apps through `InstallPipeline` (#16): checks, download, signing
/// with the default certificate (#6) and install through the route
/// `RouteSelector` picks (#11): route A (#9), the pairing file and
/// LocalDevVPN, when this iPhone is paired, or route B (#10), Atelier's
/// loopback server, its own manifest endpoint and the iOS install alert.
/// The app is one tapped Install on in a source, which downloads it first
/// (#15), one the user picked, or one downloaded from a pasted URL; a
/// download is deleted once the install is confirmed. Installs run one at
/// a time; the rest wait in a queue. Every attempt goes into the install
/// history.
///
/// One model for the whole app, so the install bar (`InstallBar`) shows on
/// every tab.
@MainActor
@Observable
final class InstallModel {
	/// Shared with background update runs (#72), which start without a screen.
	static let shared = InstallModel()

	/// What to install.
	fileprivate enum Input {
		/// Picked in the Files picker, so it's copied in first.
		case picked(URL)
		/// A finished download, signed where it is.
		case download(Download, DownloadManager)
		/// A version from a source, downloaded once the checks pass.
		case source(SourceDownload)
		/// The kept data of the app with this bundle ID, put back into it
		/// (#96): Put Back in the Library. Not an install, but it runs in
		/// the queue, so none runs meanwhile, and shows in the install bar.
		case putBack(String)
		/// Disable in the Library (#49): the data of the app with this bundle
		/// ID is copied aside, then the app deleted. Not an install either,
		/// but it runs in the queue, as Put Back does.
		case disable(String)
		/// Atelier itself as it runs, packed to be signed again (#24): Sign
		/// Again With and Re-sign of Atelier.
		case ownApp
	}

	/// One install waiting in the queue or running.
	struct Job: Identifiable {
		var id: String
		/// What the queue shows.
		var title: String
		/// The app's icon, when it came from a source.
		var iconURL: URL?
		/// The app and source an install from a source is for, so app
		/// details can show it on the Install button.
		var app: AppKey?
		/// The app itself, or a numbered copy of it (#8).
		var target: InstallTarget = .original
		/// The name it's signed with: a copy's, or the one chosen for the app
		/// itself in Custom Install… (#155); nil keeps its IPA's.
		var displayName: String?
		/// What the user chose for it in Custom Install's sheet, a copy
		/// (#113) or any app (#155), or what the app it takes the place of
		/// has, once it's queued (#49); nil for what it was installed with,
		/// which its updates and re-signs keep.
		var copyChoice: CopyChoice?
		/// The link its IPA was downloaded from: noted for the app once it's
		/// installed, so Custom Install… and Re-sign can download it again
		/// (#113).
		var ipaLink: URL?
		/// Its download is one Atelier started to copy an app or sign it
		/// again from the link its IPA came from (#113), so it's deleted also
		/// when the install doesn't go ahead, rather than left in Downloads.
		var removesDownload = false
		/// The certificate to sign with, picked in Custom Install… (#17,
		/// #155); nil for the default certificate.
		var certificateID: UUID?
		/// The user picked `certificateID`, as in Custom Install…, so the
		/// check before the install doesn't sign with the one the app on
		/// this iPhone was installed with instead (#99).
		var certificatePicked = false
		/// Picked in the question before a new App ID, from its list (#49):
		/// another free Apple ID, whose row said it takes one of its own,
		/// so the install doesn't ask again.
		var newAppIDAsked = false
		/// The source app it's signed as, when its Info.plist doesn't say:
		/// Atelier's own, as it signs itself as it runs (#24).
		var originalBundleID: String?
		/// An update of an installed app (#18), for what the system's bar
		/// and the notification say (#72).
		var isUpdate = false
		/// Started by a background update run, not by the user (#72): it
		/// only installs directly, since nobody is there for iOS's alert.
		var automatic = false
		/// Left on `installWhenDownloaded` from before Atelier was last
		/// opened: an install iOS ended Atelier during, or one whose download
		/// outlasted it. It waits while the user's own installs are under
		/// way, and steps aside for them (`stepAside`).
		var carriedOver = false
		/// An installed app signed again because its certificate died (#20),
		/// for what the system's bar and the notification say.
		var isResign = false
		/// The app it replaces is deleted first, right before the install,
		/// as iOS won't replace it with one signed for another App ID (#20).
		/// Only Direct installs can, so it installs directly.
		var deletesFirst = false
		/// With `deletesFirst`, whether the app's data is copied aside first
		/// and put back into the new install (#96). Delete and Re-sign after
		/// a copy that failed goes without.
		var keepsData = true
		/// With `deletesFirst`, the app is deleted although installd lists
		/// none under its bundle ID, which iOS's refusal showed is there,
		/// such as an offloaded one (#99).
		var deletesUnlisted = false
		/// The installed app this install takes the place of, which can have
		/// another bundle ID than the one it installs as: signed with an
		/// Apple ID, or no longer with one (#49). With `deletesFirst`, it's
		/// the one deleted, its data going into the new install; either
		/// way, its Library entry goes once the install is done.
		var replacesBundleID: String?
		/// Atelier's own install (#24): it runs after every other install,
		/// also those queued after it, as it closes Atelier, and keeps
		/// Atelier's bundle ID and the App ID it was installed with.
		var isSelf = false
		/// What Atelier's own install does, for what it asks and says.
		var selfKind = PendingSelfInstall.Kind.update
		/// The version Atelier's own install installs: as its source shows
		/// it, and as its Info.plist says it.
		var selfVersion: (display: String, version: String, build: String?)?
		/// The user said to go ahead with Atelier's own install, or it
		/// needs no asking, as when it's tried again.
		var selfConfirmed = false
		/// Signs Atelier with the profile it was installed with, which lists
		/// the certificate, rather than the certificate's own, which is for
		/// another App ID (#24).
		var usesInstalledProfile = false
		/// The app signed for an install iOS refused, sent again instead of
		/// signed again once the app in its way is deleted (#99).
		var signedApp: SignedApp?
		/// Enable (#49): the app Disable took off this iPhone, `replacesBundleID`,
		/// is installed again, and the data kept for it put back. Only Direct
		/// installs can.
		var restoresData = false
		/// What runs once this one is done, unless it failed: Make Room's
		/// install, after its Disable (#49).
		var afterwards: [Job] = []
		fileprivate let input: Input

		/// Put Back in the Library rather than an install (#96).
		var isPutBack: Bool {
			if case .putBack = input { return true }
			return false
		}

		/// Disable in the Library rather than an install (#49).
		var isDisable: Bool {
			if case .disable = input { return true }
			return false
		}

		/// Put Back or Disable: they run in the queue and show in the
		/// install bar, but install nothing, so they stay out of the
		/// system's bar and the install history.
		var isChore: Bool { isPutBack || isDisable }

		/// The copy of a picked IPA it installs, or that what runs after it
		/// installs: Make Room's install, after its Disable (#49).
		var pickedFile: URL? {
			if case .picked(let file) = input { return file }
			return afterwards.lazy.compactMap(\.pickedFile).first
		}

		/// An IPA file, or one downloaded from a link, which can install as a
		/// copy instead of over the app it is (#113).
		var isIPA: Bool {
			switch input {
			case .picked: true
			case .download(let download, _): download.isFromURL
			case .source, .putBack, .disable, .ownApp: false
			}
		}
		fileprivate let certificates: CertificatesModel
		fileprivate let context: ModelContext

		/// The version an install from a source installs, keyed as Skip This
		/// Version keys it, so Version History tells its rows apart (#78).
		@MainActor fileprivate var versionKey: String? {
			guard case .source(let source) = input else { return nil }
			return UpdateCheck.key(of: source.version)
		}

		/// The bundle ID its source lists the app under, which its IPA may not
		/// have (#116); nil for an IPA file, from the Files app or a pasted
		/// URL, and for Atelier as it runs, which `originalBundleID` gives.
		@MainActor fileprivate var listedBundleID: String? {
			switch input {
			case .source(let source): source.app.bundleID
			case .download(let download, _): download.isFromURL ? nil : download.bundleID
			case .picked, .putBack, .disable, .ownApp: nil
			}
		}

		/// The download it installs, once known.
		@MainActor fileprivate var downloadID: UUID? {
			switch input {
			case .download(let download, _): download.id
			case .source(let source): source.downloadID
			case .picked, .putBack, .disable, .ownApp: nil
			}
		}

		/// The certificate it signs with; nil for an Apple ID.
		@MainActor fileprivate var certificate: StoredCertificate? {
			guard let certificateID else { return certificates.defaultCertificate }
			return certificates.certificates.first { $0.id == certificateID }
		}

		/// The Apple ID it signs with (#49), when that's what's picked or in
		/// use, rather than an imported certificate.
		@MainActor fileprivate var appleID: StoredAppleID? {
			certificates.appleID(certificateID ?? certificates.defaultID)
		}

		/// Whether there's a certificate to sign with, without writing the
		/// held copy (#72).
		@MainActor fileprivate func canSign() throws -> Bool {
			if let id = certificateID ?? certificates.defaultID, HeldSecrets.shared.holds(certificate: id) {
				return true
			}
			return try signingIdentity() != nil
		}

		/// A certificate held since it was queued is written for this signing;
		/// the caller deletes it with `HeldSecrets.deleteWritten()`.
		@MainActor fileprivate func signingIdentity() throws -> SigningIdentity? {
			var identity = try certificateIdentity()
			// Atelier signed with the profile it was installed with (#24).
			if usesInstalledProfile { identity?.profile = SelfUpdate.installedProfileURL }
			return identity
		}

		@MainActor private func certificateIdentity() throws -> SigningIdentity? {
			// Read when it was queued (#72). Always, not only once the iPhone
			// reports it's locked: it reports so about 10 s after locking,
			// and zsign reads the .p12 well after this.
			if let id = certificateID ?? certificates.defaultID, let held = try HeldSecrets.shared.writeIdentity(for: id) {
				return held
			}
			guard let certificateID else { return try certificates.defaultSigningIdentity() }
			return try certificates.signingIdentity(for: certificateID)
		}

		/// Where it came from, for its install history entry's Try again;
		/// nil for Put Back, which isn't an install.
		@MainActor fileprivate var origin: InstallAttempt.Origin? {
			switch input {
			case .picked(let file):
				return .picked(file.lastPathComponent)
			case .download(let download, _):
				return .download(download.id)
			case .source(let source):
				let copy: Int? = switch target {
				case .original: nil
				case .copy(let number): number
				}
				return .source(sourceURL: source.sourceURL, appID: source.app.id, version: source.version.version, copy: copy, displayName: displayName, certificateID: certificateID)
			case .ownApp:
				return .signedAgain(bundleID: SelfUpdate.shared.bundleID, originalBundleID: SelfUpdate.sourceBundleID, certificateID: certificateID)
			case .putBack, .disable:
				return nil
			}
		}
	}

	/// Atelier's own install, asked about before it's queued (#24), as it
	/// closes Atelier.
	struct SelfRequest: Identifiable {
		enum Kind: Equatable {
			/// Goes ahead once the user says so.
			case confirm
			/// None of the certificates signs for Atelier's App ID.
			case noCertificate
			/// A build older than the one running, which may not read the
			/// data this one saved.
			case older
			/// A free Apple ID installed Atelier, and isn't signed in here:
			/// only it signs for Atelier's App ID (#152).
			case needsAppleID
			/// Atelier's App ID ended, and its Apple ID has no new ones left
			/// this week, until `until` (#152).
			case noAppIDLeft(until: Date?)
		}

		var id: String { job.id }
		let job: Job
		let kind: Kind
		/// The certificate it signs with.
		let certificateName: String?
		/// The Apple ID it signs with instead (#152), as Atelier is one of
		/// its apps, and what that takes of its App IDs, as it last said.
		var appleID: String?
		var appIDUse: OwnAppleID.AppIDUse?
		/// The IPA as it came, which Install a Copy… installs next to
		/// Atelier instead (#113); nil for Atelier from its source and
		/// signed again as it runs.
		var copyJob: Job?
	}

	/// An installed app to sign for another App ID than the one it was
	/// installed with, which iOS can't replace it with (#76): picked in
	/// Custom Install…, or an update whose certificate is gone.
	struct ReplaceRequest: Identifiable {
		let id = UUID()
		let install: InstallRecord
		let certificateID: UUID
		let certificateName: String
		/// The version an update installs, as its source lists it; nil signs
		/// the installed one again.
		var update: (offer: Catalog.Offer, version: AppVersion)?
		/// An update signed with the certificate in use, as its own can't
		/// sign any more (#76), rather than with the one picked in Custom
		/// Install…, which installs its source's newest version too once the
		/// source no longer lists the one installed (#155). The question
		/// says which.
		var isFallback = false
		/// What was chosen for the app in Custom Install… besides the
		/// certificate (#155); nil keeps what it has.
		var look: Look?
		/// An IPA to install over the app instead, as it came, picked to in
		/// Custom Install's sheet (#155).
		var ipa: Job?
	}

	/// An app in a source.
	struct AppKey: Hashable {
		var bundleID: String
		var sourceURL: URL?
	}

	/// Where an app's install is at, for its Install button.
	enum AppStatus {
		case waiting(Job)
		case running(InstallStage)
	}

	static let endpointKey = "manifestEndpoint"
	/// The current or last install's stage; nil when there's none to show.
	private(set) var state: InstallStage?
	/// The current or last install's log, shown under "Details".
	private(set) var log: [String] = []
	/// What won't work in the app the current or last install signed,
	/// from its entitlements (#7).
	private(set) var limits: [String] = []
	/// The current or last install's permissions, as signed (#7).
	private(set) var permissions: SignedPermissions?
	/// Why iOS would refuse the current or last install over the app it
	/// replaces (#8).
	private(set) var upgradeProblem: String?
	/// Installs waiting for the current one, next first.
	private(set) var waiting: [Job] = []
	/// The running install's job.
	private var currentID: String?
	/// The running job's app, observed: set as the queue starts a job, a
	/// moment before its status is (#18).
	private var currentApp: AppKey?
	/// The job the status is about: running, or the last one to end.
	private(set) var shownJob: Job?
	/// What "Install again" runs after an install that couldn't be confirmed,
	/// "Try again" after one that failed in a way trying again may fix, and
	/// what "Install with Another Certificate" and "Install as a Copy" start
	/// from after iOS didn't install the app (#76).
	private(set) var retryJob: Job?
	/// Signing again or updates that need the app deleted first, asked about
	/// one at a time, first first (#76).
	var replaceRequests: [ReplaceRequest] = []
	/// Atelier's own installs waiting for an answer, first first (#24).
	private(set) var selfRequests: [SelfRequest] = []
	/// IPAs of installed apps waiting for an answer, first first (#113).
	private(set) var ipaQuestions: [IPAQuestion] = []
	/// New copies waiting for their names, first first (#113).
	private(set) var copyRequests: [CopyRequest] = []
	/// Atelier's own install is with iOS, which installs it once Atelier
	/// has closed: what it does, while the install bar says to go to the
	/// Home Screen (#24).
	private(set) var selfHandover: PendingSelfInstall.Kind?
	/// Whether Atelier may send notifications, as of its own install's
	/// start: the sheet that says to go to the Home Screen says how Atelier
	/// says how it went (#123).
	private(set) var selfNotifies = true
	/// What the install bar says about Atelier's own install that ended,
	/// in place of "Installed": "Updated to 0.2.0-alpha" (#24).
	private(set) var selfNote: String?
	/// Set when a fix asks for Atelier's Settings tab; the tab view clears it.
	var settingsRequested = false
	/// Set when an installs notification is tapped (#72); the tab view
	/// shows the Library and clears it.
	var libraryRequested = false
	/// Set to start Re-sign All from outside the Library, such as right
	/// after importing a certificate (#20); the Library clears it.
	var resignRequested = false
	/// Why each install that failed did, by job, for Re-sign All's report
	/// (#20). An install queued again drops its entry.
	private(set) var failures: [String: String] = [:]
	/// Set when a news notification is tapped (#19); the tab view shows
	/// Browse and clears it.
	var browseRequested = false
	/// Why each install whose app's data couldn't be copied failed, by job
	/// (#96), for Re-sign's question. An install queued again drops it.
	private(set) var dataFailures: [String: AppDataCopyFailure] = [:]
	/// The apps whose data was copied aside and is still kept, by bundle ID
	/// (#96): until the install running now puts it back, or when that
	/// couldn't, for Put Back in the Library. Observed.
	private(set) var keptData: Set<String> = []
	/// The data Disable kept, by the disabled app's bundle ID (#49): the
	/// Library lists those apps under Disabled, with Enable. Observed.
	private(set) var disabledApps: [String: KeptAppData] = [:]
	/// Make Room, over everything (#49): a free Apple ID's install, or
	/// Enable, found the 3 places on this iPhone taken.
	var makeRoom: MakeRoomRequest?
	/// The shown install worked, but its app's data wasn't put back (#96).
	private(set) var dataNotPutBack = false
	/// The download of an install that couldn't be confirmed. It's kept, out
	/// of the Downloads list, while its status shows, so installing it again
	/// needs no new download; then it's deleted.
	private(set) var keptDownload: (id: UUID, manager: DownloadManager)?

	/// Whether the Downloads list leaves this download out, because the
	/// install bar stands for it.
	func isHidden(_ download: Download) -> Bool {
		keptDownload?.id == download.id
	}

	@ObservationIgnored private var queue: InstallQueue<Job>!
	/// Route A's installer, which can also remove apps.
	private let pairingInstaller: PairingInstaller
	/// Route B's installer, which can show the iOS alert again (#51).
	private let localServerInstaller: RouteBInstaller
	/// The user closed an install whose iOS alert closed: once it ends, its
	/// status goes too.
	@ObservationIgnored private var gaveUpAlert = false
	/// The routes, route A first.
	@ObservationIgnored private var installers: [any Installer] = []

	/// Counts installs, so a delayed dismissal only closes the one it's for.
	private var runCount = 0
	/// Whether the install details sheet is open.
	var detailsOpen = false
	/// Import Certificate was tapped in the details, which the import can't
	/// show over: it opens once they're closed (#99).
	var importsAfterDetails = false
	/// The bar closed by itself while the details were open: the details
	/// stay until the user closes them, then the install's status goes.
	private(set) var barHidden = false

	/// After the details sheet closes.
	func detailsClosed() {
		detailsOpen = false
		if barHidden { reset() }
	}

	/// How long a confirmed install's status stays before closing by itself.
	/// Failures stay until dismissed, so their message and log can be read.
	private static let successLinger: Duration = .seconds(6)
	/// How long an install that couldn't be confirmed stays, with Install
	/// again, before closing by itself.
	private static let unconfirmedLinger: Duration = .seconds(30)

	init() {
		pairingInstaller = RouteASetup.shared.makeInstaller()
		localServerInstaller = RouteBInstaller(
			endpointSetting: { UserDefaults.standard.string(forKey: Self.endpointKey) ?? "" },
			open: { url in await UIApplication.shared.open(url) },
			isRegistered: { scheme in Self.isRegistered(scheme) }
		)
		installers = [pairingInstaller, localServerInstaller]
		queue = InstallQueue { [weak self] job in await self?.run(job) }
		// Atelier's own install closes Atelier, so nothing may wait behind it (#24).
		queue.runsLast = { $0.isSelf }
		queue.onChange = { [weak self] in
			guard let self else { return }
			waiting = queue.pending
			currentID = queue.current?.id
			currentApp = queue.current?.app
		}
		BackgroundInstalls.shared.model = self
		// Signed IPAs aren't kept for reinstalling any more, as they can
		// quickly fill up the iPhone (29 Oct 2026): those kept
		// before go.
		Task.detached(priority: .utility) { Self.deleteKeptSignedIPAs() }
	}

	/// Deletes the signed IPA Atelier kept of each app it installed, in
	/// Application Support/Signed, and the setting that kept them.
	nonisolated private static func deleteKeptSignedIPAs() {
		UserDefaults.standard.removeObject(forKey: "keepSignedIPAs")
		guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
		try? FileManager.default.removeItem(at: support.appending(path: "Signed", directoryHint: .isDirectory))
	}

	var isIdle: Bool {
		state == nil && waiting.isEmpty
	}

	var isRunning: Bool {
		state?.isActive ?? false
	}

	/// Whether this download is waiting or installing: installed as it is,
	/// or the download of an install from a source, which starts as it's
	/// queued.
	func isQueued(_ download: Download) -> Bool {
		let id = Self.jobID(download)
		if currentID == id || waiting.contains(where: { $0.id == id || $0.downloadID == download.id }) { return true }
		return isRunning && shownJob?.downloadID == download.id
	}

	/// Whether the app from this source is waiting or installing.
	func status(of app: AppKey) -> AppStatus? {
		if isRunning, let shownJob, shownJob.app == app, let state { return .running(state) }
		// Taken off the queue but not started yet: checking, rather than
		// briefly neither waiting nor running (#18).
		if currentApp == app { return .running(.checking) }
		if let job = waiting.first(where: { $0.app == app }) { return .waiting(job) }
		// Atelier's own install, while it's asked about (#24).
		return selfRequests.first { $0.job.app == app }.map { .waiting($0.job) }
	}

	/// Whether `version` of the app from this source is waiting or
	/// installing, for Version History, where each version has its own
	/// Install button (#78).
	func status(of app: SourceApp, version: AppVersion, sourceURL: URL?) -> AppStatus? {
		let key = AppKey(bundleID: app.bundleID, sourceURL: sourceURL)
		let versionKey = UpdateCheck.key(of: version)
		if isRunning, let shownJob, shownJob.app == key, shownJob.versionKey == versionKey, let state { return .running(state) }
		if currentApp == key, queue.current?.versionKey == versionKey { return .running(.checking) }
		return waiting.first { $0.app == key && $0.versionKey == versionKey }.map { .waiting($0) }
	}

	/// Whether this download is waiting or installing, for its Install
	/// button (#78): installed as it is, or by an install from a source,
	/// whose download starts as it's queued, so it can finish while the
	/// install still waits (7 Nov 2026).
	func status(of download: Download) -> AppStatus? {
		let id = Self.jobID(download)
		if isRunning, let shownJob, shownJob.id == id || shownJob.downloadID == download.id, let state { return .running(state) }
		if currentID == id { return .running(.checking) }
		return waiting.first { $0.id == id || $0.downloadID == download.id }.map { .waiting($0) }
	}

	/// Where the install of the Library's app `bundleID` is at: one of it from
	/// its source (`app`), as `status(of:)` says, or one over it, such as
	/// Re-sign, Reinstall or Custom Install…, for its row's ring and stage,
	/// in place of Downloads too (12 Nov 2026).
	func status(ofLibraryApp bundleID: String, key app: AppKey) -> AppStatus? {
		if let status = status(of: app) { return status }
		guard let job = job(ofLibraryApp: bundleID, key: app) else { return nil }
		if isRunning, shownJob?.id == job.id, let state { return .running(state) }
		if currentID == job.id { return .running(.checking) }
		return .waiting(job)
	}

	/// The download that install waits on or installs, also while Custom
	/// Install… or Re-sign gets the IPA of an app installed from one: its
	/// row shows it, rather than Downloads (12 Nov 2026).
	func downloadID(ofLibraryApp bundleID: String, key app: AppKey) -> UUID? {
		job(ofLibraryApp: bundleID, key: app)?.downloadID ?? fetchingIPA(of: bundleID)
	}

	/// The download of the app's IPA from its link, while Custom Install… or
	/// Re-sign waits for it to install over the app; not one for a copy.
	func fetchingIPA(of bundleID: String) -> UUID? {
		ipaDownloads.first { $0.value.install.bundleID == bundleID && $0.value.action.isOverTheApp }?.key
	}

	/// Stops that download from the app's row, where it shows rather than
	/// in Downloads (12 Nov 2026). One that was in Downloads already stays.
	func cancelIPADownload(of bundleID: String, downloads: DownloadManager) {
		for (id, fetching) in ipaDownloads where fetching.install.bundleID == bundleID && fetching.action.isOverTheApp {
			ipaDownloads[id] = nil
			if fetching.removesDownload { downloads.remove(id) }
		}
	}

	/// Whether the app is being re-signed (#20): its install waits or runs,
	/// or its IPA downloads for it. It stays in the Library's Re-sign section
	/// meanwhile, also once it's deleted to be installed again (12 Nov 2026).
	func isResigning(_ bundleID: String) -> Bool {
		let resigns = { (job: Job) in job.isResign && job.replacesBundleID == bundleID }
		if isRunning, let shownJob, resigns(shownJob) { return true }
		if currentID != nil, let current = queue.current, resigns(current) { return true }
		if waiting.contains(where: resigns) { return true }
		return ipaDownloads.values.contains { $0.install.bundleID == bundleID && $0.action.isResign }
	}

	/// The install of the Library's app `bundleID` that's running or waiting,
	/// running first.
	private func job(ofLibraryApp bundleID: String, key app: AppKey) -> Job? {
		let matches = { (job: Job) in job.app == app || job.replacesBundleID == bundleID }
		if isRunning, let shownJob, matches(shownJob) { return shownJob }
		if currentID != nil, let current = queue.current, matches(current) { return current }
		return waiting.first(where: matches)
	}

	/// Whether the install `id` is waiting or running, for Re-sign All's
	/// rows (#20).
	func status(ofJob id: String) -> AppStatus? {
		if isRunning, let shownJob, shownJob.id == id, let state { return .running(state) }
		if currentID == id { return .running(.checking) }
		if let job = waiting.first(where: { $0.id == id }) { return .waiting(job) }
		return selfRequests.first { $0.id == id }.map { .waiting($0.job) }
	}

	/// The one-tap install (#16): checks, then downloads `version` of `app`
	/// from the source at `sourceURL`, signs and installs it. A download of
	/// the same version that's running or finished is used as it is. With a
	/// copy as `target`, it installs that copy (#8), named `displayName`.
	/// `replacing` is the installed app it updates or signs again, which
	/// can have another bundle ID than the one it installs as (#49).
	func install(_ app: SourceApp, version: AppVersion, sourceURL: URL?, as target: InstallTarget = .original, displayName: String? = nil, certificateID: UUID? = nil, isUpdate: Bool = false, deletingFirst: Bool = false, copy: CopyChoice? = nil, replacing: InstallRecord? = nil, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		var job = Self.sourceJob(app, version: version, sourceURL: sourceURL, as: target, displayName: displayName, certificateID: certificateID, replacing: replacing, downloads: downloads, certificates: certificates, context: context)
		job.isUpdate = isUpdate
		job.deletesFirst = deletingFirst
		job.copyChoice = copy
		job.replacesBundleID = replacing?.bundleID
		enqueue(job)
	}

	/// `replacing` is the installed app it updates or signs again; else
	/// the one Atelier installed as the source's app, if any.
	private static func sourceJob(_ app: SourceApp, version: AppVersion, sourceURL: URL?, as target: InstallTarget, displayName: String?, certificateID: UUID?, replacing: InstallRecord? = nil, downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) -> Job {
		let source = SourceDownload(app: app, version: version, sourceURL: sourceURL, downloads: downloads)
		let copy = switch target {
		case .original: ""
		case .copy(let number): " (copy \(number))"
		}
		let installed = replacing ?? InstalledApps.record(listedAs: app.bundleID, as: target, in: context)
		return Job(
			id: "source \(sourceURL?.absoluteString ?? "") \(app.id) \(UpdateCheck.key(of: version))\(copy)",
			title: "\(app.name) \(version.displayVersion)\(copy)",
			// The installed app's own icon, which its source may not list (#118).
			iconURL: installed.flatMap { InstalledIcons.shared.url(for: $0.bundleID) } ?? app.iconURL,
			app: AppKey(bundleID: app.bundleID, sourceURL: sourceURL),
			target: target,
			displayName: displayName,
			certificateID: certificateID ?? installedCertificate(of: installed, certificates: certificates),
			certificatePicked: certificateID != nil,
			input: .source(source),
			certificates: certificates,
			context: context
		)
	}

	/// The certificate Atelier installed `bundleID` with, while it can
	/// still sign: an update keeps the app's certificate, and with it the
	/// App ID iOS has for the app, rather than the default one (#76). Nil,
	/// for the default certificate, when Atelier didn't install the app, or
	/// its certificate was removed, has expired or was revoked.
	static func installedCertificate(of bundleID: String, certificates: CertificatesModel, context: ModelContext) -> UUID? {
		installedCertificate(of: InstalledApps.record(bundleID, in: context), certificates: certificates)
	}

	/// The same for `install`, nil when Atelier didn't install the app.
	/// An app installed with an Apple ID keeps it too, and with it the
	/// bundle ID it has (#49).
	static func installedCertificate(of install: InstallRecord?, certificates: CertificatesModel) -> UUID? {
		guard let id = install?.certificateID else { return nil }
		let attention: CertificateAttention?
		if let certificate = certificates.certificates.first(where: { $0.id == id }) {
			attention = CertificateAttention(certificate)
		} else if let account = certificates.appleID(id) {
			attention = CertificateAttention(account)
		} else {
			return nil
		}
		switch attention {
		case .revoked, .expired: return nil
		case .expiring, nil: return id
		}
	}

	func install(picked: URL, certificates: CertificatesModel, into context: ModelContext) {
		// The picker greys out other files; this guards against a mis-typed one.
		guard IPAPicker.extensions.contains(picked.pathExtension.lowercased()) else {
			if !isRunning {
				log = []
				state = .failed(InstallProblem("\(picked.lastPathComponent) isn't an .ipa file."))
			}
			return
		}
		// A picked file is only readable for a moment, so it's copied in now.
		let staged: URL
		do {
			staged = try Self.stage(picked)
		} catch {
			if !isRunning {
				log = ["couldn't read \(picked.lastPathComponent): \(error.localizedDescription)"]
				state = .failed(InstallProblem("Atelier couldn't open that file. Pick it again."))
			}
			return
		}
		let name = picked.deletingPathExtension().lastPathComponent
		let job = Job(id: UUID().uuidString, title: name, input: .picked(staged), certificates: certificates, context: context)
		// One of an app Atelier installed asks first (#113).
		if let question = Self.question(job) {
			ipaQuestions.append(question)
		} else {
			enqueue(job)
		}
	}

	/// Signs and installs a finished download, then deletes it. One from a
	/// link, of an app Atelier installed, asks first (#113): what the user
	/// answers is theirs, not `carriedOver`.
	func install(_ download: Download, from downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext, carriedOver: Bool = false) {
		var job = Self.downloadJob(download, from: downloads, certificates: certificates, context: context)
		if download.isFromURL, let question = Self.question(job) {
			if !ipaQuestions.contains(where: { $0.id == question.id }) { ipaQuestions.append(question) }
		} else {
			job.carriedOver = carriedOver
			enqueue(job)
		}
	}

	private static func downloadJob(_ download: Download, from downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) -> Job {
		let title = download.displayVersion.isEmpty ? download.name : "\(download.name) \(download.displayVersion)"
		var job = Job(id: jobID(download), title: title, iconURL: download.iconURL, input: .download(download, downloads), certificates: certificates, context: context)
		// The link, to download it again (#113).
		if download.isFromURL { job.ipaLink = download.url }
		// A download of an installed app that isn't its update, such as a
		// version another source lists, shows under Downloads, so its
		// Install signs with the app's certificate, as Update does (#76),
		// and counts as an update. Its source can list it under another
		// bundle ID than its IPA's (#116).
		if let installed = InstalledApps.record(listedAs: download.bundleID, in: context) {
			job.certificateID = installedCertificate(of: installed, certificates: certificates)
			job.isUpdate = true
			// The installed app's own icon, as from its source (#118).
			job.iconURL = InstalledIcons.shared.url(for: installed.bundleID) ?? job.iconURL
		}
		return job
	}

	/// Downloads waiting to finish before they install by themselves: the
	/// ones started from a pasted URL in the Library's + menu or a link, and
	/// those of one-tap installs. Kept across launches: a large download can
	/// outlast Atelier, which iOS may end while it's in the background, and
	/// the install then picks up when Atelier is next opened.
	///
	/// Those left from before Atelier was opened (`Job.carriedOver`) don't
	/// go ahead of what the user asks for: they wait while it's under way
	/// (`userInstallPending`) and step aside for it (`stepAside`). They
	/// used to start whenever a download changed, and when the maintainer updated
	/// Atelier, an update the maintainer was holding back installed first, without a
	/// tap, while Atelier's waited (3 Nov 2026).
	private(set) var installWhenDownloaded: Set<UUID> = InstallModel.loadInstallWhenDownloaded() {
		didSet {
			UserDefaults.standard.set(installWhenDownloaded.map(\.uuidString), forKey: Self.installWhenDownloadedKey)
		}
	}

	private static let installWhenDownloadedKey = "installWhenDownloaded"

	private static func loadInstallWhenDownloaded() -> Set<UUID> {
		let strings = UserDefaults.standard.stringArray(forKey: installWhenDownloadedKey) ?? []
		return Set(strings.compactMap(UUID.init(uuidString:)))
	}

	/// The downloads on `installWhenDownloaded` the user started since
	/// Atelier was opened, from a link or a pasted URL: theirs, unlike
	/// those carried over.
	private var requested: Set<UUID> = []

	/// Something the user asked for is under way: a link's download, an
	/// app's IPA downloaded again or asked for (#113), an answer Atelier
	/// waits for, an install other than one carried over, or Atelier's own
	/// with iOS. The installs carried over on `installWhenDownloaded` wait
	/// meanwhile.
	var userInstallPending: Bool {
		!requested.isEmpty || !selfRequests.isEmpty || !ipaQuestions.isEmpty || !copyRequests.isEmpty || !replaceRequests.isEmpty
			|| !ipaRequests.isEmpty || !ipaDownloads.isEmpty
			|| selfHandover != nil
			|| waiting.contains { !$0.carriedOver }
			|| (currentID != nil && queue.current?.carriedOver != true)
	}

	/// Nothing runs, and nothing the user asked for is under way: those
	/// carried over on `installWhenDownloaded` may start, also one that
	/// stepped aside for what the user then said no to.
	var carriedOverMayStart: Bool {
		currentID == nil && !userInstallPending
	}

	/// Downloads the IPA at `url`, then signs and installs it like a picked
	/// file, without waiting for a tap on Install.
	func install(url: URL, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		let download = downloads.download(url: url)
		installWhenDownloaded.insert(download.id)
		requested.insert(download.id)
		stepAside(for: Self.jobID(download))
		installFinishedDownloads(downloads, certificates: certificates, into: context)
	}

	/// Starts the installs waiting on downloads that have finished, and stops
	/// waiting on those that failed or were deleted. Only while Atelier is
	/// in front, as the iOS install alert can't show otherwise; the tab view
	/// calls this again when it comes back, and once nothing the user asked
	/// for is under way, for those carried over.
	func installFinishedDownloads(_ downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		guard UIApplication.shared.applicationState == .active else { return }
		// And the IPAs downloaded again for apps installed from a link (#113).
		useDownloadedIPAs(downloads, certificates: certificates, context: context)
		// The user's own first, so those carried over find them under way.
		let ids = installWhenDownloaded.sorted { requested.contains($0) && !requested.contains($1) }
		for id in ids {
			guard let download = downloads.download(id: id) else {
				installWhenDownloaded.remove(id)
				requested.remove(id)
				continue
			}
			switch download.status {
			case .finished:
				if isQueued(download) {
					installWhenDownloaded.remove(id)
					requested.remove(id)
				} else if requested.contains(id) {
					installWhenDownloaded.remove(id)
					requested.remove(id)
					install(download, from: downloads, certificates: certificates, into: context)
				} else if !userInstallPending {
					installWhenDownloaded.remove(id)
					install(download, from: downloads, certificates: certificates, into: context, carriedOver: true)
				}
			case .failed:
				// Left for Try again and Install in the Downloads list.
				installWhenDownloaded.remove(id)
				requested.remove(id)
			case .downloading, .paused:
				break
			}
		}
	}

	/// The installs carried over on `installWhenDownloaded` give way to what
	/// the user asks for, the install `id`: those waiting go back on the
	/// list, and so does the one running, unless iOS may have it already.
	/// They start again once nothing the user asked for is under way, or
	/// when Atelier is next opened, as Atelier's own install closes it.
	private func stepAside(for id: String) {
		for other in waiting where other.carriedOver && !other.isSelf && other.id != id {
			remove(other)
			if let download = other.downloadID { installWhenDownloaded.insert(download) }
		}
		// Atelier's own has its own way of waiting for others (#24).
		guard steppedAside == nil, let current = queue.current, current.carriedOver, !current.isSelf, current.id != id else { return }
		if shownJob?.id == current.id {
			switch state {
			case .checking?, .downloading?, .signing?: break
			default: return
			}
		}
		steppedAside = current.id
		queue.cancelCurrent()
	}

	// MARK: Custom Install… (#113, #155)

	/// What Custom Install… asks about (#155), in its sheet: signing an app
	/// again, changing it or a copy of it, or installing a new copy (#113).
	/// From an installed app's page and menus, an app's Install button, or
	/// an IPA of an app that's installed.
	struct CopyRequest: Identifiable {
		enum Origin {
			/// A version from a source, which a new copy installs. An app
			/// installed over is signed again as the version it has, or gets
			/// this one once its source no longer lists that.
			case listing(SourceApp, AppVersion, sourceURL: URL)
			/// An IPA file or download, as it was going to install: over the
			/// app or copy picked, or as a new copy.
			case ipa(Job)
			/// An installed app without a version from its source to install:
			/// one installed from an IPA, whose IPA a new copy installs once
			/// Atelier has it again (#113), or Atelier as it runs (#24). An
			/// app installed over is signed again.
			case installed(InstallRecord)
		}

		/// What installs over one of the apps installed.
		struct OverInstall {
			/// What and from where, for the sheet's picture: "Wallcraft 4.2.1
			/// from AppTesters".
			let what: String
			/// Its version, for Advanced's.
			let version: String
			/// Why that isn't the version it has, when it isn't: "Its source
			/// no longer lists 4.2.1, so it gets 4.3.0."
			var note: String?
		}

		let id = UUID()
		let origin: Origin
		/// The copy a new one installs as: after every copy of the app
		/// installed.
		let target: InstallTarget
		/// As its source or its IPA names it.
		let appName: String
		/// What a new copy installs and from where: "Atelier 0.2.0 (323)
		/// from the Atelier repo".
		let what: String
		/// Atelier itself (#24), whose copy starts without its sources,
		/// certificates and settings.
		let isOwn: Bool
		/// The bundle ID its copies are numbered from: its IPA's, as far as
		/// it's known before it's downloaded (#116).
		let appBundleID: String
		/// The version a new copy installs, which it can say it isn't (#113).
		let version: String
		/// The app's icon without a tint or picture chosen for it, for the
		/// sheet's picture: the one its IPA has when the app is installed
		/// (#118, #155), else its source's.
		let iconURL: URL?
		/// The IPA, whose icon is the app's.
		let ipaFile: URL?
		/// The app and its copies that are installed, which it can install
		/// over, keeping their data: the app first, then the copies in order.
		let installed: [InstallRecord]
		/// What installs over each of `installed`, by bundle ID. One without
		/// has nothing to install, and can't be picked.
		let overInstalls: [String: OverInstall]
		/// The one of `installed` picked to start with: the one it's opened
		/// on. Nil for New Copy.
		let opened: InstallRecord?
		/// Whether New Copy can be picked: there's a version or an IPA to
		/// install as one.
		let offersNewCopy: Bool
		/// Whether the app itself can be picked though it isn't installed: a
		/// version from a source of an app Atelier hasn't installed, which
		/// installs as itself, with the name, icon and certificate picked
		/// (#155). Not Atelier, which is.
		var offersApp = false

		/// "Atelier 2", by the copy's number, so the Home Screen tells
		/// the copies apart, as the app's own name didn't.
		var suggestedName: String {
			guard case .copy(let number) = target else { return appName }
			return "\(appName) \(number)"
		}
	}

	/// What the user chose in Custom Install's sheet (#113, #155).
	struct CopyAnswer {
		/// The app or copy to install over, keeping its data; nil for a new
		/// copy, which installs as the request's `target`, or the app itself.
		var over: InstallRecord?
		/// The app itself, which isn't installed, rather than a new copy,
		/// when there's nothing to install over (`CopyRequest.offersApp`).
		var installsApp = false
		/// As typed in its Name field.
		var name: String
		var choice: CopyChoice
		var certificateID: UUID
	}

	/// What the user chose for an app in Custom Install's sheet (#113, #155):
	/// what it's signed with, which is kept for its updates and re-signs
	/// once it's installed.
	struct CopyChoice {
		var settings: CopySettings
		/// Its icon's picture, as PNG, when `settings` says it has one.
		var picture: Data?
		/// Include Certificate, for a copy of Atelier (#113): the copy comes
		/// with the certificate it's signed with, and its password, to import
		/// when it next opens. Only this install, not its updates and
		/// re-signs.
		var includesCertificate = false
	}

	/// A new copy as Custom Install's sheet chose it (#113, #155), installed
	/// from an IPA, once Atelier has it.
	struct NewCopy {
		var target: InstallTarget
		/// As typed in its Name field.
		var name: String
		var choice: CopyChoice?
		var certificateID: UUID?

		/// The name it's signed with: none, for its IPA's, when it's empty or
		/// the app's own, `appName`, rather than writing that in.
		func displayName(appName: String) -> String? {
			let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
			return name.isEmpty || name == appName ? nil : name
		}
	}

	/// An IPA of an app Atelier installed, which would install over it:
	/// asked about first, to install over it or as a copy next to it.
	struct IPAQuestion: Identifiable {
		var id: String { job.id }
		let job: Job
		/// The app it would install over.
		let installed: InstallRecord
		/// What the IPA's Info.plist says.
		let info: IPAInfo
	}

	/// Custom Install's sheet for a version from a source (#155): the app
	/// and its copies installed, and New Copy, which installs `version`
	/// from `source` (#113). The app itself installs it too while it isn't
	/// installed, with the name, icon and certificate picked. Opened on
	/// `install`, else on the app itself, or Atelier as it runs (#24). One
	/// offloaded isn't there to install over, nor to install afresh, as
	/// Reinstall puts it back with its data (#49).
	func askForCopy(of app: SourceApp, version: AppVersion, from source: Catalog.SourceInfo, opening install: InstallRecord? = nil, in catalog: Catalog, context: ModelContext) {
		let own = SelfUpdate.shared
		let all = InstalledApps.records(ofSourceApp: app.bundleID, in: context)
		let installs = all.filter { !isOffloaded($0) }
		let original = all.first { $0.target == .original && !own.isOwn($0) }
		let what = "\(app.name) \(version.displayVersion) from \(Self.phrase(for: source))"
		var overInstalls: [String: CopyRequest.OverInstall] = [:]
		for installed in installs {
			// Its source no longer lists the version it has: this one, as an
			// update would (#18).
			overInstalls[installed.bundleID] = signedAgain(installed, in: catalog, context: context)
				?? CopyRequest.OverInstall(what: what, version: version.version, note: "Its source no longer lists \(LibraryItem.displayVersion(of: installed)), so it gets \(version.displayVersion).")
		}
		let opening = install ?? (own.isOwnApp(app.bundleID) ? installs.first { own.isOwn($0) } : original)
		copyRequests.append(CopyRequest(
			origin: .listing(app, version, sourceURL: source.url),
			target: Self.newCopy(of: app, in: context),
			appName: app.name,
			what: what,
			isOwn: own.isOwnApp(app.bundleID),
			// Without the team ID an Apple ID adds (#49).
			appBundleID: all.first { !own.isOwn($0) }?.ipaBundleID ?? app.bundleID,
			version: version.version,
			iconURL: original.flatMap { Self.ownIconURL(of: $0, in: context) } ?? app.iconURL,
			ipaFile: nil,
			installed: installs,
			overInstalls: overInstalls,
			opened: opening.flatMap { opened in installs.first { $0.bundleID == opened.bundleID } },
			offersNewCopy: true,
			offersApp: original == nil && !own.isOwnApp(app.bundleID)
		))
	}

	/// Custom Install… on an installed app (#155): its sheet, opened on it, to
	/// sign it again, change it, or install a new copy (#113) of the newest
	/// version `listing` offers, its source's unless it's given, else of the
	/// IPA it was installed from. On New Copy for an offloaded app, which
	/// stays offloaded, with its copies that aren't (#49).
	func askForCustomInstall(_ install: InstallRecord, listing: Catalog.Offer? = nil, in catalog: Catalog, context: ModelContext) {
		if let offer = listing ?? Self.listing(of: install, in: catalog), let version = offer.app.availability().version {
			askForCopy(of: offer.app, version: version, from: offer.source, opening: install, in: catalog, context: context)
			return
		}
		let own = SelfUpdate.shared
		let isIPA = Self.isFromIPA(install)
		// Those of its IPA, without the team ID an Apple ID adds (#49), or
		// of its source's app.
		let all = isIPA
			? InstalledApps.records(ofIPA: install.ipaBundleID, in: context)
			: InstalledApps.records(ofSourceApp: install.sourceBundleID, in: context)
		let installs = all.filter { !isOffloaded($0) }
		var overInstalls: [String: CopyRequest.OverInstall] = [:]
		for installed in installs {
			overInstalls[installed.bundleID] = signedAgain(installed, in: catalog, context: context)
		}
		let original = all.first { $0.target == .original && !own.isOwn($0) }
		copyRequests.append(CopyRequest(
			origin: .installed(install),
			target: InstalledApps.newCopy(of: install.ipaBundleID, in: context),
			appName: original?.name ?? Self.ipaAppName(of: install, in: context),
			what: signedAgain(install, in: catalog, context: context)?.what ?? install.name,
			isOwn: own.isOwnApp(install.ipaBundleID),
			appBundleID: install.ipaBundleID,
			version: install.version,
			iconURL: Self.ownIconURL(of: original ?? install, in: context),
			ipaFile: nil,
			installed: installs,
			overInstalls: overInstalls,
			opened: installs.first { $0.bundleID == install.bundleID },
			offersNewCopy: isIPA
		))
	}

	/// What signing `install` again installs (#155), for Custom Install's
	/// picture: "Wallcraft 4.2.1 from AppTesters", "Atelier 0.4.0 (412), as
	/// it runs", "Lyfta 3.9.1 from github.com". Nil when there's nothing to
	/// sign, as its source no longer lists the version it has.
	private func signedAgain(_ install: InstallRecord, in catalog: Catalog, context: ModelContext) -> CopyRequest.OverInstall? {
		let installed = LibraryItem.displayVersion(of: install)
		if SelfUpdate.shared.isOwn(install) {
			return CopyRequest.OverInstall(what: "\(install.name) \(installed), as it runs", version: install.version)
		}
		if Self.isFromIPA(install) {
			let place = IPAOrigins.shared.link(of: install.bundleID).map(IPAOrigins.site(of:)) ?? "an IPA you choose"
			return CopyRequest.OverInstall(what: "\(Self.ipaAppName(of: install, in: context)) \(installed) from \(place)", version: install.version)
		}
		guard let found = installedVersion(of: install, in: catalog) else { return nil }
		return CopyRequest.OverInstall(what: "\(found.offer.app.name) \(found.version.displayVersion) from \(Self.phrase(for: found.offer.source))", version: found.version.version)
	}

	/// The app an installed app's IPA is of, by its name in the Library: for
	/// a copy, the app it copies, while that's there.
	static func ipaAppName(of install: InstallRecord, in context: ModelContext) -> String {
		guard install.target != .original, let original = InstalledApps.record(install.appBundleID, in: context) else { return install.name }
		return original.name
	}

	/// Install a Copy… for an IPA of an installed app: Custom Install's sheet,
	/// instead of installing over the app.
	func askForCopy(_ question: IPAQuestion) {
		ipaQuestions.removeAll { $0.id == question.id }
		askForCopy(of: question.job, info: question.info, isOwn: false)
	}

	/// Install a Copy… for an IPA of Atelier, which would install over
	/// Atelier (#24): Custom Install's sheet instead.
	func askForCopy(_ request: SelfRequest) {
		selfRequests.removeAll { $0.id == request.id }
		guard let job = request.copyJob else { return }
		guard let file = Self.ipaFile(of: job), let info = try? IPAInfo.read(ipaAt: file) else { return drop(job) }
		askForCopy(of: job, info: info, isOwn: true)
	}

	/// Custom Install's sheet for an IPA (#113, #155), on New Copy, with the
	/// app and its copies installed to install it over instead; for an IPA
	/// of Atelier, its copies but the one running, which Atelier's own
	/// install is for (#24).
	private func askForCopy(of job: Job, info: IPAInfo, isOwn: Bool) {
		let own = SelfUpdate.shared
		// Not an offloaded one, which Reinstall puts back with its data (#49).
		let installs = InstalledApps.records(ofIPA: info.bundleID, in: job.context).filter { !own.isOwn($0) && !(isOwn && $0.target == .original) && !isOffloaded($0) }
		// "from Atelier.ipa", "from github.com".
		let what = "\(info.name) \(Self.displayVersion(of: info)) from \(job.ipaLink.map(IPAOrigins.site(of:)) ?? "the IPA")"
		let over = CopyRequest.OverInstall(what: what, version: info.version)
		copyRequests.append(CopyRequest(
			origin: .ipa(job),
			target: InstalledApps.newCopy(of: info.bundleID, in: job.context),
			appName: info.name,
			what: what,
			isOwn: isOwn,
			appBundleID: info.bundleID,
			version: info.version,
			iconURL: nil,
			ipaFile: Self.ipaFile(of: job),
			installed: installs,
			overInstalls: Dictionary(uniqueKeysWithValues: installs.map { ($0.bundleID, over) }),
			opened: nil,
			offersNewCopy: true
		))
	}

	/// Off this iPhone with its data kept (#49). Custom Install's sheet
	/// doesn't offer to install over an offloaded app or copy, as that
	/// wouldn't put its data back; Reinstall does (#155).
	func isOffloaded(_ install: InstallRecord) -> Bool {
		disabledApps[install.bundleID] != nil && Self.presence(of: install) != .installed
	}

	/// An IPA's version with its build number, as "3.4.0 (12)", as the
	/// Library shows the installed one.
	static func displayVersion(of info: IPAInfo) -> String {
		guard let build = info.buildVersion, build != info.version else { return info.version }
		return "\(info.version) (\(build))"
	}

	/// Install in Custom Install's sheet (#155): over the app or copy
	/// picked, keeping its data, with what was chosen for it but its App
	/// ID, which stays; the app itself while it isn't installed; or a new
	/// copy next to them (#113); each signed with the certificate picked.
	/// Over an installed app, a version from a source signs the version it
	/// has again, as Sign Again With… did (#17), or once its source no
	/// longer lists that, installs this one; an IPA installs over it. One
	/// for another App ID asks first, as iOS can't replace the app with it
	/// (#76), and so does an Apple ID that installs it as another bundle ID
	/// (#49).
	func customInstall(_ request: CopyRequest, _ answer: CopyAnswer, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		copyRequests.removeAll { $0.id == request.id }
		guard let over = answer.over else {
			if answer.installsApp {
				return installApp(request, answer, downloads: downloads, certificates: certificates, into: context)
			}
			return installNewCopy(request, answer, downloads: downloads, certificates: certificates, into: context)
		}
		let look = Self.look(answer, for: over)
		let asksFirst = needsReinstall(over, signingWith: answer.certificateID, certificates: certificates)
		// Or the Apple ID's (#49).
		let certificateName = certificates.certificates.first { $0.id == answer.certificateID }?.displayName
			?? certificates.appleID(answer.certificateID)?.displayName ?? ""
		switch request.origin {
		case .ipa(let job):
			if asksFirst {
				replaceRequests.append(ReplaceRequest(install: over, certificateID: answer.certificateID, certificateName: certificateName, look: look, ipa: job))
			} else {
				enqueue(Self.ipaJob(job, over: over, look: look, certificateID: answer.certificateID))
			}
		case .listing(let app, let version, let sourceURL) where !canSignAgain(over, in: catalog):
			if asksFirst, let offer = catalog.entry(id: app.id)?.offers.first(where: { $0.source.url == sourceURL }) {
				replaceRequests.append(ReplaceRequest(install: over, certificateID: answer.certificateID, certificateName: certificateName, update: (offer, version), look: look))
			} else {
				install(app, version: version, sourceURL: sourceURL, as: over.target, displayName: Self.displayName(of: over, look: look), certificateID: answer.certificateID, isUpdate: true, copy: look.map { Self.choice($0, for: over) }, replacing: over, downloads: downloads, certificates: certificates, into: context)
			}
		case .listing, .installed:
			if asksFirst {
				replaceRequests.append(ReplaceRequest(install: over, certificateID: answer.certificateID, certificateName: certificateName, look: look))
			} else {
				signAgain(over, with: answer.certificateID, look: look, in: catalog, downloads: downloads, certificates: certificates, into: context)
			}
		}
	}

	/// The app itself, which isn't installed, as Custom Install's sheet
	/// chose it (#155): the version from its source, under its own App ID,
	/// with the name, icon and certificate picked, which its updates and
	/// re-signs keep, as for an app the sheet installs over.
	private func installApp(_ request: CopyRequest, _ answer: CopyAnswer, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		guard case .listing(let app, let version, let sourceURL) = request.origin else { return }
		// None, for its IPA's, when it's the app's own.
		let name = CopySettings.signingName(typed: answer.name, current: request.appName, chosen: nil, isCopy: false)
		var choice = answer.choice
		choice.settings.bundleID = nil
		choice.settings.name = name
		install(app, version: version, sourceURL: sourceURL, displayName: name, certificateID: answer.certificateID, copy: choice, downloads: downloads, certificates: certificates, into: context)
	}

	/// A new copy next to the app and its copies (#113), as Custom
	/// Install's sheet chose it: of the version from the source, the IPA,
	/// or the IPA the app was installed from.
	private func installNewCopy(_ request: CopyRequest, _ answer: CopyAnswer, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		let new = NewCopy(target: request.target, name: answer.name, choice: answer.choice, certificateID: answer.certificateID)
		switch request.origin {
		case .listing(let app, let version, let sourceURL):
			install(app, version: version, sourceURL: sourceURL, as: new.target, displayName: new.displayName(appName: request.appName), certificateID: new.certificateID, copy: new.choice, downloads: downloads, certificates: certificates, into: context)
		case .ipa(let job):
			guard let copy = Self.newCopyJob(job, new, appName: request.appName) else { return drop(job) }
			enqueue(copy)
		case .installed(let install):
			fetchIPA(of: install, for: .newCopy(new), downloads: downloads, certificates: certificates, context: context)
		}
	}

	/// `job`, an IPA, as a new copy next to the app and its copies (#113),
	/// as Custom Install's sheet chose it; `appName` is its IPA's. Nil for one
	/// that isn't a copy.
	private static func newCopyJob(_ job: Job, _ new: NewCopy, appName: String) -> Job? {
		guard var copy = copy(job, as: new.target) else { return nil }
		copy.displayName = new.displayName(appName: appName)
		copy.copyChoice = new.choice
		copy.certificateID = new.certificateID
		copy.certificatePicked = new.certificateID != nil
		// A new app, not the one its IPA would have updated.
		copy.isUpdate = false
		return copy
	}

	/// `job`, an IPA, installing over `install`, keeping its data (#113,
	/// #155): as the app or the copy it is, with `look`, else what it has,
	/// signed with `certificateID`.
	private static func ipaJob(_ job: Job, over install: InstallRecord, look: Look?, certificateID: UUID) -> Job {
		var job = job
		if case .copy(let number) = install.target {
			job.id = "\(job.id) (copy \(number))"
			job.title = "\(job.title) (copy \(number))"
		}
		job.target = install.target
		job.displayName = displayName(of: install, look: look)
		job.copyChoice = look.map { choice($0, for: install) }
		job.certificateID = certificateID
		job.certificatePicked = true
		job.isUpdate = true
		// Also when it installs as another bundle ID: signed with an Apple
		// ID, or no longer with one (#49).
		job.replacesBundleID = install.bundleID
		// The installed app's own icon (#118).
		job.iconURL = InstalledIcons.shared.url(for: install.bundleID) ?? job.iconURL
		return job
	}

	/// Cancel in Custom Install's sheet: an IPA isn't installed after all.
	func cancelCopy(_ request: CopyRequest) {
		copyRequests.removeAll { $0.id == request.id }
		if case .ipa(let job) = request.origin { drop(job) }
	}

	/// Installs the IPA over the app, as an update: signed with the
	/// certificate the app was installed with while it can sign, so iOS
	/// replaces the app and it keeps its data (#76).
	func installOver(_ question: IPAQuestion) {
		ipaQuestions.removeAll { $0.id == question.id }
		var job = question.job
		job.certificateID = job.certificateID ?? Self.installedCertificate(of: question.installed, certificates: job.certificates)
		job.isUpdate = true
		// The installed app's own icon (#118).
		job.iconURL = job.iconURL ?? InstalledIcons.shared.url(for: question.installed.bundleID)
		enqueue(job)
	}

	/// Cancel: the IPA isn't installed. A download stays in Downloads.
	func dismiss(_ question: IPAQuestion) {
		ipaQuestions.removeAll { $0.id == question.id }
		drop(question.job)
	}

	/// The copy a new copy of `app` installs as: numbered from its IPA's
	/// bundle ID, known once the app or a copy of it is installed (#116),
	/// and not from Atelier's own, which another tool may have changed
	/// (#24).
	static func newCopy(of app: SourceApp, in context: ModelContext) -> InstallTarget {
		let installed = InstalledApps.records(ofSourceApp: app.bundleID, in: context).first { !SelfUpdate.shared.isOwn($0) }
		// Without the team ID an Apple ID adds (#49).
		return InstalledApps.newCopy(of: installed?.ipaBundleID ?? app.bundleID, in: context)
	}

	/// Where an app is from, as Custom Install's sheet says it.
	private static func phrase(for source: Catalog.SourceInfo) -> String {
		if source.url == SelfUpdate.sourceURL { return "the built-in source" }
		if GitHubRepo(sourceURL: source.url) != nil { return "the \(source.name) repo" }
		return source.name
	}

	/// What to ask before an IPA installs over the app Atelier installed
	/// with its bundle ID, while that's on this iPhone. Nil for any other
	/// IPA, and for Atelier's own, which asks its own question (#24).
	private static func question(_ job: Job) -> IPAQuestion? {
		guard let file = ipaFile(of: job), let info = try? IPAInfo.read(ipaAt: file),
		      !SelfUpdate.shared.isOwnApp(info.bundleID),
		      let installed = InstalledApps.record(info.bundleID, in: job.context),
		      presence(of: installed) != .deleted
		else { return nil }
		return IPAQuestion(job: job, installed: installed, info: info)
	}

	/// The IPA a job installs, once it's there.
	private static func ipaFile(of job: Job) -> URL? {
		switch job.input {
		case .picked(let file): file
		case .download(let download, let downloads): downloads.fileURL(for: download.id)
		case .source, .putBack, .disable, .ownApp: nil
		}
	}

	/// Deletes the copy of a picked file that won't be installed, and a
	/// download made to get an app's IPA again (#113).
	private func drop(_ job: Job) {
		switch job.input {
		case .picked(let file):
			try? FileManager.default.removeItem(at: file)
		case .download(let download, let downloads) where job.removesDownload:
			downloads.remove(download.id)
		case .download, .source, .putBack, .disable, .ownApp:
			break
		}
	}

	// MARK: Apps installed from an IPA (#113)

	/// What Custom Install… and Re-sign do with the IPA of an app installed
	/// from one, once Atelier has it.
	enum IPAAction {
		/// Installs a new copy of it, as Custom Install's sheet chose it
		/// (#113, #155).
		case newCopy(NewCopy)
		/// Signs it again with the certificate picked in Custom Install…
		/// (#17), deleting it first when that one is for another App ID
		/// (#76), with what else was chosen there (#155).
		case signAgain(certificateID: UUID, deletingFirst: Bool, look: Look?)
		/// Signs it again with the certificate re-signing uses, once its own
		/// died (#20).
		case resign(certificateID: UUID, deletingFirst: Bool, keepingData: Bool)

		var isResign: Bool {
			if case .resign = self { return true }
			return false
		}

		/// It installs over the app, rather than a copy next to it.
		var isOverTheApp: Bool {
			if case .newCopy = self { return false }
			return true
		}
	}

	/// An app's IPA that Atelier asks the user to choose, in an alert whose
	/// Choose IPA File… opens Files: it doesn't know where the IPA is, its
	/// link doesn't work anymore, or it isn't the app's. Or it's another
	/// version than the one installed, which installs only once the user
	/// says so.
	struct IPARequest: Identifiable {
		/// Why it asks. `place` is where the IPA it found is, as the alert
		/// says it: "Atelier.ipa", "the IPA at github.com" or "that IPA".
		enum Reason {
			/// Installed from an IPA file, which Atelier can't find again,
			/// or from a link before it kept track.
			case unknown
			case linkFailed(site: String, why: String)
			/// What's at `place` is another app, `name`.
			case otherApp(place: String, name: String)
			case unreadable(place: String)
			/// What's at `place` is `version`, and `installed` is installed.
			case otherVersion(place: String, version: String, installed: String)
		}

		let id = UUID()
		/// The app the IPA is for.
		let install: InstallRecord
		let action: IPAAction
		let reason: Reason
		/// For `otherVersion`, the install of that version, once the user
		/// says so.
		fileprivate var job: Job?
	}

	/// IPAs Atelier asks the user to choose, first first.
	private(set) var ipaRequests: [IPARequest] = []
	/// Changes whenever the link an app's IPA came from does, so its page
	/// shows the new one.
	private var ipaLinksChanged = 0

	/// A link downloaded again for an app's IPA.
	private struct IPADownload {
		let install: InstallRecord
		let action: IPAAction
		/// Atelier started it, rather than finding the link in Downloads
		/// already, so it's deleted once it's used or doesn't work.
		let removesDownload: Bool
	}

	/// The links downloaded again for apps' IPAs, by download.
	private var ipaDownloads: [UUID: IPADownload] = [:]

	/// The link the IPA of the app installed as `bundleID` came from, for
	/// its page; nil when Atelier doesn't know one.
	func ipaLink(of bundleID: String) -> URL? {
		_ = ipaLinksChanged
		return IPAOrigins.shared.link(of: bundleID)
	}

	/// The download of the app's IPA from its link, while Custom Install… or
	/// Re-sign waits for it, for its page to show.
	func ipaDownloadID(of install: InstallRecord) -> UUID? {
		ipaDownloads.first { $0.value.install.bundleID == install.bundleID }?.key
	}

	private func noteIPALink(_ link: URL?, for bundleID: String) {
		guard IPAOrigins.shared.link(of: bundleID) != link else { return }
		IPAOrigins.shared.save(link, for: bundleID)
		ipaLinksChanged += 1
	}

	/// Whether an installed app was installed from an IPA, rather than
	/// from a source or as Atelier itself, so its IPA is what Custom Install…
	/// and Re-sign use.
	static func isFromIPA(_ install: InstallRecord) -> Bool {
		install.sourceURL == nil && !SelfUpdate.shared.isOwn(install)
	}

	/// Gets the IPA of `install`, an app installed from one, for `action`:
	/// downloads the link it came from again, or without one, asks for it.
	/// Shows in the Library's Downloads meanwhile, as Download from URL
	/// does; `installFinishedDownloads` goes on once it's done. A download
	/// of the link already there stays, as it was.
	private func fetchIPA(of install: InstallRecord, for action: IPAAction, downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) {
		guard let url = IPAOrigins.shared.link(of: install.bundleID) else {
			ipaRequests.append(IPARequest(install: install, action: action, reason: .unknown))
			return
		}
		let isThere = downloads.downloads.contains { $0.isFromURL && $0.url == url }
		let download = downloads.download(url: url)
		ipaDownloads[download.id] = IPADownload(install: install, action: action, removesDownload: !isThere)
		installFinishedDownloads(downloads, certificates: certificates, into: context)
	}

	/// Goes on with the IPAs downloaded again for apps installed from one,
	/// or asks for each whose link didn't work.
	private func useDownloadedIPAs(_ downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) {
		for (id, waiting) in ipaDownloads {
			guard let download = downloads.download(id: id) else {
				// Deleted in Downloads meanwhile.
				ipaDownloads[id] = nil
				continue
			}
			switch download.status {
			case .finished:
				ipaDownloads[id] = nil
				// Installed from Downloads meanwhile.
				guard !isQueued(download) else { continue }
				var job = Self.downloadJob(download, from: downloads, certificates: certificates, context: context)
				job.removesDownload = waiting.removesDownload
				use(job, for: waiting.install, action: waiting.action)
			case .failed(let why):
				ipaDownloads[id] = nil
				if waiting.removesDownload { downloads.remove(id) }
				ipaRequests.append(IPARequest(install: waiting.install, action: waiting.action, reason: .linkFailed(site: IPAOrigins.site(of: download.url), why: why)))
			case .downloading, .paused:
				break
			}
		}
	}

	/// Choose IPA File… in the alert asking for an app's IPA: the file goes
	/// on as its IPA.
	func use(picked: URL, for request: IPARequest, certificates: CertificatesModel, into context: ModelContext) {
		ipaRequests.removeAll { $0.id == request.id }
		if let job = request.job { drop(job) }
		let staged: URL
		do {
			staged = try Self.stage(picked)
		} catch {
			ipaRequests.append(IPARequest(install: request.install, action: request.action, reason: .unreadable(place: picked.lastPathComponent)))
			return
		}
		let job = Job(id: UUID().uuidString, title: request.install.name, input: .picked(staged), certificates: certificates, context: context)
		use(job, for: request.install, action: request.action, name: picked.lastPathComponent)
	}

	/// Install in the alert about another version than the one installed.
	func installOtherVersion(_ request: IPARequest) {
		ipaRequests.removeAll { $0.id == request.id }
		if let job = request.job { enqueue(job) }
	}

	/// Cancel in the alert asking for an app's IPA.
	func dismiss(_ request: IPARequest) {
		ipaRequests.removeAll { $0.id == request.id }
		if let job = request.job { drop(job) }
	}

	/// Goes on with `action` now that `job` has the IPA of `install`: once
	/// it's the app's, and the version installed; else asks. The installed
	/// version's link becomes the app's. `name` is the file's, for one the
	/// user chose.
	private func use(_ job: Job, for install: InstallRecord, action: IPAAction, name: String? = nil) {
		// Deleted from the Library meanwhile.
		guard install.modelContext != nil, !install.isDeleted else {
			drop(job)
			return
		}
		let site = job.ipaLink.map(IPAOrigins.site(of:))
		let place = site.map { "the IPA at \($0)" } ?? name ?? "that IPA"
		guard let file = Self.ipaFile(of: job), let info = try? IPAInfo.read(ipaAt: file) else {
			drop(job)
			ipaRequests.append(IPARequest(install: install, action: action, reason: .unreadable(place: place)))
			return
		}
		// Without the team ID an Apple ID signs it with (#49).
		guard info.bundleID == install.ipaBundleID else {
			drop(job)
			ipaRequests.append(IPARequest(install: install, action: action, reason: .otherApp(place: place, name: info.name)))
			return
		}
		let version = Self.displayVersion(of: info)
		let installed = LibraryItem.displayVersion(of: install)
		// The installed version's link is where Atelier looks next time; an
		// install of another one notes its link once it's installed.
		if version == installed, let link = job.ipaLink { noteIPALink(link, for: install.bundleID) }
		guard let signing = signingJob(job, for: install, info: info, action: action) else { return drop(job) }
		guard version == installed else {
			ipaRequests.append(IPARequest(install: install, action: action, reason: .otherVersion(place: place, version: version, installed: installed), job: signing))
			return
		}
		enqueue(signing)
	}

	/// The install `action` makes of the IPA of `install`, `job`'s: signing
	/// it again as the app or the copy it is, with its name, its settings or
	/// those chosen in Custom Install… (#155), and the certificate picked, as
	/// Custom Install… and Re-sign do for an app from a source, taking the
	/// app's place also when it installs as another bundle ID: signed with
	/// an Apple ID, or no longer with one (#49). Or a new copy next to it
	/// (#113). Nil for a new copy that isn't a copy.
	private func signingJob(_ job: Job, for install: InstallRecord, info: IPAInfo, action: IPAAction) -> Job? {
		var job = job
		if case .newCopy(let new) = action {
			// Named after the app it copies, with its icon without the
			// tint or picture chosen for `install` (#155).
			job.title = "\(info.name) \(Self.displayVersion(of: info))"
			job.iconURL = Self.ownIconURL(of: install, in: job.context) ?? job.iconURL
			return Self.newCopyJob(job, new, appName: info.name)
		}
		job.title = "\(install.name) \(Self.displayVersion(of: info))"
		job.iconURL = InstalledIcons.shared.url(for: install.bundleID) ?? job.iconURL
		job.target = install.target
		job.displayName = Self.displayName(of: install)
		job.isUpdate = false
		job.replacesBundleID = install.bundleID
		switch action {
		case .newCopy:
			break
		case .signAgain(let certificateID, let deletingFirst, let look):
			job.certificateID = certificateID
			job.certificatePicked = true
			job.deletesFirst = deletingFirst
			if let look {
				job.displayName = look.name
				job.copyChoice = Self.choice(look, for: install)
			}
		case .resign(let certificateID, let deletingFirst, let keepingData):
			job.certificateID = certificateID
			job.certificatePicked = true
			job.isResign = true
			job.deletesFirst = deletingFirst
			job.keepsData = keepingData
		}
		return job
	}

	// MARK: Library actions (#17)

	/// Where an installed app's source lists it now: the listing from the
	/// source it was installed from, preferring the app (of those sharing
	/// its bundle ID) that lists its installed version. Nil for an IPA file
	/// or once that source no longer lists it.
	static func listing(of install: InstallRecord, in catalog: Catalog) -> Catalog.Offer? {
		guard let sourceURL = install.sourceURL else { return nil }
		// Atelier's own source lists it under its own bundle ID, whatever
		// it runs as (#24).
		let bundleID = SelfUpdate.shared.isOwn(install) ? SelfUpdate.sourceBundleID : install.sourceBundleID
		let offers = catalog.entries
			.filter { $0.bundleID == bundleID }
			.compactMap { entry in entry.offers.first { $0.source.url == sourceURL } }
		return offers.first { listedVersion(of: install, in: $0.app) != nil } ?? offers.first
	}

	/// The installed version as `app` lists it, by version and build number,
	/// or as the tag of a GitHub pre-release Atelier didn't read (#104).
	static func listedVersion(of install: InstallRecord, in app: SourceApp) -> AppVersion? {
		UpdateCheck.installedEntry(InstalledRelease(version: install.version, buildVersion: install.buildVersion, installedAt: install.installedAt), in: app)
	}

	/// The name an installed app keeps when its source's app is installed
	/// over it: a copy's own (#8), or the one chosen for the app itself in
	/// Custom Install… (#155); nil keeps its IPA's.
	private static func displayName(of install: InstallRecord) -> String? {
		install.target == .original ? install.copySettings?.name : install.name
	}

	/// The name `install` is signed with: the one `look` has, chosen in
	/// Custom Install… (#155), else the one it keeps.
	private static func displayName(of install: InstallRecord, look: Look?) -> String? {
		if let look { return look.name }
		return displayName(of: install)
	}

	/// Updates an installed app to `version` from its source (#18), or with
	/// none, to its source's newest version this iPhone can run, as itself
	/// or as the copy it is.
	func update(_ install: InstallRecord, to version: AppVersion? = nil, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		guard let offer = Self.listing(of: install, in: catalog), let version = version ?? offer.app.availability().version else { return }
		update(install, to: version, from: offer, downloads: downloads, certificates: certificates, into: context)
	}

	/// Updates an installed app to `version` as `offer` lists it, which may
	/// be another source's: the install then records that source.
	/// When the certificate it was installed with is gone and the default
	/// one signs for another App ID, iOS can't replace the app, so the
	/// Library asks first (#76); not once it's deleted from this iPhone,
	/// as the Re-sign section asks for when Direct installs can't (#20).
	/// Atelier's own update picks a certificate for its App ID instead
	/// (#24), as it can't delete itself.
	func update(_ install: InstallRecord, to version: AppVersion, from offer: Catalog.Offer, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		// The one in use may be an Apple ID, which installs it as another
		// bundle ID (#49).
		if !SelfUpdate.shared.isOwn(install),
		   Self.presence(of: install) != .deleted,
		   Self.installedCertificate(of: install, certificates: certificates) == nil,
		   let fallbackID = certificates.defaultID, let fallbackName = certificates.inUseName,
		   needsReinstall(install, signingWith: fallbackID, certificates: certificates) {
			replaceRequests.append(ReplaceRequest(install: install, certificateID: fallbackID, certificateName: fallbackName, update: (offer, version), isFallback: true))
			return
		}
		self.install(offer.app, version: version, sourceURL: offer.source.url, as: install.target, displayName: Self.displayName(of: install), isUpdate: true, replacing: install, downloads: downloads, certificates: certificates, into: context)
	}

	/// Updates an installed app from its source by itself, from a background
	/// update run (#72), through direct installs only. Returns whether it
	/// was queued: one that needs the app deleted first, as `update` asks
	/// about (#76), is left for the user, and so is Atelier's own update,
	/// which would close Atelier while it's used (#24).
	@discardableResult
	func updateAutomatically(_ install: InstallRecord, to version: AppVersion, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) -> Bool {
		guard !SelfUpdate.shared.isOwn(install), let offer = Self.listing(of: install, in: catalog) else { return false }
		if Self.installedCertificate(of: install, certificates: certificates) == nil,
		   let fallbackID = certificates.defaultID,
		   needsReinstall(install, signingWith: fallbackID, certificates: certificates) {
			return false
		}
		var job = Self.sourceJob(offer.app, version: version, sourceURL: offer.source.url, as: install.target, displayName: Self.displayName(of: install), certificateID: nil, replacing: install, downloads: downloads, certificates: certificates, context: context)
		job.replacesBundleID = install.bundleID
		job.isUpdate = true
		job.automatic = true
		enqueue(job)
		return true
	}

	/// Whether direct installs can run now, without switching LocalDevVPN
	/// on, which needs Atelier in front (#72).
	func directInstallsHealth() async -> RouteHealth {
		await pairingInstaller.check(startingVPN: false)
	}

	/// Whether Custom Install… has something to sign again: the installed
	/// version from its source, or the IPA it was installed from (#113);
	/// Atelier as it runs (#24).
	func canSignAgain(_ install: InstallRecord, in catalog: Catalog) -> Bool {
		SelfUpdate.shared.isOwn(install) || Self.isFromIPA(install) || installedVersion(of: install, in: catalog) != nil
	}

	/// The installed version, as its source lists it.
	private func installedVersion(of install: InstallRecord, in catalog: Catalog) -> (offer: Catalog.Offer, version: AppVersion)? {
		guard let offer = Self.listing(of: install, in: catalog),
		      let version = Self.listedVersion(of: install, in: offer.app) else { return nil }
		return (offer, version)
	}

	/// Signs an installed app again with the certificate `certificateID`
	/// and installs it (#17): its installed version downloaded again from
	/// its source, or for an app installed from an IPA, its IPA (#113). It
	/// stays the copy it is, under the App ID it has, unless an Apple ID
	/// signs it as another (#49), with `look`, what was chosen for it in
	/// Custom Install…, else what it has (#155). With `deletingFirst`, it's
	/// deleted right before the install (#96). Atelier signs itself again
	/// as it runs (#24), as it is.
	func signAgain(_ install: InstallRecord, with certificateID: UUID, look: Look? = nil, deletingFirst: Bool = false, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		if SelfUpdate.shared.isOwn(install) {
			enqueue(Self.ownAppJob(isResign: false, certificateID: certificateID, certificates: certificates, context: context))
		} else if Self.isFromIPA(install) {
			fetchIPA(of: install, for: .signAgain(certificateID: certificateID, deletingFirst: deletingFirst, look: look), downloads: downloads, certificates: certificates, context: context)
		} else if let found = installedVersion(of: install, in: catalog) {
			self.install(found.offer.app, version: found.version, sourceURL: found.offer.source.url, as: install.target, displayName: Self.displayName(of: install, look: look), certificateID: certificateID, deletingFirst: deletingFirst, copy: look.map { Self.choice($0, for: install) }, replacing: install, downloads: downloads, certificates: certificates, into: context)
		}
	}

	// MARK: Custom Install's name and icon (#155)

	/// What the user chose for an installed app in Custom Install… (#155),
	/// besides the certificate: its name, its icon, and the rest of what
	/// Advanced has but the App ID, which stays, so the app keeps its data.
	/// Its updates and re-signs keep it.
	struct Look {
		/// The name it's signed with (`CopySettings.signingName`); nil for
		/// its IPA's.
		var name: String?
		var choice: CopyChoice
	}

	/// Whether Custom Install… changes the name and icon of `install` too: any
	/// app's but Atelier's itself, which signs itself as it runs (#24), with
	/// the certificate alone. Its copies' it does.
	static func canChangeLook(of install: InstallRecord) -> Bool {
		let own = SelfUpdate.shared
		return !own.isOwn(install) && !(install.target == .original && own.isOwnApp(install.appBundleID))
	}

	/// What Custom Install's sheet chose for `install` besides the certificate
	/// (#155): its name as `CopySettings.signingName` makes it, and the
	/// rest. Nil for Atelier itself, which signs itself as it is (#24).
	private static func look(_ answer: CopyAnswer, for install: InstallRecord) -> Look? {
		guard canChangeLook(of: install) else { return nil }
		let name = CopySettings.signingName(typed: answer.name, current: install.name, chosen: install.copySettings?.name, isCopy: install.target != .original)
		return Look(name: name, choice: answer.choice)
	}

	/// What `look` signs `install` with: a copy stays under the bundle ID
	/// it's installed as, and the app itself under its own, with the name
	/// chosen for it.
	private static func choice(_ look: Look, for install: InstallRecord) -> CopyChoice {
		var choice = look.choice
		if install.target == .original {
			choice.settings.bundleID = nil
			choice.settings.name = look.name
		} else {
			choice.settings.bundleID = install.copySettings?.bundleID
			// A copy's name is its Library entry's.
			choice.settings.name = nil
		}
		return choice
	}

	/// The icon of `install` without the tint or picture chosen for it, for
	/// the pictures of new ones (#155): its own, kept when it was signed
	/// with them, else the one iOS shows while it has none. Else, for an
	/// app signed with them before Atelier kept its own, its app's, as iOS
	/// shows it while that has none; nil when Atelier doesn't have it, for
	/// its source's.
	static func ownIconURL(of install: InstallRecord, in context: ModelContext) -> URL? {
		if let own = InstalledIcons.own.url(for: install.bundleID) { return own }
		if install.copySettings?.changesIcon != true, let icon = InstalledIcons.shared.url(for: install.bundleID) { return icon }
		guard install.target != .original, let app = InstalledApps.record(install.appBundleID, in: context), app.copySettings?.changesIcon != true else { return nil }
		return InstalledIcons.shared.url(for: app.bundleID)
	}

	// MARK: Kept data (#96)

	/// Whether an app's data waits to be put back: kept, and not by Put
	/// Back or an install running for it now, which puts it back itself.
	func dataWaits(for bundleID: String) -> Bool {
		guard keptData.contains(bundleID) else { return false }
		let putBack = Self.putBackID(bundleID)
		if currentID == putBack || waiting.contains(where: { $0.id == putBack }) { return false }
		if isRunning, case .installing(let info, _)? = state, info.bundleID == bundleID { return false }
		return true
	}

	private static func putBackID(_ bundleID: String) -> String {
		"put back \(bundleID)"
	}

	/// When the app's kept data was copied, and how much it holds.
	func keptDataInfo(of bundleID: String) -> KeptAppData? {
		(try? AppDataStore.standard())?.kept(bundleID)
	}

	/// Whether Put Back can start: it waits for no install, so none waits
	/// for it in turn while the user looks at its result. Observed.
	var canPutBack: Bool {
		currentID == nil && waiting.isEmpty && !isRunning
	}

	/// Put Back: puts the app's kept data back into it through Direct
	/// installs, replacing what it has saved since.
	func putBackData(of install: InstallRecord, iconURL: URL?, in context: ModelContext, certificates: CertificatesModel) {
		enqueue(Job(id: Self.putBackID(install.bundleID), title: install.name, iconURL: iconURL, input: .putBack(install.bundleID), certificates: certificates, context: context))
	}

	/// Deletes an app's kept data instead of putting it back, or with the
	/// app's Library entry.
	func deleteKeptData(of bundleID: String) {
		(try? AppDataStore.standard())?.remove(bundleID)
		refreshKeptData()
	}

	/// Re-reads which apps have kept data (#96), such as after the Library
	/// deleted an app.
	func refreshKeptData() {
		let kept = (try? AppDataStore.standard())?.allKept ?? [:]
		keptData = Set(kept.keys)
		disabledApps = kept.filter { $0.value.disabledAt != nil }
	}

	/// Whether signing `install` with `certificateID` means deleting it
	/// first: the certificate's profile is for another App ID (#76), or it
	/// installs the app as another bundle ID, signed with an Apple ID or no
	/// longer with one (#49). Never Atelier, which signs itself for its own
	/// App ID or not at all (#24).
	func needsReinstall(_ install: InstallRecord, signingWith certificateID: UUID, certificates: CertificatesModel) -> Bool {
		guard !SelfUpdate.shared.isOwn(install) else { return false }
		if let account = certificates.appleID(certificateID) {
			return install.bundleID != Self.appleIDBundleID(of: install.ipaBundleID, as: install.target, account: account)
		}
		guard let certificate = certificates.certificates.first(where: { $0.id == certificateID }) else { return false }
		// A copy keeps a bundle ID of the user's choosing (#113).
		if install.bundleID != InstalledApps.bundleID(of: install.target, for: install.ipaBundleID) { return true }
		return install.signedIdentity.needsReinstall(signingFor: certificate.profile.applicationIdentifier)
	}

	// MARK: Re-signing (#20)

	/// What re-signing an app whose certificate died signs.
	enum ResignSource {
		/// Its installed version, downloaded again from its source.
		case installedVersion(Catalog.Offer, AppVersion)
		/// Its source's newest version, as the source no longer lists the
		/// installed one.
		case newerVersion(Catalog.Offer, AppVersion)
		/// Atelier itself, as it runs (#24).
		case runningApp
		/// The IPA it was installed from, downloaded again from its link,
		/// or one the user points to (#113).
		case ipa
	}

	/// What re-signing `install` signs: its installed version from its
	/// source, else its source's newest version; Atelier as it runs; the
	/// IPA of an app installed from one. Nil when there's nothing to sign.
	func resignSource(of install: InstallRecord, in catalog: Catalog) -> ResignSource? {
		if SelfUpdate.shared.isOwn(install) { return .runningApp }
		if Self.isFromIPA(install) { return .ipa }
		if let found = installedVersion(of: install, in: catalog) { return .installedVersion(found.offer, found.version) }
		if let offer = Self.listing(of: install, in: catalog), let newest = offer.app.availability().version {
			return .newerVersion(offer, newest)
		}
		return nil
	}

	/// Signs an app whose certificate died again with `certificateID` and
	/// installs it over the old one, from what `resignSource` says. With
	/// `deletingFirst`, the old one is deleted right before, through Direct
	/// installs, as iOS can't replace it with one signed for another App ID,
	/// its data copied aside first unless `keepingData` is false (#96).
	/// Returns the install's ID, nil when there's nothing to sign, or when
	/// it isn't queued yet: an app's IPA from its link, or one it asks for
	/// (#113).
	@discardableResult
	func resign(_ install: InstallRecord, with certificateID: UUID, deletingFirst: Bool, keepingData: Bool = true, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) -> String? {
		var job: Job
		switch resignSource(of: install, in: catalog) {
		case .installedVersion(let offer, let version)?, .newerVersion(let offer, let version)?:
			job = Self.sourceJob(offer.app, version: version, sourceURL: offer.source.url, as: install.target, displayName: Self.displayName(of: install), certificateID: certificateID, downloads: downloads, certificates: certificates, context: context)
		case .runningApp?:
			job = Self.ownAppJob(isResign: true, certificateID: certificateID, certificates: certificates, context: context)
		case .ipa?:
			fetchIPA(of: install, for: .resign(certificateID: certificateID, deletingFirst: deletingFirst, keepingData: keepingData), downloads: downloads, certificates: certificates, context: context)
			return nil
		case nil:
			return nil
		}
		job.isResign = true
		job.deletesFirst = deletingFirst
		job.keepsData = keepingData
		job.replacesBundleID = install.bundleID
		enqueue(job)
		return job.id
	}

	/// Signs the app again or installs the request's update (#76), deleting
	/// the app through Direct installs right before the install, with its
	/// data copied aside and put back (#96), as Re-sign does (#20): a
	/// download or signing that fails leaves it as it was.
	func deleteAndReinstall(_ request: ReplaceRequest, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		reinstall(request, deletingFirst: true, in: catalog, downloads: downloads, certificates: certificates, into: context)
	}

	/// Signs again, updates or installs the IPA as the request asks, once
	/// the app was deleted from the Home Screen, or deleting it first.
	func reinstall(_ request: ReplaceRequest, deletingFirst: Bool = false, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		if let ipa = request.ipa {
			var job = Self.ipaJob(ipa, over: request.install, look: request.look, certificateID: request.certificateID)
			job.deletesFirst = deletingFirst
			enqueue(job)
		} else if let update = request.update {
			self.install(update.offer.app, version: update.version, sourceURL: update.offer.source.url, as: request.install.target, displayName: Self.displayName(of: request.install, look: request.look), certificateID: request.certificateID, isUpdate: true, deletingFirst: deletingFirst, copy: request.look.map { Self.choice($0, for: request.install) }, replacing: request.install, downloads: downloads, certificates: certificates, into: context)
		} else {
			signAgain(request.install, with: request.certificateID, look: request.look, deletingFirst: deletingFirst, in: catalog, downloads: downloads, certificates: certificates, into: context)
		}
	}

	/// Whether the request can install a copy instead: of its IPA, the
	/// version its source still lists, or the IPA the app was installed
	/// from (#113).
	func canInstallAsCopy(_ request: ReplaceRequest, in catalog: Catalog) -> Bool {
		request.ipa != nil || copyListing(request, in: catalog) != nil || Self.isFromIPA(request.install)
	}

	/// Whether Custom Install… over `install`, from `request`, can install a
	/// copy instead when the certificate picked is for another App ID, as
	/// the question it asks then offers (#76), for its sheet to say so up
	/// front.
	func canInstallAsCopy(_ install: InstallRecord, from request: CopyRequest, in catalog: Catalog) -> Bool {
		switch request.origin {
		// Of the IPA, or the version installed, else the one listed.
		case .ipa, .listing: true
		case .installed: Self.isFromIPA(install) || installedVersion(of: install, in: catalog) != nil
		}
	}

	/// Installs a new copy next to the app instead, with its own bundle ID
	/// and data (#8), signed with the request's certificate, and with what
	/// was chosen in Custom Install… (#155): its icon and the rest, and the
	/// name, when another was typed there.
	func installAsCopy(_ request: ReplaceRequest, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		// Numbered from its IPA's bundle ID, which the copy is signed as
		// (#116), without the team ID an Apple ID adds (#49).
		let target = InstalledApps.newCopy(of: request.install.ipaBundleID, in: context)
		var choice = request.look?.choice
		choice?.settings.bundleID = nil
		choice?.settings.name = nil
		let name = request.look?.name.flatMap { $0 == request.install.name ? nil : $0 }
		let new = NewCopy(target: target, name: name ?? "", choice: choice, certificateID: request.certificateID)
		if let ipa = request.ipa {
			guard let copy = Self.newCopyJob(ipa, new, appName: request.install.name) else { return drop(ipa) }
			enqueue(copy)
		} else if let found = copyListing(request, in: catalog) {
			self.install(found.offer.app, version: found.version, sourceURL: found.offer.source.url, as: target, displayName: name, certificateID: request.certificateID, copy: choice, downloads: downloads, certificates: certificates, into: context)
		} else if Self.isFromIPA(request.install) {
			fetchIPA(of: request.install, for: .newCopy(new), downloads: downloads, certificates: certificates, context: context)
		}
	}

	/// Cancel in the question: an IPA it was for isn't installed after all.
	func dismiss(_ request: ReplaceRequest) {
		replaceRequests.removeAll { $0.id == request.id }
		if let ipa = request.ipa { drop(ipa) }
	}

	private func copyListing(_ request: ReplaceRequest, in catalog: Catalog) -> (offer: Catalog.Offer, version: AppVersion)? {
		request.update ?? installedVersion(of: request.install, in: catalog)
	}

	/// Atelier signed again as it runs, and installed over itself (#24):
	/// Custom Install…, or Re-sign as its certificate dies.
	private static func ownAppJob(isResign: Bool, certificateID: UUID?, certificates: CertificatesModel, context: ModelContext) -> Job {
		let own = SelfUpdate.shared
		var job = Job(
			id: isResign ? "re-sign Atelier" : "sign again Atelier",
			title: own.name,
			iconURL: own.iconURL,
			app: own.appKey,
			certificateID: certificateID,
			originalBundleID: SelfUpdate.sourceBundleID,
			input: .ownApp,
			certificates: certificates,
			context: context
		)
		job.isResign = isResign
		return job
	}

	/// Whether a failed install history entry can be tried again: what it
	/// installed is still there.
	func canTryAgain(_ attempt: InstallAttempt, catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) -> Bool {
		job(retrying: attempt, catalog: catalog, downloads: downloads, certificates: certificates, context: context) != nil
	}

	/// Tries a failed install history entry again.
	func tryAgain(_ attempt: InstallAttempt, catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		guard let job = job(retrying: attempt, catalog: catalog, downloads: downloads, certificates: certificates, context: context) else { return }
		enqueue(job)
	}

	/// The install a failed attempt ran, while what it installed is still
	/// there: the source still lists that version, the download is still in
	/// Downloads, or the picked file's copy is still kept. Signed copies of
	/// apps were kept until 29 Oct 2026, so attempts that installed one
	/// can't run again.
	private func job(retrying attempt: InstallAttempt, catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) -> Job? {
		guard attempt.result == .failed, let origin = attempt.origin else { return nil }
		switch origin {
		case .source(let sourceURL, let appID, let version, let copy, let displayName, let certificateID):
			guard let entry = catalog.entry(id: appID) else { return nil }
			let offer: Catalog.Offer?
			if let sourceURL {
				offer = entry.offers.first { $0.source.url == sourceURL }
			} else {
				offer = entry.preferred
			}
			guard let offer, let listed = offer.app.versions.first(where: { $0.version == version }) else { return nil }
			return Self.sourceJob(offer.app, version: listed, sourceURL: offer.source.url, as: copy.map { InstallTarget.copy($0) } ?? .original, displayName: displayName, certificateID: certificateID, downloads: downloads, certificates: certificates, context: context)
		case .download(let id):
			guard let download = downloads.download(id: id), download.status == .finished else { return nil }
			return Self.downloadJob(download, from: downloads, certificates: certificates, context: context)
		case .picked(let name):
			let file = Self.installsFolder.appending(path: name)
			guard FileManager.default.fileExists(atPath: file.path) else { return nil }
			return Job(id: "picked \(name)", title: attempt.name, input: .picked(file), certificates: certificates, context: context)
		case .signed:
			return nil
		case .signedAgain(let bundleID, _, let certificateID):
			// Atelier signs itself again as it runs (#24).
			guard bundleID == SelfUpdate.shared.bundleID else { return nil }
			return Self.ownAppJob(isResign: false, certificateID: certificateID, certificates: certificates, context: context)
		}
	}

	/// Lists the apps on this iPhone through Direct installs (#17), connecting
	/// LocalDevVPN first when `startingVPN` and it's off, and notes which of
	/// Atelier's apps are still there and their versions. Returns why it
	/// couldn't.
	@discardableResult
	func scanDevice(into context: ModelContext, startingVPN: Bool = true) async -> String? {
		if case .unavailable(let why) = await pairingInstaller.check(startingVPN: startingVPN) { return why }
		do {
			let apps = try await pairingInstaller.installedApps()
			let scan = DeviceScan(versions: Dictionary(apps.map { ($0.bundleID, $0.version) }, uniquingKeysWith: { first, _ in first }))
			DeviceScanStore.shared.save(scan)
			InstalledApps.apply(scan, in: context)
			return nil
		} catch {
			return InstallProblem(error).message
		}
	}

	/// The user's apps and the provisioning profiles on this iPhone, through
	/// Direct installs, connecting LocalDevVPN first when `startingVPN` and
	/// it's off: which apps hold a free Apple ID's 3 places (#49).
	func appsAndProfiles(startingVPN: Bool) async throws -> AppsAndProfiles {
		if case .unavailable(let why) = await pairingInstaller.check(startingVPN: startingVPN) { throw InstallProblem(why) }
		return try await pairingInstaller.appsAndProfiles()
	}

	/// Puts an app's new profile on this iPhone through Direct installs, in
	/// place of the ones with `replacing` UUIDs, which it returns once taken
	/// off: the weekly renewal of an Apple ID's apps (#49). Assumes
	/// `appsAndProfiles` just reached iOS.
	func installProfile(_ profile: Data, replacing uuids: [String]) async throws -> [String] {
		try await pairingInstaller.installProfile(profile, replacing: uuids)
	}

	/// Takes these profiles off this iPhone, for Test Actions' End an App's
	/// Profile (#49).
	func removeProfiles(_ uuids: [String]) async throws -> [String] {
		try await pairingInstaller.removeProfiles(uuids)
	}

	// MARK: After iOS didn't install the app (#76)

	/// The certificate the failed install signed with, so it isn't offered
	/// again.
	var failedCertificateID: UUID? {
		guard case .failed = state else { return nil }
		return signedWith
	}

	/// The certificate Atelier last installed the failed app with, which
	/// signs for the App ID iOS has; nil when Atelier didn't install it.
	var installedCertificateID: UUID? {
		guard case .failed = state, let job = retryJob else { return nil }
		if let signedAs { return InstalledApps.record(signedAs.bundleID, in: job.context)?.certificateID }
		// Not signed yet: the source app, which its IPA may not be (#116).
		guard let listed = job.app?.bundleID else { return nil }
		return InstalledApps.record(listedAs: listed, as: job.target, in: job.context)?.certificateID
	}

	/// Installs the app that iOS didn't install again, signed with
	/// `certificateID`: iOS replaces an app it has only with one signed for
	/// the same App ID, so the certificate it was installed with works.
	/// `newAppIDAsked` when it was picked from a list that said another
	/// free Apple ID takes a new App ID (#49), so the install doesn't ask.
	func installWithCertificate(_ certificateID: UUID, newAppIDAsked: Bool = false) {
		guard var job = retryJob, !isRunning else { return }
		retryJob = nil
		job.certificateID = certificateID
		job.certificatePicked = true
		job.newAppIDAsked = newAppIDAsked
		job.signedApp = nil
		enqueue(job)
	}

	/// The copy "Install as a Copy" installs: the next one after those
	/// Atelier installed, and after the app iOS didn't replace. Nil when
	/// the failed install can't be signed as a copy: a copy already,
	/// Atelier's own (#24), or before it was signed, unless what's on this
	/// iPhone stopped it (#99).
	var copyTarget: InstallTarget? {
		guard let job = retryJob else { return nil }
		if let identity = signedAs {
			return Self.copyTarget(of: job, original: identity.originalBundleID, installed: identity.bundleID)
		}
		guard case .failed(let problem)? = state, let conflict = problem.conflict else { return nil }
		return Self.copyTarget(of: job, original: conflict.bundleID, installed: conflict.bundleID)
	}

	/// The copy `job` can install as, next to `installed`, the app with the
	/// bundle ID `original` on this iPhone; nil when it can't be one.
	private static func copyTarget(of job: Job, original: String, installed: String) -> InstallTarget? {
		guard !job.isSelf, job.target == .original else { return nil }
		switch job.input {
		case .picked, .download, .source: break
		case .putBack, .disable, .ownApp: return nil
		}
		return InstalledApps.newCopy(of: original, in: job.context, besides: [installed])
	}

	/// `job` as a new copy, with its own bundle ID and data (#8).
	private static func copy(_ job: Job, as target: InstallTarget) -> Job? {
		guard case .copy(let number) = target else { return nil }
		var copy = job
		copy.id = "\(job.id) (copy \(number))"
		copy.title = "\(job.title) (copy \(number))"
		copy.target = target
		copy.signedApp = nil
		return copy
	}

	/// Installs the app that iOS didn't install as a new copy, next to the
	/// one already there, with its own bundle ID and data (#8).
	func installAsCopy() {
		guard let job = retryJob, let target = copyTarget, let copy = Self.copy(job, as: target), !isRunning else { return }
		retryJob = nil
		enqueue(copy)
	}

	/// Installs again an app whose install couldn't be confirmed, or tries
	/// again one that failed.
	func installAgain() {
		guard let retryJob, !isRunning else { return }
		self.retryJob = nil
		enqueue(retryJob)
	}

	/// What's on this iPhone that iOS didn't replace with the failed install
	/// (#99), when that's what stopped it.
	var failedConflict: InstalledConflict? {
		guard case .failed(let problem)? = state, retryJob != nil else { return nil }
		return problem.conflict
	}

	/// Deletes the app on this iPhone that iOS didn't replace with the
	/// failed install, and installs that one in its place (#99): with the
	/// app's data when iOS lets Atelier copy it (#96), and without signing
	/// it again when it was signed.
	func deleteAndInstall() {
		guard var job = retryJob, let conflict = failedConflict, !isRunning else { return }
		retryJob = nil
		job.deletesFirst = true
		job.keepsData = conflict.keepsData
		job.deletesUnlisted = conflict.signer == .unlisted
		job.signedApp = refusedApp
		refusedApp = nil
		enqueue(job)
	}

	/// `next`: to run right after the running install, in its place, which
	/// may have its id (#99).
	private func enqueue(_ job: Job, next: Bool = false) {
		// What the user asks for goes ahead of the installs carried over.
		if !job.carriedOver, !job.automatic { stepAside(for: job.id) }
		// As it came, for Install a Copy… instead (#113).
		let queued = job
		var job = job
		// What was chosen for the app it takes the place of goes with it,
		// also when it installs as another bundle ID, which `CopyStore`
		// doesn't keep it by: signed with an Apple ID, or no longer with
		// one (#49, #155).
		if job.copyChoice == nil, let old = job.replacesBundleID, let replaced = InstalledApps.record(old, in: job.context), let settings = replaced.copySettings {
			job.copyChoice = CopyChoice(settings: settings, picture: CopyStore.shared.picture(for: replaced.numberedBundleID))
		}
		// Atelier's own IPA, from anywhere, installs over Atelier (#24).
		if !job.isSelf, let version = Self.ownVersion(of: job) {
			job = Self.ownInstall(job, version: version)
		}
		if job.isSelf {
			// It closes Atelier: never by itself, and one at a time.
			guard !job.automatic, !hasSelfInstall else { return }
			if var request = selfRequest(for: &job) {
				if !queued.isSelf, queued.isIPA { request.copyJob = queued }
				selfRequests.append(request)
				return
			}
		}
		failures[job.id] = nil
		dataFailures[job.id] = nil
		if !isRunning, queue.isEmpty {
			state = .checking
			log = []
			limits = []
			permissions = nil
			upgradeProblem = nil
		}
		// The queue starts it in a task of its own, after this. Put Back
		// isn't an install, for the system's bar and the notification, and
		// Atelier's own install closes Atelier and the bar with it (#24).
		if (next ? queue.enqueueNext(job) : queue.enqueue(job)), !job.isChore {
			if job.isSelf {
				// Not in the system's bar.
			} else if case .source(let source) = job.input, job.target == .original {
				BackgroundInstalls.shared.queued(id: job.id, name: source.app.name, version: source.version.displayVersion, isUpdate: job.isUpdate, isResign: job.isResign, automatic: job.automatic)
			} else {
				BackgroundInstalls.shared.queued(id: job.id, name: job.title, isUpdate: job.isUpdate, isResign: job.isResign, automatic: job.automatic)
			}
			// A direct install may still be running once the iPhone locks.
			if job.automatic || job.deletesFirst || BackgroundInstalls.shared.mayInstallDirectly {
				HeldSecrets.shared.hold(certificate: job.certificateID ?? job.certificates.defaultID, from: job.certificates)
			}
			// Its download starts now, while Atelier is in front, as Update
			// All's do: started once its checks pass, it may start with
			// Atelier in the background, which iOS can put off, as it did
			// Reinstall's (6 Nov 2026). Atelier's own downloads when its turn
			// comes, last (#24).
			if !job.isSelf, case .source(let source) = job.input, UIApplication.shared.applicationState == .active {
				source.start()
			}
		}
	}

	/// Takes a waiting install off the queue.
	func remove(_ job: Job) {
		queue.remove(job.id)
		selfRequests.removeAll { $0.id == job.id }
		drop(job)
		// The download it started as it was queued goes with it.
		if job.id != currentID, case .source(let source) = job.input { source.discard() }
		BackgroundInstalls.shared.removed(id: job.id)
	}

	/// Cancels the running install, unless iOS has Atelier's own already
	/// and installs it once Atelier closes (#24).
	func cancel() {
		guard selfHandover == nil else { return }
		queue.cancelCurrent()
	}

	/// Adds a line to the running install's log, such as what became of the
	/// system's progress bar (#72).
	func note(_ line: String) {
		log.append(line)
	}

	/// Stops the queue, as the Library's Cancel All does, from the system's
	/// bar (#72): the waiting installs and their unfinished downloads, then
	/// the running install.
	func cancelAll() {
		for job in waiting {
			remove(job)
			if case .source(let source) = job.input, let id = source.downloadID, source.downloads.download(id: id)?.status == .downloading {
				source.downloads.remove(id)
			}
		}
		cancel()
	}

	/// What's done of the running step's file, for the system's bar (#72):
	/// the download's bytes, or the signed app's while route A uploads it.
	var stageBytes: (done: Int64, total: Int64)? {
		switch state {
		case .downloading?:
			guard case .source(let source)? = shownJob?.input, let id = source.downloadID,
			      let progress = source.downloads.progress[id], let expected = progress.expected else { return nil }
			return (progress.received, expected)
		case .installing(_, .downloading(let fraction))?:
			guard let packageSize else { return nil }
			return (Int64(Double(packageSize) * fraction), packageSize)
		default:
			return nil
		}
	}

	/// Whether the running install's iOS alert closed without installing.
	var alertClosed: Bool {
		if case .installing(_, .alertClosed) = state { return true }
		return false
	}

	/// Shows the iOS alert again for the app already signed (#51).
	func retryAlert() {
		guard alertClosed else { return }
		Task { await localServerInstaller.retryAlert() }
	}

	/// Ends the install whose iOS alert closed, as not started, and closes
	/// its status; the next waiting install, if any, starts.
	func giveUpAlert() {
		guard alertClosed else { return }
		gaveUpAlert = true
		localServerInstaller.giveUpAlert()
	}

	/// Closes the status of an install that has ended: by its ✕, a swipe,
	/// or by itself after a while.
	func reset() {
		guard !isRunning, queue.isEmpty else { return }
		barHidden = false
		state = nil
		log = []
		limits = []
		permissions = nil
		upgradeProblem = nil
		dataNotPutBack = false
		selfNote = nil
		shownJob = nil
		retryJob = nil
		lastMakeRoom = nil
		dropKeptDownload()
		dropKeptPicked()
		dropRefusedApp()
	}

	/// The copy of a picked file whose install failed in a way trying again
	/// may fix (#17), or that iOS may not have installed. It's kept while
	/// the failure or the status shows, for Try again or Install again, as
	/// an unconfirmed install's download is; then it's deleted.
	@ObservationIgnored private var keptPicked: URL?

	private func dropKeptPicked() {
		guard let file = keptPicked else { return }
		keptPicked = nil
		try? FileManager.default.removeItem(at: file)
	}

	/// Deletes the download kept after an unconfirmed install.
	private func dropKeptDownload() {
		guard let kept = keptDownload else { return }
		keptDownload = nil
		kept.manager.remove(kept.id)
	}

	private static func jobID(_ download: Download) -> String {
		jobID(download.id)
	}

	private static func jobID(_ downloadID: UUID) -> String {
		"download \(downloadID.uuidString)"
	}

	/// Removes an app from this iPhone through the pairing file (#9),
	/// connecting LocalDevVPN first when it's off. Returns why it couldn't.
	func uninstall(bundleID: String) async -> String? {
		if case .unavailable(let why) = await pairingInstaller.check(startingVPN: true) { return why }
		do {
			try await pairingInstaller.uninstall(bundleID)
			return nil
		} catch {
			return InstallProblem(error).message
		}
	}

	/// Deletes the app installed as `bundleID` right before an app signed
	/// for another App ID is installed in its place (#20). Nothing to do
	/// when it's gone already, such as deleted from the Home Screen, unless
	/// `evenUnlisted`: an app installd lists nowhere, such as an offloaded
	/// one, which iOS's refusal showed is there (#99).
	/// Returns why it couldn't.
	private func deleteBeforeReplacing(_ bundleID: String, evenUnlisted: Bool = false, in context: ModelContext) async -> String? {
		if !evenUnlisted, let apps = try? await pairingInstaller.installedApps(), !apps.contains(where: { $0.bundleID == bundleID }) { return nil }
		if let problem = await uninstall(bundleID: bundleID) { return problem }
		// It's gone, so its App ID no longer stands in the way, should the
		// install fail and be tried again.
		if let record = InstalledApps.record(bundleID, in: context) {
			record.applicationIdentifier = nil
			try? context.save()
		}
		return nil
	}

	/// Notes an app's Home Screen spot before it's deleted to be installed
	/// again, and puts the new install there, while Settings › Home Screen
	/// › Keep apps’ spots is on (5 and 9 Nov 2026).
	private var homeScreenSpots: HomeScreenSpots {
		HomeScreenSpots(installer: pairingInstaller)
	}

	/// Copies an app's data aside before it's deleted to be installed again,
	/// and back into its new install, through Direct installs (#96).
	private var dataKeeper: AppDataKeeper? {
		guard let store = try? AppDataStore.standard() else { return nil }
		let pairing = pairingInstaller
		return AppDataKeeper(.init(
			store: store,
			isInstalled: { await pairing.isInstalled($0) },
			copyOut: { bundleID, folder, log, progress in
				try await pairing.copyAppData(of: bundleID, to: folder, freeSpace: Self.freeSpace, log: log, progress: progress)
			},
			copyBack: { bundleID, folder, log, progress in
				try await pairing.restoreAppData(of: bundleID, from: folder, log: log, progress: progress)
			}
		))
	}

	/// The check scheme the app signed now gets: one no installed app
	/// registers, no Library entry holds if there's one, and never an
	/// offloaded app's, which would then read as installed (12 Nov 2026).
	private func freeCheckScheme(in context: ModelContext) -> String? {
		let records = (try? context.fetch(FetchDescriptor<InstallRecord>())) ?? []
		let held = Set(records.compactMap(\.checkScheme))
		let kept = Set(records.filter { disabledApps[$0.bundleID] != nil }.compactMap(\.checkScheme))
		return InstallCheck.freeScheme(isRegistered: { Self.isRegistered($0) }, held: held, kept: kept)
	}

	/// Whether an installed app registers `scheme`. canOpenURL is deprecated
	/// in iOS 27 but still answers for declared schemes, and nothing else
	/// tells a sandboxed app that an app is installed (#11).
	static func isRegistered(_ scheme: String) -> Bool {
		guard let url = URL(string: "\(scheme)://") else { return false }
		return UIApplication.shared.canOpenURL(url)
	}

	/// Whether an app Atelier installed is still on this iPhone (#55).
	/// Atelier itself is: it's running (#24).
	static func presence(of install: InstallRecord) -> AppPresence {
		if SelfUpdate.shared.isOwn(install) { return .installed }
		return install.presence(isRegistered: isRegistered, scan: DeviceScanStore.shared.scan)
	}

	/// Opens an installed app: by its bundle ID, else through its check
	/// scheme (#55, `AppOpener`).
	static func open(_ install: InstallRecord) {
		AppOpener.shared.open(install)
	}

	// MARK: Atelier's own install (#24)

	/// The version a job installs when what it installs is Atelier: as its
	/// source shows it, and as its Info.plist says it. Nil for other apps.
	private static func ownVersion(of job: Job) -> (display: String, version: String, build: String?)? {
		let own = SelfUpdate.shared
		// A copy of Atelier is another app, with a bundle ID of its own,
		// unless it's the one running (#113).
		guard job.target == .original || job.target == own.target else { return nil }
		switch job.input {
		case .source(let source):
			guard own.isOwnApp(source.app.bundleID) else { return nil }
			return (source.version.displayVersion, source.version.version, source.version.buildVersion)
		case .download(let download, let downloads):
			// Its bundle ID is known once it's downloaded, from a source before.
			guard download.bundleID.isEmpty || own.isOwnApp(download.bundleID), let file = downloads.fileURL(for: download.id) else { return nil }
			return ownVersion(ofIPA: file, display: download.displayVersion)
		case .picked(let file):
			return ownVersion(ofIPA: file)
		case .ownApp:
			return (own.version, own.version, own.build)
		case .putBack, .disable:
			return nil
		}
	}

	/// The version of an IPA of Atelier, as `display` names it when given;
	/// nil for any other app's.
	private static func ownVersion(ofIPA file: URL, display: String = "") -> (display: String, version: String, build: String?)? {
		guard let info = try? IPAInfo.read(ipaAt: file), SelfUpdate.shared.isOwnApp(info.bundleID) else { return nil }
		return (display.isEmpty ? info.version : display, info.version, info.buildVersion)
	}

	/// Makes a job Atelier's own install: it installs over Atelier, as the
	/// bundle ID Atelier runs as, after every other install.
	private static func ownInstall(_ job: Job, version: (display: String, version: String, build: String?)) -> Job {
		let own = SelfUpdate.shared
		var job = job
		job.isSelf = true
		job.app = own.appKey
		job.iconURL = job.iconURL ?? own.iconURL
		job.target = .original
		job.displayName = nil
		job.deletesFirst = false
		job.selfVersion = version
		job.selfKind = selfKind(of: job, version: version)
		job.isUpdate = job.selfKind == .update
		return job
	}

	private static func selfKind(of job: Job, version: (display: String, version: String, build: String?)) -> PendingSelfInstall.Kind {
		if job.isResign { return .resign }
		if case .ownApp = job.input { return .signAgain }
		let own = SelfUpdate.shared
		return version.version == own.version && version.build == own.build ? .install : .update
	}

	/// Whether Atelier's own install is asked about, waiting or running.
	private var hasSelfInstall: Bool {
		!selfRequests.isEmpty || queue.current?.isSelf == true || queue.pending.contains(where: \.isSelf)
	}

	/// What to ask before Atelier's own install is queued, having picked
	/// the certificate it signs with for Atelier's App ID; nil once the
	/// user said to go ahead.
	private func selfRequest(for job: inout Job) -> SelfRequest? {
		let own = SelfUpdate.shared
		if let version = job.selfVersion, UpdateCheck.isOlder(version.version, build: version.build, than: own.version, build: own.build) {
			return SelfRequest(job: job, kind: .older, certificateName: nil)
		}
		let resigning = job.selfKind == .resign
		let picked = resigning || job.selfKind == .signAgain ? job.certificateID : nil
		guard let signer = own.signer(picked: picked, resigning: resigning, certificates: job.certificates, context: job.context) else {
			// A free Apple ID installed it, whose certificate can't be
			// imported (#152).
			let needsAppleID = picked == nil && own.needsAppleID(in: job.certificates) != nil
			return SelfRequest(job: job, kind: needsAppleID ? .needsAppleID : .noCertificate, certificateName: nil)
		}
		job.certificateID = signer.id
		switch signer {
		case .certificate(let choice):
			job.usesInstalledProfile = choice.usesInstalledProfile
			if job.selfConfirmed { return nil }
			return SelfRequest(job: job, kind: .confirm, certificateName: job.certificate?.displayName)
		case .appleID(let account):
			// With its own profile from Apple, for the App ID it runs as.
			job.usesInstalledProfile = false
			let use = OwnAppleID.appIDUse(for: own.bundleID, account: account)
			if case .noneLeft(let until) = use {
				return SelfRequest(job: job, kind: .noAppIDLeft(until: until), certificateName: nil, appleID: account.displayName, appIDUse: use)
			}
			if job.selfConfirmed { return nil }
			return SelfRequest(job: job, kind: .confirm, certificateName: nil, appleID: account.displayName, appIDUse: use)
		}
	}

	/// Goes ahead with Atelier's own install, as the user said.
	func confirmSelf(_ request: SelfRequest) {
		selfRequests.removeAll { $0.id == request.id }
		guard request.kind == .confirm else { return }
		var job = request.job
		job.selfConfirmed = true
		enqueue(job)
	}

	/// Drops Atelier's own install the user said no to, or that can't run.
	func dismissSelf(_ request: SelfRequest) {
		selfRequests.removeAll { $0.id == request.id }
	}

	/// How many installs run before Atelier's own: "It starts once the 2
	/// installs in progress have finished."
	var installsAhead: Int {
		let running = currentID != nil && queue.current?.isSelf != true ? 1 : 0
		return running + waiting.filter { !$0.isSelf }.count
	}

	/// Whether iOS has Atelier's own install, which it installs once
	/// Atelier closes.
	var isHandingOver: Bool {
		selfHandover != nil
	}

	/// What the install bar says meanwhile, under "Go to the Home Screen":
	/// "to finish updating Atelier" (#123).
	var handoverLine: String? {
		selfHandover.map { PendingSelfInstall.finishing($0, appName: SelfUpdate.shared.name) }
	}

	/// What's left for the user while Atelier's own install waits for
	/// Atelier to leave the screen (#123).
	enum LeaveStep: Equatable {
		/// iOS has the build.
		case handover
		/// iOS's alert closed before iOS asked for the build.
		case alertClosed
	}

	/// Set while Atelier's own install waits for Atelier to leave the
	/// screen: the install bar's sheet then says to go to the Home Screen,
	/// coming up by itself as this is set (#123).
	var leaveStep: LeaveStep? {
		if isHandingOver { return .handover }
		if selfAlertClosedText != nil { return .alertClosed }
		return nil
	}

	/// What the install bar says when iOS's alert for Atelier's own install
	/// closed and iOS didn't ask for it yet: iOS may wait for Atelier to
	/// leave the screen first.
	var selfAlertClosedText: String? {
		guard alertClosed, let job = shownJob, job.isSelf else { return nil }
		return "If you tapped Install, go to the Home Screen to finish \(Self.doing(job.selfKind))."
	}

	private static func doing(_ kind: PendingSelfInstall.Kind) -> String {
		switch kind {
		case .update: "updating"
		case .install: "installing"
		case .signAgain: "signing it again"
		case .resign: "re-signing"
		}
	}

	/// What Atelier's row says while its own install waits for every other
	/// install: "Downloaded, updates last".
	static func goesLast(_ kind: PendingSelfInstall.Kind, downloaded: Bool) -> String {
		switch kind {
		case .update: downloaded ? "Downloaded, updates last" : "Updates last"
		case .install: downloaded ? "Downloaded, installs last" : "Installs last"
		case .signAgain: "Signs again last"
		case .resign: "Re-signs last"
		}
	}

	/// Right before iOS gets Atelier's own install. Installs queued while it
	/// was signed go first, as it closes Atelier: it goes back in the queue
	/// behind them. Otherwise it's noted for Atelier's next launch, as iOS
	/// may close Atelier any moment from now. Those carried over on
	/// `installWhenDownloaded` don't hold it up: they stay on the list, for
	/// Atelier's next launch.
	fileprivate func selfInstallStarts(_ job: Job, package: InstallPackage, route: InstallRoute) throws {
		if queue.pending.contains(where: { !$0.isSelf && !$0.carriedOver }) {
			deferredSelf = job.id
			queue.requeueCurrent()
			throw SelfInstallDeferred()
		}
		for other in waiting where other.carriedOver {
			remove(other)
			if let id = other.downloadID { installWhenDownloaded.insert(id) }
		}
		// It ran, however it ends, so it isn't waited on any more (see `run`):
		// else Atelier, closed before `run` gets there, would install it
		// again on its next launch.
		if let id = job.downloadID { installWhenDownloaded.remove(id) }
		// For the sheet that says to go to the Home Screen once iOS has it.
		Task { selfNotifies = await Self.mayNotify() }
		let own = SelfUpdate.shared
		let info = package.info
		// Or the Apple ID it's one of the apps of, when that signs it (#152),
		// which Install History names as for any app it signs.
		let certificateName = job.certificate?.displayName ?? job.appleID?.displayName
		var sourceURL: URL?
		if case .source(let source) = job.input { sourceURL = source.sourceURL }
		selfPending = PendingSelfInstall(
			token: selfToken ?? "",
			kind: job.selfKind,
			fromVersion: own.version,
			fromBuild: own.build,
			version: info.version,
			build: info.buildVersion,
			displayVersion: job.selfVersion?.display ?? info.version,
			certificateID: signedWith,
			certificateName: certificateName,
			sourceURL: sourceURL,
			downloadID: job.downloadID,
			permissions: permissions?.encoded(),
			limits: limits.isEmpty ? nil : limits,
			attempt: InstallAttempt(
				bundleID: info.bundleID,
				name: job.title,
				version: info.version,
				certificate: certificateName,
				route: route,
				startedAt: runStartedAt,
				finishedAt: .now,
				result: .unconfirmed,
				limits: limits.isEmpty ? nil : limits,
				log: log,
				origin: job.origin
			)
		)
		saveSelfPending()
	}

	/// iOS has Atelier's own install, and installs it once Atelier closes:
	/// everything is saved, a sheet and the install bar say to go to the
	/// Home Screen (#123), and Atelier closes as soon as it leaves the
	/// screen.
	fileprivate func handOver(_ job: Job) {
		guard selfHandover == nil else { return }
		selfHandover = job.selfKind
		log.append("iOS has \(SelfUpdate.shared.name): it closes once it leaves the screen, for iOS to install it")
		try? job.context.save()
		UserDefaults.standard.synchronize()
		saveSelfPending()
		if UIApplication.shared.applicationState == .background {
			closeForIOS()
			return
		}
		// What says how it went, in case iOS closes Atelier before it leaves
		// the screen: the download is kept ahead while Atelier is in front,
		// and the notification is timed again as it closes.
		if let selfPending { SelfInstallNotice.shared.leave(for: selfPending, appName: SelfUpdate.shared.name) }
		closesInBackground = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.closeForIOS() }
		}
	}

	/// Keeps Atelier's own install showing until Atelier closes.
	fileprivate func waitForClose() async throws {
		while true { try await Task.sleep(for: .seconds(60)) }
	}

	/// Closes Atelier for iOS to install over it, its note for the next
	/// launch saved with the log as it stands. iOS won't install over an app
	/// that's running, and has no way for an app to quit, hence exit. Once
	/// iOS has what says how it went while Atelier isn't running, which the
	/// log then lists.
	private func closeForIOS() {
		log.append("closing \(SelfUpdate.shared.name) for iOS to install it, leaving a background relaunch and a notification with iOS to say how it went")
		saveSelfPending()
		guard let selfPending else { exit(0) }
		SelfInstallNotice.shared.leaveAsItCloses(for: selfPending, appName: SelfUpdate.shared.name) { [weak self] left in
			self?.log += left
			self?.saveSelfPending()
			exit(0)
		}
	}

	/// Atelier's own install ended with Atelier still running: iOS didn't
	/// take it, or it was cancelled before iOS had it.
	fileprivate func selfInstallEnded() {
		selfHandover = nil
		selfPending = nil
		if let closesInBackground { NotificationCenter.default.removeObserver(closesInBackground) }
		closesInBackground = nil
		(try? PendingSelfInstallStore.standard())?.remove()
		// Atelier runs, so the install bar says how it went.
		SelfInstallNotice.shared.installEnded()
	}

	/// Whether Atelier may send notifications, banners or not.
	private static func mayNotify() async -> Bool {
		let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
		return [.authorized, .provisional, .ephemeral].contains(status)
	}

	/// Writes Atelier's own install's note, with the log as it stands.
	private func saveSelfPending() {
		guard var pending = selfPending else { return }
		pending.attempt.log = log
		pending.attempt.finishedAt = .now
		selfPending = pending
		do {
			try PendingSelfInstallStore.standard().save(pending)
		} catch {
			log.append("couldn't note the install for \(SelfUpdate.shared.name)'s next launch: \(error.localizedDescription)")
		}
	}

	/// iOS didn't take Atelier's own install while Atelier ran: a copy or
	/// another certificate can't replace it, so trying again is what's left.
	private static func selfNotInstalled(_ job: Job) -> InstallProblem {
		let own = SelfUpdate.shared
		return InstallProblem(
			"\(own.name) \(job.selfVersion?.display ?? own.version) wasn't installed.",
			detail: "\(own.name) only installs over itself with a certificate from the account it was installed with, registered for this \(ThisDevice.name). The install log says more.",
			fix: .tryAgain
		)
	}

	/// Atelier's own install, gone back in the queue.
	private struct SelfInstallDeferred: Error {}

	/// Once Atelier's sources are loaded after a relaunch: how the install
	/// of itself that closed Atelier ended, in the install bar. "Updated to
	/// 0.2.0-alpha", or "Wasn't updated: iOS didn't install 0.2.0-alpha."
	/// with Try again.
	func reportRelaunch(catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) {
		guard isIdle, let relaunch = SelfUpdate.shared.takeUnreported() else { return }
		let pending = relaunch.pending
		let own = SelfUpdate.shared
		var job = Self.ownAppJob(isResign: pending.kind == .resign, certificateID: pending.certificateID, certificates: certificates, context: context)
		job.isSelf = true
		job.selfKind = pending.kind
		job.selfVersion = (pending.displayVersion, pending.version, pending.build)
		runCount += 1
		let run = runCount
		switch relaunch.outcome {
		case .installed:
			selfNote = pending.installedNote
			state = .finished(IPAInfo(bundleID: own.bundleID, version: own.version, name: own.name, buildVersion: own.build), .confirmed(version: own.version))
			dismissLater(run, after: Self.successLinger)
		case .notInstalled:
			let message = switch pending.kind {
			case .update: "Wasn't updated: iOS didn't install \(pending.displayVersion)."
			case .install: "Wasn't installed again: iOS didn't install \(pending.displayVersion)."
			case .signAgain: "Wasn't signed again: iOS didn't install it."
			case .resign: "Wasn't re-signed: iOS didn't install it."
			}
			retryJob = selfRetryJob(pending, catalog: catalog, downloads: downloads, certificates: certificates, context: context)
			state = .failed(InstallProblem(message, fix: retryJob == nil ? nil : .tryAgain))
		case .superseded:
			return
		}
		shownJob = job
		// As Install History has it, which may say already what iOS still
		// had once Atelier was in front; else the rest comes in later.
		log = (try? InstallHistory.standard())?.attempts().first { $0.id == pending.attempt.id }?.log ?? pending.endedAttempt(relaunch.outcome).log
		relaunchShown = (run, pending.attempt.id)
		limits = pending.limits ?? []
		permissions = pending.permissions.flatMap(SignedPermissions.decoded(from:))
	}

	/// Lines Atelier's own install got in its log in Install History after
	/// the relaunch, for the install bar while it says how that went.
	func selfInstallLogged(_ lines: [String], for attempt: UUID) {
		guard let relaunchShown, relaunchShown.attempt == attempt, relaunchShown.run == runCount, !log.isEmpty else { return }
		log += lines
	}

	/// What Try again runs after Atelier's own install iOS didn't take,
	/// without asking again.
	private func selfRetryJob(_ pending: PendingSelfInstall, catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, context: ModelContext) -> Job? {
		var job: Job?
		switch pending.kind {
		case .signAgain, .resign:
			job = Self.ownAppJob(isResign: pending.kind == .resign, certificateID: pending.certificateID, certificates: certificates, context: context)
		case .update, .install:
			var attempt = pending.attempt
			attempt.result = .failed
			job = self.job(retrying: attempt, catalog: catalog, downloads: downloads, certificates: certificates, context: context)
		}
		job?.selfConfirmed = true
		return job
	}

	// MARK: Running one install

	/// The certificate the running install signed with, for its Library
	/// entry (#5). Nil until it signs.
	@ObservationIgnored private var signedWith: UUID?
	/// What the running install signed the app as (#8), for its Library
	/// entry. Nil until it signs.
	@ObservationIgnored private var signedAs: SignedAppIdentity?
	/// The icon of the app the running install signed, for the Library
	/// (#118). Nil until it signs, or when its IPA has none.
	@ObservationIgnored private var signedIcon: Data?
	/// What the copy the running install signed was signed with, or the
	/// app itself, kept for it once it's installed (#113, #155). Nil until
	/// it signs, and for an app signed as it is.
	@ObservationIgnored private var signedCopy: SignedCopy?
	/// The size of the signed app the running install sends, once known.
	@ObservationIgnored private var packageSize: Int64?
	/// When the running install started, for the note Atelier's own install
	/// leaves for its next launch (#24).
	@ObservationIgnored private var runStartedAt = Date.now
	/// Atelier as it runs, packed for the running install to sign again
	/// (#24); deleted once that install ends.
	@ObservationIgnored private var packedApp: URL?
	/// The token the running install put in Atelier's build (#24).
	@ObservationIgnored private var selfToken: String?
	/// Atelier's own install, as noted for its next launch (#24); what it
	/// is, for the sheet that says to go to the Home Screen (#123).
	@ObservationIgnored private(set) var selfPending: PendingSelfInstall?
	/// The relaunch the install bar says how Atelier's own install went
	/// for (#24): its run, and the attempt in Install History, whose log
	/// Atelier adds to once it's in front.
	@ObservationIgnored private var relaunchShown: (run: Int, attempt: UUID)?
	/// Atelier's own install that went back in the queue rather than close
	/// Atelier while installs queued meanwhile wait (#24): its run ends
	/// unseen, and it runs again after them.
	@ObservationIgnored private var deferredSelf: String?
	/// The install carried over on `installWhenDownloaded` that steps aside
	/// for one the user asked for (`stepAside`): its run ends unseen.
	@ObservationIgnored private var steppedAside: String?
	/// Closes Atelier as it leaves the screen, once iOS has its own install.
	@ObservationIgnored private var closesInBackground: NSObjectProtocol?
	/// The Apple ID session the checks before the running install signed
	/// in with, and the bundle ID they checked (#49).
	@ObservationIgnored private var appleIDPlan: (accountID: UUID, bundleID: String, session: AppleIDSession)?
	/// The profile Apple gave the running install's app (#49), for its
	/// entitlements, and noted with the Apple ID once it's installed.
	@ObservationIgnored private var appleIDProfile: ProvisioningProfile?
	@ObservationIgnored private var pendingAppProfile: AppProfile?
	/// The App ID the team has for the running install's app, and until
	/// when, which its step says while it gets its profile (#49).
	@ObservationIgnored private var reusedAppID: (bundleID: String, until: Date?)?
	/// What the install bar says while the checks before an install sign
	/// in to Apple and ask iOS (#49).
	private(set) var checkingNote: String?
	/// Whether the running install signs with an Apple ID, for what the
	/// install bar says (#49).
	private(set) var signsWithAppleID = false
	/// The trust sheet, after the first install with an Apple ID (#49).
	var trustPrompt: TrustPrompt?

	/// What one install is up to, for its history entry.
	private struct Attempt {
		let startedAt = Date.now
		var bundleID: String?
		var name: String
		var version: String?
		var certificate: String?
		var route: InstallRoute?
		var origin: InstallAttempt.Origin?
		var automatic: Bool?
	}

	private func run(_ job: Job) async {
		if case .putBack(let bundleID) = job.input {
			return await putBack(bundleID, job: job)
		}
		if case .disable(let bundleID) = job.input {
			return await disable(bundleID, job: job)
		}
		runCount += 1
		let run = runCount
		// The last install's status gives way to this one, and with it any
		// download it kept.
		if let kept = keptDownload, job.downloadID == kept.id {
			// Installing the kept download again: it's in the Downloads list
			// again until this install ends.
			keptDownload = nil
		} else {
			dropKeptDownload()
		}
		// Likewise a picked file's copy kept for Try again.
		if case .picked(let file) = job.input, file == keptPicked {
			keptPicked = nil
		} else {
			dropKeptPicked()
		}
		retryJob = nil
		// What the last failed install kept for Delete and Install (#99),
		// unless this is it, which took it.
		dropRefusedApp()
		barHidden = false
		gaveUpAlert = false
		signedWith = nil
		signedAs = nil
		signedIcon = nil
		signedCopy = nil
		packageSize = nil
		selfNote = nil
		selfToken = nil
		switchedCertificate = nil
		signingNote = nil
		checkedBundleID = nil
		answeredBundleID = nil
		followUp = nil
		appleIDPlan = nil
		appleIDProfile = nil
		pendingAppProfile = nil
		reusedAppID = nil
		checkingNote = nil
		roomTaken = nil
		lastMakeRoom = nil
		signsWithAppleID = job.appleID != nil
		shownJob = job
		state = .checking
		// What the install it follows up on logged comes first (#99).
		if continuesLog == job.id {
			continuesLog = nil
		} else {
			log = []
		}
		// After the log is cleared, so what the system's bar did shows in it.
		// Atelier's own install isn't in the bar (#24).
		if !job.isSelf { BackgroundInstalls.shared.started(id: job.id) }
		limits = []
		permissions = nil
		upgradeProblem = nil
		dataNotPutBack = false
		// The app signed for the install iOS refused, sent again as it is
		// once the app in its way is deleted, as its signing noted it (#99).
		if let signed = Self.reused(job) {
			signedWith = signed.certificateID
			signedAs = signed.identity
			signedIcon = signed.icon
			signedCopy = signed.copy
			permissions = signed.permissions
			limits = signed.limits
			packageSize = Self.size(of: signed.package.url)
			log.append("sending \(signed.package.info.name) as signed for the install iOS refused\(signed.certificateName.map { ", with \($0)" } ?? "")")
		}
		var attempt = Attempt(name: job.title)
		attempt.origin = job.origin
		attempt.automatic = job.automatic ? true : nil
		runStartedAt = attempt.startedAt
		// iOS must still be able to fetch the IPA if the user leaves Atelier
		// while it's signed, during the alert or during the download.
		// iOS ends an app whose background time runs out with the task still
		// open, so it's closed then: a long download carries on in the
		// download session while Atelier is suspended, and this install
		// carries on when Atelier is back (or after a relaunch, through
		// `installWhenDownloaded`).
		let background = BackgroundTask(name: "Install \(job.title)")
		defer { background.end() }

		let pipeline = InstallPipeline(
			dependencies(for: job),
			onStage: { [weak self] stage in
				// Atelier's own install, gone back in the queue, ends unseen
				// (#24), and so does an install the user's answer replaced (#99).
				guard let self, deferredSelf != job.id, followUp == nil else { return }
				// One that steps aside isn't shown as cancelled.
				if steppedAside == job.id, stage == .cancelled { return }
				state = stage
				BackgroundInstalls.shared.update()
				if case .downloading = stage, case .source(let source) = job.input, let line = source.takeStartNote() {
					log.append(line)
				}
				// From the moment its download exists, a one-tap install
				// survives Atelier being ended in the background.
				if case .downloading = stage, case .source(let source) = job.input, let id = source.downloadID, !installWhenDownloaded.contains(id) {
					installWhenDownloaded.insert(id)
				}
			},
			log: { [weak self] line in self?.log.append(line) }
		)
		// The pipeline picks the route before downloading: a direct install
		// doesn't wait for Atelier to be in front once downloaded (#72).
		if case .source(let source) = job.input {
			source.needsFront = { [weak pipeline] in pipeline?.route != .pairing }
		}
		let outcome: Result<InstallResult, Error>
		do {
			let completed = try await pipeline.run(try await payload(for: job))
			let package = completed.package
			defer {
				// A freshly signed IPA is deleted once installed.
				if completed.freshlySigned { try? FileManager.default.removeItem(at: package.url) }
			}
			outcome = .success(completed.result)
			// Asked before the install's own Library entry is written (#49).
			let trust = trustToAsk(after: job, installed: package.info)
			finish(job, package: package, result: completed.result)
			finishAppleID(job, installed: package.info)
			removeReplaced(job, installedAs: package.info.bundleID)
			if let trust { trustPrompt = trust }
			if job.deletesFirst, job.keepsData {
				refreshKeptData()
				dataNotPutBack = keptData.contains(package.info.bundleID)
			}
			// Enabled: a copy that couldn't be put back waits for Put Back,
			// as the app's, no longer as a disabled one (#49).
			if job.restoresData {
				finishEnable(installedAs: package.info.bundleID)
			}
		} catch {
			outcome = .failure(error)
		}
		// Atelier as it ran, packed for this run only (#24).
		if let packed = packedApp {
			packedApp = nil
			try? FileManager.default.removeItem(at: packed)
		}
		// Atelier's own install went back in the queue, behind installs
		// queued while it was signed, and runs again after them (#24).
		if deferredSelf == job.id {
			deferredSelf = nil
			return
		}
		// An install carried over stepped aside for one the user asked for:
		// it's back on the list, for once nothing they asked for is under way.
		if steppedAside == job.id {
			steppedAside = nil
			if case .failure(let error) = outcome, error is CancellationError {
				if let id = job.downloadID { installWhenDownloaded.insert(id) }
				BackgroundInstalls.shared.replaced(id: job.id)
				if queue.pending.allSatisfy(\.isSelf) {
					if queue.pending.isEmpty { state = nil }
					BackgroundInstalls.shared.roundOver()
					HeldSecrets.shared.release()
				}
				return
			}
		}
		// The user answered the check's question with another install, which
		// runs next in this one's place, its log going on from here (#99).
		if let next = followUp {
			followUp = nil
			BackgroundInstalls.shared.replaced(id: job.id)
			continuesLog = next.id
			enqueue(next, next: true)
			return
		}
		attempt.route = pipeline.route
		attempt.certificate = pipeline.certificateName ?? Self.reused(job)?.certificateName
		if let info = pipeline.info {
			attempt.bundleID = info.bundleID
			attempt.version = info.version
		}

		// This install ran, however it ended, so it isn't waited on any more.
		if let id = job.downloadID { installWhenDownloaded.remove(id) }

		switch outcome {
		case .success(let result):
			if queue.pending.isEmpty {
				dismissLater(run, after: result == .unconfirmed || dataNotPutBack ? Self.unconfirmedLinger : Self.successLinger)
			}
		case .failure(let error):
			if error is CancellationError {
				state = .cancelled
				if queue.pending.isEmpty { dismissLater(run, after: Self.successLinger) }
			} else {
				var problem = InstallProblem(error)
				// iOS didn't take Atelier's own install: a copy or another
				// certificate's App ID can't replace it, so trying again is
				// what's left (#24).
				if job.isSelf, problem.fix == .replaceInstalled {
					problem = Self.selfNotInstalled(job)
				}
				// iOS refused it over the app it has: what that app is, as the
				// check before an install says, when that couldn't tell (#99).
				if problem.fix == .replaceInstalled, problem.conflict == nil, !job.isSelf, !job.deletesFirst, pipeline.route == .pairing,
				   let bundleID = signedAs?.bundleID ?? pipeline.info?.bundleID,
				   let conflict = await conflictAfterRefusal(job, bundleID: bundleID, info: pipeline.info, installedAppID: problem.installedAppID) {
					problem = .cantReplace(conflict)
				}
				// Its signed app waits for Delete and Install (#99).
				if let package = pipeline.refusedPackage {
					if problem.conflict != nil {
						refusedApp = SignedApp(
							package: package,
							certificateID: signedWith,
							certificateName: pipeline.certificateName,
							identity: signedAs,
							icon: signedIcon,
							copy: signedCopy,
							permissions: permissions,
							limits: limits
						)
					} else {
						try? FileManager.default.removeItem(at: package.url)
					}
				}
				if let why = problem.dataFailure {
					// The row says "Didn't re-sign: couldn't copy its data",
					// and Re-sign asks what to do about it (#96).
					failures[job.id] = "couldn't copy its data"
					dataFailures[job.id] = why
				} else {
					failures[job.id] = problem.message
				}
				// Also for a payload that couldn't be made, which never
				// reached the pipeline.
				state = .failed(problem)
				log.append("failed: \(problem.message)")
				if let detail = problem.detail { log.append(detail) }
				if let technical = problem.technical { log.append(technical) }
				// Signing in to GitHub tries again too (#134).
				if problem.fix == .tryAgain || problem.fix == .replaceInstalled || problem.fix == .signInToGitHub || problem.fix == .anotherCertificate || problem.fix == .makeRoom {
					retryJob = job
					if case .picked(let file) = job.input { keptPicked = file }
				}
				// The download it started as it was queued doesn't carry on
				// alone once a check before it failed, unless Try again or
				// Make Room uses it.
				if retryJob == nil, case .source(let source) = job.input, !source.isFinished {
					source.discard()
				}
				// Make Room shows by itself, unless nobody is there to pick
				// an app, as for an automatic update; the details offer it
				// again (#49).
				if problem.fix == .makeRoom, let taken = roomTaken {
					let request = MakeRoomRequest(job: job, appName: taken.name, holding: taken.apps)
					lastMakeRoom = request
					if !job.automatic { makeRoom = request }
				}
			}
		}
		// Trying again, from the install bar, is the user's doing.
		retryJob?.carriedOver = false
		// A picked IPA's copy has done its job, unless it's kept for Try again.
		if case .picked(let file) = job.input, file != keptPicked { try? FileManager.default.removeItem(at: file) }
		// So has the app signed for an install iOS refused, sent again (#99):
		// trying again signs it again.
		if let signed = job.signedApp {
			try? FileManager.default.removeItem(at: signed.package.url)
			retryJob?.signedApp = nil
		}
		// Its data may be kept now, waiting for the app's next install (#96).
		if job.deletesFirst { refreshKeptData() }
		// After a Direct install, the connection works, so Atelier checks
		// which of its apps are still on this iPhone (#17).
		let scansDevice = if case .success = outcome, pipeline.route == .pairing, queue.pending.isEmpty { true } else { false }
		if scansDevice {
			let context = job.context
			let finishedID = job.id
			Task { [weak self] in
				_ = await self?.scanDevice(into: context, startingVPN: false)
				// The scan reads the pairing file too, so what was held for a
				// locked iPhone goes after it, unless another round started (#72).
				guard let self, self.queue.pending.isEmpty, self.queue.current.map({ $0.id == finishedID }) ?? true else { return }
				HeldSecrets.shared.release()
			}
		}
		recordAttempt(attempt, outcome: outcome)
		if !job.isSelf {
			switch outcome {
			case .success: BackgroundInstalls.shared.ended(id: job.id, .installed)
			case .failure(let error) where error is CancellationError: BackgroundInstalls.shared.ended(id: job.id, .cancelled)
			case .failure(let error): BackgroundInstalls.shared.ended(id: job.id, .failed(Self.message(for: error)))
			}
		}
		// The round is over once only Atelier's own install is left, which
		// stays out of the system's bar (#24).
		if queue.pending.allSatisfy(\.isSelf) {
			if !job.isSelf { BackgroundInstalls.shared.roundOver() }
			if !scansDevice { HeldSecrets.shared.release() }
		}
		if gaveUpAlert {
			gaveUpAlert = false
			reset()
		}
	}

	/// Put Back in the Library (#96): puts the app's kept data back into it
	/// through Direct installs. The install bar shows it as it shows an
	/// install, but it installs nothing, so it stays out of the system's
	/// bar and the install history.
	private func putBack(_ bundleID: String, job: Job) async {
		runCount += 1
		let run = runCount
		// The last install's status gives way to this one, and with it what
		// it kept for Try again.
		dropKeptDownload()
		dropKeptPicked()
		retryJob = nil
		barHidden = false
		gaveUpAlert = false
		shownJob = job
		log = []
		limits = []
		permissions = nil
		upgradeProblem = nil
		dataNotPutBack = false
		let name = job.title
		let info = IPAInfo(bundleID: bundleID, version: InstalledApps.record(bundleID, in: job.context)?.version ?? "", name: name)
		state = .installing(info, .connecting)
		let background = BackgroundTask(name: "Put back \(name)'s data")
		defer {
			background.end()
			refreshKeptData()
		}
		do {
			guard let keeper = dataKeeper, keptDataInfo(of: bundleID) != nil else {
				throw InstallProblem("Atelier no longer has \(name)'s data.")
			}
			if case .unavailable(let why) = await pairingInstaller.check(startingVPN: true) {
				throw InstallProblem(why, fix: .installSettings)
			}
			if await pairingInstaller.isInstalled(bundleID) == false {
				throw InstallProblem("\(name) isn't on this \(ThisDevice.name) any more. Install it again, then put its data back.")
			}
			try await keeper.putBack(bundleID, name: name) { [weak self] event in
				guard let self, self.runCount == run, self.isRunning else { return }
				switch event {
				case .log(let line): self.log.append(line)
				case .phase(let phase): self.state = .installing(info, phase)
				}
			}
			state = .finished(info, .confirmed(version: info.version))
			if queue.pending.isEmpty { dismissLater(run, after: Self.successLinger) }
		} catch is CancellationError {
			state = .cancelled
			if queue.pending.isEmpty { dismissLater(run, after: Self.successLinger) }
		} catch {
			let problem = Self.putBackProblem(error)
			state = .failed(problem)
			log.append("failed: \(problem.message)")
			if let detail = problem.detail { log.append(detail) }
			if let technical = problem.technical { log.append(technical) }
			if problem.fix == .tryAgain { retryJob = job }
		}
	}

	/// Why Put Back failed, as the install bar says it.
	private static func putBackProblem(_ error: Error) -> InstallProblem {
		let message = "Couldn't put its data back."
		switch error {
		case let problem as InstallProblem:
			return problem
		case let refused as AppDataRefused:
			var problem = InstallProblem(message, detail: "iOS doesn't let Atelier put this app's data back.")
			problem.technical = "iOS doesn't let Atelier open its data: \(refused.message)"
			return problem
		case InstallFailure.connectionLost(let why):
			var problem = InstallProblem(message, detail: "Putting it back was interrupted. Check that you're on Wi-Fi with LocalDevVPN connected, then try again.", fix: .tryAgain)
			problem.technical = why
			return problem
		default:
			let cause = InstallProblem(error)
			var problem = InstallProblem(message, detail: cause.message, fix: .tryAgain)
			problem.technical = cause.technical
			return problem
		}
	}

	/// What the pipeline installs for this job.
	private func payload(for job: Job) async throws -> InstallPipeline.Payload {
		// Signed for the install iOS refused (#99).
		if let signed = Self.reused(job) { return .signed(signed.package) }
		switch job.input {
		case .picked(let file):
			return .file(file)
		case .download(let download, let downloads):
			guard let file = downloads.fileURL(for: download.id) else {
				throw InstallProblem("The download of \(download.name) is gone. Download it again.")
			}
			return .file(file)
		case .source(let source):
			return .download(source)
		case .ownApp:
			// Atelier as it runs, as nothing else has its build (#24).
			let own = SelfUpdate.shared
			log.append("packing \(own.name) \(own.version)\(own.build.map { " (\($0))" } ?? "") as it runs, to sign it again")
			do {
				let ipa = try await SigningKit.pack(app: Bundle.main.bundleURL, outputDirectory: Self.installsFolder)
				packedApp = ipa
				return .file(ipa)
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				throw InstallProblem("Couldn't pack \(own.name) to sign it again: \(InstallProblem(error).message)")
			}
		case .putBack, .disable:
			// `run` puts data back, or disables the app, without the pipeline.
			throw InstallProblem("Put Back and Offload aren't installs.")
		}
	}

	/// The certificate, route, free space and signing the pipeline uses.
	private func dependencies(for job: Job) -> InstallPipeline.Dependencies {
		InstallPipeline.Dependencies(
			certificate: { [weak self] in
				// The one the app on this iPhone was installed with, when the
				// check before the install switched to it (#99).
				let job = self?.signing(job) ?? job
				guard let certificate = job.certificate else {
					if let account = job.appleID { return Self.check(account) }
					return .missing
				}
				if certificate.expiresAt <= .now { return .expired(name: certificate.displayName, on: certificate.expiresAt) }
				// As of the last revocation check (#5): an install doesn't wait
				// for Apple's responder.
				if certificate.isRevoked { return .revoked(name: certificate.displayName) }
				do {
					return try job.canSign() ? .ready(name: certificate.displayName) : .missing
				} catch {
					// The Keychain's error goes in the log, not the message.
					self?.log.append("couldn't open \(certificate.displayName): \(error)")
					return .unusable(name: certificate.displayName, why: "Atelier couldn't open it. Import it again.")
				}
			},
			installer: { [weak self] in
				// Deleting the app first takes route A, which then installs
				// it too (#20), keeping its data unless told not to (#96).
				// The app it replaces goes first, also when it has another
				// bundle ID than this one, which then gets its data (#49).
				if job.deletesFirst {
					let direct = try await RouteSelector.select(.pairing, from: self?.installers ?? [])
					return ReplacingInstaller(direct, deleting: job.replacesBundleID, keeping: job.keepsData ? self?.dataKeeper : nil, homeScreen: self?.homeScreenSpots) { [weak self] bundleID in
						guard let self else { return "Atelier stopped." }
						return await self.deleteBeforeReplacing(bundleID, evenUnlisted: job.deletesUnlisted, in: job.context)
					}
				}
				// Automatic updates only run through route A (#72); the rest
				// take it when they can, and the iOS alert otherwise. An app
				// signed with an Apple ID only installs through route A, as
				// iOS's alert refuses it, and so does Enable, which puts the
				// app's data back through it (#49).
				let signsWithAppleID = (self.map { $0.signing(job) } ?? job).appleID != nil
				let preference: RoutePreference = job.automatic || signsWithAppleID || job.restoresData ? .pairing : .automatic
				let selected: any Installer
				do {
					selected = try await RouteSelector.select(preference, from: self?.installers ?? [])
				} catch let error where signsWithAppleID && !job.automatic {
					throw InstallProblem("Apps signed with an Apple ID only install through Direct installs. \(InstallProblem(error).message)", fix: .installSettings)
				} catch let error where job.restoresData {
					throw InstallProblem("Reinstall installs the app through Direct installs, to put its data back. \(InstallProblem(error).message)", fix: .installSettings)
				}
				if job.restoresData, let keeper = self?.dataKeeper {
					return RestoringInstaller(selected, keeping: keeper, from: job.replacesBundleID, homeScreen: self?.homeScreenSpots)
				}
				// Atelier's own install notes itself for Atelier's next
				// launch, and closes Atelier for iOS to install it (#24).
				guard job.isSelf, let self else { return selected }
				return SelfInstaller(selected, job: job, model: self)
			},
			freeSpace: { Self.freeSpace },
			checkInstalled: { [weak self] installer, ipa in
				guard let self else { throw CancellationError() }
				let switched = try await self.checkInstalled(job, installer: installer, ipa: ipa)
				try self.checkEnabling(job, ipa: ipa)
				try await self.checkAppleID(self.signing(job), ipa: ipa)
				return switched
			},
			sign: { [weak self] ipa, progress in
				guard let self else { throw CancellationError() }
				return try await self.sign(ipa, job: self.signing(job), progress: progress)
			}
		)
	}

	/// Signs an IPA with the job's certificate, the default one unless
	/// Custom Install… picked another, into the installs folder,
	/// adding the install check scheme, and fitting its
	/// entitlements to the profile (#7).
	private func sign(_ ipa: URL, job: Job, progress: @escaping @MainActor (SigningProgress) -> Void) async throws -> InstallPackage {
		let title = job.title
		// A held certificate written for this signing goes however the
		// signing ends (#72).
		defer { HeldSecrets.deleteWritten() }
		// With an Apple ID, the app's own profile from Apple, signed as its
		// bundle ID and the team's; the profile's file goes once signed (#49).
		var appleIDSigning: (identity: SigningIdentity, bundleID: String, profile: URL, appGroups: [String: String])?
		defer { if let file = appleIDSigning?.profile { try? FileManager.default.removeItem(at: file) } }
		// Atelier itself too, when it's one of the Apple ID's apps (#152).
		if let account = job.appleID {
			appleIDSigning = try await appleIDIdentity(for: ipa, account: account, job: job)
		}
		guard let identity = try appleIDSigning?.identity ?? job.signingIdentity() else { throw InstallProblem.noCertificate }
		signedWith = appleIDSigning != nil ? job.appleID?.id : job.certificateID ?? job.certificates.defaultID
		// Never the Apple ID itself, which the log doesn't hold.
		let certificateName = job.certificate?.displayName ?? (appleIDSigning != nil ? "an Apple ID" : "no certificate")
		log.append("signing \(title) with \(certificateName)")
		if let signedWith, HeldSecrets.shared.holds(certificate: signedWith) {
			let locked = UIApplication.shared.isProtectedDataAvailable ? "unlocked" : "locked"
			log.append("certificate: the copy read when it was queued (iPhone \(locked))")
		}
		var options: SigningOptions
		if job.isSelf {
			// Atelier keeps the bundle ID it runs as, and tells on its next
			// launch from this token whether iOS installed the build (#24).
			let own = SelfUpdate.shared
			let token = UUID().uuidString
			selfToken = token
			if job.usesInstalledProfile {
				log.append("profile: the one \(own.name) was installed with, which lists \(certificateName), as the certificate's own is for another App ID")
			}
			log.append("install check: none for \(own.name) itself, which tells on its next launch whether iOS installed it")
			// A copy of Atelier keeps the name it was given too (#113).
			options = SigningOptions(displayName: own.target == .original ? nil : own.name, bundleID: own.bundleID, infoPlistValues: [PendingSelfInstall.tokenKey: token])
			// And what the user chose for it, and goes on saying which copy it
			// is (#113). Signed again as it runs, it has its icon already.
			if let marker = own.copyMarker {
				options.infoPlistValues[CopyMarker.key] = marker.encoded
				options.removesURLSchemes = marker.settings.removesURLSchemes
				let running = if case .ownApp = job.input { true } else { false }
				if !running { options.icon = Self.ownIcon(marker) }
				log.append("copy: \(marker.numberedID), keeping what was chosen for it")
			}
		} else {
			let check = freeCheckScheme(in: job.context)
			if let check {
				log.append("install check: adding \(check) to the app")
			} else {
				log.append("install check: all \(InstallCheck.schemes.count) check schemes are taken by installed apps, so this install can't be confirmed")
			}
			options = SigningOptions(target: job.target, displayName: job.displayName, installCheckScheme: check, bundleID: appleIDSigning?.bundleID)
			signChoices(job, ipa: ipa, identity: identity, options: &options)
			// The App Groups its profile allows under the team's names (#49),
			// and the library that sends the app's own names to them, unless
			// Share App Groups is off for it. With a certificate, the library
			// keeps them in folders of the app's own in the certificate's
			// group, when its profile has groups of its own but not the app's.
			options.appGroups = appleIDSigning?.appGroups ?? [:]
			if !options.appGroups.isEmpty || appleIDSigning == nil {
				if signedCopy?.choice.settings.sharesAppGroups == false {
					log.append(appleIDSigning == nil
						? "app groups: Share App Groups is off, so any the app has aren't kept in the certificate's"
						: "app groups: Share App Groups is off, so the app keeps asking for them by its own names")
				} else if let library = Self.appGroupsLibrary {
					options.appGroupsLibrary = library
				} else {
					log.append("app groups: \(AppGroupRedirect.fileName) is missing from Atelier, so the app keeps asking for them by its own names")
				}
			}
			// The app's own icon, which its tint or picture covers, for the
			// pictures of new ones (#155).
			if options.icon != nil, signedCopy != nil {
				let unsigned = ipa
				signedCopy?.ownIcon = await Task.detached(priority: .utility) { IPAIcon.read(ipaAt: unsigned) }.value
			}
		}
		let started = Date.now
		let signed = try await SigningKit.sign(ipa: ipa, with: identity, options: options, outputDirectory: Self.installsFolder) { step in
			Task { @MainActor in progress(step) }
		}
		// iOS only installs Atelier over itself signed for the App ID it was
		// installed with (#24).
		if job.isSelf, let expected = SelfUpdate.shared.identity?.applicationIdentifier, signed.identity.applicationIdentifier != expected {
			try? FileManager.default.removeItem(at: signed.url)
			let name = SelfUpdate.shared.name
			log.append("\(name) was signed for the App ID \(signed.identity.applicationIdentifier ?? "unknown"), not \(expected), the one it was installed with")
			let with = appleIDSigning == nil
				? "this certificate can't update it. Use the certificate \(name) was installed with."
				: "this Apple ID can't update it. Sign in with the Apple ID \(name) was installed with."
			throw InstallProblem("\(name) wasn't installed: \(with)")
		}
		packageSize = Self.size(of: signed.url)
		// The icon iOS will show for it, as the Library shows it (#118).
		let signedURL = signed.url
		signedIcon = await Task.detached(priority: .utility) { IPAIcon.read(ipaAt: signedURL) }.value
		let size = packageSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
		log.append(String(format: "signed %@ %@ in %.1f s (%@)", signed.info.bundleID, signed.info.version, Date.now.timeIntervalSince(started), size))
		if signedIcon == nil { log.append("icon: none found in the app, so the Library shows its source's") }
		if options.icon != nil, !signed.iconChanged { log.append("icon: the app has no icon file to tint, so the copy keeps its own") }
		let groupItem = signed.entitlements?.items.first { $0.key == AppGroups.entitlement }
		switch groupItem?.redirected {
		case true? where groupItem?.folders != nil:
			let folders = (groupItem?.folders ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) in \(groupItem?.renamedValues?[$0.key] ?? "?")/\($0.value)" }
			log.append("app groups: kept in the certificate's, through \(AppGroupRedirect.fileName): \(folders.joined(separator: "; "))")
		case true?: log.append("app groups: the app and its extensions send their own names for them to the Apple ID's, through \(AppGroupRedirect.fileName)")
		case false?: log.append("app groups: the app's executable has no room to load \(AppGroupRedirect.fileName), so it keeps asking for them by its own names")
		case nil: break
		}
		permissions = SignedPermissions(privacy: signed.info.privacy, entitlements: noteEntitlements(signed.entitlements, job: job))
		var signedIdentity = signed.identity
		// Atelier signed as it runs: its Info.plist has the bundle ID it
		// runs as, not its source app's (#24).
		if let original = job.originalBundleID { signedIdentity.originalBundleID = original }
		noteIdentity(signedIdentity, job: job)
		return InstallPackage(url: signed.url, info: signed.info)
	}

	/// Atelier's library that apps signed with an Apple ID load to find
	/// their App Groups under the Apple ID's names (#49), from its own
	/// Frameworks.
	private static var appGroupsLibrary: URL? {
		guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent(AppGroupRedirect.fileName),
		      FileManager.default.fileExists(atPath: url.path)
		else { return nil }
		return url
	}

	/// Signs an app with what the user chose for it, else what it was
	/// installed with, which its updates and re-signs keep, from Custom
	/// Install's sheet: a copy with its App ID, icon, version and URL
	/// schemes (#113), and for a copy of Atelier, which copy it is, and the
	/// certificate it comes with; the app itself with the same and its
	/// name, but not its App ID, which stays (#155). With an Apple ID, both
	/// have its team ID in their bundle ID (#49). Noted for its Library
	/// entry. Atelier itself has none.
	private func signChoices(_ job: Job, ipa: URL, identity: SigningIdentity, options: inout SigningOptions) {
		// The signing says what's wrong with an IPA it can't read.
		guard let info = try? IPAInfo.read(ipaAt: ipa) else { return }
		let isOriginal = job.target == .original
		let isOwn = SelfUpdate.shared.isOwnApp(info.bundleID)
		// Atelier itself signs as it is (#24).
		if isOriginal, isOwn { return }
		// An Apple ID's apps and copies are numbered from the app's bundle ID
		// and the team's, as they install (#49).
		let account = job.appleID
		let numbered = job.target.bundleID(for: account?.bundleID(for: info.bundleID) ?? info.bundleID)
		let store = CopyStore.shared
		let kept = store.settings(for: numbered).map { CopyChoice(settings: $0, picture: store.picture(for: numbered)) }
		var choice: CopyChoice
		if let chosen = job.copyChoice ?? kept {
			choice = chosen
		} else if isOriginal, job.displayName == nil {
			// The app itself, as it is.
			return
		} else {
			choice = CopyChoice(settings: CopySettings())
		}
		if isOriginal {
			// Under its own App ID, so it keeps its data, with the name chosen
			// for it, else the one its install had.
			choice.settings.bundleID = nil
			if job.copyChoice == nil, let name = job.displayName { choice.settings.name = name }
			options.displayName = choice.settings.name
		} else {
			// A copy's name is its Library entry's (`displayName(of:)`).
			choice.settings.name = nil
		}
		// Atelier goes by its own version for its updates.
		if isOwn { choice.settings.version = nil }
		// And an Apple ID signs one chosen for it with the team ID too, so
		// it's kept as it installs.
		if let account, choice.settings.bundleID != nil {
			choice.settings.bundleID = Self.appleIDBundleID(of: info.bundleID, as: job.target, copy: choice.settings, account: account)
		}
		let settings = choice.settings
		signedCopy = SignedCopy(numberedID: numbered, choice: choice, version: info.version, buildVersion: info.buildVersion)
		// Else the Apple ID's, or the one its copy number gives it.
		options.bundleID = settings.bundleID ?? options.bundleID
		options.version = settings.version
		options.icon = settings.icon(picture: choice.picture)
		options.removesURLSchemes = settings.removesURLSchemes
		if isOwn { options.infoPlistValues[CopyMarker.key] = CopyMarker(numberedID: numbered, settings: settings).encoded }
		if isOwn, choice.includesCertificate {
			// An Apple ID's certificate goes nowhere else, and its profile
			// is for this copy alone (#49).
			if account == nil {
				options.packagedCertificate = packagedCertificate(identity, of: job, in: info)
			} else {
				log.append("certificate: left out, as an Apple ID signs the copy, so the copy starts without one")
			}
		}
		if let id = settings.bundleID { log.append("bundle ID: \(id), chosen for \(numbered)") }
		if let name = settings.name { log.append("name: \(name), chosen for it") }
		if let tint = settings.tint { log.append("icon: tinted \(tint.rawValue)") }
		if settings.hasPicture { log.append(choice.picture == nil ? "icon: its picture is missing, so it keeps the app's" : "icon: a picture of the user's") }
		if let version = settings.version { log.append("version: says it's \(version), and is \(info.version)") }
		if settings.removesURLSchemes { log.append("URL schemes: removed") }
	}

	/// The certificate a copy of Atelier comes with, with Include
	/// Certificate on (#113): the one it's signed with, and its password,
	/// for the copy to import on its first launch, with this iPhone's UDID
	/// once the setup has read it. Left out of a copy of a build that
	/// doesn't look for one, which its Info.plist says.
	private func packagedCertificate(_ identity: SigningIdentity, of job: Job, in info: IPAInfo) -> PackagedCertificate? {
		guard info.takesCertificate else {
			log.append("certificate: left out, as \(info.name) \(Self.displayVersion(of: info)) doesn't look for one, so the copy starts without it")
			return nil
		}
		do {
			let udid = RouteASetup.shared.udid
			let certificate = PackagedCertificate(
				p12: try Data(contentsOf: identity.p12),
				profile: try Data(contentsOf: identity.profile),
				password: identity.password,
				name: job.certificate?.customName,
				udid: udid
			)
			let withUDID = udid == nil ? "" : " and this \(ThisDevice.name)'s UDID"
			log.append("certificate: put in the copy with its password\(withUDID), for the copy to import on its first launch")
			return certificate
		} catch {
			log.append("certificate: left out, as it couldn't be read (\(error.localizedDescription)), so the copy starts without it")
			return nil
		}
	}

	/// A copy of Atelier's icon for its own updates (#113): its picture,
	/// from the icon it runs with, which has it already tinted, or its tint.
	private static func ownIcon(_ marker: CopyMarker) -> IconChange? {
		if marker.settings.hasPicture, let png = IconChange.written(inApp: Bundle.main.bundleURL) {
			return IconChange(picture: png)
		}
		return marker.settings.tint.map { IconChange(tint: $0) }
	}

	/// Logs what became of each entitlement and sets what won't work. When
	/// the app's binaries carry none, as decrypted IPAs often don't, the
	/// source's list stands in for them, and the report returned says so.
	private func noteEntitlements(_ report: EntitlementsReport?, job: Job) -> EntitlementsReport? {
		guard var report else {
			log.append("entitlements: the profile couldn't be read, so they weren't checked")
			return nil
		}
		let ownKeychain = report.items.contains { $0.key == "keychain-access-groups" && $0.outcome != .dropped }
		if ownKeychain {
			log.append("entitlements: the profile's, with the app's own keychain groups under team \(report.profileTeamID)")
		} else {
			log.append("entitlements: the profile's")
		}
		if let team = report.appTeamID { log.append("entitlements: the app was signed by team \(team)") }
		if !report.readFromApp, case .source(let source) = job.input, !source.app.permissions.entitlements.isEmpty,
		   let profile = job.certificate?.profile ?? appleIDProfile {
			log.append("entitlements: none in the app's binaries, so these are from the source's list")
			report = EntitlementsReport.predict(sourceKeys: source.app.permissions.entitlements, profileKeys: Set(profile.entitlements.keys), profileTeamID: profile.teamID)
		}
		for item in report.items {
			let bundles = item.bundles.map { $0.isEmpty ? "app" : $0 }.joined(separator: ", ")
			let missing = item.missingValues.isEmpty ? "" : ", not granted: \(item.missingValues.joined(separator: ", "))"
			log.append("entitlement \(item.key): \(item.outcome.rawValue) (\(bundles)\(missing))")
		}
		limits = report.limits
		return report
	}

	/// Logs the bundle ID and App ID the app was signed as (#8), and warns
	/// first thing when iOS would refuse it over the app Atelier last
	/// installed under that bundle ID.
	private func noteIdentity(_ identity: SignedAppIdentity, job: Job) {
		signedAs = identity
		if job.isSelf {
			// Not a copy: the bundle ID Atelier runs as (#24).
			if identity.bundleID != identity.originalBundleID { log.append("bundle ID: \(identity.bundleID), the one \(SelfUpdate.shared.name) runs as") }
		} else {
			if signsWithAppleID {
				// An App ID is Apple's across every team, so the app's own may
				// be taken (#49).
				log.append("bundle ID: \(identity.originalBundleID) installed as \(identity.bundleID), with the Apple ID's team ID")
			} else if identity.bundleID != identity.originalBundleID {
				log.append("bundle ID: \(identity.originalBundleID) installed as a copy, \(identity.bundleID)")
			}
			// Its source lists it under another, which Browse and the Library
			// know it by (#116).
			if let listed = job.listedBundleID, listed != identity.originalBundleID {
				log.append("bundle ID: \(identity.originalBundleID), though its source lists \(listed)")
			}
		}
		log.append("App ID: \(identity.applicationIdentifier ?? "unknown")")
		// One deleted first leaves iOS nothing to refuse it over (#20), and
		// installd's own record, read before the install, says more than
		// Atelier's (#99).
		let installed = job.deletesFirst || answeredBundleID == identity.bundleID ? nil : InstalledApps.record(identity.bundleID, in: job.context)?.signedIdentity
		if let problem = identity.upgradeProblem(over: installed) {
			log.append("App ID changed: \(installed?.applicationIdentifier ?? "") before, \(identity.applicationIdentifier ?? "") now")
			limits.insert(problem, at: 0)
			upgradeProblem = problem
		}
	}

	// MARK: Disable and Enable (#49)

	/// A free Apple ID's install, or Enable, that found every one of the 3
	/// places on this iPhone taken: Make Room names the apps holding them,
	/// and disables the one picked, then runs the install.
	struct MakeRoomRequest: Identifiable {
		let id = UUID()
		let job: Job
		/// As the install's check named it, without its version.
		let appName: String
		/// As iOS listed them.
		let holding: [FreeApp]

		/// Enable, rather than a new install.
		var enabling: Bool { job.restoresData }
	}

	/// What the check before the running install found holding the 3
	/// places, for Make Room.
	@ObservationIgnored private var roomTaken: (name: String, apps: [FreeApp])?
	/// Make Room for the failed install, while its details can show it
	/// again.
	@ObservationIgnored private var lastMakeRoom: MakeRoomRequest?

	/// Make Room… in the failed install's details.
	var canShowMakeRoom: Bool {
		guard let request = lastMakeRoom, !isRunning else { return false }
		return retryJob?.id == request.job.id
	}

	func showMakeRoom() {
		guard canShowMakeRoom else { return }
		makeRoom = lastMakeRoom
	}

	private static func disableID(_ bundleID: String) -> String {
		"disable \(bundleID)"
	}

	private static func disableJob(_ install: InstallRecord, iconURL: URL?, certificates: CertificatesModel, context: ModelContext) -> Job {
		Job(id: disableID(install.bundleID), title: install.name, iconURL: iconURL, input: .disable(install.bundleID), certificates: certificates, context: context)
	}

	/// Disable: takes an app off this iPhone, keeping its data in Atelier
	/// until Enable puts it back, so it no longer holds one of the 3
	/// places a free Apple ID's apps have here.
	func disable(_ install: InstallRecord, iconURL: URL?, certificates: CertificatesModel, into context: ModelContext) {
		enqueue(Self.disableJob(install, iconURL: iconURL, certificates: certificates, context: context))
	}

	/// Whether a Disable of the app waits or runs.
	func isDisabling(_ bundleID: String) -> Bool {
		let id = Self.disableID(bundleID)
		return currentID == id || waiting.contains { $0.id == id }
	}

	/// Make Room's tap: disables `install`, then, once it's off this
	/// iPhone, runs the install that found no room. If Disable fails, the
	/// install doesn't run.
	func makeRoom(_ request: MakeRoomRequest, disabling install: InstallRecord, iconURL: URL?) {
		if makeRoom?.id == request.id { makeRoom = nil }
		lastMakeRoom = nil
		if retryJob?.id == request.job.id { retryJob = nil }
		var disable = Self.disableJob(install, iconURL: iconURL, certificates: request.job.certificates, context: request.job.context)
		disable.afterwards = [request.job]
		enqueue(disable)
	}

	/// Enable: installs an app Disable took off this iPhone again, as the
	/// app or the copy it is, and puts its kept data back. Its source's
	/// newest version this iPhone can run, as iOS installs after Offload
	/// App, signed with the Apple ID it was installed with while Atelier
	/// has it, else the certificate in use. Returns false when its source
	/// lists no such version, so its IPA has to be picked instead.
	@discardableResult
	func enable(_ install: InstallRecord, in catalog: Catalog, downloads: DownloadManager, certificates: CertificatesModel, into context: ModelContext) -> Bool {
		guard let offer = Self.listing(of: install, in: catalog), let version = offer.app.availability().version else { return false }
		var job = Self.sourceJob(offer.app, version: version, sourceURL: offer.source.url, as: install.target, displayName: Self.displayName(of: install), certificateID: nil, replacing: install, downloads: downloads, certificates: certificates, context: context)
		job.replacesBundleID = install.bundleID
		job.restoresData = true
		enqueue(job)
		return true
	}

	/// Enable with the app's IPA, picked again: an app installed from a
	/// file, or one its source no longer lists.
	func enable(_ install: InstallRecord, picked: URL, certificates: CertificatesModel, into context: ModelContext) {
		guard IPAPicker.extensions.contains(picked.pathExtension.lowercased()), let staged = try? Self.stage(picked) else {
			if !isRunning {
				log = []
				state = .failed(InstallProblem("Couldn't read that IPA, to reinstall \(install.name) with it."))
			}
			return
		}
		var job = Job(id: UUID().uuidString, title: install.name, iconURL: InstalledIcons.shared.url(for: install.bundleID), input: .picked(staged), certificates: certificates, context: context)
		job.target = install.target
		job.displayName = Self.displayName(of: install)
		job.certificateID = Self.installedCertificate(of: install, certificates: certificates)
		job.replacesBundleID = install.bundleID
		job.restoresData = true
		enqueue(job)
	}

	/// Enable with an IPA picked again: it has to be the disabled app,
	/// whose data it gets.
	private func checkEnabling(_ job: Job, ipa: URL?) throws {
		guard job.restoresData, let ipa, let old = job.replacesBundleID,
		      let install = InstalledApps.record(old, in: job.context),
		      let info = try? IPAInfo.read(ipaAt: ipa) else { return }
		guard info.bundleID != install.ipaBundleID, info.bundleID != install.sourceBundleID else { return }
		log.append("reinstall: the IPA is \(info.bundleID), not \(install.ipaBundleID)")
		throw InstallProblem("That IPA is \(info.name), not \(install.name). Reinstall puts \(install.name)'s data back, so it only installs \(install.name).")
	}

	/// After Enable's install: the data is back in the app, or its copy
	/// waits for Put Back as the app's, no longer a disabled app's.
	private func finishEnable(installedAs bundleID: String) {
		if let store = try? AppDataStore.standard(), store.kept(bundleID)?.disabledAt != nil {
			try? store.markDisabled(bundleID, at: nil)
		}
		refreshKeptData()
		dataNotPutBack = keptData.contains(bundleID)
	}

	/// Disable, in the queue: through Direct installs, copies the app's
	/// data aside, as before a reinstall (#96), and keeps it marked as a
	/// disabled app's, then deletes the app. If the copy fails, the app
	/// stays. It shows in the install bar as Put Back does, and then runs
	/// what waits for it: Make Room's install.
	private func disable(_ bundleID: String, job: Job) async {
		runCount += 1
		let run = runCount
		// The last install's status gives way to this one, and with it what
		// it kept for Try again, but for the picked IPA that Make Room's
		// install, after this Disable, takes.
		dropKeptDownload()
		if let kept = keptPicked, kept == job.pickedFile {
			keptPicked = nil
		} else {
			dropKeptPicked()
		}
		retryJob = nil
		lastMakeRoom = nil
		barHidden = false
		gaveUpAlert = false
		shownJob = job
		log = []
		limits = []
		permissions = nil
		upgradeProblem = nil
		dataNotPutBack = false
		let name = job.title
		let install = InstalledApps.record(bundleID, in: job.context)
		let info = IPAInfo(bundleID: bundleID, version: install?.version ?? "", name: name)
		state = .installing(info, .connecting)
		let background = BackgroundTask(name: "Offload \(name)")
		defer {
			background.end()
			refreshKeptData()
		}
		let events: @MainActor (InstallEvent) -> Void = { [weak self] event in
			guard let self, self.runCount == run, self.isRunning else { return }
			switch event {
			case .log(let line): self.log.append(line)
			case .phase(let phase): self.state = .installing(info, phase)
			}
		}
		var kept = false
		do {
			guard let keeper = dataKeeper, let store = try? AppDataStore.standard() else {
				throw InstallProblem("Atelier couldn't make a folder for \(name)'s data.")
			}
			if case .unavailable(let why) = await pairingInstaller.check(startingVPN: true) {
				throw InstallProblem(why, fix: .installSettings)
			}
			if await pairingInstaller.isInstalled(bundleID) == false {
				throw InstallProblem("\(name) isn't on this \(ThisDevice.name) any more, so there's nothing to offload.")
			}
			log.append("offload: keeping \(name)'s data, then deleting \(bundleID) from this \(ThisDevice.name)")
			do {
				try await keeper.save(bundleID, name: name, events: events)
			} catch InstallFailure.dataNotCopied(let why) {
				throw InstallProblem("Couldn't keep \(name)'s data, so it stays on this \(ThisDevice.name).", detail: why.description, fix: .tryAgain)
			}
			try store.markDisabled(bundleID, at: .now)
			kept = true
			try Task.checkCancellation()
			state = .installing(info, .connecting)
			// For Reinstall to put it back there.
			await homeScreenSpots.note(bundleID, name: name, events: events)
			if let why = await uninstall(bundleID: bundleID) {
				throw InstallProblem("Couldn't delete \(name) from this \(ThisDevice.name): \(why)", detail: "It's still there, with its data.", fix: .tryAgain)
			}
			log.append("offload: deleted \(bundleID); its data waits for Reinstall")
			// And its spot, empty, for Reinstall.
			await homeScreenSpots.hold(bundleID, name: name, events: events)
			// It no longer holds one of the 3 places.
			if let account = job.certificates.appleID(install?.certificateID) {
				job.certificates.updateAppleID(account.id) { stored in
					if let apps = stored.limits?.apps {
						stored.limits?.apps = AppleIDLimits.Apps(checkedAt: .now, apps: apps.apps.filter { $0.bundleID != bundleID })
					}
				}
			}
			state = .finished(info, .confirmed(version: info.version))
			// What it's off this iPhone for runs next.
			for next in job.afterwards.reversed() { enqueue(next, next: true) }
			if queue.pending.isEmpty { dismissLater(run, after: Self.successLinger) }
			// An app without an install check is told gone by a scan.
			let context = job.context
			Task { [weak self] in
				guard let self, self.queue.pending.isEmpty else { return }
				_ = await self.scanDevice(into: context, startingVPN: false)
			}
		} catch {
			// The app stays, with its data: the copy isn't needed.
			if kept { (try? AppDataStore.standard())?.remove(bundleID) }
			// Make Room's install doesn't run, so its picked IPA is kept as
			// its own failure keeps it, for Try again.
			if let file = job.pickedFile { keptPicked = file }
			if error is CancellationError {
				state = .cancelled
				if queue.pending.isEmpty { dismissLater(run, after: Self.successLinger) }
				return
			}
			let problem = error as? InstallProblem ?? InstallProblem("Couldn't offload \(name): \(InstallProblem(error).message)", fix: .tryAgain)
			state = .failed(problem)
			log.append("failed: \(problem.message)")
			if let detail = problem.detail { log.append(detail) }
			if problem.fix == .tryAgain { retryJob = job }
		}
	}

	// MARK: Signing with an Apple ID (#49)

	/// What the trust sheet says after the first install with an Apple ID
	/// on this iPhone: iOS opens the app once the user trusts the Apple ID.
	struct TrustPrompt: Identifiable {
		let id = UUID()
		let appName: String
		let appleID: String
	}

	/// Whether the Apple ID can sign: its certificate as of its last
	/// revocation check (#5).
	private static func check(_ account: StoredAppleID) -> CertificateCheck {
		let name = account.displayName
		if account.expiresAt <= .now { return .expired(name: name, on: account.expiresAt) }
		if account.isRevoked { return .revoked(name: name) }
		return .ready(name: name)
	}

	/// Before anything is downloaded or signed with an Apple ID: signs in
	/// again, then checks there's room for the app among the 3 apps a free
	/// Apple ID's profiles run on, as iOS lists them, and among the week's
	/// 10 new App IDs when the team doesn't have the app's, as Apple lists
	/// them, so a refused install costs neither. With the source's bundle
	/// ID before the download, and again once the IPA says another.
	///
	/// Atelier's own install too (#152): it keeps the bundle ID it runs as,
	/// holds its place already, and asked about its App ID in its own
	/// question (`OwnAppleID.appIDUse`), so not again here.
	private func checkAppleID(_ job: Job, ipa: URL?) async throws {
		guard let account = job.appleID else { return }
		let info = ipa.flatMap { try? IPAInfo.read(ipaAt: $0) }
		guard let bundleID = expectedBundleID(of: job, info: info), appleIDPlan?.bundleID != bundleID else { return }
		defer { checkingNote = nil }
		let name = appName(of: job, info: info)
		log.append("Apple ID: \(account.isFree ? "a free one" : "a paid team's"), team \(account.team.id), so the app installs as \(bundleID)")
		let session = try await signIn(account, job: job, name: name)
		var limits = account.limits ?? AppleIDLimits()
		// Only apps signed with a free Apple ID take one of the 3 places.
		// iOS is asked before Apple, so a full iPhone costs no App ID.
		if account.isFree {
			checkingNote = "Checking the apps on this \(ThisDevice.name)…"
			do {
				let read = try await pairingInstaller.appsAndProfiles()
				let apps = FreeAppleID.apps(installed: read.apps, profileFiles: read.profiles)
				limits.apps = AppleIDLimits.Apps(checkedAt: .now, apps: apps)
				let listed = apps.isEmpty ? "" : ": " + apps.map(\.bundleID).joined(separator: ", ")
				log.append("Apple ID: \(apps.count) of \(FreeAppleID.appsPerDevice) apps signed with a free Apple ID on this \(ThisDevice.name)\(listed)")
				// Atelier runs, so it holds its place, however iOS lists it.
				let place: AppleIDRoom.Place = job.isSelf ? .holds : AppleIDRoom.place(for: bundleID, replacing: job.replacesBundleID, apps: apps)
				switch place {
				case .holds:
					log.append("Apple ID: the app holds one of them already")
				case .free:
					break
				case .full(let holding):
					job.certificates.updateAppleID(account.id) { $0.limits = limits }
					roomTaken = (name, holding)
					throw Self.noRoom(for: name, holding: holding)
				}
			} catch let problem as InstallProblem {
				throw problem
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				log.append("Apple ID: iOS didn't list its apps and profiles, so the install goes ahead without counting them: \(InstallProblem(error).message)")
			}
			try Task.checkCancellation()
		}
		// An app whose App ID the team has uses it again.
		checkingNote = "Checking your Apple ID's App IDs…"
		do {
			let list = try await session.appIDs()
			limits.appIDs = list.limits(checkedAt: .now)
			switch AppleIDRoom.appID(for: bundleID, in: list) {
			case .has(let expires):
				log.append("App ID: the team has \(bundleID)'s\(expires.map { ", until \(Self.logDate($0))" } ?? "")")
				reusedAppID = (bundleID, expires)
			case .adds(let left):
				log.append("App ID: Apple adds one for \(bundleID)\(left.map { ", \($0) of \(list.max ?? FreeAppleID.appIDsPerWeek) left this week" } ?? "")")
				// A free Apple ID's take one of its 10 a week, so the install
				// asks first, unless nobody is there to answer, as for an
				// automatic update (4 Nov 2026).
				if account.isFree, !job.automatic, !job.newAppIDAsked, !job.isSelf {
					job.certificates.updateAppleID(account.id) { $0.limits = limits }
					try await confirmNewAppID(for: job, account: account, name: name, left: left, max: list.max ?? FreeAppleID.appIDsPerWeek)
				}
			case .noneLeft(let next):
				log.append("App ID: none left this week\(next.map { ", the next one comes back at \(Self.logDate($0))" } ?? "")")
				job.certificates.updateAppleID(account.id) { $0.limits = limits }
				// Nothing else signs Atelier for the App ID it runs as.
				throw Self.noAppIDLeft(next: next, others: job.isSelf ? [] : Self.alternatives(for: job, account: account))
			}
		} catch let problem as InstallProblem {
			throw problem
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			log.append("App ID: Apple didn't list the team's App IDs, so the install goes ahead without counting them: \(AppleIDRoute.explain(error, "Apple didn't list them"))")
		}
		job.certificates.updateAppleID(account.id) { $0.limits = limits }
		appleIDPlan = (account.id, bundleID, session)
		try Task.checkCancellation()
	}

	/// Signs in again with the job's Apple ID, asking for Apple's code over
	/// everything when Apple wants it, unless nobody is there to answer, as
	/// for an automatic update.
	private func signIn(_ account: StoredAppleID, job: Job, name: String) async throws -> AppleIDSession {
		let access = AppleIDAccess.shared
		if access.hasSession(for: account) {
			log.append("Apple ID: signed in a moment ago, so not again")
		} else {
			checkingNote = "Signing in to Apple…"
		}
		let started = Date.now
		do {
			let session = try await access.session(for: account, purpose: job.automatic ? nil : "To get \(name)'s profile, Apple wants a code.")
			log.append(String(format: "Apple ID: signed in (%.1f s)", Date.now.timeIntervalSince(started)))
			return session
		} catch AppleIDAccess.Failure.cancelled {
			log.append("Apple ID: the sign-in was cancelled")
			throw CancellationError()
		} catch AppleIDAccess.Failure.codeNeeded {
			log.append("Apple ID: Apple asked for a code, with nobody there to enter it")
			throw InstallProblem("Apple wants a verification code to sign in with your Apple ID. Open Atelier and \(job.isUpdate ? "update" : "install") \(name) there.")
		} catch AppleIDAccess.Failure.failed(let message) {
			log.append("Apple ID: the sign-in stopped: \(message)")
			throw InstallProblem(message, fix: .tryAgain)
		}
	}

	/// The Apple ID's certificate with the app's own profile: Apple adds
	/// the app's App ID first when the team doesn't have it, taking one of
	/// a free Apple ID's 10 this week. The app is signed as its bundle ID
	/// and the team's, its extensions on the same profile. The profile is
	/// written to a file of its own for zsign, which the caller deletes.
	/// The bundle ID an app whose IPA's is `appBundleID` installs as with
	/// `account` (#49): its own and the team ID, as an App ID is unique
	/// across all of Apple, numbered for a copy (#8). A copy installed under
	/// a bundle ID of the user's choosing (#113), in `copy` or else what's
	/// kept for it, keeps that, with the team ID on the end unless it has it.
	static func appleIDBundleID(of appBundleID: String, as target: InstallTarget, copy: CopySettings? = nil, account: StoredAppleID) -> String {
		let numbered = target.bundleID(for: account.bundleID(for: appBundleID))
		guard target != .original, let chosen = (copy ?? CopyStore.shared.settings(for: numbered))?.bundleID else { return numbered }
		let hasTeam = chosen.split(separator: ".").contains { $0.caseInsensitiveCompare(account.team.id) == .orderedSame }
		return hasTeam ? chosen : "\(chosen).\(account.team.id)"
	}

	private func appleIDIdentity(for ipa: URL, account: StoredAppleID, job: Job) async throws -> (identity: SigningIdentity, bundleID: String, profile: URL, appGroups: [String: String]) {
		let info: IPAInfo
		do {
			info = try IPAInfo.read(ipaAt: ipa)
		} catch {
			throw InstallProblem("Couldn't read the app's Info.plist: \(InstallProblem(error).message)")
		}
		// Atelier itself keeps the bundle ID it runs as, which its Apple ID's
		// team has the App ID of (#152).
		let bundleID = job.isSelf ? SelfUpdate.shared.bundleID : Self.appleIDBundleID(of: info.bundleID, as: job.target, copy: job.copyChoice?.settings, account: account)
		let name = job.isSelf ? SelfUpdate.shared.name : job.displayName ?? info.name
		let session: AppleIDSession
		if let plan = appleIDPlan, plan.accountID == account.id {
			session = plan.session
		} else {
			// An IPA from a file signs right after its checks.
			session = try await signIn(account, job: job, name: name)
			checkingNote = nil
		}
		// An App ID the team has, as the checks found (#49).
		if let reused = reusedAppID, reused.bundleID == bundleID {
			signingNote = "Using its App ID again\(reused.until.map { ", until \(Self.day($0))" } ?? "")…"
		} else {
			signingNote = "Getting its profile from Apple…"
		}
		defer { signingNote = nil }
		let groups = await appleIDGroups(of: ipa, appBundleID: info.bundleID, signedBundleID: bundleID, account: account)
		let started = Date.now
		let profile: AppleIDSession.Profile
		do {
			profile = try await session.profile(bundleID: bundleID, name: name, groups: groups.asked.map { groups.names[$0] ?? $0 })
		} catch {
			log.append("profile: Apple didn't give one: \(error)")
			throw InstallProblem(AppleIDRoute.explain(error, "Apple didn't give \(name) a profile"), fix: .tryAgain)
		}
		try Task.checkCancellation()
		let parsed = try? ProvisioningProfile(data: profile.data)
		appleIDProfile = parsed
		let expires = profile.expires ?? parsed?.expirationDate
		let what = profile.added ? "a new App ID and its profile" : "a profile"
		log.append(String(format: "profile: %@ for %@ from Apple in %.1f s%@", what, bundleID, Date.now.timeIntervalSince(started), expires.map { ", until \(Self.logDate($0))" } ?? ""))
		if profile.added {
			// One of the week's App IDs is taken now, whatever the install does.
			job.certificates.updateAppleID(account.id) { stored in
				var limits = stored.limits ?? AppleIDLimits()
				let counts = limits.appIDs ?? AppleIDLimits.AppIDs(checkedAt: .now, max: profile.max, available: profile.available, expiries: [])
				limits.appIDs = counts.adding(expires: profile.appIDExpires, available: profile.available, max: profile.max, identifier: bundleID, name: name)
				stored.limits = limits
			}
		}
		let appGroups = allowedGroups(groups, by: profile)
		// The certificate it's signed with, which the profile Atelier puts
		// on each week has to list for it to keep opening, as it has to
		// allow its App Groups.
		let serial = (job.certificates.appleID(account.id) ?? account).certificate.serialNumber
		let signedGroups = appGroups.isEmpty ? nil : groups.asked.compactMap { appGroups[$0] }
		pendingAppProfile = expires.map { AppProfile(bundleID: bundleID, uuid: profile.uuid ?? parsed?.uuid, expires: $0, certificateSerial: serial, appGroups: signedGroups) }
		let folder = FileManager.default.temporaryDirectory.appending(path: "AppleIDProfiles", directoryHint: .isDirectory)
		let file = folder.appending(path: "\(UUID().uuidString).mobileprovision")
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try profile.data.write(to: file, options: .atomic)
		} catch {
			throw InstallProblem("Couldn't keep the profile Apple gave \(name): \(error.localizedDescription)")
		}
		let identity: SigningIdentity
		do {
			guard let found = try job.certificates.appleIDSigningIdentity(for: account.id, profile: file) else {
				try? FileManager.default.removeItem(at: file)
				throw InstallProblem.noCertificate
			}
			identity = found
		} catch let problem as InstallProblem {
			throw problem
		} catch {
			try? FileManager.default.removeItem(at: file)
			throw InstallProblem("Couldn't read the Apple ID's certificate, which iOS only gives once this \(ThisDevice.name) was unlocked: \(error.localizedDescription)")
		}
		return (identity, bundleID, file, appGroups)
	}

	/// The App Groups the app and its extensions ask for, in the order they
	/// do, with the names the Apple ID's team gives them (#49,
	/// `AppGroups.names`): its App ID gets them before its profile, so the
	/// profile allows them. None when the IPA's binaries don't say, as a
	/// decrypted IPA's often don't.
	private func appleIDGroups(of ipa: URL, appBundleID: String, signedBundleID: String, account: StoredAppleID) async -> (asked: [String], names: [String: String]) {
		let read = await Task.detached(priority: .userInitiated) { Result { try AppGroups.read(ipaAt: ipa) } }.value
		let asked: [String]
		switch read {
		case .success(let groups):
			asked = groups
		case .failure(let error):
			log.append("app groups: couldn't read them from the app, so it goes without: \(error)")
			return ([], [:])
		}
		guard !asked.isEmpty else { return ([], [:]) }
		return (asked, AppGroups.names(for: asked, appBundleID: appBundleID, signedBundleID: signedBundleID, teamID: account.team.id))
	}

	/// The app's App Groups that its profile allows under the team's names,
	/// by the name the app asks for, with what became of each in the log.
	private func allowedGroups(_ groups: (asked: [String], names: [String: String]), by profile: AppleIDSession.Profile) -> [String: String] {
		guard !groups.asked.isEmpty else { return [:] }
		if let problem = profile.groupsError {
			log.append("app groups: Apple didn't give the App ID \(Self.joined(groups.asked)), so the app goes without them: \(problem)")
			return [:]
		}
		let granted = (try? ProvisioningProfile.entitlements(in: profile.data))?[AppGroups.entitlement] as? [String] ?? []
		var allowed: [String: String] = [:]
		var lines: [String] = []
		for group in groups.asked {
			guard let name = groups.names[group] else { continue }
			guard granted.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
				lines.append("\(group) not in the profile")
				continue
			}
			allowed[group] = name
			let added = profile.groupsAdded.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
			lines.append("\(group) as \(name)\(added ? ", added now" : "")")
		}
		log.append("app groups: \(lines.joined(separator: "; "))")
		return allowed
	}

	/// The trust sheet after an install with an Apple ID, when no other app
	/// signed with it was on this iPhone before: iOS asks again once each of
	/// them is deleted. Nobody sees it after an automatic update, whose app
	/// was trusted already.
	private func trustToAsk(after job: Job, installed info: IPAInfo) -> TrustPrompt? {
		guard !job.automatic, !job.isSelf, signsWithAppleID, let account = job.appleID, signedWith == account.id else { return nil }
		let records = (try? job.context.fetch(FetchDescriptor<InstallRecord>())) ?? []
		let others = records.filter { record in
			guard record.certificateID == account.id else { return false }
			// The app it replaced, deleted first or before.
			if record.bundleID == job.replacesBundleID, record.bundleID != info.bundleID { return false }
			if record.bundleID == info.bundleID, job.deletesFirst { return false }
			return Self.presence(of: record) != .deleted
		}
		guard others.isEmpty else { return nil }
		return TrustPrompt(appName: job.displayName ?? info.name, appleID: account.displayName)
	}

	/// After an install with an Apple ID: the app's profile, noted with the
	/// Apple ID for the Library's days left, and the place the app takes
	/// among a free Apple ID's 3.
	private func finishAppleID(_ job: Job, installed info: IPAInfo) {
		// Atelier's own is noted from its build on its next launch (#152).
		guard signsWithAppleID, !job.isSelf, let account = job.appleID, signedWith == account.id else { return }
		let profile = pendingAppProfile
		pendingAppProfile = nil
		let replaced = job.replacesBundleID
		ProfileRenewals.shared.installed(info.bundleID)
		job.certificates.updateAppleID(account.id) { stored in
			if let profile { stored.note(profile) }
			if stored.isFree, let apps = stored.limits?.apps {
				stored.limits?.apps = apps.installing(FreeApp(bundleID: info.bundleID, name: info.name, teamID: stored.team.id), replacing: replaced)
			}
		}
	}

	/// Takes the Library entry of the app the install took the place of
	/// off, when that one had another bundle ID: signed with an Apple ID,
	/// or no longer with one. It was deleted first, or by the user before.
	private func removeReplaced(_ job: Job, installedAs bundleID: String) {
		guard let old = job.replacesBundleID, old != bundleID, let record = InstalledApps.record(old, in: job.context) else { return }
		if let account = job.certificates.appleID(record.certificateID) {
			job.certificates.updateAppleID(account.id) { stored in
				stored.profiles?.removeAll { $0.bundleID == old }
				if let apps = stored.limits?.apps {
					stored.limits?.apps = AppleIDLimits.Apps(checkedAt: apps.checkedAt, apps: apps.apps.filter { $0.bundleID != old })
				}
			}
		}
		log.append("library: \(old) goes, as the app installs as \(bundleID) now")
		InstalledIcons.shared.remove(for: old)
		// And the one its tint or picture covered (#155).
		InstalledIcons.own.remove(for: old)
		job.context.delete(record)
		try? job.context.save()
	}

	/// An install with a free Apple ID that iOS would refuse: 3 apps signed
	/// with one are on this iPhone already, whichever Apple ID signed them.
	/// Make Room disables one of them, then installs.
	private static func noRoom(for name: String, holding apps: [FreeApp]) -> InstallProblem {
		InstallProblem(
			"This \(ThisDevice.name) already has \(apps.count) apps signed with a free Apple ID, as many as iOS allows: \(joined(apps.map(\.name))).",
			detail: "Make Room offloads one of them, keeping its data, then installs \(name). Apps signed with another Apple ID, or by another app such as SideStore, count too: delete those from the Home Screen.",
			fix: .makeRoom
		)
	}

	/// A free Apple ID's 10 new App IDs this week are taken. For a new app,
	/// its details offer what else can sign it, as the question before a
	/// new App ID lists them: another free Apple ID has 10 of its own.
	private static func noAppIDLeft(next: Date?, others: [SigningChoice]) -> InstallProblem {
		let message = next.map { date in
			let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
			return "Your Apple ID is allowed a new app again on \(day), at \(date.formatted(date: .omitted, time: .shortened))."
		} ?? "Your Apple ID added as many new apps this week as Apple allows."
		return InstallProblem(
			message,
			detail: "A free Apple ID adds 10 new App IDs a week, one for each app it installs that the team has none for, and each comes back 7 days after it was added. Apps the team has an App ID for still install. Each free Apple ID has 10 of its own, so signing in with another adds 10 more a week.",
			fix: others.isEmpty ? nil : .anotherCertificate
		)
	}

	/// What a new app can install with instead of the free Apple ID
	/// `account` (#49): none for an install that takes an app's place,
	/// which keeps what that was signed with, as anything else signs it as
	/// another bundle ID.
	private static func alternatives(for job: Job, account: StoredAppleID) -> [SigningChoice] {
		let replaces = job.isUpdate || job.deletesFirst || job.restoresData || job.replacesBundleID != nil
		return replaces ? [] : job.certificates.choices(insteadOf: account)
	}

	/// What the failed install can install with instead of its free Apple
	/// ID, which had no new App ID left this week (#49).
	var otherSigners: [SigningChoice] {
		guard let job = retryJob, let account = job.appleID, account.isFree else { return [] }
		return Self.alternatives(for: job, account: account)
	}

	// MARK: A new App ID (#49)

	/// What the check before an install with a free Apple ID asks while
	/// the install waits, when Apple would add the app an App ID, one of
	/// the 10 a week (4 Nov 2026): Install, or for a new app, Install
	/// with Another Certificate…, which lists the others that can sign it:
	/// another free Apple ID takes one of its own 10, the rest none.
	/// Closing it stops the install, and deletes the download it started.
	struct AppIDQuestion: Identifiable {
		enum Verb {
			case install, update, reinstall

			var title: String {
				switch self {
				case .install: "Install"
				case .update: "Update"
				case .reinstall: "Reinstall"
				}
			}

			var gerund: String {
				switch self {
				case .install: "Installing"
				case .update: "Updating"
				case .reinstall: "Reinstalling"
				}
			}
		}

		let id = UUID()
		let verb: Verb
		let appName: String
		let iconURL: URL?
		let appleID: StoredAppleID
		/// The new App IDs left this week, as Apple said, before this one;
		/// nil when it didn't say.
		let left: Int?
		let max: Int
		/// When the App ID Apple adds comes back, 7 days on: until then, the
		/// app installs again and updates without another.
		let until: Date
		/// What can sign the app instead, for a new app, as Install with
		/// Another Certificate… lists them.
		let others: [SigningChoice]
	}

	enum AppIDAnswer: Equatable {
		case install
		case installWith(UUID)
		case cancel
	}

	/// The question the running install waits on, which a sheet shows.
	private(set) var appIDQuestion: AppIDQuestion?
	@ObservationIgnored private var appIDAnswer: CheckedContinuation<AppIDAnswer, Never>?

	/// Asks before Apple adds the app an App ID. Install goes on; another
	/// certificate's install runs in this one's place, and Close stops it.
	private func confirmNewAppID(for job: Job, account: StoredAppleID, name: String, left: Int?, max: Int) async throws {
		let others = Self.alternatives(for: job, account: account)
		// Installing a deleted app again is no update.
		let replaced = job.replacesBundleID.flatMap { InstalledApps.record($0, in: job.context) }
		let updates = job.isUpdate && replaced.map { Self.presence(of: $0) != .deleted } ?? false
		let question = AppIDQuestion(
			verb: job.restoresData ? .reinstall : updates ? .update : .install,
			appName: name,
			iconURL: job.iconURL,
			appleID: account,
			left: left,
			max: max,
			until: .now.addingTimeInterval(AppProfileDays.free),
			others: others
		)
		switch await askAboutAppID(question) {
		case .install:
			log.append("App ID: a new one, as asked")
		case .cancel:
			log.append("App ID: cancelled, before Apple added one")
			throw CancellationError()
		case .installWith(let id):
			var other = job
			other.certificateID = id
			other.certificatePicked = true
			// Another free Apple ID's row said it takes a new App ID.
			other.newAppIDAsked = true
			// An Apple ID by its team, as the log never holds its address.
			let with: String = switch others.first(where: { $0.id == id }) {
			case .certificate(let certificate)?: certificate.displayName
			case .appleID(let chosen)?: "\(chosen.isFree ? "the free" : "the paid") Apple ID of team \(chosen.team.id)"
			case nil: "another certificate"
			}
			log.append("App ID: installing with \(with) instead")
			// This install ends unseen; the other one's runs next in its
			// place. Not as cancelled, which would drop its download.
			followUp = other
			throw InstallProblem("\(name) installs with \(with) instead.")
		}
	}

	/// Shows `question` and waits for the answer. Cancelling the install
	/// answers Close.
	private func askAboutAppID(_ question: AppIDQuestion) async -> AppIDAnswer {
		let id = question.id
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				appIDAnswer = continuation
				appIDQuestion = question
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.answerAppID(id, .cancel) }
		}
	}

	/// The sheet's answer to the question with `id`.
	func answerAppID(_ id: UUID, _ answer: AppIDAnswer) {
		guard appIDQuestion?.id == id, let continuation = appIDAnswer else { return }
		appIDQuestion = nil
		appIDAnswer = nil
		continuation.resume(returning: answer)
	}

	/// "Mon 9 Nov", as the install bar says a day.
	private static func day(_ date: Date) -> String {
		date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
	}

	/// "30sec, Mosaic and SideStore".
	private static func joined(_ names: [String]) -> String {
		guard let last = names.last else { return "" }
		guard names.count > 1 else { return last }
		return names.dropLast().joined(separator: ", ") + " and " + last
	}

	/// A date as the install log writes it.
	private static func logDate(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .shortened)
	}

	// MARK: The app already on this iPhone (#99)

	/// What the check before an install asks while the install waits: what
	/// to do about the app on this iPhone that iOS won't replace with it.
	struct ConflictQuestion: Identifiable {
		let id = UUID()
		let conflict: InstalledConflict
		/// Whether the app can install as a copy instead.
		let canCopy: Bool
	}

	enum ConflictAnswer {
		case importCertificate
		case copy
		case deleteAndInstall
		case cancel
	}

	/// The app signed for an install iOS refused, with what its signing
	/// noted for the Library, sent again once the app in its way is deleted.
	struct SignedApp {
		let package: InstallPackage
		let certificateID: UUID?
		let certificateName: String?
		let identity: SignedAppIdentity?
		let icon: Data?
		let copy: SignedCopy?
		let permissions: SignedPermissions?
		let limits: [String]
	}

	/// What a copy (#113), or an app itself (#155), was signed with, kept
	/// for it once it's installed.
	struct SignedCopy {
		/// The bundle ID its copy number gives it, which `CopyStore` keeps
		/// it by: the app's own, for the app itself.
		let numberedID: String
		let choice: CopyChoice
		/// Its IPA's version and build, which its Library entry has,
		/// whatever version it says it is, so its updates still show.
		let version: String
		let buildVersion: String?
		/// Its IPA's icon, under the tint or picture it was signed with, for
		/// the pictures of new ones (#155); nil when it has neither.
		var ownIcon: Data?
	}

	/// The question the running install waits on, which an alert shows.
	private(set) var conflictQuestion: ConflictQuestion?
	@ObservationIgnored private var conflictAnswer: CheckedContinuation<ConflictAnswer, Never>?
	/// What the user's answer turned the running install into, which runs
	/// next in its place.
	@ObservationIgnored private var followUp: Job?
	/// The install whose log goes on from the one before it.
	@ObservationIgnored private var continuesLog: String?
	/// The certificate the running install signs with instead of its own,
	/// as the app on this iPhone was installed with it.
	@ObservationIgnored private var switchedCertificate: UUID?
	/// What the install bar says while it signs with that one.
	private(set) var signingNote: String?
	/// The bundle ID the running install asked installd about, and the one
	/// installd answered for, whose record then says more than Atelier's.
	@ObservationIgnored private var checkedBundleID: String?
	@ObservationIgnored private var answeredBundleID: String?
	/// The signed app of the failed install, for Delete and Install.
	@ObservationIgnored private var refusedApp: SignedApp?

	/// The job as the running install signs it: with the certificate the app
	/// on this iPhone was installed with, when the check before the install
	/// found it among Atelier's.
	private func signing(_ job: Job) -> Job {
		guard let switchedCertificate else { return job }
		var job = job
		job.certificateID = switchedCertificate
		return job
	}

	/// Before anything is downloaded, signed or sent to iOS: asks installd
	/// about the app on this iPhone under the bundle ID this one installs
	/// as. iOS only replaces it with an app signed for the same App ID
	/// (TN2319), so the install signs with the certificate it was installed
	/// with when Atelier has it, and otherwise asks what to do, rather than
	/// fail after the download, the signing and the upload. Returns whether
	/// the certificate to sign with changed. Only Direct installs can ask;
	/// an app deleted first leaves nothing in the way, and Atelier's own
	/// install keeps its App ID anyway (#24).
	private func checkInstalled(_ job: Job, installer: any Installer, ipa: URL?) async throws -> Bool {
		guard installer.route == .pairing, !job.deletesFirst, !job.isSelf else { return false }
		let info = ipa.flatMap { try? IPAInfo.read(ipaAt: $0) }
		guard let bundleID = expectedBundleID(of: job, info: info), bundleID != checkedBundleID else { return false }
		checkedBundleID = bundleID
		answeredBundleID = nil
		let switched = switchedCertificate
		switchedCertificate = nil
		signingNote = nil
		let started = Date.now
		let record: InstalledAppRecord?
		do {
			record = try await pairingInstaller.appRecord(of: bundleID)
		} catch {
			log.append("installed app: iOS couldn't be asked about \(bundleID), so the install goes ahead: \(InstallProblem(error).message)")
			return switched != nil
		}
		try Task.checkCancellation()
		answeredBundleID = bundleID
		let took = String(format: "%.1f s", Date.now.timeIntervalSince(started))
		guard let record else {
			log.append("installed app: none as \(bundleID) (asked in \(took))")
			return switched != nil
		}
		log.append("installed app: \(record.displayName) \(record.version) as \(bundleID), \(record.signing) (asked in \(took))")
		guard let certificate = job.certificate else { return switched != nil }
		let name = appName(of: job, info: info)
		let decision = InstalledAppSigning.decide(
			installed: record,
			appName: name,
			certificate: certificate,
			certificates: Self.preferredCertificates(job.certificates),
			picked: job.certificatePicked
		)
		switch decision {
		case .proceed:
			if let appID = record.applicationIdentifier {
				log.append("installed app: signed for \(appID), as \(certificate.displayName) signs, so iOS replaces it")
			} else {
				log.append("installed app: its App ID isn't given, so the install goes ahead")
			}
			return switched != nil
		case .switchTo(let other):
			switchedCertificate = other.id
			// As for the certificate it was queued with: a direct install may
			// still be running once the iPhone locks (#72).
			if job.automatic || BackgroundInstalls.shared.mayInstallDirectly {
				HeldSecrets.shared.hold(certificate: other.id, from: job.certificates)
			}
			let installedName = record.displayName.isEmpty ? name : record.displayName
			signingNote = "Signing with \(other.displayName), which \(installedName) is installed with…"
			log.append("installed app: signed for \(other.profile.applicationIdentifier), as \(other.displayName) signs, so it's signed with \(other.displayName) rather than \(certificate.displayName), and iOS replaces it")
			return switched != other.id
		case .conflict(let conflict):
			log.append("installed app: \(conflict.failure)")
			// Nobody to ask during a background update run (#72): its
			// failure has the same choices.
			guard !job.automatic else { throw InstallProblem.cantReplace(conflict) }
			let target = Self.copyTarget(of: job, original: bundleID, installed: bundleID)
			switch await ask(ConflictQuestion(conflict: conflict, canCopy: target != nil)) {
			case .cancel:
				log.append("installed app: cancelled")
				throw CancellationError()
			case .importCertificate:
				log.append("installed app: importing a certificate instead")
				if !importsAfterDetails { job.certificates.beginImport() }
				throw CancellationError()
			case .copy:
				guard let target, let copy = Self.copy(job, as: target) else { throw CancellationError() }
				log.append("installed app: installing \(name) as a copy instead, \(target.bundleID(for: bundleID))")
				followUp = copy
			case .deleteAndInstall:
				var replacing = job
				replacing.deletesFirst = true
				replacing.keepsData = conflict.keepsData
				log.append("installed app: deleting \(conflict.installedName) once \(name) is signed, \(conflict.keepsData ? "keeping its data" : "with its data")")
				followUp = replacing
			}
			// This install ends unseen; the answer's runs next in its place.
			throw InstallProblem.cantReplace(conflict)
		}
	}

	/// Shows `question` and waits for the answer. Cancelling the install
	/// answers Cancel.
	private func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
		let id = question.id
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				conflictAnswer = continuation
				conflictQuestion = question
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.answerConflict(id, .cancel) }
		}
	}

	/// The alert's answer to the question with `id`.
	func answerConflict(_ id: UUID, _ answer: ConflictAnswer) {
		guard conflictQuestion?.id == id, let continuation = conflictAnswer else { return }
		conflictQuestion = nil
		conflictAnswer = nil
		// The import can't show over the install's details, which the alert
		// closes: it opens once they're closed.
		if answer == .importCertificate, detailsOpen { importsAfterDetails = true }
		continuation.resume(returning: answer)
	}

	/// After iOS refused an install over the app it has: what that app is,
	/// from installd's record, which the setup reaches right after an
	/// install, else, for an app installd doesn't list, such as an
	/// offloaded one, from the App ID iOS's refusal named, `installedAppID`.
	/// Nil when that can't be told, or when a certificate Atelier has would
	/// do, which Install with Another Certificate offers.
	private func conflictAfterRefusal(_ job: Job, bundleID: String, info: IPAInfo?, installedAppID: String?) async -> InstalledConflict? {
		let record: InstalledAppRecord?
		do {
			record = try await pairingInstaller.appRecord(of: bundleID)
		} catch {
			log.append("installed app: iOS couldn't be asked about \(bundleID): \(InstallProblem(error).message)")
			return nil
		}
		guard let record else {
			log.append("installed app: none as \(bundleID)")
			guard let installedAppID, let certificate = signing(job).certificate else { return nil }
			// In #99's test, AltStore Classic, offloaded, was in none of
			// installd's lists, asked six ways.
			log.append("installed app: iOS named the App ID of the app it has, \(installedAppID), but doesn't list that app, as for an offloaded one")
			let decision = InstalledAppSigning.decideUnlisted(
				appID: installedAppID,
				bundleID: bundleID,
				installedName: info?.name ?? "",
				appName: appName(of: job, info: info),
				certificate: certificate,
				certificates: Self.preferredCertificates(job.certificates)
			)
			switch decision {
			case .conflict(let conflict):
				return conflict
			case .switchTo(let other):
				log.append("installed app: signed for \(installedAppID), as \(other.displayName) signs")
				return nil
			case .proceed:
				return nil
			}
		}
		log.append("installed app: \(record.displayName) \(record.version) as \(bundleID), \(record.signing)")
		guard let certificate = signing(job).certificate else { return nil }
		let decision = InstalledAppSigning.decide(
			installed: record,
			appName: appName(of: job, info: info),
			certificate: certificate,
			certificates: Self.preferredCertificates(job.certificates),
			picked: job.certificatePicked
		)
		switch decision {
		case .conflict(let conflict):
			return conflict
		case .switchTo(let other):
			log.append("installed app: signed for \(other.profile.applicationIdentifier), as \(other.displayName) signs")
			return nil
		case .proceed:
			return nil
		}
	}

	/// The bundle ID the app installs as: its IPA's, once there is one; else
	/// the one Atelier installed it as before, or its source lists it
	/// under, which its IPA may not have (#116).
	private func expectedBundleID(of job: Job, info: IPAInfo?) -> String? {
		// Atelier itself keeps the bundle ID it runs as (#24, #152).
		if job.isSelf { return SelfUpdate.shared.bundleID }
		// An Apple ID signs it as its bundle ID and the team's (#49).
		if let account = job.appleID {
			if let info { return Self.appleIDBundleID(of: info.bundleID, as: job.target, copy: job.copyChoice?.settings, account: account) }
			guard let listed = job.listedBundleID else { return nil }
			let own = InstalledApps.record(listedAs: listed, as: job.target, in: job.context)?.ipaBundleID ?? listed
			return Self.appleIDBundleID(of: own, as: job.target, copy: job.copyChoice?.settings, account: account)
		}
		// The one chosen for a copy (#113).
		if job.target != .original, let chosen = job.copyChoice?.settings.bundleID { return chosen }
		if let info { return InstalledApps.bundleID(of: job.target, for: info.bundleID) }
		guard let listed = job.listedBundleID else { return nil }
		return InstalledApps.record(listedAs: listed, as: job.target, in: job.context)?.bundleID ?? InstalledApps.bundleID(of: job.target, for: listed)
	}

	/// The app's name as the check says it: a copy's own, else as its
	/// source lists it, else its IPA's.
	private func appName(of job: Job, info: IPAInfo?) -> String {
		if let name = job.displayName { return name }
		switch job.input {
		case .source(let source): return source.app.name
		case .download(let download, _) where !download.isFromURL: return download.name
		default: return info?.name ?? job.title
		}
	}

	/// Atelier's certificates in the order an install tries them: the
	/// default first, then as Settings lists them.
	private static func preferredCertificates(_ certificates: CertificatesModel) -> [StoredCertificate] {
		let defaultID = certificates.defaultID
		return certificates.certificates.filter { $0.id == defaultID } + certificates.certificates.filter { $0.id != defaultID }
	}

	/// The app signed for an install iOS refused, which `job` sends again,
	/// while it's still there.
	private static func reused(_ job: Job) -> SignedApp? {
		guard let signed = job.signedApp, FileManager.default.fileExists(atPath: signed.package.url.path) else { return nil }
		return signed
	}

	/// Deletes the signed app kept for Delete and Install.
	private func dropRefusedApp() {
		guard let refused = refusedApp else { return }
		refusedApp = nil
		try? FileManager.default.removeItem(at: refused.package.url)
	}

	private static func size(of file: URL) -> Int64? {
		(try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
	}

	/// Free space for the install's checks, counting what iOS would free up
	/// for something the user asked for.
	private static var freeSpace: Int64? {
		let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
		return values?.volumeAvailableCapacityForImportantUsage
	}

	/// After an install iOS took: the Library entry, the download or the
	/// picked file's copy, and what Install again would run if it isn't
	/// confirmed.
	private func finish(_ job: Job, package: InstallPackage, result: InstallResult) {
		let info = package.info
		let confirmed = result != .unconfirmed
		// iOS installed an app this run signed, so this iPhone is in the
		// certificate's profile (#45).
		if confirmed, let signedWith { job.certificates.deviceConfirmed(by: signedWith) }
		switch job.input {
		case .download(let download, let downloads):
			finishDownload(job, id: download.id, sourceURL: download.sourceURL, downloads: downloads, package: package, confirmed: confirmed)
		case .source(let source):
			if let id = source.downloadID {
				finishDownload(job, id: id, sourceURL: source.sourceURL, downloads: source.downloads, package: package, confirmed: confirmed)
			}
		case .picked(let file):
			record(info, sourceURL: nil, listedAs: nil, ipaLink: nil, in: job.context)
			// Probably installed: its copy is kept while the status shows, in
			// case it wasn't, as a download is.
			if !confirmed {
				retryJob = job
				keptPicked = file
			}
		case .putBack, .disable, .ownApp:
			// Atelier's own install never gets here: it closes Atelier (#24).
			break
		}
	}

	private func finishDownload(_ job: Job, id: UUID, sourceURL: URL?, downloads: DownloadManager, package: InstallPackage, confirmed: Bool) {
		record(package.info, sourceURL: sourceURL, listedAs: job.listedBundleID, ipaLink: job.ipaLink, in: job.context)
		if confirmed {
			// Installed, so the download has done its job.
			downloads.remove(id)
		} else {
			// Probably installed: kept while the status shows, in case it wasn't.
			keptDownload = (id, downloads)
			retryJob = job
		}
	}

	private func recordAttempt(_ attempt: Attempt, outcome: Result<InstallResult, Error>) {
		let result: InstallAttempt.Result
		var error: String?
		switch outcome {
		case .success(.confirmed): result = .confirmed
		case .success(.unconfirmed): result = .unconfirmed
		case .failure(let failure) where failure is CancellationError:
			result = .cancelled
		case .failure(let failure):
			result = .failed
			error = Self.message(for: failure)
		}
		let entry = InstallAttempt(
			bundleID: attempt.bundleID,
			name: attempt.name,
			version: attempt.version,
			certificate: attempt.certificate,
			route: attempt.route,
			startedAt: attempt.startedAt,
			finishedAt: .now,
			result: result,
			error: error,
			limits: limits.isEmpty ? nil : limits,
			log: log,
			origin: attempt.origin,
			automatic: attempt.automatic
		)
		try? InstallHistory.standard().record(entry)
	}

	private static func message(for error: Error) -> String {
		error is CancellationError ? "Install cancelled." : InstallProblem(error).message
	}

	/// Closes a successful install's status after a moment, unless another
	/// install has started since.
	private func dismissLater(_ run: Int, after delay: Duration) {
		Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard let self, self.runCount == run, !self.isRunning, self.queue.isEmpty else { return }
			if case .failed = self.state { return }
			if self.detailsOpen {
				self.barHidden = true
			} else {
				self.reset()
			}
		}
	}

	/// Extra time in the background, given back when iOS asks for it.
	private final class BackgroundTask {
		private var identifier = UIBackgroundTaskIdentifier.invalid

		init(name: String) {
			// iOS calls this on the main thread.
			identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
				MainActor.assumeIsolated { self?.end() }
			}
		}

		func end() {
			guard identifier != .invalid else { return }
			UIApplication.shared.endBackgroundTask(identifier)
			identifier = .invalid
		}
	}

	/// Where picked and signed IPAs wait to be installed.
	private static var installsFolder: URL {
		FileManager.default.temporaryDirectory.appending(path: "Installs", directoryHint: .isDirectory)
	}

	/// Copies the picked file into Atelier's temporary folder, where the
	/// loopback server can read it after the picker's access ends. A file
	/// opened in Atelier is already a copy, in Documents/Inbox, so it's
	/// moved instead (#93).
	private static func stage(_ picked: URL) throws -> URL {
		let folder = installsFolder
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let destination = folder.appending(path: "\(UUID().uuidString).ipa")
		if picked.pathComponents.suffix(2).first == "Inbox" {
			try FileManager.default.moveItem(at: picked, to: destination)
			return destination
		}
		let scoped = picked.startAccessingSecurityScopedResource()
		defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
		try FileManager.default.copyItem(at: picked, to: destination)
		return destination
	}

	/// Notes the install, by the bundle ID iOS has it under, with the one
	/// its source lists it under, `listed`, which its IPA may not have
	/// (#116), and for an IPA from a link, the link (#113).
	private func record(_ info: IPAInfo, sourceURL: URL?, listedAs listed: String?, ipaLink: URL?, in context: ModelContext) {
		var info = info
		if let signedCopy {
			// First, as the record's copy number comes from it when it's
			// installed under a bundle ID of the user's choosing (#113).
			try? CopyStore.shared.save(signedCopy.choice.settings, picture: signedCopy.choice.picture, for: signedCopy.numberedID)
			// The version it is, rather than the one it says, so its updates
			// show.
			if signedCopy.choice.settings.version != nil {
				info.version = signedCopy.version
				info.buildVersion = signedCopy.buildVersion
			}
		}
		let bundleID = info.bundleID
		let existing = try? context.fetch(FetchDescriptor<InstallRecord>(predicate: #Predicate { $0.bundleID == bundleID })).first
		if let existing {
			existing.name = info.name
			existing.version = info.version
			existing.buildVersion = info.buildVersion
			existing.installedAt = .now
			existing.sourceURL = sourceURL
			if let signedWith { existing.certificateID = signedWith }
			if let signedAs {
				existing.note(signedAs, listedAs: listed)
				existing.limits = limits
				existing.signedPermissions = permissions
			}
			InstalledApps.give(InstallCheck.scheme(of: info), to: existing, in: context)
		} else {
			let record = InstallRecord(bundleID: info.bundleID, name: info.name, version: info.version)
			record.buildVersion = info.buildVersion
			record.sourceURL = sourceURL
			record.certificateID = signedWith
			if let signedAs {
				record.note(signedAs, listedAs: listed)
				record.limits = limits
				record.signedPermissions = permissions
			}
			context.insert(record)
			InstalledApps.give(InstallCheck.scheme(of: info), to: record, in: context)
		}
		// The icon iOS shows, which can be another app's than the one its
		// source lists (#118); without one in its IPA, its source's.
		if let signedIcon {
			InstalledIcons.shared.save(signedIcon, for: bundleID)
		} else {
			InstalledIcons.shared.remove(for: bundleID)
		}
		// And the one its tint or picture covers, for the pictures of new
		// ones (#155).
		if let own = signedCopy?.ownIcon {
			InstalledIcons.own.save(own, for: bundleID)
		} else {
			InstalledIcons.own.remove(for: bundleID)
		}
		// The link its IPA came from, for Custom Install… and Re-sign; none
		// for an app from a source, or from an IPA file, which Atelier can't
		// find again (#113).
		noteIPALink(sourceURL == nil ? ipaLink : nil, for: bundleID)
		try? context.save()
	}
}

/// Atelier's own install through the route picked (#24). Right before iOS
/// gets it, it's noted for Atelier's next launch, or goes back in the
/// queue behind installs queued meanwhile. Once iOS has it, the install bar
/// says to go to the Home Screen, and Atelier closes as it leaves the
/// screen: iOS installs over an app only once it isn't running.
@MainActor
private final class SelfInstaller: Installer {
	private let base: any Installer
	private let job: InstallModel.Job
	private weak var model: InstallModel?

	init(_ base: any Installer, job: InstallModel.Job, model: InstallModel) {
		self.base = base
		self.job = job
		self.model = model
	}

	var route: InstallRoute { base.route }

	func healthCheck() async -> RouteHealth {
		await base.healthCheck()
	}

	func install(_ package: InstallPackage, events: @escaping @MainActor (InstallEvent) -> Void) async throws -> InstallResult {
		guard let model else { throw CancellationError() }
		try model.selfInstallStarts(job, package: package, route: base.route)
		let job = job
		do {
			_ = try await base.install(package) { [weak model] event in
				events(event)
				// iOS has the whole app.
				if case .phase(.installing) = event { model?.handOver(job) }
			}
			model.handOver(job)
			try await model.waitForClose()
			throw CancellationError()
		} catch {
			model.selfInstallEnded()
			throw error
		}
	}
}

/// The last Direct installs scan (#17), kept across launches. It tells
/// whether apps without a check scheme are still installed. Observed, so
/// the Library and app details update once a scan finishes.
@MainActor
@Observable
final class DeviceScanStore {
	static let shared = DeviceScanStore()
	private static let defaultsKey = "deviceScan"

	private(set) var scan: DeviceScan?

	private init() {
		scan = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(DeviceScan.self, from: $0) }
	}

	func save(_ scan: DeviceScan) {
		self.scan = scan
		if let data = try? JSONEncoder().encode(scan) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}
}
