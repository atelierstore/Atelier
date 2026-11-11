import AtelierCore
import DownloadKit
import InstallKit
import SwiftData
import SwiftUI
import UIKit

/// Shows Custom Install's sheet (#155), wherever it starts, and before an IPA
/// of an installed app installs over it, asks whether to install it over
/// the app or as a copy next to it (#113), in an alert. Also asks for the
/// IPA of an app installed from one, when Custom Install… or Re-sign can't use
/// the one it came from. All from UIKit, shown on top of whatever is
/// showing once nothing is opening or closing: Custom Install… starts from
/// menus, sheets and other alerts, and a SwiftUI alert that came while one
/// of those closed was lost (#93). One at a time, IPAs' questions first.
/// Takes the models rather than the environment, as it sits on the tab
/// view that provides them.
struct CopyPrompts: ViewModifier {
	let installer: InstallModel
	let catalog: CatalogModel
	let certificates: CertificatesModel
	let downloads: DownloadManager
	@Environment(\.modelContext) private var context
	/// The question or sheet showing, by its ID.
	@State private var showing: String?

	/// The next question or sheet, by its ID.
	private var next: String? {
		installer.ipaQuestions.first?.id
			?? installer.ipaRequests.first?.id.uuidString
			?? installer.copyRequests.first?.id.uuidString
	}

	func body(content: Content) -> some View {
		content
			.onChange(of: next, initial: true) { askNext() }
			// Also once one is answered: a question that came while a
			// sheet showed is first already.
			.onChange(of: showing) { askNext() }
	}

	private func askNext() {
		guard showing == nil else { return }
		let controller: UIViewController
		let drop: () -> Void
		if let question = installer.ipaQuestions.first {
			showing = question.id
			controller = alert(for: question)
			drop = { installer.dismiss(question) }
		} else if let request = installer.ipaRequests.first {
			showing = request.id.uuidString
			controller = alert(for: request)
			drop = { installer.dismiss(request) }
		} else if let request = installer.copyRequests.first {
			showing = request.id.uuidString
			controller = sheet(for: request, context: context)
			drop = { installer.cancelCopy(request) }
		} else {
			return
		}
		Task {
			guard let top = await DocumentPicker.settledTop() else {
				// Atelier left the screen: it's dropped rather than hold up the rest.
				showing = nil
				drop()
				return
			}
			top.present(controller, animated: true)
		}
	}

