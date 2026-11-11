import CertKit
import DownloadKit
import Foundation
import InstallKit
import Observation
import AtelierCore
import SigningKit
import SwiftData
import UIKit

/// Atelier's own updates (#24). Atelier's releases are in a source of its
/// own, which is one of the sources from the start: read, shown and kept
/// like the ones the user adds, but it can't be removed, and only it
/// updates Atelier.
///
/// Atelier is in the Library like the apps it installed, with the
/// certificate it was installed with. It updates and signs itself again
/// through the install queue, last, keeping its bundle ID and the App ID it
/// was installed with, as iOS only replaces an app with one signed for that
/// App ID (`OwnAppSigning`). iOS closes Atelier to install over it, so it
/// notes the install first (`PendingSelfInstall`) and tells on its next
/// launch, from the token in the new build's Info.plist, how it ended.
@MainActor
@Observable
final class SelfUpdate {
	static let shared = SelfUpdate()

	/// The bundle ID Atelier's source lists it under, which Codemagic signs
	/// it with (release/source-template.json).
	nonisolated static let sourceBundleID = "com.atelier.app"
	/// Atelier's own source, as the repo's `source` branch publishes it
	/// (`SOURCE_BRANCH` and `SOURCE_PATH` in scripts/publish_release.py).
	nonisolated static let sourceURL = URL(string: "https://raw.githubusercontent.com/atelierstore/Atelier/source/source.json")!
	/// The name that source has (release/source-template.json), which its
	/// first refresh gives it anyway: Atelier's, not a copy's (#113).
	nonisolated static let sourceName = "Atelier"

	/// What Atelier runs as: its bundle ID, which another tool may have
	/// changed, its name and its build.
	let bundleID: String
	let name: String
	let version: String
	let build: String?
	/// The token its Info.plist carries when Atelier installed this build
	/// itself.
	let runningToken: String?
	/// What a copy of Atelier's Info.plist says it is (#113); nil for
	/// Atelier, and copies installed before they said.
	let copyMarker: CopyMarker?
	/// What it was signed as, with the App ID iOS has for it; nil when that
	/// can't be read.
	let identity: SignedAppIdentity?
	/// The profile it was installed with.
	let installedProfile: ProvisioningProfile?
	/// Its icon as a file, as rows and the install bar load icons by URL: its
	/// row's until its source was read.
	let iconURL: URL?

	/// How the install of itself that closed Atelier ended, until Atelier
	/// leaves the screen: its row says so meanwhile.
	private(set) var relaunch: Relaunch?

	struct Relaunch {
		let pending: PendingSelfInstall
		let outcome: PendingSelfInstall.Outcome
		/// Whether the install bar said so.
		var reported = false
	}

	@ObservationIgnored private var launchChecked = false

	private init() {
		let bundle = Bundle.main
		bundleID = bundle.bundleIdentifier ?? Self.sourceBundleID
		name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
			?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
			?? "Atelier"
		version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
		build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
		runningToken = bundle.object(forInfoDictionaryKey: PendingSelfInstall.tokenKey) as? String
		copyMarker = CopyMarker(bundle: bundle)
		identity = SignedAppIdentity.read(app: bundle.bundleURL, originalBundleID: Self.sourceBundleID)
		installedProfile = (try? Data(contentsOf: Self.installedProfileURL)).flatMap { try? ProvisioningProfile(data: $0) }
		iconURL = Self.writeIcon(build: build)
	}

	/// The profile Atelier was installed with, in its bundle: what it signs
	/// itself with when only that profile is for its App ID.
	static var installedProfileURL: URL {
		Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
	}

	// MARK: Which app is Atelier

	/// Whether an app a source lists, or an IPA, is Atelier: its source's
	/// bundle ID, or the one it runs as.
	func isOwnApp(_ bundleID: String) -> Bool {
		bundleID == Self.sourceBundleID || bundleID == self.bundleID
	}

	/// Whether a Library entry is Atelier's own.
	func isOwn(_ install: InstallRecord) -> Bool {
		install.bundleID == bundleID
	}

	/// The copy of Atelier this is (#113), by what its Info.plist says, as
	/// one installed under an App ID of the user's choosing has no number
	/// in its bundle ID, else by its bundle ID: a copy installs its own
	/// updates over itself, as Atelier does.
	var target: InstallTarget {
		Self.copyNumber(bundleID: bundleID, marker: copyMarker).map(InstallTarget.copy) ?? .original
	}

	/// Whether this is a copy of Atelier, read before anything else runs:
	/// only Atelier itself takes the store it shared with its copies
	/// (`Persistence`, #113).
	nonisolated static var runsAsCopy: Bool {
		copyNumber(bundleID: Bundle.main.bundleIdentifier ?? sourceBundleID, marker: CopyMarker(bundle: .main)) != nil
	}

	nonisolated private static func copyNumber(bundleID: String, marker: CopyMarker?) -> Int? {
		if let marker, let number = InstallTarget.copyNumber(of: marker.numberedID, original: sourceBundleID) { return number }
		return InstallTarget.copyNumber(of: bundleID, original: sourceBundleID)
	}

