import DownloadKit
import AtelierCore
import SourceKit
import SwiftData
import SwiftUI
import UIKit

/// A source as a card in its own colour, the way AltStore shows sources: the
/// source's tint, or its first app's, with the app count on the right.
struct SourceCard: View {
	private let url: URL
	private let name: String
	private let iconURL: URL?
	private let tintColor: String?
	private let isPrivate: Bool
	private let subtitle: String
	private let detail: String?
	private let problem: String?
	/// The GitHub account a repo is read as (#74).
	private let account: String?
	private let appCount: Int
	/// A source being added's pre-release switch; nil for an added source,
	/// whose flask follows its setting.
	private let includesPrereleases: Bool?

	/// An added source, with when it was last updated, and for a GitHub repo
	/// the account it's read as, when it's given.
	init(source: SourceRecord, account: String? = nil) {
		url = source.url
		name = source.name
		iconURL = source.iconURL
		tintColor = source.tintColor
		isPrivate = false
		subtitle = source.subtitle ?? source.url.host ?? source.url.absoluteString
		detail = source.detail
		problem = source.refreshError
		self.account = account
		appCount = source.apps.count
		includesPrereleases = nil
	}

	/// A source being added, as it will look once added (#83): an AltStore
	/// source's domain, or a GitHub repo's latest release, in place of when
	/// it was updated. `listed` is the source as it will be listed, with or
	/// without its betas (#104), for its apps.
	init(preview: SourceLibrary.Preview, listing listed: Source, includesPrereleases: Bool) {
		let source = preview.source
		url = preview.url
		name = source.name
		iconURL = source.effectiveIconURL
		tintColor = source.effectiveTintColor
		isPrivate = preview.gitHubSummary?.isPrivate ?? false
		if let repo = preview.gitHubRepo {
			subtitle = source.subtitle ?? preview.gitHubSummary?.fullName ?? repo.description
			detail = Self.latest(in: listed).map { "Latest \($0)" }
		} else if let sourceSubtitle = source.subtitle {
			subtitle = sourceSubtitle
			detail = preview.domain
		} else {
			subtitle = preview.domain
			detail = nil
		}
		problem = nil
		account = nil
		appCount = listed.apps.count
		self.includesPrereleases = includesPrereleases
	}

