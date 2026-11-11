import AtelierCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import InstallKit
import Observation
import SigningKit
import UIKit

/// Test Actions' Offload Markers Test (9 Nov 2026): whether a free
/// Apple ID's offloaded app can keep a marker in its Home Screen spot, a
/// web clip that takes none of its 3 places. One profile makes a few
/// generic markers, a grey cloud named Offloaded, that any app can borrow;
/// the test hides them, lends them to the spots Offload keeps empty, tries
/// renaming one, puts them away and removes them, and says what tapping one
/// opened. Any other app's spot gets a stand-in, a small app Atelier
/// carries, signed as the app was, with its name and its icon greyed. It
/// never offloads, reinstalls or deletes an app, but its own stand-ins.
@MainActor
@Observable
final class OffloadMarkersTest {
	static let shared = OffloadMarkersTest()
	/// What the test found, kept across launches: a JSON `State`.
	static let stateKey = "offloadMarkersTest"
	/// How many markers the profile makes.
	static let count = 3
	/// The folder Put Them in a Folder makes.
	static let folderName = "Markers"
	/// The most log lines kept.
	static let logLines = 300

	enum Step: String, Codable, CaseIterable {
		case make, hide, folder, fill, name, putAway, remove
		case makeStandIns, removeStandIns

		/// Whether it writes the Home Screen.
		var writes: Bool {
			switch self {
			case .make, .remove: false
			case .hide, .folder, .fill, .name, .putAway, .makeStandIns, .removeStandIns: true
			}
		}
	}

	/// Where the markers were put out of sight.
	enum Hiding: String, Codable {
		case appLibrary, folder
	}

	/// An app Atelier installed, for lending markers to free Apple ID ones
	/// and making stand-ins for the others.
	struct App {
		var name: String
		var isFreeAppleID: Bool
		/// The certificate or Apple ID it was signed with.
		var certificateID: UUID?
		/// Its icon, as its source lists it.
		var iconURL: URL?
	}

	struct State: Codable {
		/// Each step's last result, by step.
		var results: [String: String] = [:]
		/// Each marker's web clip identifier, by number, as last seen.
		var ids: [Int: String] = [:]
		/// Where each marker is, by number, in words.
		var places: [Int: String] = [:]
		/// The app whose spot each lent marker holds, by number.
		var lent: [Int: String] = [:]
		/// The apps' names, by bundle ID.
		var names: [String: String] = [:]
		var hiddenIn: Hiding?
		/// When the profile went to iOS, until its markers show up.
		var sent: Date?
		/// What the last tap on a marker opened.
		var opened: String?
		var openedLink: String?
		var log: [String] = []
		/// Each stand-in's bundle ID, by the bundle ID of the app it stands
		/// in for.
		var standIns: [String: String] = [:]
		/// Where each stand-in is, in words, by its app's bundle ID.
		var standInPlaces: [String: String] = [:]
	}

	private(set) var state: State
	/// The step running, if any.
	private(set) var running: Step?
	/// Shows the test's page over Atelier, when a marker opened it.
	var showsFromLink = false

	init() {
		state = UserDefaults.standard.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
	}

	func result(_ step: Step) -> String? {
		state.results[step.rawValue]
	}

	var logText: String {
		state.log.joined(separator: "\n")
	}

	private var scheme: String { RouteASetup.callbackScheme }

	// MARK: Running a step

	func run(_ step: Step, apps: [String: App]) {
		guard running == nil else { return }
		running = step
		for (bundleID, app) in apps { state.names[bundleID] = app.name }
		// A read and a write can take a while; a locked iPhone would stop them.
		UIApplication.shared.isIdleTimerDisabled = true
		Task {
			let installer = RouteASetup.shared.makeInstaller()
			let line: String
			if step.writes, ThisDevice.name == "iPhone", !GapsQuestion.isAnswered {
				line = "Mark the open spaces to keep first, in Settings › Open Spaces, as this rewrites your Home Screen."
			} else if case .unavailable(let why) = await installer.check(startingVPN: true) {
				line = "Couldn’t start: \(why)"
			} else {
				do {
					line = try await perform(step, installer: installer, apps: apps)
				} catch let problem as HomeScreenLayout.PlacingProblem {
					line = "Couldn’t place it: \(problem)."
					log("\(step.rawValue): couldn't place it: \(problem)")
				} catch {
					line = "Failed: \(HomeScreenSpots.why(error))"
					log("\(step.rawValue): failed: \(HomeScreenSpots.why(error))")
				}
			}
			UIApplication.shared.isIdleTimerDisabled = false
			state.results[step.rawValue] = line
			save()
			running = nil
		}
	}

