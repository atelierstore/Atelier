import CertKit
import Foundation
import InstallKit
import SigningKit

// The one-tap install (#16): checks, download, signing and install as one
// job with one progress, which the app's install queue runs. Everything the
// job touches outside itself (the certificate, the install route, free space,
// the download and signing) comes in through `InstallPipeline.Dependencies`
// and `PipelineDownload`, so each step and failure is tested with stand-ins.
//
// Signing fits the app's entitlements to the profile (#7), and the app
// shows what won't work once the app is signed, rather than in a review
// step that would cost the one tap. Apps keep their own bundle ID, apart
// from the numbered copies the user installs next to them (#8,
// `InstallTarget`).

/// Where one install is at.
public enum InstallStage: Equatable, Sendable {
	/// Checking the certificate, the install route, free space and the app
	/// already on this device (#99).
	case checking
	/// Downloading the IPA, with the fraction done when the size is known.
	case downloading(Double?)
	case signing(SigningProgress)
	/// The route has the signed app.
	case installing(IPAInfo, InstallPhase)
	case finished(IPAInfo, InstallResult)
	case failed(InstallProblem)
	case cancelled

	/// Whether the install is still going.
	public var isActive: Bool {
		switch self {
		case .checking, .downloading, .signing, .installing: true
		case .finished, .failed, .cancelled: false
		}
	}

	/// The stages in the order they run; the ended ones share the last place.
	fileprivate var order: Int {
		switch self {
		case .checking: 0
		case .downloading: 1
		case .signing: 2
		case .installing: 3
		case .finished, .failed, .cancelled: 4
		}
	}

	/// The whole install's progress, for the Install button's ring: the
	/// download takes the first 60 %, signing the next 20 % and the install
	/// the rest. A picked file or an IPA that's already signed starts
	/// further along.
	public var overallFraction: Double {
		switch self {
		case .checking: 0
		case .downloading(let fraction): 0.6 * (fraction ?? 0)
		case .signing(.unpacking(let fraction)): 0.6 + 0.1 * fraction
		case .signing(.signing): 0.7
		case .signing(.packing(let fraction)): 0.7 + 0.1 * fraction
		case .installing(_, .connecting), .installing(_, .waitingForApproval), .installing(_, .alertClosed): 0.8
		// Before the old app is deleted (#96).
		case .installing(_, .copyingData): 0.8
		case .installing(_, .downloading(let fraction)): 0.8 + 0.1 * fraction
		case .installing(_, .installing(let fraction)): 0.9 + 0.1 * (fraction ?? 0)
		// Once the new one is in, or from the Library's Put Back.
		case .installing(_, .restoringData(let fraction)): 0.95 + 0.05 * (fraction ?? 0)
		case .finished, .failed, .cancelled: 1
		}
	}
}

/// Why an install stopped, said once, with what fixes it when Atelier can
/// take the user there.
public struct InstallProblem: Error, Equatable, Sendable, CustomStringConvertible {
	public enum Fix: Equatable, Sendable {
		/// Import a certificate (Settings › Installs › Certificates).
		case importCertificate
		/// Check the install settings, such as the manifest endpoint.
		case installSettings
		/// Free up space, starting with Atelier's own downloads and kept apps.
		case freeSpace
		/// Nothing to change: trying again may work.
		case tryAgain
		/// The app may already be installed another way, which iOS won't
		/// replace (#76): install it with another certificate, or as a copy.
		case replaceInstalled
		/// GitHub can't find the app's file without an account, as for a
		/// private repo's: sign in, then try again (#134).
		case signInToGitHub
		/// A free Apple ID can't add the app's App ID this week: install
		/// with an imported certificate instead (#49).
		case anotherCertificate
		/// The 3 places a free Apple ID's apps have on the iPhone are all
		/// taken: disable one of the apps, then install (#49).
		case makeRoom
	}

	public var message: String
	/// More on what else it may be, in smaller print under the message.
	public var detail: String?
	public var fix: Fix?
	/// Why the app's data couldn't be copied, when that's what stopped the
	/// install (#96), for Re-sign's question.
	public var dataFailure: AppDataCopyFailure?
	/// The app on this iPhone that iOS won't replace with this one, when
	/// that's what stopped the install (#99), for what to do about it.
	public var conflict: InstalledConflict?
	/// The App ID of the app iOS wouldn't replace, as installd's refusal
	/// names it (#99): the only place iOS names it for an app installd
	/// lists nowhere, such as an offloaded one.
	public var installedAppID: String?
	/// What failed in its own words, such as iOS's error, which the message
	/// leaves out: for the install log only (5 Nov 2026).
	public var technical: String?