	/// The newest version in the source, and when it was released.
	private static func latest(in source: Source) -> String? {
		let versions = source.apps.compactMap(\.latestVersion)
		guard let newest = versions.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) else { return nil }
		// As Version History names it (#104).
		let name = newest.tag ?? newest.version
		let version = name.first?.isNumber == true ? "v\(name)" : name
		guard let date = newest.date else { return version }
		return "\(version) · \(date.formatted(date: .abbreviated, time: .omitted))"
	}

	var body: some View {
		let tint = SourceTint(hex: tintColor, url: url)
		HStack(spacing: 12) {
			SourceIcon(url: iconURL, tint: tintColor, size: 52)
			VStack(alignment: .leading, spacing: 2) {
				SourceName(name: name, url: url, isPrivate: isPrivate, includesPrereleases: includesPrereleases)
					.font(.headline)
				Text(subtitle)
					.font(.subheadline)
					.lineLimit(1)
					.opacity(0.85)
				if let problem {
					Label(problem, systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.lineLimit(2)
				} else if let detail {
					Text(detail)
						.font(.caption)
						.opacity(0.7)
				}
				if let account {
					HStack(spacing: 3) {
						Image(systemName: "person.crop.circle")
						Text(account)
							.lineLimit(1)
					}
					.font(.caption)
					.opacity(0.7)
					.accessibilityElement(children: .combine)
					.accessibilityLabel("GitHub account \(account)")
				}
			}
			Spacer(minLength: 8)
			AppCount(count: appCount)
		}
		.foregroundStyle(tint.foreground)
		.padding(12)
		.background(tint.color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
	}
}

private struct AppCount: View {
	let count: Int

	var body: some View {
		VStack(spacing: 0) {
			Text(count, format: .number)
				.font(.title2.bold())
				.monospacedDigit()
			Text(count == 1 ? "app" : "apps")
				.font(.caption2.weight(.semibold))
				.textCase(.uppercase)
				.opacity(0.8)
		}
		.frame(minWidth: 52)
		.padding(.vertical, 6)
		.padding(.horizontal, 8)
		.background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
	}
}

/// A source's apps in the source's order, each with its Install button
/// (#38). Tapping one opens its details from this source (#14). Its search
/// field searches only this source's apps (#124).
struct SourceAppsView: View {
	let source: SourceRecord
	@Environment(CatalogModel.self) private var model
	@Query private var installs: [InstallRecord]
	/// Sets its rows' links apart from the same apps' links further back on
	/// the path, as when an app's source chip opens its source's apps
	/// (30 Oct).
	@State private var listID = UUID()
	@State private var query = ""

	var body: some View {
		// The source's own listing of each app, from the catalog, so the rows
		// can install it.
		let apps = model.catalog.source(url: source.url)?.apps ?? []
		let search = SearchText(query)
		let shown = search.isEmpty ? apps : Catalog.search(search, in: apps)
		let installed = InstalledVersions(installs)
		List {
			// What it listed before it needed an account, under why it
			// doesn't update (#134).
			if source.needsGitHubSignIn, !apps.isEmpty {
				VStack(alignment: .leading, spacing: 6) {
					Label {
						Text(SourceLibrary.Problem.gitHubSignIn.description)
					} icon: {
						// Orange as Atelier's other warnings, not in the
						// source's colour.
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
					}
					GitHubSignInButton()
				}
				.font(.subheadline)
				.buttonStyle(.borderless)
				.padding(.vertical, 4)
			}
			ForEach(shown) { entry in
				// The line above says it once, so the rows keep their
				// subtitles.
				AppListRow(entry: entry, sourceURL: source.url, installed: installed, listID: listID, warnsOfSignIn: false)
			}
		}
		.listStyle(.plain)
		.overlay {
			if apps.isEmpty {
				if !model.isLoaded {
					ProgressView()
				} else if source.needsGitHubSignIn {
					GitHubSignInNeeded()
				} else if let error = source.refreshError {
					ContentUnavailableView("Couldn't load the source", systemImage: "exclamationmark.triangle", description: Text(error))
				} else {
					ContentUnavailableView("No apps", systemImage: "square.grid.2x2", description: Text("This source doesn't list any apps."))
				}
			} else if shown.isEmpty {
				ContentUnavailableView.search(text: query)
			}
		}
		.searchable(text: $query, prompt: Text.searchingApps(apps.count))
		.navigationTitle(source.name)
		// Large, as from Browse, also after an app's page, whose title is
		// inline (30 Oct).
		.navigationBarTitleDisplayMode(.large)
		.tint(SourceTint(hex: source.tintColor, url: source.url).color)
	}
}

/// A source's page while it's in a GitHub repo that only an account can
/// read, and there's none (#134): it can only be missing or private, as
/// GitHub doesn't say which without an account. It signs in with a tap,
/// and loads once that's done. Atelier's own repo is public, so its
/// source never asks.
private struct GitHubSignInNeeded: View {
	var body: some View {
		ContentUnavailableView {
			Label("Couldn't load the source", systemImage: "exclamationmark.triangle")
		} description: {
			Text("GitHub can't find this source without an account. If it's in a private repo, sign in with one that can see it.")
		} actions: {
			GitHubSignInButton(isProminent: true)
		}
	}
}

/// A source's colour: its tint when it has one, otherwise one picked from the
/// source's URL, so every source keeps the same distinct colour. Text on it
/// turns dark when the colour is too light for white.
struct SourceTint {
	let color: Color
	let foreground: Color

	private static let palette: [UInt32] = [0x5B5BD6, 0x1E9E8F, 0xE5484D, 0xD6409F, 0x8E4EC6, 0x0090FF, 0xF76B15, 0x30A46C]

	init(hex: String?, url: URL) {
		let value = Self.parse(hex) ?? Self.palette[Int(Self.stableHash(url.absoluteString) % UInt64(Self.palette.count))]
		let red = Double((value >> 16) & 0xFF) / 255
		let green = Double((value >> 8) & 0xFF) / 255
		let blue = Double(value & 0xFF) / 255
		color = Color(red: red, green: green, blue: blue)
		let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
		foreground = luminance > 0.7 ? .black : .white
	}

	static func parse(_ hex: String?) -> UInt32? {
		guard var hex else { return nil }
		if hex.hasPrefix("#") { hex.removeFirst() }
		guard hex.count == 6 else { return nil }
		return UInt32(hex, radix: 16)
	}

	/// FNV-1a: `hashValue` changes between launches.
	private static func stableHash(_ string: String) -> UInt64 {
		var hash: UInt64 = 0xCBF2_9CE4_8422_2325
		for byte in string.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x100_0000_01B3
		}
		return hash
	}
}

