import InstallKit
import SourceKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Atelier in other apps' share sheets, for links (#56). It has no screen of
/// its own: it opens Atelier with the link Atelier reads for it
/// (`SharedLink`) and closes. Files shared to Atelier don't come here; iOS
/// hands those to the app itself.
///
/// Share extensions have no supported way to open their app:
/// `NSExtensionContext.open(_:completionHandler:)` only works for widgets.
/// So it calls `open(_:options:completionHandler:)` on the UIApplication up
/// its responder chain, as other apps' share extensions do, which needs
/// `APPLICATION_EXTENSION_API_ONLY` off (project.yml). When iOS refuses, it
/// says so, with the link to copy (`OpenFailedView`).
final class ShareViewController: UIViewController {
	private var link: URL?
	/// Whether the shared link has been read, if there was one.
	private var loaded = false
	private var appeared = false
	private var opening = false

	override func viewDidLoad() {
		super.viewDidLoad()
		// Nothing shows while Atelier opens.
		view.backgroundColor = .clear
		Task {
			link = await sharedLink()
			loaded = true
			openIfReady()
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// The responder chain only reaches the application once the view is
		// in a window.
		appeared = true
		openIfReady()
	}

	private func openIfReady() {
		guard appeared, loaded, !opening else { return }
		opening = true
		guard let link else {
			extensionContext?.completeRequest(returningItems: nil)
			return
		}
		guard let atelierLink = SharedLink.link(for: link, scheme: Self.ownScheme), let application else {
			showOpenFailed(link)
			return
		}
		application.open(atelierLink, options: [:]) { [weak self] opened in
			guard let self else { return }
			if opened {
				extensionContext?.completeRequest(returningItems: nil)
			} else {
				showOpenFailed(link)
			}
		}
	}

	/// The web link the share sheet was given.
	private func sharedLink() async -> URL? {
		let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
		guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
			return nil
		}
		return await withCheckedContinuation { continuation in
			_ = provider.loadObject(ofClass: URL.self) { url, _ in
				continuation.resume(returning: url)
			}
		}
	}

	/// The application up the responder chain, which opens links.
	private var application: UIApplication? {
		var responder: UIResponder? = self
		while let current = responder {
			if let application = current as? UIApplication { return application }
			responder = current.next
		}
		return nil
	}

	/// The scheme only this Atelier answers (`SwitchBackScheme`), so a copy
	/// of Atelier's extension opens that copy, not whichever Atelier iOS
	/// picks for `atelier://`. The app is two folders up, from PlugIns.
	private static var ownScheme: String {
		let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
		return Bundle(url: app)?.infoDictionary.flatMap(SwitchBackScheme.scheme(in:)) ?? "atelier"
	}

	private func showOpenFailed(_ link: URL) {
		let sheet = UIHostingController(rootView: OpenFailedView(link: link) { [weak self] in
			self?.extensionContext?.completeRequest(returningItems: nil)
		})
		sheet.presentationController?.delegate = self
		if let controller = sheet.sheetPresentationController {
			controller.detents = [.medium(), .large()]
			controller.prefersGrabberVisible = true
		}
		present(sheet, animated: true)
	}
}

extension ShareViewController: UIAdaptivePresentationControllerDelegate {
	/// Swiped away: the share sheet is done too.
	func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
		extensionContext?.completeRequest(returningItems: nil)
	}
}

/// When iOS won't let the extension open Atelier: what happened, and the
/// link to copy into Library › + › Download from URL.
private struct OpenFailedView: View {
	let link: URL
	let done: () -> Void
	@State private var copied = false

	var body: some View {
		ScrollView {
			VStack(spacing: 0) {
				if let icon = Self.appIcon {
					Image(uiImage: icon)
						.resizable()
						.frame(width: 60, height: 60)
						.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
						.accessibilityHidden(true)
				}
				Text("Couldn't open Atelier")
					.font(.title3.bold())
					.multilineTextAlignment(.center)
					.padding(.top, 12)
				Text("iOS didn't let Atelier open from here. Copy the link, then in Atelier's Library, tap + › Download from URL.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.top, 8)
				Text(verbatim: Self.shown(link))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
					.padding(.top, 14)
					.accessibilityLabel(link.absoluteString)
				Button {
					UIPasteboard.general.url = link
					copied = true
					AccessibilityNotification.Announcement("Link copied").post()
				} label: {
					Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
						.bold()
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.large)
				.padding(.top, 18)
				Button(action: done) {
					// The whole width and 44pt tall take the tap, not just the word.
					Text("Done")
						.frame(maxWidth: .infinity, minHeight: 44)
						.contentShape(Rectangle())
				}
				.keyboardShortcut(.cancelAction)
				.padding(.top, 6)
			}
			.padding(.horizontal, 22)
			.padding(.top, 24)
			.padding(.bottom, 16)
		}
		.task(id: copied) {
			guard copied else { return }
			try? await Task.sleep(for: .seconds(2))
			copied = false
		}
	}

	/// The link without its scheme, as Safari shows addresses.
	private static func shown(_ link: URL) -> String {
		let text = link.absoluteString
		guard let range = text.range(of: "://") else { return text }
		return String(text[range.upperBound...])
	}

	/// Atelier's icon, from the app the extension is in.
	private static var appIcon: UIImage? {
		let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
		guard
			let bundle = Bundle(url: app),
			let icons = bundle.infoDictionary?["CFBundleIcons"] as? [String: Any],
			let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
			let name = (primary["CFBundleIconFiles"] as? [String])?.last
		else { return nil }
		return UIImage(named: name, in: bundle, compatibleWith: nil)
	}
}
