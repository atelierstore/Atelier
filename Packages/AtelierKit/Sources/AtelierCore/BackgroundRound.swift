import Foundation
import InstallKit

/// The installs that run one after another while Atelier may be in the
/// background (#72): what the system's progress bar says about them, its
/// progress, and the notification once they've all ended.
///
/// A round starts with the first install queued while none is running and
/// ends when the queue is empty. Every app counts the same in the progress,
/// whatever its size.
public struct BackgroundRound: Equatable, Sendable {
	public enum Outcome: Equatable, Sendable {
		case installed
		case failed(String)
		case cancelled
	}

	public struct Entry: Equatable, Sendable {
		public var id: String
		public var name: String
		/// An update of an app Atelier installed before.
		public var isUpdate: Bool
		/// An installed app signed again because its certificate died (#20).
		public var isResign = false
		/// The version it installs, when known.
		public var version: String?
		public var outcome: Outcome?
	}

	/// What the notification says once the round is over.
	public struct Summary: Equatable, Sendable {
		public var title: String
		public var body: String
	}

	/// In the order they were queued.
	public private(set) var entries: [Entry] = []
	/// The running install.
	public private(set) var currentID: String?
	/// Started by Atelier itself, from its background update run, rather
	/// than by the user.
	public var isAutomatic = false

	public init() {}

	public var isEmpty: Bool { entries.isEmpty }

	/// Queues an install. One already in the round, such as one tried again
	/// after it failed, starts over in its new place.
	public mutating func add(id: String, name: String, isUpdate: Bool, isResign: Bool = false, version: String? = nil) {
		entries.removeAll { $0.id == id && $0.id != currentID }
		entries.append(Entry(id: id, name: name, isUpdate: isUpdate, isResign: isResign, version: version))
	}

	/// Takes a waiting install out of the round.
	public mutating func remove(id: String) {
		entries.removeAll { $0.id == id && $0.outcome == nil && $0.id != currentID }
	}

	public mutating func start(id: String) {
		currentID = id
	}

	/// Takes the running install out of the round, as another takes its
	/// place: one the user's answer to what it asked turned it into (#99).
	public mutating func drop(id: String) {
		entries.removeAll { $0.id == id && $0.outcome == nil }
		if currentID == id { currentID = nil }
	}

	public mutating func end(id: String, _ outcome: Outcome) {
		guard let index = entries.lastIndex(where: { $0.id == id && $0.outcome == nil }) else { return }
		entries[index].outcome = outcome
		if currentID == id { currentID = nil }
	}

	private var current: Entry? {
		currentID.flatMap { id in entries.last { $0.id == id && $0.outcome == nil } }
	}

	private var ended: Int { entries.filter { $0.outcome != nil }.count }

	private var allUpdates: Bool { entries.allSatisfy(\.isUpdate) }

	private var allResigns: Bool { entries.allSatisfy(\.isResign) }

	/// Whether every install in the round has ended.
	public var isOver: Bool { !entries.isEmpty && entries.allSatisfy { $0.outcome != nil } }

	/// The bar's first line: "Updating Delta", "Updating 3 apps",
	/// "Re-signing 3 apps", "Installing 2 apps". Once every install has
	/// ended, how it went, as the notification will say.
	public var title: String {
		if let ending { return ending.title }
		let verb = allResigns ? "Re-signing" : allUpdates ? "Updating" : "Installing"
		if entries.count == 1 { return "\(verb) \(entries[0].name)" }
		return "\(verb) \(entries.count) apps"
	}

	/// The bar's second line: which app, what it's doing and, with several
	/// apps, which one of how many. `bytes` is what's done of the current
	/// step's file, when the step moves one and its size is known.
	///
	/// Between two installs it keeps how the last one ended, and once they
	/// all have, it says how the round went. It used to say "Starting" then,
	/// so the bar ended on "Starting" while the notification said the
	/// updates were done (#72).
	public func subtitle(stage: InstallStage?, bytes: (done: Int64, total: Int64)? = nil) -> String {
		if let ending { return ending.subtitle }
		if let current { return line(current, Self.describe(stage, bytes: bytes)) }
		guard let last = entries.last(where: { $0.outcome != nil }), let outcome = last.outcome else { return "Starting" }
		return line(last, Self.describe(outcome))
	}

	/// "Delta: signing (1 of 3)", with which one of how many only when
	/// there are several.
	private func line(_ entry: Entry, _ step: String) -> String {
		var line = "\(entry.name): \(step)"
		if entries.count > 1, let position = entries.firstIndex(of: entry) {
			line += " (\(position + 1) of \(entries.count))"
		}
		return line
	}

	private static func describe(_ outcome: Outcome) -> String {
		switch outcome {
		case .installed: "installed"
		case .failed: "failed"
		case .cancelled: "cancelled"
		}
	}

	private static func describe(_ stage: InstallStage?, bytes: (done: Int64, total: Int64)?) -> String {
		let amount = bytes.map { ", \(megabytes($0.done)) of \(megabytes($0.total)) MB" }
		switch stage {
		case nil, .checking?:
			return "checking"
		case .downloading(let fraction)?:
			return "downloading" + (amount ?? percent(fraction))
		case .signing?:
			return "signing"
		case .installing(_, .connecting)?:
			return "connecting"
		case .installing(_, .waitingForApproval)?, .installing(_, .alertClosed)?:
			return "waiting for you to approve it"
		case .installing(_, .downloading(let fraction))?:
			return "uploading" + (amount ?? percent(fraction))
		case .installing(_, .installing)?:
			return "installing"
		case .installing(_, .copyingData(let fraction))?:
			return "copying its data" + percent(fraction)
		case .installing(_, .restoringData(let fraction))?:
			return "putting its data back" + percent(fraction)
		case .finished?:
			return "installed"
		case .failed?:
			return "failed"
		case .cancelled?:
			return "cancelled"
		}
	}