	public init(_ message: String, detail: String? = nil, fix: Fix? = nil) {
		self.message = message
		self.detail = detail
		self.fix = fix
	}

	public var description: String { message }

	public static let noCertificate = InstallProblem(
		"No certificate to sign with. Import one in Settings › Installs › Certificates.",
		fix: .importCertificate
	)

	public static func certificateRevoked(_ name: String) -> InstallProblem {
		InstallProblem(
			"Apple revoked “\(name)”, so apps signed with it won't open. Import another certificate.",
			fix: .importCertificate
		)
	}

	public static func certificateExpired(_ name: String, on date: Date) -> InstallProblem {
		InstallProblem(
			"“\(name)” expired on \(date.formatted(date: .abbreviated, time: .omitted)). Apps signed with it won't open. Import a new certificate.",
			fix: .importCertificate
		)
	}

	public static func notEnoughSpace(needed: Int64, available: Int64) -> InstallProblem {
		let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
		return InstallProblem(
			"There isn't enough free space. Installing this app needs about \(format(needed)), and \(format(max(available, 0))) is free.",
			fix: .freeSpace
		)
	}

	/// iOS had the whole app and didn't install it (#76). Most often the app
	/// is already on this iPhone, from another app such as Feather or signed
	/// with another certificate: iOS refuses to replace an app with one
	/// signed for another App ID (Apple's TN2319). Atelier only knows the
	/// apps it installed itself, so it can't tell for sure.
	public static func notInstalled(_ name: String?) -> InstallProblem {
		let device = ThisDevice.name
		return InstallProblem(
			"\(name ?? "The app") wasn't installed. If it's already on this \(device) from another app or certificate, delete it first and try again; its data will be lost.",
			detail: "Otherwise your certificate may not be registered for this \(device), or \(name ?? "the app") may need a newer iOS.",
			fix: .replaceInstalled
		)
	}

	/// Route A: installd said why, refusing to replace the installed app with
	/// one signed for another App ID ("MismatchedApplicationIdentifierEntitlement",
	/// Apple's TN2319), so Atelier can say it for certain (#76).
	public static func appIDMismatch(_ name: String?) -> InstallProblem {
		let device = ThisDevice.name
		return InstallProblem(
			"\(name ?? "The app") wasn't installed: the one on this \(device) was installed with a different certificate.",
			detail: "Install it with that certificate, or as a second app next to it. Or delete \(name ?? "the app") first; its data will be lost.",
			fix: .replaceInstalled
		)
	}

	/// The app on this iPhone that iOS won't replace with this one, as
	/// installd's record of it says (#99): before anything is downloaded,
	/// or once iOS refused the install.
	public static func cantReplace(_ conflict: InstalledConflict) -> InstallProblem {
		var problem = InstallProblem(conflict.failure, fix: .replaceInstalled)
		problem.conflict = conflict
		return problem
	}

	/// The app's data couldn't be copied aside before it was to be deleted
	/// to be installed again, so it wasn't deleted (#96). Said under the
	/// app's name, as the install bar and the history show it.
	public static func dataNotCopied(_ why: AppDataCopyFailure) -> InstallProblem {
		let message = "Couldn't copy its data, so it wasn't deleted."
		var problem: InstallProblem
		switch why {
		case .brokeOff(let detail):
			problem = InstallProblem(message, detail: "Copying it was interrupted. Check that you're on Wi-Fi with LocalDevVPN connected, then try again.", fix: .tryAgain)
			problem.technical = detail
		case .refused(let answer):
			problem = InstallProblem(message, detail: "iOS doesn't let Atelier copy this app's data.")
			problem.technical = "iOS doesn't let Atelier open its data: \(answer)."
		case .notEnoughSpace(let needed, let free):
			let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
			problem = InstallProblem(
				message,
				detail: "Its data takes \(format(needed)), and copying it would leave less than \(format(AppDataCopy.spareSpace)) of the \(format(max(free, 0))) free on this \(ThisDevice.name).",
				fix: .freeSpace
			)
		}
		problem.dataFailure = why
		return problem
	}

