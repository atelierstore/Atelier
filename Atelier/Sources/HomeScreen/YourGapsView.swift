import AtelierCore
import InstallKit
import SwiftData
import SwiftUI

/// Settings › Home Screen › Open Spaces (7 Nov 2026), or a sheet from
/// the gaps question's Mark Spaces to Keep (9 Nov 2026): each page as
/// the last read found it, with its apps packed together as iOS reports
/// them. Tap an app to put a gap before it, so the page looks as it does
/// on the iPhone, and every write keeps it. On a page that might have open
/// spaces, Find Open Spaces Automatically marks those a screenshot of it
/// shows (11 Nov 2026). Swipe from page to page, as on the Home Screen
/// (12 Nov 2026).
struct YourGapsView: View {
	/// As a sheet: the action its button, top right, carries on with.
	var carryOn: MarkGapsFirst?
	@State private var model = YourGapsModel()
	/// Whether Find Open Spaces Automatically is asking first.
	@State private var asking = false
	@Query private var installs: [InstallRecord]
	@Environment(\.modelContext) private var context
	@Environment(\.dismiss) private var dismiss

	/// A grid row's height: the icon and its name.
	private static let rowHeight: CGFloat = 80
	private static let iconSize: CGFloat = 56

	var body: some View {
		ScrollView {
			VStack(spacing: 12) {
				switch model.state {
				case .reading:
					ProgressView("Reading the Home Screen…")
						.padding(.top, 120)
				case .failed(let why):
					VStack(spacing: 14) {
						Text("Couldn’t read the Home Screen")
							.font(.headline)
						Text(why)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
						Button("Try Again") {
							Task { await model.load() }
						}
						.buttonStyle(.borderedProminent)
					}
					.padding(.top, 100)
				case .ready:
					pager
					pageGrids
					dots
					findButton
					hint
				}
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 24)
		}
		.background(Color(.systemGroupedBackground))
		.navigationTitle("Open Spaces")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			if let carryOn {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel", systemImage: "xmark") {
						dismiss()
						carryOn.cancel?()
					}
				}
				ToolbarItem(placement: .confirmationAction) {
					Button(carryOn.title) {
						dismiss()
						carryOn.action()
					}
					.fontWeight(.semibold)
				}
			}
		}
		.task { await model.load() }
		.fullScreenCover(isPresented: $asking) {
			FindOpenSpacesAlert(page: model.page + 1) { finding in
				ask(false)
				if finding {
					Task { await model.findOpenSpaces() }
				}
			}
			.presentationBackground(.clear)
		}
	}

	/// Shows or hides Find Open Spaces Automatically's alert at once, as it
	/// fades itself in and out rather than sliding up.
	private func ask(_ showing: Bool) {
		var transaction = Transaction()
		transaction.disablesAnimations = true
		withTransaction(transaction) { asking = showing }
	}

	// MARK: Parts

	private var pager: some View {
		HStack {
			pageButton("chevron.left", label: "Previous Page", to: model.page - 1)
			Spacer()
			VStack(spacing: 1) {
				Text("Page \(model.page + 1)")
					.font(.headline)
				Text("of \(model.pages.count) · \(pageNote)")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Spacer()
			pageButton("chevron.right", label: "Next Page", to: model.page + 1)
		}
		.padding(.top, 4)
	}

	/// "2 open spaces", "widgets", "full", or "might have open spaces"
	/// until any are marked.
	private var pageNote: String {
		guard model.canMark else { return "widgets" }
		switch model.gapCount {
		case 0:
			if model.isFull { return "full" }
			if case .found = model.finding { return "no open spaces" }
			return "might have open spaces"
		case 1: return "1 open space"
		default: return "\(model.gapCount) open spaces"
		}
	}

	private func pageButton(_ symbol: String, label: String, to page: Int) -> some View {
		Button {
			withAnimation { model.page = page }
		} label: {
			Image(systemName: symbol)
				.font(.body.weight(.semibold))
				.frame(width: 40, height: 40)
				.background(Circle().fill(Color(.secondarySystemGroupedBackground)))
		}
		.disabled(!model.pages.indices.contains(page))
		.accessibilityLabel(label)
	}

	/// The pages side by side, to swipe through as on the Home Screen: edge
	/// to edge, so a page slides off the screen rather than into the margin.
	private var pageGrids: some View {
		ScrollViewReader { proxy in
			ScrollView(.horizontal) {
				HStack(alignment: .top, spacing: 0) {
					ForEach(model.pages.indices, id: \.self) { page in
						grid(page)
							.padding(.horizontal, 16)
							.containerRelativeFrame(.horizontal)
					}
				}
				.scrollTargetLayout()
			}
			.scrollTargetBehavior(.paging)
			.scrollPosition(id: Binding<Int?>($model.page), anchor: .center)
			.scrollIndicators(.hidden)
			// Starts on the page shown, which isn't the first when it comes
			// back from another tab and reads the Home Screen again.
			.onAppear { proxy.scrollTo(model.page) }
		}
		.padding(.horizontal, -16)
	}

	private func grid(_ page: Int) -> some View {
		let slots = model.slots(of: page)
		let layout = YourGapsModel.cells(slots)
		let canMark = model.canMark(page: page)
		return GeometryReader { geometry in
			let width = geometry.size.width / 4
			ZStack(alignment: .topLeading) {
				ForEach(layout.cells) { cell in
					place(slots[cell.index], at: cell.index, on: page)
						.frame(width: width * CGFloat(cell.columns), height: Self.rowHeight * CGFloat(cell.rows))
						.position(
							x: width * (CGFloat(cell.column) + CGFloat(cell.columns) / 2),
							y: Self.rowHeight * (CGFloat(cell.row) + CGFloat(cell.rows) / 2)
						)
				}
			}
		}
		.frame(height: Self.rowHeight * CGFloat(max(layout.rows, HomeScreenLayout.pageRows)))
		.padding(.vertical, 16)
		.padding(.horizontal, 8)
		.background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
		.opacity(canMark ? 1 : 0.45)
		.saturation(canMark ? 1 : 0.6)
	}

	@ViewBuilder
	private func place(_ slot: HomeScreenSlot, at index: Int, on page: Int) -> some View {
		switch slot {
		case .item(.widget):
			RoundedRectangle(cornerRadius: 20, style: .continuous)
				.fill(Color(.tertiarySystemFill))
				.overlay {
					Text(model.name(slot))
						.font(.footnote.weight(.medium))
						.foregroundStyle(.secondary)
				}
				.padding(6)
				.accessibilityLabel("\(model.name(slot)) widget")
		default:
			Button {
				model.tap(index, on: page)
			} label: {
				VStack(spacing: 5) {
					icon(slot)
						.frame(width: Self.iconSize, height: Self.iconSize)
					Text(label(slot))
						.font(.caption2)
						.foregroundStyle(nameStyle(slot))
						.lineLimit(1)
						.frame(maxWidth: 80)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
				.padding(.top, 2)
			}
			.buttonStyle(.plain)
			.disabled(!model.canMark(page: page))
			.accessibilityHint(slot == .gap ? "Takes the open space out" : "Puts an open space before it")
		}
	}

	private func nameStyle(_ slot: HomeScreenSlot) -> AnyShapeStyle {
		switch slot {
		case .gap: AnyShapeStyle(Color.accentColor)
		case .held: AnyShapeStyle(HierarchicalShapeStyle.secondary)
		default: AnyShapeStyle(HierarchicalShapeStyle.primary)
		}
	}

	@ViewBuilder
	private func icon(_ slot: HomeScreenSlot) -> some View {
		let shape = RoundedRectangle(cornerRadius: Self.iconSize * 0.225, style: .continuous)
		switch slot {
		case .item(.icon(let id, _)):
			appIcon(id, size: Self.iconSize)
		case .item(.folder(_, let folderPages, _)):
			let ids = (folderPages.first ?? []).prefix(9).compactMap(\.id)
			shape
				.fill(Color(.systemFill))
				.overlay {
					LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 3), count: 3), spacing: 3) {
						ForEach(ids, id: \.self) { id in
							appIcon(id, size: 12)
						}
					}
				}
		case .item(.widget), .item(.other):
			shape.fill(Color(.tertiarySystemFill))
		case .held(let id):
			DisabledAppIcon(url: heldIcon(id), tint: nil, size: Self.iconSize)
		case .gap:
			shape
				.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
				.background(shape.fill(Color.accentColor.opacity(0.07)))
		}
	}

	@ViewBuilder
	private func appIcon(_ id: String, size: CGFloat) -> some View {
		let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
		if let image = model.icons[id] {
			Image(uiImage: image)
				.resizable()
				.scaledToFill()
				.frame(width: size, height: size)
				.clipShape(shape)
		} else {
			shape
				.fill(Color(.tertiarySystemFill))
				.frame(width: size, height: size)
		}
	}

	/// The name under a place: an offloaded app's as the Library has it,
	/// as installd no longer lists it.
	private func label(_ slot: HomeScreenSlot) -> String {
		if case .held(let id) = slot, let install = installs.first(where: { $0.bundleID == id }) {
			return install.name
		}
		return model.name(slot)
	}

	/// An offloaded app's icon, as the Library has it: SpringBoard has none
	/// once it's deleted.
	private func heldIcon(_ id: String) -> URL? {
		if let url = InstalledIcons.shared.url(for: id) { return url }
		guard let install = installs.first(where: { $0.bundleID == id }) else { return nil }
		return InstalledApps.iconURL(of: install, in: context)
	}

	private var dots: some View {
		HStack(spacing: 7) {
			ForEach(model.pages.indices, id: \.self) { page in
				Circle()
					.fill(page == model.page ? Color.primary : Color(.systemGray3))
					.frame(width: 7, height: 7)
			}
		}
		.accessibilityHidden(true)
	}

	/// Find Open Spaces Automatically, on a page that might have open
	/// spaces: Find Again once it has looked, Try Again when it couldn't.
	@ViewBuilder
	private var findButton: some View {
		if model.mightHaveOpenSpaces {
			Button {
				ask(true)
			} label: {
				HStack(spacing: 7) {
					if model.finding == .looking {
						ProgressView()
					} else {
						FindSpacesGlyph()
					}
					Text(findTitle)
				}
				.font(.body.weight(.semibold))
				.frame(maxWidth: .infinity, minHeight: 32)
			}
			.buttonStyle(.bordered)
			.buttonBorderShape(.capsule)
			.controlSize(.large)
			.disabled(model.isFinding)
			.padding(.horizontal, 8)
		}
	}

	private var findTitle: String {
		switch model.finding {
		case .found: "Find Again"
		case .failed: "Try Again"
		case .looking, nil: "Find Open Spaces Automatically"
		}
	}

	@ViewBuilder
	private var hint: some View {
		Group {
			if let notice = model.notice {
				Text(notice)
					.foregroundStyle(.orange)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else if !model.canMark {
				Text("**Page \(model.page + 1) has widgets, so it keeps no open spaces.** iOS fits icons around widgets its own way. Its apps still go back to their spots.")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else if model.isFull {
				Text(verbatim: "This page is full, so it has no open spaces.\(heldNote)\(thenNote)")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: .infinity)
			} else {
				switch model.finding {
				case .found(let count, let date, let doubtful, let cameBack):
					found(count, at: date, doubtful: doubtful, cameBack: cameBack)
						.multilineTextAlignment(.center)
						.frame(maxWidth: .infinity)
				case .failed(let message):
					Label {
						Text(verbatim: "\(message)\(thenNote)")
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				case .looking, nil:
					Text(verbatim: "Atelier shows this page on your Home Screen for a moment and marks the open spaces it sees. \(markHint)")
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.frame(maxWidth: .infinity)
				}
			}
		}
		.font(.footnote)
		.padding(.horizontal, 16)
	}

	/// What Find Open Spaces Automatically marked, for you to check.
	private func found(_ count: Int, at date: Date, doubtful: Bool, cameBack: Bool) -> Text {
		let found = switch count {
		case 0: "Found no open spaces \(HomeScreenSpots.when(date))."
		case 1: "Found 1 open space \(HomeScreenSpots.when(date))."
		default: "Found \(count) open spaces \(HomeScreenSpots.when(date))."
		}
		var check = count == 0
			? "Check the page, and tap an app to put an open space before it if it missed one."
			: "Check them, and tap to fix any it got wrong."
		if doubtful { check = "Check this page: some places were hard to tell from apps. Tap to fix any it got wrong." }
		let back = cameBack ? "" : " Atelier didn’t come back by itself."
		let rest = " \(check)\(back)\(thenNote)"
		let headline = Text(found).fontWeight(.semibold).foregroundStyle(.tint)
		return Text("\(headline)\(rest)")
	}

	/// How to mark, and which offloaded apps' spots are kept on the page.
	private var markHint: String {
		"Tap an app to put an open space before it, as on your iPhone, and again for two. Tap an open space to take it out.\(heldNote)\(thenNote)"
	}

	/// Which offloaded apps' spots are kept on the page, after a space.
	private var heldNote: String {
		let held = model.slots.compactMap { slot -> String? in
			guard case .held = slot else { return nil }
			return label(slot)
		}
		switch held.count {
		case 0: return ""
		case 1: return " \(held[0]) is offloaded: its spot stays empty until Reinstall."
		default: return " \(held.formatted(.list(type: .and))) are offloaded: their spots stay empty until Reinstall."
		}
	}

	/// As a sheet: what its button then does, after a space.
	private var thenNote: String {
		carryOn.map { " \($0.then)" } ?? ""
	}
}

/// Find Open Spaces Automatically's alert (12 Nov 2026), in the style of
/// iOS's own, which draws its text in grey: it says in red that iOS might
/// show a notification afterwards, shows it, and says that's normal. It
/// dims the whole screen, as iOS's alerts do, and fades in and out like
/// them.
private struct FindOpenSpacesAlert: View {
	/// The page, counted from 1.
	let page: Int
	/// Once it has faded out: whether to find them.
	let close: (Bool) -> Void
	@State private var isShown = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		ZStack {
			Color.black
				.opacity(isShown ? 0.3 : 0)
				.ignoresSafeArea()
				.accessibilityHidden(true)
			// With the largest text, it scrolls rather than leave the screen.
			ViewThatFits(in: .vertical) {
				card
				ScrollView {
					card.padding(.vertical, 24)
				}
				.scrollBounceBehavior(.basedOnSize)
			}
			.scaleEffect(isShown || reduceMotion ? 1 : 1.1)
			.opacity(isShown ? 1 : 0)
		}
		.onAppear {
			withAnimation(.spring(duration: 0.3, bounce: 0.2)) { isShown = true }
		}
	}

	private var card: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Find open spaces on page \(page)?")
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
			// The words come first, so the picture doesn't pass for iOS's own
			// notification.
			Text("Afterwards, iOS might show this:")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.red)
				.padding(.top, 8)
			DeviceHubNotification()
				.padding(.top, 10)
			Text("That’s normal: it’s because Atelier will take a screenshot of the page to locate the open spaces. Keep it paired.")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.red)
				.padding(.top, 10)
			Text("Don’t touch your iPhone until Atelier is back, in a few seconds.")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.padding(.top, 14)
			VStack(spacing: 8) {
				Button {
					leave(finding: true)
				} label: {
					Text("Find Open Spaces")
						.fontWeight(.semibold)
						.foregroundStyle(Color.accentColor)
				}
				.keyboardShortcut(.defaultAction)
				Button(role: .cancel) {
					leave(finding: false)
				} label: {
					Text("Cancel")
						.foregroundStyle(.primary)
				}
				.keyboardShortcut(.cancelAction)
			}
			.buttonStyle(AlertButtonStyle())
			.padding(.top, 18)
		}
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
		.shadow(color: .black.opacity(0.18), radius: 24, y: 10)
		.frame(maxWidth: 360)
		.padding(.horizontal, 22)
		.accessibilityAction(.escape) { leave(finding: false) }
	}

	private func leave(finding: Bool) {
		guard isShown else { return }
		withAnimation(.easeOut(duration: 0.2)) {
			isShown = false
		} completion: {
			close(finding)
		}
	}
}

