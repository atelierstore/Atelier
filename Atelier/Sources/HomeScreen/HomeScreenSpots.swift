import AtelierCore
import Foundation
import InstallKit
import Observation

/// Keeps an app's Home Screen spot when Atelier deletes it and installs it
/// again (5 Nov 2026), while Settings › Home Screen › Keep apps’
/// spots is on, as it is unless turned off (9 Nov 2026). Offload
/// notes where the app is and Reinstall puts it back. So does every
/// install that deletes the app first: Reinstall required, and moving to
/// or from an Apple ID. A spot is noted under the bundle ID the app had,
/// until the app is back. Offload also keeps the spot empty with a gap
/// until Reinstall (6 Nov 2026), which every write keeps while the
/// app is away. On an iPhone, nothing is noted until the gaps question is
/// answered (`GapsQuestion`).
@MainActor
final class HomeScreenSpots: HomeScreenKeeping {
	/// Where each app Atelier deleted to install again was, by the bundle
	/// ID it had: a JSON `[String: Noted]`.
	nonisolated static let notedKey = "homeScreenSpots"
	/// Whether Atelier keeps apps' spots; on unless turned off.
	nonisolated static let onKey = "keepHomeScreenSpots"

	/// Nonisolated, as is what reads the spots noted, for the Library's
	/// lines about an offloaded app.
	nonisolated static var isOn: Bool {
		UserDefaults.standard.object(forKey: onKey) as? Bool ?? true
	}
	/// How long to wait for SpringBoard to place an app installd has just
	/// installed, a second at a time.
	static let placingWait = 3

	/// Where an app was before Atelier deleted it.
	struct Noted: Codable, Equatable {
		/// Nil when it was only in the App Library.
		var spot: HomeScreenSpot?
		var at: Date
		/// Whether Offload left a gap there, which writes keep until the
		/// app is back. Nil in what earlier builds noted.
		var holdsGap: Bool?
		/// The app's name, for the log and Open Spaces while it's away. Nil
		/// in what earlier builds noted.
		var name: String?
	}

	private let installer: PairingInstaller

	init(installer: PairingInstaller) {
		self.installer = installer
	}

	func note(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		guard Self.isOn else {
			// Off, the app goes where iOS puts it, also once it's on again.
			Self.take(bundleID)
			return
		}
		let say = Self.say(events)
		// Deleted without the question, such as by an update in the
		// background: no gap closes before you're asked.
		guard GapsQuestion.allowsWrites else {
			say("Atelier hasn't asked about open spaces yet, so \(name) goes where iOS puts it")
			Self.take(bundleID)
			return
		}
		do {
			let screen = try await installer.homeScreen()
			guard screen.apps.contains(where: { $0.bundleID == bundleID }) else {
				// Gone already, such as after a failed try: the spot noted
				// then stays.
				if let noted = Self.noted(bundleID) {
					say("\(name) isn't on this \(ThisDevice.name), so it goes back to \(Self.text(noted.spot)), as noted \(Self.when(noted.at))")
				} else {
					say("\(name) isn't on this \(ThisDevice.name), so it goes where iOS puts it")
				}
				return
			}
			let spot = screen.layout.spot(of: bundleID)
			Self.save(Noted(spot: spot, at: .now, name: name), for: bundleID)
			say("before deleting it, \(name) is at \(Self.text(spot))")
		} catch {
			say("couldn't read where \(name) is, so it goes where iOS puts it: \(Self.why(error))")
			Self.take(bundleID)
		}
	}

	/// Keeps the spot of `bundleID`, which Offload just deleted, empty until
	/// Reinstall: writes the layout with a gap there, which later writes
	/// keep while the app is away. Only on an iPhone's page with an icon
	/// after the spot, as nothing else would move into it, and without
	/// widgets: the Dock and folders keep no gaps.
	func hold(_ bundleID: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		guard Self.isOn, var entry = Self.noted(bundleID), let spot = entry.spot else { return }
		let say = Self.say(events)
		if let folder = spot.folder {
			say("folders keep no open spaces, so \(name)'s place in \(folder.name) isn't kept empty")
			return
		}
		guard let page = spot.page else {
			say("the Dock keeps no open spaces, so \(name)'s place in it isn't kept empty")
			return
		}
		guard ThisDevice.name == "iPhone" else {
			say("only an iPhone's pages keep open spaces here, so \(name)'s spot isn't kept empty")
			return
		}
		do {
			let screen = try await installer.homeScreen()
			var gaps = YourGaps.gaps(installed: screen.apps)
			gaps.held[bundleID] = spot
			guard screen.layout.gapPlaces(HomeScreenGaps(held: [bundleID: spot], marked: gaps.marked))[page] != nil else {
				say("\(name)'s spot isn't kept empty: nothing comes after it on page \(page + 1), or the page has widgets or no room")
				return
			}
			let appLibrary = screen.appLibrary
			say("keeping \(name)'s spot empty at \(Self.text(spot)), with \(appLibrary.count) in the App Library\(Self.others(gaps.held.count - 1))\(YourGaps.kept(screen.layout, gaps))")
			let after = try await installer.writeHomeScreen(screen.layout, appLibrary: appLibrary, gaps: gaps)
			entry.holdsGap = true
			Self.save(entry, for: bundleID)
			YourGaps.written(screen.layout, gaps: gaps, names: screen.names, say: say)
			Self.readBack(after, written: screen.layout, names: screen.names, say: say)
		} catch {
			say("couldn't keep \(name)'s spot empty: \(Self.why(error))")
		}
	}