/// A source's or app's icon, or its tint with a tray while there's none.
struct SourceIcon: View {
	let url: URL?
	let tint: String?
	var size: CGFloat = 44

	var body: some View {
		CachedImage(url: url, maxPoints: size) {
			ZStack {
				Color(hex: tint) ?? Color.secondary.opacity(0.2)
				Image(systemName: "tray.full")
					.foregroundStyle(.white)
			}
		}
		.scaledToFill()
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
	}
}

extension Color {
	/// Six hex digits, with or without `#`, as sources write tints.
	init?(hex: String?) {
		guard let value = SourceTint.parse(hex) else { return nil }
		self.init(
			red: Double((value >> 16) & 0xFF) / 255,
			green: Double((value >> 8) & 0xFF) / 255,
			blue: Double(value & 0xFF) / 255
		)
	}
}

/// A source's name, followed by GitHub's mark when the source is a GitHub
/// repo (#30) and the flask while its pre-releases are listed (#104), in
/// the text's colour, and a lock for a private repo being added (#83).
struct SourceName: View {
	let name: String
	let url: URL
	let isPrivate: Bool
	/// A source being added's pre-release switch; nil for an added source.
	let includesPrereleases: Bool?
	@ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 15
	@Environment(SourcesModel.self) private var sources

	init(source: SourceRecord) {
		self.init(name: source.name, url: source.url)
	}

	init(name: String, url: URL, isPrivate: Bool = false, includesPrereleases: Bool? = nil) {
		self.name = name
		self.url = url
		self.isPrivate = isPrivate
		self.includesPrereleases = includesPrereleases
	}

	var body: some View {
		HStack(spacing: 5) {
			Text(name)
				.lineLimit(1)
			if GitHubRepo(sourceURL: url) != nil {
				GitHubMark(size: markSize)
			}
			if includesPrereleases ?? sources.listsPrereleases(url) {
				PrereleaseMark(size: markSize)
			}
			if isPrivate {
				Image(systemName: "lock.fill")
					.font(.caption)
					.accessibilityLabel("Private")
			}
		}
	}
}

/// Include Pre-releases' flask, after a source's name, and a GitHub repo's
/// mark, while its pre-releases are listed (#104), in the colour of the text
/// around it.
struct PrereleaseMark: View {
	/// The GitHub mark's.
	let size: CGFloat

	var body: some View {
		Image(systemName: "flask.fill")
			.font(.system(size: size * 0.85, weight: .semibold))
			.frame(height: size)
			.accessibilityLabel("Pre-releases included")
	}
}

/// Turning a source's pre-releases off while apps installed from it are
/// betas it only lists with them (#104): each goes back to the app's latest
/// release, installed in its place, or stays as it is (29 Oct), no
/// longer listed, as a beta with no release, such as a beta app, does.
/// Atelier itself stays too, as it never goes back to an older build: it
/// signs itself again as it runs, but gets no updates until they're back
/// on (#24).
struct PrereleasesOff {
	struct Beta {
		let install: InstallRecord
		let offer: Catalog.Offer
		/// The latest release this iPhone can run, which can take its place.
		let release: AppVersion?
		/// Atelier itself (#24).
		let isOwn: Bool
	}

	let source: SourceRecord
	let betas: [Beta]

