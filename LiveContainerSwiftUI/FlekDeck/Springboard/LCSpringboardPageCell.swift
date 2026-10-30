//
//  LCSpringboardPageCell.swift
//  LiveContainerSwiftUI
//
//  One page of the springboard grid. Contains an inner UICollectionView
//  showing LCSpringboardIconCells in a grid layout.
//  Modelled after jSpringBoard's PageCell.
//

import UIKit

protocol LCSpringboardPageCellDelegate: AnyObject {
    func pageCell(_ pageCell: LCSpringboardPageCell, didTapItem item: FlekHomeItem)
    func pageCell(_ pageCell: LCSpringboardPageCell, didTapDeleteFor item: FlekHomeItem)
    func pageCell(_ pageCell: LCSpringboardPageCell, contextMenuFor item: FlekHomeItem) -> UIMenu?
}

final class LCSpringboardPageCell: UICollectionViewCell {

    // MARK: - Public state

    weak var delegate: LCSpringboardPageCellDelegate?

    var items: [FlekHomeItem] = []
    var draggedItemId: String?
    var darkModeIcon: Bool = false
    private(set) var isEditing = false
    private var isContextMenuActive = false
    private var pendingReloadItems: [FlekHomeItem]?

    // MARK: - Inner collection view

    let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 0

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.clipsToBounds = false
        cv.isScrollEnabled = false
        cv.showsVerticalScrollIndicator = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.register(LCSpringboardIconCell.self, forCellWithReuseIdentifier: "IconCell")
        return cv
    }()

    // MARK: - Layout config

    /// Columns on iPhone, and in any window too narrow for the iPad grid.
    static let phoneColumns: Int = 3
    /// The gap between two cards, across and down alike, and the margin the
    /// grid keeps from the sides of the screen.
    private static let phoneSpacing: CGFloat = 8
    private static let phoneSideMargin: CGFloat = 28
    /// Strip left clear at the foot of a phone page for the page dots, which
    /// the springboard draws along the bottom of its own view.
    private static let phoneBottomReserve: CGFloat = 30

    /// Narrowest page that gets the iPad grid, on any device. Below it — an iPhone
    /// held upright, Slide Over, a small Stage Manager window — the phone's three
    /// columns suit the width better.
    private static let padMinWidth: CGFloat = 600

    /// The iPad grid is fixed rather than derived from the height, and both ways
    /// up hold 24 icons. Page boundaries are persisted, so a capacity that
    /// changed with orientation would repaginate the home screen on every turn.
    private static let padPortraitGrid = (columns: 4, rows: 6)
    private static let padLandscapeGrid = (columns: 6, rows: 4)

    /// Share of the width the iPad grid spans. The rest is the side margin that
    /// keeps it a centred block rather than icons strewn from edge to edge.
    private static let padGridWidthFraction: CGFloat = 0.66
    /// A cell's share of its column; the remainder is the gap to the next one.
    /// Nearly all of it: the column pitch is fixed by the grid's span, so what the
    /// cell takes the gap gives up — a big card with tight gaps reads as a grid of
    /// icons rather than icons stranded far apart.
    private static let padCellWidthFraction: CGFloat = 0.95
    /// Bounds on the iPad cell. The icon is a fraction of the cell, so these
    /// bound the icon too: neither so narrow that it shrinks to a phone's, nor
    /// so wide that one icon takes a quarter of the screen.
    private static let padCellWidthRange: ClosedRange<CGFloat> = 114...145
    /// Height an iPad cell never goes below, so a short window keeps the same
    /// breathing space above the icon and below the label that the phone's
    /// card gives them.
    private static let padMinCellHeight: CGFloat = 130
    private static let padMinSpacing: CGFloat = 16
    /// Widest gap between iPad cells. Past this the spare space goes to the
    /// margins instead, so a larger iPad gets a bigger grid, not a sparser one.
    private static let padMaxSpacing: CGFloat = 20
    /// Room kept below the last row for the page dots, which sit at the bottom
    /// of the springboard view.
    private static let padBottomReserve: CGFloat = 34

    /// Padding `LCAppListView` puts above the springboard, measured from the
    /// safe area: the design's 108pt down from the top of the screen, less the
    /// 62 the inset already accounts for. Callers with no view to measure need
    /// it to work out the page size from the screen.
    static let gridTopPadding: CGFloat = 46

    /// Clear space between the page dots and the top of the bottom bar.
    private static let barClearance: CGFloat = 18

    /// Padding below the springboard, which the bottom bar decides. The dots sit
    /// at the foot of the springboard's own view rather than below it, so the
    /// view has to stop short of the search button and the multitask bar or they
    /// cover the dots. That cannot be a fixed number, because the bar is itself
    /// sized off the screen and a tablet's stands half again as tall as a
    /// phone's — which is exactly how it came to swallow them.
    ///
    /// On the screen the design is drawn for this works out at 70, putting the
    /// last row of icons at the design's 134 up from the bottom: the grid stops
    /// `phoneBottomReserve` short of the padding to leave the dots their strip.
    static func gridBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        max(0, FlekTheme.bottomBarScreenMargin + FlekTheme.bottomBarControlSize
               + barClearance - safeAreaBottom)
    }

    /// Whether a page of this size uses the iPad grid.
    ///
    /// Decided by the width alone, not by the kind of device. No iPhone page gets
    /// there: the springboard is held upright, and the widest iPhone is 440pt
    /// across. The unfolded iPhone Duo does, and it needs to — it is a tablet-sized
    /// display on a phone, where three columns would stretch each card to 200 to
    /// 290pt across.
    static func usesPadGrid(pageSize: CGSize) -> Bool {
        pageSize.width >= padMinWidth
    }

    private static func padGrid(forPageSize size: CGSize) -> (columns: Int, rows: Int) {
        size.width > size.height ? padLandscapeGrid : padPortraitGrid
    }

    static func columns(forPageSize size: CGSize) -> Int {
        usesPadGrid(pageSize: size) ? padGrid(forPageSize: size).columns : phoneColumns
    }

    /// Width one column occupies on iPad, cell plus the gap that follows it.
    private static func padColumnPitch(forPageSize size: CGSize) -> CGFloat {
        size.width * padGridWidthFraction / CGFloat(padGrid(forPageSize: size).columns)
    }

    /// What the margins and the gaps between the columns leave for a card.
    static func computeCellWidth(forPageSize size: CGSize) -> CGFloat {
        guard usesPadGrid(pageSize: size) else {
            let screenWidth = max(size.width, 320)
            let cols = CGFloat(phoneColumns)
            let totalSpacing: CGFloat = phoneSpacing * (cols - 1)
            let availableWidth = screenWidth - (phoneSideMargin * 2) - totalSpacing
            return floor(availableWidth / cols)
        }
        let target = padColumnPitch(forPageSize: size) * padCellWidthFraction
        return floor(min(max(target, padCellWidthRange.lowerBound), padCellWidthRange.upperBound))
    }

    /// A card is a little taller than it is wide — the room the label takes up
    /// under the icon. Twelve elevenths of it: five rows of the card the design's
    /// margins give come to exactly the height between the top of the grid and
    /// the page dots, so the last row lands where the design puts it. Multiplied
    /// before it is divided, so that a ratio a hair under the real one cannot
    /// floor an exact height down to the point below.
    private static let cellAspect: (width: CGFloat, height: CGFloat) = (11, 12)

    static func computeCellHeight(forPageSize size: CGSize) -> CGFloat {
        let fromAspect = floor(computeCellWidth(forPageSize: size)
                               * cellAspect.height / cellAspect.width)
        return usesPadGrid(pageSize: size) ? max(fromAspect, padMinCellHeight) : fromAspect
    }

    static func interitemSpacing(forPageSize size: CGSize) -> CGFloat {
        guard usesPadGrid(pageSize: size) else { return phoneSpacing }
        let gap = padColumnPitch(forPageSize: size) - computeCellWidth(forPageSize: size)
        return floor(min(max(gap, padMinSpacing), padMaxSpacing))
    }

    /// Horizontal margin: centres the grid with leftover space.
    static func computeHorizontalInset(forPageSize size: CGSize) -> CGFloat {
        let screenWidth = max(size.width, 320)
        let cols = CGFloat(columns(forPageSize: size))
        let totalSpacing = interitemSpacing(forPageSize: size) * (cols - 1)
        let cellWidth = computeCellWidth(forPageSize: size)
        let inset = (screenWidth - (cellWidth * cols) - totalSpacing) / 2
        // Floored on iPad so a fractional point can never leave the row a hair
        // too narrow for its last column, which would drop it to the next line.
        return max(4, usesPadGrid(pageSize: size) ? floor(inset) : inset)
    }

    /// Rows, line spacing and the inset that centres them vertically, for the
    /// iPad grid. The row count is fixed but gives way when a window is too
    /// short to hold it, so the last row can never end up under the dock.
    private static func padVerticalLayout(forPageSize size: CGSize)
        -> (rows: Int, lineSpacing: CGFloat, topInset: CGFloat) {
        let cellHeight = computeCellHeight(forPageSize: size)
        let available = max(0, size.height - padBottomReserve)

        var rows = padGrid(forPageSize: size).rows
        while rows > 1,
              CGFloat(rows) * cellHeight + CGFloat(rows - 1) * padMinSpacing > available {
            rows -= 1
        }

        // Rows sit exactly as far apart as columns, so the grid reads as one
        // lattice rather than two spacings that happen to be close. The height
        // left over is not shared out between the rows to fill it — it becomes
        // the inset that centres them, which is what keeps the two equal.
        let target = interitemSpacing(forPageSize: size)
        let spacing: CGFloat
        if rows > 1 {
            // All the room there is, if the window cannot give it the full gap.
            // The row-count guard above already promised at least `padMinSpacing`,
            // so this can only narrow the gap, never close it.
            let widest = (available - CGFloat(rows) * cellHeight) / CGFloat(rows - 1)
            spacing = min(target, floor(widest))
        } else {
            spacing = 0
        }
        let gridHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
        return (rows, spacing, max(0, floor((available - gridHeight) / 2)))
    }

    /// Icons an iPad page holds, or nil at a size that uses the phone grid and
    /// so derives its count from the height instead.
    static func padItemsPerPage(forPageSize size: CGSize) -> Int? {
        guard usesPadGrid(pageSize: size) else { return nil }
        return max(1, padVerticalLayout(forPageSize: size).rows * columns(forPageSize: size))
    }

    /// Rows a phone page holds: as many as fit above the strip kept for the
    /// page dots, hanging from the top of the page. What is left over at the
    /// bottom stays empty rather than being shared out among the rows, so the
    /// gap between two rows is the 8pt the design asks for on every screen.
    static func phoneRows(forPageSize size: CGSize) -> Int {
        let cellHeight = computeCellHeight(forPageSize: size)
        let available = size.height - phoneBottomReserve
        guard cellHeight > 0, available > 0 else { return 1 }
        return max(1, Int((available + phoneSpacing) / (cellHeight + phoneSpacing)))
    }

    /// Icons a page of this size holds, whichever grid it uses.
    static func itemsPerPage(forPageSize size: CGSize) -> Int {
        if let padCount = padItemsPerPage(forPageSize: size) { return padCount }
        return max(1, phoneRows(forPageSize: size) * phoneColumns)
    }

    /// The springboard's own size on a screen of the given size: the safe area
    /// and the padding around the grid taken off. For callers that have no view
    /// to measure but need to arrive at the same page capacity.
    static func estimatedPageSize(screenSize: CGSize, safeAreaInsets: UIEdgeInsets) -> CGSize {
        CGSize(
            width: screenSize.width - safeAreaInsets.left - safeAreaInsets.right,
            height: screenSize.height - safeAreaInsets.top - safeAreaInsets.bottom
                - gridTopPadding - gridBottomPadding(safeAreaBottom: safeAreaInsets.bottom)
        )
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = false
        contentView.clipsToBounds = false

        contentView.addSubview(collectionView)
        collectionView.dataSource = self
        collectionView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = contentView.bounds
        updateFlowLayout()
    }

    private func updateFlowLayout() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }

        let size = contentView.bounds.size
        let inset = Self.computeHorizontalInset(forPageSize: size)

        layout.itemSize = CGSize(width: Self.computeCellWidth(forPageSize: size),
                                 height: Self.computeCellHeight(forPageSize: size))
        layout.minimumInteritemSpacing = Self.interitemSpacing(forPageSize: size)

        if Self.usesPadGrid(pageSize: size) {
            // The iPad grid no longer fills the height it is given, so centre it
            // in what is left above the page dots rather than hanging it from
            // the top with all the slack below the last row.
            let vertical = Self.padVerticalLayout(forPageSize: size)
            layout.minimumLineSpacing = vertical.lineSpacing
            layout.sectionInset = UIEdgeInsets(top: vertical.topInset, left: inset,
                                               bottom: Self.padBottomReserve, right: inset)
        } else {
            layout.minimumLineSpacing = Self.phoneSpacing
            layout.sectionInset = UIEdgeInsets(top: 0, left: inset,
                                               bottom: Self.phoneBottomReserve, right: inset)
        }
    }

    /// Redraws the icons already on screen from the items this page is holding.
    /// An item carries a reference to its app, so one that changed underneath
    /// the grid is picked up without re-paginating or reloading anything — and
    /// without the flash a `reloadData` costs.
    func refreshVisibleCells() {
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell,
                  let idx = collectionView.indexPath(for: iconCell)?.item,
                  idx < items.count else { continue }
            iconCell.configure(with: items[idx], darkMode: darkModeIcon, cardWidth: cardWidth)
        }
    }

    /// The width this page lays its cards out at, which the icon inside each one
    /// is sized from — the same width `updateFlowLayout` gives the layout.
    private var cardWidth: CGFloat {
        Self.computeCellWidth(forPageSize: contentView.bounds.size)
    }

    // MARK: - Edit mode

    func enterEditingMode() {
        guard !isEditing else { return }
        isEditing = true
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell, !iconCell.isPlaceholderCell else { continue }
            let idx = collectionView.indexPath(for: iconCell)?.item ?? 0
            let badge = idx < items.count ? items[idx].editBadge : .none
            iconCell.startJiggle()
            iconCell.setDeleteButtonVisible(badge != .none, animated: true)
        }
    }

    func leaveEditingMode() {
        guard isEditing else { return }
        isEditing = false
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell else { continue }
            iconCell.stopJiggle()
            iconCell.setDeleteButtonVisible(false, animated: true)
        }
    }

    // MARK: - Helpers

    /// Calculates how many rows fit in the current page height.
    func rowsPerPage() -> Int {
        let size = contentView.bounds.size
        if Self.usesPadGrid(pageSize: size) {
            return Self.padVerticalLayout(forPageSize: size).rows
        }
        return Self.phoneRows(forPageSize: size)
    }

    func itemsPerPage() -> Int {
        return Self.itemsPerPage(forPageSize: contentView.bounds.size)
    }

    /// Reload items, deferring if a context menu is active to avoid cell reuse glitches.
    /// When a single item is deleted, applies jSpringBoard's shrink-to-zero animation.
    func safeReloadItems(_ newItems: [FlekHomeItem]) {
        if isContextMenuActive {
            pendingReloadItems = newItems
            return
        }

        // Delete animation: shrink icon to ~0, then batch-delete so
        // remaining icons shift smoothly. Only the icon is scaled —
        // applying a transform to the full contentView causes liquid
        // glass visual artefacts.
        if newItems.count == items.count - 1 {
            let oldIDs = Set(items.map(\.id))
            let newIDs = Set(newItems.map(\.id))
            let removed = oldIDs.subtracting(newIDs)
            if removed.count == 1, let removedID = removed.first,
               let index = items.firstIndex(where: { $0.id == removedID }),
               let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? LCSpringboardIconCell {
                UIView.animate(withDuration: 0.25, animations: {
                    cell.iconImageView.transform = CGAffineTransform.identity.scaledBy(x: 0.0001, y: 0.0001)
                    cell.nameLabel.alpha = 0
                    cell.contentView.alpha = 0
                }, completion: { _ in
                    self.items = newItems
                    self.collectionView.performBatchUpdates({
                        self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
                    }, completion: { _ in
                        cell.iconImageView.transform = .identity
                        cell.nameLabel.alpha = 1
                        cell.contentView.alpha = 1
                    })
                })
                return
            }
        }

        items = newItems
        collectionView.reloadData()
    }
}