	private func perform(_ step: Step, installer: PairingInstaller, apps: [String: App]) async throws -> String {
		switch step {
		case .make: return try await make(installer)
		case .hide: return try await hide(installer)
		case .folder: return try await folder(installer)
		case .fill: return try await fill(installer, apps: apps)
		case .name: return try await rename(installer, apps: apps)
		case .putAway: return try await putAway(installer)
		case .remove: return try await remove(installer)
		case .makeStandIns: return try await makeStandIns(installer, apps: apps)
		case .removeStandIns: return try await removeStandIns(installer)
		}
	}

	// MARK: The steps

	/// Hands iOS the profile with the markers, for you to approve in
	/// Settings.
	private func make(_ installer: PairingInstaller) async throws -> String {
		let bundleID = Bundle.main.bundleIdentifier ?? "com.atelier.app"
		let profile = try OffloadMarkers.profile(count: Self.count, scheme: scheme, bundleID: bundleID, icon: Self.markerIcon())
		log("profile: sending \(Self.count) markers opening \(scheme)://marker/…, \(ByteCountFormatter.string(fromByteCount: Int64(profile.count), countStyle: .file))")
		let requests: [OffloadMarkers.Request] = [.hello, .list, .install(profile)]
		let answers = try await installer.profileRequests(requests)
		for (request, answer) in zip(requests, answers) {
			log("profile: \(request.type): \(answer.status ?? "no status")\(answer.error.map { ", \($0)" } ?? "")")
		}
		if answers.count > 1 {
			let names = answers[1].profiles.map { $0.name ?? $0.identifier }
			log("profile: installed before: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
		}
		guard let install = answers.last, answers.count == requests.count else { return "iOS gave no answer to the profile." }
		guard install.isAcknowledged else { return "iOS didn’t take the profile: \(install.error ?? "no reason given")." }
		state.sent = .now
		return "Sent at \(Self.time(.now)). Approve it in Settings › General › VPN & Device Management, then come back here, and Atelier looks for the markers."
	}

	/// Once the profile is approved, finds its markers on the Home Screen.
	/// Atelier looks when the page shows and when it comes back to the
	/// front.
	func refresh() async {
		guard let sent = state.sent, running == nil else { return }
		let installer = RouteASetup.shared.makeInstaller()
		guard case .ready = await installer.check(startingVPN: false) else { return }
		guard let screen = try? await installer.homeScreen() else { return }
		let found = note(screen.layout)
		guard !found.isEmpty else {
			log("read: no markers yet")
			save()
			return
		}
		state.sent = nil
		state.results[Step.make.rawValue] = "\(found.count) \(found.count == 1 ? "marker" : "markers"), approved by \(Self.time(.now)), sent at \(Self.time(sent)). iOS put them \(Self.whereabouts(found))."
		save()
	}

	/// Writes the Home Screen without the markers, and puts them in the App
	/// Library's list, then reads where iOS put them.
	private func hide(_ installer: PairingInstaller) async throws -> String {
		let screen = try await installer.homeScreen()
		note(screen.layout)
		let ids = state.ids.sorted { $0.key < $1.key }.map(\.value)
		guard !ids.isEmpty else { return "No markers to hide: Make Markers first." }
		returnLent()
		var layout = screen.layout
		for id in ids { layout = layout.removing(id) }
		let appLibrary = layout.appLibrary(installed: screen.apps) + ids
		let gaps = YourGaps.gaps(installed: screen.apps)
		log("write: without the \(ids.count) markers, which go in the App Library's list, with \(appLibrary.count) there")
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary, gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		state.hiddenIn = .appLibrary
		let back = note(after)
		guard !back.isEmpty else {
			for number in state.ids.keys { state.places[number] = "Not on the Home Screen" }
			log("read back: no markers on the Home Screen")
			return "Read back: none on the Home Screen. Search your App Library for Offloaded to see whether they’re there."
		}
		log("read back: \(back.count) still on the Home Screen")
		return "Read back: iOS kept \(back.count) on the Home Screen, \(Self.whereabouts(back))."
	}

	/// Puts the markers in a folder on the last page.
	private func folder(_ installer: PairingInstaller) async throws -> String {
		let screen = try await installer.homeScreen()
		note(screen.layout)
		let ids = state.ids.sorted { $0.key < $1.key }.map(\.value)
		guard !ids.isEmpty else { return "No markers to put away: Make Markers first." }
		returnLent()
		let layout = screen.layout.foldering(ids, named: Self.folderName)
		let appLibrary = layout.appLibrary(installed: screen.apps)
		let gaps = YourGaps.gaps(installed: screen.apps)
		log("write: the \(ids.count) markers in a folder named \(Self.folderName), at \(HomeScreenSpots.text(layout.spot(of: ids[0])))")
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary, gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		state.hiddenIn = .folder
		let back = note(after)
		let inFolder = back.filter { $0.spot?.folder?.name == Self.folderName }
		log("read back: \(inFolder.count) of \(ids.count) in \(Self.folderName)")
		guard inFolder.count == ids.count else { return "Read back: \(inFolder.count) of \(ids.count) in \(Self.folderName); the others are \(Self.whereabouts(back.filter { $0.spot?.folder?.name != Self.folderName }))." }
		return "Read back: all \(ids.count) in \(Self.folderName), \(HomeScreenSpots.text(after.spot(of: ids[0])).lowercasedFirst)."
	}

	/// Lends a marker to each spot Offload keeps empty for a free Apple
	/// ID's app, as Offload would.
	private func fill(_ installer: PairingInstaller, apps: [String: App]) async throws -> String {
		let screen = try await installer.homeScreen()
		note(screen.layout)
		guard !state.ids.isEmpty else { return "No markers to lend: Make Markers first." }
		let held = HomeScreenSpots.heldGaps(installed: screen.apps)
		let lentApps = Set(state.lent.values)
		let waiting = held
			.filter { apps[$0.key]?.isFreeAppleID == true && !lentApps.contains($0.key) }
			.sorted { name($0.key).lowercased() < name($1.key).lowercased() }
		log("fill: \(held.count) spots kept empty, \(waiting.count) of them free Apple ID apps' without a marker")
		guard !waiting.isEmpty else {
			return held.isEmpty
				? "No spot is kept empty: offload a free Apple ID app first, with Keep apps’ spots on."
				: "No free Apple ID app’s spot is kept empty without a marker. The ones kept are other apps’, for stand-ins."
		}
		var free = state.ids.keys.filter { state.lent[$0] == nil }.sorted()
		var layout = screen.layout
		var gaps = YourGaps.gaps(installed: screen.apps)
		var filled: [(number: Int, bundleID: String)] = []
		for (bundleID, spot) in waiting {
			guard let number = free.first, let id = state.ids[number] else { break }
			free.removeFirst()
			layout = try layout.placing(id, at: spot)
			gaps.held[bundleID] = nil
			filled.append((number, bundleID))
			log("fill: marker \(number) to \(name(bundleID))’s spot, \(HomeScreenSpots.text(spot))")
		}
		guard !filled.isEmpty else { return "Every marker is lent already." }
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary(layout, installed: screen.apps), gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		var lines: [String] = []
		for (number, bundleID) in filled {
			// The marker holds the spot now, so writes stop keeping it empty
			// until Put Them Away.
			HomeScreenSpots.release(bundleID)
			state.lent[number] = bundleID
			let id = state.ids[number] ?? ""
			let now = after.spot(of: id)
			let asWritten = now?.description == layout.spot(of: id)?.description
			log("read back: marker \(number) at \(HomeScreenSpots.text(now))\(asWritten ? ", as written" : ", not \(HomeScreenSpots.text(layout.spot(of: id)))")")
			lines.append("Marker \(number) in \(name(bundleID))’s spot, \(HomeScreenSpots.text(now).lowercasedFirst)\(asWritten ? "" : " (not where written)")")
		}
		note(after)
		return lines.joined(separator: ". ") + "."
	}

	/// Tries naming a lent marker after its app, through the layout.
	private func rename(_ installer: PairingInstaller, apps: [String: App]) async throws -> String {
		guard let loan = state.lent.min(by: { $0.key < $1.key }), let id = state.ids[loan.key] else {
			return "No marker holds an app’s spot: Fill Held Spots first."
		}
		let number = loan.key, bundleID = loan.value
		let screen = try await installer.homeScreen()
		let appName = apps[bundleID]?.name ?? name(bundleID)
		var raw = screen.layout.raw(of: id)?.values ?? ["displayIdentifier": id]
		raw["displayName"] = appName
		let gaps = YourGaps.gaps(installed: screen.apps)
		var archive = screen.layout.archive(appLibrary: appLibrary(screen.layout, installed: screen.apps), gaps: gaps)
		for key in ["buttonBar", "iconLists"] {
			archive[key] = archive[key].map { Self.replacing(id, with: raw, in: $0) }
		}
		log("write: marker \(number) as \(appName), with what iOS gives for it: \(raw.keys.sorted().joined(separator: ", "))")
		let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
		let after = try await installer.writeHomeScreen(archive: data)
		YourGaps.written(screen.layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		note(after)
		guard after.placedIDs.contains(id) else {
			log("read back: marker \(number) is gone from the Home Screen")
			return "Read back: marker \(number) is gone from the Home Screen, so iOS didn’t take it that way."
		}
		let now = after.raw(of: id)?.values["displayName"] as? String
		log("read back: marker \(number) named \(now ?? "nothing")")
		return now == appName ? "Read back: now \(appName). Check your Home Screen too." : "Read back: still \(now ?? "unnamed")."
	}

	/// Takes the lent markers out of the spots, back out of sight, and has
	/// writes keep those spots empty again, as Reinstall would.
	private func putAway(_ installer: PairingInstaller) async throws -> String {
		guard !state.lent.isEmpty else { return "No marker holds an app’s spot." }
		let screen = try await installer.homeScreen()
		note(screen.layout)
		let names = state.lent.sorted { $0.key < $1.key }.map { name($0.value) }
		returnLent()
		let ids = state.ids.sorted { $0.key < $1.key }.map(\.value)
		var layout = screen.layout
		let appLibrary: [String]
		let place: String
		if state.hiddenIn == .folder {
			layout = layout.foldering(ids, named: Self.folderName)
			appLibrary = layout.appLibrary(installed: screen.apps)
			place = "in \(Self.folderName)"
		} else {
			for id in ids { layout = layout.removing(id) }
			appLibrary = layout.appLibrary(installed: screen.apps) + ids
			place = "out of the Home Screen"
		}
		let gaps = YourGaps.gaps(installed: screen.apps)
		log("write: markers \(place), and \(names.formatted(.list(type: .and)))’s spots kept empty again")
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary, gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		note(after)
		return "Markers \(place), and \(names.formatted(.list(type: .and)))’s \(names.count == 1 ? "spot is" : "spots are") kept empty again."
	}

	/// Has iOS remove the profile, and its markers.
	private func remove(_ installer: PairingInstaller) async throws -> String {
		let identifier = OffloadMarkers.profileIdentifier(bundleID: Bundle.main.bundleIdentifier ?? "com.atelier.app")
		let listed = try await installer.profileRequests([.hello, .list])
		guard let list = listed.last, list.isAcknowledged else { return "iOS didn’t list its profiles: \(listed.last?.error ?? "no answer")." }
		log("profile: installed: \(list.profiles.map { $0.name ?? $0.identifier }.joined(separator: ", "))")
		guard let profile = list.profiles.first(where: { $0.identifier == identifier }) else {
			return "No marker profile is installed."
		}
		let removal = try OffloadMarkers.Request.remove(identifier: profile.identifier, uuid: profile.uuid, version: profile.version)
		let removed = try await installer.profileRequests([.hello, removal])
		log("profile: RemoveProfile: \(removed.last?.status ?? "no status")\(removed.last?.error.map { ", \($0)" } ?? "")")
		guard removed.last?.isAcknowledged == true else { return "iOS didn’t remove it: \(removed.last?.error ?? "no answer")." }
		returnLent()
		state.ids = [:]
		state.places = [:]
		state.hiddenIn = nil
		state.sent = nil
		let left = (try? await installer.homeScreen()).map { note($0.layout) } ?? []
		return left.isEmpty
			? "Removed at \(Self.time(.now)). None left on the Home Screen."
			: "Removed at \(Self.time(.now)), but \(left.count) still on the Home Screen, \(Self.whereabouts(left))."
	}

	/// Installs a stand-in in each spot Offload keeps empty for an app that
	/// isn't a free Apple ID's, signed with the certificate the app was,
	/// as Offload would.
	private func makeStandIns(_ installer: PairingInstaller, apps: [String: App]) async throws -> String {
		guard let package = Bundle.main.url(forResource: "StandIn", withExtension: "ipa") else {
			return "This build of Atelier has no stand-in app."
		}
		let screen = try await installer.homeScreen()
		let held = HomeScreenSpots.heldGaps(installed: screen.apps)
		let waiting = held
			.filter { apps[$0.key].map { !$0.isFreeAppleID } == true && state.standIns[$0.key] == nil }
			.sorted { name($0.key).lowercased() < name($1.key).lowercased() }
		log("stand-ins: \(held.count) spots kept empty, \(waiting.count) of them other apps’ without a stand-in")
		guard !waiting.isEmpty else {
			return held.isEmpty
				? "No spot is kept empty: offload an app that isn’t a free Apple ID’s first, with Keep apps’ spots on."
				: "No other app’s spot is kept empty without a stand-in. The ones kept are free Apple ID apps’, for markers."
		}
		var made: [(bundleID: String, standIn: String, spot: HomeScreenSpot)] = []
		var notMade: [String] = []
		for (bundleID, spot) in waiting {
			let app = apps[bundleID]
			guard let certificateID = app?.certificateID else {
				log("stand-ins: \(name(bundleID)): Atelier doesn’t know what signed it")
				notMade.append("None for \(name(bundleID)), as Atelier doesn’t know what signed it")
				continue
			}
			guard let identity = try? CertificatesModel.shared.signingIdentity(for: certificateID) else {
				log("stand-ins: \(name(bundleID)): not signed with a certificate Atelier has")
				notMade.append("None for \(name(bundleID)), as it was signed with an Apple ID, which stand-ins don’t use yet")
				continue
			}
			let standIn = OffloadMarkers.standInBundleID(of: bundleID)
			do {
				let iconData = await Self.download(app?.iconURL)
				log("stand-ins: \(name(bundleID)): signing \(standIn), \(iconData == nil ? "with no icon to grey" : "with its icon greyed")")
				let options = SigningOptions(
					displayName: name(bundleID),
					bundleID: standIn,
					infoPlistValues: [OffloadMarkers.standInLinkKey: OffloadMarkers.standInLink(bundleID, scheme: scheme).absoluteString],
					icon: IconChange(picture: Self.standInIcon(iconData, name: name(bundleID)))
				)
				let signed = try await SigningKit.sign(ipa: package, with: identity, options: options)
				defer { try? FileManager.default.removeItem(at: signed.url) }
				let result = try await installer.install(InstallPackage(url: signed.url, info: signed.info)) { [weak self] event in
					if case .log(let line) = event { self?.log("install: \(line)") }
				}
				log("stand-ins: \(name(bundleID)): installed, \(result == .unconfirmed ? "unconfirmed" : "confirmed")")
				state.standIns[bundleID] = standIn
				made.append((bundleID, standIn, spot))
			} catch {
				log("stand-ins: \(name(bundleID)): failed: \(HomeScreenSpots.why(error))")
				notMade.append("None for \(name(bundleID)): \(HomeScreenSpots.why(error))")
			}
		}
		save()
		guard !made.isEmpty else { return notMade.joined(separator: ". ") + "." }
		// SpringBoard places a new app a moment after installd has it, or
		// never, when new apps go to the App Library only.
		var screenNow = try await installer.homeScreen()
		var waited = 0
		while waited < 5, !made.allSatisfy({ screenNow.layout.placedIDs.contains($0.standIn) }) {
			waited += 1
			try await Task.sleep(for: .seconds(1))
			screenNow = try await installer.homeScreen()
		}
		let unplaced = made.filter { !screenNow.layout.placedIDs.contains($0.standIn) }.map(\.standIn)
		log("read: after \(waited) s, \(unplaced.isEmpty ? "iOS has put every stand-in on the Home Screen" : "not on the Home Screen yet: \(unplaced.joined(separator: ", "))")")
		var layout = screenNow.layout
		var gaps = YourGaps.gaps(installed: screenNow.apps)
		for standIn in made {
			log("write: \(name(standIn.bundleID))’s stand-in in its spot, \(HomeScreenSpots.text(standIn.spot))")
			layout = try layout.placing(standIn.standIn, at: standIn.spot)
			gaps.held[standIn.bundleID] = nil
		}
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary(layout, installed: screenNow.apps), gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screenNow.names) { self.log("write: \($0)") }
		var lines: [String] = []
		for standIn in made {
			// The stand-in holds the spot now, so writes stop keeping it
			// empty until Remove Stand-ins.
			HomeScreenSpots.release(standIn.bundleID)
			let now = after.spot(of: standIn.standIn)
			let asWritten = now?.description == layout.spot(of: standIn.standIn)?.description
			state.standInPlaces[standIn.bundleID] = HomeScreenSpots.text(now)
			log("read back: \(name(standIn.bundleID))’s stand-in at \(HomeScreenSpots.text(now))\(asWritten ? ", as written" : "")")
			lines.append("\(name(standIn.bundleID))’s, \(HomeScreenSpots.text(now).lowercasedFirst)\(asWritten ? "" : " (not where written)")")
		}
		note(after)
		return (lines + notMade).joined(separator: ". ") + "."
	}

	/// Deletes the stand-ins, and has writes keep their apps' spots empty
	/// again, as Reinstall would before putting the apps back.
	private func removeStandIns(_ installer: PairingInstaller) async throws -> String {
		guard !state.standIns.isEmpty else { return "No stand-in to remove." }
		var removed: [String] = []
		var left: [String] = []
		for (bundleID, standIn) in state.standIns.sorted(by: { $0.key < $1.key }) {
			HomeScreenSpots.hold(again: bundleID)
			do {
				if await installer.isInstalled(standIn) == false {
					log("stand-ins: \(standIn) was gone already")
				} else {
					try await installer.uninstall(standIn)
					log("stand-ins: deleted \(standIn)")
				}
				state.standIns[bundleID] = nil
				state.standInPlaces[bundleID] = nil
				removed.append(standIn)
			} catch {
				HomeScreenSpots.release(bundleID)
				log("stand-ins: couldn't delete \(standIn): \(HomeScreenSpots.why(error))")
				left.append("\(name(bundleID))’s couldn’t be deleted: \(HomeScreenSpots.why(error))")
			}
		}
		save()
		guard !removed.isEmpty else { return left.joined(separator: ". ") + "." }
		// Their spots, empty again, as Offload left them.
		let screen = try await installer.homeScreen()
		var layout = screen.layout
		for standIn in removed { layout = layout.removing(standIn) }
		let gaps = YourGaps.gaps(installed: screen.apps.filter { !removed.contains($0.bundleID) })
		log("write: \(removed.count) \(removed.count == 1 ? "spot" : "spots") kept empty again")
		let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary(layout, installed: screen.apps.filter { !removed.contains($0.bundleID) }), gaps: gaps)
		YourGaps.written(layout, gaps: gaps, names: screen.names) { self.log("write: \($0)") }
		note(after)
		let still = removed.filter { after.placedIDs.contains($0) }
		if !still.isEmpty { log("read back: still on the Home Screen: \(still.joined(separator: ", "))") }
		let deleted = state.standIns.isEmpty ? "All deleted" : "\(removed.count) deleted"
		return (["\(deleted), and their spots kept empty again"] + left).joined(separator: ". ") + "."
	}

