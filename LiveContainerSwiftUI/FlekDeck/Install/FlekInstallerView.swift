//
//  FlekInstallerView.swift
//  LiveContainerSwiftUI
//
//  Redesigned Installer (reimagining of LiveContainer's Catalog). Reuses the
//  existing FlekstoreAppsListViewModel for fetching/paging/categories and the
//  saved-repositories store; only the UI is new:
//   - a horizontal source carousel (Telegram-style) + a "manage sources" button
//   - a category switcher (FlekSt0re source only)
//   - app rows with a download button
//   - a bottom bar with Import IPA, a back-to-home chevron, and search
//
//  Installs are triggered through LCInstallQueue.shared so multiple downloads
//  can run concurrently while installs run serially.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Kingfisher
import QuartzCore

extension Notification.Name {
    /// An app page is waiting in `FlekInstallerView.pendingDetailRequest` for an
    /// installer that is already open to pick up.
    static let flekInstallerOpenAppDetail = Notification.Name("FlekInstallerOpenAppDetail")
    /// A URL or URL scheme the Installer was given to open, for the home
    /// screen to open: it is what launches apps and has the browser. The
    /// object is the text as typed.
    static let flekOpenURL = Notification.Name("FlekOpenURL")
}

struct FlekInstallerView: View {
    var preselectFlekstore: Bool
    var preselectRepoURL: String? = nil
    var onClose: () -> Void

    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var installQueue = LCInstallQueue.shared
    @StateObject private var viewModel = FlekstoreAppsListViewModel()
    @StateObject private var repoSearch = MultiRepoSearchModel()

    @State private var repos: [AppRepository] = []
    @State private var selectedRepoID: UUID?
    @State private var showSources = false
    /// The app whose page is open, if any.
    @State private var detailTarget: DetailTarget?
    @State private var searchActive = false
    @State private var importURLInput = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var importUrlHelper = InputHelper()
    /// Asks for a URL or URL scheme to open, as LiveContainer's link button did.
    @StateObject private var openURLHelper = InputHelper()
    @State private var choosingIPA = false
    /// Counts source switches, so that a slow one is not finished after a later one.
    @State private var switchCount = 0
    @State private var switcherBarVisible = true
    @State private var barIsLandscape = false
    /// Bumped to (re)center the selected repo in the pill after the sources
    /// sheet is dismissed, so the shift animation plays once it's visible.
    @State private var pillRecenterNonce = 0
    /// Measured width of the manage-sources button, used to end the carousel
    /// exactly at the button's leading edge (so repos can't scroll under it).
    @State private var manageButtonWidth: CGFloat = 0
    /// Measured height of the install tray, so the app list can scroll clear of it.
    @State private var trayHeight: CGFloat = 0
    /// How far the app list has been pulled sideways by a swipe between sources.
    @State private var sourceSwipeOffset: CGFloat = 0
    /// Set while a finger is swiping the list sideways.
    @State private var sourceSwipeDragging = false
    /// Set while a swiped-to source slides in, so a new swipe waits for it.
    @State private var sourceSwipeSettling = false
    /// Set from the start of a swipe until its page has come to rest, so the
    /// sources beside it stay drawn while it springs back.
    @State private var sourceSwipeInFlight = false
    /// Held from the moment a drag reads as a swipe until just after it ends,
    /// so letting go over a row doesn't also open or download that app.
    @State private var sourceSwipeBlocksTaps = false
    /// The catalogs of the sources either side of the one shown, by source
    /// address, drawn beside the list while it is swiped.
    @State private var neighbourCatalogs: [String: [FSAppModel]] = [:]
    /// Width of the list, which a swipe is measured against.
    @State private var contentWidth: CGFloat = 0

    /// The bottom bar/blur only need to make room when the switcher bar actually
    /// sits along the bottom edge — i.e. portrait. In landscape the bar is on the
    /// right edge, so bottom content stays pinned to the bottom edge.
    private var barOccupiesBottom: Bool { switcherBarVisible && !barIsLandscape }

    /// How far the bottom bar sits from the edge.
    ///
    /// With the switcher bar below it the controls are lifted clear of it. Otherwise
    /// they are pulled back down into the home-indicator inset, leaving a 2pt margin
    /// above the screen edge — but only as far as that inset actually reaches. A phone
    /// with a physical home button has no bottom inset at all, and the fixed -18 that
    /// used to be here pushed the buttons off the bottom of the screen.
    private var bottomBarInset: CGFloat {
        if barOccupiesBottom { return 12 }
        // Where there is a home-indicator inset, sink into it and leave a 2pt margin.
        // Where there isn't one there is nothing to sink into, so add a margin instead
        // of letting the controls sit flush against the screen edge.
        let sinkable = max(bottomSafeInset - 2, 0)
        return sinkable > 0 ? -min(18, sinkable) : 10
    }

    /// An app whose page the user opened, tagged with the source it came from.
    /// A custom repo's `app_id` is only its index in that repo's catalog, so the
    /// flag has to travel with it — it must never be spent on FlekSt0re's
    /// detail endpoint, which would return an unrelated app.
    struct DetailTarget: Identifiable {
        let app: FSAppModel
        let isFlekstore: Bool
        var id: String { "\(isFlekstore)|\(app.app_id)|\(app.install_url)" }
    }

    /// An app page asked for from outside the installer — a result tapped, rather
    /// than downloaded, in the springboard's search.
    struct DetailRequest {
        /// The source the result came from, so the installer lands on it.
        let repoURL: String
        let app: FSAppModel
        let isFlekstore: Bool
    }

    /// The page waiting to be opened, if any.
    ///
    /// Handed over here rather than only as a parameter because the installer may
    /// already be open: the dock hands that page back to the front instead of
    /// building a new one, so its `task` never runs a second time. A fresh page
    /// drains this on appearance; one already on screen drains it when
    /// `.flekInstallerOpenAppDetail` says something is waiting.
    static var pendingDetailRequest: DetailRequest?

    /// Repo selected during this app session. A static resets on process
    /// relaunch, so the installer defaults back to FlekSt0re after an app
    /// restart while still remembering the choice within a session.
    private static var sessionSelectedRepoURL: String?