	func putBack(_ bundleID: String, notedAs noted: String, name: String, events: @escaping @MainActor (InstallEvent) -> Void) async {
		let entry = Self.take(noted)
		guard Self.isOn else { return }
		let say = Self.say(events)
		guard let entry else {
			say("no spot was noted for \(name), so it stays where iOS put it")
			return
		}
		do {
			var screen = try await installer.homeScreen()
			// SpringBoard places a new app a moment after installd has it,
			// unless new apps go to the App Library only.
			var waited = 0
			while !screen.layout.placedIDs.contains(bundleID), waited < Self.placingWait {
				waited += 1
				try await Task.sleep(for: .seconds(1))
				screen = try await installer.homeScreen()
			}
			let now = screen.layout.spot(of: bundleID)
			say("after installing it, iOS put \(name) at \(Self.text(now))")
			if now?.description == entry.spot?.description {
				say("\(name) is in its spot already")
				return
			}
			// Something came into its spot while it was away, such as an
			// icon you moved there: putting the app back would push it and
			// the icons after it along, so the app stays where iOS put it
			// (8 Nov 2026).
			if let spot = entry.spot, let taken = screen.layout.removing(bundleID).taken(spot), !taken.isEmpty {
				say("\(YourGaps.names(taken, screen.names)) took \(name)'s spot at \(Self.text(spot)) meanwhile, so \(name) stays where iOS put it")
				return
			}
			let layout: HomeScreenLayout
			if let spot = entry.spot {
				layout = try screen.layout.placing(bundleID, at: spot)
			} else {
				layout = screen.layout.removing(bundleID)
			}
			let target = layout.spot(of: bundleID)
			let appLibrary = layout.appLibrary(installed: screen.apps)
			let gaps = YourGaps.gaps(installed: screen.apps)
			say("writing \(name) back to \(Self.text(target)), with \(appLibrary.count) in the App Library\(Self.others(gaps.held.count))\(YourGaps.kept(layout, gaps))")
			let after = try await installer.writeHomeScreen(layout, appLibrary: appLibrary, gaps: gaps)
			YourGaps.written(layout, gaps: gaps, names: screen.names, say: say)
			if after.differences(from: layout, names: screen.names).isEmpty {
				say("read back: \(name) at \(Self.text(after.spot(of: bundleID))), as written")
			} else {
				Self.readBack(after, written: layout, names: screen.names, say: say)
			}
		} catch let problem as HomeScreenLayout.PlacingProblem {
			say("couldn't put \(name) back at \(Self.text(entry.spot)): \(problem), so it stays where iOS put it")
		} catch {
			say("couldn't put \(name) back: \(Self.why(error))")
		}
	}

	// MARK: The spots noted

	/// The most differences a write's read-back logs.
	static let differencesShown = 10

	/// What's noted for the app that had `bundleID`, if anything.
	nonisolated static func noted(_ bundleID: String) -> Noted? {
		all()[bundleID]
	}

	/// The spots Offload keeps empty for apps still away, by bundle ID:
	/// none of `installed` has it. Every write sends them, or their gaps
	/// would close.
	static func heldGaps(installed: [HomeScreenApp]) -> [String: HomeScreenSpot] {
		let back = Set(installed.map(\.bundleID))
		return all()
			.filter { bundleID, entry in entry.holdsGap == true && !back.contains(bundleID) }
			.compactMapValues(\.spot)
	}

	/// What's noted for each app Atelier deleted that isn't back yet, by
	/// bundle ID: none of `installed` has it. For the Offload Markers
	/// Test's stand-ins, which also go in a spot that isn't kept empty,
	/// when nothing came into it.
	static func away(installed: [HomeScreenApp]) -> [String: Noted] {
		let back = Set(installed.map(\.bundleID))
		return all().filter { !back.contains($0.key) }
	}