/// The notification iOS posts some time after a look (12 Nov 2026), drawn
/// as iOS draws it, so that you know it when it comes: Device Hub, which
/// takes Atelier's screen stream for a Mac's, says this iPhone was viewed
/// remotely from a Mac.
private struct DeviceHubNotification: View {
	var body: some View {
		HStack(spacing: 11) {
			RoundedRectangle(cornerRadius: 8.5, style: .continuous)
				.fill(LinearGradient(colors: [Color(white: 0.63), Color(white: 0.42)], startPoint: .top, endPoint: .bottom))
				.frame(width: 38, height: 38)
				.overlay {
					Image(systemName: "gearshape.fill")
						.font(.system(size: 25))
						.foregroundStyle(Color(white: 0.9))
				}
			VStack(alignment: .leading, spacing: 1) {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("Device Hub")
						.font(.subheadline.weight(.semibold))
					Spacer(minLength: 0)
					Text("now")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Text("This device was viewed remotely from Mac")
					.font(.subheadline)
			}
		}
		.padding(EdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 14))
		.background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
		}
		.shadow(color: .black.opacity(0.08), radius: 6, y: 2)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("iOS’s notification: Device Hub, This device was viewed remotely from Mac")
	}
}

/// A button of Find Open Spaces Automatically's alert: a grey capsule, as
/// iOS's alerts have them, darker while pressed.
private struct AlertButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.body)
			.multilineTextAlignment(.center)
			.padding(.horizontal, 16)
			.padding(.vertical, 12)
			.frame(maxWidth: .infinity, minHeight: 48)
			.background(Capsule().fill(Color(uiColor: configuration.isPressed ? .systemFill : .secondarySystemFill)))
			.contentShape(Capsule())
	}
}