	// MARK: A tap on a marker

	/// Says which marker or stand-in opened `url`, if one did, and shows
	/// the page.
	func open(_ url: URL) -> Bool {
		if let bundleID = OffloadMarkers.standIn(of: url, scheme: scheme) {
			state.opened = "Opened by \(name(bundleID))’s stand-in, at \(Self.time(.now))"
			state.openedLink = url.absoluteString
			log("opened: \(url.absoluteString)")
			save()
			showsFromLink = true
			return true
		}
		guard let number = OffloadMarkers.number(of: url, scheme: scheme) else { return false }
		let line: String
		if let bundleID = state.lent[number] {
			line = "Opened by marker \(number), in \(name(bundleID))’s spot"
		} else {
			line = "Opened by marker \(number), which holds no app’s spot"
		}
		state.opened = "\(line), at \(Self.time(.now))"
		state.openedLink = url.absoluteString
		log("opened: \(url.absoluteString)")
		save()
		showsFromLink = true
		return true
	}

	// MARK: Keeping track

	/// Notes the markers `layout` places: their identifiers and where they
	/// are, and the keys iOS gives for web clips, once.
	@discardableResult
	private func note(_ layout: HomeScreenLayout) -> [OffloadMarker] {
		let found = layout.markers(scheme: scheme)
		if !found.isEmpty, !state.log.contains(where: { $0.contains("web clip keys:") }) {
			log("read: web clip keys: \(found[0].keys.joined(separator: ", "))\(found[0].byLink ? "" : "; no link, so numbered in order")")
		}
		for marker in found {
			state.ids[marker.number] = marker.id
			state.places[marker.number] = state.lent[marker.number].map { "\(name($0))’s spot" } ?? HomeScreenSpots.text(marker.spot)
		}
		let placed = Set(found.map(\.number))
		for number in state.ids.keys where !placed.contains(number) {
			state.places[number] = "Not on the Home Screen"
		}
		save()
		return found
	}

