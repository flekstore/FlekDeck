//
//  LCSpringboardViewController.swift
//  LiveContainerSwiftUI
//
//  Main UIViewController hosting the paged springboard grid.
//  Outer UICollectionView pages horizontally; each page cell contains
//  an inner grid of app icons. Adapted from jSpringBoard's HomeViewController.
//

import UIKit

final class LCSpringboardViewController: UIViewController {

    /// The grid currently on screen, so a page being minimized can find the icon
    /// to fly into. Only ever one: the grid layout's representable makes it, and
    /// the list layout makes none at all.
    private(set) static weak var current: LCSpringboardViewController?

    // MARK: - Public data

    /// Flat list of all items (source of truth from SwiftUI).
    var flatItems: [FlekHomeItem] = []

    /// Latest items from SwiftUI, even if updateItems() hasn't been called yet.
    /// Used to catch up when the view reappears after being behind a cover.
    var pendingItems: [FlekHomeItem]?

    /// What the tiles on screen were last drawn from, so the Representable can
    /// tell a change that only alters a tile's contents from one that adds or
    /// removes tiles. See `FlekHomeItem.displaySignature`.
    var displaySignature: String?

    /// Paginated items (computed from flatItems).
    var pages: [[FlekHomeItem]] = [[]]

    /// Whether edit / jiggle mode is active.
    private(set) var isInEditMode: Bool = false

    var darkModeIcon: Bool = false
    /// Whether the icons' cards are Liquid Glass, or frosted: see `FlekGlassStyle`.
    var drawsGlass = true
    

    // MARK: - Callbacks (set by Representable)

    var onTap: ((FlekHomeItem) -> Void)?
    var onDelete: ((FlekHomeItem) -> Void)?
    var onReorder: (([FlekHomeItem]) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    var contextMenuProvider: ((FlekHomeItem) -> UIMenu?)?

    // MARK: - UI

    private(set) var outerCollectionView: UICollectionView!
    private var pageControl: UIPageControl!

    private(set) var dragManager: LCSpringboardDragManager!
    private var longPressGesture: UILongPressGestureRecognizer!
    /// Ends edit mode on a tap anywhere off an icon, as SpringBoard does.
    private var endEditingTapGesture: UITapGestureRecognizer!

    private var currentPage: Int = 0

    /// Set when a page was closed for being empty and the tightened layout
    /// still has to be written back. Flushed as soon as the view has the
    /// geometry to measure a page with.
    private var needsEmptyPageSync = false

    // MARK: - Layout config

    private(set) var itemsPerPage: Int = 15

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Self.current = self

        setupOuterCollectionView()
        setupPageControl()
        setupDragManager()
        // A pair made or broken, in Split View or from an icon's menu: its two
        // icons gain or lose the link and partner icon under their names.
        NotificationCenter.default.addObserver(self, selector: #selector(splitPairsChanged),
                                               name: FlekSplitPairStore.didChange, object: nil)
    }

    @objc private func splitPairsChanged() {
        refreshVisibleItems()
    }

    deinit {
        if Self.current === self { Self.current = nil }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Lock orientation to portrait while the springboard is visible.
        AppDelegate.orientationLock = .portrait
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        // When the view reappears (e.g. after a fullScreenCover is dismissed),
        // apply any items that were synced while we were hidden.
        if let pending = pendingItems {
            let currentIDs = flatItems.map(\.id)
            let pendingIDs = pending.map(\.id)
            if currentIDs != pendingIDs {
                updateItems(pending)
                // If the pending items include .installing, scroll to its page
                // (the original scroll-to-page may have been consumed behind the cover).
                if let idx = pending.firstIndex(where: { $0.id.hasPrefix("installing.") }) {
                    let page = pageForFlatIndex(idx)
                    if page < pages.count {
                        DispatchQueue.main.async { [weak self] in
                            self?.scrollToPage(page)
                        }
                    }
                }
            }
            pendingItems = nil
        }

        // Something that changed behind the cover without adding or removing a
        // tile — an app converted to shared — could not be drawn while the
        // cells were off-screen. Now they are back.
        refreshVisibleItems()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // The outer CV fills the view, so every icon a page lays out is inside
        // its bounds and receives tap events.
        let cvHeight = view.bounds.height

        outerCollectionView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: cvHeight)

