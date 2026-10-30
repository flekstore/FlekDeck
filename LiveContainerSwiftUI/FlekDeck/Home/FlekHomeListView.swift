//
//  FlekHomeListView.swift
//  LiveContainerSwiftUI
//
//  The "List" home screen layout (Personalization → Home Screen Layout → List).
//  Shows the same items as the springboard as glass rows; tapping a row
//  launches it.
//  Uses Dragula for smooth drag-and-drop reordering in edit mode.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekHomeListView<Menu: View>: View {
    @Binding var items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var isNew: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onDropCompleted: () -> Void = {}
    var onCancelInstall: (InstallItem) -> Void = { _ in }
    /// Whether to show the single-mode launch badge (app.dashed) for an app,
    /// matching the grid's per-cell indicator. Shown in the row's trailing slot.
    var showsSingleBadge: (LCAppModel) -> Bool = { _ in false }
    /// Whether the search button and the running apps are in the side column,
    /// leaving nothing along the bottom for the rows to clear but the home
    /// indicator.
    var barOnSide: Bool = false
    @ViewBuilder var contextMenu: (FlekHomeItem) -> Menu

    /// Observed for the built-in apps' badges, so the Settings count comes and
    /// goes with the certificate as it does on the grid.
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var draggedItem: FlekHomeItem?
    /// Whether the drag layer is mounted. Set true a beat after entering edit
    /// mode (so the enter animation plays uncovered) and cleared a beat after
    /// exiting — the layer is hidden immediately via opacity, but stays mounted
    /// briefly so its teardown doesn't hitch the exit animation.
    @State private var dragMounted = false

    /// Installed + default app rows (installing rows and grid placeholders are
    /// handled separately). The same set is used in both modes so each row
    /// keeps its identity across the edit toggle and can animate organically.
    private var displayItems: [FlekHomeItem] {
        items.filter { item in
            if case .installing = item { return false }
            return !item.isPlaceholder
        }
    }

    private var installingItems: [InstallItem] {
        items.compactMap { item in
            if case .installing(let inst) = item { return inst }
            return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            LazyVStack(spacing: 5) {
                // Installed/default app rows — one ForEach for BOTH modes so
                // each row keeps its identity when edit mode toggles and its
                // layout can shift organically.
                ForEach(displayItems) { item in
                    listRow(for: item)
                }
                // Installing rows rendered separately — uses UIKit
                // UIContextMenuInteraction instead of SwiftUI .contextMenu
                // to avoid cross-contamination with installed app menus.
                ForEach(installingItems) { inst in
                    FlekInstallRow(state: inst.installState)
                        .overlay {
                            CancelInstallContextMenu { onCancelInstall(inst) }
                        }
                        // A failed install is tappable to show the failure alert;
                        // in-progress rows keep long-press-to-cancel only.
                        .onTapGesture {
                            if inst.installState.failed { onTap(.installing(inst)) }
                        }
                }
            }
            .padding(.horizontal, FlekTheme.screenHPadding)
            // Inset past the top safe area and the bottom bar so rows scroll
            // *behind* them instead of stopping short at their edges.
            .padding(.top, geo.safeAreaInsets.top + 16)
            .padding(.bottom, geo.safeAreaInsets.bottom + (barOnSide ? 16 : 89))
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        }
        .onChange(of: isEditing) { editing in
            if editing {
                // Mount the drag layer only after the enter animation plays.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    if isEditing { dragMounted = true }
                }
            } else {
                // Already hidden via opacity below; keep it mounted a beat so
                // its teardown doesn't hitch the exit animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !isEditing { dragMounted = false }
                }
            }
        }
    }

    // MARK: - Row

    /// A single list row. The visible row is always the native `FlekAppRow`,
    /// so toggling edit mode animates its own layout organically — the delete
    /// button slides in from the left and pushes the icon/title to the right,
    /// reversing on exit. In edit mode a Dragula drag layer is overlaid on top
    /// (only after the enter animation) for reordering; in normal mode a tap
    /// anywhere on the row launches it, and it keeps its context menu.
    @ViewBuilder
    private func listRow(for item: FlekHomeItem) -> some View {
        FlekAppRow(
            title: title(for: item),
            subtitle: subtitle(for: item),
            isNew: newDot(for: item),
            isShared: sharedMark(for: item),
            showsSingleBadge: singleBadge(for: item),
            showsJITBadge: jitBadge(for: item),
            notificationCount: notificationCount(for: item),
            isEditing: isEditing,
            editBadge: item.editBadge,
            onDelete: { onDelete(item) },
            icon: { iconView(for: item) }
        )
        // Animate this row's own layout on the edit toggle (delete button in,
        // content shifting, badge/handle swap). Scoped to the row so the drag
        // overlay's show/hide below is not swept into the same animation.
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isEditing)
        // Hide the native row when the drag overlay is covering it (or while
        // it is the one being dragged), so the two glass backgrounds never
        // stack and tint the cell — exactly one layer paints the background.
        .opacity(draggedItem?.id == item.id || (dragMounted && isEditing) ? 0 : 1)
        .overlay {
            if dragMounted && item.isDraggable {
                DraggableView(
                    preview: { editRow(for: item) },
                    dropView: { rowDropPlaceholder() },
                    itemProvider: { item.getItemProvider() },
                    onDragWillBegin: { draggedItem = item },
                    onDragWillEnd: {
                        draggedItem = nil
                        onDropCompleted()
                    }
                )
                .onDrop(of: [UTType.text], delegate: ListReorderDelegate(
                    item: item,
                    items: $items,
                    draggedItem: $draggedItem
                ))
                .environment(\.dragPreviewCornerRadius, 20)
                // Visible/interactive only while editing; hidden instantly on
                // exit (no fade) so the row's morph plays uncovered.
                .opacity(isEditing ? 1 : 0)
                .allowsHitTesting(isEditing)
                .animation(nil, value: isEditing)
            }
        }
        // The row itself is the launch control now that the Run pill is gone;
        // the drag overlay above owns the touches while editing.
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing { onTap(item) }
        }
        .contextMenu {
            if !isEditing {
                contextMenu(item)
            }
        }
    }

    @ViewBuilder
    private func editRow(for item: FlekHomeItem) -> some View {
        FlekAppRow(
            title: title(for: item),
            subtitle: subtitle(for: item),
            isNew: newDot(for: item),
            isShared: sharedMark(for: item),
            showsSingleBadge: singleBadge(for: item),
            showsJITBadge: jitBadge(for: item),
            notificationCount: notificationCount(for: item),
            isEditing: true,
            editBadge: item.editBadge,
            onDelete: { onDelete(item) },
            icon: { iconView(for: item) }
        )
    }

    /// Shown in the origin slot while a row is being dragged. Kept as an
    /// invisible spacer so surrounding rows still make room, but with no
    /// visible translucent placeholder box.
    @ViewBuilder
    private func rowDropPlaceholder() -> some View {
        Color.clear
            .frame(height: 84)
    }

    // MARK: - Helpers

    private func sharedMark(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return app.uiIsShared }
        return false
    }

    private func singleBadge(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return showsSingleBadge(app) }
        return false
    }

    private func jitBadge(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return app.uiIsJITNeeded }
        return false
    }

    private func notificationCount(for item: FlekHomeItem) -> Int {
        if case .defaultApp(let kind) = item { return kind.badgeCount(in: sharedModel) }
        return 0
    }

    @ViewBuilder
    private func iconView(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp(let kind):
            Image(kind.iconAssetName).resizable().scaledToFill()
        case .installed(let app):
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon)).resizable().scaledToFill()
        case .installing, .placeholder:
            Color.clear
        }
    }

    private func title(for item: FlekHomeItem) -> String {
        switch item {
        case .defaultApp(let kind): return kind.title
        case .installed(let app): return app.appInfo.displayName() ?? "?"
        case .installing(let inst): return inst.name ?? ""
        case .placeholder: return ""
        }
    }

    private func subtitle(for item: FlekHomeItem) -> String? {
        if case .installed(let app) = item {
            return "\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")"
        }
        return nil
    }

    private func newDot(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return isNew(app) }
        return false
    }

}

