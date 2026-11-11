import AtelierCore
import CertKit
import InstallKit
import SwiftUI

/// A certificate or Apple ID that signed apps in the Library, for the
/// Library's filter (#49), which shows one's apps at a time, so it's plain
/// which apps hold a free Apple ID's 3 places on this iPhone (4 Nov
/// 2026).
struct LibrarySigner: Identifiable, Equatable {
	/// The certificate's or Apple ID's, as the apps' records note it.
	let id: UUID
	let name: String
	/// "Free Apple ID · 2 of 3 on this iPhone, 1 offloaded", or
	/// "Development · 2 apps".
	let detail: String
	let symbol: String
	/// How many of the Library's apps it signed.
	let appCount: Int

	/// The ones the Library's apps are signed with, as Certificates lists
	/// them: Apple IDs, then imported certificates, then deleted ones, by
	/// name. Apps signed with none Atelier knows show only under All Apps.
	@MainActor
	static func all(in installs: [InstallRecord], certificates: CertificatesModel, installer: InstallModel) -> [LibrarySigner] {
		var bySigner: [UUID: [InstallRecord]] = [:]
		for install in installs {
			if let id = install.certificateID { bySigner[id, default: []].append(install) }
		}
		var signers: [LibrarySigner] = []
		for account in certificates.appleIDs {
			guard let apps = bySigner.removeValue(forKey: account.id) else { continue }
			signers.append(LibrarySigner(id: account.id, name: account.displayName, detail: detail(of: account, apps: apps, installer: installer), symbol: "person.badge.key", appCount: apps.count))
		}
		for certificate in certificates.certificates {
			guard let apps = bySigner.removeValue(forKey: certificate.id) else { continue }
			signers.append(LibrarySigner(id: certificate.id, name: certificate.displayName, detail: "\(certificate.profile.kind.title) · \(count(apps.count))", symbol: certificate.profile.kind.symbol, appCount: apps.count))
		}
		let deleted = bySigner.compactMap { id, apps in
			certificates.retired[id].map { LibrarySigner(id: id, name: $0.name, detail: "Deleted from Atelier · \(count(apps.count))", symbol: "seal", appCount: apps.count) }
		}
		return signers + deleted.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// A free Apple ID's: how many of the 3 places on this iPhone its apps
	/// hold, and how many are offloaded. Else the team's kind and its apps.
	@MainActor
	private static func detail(of account: StoredAppleID, apps: [InstallRecord], installer: InstallModel) -> String {
		guard account.isFree else {
			let kind = account.team.isFree == false ? "Apple Developer Program" : "Apple ID"
			return "\(kind) · \(count(apps.count))"
		}
		let offloaded = apps.filter { installer.isOffloaded($0) }.count
		let here = apps.filter { InstallModel.presence(of: $0) != .deleted && !installer.isOffloaded($0) }.count
		let places = "Free Apple ID · \(here) of \(FreeAppleID.appsPerDevice) on this \(ThisDevice.name)"
		return offloaded == 0 ? places : "\(places), \(offloaded) offloaded"
	}

	/// "1 app", "5 apps".
	static func count(_ apps: Int) -> String {
		apps == 1 ? "1 app" : "\(apps) apps"
	}
}

/// The Library's filter (#49): All Apps, or one certificate's or Apple
/// ID's apps, each with how many it has under its name. Filled while it
/// shows one's.
struct LibraryFilterMenu: View {
	let signers: [LibrarySigner]
	/// Every app in the Library.
	let total: Int
	@Binding var selection: UUID?

	var body: some View {
		Menu {
			Section {
				option(nil, name: "All Apps", detail: LibrarySigner.count(total), symbol: "square.stack")
			}
			Section {
				ForEach(signers) { signer in
					option(signer.id, name: signer.name, detail: signer.detail, symbol: signer.symbol)
				}
			}
		} label: {
			Label("Filter", systemImage: selection == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
		}
	}

	/// A button, not a picker's option, which shows only its name (4
	/// Nov 2026), with what it holds on the line under it, as Install Older
	/// Version's versions have their dates. The one shown has a checkmark
	/// for its icon.
	private func option(_ id: UUID?, name: String, detail: String, symbol: String) -> some View {
		let shown = selection == id
		return Button {
			selection = id
		} label: {
			Text(name)
			Text(detail)
			Image(systemName: shown ? "checkmark" : symbol)
		}
		.accessibilityAddTraits(shown ? .isSelected : [])
	}

	/// Only when it would leave some apps out: two or more signers, or one
	/// that didn't sign every app.
	static func narrows(_ signers: [LibrarySigner], total: Int) -> Bool {
		signers.count > 1 || signers.first.map { $0.appCount < total } == true
	}
}