	private static func percent(_ fraction: Double?) -> String {
		guard let fraction else { return "" }
		return ", \(Int((fraction * 100).rounded()))%"
	}

	/// Whole megabytes, as the bar has little room.
	private static func megabytes(_ bytes: Int64) -> Int {
		Int((Double(bytes) / 1_000_000).rounded())
	}

	/// The round's progress out of `unitsPerApp` for each app: the ended
	/// apps, and the running one's share from its stage.
	public func progress(stage: InstallStage?, unitsPerApp: Int64 = 1000) -> (completed: Int64, total: Int64) {
		let total = Int64(entries.count) * unitsPerApp
		var completed = Int64(ended) * unitsPerApp
		if current != nil, let stage {
			// Short of the end until it has ended.
			completed += Int64(Double(unitsPerApp) * min(stage.overallFraction, 0.99))
		}
		return (min(completed, total), total)
	}

	/// The notification once every install has ended; nil when there's
	/// nothing to say, such as when they were all cancelled.
	public var summary: Summary? {
		guard let result else { return nil }
		return Summary(title: result.title, body: [result.text, result.next].compactMap { $0 }.joined(separator: " "))
	}

	/// The notification once iOS has paused Atelier with installs left
	/// (#72): what's done, and what opening Atelier finishes. Nil once
	/// they've all ended.
	public var paused: Summary? {
		let left = entries.filter { $0.outcome == nil }
		guard !left.isEmpty else { return nil }
		let resigning = left.allSatisfy(\.isResign)
		let updating = left.allSatisfy(\.isUpdate)
		// An app that's also left, such as one queued again, is only named there.
		let installed = entries.filter { done in done.outcome == .installed && !left.contains { $0.name == done.name } }
		let failed = entries.filter { entry in
			if case .failed? = entry.outcome { return !left.contains { $0.name == entry.name } }
			return false
		}
		var body: [String] = []
		if !installed.isEmpty {
			let ready = installed.allSatisfy(\.isUpdate) ? "up to date" : "ready to open"
			body.append("\(Self.list(installed.map(\.name))) \(installed.count == 1 ? "is" : "are") \(ready).")
		}
		if !failed.isEmpty {
			body.append("\(Self.list(failed.map(\.name))) didn't \(failed.allSatisfy(\.isResign) ? "re-sign" : "install").")
		}
		let doing = resigning ? "re-signing" : updating ? "updating" : "installing"
		body.append("Open Atelier to finish \(doing) \(Self.list(left.map(\.name))).")
		let title = resigning ? "Re-signing paused" : updating ? "Updates paused" : "Installs paused"
		return Summary(title: title, body: body.joined(separator: " "))
	}

	/// The bar's two lines once every install has ended: the notification's
	/// title and what happened, without what to do next or a full stop, as
	/// the bar has one line for it (#72). Nil before then, and when there's
	/// nothing to say.
	public var ending: (title: String, subtitle: String)? {
		guard isOver, let result else { return nil }
		return (result.title, result.text.hasSuffix(".") ? String(result.text.dropLast()) : result.text)
	}

	/// How the round went: a title, what happened, and what to do about it.
	private var result: (title: String, text: String, next: String?)? {
		let installed = entries.filter { $0.outcome == .installed }
		let failed = entries.compactMap { entry -> (name: String, why: String)? in
			if case .failed(let why)? = entry.outcome { return (entry.name, why) }
			return nil
		}
		guard !installed.isEmpty || !failed.isEmpty else { return nil }
		let ended = entries.filter { $0.outcome != nil && $0.outcome != .cancelled }
		let resigns = ended.allSatisfy(\.isResign)
		let updates = ended.allSatisfy(\.isUpdate)
		let done = resigns ? "re-signed" : updates ? "updated" : "installed"
		let apps = { (count: Int) in count == 1 ? "1 app" : "\(count) apps" }

		if failed.isEmpty, isAutomatic {
			let names = installed.map { [$0.name, $0.version].compactMap { $0 }.joined(separator: " ") }
			return ("Updated in the background", "\(Self.list(names)) \(installed.count == 1 ? "was" : "were") installed.", nil)
		}
		if failed.isEmpty {
			let title = installed.count == 1 ? "\(installed[0].name) \(done)" : "\(apps(installed.count)) \(done)"
			let body = updates
				? "\(Self.list(installed.map(\.name))) \(installed.count == 1 ? "is" : "are") up to date."
				: "\(Self.list(installed.map(\.name))) \(installed.count == 1 ? "is" : "are") ready to open."
			return (title, body, nil)
		}
		let title: String
		if installed.isEmpty {
			title = failed.count == 1 ? "\(failed[0].name) wasn't \(done)" : "\(apps(failed.count)) weren't \(done)"
		} else {
			title = "\(apps(installed.count)) \(done), \(failed.count) didn't"
		}
		let text = failed.count == 1
			? "\(failed[0].name): \(Self.sentence(failed[0].why))"
			: "\(Self.list(failed.map(\.name))) didn't \(resigns ? "re-sign" : "install")."
		return (title, text, "Open Atelier to try again.")
	}

	/// "Delta", "Delta and YTLite", "Delta, EeveeSpotify and YTLite".
	static func list(_ names: [String]) -> String {
		switch names.count {
		case 0: ""
		case 1: names[0]
		default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
		}
	}

	/// A message as one sentence, without a trailing full stop doubled up.
	private static func sentence(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let last = trimmed.last else { return "" }
		return ".!?".contains(last) ? trimmed : trimmed + "."
	}
}