/// Tuning knob for the list row surface. Matches the value `flekGlassCard`
/// passes on the grid, so rows and cards read as the same material.
enum FlekHomeListRow {
    static let surfaceTint: Double = 0.22
}

struct FlekAppRow<Icon: View>: View {
    let title: String
    var subtitle: String?
    var isNew: Bool = false
    var isShared: Bool = false
    var showsSingleBadge: Bool = false
    /// The app is set to launch with JIT.
    var showsJITBadge: Bool = false
    /// The red count on the icon's corner; 0 draws none.
    var notificationCount: Int = 0
    var isEditing: Bool = false
    var editBadge: FlekEditBadge = .remove
    var onDelete: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 16) {
            if isEditing && editBadge != .none {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            icon()
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                // Hung off the icon's top-right corner, as on the grid. Laid
                // over the clipped icon rather than inside it, so the part
                // reaching past the corner still shows.
                .overlay(alignment: .topTrailing) {
                    if notificationCount > 0 {
                        FlekNotificationBadge(count: notificationCount)
                            .offset(x: 8, y: -8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isNew {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                    }
                    if isShared {
                        // The app's data is kept in the shared folder rather
                        // than privately — the same mark the grid puts in front
                        // of the icon's title.
                        Image(systemName: FlekSymbol.shared)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            } else if showsSingleBadge || showsJITBadge {
                // Same indicators as the grid cell (app launches with JIT, in
                // single mode), sitting where the Run pill used to.
                HStack(spacing: 6) {
                    if showsJITBadge {
                        Image(systemName: FlekSymbol.jit)
                    }
                    if showsSingleBadge {
                        Image(systemName: "app.dashed")
                    }
                }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 84)
        .background {
            // The same surface the grid cards fall back to, so a row and a card
            // are one material. `flekGlassCard` is deliberately not used here:
            // it would take the Liquid Glass path on iOS 26, and rows are not
            // opting into that yet.
            FlekGlassBackground(cornerRadius: 20, tint: FlekHomeListRow.surfaceTint)
        }
    }
}

/// The red count iOS draws on an app icon's corner, for the list's icons. The
/// grid draws the same badge in UIKit, in `LCSpringboardIconCell`.
struct FlekNotificationBadge: View {
    let count: Int
    var height: CGFloat = 24

    var body: some View {
        Text("\(count)")
            .font(.system(size: (height * 16 / 24).rounded()))
            .foregroundStyle(.white)
            // A circle for one digit, a capsule once the figure is wider.
            .padding(.horizontal, height / 4)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(Color.red))
    }
}

/// UIKit-based context menu for the installing row. Uses
/// `UIContextMenuInteraction` directly instead of SwiftUI's `.contextMenu`
/// to avoid cross-contamination with installed app context menus.
private struct CancelInstallContextMenu: UIViewRepresentable {
    var onCancel: () -> Void

    class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let cancel = self.onCancel
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(title: "", children: [
                    UIAction(
                        title: "lc.flek.cancelInstall".loc,
                        image: UIImage(systemName: FlekSymbol.cancelDownload),
                        attributes: .destructive
                    ) { _ in cancel() }
                ])
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onCancel = onCancel
    }
}

/// List-layout row for the in-progress install.
struct FlekInstallRow: View {
    let state: FlekInstallState

    var body: some View {
        HStack(spacing: 16) {
            FlekInstallIcon(state: state, size: 68, corner: 15)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.name ?? "lc.flek.installing".loc)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // Progress is shown on the app icon itself (percentage while
                // downloading, ring while installing), so the text column shows
                // just the app name — no progress bar or status label.
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 84)
        .background {
            // The same surface the grid cards fall back to, so a row and a card
            // are one material. `flekGlassCard` is deliberately not used here:
            // it would take the Liquid Glass path on iOS 26, and rows are not
            // opting into that yet.
            FlekGlassBackground(cornerRadius: 20, tint: FlekHomeListRow.surfaceTint)
        }
    }
}
