import AtelierCore
import CertKit
import DownloadKit
import InstallKit
import SourceKit
import SwiftData
import SwiftUI

// The apps a certificate or an Apple ID signed (#49), in one view for both
// (4 Nov 2026 at 23:09): Apps on this iPhone, in a card of its own
// under the header of its page, says how many and names them, and opens
// them as New apps allowed this week opens its own. It replaced an Apps
// section at the bottom of both pages.

/// What Apps on this iPhone counts and lists for a certificate or an
/// Apple ID (#49). A free Apple ID's are the apps iOS last listed with a
/// free Apple ID's profile, as they hold its 3 places, another Apple ID's
/// among them; a certificate's and a paid Apple ID's are the Library's apps
/// signed with it that weren't deleted from this iPhone. The offloaded
/// ones, their data kept, are apart: they hold no place.
@MainActor
struct SignedApps {
	struct Entry: Identifiable {
		/// The bundle ID it's installed as.
		let id: String
		let name: String
		/// Its install in the Library, for its icon, source, days and page.
		let install: InstallRecord?
	}

	/// A free Apple ID's 3 places as iOS last listed them; nil for anything
	/// else, and before Atelier asked.
	let places: AppleIDLimits.Apps?
	/// Its apps on this iPhone, by name.
	let here: [Entry]
	/// On this iPhone with another free Apple ID, which takes one of the 3
	/// places too: for a free Apple ID only.
	let others: [Entry]
	/// Off this iPhone, with their data kept, by name.
	let offloaded: [InstallRecord]

	init(signerID: UUID, appleID: StoredAppleID?, installs: [InstallRecord], installer: InstallModel) {
		let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
		let offloaded = installs
			.filter { $0.certificateID == signerID && installer.disabledApps[$0.bundleID] != nil && InstallModel.presence(of: $0) != .installed }
			.sorted { byName($0.name, $1.name) }
		self.offloaded = offloaded
		if let account = appleID, account.isFree {
			let listed = account.limits?.apps
			places = listed
			let apps = (listed?.apps ?? []).map { free -> (teamID: String, entry: Entry) in
				let install = installs.first { $0.bundleID == free.bundleID }
				return (teamID: free.teamID, entry: Entry(id: free.bundleID, name: install?.name ?? free.name, install: install))
			}
			here = apps.filter { $0.teamID == account.team.id }.map { $0.entry }.sorted { byName($0.name, $1.name) }
			others = apps.filter { $0.teamID != account.team.id }.map { $0.entry }.sorted { byName($0.name, $1.name) }
		} else {
			places = nil
			let offloadedIDs = Set(offloaded.map(\.bundleID))
			here = installs
				.filter { $0.certificateID == signerID && !offloadedIDs.contains($0.bundleID) && InstallModel.presence(of: $0) != .deleted }
				.sorted { byName($0.name, $1.name) }
				.map { Entry(id: $0.bundleID, name: $0.name, install: $0) }
			others = []
		}
	}

	/// Nothing to list.
	var isEmpty: Bool { here.isEmpty && others.isEmpty && offloaded.isEmpty }

	/// "30sec, Mosaic and SideStore".
	static func joined(_ names: [String]) -> String {
		guard let last = names.last else { return "" }
		guard names.count > 1 else { return last }
		return names.dropLast().joined(separator: ", ") + " and " + last
	}

	/// "Atlas, 30sec, Scanner and 3 more": the first 3, and how many more.
	static func firstNames(_ names: [String]) -> String {
		names.count <= 4 ? joined(names) : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
	}
}

/// Apps on this iPhone, the first row under the header of a certificate's
/// or an Apple ID's page (#49): how many, with their names and the
/// offloaded ones, opening them as New apps allowed this week opens its
/// own. A free Apple ID's counts its 3 places, with a slot for each; a
/// certificate has no limit, so its row has no slots.
struct SignedAppsRow: View {
	let signerID: UUID
	/// The Apple ID's page's, nil on a certificate's.
	var appleID: StoredAppleID?
	@Query private var installs: [InstallRecord]

	/// Which apps are offloaded; not from the environment, which a page
	/// opened from a sheet may not have.
	private var installer: InstallModel { .shared }

	var body: some View {
		let apps = SignedApps(signerID: signerID, appleID: appleID, installs: installs, installer: installer)
		if apps.isEmpty {
			label(apps)
		} else {
			NavigationLink {
				SignedAppsView(signerID: signerID)
			} label: {
				label(apps)
			}
		}
	}