/// Find Open Spaces Automatically's glyph, as the mockup drew it: three
/// places, an open one, and a magnifying glass.
private struct FindSpacesGlyph: View {
	var body: some View {
		Canvas { context, size in
			// Drawn on a 24-point grid, scaled to the glyph's size.
			let unit: CGFloat = size.width / 24
			func scaled(_ value: CGFloat) -> CGFloat { value * unit }
			func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGRect {
				CGRect(x: scaled(x), y: scaled(y), width: scaled(side), height: scaled(side))
			}
			func place(_ x: CGFloat, _ y: CGFloat) -> Path {
				Path(roundedRect: square(x, y, 7), cornerRadius: scaled(2))
			}
			let line = StrokeStyle(lineWidth: scaled(2), lineCap: .round, lineJoin: .round)
			let dashed = StrokeStyle(lineWidth: scaled(2), dash: [scaled(2.4), scaled(2)])
			context.stroke(place(3.5, 3.5), with: .foreground, style: line)
			context.stroke(place(13.5, 3.5), with: .foreground, style: dashed)
			context.stroke(place(3.5, 13.5), with: .foreground, style: line)
			context.stroke(Path(ellipseIn: square(13.6, 13.6, 6.8)), with: .foreground, style: line)
			var handle = Path()
			handle.move(to: CGPoint(x: scaled(19.5), y: scaled(19.5)))
			handle.addLine(to: CGPoint(x: scaled(21.5), y: scaled(21.5)))
			context.stroke(handle, with: .foreground, style: line)
		}
		.frame(width: 19, height: 19)
		.accessibilityHidden(true)
	}
}