	/// Nil when no beta from the source is installed.
	@MainActor
	init?(source: SourceRecord, catalog: Catalog, installs: [InstallRecord]) {
		let betas = installs.compactMap { install -> Beta? in
			guard install.sourceURL == source.url,
			      InstallModel.presence(of: install) != .deleted,
			      let offer = InstallModel.listing(of: install, in: catalog),
			      // A beta as the Library tags it.
			      InstalledRelease(version: install.version, buildVersion: install.buildVersion, installedAt: install.installedAt, listing: offer.app).isBeta
			else { return nil }
			let app = offer.app
			// An older Atelier may not read the data a newer one saved.
			let isOwn = SelfUpdate.shared.isOwn(install)
			let release = isOwn ? nil : app.versions.first { !app.isBeta($0) && app.downloadKind(of: $0) == .ipa && $0.supports(.current) }
			return Beta(install: install, offer: offer, release: release, isOwn: isOwn)
		}
		guard !betas.isEmpty else { return nil }
		self.source = source
		self.betas = betas
	}

	var title: String { "Turn Off Pre-releases for \(source.name)?" }

	/// What happens to each beta: a release in its place, with Install Older
	/// Version's words about data when it's older, or kept and no longer
	/// listed, in the words of the app page's card.
	var message: String {
		var parts: [String] = []
		let replaceable = betas.filter { $0.release != nil }
		if replaceable.count == 1, let beta = replaceable.first, let release = beta.release {
			let install = beta.install
			let installed = InstalledRelease(version: install.version, buildVersion: install.buildVersion, installedAt: install.installedAt)
			if UpdateCheck.isNewer(release, than: installed, in: beta.offer.app) {
				parts.append("\(Self.name(of: install)) is a beta. Atelier can update it to \(release.releaseName), its latest release.")
			} else {
				parts.append("\(Self.name(of: install)) is a beta. Atelier can install \(release.releaseName), its latest release, in its place and keep the app's data. Some apps can't read data saved by a newer version.")
			}
			parts.append("Or keep \(install.version): you can still open and use it, but Atelier can't download, sign or install it again.")
		} else if replaceable.count > 1 {
			parts.append("\(replaceable.map { Self.name(of: $0.install) }.formatted(.list(type: .and))) are betas. Atelier can install each one's latest release in its place and keep the apps' data. Some apps can't read data saved by a newer version.")
			parts.append("Or keep them: you can still open and use them, but Atelier can't download, sign or install them again.")
		}
		let unlisted = betas.filter { $0.release == nil && !$0.isOwn }
		if unlisted.count == 1, let beta = unlisted.first {
			// A beta app, such as Delta's in AltStore's source, has no release of its own.
			let reason = beta.offer.app.isBeta ? "is a beta app" : "has no release"
			parts.append("\(Self.name(of: beta.install)) \(reason), so \(source.name) will no longer list it. You can still open and use it, but Atelier can't download, sign or install it again.")
		} else if unlisted.count > 1 {
			parts.append("\(unlisted.map { Self.name(of: $0.install) }.formatted(.list(type: .and))) have no release, so \(source.name) will no longer list them. You can still open and use them, but Atelier can't download, sign or install them again.")
		}
		if let own = betas.first(where: \.isOwn) {
			parts.append("\(Self.name(of: own.install)) is a beta and has no release yet, so its source will no longer list it. You can still sign it again, but it won't get updates while pre-releases are off.")
		}
		return parts.joined(separator: "\n\n")
	}

	/// Turn Off and Install, when a beta has a release to go back to.
	var installTitle: String? {
		let releases = betas.compactMap(\.release)
		switch releases.count {
		case 0: return nil
		case 1: return "Turn Off and Install \(releases[0].releaseName)"
		default: return "Turn Off and Install Releases"
		}
	}

	/// Turn Off, which leaves the betas as they are, and says so when
	/// Install is there too.
	var keepTitle: String {
		let replaceable = betas.filter { $0.release != nil }
		switch replaceable.count {
		case 0: return "Turn Off"
		case 1: return "Turn Off and Keep \(replaceable[0].install.version)"
		default: return "Turn Off and Keep the Betas"
		}
	}