    /// The device's own bottom safe-area inset — the home indicator, if there is one.
    ///
    /// Read from the window rather than a GeometryReader: a reader placed under
    /// `ignoresSafeArea` reports zero insets on every device, and the window's value
    /// also excludes the `additionalSafeAreaInsets` the host adds for the switcher
    /// bar, which is what we want here.
    @State private var bottomSafeInset: CGFloat = LCDeviceSafeArea.bottomInset()

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)
    private static let screenBG = Color(.systemGroupedBackground)

    var body: some View {
        ZStack {
            Self.screenBG.ignoresSafeArea()

            // App list fills the whole area and scrolls *behind* the bars,
            // which float on top with transparent backgrounds.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Every swap between the mutually exclusive states below
                // (catalog / search / spinner / error) crossfades instead of
                // cutting. Keyed on the state itself so nothing else in the list
                // — row inserts, pagination — gets dragged into the animation.
                .animation(Self.crossfade, value: contentState)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { contentWidth = geo.size.width }
                        .onChange(of: geo.size.width) { contentWidth = $0 }
                })
                // The whole page answers a swipe, blank space included — the
                // error page has little else to take hold of.
                .contentShape(Rectangle())
                // Swiping the list sideways moves to the previous or next source,
                // the way pages turn elsewhere in iOS.
                .offset(x: sourceSwipeOffset)
                .overlay { neighbourPages }
                .modifier(FlekSourceSwipeGesture(
                    isEnabled: !searchActive && !viewModel.isBanned && !sourceSwipeSettling,
                    onBegan: sourceSwipeBegan,
                    onChanged: sourceSwipeChanged,
                    onEnded: sourceSwipeEnded))

            // Top-edge blur: sits above the list but below the bars so the
            // content fades out as it scrolls up under the pill/category bar.
            topEdgeBlur

            VStack(spacing: 0) {
                // Hide the top bars while searching by fading them out rather than
                // removing them from the hierarchy. Structurally tearing down the
                // source carousel's ScrollViewReader at the same moment the search
                // field takes focus was dropping the keyboard's first responder, so
                // typed text never registered. Kept mounted + non-interactive, the
                // focus stays put.
                Group {
                    sourceCarousel
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    // Swiping toward FlekSt0re, its categories come up with it.
                    if viewModel.repository == .flekstore || swipeTargetRepo.map(Self.isFlekstore) == true {
                        categoryBar.padding(.top, 8)
                            .opacity(categoryBarOpacity)
                            .allowsHitTesting(viewModel.repository == .flekstore)
                    }
                }
                .opacity(searchActive ? 0 : 1)
                // Lift and shrink a touch on the way out so the bars read as
                // receding behind the search field rather than blinking off.
                .scaleEffect(searchActive && !reduceMotion ? 0.96 : 1, anchor: .top)
                .offset(y: searchActive && !reduceMotion ? -10 : 0)
                .allowsHitTesting(!searchActive)
                .animation(searchMotion, value: searchActive)

                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    installTray
                    bottomBar
                }
                .padding(.horizontal, 10)
                .padding(.bottom, bottomBarInset)
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: installQueue.manualItems.count)
            }
        }
        .onPreferenceChange(InstallTrayHeightKey.self) { trayHeight = $0 }
        // A switch has gone through: the list left behind is now kept in memory,
        // ready to be swiped back to.
        .onChange(of: viewModel.repository) { _ in
            loadNeighbourCatalogs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .multitaskBarVisibilityChanged)) { _ in
            // Animate the bottom bar / blur shift in sync with the switcher bar's
            // slide (same easing + duration) instead of snapping.
            withAnimation(.easeInOut(duration: 0.2)) {
                updateSwitcherBarState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Same rule as the dock: face-up and face-down say nothing about how
            // the page is being read, so re-deriving the bar's layout from one
            // only reintroduces whatever its fallbacks answer.
            guard UIDevice.current.orientation.isValidInterfaceOrientation else { return }
            updateSwitcherBarState()
        }
        // Folding or unfolding an iPhone Duo moves the bar without turning the
        // device, and the height class is what the bar's edge follows.
        .onChange(of: verticalSizeClass) { _ in
            updateSwitcherBarState()
        }
        .onAppear {
            updateSwitcherBarState()
        }
        .task {
            repoSearch.setup()
            repos = Self.loadRepos()
            if let repoURL = preselectRepoURL, let match = repos.first(where: { $0.sourceURL == repoURL }) {
                selectedRepoID = match.id
                viewModel.repository = Self.source(for: match)
            } else if preselectFlekstore, let flek = repos.first(where: { Self.isFlekstore($0) }) {
                selectedRepoID = flek.id
                viewModel.repository = .flekstore
            } else if let sessionURL = Self.sessionSelectedRepoURL,
                      let match = repos.first(where: { $0.sourceURL == sessionURL }) {
                // Remember the pick within this app session only.
                selectedRepoID = match.id
                viewModel.repository = Self.source(for: match)
            } else if let flek = repos.first(where: { Self.isFlekstore($0) }) {
                // Fresh launch (or nothing to restore): default to FlekSt0re.
                selectedRepoID = flek.id
                viewModel.repository = .flekstore
            } else {
                viewModel.repository = .flekstore
            }
            // A page asked for from outside opens as soon as this one has finished
            // arriving, rather than waiting on the catalog loading behind it.
            if Self.pendingDetailRequest != nil {
                Task { await openPendingDetail(afterPresentation: true) }
            }
            // Premium's check runs beside the catalog's load, which would
            // otherwise wait on it with an empty page.
            async let subscription: Void = viewModel.refreshSubscriptionStatus()
            await viewModel.resetAndFetchApps()
            await subscription
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flekInstallerOpenAppDetail)) { _ in
            // This page was already open, so it was handed back to the front
            // rather than rebuilt — nothing else would pick the request up.
            Task { await openPendingDetail(afterPresentation: false) }
        }
        .sheet(isPresented: $showSources, onDismiss: {
            // AppRepository.id is a fresh UUID on every decode, so reloading
            // from disk renumbers the repos. Re-anchor the selection on the
            // stable sourceURL so the pill highlight survives the reload.
            let selectedURL = repos.first(where: { $0.id == selectedRepoID })?.sourceURL
            repos = Self.loadRepos()
            if let selectedURL, let match = repos.first(where: { $0.sourceURL == selectedURL }) {
                selectedRepoID = match.id
            }
            // The source shown was removed: FlekSt0re, rather than its apps
            // under no pill, still there to refresh and install.
            if case .custom(let shownURL) = viewModel.repository,
               !repos.contains(where: { $0.sourceURL == shownURL }),
               let flekstore = repos.first(where: { Self.isFlekstore($0) }) {
                selectedRepoID = flekstore.id
                Task { await switchTo(flekstore) }
            }
            // The sources may have been reordered, so the neighbours with them.
            loadNeighbourCatalogs()
            // Let the sheet finish dismissing and repos reload before scrolling
            // so the centering animation is actually visible in the pill.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pillRecenterNonce += 1
            }
        }) {
            FlekSourcesPopup(repos: $repos) { repo in
                selectedRepoID = repo.id
                Task { await switchTo(repo) }
            }
        }
        .sheet(item: $detailTarget) { target in
            FlekAppDetailSheet(
                app: target.app,
                isFlekstore: target.isFlekstore,
                accent: Self.flekBlue,
                onInstall: { overrides in
                    enqueueInstall(target.app, fromFlekstore: target.isFlekstore, overrides: overrides)
                }
            )
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            if let u = urls.first {
                LCInstallQueue.shared.enqueue(
                    url: u.absoluteString,
                    name: Self.importName(from: u.absoluteString),
                    iconURL: nil,
                    isManual: true
                )
            }
        }, onDismiss: { choosingIPA = false })
        .textFieldAlert(
            isPresented: $importUrlHelper.show,
            title: "lc.appList.installUrlInputTip".loc,
            text: $importUrlHelper.initVal,
            placeholder: "https://",
            action: { newText in
                importUrlHelper.close(result: newText)
                let t = (newText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                // A link to a manifest rather than an IPA, which the home
                // screen resolves, as it does one opened with Open URL.
                if t.lowercased().hasPrefix("itms-services:") {
                    NotificationCenter.default.post(name: .flekOpenURL, object: t)
                    onClose()
                    return
                }
                LCInstallQueue.shared.enqueue(
                    url: t,
                    name: Self.importName(from: t),
                    iconURL: nil,
                    isManual: true
                )
            },
            actionCancel: { _ in importUrlHelper.close(result: nil) }
        )
        .textFieldAlert(
            isPresented: $openURLHelper.show,
            title: "lc.appList.enterUrlTip".loc,
            text: $openURLHelper.initVal,
            placeholder: "scheme://",
            action: { newText in
                openURLHelper.close(result: newText)
                let link = (newText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !link.isEmpty else { return }
                // Handed on before the Installer goes, so that the home screen,
                // which opens it, knows to wait for it to have gone.
                NotificationCenter.default.post(name: .flekOpenURL, object: link)
                onClose()
            },
            actionCancel: { _ in openURLHelper.close(result: nil) }
        )
    }

    // MARK: Motion

    /// Crossfade used whenever one full-screen state replaces another. Short and
    /// linear-ish: the eye reads it as the content settling, not as a move.
    private static let crossfade: Animation = .easeInOut(duration: 0.25)

    /// The search open/close choreography — bars receding, field expanding, icon
    /// morphing — all run on this one curve so they read as a single gesture.
    /// Reduce Motion gets the same timing without the travel.
    private var searchMotion: Animation {
        reduceMotion ? .easeInOut(duration: 0.22) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    /// Which of the mutually exclusive full-screen states is showing. Mirrors the
    /// branches of `content` exactly, and is what the crossfade is keyed on.
    private enum ContentState: Equatable { case blocked, search, loading, error, list }

    private var contentState: ContentState {
        if viewModel.isBanned { return .blocked }
        if searchActive { return .search }
        if viewModel.apps.isEmpty && viewModel.isLoading { return .loading }
        if viewModel.errorMessage != nil && viewModel.apps.isEmpty { return .error }
        return .list
    }

    /// The stages a search passes through. Kept explicit so the gap between a
    /// keystroke and its results is `.loading` rather than `.empty` — deriving
    /// "nothing found" from an empty result set alone flashes that message every
    /// time the user types another character.
    private enum SearchState: Equatable { case idle, loading, empty, results }

    private var searchState: SearchState {
        if viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .idle }
        if !repoSearch.sections.isEmpty { return .results }
        return repoSearch.isLoading ? .loading : .empty
    }

    /// Distance from the top safe-area edge down to the bottom of the floating
    /// bars (source pill + category bar when shown).
    private var barsBottomInset: CGFloat {
        // During search both floating top bars (source pill + category bar) are
        // hidden, so reserve only a small top margin for the results list.
        guard !searchActive else { return 8 }
        var inset: CGFloat = 8 + 52          // pill top padding + pill height
        if viewModel.repository == .flekstore {
            inset += 8 + 44                  // category bar top padding + height
        }
        return inset
    }

    /// Height reserved at the top so the first list row starts just below the
    /// floating bars, which overlay the scrolling list instead of pushing it down.
    private var barsTopInset: CGFloat {
        barsBottomInset + (searchActive ? 10 : Self.listGap(isFlekstore: viewModel.repository == .flekstore))
    }

    /// The gap between the bars and the first row of a source's list. On the
    /// iPhone Duo the top blur reaches a few points further into a list that
    /// starts right under the source pills, so such a list starts that much
    /// lower there. FlekSt0re's, under its category bar, is clear of it.
    private static func listGap(isFlekstore: Bool) -> CGFloat {
        10 + (FlekDeviceModel.isDuo && !isFlekstore ? 7 : 0)
    }

    /// Room at the bottom of the list for the floating bottom bar, plus the
    /// install tray when it's up, so the last row can still be scrolled clear.
    private var listBottomInset: CGFloat { 80 + (trayHeight > 0 ? trayHeight + 10 : 0) }

    /// Progressive blur from the very top edge of the screen (through the safe
    /// area) down to the bottom of the category bar — strongest at the top,
    /// easing to clear for an organic falloff. Material + gradient-alpha mask
    /// (the pre-iOS-26 native approach, matching the bottom blur in this view).
    /// iOS 26 could instead use `scrollEdgeEffectStyle(.soft, for: .top)`.
    private var topEdgeBlur: some View {
        GeometryReader { geo in
            // During search the floating bars are hidden, so the blur only needs
            // to cover the status-bar strip — dropping the 50pt falloff keeps it
            // from frosting the first repository section header in the results.
            let falloff: CGFloat = searchActive ? 15 : 50
            let total = max(geo.safeAreaInsets.top + blurBarsInset + falloff, 1)
            // Real progressive blur: radius ramps from strong at the top edge to
            // none ~50pt below the bottom of the category bar.
            VariableBlurView(maxBlurRadius: searchActive ? 15 : 20, direction: .top)
                .frame(height: total)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        // Shrink the blur band in step with the bars it was covering, instead of
        // snapping to the shorter search-mode band.
        .animation(Self.crossfade, value: searchActive)
    }

    // MARK: Source carousel

    private var sourceCarousel: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(repos) { repo in
                            let selected = repo.id == selectedRepoID
                            Button {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                    selectedRepoID = repo.id
                                }
                                Task { await switchTo(repo) }
                            } label: {
                                HStack(spacing: 10) {
                                    FlekRemoteIcon(url: repo.iconUrl, size: 30, corner: 10)
                                    Text(repo.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .tracking(-0.23)
                                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.9))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .repoChipSelection(selected)
                            }
                            .buttonStyle(.plain)
                            .id(repo.id)
                        }
                    }
                    .padding(4)
                }
                // End the scrollable area at the button's leading edge, so repos
                // stop right before the button instead of scrolling under it.
                .padding(.trailing, manageButtonWidth)

                // Progressive blur behind the manage-sources button: the same
                // variable blur used on the installer's top/bottom edges, here
                // horizontal — strongest at the right edge, fading to clear on the
                // left. Sits above the scrolling carousel but below the icon.
                VariableBlurView(maxBlurRadius: 9, direction: .trailing)
                    .frame(width: 64, height: 52)
                    .allowsHitTesting(false)

                // Manage-sources icon pinned to the right, sitting on the blur
                // (no opaque background) so the carousel frosts out beneath it.
                Button {
                    showSources = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        // Smaller left margin, original right margin / full height.
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Measure the button's width (invisibly) so the carousel can inset
                // its trailing edge by exactly this much.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ManageButtonWidthKey.self, value: geo.size.width)
                    }
                )
            }
            .frame(height: 52)
            .onPreferenceChange(ManageButtonWidthKey.self) { manageButtonWidth = $0 }
            .repoPillGlass()
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
            // Center the tapped repo (skip while the sources sheet is open so the
            // move plays *after* dismissal instead of behind the sheet).
            .onChange(of: selectedRepoID) { id in
                loadNeighbourCatalogs()
                guard let id, !showSources else { return }
                centerSelectedRepo(id, proxy: proxy)
            }
            // Fired after the sources sheet closes: replay the shift for a repo
            // chosen from the manage-sources menu.
            .onChange(of: pillRecenterNonce) { _ in
                guard let id = selectedRepoID else { return }
                centerSelectedRepo(id, proxy: proxy)
            }
        }
    }

    // MARK: Source swipe

    /// The source whose list is on screen. Not `selectedRepoID`, which the pill
    /// moves to as soon as a swipe is let go, before the new list is in.
    private var shownRepoIndex: Int? {
        repos.firstIndex(where: { Self.source(for: $0) == viewModel.repository })
            ?? repos.firstIndex(where: { $0.id == selectedRepoID })
    }

    /// The source beside the one shown on the side a swipe moves toward:
    /// a swipe to the left brings in the next source, to the right the previous.
    private func neighbourRepo(swipingLeft: Bool) -> AppRepository? {
        guard let index = shownRepoIndex else { return nil }
        let target = swipingLeft ? index + 1 : index - 1
        return repos.indices.contains(target) ? repos[target] : nil
    }

    /// The source the list is being swiped toward.
    private var swipeTargetRepo: AppRepository? {
        guard sourceSwipeOffset != 0 else { return nil }
        return neighbourRepo(swipingLeft: sourceSwipeOffset < 0)
    }

    /// How far the swipe has gone, as a share of the page.
    private var sourceSwipeProgress: Double {
        min(1, abs(sourceSwipeOffset) / max(contentWidth, 1))
    }

    /// FlekSt0re's category bar fades with the swipe: out on the way to another
    /// source, in on the way back to FlekSt0re.
    private var categoryBarOpacity: Double {
        guard let target = swipeTargetRepo else { return 1 }
        let leavingFlekstore = viewModel.repository == .flekstore
        if leavingFlekstore == Self.isFlekstore(target) { return 1 }
        return leavingFlekstore ? 1 - sourceSwipeProgress : sourceSwipeProgress
    }

    /// The bottom of the bars as the top blur follows it: through a swipe to or
    /// from FlekSt0re, part way between with and without its category bar.
    private var blurBarsInset: CGFloat {
        guard !searchActive else { return barsBottomInset }
        let categoryBarShown = viewModel.repository == .flekstore
            || swipeTargetRepo.map(Self.isFlekstore) == true
        return 8 + 52 + (categoryBarShown ? (8 + 44) * categoryBarOpacity : 0)
    }

    private static func sourceKey(_ source: FlekstoreAppsListViewModel.RepositorySource) -> String {
        switch source {
        case .flekstore: return "flekstore"
        case .custom(let url): return url
        }
    }

    /// The sources either side, carried along beside the list as it is
    /// swiped, so the next one is already there to be pulled into view.
    @ViewBuilder
    private var neighbourPages: some View {
        ZStack {
            if sourceSwipeInFlight {
                if let previous = neighbourRepo(swipingLeft: false) {
                    sourcePreview(previous).offset(x: sourceSwipeOffset - contentWidth)
                }
                if let next = neighbourRepo(swipingLeft: true) {
                    sourcePreview(next).offset(x: sourceSwipeOffset + contentWidth)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A source's list as it will look once it is shown.
    private func sourcePreview(_ repo: AppRepository) -> some View {
        let apps = neighbourCatalogs[repo.sourceURL] ?? []
        // The category bar comes with FlekSt0re, so its list starts lower.
        let isFlekstore = Self.isFlekstore(repo)
        let topInset: CGFloat = 8 + 52 + (isFlekstore ? 8 + 44 : 0) + Self.listGap(isFlekstore: isFlekstore)
        return FlekSourcePreviewPage(apps: Array(apps.prefix(Self.previewRowCount)),
                                     topInset: topInset,
                                     accent: Self.flekBlue,
                                     placeholderRows: Self.skeletonRowCount)
            .equatable()
    }

    /// Enough rows to fill a screen while a preview is in view.
    private static let previewRowCount = 12

    /// Gathers the catalogs of the sources either side of the one shown, so a
    /// swipe has them to show from its first point of movement.
    private func loadNeighbourCatalogs() {
        let neighbours = [neighbourRepo(swipingLeft: false), neighbourRepo(swipingLeft: true)].compactMap { $0 }
        let wanted = Set(neighbours.map(\.sourceURL))
        neighbourCatalogs = neighbourCatalogs.filter { wanted.contains($0.key) }
        for repo in neighbours {
            let source = Self.source(for: repo)
            if let kept = viewModel.cachedApps(for: source) {
                neighbourCatalogs[repo.sourceURL] = kept
            } else if case .custom(let url) = source {
                Task {
                    var catalog = await Task.detached(priority: .utility) {
                        RepoCatalogCache.shared.cachedApps(for: url)
                    }.value
                    // Never fetched: fetched now, ahead of a swipe to it, rather
                    // than loaded once the swipe has landed.
                    let failedLately = await RepoCatalogLoader.shared.hasFailedRecently(url)
                    if catalog == nil && !failedLately {
                        catalog = await RepoCatalogLoader.shared.catalog(for: url)
                    }
                    if let catalog { neighbourCatalogs[url] = catalog }
                }
            } else {
                // FlekSt0re, not shown yet: its first page is fetched ahead too.
                let key = repo.sourceURL
                Task {
                    if let apps = await viewModel.keepFlekstoreFirstPage() { neighbourCatalogs[key] = apps }
                }
            }
        }
    }

    private func sourceSwipeBegan() {
        sourceSwipeDragging = true
        sourceSwipeBlocksTaps = true
        sourceSwipeInFlight = true
    }

    private func sourceSwipeChanged(_ translation: CGFloat) {
        // With no source on that side the list only gives a little, like a
        // scroll view pulled past its end.
        let offset = neighbourRepo(swipingLeft: translation < 0) == nil ? rubberBand(translation) : translation
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { sourceSwipeOffset = offset }
    }

    /// `velocity` is the finger's, in points a second, as it lifted.
    private func sourceSwipeEnded(_ translation: CGFloat, velocity: CGFloat) {
        sourceSwipeDragging = false
        // The row under the finger hears the lift too, right about now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !sourceSwipeDragging { sourceSwipeBlocksTaps = false }
        }
        let dx = sourceSwipeOffset
        let width = max(contentWidth, 1)
        // Flicked, or let go past halfway: the page turns. Flicking back the
        // other way cancels it however far it went, as in iOS.
        let swipingLeft = dx < 0
        let flicking = abs(velocity) > 450
        let flickedBack = flicking && (velocity < 0) != swipingLeft
        if let repo = neighbourRepo(swipingLeft: swipingLeft), !flickedBack,
           flicking || abs(dx) > width * 0.5 {
            turnToSource(repo, swipingLeft: swipingLeft, width: width, speed: abs(velocity))
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                sourceSwipeOffset = 0
            }
            // Back at rest, unless another swipe has taken it up since.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !sourceSwipeDragging && !sourceSwipeSettling {
                    sourceSwipeInFlight = false
                }
            }
        }
    }

    /// Carries the swipe on until the new source's page fills the screen, and
    /// there hands over from its preview to the real list, unseen.
    private func turnToSource(_ repo: AppRepository, swipingLeft: Bool, width: CGFloat, speed: CGFloat) {
        sourceSwipeSettling = true
        // The pill goes ahead to the new source as the page is let go.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            selectedRepoID = repo.id
        }

        let target = swipingLeft ? -width : width
        let remaining = abs(target - sourceSwipeOffset)
        // The curve sets off at twice its average pace and eases to a stop, so
        // timed by the finger's speed the page leaves at that speed.
        let duration = min(max(Double(2 * remaining / max(speed, 1)), 0.2), 0.38)
        withAnimation(.timingCurve(0.25, 0.5, 0.5, 1, duration: duration)) {
            sourceSwipeOffset = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) {
            // The list takes the place of the preview in the same frame, with
            // the rows the preview drew, so nothing moves or fades — and stays
            // as it is, with no refresh coming in after to change it.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            var shown: FlekstoreAppsListViewModel.ShownRepository?
            withTransaction(transaction) {
                sourceSwipeOffset = 0
                sourceSwipeInFlight = false
                // A pill tapped while the page slid has the last word.
                guard selectedRepoID == repo.id else { return }
                if searchActive { closeSearch() }
                Self.sessionSelectedRepoURL = repo.sourceURL
                switchCount &+= 1
                shown = viewModel.showRepository(Self.source(for: repo),
                                                 preloaded: neighbourCatalogs[repo.sourceURL],
                                                 inPlace: true)
            }
            sourceSwipeSettling = false
            if let shown {
                Task { await viewModel.loadShownRepository(shown) }
            }
        }
    }

    /// UIScrollView's resistance past its end: the further it is pulled, the
    /// less it follows, never quite reaching the width.
    private func rubberBand(_ offset: CGFloat) -> CGFloat {
        let width = max(contentWidth, 1)
        let pulled = (1 - 1 / (abs(offset) * 0.55 / width + 1)) * width
        return offset < 0 ? -pulled : pulled
    }

    private func centerSelectedRepo(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: Category bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill("Updates", selected: viewModel.selectedCategoryID == nil) { viewModel.selectCategory(nil) }
                categoryPill("Top", selected: viewModel.selectedCategoryID == "downloads") { viewModel.selectCategory("downloads") }
                ForEach(viewModel.categories) { cat in
                    categoryPill(cat.name, selected: viewModel.selectedCategoryID == cat.id) { viewModel.selectCategory(cat.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
        .scrollClipDisabledIfAvailable()  // let each pill's shadow draw past the 44pt scroll bounds (no bottom cutout)
        .clippedAtVerticalBar()
    }

    private func categoryPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Self.flekBlue : Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)  // subtle per-pill contact shadow (kept tight so neighbours don't bleed)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isBanned {
            AccessBlockedView(reason: viewModel.banReason, message: viewModel.banMessage)
                .frame(maxHeight: .infinity)
        } else if searchActive {
            searchContent
        } else if viewModel.apps.isEmpty && viewModel.isLoading {
            skeletonList
                .transition(.opacity)
        } else if let error = viewModel.errorMessage, viewModel.apps.isEmpty {
            loadFailed(error)
                // Recedes as the placeholders come up under it, rather than the
                // two simply swapping.
                .transition(reduceMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.94)))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(viewModel.visibleApps.enumerated()), id: \.element.id) { index, app in
                        FlekInstallerRow(
                            app: app,
                            accent: Self.flekBlue,
                            installState: LCInstallQueue.shared.item(for: app.install_url)?.installState,
                            isCompleted: LCInstallQueue.shared.completedURLs.contains(app.install_url),
                            onInstall: { guard !sourceSwipeBlocksTaps else { return }; install(app) },
                            onCancel: {
                                guard !sourceSwipeBlocksTaps else { return }
                                LCInstallQueue.shared.cancel(url: app.install_url)
                            },
                            onOpen: {
                                guard !sourceSwipeBlocksTaps else { return }
                                detailTarget = DetailTarget(app: app,
                                                            isFlekstore: viewModel.repository == .flekstore)
                            }
                        )
                        .rowEntrance(index: index - viewModel.appsBatchStart, batchStamp: viewModel.appsStamp)
                        .onAppear {
                            if app.id == viewModel.visibleApps.last?.id {
                                Task { await viewModel.fetchApps() }
                            }
                        }
                    }
                    if viewModel.isLoading && !viewModel.apps.isEmpty {
                        // Next page on its way — show what is coming, in place.
                        ForEach(0 ..< 2, id: \.self) { index in
                            FlekInstallerSkeletonRow(seed: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, listBottomInset)
            }
            // Inset the scroll view rather than padding its content, so the
            // pull-to-refresh spinner is dragged down into the gap *below* the
            // floating bars. Padding leaves it pinned to the screen edge, hidden
            // behind the pill and its blur, and the pull looks like it did nothing.
            // Non-interactive so a drag starting up here still scrolls the list.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: barsTopInset)
                    .allowsHitTesting(false)
            }
            .refreshable { await refreshCatalog() }
            .id(Self.sourceKey(viewModel.repository))
        }
    }

    /// Shown when the first page couldn't be fetched. Built to the same shape as
    /// the "nothing found" state — a bare line of red text next to a full list of
    /// placeholders had nothing to transition between.
    private func loadFailed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color(.systemGray3))

            Text(message)
                .font(.system(size: 17))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.resetAndFetchApps() }
            } label: {
                Text("lc.flek.retry".loc)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.flekBlue)
                    .padding(.horizontal, 24)
                    .frame(height: 42)
                    .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Placeholder rows filling the list while the first page loads. Laid out
    /// with the list's own insets and spacing, so the real rows crossfade in
    /// where the placeholders already were.
    private var skeletonList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0 ..< Self.skeletonRowCount, id: \.self) { index in
                    FlekInstallerSkeletonRow(seed: index)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, barsTopInset)
            .padding(.bottom, listBottomInset)
        }
        .scrollDisabledIfAvailable()
    }

    /// Enough to fill a phone screen and hint at more below it.
    private static let skeletonRowCount = 8

    /// Pull-to-refresh for the catalog.
    ///
    /// The rows stay on screen for the whole request — see
    /// `refreshCurrentRepository` — and the control is held open for a beat so a
    /// cached or fast response doesn't snap it shut mid-gesture, which reads as a
    /// glitch rather than as a refresh.
    @MainActor
    private func refreshCatalog() async {
        let started = CACurrentMediaTime()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        await viewModel.refreshCurrentRepository()
        let elapsed = CACurrentMediaTime() - started
        if elapsed < Self.minRefreshDuration {
            try? await Task.sleep(nanoseconds: UInt64((Self.minRefreshDuration - elapsed) * 1_000_000_000))
        }
    }

    /// How long the refresh control stays open at minimum.
    private static let minRefreshDuration: TimeInterval = 0.55

    @ViewBuilder
    private var searchContent: some View {
        Group {
            switch searchState {
            case .idle:
                Color.clear
            case .loading:
                // Only reached with no results to show yet. Once there are
                // results they stay put while the next query loads, so the list
                // never blanks out under the user mid-typing.
                skeletonList
            case .empty:
                VStack(spacing: 12) {
                    Image(systemName: FlekSymbol.appGrid)
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(Color(.systemGray3))
                    Text("Nothing found")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(.label))
                    if let note = repoSearch.sourcesNote {
                        Text(note)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            case .results:
                searchResults
            }
        }
        .animation(Self.crossfade, value: searchState)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(repoSearch.sections.enumerated()), id: \.element.id) { sectionIndex, repoSection in
                    // Position of this section's header in the flattened list of
                    // rendered rows, so the entrance stagger keeps running down
                    // the whole list instead of restarting at every header.
                    let base = rowEntranceBase(before: sectionIndex)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            FlekRemoteIcon(url: repoSection.iconUrl, size: 20, corner: 4)
                            Text(repoSection.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 4)
                        .rowEntrance(index: base, batchStamp: repoSearch.sectionsStamp)

                        if repoSection.apps.isEmpty && repoSection.isLoading {
                            // FlekSt0re's slot, held while its server search runs.
                            // Rows rather than a spinner, so the sections below
                            // are pushed down once, now, instead of again when
                            // the results land.
                            VStack(spacing: 8) {
                                ForEach(0 ..< 3, id: \.self) { index in
                                    FlekInstallerSkeletonRow(seed: index)
                                }
                            }
                            .rowEntrance(index: base + 1, batchStamp: repoSearch.sectionsStamp)
                        } else {
                            ForEach(Array(repoSection.apps.enumerated()), id: \.element.id) { index, app in
                                FlekInstallerRow(
                                    app: app,
                                    accent: Self.flekBlue,
                                    installState: LCInstallQueue.shared.item(for: app.install_url)?.installState,
                                    isCompleted: LCInstallQueue.shared.completedURLs.contains(app.install_url),
                                    onInstall: { installSearchResult(app, fromFlekstore: repoSection.isFlekstore) },
                                    onCancel: {
                                        LCInstallQueue.shared.cancel(url: app.install_url)
                                    },
                                    onOpen: {
                                        detailTarget = DetailTarget(app: app,
                                                                    isFlekstore: repoSection.isFlekstore)
                                    }
                                )
                                .rowEntrance(index: base + 1 + index, batchStamp: repoSearch.sectionsStamp)
                            }
                        }
                    }
                }
                // Under everything found, as what is missing from it.
                if let note = repoSearch.sourcesNote {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, barsTopInset)
            .padding(.bottom, listBottomInset)
            // FlekSt0re's results arrive after the cached repos', filling in the
            // placeholder slot held for them at the top. Animating on the batch
            // counter lets the sections below slide down to make room instead of
            // jumping under the user's eye (or thumb).
            .animation(reduceMotion ? Self.crossfade : .spring(response: 0.42, dampingFraction: 0.9),
                       value: repoSearch.batch)
        }
        // Scrolling the results puts the keyboard away, as it does anywhere else
        // in iOS that a list sits under a search field.
        .scrollDismissesKeyboardIfAvailable()
    }

    /// Number of rendered rows (headers included) ahead of `sectionIndex`.
    private func rowEntranceBase(before sectionIndex: Int) -> Int {
        repoSearch.sections.prefix(sectionIndex).reduce(0) { $0 + 1 + max($1.apps.count, 1) }
    }

    // MARK: Install tray

    /// Progress for installs started from Import IPA / Install from URL.
    ///
    /// A catalog install shows its progress on its own row, but a hand-picked
    /// IPA or URL has no row here — the only feedback used to be the card on the
    /// home screen, which the user can't see while the installer is open.
    @ViewBuilder
    private var installTray: some View {
        let manual = installQueue.manualItems
        if !manual.isEmpty {
            FlekInstallTray(items: manual, accent: Self.flekBlue) { item in
                if case .failed = item.phase {
                    installQueue.dismissFailed(item)
                } else {
                    installQueue.cancel(item)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: InstallTrayHeightKey.self, value: geo.size.height)
                }
            )
            .onDisappear { trayHeight = 0 }
        }
    }

    // MARK: Bottom bar

    /// The trailing circle is *one* button in both states — only its icon and
    /// role change — so opening search reads as that control turning into the
    /// close button, with the field expanding out of it. Swapping two whole bars
    /// (the previous structure) made the circle disappear and reappear a few
    /// points away, which is the jump the eye picks up.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if searchActive {
                    searchField
                        .transition(reduceMotion ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                } else {
                    importMenu
                        .transition(reduceMotion ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                }
            }
            // Pinned height: the import capsule (48) and the search field (50)
            // differ, and letting the row resize itself would nudge everything
            // above it at the end of the transition.
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .leading)

            searchToggleButton
        }
        .animation(searchMotion, value: searchActive)
    }

    private var importMenu: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    choosingIPA = true
                } label: {
                    Label("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus")
                }
                Button {
                    Task { _ = await importUrlHelper.open() }
                } label: {
                    Label("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus")
                }
                // LiveContainer's link button: a URL scheme opens the installed
                // app that takes it, a web address the browser inside FlekDeck.
                Button {
                    Task { _ = await openURLHelper.open() }
                } label: {
                    Label("lc.flek.openURL".loc, systemImage: "link")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .medium))
                    Text("lc.flek.importIpa".loc)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(capsuleChrome)
            }

            Spacer(minLength: 0)
        }
    }

    /// Magnifying glass ↔ close. The two glyphs crossfade through a quarter turn
    /// and a scale, which is how iOS morphs a control's icon when its meaning
    /// changes; the circle underneath never moves.
    private var searchToggleButton: some View {
        Button {
            if searchActive { closeSearch() } else { openSearch() }
        } label: {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .opacity(searchActive ? 0 : 1)
                    .scaleEffect(searchActive && !reduceMotion ? 0.55 : 1)
                    .rotationEffect(.degrees(searchActive && !reduceMotion ? -90 : 0))
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .opacity(searchActive ? 1 : 0)
                    .scaleEffect(!searchActive && !reduceMotion ? 0.55 : 1)
                    .rotationEffect(.degrees(!searchActive && !reduceMotion ? 90 : 0))
            }
            .foregroundStyle(.primary.opacity(0.7))
            .frame(width: 50, height: 50)
            .background(circleChrome)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchActive ? "lc.common.close".loc : "lc.flek.search".loc)
    }

    /// Shared frosted-capsule surface for the bottom controls.
    private var capsuleChrome: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(Color(.systemBackground).opacity(0.5)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
    }

    private var circleChrome: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().fill(Color(.systemBackground).opacity(0.5)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(Color(.systemGray))

            TextField("lc.flek.search".loc, text: $viewModel.searchQuery)
                .font(.system(size: 17))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                // Debouncing lives in the search model so it can report "busy"
                // from the first keystroke — see `queryChanged`.
                .onChange(of: viewModel.searchQuery) { repoSearch.queryChanged($0) }
                .onSubmit { repoSearch.searchNow(viewModel.searchQuery) }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    // Clearing the text is enough: the catalog list underneath was
                    // never re-fetched for the query, so there is nothing to
                    // restore. Keep the keyboard up — the user is still searching.
                    viewModel.searchQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Color(.systemGray))
                }
                .buttonStyle(.plain)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.searchQuery.isEmpty)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(capsuleChrome)
    }

    // MARK: Actions

    private func openSearch() {
        searchActive = true
        // The field only exists once `searchActive` flips, so focus has to wait
        // for it to be installed in the hierarchy. Landing partway through the
        // expansion means the keyboard rises with the field, not after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        repoSearch.cancelSearch()
        searchActive = false
        viewModel.searchQuery = ""
    }

    /// Opens the page `pendingDetailRequest` is asking for, switching to the
    /// source it came from first.
    ///
    /// `afterPresentation` waits out the animation that is bringing this page on
    /// screen. A sheet asked for while that is still in flight is asked of a
    /// controller that is itself mid-presentation, and simply never appears.
    private func openPendingDetail(afterPresentation: Bool) async {
        guard let request = Self.pendingDetailRequest else { return }
        Self.pendingDetailRequest = nil

        if afterPresentation {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
        }

        // Already on the right source when the page was opened straight onto it;
        // only an installer that was already open has somewhere to move to.
        if let match = repos.first(where: { $0.sourceURL == request.repoURL }),
           match.id != selectedRepoID {
            selectedRepoID = match.id
            await switchTo(match)
        }
        detailTarget = DetailTarget(app: request.app, isFlekstore: request.isFlekstore)
    }

    private func install(_ app: FSAppModel) {
        enqueueInstall(app, fromFlekstore: viewModel.repository == .flekstore)
    }

    private func installSearchResult(_ app: FSAppModel, fromFlekstore: Bool) {
        enqueueInstall(app, fromFlekstore: fromFlekstore)
    }

    /// Queues the download + install and counts the FlekSt0re download.
    private func enqueueInstall(_ app: FSAppModel, fromFlekstore: Bool,
                                overrides: FlekInstallOverrides? = nil) {
        LCInstallQueue.shared.enqueue(
            url: app.install_url,
            name: overrides?.displayName ?? app.app_name,
            iconURL: app.app_icon,
            overrides: overrides
        )
        if fromFlekstore {
            FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
        }
    }

    private func switchTo(_ repo: AppRepository) async {
        if searchActive { closeSearch() }
        let source = Self.source(for: repo)
        Self.sessionSelectedRepoURL = repo.sourceURL
        switchCount &+= 1
        let thisSwitch = switchCount
        // Custom repos are pre-fetched to disk; show that cache instantly and
        // refresh in the background instead of flashing an empty loading state.
        // Read off the main thread, as a big catalog takes a moment, and not
        // at all where the list is still held in memory.
        var disk: [FSAppModel]? = nil
        if case .custom(let url) = source, !viewModel.hasMemoryCache(for: source) {
            disk = await Task.detached(priority: .userInitiated) {
                RepoCatalogCache.shared.cachedApps(for: url)
            }.value
            // Another source was picked while this one was being read.
            guard thisSwitch == switchCount else { return }
        }
        await viewModel.switchRepository(to: source, diskPreloaded: disk)
    }

    private func updateSwitcherBarState() {
        bottomSafeInset = LCDeviceSafeArea.bottomInset()
        // Read the interface orientation directly so it is always current — the
        // dock manager's cached flag only updates while the bar is visible and
        // can be stale when the page first opens in landscape.
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) {
            // Matches the dock's own rule: the bar only leaves the bottom when the
            // height is short. On iPad, and on the unfolded iPhone Duo, it stays
            // along the bottom in both orientations, so bottom content must keep
            // making room for it.
            barIsLandscape = scene.interfaceOrientation.isLandscape
                && scene.traitCollection.userInterfaceIdiom != .pad
                && scene.traitCollection.verticalSizeClass == .compact
        }
        if #available(iOS 16.0, *) {
            let mgr = MultitaskDockManager.shared
            // Only override the default when the dock is actually set up;
            // keeps the safe default (true → 12pt padding) during setup.
            guard mgr.isVisible else { return }
            switcherBarVisible = mgr.isSwitcherBarVisible
        }
    }

    /// A readable title for a hand-started install, taken from the file or URL
    /// the user picked, so the tray (and the home-screen card) name the app
    /// instead of showing a bare "Installing…".
    static func importName(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base != "/" else { return url.host }
        // A file URL's components come back decoded already; a typed URL's don't.
        return url.isFileURL ? base : (base.removingPercentEncoding ?? base)
    }

    // MARK: Repo helpers

    static func isFlekstore(_ repo: AppRepository) -> Bool {
        repo.sourceURL == "Default app catalog" || repo.name.localizedCaseInsensitiveContains("FlekSt0re")
    }

    static func source(for repo: AppRepository) -> FlekstoreAppsListViewModel.RepositorySource {
        isFlekstore(repo) ? .flekstore : .custom(url: repo.sourceURL)
    }

    static func loadRepos() -> [AppRepository] {
        guard let data = UserDefaults.standard.data(forKey: "savedRepositories"),
              let decoded = try? JSONDecoder().decode([AppRepository].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Reports the manage-sources button's measured width up to the carousel.
private struct ManageButtonWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the install tray's measured height so the list can inset for it.
private struct InstallTrayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// How a result row arrives: a short fade with a small rise, staggered a few
/// rows deep so a batch of results reads as settling into place rather than
/// appearing all at once.
///
/// Only rows belonging to a freshly published batch animate. A lazy stack also
/// builds rows as the user scrolls, and animating *those* is the tell of a
/// hand-rolled list — system lists never re-animate a row you scroll back to.
/// `batchStamp` is taken when the data is published, so a row can tell which
/// case it is in by how old its batch is when it first appears.
private struct FlekRowEntrance: ViewModifier {
    let index: Int
    let batchStamp: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool

    init(index: Int, batchStamp: TimeInterval) {
        self.index = index
        self.batchStamp = batchStamp
        // A row of a batch that is no longer fresh starts in place, rather than
        // drawing one frame at the start of an entrance it then skips.
        _shown = State(initialValue: CACurrentMediaTime() - batchStamp >= Self.batchWindow)
    }

    /// Rows arriving within this long of their batch are treated as part of it.
    private static let batchWindow: TimeInterval = 0.4
    /// Per-row stagger, and the depth at which it stops growing — past a handful
    /// of rows the delay would outlast the animation and read as a slow wipe.
    private static let stagger: TimeInterval = 0.035
    private static let maxStaggeredRows = 7

    func body(content: Content) -> some View {
        content
            // Transform-only (no layout effect), so a row animating in never
            // shifts the rows around it.
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !reduceMotion,
                      CACurrentMediaTime() - batchStamp < Self.batchWindow else {
                    shown = true
                    return
                }
                let step = Double(min(max(index, 0), Self.maxStaggeredRows))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)
                    .delay(step * Self.stagger)) {
                    shown = true
                }
            }
    }
}

