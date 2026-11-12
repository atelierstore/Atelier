import SwiftUI

/// Said in place of an app's subtitle or status wherever what Atelier shows
/// of it comes from a source that needs a GitHub sign-in (#134): the source
/// is in a GitHub repo only an account can read, and there's none, so what
/// shows is what it listed last.
struct NotSignedInToGitHubLabel: View {
	var body: some View {
		Label("Not signed in to GitHub", systemImage: "exclamationmark.triangle.fill")
			// Right before the words, also in a list row.
			.labelStyle(InlineLabelStyle())
			.font(.caption.weight(.medium))
			.foregroundStyle(.orange)
			.lineLimit(1)
	}
}

/// An app's page and its Version History while the app's source needs a
/// GitHub sign-in (#134): what may be out of date, and the button to sign
/// in, in orange as Atelier's other warnings. The caller puts it on an
/// orange card, its button's own height under it.
struct GitHubSignInNotice: View {
	enum Page {
		/// The app's page.
		case app
		/// Its Version History.
		case versions
	}

	let sourceName: String
	let page: Page

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
				Text("Not signed in to GitHub")
			}
			.font(.subheadline.weight(.semibold))
			Text(message)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			GitHubSignInButton()
				.font(.subheadline.weight(.semibold))
				.buttonStyle(.borderless)
				.frame(minHeight: 44)
		}
	}

	/// GitHub says no more about a source without an account than that it
	/// can't find it. Atelier's own is in a public repo, so it never asks.
	private var message: String {
		let outOfDate = switch page {
		case .app: "this page may be out of date"
		case .versions: "newer versions may be missing"
		}
		return "GitHub can't find \(sourceName) without an account, so \(outOfDate). If it's in a private repo, sign in."
	}
}