	/// installd's error code for an upgrade signed for another App ID.
	static let appIDMismatchCode = "MismatchedApplicationIdentifierEntitlement"

	/// The installed app's App ID in installd's refusal: "…does not match
	/// installed application's application-identifier string
	/// (6XVY5G3U44.com.rileytestut.AltStore); rejecting upgrade." Nil when
	/// it isn't there.
	static func installedAppID(inRefusal refusal: String) -> String? {
		let marker = "installed application's application-identifier string ("
		guard let start = refusal.range(of: marker)?.upperBound,
		      let end = refusal[start...].firstIndex(of: ")"),
		      start < end
		else { return nil }
		return String(refusal[start..<end])
	}

	/// The problem behind any error a step throws, about the app `appName`
	/// when it's known.
	public init(_ error: Error, appName: String? = nil) {
		switch error {
		case let problem as InstallProblem:
			self = problem
		case let failure as InstallFailure:
			switch failure {
			case .couldNotStart(let why): self.init(why)
			case .notStarted, .downloadFailed, .connectionLost, .routeAStep: self.init(failure.description, fix: .tryAgain)
			case .notInstalled: self = .notInstalled(appName)
			case .rejected(let why) where why.contains(Self.appIDMismatchCode):
				self = .appIDMismatch(appName)
				installedAppID = Self.installedAppID(inRefusal: why)
			case .rejected: self.init(failure.description)
			case .deviceNotInProfile: self.init(failure.description, fix: .importCertificate)
			case .dataNotCopied(let why): self = .dataNotCopied(why)
			}
			if let technical = failure.technical { self.technical = technical }
		case let unavailable as RouteSelector.Unavailable:
			self.init(unavailable.description, fix: .installSettings)
		case let signing as SigningError:
			switch signing {
			case .outOfSpace(let needed, let available):
				self = .notEnoughSpace(needed: needed, available: available)
			case .badCertificate, .unsupportedCertificate:
				self.init(signing.description, fix: .importCertificate)
			case .unsignedBinary, .signingFailed:
				self.init(signing.description, fix: .tryAgain)
			default:
				self.init(signing.description)
			}
			technical = signing.technical
		default:
			self.init("\(error)")
		}
	}
}

/// What the default certificate is like, for the checks before an install.
public enum CertificateCheck: Equatable, Sendable {
	case ready(name: String)
	case missing
	case expired(name: String, on: Date)
	/// The last revocation check (#5) found Apple revoked it.
	case revoked(name: String)
	/// It's there but can't be read, such as when the Keychain refuses its
	/// password.
	case unusable(name: String, why: String)
}

/// The IPA download behind an install from a source, as the pipeline needs
/// it. The app's version wraps `DownloadManager`.
@MainActor
public protocol PipelineDownload: AnyObject {
	/// The IPA's size, when known, for the free-space check.
	var expectedSize: Int64? { get }
	/// Whether the IPA is already downloaded.
	var isFinished: Bool { get }
	/// Starts the download, or picks up the one already running or finished,
	/// and returns the IPA once it's downloaded and checked. Throws
	/// `InstallProblem` when the download fails, and `CancellationError` when
	/// the task is cancelled.
	func file(progress: @escaping @MainActor (Double?) -> Void) async throws -> URL
	/// Deletes the download if this install started it: on cancel.
	func discard()
}

/// The order an install's stages may come in: forward only, ending once.
/// `InstallPipeline` reports every change through it, so a stray progress
/// update from a finished step can't move the install back.
public struct InstallStateMachine: Equatable, Sendable {
	public private(set) var stage: InstallStage = .checking

	public init() {}

	public enum Event: Equatable, Sendable {
		case downloading(Double?)
		case signing(SigningProgress)
		case installing(IPAInfo, InstallPhase)
		case installed(IPAInfo, InstallResult)
		case failed(InstallProblem)
		case cancelled
	}

	/// Moves to the event's stage when it may follow the current one, and
	/// returns whether it did.
	@discardableResult
	public mutating func handle(_ event: Event) -> Bool {
		guard stage.isActive else { return false }
		let next: InstallStage
		switch event {
		case .downloading(let fraction): next = .downloading(fraction)
		case .signing(let progress): next = .signing(progress)
		case .installing(let info, let phase): next = .installing(info, phase)
		case .installed(let info, let result):
			guard case .installing = stage else { return false }
			next = .finished(info, result)
		case .failed(let problem): next = .failed(problem)
		case .cancelled: next = .cancelled
		}
		guard next.order >= stage.order else { return false }
		stage = next
		return true
	}
}

