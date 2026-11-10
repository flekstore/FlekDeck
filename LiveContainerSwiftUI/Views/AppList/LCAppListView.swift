//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private extension View {
    /// The two-layer shadow used on the installer's bottom-bar controls: a soft
    /// ambient shadow plus a tighter contact shadow for contrast over the blur.
    func installerBarShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

/// Identifiable wrapper so the game-launch warning can be presented via .sheet(item:).
struct FlekGameWarningTarget: Identifiable {
    let id = UUID()
    let app: LCAppModel
}

struct NavigationTarget: Identifiable {
    let id = UUID()
    let view: AnyView
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    /// What to tell the user when an app set to launch with JIT was not started
    /// because JIT is not set up; nil while there is nothing to tell.
    @State private var jitNotReadyMessage: String?
    /// Kept after the warning has gone, so that it does not blank on its way out.
    @State private var jitNotReadyTitle = "lc.flek.jit.notReady.title".loc
    /// A warning to put up once the one that is up has gone: an alert keeps
    /// the text it came up with.
    @State private var jitNotReadyNext: (title: String, message: String)?
    /// An app with Location Spoofer on was not started for want of Premium,
    /// which the warning offers.
    @State private var locationSpooferNeedsPremium = false
    @State private var showsPremiumOffer = false
    /// A launch held back for what the device is connected through, to be
    /// started once that has changed. The warning stays up meanwhile.
    @State private var waitingLaunch: (() async -> Void)?
    @State private var connectionWatch: FlekJITSetup.ConnectionWatch?
    @State private var isRetryingLaunch = false
    /// The FlekJIT shortcut has been run for the launch that waits, which it
    /// is once: with Mobile Data still on after it, the user is asked.
    @State private var hasRunShortcutForLaunch = false
    /// While the shortcut runs, with the Shortcuts app in front.
    @State private var isRunningShortcut = false
    /// The shortcut has just run: how many times the next asking goes over
    /// it with nothing said meanwhile, as what the shortcut switched takes a
    /// moment to take. Zero where it has not.
    @State private var quietTriesAfterShortcut = 0
    @State var errorInfo = ""
    /// The failed install the user tapped, driving the failed-install alert.
    @State private var failedInstallItem: InstallItem?
    
    // ipa installing stuff
    @ObservedObject var installQueue = LCInstallQueue.shared
    @State private var homeScrollToPage: Int?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    @StateObject var bundleIdInput = InputHelper()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigationTarget: NavigationTarget?
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false

    // FlekDeck springboard state
    @State private var isEditing = false
    @State private var showSettingsCover = false
    @State private var showInstallerCover = false
    /// A URL or URL scheme the Installer handed on, to be opened once its
    /// page has gone: nothing can be presented over it while it is up.
    @State private var linkAfterInstaller: String?
    @State private var showSearch = false
    @State private var installerPreselectFlekstore = false
    @State private var installerPreselectRepoURL: String?
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @AppStorage(FlekDeckKeys.homeLayout, store: LCUtils.appGroupUserDefault) var homeLayout: String = FlekHomeLayout.grid.rawValue
    @AppStorage(FlekDeckKeys.homeBarPosition, store: LCUtils.appGroupUserDefault) var homeBarPosition: String = FlekHomeBarPosition.bottom.rawValue
    @AppStorage(FlekDeckKeys.glassStyle, store: LCUtils.appGroupUserDefault) var glassStyle: FlekGlassStyle = .liquid
    /// The edge an iPhone Duo's status bar runs down; nil wherever there is none.
    @State private var verticalBarEdge: HorizontalEdge?


    @State private var homeSaveIconExporterShow = false
    @State private var homeSaveIconFile : ImageDocument?
    @StateObject private var homeUninstallAlert = YesNoHelper()
    @StateObject private var homeSharedUninstallAlert = YesNoHelper()
    @StateObject private var homeUninstallFolderAlert = YesNoHelper()
    @State private var homeRefreshToggle = false
    // Bumped when a launch mode is picked from the list menu. Unlike
    // homeRefreshToggle (which drives .id and rebuilds the view, closing the
    // menu), this just refreshes badges in place so the menu stays open.
    @State private var launchModeVersion = 0
    @State private var gameWarningTarget: FlekGameWarningTarget?
    @State private var orderedHomeItems: [FlekHomeItem] = []

    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    
    @EnvironmentObject private var flekstoreSharedModel: FlekstoreSharedModel
    @EnvironmentObject private var sceneDelegate: SceneDelegate
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    
    @State private var isViewAppeared = false
    @State private var isMultitaskHomeState = false
    /// Whether any guest apps are currently running in multitask. Home state
    /// stays true after the user closes them all, so this is what tells the
    /// dock pill apart from an empty one.
    @State private var hasMultitaskApps = false

    /// Show the multitask dock pill only when we're in home state AND at least
    /// one multitask app is running. Once everything is closed, show just the
    /// search button.
    private var showMultitaskDock: Bool {
        isMultitaskHomeState && hasMultitaskApps
    }