        // Update flow layout item size to match collection view size
        if let layout = outerCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let newSize = CGSize(width: view.bounds.width, height: cvHeight)
            if layout.itemSize != newSize {
                layout.itemSize = newSize
                layout.invalidateLayout()
            }
        }

        // Page control overlays the bottom of the CV.
        let pageControlTopPadding: CGFloat = 4
        let pageControlHeight: CGFloat = 10
        pageControl.frame = CGRect(
            x: 0,
            y: cvHeight - pageControlHeight - pageControlTopPadding,
            width: view.bounds.width,
            height: pageControlHeight
        )
        // Recalculate items-per-page; re-paginate if it changed.
        let oldIPP = itemsPerPage
        recalculateItemsPerPage()
        if itemsPerPage != oldIPP && !flatItems.isEmpty {
            if paginateFromFlatItems() { needsEmptyPageSync = true }
            outerCollectionView.reloadData()
            pageControl.numberOfPages = pages.count
            // Restore scroll position after re-pagination
            if currentPage > 0 && currentPage < pages.count {
                let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(currentPage), y: 0)
                outerCollectionView.setContentOffset(offset, animated: false)
            }
        }

        // A page may have been closed before there was a page size to measure;
        // now there is one.
        flushEmptyPageSyncIfNeeded()
    }

    // MARK: - Setup

    private func setupOuterCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize = CGSize(width: view.bounds.width, height: view.bounds.height)

        outerCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        outerCollectionView.isPagingEnabled = true
        outerCollectionView.showsHorizontalScrollIndicator = false
        outerCollectionView.contentInsetAdjustmentBehavior = .never
        outerCollectionView.backgroundColor = .clear
        outerCollectionView.clipsToBounds = false
        outerCollectionView.register(LCSpringboardPageCell.self, forCellWithReuseIdentifier: "PageCell")
        outerCollectionView.dataSource = self
        outerCollectionView.delegate = self

        view.addSubview(outerCollectionView)
    }

    private func setupPageControl() {
        pageControl = UIPageControl()
        pageControl.currentPageIndicatorTintColor = .white
        pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.35)
        pageControl.backgroundStyle = .minimal
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = true
        pageControl.addTarget(self, action: #selector(pageControlTapped(_:)), for: .valueChanged)
        pageControl.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)

        view.addSubview(pageControl)
    }

    private func setupDragManager() {
        dragManager = LCSpringboardDragManager()
        dragManager.viewController = self

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3
        view.addGestureRecognizer(longPressGesture)

        endEditingTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEndEditingTap(_:)))
        endEditingTapGesture.cancelsTouchesInView = false
        endEditingTapGesture.delegate = self
        view.addGestureRecognizer(endEditingTapGesture)
    }

    // MARK: - Data update

    /// Called by the Representable when SwiftUI items genuinely change
    /// (items added or removed, NOT just reordered).
    func updateItems(_ newItems: [FlekHomeItem]) {
        let oldPageCount = pages.count
        flatItems = newItems
        recalculateItemsPerPage()
        let closedEmptyPages = paginateFromFlatItems()

        // In edit mode, preserve the trailing empty page so that the page
        // count stays stable after a deletion. Without this,
        // paginateFromFlatItems strips the empty page, causing a page-count
        // mismatch that forces a full reloadData (no smooth shift animation).
        if isInEditMode {
            if pages.last?.isEmpty != true {
                pages.append([])
            }
        }

        // If the page count is unchanged, update visible page cells in-place
        // instead of reloading the outer collection view (which destroys cells
        // and causes a visible flash, e.g. when an installing item is cancelled).
        if pages.count == oldPageCount {
            let visiblePageCells = outerCollectionView.visibleCells.compactMap { $0 as? LCSpringboardPageCell }
            if visiblePageCells.isEmpty {
                // View is off-screen (e.g. behind a fullScreenCover);
                // reload so cells pick up the new data when they appear.
                outerCollectionView.reloadData()
            } else {
                for pageCell in visiblePageCells {
                    guard let indexPath = outerCollectionView.indexPath(for: pageCell) else { continue }
                    let pageIndex = indexPath.item
                    guard pageIndex < pages.count else { continue }
                    pageCell.safeReloadItems(pages[pageIndex])
                }
            }
        } else {
            currentPage = max(0, min(currentPage, pages.count - 1))
            outerCollectionView.reloadData()
            // Preserve scroll position after page count change
            let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(currentPage), y: 0)
            outerCollectionView.setContentOffset(offset, animated: false)
        }
        pageControl.numberOfPages = pages.count
        pageControl.currentPage = min(currentPage, max(0, pages.count - 1))

        // The emptied page is gone from `pages`, but the persisted order still
        // holds the padding that made it a page. Write the tightened layout
        // back so the next rebuild doesn't hand the dead page straight back.
        if closedEmptyPages {
            needsEmptyPageSync = true
            flushEmptyPageSyncIfNeeded()
        }
    }

    /// Recalculate the `itemsPerPage` metric from the size of a page.
    ///
    /// A page is exactly the view: the padding that holds the grid off the top
    /// of the screen and clear of the dock is applied outside the springboard,
    /// so the rows that fit here are the rows the design has room for.
    private func recalculateItemsPerPage() {
        guard view.bounds.height > 0 else { return }
        itemsPerPage = LCSpringboardPageCell.itemsPerPage(forPageSize: view.bounds.size)
    }

    /// Flatten `pages` back into a single array, padding non-last pages
    /// with placeholders up to `itemsPerPage` so that page boundaries
    /// survive the round-trip through `persistHomeOrder` / `rebuildOrderedHomeItems`.
    func flatItemsPreservingPageBoundaries() -> [FlekHomeItem] {
        guard itemsPerPage > 0 else { return pages.flatMap { $0 } }
        var result: [FlekHomeItem] = []
        for (i, page) in pages.enumerated() {
            result.append(contentsOf: page)
            // Pad intermediate pages that are shorter than itemsPerPage
            if i < pages.count - 1 {
                let padding = max(0, itemsPerPage - page.count)
                for j in 0..<padding {
                    result.append(.placeholder("pad.\(i).\(j)"))
                }
            }
        }
        return result
    }

    /// Syncs the current page layout back to SwiftUI, persisting both the
    /// padded flat items and page sizes so that page boundaries survive
    /// through `rebuildOrderedHomeItems` and `paginateFromFlatItems`.
    func syncPagesToSwiftUI() {
        flatItems = flatItemsPreservingPageBoundaries()
        // Save page sizes matching the padded flat layout.
        // Non-last pages are padded to itemsPerPage (just like the flat
        // array), so paginateFromFlatItems splits items at the right
        // boundaries when reading these sizes back.
        var sizes: [Int] = []
        for (i, page) in pages.enumerated() {
            if i < pages.count - 1 {
                sizes.append(max(page.count, itemsPerPage))
            } else {
                sizes.append(page.count)
            }
        }
        while sizes.last == 0 { sizes.removeLast() }
        if !sizes.isEmpty {
            LCUtils.appGroupUserDefault.set(sizes, forKey: FlekDeckKeys.homeScreenPageSizes)
        }
        onReorder?(flatItems)
    }

    /// Distribute `flatItems` into pages.
    /// Uses stored per-page sizes when available so that custom page
    /// boundaries (from drag-and-drop reorder) are preserved. Falls back
    /// to uniform chunking by `itemsPerPage` when no sizes are stored.
    ///
    /// When items exist beyond the stored sizes (e.g. a newly installed app),
    /// the last page is filled up to `itemsPerPage` before a new page is
    /// created — matching real iOS SpringBoard behaviour.
    ///
    /// Returns whether any page was closed for being empty, so the caller can
    /// persist the tightened layout.
    @discardableResult
    private func paginateFromFlatItems() -> Bool {
        guard itemsPerPage > 0 else { return false }

        let storedSizes = LCUtils.appGroupUserDefault.array(
            forKey: FlekDeckKeys.homeScreenPageSizes
        ) as? [Int]

        var newPages: [[FlekHomeItem]] = []
        var offset = 0

        if let sizes = storedSizes, !sizes.isEmpty {
            for size in sizes where offset < flatItems.count {
                let count = min(size, flatItems.count - offset)
                newPages.append(Array(flatItems[offset..<(offset + count)]))
                offset += count
            }

            // Fill the last page up to itemsPerPage before creating new pages.
            // The last stored page size is the actual item count (not padded),
            // so there may be room for more items (e.g. a newly installed app).
            if !newPages.isEmpty && offset < flatItems.count {
                let lastPageCount = newPages[newPages.count - 1].count
                let room = itemsPerPage - lastPageCount
                if room > 0 {
                    let toAdd = min(room, flatItems.count - offset)
                    newPages[newPages.count - 1].append(
                        contentsOf: flatItems[offset..<(offset + toAdd)]
                    )
                    offset += toAdd
                }
            }
        }

        // Remaining items (beyond stored sizes + last-page fill, or no sizes stored)
        while offset < flatItems.count {
            let end = min(offset + itemsPerPage, flatItems.count)
            newPages.append(Array(flatItems[offset..<end]))
            offset = end
        }

        // Strip placeholder padding so the UIKit collection view only
        // contains real items. This matches jSpringBoard (which has no
        // placeholder concept) and ensures clean moveItem animations
        // during within-page rearrangement. Placeholders are re-added
        // by flatItemsPreservingPageBoundaries() when syncing back to
        // SwiftUI for persistence.
        for i in newPages.indices {
            newPages[i].removeAll(where: { $0.isPlaceholder })
        }
        if newPages.isEmpty {
            newPages = [[]]
        }
        pages = newPages

        // A page left with nothing on it after stripping is closed wherever it
        // sits, not only at the end: a screen the user emptied in the middle of
        // the deck goes away like any other.
        return removeEmptyPages()
    }

    // MARK: - Empty pages

    /// Closes every page holding nothing the user can see — no items, or only
    /// placeholder padding — wherever it sits in the deck, and keeps
    /// `currentPage` on the page being looked at. At least one page survives.
    ///
    /// Edit mode's trailing page is spared: it is the empty page an icon
    /// dragged past the end of the deck lands on, and it goes when editing does.
    ///
    /// Returns whether any page was closed.
    @discardableResult
    private func removeEmptyPages() -> Bool {
        let dropTargetPage = isInEditMode && pages.count > 1 ? pages.count - 1 : -1
        var survivors = pages.indices.filter { index in
            index == dropTargetPage || !pages[index].allSatisfy({ $0.isPlaceholder })
        }
        // A springboard with nothing on it at all still shows one page.
        if survivors.isEmpty { survivors = [0] }
        guard survivors.count < pages.count else { return false }

        pages = survivors.map { pages[$0] }
        // The user stays with the page they were looking at: it keeps its
        // icons, only its index moves down by the pages closed ahead of it.
        // When the page they were on is the one that closed, they land on the
        // page that slid into its place.
        currentPage = survivors.firstIndex(where: { $0 >= currentPage }) ?? pages.count - 1
        return true
    }

    /// Writes a layout tightened by `removeEmptyPages()` back to SwiftUI.
    ///
    /// Held until the view has been laid out: the sync records page sizes in
    /// terms of `itemsPerPage`, and with no geometry to measure a page with
    /// that is a guess, which would persist page boundaries the user never
    /// drew. Deferred by a turn either way — the caller is usually inside a
    /// SwiftUI update or a layout pass, and the sync writes to a binding.
    private func flushEmptyPageSyncIfNeeded() {
        guard needsEmptyPageSync, view.bounds.height > 0, !dragManager.isDragging else { return }
        needsEmptyPageSync = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.dragManager.isDragging else { return }
            self.syncPagesToSwiftUI()
        }
    }

    /// Closes a page a drag just emptied and persists the tightened layout.
    /// Called once the dropped icon has settled, so nothing moves out from
    /// under the slide-back animation.
    func collapseEmptyPagesAfterDrag() {
        guard !dragManager.isDragging, removeEmptyPages() else { return }

        outerCollectionView.reloadData()
        // The emptied page is behind the user — the drag scrolled them off it
        // to drop the icon — so re-pinning the offset to its new index leaves
        // the screen looking exactly as it did.
        let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(currentPage), y: 0)
        outerCollectionView.setContentOffset(offset, animated: false)
        pageControl.numberOfPages = pages.count
        pageControl.currentPage = currentPage

        syncPagesToSwiftUI()
    }

    // MARK: - Editing (matches jSpringBoard's enterEditingMode / leaveEditingMode)

    func setEditing(_ editing: Bool, fromDrag: Bool = false) {
        guard editing != isInEditMode else { return }
        isInEditMode = editing

        if editing {
            // Add a trailing empty page for reorder target
            // (jSpringBoard: items.append([]) + insertItems)
            if let last = pages.last, !last.isEmpty {
                pages.append([])
                outerCollectionView.insertItems(at: [IndexPath(item: pages.count - 1, section: 0)])
                pageControl.numberOfPages = pages.count
            }

            for cell in outerCollectionView.visibleCells {
                (cell as? LCSpringboardPageCell)?.enterEditingMode()
            }

            pageControl.backgroundStyle = .prominent
        } else {
            for cell in outerCollectionView.visibleCells {
                (cell as? LCSpringboardPageCell)?.leaveEditingMode()
            }

            pageControl.backgroundStyle = .minimal

            // Close the pages left empty, after edit animations settle.
            // Uses reloadData instead of deleteItems to avoid conflicts
            // with ongoing leaveEditingMode animations.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }

                // Editing is over, so the trailing drop target goes too.
                if self.removeEmptyPages() {
                    self.outerCollectionView.reloadData()
                    self.pageControl.numberOfPages = self.pages.count
                    self.pageControl.currentPage = self.currentPage
                    // Scroll to valid page
                    let offset = CGPoint(
                        x: self.outerCollectionView.bounds.width * CGFloat(self.currentPage),
                        y: 0
                    )
                    self.outerCollectionView.setContentOffset(offset, animated: true)
                }

                // Always sync page sizes and flat items back to SwiftUI
                // so page boundaries survive through persistence and rebuild.
                self.syncPagesToSwiftUI()
            }
        }

        onEditingChanged?(editing)
    }

    // MARK: - Page overflow (jSpringBoard's moveLastItem)

    /// Moves the last item from `pages[page]` to the front of `pages[page+1]`.
    /// Recurses if the next page overflows. Exactly matches jSpringBoard.
    func moveLastItem(inPage page: Int) {
        guard page + 1 < pages.count else { return }

        let item = pages[page].removeLast()
        pages[page + 1].insert(item, at: 0)

        if pages[page + 1].count > itemsPerPage {
            moveLastItem(inPage: page + 1)
        }
    }

    /// Applies any pending item changes that were deferred while dragging.
    func applyPendingItemsIfNeeded() {
        guard let pending = pendingItems else { return }
        let currentSet = Set(flatItems.map(\.id))
        let newSet = Set(pending.map(\.id))
        if currentSet != newSet {
            updateItems(pending)
        }
        pendingItems = nil
    }

    // MARK: - Install state update

    /// Updates install progress on visible installing cells without full reload.
    func updateInstallProgress() {
        for cell in outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            for iconCell in pageCell.collectionView.visibleCells {
                guard let ic = iconCell as? LCSpringboardIconCell else { continue }
                ic.updateInstallState()
            }
        }
    }

    /// Redraws what is on screen without touching pagination — for a change to
    /// the apps themselves rather than to which apps there are. Skipped mid-drag,
    /// where the cells are the drag's to arrange.
    ///
    /// Returns whether it reached any cells: behind a fullScreenCover there are
    /// none to reach, and the caller must not record the change as drawn.
    @discardableResult
    func refreshVisibleItems() -> Bool {
        guard !dragManager.isDragging else { return false }
        var refreshed = false
        for cell in outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            pageCell.refreshVisibleCells()
            refreshed = true
        }
        return refreshed
    }

    // MARK: - Scroll to page

    func scrollToPage(_ page: Int, animated: Bool = true) {
        guard page >= 0 && page < pages.count else { return }
        let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(page), y: 0)
        outerCollectionView.setContentOffset(offset, animated: animated)
    }

    // MARK: - Page index calculation

    /// Returns the page index for a flat-array position, using stored page
    /// sizes and filling the last page up to `itemsPerPage` — matching
    /// `paginateFromFlatItems()` exactly.
    func pageForFlatIndex(_ index: Int) -> Int {
        guard itemsPerPage > 0 else { return 0 }

        let sizes = LCUtils.appGroupUserDefault.array(
            forKey: FlekDeckKeys.homeScreenPageSizes
        ) as? [Int] ?? []

        if !sizes.isEmpty {
            var offset = 0
            for (page, size) in sizes.enumerated() {
                offset += size
                if index < offset { return page }
            }
            // Beyond stored sizes: the last page can still hold items
            // up to itemsPerPage (mirroring paginateFromFlatItems).
            let lastPageSize = sizes.last ?? 0
            let room = max(0, itemsPerPage - lastPageSize)
            let beyondStored = index - offset
            if beyondStored < room {
                return sizes.count - 1
            }
            // Truly new pages beyond the last stored page's capacity
            let beyondLastPage = beyondStored - room
            return sizes.count + beyondLastPage / itemsPerPage
        }

        return index / itemsPerPage
    }

    // MARK: - Helpers

    /// Returns the page cell and its index for a given point in the VC's view.
    func pageCellAtPoint(_ point: CGPoint) -> (pageIndex: Int, cell: LCSpringboardPageCell)? {
        let convertedPoint = view.convert(point, to: outerCollectionView)
        guard let indexPath = outerCollectionView.indexPathForItem(at: convertedPoint),
              let cell = outerCollectionView.cellForItem(at: indexPath) as? LCSpringboardPageCell else {
            // Fallback to current visible cell
            guard let visibleCell = outerCollectionView.visibleCells.first as? LCSpringboardPageCell,
                  let ip = outerCollectionView.indexPath(for: visibleCell) else { return nil }
            return (ip.item, visibleCell)
        }
        return (indexPath.item, cell)
    }

    /// Returns the visible page cell for a given page index (if currently on screen).
    func visiblePageCell(forPage page: Int) -> LCSpringboardPageCell? {
        let ip = IndexPath(item: page, section: 0)
        return outerCollectionView.cellForItem(at: ip) as? LCSpringboardPageCell
    }

    /// The icon cell for `itemID`, but only when the user can actually see it:
    /// the page it sits on is the one on screen.
    ///
    /// Having a cell is not the same as the cell being visible. A paging
    /// collection view keeps the neighbouring page loaded while it is off screen,
    /// so `cellForItem` answers for icons a page-width away in either direction —
    /// and an animation aimed at one of those flies sideways off the display.
    /// Callers that need somewhere to go when this returns nil should aim at
    /// something the user is looking at instead.
    ///
    /// The page is deliberately not scrolled to bring the icon into view: nobody
    /// asked for the home screen to change page, and doing it silently leaves the
    /// user somewhere they did not navigate to.
    func iconCell(forItemID itemID: String) -> LCSpringboardIconCell? {
        guard let position = position(ofItemID: itemID),
              position.page == pageOnScreen,
              let pageCell = visiblePageCell(forPage: position.page) else { return nil }

        // Force the page's grid through layout so the icon exists to be measured.
        pageCell.collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: position.index, section: 0)
        return pageCell.collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell
    }

    /// The page filling the screen, read from the scroll position rather than
    /// from `currentPage`, which only catches up once a scroll settles.
    private var pageOnScreen: Int {
        let width = outerCollectionView.bounds.width
        guard width > 0 else { return 0 }
        return Int((outerCollectionView.contentOffset.x / width).rounded())
    }

    /// Which page holds `itemID`, and where on it.
    private func position(ofItemID itemID: String) -> (page: Int, index: Int)? {
        for (page, items) in pages.enumerated() {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                return (page, index)
            }
        }
        return nil
    }

    // MARK: - Gesture handlers

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        dragManager.handleLongPress(gesture)
    }

    @objc private func pageControlTapped(_ sender: UIPageControl) {
        scrollToPage(sender.currentPage)
    }

    @objc private func handleEndEditingTap(_ gesture: UITapGestureRecognizer) {
        guard isInEditMode, !dragManager.isDragging else { return }
        setEditing(false)
    }
}

