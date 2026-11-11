import AtelierCore
import SigningKit
import SourceKit
import SwiftData
import SwiftUI

/// Custom Install…'s name, and the line under it that says what else it
/// does (#155), wherever it's offered.
enum CustomInstall {
	static let title = "Custom Install…"
	static let systemImage = "square.and.pencil"

	/// For an app with an install to change or sign again, also a copy;
	/// else for one it installs with the name, icon and certificate picked.
	static func line(installed: Bool) -> String {
		installed ? "Edit, sign again or add a copy" : "Pick its name, icon and certificate"
	}

	/// Whether there's a certificate to sign with, or an Apple ID (#49).
	@MainActor
	static func canSign(with certificates: CertificatesModel) -> Bool {
		!certificates.certificates.isEmpty || !certificates.appleIDs.isEmpty
	}
}

/// The Install button's long-press menu (#8), or in lists the row's (#113):
/// Custom Install…, to install a new copy of the app next to the original
/// and the copies already installed, or sign one of those again or change
/// it, or install the app itself with a name and icon of the user's while
/// it isn't installed (#155); or update one of those copies. Each copy has
/// its own bundle ID (`InstallTarget`) and data.
struct CopyMenu: View {
	let app: SourceApp
	/// Opens Custom Install's sheet, which installs it (#113, #155).
	let customInstall: () -> Void
	/// Installs a copy again, keeping its name.
	let update: (InstallTarget, String) -> Void
	/// The app and its copies, also when their IPA has another bundle ID
	/// than the one the source lists (#116).
	@Query private var installs: [InstallRecord]

	init(app: SourceApp, customInstall: @escaping () -> Void, update: @escaping (InstallTarget, String) -> Void) {
		self.app = app
		self.customInstall = customInstall
		self.update = update
		let bundleID = app.bundleID
		let prefix = "\(bundleID)."
		_installs = Query(filter: #Predicate<InstallRecord> { $0.bundleID == bundleID || $0.bundleID.starts(with: prefix) || $0.originalBundleID == bundleID })
	}

	var body: some View {
		// The same name everywhere it's offered (#113, #155).
		Button(action: customInstall) {
			Label(CustomInstall.title, systemImage: CustomInstall.systemImage)
			Text(CustomInstall.line(installed: installs.contains { $0.sourceBundleID == app.bundleID }))
		}
		ForEach(copies) { install in
			Button("Update \(install.name)", systemImage: "arrow.down.circle") {
				update(install.target, install.name)
			}
		}
	}

	/// The installed copies, in order, also those installed under a bundle
	/// ID of the user's choosing (#113). Not Atelier as it runs, which can
	/// be a copy itself (#24).
	private var copies: [InstallRecord] {
		installs
			.filter { $0.sourceBundleID == app.bundleID && $0.target != .original && !SelfUpdate.shared.isOwn($0) }
			.sorted { $0.numberedBundleID.localizedStandardCompare($1.numberedBundleID) == .orderedAscending }
	}
}
