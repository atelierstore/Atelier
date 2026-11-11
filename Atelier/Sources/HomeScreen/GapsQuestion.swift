import AtelierCore
import InstallKit
import SwiftUI

/// The one question about gaps (9 Nov 2026): the first action that
/// deletes an app to install it again, while Atelier keeps apps' spots,
/// asks in its own alert whether to mark your gaps first, as putting the
/// app back closes the ones iOS doesn't report. Mark Spaces to Keep opens
/// Open Spaces as a sheet, whose button carries on with the action; going
/// ahead without answers it too. Until it's answered, an app deleted
/// without the question, such as by an update in the background, goes
/// where iOS puts it, so no gap closes without you knowing.
///
/// What you see calls gaps open spaces, Apple's word for them, and asks
/// you to mark the ones Atelier should keep (9 Nov 2026).
@MainActor
enum GapsQuestion {
	/// Whether it's been answered, or Open Spaces used. A new key with
	/// the new words, so it asks once more (9 Nov 2026): build 591's
	/// answer was to the old ones.
	static let answeredKey = "homeScreenSpacesAnswered"

	static var isAnswered: Bool {
		get { UserDefaults.standard.bool(forKey: answeredKey) }
		set { UserDefaults.standard.set(newValue, forKey: answeredKey) }
	}

	/// Whether an action that deletes an app asks now: Atelier keeps apps'
	/// spots, on an iPhone, as only an iPhone has Open Spaces, and it hasn't
	/// been answered.
	static var asks: Bool {
		HomeScreenSpots.isOn && ThisDevice.name == "iPhone" && !isAnswered
	}

	/// Whether Atelier may move icons for an app it deletes: keeping
	/// spots is on, and on an iPhone the question's been answered.
	static var allowsWrites: Bool {
		HomeScreenSpots.isOn && (isAnswered || ThisDevice.name != "iPhone")
	}

	/// What the alert adds, the first time, for `count` apps: Offload's
	/// keeps the spot empty meanwhile.
	static func message(count: Int = 1, offload: Bool = false) -> String {
		let keep = "rearranges your Home Screen, which fills in open spaces between apps. If you want Atelier to keep some of these spaces, you need to mark them explicitly."
		if offload { return "Keeping its spot \(keep)" }
		return count == 1 ? "Putting it back in its spot \(keep)" : "Putting them back in their spots \(keep)"
	}

	/// `text`, with the question after it when it asks. `last`, such as
	/// Install as a Copy's sentence, ends `text` when it doesn't, and comes
	/// after the question when it does, next to its button (9 Nov 2026).
	static func adding(to text: String, count: Int = 1, offload: Bool = false, last: String? = nil) -> String {
		guard asks else { return [text, last].compactMap { $0 }.joined(separator: " ") }
		return [text, message(count: count, offload: offload), last].compactMap { $0 }.joined(separator: "\n\n")
	}
}

/// An action Mark Spaces to Keep carries on with, from Open Spaces' sheet.
struct MarkGapsFirst: Identifiable {
	let id = UUID()
	/// Its button, top right: "Offload", "Delete and Re-sign".
	let title: String
	/// What it then does, under the page: "Offload then keeps 30sec’s spot
	/// empty, and your gaps too."
	let then: String
	let action: @MainActor () -> Void
	/// What closing the sheet does, as the alert's Cancel would.
	var cancel: (@MainActor () -> Void)?
}

extension GapsQuestion {
	/// An alert's buttons with the question: Mark Spaces to Keep when it asks,
	/// then the action's own, which answers it too. Buttons, not a view of
	/// its own, as an alert only takes buttons.
	@ViewBuilder
	static func buttons(_ title: String, role: ButtonRole? = nil, then: String, marking: Binding<MarkGapsFirst?>, cancel: (@MainActor () -> Void)? = nil, action: @escaping @MainActor () -> Void) -> some View {
		if asks {
			Button("Mark Spaces to Keep") {
				isAnswered = true
				marking.wrappedValue = MarkGapsFirst(title: title, then: then, action: action, cancel: cancel)
			}
		}
		Button(title, role: role) {
			isAnswered = true
			action()
		}
	}
}

extension View {
	/// Open Spaces as a sheet, for Mark Spaces to Keep: closing it cancels the
	/// action, and its button carries on.
	func yourGapsSheet(_ marking: Binding<MarkGapsFirst?>) -> some View {
		sheet(item: marking) { carryOn in
			NavigationStack {
				YourGapsView(carryOn: carryOn)
			}
		}
	}
}