/// Reads a sideways drag on the Installer's list as a swipe between sources.
///
/// From iOS 18 a UIKit pan, which starts only on a drag that sets off sideways:
/// any other drag — the list's scroll, pull-to-refresh with it — is left to the
/// list as if the swipe were not there. Once started, it holds the list still
/// and takes the touch from the row under the finger, as a paged scroll view
/// does. Earlier, a drag gesture alongside the list's own, which keeps its
/// reading of a drag it leaves alone out of view state, so that such a drag
/// changes nothing on screen.
private struct FlekSourceSwipeGesture: ViewModifier {
    var isEnabled: Bool
    var onBegan: () -> Void
    /// How far the finger has gone sideways since the swipe started.
    var onChanged: (CGFloat) -> Void
    /// How far it went, and its speed, in points a second, as it lifted.
    var onEnded: (CGFloat, _ velocity: CGFloat) -> Void

    @State private var drag = FlekSourceSwipeDrag()

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(FlekSourceSwipeRecognizer(isEnabled: isEnabled, onBegan: onBegan,
                                                      onChanged: onChanged, onEnded: onEnded))
        } else {
            content.simultaneousGesture(dragGesture, including: isEnabled ? .all : .subviews)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                // Read once, from the first stretch of movement: a mostly
                // sideways one is a swipe, anything else the list's own scroll.
                if drag.isSideways == nil {
                    drag.isSideways = abs(dx) > abs(dy) * 1.4
                    guard drag.isSideways == true else { return }
                    drag.origin = dx
                    drag.sample = nil
                    drag.speed = 0
                    onBegan()
                }
                guard drag.isSideways == true else { return }
                let translation = dx - drag.origin
                if let last = drag.sample {
                    let elapsed = value.time.timeIntervalSince(last.time)
                    if elapsed > 0.004 {
                        drag.speed = drag.speed * 0.3 + (translation - last.translation) / elapsed * 0.7
                    }
                }
                drag.sample = (translation, value.time)
                onChanged(translation)
            }
            .onEnded { value in
                defer { drag.isSideways = nil }
                guard drag.isSideways == true else { return }
                // A finger that came to rest before lifting has no speed left.
                let resting = drag.sample.map { value.time.timeIntervalSince($0.time) > 0.06 } ?? true
                var speed = resting ? 0 : drag.speed
                // A flick too quick to be sampled shows in where SwiftUI expects
                // the drag to have carried on to.
                let carriedOn = value.predictedEndTranslation.width - value.translation.width
                if abs(speed) < 450 && abs(carriedOn) > 120 { speed = carriedOn * 4 }
                onEnded(value.translation.width - drag.origin, speed)
            }
    }
}