	private func label(_ apps: SignedApps) -> LimitRow {
		var notes: [String] = []
		let offloaded = apps.offloaded.map(\.name)
		if let account = appleID, account.isFree {
			guard let places = apps.places else {
				return LimitRow(title: "Apps on this \(ThisDevice.name)", value: "Not checked yet", note: offloaded.isEmpty ? nil : offloadedNote(offloaded))
			}
			let names = apps.here.map(\.name) + apps.others.map { "\($0.name) with another Apple ID" }
			if !names.isEmpty { notes.append(SignedApps.joined(names) + ".") }
			if !offloaded.isEmpty { notes.append(offloadedNote(offloaded)) }
			let count = places.apps.count
			let full = !places.hasRoom
			if full { notes.append("A new app needs one of them offloaded first.") }
			return LimitRow(
				title: "Apps on this \(ThisDevice.name)",
				value: "\(min(count, FreeAppleID.appsPerDevice)) of \(FreeAppleID.appsPerDevice)",
				slots: (FreeAppleID.appsPerDevice, count),
				note: notes.isEmpty ? "None yet." : notes.joined(separator: " "),
				full: full
			)
		}
		let names = apps.here.map(\.name)
		if !names.isEmpty { notes.append(SignedApps.firstNames(names) + ".") }
		if !offloaded.isEmpty { notes.append(offloadedNote(offloaded)) }
		return LimitRow(
			title: "Apps on this \(ThisDevice.name)",
			value: names.isEmpty ? "None" : "\(names.count)",
			note: notes.isEmpty ? nil : notes.joined(separator: " ")
		)
	}

	/// "Scanner is offloaded, with its data kept."
	private func offloadedNote(_ names: [String]) -> String {
		names.count == 1 ? "\(names[0]) is offloaded, with its data kept." : "\(SignedApps.firstNames(names)) are offloaded, with their data kept."
	}
}

/// The apps Apps on this iPhone opens (#49), drawn as New Apps Allowed This
/// Week's: a free Apple ID's 3 places first, then its apps on this iPhone,
/// another free Apple ID's that hold a place, and its offloaded ones. Each
/// row has the app's icon, its source and its days left, and opens its
/// page, which has Open, Update, Offload and Reinstall: the rows have no
/// buttons (4 Nov 2026).
struct SignedAppsView: View {
	let signerID: UUID
	@Environment(CertificatesModel.self) private var certificates
	/// For the apps' pages; not there over the welcome, whose Get Ready
	/// opens Certificates without the Library's models.
	@Environment(CatalogModel.self) private var catalog: CatalogModel?
	@Environment(DownloadManager.self) private var downloads: DownloadManager?
	@Environment(SourcesModel.self) private var sources: SourcesModel?
	@Environment(\.modelContext) private var context
	@Query private var installs: [InstallRecord]
	@Query private var sourceRecords: [SourceRecord]

	/// Which apps are offloaded; not from the environment, which a page
	/// opened from a sheet may not have.
	private var installer: InstallModel { .shared }

	var body: some View {
		let appleID = certificates.appleID(signerID)
		let apps = SignedApps(signerID: signerID, appleID: appleID, installs: installs, installer: installer)
		let isFree = appleID?.isFree == true
		Form {
			if isFree, let places = apps.places {
				Section {
					LimitRow(
						title: "Places taken",
						value: "\(min(places.apps.count, FreeAppleID.appsPerDevice)) of \(FreeAppleID.appsPerDevice)",
						slots: (FreeAppleID.appsPerDevice, places.apps.count),
						note: "Apps signed with any free Apple ID share the \(FreeAppleID.appsPerDevice) places on this \(ThisDevice.name), as iOS counts them.",
						full: !places.hasRoom
					)
				}
			}
			if !apps.here.isEmpty {
				Section {
					ForEach(apps.here) { app in
						row(app)
					}
				} header: {
					Text("On this \(ThisDevice.name) · \(apps.here.count)")
				} footer: {
					if apps.others.isEmpty && apps.offloaded.isEmpty { Text(footer(apps, isFree: isFree)) }
				}
			}
			if !apps.others.isEmpty {
				Section {
					ForEach(apps.others) { app in
						row(app, another: true)
					}
				} header: {
					Text("With another Apple ID · \(apps.others.count)")
				} footer: {
					if apps.offloaded.isEmpty { Text(footer(apps, isFree: isFree)) }
				}
			}
			if !apps.offloaded.isEmpty {
				Section {
					ForEach(apps.offloaded) { install in
						offloadedRow(install)
					}
				} header: {
					Text("Offloaded · \(apps.offloaded.count)")
				} footer: {
					Text(footer(apps, isFree: isFree))
				}
			}
			if apps.isEmpty {
				Text("None on this \(ThisDevice.name).")
					.foregroundStyle(.secondary)
			}
		}
		.navigationTitle("Apps on This \(ThisDevice.name)")
		.navigationBarTitleDisplayMode(.inline)
	}