/// Runs one install: the checks, then the download, signing and install
/// each payload needs, cleaning up after a failure or a cancel.
@MainActor
public final class InstallPipeline {
	/// What to install.
	public enum Payload {
		/// An app from a source, downloaded first.
		case download(any PipelineDownload)
		/// An IPA on disk to sign: a picked file or a finished download.
		case file(URL)
		/// An IPA that's already signed, installed as it is.
		case signed(InstallPackage)

		var needsSigning: Bool {
			if case .signed = self { return false }
			return true
		}
	}

	public struct Dependencies {
		/// The default certificate's state.
		public var certificate: @MainActor () -> CertificateCheck
		/// The route to install with (`RouteSelector.select`). Throws when no
		/// route can install.
		public var installer: @MainActor () async throws -> any Installer
		/// Free space on the device, or nil when it can't be told.
		public var freeSpace: @MainActor () -> Int64?
		/// What's on this device already (#99): with the route picked and
		/// the IPA, once there is one (nil before a download), checks the
		/// app installed under the bundle ID this one installs as. Returns
		/// true when it changed the certificate to sign with, which is then
		/// checked again; throws `InstallProblem` when iOS won't let the
		/// install replace that app.
		public var checkInstalled: @MainActor (any Installer, URL?) async throws -> Bool
		/// Signs an IPA with the default certificate, into a new file.
		public var sign: @MainActor (URL, @escaping @MainActor (SigningProgress) -> Void) async throws -> InstallPackage

		public init(
			certificate: @escaping @MainActor () -> CertificateCheck,
			installer: @escaping @MainActor () async throws -> any Installer,
			freeSpace: @escaping @MainActor () -> Int64?,
			checkInstalled: @escaping @MainActor (any Installer, URL?) async throws -> Bool = { _, _ in false },
			sign: @escaping @MainActor (URL, @escaping @MainActor (SigningProgress) -> Void) async throws -> InstallPackage
		) {
			self.certificate = certificate
			self.installer = installer
			self.freeSpace = freeSpace
			self.checkInstalled = checkInstalled
			self.sign = sign
		}
	}

	/// An install iOS took.
	public struct Completed {
		public var package: InstallPackage
		public var result: InstallResult
		/// Whether `package` was signed by this install, so it's the
		/// caller's to delete; an IPA that was already signed stays where it
		/// is.
		public var freshlySigned: Bool
	}

	public private(set) var machine = InstallStateMachine()
	public var stage: InstallStage { machine.stage }
	/// The route picked, once the checks pass.
	public private(set) var route: InstallRoute?
	/// The certificate's name, once checked.
	public private(set) var certificateName: String?
	/// The app being installed, once signed or read.
	public private(set) var info: IPAInfo?
	/// The signed app of an install iOS refused to put over the app it has
	/// (`InstallProblem.Fix.replaceInstalled`), kept so it can be sent
	/// again once that app is deleted, without signing it again (#99). The
	/// caller's to delete.
	public private(set) var refusedPackage: InstallPackage?

	private let dependencies: Dependencies
	private let onStage: @MainActor (InstallStage) -> Void
	private let log: @MainActor (String) -> Void

	/// `onStage` hears every stage change, `log` the lines for the install log.
	public init(
		_ dependencies: Dependencies,
		onStage: @escaping @MainActor (InstallStage) -> Void = { _ in },
		log: @escaping @MainActor (String) -> Void = { _ in }
	) {
		self.dependencies = dependencies
		self.onStage = onStage
		self.log = log
	}

	/// Room kept free beyond the download and signing, like SigningKit's.
	public static let spaceMargin: Int64 = 64 << 20

	/// About how much free space an install needs: the download, then an
	/// unpacked copy and a signed copy, each taken as the IPA's size again
	/// (apps compress little, as most of their size is already-compressed
	/// assets). SigningKit checks again with the real unpacked size.
	public static func requiredSpace(ipaSize: Int64, download: Bool, sign: Bool) -> Int64 {
		guard download || sign else { return 0 }
		return (download ? ipaSize : 0) + (sign ? 2 * ipaSize : 0) + spaceMargin
	}