// MARK: - UIGestureRecognizerDelegate (tap off an icon ends editing)

extension LCSpringboardViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === endEditingTapGesture else { return true }
        guard isInEditMode, !dragManager.isDragging else { return false }

        // Icons, their delete buttons and the page dots keep their own taps;
        // only empty slots and the space around the grid end editing.
        var hit = touch.view
        while let view = hit, view !== self.view {
            if view is UIControl { return false }
            if let cell = view as? LCSpringboardIconCell { return cell.isPlaceholderCell }
            hit = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === endEditingTapGesture
    }
}

// MARK: - UICollectionViewDataSource

extension LCSpringboardViewController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PageCell", for: indexPath) as! LCSpringboardPageCell
        cell.items = pages[indexPath.item]
        cell.delegate = self
        cell.darkModeIcon = darkModeIcon
        cell.drawsGlass = drawsGlass
        cell.draggedItemId = dragManager.currentOperation?.itemId
        cell.collectionView.reloadData()

        if isInEditMode {
            cell.enterEditingMode()
        } else {
            cell.leaveEditingMode()
        }

        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension LCSpringboardViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let pageCell = cell as? LCSpringboardPageCell else { return }

        // If a drag is in progress and needs to adopt this page
        dragManager.adoptDragOnVisiblePage(pageCell, pageIndex: indexPath.item)

        pageCell.items = pages[indexPath.item]
        pageCell.draggedItemId = dragManager.currentOperation?.itemId
        pageCell.collectionView.reloadData()

        if isInEditMode {
            pageCell.enterEditingMode()
        } else {
            pageCell.leaveEditingMode()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Note: Do NOT call leaveEditingMode() here. When the user swipes
        // between pages during edit mode, leaveEditingMode() starts an animated
        // hide of delete buttons. If the page scrolls back into view before the
        // animation completes, the stale completion handler sets isHidden = true
        // after enterEditingMode() has already shown the buttons, causing them
        // to randomly disappear. The willDisplay/cellForItemAt callbacks already
        // handle restoring edit mode state correctly when pages reappear.
    }
}

// MARK: - UIScrollViewDelegate (page tracking)

extension LCSpringboardViewController: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.frame.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.frame.width))
        if page != currentPage && page >= 0 && page < pages.count {
            currentPage = page
            pageControl.currentPage = page
        }
    }
}

// MARK: - LCSpringboardPageCellDelegate

extension LCSpringboardViewController: LCSpringboardPageCellDelegate {

    func pageCell(_ pageCell: LCSpringboardPageCell, didTapItem item: FlekHomeItem) {
        guard !isInEditMode else { return }
        onTap?(item)
    }

    func pageCell(_ pageCell: LCSpringboardPageCell, didTapDeleteFor item: FlekHomeItem) {
        onDelete?(item)
    }

    func pageCell(_ pageCell: LCSpringboardPageCell, contextMenuFor item: FlekHomeItem) -> UIMenu? {
        return contextMenuProvider?(item)
    }
}