	/// An app on this iPhone: its page when it's in the Library, else its
	/// name and bundle ID, as another app installed it.
	@ViewBuilder
	private func row(_ app: SignedApps.Entry, another: Bool = false) -> some View {
		if let install = app.install, let item = item(install) {
			link(item) {
				SignedAppRow(name: app.name, detail: detail(item)) {
					SourceIcon(url: item.iconURL, tint: item.tint, size: 44)
				}
			}
		} else if let install = app.install {
			// Over the welcome, without the Library's models.
			SignedAppRow(name: app.name, detail: another ? "With another Apple ID" : "In the Library") {
				SourceIcon(url: InstalledApps.iconURL(of: install, in: context), tint: nil, size: 44)
			}
		} else {
			SignedAppRow(
				name: app.name,
				detail: another ? "With another Apple ID, not in the Library" : "Not in the Library",
				identifier: app.id
			) {
				SourceIcon(url: nil, tint: nil, size: 44)
			}
		}
	}

	/// An offloaded app, greyed with iOS's cloud, and the size of its data.
	@ViewBuilder
	private func offloadedRow(_ install: InstallRecord) -> some View {
		let size = installer.disabledApps[install.bundleID].map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) }
		let detail = ["Offloaded, its data kept", size].compactMap { $0 }.joined(separator: " · ")
		if let item = item(install) {
			link(item) {
				SignedAppRow(name: install.name, detail: detail, dimmed: true) {
					DisabledAppIcon(url: item.iconURL, tint: item.tint, size: 44)
				}
			}
		} else {
			SignedAppRow(name: install.name, detail: detail, dimmed: true) {
				DisabledAppIcon(url: InstalledApps.iconURL(of: install, in: context), tint: nil, size: 44)
			}
		}
	}

	/// The app's page over the list, as the Library has it.
	private func link<Content: View>(_ item: LibraryItem, @ViewBuilder content: () -> Content) -> some View {
		NavigationLink {
			PushedAppPage(.library(LibraryLink(item)))
				.environment(installer)
		} label: {
			content()
		}
	}

	/// As the Library has it, with the Library's models; none over the
	/// welcome.
	private func item(_ install: InstallRecord) -> LibraryItem? {
		guard let catalog, downloads != nil, sources != nil else { return nil }
		return LibraryItem(install, catalog: catalog.catalog, certificates: certificates, installer: installer)
	}

	/// "Atlas Repo · 7 days left": its source, and its own profile's days
	/// or else its certificate's, as the Library's rows say them.
	private func detail(_ item: LibraryItem) -> String {
		let days: String? = if let profile = item.appProfile {
			AppProfileDays.days(until: profile.expires) == 0 ? "Profile ended" : AppProfileDays.text(until: profile.expires)
		} else if let certificate = item.certificate {
			certificate.remainingText()
		} else {
			item.appleID?.remainingText()
		}
		return [sourceName(of: item), days].compactMap { $0 }.joined(separator: " · ")
	}

	/// As the Library's rows name it.
	private func sourceName(of item: LibraryItem) -> String {
		if let listing = item.listing { return listing.source.name }
		guard let url = item.install.sourceURL else { return "IPA file" }
		return sourceRecords.first { $0.url == url }?.name ?? "Removed source"
	}

	/// "Tap one for its page, to open, update, offload or reinstall it. …"
	private func footer(_ apps: SignedApps, isFree: Bool) -> String {
		var lines = ["Tap one for its page, to open, update, offload or reinstall it."]
		if isFree, !apps.offloaded.isEmpty { lines.append("An offloaded app takes no place.") }
		lines.append("Apps deleted from this \(ThisDevice.name) aren’t listed.")
		if isFree, let checked = apps.places?.checkedAt {
			lines.append("As this \(ThisDevice.name) said \(Self.when(checked)).")
		}
		return lines.joined(separator: " ")
	}

	/// "at 14:40", or "on Mon 2 Nov at 14:40" before today.
	private static func when(_ date: Date) -> String {
		let time = date.formatted(date: .omitted, time: .shortened)
		guard !Calendar.current.isDateInToday(date) else { return "at \(time)" }
		return "on \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
	}
}

/// An app's row in Apps on This iPhone, as New Apps Allowed This Week has
/// them: its icon and name, a line on where it is, and its bundle ID when
/// Atelier has no page for it.
private struct SignedAppRow<Icon: View>: View {
	let name: String
	let detail: String
	var identifier: String?
	var dimmed = false
	@ViewBuilder let icon: () -> Icon

	var body: some View {
		HStack(spacing: 12) {
			icon()
			VStack(alignment: .leading, spacing: 2) {
				Text(name)
					.foregroundStyle(dimmed ? .secondary : .primary)
				Text(detail)
					.font(.footnote)
					.foregroundStyle(.secondary)
				if let identifier {
					Text(identifier)
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
		}
		.padding(.vertical, 2)
		.accessibilityElement(children: .combine)
	}
}