	/// Has writes keep the lent markers' spots empty again, and forgets
	/// the loans.
	private func returnLent() {
		for bundleID in state.lent.values { HomeScreenSpots.hold(again: bundleID) }
		state.lent = [:]
	}

	private func name(_ bundleID: String) -> String {
		state.names[bundleID] ?? HomeScreenSpots.noted(bundleID)?.name ?? bundleID
	}

	/// A stand-in, for Where They Are.
	struct StandInRow: Identifiable {
		/// Its app's bundle ID.
		var id: String
		var name: String
		var place: String
	}

	/// The stand-ins, by their apps' names, and where each is.
	var standInRows: [StandInRow] {
		state.standIns.keys
			.map { StandInRow(id: $0, name: name($0), place: state.standInPlaces[$0] ?? "Unknown") }
			.sorted { $0.name.lowercased() < $1.name.lowercased() }
	}

	/// The apps only in the App Library for a write of `layout`, with the
	/// markers hidden there.
	private func appLibrary(_ layout: HomeScreenLayout, installed: [HomeScreenApp]) -> [String] {
		let placed = layout.placedIDs
		let hidden = state.hiddenIn == .appLibrary ? state.ids.values.filter { !placed.contains($0) }.sorted() : []
		return layout.appLibrary(installed: installed) + hidden
	}