/// The drag gesture's reading of the drag under way, kept in a reference so
/// that updating it is not a change of view state.
private final class FlekSourceSwipeDrag {
    var isSideways: Bool?
    var origin: CGFloat = 0
    var sample: (translation: CGFloat, time: Date)?
    var speed: CGFloat = 0
}

@available(iOS 18.0, *)
private struct FlekSourceSwipeRecognizer: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Global, not local: the list being swiped moves with the finger.
        let translation = context.converter.translation(in: .global)?.x ?? 0
        switch recognizer.state {
        case .began:
            // Measured from where it set off, so the page starts from where it
            // stood rather than jumping the distance it took to tell.
            context.coordinator.origin = translation
            onBegan()
            onChanged(0)
        case .changed:
            onChanged(translation - context.coordinator.origin)
        case .ended:
            onEnded(translation - context.coordinator.origin,
                    context.converter.velocity(in: .global)?.x ?? 0)
        case .cancelled, .failed:
            onEnded(translation - context.coordinator.origin, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var origin: CGFloat = 0

        /// Sideways only. A drag that sets off any other way fails the pan at
        /// once and is the list's alone.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let movement = pan.translation(in: pan.view)
            return abs(movement.x) > abs(movement.y) * 1.2
        }
    }
}

/// A source's list as it will look once it is shown, for a swipe to carry in
/// beside the list: the top of its catalog, or placeholders where none has
/// been fetched yet. Drawn row for row as the list draws it, so the list can
/// take its place unseen, and equatable on what it draws, so the frames of a
/// swipe move it without building it again.
private struct FlekSourcePreviewPage: View, Equatable {
    let apps: [FSAppModel]
    let topInset: CGFloat
    let accent: Color
    let placeholderRows: Int