	/// Runs the install. Throws `InstallProblem`, or `CancellationError` when
	/// the task is cancelled; `stage` says the same.
	public func run(_ payload: Payload) async throws -> Completed {
		var freshFile: URL?
		do {
			let completed = try await stages(payload, freshFile: &freshFile)
			return completed
		} catch {
			if error is CancellationError || Task.isCancelled {
				if let freshFile { try? FileManager.default.removeItem(at: freshFile) }
				if case .download(let download) = payload { download.discard() }
				move(.cancelled)
				throw CancellationError()
			}
			let problem = InstallProblem(error, appName: info?.name)
			if problem.fix == .replaceInstalled, let freshFile, let info {
				refusedPackage = InstallPackage(url: freshFile, info: info)
			} else if let freshFile {
				try? FileManager.default.removeItem(at: freshFile)
			}
			move(.failed(problem))
			throw problem
		}
	}

	private func stages(_ payload: Payload, freshFile: inout URL?) async throws -> Completed {
		onStage(stage)
		let installer = try await check(payload)
		try Task.checkCancellation()

		let package: InstallPackage
		switch payload {
		case .signed(let kept):
			package = kept
		case .file(let ipa):
			try await checkInstalled(installer, ipa: ipa)
			package = try await sign(ipa)
			freshFile = package.url
		case .download(let download):
			// Before the download, as the source lists the app (#99).
			try await checkInstalled(installer, ipa: nil)
			move(.downloading(nil))
			let ipa = try await download.file { [weak self] fraction in
				self?.move(.downloading(fraction))
			}
			try Task.checkCancellation()
			// Its IPA may have another bundle ID than its source lists (#116).
			try await checkInstalled(installer, ipa: ipa)
			package = try await sign(ipa)
			freshFile = package.url
		}
		info = package.info
		try Task.checkCancellation()

		log("route: \(installer.route.displayName)")
		move(.installing(package.info, installer.firstPhase))
		let result = try await installer.install(package) { [weak self] event in
			switch event {
			case .log(let line): self?.log(line)
			case .phase(let phase): self?.move(.installing(package.info, phase))
			}
		}
		move(.installed(package.info, result))
		return Completed(package: package, result: result, freshlySigned: freshFile != nil)
	}

	/// The checks before anything is downloaded or signed: the certificate,
	/// the route and free space. Returns the route to install with.
	private func check(_ payload: Payload) async throws -> any Installer {
		if payload.needsSigning { try checkCertificate() }

		let installer = try await dependencies.installer()
		route = installer.route

		let size: Int64?
		let downloading: Bool
		switch payload {
		case .download(let download):
			size = download.expectedSize
			downloading = !download.isFinished
		case .file(let url):
			size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
			downloading = false
		case .signed:
			size = nil
			downloading = false
		}
		if let size, let free = dependencies.freeSpace() {
			let needed = Self.requiredSpace(ipaSize: size, download: downloading, sign: payload.needsSigning)
			if needed > free { throw InstallProblem.notEnoughSpace(needed: needed, available: free) }
		}
		return installer
	}

	/// The certificate to sign with: its name, or why it can't sign.
	private func checkCertificate() throws {
		switch dependencies.certificate() {
		case .ready(let name):
			certificateName = name
		case .missing:
			throw InstallProblem.noCertificate
		case .expired(let name, let date):
			certificateName = name
			throw InstallProblem.certificateExpired(name, on: date)
		case .revoked(let name):
			certificateName = name
			throw InstallProblem.certificateRevoked(name)
		case .unusable(let name, let why):
			certificateName = name
			throw InstallProblem("Can't sign with “\(name)”: \(why)", fix: .importCertificate)
		}
	}

	/// What's on this device already (#99), and the certificate again when
	/// that changed it.
	private func checkInstalled(_ installer: any Installer, ipa: URL?) async throws {
		let switched = try await dependencies.checkInstalled(installer, ipa)
		try Task.checkCancellation()
		if switched { try checkCertificate() }
	}

	private func sign(_ ipa: URL) async throws -> InstallPackage {
		move(.signing(.unpacking(0)))
		let package = try await dependencies.sign(ipa) { [weak self] progress in
			self?.move(.signing(progress))
		}
		return package
	}

	private func move(_ event: InstallStateMachine.Event) {
		if machine.handle(event) { onStage(machine.stage) }
	}
}