	private func log(_ line: String) {
		state.log.append("\(Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(line)")
		if state.log.count > Self.logLines { state.log.removeFirst(state.log.count - Self.logLines) }
	}

	private func save() {
		UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: Self.stateKey)
	}

	func clearLog() {
		state.log = []
		save()
	}

	// MARK: Helpers

	/// `value`, a layout's lists as setIconState imports them, with the app
	/// or web clip `id` as `raw` instead of its identifier, in folders too.
	static func replacing(_ id: String, with raw: [String: Any], in value: Any) -> Any {
		if let text = value as? String { return text == id ? raw : text }
		if let list = value as? [Any] { return list.map { replacing(id, with: raw, in: $0) } }
		if var folder = value as? [String: Any], let lists = folder["iconLists"] {
			folder["iconLists"] = replacing(id, with: raw, in: lists)
			return folder
		}
		return value
	}

	/// "on page 11", "on pages 10 and 11", "in Markers".
	static func whereabouts(_ markers: [OffloadMarker]) -> String {
		let folders = Set(markers.compactMap { $0.spot?.folder?.name })
		let pages = Set(markers.compactMap { $0.spot?.folder == nil ? $0.spot?.page : nil }).sorted().map { "\($0 + 1)" }
		var parts: [String] = []
		if !pages.isEmpty { parts.append(pages.count == 1 ? "on page \(pages[0])" : "on pages \(pages.formatted(.list(type: .and)))") }
		if markers.contains(where: { $0.spot?.page == nil && $0.spot?.folder == nil }) { parts.append("in the Dock") }
		parts += folders.sorted().map { "in \($0)" }
		return parts.isEmpty ? "somewhere Atelier can’t see" : parts.joined(separator: " and ")
	}

	static func time(_ date: Date) -> String {
		date.formatted(date: .omitted, time: .shortened)
	}

	/// A marker's icon: a white cloud on grey, as a PNG, which iOS rounds.
	static func markerIcon() -> Data {
		let side: CGFloat = 180
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
			let colors = [
				UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1).cgColor,
				UIColor(red: 0.77, green: 0.77, blue: 0.80, alpha: 1).cgColor,
			] as CFArray
			if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
				context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
			}
			let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .medium)
			if let cloud = UIImage(systemName: "icloud", withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
				let size = cloud.size
				cloud.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
			}
		}
	}
}

