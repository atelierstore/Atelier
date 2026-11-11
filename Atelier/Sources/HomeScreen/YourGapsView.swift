import AtelierCore
import InstallKit
import SwiftData
import SwiftUI

/// Settings › Home Screen › Open Spaces (7 Nov 2026), or a sheet from
/// the gaps question's Mark Spaces to Keep (9 Nov 2026): each page as
/// the last read found it, with its apps packed together as iOS reports
/// them. Tap an app to put a gap before it, so the page looks as it does
/// on the iPhone, and every write keeps it.
struct YourGapsView: View {
	/// As a sheet: the action its button, top right, carries on with.
	var carryOn: MarkGapsFirst?
	@State private var model = YourGapsModel()
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
					grid
					dots
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

	/// "2 open spaces", "widgets" or "no open spaces".
	private var pageNote: String {
		guard model.canMark else { return "widgets" }
		switch model.gapCount {
		case 0: return "no open spaces"
		case 1: return "1 open space"
		default: return "\(model.gapCount) open spaces"
		}
	}

	private func pageButton(_ symbol: String, label: String, to page: Int) -> some View {
		Button {
			model.page = page
		} label: {
			Image(systemName: symbol)
				.font(.body.weight(.semibold))
				.frame(width: 40, height: 40)
				.background(Circle().fill(Color(.secondarySystemGroupedBackground)))
		}
		.disabled(!model.pages.indices.contains(page))
		.accessibilityLabel(label)
	}

	private var grid: some View {
		let layout = model.cells
		let slots = model.slots
		return GeometryReader { geometry in
			let width = geometry.size.width / 4
			ZStack(alignment: .topLeading) {
				ForEach(layout.cells) { cell in
					place(slots[cell.index], at: cell.index)
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
		.opacity(model.canMark ? 1 : 0.45)
		.saturation(model.canMark ? 1 : 0.6)
	}

	@ViewBuilder
	private func place(_ slot: HomeScreenSlot, at index: Int) -> some View {
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
				model.tap(index)
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
			.disabled(!model.canMark)
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

	@ViewBuilder
	private var hint: some View {
		Group {
			if let notice = model.notice {
				Text(notice)
					.foregroundStyle(.orange)
			} else if !model.canMark {
				Text("**Page \(model.page + 1) has widgets, so it keeps no open spaces.** iOS fits icons around widgets its own way. Its apps still go back to their spots.")
					.foregroundStyle(.secondary)
			} else {
				Text(markHint)
					.foregroundStyle(.secondary)
			}
		}
		.font(.footnote)
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 16)
	}

	/// How to mark, and which offloaded apps' spots are kept on the page.
	private var markHint: String {
		let held = model.slots.compactMap { slot -> String? in
			guard case .held = slot else { return nil }
			return label(slot)
		}
		let tap = "Tap an app to put an open space before it, as on your iPhone, and again for two. Tap an open space to take it out."
		let then = carryOn.map { " \($0.then)" } ?? ""
		switch held.count {
		case 0: return tap + then
		case 1: return "\(tap) \(held[0]) is offloaded: its spot stays empty until Reinstall.\(then)"
		default: return "\(tap) \(held.formatted(.list(type: .and))) are offloaded: their spots stay empty until Reinstall.\(then)"
		}
	}
}