	/// Kept betas can't be signed again, except Atelier itself.
	var keepIsDestructive: Bool { betas.contains { !$0.isOwn } }

	/// As the app's page and the Library name it: Nimbus 0.6.5.
	private static func name(of install: InstallRecord) -> String {
		"\(install.name) \(install.version)"
	}
}

/// Asks before a source's pre-releases go off while betas from it are
/// installed: their releases in their place, or the betas kept (#104).
struct PrereleasesOffConfirmation: ViewModifier {
	@Environment(SourcesModel.self) private var model
	@Environment(CatalogModel.self) private var catalog
	@Environment(InstallModel.self) private var installer
	@Environment(DownloadManager.self) private var downloads
	@Environment(CertificatesModel.self) private var certificates
	@Environment(\.modelContext) private var context

	func body(content: Content) -> some View {
		content
			.confirmationDialog(
				model.prereleasesOff?.title ?? "",
				isPresented: Binding(get: { model.prereleasesOff != nil }, set: { if !$0 { model.prereleasesOff = nil } }),
				titleVisibility: .visible,
				presenting: model.prereleasesOff
			) { request in
				if let installTitle = request.installTitle {
					Button(installTitle) { turnOff(request, installingReleases: true) }
				}
				Button(request.keepTitle, role: request.keepIsDestructive ? .destructive : nil) { turnOff(request, installingReleases: false) }
				Button("Cancel", role: .cancel) {}
			} message: { request in
				Text(request.message)
			}
	}

	private func turnOff(_ request: PrereleasesOff, installingReleases: Bool) {
		// Queued while the source still lists them as they're shown.
		if installingReleases {
			for beta in request.betas {
				guard let release = beta.release else { continue }
				installer.update(beta.install, to: release, from: beta.offer, downloads: downloads, certificates: certificates, into: context)
			}
		}
		model.setIncludesPrereleases(false, for: request.source)
		catalog.prereleasesChanged()
	}
}

/// GitHub's mark (Octicons, MIT), in the colour of the text around it.
struct GitHubMark: View {
	let size: CGFloat

	var body: some View {
		Image("GitHubMark")
			.renderingMode(.template)
			.resizable()
			.scaledToFit()
			.frame(width: size, height: size)
			.accessibilityLabel("GitHub")
	}
}

/// A source's touch-and-hold menu: its pre-release setting (#104), copy its
/// URL and remove it. A GitHub repo (#30) has its page instead of the URL,
/// and Atelier's own source (#24) can't be removed.
struct SourceMenu: View {
	let source: SourceRecord
	let remove: () -> Void
	@Environment(SourcesModel.self) private var model
	@Environment(CatalogModel.self) private var catalog
	@Query private var installs: [InstallRecord]
	@Environment(\.openURL) private var openURL

	var body: some View {
		Toggle(isOn: Binding(
			get: { model.listsPrereleases(source.url) },
			set: { include in
				// Betas installed from the source ask first.
				if !include, let request = PrereleasesOff(source: source, catalog: catalog.catalog, installs: installs) {
					model.prereleasesOff = request
				} else {
					model.setIncludesPrereleases(include, for: source)
					catalog.prereleasesChanged()
				}
			}
		)) {
			Label("Include Pre-releases", systemImage: "flask")
		}
		if GitHubRepo(sourceURL: source.url) != nil {
			Button("Open on GitHub", systemImage: "safari") { openURL(source.url) }
		} else {
			Button("Copy URL", systemImage: "doc.on.doc") {
				UIPasteboard.general.url = source.url
			}
		}
		// Atelier updates itself from its own (#24).
		if !source.isBuiltIn {
			Button("Remove", systemImage: "trash", role: .destructive, action: remove)
		}
	}
}

extension SourceRecord {
	/// Under its name on its card: when it last updated, or else its
	/// domain. Atelier's own says it's built in first (#24).
	var detail: String {
		let updated = lastRefreshedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" }
		guard isBuiltIn else { return updated ?? url.host ?? "" }
		return ["Built in", updated].compactMap { $0 }.joined(separator: " · ")
	}
}