extension OffloadMarkersTest.State {
	/// Reads what earlier builds kept too, which has no stand-ins.
	init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init()
		results = try values.decodeIfPresent([String: String].self, forKey: .results) ?? [:]
		ids = try values.decodeIfPresent([Int: String].self, forKey: .ids) ?? [:]
		places = try values.decodeIfPresent([Int: String].self, forKey: .places) ?? [:]
		lent = try values.decodeIfPresent([Int: String].self, forKey: .lent) ?? [:]
		names = try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
		hiddenIn = try values.decodeIfPresent(OffloadMarkersTest.Hiding.self, forKey: .hiddenIn)
		sent = try values.decodeIfPresent(Date.self, forKey: .sent)
		opened = try values.decodeIfPresent(String.self, forKey: .opened)
		openedLink = try values.decodeIfPresent(String.self, forKey: .openedLink)
		log = try values.decodeIfPresent([String].self, forKey: .log) ?? []
		standIns = try values.decodeIfPresent([String: String].self, forKey: .standIns) ?? [:]
		standInPlaces = try values.decodeIfPresent([String: String].self, forKey: .standInPlaces) ?? [:]
	}
}

extension OffloadMarkersTest {
	/// What `url` serves, if it's a picture, for a stand-in's icon.
	static func download(_ url: URL?) async -> Data? {
		guard let url else { return nil }
		guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)) else { return nil }
		if let status = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) { return nil }
		return UIImage(data: data) == nil ? nil : data
	}

	/// A stand-in's icon, as a PNG: the app's own greyed, as the Home
	/// Screen shows an offloaded app's, or its first letter on grey when
	/// there's none, with a cloud in a white circle in the corner.
	static func standInIcon(_ icon: Data?, name: String) -> Data {
		let side: CGFloat = 512
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		let bounds = CGRect(x: 0, y: 0, width: side, height: side)
		return UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { context in
			UIColor.white.setFill()
			context.fill(bounds)
			if let icon, let image = greyed(icon) {
				image.draw(in: bounds, blendMode: .normal, alpha: 0.62)
			} else {
				UIColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1).setFill()
				context.fill(bounds)
				let letter = String(name.prefix(1)).uppercased() as NSString
				let attributes: [NSAttributedString.Key: Any] = [
					.font: UIFont.systemFont(ofSize: side * 0.5, weight: .semibold),
					.foregroundColor: UIColor.white,
				]
				let size = letter.size(withAttributes: attributes)
				letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
			}
			// Clear of the corner iOS rounds off.
			let badge = CGRect(x: side * 0.6, y: side * 0.6, width: side * 0.3, height: side * 0.3)
			context.cgContext.setShadow(offset: CGSize(width: 0, height: side * 0.006), blur: side * 0.02, color: UIColor.black.withAlphaComponent(0.18).cgColor)
			UIColor.white.setFill()
			context.cgContext.fillEllipse(in: badge)
			context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
			let configuration = UIImage.SymbolConfiguration(pointSize: badge.width * 0.42, weight: .semibold)
			if let cloud = UIImage(systemName: "icloud", withConfiguration: configuration)?.withTintColor(UIColor(red: 0.54, green: 0.54, blue: 0.56, alpha: 1), renderingMode: .alwaysOriginal) {
				let size = cloud.size
				cloud.draw(in: CGRect(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2, width: size.width, height: size.height))
			}
		}
	}

	/// `icon` with little of its colour left, a little lighter.
	private static func greyed(_ icon: Data) -> UIImage? {
		guard let input = CIImage(data: icon) else { return nil }
		let filter = CIFilter.colorControls()
		filter.inputImage = input
		filter.saturation = 0.2
		filter.brightness = 0.04
		guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: input.extent) else { return nil }
		return UIImage(cgImage: image)
	}
}

private extension String {
	/// "page 9, 20th" from "Page 9, 20th".
	var lowercasedFirst: String {
		prefix(1).lowercased() + dropFirst()
	}
}