	/// "Provenance is already installed": over it, keeping its data, or as
	/// a copy next to it.
	private func alert(for question: InstallModel.IPAQuestion) -> UIAlertController {
		let name = question.installed.name
		let installed = LibraryItem.displayVersion(of: question.installed)
		let ipa = InstallModel.displayVersion(of: question.info)
		let versions = ipa == installed
			? "The IPA has \(question.info.name) \(ipa), the version installed."
			: "The IPA has \(question.info.name) \(ipa), and \(installed) is installed."
		let alert = UIAlertController(
			title: "\(name) is already installed",
			message: "\(versions) Install it over \(name), keeping its data, or as a copy next to it.",
			preferredStyle: .alert
		)
		alert.addAction(UIAlertAction(title: "Install over \(name)", style: .default) { _ in
			showing = nil
			installer.installOver(question)
		})
		alert.addAction(UIAlertAction(title: "Install a Copy…", style: .default) { _ in
			showing = nil
			installer.askForCopy(question)
		})
		alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
			showing = nil
			installer.dismiss(question)
		})
		return alert
	}

	/// Asks for the IPA of an app installed from one (#113): Atelier doesn't
	/// know where it is, its link doesn't work anymore, or it isn't the
	/// app's. Or it's another version than the one installed, which installs
	/// once the user says so.
	private func alert(for request: InstallModel.IPARequest) -> UIAlertController {
		let install = request.install
		let app = appName(of: install)
		let purpose = switch request.action {
		case .newCopy: "to install a copy"
		case .signAgain: "to sign \(install.name) again"
		case .resign: "to re-sign \(install.name)"
		}
		let choose = "Choose an IPA of \(app) \(purpose)."
		var installOther: String?
		let title: String
		let message: String
		switch request.reason {
		case .unknown:
			title = "Atelier doesn't know where \(install.name)'s IPA is"
			message = choose
		case .linkFailed(let site, let why):
			title = "The link at \(site) doesn't work anymore"
			message = "\(Self.sentence(why)) \(choose)"
		case .otherApp(let place, let name):
			title = "\(Self.capitalized(place)) is \(name), not \(app)"
			message = choose
		case .unreadable(let place):
			title = "Atelier can't read \(place)"
			message = choose
		case .otherVersion(let place, let version, let installed):
			title = "\(Self.capitalized(place)) has \(app) \(version)"
			message = "\(install.name) \(installed) is installed. Install \(version) instead, or choose an IPA of \(installed)."
			installOther = version
		}
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		if let version = installOther {
			alert.addAction(UIAlertAction(title: "Install \(version)", style: .default) { _ in
				showing = nil
				installer.installOtherVersion(request)
			})
		}
		alert.addAction(UIAlertAction(title: "Choose IPA File…", style: .default) { _ in
			// What's asked next waits until Files closes.
			Task {
				_ = await DocumentPicker.settledTop()
				IPAPicker.present(onCancel: {
					showing = nil
					installer.dismiss(request)
				}) { url in
					installer.use(picked: url, for: request, certificates: certificates, into: context)
					showing = nil
				}
			}
		})
		alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
			showing = nil
			installer.dismiss(request)
		})
		return alert
	}

	/// The app an installed app's IPA is of: for a copy, the app it copies,
	/// by its name in the Library while it's there.
	private func appName(of install: InstallRecord) -> String {
		InstallModel.ipaAppName(of: install, in: context)
	}

	/// "That IPA" for "that IPA", at the start of a title. A file's name
	/// stays as it is.
	private static func capitalized(_ place: String) -> String {
		guard place.hasPrefix("the ") || place.hasPrefix("that ") else { return place }
		return place.prefix(1).uppercased() + place.dropFirst()
	}

	/// `text` ending with a full stop, as a download's failure may not.
	private static func sentence(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
		return trimmed + "."
	}

	/// Custom Install's sheet (`CopySheet`).
	private func sheet(for request: InstallModel.CopyRequest, context: ModelContext) -> UIViewController {
		// The bundle IDs in the Library, which a new copy's can't be.
		let taken = Set(((try? context.fetch(FetchDescriptor<InstallRecord>())) ?? []).map { $0.bundleID.lowercased() })
		let presented = PresentedSheet()
		let copySheet = CopySheet(
			request: request,
			certificates: certificates,
			needsReinstall: { install, id in installer.needsReinstall(install, signingWith: id, certificates: certificates) },
			canInstallAsCopy: { installer.canInstallAsCopy($0, from: request, in: catalog.catalog) },
			isTaken: { taken.contains($0.lowercased()) }
		) {
			presented.controller?.dismiss(animated: true)
			showing = nil
			installer.cancelCopy(request)
		} install: { answer in
			presented.controller?.dismiss(animated: true)
			showing = nil
			installer.customInstall(request, answer, in: catalog.catalog, downloads: downloads, certificates: certificates, into: context)
		}
		let controller = CopySheetController(rootView: copySheet)
		// Swiped down, it's cancelled, as with Cancel.
		controller.onSwipeDown = {
			showing = nil
			installer.cancelCopy(request)
		}
		presented.controller = controller
		return controller
	}
}

/// The sheet, for its buttons to close it once it's made.
private final class PresentedSheet {
	weak var controller: UIViewController?
}

/// Custom Install's sheet as UIKit presents it: swiping it down closes it and
/// tells `onSwipeDown`, which its buttons don't.
private final class CopySheetController: UIHostingController<CopySheet>, UIAdaptivePresentationControllerDelegate {
	var onSwipeDown: () -> Void = {}

	override init(rootView: CopySheet) {
		super.init(rootView: rootView)
		modalPresentationStyle = .formSheet
		presentationController?.delegate = self
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
		onSwipeDown()
	}
}