    var body: some View {
        // The page is the size of the list, with the rows hung from its top: a
        // screenful and more, they run on below it as the list's do. Framed
        // instead, the rows would be centred on the page, starting above it.
        // Each row is as tall as it is in the list, where the scroll view
        // leaves its height open, rather than squeezed to share the page —
        // a description given two lines there would be cut to one here.
        Color.clear.overlay(alignment: .top) {
            VStack(spacing: 8) {
                if apps.isEmpty {
                    ForEach(0 ..< placeholderRows, id: \.self) { index in
                        FlekInstallerSkeletonRow(seed: index)
                    }
                } else {
                    ForEach(apps) { app in
                        FlekInstallerRow(
                            app: app,
                            accent: accent,
                            installState: LCInstallQueue.shared.item(for: app.install_url)?.installState,
                            isCompleted: LCInstallQueue.shared.completedURLs.contains(app.install_url),
                            onInstall: {},
                            onCancel: {},
                            onOpen: {}
                        )
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, topInset)
        }
    }
}

private extension View {
    func rowEntrance(index: Int, batchStamp: TimeInterval) -> some View {
        modifier(FlekRowEntrance(index: index, batchStamp: batchStamp))
    }

    /// iOS 16+: put the keyboard away as soon as the results are scrolled.
    // Erased to AnyView for the same reason as `scrollClipDisabledIfAvailable`
    // below: an opaque return type would bake an iOS 16-only modifier type into
    // this function's static type, which the runtime resolves on iOS 15 before
    // the availability check runs.
    func scrollDismissesKeyboardIfAvailable() -> AnyView {
        if #available(iOS 16.0, *) { return AnyView(self.scrollDismissesKeyboard(.immediately)) }
        return AnyView(self)
    }

    /// iOS 16+: keep a placeholder list from scrolling — there is nothing under
    /// it to reach. Erased to AnyView for the same reason as the helpers around it.
    func scrollDisabledIfAvailable() -> AnyView {
        if #available(iOS 16.0, *) { return AnyView(self.scrollDisabled(true)) }
        return AnyView(self)
    }

    /// iOS 17+: let content (e.g. pill shadows) draw outside the scroll view's
    /// bounds instead of being clipped. No-op below iOS 17 (shadow stays clipped).
    // Erased to AnyView: `scrollClipDisabled` is iOS 17+, and an opaque return
    // type would bake its modifier type into this function's static type. The
    // runtime resolves that type before the availability check ever runs, so on
    // iOS 16 the lookup fails and traps.
    func scrollClipDisabledIfAvailable() -> AnyView {
        if #available(iOS 17.0, *) { return AnyView(self.scrollClipDisabled()) }
        return AnyView(self)
    }

    /// Cuts a row that draws past its ends at the side the system's vertical bar
    /// runs down, and nowhere else. See `VerticalBarSideClip`.
    func clippedAtVerticalBar() -> some View { modifier(VerticalBarSideClip()) }

    /// See `RepoPillSurface`.
    func repoPillGlass() -> some View { modifier(RepoPillSurface()) }

    /// See `RepoChipSurface`.
    func repoChipSelection(_ selected: Bool) -> some View { modifier(RepoChipSurface(selected: selected)) }
}

/// The source pill's surface: native Liquid Glass on iOS 26+, and a frosted
/// capsule built by hand on older versions — which means picking its own tint
/// per theme. Light theme keeps the FlekSign white wash; dark theme darkens the
/// material instead, because that white wash over a dark backdrop turned the
/// pill into a pale slab that its own `Color.primary` labels vanished into.
/// The dark build matches the search view's pre-26 glass, so the two floating
/// bars read as the same material.
private struct RepoPillSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    // Returns AnyView rather than an opaque type, so the iOS 26-only type
    // `glassEffect` produces stays out of this modifier's static type — the
    // runtime resolves that before the availability check runs, and traps on
    // older systems where the type is absent.
    func body(content: Content) -> AnyView {
        if #available(iOS 26, *) {
            return AnyView(content.clipShape(Capsule()).glassEffect(.regular, in: Capsule()))
        }
        let isDark = colorScheme == .dark
        return AnyView(
            content
                .background(
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
                        // Hairline rim: the dark pill has no bright wash to give
                        // it an edge, so it needs one to separate from the blur.
                        if isDark {
                            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        }
                    }
                )
                .clipShape(Capsule())
        )
    }
}