// MARK: - UICollectionViewDataSource

extension LCSpringboardPageCell: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "IconCell", for: indexPath) as! LCSpringboardIconCell
        let item = items[indexPath.item]

        cell.configure(with: item, darkMode: darkModeIcon, cardWidth: cardWidth)

        // Edit mode state
        if isEditing && !cell.isPlaceholderCell {
            cell.startJiggle()
            cell.setDeleteButtonVisible(item.editBadge != .none, animated: false)
        } else {
            cell.stopJiggle()
            cell.setDeleteButtonVisible(false, animated: false)
        }

        // Hide cell's contentView if it's being dragged (jSpringBoard pattern)
        if let dragId = draggedItemId, item.id == dragId {
            cell.contentView.isHidden = true
        } else if !cell.isPlaceholderCell {
            cell.contentView.isHidden = false
        }

        // Callbacks
        cell.onTap = { [weak self] in
            guard let self else { return }
            self.delegate?.pageCell(self, didTapItem: item)
        }
        cell.onDeleteTap = { [weak self] in
            guard let self else { return }
            self.delegate?.pageCell(self, didTapDeleteFor: item)
        }

        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension LCSpringboardPageCell: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        return false
    }

    /// The currently active context menu interaction, used to live-update
    /// the menu (e.g. toggling launch mode) without dismissing it.
    private(set) static weak var activeContextMenuInteraction: UIContextMenuInteraction?
    private static var activeContextMenuRefresh: (() -> UIMenu?)?
    private static weak var activeContextMenuPageCell: LCSpringboardPageCell?
    private static var activeContextMenuIndexPath: IndexPath?

    /// Rebuilds the currently visible context menu in-place so that state
    /// changes (like launch-mode toggles) are reflected immediately.
    static func refreshActiveContextMenu() {
        guard #available(iOS 16.0, *),
              let interaction = activeContextMenuInteraction,
              let refresh = activeContextMenuRefresh else { return }
        interaction.updateVisibleMenu { _ in
            refresh() ?? UIMenu(children: [])
        }
    }

    /// Updates the badge on the icon cell that currently has an active
    /// context menu, without reloading the entire cell.
    static func refreshActiveCellBadge() {
        guard let pageCell = activeContextMenuPageCell,
              let ip = activeContextMenuIndexPath,
              let cell = pageCell.collectionView.cellForItem(at: ip) as? LCSpringboardIconCell else { return }
        cell.updateBadge()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing else { return nil }
        let item = items[indexPath.item]
        guard !item.isPlaceholder else { return nil }
        guard let menu = delegate?.pageCell(self, contextMenuFor: item) else { return nil }

        // Store references so the menu and badge can be updated while visible.
        Self.activeContextMenuPageCell = self
        Self.activeContextMenuIndexPath = indexPath
        Self.activeContextMenuRefresh = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.pageCell(self, contextMenuFor: item)
        }

        return UIContextMenuConfiguration(identifier: indexPath as NSCopying, previewProvider: nil) { _ in
            menu
        }
    }

    func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell else { return nil }
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(
            roundedRect: cell.iconImageView.bounds,
            cornerRadius: LCSpringboardIconCell.iconCornerRadius(forIconSize: cell.iconImageView.bounds.width)
        )
        params.shadowPath = UIBezierPath()
        return UITargetedPreview(view: cell.iconImageView, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell else { return nil }
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(
            roundedRect: cell.iconImageView.bounds,
            cornerRadius: LCSpringboardIconCell.iconCornerRadius(forIconSize: cell.iconImageView.bounds.width)
        )
        params.shadowPath = UIBezierPath()
        return UITargetedPreview(view: cell.iconImageView, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        isContextMenuActive = true
        // Grab the UIContextMenuInteraction so we can call updateVisibleMenu later.
        for interaction in collectionView.interactions {
            if let cmi = interaction as? UIContextMenuInteraction {
                Self.activeContextMenuInteraction = cmi
                break
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        Self.activeContextMenuInteraction = nil
        Self.activeContextMenuRefresh = nil
        Self.activeContextMenuPageCell = nil
        Self.activeContextMenuIndexPath = nil
        animator?.addCompletion { [weak self] in
            guard let self else { return }
            self.isContextMenuActive = false
            if let pending = self.pendingReloadItems {
                self.pendingReloadItems = nil
                self.items = pending
                self.collectionView.reloadData()
            }
        }
        // Fallback if no animator
        if animator == nil {
            isContextMenuActive = false
            if let pending = pendingReloadItems {
                pendingReloadItems = nil
                items = pending
                collectionView.reloadData()
            }
        }
    }
}