    /// How the dock arrives. Normally it springs in beside the search button, but
    /// not when a minimizing window is already on its way to it: something still
    /// travelling into position is not something a window can land on, and the
    /// window's own arrival is the animation that matters at that moment.
    private var dockEntranceAnimation: Animation? {
        if #available(iOS 16.0, *), MultitaskDockManager.shared.homeDockShouldSkipEntrance {
            // A single frame rather than no animation at all. The dock is inserted
            // with a transition, and a transition given nothing to run on is left
            // to chance: sometimes it lands on its identity, sometimes on the
            // scaled-down transparent state it was supposed to animate out of —
            // which is a dock that never appears. One frame is imperceptible and
            // leaves nothing to chance.
            return .linear(duration: 0.01)
        }
        return .spring(response: 0.42, dampingFraction: 0.82)
    }

    /// What the dock arrives with: grown out of the search button's side, or with a
    /// window already on its way to one of its icons, only faded in where it
    /// stands. Grown, its icons start out crowded toward the search button, and a
    /// window that measures its icon on that first frame flies to where the dock
    /// is only passing through: the rightmost app to the dock's own switcher
    /// button, before its icon turns up further left.
    private func dockTransition(anchor: UnitPoint) -> AnyTransition {
        if #available(iOS 16.0, *), MultitaskDockManager.shared.homeDockShouldSkipEntrance {
            return .opacity
        }
        return .scale(scale: 0.6, anchor: anchor).combined(with: .opacity)
    }

    /// The home bar: the multitask dock pill (only while apps are running) beside
    /// a persistent search button — along the bottom, or stood on end in the side
    /// column (`.vertical`). The search button keeps its identity across states,
    /// so it glides as the pill springs in/out — a morph rather than a cross-fade.
    // Erased to AnyView: `GlassEffectContainer` and `glassEffect` are iOS 26-only
    // types, and an opaque return type would bake them into this property's static
    // type. The runtime resolves that type before it ever runs the availability
    // check, so on iOS 17.x the lookup fails and the Swift runtime traps.
    private func homeBar(axis: Axis) -> AnyView {
        let controlSize = axis == .horizontal ? FlekTheme.bottomBarControlSize : FlekTheme.sideBarWidth
        let glyphSize = axis == .horizontal ? FlekTheme.bottomBarGlyphSize : FlekTheme.sideBarGlyphSize
        // The pill grows out of the search button's side: from the end that
        // faces it, whichever way the bar runs.
        let pillAnchor: UnitPoint = axis == .horizontal ? .trailing : .bottom
        if #available(iOS 26.0, *), glassStyle == .liquid {
            return AnyView(
                GlassEffectContainer(spacing: 10) {
                    FlekBarStack(axis: axis, spacing: 10) {
                        if showMultitaskDock {
                            MultitaskHomeDockPill(darkModeIcon: darkModeIcon, axis: axis)
                                .transition(dockTransition(anchor: pillAnchor))
                                .installerBarShadow()
                        }
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: glyphSize, weight: .regular))
                                .foregroundStyle(Color.primary.opacity(0.6))
                                .frame(width: controlSize, height: controlSize)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(in: .circle)
                        .installerBarShadow()
                    }
                }
                .animation(dockEntranceAnimation, value: showMultitaskDock)
            )
        }
        return AnyView(
            FlekBarStack(axis: axis, spacing: 10) {
                if #available(iOS 16.0, *), showMultitaskDock {
                    MultitaskHomeDockPill(darkModeIcon: darkModeIcon, axis: axis)
                        .transition(dockTransition(anchor: pillAnchor))
                        .installerBarShadow()
                }
                FlekGlassCircleButton(systemImage: "magnifyingglass", size: controlSize) {
                    showSearch = true
                }
                .installerBarShadow()
            }
            .animation(dockEntranceAnimation, value: showMultitaskDock)
        )
    }

    /// Whether the search button and the running apps stand in the side column
    /// rather than along the bottom: chosen on Personalization, and only while an
    /// iPhone Duo's status bar is actually running down a side. Anywhere else the
    /// bottom bar stands in.
    private var isHomeBarOnSide: Bool {
        homeBarPosition == FlekHomeBarPosition.side.rawValue
            && FlekDeviceModel.isDuo && verticalBarEdge != nil
    }

    /// The bar stood on end in the column the status bar runs down: the running
    /// apps' pill above the search button, centred on the status bar's own column
    /// and as far from the bottom of the display as the bottom bar sits.
    private func homeSideColumn(on edge: HorizontalEdge) -> some View {
        Group {
            if isEditing {
                Button {
                    isEditing = false
                } label: {
                    sideDoneLabel
                }
                .buttonStyle(.plain)
            } else {
                homeBar(axis: .vertical)
                    .id(colorScheme)
            }
        }
        .padding(edge == .leading ? .leading : .trailing,
                 FlekTheme.sideBarCentreInset - FlekTheme.sideBarWidth / 2)
        .padding(.bottom, FlekTheme.bottomBarScreenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: edge == .leading ? .bottomLeading : .bottomTrailing)
        .ignoresSafeArea()
    }

    /// Edit mode's Done in the side column: the checkmark alone, in a circle the
    /// size of the search button it stands in for. Erased to AnyView — see
    /// `homeBar(axis:)` for why.
    private var sideDoneLabel: AnyView {
        let label = Image(systemName: "checkmark")
            .font(.system(size: FlekTheme.sideBarGlyphSize, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(width: FlekTheme.sideBarWidth, height: FlekTheme.sideBarWidth)

        if #available(iOS 26.0, *), glassStyle == .liquid {
            return AnyView(label.glassEffect(.regular.interactive(false), in: .circle))
        }
        return AnyView(
            label
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().fill(Color.primary.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        )
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ObservedObject var searchContext: SearchContext
    /// The device's own bottom safe-area inset — the home indicator, if there is one.
    @State private var homeBottomSafeInset: CGFloat = LCDeviceSafeArea.bottomInset()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    /// Apps offered to search. Hidden apps are included: the springboard draws no
    /// icon for them, so search is the only place they can still be found. Strict
    /// Hiding Mode keeps them out until the session is unlocked — the same rule the
    /// URL-scheme launch path applies — and launching one still passes through the
    /// Face ID gate in `launchHomeApp`.
    /// How far the home bottom bar sits from the bottom of the safe area.
    ///
    /// The grid puts its controls a fixed distance from the bottom edge of the
    /// *screen*, which on a device with a home indicator is inside the inset —
    /// hence the negative result there, reaching back down past it.
    ///
    /// List mode sits lower still, sinking into the home-indicator inset. A
    /// device with a physical home button has no such inset, so the negative
    /// value pushed the bar off the bottom of the screen — it keeps a small
    /// positive margin instead.
    private var homeBottomBarInset: CGFloat {
        guard homeLayout == FlekHomeLayout.list.rawValue else {
            return FlekTheme.bottomBarScreenMargin - homeBottomSafeInset
        }
        return homeBottomSafeInset > 2 ? -9 : 5
    }

    var searchableApps: [LCAppModel] {
        var apps = sortedApps
        if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            apps.append(contentsOf: sortedHiddenApps)
        }
        return apps
    }

    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init(searchContext: SearchContext) {
        _installOptions = State(initialValue: [])
        self.searchContext = searchContext
    }
    
    var body: some View {
        ZStack {
            ZStack {
                FlekWallpaperView()
                FlekBlurredWallpaperOverlay(radius: 30)

                homeContentView
                .id(homeRefreshToggle)

            // Real progressive blur behind the bottom bar (list layout) — the
            // same CAFilter variable blur the installer uses at its bottom edge:
            // clear at the top, ramping to full blur at the bottom, reaching up
            // to just above the search / multitask bar.
            if homeLayout == FlekHomeLayout.list.rawValue && !showSearch && !isHomeBarOnSide {
                GeometryReader { geo in
                    VariableBlurView(maxBlurRadius: 4, direction: .bottom)
                        .frame(height: geo.safeAreaInsets.bottom + 100)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if !showSearch {
            if isHomeBarOnSide, let verticalBarEdge {
                homeSideColumn(on: verticalBarEdge)
            } else {
            VStack {
                Spacer()
                if isEditing {
                    Button {
                        isEditing = false
                    } label: {
                        doneButtonLabel
                    }
                    .buttonStyle(.plain)
                    // The same inset as the bar it stands in for, so that
                    // entering edit mode does not shift the control's position.
                    .padding(.bottom, homeBottomBarInset)
                } else {
                    homeBar(axis: .horizontal)
                        .id(colorScheme)
                        .padding(.bottom, homeBottomBarInset)
                }
            }
            }
            }
            }

            if showSearch {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)   // use dark material variant, no white tint
                    .ignoresSafeArea()
                    .onTapGesture { showSearch = false }
            }

            if showSearch {
                FlekSearchView(
                    isPresented: $showSearch,
                    apps: searchableApps,
                    darkModeIcon: darkModeIcon,
                    onSelect: { app in handleHomeTap(.installed(app)) },
                    contextMenu: { app in AnyView(installedContextMenu(app)) },
                    onInstallStoreApp: { app in
                        installQueue.enqueue(
                            url: app.install_url,
                            name: app.app_name,
                            iconURL: app.app_icon
                        )
                    },
                    onOpenStoreApp: { request in
                        // The installer picks the page up from here, so that a
                        // window already open — which is handed back to the front
                        // rather than rebuilt — still answers the tap.
                        FlekInstallerView.pendingDetailRequest = request
                        openInstaller(atRepo: request.repoURL)
                        NotificationCenter.default.post(name: .flekInstallerOpenAppDetail, object: nil)
                    },
                    onOpenRepo: { repoURL in
                        openInstaller(atRepo: repoURL)
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showSearch)
        .background(FlekVerticalBarEdgeReader(edge: $verticalBarEdge))
        // Folding or unfolding an iPhone Duo moves the app to another display,
        // whose bottom inset need not be this one's.
        .onChange(of: verticalBarEdge) { _ in
            homeBottomSafeInset = LCDeviceSafeArea.bottomInset()
        }
        .onChange(of: horizontalSizeClass) { _ in
            homeBottomSafeInset = LCDeviceSafeArea.bottomInset()
        }
        .onAppear {
            homeBottomSafeInset = LCDeviceSafeArea.bottomInset()
            if !didAppear { onAppear() }
            if #available(iOS 16.0, *) { registerSplitHooks() }
            if flekstoreSharedModel.appInstallURL != "" {
                installQueue.enqueue(
                    url: flekstoreSharedModel.appInstallURL,
                    name: nil,
                    iconURL: nil
                )
                flekstoreSharedModel.appInstallURL = ""
            }
            rebuildOrderedHomeItems()
        }
        .onChange(of: sharedAppSortManager.sortedApps.count) { _ in
            rebuildOrderedHomeItems()
        }
        // The Apps widget shows the start of the home screen, so it follows
        // every change to what the home screen shows and in what order.
        .onChange(of: orderedHomeItems.map(\.displaySignature)) { _ in
            FlekWidgetSync.shared.update(homeItems: orderedHomeItems)
        }
        .onChange(of: installQueue.items.count) { _ in
            rebuildOrderedHomeItems()
        }
        .onChange(of: installQueue.completedURLs.count) { _ in
            rebuildOrderedHomeItems()
        }
        .onReceive({
            if #available(iOS 16.0, *) {
                return MultitaskDockManager.shared.$isHomeState.eraseToAnyPublisher()
            } else {
                return Just(false).eraseToAnyPublisher()
            }
        }()) { newValue in
            isMultitaskHomeState = newValue
        }
        .onReceive({
            if #available(iOS 16.0, *) {
                return MultitaskDockManager.shared.$apps.map { !$0.isEmpty }.eraseToAnyPublisher()
            } else {
                return Just(false).eraseToAnyPublisher()
            }
        }()) { newValue in
            hasMultitaskApps = newValue
        }
        .fullScreenCover(isPresented: $showSettingsCover) {
            FlekMinimizingCover(isPresented: $showSettingsCover,
                                itemID: FlekHomeItem.defaultApp(.settings).id) { minimize in
                FlekInternalPage(minimize: minimize) {
                    LCSettingsView()
                }
            }
        }
        .fullScreenCover(isPresented: $showInstallerCover, onDismiss: {
            installerPreselectRepoURL = nil
            if let link = linkAfterInstaller {
                linkAfterInstaller = nil
                Task { await openWebView(urlString: link) }
            }
        }) {
            FlekMinimizingCover(
                isPresented: $showInstallerCover,
                itemID: FlekHomeItem.defaultApp(installerPreselectFlekstore ? .flekstore : .installer).id
            ) { minimize in
                FlekInstallerView(preselectFlekstore: installerPreselectFlekstore, preselectRepoURL: installerPreselectRepoURL) {
                    minimize()
                }
            }
        }
        .sheet(item: $navigationTarget) { target in
            NavigationView {
                target.view
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("lc.common.done".loc) {
                                navigationTarget = nil
                            }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $gameWarningTarget) { target in
            FlekGameWarningView(appName: target.app.appInfo.displayName() ?? "") { parallel, remember in
                if remember {
                    FlekLaunchModeStore.shared.set(parallel ? .parallel : .single, for: target.app)
                    homeRefreshToggle.toggle()
                }
                Task { await launchHomeApp(target.app, parallel: parallel) }
            }
        }
        
        .fileExporter(
            isPresented: $homeSaveIconExporterShow,
            document: homeSaveIconFile,
            contentType: .image,
            defaultFilename: "Icon.png",
            onCompletion: { _ in })
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $homeUninstallAlert.show) {
            Button(role: .destructive) { homeUninstallAlert.close(result: true) } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) { homeUninstallAlert.close(result: false) }
        } message: {
            Text("lc.appBanner.confirmUninstallShortMsg".loc)
        }
        // Stands in for the plain uninstall confirmation on a shared app: the
        // app group's copy is the one every LiveContainer on the device uses, so
        // saying yes here also gives up sharing it, and that is worth saying
        // before the deletion rather than after.
        .alert("Delete Shared App?", isPresented: $homeSharedUninstallAlert.show) {
            Button("Continue", role: .destructive) { homeSharedUninstallAlert.close(result: true) }
            Button("lc.common.cancel".loc, role: .cancel) { homeSharedUninstallAlert.close(result: false) }
        } message: {
            Text("This app is shared with other FlekDeck instances. To delete it, it will first be converted to a private app, making it unavailable in all other instances.")
        }
        .alert("lc.appBanner.deleteDataTitle".loc, isPresented: $homeUninstallFolderAlert.show) {
            Button(role: .destructive) { homeUninstallFolderAlert.close(result: true) } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.no".loc, role: .cancel) { homeUninstallFolderAlert.close(result: false) }
        } message: {
            Text("lc.appBanner.deleteDataShortMsg".loc)
        }
        .task {
            // Wire up the queue's install handler — called serially for each
            // item that has finished downloading and is ready for extraction + signing.
            installQueue.installHandler = { [self] item in
                let fileURL: URL
                var isLocalFile = false
                if let downloaded = item.downloadedFileURL {
                    fileURL = downloaded
                } else if let url = URL(string: item.url), url.isFileURL {
                    fileURL = url
                    isLocalFile = true
                    // Try to access security-scoped resource for local files
                    let fm = FileManager.default
                    if !fm.isReadableFile(atPath: url.path) {
                        _ = url.startAccessingSecurityScopedResource()
                    }
                } else if let url = URL(string: item.url) {
                    fileURL = url
                } else {
                    throw "lc.appList.urlInvalidError".loc
                }

                defer {
                    if isLocalFile {
                        fileURL.stopAccessingSecurityScopedResource()
                        // Clean up IPA if it was imported via Inbox
                        let fm = FileManager.default
                        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                            let inboxFile = docs.appendingPathComponent("Inbox")
                                .appendingPathComponent(fileURL.lastPathComponent)
                            if fm.fileExists(atPath: inboxFile.path) {
                                try? fm.removeItem(at: fileURL)
                            }
                        }
                        // A copy the share extension staged in the app group is
                        // ours to remove, and exists for no other reason than to
                        // have reached us. It sits in a folder of its own.
                        if let shareInbox = LCSharedUtils.shareInboxPath(),
                           fileURL.path.hasPrefix(shareInbox.path + "/") {
                            try? fm.removeItem(at: fileURL.deletingLastPathComponent())
                        }
                    }
                }

                try await installIpaFile(fileURL, item: item)
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .alert(jitNotReadyTitle, isPresented: Binding(
            get: { jitNotReadyMessage != nil },
            set: { if !$0 { jitNotReadyMessage = nil } }
        )) {
            if waitingLaunch == nil {
                Button("lc.tabView.settings".loc) {
                    handleHomeTap(.defaultApp(.settings))
                }
                Button("lc.common.ok".loc, role: .cancel) {}
            } else {
                // Up for as long as the launch waits, and taken down by it:
                // the button is for not waiting.
                Button("lc.common.cancel".loc, role: .cancel) {
                    abandonWaitingLaunch()
                }
            }
        } message: {
            Text(jitNotReadyMessage ?? "")
        }
        .alert("lc.flek.jit.premium.title".loc, isPresented: $locationSpooferNeedsPremium) {
            Button("lc.flek.premium.get".loc) {
                // Once the alert has gone: asked for while it is still going,
                // the sheet may not come up at all.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showsPremiumOffer = true
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text(FlekLocationSpoofer.PremiumNeeded().localizedDescription)
        }
        .sheet(isPresented: $showsPremiumOffer) {
            FlekPremiumOfferView()
        }
        // Back from Settings, where Airplane Mode has a switch as well.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            retryWaitingLaunch()
        }
        .alert("lc.flek.installFailedTitle".loc, isPresented: Binding(
            get: { failedInstallItem != nil },
            set: { if !$0 { failedInstallItem = nil } }
        ), presenting: failedInstallItem) { item in
            Button("lc.common.delete".loc, role: .destructive) {
                installQueue.dismissFailed(item)
                failedInstallItem = nil
                rebuildOrderedHomeItems()
            }
        } message: { item in
            Text(item.installState.errorMessage ?? "lc.flek.installFailedGeneric".loc)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    // The replace options used to be labelled with the bundle
                    // folder alone, which reads as a heading rather than as the
                    // thing the button is about to do to it.
                    Text(installOption.isReplace
                         ? "lc.appList.updateReplace %@".localizeWithFormat(installOption.nameOfFolderToInstall)
                         : "lc.appList.installAsNew".loc)
                })
                
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $bundleIdInput.show,
            title: "lc.appList.customBundleId".loc,
            text: $bundleIdInput.initVal,
            placeholder: "com.example.app",
            action: { newText in
                bundleIdInput.close(result: newText)
            },
            actionCancel: { _ in
                bundleIdInput.close(result: nil)
            }
        )
        // Download progress is shown on the home app icon (and Installer row),
        // not as a blocking popup.
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        // From the Installer's Open URL or URL Scheme. Its full-screen page
        // goes first; in a window it is already out of the way.
        .onReceive(NotificationCenter.default.publisher(for: .flekOpenURL)) { notification in
            guard let link = notification.object as? String else { return }
            if showInstallerCover {
                linkAfterInstaller = link
            } else {
                Task { await openWebView(urlString: link) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                installFromUrl(urlStr: installUrl.absoluteString)
            }
        }
        .modifier(OrientationLockModifier(
            showSettingsCover: showSettingsCover,
            showInstallerCover: showInstallerCover,
            webViewOpened: webViewOpened,
            safariViewOpened: safariViewOpened,
            helpPresent: helpPresent,
            customSortViewPresent: customSortViewPresent,
            hasNavigationTarget: navigationTarget != nil,
            hasGameWarningTarget: gameWarningTarget != nil
        ))
    }

    /// Erased to AnyView — see `homeBar(axis:)` for why.
    private var doneButtonLabel: AnyView {
        let label = HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
            Text("Done")
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(Color.primary.opacity(0.75))
        .padding(.horizontal, 18)
        .frame(height: FlekTheme.bottomBarControlSize)

        if #available(iOS 26.0, *), glassStyle == .liquid {
            return AnyView(label.glassEffect(.regular.interactive(false)))
        }
        return AnyView(
            label
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().fill(Color.primary.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        )
    }

    // MARK: - FlekDeck springboard

    /// Extracted to a separate computed property to help the Swift type-checker
    /// with the complex view body expression.
    @ViewBuilder
    private var homeContentView: some View {
        Group {
            if homeLayout == FlekHomeLayout.list.rawValue {
                FlekHomeListView(
                    items: $orderedHomeItems,
                    darkModeIcon: darkModeIcon,
                    isEditing: $isEditing,
                    isNew: { FlekLaunchTracker.shared.isNew($0) },
                    onTap: { handleHomeTap($0) },
                    onDelete: { item in
                        if case .installed(let app) = item { Task { await requestUninstall(app) } }
                    },
                    onDropCompleted: { persistHomeOrder() },
                    onCancelInstall: { installQueue.cancel($0) },
                    showsSingleBadge: { _ = launchModeVersion; return FlekLaunchModeStore.shared.showsSingleBadge(for: $0) },
                    barOnSide: isHomeBarOnSide,
                    contextMenu: { item in homeContextMenu(for: item) }
                )
            } else {
                LCSpringboardRepresentable(
                    items: $orderedHomeItems,
                    darkModeIcon: darkModeIcon,
                    drawsGlass: glassStyle == .liquid,
                    isEditing: $isEditing,
                    onTap: { handleHomeTap($0) },
                    onDelete: { item in
                        if case .installed(let app) = item { Task { await requestUninstall(app) } }
                    },
                    onReorder: { handleHomeReorder() },
                    contextMenuProvider: { homeUIMenu(for: $0) },
                    scrollToPage: $homeScrollToPage
                )
                // Grid keeps the original fixed insets (list handles its own).
                // Shared with the grid maths, which works the page size back out
                // from the screen when there is no view to measure.
                //
                // With the bar in the side column, the grid runs on down into the
                // bottom inset to a margin measured from the display's edge — so
                // the padding goes negative where the inset is deeper than that.
                .padding(.top, isHomeBarOnSide
                         ? LCSpringboardPageCell.sideBarGridTopPadding
                         : LCSpringboardPageCell.gridTopPadding)
                .padding(.bottom, isHomeBarOnSide
                         ? LCSpringboardPageCell.sideBarGridBottomMargin - homeBottomSafeInset
                         : LCSpringboardPageCell.gridBottomPadding(safeAreaBottom: homeBottomSafeInset))
            }
        }
    }

    /// Rebuilds `orderedHomeItems` from persisted order + current app list.
    /// Uses the stored home screen order only when the sort type is `.custom`
    /// (i.e. the user has manually dragged cards). For other sort types, the
    /// default-app positions fall back to the front of the list.
    func rebuildOrderedHomeItems() {
        let storedOrder = LCUtils.appGroupUserDefault.stringArray(forKey: FlekDeckKeys.homeScreenOrder) ?? []
        let useStoredOrder = !storedOrder.isEmpty && sharedAppSortManager.appSortType == .custom

        // Build a lookup of all available items by ID
        var available: [String: FlekHomeItem] = [:]
        for kind in [FlekDefaultAppKind.settings, .installer] {
            let item = FlekHomeItem.defaultApp(kind)
            available[item.id] = item
        }
        for app in sortedApps {
            let item = FlekHomeItem.installed(app)
            available[item.id] = item
        }

        var result: [FlekHomeItem] = []
        var lastNewIdx: Int?
        var didReplaceDeleted = false

        if useStoredOrder {
            // Respect the full user-defined order (default apps + installed apps).
            // "__empty__" markers are restored as placeholder items to preserve
            // the user's custom grid layout (free-placement of icons).
            for (slotIndex, id) in storedOrder.enumerated() {
                if id == "__empty__" {
                    result.append(.placeholder("slot.\(slotIndex)"))
                } else if id.hasPrefix("__installing.") && id.hasSuffix("__") {
                    // Persisted as "__installing.<UUID>__" — extract the
                    // inner key so the installing item can reclaim its slot.
                    let inner = String(id.dropFirst(2).dropLast(2)) // "installing.<UUID>"
                    // Check if this install is still active; if not, the slot
                    // becomes available for new apps (uses "installing." prefix
                    // so it's preferred over generic placeholders).
                    let uuidStr = String(inner.dropFirst("installing.".count))
                    let stillActive = installQueue.activeItems.contains { $0.id.uuidString == uuidStr }
                    result.append(.placeholder(stillActive ? inner : "installing.\(slotIndex)"))
                } else if id == "__installing__" {
                    // Legacy single-install marker
                    result.append(.placeholder("installing.\(slotIndex)"))
                } else if let item = available.removeValue(forKey: id) {
                    result.append(item)
                } else {
                    // Deleted app – use distinct prefix so per-page
                    // compaction can remove only these gaps.
                    result.append(.placeholder("deleted.\(slotIndex)"))
                    didReplaceDeleted = true
                }
            }
            // Place new items at the first available placeholder slot.
            // Prefer the slot where the installing icon was so the new
            // app appears at the exact page/position the user dragged to.
            let remainingDefaults = available.values.compactMap { item -> FlekHomeItem? in
                if case .defaultApp = item { return item }
                return nil
            }
            var remainingInstalled = available.values.compactMap { item -> FlekHomeItem? in
                if case .installed = item { return item }
                return nil
            }
            // List layout only: installed apps missing from the stored order
            // are newly installed. `available` is a dictionary, so its values
            // have no stable order — sort them by installation date (oldest
            // first, newest last) so new apps land at the end in install order
            // instead of an arbitrary order that shifts between rebuilds.
            // The grid (springboard) layout is left untouched.
            if homeLayout == FlekHomeLayout.list.rawValue {
                remainingInstalled.sort { lhs, rhs in
                    guard case .installed(let la) = lhs, case .installed(let ra) = rhs else { return false }
                    switch (la.appInfo.installationDate, ra.appInfo.installationDate) {
                    case let (l?, r?): return l < r
                    case (nil, _?):    return true
                    case (_?, nil):    return false
                    case (nil, nil):   return la.appInfo.displayName() < ra.appInfo.displayName()
                    }
                }
            }
            // Only consume freed installing slots (where the install already
            // completed), not slots reserved for still-active queue items.
            let activeIDs = Set(installQueue.activeItems.map { "installing.\($0.id)" })
            let isFreedInstallingSlot: (FlekHomeItem) -> Bool = { item in
                if case .placeholder(let id) = item {
                    return id.hasPrefix("installing.") && !activeIDs.contains(id)
                }
                return false
            }
            for newItem in remainingDefaults + remainingInstalled {
                if let installIdx = result.firstIndex(where: isFreedInstallingSlot) {
                    result[installIdx] = newItem
                    lastNewIdx = installIdx
                } else if let placeholderIdx = result.firstIndex(where: { $0.isPlaceholder }) {
                    result[placeholderIdx] = newItem
                    lastNewIdx = placeholderIdx
                } else {
                    lastNewIdx = result.count
                    result.append(newItem)
                }
            }
        } else {
            // Default layout: settings + installer at the front, then sorted apps
            result = [.defaultApp(.settings), .defaultApp(.installer)]
            result.append(contentsOf: sortedApps.map { .installed($0) })
        }

        // Close the gap a deleted app left, on its own page and nowhere else:
        // the icons after it move up, and the slot it freed goes to the end of
        // that same page as an empty one.
        //
        // The page keeps the number of slots it had, which is the whole point.
        // Page boundaries are recorded beside the order rather than in it, so a
        // page that quietly loses a slot moves every boundary behind it back by
        // one — the first icon of the next screen steps onto this one, and each
        // screen after that follows. Nothing is removed from `result` here for
        // the same reason: its length is what the boundaries are counted in.
        if didReplaceDeleted {
            let isDeletedPlaceholder: (FlekHomeItem) -> Bool = { item in
                if case .placeholder(let id) = item { return id.hasPrefix("deleted.") }
                return false
            }

            var sizes = LCUtils.appGroupUserDefault.array(forKey: FlekDeckKeys.homeScreenPageSizes) as? [Int] ?? []
            let itemsPerPage = max(1, homeItemsPerPage)
            var offset = 0
            var pageIdx = 0
            while offset < result.count {
                // Past the stored sizes lie the uniform pages
                // paginateFromFlatItems() makes for the items beyond them.
                let size = pageIdx < sizes.count ? sizes[pageIdx] : itemsPerPage
                pageIdx += 1
                guard size > 0 else { continue }

                let pageEnd = min(offset + size, result.count)
                var page = Array(result[offset..<pageEnd])
                let freed = page.filter(isDeletedPlaceholder).count
                if freed > 0 {
                    page.removeAll(where: isDeletedPlaceholder)
                    // Distinct ids: `slot.<n>` names a slot by its position in
                    // the stored order, and one of those may already sit at the
                    // end of this page.
                    page.append(contentsOf: (0..<freed).map { .placeholder("freed.\(offset).\($0)") })
                    result.replaceSubrange(offset..<pageEnd, with: page)
                }
                offset = pageEnd
            }

            // A trailing page with nothing left on it is not a page. Only the
            // trailing one here: an emptied page in the middle is closed by the
            // springboard, which writes the tightened layout back itself.
            if !sizes.isEmpty {
                while sizes.count > 1 {
                    let lastPageStart = sizes.dropLast().reduce(0, +)
                    let lastPageEnd = min(lastPageStart + (sizes.last ?? 0), result.count)
                    guard lastPageStart < result.count else {
                        sizes.removeLast()
                        continue
                    }
                    let lastPage = result[lastPageStart..<lastPageEnd]
                    if lastPage.isEmpty || !lastPage.contains(where: { !$0.isPlaceholder }) {
                        result.removeSubrange(lastPageStart..<lastPageEnd)
                        sizes.removeLast()
                    } else {
                        break
                    }
                }
                LCUtils.appGroupUserDefault.set(sizes, forKey: FlekDeckKeys.homeScreenPageSizes)
            }
        }

        // Place installing indicators for each active queue item.
        // Each item reclaims its previously-persisted slot (keyed by UUID)
        // so positions stay stable across rebuilds.
        var newInstallScrollIdx: Int?
        var didPlaceInstalling = false
        for item in installQueue.activeItems {
            let itemKey = "installing.\(item.id)"
            let isInstallingSlot: (FlekHomeItem) -> Bool = { homeItem in
                if case .placeholder(let id) = homeItem { return id == itemKey }
                return false
            }
            let installingItem = FlekHomeItem.installing(item)
            if let installIdx = result.firstIndex(where: isInstallingSlot) {
                // Reclaiming a previously-persisted slot — no scroll needed
                result[installIdx] = installingItem
            } else if let placeholderIdx = result.firstIndex(where: { $0.isPlaceholder }) {
                result[placeholderIdx] = installingItem
                newInstallScrollIdx = newInstallScrollIdx ?? placeholderIdx
                didPlaceInstalling = true
            } else {
                newInstallScrollIdx = newInstallScrollIdx ?? result.count
                result.append(installingItem)
                didPlaceInstalling = true
            }
        }

        // Safety net: ensure every installed app appears in the result.
        // Race conditions between drag-end sync and install completion can
        // occasionally cause an app to be absent from the grid.
        let presentIDs = Set(result.compactMap { $0.id })
        for app in sortedApps {
            let item = FlekHomeItem.installed(app)
            if !presentIDs.contains(item.id) {
                lastNewIdx = result.count
                result.append(item)
            }
        }

        orderedHomeItems = result

        // Persist immediately when the grid changed (new items placed at
        // placeholder slots, installing items placed, or deleted apps
        // replaced with placeholders) so subsequent rebuilds produce a
        // stable layout.
        if lastNewIdx != nil || didReplaceDeleted || didPlaceInstalling {
            persistHomeOrder()
        }

        // Auto-scroll only when a NEW install is initiated (first placement
        // on the grid). Don't scroll when an install completes or when
        // items reclaim their persisted slots on rebuild.
        if let idx = newInstallScrollIdx {
            homeScrollToPage = pageForIndex(idx)
        }
    }

    /// Called when the UIKit springboard finishes a drag-and-drop reorder.
    func handleHomeReorder() {
        persistHomeOrder()
        // If an install finished while the icon was being dragged, the
        // reorder pushes stale items (still containing .installing) back to
        // SwiftUI, overwriting the correct pending update. Detect and rebuild.
        let hasInstallingItems = orderedHomeItems.contains(where: { if case .installing = $0 { return true }; return false })
        if hasInstallingItems && installQueue.activeItems.isEmpty {
            rebuildOrderedHomeItems()
        }
    }

    /// Persists the current home screen order after a drag-and-drop reorder.
    /// Placeholders are saved as `"__empty__"` markers to preserve grid positions.
    func persistHomeOrder() {
        let ids = orderedHomeItems.compactMap { item -> String? in
            // Mark the installing card's slot distinctly so the new app
            // takes the exact same position once install finishes,
            // rather than the first available placeholder on any page.
            if case .installing(let inst) = item { return "__installing.\(inst.id)__" }
            if item.isPlaceholder { return "__empty__" }
            return item.id
        }
        LCUtils.appGroupUserDefault.set(ids, forKey: FlekDeckKeys.homeScreenOrder)
        // Also update the app sort manager for installed app order
        let appIds = orderedHomeItems.compactMap { item -> String? in
            guard case .installed(let app) = item else { return nil }
            return sharedAppSortManager.getUniqueIdentifier(for: app)
        }
        if sharedAppSortManager.appSortType != .custom {
            sharedAppSortManager.appSortType = .custom
        }
        sharedAppSortManager.customSortOrder = appIds
    }

    /// How many icons fit on a springboard page, worked back from the screen —
    /// the same count `LCSpringboardViewController` measures from the page it
    /// has in front of it. Pages the stored sizes say nothing about are this big.
    private var homeItemsPerPage: Int {
        // Mirrors LCSpringboardViewController.recalculateItemsPerPage
        let screenBounds = FlekTheme.screen.bounds
        let safeArea = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets }
            .first ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let pageSize = LCSpringboardPageCell.estimatedPageSize(
            screenSize: screenBounds.size,
            safeAreaInsets: safeArea,
            barOnSide: isHomeBarOnSide
        )
        return LCSpringboardPageCell.itemsPerPage(forPageSize: pageSize)
    }

    /// Returns the page index for a given flat-array position using
    /// the persisted page sizes (or uniform chunking as fallback).
    ///
    /// When the index is beyond the stored page sizes the last page is
    /// filled up to `itemsPerPage` before a new page is assumed —
    /// matching `LCSpringboardViewController.paginateFromFlatItems()`.
    private func pageForIndex(_ index: Int) -> Int {
        let ipp = homeItemsPerPage

        let sizes = LCUtils.appGroupUserDefault.array(forKey: FlekDeckKeys.homeScreenPageSizes) as? [Int] ?? []
        if !sizes.isEmpty {
            var offset = 0
            for (page, size) in sizes.enumerated() {
                offset += size
                if index < offset { return page }
            }
            // Beyond stored sizes: the last page can still hold items
            // up to itemsPerPage (mirroring paginateFromFlatItems).
            let lastPageSize = sizes.last ?? 0
            let room = max(0, ipp - lastPageSize)
            let beyondStored = index - offset
            if beyondStored < room {
                return sizes.count - 1
            }
            let beyondLastPage = beyondStored - room
            return sizes.count + beyondLastPage / ipp
        }

        return index / ipp
    }

    /// Scrolls the springboard to the page containing the given item.
    private func scrollToItem(_ item: FlekHomeItem) {
        guard let idx = orderedHomeItems.firstIndex(where: { $0.id == item.id }) else { return }
        let page = pageForIndex(idx)
        homeScrollToPage = page
    }

    

    func handleHomeTap(_ item: FlekHomeItem) {
        switch item {
        case .defaultApp(let kind):
            let isMultitaskAvailable: Bool = {
                guard #available(iOS 16.0, *) else { return false }
                let mode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
                return mode == .virtualWindow && sharedModel.multiLCStatus != 2
            }()
            if #available(iOS 16.0, *), isMultitaskAvailable {
                openInternalPageForKind(kind)
            } else {
                switch kind {
                case .settings:
                    showSettingsCover = true
                case .installer:
                    installerPreselectFlekstore = false
                    installerPreselectRepoURL = nil
                    showInstallerCover = true
                case .flekstore:
                    installerPreselectFlekstore = true
                    installerPreselectRepoURL = nil
                    showInstallerCover = true
                }
            }
        case .installed(let app):
            FlekLaunchTracker.shared.markLaunched(app)
            let mode = FlekLaunchModeStore.shared.mode(for: app)
            // Only ask where a parallel launch is actually possible. `launchHomeApp`
            // falls back to a single launch below iOS 16 and in a secondary
            // LiveContainer install, so the prompt would record a preference that
            // could never be honoured — and "remember my choice" defaults to on.
            if mode == nil, isGame(app), sharedModel.multiLCStatus != 2, #available(iOS 16.0, *) {
                gameWarningTarget = FlekGameWarningTarget(app: app)
            } else {
                let parallel = mode != nil ? (mode == .parallel) : app.shouldLaunchInMultitaskMode
                Task { await launchHomeApp(app, parallel: parallel) }
            }
        case .installing(let inst):
            // A failed install is tappable — open the alert offering to delete it.
            if inst.installState.failed { failedInstallItem = inst }
        case .placeholder:
            break
        }
    }

    /// Opens the installer on one source — as a multitask window where that is
    /// available, and as a full-screen page otherwise.
    private func openInstaller(atRepo repoURL: String) {
        let isMultitaskAvailable: Bool = {
            guard #available(iOS 16.0, *) else { return false }
            let mode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
            return mode == .virtualWindow && sharedModel.multiLCStatus != 2
        }()
        if #available(iOS 16.0, *), isMultitaskAvailable {
            openInternalPageForKind(.installer, preselectRepoURL: repoURL)
        } else {
            installerPreselectFlekstore = false
            installerPreselectRepoURL = repoURL
            showInstallerCover = true
        }
    }

    @available(iOS 16.0, *)
    private func openInternalPageForKind(_ kind: FlekDefaultAppKind, preselectRepoURL: String? = nil) {
        let dockManager = MultitaskDockManager.shared
        
        switch kind {
        case .settings:
            dockManager.openInternalPage(kind: "settings", uuid: "internal-settings", name: "lc.tabView.settings".loc) {
                StandaloneSettingsView()
                    .environmentObject(sharedModel)
                    .environmentObject(sceneDelegate)
            }
        case .installer:
            dockManager.openInternalPage(kind: "installer", uuid: "internal-installer", name: "Installer") {
                FlekInstallerView(preselectFlekstore: false, preselectRepoURL: preselectRepoURL) {
                    dockManager.closeApp(uuid: "internal-installer")
                }
                .environmentObject(sharedModel)
                .environmentObject(sceneDelegate)
            }
        case .flekstore:
            // FlekStore reuses the installer UUID — if already open, bring to front
            if dockManager.apps.contains(where: { $0.appUUID == "internal-installer" }) {
                let _ = dockManager.bringMultitaskViewToFront(uuid: "internal-installer")
            } else {
                dockManager.openInternalPage(kind: "flekstore", uuid: "internal-installer", name: "FlekSt0re") {
                    FlekInstallerView(preselectFlekstore: true) {
                        dockManager.closeApp(uuid: "internal-installer")
                    }
                    .environmentObject(sharedModel)
                    .environmentObject(sceneDelegate)
                }
            }
        }
    }

    // moveHomeItem is no longer needed — Dragula handles reordering
    // directly via the bound items array, and persistHomeOrder() saves
    // the result on drop completion.

    /// Whether a guest app is a game. Prefers the flag computed and cached at
    /// install time (see `GameDetector` and the install path in `installIpaFile`);
    /// falls back to computing it now for apps installed before caching existed
    /// (and caches the result so it's a cheap flag read next time).
    func isGame(_ app: LCAppModel) -> Bool {
        let info = app.appInfo.info()
        // Trust the cached flag only if it was computed by the current detector.
        if (info?["LCIsGameV"] as? Int) == GameDetector.detectorVersion,
           let cached = info?["LCIsGame"] as? Bool {
            return cached
        }
        guard let bundlePath = app.appInfo.bundlePath(), !bundlePath.isEmpty else { return false }
        let result = GameDetector.isGame(bundlePath: bundlePath)
        info?["LCIsGame"] = result
        info?["LCIsGameV"] = GameDetector.detectorVersion
        app.appInfo.save()
        return result
    }

    func launchHomeApp(_ app: LCAppModel, parallel: Bool) async {
        if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) { return }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        do {
            if #available(iOS 16.0, *), sharedModel.multiLCStatus != 2, parallel {
                try await app.runApp(multitask: true)
            } else {
                try await app.runApp(multitask: false)
            }
        } catch let notReady as FlekJITSetup.NotReady {
            showJITNotReady(notReady) {
                await launchHomeApp(app, parallel: parallel)
            }
        } catch is FlekLocationSpoofer.PremiumNeeded {
            locationSpooferNeedsPremium = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    /// Says why an app set to launch with JIT was not started. Where all that
    /// is missing is the connection, which the user is about to change, the
    /// launch is kept and started once they have, with the warning up until
    /// then: Control Center opens over it.
    private func showJITNotReady(_ notReady: FlekJITSetup.NotReady, retry: @escaping () async -> Void) {
        if let message = notReady.messageWhileWaiting {
            waitingLaunch = retry
            if connectionWatch == nil {
                connectionWatch = FlekJITSetup.ConnectionWatch {
                    retryWaitingLaunch()
                }
            }
            // Over mobile data the FlekJIT shortcut switches Mobile Data off,
            // where the user has added it, and the launch goes on from there.
            // The user is asked only if that leads nowhere.
            if notReady.isOverMobileData, FlekMobileDataShortcut.shared.isOn, !hasRunShortcutForLaunch {
                hasRunShortcutForLaunch = true
                isRunningShortcut = true
                FlekMobileDataShortcut.shared.turnMobileDataOff { outcome in
                    isRunningShortcut = false
                    // One that did not run to its end has most likely switched
                    // nothing, which a look or two shows.
                    quietTriesAfterShortcut = outcome == .done ? 6 : 2
                    retryWaitingLaunch()
                }
                return
            }
            presentJITNotReady(title: notReady.title, message: message)
        } else {
            abandonWaitingLaunch()
            presentJITNotReady(title: notReady.title, message: notReady.message)
        }
    }

    /// The warning that is up, or about to be.
    private var jitNotReadyShown: String? {
        jitNotReadyNext?.message ?? jitNotReadyMessage
    }

    private func presentJITNotReady(title: String, message: String) {
        guard jitNotReadyShown != message else { return }
        guard jitNotReadyMessage != nil || jitNotReadyNext != nil else {
            jitNotReadyTitle = title
            jitNotReadyMessage = message
            return
        }
        // The one that is up goes first, and the latest asked for follows it.
        let isAlreadyChanging = jitNotReadyNext != nil
        jitNotReadyNext = (title, message)
        jitNotReadyMessage = nil
        guard !isAlreadyChanging else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let next = jitNotReadyNext else { return }
            jitNotReadyNext = nil
            jitNotReadyTitle = next.title
            jitNotReadyMessage = next.message
        }
    }

    private func stopWaitingForConnection() {
        waitingLaunch = nil
        connectionWatch = nil
        hasRunShortcutForLaunch = false
    }

    /// The launch that waited is not going to be started: Mobile Data that
    /// the shortcut switched off for it goes back on.
    private func abandonWaitingLaunch() {
        stopWaitingForConnection()
        FlekMobileDataShortcut.shared.turnMobileDataBackOn()
    }

    /// The connection has changed, or FlekDeck is back in front, with a
    /// launch waiting: asks again whether JIT can be started, a few times
    /// over, as what a change of connection opens takes a moment to open.
    private func retryWaitingLaunch() {
        guard waitingLaunch != nil, !isRetryingLaunch, !isRunningShortcut,
              UIApplication.shared.applicationState == .active else {
            return
        }
        isRetryingLaunch = true
        let afterShortcut = quietTriesAfterShortcut > 0
        let tries = afterShortcut ? quietTriesAfterShortcut : 4
        quietTriesAfterShortcut = 0
        Task {
            defer { isRetryingLaunch = false }
            for attempt in 0..<tries {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                guard let launch = waitingLaunch else { return }
                do {
                    try await FlekJITSetup.ensureReady()
                    // Off mobile data, and the device not answering yet: what
                    // the shortcut switched is still taking.
                    if afterShortcut, attempt < tries - 1, !(await FlekBuiltInJIT.isDeviceReachable()) {
                        continue
                    }
                } catch let notReady as FlekJITSetup.NotReady {
                    guard let message = notReady.messageWhileWaiting else {
                        // Something else is in the way now.
                        showJITNotReady(notReady, retry: launch)
                        return
                    }
                    if afterShortcut {
                        guard attempt == tries - 1 else { continue }
                        // After all that the shortcut has not got the device
                        // off mobile data, and the user is asked, as without
                        // it. Mobile Data it did switch off, for a launch that
                        // now waits on something else, goes back on.
                        if notReady.isOverMobileData {
                            FlekMobileDataShortcut.shared.forget()
                        } else {
                            FlekMobileDataShortcut.shared.turnMobileDataBackOn()
                        }
                        presentJITNotReady(title: notReady.title, message: message)
                        return
                    }
                    if message != jitNotReadyShown {
                        // The next step of the same errand: Airplane Mode off
                        // for the VPN to start, then on again.
                        presentJITNotReady(title: notReady.title, message: message)
                        return
                    }
                    continue
                } catch {
                    return
                }
                stopWaitingForConnection()
                jitNotReadyNext = nil
                jitNotReadyMessage = nil
                await launch()
                return
            }
        }
    }

    // MARK: - Home context menu

    @ViewBuilder
    // MARK: - UIKit Context Menu (for UIKit springboard)

    /// An icon's menu, with "Open in Split View" added where two apps can be put
    /// side by side: on an iPhone Duo opened out.
    func homeUIMenu(for item: FlekHomeItem) -> UIMenu? {
        let menu = homeUIMenuItems(for: item)
        guard #available(iOS 16.0, *), let split = openInSplitViewAction(for: item) else { return menu }
        var children = menu?.children ?? []
        // Below the launch modes where an app's menu starts with them.
        let index = (children.first as? UIMenu)?.options.contains(.displayInline) == true ? 1 : 0
        children.insert(split, at: index)
        return UIMenu(title: menu?.title ?? "", children: children)
    }

    @available(iOS 16.0, *)
    private func openInSplitViewAction(for item: FlekHomeItem) -> UIAction? {
        switch item {
        case .defaultApp, .installed: break
        default: return nil
        }
        guard MultitaskDockManager.shared.canSplitNow else { return nil }
        return UIAction(
            title: "lc.flek.openInSplitView".loc,
            image: UIImage(systemName: "rectangle.split.2x1")
        ) { _ in
            MultitaskDockManager.shared.openInSplitView(item)
        }
    }

    /// Lets the multitask dock list the home screen's apps, for the side of the
    /// screen choosing one, and open them there.
    @available(iOS 16.0, *)
    private func registerSplitHooks() {
        let dock = MultitaskDockManager.shared
        dock.splitHomeItems = { orderedHomeItems }
        dock.splitOpenHomeItem = { item in openHomeItemInWindow(item) }
    }

    /// Opens a home item in a window of its own, whatever launch mode it is set
    /// to: on a side of the screen an app can only be a window.
    @available(iOS 16.0, *)
    private func openHomeItemInWindow(_ item: FlekHomeItem) {
        switch item {
        case .defaultApp(let kind):
            openInternalPageForKind(kind)
        case .installed(let app):
            FlekLaunchTracker.shared.markLaunched(app)
            Task { await launchHomeApp(app, parallel: true) }
        default:
            break
        }
    }

    private func homeUIMenuItems(for item: FlekHomeItem) -> UIMenu? {
        switch item {
        case .defaultApp(let kind):
            guard kind != .settings && kind != .installer else { return nil }
            let moveCards = UIAction(
                title: "lc.appBanner.moveCards".loc,
                image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            ) { [self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isEditing = true
                }
            }
            return UIMenu(title: "", children: [moveCards])
        case .installed(let app):
            return installedUIMenu(app)
        case .installing(let inst):
            let cancel = UIAction(
                title: "lc.flek.cancelInstall".loc,
                image: UIImage(systemName: FlekSymbol.cancelDownload),
                attributes: .destructive
            ) { _ in
                LCInstallQueue.shared.cancel(inst)
            }
            return UIMenu(title: "", children: [cancel])
        case .placeholder:
            return nil
        }
    }

    private func installedUIMenu(_ app: LCAppModel) -> UIMenu {
        let currentMode = FlekLaunchModeStore.shared.mode(for: app)
        let effectiveIsParallel = currentMode != nil ? (currentMode == .parallel) : app.shouldLaunchInMultitaskMode

        let keepOpen: UIMenuElement.Attributes
        if #available(iOS 16.0, *) {
            keepOpen = .keepsMenuPresented
        } else {
            keepOpen = []
        }

        // `preferredElementSize = .medium` lays the two modes out as a compact
        // palette, which has no checkmark column: `state == .on` draws nothing
        // there. iOS 26 tints the selected element instead, so it reads correctly,
        // but every earlier system left the menu with no sign of the active mode.
        //
        // Rather than give up the compact layout, carry the indicator in the image
        // on those systems — the image is always drawn. `state` stays set either
        // way, so `.singleSelection` still enforces the radio behaviour and iOS 26
        // keeps using its own styling.
        let usesCompactLayout: Bool
        let stylesSelectionItself: Bool
        if #available(iOS 26.0, *) {
            usesCompactLayout = true
            stylesSelectionItself = true
        } else if #available(iOS 16.0, *) {
            usesCompactLayout = true
            stylesSelectionItself = false
        } else {
            // Full-width rows, where the checkmark renders on its own.
            usesCompactLayout = false
            stylesSelectionItself = true
        }
        let markInImage = usesCompactLayout && !stylesSelectionItself
        let isSingle = !effectiveIsParallel

        /// UIKit exposes no per-element background tint — `state` is the only
        /// selection mechanism, and iOS 26's tinted element is its own styling
        /// rather than something that can be asked for. The image is the one part
        /// of a compact element we control, so colour the active mode's glyph
        /// instead; `.alwaysOriginal` keeps that colour rather than letting the
        /// menu re-template it to the label colour.
        ///
        /// Green rather than the accent: the accent is close enough to the menu's
        /// own label colour to read as no change at all at palette icon size, so
        /// the cue needs a hue that is obviously not the default.
        func modeImage(_ name: String, selected: Bool) -> UIImage? {
            let image = UIImage(systemName: name)
            guard markInImage, selected else { return image }
            return image?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
        }

        let runSingle = UIAction(
            title: "lc.appBanner.runSingle".loc,
            image: modeImage("app.dashed", selected: isSingle),
            attributes: keepOpen,
            state: effectiveIsParallel ? .off : .on
        ) { _ in
            FlekLaunchModeStore.shared.set(.single, for: app)
            LCSpringboardPageCell.refreshActiveContextMenu()
            LCSpringboardPageCell.refreshActiveCellBadge()
        }
        let runParallel = UIAction(
            title: "lc.appBanner.runParallel".loc,
            image: modeImage("macwindow.on.rectangle", selected: !isSingle),
            attributes: keepOpen,
            state: effectiveIsParallel ? .on : .off
        ) { _ in
            FlekLaunchModeStore.shared.set(.parallel, for: app)
            LCSpringboardPageCell.refreshActiveContextMenu()
            LCSpringboardPageCell.refreshActiveCellBadge()
        }
        let launchGroup = UIMenu(title: "", options: [.displayInline, .singleSelection], children: [runSingle, runParallel])
        if usesCompactLayout, #available(iOS 16.0, *) {
            launchGroup.preferredElementSize = .medium
        }

        let copyUrl = UIAction(
            title: "lc.appBanner.copyLaunchUrl".loc,
            image: UIImage(systemName: "link")
        ) { [self] _ in
            homeCopyLaunchUrl(app)
        }
        let saveIcon = UIAction(
            title: "lc.appBanner.saveAppIcon".loc,
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [self] _ in
            Task { await homeSaveIcon(app) }
        }
        let createClip = UIAction(
            title: "lc.appBanner.createAppClip".loc,
            image: UIImage(systemName: "appclip")
        ) { [self] _ in
            Task { await homeCreateAppClip(app) }
        }
        let addToHomeScreen = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [copyUrl, saveIcon, createClip]
        )

        // Same toggle as the Lock App switch in the app's settings, surfaced here
        // so it's one long-press away. Labelled by the action it performs, not the
        // state it's in.
        let lockToggle = UIAction(
            title: app.uiIsLocked ? "lc.appBanner.dontRequireFaceId".loc : "lc.appBanner.requireFaceId".loc,
            image: UIImage(systemName: app.uiIsLocked ? "lock.open" : "faceid")
        ) { [self] _ in
            Task { await toggleAppLock(app) }
        }

        let settings = UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [self] _ in
            Task { await openAppSettings(app) }
        }

        let moveCards = UIAction(
            title: "lc.appBanner.moveCards".loc,
            image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        ) { [self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditing = true
            }
        }

        // Offered for a shared app too, the same as the minus in edit mode:
        // `requestUninstall` converts it to a private app on the way out rather
        // than the menu leaving the user nowhere to go.
        let uninstall = UIAction(
            title: "lc.appBanner.uninstall".loc,
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [self] _ in
            Task { await requestUninstall(app) }
        }

        let children: [UIMenuElement] = [launchGroup, addToHomeScreen, lockToggle, settings, moveCards, uninstall]

        return UIMenu(title: "", children: children)
    }

    @ViewBuilder
    func homeContextMenu(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp(let kind):
            // Built-in apps: only the "arrange" action is offered (they can be
            // moved but not removed). Settings/Installer have no menu (matches grid).
            if kind != .settings && kind != .installer {
                Button {
                    // Delay so the context menu dismissal animation finishes
                    // before the view switches to edit mode.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isEditing = true
                    }
                } label: {
                    Label("lc.appBanner.moveCards".loc, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
            }
        case .installed(let app):
            installedContextMenu(app)
        case .installing, .placeholder:
            EmptyView()
        }
    }

    /// The single/parallel launch-mode picker.
    ///
    /// Erased to AnyView: `ControlGroup` is iOS 16+ and `menuActionDismissBehavior`
    /// is iOS 16.4+, so with an opaque return type both would land in this
    /// function's static type. The runtime resolves that type before the
    /// availability check runs, so a system without them traps rather than falling
    /// back. The erasure is kept to this one menu item — the surrounding menu
    /// content stays a plain ViewBuilder so SwiftUI can still see its items.
    private func launchModeControls(_ app: LCAppModel) -> AnyView {
        if #available(iOS 16.4, *) {
            return AnyView(
                ControlGroup { launchModeButtons(app) }
                    .menuActionDismissBehavior(.disabled)
            )
        }
        if #available(iOS 16.0, *) {
            return AnyView(ControlGroup { launchModeButtons(app) })
        }
        return AnyView(Group { launchModeButtons(app) })
    }

    @ViewBuilder
    private func launchModeButtons(_ app: LCAppModel) -> some View {
        Button {
            FlekLaunchModeStore.shared.set(.single, for: app)
            launchModeVersion += 1
        } label: {
            Label("lc.appBanner.runSingle".loc, systemImage: "app.dashed")
        }
        Button {
            FlekLaunchModeStore.shared.set(.parallel, for: app)
            launchModeVersion += 1
        } label: {
            Label("lc.appBanner.runParallel".loc, systemImage: "macwindow.on.rectangle")
        }
    }

    @ViewBuilder
    private func installedContextMenu(_ app: LCAppModel) -> some View {
        // Fixed grid symbols; the menu stays open on tap (launchModeVersion +
        // menuActionDismissBehavior) so multiple picks behave like the grid.
        launchModeControls(app)

        Menu {
            Button {
                homeCopyLaunchUrl(app)
            } label: {
                Label("lc.appBanner.copyLaunchUrl".loc, systemImage: "link")
            }
            Button {
                Task { await homeSaveIcon(app) }
            } label: {
                Label("lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await homeCreateAppClip(app) }
            } label: {
                Label("lc.appBanner.createAppClip".loc, systemImage: "appclip")
            }
        } label: {
            Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
        }

        // Same toggle as the Lock App switch in the app's settings, surfaced here
        // so it's one long-press away. Labelled by the action it performs, not the
        // state it's in.
        Button {
            Task { await toggleAppLock(app) }
        } label: {
            if app.uiIsLocked {
                Label("lc.appBanner.dontRequireFaceId".loc, systemImage: "lock.open")
            } else {
                Label("lc.appBanner.requireFaceId".loc, systemImage: "faceid")
            }
        }

        Button {
            Task { await openAppSettings(app) }
        } label: {
            Label("lc.tabView.settings".loc, systemImage: "gear")
        }

        Button {
            // Rearranging happens on the home screen, so leave search if it's up.
            showSearch = false
            // Delay so the context menu dismissal animation finishes
            // before the view switches to edit mode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditing = true
            }
        } label: {
            Label("lc.appBanner.moveCards".loc, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
        }

        Button(role: .destructive) {
            Task { await requestUninstall(app) }
        } label: {
            Label("lc.appBanner.uninstall".loc, systemImage: "trash")
        }
    }

    /// Flip the app's lock, mirroring the settings screen's Lock App toggle: write the
    /// published state first, then let `setLocked` do the work. Turning the lock off
    /// prompts for Face ID and rolls `uiIsLocked` back itself if that fails; it also
    /// clears the hidden flag, so a hidden app returns to the springboard.
    func toggleAppLock(_ app: LCAppModel) async {
        let newLockState = !app.uiIsLocked
        app.uiIsLocked = newLockState
        await app.setLocked(newLockState: newLockState)
    }

    /// A locked app's settings hold the lock and hide toggles, so authenticate before
    /// showing them — the same gate `LCAppBanner` applies. This matters now that
    /// hidden apps are reachable from search: without it the menu would hand out an
    /// unhide switch to anyone who can type the app's name.
    func openAppSettings(_ app: LCAppModel) async {
        if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) { return }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        showSearch = false
        openNavigationView(view: AnyView(LCAppSettingsView(model: app)))
    }

    func homeCopyLaunchUrl(_ app: LCAppModel) {
        guard let path = app.appInfo.relativeBundlePath else { return }
        if let fn = app.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "flekdeck://livecontainer-launch?bundle-name=\(path)&container-folder-name=\(fn)"
        } else {
            UIPasteboard.general.string = "flekdeck://livecontainer-launch?bundle-name=\(path)"
        }
    }

    func homeSaveIcon(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        guard let img = app.appInfo.generateLiveContainerWrappedIcon(with: style) else { return }
        homeSaveIconFile = ImageDocument(uiImage: img)
        homeSaveIconExporterShow = true
    }

    func homeCreateAppClip(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: app.appInfo.generateWebClipConfig(withContainerId: app.uiSelectedContainer?.folderName, iconStyle: style)!,
                format: .xml, options: 0)
            installMdm(data: data)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    /// Asks about, and then performs, an uninstall from the home screen.
    ///
    /// A shared app is not this install's copy to take away, so it gets its own
    /// confirmation, and saying yes converts it to a private app first — which
    /// is what makes it deletable at all, `uninstall` refusing a shared bundle.
    /// Everything after that point is the same for both kinds of app.
    func requestUninstall(_ app: LCAppModel) async {
        do {
            if app.isUninstallable {
                if let r = await homeUninstallAlert.open(), !r { return }
            } else {
                // Asked before the confirmation, so a FlekDeck that cannot
                // convert says so rather than putting the user to a decision it
                // is not going to honour.
                try app.checkCanConvertToPrivate(sharedModel: sharedModel)
                guard let r = await homeSharedUninstallAlert.open(), r else { return }
                // Its tweak folder stays where it is: the app is on its way out,
                // and the shared copy may be another shared app's too.
                try app.convertToPrivate(sharedModel: sharedModel, movingTweakFolder: false)
            }

            var doRemoveFolder = false
            if !app.appInfo.containers.isEmpty {
                if let r = await homeUninstallFolderAlert.open() { doRemoveFolder = r }
            }

            try app.uninstall(removingContainers: doRemoveFolder)
            removeApp(app: app)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
        appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }
            
            
            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }
    
    
    
    func startInstallApp(_ fileUrl:URL) async {
        installQueue.enqueue(url: fileUrl.absoluteString, name: nil, iconURL: nil)
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    /// Finds the `.app` bundle inside a decompressed IPA tree, tolerating archives
    /// that don't use the standard top-level `Payload/App.app` layout (a wrapper
    /// folder with different casing or name, extra nesting, or no wrapper at all).
    /// Breadth-first so the shallowest match wins, preferring one directly inside a
    /// `Payload` folder. Does not descend into a found `.app`. Returns nil if none.
    nonisolated static func findAppBundle(in root: URL, fm: FileManager) -> URL? {
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var fallback: URL? = nil
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard depth <= 8,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if entry.pathExtension.lowercased() == "app" {
                    if entry.deletingLastPathComponent().lastPathComponent.lowercased() == "payload" {
                        return entry
                    }
                    if fallback == nil { fallback = entry }
                } else {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return fallback
    }

    func installIpaFile(_ url:URL, item: InstallItem) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        let observedItem = item
        let queue = installQueue
        let installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                queue.updateInstallProgress(observedItem, fraction: p.fractionCompleted)
            }
        }
        // Keep observer alive for the duration of this method
        _ = installObserver
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        // Decompress into a clean, dedicated folder (auto-removed when this method
        // exits) so the extracted tree is isolated from other temp files.
        let extractDir = fm.temporaryDirectory.appendingPathComponent("lc_extract_\(UUID().uuidString)")
        if fm.fileExists(atPath: extractDir.path) {
            try fm.removeItem(at: extractDir)
        }
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        // decompress
        guard await decompress(url.path, extractDir.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        // Locate the .app bundle anywhere in the extracted tree. A valid IPA uses a
        // top-level `Payload/App.app`, but archives in the wild often differ — a
        // wrapper folder with different casing or name, an extra level of nesting,
        // or no wrapper at all — so search for the .app rather than assume `Payload/`.
        guard let appFolderPath = Self.findAppBundle(in: extractDir, fm: fm) else {
            throw "lc.appList.bundleNotFondError".loc
        }
        
        // Name and icon chosen on the app's page, applied before LCAppInfo reads
        // the bundle — it parses Info.plist once at init, so a later edit to the
        // display name would go unnoticed.
        item.overrides?.applyNameAndIcon(toBundleAt: appFolderPath)

        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }
        item.resolvedName = newAppInfo.displayName()

        // A bundle ID chosen on the app's page. Goes through LCAppInfo rather
        // than the plist directly, so the original is recorded the way
        // LiveContainer expects.
        if let chosenBundleId = item.overrides?.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chosenBundleId.isEmpty {
            newAppInfo.overrideBundleIdentifier(chosenBundleId)
        } else if LCUtils.appGroupUserDefault.bool(forKey: "LCCustomBundleIdEnabled") {
            // Show bundle ID customization if enabled in settings
            guard let chosenBundleId = await bundleIdInput.open(
                initVal: newAppInfo.bundleIdentifier()!
            ) else {
                // User cancelled
                throw CancellationError()
            }
            let trimmed = chosenBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != newAppInfo.bundleIdentifier()! {
                newAppInfo.overrideBundleIdentifier(trimmed)
            }
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Where the bundle being replaced is parked while its replacement moves in.
        var replacedBundleBackup : URL? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        throw CancellationError()
                    }
                } catch {
                    throw error
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            // Sanitised like the first-install name above: this becomes the app's
            // relativeBundlePath, which is interpolated straight into
            // flekdeck://livecontainer-launch?bundle-name=… URLs, so a
            // non-ASCII bundle id here would produce a launch URL that no longer
            // parses — breaking Add to Home Screen and the relaunch handoff.
            appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII())_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }
            
            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                throw CancellationError()
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            // Nothing to move aside when the entry being replaced has already lost
            // its folder — reinstalling over such a leftover is how the user gets
            // rid of it, so it must not fail the way removing a missing folder did.
            if installOptionChosen.isReplace, fm.fileExists(atPath: outputFolder.path) {
                // Move the app being replaced aside rather than deleting it, and
                // only drop it once its replacement is in place. Deleting first
                // leaves nothing behind if the move then fails or the process is
                // killed in between: the list keeps an entry pointing at a folder
                // that no longer exists, which can be neither launched, converted
                // between private and shared, nor — for a shared app — removed.
                // LCPath.replacingSuffix names the copy so that an interrupted
                // install is put back on the next launch.
                replacedBundleBackup = outputFolder
                    .deletingLastPathComponent()
                    .appendingPathComponent(outputFolder.lastPathComponent + LCPath.replacingSuffix)
                try? fm.removeItem(at: replacedBundleBackup!)
                try fm.moveItem(at: outputFolder, to: replacedBundleBackup!)
            }
        }
        // Move it!
        do {
            try fm.moveItem(at: appFolderPath, to: outputFolder)
        } catch {
            if let replacedBundleBackup {
                try? fm.moveItem(at: replacedBundleBackup, to: outputFolder)
            }
            throw error
        }
        if let replacedBundleBackup {
            // Out of the Applications folder in one rename, then deleted on a
            // queue of its own: a bundle runs to thousands of files, and removing
            // them here held the main thread as the install finished. rename(2)
            // rather than a move, which across volumes would copy the whole app.
            let discarded = fm.temporaryDirectory.appendingPathComponent("lc_replaced_\(UUID().uuidString)")
            if rename(replacedBundleBackup.path, discarded.path) == 0 {
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager().removeItem(at: discarded)
                }
            } else {
                try? fm.removeItem(at: replacedBundleBackup)
            }
        }
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
            finalNewApp.dontSign = true
        }
        // On a queue of its own: before the signer takes over, patching goes
        // through every file of the bundle twice, opening each one, which for a
        // large app held the main thread, and the screen with it, for seconds.
        let (signSuccess, signError) = await withUnsafeContinuation { (c: UnsafeContinuation<(Bool, String?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                    c.resume(returning: (success, error))
                }, progressHandler: { signProgress in
                    installProgress.addChild(signProgress!, withPendingUnitCount: 20)
                }, forceSign: false)
            }
        }
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.spoofLocation = appToReplace.appInfo.spoofLocation
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.jitLaunchScriptName = appToReplace.appInfo.jitLaunchScriptName
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        // WhatsApp never delivers a local notification unless the fix under the
        // app's Fixes section is on, so turn it on here instead of leaving the
        // user to discover the toggle. Matching the bundle id loosely covers the
        // whole family (net.whatsapp.WhatsApp, .WhatsAppSMB, re-signed clones).
        // Deliberately applied on reinstall too — an app updated from an older
        // install should end up with the fix on as well.
        if finalNewApp.bundleIdentifier()?.localizedCaseInsensitiveContains("whatsapp") ?? false {
            finalNewApp.fixLocalNotification = true
        }
        finalNewApp.installationDate = Date.now
        // Detect (once) whether this is a game and cache it, so the launch-time
        // check is a cheap flag read instead of a per-tap bundle scan. Runs off
        // the main thread here, after the bundle is in place and signed.
        if let installedBundlePath = finalNewApp.bundlePath() {
            finalNewApp.info()?["LCIsGame"] = GameDetector.isGame(bundlePath: installedBundlePath)
            finalNewApp.info()?["LCIsGameV"] = GameDetector.detectorVersion
            let landscapeOnly = AppOrientation.isLandscapeOnly(bundlePath: installedBundlePath)
            finalNewApp.info()?["LCLandscapeOnly"] = landscapeOnly
            // An app that declares only landscape gets its orientation toggle set to
            // match, so it opens the right way round by itself instead of coming up
            // portrait with a message asking the user to turn the device.
            //
            // Only while the toggle is still at its default: an update copies the
            // previous install's `orientationLock`, and a choice the user made once
            // has to survive the app being updated. Written into the same dictionary
            // as the flags above — `orientationLock` reads this key — so the save
            // below persists all of it in one write.
            if landscapeOnly, finalNewApp.orientationLock == .Disabled {
                finalNewApp.info()?["LCOrientationLock"] = LCOrientationLock.Landscape.rawValue
            }
            finalNewApp.save()
        }

        await MainActor.run {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
                
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }
            
            // Don't rebuild here — the install item is still in
            // .installing phase so its slot won't be freed for the new
            // app.  The rebuild is triggered after markCompleted() sets
            // .completed, via .onChange(of: completedURLs.count).
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) {
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        // A file opened from the Files app is not readable by path: access has
        // to be claimed before anything can open it, and the claim belongs to
        // this moment. The queue installs asynchronously and would reach the
        // file long after the claim lapsed, so it is copied somewhere we own
        // while the claim is still held and the copy is what gets queued.
        var queuedUrl = urlStr
        if let url = URL(string: urlStr), url.isFileURL {
            if let staged = stageSecurityScopedIpaIfNeeded(url) {
                queuedUrl = staged.absoluteString
            } else if !FileManager.default.isReadableFile(atPath: url.path) {
                // Queueing it anyway would install nothing and report that the
                // file is not an IPA, which sends the user off looking at a
                // file that is perfectly fine.
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
        }

        installQueue.enqueue(url: queuedUrl, name: nil, iconURL: nil)
    }

    /// Copies an IPA that is only reachable through a security scope into our
    /// own temporary directory, and returns the copy.
    ///
    /// Returns nil when the file is already readable — the ordinary case for
    /// anything chosen with the document picker, which needs no copy — and
    /// when no copy could be made, which the caller tells the difference
    /// between by looking at the file again.
    private func stageSecurityScopedIpaIfNeeded(_ url: URL) -> URL? {
        let fm = FileManager.default
        if fm.isReadableFile(atPath: url.path) { return nil }

        var resolved = url
        // A file opened in place -- Files' Open With, and the button its
        // preview puts at the bottom -- arrives carrying its own scope, so
        // claim that first.
        var didStartAccessing = url.startAccessingSecurityScopedResource()
        // The bookmark is only ever about a file the share extension handed
        // over. Reading it first meant that any bookmark left in the app group
        // -- and nothing here ever cleared one -- silently redirected the
        // install to whatever had last been shared, so it is consulted only
        // when the URL did not open on its own, and only when it names the
        // same file.
        if !FileManager.default.isReadableFile(atPath: resolved.path),
           let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
            var isStale = false
            if let bookmarkUrl = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), bookmarkUrl.lastPathComponent == url.lastPathComponent {
                if didStartAccessing {
                    resolved.stopAccessingSecurityScopedResource()
                }
                resolved = bookmarkUrl
                didStartAccessing = bookmarkUrl.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if didStartAccessing {
                resolved.stopAccessingSecurityScopedResource()
            }
        }

        guard fm.isReadableFile(atPath: resolved.path) else { return nil }

        let dest = fm.temporaryDirectory.appendingPathComponent(resolved.lastPathComponent)
        // The same file can be handed over twice — the scene delegate parks
        // every URL UIKit gives it, and SwiftUI may deliver that same URL on
        // its own. The queue drops the second install, but only after this has
        // run, and re-copying over a file the first install is reading would
        // pull the ground out from under it.
        if installQueue.item(for: dest.absoluteString) != nil {
            return dest
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: resolved, to: dest)
        } catch {
            return nil
        }
        return dest
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }

            // Withdraw the app's URL schemes. Only the ones no remaining visible
            // app declares: two installs of the same guest claim the same schemes,
            // and this list is rebuilt from exactly those apps at launch. Without
            // this, LiveContainer keeps claiming the removed app's schemes for the
            // rest of the session — and a secondary instance, which never rebuilds
            // the list, keeps claiming them for good.
            if let schemes = app.appInfo.urlSchemes() as? [String], !schemes.isEmpty {
                let stillClaimed = Set(sharedModel.apps.flatMap { $0.appInfo.urlSchemes() as? [String] ?? [] })
                let toWithdraw = schemes.filter { !stillClaimed.contains($0) }
                if !toWithdraw.isEmpty {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .removeObjects(in: toWithdraw)
                }
            }

            // The launcher's own records are keyed by the app's folder name and
            // live in the app group, so nothing about uninstalling the app — or
            // even reinstalling LiveContainer — clears them on its own. Left
            // behind, the next install of the same app silently adopts the old
            // app's launch mode and never shows as new.
            FlekLaunchModeStore.shared.forget(app)
            FlekLaunchTracker.shared.forget(app)

            // The app's slot in the home order is deliberately left alone here.
            // `rebuildOrderedHomeItems` is what takes an app off the grid: an id
            // it can no longer resolve becomes an empty slot on the page the app
            // was on, the icons behind it close the gap, and the tightened order
            // is written back.
            //
            // Splicing the id out first is what stopped that happening. It shifts
            // every id after it back one place, so the rebuild finds nothing
            // missing, skips the whole per-page pass — and the first icon of the
            // next screen steps back onto this one to fill the hole.
            if let uniqueId = sharedAppSortManager.getUniqueIdentifier(for: app) {
                sharedAppSortManager.customSortOrder.removeAll { $0 == uniqueId }
            }
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch let notReady as FlekJITSetup.NotReady {
            showJITNotReady(notReady) {
                await launchAppWithBundleId(bundleId: bundleId, container: container, urlStr: urlStr, forceJIT: forceJIT)
            }
        } catch is FlekLocationSpoofer.PremiumNeeded {
            locationSpooferNeedsPremium = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StikJITHeadless {
                    // let guest app spawn it
                    return
                }
                
                let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        // Nothing takes the link where StikDebug is not
                        // installed, and the window would wait for JIT unanswered.
                        UIApplication.shared.open(url) { opened in
                            if !opened {
                                errorInfo = "StikDebug could not be opened. Is it installed? Need Help in Settings › JIT shows how to set it up."
                                errorShow = true
                            }
                        }
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigationTarget = NavigationTarget(view: view)
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        navigationTarget = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            installFromUrl(urlStr: url.absoluteString)
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    installFromUrl(urlStr: installUrl)
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
/// Unlocks rotation when any overlay is presented over the springboard,
/// re-locks to portrait when the bare springboard is visible.
private struct OrientationLockModifier: ViewModifier {
    let showSettingsCover: Bool
    let showInstallerCover: Bool
    let webViewOpened: Bool
    let safariViewOpened: Bool
    let helpPresent: Bool
    let customSortViewPresent: Bool
    let hasNavigationTarget: Bool
    let hasGameWarningTarget: Bool

    private var anyOverlay: Bool {
        showSettingsCover || showInstallerCover || webViewOpened
            || safariViewOpened || helpPresent || customSortViewPresent
            || hasNavigationTarget || hasGameWarningTarget
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: anyOverlay) { showing in
                AppDelegate.orientationLock = showing ? .allButUpsideDown : .portrait
                if #available(iOS 16.0, *) {
                    UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .first { $0.isKeyWindow }?
                        .rootViewController?
                        .setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
    }
}


/// An HStack or a VStack, for the home bar running along the bottom or down the
/// side column.
private struct FlekBarStack<Content: View>: View {
    let axis: Axis
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if axis == .horizontal {
            HStack(spacing: spacing, content: content)
        } else {
            VStack(spacing: spacing, content: content)
        }
    }
}