/// Keeps a row that draws past its ends from drawing under the system's vertical
/// bar.
///
/// The category row turns scroll clipping off so each pill's shadow can fall
/// outside it, which lets the pills scroll out past its ends as well. On an
/// upright iPhone those ends are the screen's own and nothing shows; on the iPhone
/// Duo the trailing end is where the status bar's column begins, and the pills slid
/// in under it. So the row is cut at the side that holds the bar and only there:
/// the shadows above and below, and the other end, draw as before. With no
/// vertical bar nothing is cut at all.
private struct VerticalBarSideClip: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Cut())
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Cut: ViewModifier {
        @Environment(\.toolbarVerticalEdge) private var barEdge
        @Environment(\.layoutDirection) private var layoutDirection

        // Clipped whether or not there is a bar, to a shape that cuts nothing
        // without one, so that folding or unfolding does not rebuild the row and
        // lose how far it was scrolled.
        func body(content: Content) -> some View {
            content.clipShape(OneSideCut(side: barSide))
        }

        /// The bar's side on screen: its edge follows the layout direction, and the
        /// clip is drawn left to right.
        private var barSide: OneSideCut.Side? {
            guard let barEdge else { return nil }
            let isTrailing = barEdge == .trailing
            return isTrailing == (layoutDirection == .leftToRight) ? .right : .left
        }
    }
}