	/// How the install queue knows Atelier's installs from its source.
	var appKey: InstallModel.AppKey {
		InstallModel.AppKey(bundleID: Self.sourceBundleID, sourceURL: Self.sourceURL)
	}

	// MARK: Signing itself

	/// The certificate Atelier signs itself with, and how (`OwnAppSigning`):
	/// `picked`, the one Custom Install… or Re-sign picked, else the one it
	/// was installed with, then the default, then the rest. Re-signing takes
	/// a certificate that can re-sign (#20), and not the profile Atelier was
	/// installed with, which is likely the one running out. Nil when none
	/// signs for Atelier's App ID.
	func signing(picked: UUID?, resigning: Bool, certificates: CertificatesModel, context: ModelContext) -> OwnAppSigning.Choice? {
		let all = certificates.certificates
		let ordered: [StoredCertificate]
		if let picked {
			ordered = all.filter { $0.id == picked }
		} else {
			let installedWith = InstalledApps.record(bundleID, in: context)?.certificateID
			let defaultID = certificates.defaultID
			ordered = all.filter { $0.id == installedWith }
				+ all.filter { $0.id == defaultID && $0.id != installedWith }
				+ all.filter { $0.id != installedWith && $0.id != defaultID }
		}
		return OwnAppSigning.choose(
			from: ordered,
			applicationIdentifier: identity?.applicationIdentifier,
			installedProfile: installedProfile,
			allowsInstalledProfile: !resigning,
			isUsable: { resigning ? CertificatesModel.canResign(with: $0) : Self.canSign(with: $0) }
		)
	}

	/// Whether `certificate` signs Atelier for its App ID, for Sign Again
	/// With's list.
	func signs(with certificate: StoredCertificate) -> Bool {
		OwnAppSigning.choice(for: certificate, applicationIdentifier: identity?.applicationIdentifier, installedProfile: installedProfile) != nil
	}

	/// Whether re-signing with `target` can sign Atelier for its App ID.
	func canResign(with target: StoredCertificate) -> Bool {
		OwnAppSigning.choose(from: [target], applicationIdentifier: identity?.applicationIdentifier, installedProfile: installedProfile, allowsInstalledProfile: false) { _ in true } != nil
	}

	/// Not revoked or expired.
	private static func canSign(with certificate: StoredCertificate) -> Bool {
		switch CertificateAttention(certificate) {
		case .revoked, .expired: false
		case .expiring, nil: true
		}
	}

	// MARK: Its Library entry

	/// Once per launch, with the store: how the install of itself that
	/// closed Atelier ended, for Install History and its Library entry, kept
	/// for the install bar; then its Library entry as it runs.
	func launched(in context: ModelContext, certificates: CertificatesModel, downloads: DownloadManager) {
		guard !launchChecked else { return }
		launchChecked = true
		var installed: PendingSelfInstall?
		if let store = try? PendingSelfInstallStore.standard(), let pending = store.load() {
			store.remove()
			let outcome = pending.outcome(runningToken: runningToken, version: version, build: build)
			try? InstallHistory.standard().record(pending.endedAttempt(outcome))
			relaunch = Relaunch(pending: pending, outcome: outcome)
			// Its log then says what iOS still had of what Atelier left with
			// it to say how it went.
			SelfInstallNotice.shared.launched(after: pending)
			if outcome == .installed {
				installed = pending
				// Installed, so its download has done its job, as after any
				// install. One iOS didn't install stays, for Try again.
				if let id = pending.downloadID { downloads.remove(id) }
			}
		}
		syncRecord(in: context, certificates: certificates, installed: installed)
	}

	/// The relaunch the install bar hasn't said anything about yet.
	func takeUnreported() -> Relaunch? {
		guard let relaunch, !relaunch.reported else { return nil }
		self.relaunch?.reported = true
		return relaunch
	}

	/// Once Atelier leaves the screen, its row no longer says it was just
	/// updated.
	func forgetRelaunch() {
		guard relaunch?.reported == true else { return }
		relaunch = nil
	}

	/// What its row says right after it installed itself: "Updated just now"
	/// after an update, "Re-signed just now" after a re-sign.
	func justInstalled(_ install: InstallRecord, as kind: PendingSelfInstall.Kind) -> Bool {
		guard isOwn(install), let relaunch, relaunch.outcome == .installed else { return false }
		return relaunch.pending.kind == kind
	}