	/// Stops keeping the spot of `bundleID` empty, as something came into
	/// it, and returns its app's name. The spot stays noted, for Reinstall
	/// to find it taken.
	@discardableResult
	static func release(_ bundleID: String) -> String? {
		guard var entry = noted(bundleID) else { return nil }
		entry.holdsGap = false
		save(entry, for: bundleID)
		return entry.name
	}

	/// Keeps the spot of `bundleID` empty again in writes, once the Offload
	/// Markers Test's marker that held it is put away.
	static func hold(again bundleID: String) {
		guard var entry = noted(bundleID), entry.spot != nil else { return }
		entry.holdsGap = true
		save(entry, for: bundleID)
	}

	/// Forgets what's noted for `bundleID` and returns it.
	@discardableResult
	static func take(_ bundleID: String) -> Noted? {
		var noted = all()
		guard let entry = noted.removeValue(forKey: bundleID) else { return nil }
		store(noted)
		return entry
	}

	private static func save(_ entry: Noted, for bundleID: String) {
		var noted = all()
		noted[bundleID] = entry
		store(noted)
	}

	private nonisolated static func all() -> [String: Noted] {
		guard let data = UserDefaults.standard.data(forKey: notedKey) else { return [:] }
		return (try? JSONDecoder().decode([String: Noted].self, from: data)) ?? [:]
	}

	private static func store(_ noted: [String: Noted]) {
		UserDefaults.standard.set(try? JSONEncoder().encode(noted), forKey: notedKey)
	}

	// MARK: In words

	/// "Page 2, 7th", "In Tools (Page 1, 5th), 2nd", or "the App Library
	/// only".
	static func text(_ spot: HomeScreenSpot?) -> String {
		spot?.detail ?? "the App Library only"
	}

	/// "its spot on page 9 of your Home Screen", "its place in Utilities",
	/// "its place in the Dock": what an offloaded app's page says is kept.
	nonisolated static func kept(_ spot: HomeScreenSpot) -> String {
		if let folder = spot.folder { return "its place in \(folder.name)" }
		guard let page = spot.page else { return "its place in the Dock" }
		return "its spot on page \(page + 1) of your Home Screen"
	}

	/// ", and 2 other spots kept empty", or nothing for none.
	static func others(_ count: Int) -> String {
		switch count {
		case 0: ""
		case 1: ", and 1 other spot kept empty"
		default: ", and \(count) other spots kept empty"
		}
	}

	/// Logs how the layout read back after a write compares with the one
	/// written. The gaps don't show, as iOS doesn't report them.
	static func readBack(_ after: HomeScreenLayout, written: HomeScreenLayout, names: [String: String], say: @MainActor (String) -> Void) {
		let differences = after.differences(from: written, names: names)
		guard !differences.isEmpty else {
			say("read back: as written")
			return
		}
		say("read back: \(differences.count) not as written")
		for line in differences.prefix(differencesShown) { say("  \(line)") }
		if differences.count > differencesShown { say("  and \(differences.count - differencesShown) more") }
	}

	/// "at 23:15", or "on 3 Nov" before today.
	static func when(_ date: Date) -> String {
		Calendar.current.isDateInToday(date)
			? "at \(date.formatted(date: .omitted, time: .shortened))"
			: "on \(date.formatted(.dateTime.day().month(.abbreviated)))"
	}

	/// What iOS or idevice said, for the log.
	static func why(_ error: any Error) -> String {
		if let failure = error as? InstallFailure { return failure.technical ?? failure.description }
		if let problem = error as? InstallProblem { return problem.message }
		return String(describing: error)
	}

	/// Logs `line` to the install's log, which its details show.
	private static func say(_ events: @escaping @MainActor (InstallEvent) -> Void) -> @MainActor (String) -> Void {
		{ line in events(.log("home screen: \(line)")) }
	}

	/// Forgets what the test build kept (9 Nov 2026): Home Screen
	/// Test's switch, log and layouts, and build 591's answer to the
	/// question, asked again in new words. The gaps marked there stay.
	static func forgetTestBuild() {
		UserDefaults.standard.removeObject(forKey: "testHomeScreenSpots")
		UserDefaults.standard.removeObject(forKey: "homeScreenGapsAnswered")
		let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appending(path: "HomeScreenTest", directoryHint: .isDirectory)
		try? FileManager.default.removeItem(at: folder)
	}
}