/// A view's own rectangle opened out far past it on every side except `side`,
/// where it stops at the view's edge.
private struct OneSideCut: Shape {
    enum Side { case left, right }
    let side: Side?

    /// Far enough past the view to take in anything drawn beyond it on screen.
    private static let reach: CGFloat = 1_000

    func path(in rect: CGRect) -> Path {
        let minX = side == .left ? rect.minX : rect.minX - Self.reach
        let maxX = side == .right ? rect.maxX : rect.maxX + Self.reach
        return Path(CGRect(x: minX, y: rect.minY - Self.reach,
                           width: maxX - minX, height: rect.height + Self.reach * 2))
    }
}

/// The selected repo chip inside the source pill: a native Liquid Glass thumb on
/// iOS 26+, and a plain capsule on older versions — FlekSign's #EDEDED over the
/// light pill, and a soft white lift over the dark one, where #EDEDED left white
/// labels sitting on near-white. Unselected chips stay clear (rather than drop
/// the background) so selection cross-fades instead of popping in.
/// AnyView for the same reason as `RepoPillSurface`.
private struct RepoChipSurface: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> AnyView {
        if #available(iOS 26, *) {
            guard selected else { return AnyView(content) }
            // Subtle grey tint so the selected thumb reads against the glass pill.
            return AnyView(content.glassEffect(.regular.tint(Color.gray.opacity(0.3)), in: Capsule()))
        }
        let isDark = colorScheme == .dark
        let fill: Color = selected
            ? (isDark ? Color.white.opacity(0.18) : Color(red: 0.929, green: 0.929, blue: 0.929))
            : .clear
        let rim: Color = selected && isDark ? Color.white.opacity(0.22) : .clear
        return AnyView(
            content.background(
                Capsule()
                    .fill(fill)
                    .overlay(Capsule().strokeBorder(rim, lineWidth: 0.5))
            )
        )
    }
}