	/// Notes Atelier in the Library as the apps it installed are, from the
	/// build running: its version and App ID, its built-in source, and the
	/// certificate it was installed with, the one whose profile it carries,
	/// or else one that profile lists. Once it installed itself, `installed`
	/// says the certificate it signed with and what won't work in it.
	func syncRecord(in context: ModelContext, certificates: CertificatesModel, installed: PendingSelfInstall? = nil) {
		// A copy of Atelier under an App ID of the user's choosing is the copy
		// its Info.plist says, in its own Library too (#113).
		if let copyMarker, copyMarker.numberedID != bundleID {
			var settings = copyMarker.settings
			settings.bundleID = bundleID
			if CopyStore.shared.settings(for: copyMarker.numberedID) != settings {
				try? CopyStore.shared.save(settings, for: copyMarker.numberedID)
			}
		}
		let record: InstallRecord
		if let existing = InstalledApps.record(bundleID, in: context) {
			record = existing
		} else {
			record = InstallRecord(bundleID: bundleID, name: name, version: version, installedAt: Self.installDate ?? .now)
			context.insert(record)
		}
		// A new build, or one it installed itself, a re-sign too, as any app's
		// install dates it.
		if record.version != version || record.buildVersion != build || installed != nil {
			record.version = version
			record.buildVersion = build
			record.installedAt = installed == nil ? Self.installDate ?? .now : .now
		}
		if record.name != name { record.name = name }
		if record.sourceURL != Self.sourceURL { record.sourceURL = Self.sourceURL }
		if let identity, record.signedIdentity != identity { record.note(identity) }
		// Atelier can't tell from its own check scheme whether it's there.
		if record.checkScheme != nil { record.checkScheme = nil }
		if let installed {
			record.certificateID = installed.certificateID
			record.limits = installed.limits
			record.permissions = installed.permissions
		} else if !isInstalledWith(record.certificateID, certificates: certificates) {
			let found = installedCertificate(in: certificates)
			if record.certificateID != found { record.certificateID = found }
		}
		if context.hasChanges { try? context.save() }
	}

	/// Whether `id` is a certificate Atelier's profile is, or lists. With
	/// that profile unreadable, whatever was noted stands.
	private func isInstalledWith(_ id: UUID?, certificates: CertificatesModel) -> Bool {
		guard let installedProfile else { return true }
		guard let id, let certificate = certificates.certificates.first(where: { $0.id == id }) else { return false }
		return certificate.profile.uuid == installedProfile.uuid || installedProfile.allows(certificate.certificate)
	}

	/// The certificate with the profile Atelier was installed with, else
	/// one that profile lists, one for the same App ID first.
	private func installedCertificate(in certificates: CertificatesModel) -> UUID? {
		guard let installedProfile else { return nil }
		let all = certificates.certificates
		if let same = all.first(where: { $0.profile.uuid == installedProfile.uuid }) { return same.id }
		let listed = all.filter { installedProfile.allows($0.certificate) }
		return (listed.first { $0.profile.applicationIdentifier == installedProfile.applicationIdentifier } ?? listed.first)?.id
	}

	/// When this build was installed: when iOS put its bundle in its folder,
	/// else when it made that folder. The bundle's own creation date reads as
	/// 1 Jan 1970 (build 357, 29 Oct 2026), so a date before 2020, or
	/// one still to come, doesn't count. Nil when neither says, for its first
	/// launch instead.
	private static var installDate: Date? {
		let bundle = Bundle.main.bundleURL
		let dates = [
			try? bundle.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate,
			try? bundle.deletingLastPathComponent().resourceValues(forKeys: [.creationDateKey]).creationDate,
		]
		let earliest = Date(timeIntervalSince1970: 1_577_836_800)
		return dates.compactMap { $0 }.first { $0 > earliest && $0 <= .now }
	}

	/// Atelier's icon as a PNG in Caches, written once per build and
	/// install. The asset catalog's app icon only loads by the names its
	/// Info.plist gives.
	private static func writeIcon(build: String?) -> URL? {
		guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
		let file = caches.appending(path: "AtelierIcon-\(build ?? "0").png")
		// Written again once Atelier is installed again: a copy can be, on
		// the same build, with another tint or picture (#113).
		if let written = modified(file), let installed = modified(Bundle.main.bundleURL.appending(path: "Info.plist")), written >= installed {
			return file
		}
		let icons = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
		let names = Array(((icons?["CFBundleIconFiles"] as? [String]) ?? []).reversed()) + [(icons?["CFBundleIconName"] as? String) ?? "AppIcon"]
		guard let image = names.lazy.compactMap({ UIImage(named: $0) }).first, let data = image.pngData() else { return nil }
		do {
			try data.write(to: file, options: .atomic)
			return file
		} catch {
			return nil
		}
	}

	private static func modified(_ url: URL) -> Date? {
		(try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
	}
}

/// What a copy of Atelier's Info.plist says about it (#113): which copy it
/// is, whatever bundle ID it's installed as, and what the user chose for
/// it in Custom Install…, which the copy's own updates keep. Atelier writes
/// it into each copy of itself it signs, as JSON in one string.
struct CopyMarker: Codable, Equatable {
	static let key = "AtelierCopy"

	/// The bundle ID its copy number gives it (`InstallTarget`).
	var numberedID: String
	var settings: CopySettings

	init(numberedID: String, settings: CopySettings) {
		self.numberedID = numberedID
		self.settings = settings
	}

	/// What `bundle`'s Info.plist says; nil when it says nothing.
	init?(bundle: Bundle) {
		guard
			let text = bundle.object(forInfoDictionaryKey: Self.key) as? String,
			let marker = try? JSONDecoder().decode(CopyMarker.self, from: Data(text.utf8))
		else { return nil }
		self = marker
	}

	/// As the Info.plist holds it.
	var encoded: String {
		(try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
	}
}
