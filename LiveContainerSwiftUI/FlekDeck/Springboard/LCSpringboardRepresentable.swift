//
//  LCSpringboardRepresentable.swift
//  LiveContainerSwiftUI
//
//  UIViewControllerRepresentable bridge wrapping LCSpringboardViewController
//  for use inside LCAppListView, replacing FlekSpringboardView.
//

import SwiftUI

struct LCSpringboardRepresentable: UIViewControllerRepresentable {

    @Binding var items: [FlekHomeItem]
    let darkModeIcon: Bool
    /// Liquid Glass cards, or frosted ones: see `FlekGlassStyle`.
    let drawsGlass: Bool
    @Binding var isEditing: Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onReorder: () -> Void
    var contextMenuProvider: ((FlekHomeItem) -> UIMenu?)?
    @Binding var scrollToPage: Int?

    func makeUIViewController(context: Context) -> LCSpringboardViewController {
        let vc = LCSpringboardViewController()
        vc.darkModeIcon = darkModeIcon
        vc.drawsGlass = drawsGlass
        vc.onTap = onTap
        vc.onDelete = onDelete
        vc.onReorder = { [self] newItems in
            items = newItems
            onReorder()
        }
        vc.onEditingChanged = { editing in
            isEditing = editing
        }
        vc.contextMenuProvider = contextMenuProvider
        return vc
    }

    func updateUIViewController(_ vc: LCSpringboardViewController, context: Context) {
        // Always store the latest items so viewWillAppear can catch up
        // after being hidden behind a fullScreenCover.
        vc.pendingItems = items

        // Only call updateItems when the SET of items changes
        // (app added/removed), not when order changes (reorder).
        // Compare as sets so reorder doesn't trigger re-pagination.
        var repaginated = false
        if !vc.dragManager.isDragging {
            let currentSet = Set(vc.flatItems.map(\.id))
            let newSet = Set(items.map(\.id))
            if currentSet != newSet {
                vc.updateItems(items)
                vc.pendingItems = nil
                repaginated = true
            }
        }

        // A tile can change without the set of tiles changing: an app converted
        // to shared, or renamed. The comparison above only catches apps arriving
        // and leaving, so a cell configured once would otherwise go on showing
        // what was true when it was dequeued -- which is also how a cell that
        // read its icon at a bad moment stays blank.
        let signature = items.map(\.displaySignature).joined(separator: "\u{1}")
        if vc.displaySignature != signature {
            // Recorded as drawn only once it has been: behind a cover there are
            // no cells to reach, and `viewWillAppear` picks it up instead.
            if repaginated || vc.refreshVisibleItems() {
                vc.displaySignature = signature
            }
        }

        // Sync editing state (may be toggled from SwiftUI "Done" button)
        if vc.isInEditMode != isEditing {
            vc.setEditing(isEditing)
        }

        // Dark mode icon
        if vc.darkModeIcon != darkModeIcon {
            vc.darkModeIcon = darkModeIcon
            vc.outerCollectionView?.reloadData()
        }

        // Glass style changed on Personalization: every card is made again.
        if vc.drawsGlass != drawsGlass {
            vc.drawsGlass = drawsGlass
            vc.outerCollectionView?.reloadData()
        }

        // Install progress (the VC observes the queue directly for
        // frequent progress ticks; this call handles structural changes)
        vc.updateInstallProgress()

        // Closures that may have captured new state
        vc.onTap = onTap
        vc.onDelete = onDelete
        vc.onReorder = { [self] newItems in
            items = newItems
            onReorder()
        }
        vc.onEditingChanged = { editing in
            isEditing = editing
        }
        vc.contextMenuProvider = contextMenuProvider

        // Scroll-to-page request from SwiftUI
        if let page = scrollToPage {
            DispatchQueue.main.async {
                scrollToPage = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                vc.scrollToPage(page)
            }
        }
    }
}