/// App row in the installer: icon, name, version·bundle, description, download.
/// While installing, the app icon shows a dimmed overlay with progress (same as
/// the springboard). A checkmark overlay appears on the icon when done.
///
/// The row surface opens the app's page; the trailing control installs. It is
/// laid out as a button *plus* an overlay rather than nesting the install button
/// inside the row button — nested SwiftUI buttons fight over the tap, and the
/// outer one usually wins.
struct FlekInstallerRow: View {
    let app: FSAppModel
    let accent: Color
    var installState: FlekInstallState? = nil
    var isCompleted: Bool = false
    var onInstall: () -> Void
    var onCancel: () -> Void = {}
    /// Opens the detail sheet. Rows with no page to show leave this unset and
    /// stay inert, rather than offering a tap that goes nowhere.
    var onOpen: (() -> Void)? = nil

    @State private var showCheckmark = false

    /// Which trailing control the row is showing. Used as the animation key so
    /// install → cancel → done reads as one control changing, not three views
    /// cutting in and out.
    private enum TrailingControl: Equatable { case install, cancel, done }

    private var trailingControl: TrailingControl {
        if installState != nil { return .cancel }
        return showCheckmark ? .done : .install
    }

    private var controlTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.7))
    }

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { rowContent }
                    .buttonStyle(FlekRowPressStyle())
            } else {
                rowContent
            }
        }
        .overlay(alignment: .trailing) { trailingSlot.padding(.trailing, 14) }
        .onChange(of: isCompleted) { completed in
            guard completed else { return }
            // The swap itself is animated by `trailingControl` below.
            showCheckmark = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showCheckmark = false
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            // Icon — shows progress overlay when installing
            ZStack {
                if let installState {
                    FlekInstallIcon(state: installState, size: 74, corner: 17)
                        .transition(.opacity)
                } else {
                    FlekRemoteIcon(url: app.app_icon, size: 74, corner: 17)
                        .transition(.opacity)
                }
            }
            .frame(width: 74, height: 74)
            // Same artwork underneath either way, so the progress overlay should
            // dissolve on and off rather than cut.
            .animation(.easeInOut(duration: 0.2), value: installState == nil)

            VStack(alignment: .leading, spacing: 6) {
                Text(app.app_name).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(app.app_version).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                if !app.app_short_description.isEmpty {
                    Text(app.app_short_description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)

            // Room for the trailing control, which is overlaid on top.
            Spacer(minLength: 8)
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var trailingSlot: some View {
        ZStack {
            switch trailingControl {
            case .cancel:
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(controlTransition)
            case .done:
                FlekRowCheckmark(accent: accent)
                    .transition(controlTransition)
            case .install:
                Button(action: onInstall) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .transition(controlTransition)
            }
        }
        // Fixed slot: the three controls aren't the same size, and letting
        // the row re-measure would shuffle the text beside it on every swap.
        .frame(width: 32, height: 32)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: trailingControl)
    }
}

/// Row press feedback: the same brief dim-and-settle a list row gives, kept
/// subtle because the row is a large target.
private struct FlekRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A placeholder in the shape of `FlekInstallerRow`, shown while a list is
/// loading.
///
/// It carries the row's real geometry — 74pt icon, the same paddings, the same
/// 24pt card — so the list is already the right shape before any data arrives
/// and the content crossfades into place instead of the page jumping. A bare
/// centred spinner reserves nothing, so every row lands as a layout change.
struct FlekInstallerSkeletonRow: View {
    /// Varies the bar widths, so a column of these doesn't read as a repeating
    /// pattern the way identical rows would.
    let seed: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private static let nameWidths: [CGFloat] = [140, 116, 168, 128]
    private static let versionWidths: [CGFloat] = [64, 52, 78, 58]
    private static let detailWidths: [CGFloat] = [196, 168, 220, 182]

    /// Shared with every image placeholder, so a half-loaded list doesn't show
    /// two different greys side by side.
    private var fill: Color { FlekPlaceholderStyle.fill }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(fill)
                .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 8) {
                bar(width: Self.nameWidths[seed % Self.nameWidths.count], height: 14)
                bar(width: Self.versionWidths[seed % Self.versionWidths.count], height: 10)
                bar(width: Self.detailWidths[seed % Self.detailWidths.count], height: 9)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(fill)
                .frame(width: 30, height: 30)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
        .opacity(dim ? FlekPlaceholderStyle.dimmedOpacity : 1)
        .onAppear {
            guard let animation = FlekPlaceholderStyle.pulse(reduceMotion: reduceMotion) else { return }
            withAnimation(animation) { dim = true }
        }
        // Nothing here is real content, so keep it away from VoiceOver and taps.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
    }
}

/// Animated checkmark shown briefly after a successful install, and larger
/// where a pairing file has just been received.
struct FlekRowCheckmark: View {
    let accent: Color
    /// Across. The check's stroke and the room around it go by it.
    var size: CGFloat = 30
    @State private var trimEnd: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
            CheckmarkShape()
                .trim(from: 0, to: trimEnd)
                .stroke(.white, style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
                .padding(size * 4 / 15)
        }
        .frame(width: size, height: size)
        .onAppear {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) {
                trimEnd = 1
            }
        }
    }
}

/// A checkmark shape for stroke animation.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.2, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.8, y: h * 0.28))
        return path
    }
}

/// Async remote icon with a placeholder. Uses Kingfisher (already a project
/// dependency) so icons are cached in memory + on disk and keyed by URL. A
/// cached icon renders on the first frame — no placeholder flash — even when
/// the hosting row is torn down and rebuilt (e.g. after the repo list is
/// re-decoded and every repo gets a new identity).
struct FlekRemoteIcon: View {
    let url: String
    var size: CGFloat
    var corner: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        KFImage(URL(string: url))
            .placeholder {
                FlekImagePlaceholder(cornerRadius: corner)
            }
            // Decode/downsample to the display size instead of full resolution, and
            // cancel in-flight loads when the row scrolls away — keeps long result
            // lists smooth and bounds memory.
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: size, height: size)))
            .scaleFactor(displayScale)
            .cacheOriginalImage()
            .cancelOnDisappear(true)
            .fade(duration: 0.15)   // only animates on a network load, not on a cache hit
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
