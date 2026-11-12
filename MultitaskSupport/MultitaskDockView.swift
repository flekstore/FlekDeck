//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine
import CoreImage

extension NSNotification.Name {
    static let multitaskBarVisibilityChanged = NSNotification.Name("MultitaskBarVisibilityChanged")
    /// Posted when the rounded/flat bar design setting is toggled in Settings, so
    /// the visible bar can re-lay out live instead of waiting for the next layout.
    static let multitaskBarDesignChanged = NSNotification.Name("MultitaskBarDesignChanged")
    /// Posted when the home bar is switched on or off in Settings, so it can appear
    /// or go away without waiting for the app window to be reopened.
    static let multitaskHomeBarSettingChanged = NSNotification.Name("MultitaskHomeBarSettingChanged")
    /// Posted when Personalization's Bar Position changes, so a bar up over an app
    /// moves into or out of the side column at once.
    static let multitaskBarPositionChanged = NSNotification.Name("MultitaskBarPositionChanged")
    /// Posted by a guest window once its app is drawing its own content, which is
    /// the cue to drop the launch screen the window opened with. Object is the
    /// window's view. Name is duplicated as a literal in
    /// `DecoratedAppSceneViewController`.
    static let lcWindowContentDidArrive = NSNotification.Name("LCWindowContentDidArrive")
}

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    /// Non-nil for built-in pages (e.g. "settings", "installer"); nil for guest apps
    let internalPageKind: String?
    
    var isInternalPage: Bool { internalPageKind != nil }
    
    /// The home-screen item this window belongs to, so minimizing it can find the
    /// icon to shrink into: a built-in page by its kind, a guest app by its
    /// bundle. Both are asked of `FlekHomeItem`, so neither can drift from the id
    /// the springboard files that icon under. Nil for a guest registered without
    /// app info, which has no icon that can be named.
    var springboardItemID: String? {
        if let kind = internalPageKind.flatMap(FlekDefaultAppKind.init(rawValue:)) {
            return FlekHomeItem.defaultApp(kind).id
        }
        guard let appInfo else { return nil }
        return FlekHomeItem.installedID(for: appInfo)
    }

    /// Asset catalog icon name for built-in pages
    var internalPageIconAssetName: String? {
        switch internalPageKind {
        case "settings": return "FlekIconSettings"
        case "installer": return "FlekIconInstaller"
        case "flekstore": return "FlekIconFlekStore"
        default: return nil
        }
    }
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        self.internalPageKind = nil
        super.init()
    }
    
    init(appName: String, appUUID: String, view: UIView?, internalPageKind: String) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = nil
        self.view = view
        self.internalPageKind = internalPageKind
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = [] {
        // The rotation lock polls the device only while a guest has a window.
        didSet { LCRotationLock.hasGuestWindows = apps.contains { !$0.isInternalPage } }
    }
    @Published var isVisible: Bool = false
    @Published var isSwitcherBarVisible: Bool = true
    /// Both drive `updatePiPArming()`: between them they decide which window, if
    /// any, should be ready to float when the user leaves FlekDeck. Observed here
    /// rather than at each assignment because they are written from a dozen
    /// places — launch, minimize, restore, the switcher, Close All — and a route
    /// that forgot to tell the PiP manager would leave it armed on a window that
    /// is no longer there.
    @Published var frontmostAppUUID: String? {
        didSet {
            floatWindowLeavingStage(oldValue)
            updatePiPArming()
            // Another app in front may have more of its own side bar, or less.
            if frontmostAppUUID != oldValue { refreshSideColumnRoom() }
        }
    }
    @Published var isHomeState: Bool = false {
        didSet {
            if isHomeState { floatWindowLeavingStage(frontmostAppUUID) }
            updatePiPArming()
            quickSwitchHomeStateChanged()
            // The light's bubble is about the home screen's pill.
            if !isHomeState { hideSplitHelp() }
            // Back on stage: what was decided while home is decided again.
            if !isHomeState, oldValue { refreshSideColumnRoom() }
            // The next home state's dock may hold other apps, in other places.
            if !isHomeState {
                if !homeDockIconFrames.isEmpty { lastHomeDockIconFrames = homeDockIconFrames }
                homeDockIconFrames.removeAll()
                homeDockPillFrame = .zero
            } else if !oldValue {
                homeStatesBegun &+= 1
            }
        }
    }
    /// Where each running app's icon sits in the home dock, in window
    /// coordinates, keyed by its home-screen item id. Written by the icons
    /// themselves as they lay out, and read by the minimize animation, which puts
    /// a window away into its icon here, and by an icon's own tap, which opens
    /// the window out of it. Only what this home state's dock has laid out: it is
    /// emptied as the home state ends, so a window going home waits the frame or
    /// two the dock takes to appear rather than aiming where an icon used to be.
    /// Deliberately not `@Published`: it is written from a layout pass, and
    /// publishing it would invalidate the view that just reported it.
    var homeDockIconFrames: [String: CGRect] = [:]
    /// The home dock's icons as the last home state left them, for a window put
    /// back out of its icon once that state has already ended: the home button
    /// ends it before bringing the last app back, and a second app kept beside
    /// that one has to come out of its own icon too.
    private var lastHomeDockIconFrames: [String: CGRect] = [:]
    /// Where each switcher card sits, in window coordinates, as the cards report
    /// it: a window kept beside the app whose card was pressed comes out of its
    /// own card. Not `@Published`, as `homeDockIconFrames` is not.
    var switcherCardFrames: [String: CGRect] = [:]
    /// Where the home dock itself sits, in window coordinates — what a window
    /// aims at when it belongs in the dock but has no icon of its own there, the
    /// dock showing only the four most recent apps.
    var homeDockPillFrame: CGRect = .zero
    /// Counts the home states begun, so the home dock reports where it is for
    /// each one: what it reported for the last was forgotten as that one ended.
    /// A dock coming into view reports as it appears. One brought back before it
    /// had finished leaving — home again inside the half second its exit takes,
    /// an app opened and put straight away — is the same dock as before, with
    /// nothing appearing, and whatever moved in it moved while the home state
    /// was off, when nothing is taken. It reports on this instead, and without
    /// it the window going home found no place in the dock and went into its
    /// springboard icon.
    @Published private(set) var homeStatesBegun = 0
    /// How many of the most recent apps the home dock shows an icon for.
    static let homeDockIconCount = 4
    /// The home dock's icons standing aside, by home-screen item id, while a window
    /// flies into or out of them: the window is carrying the icon for the length of
    /// the flight, as on iOS, and its own place stands empty until it lands.
    @Published var homeDockIconsStandingAside: Set<String> = []
    /// Set while a minimizing window is on its way to the dock, which makes the
    /// dock appear in place rather than springing in. A target still travelling
    /// into position is one the window cannot land on cleanly.
    var homeDockShouldSkipEntrance = false
    /// Identifies the trip to the dock that asked for the entrance to be skipped,
    /// so the reset belonging to an earlier one cannot clear a later one's — going
    /// home twice inside the reset's own delay would otherwise leave the second
    /// dock springing in under an arriving window.
    private var homeDockEntranceSkipToken = 0
    /// The launch screen each window opened with, until its guest has content of
    /// its own to show behind it.
    private var launchPlaceholders: [ObjectIdentifier: UIView] = [:]
    /// Windows whose guest has reported drawing content of its own. Kept apart
    /// from the placeholders so the report and the placeholder can arrive in
    /// either order without one being lost.
    private var windowsWithContent: Set<ObjectIdentifier> = []
    /// Where a run of swipes along the bar's app button stands. See
    /// `quickSwitchBegan`.
    private let quickSwitch = MultitaskQuickSwitch()
    /// See `barMenuTextWidth`.
    private var barMenuTextWidths: [String: CGFloat] = [:]

    /// Two apps side by side, one on each side of an iPhone Duo's fold, or one app
    /// and the apps to choose the second from. Kept while the screen is turned or
    /// the switcher is up, and drawn only while the inner display is held open;
    /// see "Two apps side by side" below.
    var splitPair: SplitPair? {
        didSet {
            // Another two side by side: two kept from going home are apps of
            // their own again.
            if splitPair != nil, splitSuspended != nil { dissolveSuspendedSplit() }
            // The app under the side column may be another one now.
            if splitPair != oldValue { refreshSideColumnRoom() }
        }
    }
    /// Two apps that were side by side when FlekDeck went home, both still open:
    /// the switcher shows them as one card, as they were, and brings them back
    /// side by side from it. Any other way of opening either opens it on its own.
    var splitSuspended: SplitPair?
    /// The black on the fold between the two, with its handle.
    var splitDivider: SplitDividerView?
    /// The switcher is closing, or going home from over the two: what is drawn
    /// around them is taken away while the switcher still covers it, and comes
    /// back once the switcher has gone. The switcher's card of the two grows as
    /// it fades, and the divider on the screen underneath showed through before
    /// the card had grown to meet it.
    var splitChromeAwaitsSwitcher = false
    /// Windows growing back into their sides after a lift, counted: what is
    /// drawn around the two waits for them, as it does for windows flying in.
    var splitSettlingCount = 0
    /// Darkens the side the divider is being dragged across.
    var splitCurtain: UIView?
    /// Apps whose windows left a split on their way in or out, given the whole
    /// screen back once they have landed, where the change will not be seen.
    var splitLeftovers: Set<String> = []
    /// A check of the split's windows is queued: a burst of visibility changes
    /// makes one.
    var splitCheckQueued = false
    /// The apps to choose from, on a side of the screen with no app.
    var splitPicker: UIHostingController<AnyView>?
    let splitPickerModel = SplitPickerModel()
    /// An app chosen for a side that is still starting up.
    var splitLaunch: SplitLaunch?
    /// The app button has been held long enough to lift the app in use.
    var splitLiftArmed = false
    /// The app lifted off the screen by the app button, under the finger.
    var splitLift: SplitLift?
    /// An app being carried out of the home dock (see `DockLift`).
    var dockLift: DockLift?
    /// The running app whose dock icon is held, ready to be carried out.
    var dockLiftArmed: String?
    /// The home screen frosted and dimmed behind an app carried out of the dock.
    private var dockLiftBackdrop: UIVisualEffectView?
    /// The drop targets at each side while an app is lifted.
    var splitShelves: [SplitSide: SplitShelfView] = [:]
    /// Where the divider rests between two apps on an iPad, as the left side's
    /// share of the width, by the two (see `splitFoldFraction`). Kept from one
    /// launch to the next, as iPadOS keeps its own pairs' sizes.
    var splitFractions: [String: CGFloat] = (LCUtils.appGroupUserDefault
        .dictionary(forKey: MultitaskDockManager.splitFractionsKey) as? [String: Double])?
        .mapValues { CGFloat($0) } ?? [:] {
        didSet {
            LCUtils.appGroupUserDefault.set(splitFractions.mapValues { Double($0) },
                                            forKey: Self.splitFractionsKey)
        }
    }
    /// What veils each side while the divider is dragged on an iPad (see
    /// `resizeSplit(with:)`).
    var splitPaneCovers: [SplitSide: SplitPaneCoverView] = [:]
    /// The light in the home screen's running-apps pill on an iPad: green where an
    /// app held there can be dragged out beside another, red where it cannot now,
    /// and why (see `refreshSplitLight`).
    @Published private(set) var splitLight: SplitLight?
    /// How Split View works, in a popover over the light while it is tapped.
    weak var splitHelpController: UIViewController?
    /// The handle under each app: its own home indicator.
    var splitHandles: [SplitSide: SplitHandleView] = [:]
    /// The app button's tap that ends a lift is not a press of the button.
    var splitAppButtonTapSuppressed = false
    /// Set by the home screen: opens one of its items in a window, whatever
    /// launch mode it has, for a side of the screen.
    var splitOpenHomeItem: ((FlekHomeItem) -> Void)?
    /// Set by the home screen: its items, in its order.
    var splitHomeItems: (() -> [FlekHomeItem])?
    /// The app a swipe along the bar is landing on, whose width the bar's app
    /// button takes from the moment the finger lets go rather than once the
    /// window has settled. Its name is on the way in by then, moving with the
    /// windows (see `MultitaskQuickSwitch.ButtonSlide`).
    @Published private(set) var quickSwitchLanding: String?
    @Published var isAppSwitcherOpen: Bool = false
    /// Whether the bar's app button reads Close all, as the switcher's chin does in
    /// its place: on as the switcher opens, off as it closes back to an app or the
    /// next time the bar comes up. The bar and the chin both read it, so the one
    /// change turns the two of them together.
    @Published private(set) var barShowsCloseAll = false
    /// How the app button turns between the app's name and Close all.
    private static let barAppButtonSwap = Animation.spring(response: 0.35, dampingFraction: 1)
    /// The switcher is fading back to an app. Its cards and the blur behind them
    /// grow a little as they go; its chin stays as it is, over the bar it hands
    /// back to, which is the same but for the label already turning.
    @Published private(set) var isDismissingAppSwitcher = false
    /// The interface orientation the switcher overrode, restored when it closes.
    private var orientationBeforeSwitcher: UIInterfaceOrientation?
    @Published var isClosingAll: Bool = false
    /// Snapshot of the springboard (wallpaper + icons) captured when the switcher
    /// opens, shown blurred behind the cards — the app-switcher equivalent of
    /// Spotlight's blurred home background.
    @Published var springboardSnapshot: UIImage?
    /// The switcher's backdrop kept from one open to the next (see
    /// `switcherBackdropPicture`).
    private var keptSwitcherBackdrop: (image: UIImage, size: CGSize, style: UIUserInterfaceStyle, epoch: Int)?
    /// Counts the chances the springboard has had to change.
    private var springboardEpoch = 0
    /// Published mirror of `isBarLandscape` so the SwiftUI bar content can react
    /// to rotation (its own local geometry is always a horizontal strip and
    /// can't reveal orientation).
    @Published var isLandscapeBar: Bool = false
    /// Whether the bar was last laid out standing upright in the side column an
    /// iPhone Duo's status bar runs down, and on which side — for the bar's content
    /// to draw itself as that column. See `sideColumnEdge(for:)`.
    @Published private(set) var isSideColumnBar = false
    @Published private(set) var isSideColumnOnLeft = false
    /// The same for the switcher's controls, which take the bar's place while it is
    /// open. Read for themselves when it opens: the bar may be down by then, and its
    /// own placement only as recent as the last time it was up.
    @Published private(set) var isSwitcherSideColumn = false
    @Published private(set) var isSwitcherSideColumnOnLeft = false
    /// Where each guest's own side bar sits, by its window's data UUID: its tab
    /// bar and its other items, which an iPhone Duo stands in the column the side
    /// column stands in. Told by the guest itself — see LCGuestSideBar.m.
    private var guestSideBars: [String: GuestSideBar] = [:]
    /// Whether the side column has stepped aside for the app in front, whose own
    /// side bar leaves it no room. The floating button stands in for it meanwhile,
    /// as for a bar put away by hand, but nothing has been chosen: the column comes
    /// back by itself once there is room for it again.
    private(set) var sideColumnStepsAside = false {
        didSet { if sideColumnStepsAside != oldValue { splitControlChanged() } }
    }
    /// Whether the floating button stands in for the bar: because it was chosen,
    /// or because the side column has no room over the app in front.
    private var usesFloatingButton: Bool { prefersFloatingButton || sideColumnStepsAside }

    /// The screen the switcher overlay sizes its cards against.
    ///
    /// Published rather than read from `UIScreen` where it is needed. A plain read
    /// is not something SwiftUI can depend on, so nothing re-ran the overlay's body
    /// when the device turned: the cards kept the width and height the previous
    /// orientation gave them, which on iPad left a landscape-shaped card sitting in
    /// a portrait window, clipped and off-centre. iPhone turns the window portrait
    /// before the switcher opens and holds it, so this never changes there.
    @Published private(set) var switcherScreenSize: CGSize = FlekTheme.screen.bounds.size

    /// Points the overlay at the window's current shape: the box it is laid out in,
    /// and the size its cards measure themselves against.
    ///
    /// Both, because either alone leaves the layout wrong. The published size fixes
    /// the card metrics; the frame fixes the space they are arranged in. The hosting
    /// view is parented straight to the window and never becomes a child view
    /// controller, so nothing tells it the window turned — autoresizing is supposed
    /// to carry it, and when it does not the column is laid out against the old
    /// height and runs off the bottom of the new one.
    ///
    /// Deliberately NOT sampled while the turn is in progress.
    ///
    /// Taken as the turn begins and animated over it, so the overlay travels with the
    /// rotation rather than waiting for it and then jumping.
    ///
    /// Measuring this early was once ruinous: it caught the scroll view mid-turn at a
    /// viewport 1698pt wide inside an 820pt window. That was the backdrop, which
    /// filled rather than fitted and dragged the whole stack out with it; now that it
    /// is pinned to this very size, an early measurement has nothing left to distort.
    /// The later samples remain as insurance for a window that is slow to settle —
    /// they cost nothing when the size already matches.
    ///
    /// - Parameter animated: false when opening, where there is no turn to follow and
    ///   the overlay is about to be built from the result.
    func refreshSwitcherScreenSize(animated: Bool = true) {
        let apply = { [weak self] in
            guard let self else { return }
            let overlay = self.switcherOverlayController?.view
            guard let window = overlay?.window ?? self.keyWindow else { return }
            let bounds = window.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            if let overlay, overlay.frame != bounds { overlay.frame = bounds }
            // An iPhone Duo folding or unfolding under the switcher changes its
            // window too, and the status bar's column goes with the display.
            self.refreshSwitcherSideColumn()
            guard self.switcherScreenSize != bounds.size else { return }

            // Roughly the system's own rotation, so the cards resize and re-centre
            // across the same beat the window turns on instead of after it.
            if animated {
                withAnimation(.easeInOut(duration: Self.rotationDuration)) {
                    self.switcherScreenSize = bounds.size
                }
            } else {
                self.switcherScreenSize = bounds.size
            }
        }
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: apply)
    }

    /// How long the system takes to turn the interface.
    static let rotationDuration: TimeInterval = 0.35

    /// How hard every multitask control taps back: the bar's and the switcher's
    /// buttons, the springboard's dock pill, the floating button, and the bottom
    /// swipe. How strong is a deliberate choice — the controls sit under the
    /// thumb during any app switch, and their feedback is the most repeated in
    /// the app — so it lives in Settings ▸ Personalization rather than following
    /// the system's global haptics setting alone.
    ///
    /// `0` is silent; `1`…`maxHapticsLevel` climb from the softest impact iOS
    /// offers to its heaviest.
    static let hapticsLevelKey = "LCMultitaskHapticsLevel"
    static let maxHapticsLevel = 3
    /// The softest step, which is the feedback these controls have always had.
    static let defaultHapticsLevel = 1

    /// The on/off switch this slider replaced. Only read to carry an old
    /// preference over — see `migrateHapticsPreferenceIfNeeded`.
    private static let legacyHapticsToggleKey = "LCMultitaskButtonHaptics"

    /// The chosen strength, clamped: a value written by an older or newer build
    /// than this one still has to name a step that exists.
    static var hapticsLevel: Int {
        let defaults = LCUtils.appGroupUserDefault
        if let stored = defaults.object(forKey: hapticsLevelKey) as? Int {
            return min(max(stored, 0), maxHapticsLevel)
        }
        return migrateHapticsPreferenceIfNeeded() ?? defaultHapticsLevel
    }

    /// Move a pre-slider on/off preference onto the scale, once. On becomes the
    /// softest step — the feedback that switch actually played — and off stays
    /// silent, so nobody who deliberately turned this off gets it back.
    ///
    /// Returns the level it wrote, or nil when there was nothing to carry over.
    @discardableResult
    static func migrateHapticsPreferenceIfNeeded() -> Int? {
        let defaults = LCUtils.appGroupUserDefault
        guard defaults.object(forKey: hapticsLevelKey) == nil,
              let wasEnabled = defaults.object(forKey: legacyHapticsToggleKey) as? Bool
        else { return nil }
        let level = wasEnabled ? defaultHapticsLevel : 0
        defaults.set(level, forKey: hapticsLevelKey)
        return level
    }

    /// Every multitask control's one and only feedback, at the chosen strength.
    /// Silent when the slider sits at its left end.
    static func buttonHaptic() {
        playHaptic(level: hapticsLevel)
    }

    /// Fire the feedback a given step plays, whatever is currently saved — the
    /// settings slider uses this to let the strength be felt as it is chosen.
    static func playHaptic(level: Int) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch level {
        case 1: style = .soft
        case 2: style = .medium
        case 3: style = .heavy
        default: return
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Persisted user preference for which multitask control to show when an app
    /// is opened: the switcher bar (false) or the floating button (true). The
    /// switcher overlay toggles this; it takes effect the next time an app opens.
    static let preferFloatingButtonKey = "LCMultitaskPreferFloatingButton"
    @Published var prefersFloatingButton: Bool =
        LCUtils.appGroupUserDefault.bool(forKey: MultitaskDockManager.preferFloatingButtonKey) {
        didSet { if prefersFloatingButton != oldValue { splitControlChanged() } }
    }

    /// Update and persist the control preference. Does not change what's on
    /// screen right now — it is applied when an app is next opened.
    func setPrefersFloatingButton(_ value: Bool) {
        prefersFloatingButton = value
        LCUtils.appGroupUserDefault.set(value, forKey: MultitaskDockManager.preferFloatingButtonKey)
    }

    var appSnapshotViews: [String: UIView] = [:]
    /// Each snapshot's size at capture time. A card is always portrait, but an app
    /// captured in landscape is a landscape image — without its original shape the
    /// card can only stretch it to fit.
    var appSnapshotSizes: [String: CGSize] = [:]
    /// The quarter-turn each capture needs to sit upright in a portrait card, in
    /// radians. Shared by both card paths so a guest app and an internal page
    /// captured side by side are turned the same way.
    var appSnapshotRotations: [String: CGFloat] = [:]
    /// Genuinely frozen captures, preferred over `appSnapshotViews` when available.
    ///
    /// `resizableSnapshotView` does not freeze a view that hosts a guest process's
    /// remote layer — it returns a replicant that keeps mirroring the live layer. So
    /// once the switcher rotates the interface to portrait the guest re-lays out and
    /// the card's content silently changes underneath whatever size we laid it out
    /// against. An image captured while the app is still on screen cannot drift.
    var appSnapshotImages: [String: UIImage] = [:]
    /// The apps whose picture was taken beside another app, at half the screen.
    /// It fits a half of the two's card in the switcher and no card of the app's
    /// own: one shaped like the whole screen cropped it to a strip of the app, and
    /// shaped like the picture it stood taller than every card beside it. Such a
    /// card shows the app's icon until the app has been seen on its own again.
    private(set) var splitPaneSnapshots: Set<String> = []
    /// Where on an iPhone Duo a picture was taken: which display, and which way
    /// up the window was.
    struct SnapshotDisplay: Equatable {
        let duo: FlekDeviceModel.DuoDisplay
        let landscape: Bool
    }
    /// Each picture's display on an iPhone Duo; none on any other phone (see
    /// `pictureFitsDisplay`).
    private var appSnapshotDisplays: [String: SnapshotDisplay] = [:]
    var internalPageControllers: [String: UIHostingController<AnyView>] = [:]

    @objc public var windowHostingView = VirtualWindowsHostView()
    /// Watches the window's safe area so the bar re-lays out when it changes.
    private let safeAreaSentinel = SafeAreaSentinelView()
    internal var hostingController: UIHostingController<AnyView>?
    private var switcherOverlayController: UIHostingController<AnyView>?
    /// Full-window host for the switcher bar that limits touches to the bar's
    /// visible shape so its transparent corners/overhang pass taps to the content.
    private var barContainer: BarPassthroughContainer?
    /// The window the bar, the floating button and the switcher overlay live in.
    ///
    /// They used to be plain subviews of the app's own window — which is exactly
    /// where UIKit puts a modal presentation. A sheet, a full-screen cover, an
    /// alert or a document picker is inserted above whatever the window already
    /// held, so the installer's sources sheet, a settings sheet or an error alert
    /// raised over a guest window all buried the bar and left no way out of the
    /// app but the sheet's own dismiss. A presentation cannot escape the window of
    /// the controller presenting it, so one window higher is enough to be out of
    /// reach of all of them at once.
    private var overlayWindow: MultitaskOverlayWindow?
    private var navAssistButton: UIView?
    private var navAssistChevron: UIImageView?
    private var isNavAssistStashed: Bool = false
    /// LiveContainer's own home bar, shown along the bottom edge whenever the
    /// floating button is the control on screen. See `MultitaskSwipeZone`.
    private var swipeZone: MultitaskSwipeZone?

    /// One of the four sides. Which frame it is named in depends on where it is
    /// used: the layout's own coordinates, or the viewer's — what the user sees
    /// once the phone has been turned. `viewerRotationSteps` converts between them,
    /// and both the switcher bar and the floating button go through it.
    private enum ScreenEdge { case left, right, top, bottom }

    /// Where the floating button lives, held in the VIEWER's frame: which side of
    /// what the user is looking at it is parked on, and how far along that side it
    /// sits as a fraction of the side's usable travel (down the viewer's left and
    /// right sides from the top; across the viewer's top and bottom from the left).
    ///
    /// The viewer's frame, because that is the one the user is describing when they
    /// say the button was "on the right". Which layout edge that turns out to be
    /// depends on whether the interface turns with the phone:
    ///
    ///  - Interface rotates with the device — the layout's right edge already *is*
    ///    the viewer's right, and the button stays on it.
    ///  - Interface stays put while the phone turns (a portrait-locked host with a
    ///    guest app rotating inside it) — the viewer's right is now the layout's top
    ///    or bottom, depending on which way the phone was turned, and the button has
    ///    to move to that edge to stay where the user left it.
    ///
    /// `viewerRotationSteps` is the difference between those two worlds, and is 0
    /// in the first. `currentScreenPlacement()` resolves the stored position into
    /// the layout edge and offset to draw at; `rememberScreenPlacement(edge:fraction:)`
    /// converts a drag's layout-space landing spot back.
    private var navAssistViewEdge: ScreenEdge = .right
    private var navAssistAlongFraction: CGFloat = 0.5
    /// The floating button's diameter: on an iPhone Duo the size of the side
    /// column's own buttons, which are iOS's in that column, and elsewhere the
    /// larger size it has always had.
    private var navAssistSize: CGFloat {
        FlekDeviceModel.isDuo ? FlekTheme.sideBarButtonSize : Constants.navAssistSize
    }

    /// Whether the floating button is where it was put rather than where it was
    /// moved: a fresh one goes with the app's side bar as that changes, until it is
    /// dragged or tucked away, or unless it came out tucked away.
    private var navAssistFollowsSideBar = false

    /// Last device orientation worth acting on, as quarter-turns. `UIDevice` reports
    /// face-up and face-down as orientations of their own; a phone laid flat on a
    /// table must not read as "portrait" and swing the button across the screen.
    /// Nil until the device has reported a real one.
    private var lastKnownDeviceSteps: Int?

    /// The last device orientation that describes how the screen is being *read*,
    /// ignoring face-up and face-down. Kept beside `lastKnownDeviceSteps` because
    /// callers that need the orientation itself, rather than a quarter-turn count,
    /// need the same stickiness for the same reason.
    private var lastValidDeviceOrientation: UIDeviceOrientation {
        let current = UIDevice.current.orientation
        if current.isValidInterfaceOrientation { _lastValidDeviceOrientation = current }
        return _lastValidDeviceOrientation
    }
    private var _lastValidDeviceOrientation: UIDeviceOrientation = .portrait
    /// True while a finger is actually moving the button, so the geometry callbacks
    /// that re-place it on a resize don't pull it out from under that finger.
    ///
    /// Asked of the gesture rather than latched by it: a latch set on `.began` is
    /// never cleared if the button is torn down mid-drag (the switcher bar coming
    /// back, the dock hiding), and a stuck latch would silently stop every later
    /// re-placement. A recogniser that has gone away answers false by construction.
    private var isNavAssistDragging: Bool {
        navAssistButton?.gestureRecognizers?.contains {
            $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed)
        } ?? false
    }

    // Backward compatibility — always false since collapsed dock concept was removed
    @objc public var isCollapsed: Bool { return false }
    
    /// ObjC-accessible flag for whether the switcher bar is currently shown
    @objc public var barVisible: Bool { return isSwitcherBarVisible }

    /// Live read of the LCMultitaskBarLedgeAmount setting: how rounded the bar's
    /// concave top corners are, as a fraction 0 (flat, the original short bar) …
    /// 1 (full device-radius rounded corners). Migrates from the old on/off
    /// boolean `LCMultitaskBarLedge` (on → 1, off → 0) until the slider is used.
    /// With neither key set, defaults to `Self.barLedgeAmountDefault`.
    /// Read live here but only applied via `captureBarDesign()` as the bar
    /// (re)lays out, so changing it in Settings never resizes the bar under the
    /// user's finger.
    private var barLedgeAmountSetting: CGFloat {
        let d = LCUtils.appGroupUserDefault
        if let stored = d.object(forKey: "LCMultitaskBarLedgeAmount") as? NSNumber {
            return max(0, min(1, CGFloat(stored.doubleValue) / 100.0))
        }
        if let legacyOn = d.object(forKey: "LCMultitaskBarLedge") as? Bool {
            return legacyOn ? 1 : 0
        }
        return Self.barLedgeAmountDefault
    }

    /// Default bar rounding when the user has never touched the slider — must
    /// match the `LCMultitaskBarLedgeAmount` @AppStorage default in settings.
    private static let barLedgeAmountDefault: CGFloat = 0.6

    /// The design actually in effect on the visible bar. Captured from the setting
    /// only when the bar (re)appears via `captureBarDesign()` — never mid-session —
    /// so toggling the setting while the settings page (whose own toggle sits over
    /// this same bar) is open never changes anything under the user's finger. The
    /// new design applies the next time the bar is laid out (app switch, rotation,
    /// or re-show).
    @Published private(set) var barLedgeActive: Bool = true

    /// How rounded the bar's concave corners actually are on the visible bar,
    /// 0 (flat) … 1 (full `barCornerRadiusActive`). Captured from the slider
    /// setting; published so moving the slider re-renders the bar live.
    @Published private(set) var barLedgeAmountActive: CGFloat = 1

    /// The concave corner radius actually in effect on the visible bar, captured
    /// from the user's slider setting (falling back to the device screen radius).
    /// Published so changing the slider re-renders the bar live.
    @Published private(set) var barCornerRadiusActive: CGFloat = 39

    /// Re-reads the design settings (rounded/flat + corner radius) into the
    /// published state; called as the bar is laid out and when the settings change.
    func captureBarDesign() {
        let amount = barLedgeAmountSetting
        if barLedgeAmountActive != amount { barLedgeAmountActive = amount }
        // Any rounding at all uses the concave-cornered hit path; only a fully
        // flat bar (0) uses the plain flat-top hit path.
        let active = amount > 0
        if barLedgeActive != active { barLedgeActive = active }
        let r = barCornerRadiusSetting
        if barCornerRadiusActive != r { barCornerRadiusActive = r }
    }

    /// Bar strip height. Both designs use the same tall strip so the buttons and
    /// the reserved content sit in exactly the same place: the rounded design
    /// carves concave corners from the top, while the flat design just draws its
    /// fill in the lower flat-solid region (square top). Only the corners differ.
    var effectiveBarHeight: CGFloat {
        // The bar's visible strip is measured *inward* from the screen's corner
        // radius (`effectiveBarHeight - cornerRadius + bottom inset`), so a shallower
        // corner yields a thicker bar from the same constant. iPad's corners are about
        // a third of an iPhone's, which made both the bar and the switcher's chin
        // noticeably taller there; a smaller constant brings the visible strip back in
        // line with iPhone's.
        UIDevice.current.userInterfaceIdiom == .pad
            ? Constants.barHeightWithLedgePad
            : Constants.barHeightWithLedge
    }

    /// The physical corner radius of the display the bar is on (private UIScreen
    /// value) so the bar's concave corners match the phone's rounded screen
    /// corners. Falls back to a sensible default on devices that report none.
    var deviceScreenCornerRadius: CGFloat {
        let screen = keyWindow?.windowScene?.screen ?? FlekTheme.screen
        let r = (screen.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        return r > 0 ? r : 39
    }

    /// The display's radius at each of its corners, as the interface is turned: the
    /// shape an app's window is cut to while it moves — out of its dock icon, back
    /// into it, along the bar in a swipe — as iOS shows an app on the move. The one
    /// radius all round, except where the display's corners differ, as the iPhone
    /// Duo's cover display's do from side to side.
    var deviceScreenCornerRadii: FlekCornerRadii {
        let screen = keyWindow?.windowScene?.screen ?? FlekTheme.screen
        return FlekDeviceModel.displayCornerRadii(of: screen) ?? .uniform(deviceScreenCornerRadius)
    }

    /// Resolved concave corner radius from the user setting: the stored slider
    /// value when set, otherwise the device screen radius (the default "match the
    /// phone's corners"). Read via `captureBarDesign()` into `barCornerRadiusActive`.
    private var barCornerRadiusSetting: CGFloat {
        // The corner-radius slider is hidden for now, so always match the device
        // screen radius and IGNORE any previously-stored value. A value written
        // while the slider was enabled persists across reinstalls (but is absent on
        // a clean install), so reading it here made the bar's corners the wrong size
        // only after an update/relaunch — the "too tall after reinstall" bug.
        // Re-enable the stored read below when the slider is brought back.
        return deviceScreenCornerRadius
        // let v = LCUtils.appGroupUserDefault.double(forKey: "LCMultitaskBarCornerRadius")
        // return v > 0 ? CGFloat(v) : deviceScreenCornerRadius
    }

    /// The strip the bar occupies, as insets on whichever edge it currently sits
    /// on — zero when no bar is up. Guest windows inset their maximized frame by
    /// this so their content sits flush against the bar wherever it is, rather than
    /// assuming a bottom-or-right edge derived from the interface orientation, which
    /// is not the same question once the layout and the device part ways.
    @objc public var barReservedInsets: UIEdgeInsets {
        // `lastPlacedBarEdge` is the proof that the bar has been laid out at least
        // once. Until it has, its hosting view's rectangle is whatever the view was
        // born with and says nothing about where the bar is going to be — and a
        // window opening before the first bar of the session was placed would trim
        // itself against that. Nothing is reserved for a bar that has yet to take
        // its place; `showDock` tells the windows once it has.
        // Nor for a bar standing in the side column: it is in the strip an iPhone
        // Duo's status bar keeps for itself, which the guest's safe area already
        // keeps its content out of.
        guard isSwitcherBarVisible,
              lastPlacedBarEdge != nil,
              placedSideColumnEdge == nil,
              let barView = hostingController?.view,
              let window = keyWindow else { return .zero }

        // Measured from where the bar physically is, converted into the window the
        // guest lives in — not derived a second time from the rotation maths.
        //
        // The bar is laid out inside its own container, in a separate overlay
        // window, and its edge is chosen in THAT rectangle. The guest window lives
        // in the app's window. While the two rectangles agree the edge name means
        // the same thing in both, and everything lines up. When they do not — the
        // app's window upright, the bar's container turned with the viewer — the
        // same name points at different sides, and the guest gets trimmed on an
        // edge the bar is nowhere near: content pushed inward, its far end left
        // under the bar, and the host's black backdrop showing in the gap.
        //
        // A rect converted between them cannot disagree with itself, whatever the
        // two spaces are doing.
        let strip = barView.convert(barView.bounds, to: window).intersection(window.bounds)
        guard !strip.isNull, strip.width > 0, strip.height > 0 else { return .zero }

        // The visible flat region only. The strip also carries the concave corner
        // overhang, which is transparent and deliberately overlaps the app.
        let thickness = barReservedThickness
        let bounds = window.bounds
        if strip.width >= strip.height {
            return strip.midY < bounds.midY
                ? UIEdgeInsets(top: thickness, left: 0, bottom: 0, right: 0)
                : UIEdgeInsets(top: 0, left: 0, bottom: thickness, right: 0)
        }
        return strip.midX < bounds.midX
            ? UIEdgeInsets(top: 0, left: thickness, bottom: 0, right: 0)
            : UIEdgeInsets(top: 0, left: 0, bottom: 0, right: thickness)
    }

    /// The exact on-screen thickness of the switcher bar strip on its short edge
    /// (matches `updateDockFrame`). App windows reserve this so their content
    /// sits flush against the bar with no background gap showing through.
    @objc public var barReservedThickness: CGFloat {
        // Reserve down to the bar's visible flat top so the app sits flush against
        // it. The tall rounded design's concave corners rise `deviceScreenCornerRadius`
        // above that flat top and overlay the app's bottom corners (the nesting
        // look), so they must not be reserved. Deriving the flat top from the real
        // corner radius keeps the app flush on every device — the old fixed base
        // height only lined up on phones whose corner radius matched the assumed
        // value and left a thin gap on the rest.
        // Both designs and both orientations share the same flat-top line, so reserve
        // down to it (the concave corners / square top sit above it and overlay
        // nothing that needs reserving). Landscape uses the identical value now that
        // its bar is the same shaped strip as portrait.
        return barFlatRegion
    }

    /// Reserves (or clears) space for the switcher bar on an internal page,
    /// on the axis where the bar actually lives — the bottom edge in portrait,
    /// the right edge in landscape. Reserving the bottom in landscape (where the
    /// bar is on the right) left a stale inset that pushed bottom content up and
    /// broke the hide-to-bottom-edge behaviour.
    func applyBarInset(to controller: UIHostingController<AnyView>, reserved: Bool) {
        // Reserve the bar's *actual* solid region, minus whatever the device already
        // insets on that edge — the page's safe area covers that part already.
        //
        // This used to reserve a flat `Constants.barHeight` (25pt) against a bar whose
        // solid region is more than twice that. On a notched phone the home-indicator
        // inset happened to make up the difference, so it looked right; a device with
        // a home button has no such inset, and the bar covered the page's bottom
        // controls.
        let insets = safeAreaInsets
        // Cleared on every edge first: the bar moves between them, and a reservation
        // left behind on the edge it came from would push content off the other side.
        var reserve = UIEdgeInsets.zero
        // Nothing for the side column, which stands in the status bar's own strip —
        // already inside the page's safe area. Nor on an edge the page doesn't
        // reach, beside another app on the far side of the fold.
        if reserved, Self.sideColumnEdge(for: keyWindow?.traitCollection) == nil,
           pageReachesEdge(controller, barLayoutEdge) {
            switch barLayoutEdge {
            case .bottom: reserve.bottom = max(barFlatRegion - insets.bottom, 0)
            case .top:    reserve.top    = max(barFlatRegion - insets.top, 0)
            case .right:  reserve.right  = max(barFlatRegion - insets.right, 0)
            case .left:   reserve.left   = max(barFlatRegion - insets.left, 0)
            }
        }
        controller.additionalSafeAreaInsets = reserve
    }

    public struct Constants {
        // MARK: - Switcher Bar Layout
        static let barHeight: CGFloat = 25.0
        /// Taller bar strip used when the rounded ledge (concave corners) is on.
        static let barHeightWithLedge: CGFloat = 80.0
        /// iPad equivalent of `barHeightWithLedge`. Lower because iPad's shallow screen
        /// corners would otherwise turn the same constant into a much thicker strip.
        static let barHeightWithLedgePad: CGFloat = 58.0
        static let barIconSize: CGFloat = 40.0
        static let barButtonSize: CGFloat = 40.0
        /// The switcher's Close all capsule, and the width the bar's app menu
        /// starts from — so the two read as the same control in both states.
        static let barMenuBaseWidth: CGFloat = 112.0
        /// As wide as the app menu may grow to fit a long name before the name
        /// itself has to give way. Past this the row starts to crowd the side
        /// buttons on a narrow phone, and the capsule stops looking like the one
        /// Close all occupies.
        static let barMenuMaxWidth: CGFloat = 140.0
        /// The app menu's internal layout, shared by the label and the width
        /// measurement that sizes its capsule — they have to agree or the name is
        /// measured against the wrong room.
        static let barMenuHPadding: CGFloat = 10.0
        static let barMenuSpacing: CGFloat = 4.0
        static let barMenuIconSize: CGFloat = 24.0
        static let barMenuChevronWidth: CGFloat = 12.0
        /// Clearance kept either side of the row so it never runs to the bezel.
        static let barRowMargin: CGFloat = 16.0
        /// The row is drawn at `barButtonSize` and scaled up by this on screen.
        static let barContentScale: CGFloat = 1.1
        static let barSpacing: CGFloat = 10.0
        static let barHPadding: CGFloat = 12.0
        static let barVPadding: CGFloat = 4.0
        static let barCornerRadius: CGFloat = 26.0
        static let barBottomMargin: CGFloat = 16.0
        
        // MARK: - Navigation Assist
        static let navAssistSize: CGFloat = 65.0
        static let navAssistMargin: CGFloat = 8.0
        
        // MARK: - Animation
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let barSlideDuration: TimeInterval = 0.2  // bar slide up/down (snappy)
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }

    /// The app's own window — the one the springboard, the guest windows and the
    /// built-in pages live in.
    ///
    /// `connectedScenes` is an
    /// *unordered* Set and multi-scene support is enabled, so after an in-place app
    /// update iOS can restore a stale/background scene from the previous launch.
    /// Picking `connectedScenes.first`/`windows.first` could then return nil (→ the
    /// bar container is never added, so the bar never shows) or a not-yet-ready
    /// window whose `safeAreaInsets` are still zero (→ the bar is sized without the
    /// home-indicator inset — the "weird sizing"). A clean install has only one
    /// fresh scene, which is why the bug never appears there. Resolve deterministically
    /// by preferring the foreground-active scene's key window, then falling back.
    ///
    /// Our own overlay window is never a candidate: it is never made key, but the
    /// fallbacks below would happily settle on it, and everything that resolves the
    /// key window here wants the app's content — its safe area, its root view
    /// controller, its orientation.
    public var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { Self.sceneActivationRank($0) < Self.sceneActivationRank($1) }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow && !($0 is MultitaskOverlayWindow) }) {
                return key
            }
        }
        for scene in scenes {
            let candidates = scene.windows.filter { !($0 is MultitaskOverlayWindow) }
            if let visible = candidates.first(where: { !$0.isHidden }) ?? candidates.first {
                return visible
            }
        }
        return nil
    }

    /// Ranks scenes so the foreground-active one wins over restored/background
    /// scenes left over from a previous launch (lower is preferred).
    private static func sceneActivationRank(_ scene: UIWindowScene) -> Int {
        switch scene.activationState {
        case .foregroundActive:   return 0
        case .foregroundInactive: return 1
        case .background:         return 2
        default:                  return 3
        }
    }

    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    /// A cached copy for SwiftUI bodies to read.
    ///
    /// `safeAreaInsets` resolves `keyWindow`, which enumerates every connected scene,
    /// allocates, sorts them and then scans their windows. That is fine once per
    /// layout but ruinous inside a view body, where it runs per card per frame — it
    /// showed up as the switcher carousel stuttering and dropping touches. Refreshed
    /// wherever the real insets can change.
    @Published private(set) var cachedSafeAreaInsets: UIEdgeInsets = .zero

    func refreshCachedSafeAreaInsets() {
        let current = safeAreaInsets
        if cachedSafeAreaInsets != current { cachedSafeAreaInsets = current }
        refreshCachedWindowShortEdge()
    }

    /// The window's shorter side — the one the bar's row has to fit across. The
    /// window, not the screen: on iPad the app can be handed a fraction of the
    /// display in Split View or Slide Over, and `UIScreen` would still report the
    /// whole panel.
    @Published private(set) var cachedWindowShortEdge: CGFloat =
        min(FlekTheme.screen.bounds.width, FlekTheme.screen.bounds.height)

    func refreshCachedWindowShortEdge() {
        guard let bounds = keyWindow?.bounds, bounds.width > 0, bounds.height > 0 else { return }
        let edge = min(bounds.width, bounds.height)
        if cachedWindowShortEdge != edge { cachedWindowShortEdge = edge }
    }

    /// Room the row's middle capsule may occupy, after the two side buttons, the
    /// gaps and the side padding have taken theirs.
    ///
    /// The window, not the screen: Display Zoom drops an iPhone to 320pt and an
    /// iPad Slide Over window is narrower still, and nothing else stops the row
    /// running past the bezel there. Everything in the row is scaled up by
    /// `barContentScale` on screen, so the budget is divided back down by it.
    private var barMenuBudget: CGFloat {
        let sides = Constants.barButtonSize * 2
            + Constants.barSpacing * 2
            + Constants.barHPadding * 2
        return (cachedWindowShortEdge - Constants.barRowMargin * 2)
            / Constants.barContentScale - sides
    }

    /// The switcher's Close all capsule: one fixed size, whatever is on screen.
    public var barCloseAllWidth: CGFloat {
        min(Constants.barMenuBaseWidth, barMenuBudget)
    }

    /// The bar's app menu capsule, sized to the app it is naming.
    ///
    /// It starts at Close all's width and grows with a longer name, up to
    /// `barMenuMaxWidth`. A name too long even for that doesn't widen it further —
    /// the label shrinks inside the capsule instead (see `FrontmostAppIconLabel`),
    /// which keeps the capsule recognisably the same control as the one the
    /// switcher puts in its place.
    public var barMenuWidth: CGFloat {
        barMenuWidth(forName: frontmostAppName())
    }

    /// The capsule's width naming the app called `name`.
    func barMenuWidth(forName name: String) -> CGFloat {
        // Padding + icon + gap + name + gap + chevron + padding, matching the
        // label's own layout.
        let content = Constants.barMenuHPadding * 2
            + Constants.barMenuIconSize
            + Constants.barMenuSpacing * 2
            + barMenuTextWidth(name)
            + Constants.barMenuChevronWidth
        let ideal = min(max(content, Constants.barMenuBaseWidth), Constants.barMenuMaxWidth)
        return min(ideal, barMenuBudget)
    }

    /// What the icon and name take of `barMenuWidth`: their own width, or the
    /// room left beside the padding and the chevron, whichever is less.
    public var barMenuNameWidth: CGFloat {
        barMenuNameWidth(forName: frontmostAppName())
    }

    /// The same for the app called `name`.
    func barMenuNameWidth(forName name: String) -> CGFloat {
        let own = Constants.barMenuIconSize + Constants.barMenuSpacing + barMenuTextWidth(name)
        let room = barMenuWidth(forName: name) - Constants.barMenuHPadding * 2
            - Constants.barMenuSpacing - Constants.barMenuChevronWidth
        return max(0, min(own, room))
    }

    /// A name's width on the app button, measured once: a swipe along the bar
    /// asks for two of them every frame.
    private func barMenuTextWidth(_ name: String) -> CGFloat {
        if let width = barMenuTextWidths[name] { return width }
        let width = ceil((name as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium)
        ]).width)
        barMenuTextWidths[name] = width
        return width
    }

    /// The visible solid strip of the bar (below the concave corners). Floored to
    /// the button height so the buttons are always covered: portrait gets button
    /// room from its ~34pt home-indicator inset, but landscape has none — and with a
    /// large device corner radius (~55pt) the natural region (effectiveBarHeight -
    /// cornerRadius + inset) fell short of the 44pt buttons. Portrait's larger
    /// natural value still wins, so it's unaffected.
    public var barFlatRegion: CGFloat {
        let buttonRoom = Constants.barButtonSize * Constants.barContentScale + 14   // buttons + margin
        let base = max(effectiveBarHeight - barCornerRadiusActive, 0) + safeAreaInsets.bottom
        return max(base, buttonRoom)
    }

    // MARK: - Bar Edge / Orientation

    /// The space the bar is laid out in: the pass-through container that holds it,
    /// which tracks the overlay host it was added to.
    ///
    /// Not `UIScreen.main.bounds`. That describes the display, and the two part
    /// company whenever the overlay host is not turned the same way as the device —
    /// at which point a bar positioned by screen numbers lands wherever those
    /// numbers happen to fall in the host's own coordinates, which is nowhere in
    /// particular. Falls back outward through the hierarchy, and only reaches the
    /// screen when the bar has no home yet.
    private var barLayoutBounds: CGRect {
        let candidates = [
            barContainer?.bounds,
            barContainer?.superview?.bounds,
            hostingController?.view.superview?.bounds,
            keyWindow?.bounds,
        ]
        for case let bounds? in candidates where bounds.width > 0 && bounds.height > 0 {
            return bounds
        }
        return FlekTheme.screen.bounds
    }

    /// The bar's space as the user sees it — the layout's own rectangle, turned if
    /// the layout is not the way up the viewer is.
    private var barViewerSize: CGSize {
        let bounds = barLayoutBounds
        return viewerRotationSteps % 2 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
    }

    /// The side of the *user's view* the bar belongs on: its bottom when the view is
    /// upright, its right when the view is on its side. This is the rule stated in
    /// the terms the user sees it in, and everything else is derived from it.
    private var barViewerEdge: ScreenEdge {
        // Retained for the nav-assist button's frame conversions. The bar itself no
        // longer derives its edge from here — see `barLayoutEdge`.
        return .bottom
    }

    /// The layout edge that currently *is* `barViewerEdge`.
    ///
    /// The two are the same edge whenever the layout turns with the phone. When it
    /// does not — a host that stays put while the device turns — the side the user
    /// sees as the right of the screen is the layout's top or bottom, depending on
    /// which way the phone was turned, and the bar has to be drawn along that edge
    /// to appear where the rule says it should be.
    private var barLayoutEdge: ScreenEdge {
        // The device's chin — the hardware edge with the charging port, opposite
        // the sensor housing. That edge is the bar's home in every orientation.
        //
        // Taken from the interface orientation, which is the only thing that says
        // where the chin physically is once the interface has turned. The previous
        // rule put the bar on the viewer's right whenever the view was wider than
        // tall; `.right` is the chin on one landscape turn and the Dynamic Island
        // on the other, so half the time the bar sat behind the island with its
        // buttons unreachable. Nothing about "right" distinguishes the two turns.
        //
        // Reading the safe area instead does not work: landscape does not give the
        // asymmetric left/right insets that would be needed to locate the housing
        // that way.
        //
        // The enum names are inverted against `UIDeviceOrientation` — see
        // `interfaceRotationSteps`, where `.landscapeLeft` is documented as the
        // phone turned clockwise with the home button on the left. Home button on
        // the left means chin on the left, so:
        //
        //   turned clockwise      → interface .landscapeLeft  → chin left
        //   turned anticlockwise  → interface .landscapeRight → chin right
        //
        // iPad has no housing to avoid and keeps the bottom, as it always has.
        //
        // So does any display tall enough to spare the bar's height the other way
        // up. The bar only leaves the bottom when the height is what is short: an
        // iPhone on its side, or the iPhone Duo's cover display. The Duo unfolded is
        // a tablet-sized display on a phone, and keeps the bottom the way iPad does.
        // Read off the bar's own window, which is the scene the bar is drawn in.
        let window = hostingController?.view.window ?? keyWindow
        guard let traits = window?.traitCollection,
              traits.userInterfaceIdiom != .pad,
              traits.verticalSizeClass == .compact else { return .bottom }
        switch resolvedInterfaceOrientation(window?.windowScene) {
        case .landscapeLeft:  return .left
        case .landscapeRight: return .right
        default:              return .bottom
        }
    }

    /// `scene.interfaceOrientation`, corrected against the rectangle the bar is
    /// actually being laid out in.
    ///
    /// The two part company for a frame or two around every turn, and a turn is now
    /// asked for explicitly on several paths — going home, opening the switcher, a
    /// guest with an orientation lock coming to the front — so the window rotates at
    /// moments no device event accompanies. Reading the stale value lays the bar
    /// along the wrong edge, and `lastPlacedBarEdge` then caches that until
    /// something else happens to force a layout, which is why it only goes wrong
    /// some of the time.
    ///
    /// The layout rectangle cannot be stale about its own shape: it is the thing the
    /// bar is being positioned inside. So when the two disagree the rectangle wins,
    /// and the device says which of the two landscape directions it is. Same rule
    /// and same reason as `LCWindowOrientation` in DecoratedAppSceneViewController,
    /// which was written for this failure on the guest's side of the window.
    ///
    /// A pinned host is not a disagreement: its rectangle stays portrait and so does
    /// its reported orientation, so nothing here overrides it.
    private func resolvedInterfaceOrientation(_ scene: UIWindowScene?) -> UIInterfaceOrientation {
        let reported = scene?.interfaceOrientation ?? .portrait
        let bounds = barLayoutBounds
        guard bounds.width > 0, bounds.height > 0 else { return reported }

        let boundsAreLandscape = bounds.width > bounds.height
        if boundsAreLandscape == reported.isLandscape { return reported }

        switch UIDevice.current.orientation {
        case .landscapeLeft:      return .landscapeRight   // device and interface axes are mirrored
        case .landscapeRight:     return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: break
        }
        // Flat, or not yet reporting. The shape is still known even when the
        // direction is not, so keep the axis and pick either turn over ignoring it.
        return boundsAreLandscape ? .landscapeRight : .portrait
    }

    /// True from the moment the switcher is asked for until its overlay is up.
    ///
    /// The overlay is portrait-only and the turn to portrait is requested before it
    /// is built, so for the length of that turn the destination is known but nothing
    /// on screen says so: `isAppSwitcherOpen` is still false and the app's controls
    /// are still up. Anything recomputing the lock in that window read a pinned app
    /// on stage and handed the window back to its orientation, reversing the turn —
    /// after which the wait timed out, the overlay was built against landscape
    /// bounds, and `refreshSwitcherScreenSize`'s later re-samples were left to undo
    /// it in front of the user.
    private var isOpeningAppSwitcher = false

    /// The edge `updateDockFrame` last actually drew the bar along. Everything that
    /// has to agree with where the bar *is* — rather than re-derive where it should
    /// be — reads this, so a device reading taken at a different moment cannot put
    /// the bar and a guest window's reserved strip on two different edges.
    private var lastPlacedBarEdge: ScreenEdge?

    /// True between the start and end of a system rotation.
    ///
    /// While it is set, the device-orientation notification leaves the bar and the
    /// floating button alone. Both are moved by the rotation coordinator instead,
    /// which is the only place they can be moved smoothly: property changes made
    /// inside `animate(alongsideTransition:)` are interpolated with the system's
    /// own rotation, on its curve and over its duration, and land exactly as the
    /// screen finishes turning.
    private var isRotating = false

    /// Guards the self-healing clear below, so an earlier turn's timer cannot end a
    /// later turn that is still running.
    private var rotationEndToken: UInt64 = 0

    /// Marks a turn as started, and guarantees it will be marked finished.
    ///
    /// `isRotating` is what `whenWindowIsPortrait` waits on to know a turn is really
    /// over rather than merely begun, so a flag left set is not cosmetic: every later
    /// wait for an upright window runs to its cap instead of ending when the screen
    /// does, and the switcher takes three quarters of a second to appear every time.
    /// The coordinator's completion is the proper end of a turn and normally arrives,
    /// but an interrupted or cancelled transition never delivers one — so the flag is
    /// also cleared on a timer at rather more than a turn's length, which bounds how
    /// long it can be wrong to that.
    private func beginRotation() {
        isRotating = true
        rotationEndToken &+= 1
        let token = rotationEndToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rotationDuration * 2) { [weak self] in
            guard let self, self.rotationEndToken == token else { return }
            self.isRotating = false
        }
    }

    /// Marks a turn as finished, and retires its safety clear so it cannot fire into
    /// a turn that starts later.
    private func endRotation() {
        rotationEndToken &+= 1
        isRotating = false
    }

    /// True while the bar is parked off-screen for a rotation.
    ///
    /// Paired with `isRotating` rather than trusted alone: if the coordinator's
    /// completion never arrives — an interrupted or cancelled turn — the bar would
    /// otherwise stay parked forever. Every read requires both, so the first layout
    /// after a turn ends puts it back regardless.
    private var isBarSlidOut = false

    /// Whether the bar should currently be drawn off its edge.
    private var isBarParked: Bool { isBarSlidOut && isRotating }

    /// Whether the bar is laid out as a vertical strip, i.e. it sits on a left or
    /// right *layout* edge. Drives the -90° turn of the strip, the edge the internal
    /// pages reserve, and the bar content's own edge margins.
    private var isBarLandscape: Bool {
        let edge = barLayoutEdge
        return edge == .left || edge == .right
    }

    /// The side of the window the bar stands upright in, beside an iPhone Duo's
    /// status bar, or nil when it lies along an edge as it always has.
    ///
    /// The in-app half of Personalization's Side bar position: where the home screen
    /// stands its search button and running apps in the column that status bar runs
    /// down, the bar over an app stands in the same column, in the same place and at
    /// the same width, with its buttons upright and nothing turned. Folded and
    /// unfolded alike, but only while the system is showing a vertical bar at all.
    private static func sideColumnEdge(for traits: UITraitCollection?) -> ScreenEdge? {
        guard FlekDeviceModel.isDuo,
              LCUtils.appGroupUserDefault.string(forKey: FlekDeckKeys.homeBarPosition)
                == FlekHomeBarPosition.side.rawValue,
              let traits else { return nil }
        guard #available(iOS 27.1, *) else { return nil }
        // The bar's edge follows the layout direction; the window's sides do not.
        let rightToLeft = traits.layoutDirection == .rightToLeft
        switch traits.verticalBarEdge {
        case .leading:  return rightToLeft ? .right : .left
        case .trailing: return rightToLeft ? .left : .right
        default:        return nil
        }
    }

    /// Whether the bar stands in the side column rather than along an edge, for the
    /// pages that leave room for it at the bottom: in the column it takes none.
    static func barStandsInSideColumn(for traits: UITraitCollection?) -> Bool {
        sideColumnEdge(for: traits) != nil
    }

    /// Re-reads the side column for the switcher's controls.
    private func refreshSwitcherSideColumn() {
        let column = Self.sideColumnEdge(for: keyWindow?.traitCollection)
        let inColumn = column != nil
        let onLeft = column == .left
        if isSwitcherSideColumn != inColumn { isSwitcherSideColumn = inColumn }
        if isSwitcherSideColumnOnLeft != onLeft { isSwitcherSideColumnOnLeft = onLeft }
    }

    /// The side column the bar was last laid out in, if any. What the bar's
    /// transforms, the room it reserves and its published state all follow.
    private var placedSideColumnEdge: ScreenEdge? {
        didSet {
            let inColumn = placedSideColumnEdge != nil
            let onLeft = placedSideColumnEdge == .left
            if isSideColumnBar != inColumn { isSideColumnBar = inColumn }
            if isSideColumnOnLeft != onLeft { isSideColumnOnLeft = onLeft }
            // The column stands in the status bar's strip, which is all safe-area
            // inset. Left to it, the hosting view lays the buttons out in what the
            // inset leaves of its width — none — and they land off the strip's
            // centre; `ignoresSafeArea()` in the content doesn't win that back.
            if #available(iOS 16.4, *), let host = hostingController {
                let regions: SafeAreaRegions = inColumn ? [] : .all
                if host.safeAreaRegions != regions { host.safeAreaRegions = regions }
            }
        }
    }

    /// The side column's length: its three buttons stacked.
    private var sideColumnLength: CGFloat {
        FlekTheme.sideBarButtonSize * 3 + Constants.barSpacing * 2
    }

    /// A guest's report of its own side bar, in its window's points.
    private struct GuestSideBar {
        /// The lowest group of the app's items: its tab bar, where it has one.
        var lowerTop: CGFloat
        var lowerBottom: CGFloat
        /// The bottom of the app's items above that group, if it has any there.
        var upperBottom: CGFloat?
        /// The height of the window those are measured in, and the side of it the
        /// bar runs down.
        var windowHeight: CGFloat
        var onRight: Bool
    }

    /// How far the side column keeps from the app's own items: the gap iOS leaves
    /// between its own in that column.
    private static let sideColumnClearance: CGFloat = 12
    /// The highest the side column climbs over an app with nothing above its tab
    /// bar: where iOS starts an app's items, under the time and Wi-Fi, on the
    /// cover display. On the inner display they start at 124pt, so there the column
    /// stops 50pt short of where it could go.
    private static let sideColumnHighestTop: CGFloat = 174

    /// Told by a guest's window whenever the app's own side bar changes, packed as
    /// LCGuestSideBar packs it; 0 for an app with none, or none any more.
    @objc public func setGuestSideBar(_ state: UInt64, forAppUUID appUUID: String) {
        // On the main thread, whoever tells: what it decides moves the side
        // column and the floating button. A guest's notices arrive there, but its
        // clean-up as it ends (`-[AppSceneViewController appTerminationCleanUp]`)
        // comes on the extension's own queue, and laying the button out from
        // there tripped the main-thread assertion.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setGuestSideBar(state, forAppUUID: appUUID) }
            return
        }
        if state == 0 {
            guestSideBars[appUUID] = nil
        } else {
            let above = CGFloat((state >> 32) & 0xFFFF)
            guestSideBars[appUUID] = GuestSideBar(
                lowerTop: CGFloat(state & 0xFFFF),
                lowerBottom: CGFloat((state >> 16) & 0xFFFF),
                upperBottom: above > 0 ? above : nil,
                windowHeight: CGFloat((state >> 48) & 0x7FFF),
                onRight: (state >> 63) & 1 == 1)
        }
        if appUUID == frontmostAppUUID || splitPair?.contains(appUUID) == true {
            refreshSideColumnRoom()
        }
    }

    /// The app the side column stands over: the one in front, or with two side by
    /// side, the one on the column's side of the fold, whichever is in use. The
    /// column only ever stands over that one.
    private func appUnderSideColumn(_ column: ScreenEdge) -> String? {
        guard isSplitShowing, let pair = splitPair else { return frontmostAppUUID }
        switch column {
        case .left: return pair.left
        case .right: return pair.right
        default: return frontmostAppUUID
        }
    }

    /// Where the side column's foot goes over the app in front, in `bounds`: its
    /// usual place, or above the app's tab bar where that would be under it. Nil
    /// when the app's own side bar leaves no room for it anywhere.
    ///
    /// Only for an app that fills the screen: a smaller window's side bar runs
    /// down its own edge, nowhere near the column.
    private func sideColumnFoot(column: ScreenEdge, in bounds: CGRect) -> CGFloat? {
        let standardFoot = bounds.maxY - FlekTheme.bottomBarScreenMargin
        guard let bar = frontmostSideBar(column: column, in: bounds) else { return standardFoot }
        let gap = Self.sideColumnClearance
        let length = sideColumnLength
        // Clear of the app's lowest group where it always stands: an app whose
        // items are all at the top.
        if bar.lowerBottom + gap + length <= standardFoot { return standardFoot }
        // Otherwise above it, as close as iOS stacks its own items, and below
        // whatever the app has higher up, or where iOS would start it.
        let foot = min(standardFoot, bar.lowerTop - gap)
        return foot - length >= bar.highestTop ? foot : nil
    }

    /// The own side bar of the app under the side column (`appUnderSideColumn`),
    /// in `bounds`, where it runs down `column`'s side of a window as tall as the
    /// screen: its lowest group, and the highest anything of FlekDeck's may go
    /// above it — clear of what the app has higher up, or where iOS would start
    /// the app's items. Nil for any other app.
    private func frontmostSideBar(column: ScreenEdge, in bounds: CGRect)
        -> (lowerTop: CGFloat, lowerBottom: CGFloat, highestTop: CGFloat)? {
        guard let uuid = appUnderSideColumn(column),
              let bar = guestSideBars[uuid],
              bar.onRight == (column == .right),
              bar.windowHeight > 0,
              let decorated = apps.first(where: { $0.appUUID == uuid })?.view?._viewDelegate()
                as? DecoratedAppSceneViewController,
              decorated.isMaximized else { return nil }
        // From the window's own size rather than where it is drawn, which a window
        // flying in or out of its icon is not yet, or no longer.
        let scale = bounds.height / bar.windowHeight
        return (bounds.minY + bar.lowerTop * scale,
                bounds.minY + bar.lowerBottom * scale,
                bar.upperBottom.map { bounds.minY + $0 * scale + Self.sideColumnClearance }
                    ?? bounds.minY + Self.sideColumnHighestTop)
    }

    /// Where a fresh floating button's middle goes on the right of `host`, when an
    /// iPhone Duo stands the app's own side bar down that side too: halfway down if
    /// that is clear of the app's items, or else just above its tabs, as the side
    /// column goes. Nil for halfway down regardless — no side bar on that side, or
    /// no room above its tabs either.
    private func navAssistSpotClearOfSideBar(in host: UIView) -> CGFloat? {
        guard Self.sideColumnEdge(for: keyWindow?.traitCollection) == .right,
              let bar = frontmostSideBar(column: .right, in: host.bounds) else { return nil }
        let half = navAssistSize / 2
        let gap = Self.sideColumnClearance
        let range = navAssistAlongRange(for: .right, in: host.bounds, insets: host.safeAreaInsets)
        let middle = (range.lowerBound + range.upperBound) / 2
        let clearOfLowest = middle + half + gap <= bar.lowerTop || middle - half - gap >= bar.lowerBottom
        if clearOfLowest, middle - half >= bar.highestTop { return nil }
        let aboveTabs = bar.lowerTop - gap - half
        return aboveTabs - half >= bar.highestTop ? aboveTabs : nil
    }

    /// Settles a fresh floating button on the right: above the app's tabs where
    /// halfway down would be over them (`navAssistSpotClearOfSideBar`), halfway
    /// down otherwise.
    private func placeNavAssistClearOfSideBar(in host: UIView) {
        if let spot = navAssistSpotClearOfSideBar(in: host) {
            let range = navAssistAlongRange(for: .right, in: host.bounds, insets: host.safeAreaInsets)
            rememberScreenPlacement(edge: .right, fraction: navAssistFraction(of: spot, in: range))
        } else {
            navAssistViewEdge = .right
            navAssistAlongFraction = 0.5
        }
    }

    /// Moves a floating button nobody has moved by hand to wherever a fresh one
    /// would go now, as the app's side bar changes under it: from halfway down to
    /// above the tabs, and back.
    private func refreshNavAssistSpot() {
        guard navAssistFollowsSideBar, !isNavAssistStashed,
              let button = navAssistButton, let host = button.superview else { return }
        placeNavAssistClearOfSideBar(in: host)
        placeNavAssist(button, stashed: false, animated: true)
    }

    /// Decides again whether the side column has room over the app in front:
    /// moves it there if so, and hands over to the floating button if not — and
    /// back, once there is room again, unless the floating button was chosen.
    private func refreshSideColumnRoom() {
        // Left as it is while home: the app in front is the one that comes back,
        // and its window, put away, is no measure of anything.
        guard !isHomeState else { return }
        let column = Self.sideColumnEdge(for: keyWindow?.traitCollection)
        let noRoom = column.map { sideColumnFoot(column: $0, in: barLayoutBounds) == nil } ?? false
        // The floating button, where it is up and nobody has moved it, goes with the
        // app's side bar too.
        defer { refreshNavAssistSpot() }
        guard noRoom != sideColumnStepsAside else {
            // The same answer, but perhaps another place for the column.
            if isVisible, isSwitcherBarVisible, column != nil { updateDockFrame() }
            return
        }
        sideColumnStepsAside = noRoom
        // The switcher puts up whichever control is due as it closes.
        guard isVisible, !isAppSwitcherOpen else { return }
        if noRoom {
            if isSwitcherBarVisible { hideSwitcherBar(choosingFloatingButton: false) }
        } else if !prefersFloatingButton, !isSwitcherBarVisible, hasForegroundAppWindow() {
            showSwitcherBar(choosingBar: false)
        }
    }

    /// The resting transform of the bar's hosting view: the turn that lays the
    /// strip along its layout edge with its concave top facing into the screen.
    ///
    /// The strip is always built the same way — long axis horizontal, ledge along
    /// its own top — so identity puts it on the bottom edge and each quarter-turn
    /// walks it round to the next one. Facing the interior is what makes the bar
    /// read the same to the user on every edge: the content leans into the screen,
    /// exactly as the landscape bar has always done.
    ///
    /// In the side column there is no turn: the column stands upright as it is.
    private var barBaseTransform: CGAffineTransform {
        if placedSideColumnEdge != nil { return .identity }
        switch barLayoutEdge {
        case .bottom: return .identity
        case .right:  return CGAffineTransform(rotationAngle: -.pi / 2)
        case .left:   return CGAffineTransform(rotationAngle: .pi / 2)
        case .top:    return CGAffineTransform(rotationAngle: .pi)
        }
    }

    /// The transform used while the bar is hidden/off-screen. The slide offset
    /// is applied in the bar's *local* space (before rotation), so a local
    /// downward slide becomes an off-bottom slide in portrait and an off-right
    /// slide in landscape — the bar always exits through its own short edge.
    private func barHiddenTransform(offset: CGFloat = 50) -> CGAffineTransform {
        // The side column leaves through the edge it stands beside, and goes the
        // whole way: it sits that far in from the edge and has its width to clear.
        if let column = placedSideColumnEdge {
            let travel = max(offset, FlekTheme.sideBarCentreInset + FlekTheme.sideBarWidth)
            return CGAffineTransform(translationX: column == .left ? -travel : travel, y: 0)
        }
        return CGAffineTransform(translationX: 0, y: offset).concatenating(barBaseTransform)
    }

    // MARK: - Bar Width Calculation
    private func barWidth() -> CGFloat {
        // Side buttons: hide + home
        let sideButtonsWidth = Constants.barButtonSize * 2 + Constants.barSpacing * 2
        
        // Menu label: a fixed capsule now, whatever the app is called — the name
        // truncates inside it rather than stretching it.
        return Constants.barHPadding + sideButtonsWidth + barMenuWidth + Constants.barHPadding
    }
    
    private func frontmostAppName() -> String {
        if let uuid = quickSwitchLanding ?? frontmostAppUUID,
           let app = apps.first(where: { $0.appUUID == uuid }) {
            return app.appName
        }
        return apps.last?.appName ?? "App"
    }

    /// The running app `uuid` names, if it is still running.
    func dockApp(_ uuid: String) -> DockAppModel? {
        apps.first { $0.appUUID == uuid }
    }
    
    override init() {
        super.init()
        // Every launch starts with the switcher bar as the control. The
        // floating-button choice is session-only and deliberately NOT restored on
        // relaunch, so the user always returns to the bar after quitting (and, since
        // the bar mode lays the bar out, its sizing is always captured correctly —
        // floating-button mode skips that layout).
        prefersFloatingButton = false
        LCUtils.appGroupUserDefault.set(false, forKey: MultitaskDockManager.preferFloatingButtonKey)
        keyWindow!.rootViewController!.view.addSubview(self.windowHostingView)
        // Ask UIKit to keep `UIDevice.current.orientation` live. Without this the
        // device orientation reads as unknown and its notification may never fire —
        // and when the interface itself is not rotating, the phone being turned is
        // the *only* signal that the floating button has to move.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Keep the device reading live for the rotation lock. Unconditional, and
        // separate from the overlay below: the lock has to behave identically
        // whether or not the diagnostic panel is switched on.
        LCRotationLock.beginTracking()
        // Position + lock readout, with a manual lock button. Off unless switched
        // on under Multitask > Developer — the rotation lock itself always runs;
        // this only shows what it is doing and offers a manual override.
        // The overlay is always created and never torn down; the setting only
        // decides whether its panel is drawn.
        //
        // The rotation lock engages while this overlay exists and does not when it
        // is absent — reproducibly, and for reasons I could not find. Creating it
        // once at launch and removing it again was not enough, so it is not merely
        // having existed: it has to still be there while a guest is running. The
        // configuration that demonstrably works is "overlay on", so that is the
        // configuration shipped, minus the pixels.
        // `LCShowRotationPanel`, a fresh key: the old `LCShowRotationOverlay` used
        // to decide whether the overlay existed at all, and anyone who switched it
        // on then would otherwise inherit a visible panel now that the flag means
        // something narrower.
        LCRotationLockOverlay.isPanelVisible =
            LCUtils.appGroupUserDefault.bool(forKey: "LCShowRotationPanel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            LCRotationLockOverlay.shared.start()
        }
        if let win = keyWindow { attachSafeAreaSentinel(to: win) }
        refreshCachedSafeAreaInsets()
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        // Safety net: whenever LiveContainer returns to the foreground, make sure a
        // foregrounded app/page always exposes a way to minimize or exit it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // Re-lay out the bar live when the rounded/flat design toggle changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(barDesignSettingChanged),
            name: .multitaskBarDesignChanged,
            object: nil
        )
        // A guest window announcing it has something to show. Sent rather than
        // called, the way the bar's own state travels between these two files:
        // the window is Objective-C and the dock is Swift, and a notification
        // needs neither side's generated header to reach the other.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowContentDidArrive(_:)),
            name: .lcWindowContentDidArrive,
            object: nil
        )
        // Show or hide the home bar the moment its Settings toggle changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(swipeZoneSettingChanged),
            name: .multitaskHomeBarSettingChanged,
            object: nil
        )
        // Move the bar into or out of the side column the moment Bar Position
        // changes — the page that changes it is itself up over the bar.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(barPositionSettingChanged),
            name: .multitaskBarPositionChanged,
            object: nil
        )
        // The bar and the bottom swipe share the bottom edge, and only one of them
        // may own it. Every path that raises or lowers the bar announces itself
        // here, so this is the one place able to reconcile the two whichever path
        // made the change — several of them hand the bar over inside an animation's
        // completion, and one used to not hand it over at all.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(barVisibilityChanged),
            name: .multitaskBarVisibilityChanged,
            object: nil
        )
    }

    /// Take the bottom swipe zone down when the bar takes the bottom edge back.
    ///
    /// Deferred by a turn of the runloop because the bar's own announcement runs
    /// ahead of the control that replaces it: `hideSwitcherBar` posts before it puts
    /// the swipe zone up, and a teardown in the same turn would be asking about a
    /// zone that does not exist yet and would miss the one that follows.
    @objc private func barVisibilityChanged() {
        DispatchQueue.main.async {
            guard self.swipeZone != nil, self.isSwitcherBarHoldingBottomEdge else { return }
            self.tearDownSwipeZone()
        }
    }

    /// Swap between the floating button and the swipe zone when the setting changes.
    ///
    /// Only while one of them is actually up — this picks which of the two is shown,
    /// not whether a control is shown at all, and `showNavAssist` is the single place
    /// that decides. Asking whether either is on screen is a more direct test than
    /// re-deriving the conditions it was called under.
    @objc private func swipeZoneSettingChanged() {
        DispatchQueue.main.async {
            guard self.navAssistButton != nil || self.swipeZone != nil,
                  let keyWindow = self.keyWindow else { return }
            self.showNavAssist(in: keyWindow)
        }
    }

    /// Live-apply the rounded/flat bar design when its Settings toggle changes.
    /// Safe to do live because the toggle is a Settings list row, not a control
    /// sitting on the bar. `updateDockFrame` re-reads the setting via
    /// `captureBarDesign()` and animates the strip to the new size/shape. If the
    /// bar isn't on screen, the next layout picks the design up on its own.
    @objc private func barDesignSettingChanged() {
        DispatchQueue.main.async {
            // Both designs share the same strip size, so re-reading the design
            // (rounded/flat + corner radius) into the published state is all that's
            // needed to re-render the bar live — no re-layout. `captureBarDesign`
            // only publishes when a value actually changed.
            self.captureBarDesign()
        }
    }

    @objc private func barPositionSettingChanged() {
        DispatchQueue.main.async {
            // In the side column or out of it, the app's side bar matters or not.
            self.refreshSideColumnRoom()
            if self.isVisible && self.isSwitcherBarVisible {
                self.updateDockFrame()
            }
        }
    }

    @objc private func appDidBecomeActive() {
        ensureControlAccessible()
        DispatchQueue.main.async {
            // Keep the safe-area sentinel on the current key window (it can change
            // across scene transitions), and re-lay out the bar if it's already
            // visible: on a cold relaunch the bar can first appear before the safe
            // area is ready, and `ensureControlAccessible` won't re-lay out a bar
            // that's already shown — so it would otherwise stay mis-sized.
            if let win = self.keyWindow { self.attachSafeAreaSentinel(to: win) }
            self.refreshCachedSafeAreaInsets()
            if self.isVisible && self.isSwitcherBarVisible {
                self.updateDockFrame(animated: false)
            }
        }
    }

    /// The view the bar, the floating button and the switcher overlay are parented
    /// to: the root of the overlay window, created on first use.
    ///
    /// Created lazily rather than at init so the app's own window is long since
    /// key by the time this one appears — a window made visible while nothing else
    /// is key can be handed the key window role, and this one must never have it.
    ///
    /// Follows the app if it ever moves to another scene (an in-place update can
    /// restore one), carrying whatever is on screen across rather than stranding
    /// it on a window the user is no longer looking at.
    private func overlayHostView() -> UIView? {
        guard let scene = keyWindow?.windowScene else {
            return overlayWindow?.rootViewController?.view
        }
        if let existing = overlayWindow, existing.windowScene === scene {
            existing.isHidden = false
            return existing.rootViewController?.view
        }

        let window = MultitaskOverlayWindow(windowScene: scene)
        // One level above the app's own window: past every presentation made
        // inside it, and still below the status bar and the system's own alert
        // windows, which have no business being covered by ours.
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = MultitaskOverlayRootViewController()
        // The button is positioned in this host's coordinate space, so the host is
        // what has to be re-measured when it changes size — a rotation, or anything
        // else that resizes the window. Runs both from the rotation coordinator (so
        // the move rides the system animation) and from the host's own layout (the
        // authoritative moment, whatever order the rotation callbacks arrive in).
        // A turn takes the bar off its old edge, moves it while it cannot be seen,
        // and brings it back in on the new one. Out and in take half the rotation
        // each, so the whole thing lasts exactly as long as the screen takes to
        // turn. Riding the coordinator's interpolation instead sweeps the bar round
        // the corner, because its own quarter-turn and the window's compose into a
        // longer arc than either.
        root.onHostRotationBegan = { [weak self] in
            guard let self else { return }
            self.beginRotation()
            guard self.isVisible, self.isSwitcherBarVisible,
                  let host = self.hostingController else { return }
            self.isBarSlidOut = true
            UIView.animate(withDuration: Self.rotationDuration / 2, delay: 0,
                           options: [.curveEaseIn, .allowUserInteraction]) {
                host.view.transform = self.barHiddenTransform()
            }
        }
        root.onHostRotationEnded = { [weak self] in
            guard let self else { return }
            self.endRotation()
            guard self.isBarSlidOut else { return }
            self.isBarSlidOut = false
            guard let host = self.hostingController else { return }
            UIView.animate(withDuration: Self.rotationDuration / 2, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                host.view.transform = self.barBaseTransform
            }
        }
        root.onHostGeometryChange = { [weak self] bounds in
            guard let self else { return }
            // The bar is measured against this same host, so it re-lays out here too
            // rather than waiting on a device notification that may fire before the
            // host has resized — or, when the host is not the thing turning, never
            // describe this host at all.
            if self.isVisible && self.isSwitcherBarVisible {
                if self.isBarParked {
                    // Explicitly unanimated. This runs inside the coordinator's
                    // block, where a plain assignment is interpolated — and
                    // interpolating from one off-screen position to another can
                    // cross the visible area on the way.
                    UIView.performWithoutAnimation { self.updateDockFrame(animated: false) }
                } else {
                    self.updateDockFrame(animated: false)
                }
            }
            // Ahead of the button's guard: the strip spans the bottom edge whatever
            // the button is doing, and a return there would leave it on the old size.
            self.placeSwipeZone(in: bounds)
            guard let button = self.navAssistButton, !self.isNavAssistDragging else { return }
            self.placeNavAssist(button, in: bounds, stashed: self.isNavAssistStashed, animated: false)
        }
        window.rootViewController = root
        window.isHidden = false

        // Both windows share the scene's coordinate space, so the frames the
        // moved views already have still mean the same thing here.
        if let old = overlayWindow?.rootViewController?.view,
           let new = window.rootViewController?.view {
            for subview in old.subviews {
                new.addSubview(subview)
            }
        }
        overlayWindow?.isHidden = true
        overlayWindow = window
        return window.rootViewController?.view
    }

    /// Attach the safe-area sentinel to `window` (moving it if the key window
    /// changed) so a later safe-area update re-lays out the bar and internal-page
    /// reservations with the correct inset.
    private func attachSafeAreaSentinel(to window: UIWindow) {
        if safeAreaSentinel.onChange == nil {
            safeAreaSentinel.backgroundColor = .clear
            safeAreaSentinel.isUserInteractionEnabled = false
            safeAreaSentinel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            safeAreaSentinel.onChange = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.refreshCachedSafeAreaInsets()
                    if self.isVisible && self.isSwitcherBarVisible {
                        self.updateDockFrame(animated: false)
                    }
                    let reserved = self.isVisible && self.isSwitcherBarVisible
                    for (_, controller) in self.internalPageControllers {
                        self.applyBarInset(to: controller, reserved: reserved)
                    }
                    // And the guest windows, which were the one thing this repaired
                    // nothing for.
                    //
                    // A window's safe area can still read zero when a guest is first
                    // laid out — `updateDockFrame` says so itself and re-reads for the
                    // bar — and the guest's frame, its periphery insets and the shape
                    // of its drawable are all measured through it. Nothing else asks
                    // again: the host view re-derives on a bounds change, and a safe
                    // area resolving is not one. So a guest opened into a not-yet-ready
                    // inset kept it, drawing under the notch or short of the window,
                    // until some unrelated change happened to push fresh settings.
                    NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
                }
            }
        }
        if safeAreaSentinel.superview !== window {
            safeAreaSentinel.removeFromSuperview()
            safeAreaSentinel.frame = window.bounds
            window.addSubview(safeAreaSentinel)
            window.sendSubviewToBack(safeAreaSentinel)
        }
    }

    
    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange() {
        // Face-up and face-down are not orientations anything here can act on.
        //
        // `UIDevice` reports them alongside the four real ones, and they describe
        // the phone's relationship to the ground rather than to the viewer — a
        // phone set down on a table is still being read the same way round it was
        // a moment earlier. Every consumer below re-derives geometry from "which
        // way is the device", so letting a face-up transition through means
        // re-deriving all of it from a reading that carries no such information,
        // and the answers that come back are whatever the fallbacks happen to say.
        // That is the whole of the bug where laying the phone flat while holding
        // it in landscape snapped the window back to portrait: the turn was not
        // decided anywhere, it fell out of a dozen defaults at once.
        //
        // iOS itself holds the interface across face-up, which is why a native app
        // laid on a table keeps its orientation. This does the same by refusing to
        // treat the transition as news.
        guard UIDevice.current.orientation.isValidInterfaceOrientation else { return }
        DispatchQueue.main.async {
            // Re-size the switcher's cards for the orientation they are now in.
            self.refreshSwitcherScreenSize()
            // Left to the rotation coordinator when the interface is turning.
            //
            // This used to snap the bar into place here, to avoid animating the
            // bar's own -90° turn on top of the window's — which does read as a
            // compounded spin. But snapping was the wrong half to keep: this
            // notification arrives before the coordinator's block runs, so the bar
            // had already jumped to its new edge and there was nothing left for the
            // system animation to carry. Standing aside lets the coordinator move
            // it, which is both smooth and correct, because changes made inside its
            // block are interpolated with the rotation rather than against it.
            //
            // Still runs when the interface is not turning — a portrait-locked host
            // with the phone turned in the hand — where there is no coordinator and
            // no animation to ride.
            if self.isVisible && !self.isRotating {
                self.updateDockFrame(animated: false)
            }
            // Every open guest re-measures on a turn, whatever the bar decided to do.
            //
            // `updateDockFrame` only tells them when the bar changes edge — and it
            // does not change edge in one of the two landscape directions, because
            // the viewer's right lands on the layout's bottom both when the phone is
            // upright and when it is turned that way. So in that direction nothing
            // recomputed a guest's insets at all and it kept the ones it was handed
            // upright, which is a clearance sitting on an edge that turned away from
            // what it was clearing. Posted from here rather than from inside
            // `updateDockFrame` for a second reason: the post there runs before the
            // bar has actually moved, so the reservation would still measure the old
            // strip.
            // Only for a turn that means something. `UIDevice` reports face-up and
            // face-down alongside the four real orientations, and neither changes
            // any geometry — re-framing every guest window on them is work nobody
            // asked for, inside an animation the user can see.
            if UIDevice.current.orientation.isValidInterfaceOrientation {
                NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            }
            // Put the floating button back on the edge it was already on, measured
            // in its host's bounds. Not gated on `isVisible` (that tracks the bar)
            // and deliberately outside it: the button is its own control, and this
            // is a cheap idempotent re-place. The host's layout callback repeats it
            // once the rotation settles, which is what makes a device notification
            // arriving before the window has resized harmless.
            if let button = self.navAssistButton, !self.isNavAssistDragging, !self.isRotating {
                // Animated: when the interface is not rotating there is no system
                // animation for the move to hide inside, and a jump reads as a
                // glitch. When it is, this pass finds the button already at its
                // target and the animation costs nothing.
                self.placeNavAssist(button, stashed: self.isNavAssistStashed, animated: true)
            }
            // Move the internal-page bar reservation to the correct edge for the
            // new orientation (bottom in portrait, right in landscape).
            let reserved = self.isVisible && self.isSwitcherBarVisible
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: reserved)
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            // Capture the design once at startup so `barCornerRadiusActive` reflects
            // the device radius from the start (used by the bar reserve and the
            // switcher toggle) even before the bar is first laid out.
            self.captureBarDesign()
            let barView = AnyView(SwitcherBarContentView()
                .environmentObject(self)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark))
            
            self.hostingController = UIHostingController(rootView: barView)
            self.hostingController?.view.backgroundColor = .clear
            self.hostingController?.view.clipsToBounds = false
            self.hostingController?.view.insetsLayoutMarginsFromSafeArea = false
            self.hostingController?.overrideUserInterfaceStyle = .dark
            self.hostingController?.view.overrideUserInterfaceStyle = .dark

            // Wrap the bar in a full-window pass-through container so taps that land
            // in the bar's transparent concave corners / overhang reach the content
            // underneath (guest apps and internal-page controls like Import IPA /
            // search) instead of being swallowed by the rectangular hosting view.
            // The container hit-tests against the bar's actual shape.
            let container = BarPassthroughContainer()
            container.backgroundColor = .clear
            container.clipsToBounds = false
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let barView = self.hostingController?.view {
                container.barView = barView
                container.addSubview(barView)
            }
            container.hitPathProvider = { [weak self] bounds in
                // Landscape / plain bar fills its whole bounds (nil == full rect).
                // Both designs (portrait and landscape) leave the region above the
                // flat-top line transparent, so hit-test against the actual fill shape
                // and pass taps above it through to the content beneath. The point is
                // converted into the bar's un-rotated local space below, so the same
                // local shape works in landscape after the -90° transform.
                guard let self = self else { return nil }
                // The side column is its buttons and nothing else: all of it is bar.
                guard !self.isSideColumnBar else { return nil }
                let r = self.barCornerRadiusActive
                let cg = self.barLedgeActive
                    ? BarTopBar(radius: r, curve: r * self.barLedgeAmountActive)
                        .path(in: bounds).cgPath
                    : BarFlatTop(inset: r).path(in: bounds).cgPath
                return UIBezierPath(cgPath: cg)
            }
            self.barContainer = container
        }
    }

    // MARK: - Frame Management

    /// Positions the switcher bar on the current short edge — bottom in
    /// portrait, right edge in landscape — keeping identical portrait sizing.
    ///
    /// The hosting view's *local* bounds are always a horizontal strip
    /// (`length × thickness`, thickness = barHeight + outer safe-area inset).
    /// In landscape the view is rotated -90° via `barBaseTransform`, turning the
    /// horizontal pill into a vertical one hugging the right edge. Because the
    /// view carries a transform, we drive it with bounds + center + transform
    /// rather than `frame` (setting `frame` under a non-identity transform is
    /// undefined).
    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController, isSwitcherBarVisible else { return }
        refreshSplitLight()

        // Pick up the current design as the bar (re)lays out — never mid-toggle.
        captureBarDesign()

        // Keep the published orientation flag in sync so the bar content picks
        // the right edge margin (-2 portrait, -10 landscape).
        if isLandscapeBar != isBarLandscape {
            isLandscapeBar = isBarLandscape
        }

        let screenBounds = barLayoutBounds
        var insets = safeAreaInsets
        // On a fast, state-restored launch (after an in-place update) the window's
        // safe area can still be zero when the bar first lays out, which would size
        // the bar without the home-indicator inset. Force a layout pass and re-read
        // so a late-arriving bottom inset is applied instead of baked in as zero.
        if barLayoutEdge == .bottom, insets.bottom == 0, let win = keyWindow {
            win.layoutIfNeeded()
            insets = win.safeAreaInsets
        }

        // Cross-thickness of the bar. Deliberately the same slim value in both
        // orientations so the landscape bar matches the portrait one instead of
        // ballooning to include the large horizontal safe-area inset (e.g. the
        // notch), which previously made it a wide full-height sidebar.
        // Strip = visible flat region + the concave corner radius carved above it.
        let thickness = barFlatRegion + barCornerRadiusActive


        // The strip spans its edge and its thickness reaches inward from it. Local
        // bounds are always a horizontal strip; `barBaseTransform` turns it onto the
        // edge, so the length here is the length of that edge.
        let edge = barLayoutEdge
        // Remembered for `barReservedInsets`, so what a guest window trims is the
        // edge the bar is on right now rather than a recomputed guess. Guests are
        // told when it moves, below.
        let edgeChanged = lastPlacedBarEdge != edge
        lastPlacedBarEdge = edge
        // Or upright in the side column beside an iPhone Duo's status bar, where the
        // home screen's own bar stands: centred on the status bar's column, its foot
        // as far from the bottom of the display as the home screen's. Placed before
        // `apply` runs, since the transforms it sets follow it.
        let column = Self.sideColumnEdge(for: keyWindow?.traitCollection)
        let columnChanged = placedSideColumnEdge != column
        placedSideColumnEdge = column
        let boundsSize: CGSize
        let center: CGPoint
        if let column {
            // Lifted above the app's own tab bar where it would be under it. With
            // no room at all it has stepped aside, and this is only where it would
            // stand; if that is out of step with what was decided, decide again.
            let foot = sideColumnFoot(column: column, in: screenBounds)
            if (foot == nil) != sideColumnStepsAside {
                DispatchQueue.main.async { self.refreshSideColumnRoom() }
            }
            boundsSize = CGSize(width: FlekTheme.sideBarWidth, height: sideColumnLength)
            center = CGPoint(
                x: column == .left
                    ? screenBounds.minX + FlekTheme.sideBarCentreInset
                    : screenBounds.maxX - FlekTheme.sideBarCentreInset,
                y: (foot ?? screenBounds.maxY - FlekTheme.bottomBarScreenMargin) - sideColumnLength / 2
            )
        } else {
            switch edge {
            case .bottom:
                boundsSize = CGSize(width: screenBounds.width, height: thickness)
                center = CGPoint(x: screenBounds.midX, y: screenBounds.height - thickness / 2)
            case .top:
                boundsSize = CGSize(width: screenBounds.width, height: thickness)
                center = CGPoint(x: screenBounds.midX, y: thickness / 2)
            case .right:
                boundsSize = CGSize(width: screenBounds.height, height: thickness)
                center = CGPoint(x: screenBounds.width - thickness / 2, y: screenBounds.midY)
            case .left:
                boundsSize = CGSize(width: screenBounds.height, height: thickness)
                center = CGPoint(x: thickness / 2, y: screenBounds.midY)
            }
        }

        let apply = {
            hostingController.view.bounds = CGRect(origin: .zero, size: boundsSize)
            // Parked while the screen turns, so the move to the new edge happens
            // out of sight and the bar slides back in rather than sweeping round
            // the corner.
            hostingController.view.transform = self.isBarParked
                ? self.barHiddenTransform()
                : self.barBaseTransform
            hostingController.view.center = center
        }

        // A guest window reserves the bar's strip on whichever edge it is on, so a
        // bar that moves to another edge leaves every open guest trimmed against
        // the old one. This is the same notification the show/hide path posts, and
        // it re-frames each maximized window and resizes its drawable.
        //
        // Moving into or out of the side column is the same: in the column the bar
        // takes no room from a window, and along an edge it does. Built-in pages keep
        // their own reservation, so they are told directly.
        if edgeChanged || columnChanged {
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        }
        if columnChanged {
            for (_, controller) in internalPageControllers {
                applyBarInset(to: controller, reserved: true)
            }
        }

        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                // The bar carries the buttons that leave an app, and a view being
                // animated by UIKit takes no touches unless it is asked to. Without
                // this it is dead to the touch for the length of every re-layout.
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                apply()
            }
        } else {
            apply()
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            // Before the app leaves the list, while its controller can still be
            // found: anything it presented goes with it.
            self.dismissPresentation(forAppUUID: appUUID)
            // Read while the app is still in the list: a window closed before its
            // app ever drew would otherwise leave its launch screen behind here.
            if let view = self.apps.first(where: { $0.appUUID == appUUID })?.view {
                self.launchPlaceholders.removeValue(forKey: ObjectIdentifier(view))
                self.windowsWithContent.remove(ObjectIdentifier(view))
            }
            // Animate the list mutation so the remaining switcher cards slide in
            // to fill the gap smoothly instead of snapping into place.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                self.apps.removeAll { $0.appUUID == appUUID }
            }
            // One of two side by side closed: the other has the screen to itself.
            if self.splitPair?.contains(appUUID) == true { self.endSplit() }
            if self.splitSuspended?.contains(appUUID) == true { self.dissolveSuspendedSplit() }
            self.appSnapshotViews.removeValue(forKey: appUUID)
            self.appSnapshotSizes.removeValue(forKey: appUUID)
            self.appSnapshotImages.removeValue(forKey: appUUID)
            self.appSnapshotRotations.removeValue(forKey: appUUID)
            self.splitPaneSnapshots.remove(appUUID)
            self.appSnapshotDisplays.removeValue(forKey: appUUID)
            if let hostVC = self.internalPageControllers.removeValue(forKey: appUUID) {
                hostVC.willMove(toParent: nil)
                hostVC.view.removeFromSuperview()
                hostVC.removeFromParent()
            }
            
            if self.frontmostAppUUID == appUUID {
                self.updateFrontmostApp()
            }
            
            if self.apps.isEmpty {
                if self.isAppSwitcherOpen {
                    // Dismiss overlay without restoring bar (since we're hiding dock next)
                    self.isAppSwitcherOpen = false
                    if let overlay = self.switcherOverlayController {
                        // Eased out over the standard duration: this uncovers the live
                        // springboard, whose icons carry glass the backdrop's snapshot
                        // does not, and a short ease-in dropped that difference in on
                        // the last frame.
                        UIView.animate(withDuration: Constants.standardAnimationDuration,
                                       delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                            overlay.view.alpha = 0
                        } completion: { _ in
                            overlay.view.removeFromSuperview()
                            overlay.view.alpha = 1
                        }
                    }
                }
                // No apps left: we are effectively on the springboard now. Record the
                // home state so control-visibility logic stays consistent.
                self.isHomeState = true
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
                // A different app is in front now, and it may be pinned where the
                // one that just left was not — or the other way round.
                self.refreshOrientationLock()
            }
        }
    }
    
    // MARK: - Show/Hide Dock (lifecycle — called when apps are added/removed)
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            // Up again after the switcher went home, which leaves Close all on. Put
            // back as it is rather than turned, even with the app's name just
            // changed: the bar is only now coming into view.
            if !self.isAppSwitcherOpen, self.barShowsCloseAll {
                var instantly = Transaction()
                instantly.disablesAnimations = true
                withTransaction(instantly) { self.barShowsCloseAll = false }
            }
            // Capture the design (corner radius + rounded/flat) now, even in
            // floating-button mode where the bar isn't laid out. Otherwise
            // `captureBarDesign()` — which only runs inside `updateDockFrame` — never
            // fires, leaving `barCornerRadiusActive` at its default and the switcher
            // toggle / bar reserve sized with the wrong radius.
            self.captureBarDesign()

            // Honor the saved control preference: show the floating button
            // instead of the bar when the user has chosen it, or while the side
            // column has no room over the app.
            if self.usesFloatingButton {
                self.isSwitcherBarVisible = false
                // No bar on screen → don't reserve its strip on internal pages.
                for (_, controller) in self.internalPageControllers {
                    self.applyBarInset(to: controller, reserved: false)
                }
                hostingController.view.isHidden = true
                hostingController.view.alpha = 0
                if !self.isHomeState && self.hasForegroundAppWindow() {
                    self.showNavAssist(in: keyWindow)
                }
                self.refreshOrientationLock()
                NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
                return
            }

            self.isSwitcherBarVisible = true
            // Whatever was standing in for the bar goes as the bar arrives — the
            // other end of the exchange `showSwitcherBar` makes, for the path that
            // brings the bar back by putting the whole dock up rather than by
            // sliding the bar in.
            self.navAssistButton?.removeFromSuperview()
            self.navAssistButton = nil
            self.isNavAssistStashed = false
            self.navAssistChevron = nil
            self.tearDownSwipeZone()
            self.refreshOrientationLock()

            // Reserve space for the bar on its current edge for internal pages
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: true)
            }

            // Add the pass-through container (which holds the bar) to the overlay
            // window, out of reach of anything presented in the app's own.
            let host: UIView = self.overlayHostView() ?? keyWindow
            if let container = self.barContainer {
                container.frame = host.bounds
                if container.superview !== host {
                    host.addSubview(container)
                } else {
                    host.bringSubviewToFront(container)
                }
            } else if hostingController.view.superview == nil {
                host.addSubview(hostingController.view)
            }

            self.updateDockFrame(animated: false)

            hostingController.view.isHidden = false
            hostingController.view.alpha = 0
            let slideOffset = max(hostingController.view.bounds.height, 120)
            hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)

            // Smooth ease-in-out slide up from just below the edge (no spring kick).
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    hostingController.view.alpha = 1
                    hostingController.view.transform = self.barBaseTransform
                }
            )

            // Tell the windows the bar is here, now that it has been laid out and
            // the strip it occupies is known. Hiding and showing the bar announced
            // itself; its first appearance did not — so a window opened before the
            // bar existed kept the full-height frame it was given and left its
            // guest drawing underneath the bar, until some later change happened to
            // put the frame right. Toggling the bar was that later change.
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        }
    }

    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            self.isVisible = false

            // Remove the bar reservation from internal pages
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: false)
            }

            // Also remove nav assist if visible
            self.navAssistButton?.removeFromSuperview()
            self.navAssistButton = nil
            self.tearDownSwipeZone()

            // No control on screen anymore → back to portrait (springboard).
            self.refreshOrientationLock()
            
            let slideOffset = max(hostingController.view.bounds.height, 120)
            // Smooth ease-in-out slide down just off the edge (no spring kick).
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    hostingController.view.alpha = 0
                    hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)
                }
            ) { _ in
                hostingController.view.transform = self.barBaseTransform
            }
        }
    }
    
    // MARK: - Switcher Bar Actions
    
    /// Home button: minimize all visible windows, or restore last app if all minimized
    @objc public func goHome() {
        DispatchQueue.main.async {
            // Dismiss app switcher if open
            if self.isAppSwitcherOpen { self.dismissAppSwitcher() }
            // And cancel one that has asked for the screen but not yet taken it.
            self.isOpeningAppSwitcher = false
            
            // Check if any windows are visible
            let hasVisibleWindow = self.windowHostingView.subviews.contains { view in
                !view.isHidden && view.alpha > 0.1
            }
            
            if hasVisibleWindow {
                guard self.frontmostAppOrientations == nil else {
                    // A guest pinned to its own orientation cannot be shown in
                    // another one. Its view controllers have been told they support
                    // only the one, so a window turned out from under it is a window
                    // it will not lay out for — handed a portrait drawable it flips
                    // between the two and never settles, which is the judder before
                    // the shrink. So it leaves first, in the orientation it is
                    // pinned to, and the screen turns once its window has gone.
                    self.flyEverythingHome()
                    // Recomputed rather than forced: by now we are on the springboard
                    // and it resolves to portrait, but if the wait expired with a
                    // window still up — or the user opened another app during it —
                    // forcing portrait would turn that app's window out from under it.
                    self.whenWindowsAreAway { self.refreshOrientationLock() }
                    return
                }
                // Upright first, then the flight. The window is aimed at one of the
                // springboard's icons, and where that icon sits is decided by the
                // portrait layout it is the only one to have. Turning underneath the
                // flight instead would resolve the target against a landscape
                // springboard and then take that springboard away mid-air, landing
                // the window nowhere near the icon it was going to.
                self.whenUpright { self.flyEverythingHome() }
            } else {
                // All minimized — bring back last used app, out of its icon in the
                // dock, where it went. Looked up before the home state ends, which
                // takes the dock and what it knows of its icons with it.
                let uuid = self.frontmostAppUUID ?? self.apps.last?.appUUID
                let icon = self.apps.first { $0.appUUID == uuid }?.springboardItemID
                    .flatMap { self.homeDockIconFrames[$0] }
                self.isHomeState = false
                self.showDock()
                if let uuid {
                    let _ = self.bringMultitaskViewToFront(uuid: uuid, fromIcon: icon)
                }
            }
        }
    }
    
    /// Locks the interface to portrait and runs `body` once the window has
    /// actually turned — straight away when it is upright already, or when the
    /// turn is declined (rotation locked at the system level, so it never comes).
    private func whenUpright(_ body: @escaping () -> Void) {
        AppDelegate.orientationLock = .portrait
        guard !displayNeverTurns, AppDelegate.applyOrientationLock(), let window = keyWindow else {
            body()
            return
        }
        whenWindowIsPortrait(window, body)
    }

    /// Runs `body` once no guest window is left on screen, or after a grace period
    /// if one never goes — the caller must run either way.
    ///
    /// Polls the same question `ensureControlAccessible` asks, rather than counting
    /// out the flight's duration, so it is the windows actually being gone that
    /// releases the turn and not an assumption about how long that takes.
    private func whenWindowsAreAway(attempt: Int = 0, _ body: @escaping () -> Void) {
        guard hasForegroundAppWindow(), attempt < 45 else {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.whenWindowsAreAway(attempt: attempt + 1, body)
        }
    }

    /// The home button's second half: every visible window put away into its icon
    /// and the bar taken down. Split out of `goHome` so it can be run after the
    /// window has turned upright rather than beside the turn.
    private func flyEverythingHome() {
        // Whether anything is headed for the dock has to be settled before
        // the home state flips, since that is what puts the dock on screen:
        // decided any later and its entrance has already begun. A window that
        // flies home always goes into its icon there.
        let flying = frontmostVisibleWindow()
        homeDockShouldSkipEntrance = apps.contains { app in
            app.view != nil && app.view === flying && app.springboardItemID != nil
        }

        // Minimize ALL visible windows and hide the dock bar. This is the
        // way home, so a built-in page shrinks into its own icon on the
        // way rather than simply going out.
        minimizeAllWindows(style: .intoIcons)
        updateFrontmostApp()
        isHomeState = true
        hideDock()

        // Every other way the dock appears keeps its entrance.
        guard homeDockShouldSkipEntrance else { return }
        homeDockEntranceSkipToken &+= 1
        let token = homeDockEntranceSkipToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if self.homeDockEntranceSkipToken == token {
                self.homeDockShouldSkipEntrance = false
            }
        }
    }

    /// Find the current frontmost visible app from the view hierarchy
    private func updateFrontmostApp() {
        for view in self.windowHostingView.subviews.reversed() {
            if !view.isHidden && view.alpha > 0.1 {
                if let app = apps.first(where: { $0.view === view }) {
                    frontmostAppUUID = app.appUUID
                    updateDockFrame()
                    return
                }
            }
        }
        frontmostAppUUID = nil
        updateDockFrame()
    }

    /// True when an app or built-in page (Settings / Installer / FlekStore) is
    /// actually on screen in the window host.
    private func hasForegroundAppWindow() -> Bool {
        return self.windowHostingView.subviews.contains { view in
            !view.isHidden && view.alpha > 0.1
        }
    }

    // MARK: - Orientation

    /// Whether a multitask control — the bottom switcher bar OR the floating
    /// nav-assist button — is currently on screen. This is the single flag used
    /// to decide if the device may rotate: when a control is present an app is
    /// on stage and should be rotatable; the bare springboard (no control)
    /// stays portrait-locked.
    ///
    /// Uses the logical visibility flags (not view alpha) so the value is
    /// correct immediately, before show/hide animations settle.
    var isAnyControlVisible: Bool {
        let navShown = navAssistButton != nil || swipeZone != nil
        return isSwitcherBarOnStage || navShown
    }

    /// Whether the three-button switcher bar is the control the dock means to be
    /// showing. The dock's own record of its intent, and the sharper edge of the
    /// two below: the bar counts from the moment it is asked for and stops from the
    /// moment it is dismissed, rather than when either slide finishes.
    ///
    /// This is the reading the rotation lock wants, and it must stay this one.
    /// `hideDock` refreshes that lock before the animation it then starts has taken
    /// the bar's alpha down, so a reading that consulted the view would still find a
    /// bar fully drawn on screen at the exact moment going home is meant to re-lock
    /// to portrait — and the springboard would be left free to turn.
    var isSwitcherBarOnStage: Bool {
        isVisible
            && isSwitcherBarVisible
            && (hostingController?.view.isHidden == false)
    }

    /// Whether the bar is holding the bottom edge — the question the swipe zone
    /// answers to, since the two share that edge and only one of them may own it.
    ///
    /// The same question asked of the view as well, and either one saying the bar is
    /// there settles it. The record can be wrong, and the user is looking at the
    /// bar, not at the record: this is deliberately the pessimistic reading, so that
    /// whichever of the two is stale the swipe stands down rather than opening the
    /// switcher from under a bar that is plainly on screen.
    ///
    /// Alpha is what separates the two during a slide. Both `hideSwitcherBar` and
    /// `hideDock` set it to zero as the animation begins — a model value, so it
    /// reads zero at once — well before `isHidden` is set in the completion, which
    /// is why a bar on its way out does not go on claiming the edge for the length
    /// of its exit.
    var isSwitcherBarHoldingBottomEdge: Bool {
        if isSwitcherBarOnStage { return true }
        guard let barView = hostingController?.view else { return false }
        return barView.window != nil && !barView.isHidden && barView.alpha > 0.1
    }

    /// The orientations a foreground guest has been pinned to in its own settings,
    /// or nil when it is free to turn.
    ///
    /// The per-app lock is enforced inside the guest process, by swizzling
    /// `-[UIViewController __supportedInterfaceOrientations]`, and that stops the
    /// guest turning its *content*. It cannot stop the host window turning
    /// underneath it — and a turned host hands the guest a differently shaped
    /// drawable, which is the whole of how a guest comes to look rotated. So the
    /// window has to be pinned here as well; neither half is sufficient alone.
    ///
    /// Built-in pages are excluded: they are our own SwiftUI and carry no lock.
    private var frontmostAppOrientations: UIInterfaceOrientationMask? {
        // Two side by side: one app's lock would turn the other with it.
        guard !isSplitShowing else { return nil }
        guard let uuid = frontmostAppUUID,
              let app = apps.first(where: { $0.appUUID == uuid }),
              !app.isInternalPage,
              let info = app.appInfo else { return nil }
        switch info.orientationLock {
        // Matching the guest hook, which maps its landscape to a mask covering
        // both directions rather than to the one it names.
        case .Landscape: return .landscape
        case .Portrait: return .portrait
        default: return nil
        }
    }

    /// Drives `AppDelegate.orientationLock` from control visibility:
    /// rotatable (`.allButUpsideDown`) while the switcher bar or floating button
    /// is shown, portrait-locked otherwise. No-op outside virtual-window
    /// multitask mode, where the SwiftUI `OrientationLockModifier` owns
    /// orientation instead.
    @objc public func refreshOrientationLock() {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            // The app switcher overlay is portrait-only. Otherwise: the foreground
            // app's own orientation lock if it has one, free rotation if it does
            // not, portrait-locked on the springboard.
            let openingOrOpen = self.isOpeningAppSwitcher || self.isAppSwitcherOpen
            let lockPortrait = openingOrOpen || !self.isAnyControlVisible
            var mask: UIInterfaceOrientationMask = lockPortrait
                ? .portrait
                : (self.frontmostAppOrientations ?? .allButUpsideDown)
            // A pinned guest holds the window at its own orientation for as long as
            // its window is on screen — including the stretch after the controls
            // have gone, when we are already on the way home and `hideDock` calls
            // this while the flight is still running. Turning there is what makes a
            // locked guest judder; see `goHome`.
            //
            // Only where the window is already in that orientation. This hold exists
            // to stop a turn and must never cause one: leaving the switcher for the
            // springboard, the window is portrait — the switcher put it there — while
            // the guest's own windows are still a dispatch away from being hidden, so
            // an unconditional hold asked for landscape and turned the springboard
            // into it. Which of the two blocks ran first decided whether it happened,
            // which is what made it intermittent.
            let facing = self.keyWindow?.windowScene
                .map { AppDelegate.mask(for: $0.interfaceOrientation) } ?? []
            if lockPortrait, !openingOrOpen, self.hasForegroundAppWindow(),
               let pinned = self.frontmostAppOrientations,
               !facing.isEmpty, pinned.contains(facing) {
                mask = pinned
            }
            AppDelegate.orientationLock = mask

            // Applied rather than only recorded. A window that is already lying
            // sideways has to be asked to turn — the phone has not moved, so nothing
            // else will ask — and this runs for every way back to the springboard,
            // not only the switcher's. See `AppDelegate.applyOrientationLock`.
            AppDelegate.applyOrientationLock()
        }
    }

    /// Invariant guard: whenever an app/page is in the foreground (i.e. we are not on
    /// the springboard), at least one control — the bottom switcher bar OR the floating
    /// nav-assist button — must be reachable so the user can always minimize or exit.
    /// If a state desync ever leaves both hidden, this restores the switcher bar.
    @objc public func ensureControlAccessible() {
        ensureControlAccessible(retriesLeft: 8)
    }

    /// Guarantees a multitask control (switcher bar or floating button) is on screen
    /// whenever an app is foregrounded. This self-heals two launch/relaunch races
    /// that could otherwise leave neither control visible:
    ///  1. The app's view is in the hierarchy a beat before it becomes visible, so
    ///     `hasForegroundAppWindow()` can momentarily be false; if we still expect an
    ///     app (the list is non-empty) we retry shortly instead of giving up.
    ///  2. When neither control is up we show the one the user *prefers* (the old
    ///     code always brought back the bar, ignoring floating-button mode, and
    ///     `applyPreferredControl` only switches between controls — it does nothing
    ///     when neither is present).
    private func ensureControlAccessible(retriesLeft: Int) {
        DispatchQueue.main.async {
            guard self.isDockEnabled() else { return }
            // Reconcile rotation with current control visibility every time we
            // re-check (e.g. on foreground), self-healing against any stale lock.
            self.refreshOrientationLock()
            // Springboard has its own UI (the app list); no floating control is needed.
            guard !self.isHomeState else { return }
            // The app-switcher overlay already provides controls while it is open.
            guard !self.isAppSwitcherOpen else { return }

            // A control is only needed when an app window is actually on screen.
            // During launch/relaunch the app view can lag its own appearance, so if
            // we expect an app but its window isn't ready yet, retry shortly rather
            // than leaving the user with no bar and no button.
            guard self.hasForegroundAppWindow() else {
                if !self.apps.isEmpty && retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.ensureControlAccessible(retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }

            // In a window, and not merely unhidden. The bar's container is parented
            // by `showDock` and by nothing else, so a bar whose flags and alpha both
            // say "shown" can still be in no window at all — and this guard, the
            // last thing between the user and an app with no way out, would take
            // the flags' word for it and stand down.
            let barInWindow = self.hostingController?.view.window != nil
            let barShown = self.isVisible
                && self.isSwitcherBarVisible
                && (self.hostingController?.view.isHidden == false)
                && ((self.hostingController?.view.alpha ?? 0) > 0.1)
                && barInWindow
            let navShown = self.navAssistButton?.window != nil || self.swipeZone?.window != nil

            guard !barShown && !navShown else { return }

            // Neither control is reachable — show the one the user prefers, or
            // the floating button while the side column has no room.
            if self.usesFloatingButton {
                guard let keyWindow = self.keyWindow else { return }
                self.isVisible = true
                self.isSwitcherBarVisible = false
                self.hostingController?.view.isHidden = true
                self.hostingController?.view.alpha = 0
                self.showNavAssist(in: keyWindow)
            } else if self.isVisible, barInWindow {
                self.showSwitcherBar(choosingBar: false)
            } else {
                // Off screen for want of a host, not merely slid away — and
                // `showSwitcherBar` animates the bar where it stands. Only the way
                // it first arrives puts it somewhere.
                self.isVisible = false
                self.showDock()
            }
        }
    }
    
    /// Hide the switcher bar with slide-down animation and show navigation assist
    @objc public func hideSwitcherBar() {
        hideSwitcherBar(choosingFloatingButton: true)
    }

    /// - Parameter choosingFloatingButton: whether this is the floating button
    ///   being chosen, as the bar's own button chooses it, rather than the side
    ///   column stepping aside for an app's side bar, which chooses nothing.
    private func hideSwitcherBar(choosingFloatingButton: Bool) {
        hideSplitHelp()
        guard let hostingController = hostingController, let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            guard self.isSwitcherBarVisible else { return }
            self.isSwitcherBarVisible = false
            // Taking the bar down is choosing the floating button, and the choice has
            // to outlive the controls: anything that puts them away — going home, an
            // app closing — brings back whichever one this names.
            if choosingFloatingButton { self.setPrefersFloatingButton(true) }
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            // Bring the floating button in immediately, concurrent with the bar
            // sliding out, instead of waiting for the slide to finish. The button
            // sits mid-right and the bar at the bottom, so they never overlap.
            // Put away from the side column by hand, it starts tucked into that
            // side instead, where the hide button just pressed was. Read before
            // the column starts to leave.
            var stashPoint: CGPoint?
            if choosingFloatingButton, self.placedSideColumnEdge != nil, let column = hostingController.view {
                stashPoint = column.convert(CGPoint(x: column.bounds.midX, y: FlekTheme.sideBarButtonSize / 2),
                                            to: keyWindow)
            }
            let showsFloatingButton = !self.isHomeState && self.hasForegroundAppWindow()
            if showsFloatingButton {
                self.showNavAssist(in: keyWindow, stashedAt: stashPoint)
            }

            // Remove the bar reservation from internal pages so they stretch full
            for (_, controller) in self.internalPageControllers {
                UIView.animate(withDuration: Constants.longAnimationDuration, delay: 0, options: .allowUserInteraction) {
                    self.applyBarInset(to: controller, reserved: false)
                }
            }

            // Smooth ease-in-out slide fully off the bottom edge (no spring kick),
            // keeping the bar opaque for most of the travel so it reads as a clean
            // slide-down rather than a quick fade.
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    hostingController.view.transform = self.barHiddenTransform(offset: 160)
                    hostingController.view.alpha = 0
                }
            ) { _ in
                hostingController.view.isHidden = true
                hostingController.view.transform = self.barBaseTransform
                // showNavAssist already refreshes the orientation lock when it
                // runs, so only do it here for the no-button (home) case.
                if !showsFloatingButton {
                    self.refreshOrientationLock()
                }
                // Safety net: guarantee a control is on screen. If an app is
                // foreground but its window read as not-ready when we tried to show
                // the floating button above, this re-checks (and retries) so hiding
                // the bar can never leave the user with neither control.
                self.ensureControlAccessible()
            }
        }
    }

    /// Show the switcher bar with slide-up animation and hide navigation assist
    @objc public func showSwitcherBar() {
        showSwitcherBar(choosingBar: true)
    }

    /// - Parameter choosingBar: whether this is the bar being chosen, rather than
    ///   the side column coming back over an app that has room for it again.
    private func showSwitcherBar(choosingBar: Bool) {
        guard let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            // Hide nav assist and reset stash state
            self.isNavAssistStashed = false
            self.navAssistChevron = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: .allowUserInteraction, animations: {
                self.navAssistButton?.alpha = 0
                self.navAssistButton?.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                self.swipeZone?.alpha = 0
            }) { _ in
                self.navAssistButton?.removeFromSuperview()
                self.navAssistButton = nil
                self.tearDownSwipeZone()
            }
            
            self.isSwitcherBarVisible = true
            // The other half of the same choice — see `hideSwitcherBar`.
            if choosingBar { self.setPrefersFloatingButton(false) }
            self.refreshOrientationLock()
            self.updateDockFrame(animated: false)
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            // Restore the bar reservation on internal pages
            for (_, controller) in self.internalPageControllers {
                UIView.animate(withDuration: Constants.standardAnimationDuration, delay: 0, options: .allowUserInteraction) {
                    self.applyBarInset(to: controller, reserved: true)
                }
            }
            
            hostingController.view.isHidden = false
            hostingController.view.alpha = 0
            let slideOffset = max(hostingController.view.bounds.height, 120)
            hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)

            // Smooth ease-in-out slide up (no spring kick), after nav assist hides.
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0.15,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    hostingController.view.alpha = 1
                    hostingController.view.transform = self.barBaseTransform
                }
            )
        }
    }
    
    // MARK: - Multitask swipe zone

    /// Whether the bottom swipe is the chosen control rather than the floating button.
    ///
    /// Read with a default, as `bool(forKey:)` reads a missing key as false: the
    /// swipe, except on an iPhone Duo, which starts with the floating button
    /// (`FlekDeviceModel.usesBottomSwipeByDefault`, which the picker in
    /// `LCSettingsView` takes its default from too).
    private var isSwipeZoneEnabled: Bool {
        LCUtils.appGroupUserDefault.object(forKey: "LCMultitaskHomeBar") as? Bool
            ?? FlekDeviceModel.usesBottomSwipeByDefault
    }

    /// Put the swipe zone up along the bottom edge of `host`.
    ///
    /// Idempotent: any existing zone is taken down first, so this can run on every
    /// `showNavAssist` — which is itself called repeatedly by the control self-heal —
    /// without stacking zones on top of each other.
    private func installSwipeZone(in host: UIView, animated: Bool) {
        tearDownSwipeZone()
        guard isSwipeZoneEnabled else { return }
        // The bar and the swipe are two ways to the one switcher, and the swipe is
        // what stands in for the bar while the bar is down. Never both: they share
        // the bottom edge, so a zone up over the bar would open the switcher from
        // underneath its own buttons — and eat the touches meant for them on the way.
        guard !isSwitcherBarHoldingBottomEdge else { return }
        let bar = MultitaskSwipeZone()
        // Answered live, so a zone that somehow outlasts the bar's return is inert
        // from the moment the bar is back rather than until something takes it down.
        // Inert with no manager to ask, too: nothing can be opened without one.
        bar.isInert = { [weak self] in self?.isSwitcherBarHoldingBottomEdge ?? true }
        bar.onActivate = { [weak self] in
            guard let self else { return }
            // Asked again at the moment of the swipe, not only at install time. Every
            // path that brings the bar back takes the zone down with it, but they are
            // several and some of them finish in an animation's completion; this is
            // the one place the rule cannot be got round, and a refused swipe is
            // silent — the haptic below is the only acknowledgement the gesture has,
            // so it belongs to a swipe that is actually going to do something.
            guard !self.isSwitcherBarHoldingBottomEdge else { return }
            // Nothing is drawn in the zone, so this tap is all the gesture gets —
            // but it answers to the same setting as the buttons.
            MultitaskDockManager.buttonHaptic()
            self.showAppSwitcher()
        }
        host.addSubview(bar)
        swipeZone = bar
        placeSwipeZone(in: host.bounds)

        guard animated else { return }
        bar.alpha = 0
        UIView.animate(withDuration: Constants.standardAnimationDuration,
                       delay: 0.03,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            bar.alpha = 1
        }
    }

    private func tearDownSwipeZone() {
        swipeZone?.removeFromSuperview()
        swipeZone = nil
    }


    /// Centres the bar along the bottom of `bounds`, clear of the safe-area inset
    /// rather than inside it — the whole point of the shape this control ended up in.
    ///
    /// `bounds` is passed in during a rotation, where it describes the size being
    /// turned into and the host has not resized yet. The host's own layout pass
    /// repeats the call afterwards with the real geometry, which is also what
    /// resolves a safe area that was still zero on a cold start.
    private func placeSwipeZone(in bounds: CGRect? = nil) {
        guard let bar = swipeZone, let host = bar.superview else { return }
        let area = bounds ?? host.bounds
        guard area.width > 0, area.height > 0 else { return }
        let inset = max(host.safeAreaInsets.bottom, safeAreaInsets.bottom)
        let screen = (host.window?.windowScene?.screen ?? FlekTheme.screen).bounds
        let size = MultitaskSwipeZone.preferredSize(forShortSide: min(screen.width, screen.height))
        // Down from the top of the safe-area band by `bandIntrusion`, which is as far
        // towards the real indicator as the touches still arrive over a guest.
        // Never further down than the band is deep: on a device with no bottom inset
        // an unclamped intrusion would carry the target clean off the screen.
        let intrusion = min(MultitaskSwipeZone.bandIntrusion, inset)
        bar.frame = CGRect(x: ((area.width - size.width) / 2).rounded(),
                           y: area.height - inset + intrusion - size.height,
                           width: size.width,
                           height: size.height)
    }

    // MARK: - Navigation Assist Button
    
    /// - Parameter stashPoint: where, in `window`, the button that put the side
    ///   column away was: the floating button then starts tucked into the side the
    ///   column stood against, level with it. Nil for every other way it appears.
    private func showNavAssist(in window: UIWindow, animated: Bool = true, stashedAt stashPoint: CGPoint? = nil) {
        // Remove any existing nav assist button to prevent duplicates
        navAssistButton?.removeFromSuperview()
        navAssistButton = nil

        isNavAssistStashed = false
        navAssistChevron = nil

        // The overlay window, alongside the bar and for the same reason: when this
        // control is the one on screen it is the only way out of the app, so a sheet
        // presented over it must not be able to take it away.
        let host = self.overlayHostView() ?? window

        // The swipe zone replaces the floating button rather than accompanying it —
        // they are two ways to reach the same switcher, and the setting picks one.
        guard !self.isSwipeZoneEnabled else {
            self.installSwipeZone(in: host, animated: animated)
            self.refreshOrientationLock()
            return
        }
        self.tearDownSwipeZone()

        let button = createNavAssistButton()
        host.addSubview(button)
        self.navAssistButton = button
        // A fresh button starts halfway down the right of the user's view, whichever
        // layout edge that currently is — unless it is taking the place of a side
        // column just put away, when it starts tucked into the column's side where
        // the column's hide button was, as if that button had gone into the edge.
        let stashedEdge = stashPoint == nil ? nil : placedSideColumnEdge
        if let stashPoint, let stashedEdge {
            let point = host.convert(stashPoint, from: window)
            let range = navAssistAlongRange(for: stashedEdge, in: host.bounds, insets: host.safeAreaInsets)
            let along = stashedEdge == .left || stashedEdge == .right ? point.y : point.x
            self.rememberScreenPlacement(edge: stashedEdge, fraction: navAssistFraction(of: along, in: range))
            self.navAssistFollowsSideBar = false
        } else {
            // Above the app's tabs instead, where an iPhone Duo stands them down
            // the right and halfway down would be over them.
            self.placeNavAssistClearOfSideBar(in: host)
            self.navAssistFollowsSideBar = true
        }
        // Placed only now that it has a host: its position is measured in that
        // host's space, and the host is not necessarily `window`.
        self.placeNavAssist(button, stashed: stashedEdge != nil, animated: false)
        // Floating button now on stage → allow rotation.
        self.refreshOrientationLock()

        // As placing it left it: opaque, or see-through when tucked away.
        let restingAlpha = button.alpha
        guard animated else {
            // Instant placement (e.g. when revealing behind the switcher overlay
            // as it fades) so the button is already in its final state.
            button.alpha = restingAlpha
            button.transform = .identity
            return
        }

        button.alpha = 0
        // Tucked away it only fades in, half off the screen as it already is.
        button.transform = stashedEdge == nil ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0.03,
            usingSpringWithDamping: Constants.showHideSpringDamping,
            initialSpringVelocity: 0,
            // Tappable as it arrives, rather than only once it has settled.
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            button.alpha = restingAlpha
            button.transform = .identity
        }
    }
    
    private func createNavAssistButton() -> UIView {
        let size = navAssistSize
        let button = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        
        let blurEffect = UIBlurEffect(style: .systemMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = button.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = size / 2
        blurView.clipsToBounds = true
        button.addSubview(blurView)
        
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let iconImage = UIImage(systemName: FlekSymbol.appSwitcher, withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iconView.tag = 100 // Tag for reliable lookup
        // Upright from the start: the button can be created while the phone is
        // already held sideways.
        iconView.transform = navAssistIconTransform
        button.addSubview(iconView)
        
        button.layer.cornerRadius = size / 2
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(navAssistTapped))
        button.addGestureRecognizer(tapGesture)
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(navAssistDragged(_:)))
        button.addGestureRecognizer(panGesture)

        // Held, then dragged: the app in use lifts off the screen, as from the
        // bar's app button. Only where two apps can be put side by side, so
        // anywhere else a hold and a drag still moves the button.
        let liftPress = UILongPressGestureRecognizer(target: self, action: #selector(navAssistLiftPressed(_:)))
        liftPress.minimumPressDuration = 0.3
        liftPress.allowableMovement = 12
        liftPress.delegate = self
        button.addGestureRecognizer(liftPress)

        return button
    }

    /// The floating button held, then dragged: the same lift as the bar's app
    /// button (`SplitLiftGesture`).
    @objc private func navAssistLiftPressed(_ gesture: UILongPressGestureRecognizer) {
        let point = navAssistLiftPoint(gesture)
        switch gesture.state {
        case .began:
            // Nothing to lift after all: the press is called off (its cancel
            // disarms), which puts it out of the way of the button's own drag.
            guard splitLiftArm(), splitLiftBegan(at: point, keepingGrabPoint: true) else {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
        case .changed:
            splitLiftMoved(to: point)
        case .ended:
            guard splitLift != nil else { return }
            splitLiftEnded(at: point)
        case .cancelled, .failed:
            splitLiftCancelled()
        default:
            break
        }
    }

    /// The finger where the lift measures everything, in the floating button's own
    /// host: the overlay's root view, which fills the screen in the interface's
    /// orientation, as the windows' host does, and is the space the button is
    /// placed and dragged in. Not the overlay window's base coordinates (a nil
    /// view): on the iPhone Duo's inner display, mounted on its side, those came
    /// out a quarter turned from the interface, which swapped the lift's x and y.
    private func navAssistLiftPoint(_ gesture: UIGestureRecognizer) -> CGPoint {
        gesture.location(in: gesture.view?.superview ?? windowHostingView)
    }

    
    @objc private func navAssistTapped() {
        // The same feedback, at the same strength, as the bar's buttons: this is
        // the other control the user picked between, not a different one.
        MultitaskDockManager.buttonHaptic()

        if isNavAssistStashed {
            // Docked at an edge: first tap brings the button back out.
            unstashNavAssist()
        } else {
            // Open the multitask switcher directly instead of showing the bar.
            showAppSwitcher()
        }
    }
    
    @objc private func navAssistDragged(_ gesture: UIPanGestureRecognizer) {
        guard let button = navAssistButton else { return }
        let translation = gesture.translation(in: button.superview)
        
        switch gesture.state {
        case .changed:
            button.center = CGPoint(
                x: button.center.x + translation.x,
                y: button.center.y + translation.y
            )
            gesture.setTranslation(.zero, in: button.superview)
            
        case .ended, .cancelled, .failed:
            snapNavAssistToEdge(button, animated: true)
            
        default:
            break
        }
    }
    
    private func snapNavAssistToEdge(_ button: UIView, animated: Bool) {
        guard let screenBounds = navAssistHostBounds(for: button) else { return }
        let margin = Constants.navAssistMargin
        let halfSize = navAssistSize / 2
        let stashThreshold: CGFloat = halfSize + margin // How close to edge before stashing

        // Every edge is dockable in either orientation. The edge is remembered and
        // carried through rotation, so restricting the set per orientation would
        // mean a button parked on one could not stay there once the device turned.
        let allowedEdges: [ScreenEdge] = [.left, .right, .top, .bottom]

        // Distance from the button center to a given screen edge.
        func distance(to edge: ScreenEdge) -> CGFloat {
            switch edge {
            case .left:   return button.center.x
            case .right:  return screenBounds.width - button.center.x
            case .top:    return button.center.y
            case .bottom: return screenBounds.height - button.center.y
            }
        }

        // Snap to whichever allowed edge is nearest, and remember where along it the
        // drag left the button so a rotation can reproduce the same spot.
        let edge = allowedEdges.min(by: { distance(to: $0) < distance(to: $1) })!
        let range = navAssistAlongRange(for: edge, in: screenBounds, insets: navAssistHostInsets(for: button))
        let along: CGFloat
        switch edge {
        case .left, .right:  along = button.center.y
        case .top, .bottom:  along = button.center.x
        }

        rememberScreenPlacement(edge: edge, fraction: navAssistFraction(of: along, in: range))
        navAssistFollowsSideBar = false
        placeNavAssist(button, in: screenBounds, stashed: distance(to: edge) < stashThreshold, animated: animated)
    }

    // MARK: - Viewer Frame

    /// The four sides in clockwise order, the order a quarter-turn steps through.
    private static let edgesClockwise: [ScreenEdge] = [.top, .right, .bottom, .left]

    /// Quarter-turns the interface has been turned against the phone's own frame.
    /// `.landscapeLeft` is the phone held turned clockwise (home button on the
    /// left — the enum names are inverted against `UIDeviceOrientation`, see
    /// UIOrientation.h), which puts the phone's top side at the picture's right:
    /// one step.
    ///
    /// Against the phone, not the display: a display mounted on its side in the
    /// phone — the iPhone Duo's inner one — has its interface turned that much
    /// already when it is the right way up to the user, and without taking that
    /// off, opening the phone read as a quarter-turn of the phone that never
    /// happened. The floating button went over to the bottom edge, its symbol
    /// lying on its side.
    private var interfaceRotationSteps: Int {
        let scene = navAssistButton?.window?.windowScene ?? keyWindow?.windowScene
        let steps: Int
        switch scene?.interfaceOrientation {
        case .landscapeLeft:      steps = 1
        case .portraitUpsideDown: steps = 2
        case .landscapeRight:     steps = 3
        default:                  steps = 0
        }
        let mounting = scene.map { FlekDeviceModel.displayMountingSteps(of: $0.screen) } ?? 0
        return (steps - mounting + 4) % 4
    }

    /// Quarter-turns the phone itself is being held at, from the same zero.
    /// `UIDeviceOrientation.landscapeRight` is home button on the left, i.e. the
    /// phone turned clockwise — the mirror of the interface naming above.
    ///
    /// Falls back to the interface's own turn when the device won't say (flat on a
    /// table, or orientation notifications not running), which makes the two cancel
    /// out and leaves the button on the layout edge it is already on.
    private func deviceRotationSteps() -> Int {
        switch UIDevice.current.orientation {
        case .portrait:           lastKnownDeviceSteps = 0
        case .landscapeRight:     lastKnownDeviceSteps = 1
        case .portraitUpsideDown: lastKnownDeviceSteps = 2
        case .landscapeLeft:      lastKnownDeviceSteps = 3
        default: break
        }
        return lastKnownDeviceSteps ?? interfaceRotationSteps
    }

    /// Quarter-turns from the layout's frame to the viewer's — how far what the user
    /// sees has turned relative to the coordinates the button is positioned in.
    ///
    /// Zero whenever the interface rotates with the phone, because then they are the
    /// same frame. Non-zero exactly when the interface has stayed where it was while
    /// the phone turned, which is the case that has to move the button to a
    /// different layout edge to leave it on the same side of the user's view.
    private var viewerRotationSteps: Int {
        ((deviceRotationSteps() - interfaceRotationSteps) % 4 + 4) % 4
    }

    /// The turn that keeps the button's symbol upright to the user: the inverse of
    /// however far the layout is turned away from the viewer's frame. Identity
    /// whenever the interface rotates with the phone — there the layout is already
    /// the right way up — and a quarter-turn back when it is not, where a glyph
    /// drawn upright in layout coordinates would otherwise read as lying on its
    /// side. Quarter-turns only, so the square symbol never clips.
    private var navAssistIconTransform: CGAffineTransform {
        let steps = viewerRotationSteps
        guard steps != 0 else { return .identity }
        return CGAffineTransform(rotationAngle: -CGFloat(steps) * .pi / 2)
    }

    private func rotateEdge(_ edge: ScreenEdge, by steps: Int) -> ScreenEdge {
        let edges = Self.edgesClockwise
        guard let index = edges.firstIndex(of: edge) else { return edge }
        return edges[(index + steps % 4 + 4) % 4]
    }

    /// Whether the along-edge direction reverses when the layout is turned `steps`
    /// quarter-turns into the viewer's frame. A quarter-turn keeps one pair of sides
    /// running the same way and reverses the other; a half-turn reverses both.
    /// Named for the edge as it is in the layout, so the same answer serves both
    /// directions of the conversion.
    private func fractionFlips(layoutEdge: ScreenEdge, steps: Int) -> Bool {
        switch ((steps % 4) + 4) % 4 {
        case 1:  return layoutEdge == .left || layoutEdge == .right
        case 2:  return true
        case 3:  return layoutEdge == .top || layoutEdge == .bottom
        default: return false
        }
    }

    /// The stored viewer-frame position resolved into the layout edge that is
    /// currently on that side of the user's view, and the offset to draw it at.
    private func currentScreenPlacement() -> (edge: ScreenEdge, fraction: CGFloat) {
        let steps = viewerRotationSteps
        let edge = rotateEdge(navAssistViewEdge, by: -steps)
        let flips = fractionFlips(layoutEdge: edge, steps: steps)
        return (edge, flips ? 1 - navAssistAlongFraction : navAssistAlongFraction)
    }

    /// Records where a drag left the button — a layout edge and offset — as the side
    /// of the user's view it landed on, so a later turn of the phone can put it back
    /// on that same side rather than that same layout edge.
    private func rememberScreenPlacement(edge: ScreenEdge, fraction: CGFloat) {
        let steps = viewerRotationSteps
        navAssistViewEdge = rotateEdge(edge, by: steps)
        navAssistAlongFraction = fractionFlips(layoutEdge: edge, steps: steps)
            ? 1 - fraction
            : fraction
    }

    /// The space the button's center is expressed in: its own superview — the
    /// overlay window's root view — not `keyWindow`. The two are different windows,
    /// and measuring a position for one against the other is what puts the button
    /// somewhere the user cannot see it. `keyWindow` is only the fallback for a
    /// button that has not been added to a host yet.
    private func navAssistHostBounds(for button: UIView) -> CGRect? {
        guard let bounds = button.superview?.bounds ?? keyWindow?.bounds,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Safe-area insets of that same host, for the same reason.
    private func navAssistHostInsets(for button: UIView) -> UIEdgeInsets {
        button.superview?.safeAreaInsets ?? safeAreaInsets
    }

    /// The span the button's center may travel along `edge` — the free axis (Y for
    /// the side edges, X for the top and bottom), inset by the safe area and the
    /// margin at both ends.
    private func navAssistAlongRange(for edge: ScreenEdge, in screenBounds: CGRect, insets safeArea: UIEdgeInsets) -> ClosedRange<CGFloat> {
        let margin = Constants.navAssistMargin
        let halfSize = navAssistSize / 2
        let lower: CGFloat
        let upper: CGFloat
        switch edge {
        case .left, .right:
            lower = safeArea.top + margin + halfSize
            upper = screenBounds.height - safeArea.bottom - margin - halfSize
        case .top, .bottom:
            lower = safeArea.left + margin + halfSize
            upper = screenBounds.width - safeArea.right - margin - halfSize
        }
        return lower...max(lower, upper)
    }

    /// Where `along` sits within `range`, as 0...1. A degenerate range (a window too
    /// small for the button to travel at all) reads as the middle.
    private func navAssistFraction(of along: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((along - range.lowerBound) / span, 0), 1)
    }

    /// Puts the button back on the side of the phone it is parked on, at the offset
    /// along that side it is parked at, docked or stashed. Everything is derived
    /// from the stored device-frame position and the bounds passed in — never from
    /// the button's current center — which is what makes this safe to re-run after a
    /// rotation has left that center describing the old geometry.
    private func placeNavAssist(_ button: UIView, in bounds: CGRect? = nil, stashed: Bool, animated: Bool) {
        guard let screenBounds = bounds ?? navAssistHostBounds(for: button),
              screenBounds.width > 0, screenBounds.height > 0 else { return }
        let margin = Constants.navAssistMargin
        let halfSize = navAssistSize / 2
        // The physical side the button is parked on, read as the screen edge it
        // shows up as in the orientation the interface is in right now.
        let placement = currentScreenPlacement()
        let range = navAssistAlongRange(for: placement.edge, in: screenBounds, insets: navAssistHostInsets(for: button))
        let along = range.lowerBound + (range.upperBound - range.lowerBound) * placement.fraction

        if stashed {
            stashNavAssist(button, in: screenBounds, edge: placement.edge, along: along, animated: animated)
            return
        }

        // Resting position when docked to an edge ignores that edge's safe-area
        // inset so the button can sit right against the physical edge (the notch
        // inset on the sides, and the home-indicator inset at the bottom, would
        // otherwise push it far inward in landscape). Except on the side an iPhone
        // Duo's side column stands on: there it sits on the column's own line, as
        // far in as the column's buttons and the app's side bar are centred.
        let columnEdge = Self.sideColumnEdge(for: keyWindow?.traitCollection)
        let edgeMinX = columnEdge == .left ? FlekTheme.sideBarCentreInset : margin + halfSize
        let edgeMaxX = screenBounds.width
            - (columnEdge == .right ? FlekTheme.sideBarCentreInset : margin + halfSize)
        let edgeMinY = margin + halfSize
        let edgeMaxY = screenBounds.height - margin - halfSize

        let target: CGPoint
        switch placement.edge {
        case .left:   target = CGPoint(x: edgeMinX, y: along)
        case .right:  target = CGPoint(x: edgeMaxX, y: along)
        case .top:    target = CGPoint(x: along, y: edgeMinY)
        case .bottom: target = CGPoint(x: along, y: edgeMaxY)
        }
        restoreNavAssistIcon(button)
        moveNavAssist(button, to: clampNavAssistCenter(target, in: screenBounds), alpha: 1.0, animated: animated)
    }

    /// Keeps a center inside the host, which keeps at least half the button on
    /// screen on each axis — the same half a stash deliberately leaves showing.
    /// A backstop: if the remembered fraction is ever applied against geometry it
    /// wasn't measured in, the button comes out at the wrong spot rather than at no
    /// spot at all.
    private func clampNavAssistCenter(_ center: CGPoint, in screenBounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(center.x, 0), screenBounds.width),
                y: min(max(center.y, 0), screenBounds.height))
    }

    /// Clears the stashed chevron and restores the normal iphone.app.switcher icon.
    private func restoreNavAssistIcon(_ button: UIView) {
        isNavAssistStashed = false
        navAssistChevron?.removeFromSuperview()
        navAssistChevron = nil
        button.viewWithTag(100)?.isHidden = false
    }

    /// Animates (or snaps) the floating button to a center point.
    ///
    /// Also the one place the symbol's counter-turn is applied, because every
    /// placement — docked, stashed, dragged, re-placed on a turn of the phone —
    /// comes through here, so the glyph can never be left lying on its side.
    /// The chevron is deliberately left alone: it points into the screen, and
    /// which way that is survives the turn on its own.
    private func moveNavAssist(_ button: UIView, to center: CGPoint, alpha: CGFloat, animated: Bool) {
        let icon = button.viewWithTag(100)
        let iconTransform = navAssistIconTransform
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                // Still a button while it is settling against the edge it was
                // thrown at, not a picture of one.
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                button.center = center
                button.alpha = alpha
                icon?.transform = iconTransform
            }
        } else {
            button.center = center
            button.alpha = alpha
            icon?.transform = iconTransform
        }
    }
    
    private func stashNavAssist(_ button: UIView, in screenBounds: CGRect, edge: ScreenEdge, along: CGFloat, animated: Bool) {
        let size = navAssistSize
        // Show half the button off the edge; the chevron is positioned in the
        // visible half (below) so it stays fully on-screen.
        let visibleAmount: CGFloat = size * 0.50

        // Center for the half-off-screen stashed position, and the chevron that
        // points back toward the screen interior. `along` is the free-axis
        // coordinate (Y for left/right edges, X for top/bottom edges).
        let newCenter: CGPoint
        let chevronName: String
        switch edge {
        case .right:
            newCenter = CGPoint(x: screenBounds.width - visibleAmount + size / 2, y: along)
            chevronName = "chevron.left"
        case .left:
            newCenter = CGPoint(x: visibleAmount - size / 2, y: along)
            chevronName = "chevron.right"
        case .bottom:
            newCenter = CGPoint(x: along, y: screenBounds.height - visibleAmount + size / 2)
            chevronName = "chevron.up"
        case .top:
            newCenter = CGPoint(x: along, y: visibleAmount - size / 2)
            chevronName = "chevron.down"
        }

        isNavAssistStashed = true

        // Add or update chevron indicator, positioned in the visible half of the
        // button (the half facing the screen interior) so the edge can't clip it.
        let config = UIImage.SymbolConfiguration(pointSize: 16.8, weight: .bold)  // 20% larger than the base 14
        let chevronImage = UIImage(systemName: chevronName, withConfiguration: config)

        // Center the chevron on the centroid of the visible half-disk — the true
        // middle of the not-hidden part of the round button — rather than the
        // rectangular midpoint of the half, which reads as off toward the interior.
        let mid = size / 2
        let centroidOffset = 2 * size / (3 * CGFloat.pi)  // half-disk centroid from the flat (edge) side
        let chevronCenter: CGPoint
        switch edge {
        case .right:  chevronCenter = CGPoint(x: mid - centroidOffset, y: mid)
        case .left:   chevronCenter = CGPoint(x: mid + centroidOffset, y: mid)
        case .bottom: chevronCenter = CGPoint(x: mid, y: mid - centroidOffset)
        case .top:    chevronCenter = CGPoint(x: mid, y: mid + centroidOffset)
        }

        let chevronView: UIImageView
        if let existing = navAssistChevron {
            existing.image = chevronImage
            chevronView = existing
        } else {
            let v = UIImageView(image: chevronImage)
            v.tintColor = .white
            v.contentMode = .center
            button.viewWithTag(100)?.isHidden = true
            button.addSubview(v)
            navAssistChevron = v
            chevronView = v
        }
        chevronView.sizeToFit()
        chevronView.center = chevronCenter

        // See-through while stashed (down from the default), but the frosted
        // background stays so the chevron keeps contrast against app content.
        moveNavAssist(button, to: clampNavAssistCenter(newCenter, in: screenBounds), alpha: 0.55, animated: animated)
    }
    
    private func unstashNavAssist() {
        guard let button = navAssistButton else { return }
        // Slides back in from whichever edge it was stashed against, to the same
        // resting place a drag to that edge would have left it in.
        placeNavAssist(button, stashed: false, animated: true)
    }
    
    // Find and bring corresponding multitask view to front
    /// `fromRect` is the thing on screen the window should come out of, in window
    /// coordinates — a switcher card, which is already showing the app at a known
    /// size and place — and `fromRectRadius` its corner radius on screen, which the
    /// window starts out with. `fromIcon` is an icon it grows out of instead,
    /// fading in over it: the home dock's, when that is what was pressed, rather
    /// than the app's springboard icon that would otherwise be looked up. `from` is
    /// the weaker form for a caller that knows only where a finger landed.
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil,
                                   fromRect: CGRect? = nil, fromRectRadius: CGFloat? = nil,
                                   fromIcon: CGRect? = nil) -> Bool {
        // Use the same foreground-active resolution as `keyWindow` rather than the
        // unordered `connectedScenes.first`, so a restored/background scene from a
        // previous launch can't be searched instead of the live one.
        guard let windowScene = keyWindow?.windowScene else {
            return false
        }

        // Capture snapshot of the current frontmost app before switching away from it
        if let currentFrontmost = self.frontmostAppUUID, currentFrontmost != uuid {
            captureSnapshot(for: currentFrontmost)
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                // A third app coming forward ends two side by side; either of the
                // two is only the other one being used. Decided here, once there is
                // a window to come forward: every launch first asks this whether its
                // app has one, and an app chosen for a side, asking that before it
                // has started, ended the split it was chosen for and opened full
                // screen.
                if let pair = splitPair, !pair.contains(uuid) { endSplit() }
                // One of two kept from going home: both come back as they were.
                if let kept = splitSuspended, kept.contains(uuid) {
                    // Only the home dock's icons pass themselves as `fromIcon`.
                    restoreSuspendedSplit(kept, bringingForward: uuid,
                                          fromDock: fromIcon != nil,
                                          fromCard: fromRect != nil, cardRadius: fromRectRadius)
                }
                // Paired with another app: framed for its side before it comes
                // forward, and the other opened beside it once it has.
                let openPartner = splitPartnerOpener(for: uuid)
                passURLSchemeToView(targetView)
                // The window being left behind takes its modals with it. Windows here
                // are always maximized, so a sheet belonging to one of them would
                // otherwise be left sitting over the window arriving in its place —
                // the switcher's path to another app never minimizes the old one.
                for other in self.apps where other.appUUID != uuid
                    && self.splitPair?.contains(other.appUUID) != true {
                    self.dismissPresentation(forAppUUID: other.appUUID)
                }
                let source = fromRect ?? fromIcon
                    ?? center.map(LCMinimizeToIconAnimator.sourceRect(around:))
                // A card is already showing this app, so the window grows out of it
                // opaque. Everywhere else it comes out of an icon, which it has to
                // fade in over.
                animateViewAppearance(targetView, from: source,
                                      sourceRadius: fromRect == nil ? nil : fromRectRadius,
                                      fadesIn: fromRect == nil, in: window)
                windowTookStage(uuid: uuid)
                openPartner?()
                return true
            }
        }
        
        return false
    }

    /// Everything the dock has to know once a window is in front, whichever way it
    /// got there — out of a switcher card or a dock icon, at launch, or back from
    /// the system's PiP window. The entrance is each caller's own; this is the
    /// record of it.
    ///
    /// Leaving home state is what brings the bar in, alongside the window. From
    /// anywhere else the bar is already up and only re-measures itself against
    /// the app now in front.
    private func windowTookStage(uuid: String) {
        if let pair = splitPair, !pair.contains(uuid) { endSplit() }
        // One of two kept from going home, come forward some way that brings
        // only it, a swipe along the bar: it is an app of its own again.
        if splitSuspended?.contains(uuid) == true { dissolveSuspendedSplit(except: uuid) }
        let wasHomeState = isHomeState
        isHomeState = false
        frontmostAppUUID = uuid
        if apps.first(where: { $0.appUUID == uuid })?.isInternalPage == true { springboardMayHaveChanged() }
        // However it got here, a run of swipes along the bar is over. A swipe
        // that landed here starts its run again once this is done.
        quickSwitch.isLive = false
        // Move app to end so it's most recent (for home screen icon ordering)
        if let idx = apps.firstIndex(where: { $0.appUUID == uuid }) {
            let app = apps.remove(at: idx)
            apps.append(app)
        }
        if wasHomeState {
            showDock()
        } else {
            updateDockFrame()
        }
        ensureControlAccessible()
    }

    /// Keeps the armed PiP window pointed at whatever is in front.
    ///
    /// The window in front is the one that should float when the user leaves
    /// FlekDeck, so it keeps a PiP controller ready — which is the whole point of
    /// arming: AVKit can only start PiP by itself through a controller that
    /// already exists, and one built at the moment PiP is chosen arrives long
    /// after the user is looking at the home screen. On the home state nothing is
    /// on stage and nothing should float, so the controller is dropped again.
    ///
    /// Written to be cheap and repeatable, since it runs on every change to
    /// either property: arming a window that is already armed does nothing, and
    /// neither call disturbs a window that is actually floating.
    private func updatePiPArming() {
        guard let pipManager = PiPManager.shared else { return }
        // A built-in page has no guest process behind it and nothing to float, so
        // the cast failing is an ordinary answer rather than a problem.
        guard !isHomeState,
              let uuid = frontmostAppUUID,
              let view = apps.first(where: { $0.appUUID == uuid })?.view,
              !view.isHidden, view.alpha > 0.1,
              let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController,
              let appSceneVC = decoratedVC.appSceneVC
        else {
            pipManager.disarmIfInactive()
            return
        }
        pipManager.arm(forVC: appSceneVC)
    }

    /// Floats a window whose guest has a video as it leaves the stage — another
    /// window brought forward, the switcher opened, this one minimized.
    ///
    /// The same thing happens when the user leaves FlekDeck altogether, but this
    /// is the easier half of it: FlekDeck is still in front, so the float can be
    /// started outright instead of waiting on AVKit to start it on backgrounding.
    ///
    /// Does nothing for a window with no video, and nothing when something is
    /// already floating.
    private func floatWindowLeavingStage(_ uuid: String?) {
        guard let uuid, uuid != frontmostAppUUID || isHomeState else { return }
        // Beside the app now in use, it is still on screen.
        if !isHomeState, splitPair?.contains(uuid) == true { return }
        guard let pipManager = PiPManager.shared, !pipManager.isPiP else { return }
        guard let decoratedVC = apps.first(where: { $0.appUUID == uuid })?.view?._viewDelegate()
                as? DecoratedAppSceneViewController,
              let appSceneVC = decoratedVC.appSceneVC, appSceneVC.guestHasVideo else { return }
        appSceneVC.requestGuestFloat()
    }

    /// Re-checks which window should be armed, for a caller that changed
    /// something the answer depends on without touching either published
    /// property — a guest presenting its scene, which is the first moment the
    /// window in front has anything in it to float.
    @objc public func refreshPiPArming() {
        updatePiPArming()
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from source: CGRect?,
                                       sourceRadius: CGFloat? = nil,
                                       fadesIn: Bool = true, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            // They are making way rather than going home, so the one on top fades
            // and the rest simply go. Every window fading at once read as the stack
            // being scattered by an app being opened.
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC, style: .fade)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            // Asked through hasShared first: if there is no manager there is no
            // PiP to stop, so the scale-in below is already the right branch.
            if PiPManager.hasShared, let pipManager = PiPManager.shared,
               let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
                view.isHidden = false
                view.alpha = 1
                self.bringViewToFront(view, in: window)
            } else {
                // Out of the icon it went into: the way home, run backwards. A
                // window pressed in the switcher comes out of its card instead,
                // that being what the user just touched.
                self.bringViewToFront(view, in: window)
                LCMinimizeToIconAnimator.expand(
                    view,
                    fromItemID: self.apps.first { $0.view === view }?.springboardItemID,
                    sourceInWindow: source,
                    sourceCornerRadius: sourceRadius,
                    fadesIn: fadesIn
                )
            }
        } else {
            bringViewToFront(view, in: window)

            // The pulse that acknowledges a tap on an already-visible window is
            // motion for its own sake — the window is where it was either way —
            // so under Reduce Motion it is simply brought forward.
            guard !UIAccessibility.isReduceMotionEnabled else { return }

            UIView.animate(withDuration: Constants.shortAnimationDuration1, delay: 0, options: .allowUserInteraction, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2, delay: 0, options: .allowUserInteraction) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // MARK: - Picture in Picture

    /// A guest window has left for the system's PiP window.
    ///
    /// It hides itself for this the way `minimizeWindow` does, and until now that
    /// was all it did: nothing here watches a window's visibility, so the dock went
    /// on believing the window was in front — `frontmostAppUUID` naming an app
    /// nobody could see, the bar up over the springboard, and every self-heal
    /// declining to act because there was no window on screen to act for. What is
    /// left behind decides what happens instead, exactly as it does when a window
    /// closes: another window, and that one is in front now; none, and this is the
    /// springboard.
    ///
    /// The switcher, if it is open, comes down with the same distinction. PiP is
    /// started from a card's Customize menu, and an overlay left standing over a
    /// window that has just gone was where the way back got lost: dismissed later,
    /// the control logic found no window to put a control up for, and nothing told
    /// it when the window returned.
    @objc public func windowDidEnterPiP(_ appUUID: String) {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            self.updateFrontmostApp()
            if self.hasForegroundAppWindow() {
                // Whatever was underneath is the app on stage now, and it may be
                // pinned where the one that just left was not.
                if self.isAppSwitcherOpen { self.dismissAppSwitcher() }
                self.refreshOrientationLock()
                return
            }
            // Nothing left on stage: the springboard, recorded as such so the
            // controls read it that way. The switcher's own way home already does
            // all of this, and takes the overlay down over the top of it.
            if self.isAppSwitcherOpen {
                self.goToSpringboardFromSwitcher()
            } else {
                self.isHomeState = true
                self.hideDock()
            }
        }
    }

    /// A guest window is back from the system's PiP window and on stage again.
    ///
    /// The mirror of `windowDidEnterPiP`, and the return the dock never used to
    /// see: the PiP window's own restore button brings a window back without
    /// passing through anything here — no icon tapped, no card pressed — so nothing
    /// put a control up over it. This is the record `bringMultitaskViewToFront`
    /// makes, minus the entrance: the window fades itself back in.
    @objc public func windowDidExitPiP(_ appUUID: String) {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            guard let view = self.apps.first(where: { $0.appUUID == appUUID })?.view else { return }
            // Ahead of the record below, the way a card tap orders it: the overlay
            // fades to reveal the window with its control already in place, and
            // when this is the way back from the springboard the bar comes in with
            // the window.
            if self.isAppSwitcherOpen { self.dismissAppSwitcher() }
            // The window being returned to takes the stage from whatever was
            // there, modals included — see `bringMultitaskViewToFront`.
            for other in self.apps where other.appUUID != appUUID {
                self.dismissPresentation(forAppUUID: other.appUUID)
            }
            view.superview?.bringSubviewToFront(view)
            self.windowTookStage(uuid: appUUID)
        }
    }

    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        // Hidden the instant it is registered, not when the animation gets around
        // to it. The window is added to the hierarchy at full size by its own
        // construction, and the opening runs a turn of the run loop later — long
        // enough for one frame of a full-screen window to be drawn before it
        // collapses onto its icon to grow back out of it.
        view?.alpha = 0
        if let view {
            self.attachLaunchPlaceholder(to: view, appInfo: appInfo)
        }

        DispatchQueue.main.async {
            // Chosen for a side of the screen: it opens onto that side.
            if self.takeArrivingWindowIntoSplit(appModel) { return }
            self.endSplit()
            self.apps.append(appModel)
            self.frontmostAppUUID = appUUID
            self.isHomeState = false
            // Paired with another app: framed for its side before it opens, and the
            // other opened beside it.
            let openPartner = self.splitPartnerOpener(for: appUUID)

            // Opens at once, carrying the app's launch screen. The guest has drawn
            // nothing yet, but its bundle has been readable all along, so there is
            // something to open *with* — and nothing has to wait. The placeholder
            // is dropped once the guest has content behind it.
            if let view {
                LCMinimizeToIconAnimator.expand(view, fromItemID: appModel.springboardItemID)
            }
            openPartner?()

            // The bar comes up with the window, never ahead of it: it is the
            // control for a foreground window, and on a screen that still shows
            // the springboard it is both a lie and — since `goHome` decides by
            // what is visible — a button that would open the app rather than
            // leave it.
            if !self.isVisible {
                self.showDock()
            } else {
                self.updateDockFrame()
                // Dock already up: reconcile the control with the saved
                // preference so opening another app applies a changed choice.
                self.applyPreferredControl()
            }
            self.ensureControlAccessible()
        }
    }
    
    /// Open a built-in page (Settings, Installer, FlekStore) as a multitask window
    public func openInternalPage<Content: View>(kind: String, uuid: String, name: String, @ViewBuilder content: () -> Content) {
        guard isDockEnabled() else { return }
        
        // If already open, just bring to front
        if apps.contains(where: { $0.appUUID == uuid }) {
            let _ = bringMultitaskViewToFront(uuid: uuid)
            return
        }
        
        // A page minimized into the dock is only hidden, and SwiftUI animates what
        // it cannot see. Its views are told, so their endless animations stop.
        let visibility = FlekPageVisibility()
        let hostVC = UIHostingController(rootView: AnyView(FlekPageVisibilityRoot(visibility: visibility, content: content())))
        hostVC.view.frame = windowHostingView.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if isSwitcherBarVisible {
            applyBarInset(to: hostVC, reserved: true)
        }

        // Add as child view controller so the hosting controller inherits
        // proper safe area insets (status bar, etc.) for correct nav bar layout
        if let rootVC = keyWindow?.rootViewController {
            rootVC.addChild(hostVC)
            windowHostingView.addSubview(hostVC.view)
            hostVC.didMove(toParent: rootVC)
        } else {
            windowHostingView.addSubview(hostVC.view)
        }
        
        internalPageControllers[uuid] = hostVC
        // Hidden from the moment it is in the hierarchy, so the frame before the
        // opening animation starts is not a full-screen page appearing whole.
        hostVC.view.alpha = 0
        visibility.track(hostVC.view)

        let appModel = DockAppModel(appName: name, appUUID: uuid, view: hostVC.view, internalPageKind: kind)
        
        DispatchQueue.main.async {
            if self.takeArrivingWindowIntoSplit(appModel) { return }
            self.endSplit()
            self.apps.append(appModel)
            self.frontmostAppUUID = uuid
            self.isHomeState = false
            let openPartner = self.splitPartnerOpener(for: uuid)

            // Out of its own icon, the same as a guest app — this page used to
            // simply be there, one frame absent and the next full screen.
            LCMinimizeToIconAnimator.expand(hostVC.view, fromItemID: appModel.springboardItemID)
            openPartner?()

            if !self.isVisible {
                self.showDock()
            } else {
                self.updateDockFrame()
                // Dock already up: reconcile the control with the saved
                // preference so opening another app applies a changed choice.
                self.applyPreferredControl()
            }
            self.ensureControlAccessible()
        }
    }
    
    // MARK: - A Window's Modals

    /// The controller a window's modals are presented from: the hosting controller
    /// for a built-in page, the decorated controller for a guest window.
    private func presentingController(forAppUUID uuid: String) -> UIViewController? {
        if let page = internalPageControllers[uuid] { return page }
        return apps.first { $0.appUUID == uuid }?.view?._viewDelegate() as? DecoratedAppSceneViewController
    }

    /// Closes whatever a window has presented — a sheet, a cover, an alert — as the
    /// window leaves the screen.
    ///
    /// UIKit puts a presentation in the *window*, beside the page that raised it
    /// rather than inside it, so hiding the page leaves its sheet behind. Nothing
    /// could reach that state while the bar sat underneath every presentation —
    /// there was no way to press home or switch windows with a sheet open — but now
    /// that the bar is above them, going home would strand the sheet over the
    /// springboard.
    ///
    /// Closed rather than hidden along with the page. A sheet is not simply a view
    /// laid over the window: UIKit re-hosts the presenting content inside the
    /// presentation to build the card stack, so putting the container away takes
    /// parts of the app with it and leaves the presentation half-live — reachable
    /// by neither the page nor the springboard. Dismissing is the only way to get
    /// the window back into a state UIKit agrees with.
    ///
    /// `then` runs once the window is out of that card stack and back in the
    /// window on its own, which is what any animation of the window has to wait
    /// for. Starting the minimize alongside the dismissal instead flew a page that
    /// was still hosted inside the presentation: the page shrank into its icon
    /// while the sheet stayed put on top of the springboard, and only caught up
    /// when UIKit finished unwinding the presentation a beat later. It runs
    /// straight away — same turn, no dispatch — when there is nothing presented,
    /// so the common path keeps the timing it always had.
    private func dismissPresentation(forAppUUID uuid: String, then: (() -> Void)? = nil) {
        guard let controller = presentingController(forAppUUID: uuid),
              controller.presentedViewController != nil else {
            then?()
            return
        }
        controller.dismiss(animated: false) { then?() }
    }

    /// A newly launched window has something to show, and now makes its entrance
    /// out of the icon it was launched from.
    ///
    /// Until this runs the window is invisible and the springboard is what the
    /// user is looking at, which is the point: a window opened the instant its
    /// icon is pressed spends its first stretch as a black rectangle, because the
    /// guest process renders on its own schedule. Growing that out of an icon
    /// replaces the home screen with nothing. The home screen keeps the screen
    /// until the app can take it.
    @objc private func windowContentDidArrive(_ note: Notification) {
        guard let view = note.object as? UIView else { return }
        DispatchQueue.main.async {
            // Remembered even when there is nothing to drop yet. The guest reports
            // once and only once, so a report that arrives before the window has
            // been given its launch screen must not be the report that is lost —
            // that is a stand-in left covering a running app for good.
            self.windowsWithContent.insert(ObjectIdentifier(view))

            // Whatever the window opened with has served its purpose: the guest is
            // drawing its own first frame behind it now, which for most apps is the
            // very launch screen this was standing in for — so the two crossing
            // over is not something there is anything to see.
            guard let placeholder = self.launchPlaceholders.removeValue(forKey: ObjectIdentifier(view)) else { return }
            self.fadeOutLaunchPlaceholder(placeholder)
        }
    }

    private func fadeOutLaunchPlaceholder(_ placeholder: UIView) {
        UIView.animate(withDuration: Constants.standardAnimationDuration, delay: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
            placeholder.alpha = 0
        } completion: { _ in
            placeholder.removeFromSuperview()
        }
    }

    /// Puts the app's launch screen into a window that has not opened yet, so it
    /// has something of its own to open with. Kept here rather than on the window
    /// so that dropping it later does not depend on the guest still being around
    /// to be asked.
    private func attachLaunchPlaceholder(to view: UIView, appInfo: LCAppInfo?) {
        // The guest got there first: it is already drawing, so there is nothing
        // for a launch screen to stand in for.
        guard !windowsWithContent.contains(ObjectIdentifier(view)) else { return }
        guard let placeholder = LCLaunchPlaceholder.view(for: appInfo) else { return }
        // Pinned rather than framed: the window is handed this while it is still
        // being assembled, and is given its real size only once the guest's scene
        // reports in — by which time the placeholder has to have followed it.
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: view.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        launchPlaceholders[ObjectIdentifier(view)] = placeholder
    }

    /// How windows leave when several are put away at once. Whichever it is, at
    /// most one of them moves: several windows animating together reads as the
    /// stack being scattered rather than an app being put away.
    enum WindowExit {
        /// Going home. The window on top shrinks into its own icon.
        case intoIcons
        /// Making way for a window being brought forward. The one on top fades;
        /// there is no icon it is going to.
        case fade
        /// Underneath somebody else's choreography — the switcher's own way home,
        /// where the overlay is clearing to reveal the springboard. Any movement
        /// of ours would be seen through it, so there is none.
        case immediate
    }

    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        minimizeAllWindows(except: except, style: .fade)
    }

    /// `intoIcons` is the home button's path: a built-in page shrinks into its
    /// own springboard icon on the way out. Every other caller — switching apps,
    /// the switcher's own way back — has its own choreography over the top of
    /// this, so there the page just goes.
    func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil, style: WindowExit) {
        DispatchQueue.main.async {
            // Capture snapshots of visible windows before minimizing them
            for app in self.apps {
                self.captureSnapshot(for: app.appUUID)
            }
            // Only the window on top flies home. Hopping between apps in the
            // switcher leaves the ones behind visible but covered — nothing hides
            // them, they are simply underneath — and flying those as well sends
            // several windows shrinking out from under the top one at once, a home
            // button that scatters the whole stack instead of putting away the app
            // in front of you. The rest go without a move of their own, so what the
            // flying window uncovers is the springboard.
            let flying = style == .immediate ? nil : self.frontmostVisibleWindow()
            // What the flying window actually covers. A maximized window covers the
            // whole stack, which is the usual case; a windowed guest covers little
            // or nothing, and those windows are genuinely on screen beside it, so
            // they keep an exit of their own rather than blinking out.
            let covered = flying?.frame ?? .null
            // Two side by side go home together, each into its own icon in the
            // dock's tile for the two, rather than the one in front alone.
            var flyingTogether: Set<String> = []
            if style == .intoIcons, let flying, let pair = self.splitPair,
               let flyingUUID = self.apps.first(where: { $0.view === flying })?.appUUID,
               pair.contains(flyingUUID) {
                flyingTogether = Set(pair.members)
            }
            // Making way for one of two side by side, the other stays.
            var spared: Set<String> = []
            if let pair = self.splitPair, let except,
               let kept = self.apps.first(where: { $0.view === except.view })?.appUUID,
               pair.contains(kept) {
                spared = Set(pair.members)
            }
            self.apps.forEach { app in
                if spared.contains(app.appUUID) { return }
                if app.isInternalPage {
                    guard let pageView = app.view else { return }
                    // The page's sheet goes first and the flight waits for it, so the
                    // page leaves from the window rather than from inside the
                    // presentation it was hosted in.
                    self.dismissPresentation(forAppUUID: app.appUUID) {
                        if style == .intoIcons,
                           pageView === flying || flyingTogether.contains(app.appUUID),
                           let itemID = app.springboardItemID {
                            LCMinimizeToIconAnimator.minimize(pageView, toItemID: itemID)
                        } else {
                            pageView.isHidden = true
                        }
                    }
                } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    self.dismissPresentation(forAppUUID: app.appUUID) {
                        app.view?.layer.removeAllAnimations()
                        // A guest window goes into its own icon too. It has to fly the
                        // live view — a guest renders into a layer hosted by the render
                        // server, which this process cannot snapshot — and then be left
                        // in the resting state the window class expects, which is what
                        // `finishMinimizeWindow` is for.
                        if style == .intoIcons, let guestView = app.view,
                           guestView === flying || flyingTogether.contains(app.appUUID),
                           let itemID = app.springboardItemID {
                            LCMinimizeToIconAnimator.minimize(guestView, toItemID: itemID) {
                                vc.finishMinimizeWindow()
                            }
                        } else if style == .immediate {
                            vc.finishMinimizeWindow()
                        } else if let guestView = app.view, guestView !== flying,
                                  covered.contains(guestView.frame) {
                            // Out of sight behind the window that is leaving, so it
                            // needs no exit of its own — and must not draw one, or it
                            // is seen moving as that window uncovers it.
                            vc.finishMinimizeWindow()
                        } else {
                            vc.minimizeWindow()
                        }
                    }
                }
            }
        }
    }

    /// The window the user is actually looking at: the topmost of the host's
    /// stack that is neither hidden nor transparent. Read from the view order
    /// rather than from `frontmostAppUUID`, which records what was last brought
    /// forward and not what is on top of the screen now.
    private func frontmostVisibleWindow() -> UIView? {
        let windows = Set(apps.compactMap { $0.view }.map(ObjectIdentifier.init))
        return windowHostingView.subviews.last {
            windows.contains(ObjectIdentifier($0)) && !$0.isHidden && $0.alpha > 0.1
        }
    }
    
    // MARK: - App Switcher Overlay
    
    /// Capture the springboard (wallpaper + icons) as a still image, excluding
    /// the live guest-app windows, so the switcher can show it blurred behind the
    /// cards (matching Spotlight's blurred home). Renders the layer tree with the
    /// app-window host hidden; `isHidden` is honoured by layer rendering without a
    /// screen update, so hiding + restoring in place causes no flicker.
    func captureSpringboardSnapshot() {
        guard let image = switcherBackdropPicture() else { return }
        springboardSnapshot = image
    }

    /// The springboard as the switcher's backdrop shows it: blurred behind the
    /// cards anyway, so drawn at 1x, not full retina.
    ///
    /// Drawing it is a pass over the whole springboard on the main thread, and it
    /// came at the moment the switcher was asked for, every time. So a copy is
    /// drawn a moment after an app covers the home screen and kept for every open
    /// after, while nothing can have changed the springboard: drawn for this size
    /// and light or dark look, and no chance to change it since (see
    /// `springboardMayHaveChanged`). On the home screen, or over a built-in page,
    /// it is drawn fresh, as before, and not kept.
    private func switcherBackdropPicture() -> UIImage? {
        let size = keyWindow?.bounds.size ?? .zero
        let style = keyWindow?.traitCollection.userInterfaceStyle ?? .unspecified
        let keepable = !isHomeState && !frontmostIsBuiltInPage
        if keepable, let kept = keptSwitcherBackdrop, kept.size == size, kept.style == style,
           kept.epoch == springboardEpoch {
            return kept.image
        }
        guard let image = renderSpringboard(scale: 1) else { return nil }
        keptSwitcherBackdrop = keepable ? (image, size, style, springboardEpoch) : nil
        return image
    }

    /// The springboard may look different from here on: it has been on screen, to
    /// be changed directly, or a built-in page has come forward, where its
    /// wallpaper, its look and its apps are changed. A kept backdrop goes.
    private func springboardMayHaveChanged() {
        springboardEpoch += 1
        keptSwitcherBackdrop = nil
    }

    /// Settings, the Installer or the store in front, rather than an app.
    private var frontmostIsBuiltInPage: Bool {
        guard let uuid = frontmostAppUUID else { return false }
        return apps.first(where: { $0.appUUID == uuid })?.isInternalPage == true
    }

    /// The springboard drawn without the app windows over it, `scale` pixels to
    /// the point.
    func renderSpringboard(scale: CGFloat) -> UIImage? {
        guard let rootView = keyWindow?.rootViewController?.view,
              rootView.bounds.width > 0, rootView.bounds.height > 0 else { return nil }
        let wasHidden = windowHostingView.isHidden
        windowHostingView.isHidden = true
        // Nor the quick switch's blurred copy of it, laid between the two while
        // a swipe is under way.
        let switchCopy = quickSwitch.springboard?.view
        let switchCopyWasHidden = switchCopy?.isHidden ?? false
        switchCopy?.isHidden = true

        // UIVisualEffectView blurs (the list rows' .ultraThinMaterial glass, the
        // bottom variable blur, glass controls) are extremely slow to rasterize
        // via `layer.render(in:)` and dominated the capture time (list ~240ms).
        // The snapshot is only ever shown heavily blurred behind the switcher
        // cards, so hide them for the render and restore immediately (same run
        // loop, no screen update = no flicker).
        var hiddenEffectViews: [UIView] = []
        // Except a glass container, which draws nothing of its own: a page of
        // the springboard keeps its icons inside one, and they would go with it.
        func isGlassContainer(_ view: UIView) -> Bool {
            guard #available(iOS 26, *) else { return false }
            return (view as? UIVisualEffectView)?.effect is UIGlassContainerEffect
        }
        func hideEffectViews(in view: UIView) {
            for sub in view.subviews {
                if sub is UIVisualEffectView, !sub.isHidden, !isGlassContainer(sub) {
                    sub.isHidden = true
                    hiddenEffectViews.append(sub)
                }
                hideEffectViews(in: sub)
            }
        }
        hideEffectViews(in: rootView)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(bounds: rootView.bounds, format: format)
        let image = renderer.image { ctx in
            rootView.layer.render(in: ctx.cgContext)
        }

        for v in hiddenEffectViews { v.isHidden = false }
        switchCopy?.isHidden = switchCopyWasHidden
        windowHostingView.isHidden = wasHidden
        return image
    }

    func captureSnapshots() {
        // Only attempt fresh snapshots for currently visible apps.
        // Keep existing cached snapshots for hidden/minimized apps,
        // since drawHierarchy cannot capture CARemoteLayer content
        // from child processes when views are not actively rendered.
        for app in apps {
            guard let appView = app.view else { continue }
            if !appView.isHidden && appView.alpha > 0.1 {
                captureSnapshot(for: app.appUUID)
            }
        }
    }
    
    /// Capture a snapshot of a single app's view while it's currently visible on screen.
    /// Must be called while the view is still rendering (before any minimize/hide animation).
    /// Snapshots the app view directly (not the window) so each app captures its own
    /// layer tree, avoiding cross-contamination when multiple apps overlap on screen.
    func captureSnapshot(for appUUID: String) {
        guard let app = apps.first(where: { $0.appUUID == appUUID }),
              let appView = app.view,
              !appView.isHidden, appView.alpha > 0.1 else { return }
        
        // The quarter turn a landscape capture needs to stand upright in a PORTRAIT
        // card, so it fills one rather than sitting as a band between black margins.
        // Which way to turn depends on the edge the user rotated towards, so the
        // content ends up the same way up as when they were looking at it.
        //
        // Recorded, not applied. Whether the card is portrait is not knowable here:
        // on iPad the card takes the shape of the screen, so it is landscape whenever
        // the device is, and the device can turn while the switcher is open. The card
        // applies this itself, against the shape it actually has.
        //
        // Decided from the view's own shape rather than from the trimmed capture,
        // because the trim below depends on this turn and so cannot be what fixes it.
        // The two never disagree: a trim takes a strip off an edge, which is nowhere
        // near enough to stand a landscape view on its end.
        var quarterTurn: CGFloat = 0
        if appView.bounds.width > appView.bounds.height {
            quarterTurn = landscapePictureTurn(of: appView)
        }

        // Capture the content region, dropping the safe-area periphery on every edge
        // except the one that ends up along the TOP of the card. The guest is handed
        // those insets as `peripheryInsets` and fills them with its own background,
        // which on screen reads as the status-bar and home-indicator strips. The home
        // indicator and the side strips are dead margin once the app is in a card, but
        // the status bar is part of how the app actually looked, and the system's own
        // switcher keeps it — so this one does too. Internal pages are trimmed for a
        // second reason: they pin their bottom controls above the switcher bar, and
        // that reserved strip is part of the safe area as well.
        //
        // Which edge survives depends on the turn the card will apply. A portrait
        // capture is drawn as it was taken, so it is the capture's own top. A landscape
        // capture is stood upright, and the turn carries one of its sides up there —
        // clockwise brings the left edge to the top, counter-clockwise the right one.
        //
        // The capture's own top is kept in every case as well, not just the unturned
        // one. It costs nothing where the turn is what matters (a phone held in
        // landscape has no top inset to keep), and it covers the one case the turn
        // cannot: an iPad, whose card takes the screen's shape, so a landscape capture
        // is drawn flat in a landscape card with its top edge still on top.
        //
        // Beside another app, the picture is one half of the two's card, and is
        // trimmed as a picture of the whole screen would be, which is landscape: the
        // side the status bar's column stands on is kept, as a card of one app keeps
        // it. The two halves and the fold between them then make the shape of a
        // card of one app, and the pair stands as tall as the cards beside it.
        let inPane = !splitPaneFrame(forAppUUID: appUUID).isNull
        let trim = Self.pictureTrim(of: appView.safeAreaInsets,
                                    turn: inPane ? landscapePictureTurn(of: appView) : quarterTurn)
        let captureRect = appView.bounds.inset(by: trim)
        let viewSize = captureRect.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        appSnapshotRotations[appUUID] = quarterTurn
        // Beside another app, this is a picture of half the screen: for the two's
        // card, and no card of the app's own (see `splitPaneSnapshots`).
        if inPane {
            splitPaneSnapshots.insert(appUUID)
        } else {
            splitPaneSnapshots.remove(appUUID)
        }
        // Which of an iPhone Duo's displays, and which way up (see
        // `pictureFitsDisplay`).
        if let window = appView.window, let screen = window.windowScene?.screen,
           let display = FlekDeviceModel.duoDisplay(of: screen) {
            appSnapshotDisplays[appUUID] = SnapshotDisplay(
                duo: display, landscape: window.bounds.width > window.bounds.height)
        } else {
            appSnapshotDisplays.removeValue(forKey: appUUID)
        }

        // A frozen bitmap of the page exactly as it looks right now, drawn through
        // the render server while the view is on screen, which is the moment this
        // runs.
        // Internal pages only. A guest app renders into a remote layer composited by
        // the render server, and the host process cannot read those pixels back:
        // `drawHierarchy` reports success — it did draw the local hierarchy — but the
        // guest's content simply is not in it, so the bitmap comes out black. Internal
        // pages are ordinary in-process views and capture correctly.
        //
        // As it is on screen, not after the next screen update. Waiting for that
        // held the main thread until the render server had drawn a fresh frame, on
        // every opening of the switcher over a page and on the way home from it:
        // measured at about 0.2s over the Installer in the iPhone Duo simulator,
        // varying with how heavy the page is to draw, while the finger on the cards
        // waited. A page in view has long been committed; there is nothing newer to
        // wait for. Where nothing could be drawn, the replicant below stands in.
        if app.isInternalPage {
            let renderer = UIGraphicsImageRenderer(size: viewSize)
            var drawn = false
            let image = renderer.image { _ in
                drawn = appView.drawHierarchy(
                    in: CGRect(origin: CGPoint(x: -captureRect.origin.x, y: -captureRect.origin.y),
                               size: appView.bounds.size),
                    afterScreenUpdates: false)
            }
            if drawn {
                // Stored as captured; the card turns it when it draws it.
                appSnapshotImages[appUUID] = image
                appSnapshotSizes[appUUID] = viewSize
            } else {
                appSnapshotImages.removeValue(forKey: appUUID)
            }
        } else {
            appSnapshotImages.removeValue(forKey: appUUID)
        }

        // Replicant fallback, for when the bitmap capture comes back empty.
        // Using the view (not the window) ensures we get this specific app's
        // layer tree including CARemoteLayer content, rather than whatever
        // happens to be visually on top at the same screen position.
        if let viewSnapshot = appView.resizableSnapshotView(
            from: captureRect,
            afterScreenUpdates: false,
            withCapInsets: .zero
        ) {
            viewSnapshot.frame = CGRect(origin: .zero, size: viewSize)
            appSnapshotViews[appUUID] = viewSnapshot
            appSnapshotSizes[appUUID] = viewSize
            return
        }
        
        // Fallback: snapshot the content view directly
        if let decoratedVC = appView._viewDelegate() as? DecoratedAppSceneViewController,
           let contentView = decoratedVC.appSceneVC.contentView,
           let viewSnapshot = contentView.snapshotView(afterScreenUpdates: false) {
            appSnapshotViews[appUUID] = viewSnapshot
            appSnapshotSizes[appUUID] = viewSnapshot.bounds.size
        }
    }
    
    /// The quarter turn a landscape picture needs to stand upright in a PORTRAIT
    /// card. Which way depends on the edge the user turned towards, so the content
    /// ends up the same way up as when they were looking at it.
    private func landscapePictureTurn(of view: UIView) -> CGFloat {
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation
            ?? keyWindow?.windowScene?.interfaceOrientation
        switch interfaceOrientation {
        case .landscapeLeft:
            return -.pi / 2
        case .landscapeRight:
            return .pi / 2
        default:
            // The interface is portrait but the capture is not: a landscape-only
            // guest rendering sideways inside an upright host. The interface can't
            // say which way it is being read, so use the device. Note the axes are
            // mirrored — device landscapeLeft is interface landscapeRight.
            // Last valid reading: face-up would otherwise silently pick the
            // other direction and capture the card upside down.
            return lastValidDeviceOrientation == .landscapeLeft ? .pi / 2 : -.pi / 2
        }
    }

    /// What a picture leaves out of the safe area `insets` (see `captureSnapshot`):
    /// every edge but the one along the top of its card. That is the picture's own
    /// top, and for a landscape picture turned by `turn`, the side the turn brings
    /// up there too.
    private static func pictureTrim(of insets: UIEdgeInsets, turn: CGFloat) -> UIEdgeInsets {
        var trim = insets
        trim.top = 0
        if turn > 0 {
            trim.left = 0
        } else if turn < 0 {
            trim.right = 0
        }
        return trim
    }

    /// The shape of a picture of an app with the whole of a `screen`-sized screen,
    /// with `insets` for its safe area, as `captureSnapshot` would take it now: what
    /// shapes a card with no picture of its own to go by.
    func wholeScreenPictureSize(screen: CGSize, insets: UIEdgeInsets) -> CGSize {
        let turn = screen.width > screen.height ? landscapePictureTurn(of: windowHostingView) : 0
        let trim = Self.pictureTrim(of: insets, turn: turn)
        return CGSize(width: max(screen.width - trim.left - trim.right, 1),
                      height: max(screen.height - trim.top - trim.bottom, 1))
    }

    /// Whether `uuid`'s picture was taken on the display the switcher is on now,
    /// and on the inner one the same way up. An iPhone Duo's apps lay themselves
    /// out again for the other display, or for the inner one turned, so a picture
    /// from before shows an app as it will not be: one from the cover display,
    /// shaped and filled to a card on the inner one, stood taller than every card
    /// beside it, its rows half again their size. The cover display keeps its
    /// pictures of apps held sideways: its switcher is always upright, and such a
    /// picture is turned to stand up in its card, as on any other iPhone. Always
    /// on any other phone.
    func pictureFitsDisplay(_ uuid: String) -> Bool {
        guard let taken = appSnapshotDisplays[uuid],
              let screen = (windowHostingView.window ?? keyWindow)?.windowScene?.screen,
              let display = FlekDeviceModel.duoDisplay(of: screen) else { return true }
        guard taken.duo == display else { return false }
        if display == .cover { return true }
        return taken.landscape == (switcherScreenSize.width > switcherScreenSize.height)
    }

    /// The turn a card should apply to a capture, given the shape the card has now.
    /// Zero for a landscape card: the turn only ever existed to stand a landscape
    /// capture up in a portrait one, and applying it to a card that is already
    /// landscape lays the app on its side in a frame that matched it.
    func cardSnapshotRotation(for appUUID: String, portraitCard: Bool) -> CGFloat {
        guard portraitCard else { return 0 }
        return appSnapshotRotations[appUUID] ?? 0
    }

    /// Opens the switcher, first making sure the window is actually portrait.
    ///
    /// The overlay is portrait-only, but requesting the rotation and building the
    /// overlay in the same pass laid it out against the *outgoing* landscape window —
    /// the rotation only lands a runloop or two later. The first rendered frame was
    /// therefore sized from landscape geometry, and if the system declined the
    /// request altogether the overlay simply stayed there, portrait layout inside a
    /// landscape window. Waiting for the window to actually turn removes both cases.
    func showAppSwitcher() {
        guard let keyWindow = self.keyWindow else { return }
        hideSplitHelp()

        // Snapshot the running apps before any rotation, so a card shows the app as
        // it actually looked. Capturing afterwards would catch it mid-turn or already
        // re-laid out for a portrait window it is about to leave again.
        captureSnapshots()

        // Lock now and synchronously — `refreshOrientationLock` defers to the next
        // runloop, which is already too late for the presentation below.
        orientationBeforeSwitcher = keyWindow.windowScene?.interfaceOrientation
        // Raised before the turn is asked for, so nothing that recomputes the lock
        // while it is in flight can hand the window back to the app being left.
        isOpeningAppSwitcher = true
        AppDelegate.orientationLock = .portrait
        // Where the display never turns there is no turn to wait for, and waiting
        // ran out the whole grace period on every open before the cards came up.
        if !displayNeverTurns, AppDelegate.applyOrientationLock() {
            whenWindowIsPortrait(keyWindow) { [weak self] in
                self?.presentAppSwitcher(in: keyWindow)
            }
            return
        }
        presentAppSwitcher(in: keyWindow)
    }

    /// Whether the display FlekDeck is on keeps its shape whatever is asked of it:
    /// the iPhone Duo's inner one, opened out, where iOS shows every scene in all
    /// orientations and no lock holds, and an iPad from iPadOS 26 on, where apps
    /// are windows that turn with the iPad and cannot hold it to one way up. The
    /// portrait the switcher and the way home ask for is never granted there, so
    /// whatever waits for it waits in vain; both go ahead as they are. The Duo's
    /// cover display turns as any iPhone's does.
    private var displayNeverTurns: Bool {
        guard let screen = keyWindow?.windowScene?.screen else { return false }
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .pad { return true }
        return FlekDeviceModel.duoDisplay(of: screen) == .inner
    }

    /// Calls `body` once the window has finished rotating to portrait, or after a
    /// short grace period if it never does — the caller must run either way, and a
    /// device with rotation locked at the system level never turns at all.
    ///
    /// Finished, not merely started. The bounds flip at the top of the transition
    /// and the animation runs on for several more frames, so waiting on the shape
    /// alone lets the caller go while the screen is still turning under it. That is
    /// what made the way home from an orientation-locked app stutter: the window was
    /// being resized by the rotation at the same time as its own flight into an icon
    /// was interpolating toward a rect measured before either had happened. With the
    /// lock off and the device already upright there is no turn, nothing waits, and
    /// the flight has always run alone — which is why only locked apps juddered.
    ///
    /// `isRotating` is the coordinator's own bracket, so this waits on the real
    /// transition rather than a guess at its length. It stays false when there is no
    /// overlay host to report one, which degrades to the old shape-only test rather
    /// than hanging. The cap covers a full turn with room to spare, and a lock left
    /// set by an interrupted transition costs half a second once.
    private func whenWindowIsPortrait(_ window: UIWindow, attempt: Int = 0, _ body: @escaping () -> Void) {
        let isPortrait = window.bounds.height >= window.bounds.width
        guard !(isPortrait && !isRotating), attempt < 45 else {
            body()
            return
        }
        // Asked again, periodically, while it still has not happened — belt to the
        // retry in `applyOrientationLock`'s error handler, which depends on the
        // refusal actually being reported. Costs nothing once the turn is underway:
        // the scene reports portrait by then and the call asks for nothing.
        if attempt > 0, attempt % 12 == 0 { AppDelegate.applyOrientationLock() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.whenWindowIsPortrait(window, attempt: attempt + 1, body)
        }
    }

    /// Stops the card row holding on to a touch before it will scroll.
    ///
    /// A scroll view delays touches to its content by default, so that a finger
    /// that turns out to be tapping something reaches it rather than being read
    /// as a drag. In the switcher that trade is the wrong way round: the cards
    /// are large, the row is meant to be flung, and the pause is paid on every
    /// touch — most noticeably the one right after the carousel settles, where
    /// the first part of the drag goes nowhere and the row feels stuck before it
    /// gives. Tapping a card still works: a tap is not movement, and the card's
    /// own dismiss gesture needs twenty points before it claims anything.
    private func handTouchesStraightToScrollViews(in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.delaysContentTouches = false
            // A drag that began on a card must still be able to become a scroll.
            scrollView.canCancelContentTouches = true
        }
        for subview in view.subviews {
            handTouchesStraightToScrollViews(in: subview)
        }
    }

    private func presentAppSwitcher(in keyWindow: UIWindow) {
        // A pending open can be overtaken. The bar is still on screen and live for the
        // length of the turn this is waiting on, so its home button is reachable — and
        // going home mid-wait would otherwise be followed by the switcher appearing
        // over the springboard. Whatever takes the screen clears the flag; this is
        // where that is honoured.
        guard isOpeningAppSwitcher else { return }

        // Ensure the design is captured before the overlay's bottom toggle renders,
        // so it uses the real corner radius (not the uncaptured default) — otherwise,
        // if the switcher is opened in floating-button mode, the toggle draws an
        // over-tall solid chin.
        captureBarDesign()

        // The springboard snapshot is the overlay's blurred backdrop, so it is taken
        // here — after any rotation — to match the portrait overlay it sits behind.
        captureSpringboardSnapshot()
        refreshCachedSafeAreaInsets()
        refreshSwitcherSideColumn()
        // Sync the preference to whatever control is actually active right now,
        // so the overlay's toggle reflects the current state — the user may have
        // switched between the bar and the floating button in-app since it was
        // last changed here.
        setPrefersFloatingButton(!isSwitcherBarVisible)
        isAppSwitcherOpen = true
        isOpeningAppSwitcher = false
        // The portrait lock was applied in `showAppSwitcher` before we waited for the
        // window to turn; this keeps the rest of the orientation state consistent.
        refreshOrientationLock()

        // Opened over the bar, the switcher's chin starts out exactly as the bar is,
        // its app button still naming the app, and turns that into Close all along
        // with the bar under it: the one thing on the bar that changes. With no bar
        // up along the bottom there is nothing to match, and the chin comes in with
        // Close all already on, its controls arriving as they always have.
        let opensOverBar = isVisible && isSwitcherBarVisible && lastPlacedBarEdge == .bottom
            && hostingController.map { !$0.view.isHidden && $0.view.alpha > 0.01 } == true
        if !opensOverBar { barShowsCloseAll = true }
        // Opened again before the last one had faded: this one starts at rest.
        isDismissingAppSwitcher = false

        // Always recreate the overlay so it picks up the latest apps & snapshots
        switcherOverlayController?.view.removeFromSuperview()
        // Its cards report where they are as they lay out.
        switcherCardFrames.removeAll()

        // Resolve the window's safe area before the overlay reads it, so the bottom
        // toggle bar's height (effectiveBarHeight + safeAreaInsets.bottom) is stable
        // instead of occasionally rendering with a not-yet-ready zero inset — the
        // "randomly taller/shorter" toggle. Pairs with the same guard in updateDockFrame.
        keyWindow.layoutIfNeeded()
        // Size the cards for the orientation the overlay is about to open in.
        refreshSwitcherScreenSize(animated: false)

        let overlayView = AnyView(
            AppSwitcherOverlay(opensOverBar: opensOverBar)
                .environmentObject(self)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
        )
        let hc = UIHostingController(rootView: overlayView)
        // Opaque black on the hosting view (which fills the whole window) so the
        // very bottom / home-indicator region is always covered — even when the
        // SwiftUI content is inset by a guest app's bottom safe area, which
        // otherwise left the springboard showing through as a gap under the bar.
        hc.view.backgroundColor = .black
        hc.view.frame = keyWindow.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hc.overrideUserInterfaceStyle = .dark
        switcherOverlayController = hc
        
        hc.view.alpha = 0
        // Into the overlay window, above the bar it replaces — and, like the bar,
        // above anything the app has presented in its own window.
        (overlayHostView() ?? keyWindow).addSubview(hc.view)
        // Force a full layout + render pass while the overlay is still invisible,
        // so its blurred background, cards and bottom bar are all drawn before the
        // fade starts. Without this the first visible frames show the bare black
        // backdrop and everything "pops in" a frame later — the blink/reload.
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        // Now that the hierarchy exists, hand the row's scroll view its touches
        // without the customary pause. See -handTouchesStraightToScrollViews.
        handTouchesStraightToScrollViews(in: hc.view)

        // No feedback for the arrival itself. Every way in — a bar or dock button,
        // the floating button, the bottom swipe — has already tapped back for the
        // press that asked for it, and a second tap as the overlay lands reads as
        // the one control stuttering rather than as the screen answering.

        // The chin has been laid out naming the app, as the bar does. From here
        // both turn to Close all in the same frames, so the overlay dissolving in
        // over the bar shows one label changing rather than two crossing.
        if opensOverBar {
            withAnimation(Self.barAppButtonSwap) { barShowsCloseAll = true }
        }

        // Keep the existing bottom bar at full opacity underneath during the
        // entrance. Its black rounded region is identical to the overlay's own
        // bottom bar, and so are its buttons but for the middle one's label, so
        // leaving it solid means the bar never cross-fades — instead of the whole
        // bar blinking as the overlay dissolves in over transparent content.
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            // A view being animated by UIKit does not receive touches unless it is
            // asked to. Without this the overlay ignores everything for the length
            // of its own entrance: the switcher is fully drawn and plainly there,
            // and the first tap or swipe onto a card does nothing.
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            hc.view.alpha = 1
        } completion: { _ in
            // Overlay is fully opaque on top now, so hiding the bar underneath
            // has no visible effect — it just keeps the bar's state consistent
            // for the exit path.
            self.hostingController?.view.alpha = 0
            // Again, because the row's scroll view is made by SwiftUI and need
            // not have existed at the first pass. Setting it twice costs a walk
            // of a hierarchy that is a few dozen views deep; missing it costs the
            // pause on every touch for as long as the switcher is open.
            self.handTouchesStraightToScrollViews(in: hc.view)
        }
    }
    
    /// Return to the springboard from the app switcher: minimize every window so
    /// the real home is behind the overlay, then remove the overlay after its exit
    /// animation. Kept separate from `dismissAppSwitcher` so the host is removed
    /// without the fade/scale (the SwiftUI content animates itself out).
    func goToSpringboardFromSwitcher() {
        guard isAppSwitcherOpen else { return }
        isAppSwitcherOpen = false
        // What is drawn around two side by side goes now, with the windows and
        // before the overlay starts to clear, rather than a moment after them.
        splitChromeAwaitsSwitcher = true
        UIView.performWithoutAnimation { self.syncSplitChrome() }
        // The overlay above is already clearing to reveal the springboard, and a
        // window moving underneath it is seen through it. They go without a move.
        minimizeAllWindows(style: .immediate)
        updateFrontmostApp()
        isHomeState = true
        hideDock()
        refreshOrientationLock()
        guard let overlay = switcherOverlayController else {
            splitChromeAwaitsSwitcher = false
            return
        }
        // Clear the overlay's opaque backdrop so the LIVE springboard behind it (its
        // glass already rendering) shows through as the switcher content animates out —
        // cards slide left, buttons drop, and the blurred-home background fades away.
        // Revealing the live springboard (not the glass-less snapshot) is what keeps the
        // icon glass consistent, matching Close all / the Home button.
        overlay.view.backgroundColor = .clear
        // Deaf from the moment it starts leaving. It stays in the hierarchy for
        // the third of a second below and is see-through for all of it, so every
        // touch in that window was landing on a view on its way out and going
        // nowhere. Passing them through means the springboard being revealed can
        // answer them, which is what it looks like should happen.
        overlay.view.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            overlay.view.removeFromSuperview()
            overlay.view.transform = .identity
            self.springboardSnapshot = nil
            self.ensureControlAccessible()
            self.splitChromeAwaitsSwitcher = false
            self.syncSplitChrome()
        }
    }

    /// Puts the interface back where it was before the switcher forced portrait, as
    /// far as the app being returned to allows.
    ///
    /// Releasing the lock is not enough on its own: the widened mask still includes
    /// portrait, so UIKit has no reason to leave it, and no fresh device-orientation
    /// event arrives if the phone never physically moved. Without an explicit request
    /// the app returns upright even though it is being held sideways.
    private func restoreOrientationAfterSwitcher() {
        guard let scene = keyWindow?.windowScene else { return }

        // What the app being returned to allows, which is not always everything. A
        // guest pinned to its own orientation is exactly the case this cannot simply
        // follow the device into: turn the phone upright while the switcher is open
        // over a landscape-pinned app, and following the device would hand that app a
        // portrait window it has been told it cannot be in — the judder, and then a
        // fight, since the very next `refreshOrientationLock` asks for landscape back.
        let allowed = frontmostAppOrientations ?? .allButUpsideDown

        // Follow the device where it can say — that way turning the phone while the
        // switcher was open wins over what we recorded — and fall back to the recorded
        // orientation when it cannot (face up, flat on a table, unknown).
        let target: UIInterfaceOrientation
        switch UIDevice.current.orientation {
        case .landscapeLeft: target = .landscapeRight   // device and interface axes are mirrored
        case .landscapeRight: target = .landscapeLeft
        case .portrait: target = .portrait
        default: target = orientationBeforeSwitcher ?? scene.interfaceOrientation
        }
        orientationBeforeSwitcher = nil

        // Widened first, or the request below is refused against the supported set.
        AppDelegate.orientationLock = allowed

        let mask = AppDelegate.mask(for: target)
        // Non-empty checked as well as allowed: `mask(for:)` answers [] for an unknown
        // orientation, every mask contains the empty set, so the test below would pass
        // and hand `requestGeometryUpdate` a mask permitting nothing at all.
        guard !mask.isEmpty, allowed.contains(mask),
              target != scene.interfaceOrientation else {
            // Nowhere to restore to: either we are already there, or the destination
            // does not allow where the device is pointing. Applying the lock is what
            // puts the interface into what it does allow, and asks for nothing when
            // it is there already.
            AppDelegate.applyOrientationLock()
            return
        }
        // The exact orientation rather than the whole mask: `applyOrientationLock`
        // would hand UIKit a landscape pair and let it choose, which can settle on
        // the turn the user is not holding.
        keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    func dismissAppSwitcher() {
        isAppSwitcherOpen = false
        restoreOrientationAfterSwitcher()

        // Put the chosen control into its final state INSTANTLY (no transition)
        // so it's already in place behind the overlay before it fades — the app
        // is revealed already showing the correct control, with no bar flash.
        applyPreferredControlInstant()
        // And its app button turns back from Close all to the app, the bar's and
        // the fading chin's together, as they turned on the way in.
        withAnimation(Self.barAppButtonSwap) { barShowsCloseAll = false }

        // Restore normal rotation now that the portrait-only overlay is closing.
        refreshOrientationLock()

        guard let overlay = switcherOverlayController else { return }
        // See -goToSpringboardFromSwitcher: it is fading out and must not keep
        // swallowing touches on the way.
        overlay.view.isUserInteractionEnabled = false
        // What is drawn around two side by side, taken away now, while the
        // switcher still covers it, and brought back once it has gone.
        splitChromeAwaitsSwitcher = true
        UIView.performWithoutAnimation { self.syncSplitChrome() }

        // The grow is the overlay's own, not the window's: grown as a whole, the
        // chin came apart from the bar under it, the two drawn over each other a
        // few points out for as long as the fade lasted.
        withAnimation(.easeIn(duration: Constants.shortAnimationDuration1)) {
            isDismissingAppSwitcher = true
        }
        UIView.animate(
            withDuration: Constants.shortAnimationDuration1,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            overlay.view.alpha = 0
        } completion: { _ in
            overlay.view.removeFromSuperview()
            if self.switcherOverlayController === overlay { self.isDismissingAppSwitcher = false }
            self.springboardSnapshot = nil
            self.ensureControlAccessible()
            self.splitChromeAwaitsSwitcher = false
            self.syncSplitChrome()
        }
    }

    /// Puts the multitask control into its final state for the saved preference
    /// with NO animation, so when the switcher overlay is removed the correct
    /// control (bar or floating button) is already in place — no transition and
    /// no chance for `ensureControlAccessible` to briefly restore the wrong one.
    private func applyPreferredControlInstant() {
        guard isDockEnabled(), !isHomeState, hasForegroundAppWindow(),
              let keyWindow = self.keyWindow else { return }
        if usesFloatingButton {
            // Floating button mode: keep the bar hidden, show the button now.
            isSwitcherBarVisible = false
            for (_, controller) in internalPageControllers {
                applyBarInset(to: controller, reserved: false)
            }
            hostingController?.view.isHidden = true
            hostingController?.view.alpha = 0
            showNavAssist(in: keyWindow, animated: false)
        } else {
            // Switcher bar mode: remove the floating button, show the bar now.
            navAssistButton?.removeFromSuperview()
            navAssistButton = nil
            tearDownSwipeZone()
            isNavAssistStashed = false
            navAssistChevron = nil
            isSwitcherBarVisible = true
            for (_, controller) in internalPageControllers {
                applyBarInset(to: controller, reserved: true)
            }
            updateDockFrame(animated: false)
            hostingController?.view.isHidden = false
            hostingController?.view.alpha = 1
            hostingController?.view.transform = barBaseTransform
        }
        NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        refreshOrientationLock()
    }

    /// Reconciles the on-screen control with the saved preference. Called when
    /// an app is opened so a preference changed in the switcher takes effect:
    /// shows the floating button or the switcher bar as chosen.
    func applyPreferredControl() {
        guard isDockEnabled(), isVisible else { return }
        // Puts up what is already chosen, so chooses nothing itself.
        if usesFloatingButton {
            if isSwitcherBarVisible { hideSwitcherBar(choosingFloatingButton: false) }
        } else {
            if !isSwitcherBarVisible { showSwitcherBar(choosingBar: false) }
        }
    }

    func closeApp(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }) else { return }

        if app.isInternalPage {
            let teardown = { [weak self] in
                app.view?.removeFromSuperview()
                self?.internalPageControllers[uuid] = nil
                self?.removeRunningApp(uuid)
            }
            // Its modals go first, with the page still reachable — the teardown
            // drops the controller they would have to be found through — and the
            // flight waits for them, so the snapshot below is of the page itself
            // rather than of a page still hosted inside its own sheet.
            dismissPresentation(forAppUUID: uuid) {
                // A built-in page's own close button is the way home from it, so it
                // makes the same trip into its icon the home button gives the rest.
                // The page itself goes now — a snapshot flies in its place — so the
                // bar and the home state update on time rather than after the flight.
                if let pageView = app.view, !pageView.isHidden, let itemID = app.springboardItemID {
                    LCMinimizeToIconAnimator.minimizeByReplacing(pageView, toItemID: itemID, teardown: teardown)
                } else {
                    teardown()
                }
            }
        } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            vc.closeWindow()
        }
    }

    /// Kicks off a guest app's (asynchronous) process termination WITHOUT
    /// mutating the `apps` list. The switcher removes the card separately on a
    /// fixed, short schedule via `removeRunningApp`, so the reflow of the
    /// remaining cards never has to wait for the app process to actually exit.
    /// Internal pages tear down instantly and are handled entirely by
    /// `removeRunningApp`, so nothing extra is needed for them here.
    func beginAppTeardown(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }) else { return }
        if !app.isInternalPage,
           let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            vc.closeWindow()
        }
    }

    func closeAllApps() {
        isClosingAll = true
        
        let totalDelay = 0.3 + Double(apps.count) * 0.05
        
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) { [weak self] in
            guard let self = self else { return }
            let appsToClose = self.apps
            for app in appsToClose {
                self.dismissPresentation(forAppUUID: app.appUUID)
                // Keyed by the window's identity, so they have to go while the app
                // is still here to be asked for its view. `removeRunningApp` would
                // have done this as each guest exited, but by then the list below
                // has been emptied and there is nothing left to look the view up
                // through — leaving a dead window retained here, under a key a
                // later window could be handed once the address comes back around.
                if let view = app.view {
                    self.launchPlaceholders.removeValue(forKey: ObjectIdentifier(view))
                    self.windowsWithContent.remove(ObjectIdentifier(view))
                }
                if app.isInternalPage {
                    app.view?.removeFromSuperview()
                    self.internalPageControllers[app.appUUID] = nil
                } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    // Out of sight before the overlay starts clearing, the way
                    // `goToSpringboardFromSwitcher` puts its windows away. The
                    // switcher never hid these — it only covered them — so a window
                    // left standing is uncovered by the fade below and then goes
                    // whenever its guest process happens to finish exiting, several
                    // of them blinking out one after another once the cards have
                    // already swept away.
                    vc.finishMinimizeWindow()
                    vc.closeWindow()
                }
            }
            // Every app leaves the list here, in one step and without an animation,
            // rather than each one leaving as its own guest process gets around to
            // exiting. `removeRunningApp` is what those exits call, and it animates
            // the removal with a spring so the switcher's remaining cards can close
            // the gap — right for a single app being closed, wrong for this, where
            // the list is emptying anyway and the springboard is already back. Left
            // to it, the running-app icons on the home screen spring away one at a
            // time over the second or so it takes the guests to die, well after the
            // cards have gone. The stragglers' own `removeRunningApp` calls still
            // arrive; they simply find nothing left to take out.
            self.apps.removeAll()
            self.appSnapshotViews.removeAll()
            self.appSnapshotSizes.removeAll()
            self.appSnapshotImages.removeAll()
            self.appSnapshotRotations.removeAll()
            self.splitPaneSnapshots.removeAll()
            self.appSnapshotDisplays.removeAll()
            self.updateFrontmostApp()
            self.isClosingAll = false
            self.isAppSwitcherOpen = false
            if let overlay = self.switcherOverlayController {
                // Faded rather than whipped away. Behind it is the live springboard,
                // and the backdrop it is covering has no glass on its icons — pulling
                // it in one frame made every card's glass snap into existence at once.
                UIView.animate(withDuration: Constants.standardAnimationDuration,
                               delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    overlay.view.alpha = 0
                } completion: { _ in
                    overlay.view.removeFromSuperview()
                    overlay.view.alpha = 1
                }
            }
            // All apps closed: we are back on the springboard.
            self.isHomeState = true
            self.hideDock()
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - Switcher Bar Content View
/// The flat design's fill: a plain rectangle covering only the bar's flat solid
/// part — everything at or below the flat-top line (`inset` = the device corner
/// radius, the same line the rounded design's flat top sits on). Same geometry as
/// the rounded bar, just a square top edge instead of concave corners, and the
/// region above the line stays transparent exactly as it does in the rounded one.
struct BarFlatTop: Shape {
    var inset: CGFloat
    func path(in rect: CGRect) -> Path {
        let top = min(max(inset, 0), rect.height)
        return Path(CGRect(x: rect.minX, y: rect.minY + top,
                           width: rect.width, height: rect.height - top))
    }
}

/// The portrait bar's top edge, unifying the flat and rounded designs into one
/// shape so they can animate into each other (SwiftUI can't tween between two
/// different `Shape` types). `radius` fixes the flat-top line (`inset` below the
/// strip top); `curve` is how far the concave corners rise above that line at the
/// edges — 0 gives a plain square top (flat), `radius` gives the full concave
/// corners (rounded). Interpolating `curve` (the animatable value) morphs between
/// the two while the flat-top line — and therefore the content beneath — stays put.
struct BarTopBar: Shape {
    var radius: CGFloat
    var curve: CGFloat
    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(max(radius, 0), min(rect.width / 2, rect.height))
        let flatTopY = rect.minY + r
        let c = min(max(curve, 0), r)
        var p = Path()
        if c <= 0.5 {
            // Flat: plain rectangle from the flat-top line down.
            p.addRect(CGRect(x: rect.minX, y: flatTopY,
                             width: rect.width, height: rect.maxY - flatTopY))
            return p
        }
        // Concave corners rising `c` above the flat top at each edge.
        p.move(to: CGPoint(x: rect.minX, y: flatTopY - c))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c, y: flatTopY),
                       control: CGPoint(x: rect.minX, y: flatTopY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: flatTopY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: flatTopY - c),
                       control: CGPoint(x: rect.maxX, y: flatTopY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Full-window container that hosts the switcher bar and restricts touches to the
/// bar's actual visible shape. The bar's hosting view is a full rectangular strip,
/// but its concave top corners and the transparent overhang above the bar sit over
/// live content (guest apps and internal pages) — without this, those regions
/// swallow taps meant for controls beneath them (e.g. the installer's Import IPA
/// and search buttons). Points outside the provided shape return nil so the touch
/// falls through to whatever is behind the container.
/// Invisible, non-interactive full-window view whose `safeAreaInsetsDidChange`
/// lets the dock re-lay out the bar when the window's safe area updates. On a cold
/// relaunch (and some scene transitions) the safe area is populated a beat *after*
/// the bar first appears, and nothing else re-lays the bar out for a pure safe-area
/// change — so without this the bar keeps the stale (often zero-bottom) size it was
/// first laid out with, which is the "wrong size after relaunch" symptom.
final class SafeAreaSentinelView: UIView {
    var onChange: (() -> Void)?
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onChange?()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The window the multitask bar and its companions live in, one level above the
/// app's own so that nothing presented inside the app can come up over them.
///
/// Transparent to any touch that misses their content: the bar hit-tests against
/// its own shape and the rest of the screen still belongs to whatever is beneath.
/// A window that answers `nil` is skipped, and the event goes on down the stack.
final class MultitaskOverlayWindow: UIWindow {
    /// Never the key window. UIKit hands that role to whichever window a touch
    /// lands in, so tapping the bar handed it here — and a great deal of the app
    /// asks the scene for its key window when what it means is "the window the app
    /// is in": its root view controller, its safe area, the view to present from.
    /// Refusing the role keeps all of that pointing at the app's own window; the
    /// bar and the switcher need no keyboard, which is all the role really buys.
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // A miss is the bare overlay itself: the window, the root view, and every
        // view UIKit inserts between the two. Everything else is something really
        // on screen here and takes the touch.
        //
        // Naming the two we expected — the window and its root view — was not
        // enough, because how many views sit between them depends on the device.
        // Both platforms interpose `UITransitionView` → `UIDropShadowView`, and
        // both of those decline a hit of their own, so `super.hitTest` answered nil
        // for bare overlay and the old test was never reached. iPad adds one more:
        // an untyped `UIView`, part of the decoration a resizable app's window
        // carries. That one is an ordinary view and claims the point the way any
        // opaque view does, so it came back as a hit — and every touch outside the
        // bar was swallowed by a window sitting above the whole app. Hence iPad
        // only, verified on both.
        //
        // Asking whether the *root* descends from the hit names that whole chain at
        // once, however long UIKit makes it — it is true for the root view and for
        // each of its ancestors, and false for anything else. Testing the other way
        // round is what it must not do: a sheet or alert presented into this window
        // is a sibling of the root view's transition view rather than anything
        // underneath it, so "descends from the root" would call the switcher's own
        // Close All confirmation a miss and leave its buttons dead.
        guard let root = rootViewController?.view else { return hit === self ? nil : hit }
        return root.isDescendant(of: hit) ? nil : hit
    }
}

/// Root of the overlay window. It exists only because a window is expected to
/// have one — it draws nothing, and holds no content beyond the views the dock
/// manager parents to it.
final class MultitaskOverlayRootViewController: UIViewController {
    /// Called with this host's bounds whenever they change — from the rotation
    /// coordinator with the size being rotated into, and again from the host's own
    /// layout once the new size is real. The dock manager re-places the floating
    /// button from it. Two callers because neither is sufficient alone: a
    /// device-orientation notification can arrive before the window has resized
    /// (and fires for face-up/down, where it never does), while the layout pass
    /// always runs but only after the fact.
    var onHostGeometryChange: ((CGRect) -> Void)?

    /// Bracket a rotation transition, so work driven by a device notification can
    /// keep out of the way while the coordinator is animating the same move.
    var onHostRotationBegan: (() -> Void)?
    var onHostRotationEnded: (() -> Void)?

    /// The bottom edge's first swipe is FlekDeck's, and iOS goes home on a second
    /// one. iOS takes that from a single window, the topmost that drives the
    /// system's appearance, and once this window is up it is that one, over an app
    /// and on the home screen alike. Without this the home screen's own request
    /// (`DeferBottomHomeGestureModifier` in LCTabView) never reached iOS: the first
    /// swipe always went home, and the bottom swipe that opens the switcher never
    /// got a touch.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func loadView() {
        let root = OverlayPassthroughView()
        root.backgroundColor = .clear
        root.onSizeChange = { [weak self] bounds in
            self?.onHostGeometryChange?(bounds)
        }
        view = root
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Announced so that anything else which reacts to a turn can stand aside
        // and let this coordinator own the move — see `isRotating` in the manager.
        onHostRotationBegan?()
        // Inside the coordinator so the move rides the system's rotation animation
        // rather than jumping before or after it.
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.onHostGeometryChange?(CGRect(origin: .zero, size: size))
        }, completion: { [weak self] _ in
            self?.onHostRotationEnded?()
        })
    }
}

/// Reports no hit of its own, so a touch landing on bare overlay falls through to
/// the app underneath instead of stopping at a full-screen transparent view.
final class OverlayPassthroughView: UIView {
    /// Reports a real change of size, once per change — the moment anything
    /// positioned in this view's space has to be measured again.
    var onSizeChange: ((CGRect) -> Void)?
    private var lastReportedSize: CGSize?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastReportedSize else { return }
        lastReportedSize = bounds.size
        onSizeChange?(bounds)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A gesture zone along the bottom of the screen. Swiping up in it opens the
/// multitask switcher — the same thing tapping the floating button beside it does.
///
/// It draws nothing at all. There is no bar and no pill: the system's own home
/// indicator is the only thing down there, and this is the gesture, not an
/// affordance. That is what makes `invisibleButHitTestable` load-bearing rather than
/// decorative, and it is the whole story of why earlier versions of this did not
/// work over a guest app.
///
/// One deliberate cost: a touch that lands in the zone is consumed and cannot be
/// handed on to the guest, whose scene is hosted out of process. At the current
/// `bandIntrusion` the zone sits entirely inside the bottom safe-area band, below
/// where a maximized guest's content stops, so there is nothing of the guest's under
/// it to lose. Reaching further up would start taking its taps.
@available(iOS 16.0, *)
final class MultitaskSwipeZone: UIView {
    /// Run when a swipe up clears the activation threshold.
    var onActivate: (() -> Void)?

    /// Asked before the zone will take a touch at all: true while the three-button
    /// bar is the control on screen, where the bottom edge belongs to the bar.
    ///
    /// Declining the touch rather than merely ignoring the swipe, because this view
    /// is hit-testable on purpose — see `hitTestableAlpha` — so a zone that outlived
    /// the bar coming back would go on swallowing touches along the bar's own chin
    /// even once it had stopped acting on them.
    var isInert: (() -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isInert?() == true { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: Geometry

    /// Nothing is drawn in the zone, so it is sized for a finger rather than for the
    /// eye: as wide as the system's home indicator plus room either side, and tall
    /// enough that a swipe starting anywhere in the band is caught.
    private static let zoneHeight: CGFloat = 28
    private static let zonePadding: CGFloat = 20

    /// How far the zone's bottom edge reaches down into the bottom safe-area band.
    ///
    /// The knob for where the gesture lives. At 30 with a 34pt inset the zone sits
    /// wholly inside the band, which is where it should be: that is the strip the
    /// system reserves for its own indicator, so nothing of the guest's is under it.
    static let bandIntrusion: CGFloat = 30

    /// Length of the system's home indicator on a device whose short side is `side`,
    /// which the zone is sized around so the gesture starts where the eye expects.
    ///
    /// The short side, because the indicator keeps the one length however the screen
    /// is turned. Measured values, not public API.
    private static func indicatorWidth(forShortSide side: CGFloat) -> CGFloat {
        // iPad draws a single fixed length at every size, rather than scaling it with
        // the device the way iPhone does.
        if UIDevice.current.userInterfaceIdiom == .pad { return 320 }
        return (side / 3).rounded() + 9
    }

    static func preferredSize(forShortSide side: CGFloat) -> CGSize {
        CGSize(width: indicatorWidth(forShortSide: side) + zonePadding * 2, height: zoneHeight)
    }

    // MARK: Behaviour

    /// Very nearly, but deliberately not, transparent — do not "clean this up" to
    /// `.clear`.
    ///
    /// A view that draws nothing at all receives no touches over a guest app. The
    /// guest's content is an out-of-process hosted scene, and the system works out
    /// which parts of this process's windows are in front of it and should be handed
    /// the touch; a layer with no content is not among them, and the touch goes
    /// straight through to the guest. `hitTestableAlpha` is the smallest share of it
    /// that has been seen to work.
    ///
    /// Black rather than white, because black is the one that disappears here: the
    /// band this sits in shows LiveContainer's own black backdrop behind a guest —
    /// the guest's content stops above the safe area — and 2% black over black is no
    /// change at all. White would lift it.
    ///
    /// This is what every earlier attempt was really running into. The versions that
    /// worked all drew something — a blurred capsule, a visible pill. The ones that
    /// did not all drew nothing: a clear strip in the band, a clear target with the
    /// pill drawn outside its bounds, and this zone before the background was added.
    /// It is also why switching the diagnostic tint on made it start working, which
    /// is how the cause was finally found.
    ///
    /// There is no documented floor for this, so it is a knob rather than a fact. If
    /// the tint is ever perceptible, walk it down — 0.01, then 1/255, which is the
    /// smallest step an 8-bit channel can even represent — and re-test over a guest
    /// at each step. It stops working somewhere, and where is not written down.
    private static let hitTestableAlpha: CGFloat = 0.02
    private static let invisibleButHitTestable = UIColor.black.withAlphaComponent(hitTestableAlpha)

    private static let activationDistance: CGFloat = 16
    private static let activationVelocity: CGFloat = 300

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.invisibleButHitTestable

        // Pan only. There is nothing to see here, and a tap target this size sitting
        // invisibly against the bezel would fire on any stray touch near it.
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: self).y
        let velocity = gesture.velocity(in: self).y
        // Either a deliberate pull or a flick, matching how the system reads its own
        // edge gesture — a short fast swipe is the common way to reach for this.
        let activated = -translation >= Self.activationDistance
            || velocity <= -Self.activationVelocity
        guard activated else { return }
        // Whether the swipe does anything is not the zone's to know — the bar may
        // have come back over it — so the feedback for it is the handler's too.
        onActivate?()
    }
}

final class BarPassthroughContainer: UIView {
    weak var barView: UIView?
    /// Returns the bar's opaque hit path in `barView`'s local coordinates, or nil
    /// to treat the whole bar bounds as opaque (the plain rectangular bar).
    var hitPathProvider: ((CGRect) -> UIBezierPath?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let bar = barView, bar.superview === self,
              !bar.isHidden, bar.alpha > 0.01 else {
            // No bar actively shown → never intercept; let content behind respond.
            return nil
        }
        let pInBar = bar.convert(point, from: self)
        guard bar.bounds.contains(pInBar) else { return nil }
        if let provider = hitPathProvider, let path = provider(bar.bounds),
           !path.contains(pInBar) {
            // Transparent notch / overhang → pass through to the content beneath.
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

@available(iOS 16.0, *)
struct SwitcherBarContentView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    /// Bumped on each home press to drive the glyph's bounce.
    @State private var homeBounce = 0

    
    var body: some View {
        if dockManager.isSideColumnBar {
            sideColumnContent
        } else {
            edgeBarContent
        }
    }

    /// The bar lying along an edge: its row of buttons on the black strip.
    private var edgeBarContent: some View {
        activeBarContent
        // Make the bar buttons 10% larger (scales the glass pills + glyphs uniformly).
        .scaleEffect(MultitaskDockManager.Constants.barContentScale)
        .padding(.horizontal, MultitaskDockManager.Constants.barHPadding)
        // Center the buttons in the flat solid body — a block spanning the flat-top
        // line down to the screen edge (visible flat strip + safe area). Same formula
        // in both orientations: the bar view is a horizontal strip that landscape just
        // rotates -90°, so the identical height/shape applies either way.
        .frame(height: dockManager.barFlatRegion, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        // Bar background: one shape (portrait AND landscape) that morphs between a flat
        // square top and rounded concave corners via barLedgeAmountActive — the app
        // content above then looks like it has rounded corners nesting into the bar.
        // In landscape the whole bar view is rotated -90°, so the concave "top" edge
        // lands on the screen-inward side and the shape rotates correctly with no
        // landscape special case. The host view's backgroundColor is cleared in
        // setupDockView so the concave corners reveal the app behind them.
        .background {
            BarTopBar(radius: dockManager.barCornerRadiusActive,
                      curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                .fill(Color.black)
                .animation(.easeInOut(duration: 0.32), value: dockManager.barLedgeAmountActive)
                .ignoresSafeArea()
        }
    }
    
    // MARK: - Actions (shared by the row and the side column)

    private func hideBar() {
        MultitaskDockManager.buttonHaptic()
        dockManager.hideSwitcherBar()
    }

    private func toggleAppSwitcher() {
        // Let go after lifting the app off the screen: the end of the lift, not a
        // press of the button.
        if dockManager.splitAppButtonTapSuppressed {
            dockManager.splitAppButtonTapSuppressed = false
            return
        }
        MultitaskDockManager.buttonHaptic()
        if dockManager.isAppSwitcherOpen {
            dockManager.dismissAppSwitcher()
        } else {
            dockManager.showAppSwitcher()
        }
    }

    private func goHome() {
        MultitaskDockManager.buttonHaptic()
        homeBounce += 1
        dockManager.goHome()
    }

    // MARK: - Side Column (iPhone Duo)

    /// The bar standing upright in the column beside an iPhone Duo's status bar:
    /// hide, the app in front and home, top to bottom, in circles the size of iOS's
    /// own buttons in that column. No black strip behind them: the column is the
    /// status bar's own strip, which apps keep their content out of.
    private var sideColumnContent: some View {
        let size = FlekTheme.sideBarButtonSize
        let width = FlekTheme.sideBarWidth
        let glyph = FlekTheme.sideBarButtonGlyphSize
        return VStack(spacing: MultitaskDockManager.Constants.barSpacing) {
            BarControlButton(action: hideBar) {
                // Pointing the way the column goes when it hides: out past the edge.
                Image(systemName: dockManager.isSideColumnOnLeft ? "chevron.left" : "chevron.right")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: glyph, weight: .regular))
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    .frame(width: width)
            }
            .accessibilityLabel("Hide Switcher Bar")

            BarControlButton(action: toggleAppSwitcher) {
                FrontmostAppIcon(slide: dockManager.quickSwitchButtonSlide,
                                 size: FlekTheme.sideBarButtonIconSize)
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    .frame(width: width)
            }
            .accessibilityLabel("App Switcher")
            .modifier(QuickSwitchSwipe())
            .modifier(SplitLiftGesture())

            BarControlButton(action: goHome) {
                Image(systemName: "app")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: glyph, weight: .regular))
                    .modifier(SymbolBounce(value: homeBounce))
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    .frame(width: width)
            }
            .accessibilityLabel("Home")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Active State (app running in foreground)
    private var activeBarContent: some View {
        HStack(spacing: MultitaskDockManager.Constants.barSpacing) {
            // Left: Hide button
            BarControlButton(action: hideBar) {
                Image(systemName: "chevron.down")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
            }
            .accessibilityLabel("Hide Switcher Bar")

            // Middle: App switcher button
            BarControlButton(action: toggleAppSwitcher) {
                BarAppButtonLabel(showsCloseAll: dockManager.barShowsCloseAll)
            }
            .accessibilityLabel("App Switcher")
            .modifier(QuickSwitchSwipe())
            .modifier(SplitLiftGesture())

            // Right: Home button
            BarControlButton(action: goHome) {
                Image(systemName: "app")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: 16, weight: .medium))
                    .modifier(SymbolBounce(value: homeBounce))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
            }
            .accessibilityLabel("Home")
        }
    }
    
    
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    static func cachedIcon(for app: DockAppModel) -> UIImage? {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            return cached
        }
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return icon
        }
        // Try loading synchronously and cache it
        if let appInfo = app.appInfo {
            let darkMode = LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")
            let icon = appInfo.iconIsDarkIcon(darkMode)
            if let icon { IconCacheManager.shared.setIcon(icon, for: cacheKey) }
            return icon
        }
        return nil
    }
}

// MARK: - Frontmost App Icon
/// The app in front drawn as its icon alone: the side column's app button, which
/// has no room for the name the row's capsule carries.
@available(iOS 16.0, *)
private struct FrontmostAppIcon: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    /// Where a swipe along the button has the windows, which the icons follow.
    @ObservedObject var slide: MultitaskQuickSwitch.ButtonSlide
    let size: CGFloat

    private var frontmostApp: DockAppModel? {
        if let uuid = dockManager.quickSwitchLanding ?? dockManager.frontmostAppUUID {
            return dockManager.apps.first { $0.appUUID == uuid }
        }
        return dockManager.apps.last
    }

    /// The home column's icon shape, at this size.
    private var cornerRadius: CGFloat {
        MultitaskHomeIcon.cornerRadius * size / FlekTheme.sideBarAppIconSize
    }

    var body: some View {
        let position = slide.position
        // One icon per app, so a swipe along the bar carries this one out
        // through the icon's outline the way its window goes, and the next one
        // in, step for step with the windows.
        let pages = position?.pages(gap: size / 4) { _ in size }
            ?? [.init(id: frontmostApp?.appUUID ?? "", x: 0)]
        ZStack {
            ForEach(pages) { page in
                icon(for: position == nil ? frontmostApp : dockManager.dockApp(page.id))
                    .offset(x: page.x)
                    .transition(.opacity)
                    // Where the windows put them, never eased there.
                    .transaction { if position != nil { $0.animation = nil } }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // The swipe's right is the screen's right, whatever the language.
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func icon(for app: DockAppModel?) -> some View {
        if let app, let icon = SwitcherBarContentView.cachedIcon(for: app) {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill")
                .foregroundColor(.barGlyph)
                .font(.system(size: size * 0.45))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Frontmost App Icon Label
@available(iOS 16.0, *)
struct FrontmostAppIconLabel: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    /// Where a swipe along the button has the windows, which the label follows.
    @ObservedObject var slide: MultitaskQuickSwitch.ButtonSlide
    @Environment(\.layoutDirection) private var layoutDirection

    private var frontmostApp: DockAppModel? {
        if let uuid = dockManager.quickSwitchLanding ?? dockManager.frontmostAppUUID {
            return dockManager.apps.first { $0.appUUID == uuid }
        }
        return dockManager.apps.last
    }

    /// One app's icon, name and chevron, laid out as the button lays them out
    /// with that app in front, and where it stands across the button.
    private struct Page: Identifiable {
        let id: String
        let app: DockAppModel?
        let nameWidth: CGFloat
        let width: CGFloat
        let x: CGFloat
    }

    private func pages(_ position: MultitaskQuickSwitch.ButtonSlide.Position?) -> [Page] {
        guard let position else {
            let app = frontmostApp
            return [Page(id: app?.appUUID ?? "", app: app, nameWidth: dockManager.barMenuNameWidth,
                         width: dockManager.barMenuWidth, x: 0)]
        }
        let name = { (uuid: String) in dockManager.dockApp(uuid)?.appName ?? "App" }
        return position.pages(gap: 0) { dockManager.barMenuWidth(forName: name($0)) }.map { page in
            Page(id: page.id, app: dockManager.dockApp(page.id),
                 nameWidth: dockManager.barMenuNameWidth(forName: name(page.id)),
                 width: dockManager.barMenuWidth(forName: name(page.id)), x: page.x)
        }
    }

    var body: some View {
        let sliding = slide.position != nil
        // At rest, the app in front's page. During a swipe along the bar, the
        // incoming app's beside it as well, as their windows are, and the two
        // move as the windows move: the finger's, then the slide the rest of the
        // way. Each centred on the capsule, whose centre stays put as it takes
        // the incoming app's width, and cut off only by it (see
        // `BarAppButtonLabel`), so they come and go at its very edges.
        ZStack {
            ForEach(pages(slide.position)) { page in
                BarAppButtonPage(app: page.app, nameWidth: page.nameWidth)
                    .frame(width: page.width)
                    .environment(\.layoutDirection, layoutDirection)
                    .offset(x: page.x)
                    .transition(.opacity)
                    // Where the windows put them, never eased there: not by the
                    // capsule's own glide to the incoming app's width either.
                    .transaction { if sliding { $0.animation = nil } }
            }
        }
        // The swipe's right is the screen's right, whatever the language.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// One app's side of the bar's app button: its icon and name, then the chevron.
@available(iOS 16.0, *)
private struct BarAppButtonPage: View {
    let app: DockAppModel?
    /// What the icon and name take of it (see `barMenuNameWidth`).
    let nameWidth: CGFloat

    var body: some View {
        HStack(spacing: MultitaskDockManager.Constants.barMenuSpacing) {
            AppIconAndName(app: app)
                .frame(width: nameWidth)

            Image(systemName: "chevron.up")
                .foregroundColor(Color.barGlyph.opacity(0.6))
                .font(.system(size: 10, weight: .semibold))
                .frame(width: MultitaskDockManager.Constants.barMenuChevronWidth)
        }
        .padding(.horizontal, MultitaskDockManager.Constants.barMenuHPadding)
    }
}

// MARK: - Bar App Button Label
/// The middle of the bar's row: the app in front on the bar, and Close all on the
/// switcher's chin, which stands in the bar's place while the switcher is open.
/// One view for both, so the switcher opening over the bar changes this label and
/// nothing else: the capsule takes Close all's width, and the buttons either side
/// follow it in.
@available(iOS 16.0, *)
private struct BarAppButtonLabel: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    let showsCloseAll: Bool
    /// Bumped by the chin's Close all, to bounce its glyph.
    var closeBounce = 0

    var body: some View {
        ZStack {
            if showsCloseAll {
                CloseAllLabel(bounce: closeBounce)
                    .transition(Self.swap)
            } else {
                FrontmostAppIconLabel(slide: dockManager.quickSwitchButtonSlide)
                    .transition(Self.swap)
            }
        }
        // Sized by the manager, not by this layout: the bar's and the chin's have
        // to agree, and a capsule that sized itself to its contents would stretch
        // to fill the row's slack instead of stopping at its cap.
        .frame(width: showsCloseAll ? dockManager.barCloseAllWidth : dockManager.barMenuWidth,
               height: MultitaskDockManager.Constants.barButtonSize)
        // The label going out is as often the wider one: cut to the capsule as it
        // narrows.
        .clipShape(Capsule())
        .stableBarGlass(capsule: true)
        // The width belongs to whichever app is frontmost, so it changes on every
        // switch. Glide between the two rather than snapping, the way iOS resizes
        // its own pill controls.
        .animation(.spring(response: 0.3, dampingFraction: 0.9),
                   value: dockManager.barMenuWidth)
    }

    /// Blurred out and in, the way iOS changes a control's label in place.
    private static var swap: AnyTransition {
        if #available(iOS 17.0, *) {
            return AnyTransition(BlurReplaceTransition(configuration: .downUp))
        }
        return .opacity
    }
}

/// What the app button reads while the switcher is open.
@available(iOS 16.0, *)
private struct CloseAllLabel: View {
    let bounce: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .modifier(SymbolBounce(value: bounce))
            Text("Close all")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.barGlyph)
    }
}

/// One app's icon and name on the bar's app button. A view of its own, with its
/// own icon, so the one a switch carries out keeps its app's icon as it goes.
@available(iOS 16.0, *)
private struct AppIconAndName: View {
    let app: DockAppModel?
    @State private var appIcon: UIImage?
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    init(app: DockAppModel?) {
        self.app = app
        // From the cache where it is there, so an app coming in on a swipe
        // arrives with its icon already on.
        _appIcon = State(initialValue: app.flatMap {
            IconCacheManager.shared.getIcon(for: "\($0.appName)_\($0.appUUID)")
        })
    }

    var body: some View {
        HStack(spacing: MultitaskDockManager.Constants.barMenuSpacing) {
            if let icon = appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: MultitaskDockManager.Constants.barMenuIconSize,
                           height: MultitaskDockManager.Constants.barMenuIconSize)
            } else {
                Image(systemName: "app.fill")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: 18))
                    .frame(width: MultitaskDockManager.Constants.barMenuIconSize,
                           height: MultitaskDockManager.Constants.barMenuIconSize)
            }
            
            // The capsule grows to fit this up to `barMenuMaxWidth`. Past that it
            // stops, and the name is what gives way: it shrinks first, and only
            // truncates once there is nothing left to shrink.
            Text(app?.appName ?? "App")
                .foregroundColor(.barGlyph)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
        }
        .onAppear { loadIcon() }
    }

    private func loadIcon() {
        guard let app else {
            appIcon = nil
            return
        }
        
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cached
            return
        }
        
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            self.appIcon = icon
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var icon: UIImage?
            if let appInfo = app.appInfo {
                icon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else if let found = AppInfoProvider.shared.findAppInfo(appName: app.appName, dataUUID: app.appUUID) {
                icon = found.iconIsDarkIcon(darkModeIcon)
            }
            DispatchQueue.main.async {
                if let icon = icon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    var iconSize: CGFloat = MultitaskDockManager.Constants.barIconSize
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: {
                isPressed = true
            },
            onCancel: {
                isPressed = false
            },
            onRelease: { location in
                isPressed = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            self.appIcon = icon
            self.isLoading = false
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper

/// A press that behaves the way a tap on an app icon should: it lights up as
/// soon as the finger lands, gives the touch up the moment it travels far enough
/// to be a scroll, and only fires on release if it never gave up.
///
/// It used to compare `translation` against `.zero` exactly, so a finger that
/// jittered by a fraction of a point on touch-down never lit the highlight at
/// all and the press read as ignored. And the release fired whatever the finger
/// had done in between, so a flick that merely began on a card opened that
/// card's app instead of scrolling past it — this gesture runs alongside the
/// scroll view's own, and nothing was telling the two apart.
private struct PressGesture: ViewModifier {
    let onPress: () -> Void
    let onCancel: () -> Void
    let onRelease: (CGPoint) -> Void

    /// How far the finger may travel and still count as a tap. UIKit lets a
    /// scroll view claim a touch at around ten points, so giving up at the same
    /// distance hands the gesture over exactly when the scroll takes it, rather
    /// than leaving both live and letting the release land on whichever won.
    private static let slop: CGFloat = 10

    /// Deliberately not paired with a "did cancel" flag. A scroll that claims
    /// this gesture never delivers its end, so any flag set on the way out would
    /// still be set when the next finger arrives and would swallow that press
    /// instead. Cancelling on distance alone leaves nothing behind to reset.
    @State private var isPressing = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let travelled = hypot(value.translation.width, value.translation.height)
                    if travelled > Self.slop {
                        if isPressing {
                            isPressing = false
                            onCancel()
                        }
                    } else if !isPressing {
                        isPressing = true
                        onPress()
                    }
                }
                .onEnded { value in
                    let wasPressing = isPressing
                    isPressing = false
                    let travelled = hypot(value.translation.width, value.translation.height)
                    // Not conditioned on having seen a press. A tap quick enough
                    // that no change was ever delivered still landed and lifted
                    // inside the slop, and that is the whole of the test; making
                    // the release depend on the highlight having lit would drop
                    // the fastest taps, which is the opposite of the point.
                    if travelled <= Self.slop {
                        onRelease(value.startLocation)
                    } else if wasPressing {
                        onCancel()
                    }
                }
        )
    }
}

extension View {
    func onPressGesture(onPress: @escaping () -> Void,
                        onCancel: @escaping () -> Void,
                        onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        modifier(PressGesture(onPress: onPress, onCancel: onCancel, onRelease: onRelease))
    }
}

// MARK: - App Switcher Overlay
@available(iOS 16.0, *)
struct AppSwitcherOverlay: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var isPresented = false
    @State private var exiting = false
    @State private var showCloseAllConfirm = false
    /// Bumped on press to bounce each glyph; see `SymbolBounce`.
    @State private var closeBounce = 0
    @State private var homeBounce = 0
    @Environment(\.layoutDirection) private var layoutDirection
    /// Opened over the bar: the chin starts out as the bar is, with nothing of it
    /// to arrive, and only its app button changes. See `presentAppSwitcher`.
    let opensOverBar: Bool

    init(opensOverBar: Bool) {
        self.opensOverBar = opensOverBar
    }

    private let cardSpacing: CGFloat = 16

    // Fixed corner radius (matches the Figma design spec).
    private let cardCornerRadius: CGFloat = 34

    // Card dimensions — proportional to screen like iOS app switcher
    /// Raised from 0.62 to hold the card's original height. Card height now follows
    /// the trimmed snapshot's aspect rather than the screen's, which is shorter, so
    /// at the old fraction the card lost ~11% of its height.
    private var cardWidth: CGFloat {
        dockManager.switcherScreenSize.width * 0.70
    }
    /// Height of the header row above each card's image — the app icon's own size,
    /// which is the tallest thing in it. Named because the card's height is capped
    /// against the room the column has left once this and the chin have taken theirs.
    private let cardHeaderHeight: CGFloat = 32

    /// Shaped like the snapshot it holds, not like the whole screen. A snapshot keeps
    /// the app's status-bar strip but is trimmed of the rest of the periphery, so it
    /// is shorter than the screen by the bottom inset alone — sizing the card from the
    /// full screen aspect left the image slightly too tall for it, and filling the
    /// card then cropped the sides.
    ///
    /// Capped at the height the column actually has spare. Keeping the status-bar
    /// strip makes a card taller than it used to be, and on a short screen carrying a
    /// deep bar the header above and the chin below can want more room than is left.
    /// The cap only binds there; everywhere else the card is still exactly its
    /// snapshot's shape.
    ///
    /// The width it keeps is the screen's less the side insets, which the snapshot
    /// drops too. An iPhone held upright has none; an iPhone Duo's status bar runs
    /// down one side, an 84pt column of inset, and a card shaped from the whole
    /// width was too wide for the snapshot it held: filling it cut the app's title
    /// off the top and its last rows off the bottom. Held landscape, as an iPhone
    /// Duo opened out is, a snapshot keeps that column, as the side it would turn
    /// up to the top, and so does this; trimmed of it, a card with no picture yet
    /// stood a tenth taller than the cards beside it.
    ///
    /// The shape of a card with no snapshot to go by yet, and of every card on
    /// iPad. See `cardHeight(for:)` for the rest.
    private var defaultCardHeight: CGFloat {
        let picture = dockManager.wholeScreenPictureSize(screen: dockManager.switcherScreenSize,
                                                         insets: dockManager.cachedSafeAreaInsets)
        return min(cardWidth * (picture.height / picture.width), maxCardHeight)
    }

    /// The tallest a card can be: what the column has left once the top spacer,
    /// the header row and the gap under it, the minimum gap above the chin, and the
    /// chin have taken theirs.
    private var maxCardHeight: CGFloat {
        let insets = dockManager.cachedSafeAreaInsets
        let chrome = (insets.top + 12) + (cardHeaderHeight + 8) + 20 + chinReserve
        return max(dockManager.switcherScreenSize.height - chrome, 1)
    }

    /// One app's card, shaped like that app's own snapshot as the card shows it,
    /// stood upright if it was taken sideways, so filling the card crops next to
    /// nothing. Cards in a row can then differ in height: on an iPhone Duo the status
    /// bar's column comes off an upright app's long side but a sideways app's short
    /// one, and one shape for both cut a fifth off a sideways app's width. Elsewhere
    /// the two shapes are all but the same.
    ///
    /// On iPad every card keeps the screen's shape, as it always has.
    private func cardHeight(for app: DockAppModel) -> CGFloat {
        let fallback = defaultCardHeight
        guard !FlekDeviceModel.isPad, pictureFits(app, inSplit: false),
              let size = dockManager.appSnapshotSizes[app.appUUID],
              size.width > 0, size.height > 0 else { return fallback }
        let turned = dockManager.cardSnapshotRotation(for: app.appUUID,
                                                      portraitCard: fallback > cardWidth) != 0
        // Height over width, as the card shows it.
        let aspect = turned ? size.width / size.height : size.height / size.width
        return min(cardWidth * aspect, maxCardHeight)
    }

    /// What the row shows, oldest first: a card for each app, except two side by
    /// side on an iPhone Duo, which share one where the more recent of them would
    /// be, as iOS shows a pair in Split View. That is so while they are side by
    /// side, with one beside the apps to choose from too, and after going home
    /// from them while both are still open: the switcher shows them as they were,
    /// and brings them back that way.
    private enum SwitcherItem: Identifiable {
        case single(DockAppModel)
        case split(left: DockAppModel?, right: DockAppModel?)

        var id: String {
            switch self {
            case .single(let app): return app.appUUID
            case .split(let left, let right):
                return "split:\(left?.appUUID ?? "-")|\(right?.appUUID ?? "-")"
            }
        }

        func contains(_ uuid: String) -> Bool {
            switch self {
            case .single(let app): return app.appUUID == uuid
            case .split(let left, let right): return left?.appUUID == uuid || right?.appUUID == uuid
            }
        }
    }

    private var switcherItems: [SwitcherItem] {
        let apps = dockManager.apps
        // Folded, they are one at a time, and so are their cards.
        guard dockManager.canSplitNow,
              let pair = dockManager.splitPair ?? dockManager.splitSuspended else {
            return apps.map { .single($0) }
        }
        let left = pair.left.flatMap { id in apps.first { $0.appUUID == id } }
        let right = pair.right.flatMap { id in apps.first { $0.appUUID == id } }
        guard left != nil || right != nil,
              let last = apps.lastIndex(where: { pair.contains($0.appUUID) }) else {
            return apps.map { .single($0) }
        }
        var items: [SwitcherItem] = []
        for (index, app) in apps.enumerated() {
            if !pair.contains(app.appUUID) {
                items.append(.single(app))
            } else if index == last {
                items.append(.split(left: left, right: right))
            }
        }
        return items
    }

    /// The row's item an app is shown in, to scroll to.
    private func switcherItemID(for uuid: String) -> String {
        switcherItems.first { $0.contains(uuid) }?.id ?? uuid
    }

    @ViewBuilder
    private func switcherCard(_ item: SwitcherItem, index: Int) -> some View {
        switch item {
        case .single(let app):
            AppSwitcherCard(app: app, cardWidth: cardWidth, cardHeight: cardHeight(for: app),
                            cornerRadius: cardCornerRadius, cardIndex: index,
                            showsPicture: pictureFits(app, inSplit: false))
        case .split(let left, let right):
            // One card for the two, as iOS shows a pair in Split View: the screen as
            // it was, the two pictures side by side with the fold's black between
            // them, at the size of a card of one app. Each half keeps its app's name
            // and controls over it: a tap on either brings the two back side by
            // side, with that one in use, and either swiped away closes only that
            // app. A side with the apps to choose from on it is left empty.
            //
            // Left to right whatever the language, as the screen it pictures is.
            let layout = pairCardLayout(left, right)
            HStack(alignment: .top, spacing: 0) {
                splitHalf(left, size: layout.left, index: index,
                          fold: SwitcherCardFold(edge: .trailing, gap: layout.gap / 2,
                                                 cornerRadius: layout.foldRadius))
                splitHalf(right, size: layout.right, index: index,
                          fold: SwitcherCardFold(edge: .leading, gap: layout.gap / 2,
                                                 cornerRadius: layout.foldRadius))
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder
    private func splitHalf(_ app: DockAppModel?, size: CGSize, index: Int,
                           fold: SwitcherCardFold) -> some View {
        if let app {
            AppSwitcherCard(app: app, cardWidth: size.width, cardHeight: size.height,
                            cornerRadius: cardCornerRadius, cardIndex: index,
                            showsPicture: pictureFits(app, inSplit: true), fold: fold)
        } else {
            // Where a card's header would be, then the side's space.
            VStack(alignment: fold.headerAlignment, spacing: 8) {
                Color.clear.frame(width: size.width, height: 32)
                Color.white.opacity(0.08)
                    .frame(width: size.width, height: size.height)
                    .switcherCardClip(cornerRadius: cardCornerRadius, fold: fold)
            }
        }
    }

    /// Whether `app`'s picture fits the card it is on: one taken beside another
    /// app for a half of the two's card, any other for a card of its own, and
    /// either only on the display it was taken on. A card whose picture doesn't
    /// fit shows the app's icon instead, at the card's own shape (see
    /// `MultitaskDockManager.splitPaneSnapshots` and `pictureFitsDisplay`).
    private func pictureFits(_ app: DockAppModel, inSplit: Bool) -> Bool {
        dockManager.splitPaneSnapshots.contains(app.appUUID) == inSplit
            && dockManager.pictureFitsDisplay(app.appUUID)
    }

    /// Width over height of an app's picture, as its card shows it.
    private func snapshotAspect(_ app: DockAppModel, portraitCard: Bool) -> CGFloat? {
        guard let size = dockManager.appSnapshotSizes[app.appUUID],
              size.width > 0, size.height > 0 else { return nil }
        let turned = dockManager.cardSnapshotRotation(for: app.appUUID, portraitCard: portraitCard) != 0
        return turned ? size.height / size.width : size.width / size.height
    }

    /// A split's card: each half's picture, and the fold between them.
    private struct PairCardLayout {
        var left: CGSize
        var right: CGSize
        /// The black between the two pictures.
        var gap: CGFloat
        /// The corners the fold rounds each picture off by on its side.
        var foldRadius: CGFloat
    }

    /// A split's card, drawn as the screen shows the two: one height, each half as
    /// wide as its app's picture at that height, and the fold between them at its
    /// width on screen, all scaled alike. Pictured as the screen is, the two and the
    /// fold together make the shape of a picture of one app, so the pair is exactly
    /// as wide as a card of one app and as tall; narrower only where that would be
    /// taller than the column has room for. A side with no app, or no picture of it
    /// from beside the other, is the shape its picture would be.
    private func pairCardLayout(_ left: DockAppModel?, _ right: DockAppModel?) -> PairCardLayout {
        let leftShape = dockManager.splitPictureShape(.left)
        let rightShape = dockManager.splitPictureShape(.right)
        func aspect(_ app: DockAppModel?, _ shape: CGSize) -> CGFloat {
            if let app, pictureFits(app, inSplit: true),
               let pictureAspect = snapshotAspect(app, portraitCard: true) {
                return pictureAspect
            }
            return shape.width / shape.height
        }
        let leftAspect = aspect(left, leftShape)
        let rightAspect = aspect(right, rightShape)
        // The fold, in heights of a picture.
        let pictureHeight = max(leftShape.height, 1)
        let foldAspect = MultitaskDockManager.splitGap / pictureHeight
        let height = min(cardWidth / max(leftAspect + rightAspect + foldAspect, 0.01), maxCardHeight)
        let scale = height / pictureHeight
        return PairCardLayout(left: CGSize(width: height * leftAspect, height: height),
                              right: CGSize(width: height * rightAspect, height: height),
                              gap: MultitaskDockManager.splitGap * scale,
                              foldRadius: SplitDividerView.cornerRadius * scale)
    }

    /// What the column keeps free under the cards: the chin's footprint, or with the
    /// controls in the side column, only the home indicator's band.
    private var chinReserve: CGFloat {
        dockManager.isSwitcherSideColumn
            ? dockManager.cachedSafeAreaInsets.bottom
            : dockManager.barFlatRegion + 20
    }

    /// Whether the side column is on the layout's leading side, which is the screen's
    /// left only in a left-to-right layout.
    private var sideColumnIsLeading: Bool {
        dockManager.isSwitcherSideColumnOnLeft != (layoutDirection == .rightToLeft)
    }

    // How far the cards slide left and the buttons slide down when the user taps
    // the background to return to the springboard.
    private var exitCardOffset: CGFloat { dockManager.switcherScreenSize.width + cardWidth }
    private var exitButtonOffset: CGFloat { dockManager.switcherScreenSize.height * 0.4 }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Blurred springboard background: the captured home (wallpaper +
            // icons) behind a dark material, the same treatment Spotlight uses.
            // Falls back to a flat dark blur if no snapshot was captured.
            ZStack {
                if let snapshot = dockManager.springboardSnapshot {
                    SwitcherBackdropPicture(image: snapshot, screen: dockManager.switcherScreenSize)
                }
                // Blur + scrim fade out on exit so the sharp home is revealed
                // (the snapshot, then the real springboard once the overlay goes).
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .ignoresSafeArea()
                    // Slight scrim so the cards keep contrast over the blurred home.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                }
            }
            // Fade the entire blurred-home background out on exit. The snapshot is
            // captured with layer rendering, which can't capture the icons' glass, so
            // resting on it made the glass look like it "appears". Fading it away reveals
            // the LIVE springboard behind the (cleared) overlay, glass already intact.
            .opacity(exiting ? 0 : 1)
            // Eased out, not in, and on its own curve rather than the one carrying the
            // cards away. The cards want to accelerate off the screen; the backdrop is
            // uncovering the real springboard underneath, and easing in held it at full
            // opacity for most of the animation before dropping it — so the icons' glass
            // arrived all at once at the very end, which is the pop this fade exists to
            // prevent. Easing out spends the opacity early and lets the last of it go
            // gently, so the glass comes up rather than snapping in.
            .animation(.easeOut(duration: 0.3), value: exiting)
            // Grows with the cards as the switcher fades back to an app.
            .scaleEffect(dockManager.isDismissingAppSwitcher ? 1.05 : 1)
            // Returning to the springboard lives HERE, on the backdrop, not on the
            // ZStack as a whole. The backdrop is the bottom-most, full-bleed layer;
            // every card, button and control sits above it. So whether a tap
            // dismisses is decided by ordinary front-to-back hit testing — a tap
            // reaches this gesture only when nothing on top of it caught it first.
            // For these layers — plain SwiftUI views that each fully consume any
            // touch inside their own bounds — front-to-back hit testing settles
            // that the same way on every iOS version and screen size, with none of
            // the ancestor/descendant arbitration that shifted between releases.
            //
            // Attached to the ancestor ZStack instead (as it was), the gesture
            // competed with each control's own gesture through SwiftUI's
            // ancestor/descendant arbitration, which resolves differently across
            // releases: that is why tapping the mute or Customize button dismissed
            // the switcher on 17.4 but not elsewhere. Nothing above needs to "win"
            // a race any more; it simply has to be hit first, which it always is.
            .contentShape(Rectangle())
            .onTapGesture {
                exitToSpringboard()
            }

            VStack(spacing: 0) {
                // Pin the content near the top with a small margin below the
                // safe area (the overlay ignores the safe area, so add it back
                // here) instead of pushing everything toward the bottom.
                Spacer()
                    .frame(minHeight: dockManager.cachedSafeAreaInsets.top + 12)

                // Horizontal scrolling app cards
                ScrollViewReader { proxy in
                    cardScrollView
                    .onAppear {
                        // Always land on the most-recently-used app (the rightmost
                        // card), matching iOS. `frontmostAppUUID` is transient — it's
                        // cleared to nil whenever we visit the springboard — so when
                        // it's unavailable, fall back to the last app in recency order
                        // (the `apps` array keeps the most-recent app at the end).
                        // Without this fallback the scroll was skipped and the view
                        // rested at its leading edge, showing the leftmost (oldest) card.
                        let target = (dockManager.frontmostAppUUID ?? dockManager.apps.last?.appUUID)
                            .map(switcherItemID(for:))
                        if let target {
                            // Defer to the next runloop so the scroll target layout is
                            // resolved before we scroll: calling scrollTo before layout
                            // settles under `.viewAligned` can snap back to the first
                            // card, which is the intermittent "jumps to left card" bug.
                            DispatchQueue.main.async {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isPresented = true
                        }
                    }
                    // Re-centred as the device turns, rather than rebuilt. Both the card
                    // width and the padding either side of the row change with the
                    // orientation, so the scroll is left holding an offset that belongs
                    // to the old geometry. Discarding the row's identity to clear that
                    // also discards any chance of animating it — a view with a new
                    // identity has nothing to animate from, which is what made a
                    // rotation look like a redraw. Keeping the identity and moving the
                    // scroll lets the whole thing travel with the turn.
                    //
                    // Left to the next runloop so the row has been laid out at its new
                    // width before it is centred; scrolling against the old one lands
                    // between cards.
                    .onChange(of: dockManager.switcherScreenSize) { _ in
                        guard let target = (dockManager.frontmostAppUUID
                                ?? dockManager.apps.last?.appUUID).map(switcherItemID(for:)) else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: MultitaskDockManager.rotationDuration)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
                .offset(x: exiting ? -exitCardOffset : 0)
                
                // Flexible gap so the cards sit up top and the bottom actions
                // fall to the bottom edge.
                Spacer(minLength: 20)

                // Reserve the chin's footprint — the controls live inside it, as a
                // separate bottom-anchored layer below — so the cards stop above it.
                Spacer()
                    .frame(height: chinReserve)
            }
            // Dead while the switcher animates out. Without this a second tap
            // during the ~0.3s exit could land on a card that is still sliding
            // and visible, bringing that app forward while we are already on the
            // way to the springboard.
            .allowsHitTesting(!exiting)
            // Fading back to an app, the cards grow a little as they go. The chin
            // below doesn't: it stands over the bar it is handing back to.
            .scaleEffect(dockManager.isDismissingAppSwitcher ? 1.05 : 1)

            // The switcher's three controls: the chin along the bottom, or where the
            // bar stands beside an iPhone Duo's status bar, the same column there.
            if dockManager.isSwitcherSideColumn {
                sideColumnControls
            } else {
                bottomChin
            }
        }
        .ignoresSafeArea()
        .alert("Close All Apps?", isPresented: $showCloseAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Close All", role: .destructive) {
                dockManager.closeAllApps()
            }
        } message: {
            Text("This closes every open app.")
        }
        // Note: background-tap-to-dismiss is deliberately NOT here on the ZStack.
        // It lives on the backdrop layer above, so it is governed by hit testing
        // rather than by competing with descendant controls' gestures. See there.
    }

    // MARK: - Controls (shared by the chin and the side column)

    private func toggleBarPreference() {
        MultitaskDockManager.buttonHaptic()
        // A spring, not a curve: the symbol replace below takes its
        // timing from this transaction, and iOS's own symbol swaps
        // settle with a little spring rather than easing flatly.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dockManager.setPrefersFloatingButton(!dockManager.prefersFloatingButton)
        }
    }

    private func askToCloseAll() {
        MultitaskDockManager.buttonHaptic()
        closeBounce += 1
        showCloseAllConfirm = true
    }

    private func goHome() {
        homeBounce += 1
        exitToSpringboard()
    }

    /// The chin: the switcher bar itself, anchored flush to the very bottom
    /// edge with exactly the real bar's thickness (bar height + bottom safe
    /// area), holding the overlay's three controls the way the real bar holds
    /// its own. Left toggles the bar (the action this chin used to carry as a
    /// full-width "Hide Switcher Bar" label), middle closes everything, right
    /// goes home. As its own bottom-aligned ZStack layer it can't be shifted
    /// by the VStack's flow, so its height matches the real bar precisely.
    private var bottomChin: some View {
        HStack(spacing: MultitaskDockManager.Constants.barSpacing) {
            Button(action: toggleBarPreference) {
                Image(systemName: dockManager.prefersFloatingButton ? "chevron.up" : "chevron.down")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: 14, weight: .semibold))
                    .modifier(SymbolReplaceTransition())
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
                    // The whole circle takes the tap, not just the glyph.
                    // Without it the ring around a chevron is see-through to
                    // hit testing, and a near-miss reaches the backdrop
                    // behind — which returns to the springboard.
                    .contentShape(Circle())
            }
            .buttonStyle(BarControlButtonStyle())
            .accessibilityLabel(dockManager.prefersFloatingButton ? "Use Switcher Bar" : "Hide Switcher Bar")
            .modifier(ChinControlEntrance(shown: isPresented || opensOverBar, index: 0, from: -1))

            Button(action: askToCloseAll) {
                // The bar's app button, which turns into Close all as the switcher
                // opens over it; on the way home it stays Close all to the end.
                BarAppButtonLabel(showsCloseAll: dockManager.barShowsCloseAll || exiting,
                                  closeBounce: closeBounce)
                    .contentShape(Capsule())
            }
            .buttonStyle(BarControlButtonStyle())
            .modifier(ChinControlEntrance(shown: isPresented || opensOverBar, index: 1, from: 0))

            Button(action: goHome) {
                Image(systemName: "app")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: 16, weight: .medium))
                    .modifier(SymbolBounce(value: homeBounce))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
                    .contentShape(Circle())
            }
            .buttonStyle(BarControlButtonStyle())
            .accessibilityLabel("Home")
            .modifier(ChinControlEntrance(shown: isPresented || opensOverBar, index: 2, from: 1))
        }
        // Sized and spaced exactly as the real bar sizes and spaces its own
        // row — same button metric, same 10pt gaps, same 1.1 scale-up, same
        // side padding — so the controls don't change size as the switcher
        // opens over the bar or dismisses back into it.
        .scaleEffect(MultitaskDockManager.Constants.barContentScale)
        .padding(.horizontal, MultitaskDockManager.Constants.barHPadding)
        // Centred in the flat solid body — the block from the flat-top line down
        // to the screen edge — exactly as the real bar centres its own controls.
        // `barFlatRegion` floors at that same button height, so the row always
        // has room: on a device with no bottom inset and a shallow corner radius
        // the natural region is far too short to hold it.
        .frame(maxWidth: .infinity)
        .frame(height: dockManager.barFlatRegion, alignment: .center)
        .padding(.top, dockManager.barCornerRadiusActive)
        // Same concave rounded top corners and height as the real switcher bar —
        // including the rounding amount from the Settings slider, so this chin
        // always matches it. Solid black while the bar is the active control;
        // once the user taps the arrow (floating-button mode), the black fades
        // out to reveal a translucent ultra-thin-material bar underneath.
        // Layering the black over the material and animating its opacity lets
        // the two states cross-fade smoothly when the toggle flips.
        .background {
            BarTopBar(radius: dockManager.barCornerRadiusActive,
                      curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                .fill(.thinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    BarTopBar(radius: dockManager.barCornerRadiusActive,
                              curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                        .fill(Color.black)
                        .opacity(dockManager.prefersFloatingButton ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.32), value: dockManager.barLedgeAmountActive)
                .animation(.easeInOut(duration: 0.25), value: dockManager.prefersFloatingButton)
                .ignoresSafeArea()
        }
        .offset(y: exiting ? exitButtonOffset : 0)
        // Inert during the exit animation, like the cards above. This chin is a
        // separate ZStack sibling, so the cards' own allowsHitTesting guard
        // doesn't reach it — without this, a second tap landing on the arrow
        // while the switcher slides away would flip the persisted preference.
        .allowsHitTesting(!exiting)
    }

    /// The controls standing in the side column beside an iPhone Duo's status bar,
    /// as the bar's own buttons do there: the same circles in the same places, so
    /// the switcher opening over the bar changes only what they show. Nothing
    /// behind them, as nothing is behind the bar's.
    private var sideColumnControls: some View {
        let size = FlekTheme.sideBarButtonSize
        let width = FlekTheme.sideBarWidth
        let glyph = FlekTheme.sideBarButtonGlyphSize
        // The bar leaves through the edge beside it and comes back in away from it.
        let pointsLeft = dockManager.prefersFloatingButton != dockManager.isSwitcherSideColumnOnLeft
        return VStack(spacing: MultitaskDockManager.Constants.barSpacing) {
            Button(action: toggleBarPreference) {
                Image(systemName: pointsLeft ? "chevron.left" : "chevron.right")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: glyph, weight: .regular))
                    .modifier(SymbolReplaceTransition())
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    // Across the column's whole width, not just the circle: a
                    // near-miss would otherwise reach the backdrop behind, which
                    // returns to the springboard.
                    .frame(width: width)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BarControlButtonStyle())
            .accessibilityLabel(dockManager.prefersFloatingButton ? "Use Switcher Bar" : "Hide Switcher Bar")
            .modifier(ChinControlEntrance(shown: isPresented, index: 0, from: 0))

            Button(action: askToCloseAll) {
                Image(systemName: "xmark")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: glyph, weight: .regular))
                    .modifier(SymbolBounce(value: closeBounce))
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    .frame(width: width)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BarControlButtonStyle())
            .accessibilityLabel("Close all")
            .modifier(ChinControlEntrance(shown: isPresented, index: 1, from: 0))

            Button(action: goHome) {
                Image(systemName: "app")
                    .foregroundColor(.barGlyph)
                    .font(.system(size: glyph, weight: .regular))
                    .modifier(SymbolBounce(value: homeBounce))
                    .frame(width: size, height: size)
                    .stableBarGlass(capsule: false)
                    .frame(width: width)
                    .contentShape(Rectangle())
            }
            .buttonStyle(BarControlButtonStyle())
            .accessibilityLabel("Home")
            .modifier(ChinControlEntrance(shown: isPresented, index: 2, from: 0))
        }
        // Where the bar's column stands: centred on the status bar's, its foot as
        // far from the bottom of the display as the home screen's. Measured from the
        // display's edges, not the safe area's, which the status bar's strip is not
        // part of.
        .padding(sideColumnIsLeading ? .leading : .trailing,
                 FlekTheme.sideBarCentreInset - width / 2)
        .padding(.bottom, FlekTheme.bottomBarScreenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: sideColumnIsLeading ? .bottomLeading : .bottomTrailing)
        .ignoresSafeArea()
        // Fading into the home screen's own column, which stands in the same
        // place, as the springboard comes through.
        .opacity(exiting ? 0 : 1)
        .allowsHitTesting(!exiting)
    }

    /// Tapping the background returns to the springboard: cards slide off to the
    /// left, buttons drop past the bottom edge, and the blur fades to reveal the
    /// home. The manager minimizes the app windows behind the overlay and removes
    /// it once the animation completes.
    private func exitToSpringboard() {
        guard !exiting else { return }
        // The chin's home button is one of the three ways in here, and it sits in a
        // row whose other two buttons answer to the haptics setting — so this does
        // too, rather than being the one control in the row that taps back when the
        // setting is off.
        MultitaskDockManager.buttonHaptic()
        withAnimation(.easeIn(duration: 0.3)) { exiting = true }
        dockManager.goToSpringboardFromSwitcher()
    }

    // MARK: - Card Scroll View (with iOS 17+ snapping)
    @ViewBuilder
    private var cardScrollView: some View {
        if #available(iOS 17.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                cardRow
                    // scrollTargetLayout sits directly on the HStack so it still
                    // finds the cards as snap targets; the dismiss catcher layers
                    // behind that, not between it and the stack.
                    .scrollTargetLayout()
                    .background(dismissTapCatcher)
            }
            // `.never` lets a flick carry across multiple cards with momentum and
            // then settle aligned (like the iOS App Switcher). The default
            // (`.automatic`, which acts like `.always` on a compact iPhone width)
            // limits each swipe to a single card, so a gentle or quick horizontal
            // swipe that didn't fully cross to the next card snapped back to the
            // current one — which read as the swipe "not registering".
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollClipDisabled()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                cardRow
                    .background(dismissTapCatcher)
            }
        }
    }

    /// Behind the cards and spanning the whole padded row — the side gutters and
    /// the gaps between cards. A horizontal ScrollView claims its full width for
    /// hit testing, so those regions never fall through to the backdrop's dismiss
    /// gesture below the ScrollView; this catches them from inside the scroll
    /// content instead. It sits BEHIND the cards, so a tap on a card still reaches
    /// the card (front-most wins) and only a tap on genuinely empty row space
    /// lands here — local, deterministic, no ancestor gesture in sight.
    private var dismissTapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { exitToSpringboard() }
    }

    private var cardRow: some View {
        HStack(alignment: .top, spacing: cardSpacing) {
            ForEach(Array(switcherItems.enumerated()), id: \.element.id) { pair in
                switcherCard(pair.element, index: pair.offset)
                .id(pair.element.id)
                // Graceful exit if the card is removed while still partly on-screen.
                .transition(.move(edge: .top).combined(with: .opacity))
                .scaleEffect(isPresented ? 1.0 : 0.85)
                .opacity(isPresented ? 1.0 : 0)
                // The cascade is capped rather than open-ended. At three
                // hundredths of a second per card and no ceiling, the wait before
                // the last card even begins grew with the number of apps open —
                // and a card is transparent until its turn comes, so it is neither
                // tappable nor a settled snap target for the row to align to. With
                // eight apps that was about a quarter of a second of switcher that
                // was plainly on screen and would not answer a swipe. Eighty
                // milliseconds is enough to read as a cascade and is the same
                // whether two apps are open or twenty.
                .animation(
                    .spring(response: 0.3, dampingFraction: 0.82)
                    .delay(min(Double(pair.offset) * 0.02, 0.08)),
                    value: isPresented
                )
            }
        }
        .padding(.horizontal, (dockManager.switcherScreenSize.width - cardWidth) / 2)
    }
}

/// The springboard picture behind the switcher, on the screen exactly where the
/// springboard itself is, whatever the stack it is drawn in makes of the safe area.
///
/// Positioned in the screen's own coordinates rather than centred in its stack.
/// On an iPhone Duo the status bar's column is all safe-area inset, and SwiftUI
/// laid this background out shifted by half of it: the picture stood 21pt left of
/// the screen and stopped that short of its right edge, the overlay's black showed
/// through, and the blur over the top smeared it into a dark band down that side.
///
/// A larger copy lies behind it, for the blur to find picture in past every edge
/// of the screen rather than black. The copy on top is the screen's size, so what
/// shows is the springboard at its own scale.
///
/// Each a fixed size and clipped to it: `scaledToFill` reports back what it covers,
/// which would otherwise have its say in the layout. A springboard captured in
/// landscape and drawn in portrait once came out 1698pt wide in an 820pt window and
/// dragged the card row 400pt off the left edge.
private struct SwitcherBackdropPicture: View {
    let image: UIImage
    let screen: CGSize

    /// How far past the screen's edges the copy behind reaches: more than the
    /// switcher's blur draws from.
    private static let overscan: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack {
                picture(width: screen.width + 2 * Self.overscan, height: screen.height + 2 * Self.overscan)
                picture(width: screen.width, height: screen.height)
            }
            .position(x: screen.width / 2 - origin.x, y: screen.height / 2 - origin.y)
        }
        // The screen's size in the layout, as the picture always was, so the
        // switcher lays out everything else as it did: the cards are centred in
        // what the side column leaves them. Only what is drawn moves.
        .frame(width: screen.width, height: screen.height)
        .ignoresSafeArea()
    }

    private func picture(width: CGFloat, height: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
    }
}

// MARK: - Customize Dropdown (menu-style, but with a slider)

/// Hosts a UIKit button so the Customize menu can be a genuine `UIMenu`: it needs
/// `UICustomViewMenuElement` to carry a live slider, which SwiftUI's `Menu` can't do.
/// `showsMenuAsPrimaryAction` keeps the interaction a single tap, and the menu is
/// rebuilt on each presentation so PID, PiP state and scale are always current.
/// Spans the card row so the menu is anchored to — and therefore centred on — the
/// card, while only the trailing icon area accepts touches. Without the width the
/// menu hangs off the card's right edge; without the narrowed hit area the app name
/// beside the icon would open the menu too.
final class WideAnchorMenuButton: UIButton {
    var touchableWidth: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && point.x >= bounds.width - touchableWidth
    }
}

/// The bar that appears while the speaker button is held, and fills as the
/// finger moves. Deliberately not a UISlider: nothing ever touches it directly,
/// it only reports what the gesture on the button is doing. No glyph on it
/// either — the button that raised it is already showing one.
@available(iOS 16.0, *)
final class VolumeSlideOverlay: UIView {
    static let trackWidth: CGFloat = 168
    private static let height: CGFloat = 36
    private static let inset: CGFloat = 14
    /// The track thickens once the drag is under way, the way Control Center's
    /// sliders swell under a finger.
    private static let restingTrackHeight: CGFloat = 8
    private static let activeTrackHeight: CGFloat = 11

    private let blurEffect = UIBlurEffect(style: .systemMaterialDark)
    private let blurView: UIVisualEffectView
    private let vibrancyView: UIVisualEffectView
    private let trackBackground = UIView()
    private let fill = UIView()

    private var trackHeight = VolumeSlideOverlay.restingTrackHeight
    private var volume: Float = 1

    init() {
        blurView = UIVisualEffectView(effect: blurEffect)
        vibrancyView = UIVisualEffectView(effect: UIVibrancyEffect(blurEffect: blurEffect, style: .fill))
        super.init(frame: CGRect(x: 0, y: 0, width: Self.trackWidth + Self.inset * 2, height: Self.height))

        // Material rather than a flat colour: a solid grey capsule is the one
        // thing that reads as not-iOS however well it is shaped. Same style the
        // switcher's own floating button uses.
        blurView.frame = bounds
        blurView.layer.cornerRadius = Self.height / 2
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)

        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        trackBackground.layer.cornerCurve = .continuous
        blurView.contentView.addSubview(trackBackground)

        // Vibrancy, so the fill sits inside the material and picks up what is
        // behind it, rather than looking painted on top of it.
        blurView.contentView.addSubview(vibrancyView)
        fill.backgroundColor = .white
        fill.layer.cornerCurve = .continuous
        vibrancyView.contentView.addSubview(fill)

        isAccessibilityElement = true
        accessibilityLabel = "lc.multitask.volume".loc
        applyLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        applyLayout()
        accessibilityValue = "\(Int((CGFloat(self.volume) * 100).rounded()))%"
    }

    /// Swells the track. Called inside the entrance animation, so it arrives at
    /// resting thickness and settles into the active one.
    func setDragging(_ dragging: Bool) {
        trackHeight = dragging ? Self.activeTrackHeight : Self.restingTrackHeight
        applyLayout()
    }

    private func applyLayout() {
        let trackRect = CGRect(x: Self.inset,
                               y: (Self.height - trackHeight) / 2,
                               width: Self.trackWidth,
                               height: trackHeight)
        trackBackground.frame = trackRect
        trackBackground.layer.cornerRadius = trackHeight / 2
        vibrancyView.frame = trackRect

        // Never a sliver: below its own thickness the fill stops being a bar and
        // starts looking like a rendering fault, so it bottoms out at a round
        // nub — and disappears entirely only at true silence.
        let width = volume <= 0 ? 0 : max(trackHeight, Self.trackWidth * CGFloat(volume))
        fill.frame = CGRect(x: 0, y: 0, width: width, height: trackHeight)
        fill.layer.cornerRadius = trackHeight / 2
    }
}

/// Turns a press on the speaker button into a volume drag, in one gesture: hold
/// to bring up the bar, keep moving to set the level, lift to leave it there.
///
/// A `UIMenu` carrying a slider would be less code, but it costs a second touch
/// — the menu takes the press, and the slider cannot be reached until the finger
/// has lifted and come back down. Owning the gesture is what makes hold-and-slide
/// a single motion.
@available(iOS 16.0, *)
final class VolumeSlideCoordinator: NSObject {
    let control: () -> LCGuestVolume?
    private weak var button: UIButton?
    private var overlay: VolumeSlideOverlay?
    private var startVolume: Float = 1
    private var startX: CGFloat = 0
    private var wasAtEnd = false
    private var shownIconStep = -1
    private weak var lockedScrollView: UIScrollView?

    init(control: @escaping () -> LCGuestVolume?) {
        self.control = control
    }

    /// Swaps the speaker glyph, crossfading when the drawing actually differs.
    /// A snapshot crossfade rather than iOS 17's symbol transitions: those are
    /// applied to the image view, which a button will overwrite from its own
    /// stored image on the next layout pass, and this has to look the same on
    /// every version the app supports.
    func applyIcon(volume: Float, to button: UIButton, animated: Bool) {
        let step = MuteToggleButton.iconStep(forVolume: volume)
        guard step != shownIconStep else { return }
        let firstShow = shownIconStep < 0
        shownIconStep = step
        let image = MuteToggleButton.icon(forStep: step)

        guard animated, !firstShow, !UIAccessibility.isReduceMotionEnabled else {
            button.setImage(image, for: .normal)
            return
        }
        // .allowUserInteraction matters: without it the drag under way stops
        // being tracked for the length of the fade.
        UIView.transition(with: button, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            button.setImage(image, for: .normal)
        }
    }

    func attach(to button: UIButton) {
        guard self.button !== button else { return }
        self.button = button

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.25
        button.addGestureRecognizer(press)

        // Quick tap toggles mute — and UIKit itself tells the two apart, rather
        // than a separate SwiftUI tap gesture racing the long press. require(toFail:)
        // holds the tap until the long press has failed, so a short press toggles
        // and a press held long enough to raise the volume bar never also toggles
        // on release. That was a real double-fire: a hesitant hold that never
        // moved used to both show the bar and flip the mute.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: press)
        button.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        guard let button = self.button, let audio = control() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        audio.toggleMute()
        applyIcon(volume: audio.volume, to: button, animated: true)
        button.accessibilityLabel = (audio.muted ? "lc.multitask.unmute" : "lc.multitask.mute").loc
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let button = self.button, let audio = control() else { return }
        switch gesture.state {
        case .began:
            // The finger is going to lift on this button, and that lift must not
            // also read as a tap and toggle the mute the drag just set.
            button.cancelTracking(with: nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            startVolume = audio.volume
            startX = gesture.location(in: button.window).x
            wasAtEnd = startVolume <= 0 || startVolume >= 1
            presentOverlay(from: button, volume: audio.volume)
            // Unlock first: if a previous gesture ended without its .ended ever
            // arriving, the switcher would be left unable to scroll, which is a
            // far worse failure than a stray drag.
            unlockScrollView()
            lockEnclosingScrollView(from: button)
        case .changed:
            guard let overlay = self.overlay else { return }
            // Relative to where the press started, not to where the finger is:
            // the finger comes down on the button rather than on the bar, so an
            // absolute mapping would jump the level on the first pixel of travel.
            let travel = gesture.location(in: button.window).x - startX
            let volume = min(max(startVolume + Float(travel / VolumeSlideOverlay.trackWidth), 0), 1)
            audio.volume = volume
            overlay.setVolume(volume)
            applyIcon(volume: volume, to: button, animated: true)

            // A tap on arriving at either end, once per arrival — every native
            // slider does this, and travelling into a dead stop in silence is
            // the part that feels wrong without it.
            let atEnd = volume <= 0 || volume >= 1
            if atEnd && !wasAtEnd {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
            }
            wasAtEnd = atEnd
        case .ended, .cancelled, .failed:
            dismissOverlay()
            unlockScrollView()
        default:
            break
        }
    }

    private func presentOverlay(from button: UIButton, volume: Float) {
        guard let window = button.window else { return }
        // Reuse whatever is still fading out from the last press, so a quick
        // second press does not stack a new bar on top of the old one.
        let overlay = self.overlay ?? VolumeSlideOverlay()
        overlay.layer.removeAllAnimations()
        overlay.transform = .identity
        overlay.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        overlay.setDragging(false)
        overlay.setVolume(volume)

        let anchor = button.convert(button.bounds, to: window)
        // Centred on the screen, sitting just above the button. Screen-centred,
        // not card-centred: the card's centre had to be guessed by walking the
        // view tree or measured and threaded through, and either way it landed
        // off often enough to be worth dropping. The window's centre needs
        // nothing, is the same on every device and orientation, and — since the
        // bar is a floating HUD, not part of the card — reads as belonging to the
        // screen anyway. It still springs from the button (the growth anchor
        // below uses the button's real position), so it does not feel detached.
        var origin = CGPoint(x: window.bounds.midX - overlay.bounds.width / 2,
                             y: anchor.minY - overlay.bounds.height - 10)
        origin.x = min(max(origin.x, 12), window.bounds.width - overlay.bounds.width - 12)
        // Below the button instead, if there is no room above it.
        let above = origin.y >= window.safeAreaInsets.top + 8
        if !above {
            origin.y = anchor.maxY + 10
        }
        overlay.frame.origin = origin

        // Grows out of the button that raised it rather than out of its own
        // middle: anchored at the point nearest the button, on the edge facing it.
        let anchorX = min(max((anchor.midX - overlay.frame.minX) / overlay.bounds.width, 0), 1)
        setAnchorPoint(CGPoint(x: anchorX, y: above ? 1 : 0), for: overlay)

        if overlay.superview == nil {
            window.addSubview(overlay)
        }

        if UIAccessibility.isReduceMotionEnabled {
            overlay.alpha = 0
            overlay.setDragging(true)
            // Matches the spring branch below, which already allows interaction:
            // Reduce Motion should shorten the animation, not make the overlay deaf.
            UIView.animate(withDuration: 0.12, delay: 0, options: .allowUserInteraction) { overlay.alpha = 1 }
        } else {
            overlay.alpha = 0
            overlay.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                overlay.alpha = 1
                overlay.transform = .identity
                overlay.setDragging(true)
            }
        }
        self.overlay = overlay
    }

    private func dismissOverlay() {
        guard let overlay = self.overlay else { return }
        // Held briefly before it goes, the way the system's own volume HUD
        // lingers. Fading the instant the finger lifts reads as the bar being
        // snatched away rather than finished with.
        UIView.animate(withDuration: 0.25, delay: 0.5,
                       options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]) {
            overlay.alpha = 0
            overlay.setDragging(false)
        } completion: { finished in
            // Not finished means a new press interrupted it and is now using it.
            guard finished else { return }
            overlay.removeFromSuperview()
            if self.overlay === overlay {
                self.overlay = nil
            }
        }
    }

    /// Moves the layer's anchor point without moving the view on screen.
    private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
        let newPoint = CGPoint(x: view.bounds.width * anchorPoint.x, y: view.bounds.height * anchorPoint.y)
        let oldPoint = CGPoint(x: view.bounds.width * view.layer.anchorPoint.x, y: view.bounds.height * view.layer.anchorPoint.y)
        var position = view.layer.position
        position.x += newPoint.x - oldPoint.x
        position.y += newPoint.y - oldPoint.y
        view.layer.position = position
        view.layer.anchorPoint = anchorPoint
    }

    // The switcher scrolls horizontally, and so does this drag. Without this the
    // cards slide away under the finger while the level is being set.
    private func lockEnclosingScrollView(from view: UIView) {
        var candidate: UIView? = view
        while let current = candidate {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
                lockedScrollView = scrollView
                return
            }
            candidate = current.superview
        }
    }

    private func unlockScrollView() {
        lockedScrollView?.isScrollEnabled = true
        lockedScrollView = nil
    }

    deinit {
        lockedScrollView?.isScrollEnabled = true
    }
}

/// Volume control for one guest, as a speaker button: tap to mute, or hold and
/// slide to set the level without lifting a finger.
///
/// Its own control rather than a menu item because silencing a window is
/// something you reach for while listening to another one, and a two-tap trip
/// through a menu is a poor fit for that.
@available(iOS 16.0, *)
struct MuteToggleButton: UIViewRepresentable {
    let control: () -> LCGuestVolume?

    /// Volume controls standing in for the internal pages, which have no guest
    /// process behind them. They post to container ids nothing is listening on,
    /// so the button, the bar and the glyph all behave while no audio anywhere
    /// changes — which is the only way to try this UI on a simulator, where a
    /// real guest cannot run at all.
    private static var placeholderControls: [String: LCGuestVolume] = [:]

    private static func placeholderControl(for appUUID: String) -> LCGuestVolume {
        if let existing = placeholderControls[appUUID] { return existing }
        let placeholder: LCGuestVolume = LCGuestVolume(dataUUID: "ui-placeholder-\(appUUID)")
        placeholderControls[appUUID] = placeholder
        return placeholder
    }

    static func control(for app: DockAppModel) -> LCGuestVolume? {
        if let audio = (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?.appSceneVC.audio {
            return audio
        }
        // Only for the internal pages. A guest window whose controller is
        // momentarily missing must come back nil rather than quietly send the
        // user's changes to a placeholder.
        return app.isInternalPage ? placeholderControl(for: app.appUUID) : nil
    }

    init(app: DockAppModel) {
        control = { MuteToggleButton.control(for: app) }
    }

    /// For the Xcode preview, which has no running guest to reach through.
    init(control: @escaping () -> LCGuestVolume?) {
        self.control = control
    }

    /// How many waves the speaker is drawn with, silence included. Kept as a step
    /// rather than a level because that is all the glyph can show — and knowing
    /// when it has actually changed is what keeps the animation off the other
    /// ninety-nine drag events that change nothing on screen.
    static func iconStep(forVolume volume: Float) -> Int {
        switch volume {
        case ..<0.01: return 0
        case ..<0.34: return 1
        case ..<0.67: return 2
        default: return 3
        }
    }

    static func icon(forStep step: Int) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if step == 0 {
            return UIImage(systemName: "speaker.slash.fill", withConfiguration: configuration)
        }
        // One symbol at a variable value, not three different ones: the waves are
        // the same drawing at every step, so going up or down changes only how
        // many of them are lit — which is what makes a crossfade read as waves
        // appearing rather than as two unrelated icons swapping.
        return UIImage(systemName: "speaker.wave.3.fill",
                       variableValue: Double(step) / 3.0,
                       configuration: configuration)
    }

    static func icon(forVolume volume: Float) -> UIImage? {
        icon(forStep: iconStep(forVolume: volume))
    }

    func makeCoordinator() -> VolumeSlideCoordinator {
        VolumeSlideCoordinator(control: control)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = UIColor.white.withAlphaComponent(0.9)
        button.overrideUserInterfaceStyle = CustomizeMenuButton.windowInterfaceStyle
        button.isUserInteractionEnabled = true
        // Both gestures — quick-tap mute and press-and-slide volume — are the
        // coordinator's, added here. Handling the tap in UIKit is safe now that
        // background-dismiss is hit-test-ordered: the tap lands on this button and
        // no ancestor gesture competes for it.
        context.coordinator.attach(to: button)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.attach(to: button)
        let volume = context.coordinator.control()?.volume ?? 1.0
        context.coordinator.applyIcon(volume: volume, to: button, animated: true)
        button.accessibilityLabel = (volume <= 0 ? "lc.multitask.unmute" : "lc.multitask.mute").loc
    }
}

#if DEBUG
/// Stand-in for a switcher card, so the button and its bar can be exercised in
/// the canvas without a device or a running guest. The control it drives posts
/// its notifications into the void — nothing is listening on "preview".
@available(iOS 16.0, *)
private struct VolumeSlidePreviewCard: View {
    private let audio = LCGuestVolume(dataUUID: "preview")
    private let cardWidth: CGFloat = 240

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Hold the speaker, then slide")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 100)

                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 32, height: 32)
                    Text("Guest App")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 8)
                    MuteToggleButton(control: { audio })
                        .frame(width: 32, height: 32)
                        .padding(.trailing, 44)
                }
                .frame(width: cardWidth - 40)
                .padding(.horizontal, 20)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: cardWidth, height: 300)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Every level the bar can show, for judging the fill's shape at the extremes
/// without having to drag to them.
@available(iOS 16.0, *)
private func volumeSlideLevelsPreview() -> UIView {
    let container = UIView()
    container.backgroundColor = UIColor(white: 0.08, alpha: 1)
    var y: CGFloat = 24
    for level in [Float(0), 0.02, 0.25, 0.5, 0.85, 1] {
        let overlay = VolumeSlideOverlay()
        overlay.setVolume(level)
        overlay.setDragging(true)
        overlay.frame.origin = CGPoint(x: 24, y: y)
        container.addSubview(overlay)
        y += overlay.bounds.height + 12
    }
    return container
}

// iOS 17 on the previews themselves — the macro is not available before it,
// which also satisfies the 16+ availability of everything they show.
@available(iOS 17.0, *)
#Preview("Volume bar — card") {
    VolumeSlidePreviewCard()
}

@available(iOS 17.0, *)
#Preview("Volume bar — levels") {
    volumeSlideLevelsPreview()
}
#endif

@available(iOS 16.0, *)
struct CustomizeMenuButton: UIViewRepresentable {
    let app: DockAppModel

    func makeUIView(context: Context) -> UIButton {
        let button = WideAnchorMenuButton(type: .system)
        button.setImage(UIImage(systemName: "slider.horizontal.3",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                        for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.9)
        button.contentHorizontalAlignment = .trailing
        button.showsMenuAsPrimaryAction = true
        // A menu renders in its presenting view's trait environment, and the switcher
        // overlay forces .dark over an opaque black backdrop. Glass is adaptive: with
        // near-black behind it and a dark appearance it has almost nothing to frost,
        // so it reads as clear where the springboard's menu reads as frosted. Opt this
        // button back into the window's real appearance so the two match.
        button.overrideUserInterfaceStyle = Self.windowInterfaceStyle
        updateMenu(on: button)
        return button
    }

    /// The appearance the app is actually running in, read from the window rather
    /// than the surrounding view tree, which the overlay has overridden.
    static var windowInterfaceStyle: UIUserInterfaceStyle {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow?.traitCollection.userInterfaceStyle ?? .unspecified
    }

    func updateUIView(_ button: UIButton, context: Context) {
        updateMenu(on: button)
    }

    private func updateMenu(on button: UIButton) {
        let app = self.app
        // Deferred so the menu reflects state at the moment it opens, not at layout.
        button.menu = UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { completion in
                guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else {
                    // Internal pages have no guest process, so every item in this
                    // menu is about something that does not exist. The button is
                    // still shown, and says as much when opened, rather than
                    // presenting an empty menu that looks broken.
                    completion([UIAction(title: "lc.multitask.noGuest".loc,
                                         attributes: .disabled) { _ in }])
                    return
                }
                completion(vc.customizeMenu().children)
            }
        ])
    }
}

// MARK: - Split cards

/// A switcher card that is one half of a split's card: where the other half is,
/// and the fold between the two as the screen shows it.
@available(iOS 16.0, *)
struct SwitcherCardFold {
    /// The side of this half the other half is on.
    var edge: HorizontalEdge
    /// This half's share of the black between the two pictures.
    var gap: CGFloat
    /// The corners the fold rounds the picture off by on its side.
    var cornerRadius: CGFloat

    /// The half's name and controls stand over its picture, not over its share
    /// of the gap.
    var headerAlignment: HorizontalAlignment { edge == .trailing ? .leading : .trailing }
}

/// One half of a split's card: a lone card's corners on its outer side, the
/// fold's smaller ones on the side the other half is on.
@available(iOS 16.0, *)
struct SwitcherHalfShape: Shape {
    var outerRadius: CGFloat
    var foldRadius: CGFloat
    var foldEdge: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        // Each pair of corners from a rounded rectangle of its own, carried past the
        // far side so its corners there are out of the way, and the two intersected:
        // both keep the continuous curve of a lone card's corners.
        let towardsFold: CGFloat = foldEdge == .trailing ? 1 : -1
        let outer = Path(roundedRect: rect.union(rect.offsetBy(dx: towardsFold * outerRadius * 2, dy: 0)),
                         cornerRadius: outerRadius, style: .continuous)
        let fold = Path(roundedRect: rect.union(rect.offsetBy(dx: -towardsFold * foldRadius * 2, dy: 0)),
                        cornerRadius: foldRadius, style: .continuous)
        return Path(outer.cgPath.intersection(fold.cgPath))
    }
}

/// The black behind the fold's side of a half: its share of the gap, and the
/// corners the fold rounds off its picture, which on screen are the divider's.
@available(iOS 16.0, *)
struct SwitcherFoldBacking: Shape {
    var gap: CGFloat
    var cornerRadius: CGFloat
    var edge: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        let corners = gap + cornerRadius
        let bandX = edge == .trailing ? rect.maxX - gap : rect.minX
        let cornersX = edge == .trailing ? rect.maxX - corners : rect.minX
        var path = Path()
        path.addRect(CGRect(x: bandX, y: rect.minY, width: gap, height: rect.height))
        path.addRect(CGRect(x: cornersX, y: rect.minY, width: corners, height: cornerRadius))
        path.addRect(CGRect(x: cornersX, y: rect.maxY - cornerRadius, width: corners, height: cornerRadius))
        return path
    }
}

@available(iOS 16.0, *)
extension View {
    /// Clips a switcher card's picture to the card's corners. As one half of a
    /// split's card, only the outer ones: on the fold's side it has the fold's own
    /// corners and its share of the black between the two, as the screen has them.
    @ViewBuilder
    func switcherCardClip(cornerRadius: CGFloat, fold: SwitcherCardFold?) -> some View {
        if let fold {
            clipShape(SwitcherHalfShape(outerRadius: cornerRadius, foldRadius: fold.cornerRadius,
                                        foldEdge: fold.edge))
                .padding(fold.edge == .trailing ? Edge.Set.trailing : Edge.Set.leading, fold.gap)
                .background(SwitcherFoldBacking(gap: fold.gap, cornerRadius: fold.cornerRadius,
                                                edge: fold.edge).fill(Color.black))
        } else {
            clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A switcher card's shadow. Under one half of a split's card it stops at the
    /// fold, where the other half carries on: cast over that half, it darkened the
    /// edge beside the fold, and the two read as two cards again.
    @ViewBuilder
    func switcherCardShadow(fold: SwitcherCardFold?) -> some View {
        if let fold {
            shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                .mask {
                    Rectangle().padding(fold.edge == .trailing
                        ? EdgeInsets(top: -40, leading: -40, bottom: -40, trailing: 0)
                        : EdgeInsets(top: -40, leading: 0, bottom: -40, trailing: -40))
                }
        } else {
            shadow(color: .black.opacity(0.5), radius: 10, y: 5)
        }
    }
}

// MARK: - App Switcher Card (with swipe-up-to-close)
@available(iOS 16.0, *)
struct AppSwitcherCard: View {
    let app: DockAppModel
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cornerRadius: CGFloat

    let cardIndex: Int
    /// Whether the app's picture is the shape of this card. Where it isn't, the
    /// card shows the app's icon, as before there is a picture at all.
    var showsPicture: Bool = true
    /// Where the other half is, for a card that is one half of a split's.
    var fold: SwitcherCardFold? = nil

    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    /// True only while a drag is live. SwiftUI clears a `@GestureState` when the
    /// gesture ends *or* is cancelled, which a plain `@State` gives no way to
    /// notice — and cancellation is the ordinary case here, since the row's
    /// scroll view takes the touch over whenever it decides the movement is
    /// sideways. See the reset below.
    @GestureState private var isDragActive = false
    @State private var isVerticalDrag = false
    @State private var hasPassedThreshold = false

    /// UIScrollView's overscroll curve: linear at first, then asymptotic, so the
    /// card keeps answering the finger however far it is pulled without ever
    /// travelling far enough to look like it might come off.
    private static func rubberBand(_ offset: CGFloat, limit: CGFloat = 120,
                                   coefficient: CGFloat = 0.55) -> CGFloat {
        guard offset > 0 else { return offset }
        return (1 - (1 / (offset / limit * coefficient + 1))) * limit
    }
    @State private var closeAllOffset: CGFloat = 0
    /// Where this card sits, so the window it opens can come out of it. Measured
    /// from the layout rather than from what is drawn: a card is scaled as it
    /// arrives and offset while it is dragged, and the window should come out of
    /// where the card sits rather than where it happens to be mid-gesture.
    @State private var cardFrame: CGRect = .zero

    /// Read off the size the card was given rather than from the device, so the
    /// content can never disagree with the frame holding it. iPhone's card is
    /// always the taller way round; iPad's follows the screen and turns with it.
    private var isPortraitCard: Bool { cardHeight > cardWidth }

    /// Whether this card shows the header's mute + Customize controls.
    ///
    /// A real guest window always does. The internal Settings / Installer pages
    /// have no guest process behind them, so their controls are placeholders —
    /// there only to preview this UI in the simulator, where a real multitask
    /// guest can't run. On a device build they are compiled out, so users never
    /// see a mute button that moves a level nothing hears or a Customize menu with
    /// nothing to customise.
    private var showsHeaderControls: Bool {
        if !app.isInternalPage { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private let dismissThreshold: CGFloat = -120

    var body: some View {
        VStack(alignment: fold?.headerAlignment ?? .center, spacing: 8) {
            // App icon + left-aligned name, with the Customize button inline on the
            // trailing edge. Row spans the card width with 10pt side margins: name
            // group sits 10pt from the left, the slider button 10pt from the right.
            HStack(spacing: 6) {
                if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "app.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 24))
                        .frame(width: 32, height: 32)
                }

                Text(app.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Space held for the two trailing buttons, both of which are laid
                // over this row rather than placed in it, so the name still
                // truncates before it reaches them. Only when the controls are
                // actually shown — otherwise the name gets the full width back.
                if showsHeaderControls {
                    Color.clear.frame(width: 76, height: 32)
                }
            }
            // Customize button, laid over the whole row rather than placed in it.
            // UIKit anchors a button's menu to that button's bounds, so a 32pt button
            // on the trailing edge put the menu against the card's right edge; a
            // row-wide source centres it on the card. Only its trailing icon area
            // takes touches, so the name beside it stays untappable. Guest apps only:
            // internal Settings / Installer pages have no guest process, so nothing
            // in the menu would apply to them.
            .overlay {
                // Just the button. It hit-tests as an ordinary view, so a tap that
                // lands on it opens its menu (showsMenuAsPrimaryAction) and never
                // reaches the backdrop's dismiss gesture below — no defensive
                // tap-swallowing needed now that dismissal is hit-test-ordered
                // rather than an ancestor gesture racing this one.
                if showsHeaderControls {
                    CustomizeMenuButton(app: app)
                }
            }
            // Above the Customize button, not beneath it. That button is a
            // row-wide view that narrows its own touch area with point(inside:),
            // and SwiftUI does not necessarily consult that when it decides which
            // view a touch belongs to — on iOS 17.4 it hands the whole row to the
            // menu, so a mute button sitting under it never sees a tap. Being the
            // topmost view at that point settles it at both layers.
            .overlay(alignment: .trailing) {
                // Padding, not an offset: an offset moves what is drawn while the
                // hosted button stays where it was laid out, which put this
                // button's touch target 44pt to the right of its own icon — over
                // the Customize button. Padding moves the view itself.
                //
                // The tap goes on before the padding so the touch target is the
                // 32pt button and not the 76pt block: the padding has no gesture
                // of its own, so taps in it fall through to the Customize button
                // underneath, which is where they belong.
                if showsHeaderControls {
                    MuteToggleButton(app: app)
                        .frame(width: 32, height: 32)
                        .padding(.trailing, 44)
                }
            }
            // Inset the row 20pt on each side so the name (left) and the customize
            // button (right) sit just inside the card's edges.
            .frame(width: cardWidth - 40)
            .padding(.horizontal, 20)
            
            // Card with snapshot
            ZStack {
                if showsPicture, let snapshotImage = dockManager.appSnapshotImages[app.appUUID] {
                    // Frozen bitmap, filling the card. Turned upright for a portrait
                    // card and left alone for a landscape one, so either way it arrives
                    // at roughly the card's own aspect and fill crops only a sliver —
                    // where fitting would leave black bars wherever it was trimmed.
                    //
                    // Turned with a rotationEffect rather than by re-tagging the image's
                    // orientation. Re-tagging swaps the image's intrinsic size, and the
                    // row is laid out from that before any frame constrains it — so a
                    // turned card widened the HStack and slid itself off the screen. A
                    // rotationEffect draws the turn without the layout ever knowing:
                    // the inner frame is the card's shape before the quarter turn, the
                    // outer one is what the row sees, and it is the card's size either
                    // way round.
                    let turn = dockManager.cardSnapshotRotation(for: app.appUUID,
                                                                portraitCard: isPortraitCard)
                    Image(uiImage: snapshotImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: turn == 0 ? cardWidth : cardHeight,
                               height: turn == 0 ? cardHeight : cardWidth)
                        .clipped()
                        .rotationEffect(.radians(Double(turn)))
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()
                } else if showsPicture, let snapshotView = dockManager.appSnapshotViews[app.appUUID] {
                    SnapshotViewRepresentable(
                        snapshotView: snapshotView,
                        naturalSize: dockManager.appSnapshotSizes[app.appUUID] ?? .zero,
                        rotation: dockManager.cardSnapshotRotation(for: app.appUUID,
                                                                   portraitCard: isPortraitCard))
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()
                } else {
                    // Placeholder with blurred app icon
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay {
                            VStack(spacing: 12) {
                                if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                                    Image(uiImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                Text(app.appName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                }
            }
            .switcherCardClip(cornerRadius: cornerRadius, fold: fold)
            .switcherCardShadow(fold: fold)
            // Opening the app hangs off the card itself, not off the whole
            // column. It used to include the header row, which is where both
            // controls live: SwiftUI resolves its own gestures before it reaches
            // a hosted UIKit button, so on iOS 17.4 a tap meant for the speaker
            // opened the app instead. Only a press long enough to fail this
            // gesture — the volume drag — ever got through.
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { cardFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { cardFrame = $0 }
                }
            )
            // Told to the dock too: an app kept beside another comes out of its own
            // card when the other's is pressed (see `restoreSuspendedSplit`).
            .onChange(of: cardFrame) { dockManager.switcherCardFrames[app.appUUID] = $0 }
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                // Out of the card rather than out of nowhere: it is already
                // showing the app, at the size and place the user just pressed.
                // With the app beside it too, if the two were side by side.
                dockManager.openFromSwitcherCard(
                    app.appUUID,
                    fromRect: cardFrame == .zero ? nil : cardFrame,
                    fromRectRadius: cornerRadius
                )
            }
        }
        .offset(y: dragOffset + closeAllOffset)
        .simultaneousGesture(
            // Twenty points, and not less. This gesture runs alongside the card
            // row's horizontal scrolling, and the distance is what decides which
            // of the two claims a touch: dropped to ten, this one won first and
            // the row could not be scrolled at all. The direction test below
            // sorts a vertical drag from a horizontal one only once this has
            // already taken the touch, so it cannot stand in for the distance.
            DragGesture(minimumDistance: 20)
                .updating($isDragActive) { _, state, _ in state = true }
                .onChanged { value in
                    // A card already flying off does not take another drag.
                    guard !isDismissing else { return }
                    let h = value.translation.height
                    let w = value.translation.width
                    
                    // Determine direction on first significant movement
                    if !isVerticalDrag && abs(h) > 20 && abs(h) > abs(w) * 1.5 {
                        isVerticalDrag = true
                    }
                    
                    if isVerticalDrag && h >= 0 {
                        // Down is not a dismiss direction, but refusing to move at
                        // all is what makes a card feel stuck to the screen. It
                        // follows with resistance instead, the way a scroll view
                        // does past its edge, and springs back on release.
                        dragOffset = Self.rubberBand(h)
                        if hasPassedThreshold {
                            hasPassedThreshold = false
                        }
                    } else if isVerticalDrag {
                        dragOffset = h
                        
                        // Haptic feedback when crossing the dismiss threshold
                        let pastThreshold = h < dismissThreshold
                        if pastThreshold && !hasPassedThreshold {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            hasPassedThreshold = true
                        } else if !pastThreshold && hasPassedThreshold {
                            UISelectionFeedbackGenerator().selectionChanged()
                            hasPassedThreshold = false
                        }
                    }
                }
                .onEnded { value in
                    guard !isDismissing else { return }
                    let velocity = value.velocity.height
                    let translation = value.translation.height
                    
                    // Dismiss based on distance OR velocity (inertia):
                    // - Dragged past threshold, OR
                    // - Fast upward flick (velocity < -800), OR
                    // - Predicted end position flies well past threshold
                    let shouldDismiss = isVerticalDrag && (
                        translation < dismissThreshold ||
                        velocity < -800 ||
                        value.predictedEndTranslation.height < dismissThreshold * 2
                    )
                    
                    if shouldDismiss {
                        isDismissing = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        
                        // Spring with initial velocity for smooth momentum handoff from gesture
                        let screenH = dockManager.switcherScreenSize.height
                        let totalChange = -screenH - dragOffset // negative (going further up)
                        // Normalize gesture velocity to proportion of remaining distance per second
                        let springVelocity = totalChange != 0 ? velocity / totalChange : 0
                        
                        // Fling the card off-screen with momentum handoff from the gesture.
                        withAnimation(.interpolatingSpring(stiffness: 350, damping: 38, initialVelocity: springVelocity)) {
                            dragOffset = -screenH
                        }
                        // As soon as the card has cleared the screen, start the real
                        // (async) teardown AND remove the card from the switcher list in
                        // one animated step. The remaining cards slide in to fill the gap
                        // on this fixed, short schedule instead of waiting on asynchronous
                        // app termination — so the reflow is both smooth and immediate.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            dockManager.beginAppTeardown(uuid: app.appUUID)
                            dockManager.removeRunningApp(app.appUUID)
                        }
                    } else {
                        // Snap back
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                    isVerticalDrag = false
                    hasPassedThreshold = false
                }
        )
        .onChange(of: isDragActive) { active in
            guard !active else { return }
            // The only place that runs whichever way the drag finished. SwiftUI
            // calls onEnded when a gesture ends and not when it is cancelled, and
            // the scroll view cancels this one every time it decides the movement
            // was sideways — so the flags below were being left set by the drag
            // that got interrupted. isVerticalDrag surviving is the worst of it:
            // the next touch skips the direction test entirely and is tracked as a
            // dismiss however horizontal it was, which is the swipe that does not
            // scroll and the card that lifts when the row should have moved.
            isVerticalDrag = false
            hasPassedThreshold = false
            // Left where the finger abandoned it otherwise.
            guard !isDismissing, dragOffset != 0 else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                dragOffset = 0
            }
        }
        .onChange(of: dockManager.isClosingAll) { closing in
            if closing {
                withAnimation(.easeIn(duration: 0.3).delay(Double(cardIndex) * 0.05)) {
                    closeAllOffset = -dockManager.switcherScreenSize.height
                }
            } else if closeAllOffset != 0 {
                // Closing all clears the flag once the sweep is done, but it only
                // removes the internal pages from the list itself — a window-backed
                // app leaves on its own schedule and its card can still be mounted
                // when the flag drops. Sent off-screen and never brought back, such
                // a card is present, untouchable and invisible. It comes back.
                withAnimation(.easeOut(duration: 0.25)) {
                    closeAllOffset = 0
                }
            }
        }
    }
}

// MARK: - Multitask Home Icons (shown on home screen when dock is hidden)
@available(iOS 16.0, *)
struct MultitaskHomeIcons: View {
    @ObservedObject var dockManager = MultitaskDockManager.shared
    let darkModeIcon: Bool
    var iconSize: CGFloat = FlekTheme.bottomBarAppIconSize

    /// One place in the dock: an app, or two side by side, which share one.
    private enum DockItem: Identifiable {
        case single(DockAppModel)
        case split(left: DockAppModel, right: DockAppModel)

        var id: String {
            switch self {
            case .single(let app): return app.appUUID
            case .split(let left, let right): return "split:\(left.appUUID)|\(right.appUUID)"
            }
        }
    }

    /// The most recent places, oldest first. Two side by side, on the way home
    /// from the screen or kept from going home, share one where the more recent of
    /// them would be: they come back together, and they are shown that way.
    private var dockItems: [DockItem] {
        let apps = dockManager.apps
        let count = MultitaskDockManager.homeDockIconCount
        guard let pair = dockManager.splitPair ?? dockManager.splitSuspended,
              let leftID = pair.left, let rightID = pair.right,
              let left = apps.first(where: { $0.appUUID == leftID }),
              let right = apps.first(where: { $0.appUUID == rightID }),
              let last = apps.lastIndex(where: { pair.contains($0.appUUID) }) else {
            return apps.suffix(count).map { .single($0) }
        }
        var items: [DockItem] = []
        for (index, app) in apps.enumerated() {
            if !pair.contains(app.appUUID) {
                items.append(.single(app))
            } else if index == last {
                items.append(.split(left: left, right: right))
            }
        }
        return Array(items.suffix(count))
    }

    var body: some View {
        ForEach(dockItems) { item in
            switch item {
            case .single(let app):
                MultitaskHomeIcon(app: app, iconSize: iconSize)
            case .split(let left, let right):
                MultitaskHomeSplitTile(left: left, right: right, iconSize: iconSize)
            }
        }
    }
}

/// Two apps side by side in one place in the home dock: each app's icon at half
/// size in one tile, the left app on the left, the way a folder holds its apps.
/// Pressed, the two come back side by side, the one used last in use; on the way
/// home each window flies into its own icon here.
@available(iOS 16.0, *)
private struct MultitaskHomeSplitTile: View {
    let left: DockAppModel
    let right: DockAppModel
    let iconSize: CGFloat
    @ObservedObject private var dockManager = MultitaskDockManager.shared

    private var inset: CGFloat { iconSize * 0.1 }
    private var gap: CGFloat { iconSize * 0.06 }
    private var miniSize: CGFloat { (iconSize - inset * 2 - gap) / 2 }

    var body: some View {
        Button {
            MultitaskDockManager.buttonHaptic()
            // The one used last, out of its own icon here; the other comes back
            // beside it (see `restoreSuspendedSplit`).
            let latest = dockManager.apps.last(where: {
                $0.appUUID == left.appUUID || $0.appUUID == right.appUUID
            }) ?? right
            let _ = dockManager.bringMultitaskViewToFront(
                uuid: latest.appUUID,
                fromIcon: latest.springboardItemID.flatMap { dockManager.homeDockIconFrames[$0] }
            )
        } label: {
            HStack(spacing: gap) {
                MultitaskHomeMiniIcon(app: left, size: miniSize)
                MultitaskHomeMiniIcon(app: right, size: miniSize)
            }
            .frame(width: iconSize, height: iconSize)
            .background(
                RoundedRectangle(cornerRadius: MultitaskHomeIcon.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
            .contentShape(RoundedRectangle(cornerRadius: MultitaskHomeIcon.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(left.appName) and \(right.appName)")
    }
}

/// One app's icon in a split tile. Like a dock icon of its own, it publishes where
/// it is, for the app's window to fly into on the way home and to open out of, and
/// stands aside while the window is in the air.
@available(iOS 16.0, *)
private struct MultitaskHomeMiniIcon: View {
    let app: DockAppModel
    let size: CGFloat
    @ObservedObject private var dockManager = MultitaskDockManager.shared

    private var isStandingAside: Bool {
        app.springboardItemID.map { dockManager.homeDockIconsStandingAside.contains($0) } ?? false
    }

    var body: some View {
        Group {
            if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .opacity(isStandingAside ? 0 : 1)
        .animation(nil, value: isStandingAside)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { publishFrame(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { publishFrame($0) }
                    .onChange(of: dockManager.homeStatesBegun) { _ in
                        publishFrame(geometry.frame(in: .global))
                    }
            }
        )
    }

    private func publishFrame(_ frame: CGRect) {
        guard MultitaskDockManager.shared.isHomeState,
              let itemID = app.springboardItemID, frame.width > 1, frame.height > 1 else { return }
        MultitaskDockManager.shared.homeDockIconFrames[itemID] = frame
    }
}

/// One running app in the home dock. Beyond drawing itself it does two things for
/// the minimize animation: it publishes where it is, for the app's window to fly
/// into when it is put away and to open out of when this is pressed, and it stands
/// aside while the window is in the air, carrying it.
@available(iOS 16.0, *)
private struct MultitaskHomeIcon: View {
    let app: DockAppModel
    let iconSize: CGFloat

    /// The icon's own rounded corners, which the side column's pill keeps clear of
    /// its curved end.
    static let cornerRadius: CGFloat = 10

    @ObservedObject private var dockManager = MultitaskDockManager.shared

    /// A window is flying into this icon or out of it, and is drawn as the icon
    /// itself until it lands, so its place here stands empty.
    private var isStandingAside: Bool {
        app.springboardItemID.map { dockManager.homeDockIconsStandingAside.contains($0) } ?? false
    }

    var body: some View {
        Button {
            // Let go after carrying the app out: the end of that, not a press.
            if dockManager.splitAppButtonTapSuppressed {
                dockManager.splitAppButtonTapSuppressed = false
                return
            }
            MultitaskDockManager.buttonHaptic()
            // Out of this icon, the one pressed, even with the app's own on the
            // springboard page in view as well.
            let _ = dockManager.bringMultitaskViewToFront(
                uuid: app.appUUID,
                fromIcon: app.springboardItemID.flatMap { dockManager.homeDockIconFrames[$0] }
            )
        } label: {
            if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: iconSize, height: iconSize)
                    .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(Color.gray.opacity(0.3)))
            }
        }
        .buttonStyle(.plain)
        // Held and carried out: into Split View, on the side it is dropped on.
        .modifier(SplitLiftGesture(dockAppUUID: app.appUUID))
        // Gone and back in the same frame the flight hands over in, so neither
        // the window nor the icon shows twice.
        .opacity(isStandingAside ? 0 : 1)
        .animation(nil, value: isStandingAside)
        .background(
            GeometryReader { geometry in
                // Not withdrawn on disappear: the manager forgets the lot as the
                // home state ends, and nothing is published outside one, so a
                // dock on its way out cannot leave a position behind. Published
                // again as each home state begins, for a dock called back on its
                // way out, which has no appearance to publish on.
                Color.clear
                    .onAppear { publishFrame(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { publishFrame($0) }
                    .onChange(of: dockManager.homeStatesBegun) { _ in
                        publishFrame(geometry.frame(in: .global))
                    }
            }
        )
    }

    private func publishFrame(_ frame: CGRect) {
        guard MultitaskDockManager.shared.isHomeState,
              let itemID = app.springboardItemID, frame.width > 1, frame.height > 1 else { return }
        MultitaskDockManager.shared.homeDockIconFrames[itemID] = frame
    }
}

// MARK: - Multitask Home Dock Pill
/// The pill/circle shown at the bottom of the springboard when in multitask home state.
/// Observes the dock manager so it reactively switches between a capsule (when running
/// apps are present) and a circle (when only the switcher button remains).
@available(iOS 16.0, *)
struct MultitaskHomeDockPill: View {
    @ObservedObject private var dockManager = MultitaskDockManager.shared
    /// The split light, unless it was switched off (in its help, or in
    /// Personalization).
    @AppStorage(FlekDeckKeys.splitLightShown, store: LCUtils.appGroupUserDefault)
    private var showsSplitLight = true
    let darkModeIcon: Bool
    /// Which way the pill runs: along the bottom bar, or down the side column
    /// beside an iPhone Duo's vertical status bar.
    var axis: Axis = .horizontal

    private var hasApps: Bool { !dockManager.apps.isEmpty }
    /// Across the pill: its height along the bottom, its width down the side.
    private var thickness: CGFloat {
        axis == .horizontal ? FlekTheme.bottomBarControlSize : FlekTheme.sideBarWidth
    }
    private var iconSize: CGFloat {
        axis == .horizontal ? FlekTheme.bottomBarAppIconSize : FlekTheme.sideBarAppIconSize
    }
    private var glyphSize: CGFloat {
        axis == .horizontal ? FlekTheme.bottomBarGlyphSize : FlekTheme.sideBarGlyphSize
    }

    var body: some View {
        if hasApps {
            appsStack
                .modifier(DockPillBackground(isCircle: false))
                .background(
                    GeometryReader { geometry in
                        // Again as each home state begins, as the icons do.
                        Color.clear
                            .onAppear { publishPillFrame(geometry.frame(in: .global)) }
                            .onChange(of: geometry.frame(in: .global)) { publishPillFrame($0) }
                            .onChange(of: dockManager.homeStatesBegun) { _ in
                                publishPillFrame(geometry.frame(in: .global))
                            }
                    }
                )
        } else {
            switcherButton
                .frame(width: thickness, height: thickness)
                .modifier(DockPillBackground(isCircle: true))
        }
    }

    /// The running apps, then the switcher button: left to right along the bottom,
    /// top to bottom down the side, where the switcher's glyph is centred on the
    /// curve of the pill's lower end.
    ///
    /// The first icon down the side starts a corner radius short of the centre of
    /// the pill's upper end. Its corners then lie on that end's curve at the same
    /// distance its sides keep from the pill's sides. Started that distance from the
    /// top instead, as it first was, the square icon fits the round end at its
    /// middle only, and its corners all but touched the curve.
    @ViewBuilder
    private var appsStack: some View {
        if axis == .horizontal {
            HStack(spacing: 8) {
                MultitaskHomeIcons(darkModeIcon: darkModeIcon, iconSize: iconSize)
                switcherButton
                if showsSplitLight, let light = dockManager.splitLight {
                    // Tucked in beside the switcher's glyph, into the room its
                    // square leaves on the right, rather than a whole gap away.
                    HomeSplitLight(light: light, height: thickness)
                        .padding(.leading, -20)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: thickness)
            .animation(.easeInOut(duration: 0.25), value: dockManager.splitLight)
            // As each home state begins: the light is kept up as the window turns
            // or is resized, and here as the pill comes up.
            .onAppear { dockManager.refreshSplitLight() }
        } else {
            VStack(spacing: 8) {
                MultitaskHomeIcons(darkModeIcon: darkModeIcon, iconSize: iconSize)
                switcherButton
            }
            .padding(.top, thickness / 2 - MultitaskHomeIcon.cornerRadius)
            .frame(width: thickness)
        }
    }

    /// Reported for windows that belong in the dock but have no icon of their own
    /// in it — the dock holds only the four most recent apps, so a fifth still has
    /// somewhere to go.
    private func publishPillFrame(_ frame: CGRect) {
        guard MultitaskDockManager.shared.isHomeState, frame.width > 1, frame.height > 1 else { return }
        MultitaskDockManager.shared.homeDockPillFrame = frame
    }

    private var switcherButton: some View {
        Button {
            MultitaskDockManager.buttonHaptic()
            MultitaskDockManager.shared.showAppSwitcher()
        } label: {
            Image(systemName: FlekSymbol.appSwitcher)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.6))
                .frame(width: thickness, height: thickness)
        }
        .buttonStyle(.plain)
    }
}

/// The split light in the home screen's running-apps pill, right of the
/// switcher's glyph: green where an app held in the pill can be dragged out
/// into Split View, red where it cannot now. Tapped, it says what it means and
/// how Split View works (`toggleSplitHelp`). The dot is small; what takes the tap is a
/// strip the pill's height, beside the glyph and over nothing else.
@available(iOS 16.0, *)
private struct HomeSplitLight: View {
    @ObservedObject private var dockManager = MultitaskDockManager.shared
    let light: MultitaskDockManager.SplitLight
    let height: CGFloat
    @State private var frameInWindow: CGRect = .zero

    private static let diameter: CGFloat = 7
    private static let width: CGFloat = 20

    var body: some View {
        let color = light.isAvailable ? Color(uiColor: .systemGreen) : Color(uiColor: .systemRed)
        Button {
            dockManager.toggleSplitHelp(at: frameInWindow)
        } label: {
            Circle()
                .fill(color)
                .frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: color.opacity(0.6), radius: 2.5)
                .frame(width: Self.width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frameInWindow = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { frameInWindow = $0 }
            }
        )
        .accessibilityLabel("lc.flek.splitLight".loc)
        .accessibilityValue(light.title)
        .accessibilityHint("lc.flek.splitHelp.hint".loc)
    }
}

/// Applies either a capsule or circle glass/material background depending on iOS version.
@available(iOS 16.0, *)
private extension View {
    /// Stable Liquid Glass for the multitask bar controls — pins the glass tone
    /// (fixed dark, matching the white icons) so it never re-tints to the app
    /// content behind it, the same approach as the Spotlight search. Falls back
    /// to a flat translucent fill on older iOS, when Liquid Glass is disabled,
    /// or when the glass style is frosted.
    func stableBarGlass(capsule: Bool) -> some View {
        modifier(StableBarGlass(capsule: capsule))
    }
}

/// Whether the multitask controls take iOS's own look rather than FlekDeck's:
/// the system's Liquid Glass, which takes its tone from what is behind it and
/// answers a touch itself, with glyphs in the label colour of the app's own
/// appearance. Only on the iPhone Duo, where they stand in the status bar's
/// column beside iOS's own buttons, and only while Liquid Glass is in use: the
/// frosted style keeps FlekDeck's look.
private enum BarControlLook {
    static var isNative: Bool {
        guard #available(iOS 26.0, *), FlekDeviceModel.isDuo, SharedModel.isLiquidGlassEnabled else { return false }
        let style = LCUtils.appGroupUserDefault.string(forKey: FlekDeckKeys.glassStyle)
        return (style.flatMap(FlekGlassStyle.init(rawValue:)) ?? .liquid) == .liquid
    }

    /// The app's own appearance. The bar is held dark for FlekDeck's look, which
    /// would keep iOS's glass and the glyphs on it dark over a light page.
    @available(iOS 16.0, *)
    static var colorScheme: ColorScheme {
        let style = MultitaskDockManager.shared.keyWindow?.traitCollection.userInterfaceStyle
            ?? UIScreen.main.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }
}

private extension Color {
    /// A multitask control's glyph: white on FlekDeck's own dark glass, the label
    /// colour on iOS's (`BarControlLook`).
    static var barGlyph: Color { BarControlLook.isNative ? .primary : .white }
}

/// See `stableBarGlass(capsule:)`. A modifier, so that a change of glass style
/// reaches bars already on screen.
@available(iOS 16.0, *)
private struct StableBarGlass: ViewModifier {
    let capsule: Bool
    @AppStorage(FlekDeckKeys.glassStyle, store: LCUtils.appGroupUserDefault) private var glassStyle: FlekGlassStyle = .liquid

    // AnyView for the reason `DockPillBackground.body` gives: `glassEffect` is an
    // iOS 26 type, and an opaque Body would carry it to older runtimes.
    func body(content: Content) -> AnyView {
        if #available(iOS 26.0, *), BarControlLook.isNative {
            // iOS's own glass, as on the buttons beside it in the iPhone Duo's
            // status bar column, seen in the app's appearance rather than the
            // bar's: it goes light over a light page and dark over a dark one, and
            // answers a touch itself.
            let glass = capsule
                ? AnyView(content.glassEffect(.regular.interactive(), in: .capsule))
                : AnyView(content.glassEffect(.regular.interactive(), in: .circle))
            return AnyView(glass.environment(\.colorScheme, BarControlLook.colorScheme))
        }
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled, glassStyle == .liquid {
            return AnyView(content.background {
                StableLiquidGlass(isDark: true, tint: UIColor(white: 1.0, alpha: 0.03))
            })
        }
        if capsule {
            return AnyView(content.background(Capsule().fill(Color.white.opacity(0.15))))
        }
        return AnyView(content.background(Circle().fill(Color.white.opacity(0.15))))
    }
}

private struct DockPillBackground: ViewModifier {
    let isCircle: Bool
    @AppStorage(FlekDeckKeys.glassStyle, store: LCUtils.appGroupUserDefault) private var glassStyle: FlekGlassStyle = .liquid

    // Returns AnyView instead of `some View`. With an opaque return type the
    // inferred Body embeds the iOS 26-only type that `glassEffect` produces, and
    // the runtime has to resolve that type to render the modifier at all — an
    // `#available` check guards execution, not the type. On iOS 17.x the type is
    // absent from the system SwiftUI, so the metadata lookup fails and the Swift
    // runtime traps. Erasing pins Body to AnyView, which exists on every version
    // we support; the glass call is then only reached inside the guarded branch.
    func body(content: Content) -> AnyView {
        if #available(iOS 26.0, *), glassStyle == .liquid {
            if isCircle {
                return AnyView(content.glassEffect(in: .circle))
            }
            return AnyView(content.glassEffect(in: .capsule))
        }
        // Shares FlekFrostedSurface with the springboard search button — the two
        // sit side by side in the bottom bar and previously used different tints.
        if isCircle {
            return AnyView(content.background(FlekFrostedSurface(shape: Circle())))
        }
        return AnyView(content.background(FlekFrostedSurface(shape: Capsule())))
    }
}

// MARK: - Chin Control Entrance
/// Brings one of the switcher's chin controls in as the overlay opens: it rises
/// the last few points into the row and fades up, with the side buttons leaning
/// out from the middle and each one starting a beat after the last.
///
/// The stagger is what makes the row read as arriving rather than as being drawn
/// — the same left-to-right cascade iOS gives a toolbar it is presenting.
/// `from` is which way the control leans in: -1 leading, 0 straight up, 1
/// trailing.
@available(iOS 16.0, *)
struct ChinControlEntrance: ViewModifier {
    let shown: Bool
    let index: Int
    let from: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: shown ? 0 : from * 14, y: shown ? 0 : 18)
            .opacity(shown ? 1 : 0)
            // Bound to `shown` alone, so it plays on the way in and leaves the
            // exit — a single offset carrying the whole chin off the bottom —
            // to run undisturbed.
            .animation(.spring(response: 0.42, dampingFraction: 0.82)
                        .delay(Double(index) * 0.04),
                       value: shown)
    }
}

// MARK: - Bar Control Button Style
/// The press behaviour shared by every control in the bar and in the switcher's
/// chin: the glass and its glyph shrink together under the finger and spring
/// back on release, the way iOS's own glass controls answer a touch.
///
/// A `ButtonStyle` rather than a gesture, so the press state comes from the
/// button itself and survives a finger that slides off and back on. It scales
/// `configuration.label`, which is why each control puts its glass *inside* its
/// label — glass applied to the button outside the style would sit still while
/// the glyph shrank inside it.
@available(iOS 16.0, *)
/// A bar control that answers a tap and lets a swipe go by.
///
/// Deliberately not a `Button`. The three controls sit in the strip the bottom
/// swipe zone occupies when the bar is down, and the middle one — the switcher —
/// is directly under where that swipe starts: with a ~59pt flat region and 44pt
/// controls centred in it, its lower edge is some seven points off the bottom of
/// the screen, on the home indicator itself. A pull up from the bezel therefore
/// begins on that control and, having travelled the sixteen-odd points the swipe
/// asks for, is still well inside its 44pt height when the finger lifts — which a
/// button reads as a tap, and the switcher opens. That is the bottom swipe
/// apparently still working with the bar up, and only sometimes, because whether
/// it happens depends on exactly where the finger landed and how far it went.
///
/// `onPressGesture` is the trade the switcher cards already make: the touch is
/// given up the moment it travels far enough to be a swipe rather than a press. A
/// tap behaves as it always did — the press look below is `BarControlButtonStyle`'s,
/// which the switcher overlay's own controls still use.
@available(iOS 16.0, *)
private struct BarControlButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        // Where the controls wear iOS's glass, the glass answers the press itself.
        let showsPress = isPressed && !BarControlLook.isNative
        return label()
            .scaleEffect(showsPress ? 0.92 : 1)
            .opacity(showsPress ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
            .contentShape(Rectangle())
            .onPressGesture(onPress: { isPressed = true },
                            onCancel: { isPressed = false },
                            onRelease: { _ in
                                isPressed = false
                                action()
                            })
            // A plain view carries none of what a button gives VoiceOver, so what
            // it needs to stay one control is put back by hand — including being a
            // single element, which is what lets the caller's label land on it
            // rather than on the icon and name inside the middle one.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

struct BarControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Where the controls wear iOS's glass, the glass answers the press itself.
        let showsPress = configuration.isPressed && !BarControlLook.isNative
        return configuration.label
            .scaleEffect(showsPress ? 0.92 : 1)
            .opacity(showsPress ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

// MARK: - Symbol Bounce
/// Bounces an SF Symbol each time `value` changes, as iOS bounces its own
/// symbols to acknowledge a button whose effect is elsewhere on screen.
///
/// Erased to AnyView — see `DockPillBackground.body` for why: symbol effects are
/// an iOS 17 type and must not reach an iOS 16 runtime through this Body.
@available(iOS 16.0, *)
struct SymbolBounce: ViewModifier {
    let value: Int
    func body(content: Content) -> AnyView {
        if #available(iOS 17.0, *) {
            return AnyView(content.symbolEffect(.bounce, value: value))
        }
        return AnyView(content)
    }
}

// MARK: - Symbol Replace Transition
/// Swaps one SF Symbol for another the way iOS swaps its own: the outgoing glyph
/// scales away downward as the incoming one rises into its place, rather than
/// cross-fading. Drives the switcher chevron as it flips between down (hide the
/// bar) and up (bring it back).
///
/// Erased to AnyView — see `DockPillBackground.body` for why. `.symbolEffect` is
/// an iOS 17 type, and an opaque return type would bake it into the view's Body
/// metadata, which iOS 16 cannot resolve even though the call itself is guarded.
@available(iOS 16.0, *)
struct SymbolReplaceTransition: ViewModifier {
    func body(content: Content) -> AnyView {
        if #available(iOS 17.0, *) {
            return AnyView(content.contentTransition(.symbolEffect(.replace.downUp)))
        }
        // No symbol effects before 17: fade one glyph into the other instead.
        return AnyView(content.contentTransition(.opacity))
    }
}

// MARK: - Snapshot View Representable
/// Displays a UIView snapshot (replicant) in SwiftUI, resizing it to fit the available space.
/// Uses frame-based resizing (not transforms) since the view from resizableSnapshotView is
/// designed to be resized. This avoids issues with replicant views whose internal bounds
/// may not reflect point dimensions on Retina displays.
@available(iOS 16.0, *)
struct SnapshotViewRepresentable: UIViewRepresentable {
    let snapshotView: UIView
    /// The snapshot's shape when it was taken.
    var naturalSize: CGSize = .zero
    /// Quarter-turn needed to sit upright in a portrait card.
    var rotation: CGFloat = 0

    func makeUIView(context: Context) -> SnapshotFitView {
        let container = SnapshotFitView()
        container.naturalSize = naturalSize
        container.rotation = rotation
        container.setSnapshot(snapshotView)
        return container
    }

    func updateUIView(_ container: SnapshotFitView, context: Context) {
        container.naturalSize = naturalSize
        container.rotation = rotation
        container.setSnapshot(snapshotView)
    }
}

/// Holds a snapshot aspect-fitted and centred on a black backing.
///
/// The fit runs in `layoutSubviews` rather than in the representable's `updateUIView`:
/// SwiftUI calls that on state changes, not when the view is resized, so a container
/// that was still zero-sized on the first pass would never get a second one and the
/// card stayed black.
@available(iOS 16.0, *)
final class SnapshotFitView: UIView {
    var naturalSize: CGSize = .zero {
        didSet { if naturalSize != oldValue { setNeedsLayout() } }
    }
    var rotation: CGFloat = 0 {
        didSet { if rotation != oldValue { setNeedsLayout() } }
    }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSnapshot(_ snapshot: UIView) {
        guard snapshot.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        snapshot.autoresizingMask = []
        addSubview(snapshot)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let snapshot = subviews.first else { return }
        let source = naturalSize
        guard source.width > 0, source.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            snapshot.frame = bounds
            return
        }
        // Aspect-fill. This path carries a live replicant of a guest's remote layer,
        // which keeps re-rendering as the guest re-lays out, so its content can differ
        // from the size recorded at capture. Filling crops that mismatch away; fitting
        // would strand the content in black margins.
        //
        // A turned capture is measured against its post-turn footprint, so the card is
        // filled by what the viewer actually sees rather than by the untured shape.
        let footprint = rotation == 0 ? source : CGSize(width: source.height, height: source.width)
        let scale = max(bounds.width / footprint.width, bounds.height / footprint.height)
        snapshot.transform = .identity
        snapshot.bounds = CGRect(origin: .zero,
                                 size: CGSize(width: source.width * scale,
                                              height: source.height * scale))
        snapshot.transform = rotation == 0 ? .identity : CGAffineTransform(rotationAngle: rotation)
        snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

// MARK: - Quick Switch

/// Where a run of swipes along the bar's app button stands.
@available(iOS 16.0, *)
final class MultitaskQuickSwitch {
    /// The running apps, most recent first, as the run's first swipe found them:
    /// the order every swipe of the run walks.
    var order: [String] = []
    /// Where in `order` the app in front stands.
    var index = 0
    /// Whether the run is still on: the app it last landed on is in front and
    /// has not been used yet. A finger on that app, or an app brought in front
    /// any other way, ends it, and the next swipe starts a run from the order
    /// as it then is.
    var isLive = false
    /// The swipe under way.
    var drag: Drag?
    /// A swipe let go of, its windows still sliding the rest of the way.
    var settling: Settle?
    /// Under the windows from the start of a swipe until they have settled.
    var springboard: BlurredSpringboard?
    /// The picture it shows, and the size of screen it was drawn for. Drawn a
    /// moment after the springboard is covered, so the first swipe finds it
    /// ready, and dropped when the springboard is back in view.
    var springboardImage: UIImage?
    var springboardImageSize: CGSize = .zero
    var springboardImageWork: DispatchWorkItem?
    /// What the app button shows while the windows move.
    let buttonSlide = ButtonSlide()
    /// Reads the window in front off the screen each frame while a swipe let go
    /// of slides the rest of the way, for the button to keep with it.
    var buttonSlideLink: CADisplayLink?

    /// The app button's content during a swipe along it: the app in front and
    /// the one coming in, side by side as their windows are and moving as they
    /// move, so the button names the incoming app as it comes rather than once
    /// it has landed. Its own object, watched by the button's label alone, so
    /// following the finger redraws that and nothing else.
    final class ButtonSlide: ObservableObject {
        struct Position: Equatable {
            /// The app in front as the swipe found it.
            var current: String
            /// The app coming in, if there is one that way, and the side it
            /// comes from: 1 from the left, as the windows go right, -1 from
            /// the right.
            var incoming: String?
            var side: CGFloat
            /// How far the window in front has gone along the bar, as a share of
            /// the way: 1 or -1 once the incoming one has the screen. Signed as
            /// the finger moves, to the right positive.
            var progress: CGFloat

            struct Page: Identifiable {
                let id: String
                /// From the button's centre to the page's, to the right.
                let x: CGFloat
            }

            /// Each app's place across the button, given each one's width and
            /// the space kept between two. A page's width apart, centre to
            /// centre, as the windows are a screen's: the incoming one stands
            /// just off the button's edge as the swipe starts, and where the
            /// one in front stood once it has landed.
            func pages(gap: CGFloat, width: (String) -> CGFloat) -> [Page] {
                let own = width(current)
                guard let incoming, incoming != current else {
                    return [Page(id: current, x: progress * (own + gap))]
                }
                let travel = (own + width(incoming)) / 2 + gap
                let x = progress * travel
                return [Page(id: current, x: x), Page(id: incoming, x: x - side * travel)]
            }
        }

        /// Nil at rest, when the button names the app in front alone.
        @Published var position: Position?
    }

    /// The springboard under the windows, blurred and dimmed the way the switcher
    /// shows it, standing in for the black behind them and for the windows
    /// further back: past the last app, the window in front gives a little and
    /// uncovers the springboard rather than another app.
    ///
    /// A picture blurred ahead of time rather than a blur laid live over the
    /// springboard, which came up a beat after the swipe began and showed the
    /// icons sharp for that beat.
    final class BlurredSpringboard {
        let view = UIView()
        let imageView = UIImageView()
        /// Dims the picture, and goes all the way to black as it is taken away,
        /// so that handing back to the black backdrop goes unseen.
        let scrim = UIView()
        /// The windows behind the one in front, hidden for the swipe, and how
        /// opaque each was before.
        var fadedWindows: [(view: UIView, alpha: CGFloat)] = []
        /// Counts the times it is brought up, so a fade taking it away leaves it
        /// be if the next swipe brought it back before the fade ended.
        var generation = 0

        init(frame: CGRect) {
            view.frame = frame
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.backgroundColor = .black
            view.clipsToBounds = true
            imageView.frame = view.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .scaleAspectFill
            view.addSubview(imageView)
            scrim.frame = view.bounds
            scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrim.backgroundColor = .black
            view.addSubview(scrim)
        }
    }

    /// The shape a swiped window is cut to: the one it has on screen at rest, so
    /// nothing changes as it starts moving or as it lands. The display's corners
    /// where the window reaches them; along the bar, the bar's own concave
    /// corners, which are what round a window there at rest — tighter than the
    /// display's, a different curve, and none at all for a flat bar.
    struct Shape {
        /// The display's radius at each corner, nought at those on the bar's edge.
        var radii: FlekCornerRadii
        /// The window's corners that stand on the bar, in its layer's terms.
        var barCorners: CACornerMask = []
        /// How far the bar's concave corners reach along each edge.
        var fillet: CGFloat = 0

        /// The window's outline with the bar's concave corners taken out of it:
        /// the very curve the bar draws (see `BarTopBar`), run the other way.
        func filletPath(in size: CGSize) -> CGPath {
            let c = min(fillet, size.width / 2, size.height / 2)
            let w = size.width, h = size.height
            // Each corner, with where its curve starts and ends going round clockwise.
            let corners: [(CACornerMask, CGPoint, CGPoint, CGPoint)] = [
                (.layerMinXMinYCorner, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: c), CGPoint(x: c, y: 0)),
                (.layerMaxXMinYCorner, CGPoint(x: w, y: 0), CGPoint(x: w - c, y: 0), CGPoint(x: w, y: c)),
                (.layerMaxXMaxYCorner, CGPoint(x: w, y: h), CGPoint(x: w, y: h - c), CGPoint(x: w - c, y: h)),
                (.layerMinXMaxYCorner, CGPoint(x: 0, y: h), CGPoint(x: c, y: h), CGPoint(x: 0, y: h - c)),
            ]
            let path = CGMutablePath()
            for (index, (mask, corner, before, after)) in corners.enumerated() {
                let rounded = c > 0 && barCorners.contains(mask)
                let start = rounded ? before : corner
                if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
                if rounded { path.addQuadCurve(to: after, control: corner) }
            }
            path.closeSubpath()
            return path
        }
    }

    /// A window's corners as they were before a swipe rounded them, put back as
    /// it comes to rest. A guest window clips to its bounds already; a built-in
    /// page doesn't.
    struct Corners {
        let masksToBounds: Bool
        let curve: CALayerCornerCurve
        /// For corners that aren't all alike: the window's mask before, and the
        /// one put on in its place.
        let mask: CALayer?
        let cut: CALayer?

        /// Cuts `layer` to `shape` and returns how it was. Rounded alike all round,
        /// by the layer's own corner radius, on the curve the screen's own corners
        /// follow. Otherwise by a mask: a layer for each group of corners rounded
        /// alike (see `FlekCornerRadii.cut`), and last the bar's concave corners.
        static func clip(_ layer: CALayer, shape: Shape) -> Corners {
            let radii = shape.radii
            let filleted = !shape.barCorners.isEmpty && shape.fillet > 0
            if !filleted, radii == .uniform(radii.topLeft) {
                let was = Corners(masksToBounds: layer.masksToBounds, curve: layer.cornerCurve, mask: nil, cut: nil)
                layer.masksToBounds = true
                layer.cornerCurve = .continuous
                layer.cornerRadius = radii.topLeft
                return was
            }
            let size = layer.bounds.size
            let parts = FlekCornerRadii.cut(size: size, from: radii, to: radii).map(\.layer)
            let cut = parts[0]
            cut.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            if filleted, let last = parts.last {
                let fillet = CAShapeLayer()
                fillet.frame = CGRect(origin: .zero, size: size)
                fillet.path = shape.filletPath(in: size)
                last.mask = fillet
            }
            let was = Corners(masksToBounds: layer.masksToBounds, curve: layer.cornerCurve, mask: layer.mask, cut: cut)
            layer.mask = cut
            return was
        }

        /// Square-cornered again, the way a window rests.
        func restore(_ layer: CALayer) {
            layer.cornerRadius = 0
            layer.masksToBounds = masksToBounds
            layer.cornerCurve = curve
            if let cut, layer.mask === cut { layer.mask = mask }
        }
    }

    final class Drag {
        let current: UIView
        let currentUUID: String
        /// Along the bar, in the windows' coordinates: which way, and how far a
        /// window travels that way to clear the screen.
        let axis: CGVector
        let extent: CGFloat
        /// How far apart the window in front and the one coming in are kept: a
        /// screen's length, and a little space between the two.
        var spacing: CGFloat { extent + 20 }
        let currentCorners: Corners
        /// Which side the incoming app was brought out on: 1 for the app before,
        /// coming in from the start of the bar, -1 for the one after.
        var side: CGFloat = 0
        var target: UIView?
        var targetUUID: String?
        /// How the incoming window was before it was brought out, to be put back
        /// that way if the swipe is let go of short.
        var targetWasHidden = false
        var targetAlpha: CGFloat = 1
        var targetIndex: Int?
        var targetCorners: Corners?
        /// How far along the bar the window in front already was when the swipe
        /// took it: nothing from rest, more when it was caught still sliding. In
        /// the finger's terms, so a window caught past the last app gives as it
        /// was giving.
        var origin: CGFloat = 0
        /// Caught a swipe landing, or one that had: the window in front took the
        /// stage while windows were still moving, and putting the other apps
        /// away for it waits until they rest.
        var caughtLanding = false
        /// Two side by side are one stop along the bar, as a pair in Split View
        /// is on iPad: the window in front's partner, moving with it, and the two
        /// it belongs to, kept for coming back to once the swipe lands elsewhere.
        var currentPartner: UIView?
        var currentPartnerCorners: Corners?
        var currentPair: MultitaskDockManager.SplitPair?
        /// The same for a pair kept from going home coming in: the incoming
        /// window's partner, how it was, and the two, side by side again once
        /// the swipe lands on them.
        var targetPartner: UIView?
        var targetPartnerWasHidden = false
        var targetPartnerAlpha: CGFloat = 1
        var targetPartnerIndex: Int?
        var targetPartnerCorners: Corners?
        var targetPair: MultitaskDockManager.SplitPair?

        init(current: UIView, currentUUID: String, axis: CGVector, extent: CGFloat,
             currentCorners: Corners) {
            self.current = current
            self.currentUUID = currentUUID
            self.axis = axis
            self.extent = extent
            self.currentCorners = currentCorners
        }
    }

    /// A swipe let go of, its windows sliding the rest of the way: on to the app
    /// it lands on, or back where they were. The next swipe takes them over from
    /// wherever they have got to.
    final class Settle {
        let drag: Drag
        /// The incoming window and its app, when the swipe lands on one.
        let landing: (view: UIView, uuid: String)?

        init(drag: Drag, landing: (view: UIView, uuid: String)?) {
            self.drag = drag
            self.landing = landing
        }
    }
}

@available(iOS 16.0, *)
extension MultitaskDockManager {
    /// Starts a swipe along the bar's app button, which moves between the running
    /// apps the way a swipe along the Home indicator does in iOS. To the right,
    /// the app used before the one in front comes in from the left, and swipes
    /// that follow go on back through the ones before it; to the left, forward
    /// again. Both windows follow the finger. One swipe can follow another
    /// without waiting: windows still sliding from the last are taken over from
    /// where they are.
    ///
    /// Returns false where there is nothing to move: no app in front, the
    /// switcher open, a window flying into or out of its icon.
    func quickSwitchBegan() -> Bool {
        let run = quickSwitch
        // Two side by side move as one, as a pair in Split View does on iPad. Not
        // one app beside the apps to choose from, which is a choice still open.
        let pairOnScreen = isSplitShowing ? splitPair : nil
        guard run.drag == nil, !isHomeState, !isAppSwitcherOpen,
              pairOnScreen.map({ $0.left != nil && $0.right != nil }) ?? true,
              !splitLiftArmed, splitLift == nil,
              !windowHostingView.backdropSuspended else { return false }
        // Two windows sliding as one are left to land before the next swipe:
        // taken over mid-way, each would need catching where it had got to.
        if let settle = run.settling,
           settle.drag.currentPartner != nil || settle.drag.targetPartner != nil {
            return false
        }
        var caught: UIView?
        var caughtLanding = false
        if let settle = run.settling {
            caughtLanding = settle.landing != nil || settle.drag.caughtLanding
            caught = catchQuickSwitch(settle)
        }
        guard let uuid = frontmostAppUUID,
              let current = apps.first(where: { $0.appUUID == uuid })?.view,
              let host = current.superview,
              !current.isHidden, current.alpha > 0.1 else {
            // Nothing to take on after all: what was caught comes to rest.
            if let caught {
                caught.transform = .identity
                hideBlurredSpringboard()
            }
            return false
        }
        if let caught, caught !== current { caught.transform = .identity }

        // The run goes on while the app it last landed on is in front, not yet
        // used, with the same apps running. Anything else starts a new run from
        // the order as it now is.
        let running = apps.map(\.appUUID)
        let goingOn = run.isLive
            && run.order.indices.contains(run.index) && run.order[run.index] == uuid
            && Set(run.order) == Set(running)
        if !goingOn {
            run.order = running.reversed()
            run.index = run.order.firstIndex(of: uuid) ?? 0
        }

        // The bar's long axis, carried into the windows' coordinates by the turn
        // that lays the bar along its edge: along the bar is left and right to
        // the user on every edge.
        let along = CGPoint(x: 1, y: 0).applying(barBaseTransform)
        let axis = CGVector(dx: along.x.rounded(), dy: along.y.rounded())
        let extent = axis.dx != 0 ? host.bounds.width : host.bounds.height

        // The switcher's card shows the app as it was left, taken while the
        // window is still whole on screen.
        captureSnapshot(for: uuid)
        current.layer.removeAllAnimations()
        // Caught still sliding, it is taken on from where it was; otherwise from rest.
        let offset = caught === current
            ? current.transform.tx * axis.dx + current.transform.ty * axis.dy : 0
        if offset == 0 { current.transform = .identity }
        // The app beside it, where two share the screen, goes with it.
        var partner: UIView?
        if let pair = pairOnScreen {
            guard let partnerUUID = pair.members.first(where: { $0 != uuid }),
                  let view = splitWindow(of: partnerUUID), view.superview === host,
                  !view.isHidden, view.alpha > 0.1 else { return false }
            captureSnapshot(for: partnerUUID)
            view.layer.removeAllAnimations()
            view.transform = .identity
            partner = view
        }
        // Shaped like the screen from the first moment of the swipe until the
        // window is back at rest, as iOS shows an app being swiped; beside
        // another, like its side of it.
        let drag = MultitaskQuickSwitch.Drag(current: current, currentUUID: uuid, axis: axis, extent: extent,
                                             currentCorners: .clip(current.layer, shape: quickSwitchShape(of: current)))
        drag.caughtLanding = caughtLanding && caught === current
        if let pair = pairOnScreen, let partner {
            drag.currentPair = pair
            drag.currentPartner = partner
            drag.currentPartnerCorners = .clip(partner.layer, shape: quickSwitchShape(of: partner))
        }
        run.drag = drag
        showBlurredSpringboard(behind: current, keeping: partner, in: host)
        // The divider and the handles step aside while the two are moving.
        if partner != nil { syncSplitChrome() }
        if offset != 0 {
            // The app beside it, on the side it has uncovered, comes back out
            // where it was, and the finger takes the two on from there.
            bringOutQuickSwitchTarget(on: offset > 0 ? 1 : -1, for: drag)
            drag.origin = drag.target != nil
                ? offset : Self.quickSwitchRubberBandInverse(offset, extent: extent)
            quickSwitchChanged(0)
        }
        return true
    }

    /// The swipe stopped without the finger lifting: the system's own gestures
    /// took the touch, or the bar went from under it. What it moved goes back.
    func quickSwitchCancelled() {
        guard let drag = quickSwitch.drag else { return }
        quickSwitch.drag = nil
        settleQuickSwitchBack(drag)
    }

    /// `translation` is how far the finger has gone along the bar since the
    /// swipe started, positive to the right.
    func quickSwitchChanged(_ translation: CGFloat) {
        guard let drag = quickSwitch.drag, drag.current.superview != nil else { return }
        let position = drag.origin + translation
        let side: CGFloat = position > 0 ? 1 : (position < 0 ? -1 : drag.side)
        if side != drag.side { bringOutQuickSwitchTarget(on: side, for: drag) }
        let offset: CGFloat
        if drag.target != nil {
            offset = position
            placeCurrent(of: drag, at: position)
            placeTarget(of: drag, at: position - side * drag.spacing)
        } else {
            // No app that way: the window only gives a little, as a scroll view
            // does pulled past its end.
            offset = Self.quickSwitchRubberBand(position, extent: drag.extent)
            placeCurrent(of: drag, at: offset)
        }
        slideQuickSwitchButton(of: drag, windowAt: offset)
    }

    /// The app button's label, kept with the window in front, `offset` along the
    /// bar from its place: the app's own page going the way the window goes,
    /// and the incoming app's, if any, following it in from the other side.
    private func slideQuickSwitchButton(of drag: MultitaskQuickSwitch.Drag, windowAt offset: CGFloat) {
        let position = MultitaskQuickSwitch.ButtonSlide.Position(
            current: drag.currentUUID, incoming: drag.targetUUID, side: drag.side,
            progress: offset / max(drag.spacing, 1))
        let slide = quickSwitch.buttonSlide
        if slide.position != position { slide.position = position }
    }

    /// The label for the app button and the side column's icon to follow.
    var quickSwitchButtonSlide: MultitaskQuickSwitch.ButtonSlide { quickSwitch.buttonSlide }

    /// Keeps the app button's label with the windows while a swipe let go of
    /// slides them the rest of the way. Core Animation moves them then, out of
    /// SwiftUI's sight, so the window in front is read off the screen each frame.
    private func followQuickSwitchSettle() {
        let run = quickSwitch
        guard run.buttonSlideLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(quickSwitchSettleFrame))
        // As often as the windows are drawn, on a ProMotion screen too.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        run.buttonSlideLink = link
    }

    private func stopFollowingQuickSwitchSettle() {
        quickSwitch.buttonSlideLink?.invalidate()
        quickSwitch.buttonSlideLink = nil
    }

    @objc private func quickSwitchSettleFrame() {
        guard let settle = quickSwitch.settling else {
            stopFollowingQuickSwitchSettle()
            return
        }
        let drag = settle.drag
        // Where the window is on screen this frame, not where it is headed.
        guard let shown = drag.current.layer.presentation()?.affineTransform() else { return }
        slideQuickSwitchButton(of: drag, windowAt: shown.tx * drag.axis.dx + shown.ty * drag.axis.dy)
    }

    /// The window in front, and the app beside it where two share the screen.
    private func placeCurrent(of drag: MultitaskQuickSwitch.Drag, at offset: CGFloat) {
        place(drag.current, at: offset, along: drag)
        if let partner = drag.currentPartner { place(partner, at: offset, along: drag) }
    }

    /// The window coming in, and its partner where it is one of two kept.
    private func placeTarget(of drag: MultitaskQuickSwitch.Drag, at offset: CGFloat) {
        if let target = drag.target { place(target, at: offset, along: drag) }
        if let partner = drag.targetPartner { place(partner, at: offset, along: drag) }
    }

    /// `velocity` is the finger's along the bar as it lifted, in points a second.
    func quickSwitchEnded(_ translation: CGFloat, velocity: CGFloat) {
        guard let drag = quickSwitch.drag else { return }
        quickSwitch.drag = nil
        let position = drag.origin + translation
        // Flicked, or let go a third of the way across having moved that way:
        // the switch is made. A window caught still sliding may start past that
        // third, and is only switched away by moving it on. Flicking back the
        // other way calls it off however far it went.
        let flicking = abs(velocity) > 350
        let flickedBack = flicking && (velocity > 0) != (drag.side > 0)
        let pulledAcross = abs(position) > drag.extent * 0.3 && translation * drag.side > 0
        guard let target = drag.target, let uuid = drag.targetUUID,
              drag.current.superview != nil, !flickedBack,
              flicking || pulledAcross else {
            settleQuickSwitchBack(drag)
            return
        }
        let settle = MultitaskQuickSwitch.Settle(drag: drag, landing: (target, uuid))
        quickSwitch.settling = settle
        // The bar's app button takes the incoming app's width now, gliding to
        // it (see `BarAppButtonLabel`); the app's name is already on its way in.
        quickSwitchLanding = uuid
        // Carries on at the finger's speed and eases to a stop.
        let remaining = max(drag.spacing - abs(position), 1)
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: min(abs(velocity) / remaining, 30),
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.placeCurrent(of: drag, at: drag.side * drag.spacing)
            target.transform = .identity
            drag.targetPartner?.transform = .identity
        } completion: { _ in
            // Unless the next swipe caught it on the way, which has seen to it.
            guard self.quickSwitch.settling === settle else { return }
            self.finishQuickSwitch(settle, caught: false)
        }
        followQuickSwitchSettle()
    }

    /// The shape `view` has at rest, which it keeps for the whole swipe: the
    /// display's corners, but for those on the bar's edge when the window stops
    /// at the bar, which take the bar's own concave corners. A window reaching
    /// in under the bar, as a built-in page does, keeps the display's there:
    /// the bar covers them.
    private func quickSwitchShape(of view: UIView) -> MultitaskQuickSwitch.Shape {
        var shape = MultitaskQuickSwitch.Shape(radii: deviceScreenCornerRadii)
        // Beside another app, the corners on the fold's side are the fold's own,
        // as the divider rounds them at rest.
        if let uuid = apps.first(where: { $0.view === view })?.appUUID,
           let side = framedSplitPair?.side(of: uuid) {
            let fold = SplitDividerView.cornerRadius
            switch side {
            case .left:
                shape.radii.topRight = fold
                shape.radii.bottomRight = fold
            case .right:
                shape.radii.topLeft = fold
                shape.radii.bottomLeft = fold
            }
        }
        let insets = barReservedInsets
        guard insets != .zero, let window = view.window else { return shape }
        // The window's place at rest: its transform moves it only along the bar.
        let resting = CGRect(x: view.center.x - view.bounds.width / 2,
                             y: view.center.y - view.bounds.height / 2,
                             width: view.bounds.width, height: view.bounds.height)
        let frame = view.superview?.convert(resting, to: window) ?? resting
        let flatTop = window.bounds.inset(by: insets)
        let slack: CGFloat = 1
        if insets.bottom > 0, frame.maxY <= flatTop.maxY + slack {
            shape.barCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else if insets.top > 0, frame.minY >= flatTop.minY - slack {
            shape.barCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        } else if insets.right > 0, frame.maxX <= flatTop.maxX + slack {
            shape.barCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        } else if insets.left > 0, frame.minX >= flatTop.minX - slack {
            shape.barCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
        guard !shape.barCorners.isEmpty else { return shape }
        if shape.barCorners.contains(.layerMinXMinYCorner) { shape.radii.topLeft = 0 }
        if shape.barCorners.contains(.layerMaxXMinYCorner) { shape.radii.topRight = 0 }
        if shape.barCorners.contains(.layerMinXMaxYCorner) { shape.radii.bottomLeft = 0 }
        if shape.barCorners.contains(.layerMaxXMaxYCorner) { shape.radii.bottomRight = 0 }
        shape.fillet = barLedgeActive ? barCornerRadiusActive * barLedgeAmountActive : 0
        return shape
    }

    private func place(_ view: UIView, at offset: CGFloat, along drag: MultitaskQuickSwitch.Drag) {
        view.transform = CGAffineTransform(translationX: drag.axis.dx * offset,
                                           y: drag.axis.dy * offset)
    }

    /// Brings out the app on `side` of the one in front, just off screen there,
    /// putting back any brought out on the other side first.
    private func bringOutQuickSwitchTarget(on side: CGFloat, for drag: MultitaskQuickSwitch.Drag) {
        putBackQuickSwitchTarget(of: drag)
        drag.side = side
        let run = quickSwitch
        guard let host = drag.current.superview else { return }
        // To the right, further back in the run's order; to the left, forward.
        // An app floating in Picture in Picture has no window here to bring in,
        // so the swipe goes on past it to the next.
        let step = side > 0 ? 1 : -1
        var index = run.index + step
        var found: (uuid: String, view: UIView)?
        while found == nil, run.order.indices.contains(index) {
            // The app beside the one in front is moving with it, not a stop.
            if drag.currentPair?.contains(run.order[index]) != true,
               let view = apps.first(where: { $0.appUUID == run.order[index] })?.view,
               view.superview === host, !isInPiP(view) {
                found = (run.order[index], view)
            }
            index += step
        }
        guard let (uuid, view) = found else { return }
        drag.targetWasHidden = view.isHidden
        drag.targetAlpha = view.alpha
        drag.targetIndex = host.subviews.firstIndex(of: view)
        view.layer.removeAllAnimations()
        drag.targetCorners = .clip(view.layer, shape: quickSwitchShape(of: view))
        // Just under the window it comes in beside, so nothing else that was
        // behind that one covers it on the way.
        host.insertSubview(view, belowSubview: drag.current)
        view.alpha = 1
        view.isHidden = false
        drag.target = view
        drag.targetUUID = uuid
        // One of two kept from going home comes in with the other beside it, in
        // their places, to be side by side again where the swipe lands.
        if canSplitNow, let kept = splitSuspended, kept.contains(uuid),
           let partnerUUID = kept.members.first(where: { $0 != uuid }),
           let partner = splitWindow(of: partnerUUID), partner.superview === host,
           !isInPiP(partner) {
            drag.targetPartnerWasHidden = partner.isHidden
            drag.targetPartnerAlpha = partner.alpha
            drag.targetPartnerIndex = host.subviews.firstIndex(of: partner)
            partner.layer.removeAllAnimations()
            drag.targetPartnerCorners = .clip(partner.layer, shape: quickSwitchShape(of: partner))
            host.insertSubview(partner, belowSubview: drag.current)
            partner.alpha = 1
            partner.isHidden = false
            drag.targetPartner = partner
            drag.targetPair = kept
        }
        placeTarget(of: drag, at: -side * drag.spacing)
    }

    private func putBackQuickSwitchTarget(of drag: MultitaskQuickSwitch.Drag) {
        if let partner = drag.targetPartner {
            partner.transform = .identity
            drag.targetPartnerCorners?.restore(partner.layer)
            partner.alpha = drag.targetPartnerAlpha
            partner.isHidden = drag.targetPartnerWasHidden
            if let index = drag.targetPartnerIndex, let host = partner.superview {
                host.insertSubview(partner, at: min(index, host.subviews.count - 1))
            }
        }
        drag.targetPartner = nil
        drag.targetPartnerCorners = nil
        drag.targetPair = nil
        guard let view = drag.target else { return }
        view.transform = .identity
        drag.targetCorners?.restore(view.layer)
        view.alpha = drag.targetAlpha
        view.isHidden = drag.targetWasHidden
        if let index = drag.targetIndex, let host = view.superview {
            host.insertSubview(view, at: min(index, host.subviews.count - 1))
        }
        drag.target = nil
        drag.targetUUID = nil
        drag.targetCorners = nil
    }

    private func settleQuickSwitchBack(_ drag: MultitaskQuickSwitch.Drag) {
        let settle = MultitaskQuickSwitch.Settle(drag: drag, landing: nil)
        quickSwitch.settling = settle
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            drag.current.transform = .identity
            drag.currentPartner?.transform = .identity
            self.placeTarget(of: drag, at: -drag.side * drag.spacing)
        } completion: { _ in
            guard self.quickSwitch.settling === settle else { return }
            self.finishQuickSwitch(settle, caught: false)
        }
        followQuickSwitchSettle()
    }

    /// Stops a settling swipe's windows where they have got to and does now what
    /// its end would have done, but for the window left in front, which stays
    /// where it was caught for the next swipe to take on. Returns that window.
    private func catchQuickSwitch(_ settle: MultitaskQuickSwitch.Settle) -> UIView {
        let drag = settle.drag
        for view in [drag.current, drag.target].compactMap({ $0 }) {
            if let sliding = view.layer.presentation()?.affineTransform() {
                view.transform = sliding
            }
            view.layer.removeAllAnimations()
        }
        finishQuickSwitch(settle, caught: true)
        return settle.landing?.view ?? drag.current
    }

    /// A swipe's windows have come to rest, or the next swipe has caught them on
    /// the way, which leaves the window in front where it was caught and keeps
    /// the blurred springboard up for itself.
    ///
    /// Landed, the incoming window has the screen: what a tap on its card in the
    /// switcher does from here, minus the entrance, which the swipe was.
    private func finishQuickSwitch(_ settle: MultitaskQuickSwitch.Settle, caught: Bool) {
        quickSwitch.settling = nil
        stopFollowingQuickSwitchSettle()
        let drag = settle.drag
        guard let (target, uuid) = settle.landing else {
            // Back where it was, and the window brought out goes back to how it was.
            drag.currentCorners.restore(drag.current.layer)
            if let partner = drag.currentPartner { drag.currentPartnerCorners?.restore(partner.layer) }
            putBackQuickSwitchTarget(of: drag)
            // The app button names the app in front alone again. Caught, the
            // next swipe has it moving again before it is drawn.
            quickSwitch.buttonSlide.position = nil
            // Two back side by side: the divider and the handles come back.
            if drag.currentPartner != nil { syncSplitChrome() }
            guard !caught else { return }
            hideBlurredSpringboard()
            if drag.caughtLanding { keepOneAppOnStage(drag.current) }
            return
        }
        let partner = drag.targetPartner
        let partnerUUID = partner == nil ? nil : drag.targetPair?.members.first(where: { $0 != uuid })
        // In front of the window it replaced, which goes back to its place behind
        // it, as a window brought forward leaves the rest. Two kept come in front
        // together, the one landed on the one in use.
        if let partner { partner.superview?.bringSubviewToFront(partner) }
        target.superview?.bringSubviewToFront(target)
        drag.current.transform = .identity
        drag.currentCorners.restore(drag.current.layer)
        if let left = drag.currentPartner {
            left.transform = .identity
            drag.currentPartnerCorners?.restore(left.layer)
        }
        drag.targetCorners?.restore(target.layer)
        if let partner { drag.targetPartnerCorners?.restore(partner.layer) }
        // The windows further back come back in, under the one now in front.
        quickSwitch.springboard?.fadedWindows.removeAll { $0.view === target || $0.view === partner }
        if !caught { hideBlurredSpringboard() }
        // Closed while it was coming in: nothing to hand the stage to, and the
        // button goes back to naming the app in front, gliding back to its width.
        guard apps.contains(where: { $0.appUUID == uuid }) else {
            quickSwitchLanding = nil
            quickSwitch.buttonSlide.position = nil
            if drag.currentPartner != nil { syncSplitChrome() }
            return
        }

        // Two side by side swiped away are kept, in their places, to come back
        // to, as going home keeps them (see `framedSplitPair`). Two kept, swiped
        // back to, are side by side again.
        if let pair = drag.currentPair, splitPair == pair {
            splitSuspended = pair
            splitPair = nil
            splitLaunch = nil
        }
        if let pair = drag.targetPair, partner != nil, splitSuspended == pair {
            splitSuspended = nil
            splitPair = pair
        }

        passURLSchemeToView(target)
        for other in apps where other.appUUID != uuid && other.appUUID != partnerUUID {
            dismissPresentation(forAppUUID: other.appUUID)
        }
        // Not while the next swipe has the windows: it is about to bring back out
        // the one this would put away. That swipe does it as its windows rest.
        // Nor for two side by side, which would put one of them away.
        if !caught, partner == nil { keepOneAppOnStage(target) }
        if let window = keyWindow { bringViewToFront(target, in: window) }
        windowTookStage(uuid: uuid)
        // Its width taken since the finger let go, and its page slid all the
        // way across: from here the button shows it as the app in front.
        quickSwitchLanding = nil
        quickSwitch.buttonSlide.position = nil
        // The divider and the handles, now that the windows are at rest.
        syncSplitChrome()

        // The order iOS leaves after a run: the app landed on is the most recent,
        // and the rest stay as the run found them, however many it passed. Two
        // landed on are the two most recent, the one in use the last.
        let run = quickSwitch
        var oldestFirst = Array(run.order.reversed())
        oldestFirst.removeAll { $0 == uuid || $0 == partnerUUID }
        if let partnerUUID { oldestFirst.append(partnerUUID) }
        oldestFirst.append(uuid)
        let byUUID = Dictionary(apps.map { ($0.appUUID, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = oldestFirst.compactMap { byUUID[$0] }
        if reordered.count == apps.count { apps = reordered }
        run.index = run.order.firstIndex(of: uuid) ?? 0
        // On until the app landed on is used; `windowTookStage` just ended it.
        run.isLive = true
    }

    /// With only one app allowed on stage, the rest are put away once a swipe
    /// has handed it to `view`.
    private func keepOneAppOnStage(_ view: UIView) {
        guard UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage"),
              let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController,
              decoratedVC.isMaximized else { return }
        minimizeAllWindows(except: decoratedVC, style: .fade)
    }

    /// A finger came down on an app window: whatever a run of swipes last landed
    /// on is in use now, and the next swipe starts from the order as it is.
    @objc func quickSwitchWindowTouched() {
        quickSwitch.isLive = false
    }

    /// Keeps the blurred springboard ready for the next swipe. The springboard
    /// only changes while it is in view: covered, it is drawn once, a moment
    /// after the opening is over; back in view, the picture is dropped.
    func quickSwitchHomeStateChanged() {
        let run = quickSwitch
        run.springboardImageWork?.cancel()
        run.springboardImageWork = nil
        if isHomeState {
            run.springboardImage = nil
            springboardMayHaveChanged()
        } else if run.springboardImage == nil {
            prepareQuickSwitchSpringboardImage(after: 1)
        }
    }

    private func prepareQuickSwitchSpringboardImage(after delay: TimeInterval) {
        let run = quickSwitch
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            run.springboardImageWork = nil
            guard !self.isHomeState, run.springboardImage == nil else { return }
            // Not while a window is still flying out of its icon, with the grid
            // zoomed away behind it: a little later.
            guard !self.windowHostingView.backdropSuspended else {
                self.prepareQuickSwitchSpringboardImage(after: 0.5)
                return
            }
            _ = self.quickSwitchSpringboardImage()
            // And the switcher's, kept for its next open where nothing can change
            // the springboard meanwhile.
            if !self.frontmostIsBuiltInPage { _ = self.switcherBackdropPicture() }
        }
        run.springboardImageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The springboard as a swipe shows it, drawn small and blurred, and kept
    /// for the size of screen it was drawn for. Drawn here and now when there is
    /// none ready.
    private func quickSwitchSpringboardImage() -> UIImage? {
        let run = quickSwitch
        let size = windowHostingView.bounds.size
        if let image = run.springboardImage, run.springboardImageSize == size { return image }
        // A pixel to every four points: the blur keeps no detail a finer one would.
        let scale: CGFloat = 0.25
        guard let drawn = renderSpringboard(scale: scale)?.cgImage else { return nil }
        let input = CIImage(cgImage: drawn)
        // About the switcher's blur, with the lift in colour a material gives it.
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5])
            .cropped(to: input.extent)
        guard let output = Self.quickSwitchImageContext.createCGImage(blurred, from: input.extent) else {
            return nil
        }
        let image = UIImage(cgImage: output, scale: scale, orientation: .up)
        run.springboardImage = image
        run.springboardImageSize = size
        return image
    }

    private static let quickSwitchImageContext = CIContext()

    /// Lays the blurred springboard under the windows as a swipe starts and hides
    /// the ones behind `current`. One still fading away after the swipe before is
    /// brought back instead.
    /// `partner` is the app beside `current` where two share the screen, which
    /// moves with it and stays in view as it does.
    private func showBlurredSpringboard(behind current: UIView, keeping partner: UIView? = nil,
                                        in host: UIView) {
        let run = quickSwitch
        // Before it is laid, so what is drawn is the springboard alone.
        let image = quickSwitchSpringboardImage()
        let springboard: MultitaskQuickSwitch.BlurredSpringboard
        if let shown = run.springboard {
            springboard = shown
        } else {
            guard let root = windowHostingView.superview else { return }
            springboard = .init(frame: windowHostingView.frame)
            // Under the window host, whose black would cover it, so that is held back.
            root.insertSubview(springboard.view, belowSubview: windowHostingView)
            windowHostingView.backdropHeldForQuickSwitch = true
            run.springboard = springboard
        }
        springboard.generation += 1
        springboard.imageView.image = image
        springboard.fadedWindows.removeAll { $0.view === current || $0.view === partner }
        let windows = Set(apps.compactMap(\.view).map(ObjectIdentifier.init))
        for view in host.subviews where view !== current && view !== partner
            && windows.contains(ObjectIdentifier(view)) && !view.isHidden && view.alpha > 0
            && !isInPiP(view) && !springboard.fadedWindows.contains(where: { $0.view === view }) {
            springboard.fadedWindows.append((view, view.alpha))
        }
        // All at once. The window in front covers the change, and whatever fades
        // in is seen arriving late wherever the window has already moved aside.
        springboard.scrim.layer.removeAllAnimations()
        // Dimmed about as far as the switcher's material and scrim dim it; black
        // when there is no picture.
        springboard.scrim.alpha = image == nil ? 1 : 0.4
        for (view, _) in springboard.fadedWindows {
            view.layer.removeAllAnimations()
            view.alpha = 0
        }
    }

    /// Takes the blurred springboard away once the windows have settled. It goes
    /// back to black for the backdrop to take over, and the windows behind come
    /// back with the backdrop, under the one in front.
    private func hideBlurredSpringboard() {
        let run = quickSwitch
        guard let springboard = run.springboard else { return }
        let generation = springboard.generation
        UIView.animate(withDuration: 0.25, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
            springboard.scrim.alpha = 1
        } completion: { _ in
            guard run.springboard === springboard, springboard.generation == generation else { return }
            run.springboard = nil
            springboard.view.removeFromSuperview()
            // In the same moment as the backdrop, which then lies over them. Faded
            // back in while it was still held off, they showed in every gap the
            // window in front leaves for the length of the fade. Not one closed
            // or minimized meanwhile, which stays the way that left it.
            for (view, alpha) in springboard.fadedWindows where view.superview != nil && !view.isHidden {
                view.alpha = alpha
            }
            self.windowHostingView.backdropHeldForQuickSwitch = false
        }
    }

    private func isInPiP(_ view: UIView) -> Bool {
        guard PiPManager.hasShared, let pipManager = PiPManager.shared,
              let decoratedVC = view._viewDelegate() else { return false }
        return pipManager.isPiP(withDecoratedVC: decoratedVC)
    }

    /// UIScrollView's resistance past its end: the further it is pulled, the less
    /// it follows, never quite reaching the extent.
    private static func quickSwitchRubberBand(_ offset: CGFloat, extent: CGFloat) -> CGFloat {
        let extent = max(extent, 1)
        let pulled = (1 - 1 / (abs(offset) * 0.55 / extent + 1)) * extent
        return offset < 0 ? -pulled : pulled
    }

    /// How far the finger has to have pulled for the window to have given
    /// `given`: the resistance above, undone.
    private static func quickSwitchRubberBandInverse(_ given: CGFloat, extent: CGFloat) -> CGFloat {
        let extent = max(extent, 1)
        let pulled = min(abs(given), extent * 0.99)
        let offset = pulled / (0.55 * (1 - pulled / extent))
        return given < 0 ? -offset : offset
    }
}

/// A swipe along the bar's app button, handed to the dock's quick switch.
@available(iOS 16.0, *)
private struct QuickSwitchSwipe: ViewModifier {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var reading = QuickSwitchSwipeReading()
    /// True only while the drag is live. SwiftUI clears a `@GestureState` when the
    /// gesture ends or is cancelled, but calls onEnded only when it ends — so a
    /// swipe the system's own gestures took over would leave the windows where
    /// the finger last had them, and the springboard blurred behind them.
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            // Measured in the button's own space, where the strip lies horizontal
            // whichever edge it is turned onto: along it is always left and right.
            // Not the global space, which is the window's, unturned: on a phone
            // on its side, with the bar standing down the chin's edge, it read a
            // swipe across the bar as one along it, and the swipe that switched
            // was left to right while the windows slid up and down.
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { value in
                    let dx = value.translation.width, dy = value.translation.height
                    if reading.isSwitching == nil {
                        // Along the bar only. The press under the finger gives up
                        // at this distance, so a swipe never also opens the switcher.
                        reading.isSwitching = abs(dx) > abs(dy) && dockManager.quickSwitchBegan()
                        reading.origin = dx
                    }
                    guard reading.isSwitching == true else { return }
                    dockManager.quickSwitchChanged(dx - reading.origin)
                }
                .onEnded { value in
                    defer { reading.isSwitching = nil }
                    guard reading.isSwitching == true else { return }
                    let velocity: CGFloat
                    if #available(iOS 17.0, *) {
                        velocity = value.velocity.width
                    } else {
                        velocity = (value.predictedEndTranslation.width - value.translation.width) * 4
                    }
                    dockManager.quickSwitchEnded(value.translation.width - reading.origin,
                                                 velocity: velocity)
                }
        )
        .onChange(of: isDragging) { dragging in
            if !dragging { cancelUnended() }
        }
        // Nor does a bar torn down mid-swipe tell its gesture anything.
        .onDisappear { cancelUnended() }
    }

    /// Puts back what a cancelled swipe moved. A turn of the run loop later, so a
    /// drag that ended has been through onEnded by then, whichever of the two
    /// SwiftUI calls first: one still marked switching was cancelled. Either way
    /// the next drag reads its direction afresh.
    private func cancelUnended() {
        let reading = reading, dockManager = dockManager
        DispatchQueue.main.async {
            defer { reading.isSwitching = nil }
            if reading.isSwitching == true { dockManager.quickSwitchCancelled() }
        }
    }
}

/// The swipe's reading of the drag under way, kept in a reference so that
/// updating it is not a change of view state.
private final class QuickSwitchSwipeReading {
    var isSwitching: Bool?
    var origin: CGFloat = 0
}

// MARK: - Two apps side by side (iPhone Duo, opened out)

/// Two apps side by side on an iPhone Duo opened out, one on each side of the
/// fold, the way iOS itself does it there. Each has a page about the size of the
/// cover display, which an app laid out for a phone already fits, and the fold
/// never runs through either app.
///
/// Started as iOS starts it:
/// - from an app: the app button, held and then dragged, lifts the app in use off
///   the screen, and a shelf comes up at each side to drop it on. It takes the
///   side it is dropped on, and the other side shows the apps to choose the
///   second from;
/// - from the home screen: an app's menu has "Open in Split View", which opens it
///   on the left with the apps to choose from on the right.
///
/// Once two are side by side, as with iOS's three home indicators, each app has a
/// handle of its own under it, and the bar's controls act on the two together:
/// - a side's handle, swiped up or tapped, puts that side's app away and shows the
///   apps to choose from there;
/// - the app in use, lifted and dropped on the other side, swaps sides;
/// - the divider, dragged off either edge, puts that side's app away and leaves
///   the other the screen. Tapped, it opens a menu: pair the two, so opening
///   either opens both from then on, until they are unpaired or the divider
///   parts them; swap their sides; or close either.
///
/// Over when either app is put away or closed, when a third comes forward, on the
/// way home. Folded, or turned upright while open, the app last used fills the
/// screen, and the two are side by side again once the phone is opened out or
/// turned back. Gone home from, the two come back together however either is
/// opened again, until the divider parts them or one is closed.
///
/// Each app is told its page's size and keeps the screen's orientation, as an app
/// in an iPad's Split View does: on the inner display, held open, that is
/// landscape, whatever shape the page.
@available(iOS 16.0, *)
extension MultitaskDockManager {
    struct SplitPair: Equatable {
        /// The app on each side, or nil where that side shows the apps to choose
        /// from.
        var left: String?
        var right: String?

        var members: [String] { [left, right].compactMap { $0 } }

        func contains(_ uuid: String) -> Bool { left == uuid || right == uuid }

        func side(of uuid: String) -> SplitSide? {
            uuid == left ? .left : uuid == right ? .right : nil
        }

        func app(on side: SplitSide) -> String? { side == .left ? left : right }

        /// The side showing the apps to choose from, if one is.
        var choosingSide: SplitSide? { left == nil ? .left : right == nil ? .right : nil }

        func with(_ uuid: String?, on side: SplitSide) -> SplitPair {
            var pair = self
            if side == .left { pair.left = uuid } else { pair.right = uuid }
            return pair
        }

        var swapped: SplitPair { SplitPair(left: right, right: left) }

        static let empty = SplitPair(left: nil, right: nil)
    }

    enum SplitSide: CaseIterable {
        case left, right

        var opposite: SplitSide { self == .left ? .right : .left }
    }

    /// An app chosen for a side that has yet to start: its window takes the side
    /// when it arrives, out of the icon it was chosen by.
    struct SplitLaunch {
        let side: SplitSide
        let itemID: String
        let source: CGRect?
        let started = Date()

        /// Long after, a window arriving is an app opened some other way.
        var isFresh: Bool { Date().timeIntervalSince(started) < 30 }
    }

    /// The app in use, lifted off the screen by the app button.
    final class SplitLift {
        let uuid: String
        let view: UIView
        /// Where the window's centre was as it lifted.
        let center: CGPoint
        /// Where the finger came down.
        let start: CGPoint
        /// From the finger to the lifted window's centre, where the window keeps
        /// hold of the point it was picked up by (see `splitLiftGrabOffset`). Nil
        /// for a lift from the bar, which hangs the window above the finger.
        let grabOffset: CGPoint?
        /// Whether the finger has carried the window anywhere yet. Held by the
        /// point it was picked up by, a window can come up over a shelf already:
        /// from the floating button at the screen's edge it shrinks towards that
        /// side. So it aims at nothing until the finger has moved, and held and
        /// let go where it was, it goes back rather than taking the side it came
        /// up over. A window hung above the finger starts clear of the shelves.
        private(set) var carried: Bool
        var target: SplitSide?
        /// How the window clipped before its corners were rounded for the lift: a
        /// guest window clips to its bounds already, a built-in page doesn't.
        let masksToBounds: Bool
        let cornerCurve: CALayerCornerCurve
        /// With two side by side: the side this one was on, and the window of the
        /// app on the other side, moved across to show the swap while the finger
        /// is over its side.
        let from: SplitSide?
        let otherView: UIView?
        var previewing = false
        /// The edge it came from, back at which the finger calls it off.
        let origin: SplitLiftOrigin

        init(uuid: String, view: UIView, center: CGPoint, start: CGPoint, grabOffset: CGPoint?,
             origin: SplitLiftOrigin, from: SplitSide?, otherView: UIView?) {
            self.uuid = uuid
            self.view = view
            self.center = center
            self.start = start
            self.grabOffset = grabOffset
            self.origin = origin
            carried = grabOffset == nil
            self.from = from
            self.otherView = otherView
            masksToBounds = view.layer.masksToBounds
            cornerCurve = view.layer.cornerCurve
        }

        /// Where the window is with the finger at `point`, for the half it is
        /// over: its centre where it is held by the point it was picked up by,
        /// else the finger, which it hangs centred above.
        func aim(_ point: CGPoint) -> CGPoint {
            guard let grabOffset else { return point }
            return CGPoint(x: point.x + grabOffset.x, y: point.y + grabOffset.y)
        }

        /// Notes how far the finger at `point` has come (see `carried`).
        func noteCarried(to point: CGPoint) {
            if !carried, hypot(point.x - start.x, point.y - start.y) >= Self.carryDistance {
                carried = true
            }
        }

        /// How far the finger moves before a window held by its grab point aims
        /// at anything: past a finger's wobble as it is held.
        static let carryDistance: CGFloat = 20

        /// Square-cornered again, the way a window rests: the screen's corners and
        /// the divider round it where it lands.
        func restoreCorners() {
            view.layer.cornerRadius = 0
            view.layer.masksToBounds = masksToBounds
            view.layer.cornerCurve = cornerCurve
        }
    }

    /// Where a lift came from: the screen edge nearest the finger as it came down
    /// (the floating button's, the dock's, the bar's, a handle's), and how far in
    /// from it. Brought back that close to it, the finger calls the lift off and
    /// the app goes back as it was: the user has changed their mind.
    struct SplitLiftOrigin {
        enum Edge { case left, right, top, bottom }
        let edge: Edge
        let depth: CGFloat

        init(start: CGPoint, in bounds: CGRect) {
            let distances: [(edge: Edge, distance: CGFloat)] = [
                (.left, start.x - bounds.minX), (.right, bounds.maxX - start.x),
                (.top, start.y - bounds.minY), (.bottom, bounds.maxY - start.y),
            ]
            let nearest = distances.min { $0.distance < $1.distance } ?? (.bottom, 0)
            edge = nearest.edge
            depth = max(nearest.distance, 0)
        }

        /// How far in from its edge the finger calls the lift off: a little past
        /// where it came down, so a lift starts called off until the finger
        /// leaves the control it came from.
        var reach: CGFloat { max(depth + 44, 72) }

        func callsOff(_ point: CGPoint, in bounds: CGRect) -> Bool {
            let distance: CGFloat
            switch edge {
            case .left: distance = point.x - bounds.minX
            case .right: distance = bounds.maxX - point.x
            case .top: distance = point.y - bounds.minY
            case .bottom: distance = bounds.maxY - point.y
            }
            return distance < reach
        }
    }

    /// The black between the two pages.
    static let splitGap: CGFloat = 8
    /// How quickly what is drawn around the two goes as they leave. The windows
    /// are three fifths of the way into their icons a tenth of a second after
    /// setting off; faded over 0.15s, the divider was still half there over
    /// windows nearly gone.
    static let splitChromeFadeOut: TimeInterval = 0.1
    /// Narrower than this, a side would be narrower than any phone an app is laid
    /// out for.
    static let splitMinimumWidth: CGFloat = 640
    /// How far an app shrinks as it is lifted.
    static let splitLiftScale: CGFloat = 0.5
    static let splitFractionsKey = "FlekSplitFractions"
    private static let splitIconCache = NSCache<NSString, UIImage>()

    /// Whether the display FlekDeck is on has room for two apps side by side:
    /// an iPad's, or the iPhone Duo's inner one. Whether they go side by side now
    /// is `canSplitNow`: the window held wide, and wide enough.
    var isSplitDisplay: Bool {
        guard let screen = (windowHostingView.window ?? keyWindow)?.windowScene?.screen else {
            return false
        }
        #if DEBUG
        // Folding can't be driven from the simulator's command-line tools, so a
        // test can launch FlekDeck with `-FlekSplitOnAnyDisplay YES` and get the
        // split on any display wide enough.
        if UserDefaults.standard.bool(forKey: "FlekSplitOnAnyDisplay") { return true }
        #endif
        if UIDevice.current.userInterfaceIdiom == .pad { return true }
        return FlekDeviceModel.duoDisplay(of: screen) == .inner
    }

    private var splitHostSize: CGSize {
        windowHostingView.window?.bounds.size ?? windowHostingView.bounds.size
    }

    /// Whether two apps go side by side here at all, however the display is held
    /// now: apps open in windows, on an iPad or the Duo's inner display. Where
    /// they do, the home screen's icons offer to pair two.
    var supportsSplit: Bool {
        isDockEnabled() && DataManager.shared.model.multiLCStatus != 2 && isSplitDisplay
    }

    /// Whether two apps can be put side by side now: apps open in windows, on an
    /// iPad or the Duo's inner display, held wide, and wide enough. An iPad turned
    /// upright, or FlekDeck's window made narrow beside other apps, is a Duo
    /// folded: one app at a time, the two together again once it is wide.
    var canSplitNow: Bool {
        guard supportsSplit else { return false }
        let size = splitHostSize
        return size.width > size.height && size.width >= Self.splitMinimumWidth
    }

    /// Whether the two are drawn side by side now. Turned upright, or while the
    /// switcher has turned the display, each has the whole screen until it is
    /// wide again.
    var isSplitShowing: Bool { splitPair != nil && canSplitNow }

    /// What keeps two apps from going side by side now, on a display that can
    /// hold them: held upright, or FlekDeck's window made narrow beside other
    /// apps.
    enum SplitUnavailability { case upright, narrow }

    /// Why two apps cannot go side by side now, for the home screen's menu to say
    /// so. Nil where they can, and where the question does not arise: a display
    /// that never holds two, or apps not opened in windows at all.
    var splitUnavailability: SplitUnavailability? {
        guard supportsSplit, !canSplitNow else { return nil }
        let size = splitHostSize
        return size.width > size.height ? .narrow : .upright
    }

    enum SplitLight: Equatable {
        case available
        case unavailable(SplitUnavailability)

        var isAvailable: Bool { self == .available }

        /// Where things stand, as the help and VoiceOver say it.
        var title: String {
            isAvailable ? "lc.flek.splitHelp.ready".loc : "lc.flek.splitHelp.notReady".loc
        }

        /// What would make it ready, where it is not.
        var reason: String? {
            switch self {
            case .available: return nil
            case .unavailable(.upright): return "lc.flek.splitHelp.upright".loc
            case .unavailable(.narrow): return "lc.flek.splitHelp.narrow".loc
            }
        }
    }

    /// Sets the home pill's light from where things stand: on an iPad, green where
    /// two apps can go side by side now, red where the iPad is upright or
    /// FlekDeck's window too narrow beside other apps; none elsewhere, or with
    /// apps not in windows. Whether holding an app there and dragging does
    /// anything is not something the pill otherwise shows. Published a turn
    /// later: this is asked during layout.
    func refreshSplitLight() {
        let light: SplitLight?
        if UIDevice.current.userInterfaceIdiom != .pad {
            light = nil
        } else if canSplitNow {
            light = .available
        } else if let reason = splitUnavailability {
            light = .unavailable(reason)
        } else {
            light = nil
        }
        guard light != splitLight else { return }
        DispatchQueue.main.async {
            guard self.splitLight != light else { return }
            self.splitLight = light
            // What it said is no longer so.
            self.hideSplitHelp()
        }
    }

    /// The light tapped: how Split View works, in a popover pointing at it, with
    /// where things stand now and the switch that hides the light; or the
    /// popover put away if it is up already. `lightFrame` is the light's frame in
    /// the home screen's window.
    func toggleSplitHelp(at lightFrame: CGRect) {
        if splitHelpController != nil {
            hideSplitHelp()
            return
        }
        guard var presenter = keyWindow?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard let stage = presenter.view else { return }
        let anchor = stage.convert(lightFrame, from: nil)
        // The room the popover has, above the light or below it, less its arrow
        // and the margin it keeps from the screen's edges.
        let safe = stage.safeAreaInsets
        let roomHeight = max(anchor.minY - safe.top, stage.bounds.height - safe.bottom - anchor.maxY) - 40
        let roomWidth = stage.bounds.width - safe.left - safe.right - 32
        func natural(_ layout: SplitHelpCard.Layout) -> CGSize {
            UIHostingController(rootView: SplitHelpCard(layout: layout, scrolls: false))
                .sizeThatFits(in: CGSize(width: layout.width, height: .greatestFiniteMagnitude))
        }
        // One column where it fits; two where it would not and there is the
        // width for them; scrolled where neither fits.
        var layout = SplitHelpCard.Layout.column
        var size = natural(.column)
        if size.height > roomHeight, roomWidth >= SplitHelpCard.Layout.columns.width {
            let wide = natural(.columns)
            if wide.height < size.height {
                layout = .columns
                size = wide
            }
        }
        let help = UIHostingController(rootView: SplitHelpCard(layout: layout, scrolls: true))
        // The popover's own material behind it, not a sheet of solid colour.
        help.view.backgroundColor = .clear
        help.modalPresentationStyle = .popover
        help.preferredContentSize = CGSize(width: size.width, height: min(size.height, max(roomHeight, 200)))
        if let popover = help.popoverPresentationController {
            popover.sourceView = stage
            popover.sourceRect = anchor
            popover.permittedArrowDirections = [.down, .up]
            popover.delegate = self
        }
        splitHelpController = help
        presenter.present(help, animated: true)
    }

    func hideSplitHelp() {
        guard let help = splitHelpController else { return }
        splitHelpController = nil
        help.dismiss(animated: true)
    }

    /// The page `uuid`'s window has, in the window host's coordinates, or null
    /// while it has the whole screen. Asked by a guest window each time it is
    /// framed, so it is the one place that decides.
    @objc public func splitPaneFrame(forAppUUID uuid: String) -> CGRect {
        guard let side = framedSplitPair?.side(of: uuid) else { return .null }
        return splitPaneFrame(side)
    }

    /// The two whose windows are framed side by side: the two on screen, or two
    /// kept from going home, put away in their places so they come back as they
    /// were, and so a swipe along the bar can bring them in together. Neither
    /// where there is no room for two.
    private var framedSplitPair: SplitPair? {
        guard canSplitNow else { return nil }
        return splitPair ?? splitSuspended
    }

    /// Whether the divider can rest elsewhere than in the middle: on an iPad, as
    /// in iPadOS's own Split View. The Duo's two are always half and half, the
    /// fold between its panels.
    var splitIsResizable: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The narrowest a side may be made on an iPad: room for an app laid out
    /// for a phone.
    static let splitMinimumPaneWidth: CGFloat = 320

    private static func splitFractionKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// Where the divider rests on an iPad, as shares of `width`: a third, half
    /// and two thirds, where both sides keep room for an app laid out for a
    /// phone. Half alone where a third would be narrower than that.
    private func splitSnapFractions(width: CGFloat) -> [CGFloat] {
        [1.0 / 3, 0.5, 2.0 / 3].filter { fraction in
            fraction == 0.5
                || width * min(fraction, 1 - fraction) - Self.splitGap / 2 >= Self.splitMinimumPaneWidth
        }
    }

    /// The left side's share of the width for the two framed side by side: where
    /// the divider was left for them, kept by the two whichever side each is on,
    /// so a swap keeps the sides' sizes. Half for two never resized, for an app
    /// beside the apps to choose from, on a window too narrow for that share, and
    /// always on the Duo.
    private var splitFoldFraction: CGFloat {
        guard splitIsResizable, let pair = framedSplitPair, let left = pair.left, let right = pair.right,
              let fraction = splitFractions[Self.splitFractionKey(left, right)],
              splitSnapFractions(width: splitHostSize.width).contains(fraction) else { return 0.5 }
        return fraction
    }

    private func splitPaneFrame(_ side: SplitSide) -> CGRect {
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let area = bounds.inset(by: barReservedInsets)
        // The fold runs down the middle of the display, or on an iPad wherever
        // the divider was left for these two.
        let fold = bounds.width * splitFoldFraction
        let half = Self.splitGap / 2
        switch side {
        case .left:
            return CGRect(x: area.minX, y: area.minY,
                          width: max(fold - half - area.minX, 0), height: area.height)
        case .right:
            return CGRect(x: fold + half, y: area.minY,
                          width: max(area.maxX - fold - half, 0), height: area.height)
        }
    }

    /// A side's page less the safe area on the screen edges it reaches: where its
    /// app's content is, clear of the status bar's column.
    private func splitContentFrame(_ side: SplitSide) -> CGRect {
        var frame = splitPaneFrame(side)
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let safe = windowHostingView.window?.safeAreaInsets ?? .zero
        if frame.minX <= bounds.minX + 1 {
            frame.origin.x += safe.left
            frame.size.width -= safe.left
        }
        if frame.maxX >= bounds.maxX - 1 {
            frame.size.width -= safe.right
        }
        return frame
    }

    private func splitWindow(of uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }

    /// The home screen item an open app belongs to.
    private func splitItemID(of uuid: String) -> String? {
        apps.first { $0.appUUID == uuid }?.springboardItemID
    }

    private func runningApp(forItemID itemID: String) -> DockAppModel? {
        apps.first { $0.springboardItemID == itemID }
    }

    /// A built-in page's frame beside another app. A page runs under the bar and
    /// keeps its own content clear of it, where a guest window stops short of the
    /// bar's strip, so the page's side of the fold is carried out to the screen's
    /// own edges.
    private func splitPageFrame(forAppUUID uuid: String) -> CGRect? {
        let pane = splitPaneFrame(forAppUUID: uuid)
        guard !pane.isNull, let side = framedSplitPair?.side(of: uuid) else { return nil }
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let minX = side == .left ? bounds.minX : pane.minX
        let maxX = side == .right ? bounds.maxX : pane.maxX
        return CGRect(x: minX, y: bounds.minY, width: maxX - minX, height: bounds.height)
    }

    /// Whether a built-in page reaches the screen's `edge`, where the bar may
    /// stand: always, unless it is beside another app with the fold on that side.
    private func pageReachesEdge(_ controller: UIViewController, _ edge: ScreenEdge) -> Bool {
        guard let uuid = internalPageControllers.first(where: { $0.value === controller })?.key,
              let side = framedSplitPair?.side(of: uuid) else { return true }
        switch edge {
        case .left: return side == .left
        case .right: return side == .right
        default: return true
        }
    }

    // MARK: Starting from the home screen

    /// The home screen's "Open in Split View": the app opens on the left, and the
    /// apps to choose the second from on the right.
    func openInSplitView(_ item: FlekHomeItem) {
        guard canSplitNow else { return }
        endSplit()
        if let running = runningApp(forItemID: item.id) {
            splitPair = SplitPair.empty.with(running.appUUID, on: .left)
            relayoutSplitWindow(of: running.appUUID, animated: false)
            syncSplitChrome()
            _ = bringMultitaskViewToFront(uuid: running.appUUID)
        } else {
            splitLaunch = SplitLaunch(side: .left, itemID: item.id, source: nil)
            splitOpenHomeItem?(item)
        }
    }

    /// A window arriving for an app chosen for a side: it opens onto that side,
    /// out of the icon it was chosen by. False for any other window, which takes
    /// the whole screen as usual.
    func takeArrivingWindowIntoSplit(_ model: DockAppModel) -> Bool {
        guard let launch = splitLaunch, splitLaunch(launch, matches: model) else { return false }
        splitLaunch = nil
        splitPickerModel.launchingID = nil
        let pair = splitPair ?? .empty
        guard launch.isFresh, canSplitNow, pair.app(on: launch.side) == nil else { return false }
        apps.append(model)
        splitPair = pair.with(model.appUUID, on: launch.side)
        frontmostAppUUID = model.appUUID
        isHomeState = false
        relayoutSplitWindow(of: model.appUUID, animated: false)
        syncSplitChrome()
        if let view = model.view {
            LCMinimizeToIconAnimator.expand(view, fromItemID: model.springboardItemID,
                                            sourceInWindow: launch.source,
                                            sourceCornerRadius: launch.source == nil ? nil : SplitAppPicker.iconCornerRadius)
        }
        if !isVisible {
            showDock()
        } else {
            updateDockFrame()
            applyPreferredControl()
        }
        ensureControlAccessible()
        return true
    }

    /// Whether `model` is the app `launch` is waiting for: by the home screen
    /// item it belongs to, or failing that, by its data. An app's record can be
    /// found by the dock other than through the home screen's own, which names it
    /// by another path; its data is still where the home screen's record says.
    private func splitLaunch(_ launch: SplitLaunch, matches model: DockAppModel) -> Bool {
        if launch.itemID == model.springboardItemID { return true }
        guard let item = splitHomeItems?().first(where: { $0.id == launch.itemID }),
              case .installed(let app) = item else { return false }
        return app.appInfo.containers.contains { $0.folderName == model.appUUID }
    }

    // MARK: The apps to choose from

    /// Keeps the apps to choose from on the side with no app.
    private func syncSplitPicker(shown: Bool) {
        guard shown, let pair = splitPair, let side = pair.choosingSide,
              let host = windowHostingView.superview else {
            removeSplitPicker()
            return
        }
        let entries = splitPickerEntries(excluding: pair.app(on: side.opposite))
        if splitPickerModel.entries != entries { splitPickerModel.entries = entries }
        let frame = windowHostingView.convert(splitPaneFrame(side), to: host)
        if let picker = splitPicker {
            picker.view.frame = frame
            return
        }
        let picker = UIHostingController(rootView: AnyView(
            SplitAppPicker(model: splitPickerModel) { [weak self] itemID, source in
                self?.splitPickerChose(itemID, from: source)
            }
        ))
        picker.view.backgroundColor = .black
        picker.view.frame = frame
        picker.view.alpha = 0
        let parent = keyWindow?.rootViewController
        parent?.addChild(picker)
        host.addSubview(picker.view)
        if let parent { picker.didMove(toParent: parent) }
        splitPicker = picker
        arrangeSplitChrome()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction]) {
            picker.view.alpha = 1
        }
    }

    private func removeSplitPicker() {
        guard let picker = splitPicker else { return }
        splitPicker = nil
        splitPickerModel.launchingID = nil
        UIView.animate(withDuration: 0.2, animations: {
            picker.view.alpha = 0
        }, completion: { _ in
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            picker.removeFromParent()
        })
    }

    /// The home screen's apps and built-in pages, in its order, less the app on
    /// the other side. Open ones are marked: they are the side's switcher too.
    private func splitPickerEntries(excluding uuid: String?) -> [SplitPickerModel.Entry] {
        let excluded = uuid.flatMap { splitItemID(of: $0) }
        let running = Set(apps.compactMap(\.springboardItemID))
        let darkIcons = LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")
        return (splitHomeItems?() ?? []).compactMap { item in
            guard item.id != excluded else { return nil }
            let name: String
            switch item {
            case .defaultApp(let kind): name = kind.title
            case .installed(let app): name = app.appInfo.displayName() ?? ""
            default: return nil
            }
            return SplitPickerModel.Entry(id: item.id, name: name,
                                          icon: splitIcon(for: item, darkIcons: darkIcons),
                                          isOpen: running.contains(item.id))
        }
    }

    private func splitIcon(for item: FlekHomeItem, darkIcons: Bool) -> UIImage? {
        let key = "\(item.id)|\(darkIcons)" as NSString
        if let cached = Self.splitIconCache.object(forKey: key) { return cached }
        let image: UIImage?
        switch item {
        case .defaultApp(let kind): image = UIImage(named: kind.iconAssetName)
        case .installed(let app): image = app.appInfo.iconIsDarkIcon(darkIcons)
        default: image = nil
        }
        if let image { Self.splitIconCache.setObject(image, forKey: key) }
        return image
    }

    /// An app chosen for the side with none: an open one is moved onto it, and
    /// one not yet running is started, to open onto it when its window arrives.
    private func splitPickerChose(_ itemID: String, from source: CGRect) {
        guard canSplitNow, let side = splitPair?.choosingSide else { return }
        MultitaskDockManager.buttonHaptic()
        if let running = runningApp(forItemID: itemID) {
            placeInSplit(running.appUUID, on: side, from: source)
            return
        }
        guard let item = splitHomeItems?().first(where: { $0.id == itemID }),
              let open = splitOpenHomeItem else { return }
        splitLaunch = SplitLaunch(side: side, itemID: itemID, source: source)
        splitPickerModel.launchingID = itemID
        open(item)
        // A launch that never brings a window, refused or failed, stops showing as
        // one; the alert saying why is the home screen's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.splitLaunch?.itemID == itemID else { return }
            self.splitLaunch = nil
            self.splitPickerModel.launchingID = nil
        }
    }

    /// Puts an open app's window on `side`, out of `source` if it was put away.
    private func placeInSplit(_ uuid: String, on side: SplitSide, from source: CGRect?) {
        guard let pair = splitPair else { return }
        splitLaunch = nil
        splitPickerModel.launchingID = nil
        splitPair = pair.with(uuid, on: side)
        relayoutSplitWindow(of: uuid, animated: false)
        syncSplitChrome()
        _ = bringMultitaskViewToFront(uuid: uuid, fromRect: source,
                                      fromRectRadius: source == nil ? nil : SplitAppPicker.iconCornerRadius)
    }

    // MARK: Lifting an app

    /// The app button held long enough to lift the app in use, if one can be:
    /// from here a drag lifts it rather than switching apps.
    func splitLiftArm() -> Bool {
        guard canSplitNow, !isHomeState, !isAppSwitcherOpen, quickSwitch.drag == nil,
              let uuid = frontmostAppUUID, let view = splitWindow(of: uuid),
              !view.isHidden, view.alpha > 0.1 else { return false }
        splitLiftArmed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    func splitLiftDisarm() {
        splitLiftArmed = false
    }

    /// The held app button dragged: the app in use lifts off the screen.
    ///
    /// - Parameter keepingGrabPoint: the window shrinks about the point under the
    ///   finger and keeps hold of it, for a control that can be anywhere on the
    ///   screen (the floating button). The bar's button, along the bottom, hangs
    ///   the window above the finger instead.
    func splitLiftBegan(at point: CGPoint, keepingGrabPoint: Bool = false) -> Bool {
        guard splitLiftArmed, let uuid = frontmostAppUUID,
              beginSplitLift(of: uuid, at: point, keepingGrabPoint: keepingGrabPoint) else { return false }
        splitAppButtonTapSuppressed = true
        return true
    }

    /// The handle under `side` swiped up and held, or carried aside: that side's
    /// app lifts off the screen, in use or not, as iOS lifts an app from its own
    /// home indicator.
    private func splitHandleLiftBegan(_ side: SplitSide, at point: CGPoint) -> Bool {
        guard let uuid = splitPair?.app(on: side) else { return false }
        return beginSplitLift(of: uuid, at: point)
    }

    /// `uuid` lifts off the screen under the finger, its corners rounded like the
    /// screen's, as iOS shows an app being moved. Where it can go is shown as it
    /// goes: on its own, a shelf at each side; beside another app, the other side
    /// only, marked as a swap, and over it the app there moves across to show it.
    private func beginSplitLift(of uuid: String, at point: CGPoint,
                                keepingGrabPoint: Bool = false) -> Bool {
        guard splitLift == nil, canSplitNow, !isHomeState, !isAppSwitcherOpen,
              let view = splitWindow(of: uuid), !view.isHidden, view.alpha > 0.1,
              !LCMinimizeToIconAnimator.holdsGeometry(of: view) else { return false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let from = splitPair?.side(of: uuid)
        let other = from.flatMap { splitPair?.app(on: $0.opposite) }.flatMap { splitWindow(of: $0) }
        let grabOffset = keepingGrabPoint ? splitLiftGrabOffset(of: view, at: point) : nil
        let origin = SplitLiftOrigin(start: point, in: CGRect(origin: .zero, size: splitHostSize))
        let lift = SplitLift(uuid: uuid, view: view, center: view.center, start: point,
                             grabOffset: grabOffset, origin: origin, from: from, otherView: other)
        splitLift = lift
        view.superview?.bringSubviewToFront(view)
        // In the window's own space, so shrunk with it they are the screen's
        // corners at the app's size.
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            view.layer.cornerRadius = self.deviceScreenCornerRadius
        }
        // Out of the way while the app is in the air: they go back to where the
        // two are once it lands.
        syncSplitChrome()
        // The home screen, blurred, round the app in the air rather than black:
        // the picture a swipe along the bar shows, drawn ahead of time and small,
        // so a lift costs no drawing. The app beside it stays in view.
        showBlurredSpringboard(behind: view, keeping: other, in: windowHostingView)
        showSplitShelves(from: lift.from, swapping: lift.otherView != nil, under: lift.view)
        moveSplitLift(to: point, animated: true)
        return true
    }

    func splitLiftMoved(to point: CGPoint) {
        moveSplitLift(to: point, animated: false)
    }

    /// From the finger to the centre of `view` lifted, held by the point it was
    /// picked up by (`SplitLift.grabOffset`): the point under the finger, or with
    /// the finger off the window, the point of it nearest the finger a little in
    /// from its edge. The floating button can be over the other app of two side
    /// by side; held from there, the window hung off to one side of the finger,
    /// and from a button at the screen's edge there was no room to carry it the
    /// other way. Now it comes to the finger as it shrinks.
    private func splitLiftGrabOffset(of view: UIView, at point: CGPoint) -> CGPoint {
        // Where it rests, whatever it is drawn at just now.
        let center = view.center
        let size = view.bounds.size
        func held(_ value: CGFloat, centre: CGFloat, length: CGFloat) -> CGFloat {
            let low = centre - length / 2, high = centre + length / 2
            guard value < low || value > high else { return value }
            let inset = length * 0.1
            return min(max(value, low + inset), high - inset)
        }
        let grab = CGPoint(x: held(point.x, centre: center.x, length: size.width),
                           y: held(point.y, centre: center.y, length: size.height))
        // Shrunk about its centre, `grab` ends up this far from it.
        let scale = Self.splitLiftScale
        return CGPoint(x: (center.x - grab.x) * scale, y: (center.y - grab.y) * scale)
    }

    /// Let go: over a half with a shelf, the app takes that side, or swaps sides
    /// with the app beside it, and is the one in use; over its own half, or with
    /// the finger back at the edge it came from, it goes back (`splitDropSide`).
    func splitLiftEnded(at point: CGPoint) {
        guard let lift = splitLift else { return }
        splitLift = nil
        splitLiftArmed = false
        releaseAppButtonTapSoon()
        // Decided while the shelves are still up: which are up is what decides
        // where it can go.
        let side = splitLiftSide(lift, at: point)
        hideSplitShelves()
        let next: SplitPair?
        if let side, canSplitNow {
            if let pair = splitPair, let from = pair.side(of: lift.uuid) {
                next = side == from ? nil : pair.swapped
                // An app chosen for the other side and still starting goes where
                // that side has gone.
                if next != nil, let launch = splitLaunch {
                    splitLaunch = SplitLaunch(side: launch.side.opposite, itemID: launch.itemID, source: nil)
                }
            } else {
                endSplit()
                next = SplitPair.empty.with(lift.uuid, on: side)
            }
        } else {
            next = nil
        }
        guard let next else {
            settleSplitLift(lift)
            return
        }
        // Counted before the pair changes, which can already ask for the
        // divider: it waits for the app to have grown back into its side.
        splitSettlingCount += 1
        splitPair = next
        turnSavedSplitPairToSides()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            lift.view.transform = .identity
            lift.view.layer.cornerRadius = 0
        } completion: { _ in
            // Unless it has been lifted again since.
            if self.splitLift?.view !== lift.view { lift.restoreCorners() }
            self.splitSettlingCount = max(self.splitSettlingCount - 1, 0)
            self.syncSplitChrome()
            self.liftLandedOverBlurredSpringboard()
        }
        for uuid in next.members {
            if let other = lift.otherView, splitWindow(of: uuid) === other, lift.previewing {
                // Already where it is going, moved there to show the swap: put
                // there for real without a move of its own.
                UIView.performWithoutAnimation { other.transform = .identity }
                relayoutSplitWindow(of: uuid, animated: false)
            } else {
                relayoutSplitWindow(of: uuid, animated: true)
            }
        }
        if frontmostAppUUID != lift.uuid { windowTookStage(uuid: lift.uuid) }
        syncSplitChrome()
    }

    /// The lift taken away from the finger: the app goes back where it was.
    func splitLiftCancelled() {
        splitLiftArmed = false
        guard let lift = splitLift else { return }
        splitLift = nil
        releaseAppButtonTapSoon()
        hideSplitShelves()
        settleSplitLift(lift)
    }

    // MARK: Lifting an app out of the home dock

    /// A running app held in the home dock and carried out of it, on the home
    /// screen: a picture of the app, at the size an app is lifted at, comes out of
    /// its icon under the finger, and a shelf comes up at each side. Dropped on one,
    /// the app opens on that side out of the picture, and the other side shows the
    /// apps to choose from, as "Open in Split View" does; let go anywhere else, the
    /// picture goes back into the icon.
    final class DockLift {
        let uuid: String
        let picture: UIView
        /// Where the dock's icon is, for the picture to come out of and go back into.
        let iconFrame: CGRect?
        /// Where the finger came down.
        let start: CGPoint
        /// From the finger to the picture's centre: the picture is held as the app
        /// would be, lifted from the whole screen at the point the finger is on.
        let grabOffset: CGPoint
        /// Whether the finger has carried it anywhere yet (see `SplitLift.carried`).
        var carried = false
        var target: SplitSide?
        /// The dock's edge, back at which the finger calls it off.
        let origin: SplitLiftOrigin

        init(uuid: String, picture: UIView, iconFrame: CGRect?, start: CGPoint, grabOffset: CGPoint,
             origin: SplitLiftOrigin) {
            self.uuid = uuid
            self.picture = picture
            self.iconFrame = iconFrame
            self.start = start
            self.grabOffset = grabOffset
            self.origin = origin
        }

        func center(at point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + grabOffset.x, y: point.y + grabOffset.y)
        }
    }

    /// The home dock's icon held long enough to be carried out, if it can be: two
    /// apps can go side by side here and now, and the app is still running.
    func dockLiftArm(uuid: String) -> Bool {
        guard canSplitNow, isHomeState, !isAppSwitcherOpen, splitLift == nil, dockLift == nil,
              apps.contains(where: { $0.appUUID == uuid }) else { return false }
        dockLiftArmed = uuid
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    func dockLiftDisarm() {
        dockLiftArmed = nil
    }

    /// The held icon dragged: the app's picture comes out of it under the finger.
    func dockLiftBegan(uuid: String, at point: CGPoint) -> Bool {
        guard dockLiftArmed == uuid, dockLift == nil, splitLift == nil, canSplitNow, isHomeState,
              !isAppSwitcherOpen, let app = apps.first(where: { $0.appUUID == uuid }),
              let host = windowHostingView.superview else { return false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Laid out as the whole screen and shrunk as an app is lifted.
        let size = splitHostSize
        let picture = makeDockLiftPicture(for: app, size: size)
        picture.bounds = CGRect(origin: .zero, size: size)
        picture.center = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = Self.splitLiftScale
        let grabOffset = CGPoint(x: (size.width / 2 - point.x) * scale,
                                 y: (size.height / 2 - point.y) * scale)
        let iconFrame = app.springboardItemID.flatMap { homeDockIconFrames[$0] }
        let lift = DockLift(uuid: uuid, picture: picture, iconFrame: iconFrame,
                            start: point, grabOffset: grabOffset,
                            origin: SplitLiftOrigin(start: point, in: CGRect(origin: .zero, size: size)))
        dockLift = lift
        // Let go over the icon, its press is the end of the lift, not a tap.
        splitAppButtonTapSuppressed = true
        // Out of the icon, as tall as it, fading in as it grows.
        let source = iconFrame ?? CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)
        picture.transform = dockLiftTransform(onto: source, size: size)
        picture.alpha = 0
        showDockLiftBackdrop()
        showSplitShelves(from: nil, swapping: false)
        // In front of everything, the shelves included: it is what is being
        // carried, and the frosted shelves would hide it as it passed under them.
        host.addSubview(picture)
        moveDockLift(to: point, animated: true)
        return true
    }

    func dockLiftMoved(to point: CGPoint) {
        moveDockLift(to: point, animated: false)
    }

    /// Let go over a half, the app opens on that side; with the finger back at
    /// the dock's edge, its picture goes back into the dock (`splitDropSide`).
    func dockLiftEnded(at point: CGPoint) {
        guard let lift = dockLift else { return }
        dockLift = nil
        dockLiftArmed = nil
        releaseAppButtonTapSoon()
        let side = dockLiftSide(lift, at: point)
        hideSplitShelves()
        guard let side, canSplitNow, isHomeState, !isAppSwitcherOpen,
              apps.contains(where: { $0.appUUID == lift.uuid }) else {
            returnDockLiftPicture(lift)
            return
        }
        // Where the picture is, for the window to start from: exactly over it, at
        // the same size and corners.
        let scale = Self.splitLiftScale
        let size = lift.picture.bounds.size
        let center = lift.center(at: point)
        let rect = CGRect(x: center.x - size.width * scale / 2, y: center.y - size.height * scale / 2,
                          width: size.width * scale, height: size.height * scale)
        // As "Open in Split View" opens an app that is running already, on the
        // side it was dropped on.
        endSplit()
        splitPair = SplitPair.empty.with(lift.uuid, on: side)
        relayoutSplitWindow(of: lift.uuid, animated: false)
        syncSplitChrome()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let opened = bringMultitaskViewToFront(uuid: lift.uuid, fromRect: rect,
                                               fromRectRadius: deviceScreenCornerRadius * scale)
        guard opened else {
            splitPair = nil
            syncSplitChrome()
            returnDockLiftPicture(lift)
            return
        }
        hideDockLiftBackdrop(duration: 0.35)
        // The window takes over where the picture is.
        UIView.animate(withDuration: 0.12, delay: 0.04, options: [.allowUserInteraction]) {
            lift.picture.alpha = 0
        } completion: { _ in
            lift.picture.removeFromSuperview()
        }
    }

    /// The lift taken away from the finger: the picture goes back into the dock.
    func dockLiftCancelled() {
        dockLiftArmed = nil
        guard let lift = dockLift else { return }
        dockLift = nil
        releaseAppButtonTapSoon()
        hideSplitShelves()
        returnDockLiftPicture(lift)
    }

    private func moveDockLift(to point: CGPoint, animated: Bool) {
        guard let lift = dockLift else { return }
        let size = lift.picture.bounds.size
        let scale = Self.splitLiftScale
        let center = lift.center(at: point)
        let transform = CGAffineTransform(translationX: center.x - size.width / 2,
                                          y: center.y - size.height / 2)
            .scaledBy(x: scale, y: scale)
        let target = dockLiftSide(lift, at: point)
        let apply = {
            lift.picture.transform = transform
            lift.picture.alpha = 1
            self.highlightSplitShelves(target)
        }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: apply)
        } else {
            apply()
        }
        if target != lift.target {
            lift.target = target
            if target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    /// The side the picture is over once it has been carried (`splitDropSide`).
    private func dockLiftSide(_ lift: DockLift, at point: CGPoint) -> SplitSide? {
        if !lift.carried,
           hypot(point.x - lift.start.x, point.y - lift.start.y) >= SplitLift.carryDistance {
            lift.carried = true
        }
        guard lift.carried else { return nil }
        return splitDropSide(aim: lift.center(at: point), finger: point, origin: lift.origin)
    }

    /// Back into the dock's icon, fading as it goes, and gone.
    private func returnDockLiftPicture(_ lift: DockLift) {
        hideDockLiftBackdrop()
        let size = lift.picture.bounds.size
        let back = lift.iconFrame.map { dockLiftTransform(onto: $0, size: size) }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            if let back { lift.picture.transform = back }
            lift.picture.alpha = 0
        } completion: { _ in
            lift.picture.removeFromSuperview()
        }
    }

    /// Puts the whole-screen-sized picture over `rect`, as tall as it.
    private func dockLiftTransform(onto rect: CGRect, size: CGSize) -> CGAffineTransform {
        let scale = max(rect.height, 1) / max(size.height, 1)
        return CGAffineTransform(translationX: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            .scaledBy(x: scale, y: scale)
    }

    /// The home screen frosted and dimmed behind the lift, so the shelves and the
    /// picture stand clear of its wallpaper and icons. Over the home screen and
    /// under the windows: an app opened on a side grows out over it.
    private func showDockLiftBackdrop() {
        guard let host = windowHostingView.superview else { return }
        dockLiftBackdrop?.removeFromSuperview()
        let backdrop = UIVisualEffectView(effect: nil)
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.isUserInteractionEnabled = false
        let dim = UIView(frame: backdrop.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = .black
        dim.alpha = 0
        backdrop.contentView.addSubview(dim)
        host.insertSubview(backdrop, belowSubview: windowHostingView)
        dockLiftBackdrop = backdrop
        // Through its blur, not its alpha, under which a blur draws wrongly.
        UIView.animate(withDuration: 0.3, delay: 0, options: [.allowUserInteraction]) {
            backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            dim.alpha = 0.25
        }
    }

    private func hideDockLiftBackdrop(duration: TimeInterval = 0.3) {
        guard let backdrop = dockLiftBackdrop else { return }
        dockLiftBackdrop = nil
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            backdrop.effect = nil
            backdrop.contentView.subviews.forEach { $0.alpha = 0 }
        } completion: { _ in
            backdrop.removeFromSuperview()
        }
    }

    /// What is carried out of the dock: the app's last picture, with the screen's
    /// corners, or its icon on black for an app with no picture yet.
    private func makeDockLiftPicture(for app: DockAppModel, size: CGSize) -> UIView {
        let picture = UIView(frame: CGRect(origin: .zero, size: size))
        picture.backgroundColor = .black
        picture.isUserInteractionEnabled = false
        picture.layer.cornerRadius = deviceScreenCornerRadius
        picture.layer.cornerCurve = .continuous
        picture.layer.masksToBounds = true
        if let image = appSnapshotImages[app.appUUID] {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.frame = picture.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picture.addSubview(imageView)
        } else if let icon = SwitcherBarContentView.cachedIcon(for: app) {
            let side = min(size.width, size.height) * 0.25
            let iconView = UIImageView(image: icon)
            iconView.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                    width: side, height: side)
            iconView.layer.cornerRadius = side * 0.225
            iconView.layer.cornerCurve = .continuous
            iconView.layer.masksToBounds = true
            picture.addSubview(iconView)
        }
        return picture
    }

    private func settleSplitLift(_ lift: SplitLift) {
        // What is drawn around the two waits for it to be back in its place.
        splitSettlingCount += 1
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            lift.view.transform = .identity
            lift.view.layer.cornerRadius = 0
            lift.otherView?.transform = .identity
        } completion: { _ in
            if self.splitLift?.view !== lift.view { lift.restoreCorners() }
            self.splitSettlingCount = max(self.splitSettlingCount - 1, 0)
            self.syncSplitChrome()
            self.liftLandedOverBlurredSpringboard()
        }
    }

    /// The app in its place again: the blurred springboard goes, for the black
    /// that letterboxes the windows at rest. Not while another lift or a swipe
    /// along the bar has taken it up since, which takes it away itself.
    private func liftLandedOverBlurredSpringboard() {
        guard splitLift == nil, quickSwitch.drag == nil, quickSwitch.settling == nil else { return }
        hideBlurredSpringboard()
    }

    /// The button's own tap, if the finger is let go over it, comes in the same
    /// moment; any later one is a press of its own.
    private func releaseAppButtonTapSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.splitAppButtonTapSuppressed = false
        }
    }

    private func moveSplitLift(to point: CGPoint, animated: Bool) {
        guard let lift = splitLift else { return }
        let scale = Self.splitLiftScale
        // Shrunk about its centre and held just above the finger, as iOS holds an
        // app being moved; or by the point it was picked up by.
        let center = lift.grabOffset == nil
            ? CGPoint(x: point.x, y: point.y - lift.view.bounds.height * scale * 0.4)
            : lift.aim(point)
        let transform = CGAffineTransform(translationX: center.x - lift.center.x,
                                          y: center.y - lift.center.y)
            .scaledBy(x: scale, y: scale)
        let target = splitLiftSide(lift, at: point)
        let apply = {
            lift.view.transform = transform
            self.highlightSplitShelves(target)
        }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: apply)
        } else {
            apply()
        }
        if target != lift.target {
            lift.target = target
            if target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
        // Beside another app and over its side: that app moves across to where
        // this one was, so the swap is seen before the finger lets go, and back
        // again once the finger leaves. Its side's shelf goes while it is away:
        // the place is plainly free for the app being carried, which takes it.
        if let from = lift.from, let other = lift.otherView {
            let previewing = target == from.opposite
            if previewing != lift.previewing {
                lift.previewing = previewing
                let shift = splitPaneFrame(from).minX - splitPaneFrame(from.opposite).minX
                let shelf = splitShelves[from.opposite]
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    other.transform = previewing ? CGAffineTransform(translationX: shift, y: 0) : .identity
                }
                UIView.animate(withDuration: 0.2, delay: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    shelf?.setShown(!previewing)
                }
            }
        }
    }

    /// A shelf: in the middle of its side of the screen, where the app will land,
    /// and measured clear of the status bar's column on the side that has it.
    private func splitShelfFrame(_ side: SplitSide) -> CGRect {
        let content = splitContentFrame(side)
        let width = min(content.width * 0.55, 240)
        let height = min(content.height * 0.7, 420)
        return CGRect(x: content.midX - width / 2, y: content.midY - height / 2,
                      width: width, height: height)
    }

    /// The side a lifted app goes to with the finger at `finger` and the app
    /// centred at `aim`: the half of the screen the app is over, anywhere from the
    /// middle out, where that side has a shelf (beside another app, only the other
    /// side does). None with the finger back at the edge the lift came from,
    /// which calls it off: the app goes back as it was.
    private func splitDropSide(aim: CGPoint, finger: CGPoint, origin: SplitLiftOrigin) -> SplitSide? {
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        guard !origin.callsOff(finger, in: bounds) else { return nil }
        let side: SplitSide = aim.x < bounds.midX ? .left : .right
        return splitShelves[side] != nil ? side : nil
    }

    /// The side the window is over once it has been carried (`splitDropSide`).
    private func splitLiftSide(_ lift: SplitLift, at point: CGPoint) -> SplitSide? {
        lift.noteCarried(to: point)
        guard lift.carried else { return nil }
        return splitDropSide(aim: lift.aim(point), finger: point, origin: lift.origin)
    }

    /// The shelves for `lift`: one at each side for an app on its own; beside
    /// another app, the other side's only, marked with iOS's swap arrows where an
    /// app is there to swap with, since dropping on its own side changes nothing.
    /// - Parameters:
    ///   - from: the side the app is on already, which gets no shelf.
    ///   - swapping: an app is on the other side, to swap with.
    ///   - lifted: the window being carried. The shelves go among the windows,
    ///     just under it: frosted, they would hide it as it passed under them,
    ///     and what is carried stays in front. Without one (an app carried out
    ///     of the home dock, whose picture is put on top of everything) they go
    ///     over the windows.
    private func showSplitShelves(from: SplitSide?, swapping: Bool, under lifted: UIView? = nil) {
        guard let host = windowHostingView.superview else { return }
        let among = lifted.flatMap { $0.superview === windowHostingView ? $0 : nil }
        let sides: [SplitSide] = from.map { [$0.opposite] } ?? SplitSide.allCases
        for side in sides where splitShelves[side] == nil {
            let symbol: String
            if swapping {
                symbol = "arrow.left.arrow.right"
            } else {
                symbol = side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled"
            }
            if let among {
                let shelf = SplitShelfView(frame: splitShelfFrame(side), symbol: symbol)
                // Marked first, so the host never takes it for a window.
                windowHostingView.liftChromeViews = (windowHostingView.liftChromeViews ?? []) + [shelf as UIView]
                windowHostingView.insertSubview(shelf, belowSubview: among)
                splitShelves[side] = shelf
            } else {
                let shelf = SplitShelfView(frame: windowHostingView.convert(splitShelfFrame(side), to: host),
                                           symbol: symbol)
                host.addSubview(shelf)
                splitShelves[side] = shelf
            }
        }
        arrangeSplitChrome()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction]) {
            for shelf in self.splitShelves.values { shelf.setShown(true) }
        }
    }

    /// The shelf aimed at stands out; the others wait.
    private func highlightSplitShelves(_ target: SplitSide?) {
        for (side, shelf) in splitShelves { shelf.setAimed(side == target) }
    }

    private func hideSplitShelves() {
        let shelves = Array(splitShelves.values)
        splitShelves = [:]
        UIView.animate(withDuration: 0.2, animations: {
            shelves.forEach { $0.setShown(false) }
        }, completion: { _ in
            shelves.forEach { $0.removeFromSuperview() }
            // Only these: another lift's may be up already.
            let host = self.windowHostingView
            host.liftChromeViews = (host.liftChromeViews ?? []).filter { $0.superview === host }
        })
    }

    // MARK: Once side by side

    /// Back to one app at a time: each of the two gets the whole screen again.
    func endSplit() {
        splitLaunch = nil
        splitPickerModel.launchingID = nil
        hideSplitPaneCovers(after: 0)
        guard let pair = splitPair else { return }
        splitPair = nil
        syncSplitChrome()
        for uuid in pair.members { restoreWholeScreen(uuid) }
    }

    /// A window that has left a split given the whole screen again: now if it is
    /// in view or put away, and once it lands if it is on its way in or out,
    /// where the jump would be seen.
    private func restoreWholeScreen(_ uuid: String) {
        guard let view = splitWindow(of: uuid) else { return }
        if view.isHidden {
            relayoutSplitWindow(of: uuid, animated: false)
        } else if view.alpha < 0.1 || LCMinimizeToIconAnimator.holdsGeometry(of: view) {
            // Still flying: the other of two going home together has landed
            // first. Re-framed in the air, it grew while it shrank.
            splitLeftovers.insert(uuid)
        } else {
            relayoutSplitWindow(of: uuid, animated: true)
        }
    }

    /// Frames `uuid`'s window for the page it has now, or for the whole screen.
    private func relayoutSplitWindow(of uuid: String, animated: Bool) {
        guard let app = apps.first(where: { $0.appUUID == uuid }), let view = app.view else { return }
        let apply = {
            if app.isInternalPage {
                let pageFrame = self.splitPageFrame(forAppUUID: uuid)
                let frame = pageFrame ?? self.windowHostingView.bounds
                // Through bounds and centre, as guest windows are placed: a page
                // can be carrying a transform, and `frame` is undefined under one.
                view.bounds = CGRect(origin: .zero, size: frame.size)
                view.center = CGPoint(x: frame.midX, y: frame.midY)
                // Cut off at the fold. A page draws past its own edges where it
                // lets a row run on for its shadows, as the installer's category
                // chips do, and full screen those edges are the screen's; beside
                // another app one of them is the fold, and the row ran on over it.
                view.clipsToBounds = pageFrame != nil
                // Its room for the bar follows: kept on the edges it reaches now.
                if let controller = self.internalPageControllers[uuid] {
                    self.applyBarInset(to: controller, reserved: self.isVisible && self.isSwitcherBarVisible)
                }
            } else if let vc = view._viewDelegate() as? DecoratedAppSceneViewController {
                vc.refreshPaneLayout()
            }
        }
        if animated {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 1,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }

    /// Puts `uuid` away where it stands, without an exit of its own: it has been
    /// replaced on its side, or has gone already. Its picture goes with it: it was
    /// of the app at half the screen, and its card in the switcher, on its own,
    /// shows the app's icon until the app is on screen again.
    private func putAwayInPlace(_ uuid: String) {
        guard let view = splitWindow(of: uuid), !view.isHidden else { return }
        forgetSplitSnapshot(uuid)
        if let vc = view._viewDelegate() as? DecoratedAppSceneViewController {
            vc.finishMinimizeWindow()
        } else {
            view.isHidden = true
            view.transform = .identity
            view.superview?.sendSubviewToBack(view)
        }
        relayoutSplitWindow(of: uuid, animated: false)
    }

    /// Keeps what is drawn around the two in step with them: the backdrop under
    /// both, and while both sides are in view and no app is in the air, the apps
    /// to choose from, each app's handle and the divider on the fold.
    ///
    /// Faded as the windows go, but at once if none of them is left on the
    /// screen: faded after them, it stood there alone for as long as the fade.
    func syncSplitChrome() {
        let members = splitPair?.members ?? apps.map(\.appUUID)
        let windowsShown = members.contains { uuid in
            splitWindow(of: uuid).map { !$0.isHidden && $0.alpha > 0.1 } ?? false
        }
        if windowsShown {
            applySplitChrome()
        } else {
            UIView.performWithoutAnimation { self.applySplitChrome() }
        }
    }

    private func applySplitChrome() {
        let showing = isSplitShowing
        let windows = showing ? (splitPair?.members.compactMap { splitWindow(of: $0) } ?? []) : []
        windowHostingView.splitWindows = showing ? windows : nil
        // In view, and staying: neither setting off home, and at least one of them
        // already in place. Going home, the two fly while they are still shown,
        // and coming back they are shown before they arrive; what is drawn around
        // them goes as they set off and waits for them on the way back, so it is
        // never on the screen without them. An app chosen for an empty side flies
        // in beside one that is there already, and that leaves it all where it is.
        // The same holds for the two growing back into their sides after a lift,
        // and for the switcher closing over them.
        let inView = !windows.isEmpty
            && windows.allSatisfy { !$0.isHidden && $0.alpha > 0.1 }
            && !windows.contains(where: LCMinimizeToIconAnimator.isLeaving)
            && windows.contains { !LCMinimizeToIconAnimator.isArriving($0) }
            && splitSettlingCount == 0
            && !splitChromeAwaitsSwitcher
            // Nor while a swipe along the bar is moving the two.
            && quickSwitch.drag == nil && quickSwitch.settling == nil
        let lifting = splitLift != nil
        syncSplitPicker(shown: inView && !lifting)
        // Faded rather than taken away while an app is in the air: a handle may be
        // what is lifting it, and taken away it would let go. None with the floating
        // button: put the bar away, and the two have the screen to themselves, as
        // one app does, but for iOS's own indicator.
        syncSplitHandles(shown: inView && !usesFloatingButton, faded: lifting)
        guard inView, !lifting, let host = windowHostingView.superview else {
            if splitPair == nil {
                removeSplitDivider()
                splitCurtain?.removeFromSuperview()
                splitCurtain = nil
            } else {
                setSplitDividerShown(false)
            }
            return
        }
        let divider: SplitDividerView
        if let existing = splitDivider {
            divider = existing
        } else {
            divider = makeSplitDivider()
            // Faded in below, once it is in place.
            divider.isHidden = true
        }
        if divider.superview !== host { host.addSubview(divider) }
        // Left where it is while it is being dragged.
        if divider.transform == .identity {
            let left = splitPaneFrame(.left)
            let radius = SplitDividerView.cornerRadius
            let frame = CGRect(x: left.maxX - radius, y: left.minY,
                               width: radius * 2 + Self.splitGap, height: left.height)
            divider.frame = windowHostingView.convert(frame, to: host)
        }
        divider.showsPaired = isSplitPairSaved
        setSplitDividerShown(true)
        arrangeSplitChrome()
    }

    /// The divider faded in or out with the windows it stands between, rather
    /// than switched on and off ahead of them or behind them.
    private func setSplitDividerShown(_ shown: Bool) {
        guard let divider = splitDivider else { return }
        if shown {
            // There already, or on its way.
            guard divider.isHidden || divider.alpha < 1 else { return }
            if divider.isHidden {
                divider.alpha = 0
                divider.isHidden = false
            }
            UIView.animate(withDuration: 0.2, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                divider.alpha = 1
            }
        } else {
            // Gone already, or going.
            guard !divider.isHidden, divider.alpha > 0 else { return }
            UIView.animate(withDuration: Self.splitChromeFadeOut, delay: 0, options: [.beginFromCurrentState]) {
                divider.alpha = 0
            } completion: { _ in
                // Unless it has been asked back meanwhile.
                if divider.alpha == 0 { divider.isHidden = true }
            }
        }
    }

    /// The divider gone for good, the two no longer side by side: faded out
    /// where it stands, as the windows part.
    private func removeSplitDivider() {
        guard let divider = splitDivider else { return }
        splitDivider = nil
        guard !divider.isHidden, divider.alpha > 0 else {
            divider.removeFromSuperview()
            return
        }
        divider.isUserInteractionEnabled = false
        UIView.animate(withDuration: Self.splitChromeFadeOut, delay: 0, options: [.beginFromCurrentState]) {
            divider.alpha = 0
        } completion: { _ in
            divider.removeFromSuperview()
        }
    }

    /// What is drawn around the two, in its order over the windows: the apps to
    /// choose from, the shelves and the curtain, the handles, the divider on top.
    private func arrangeSplitChrome() {
        guard let host = windowHostingView.superview else { return }
        var views: [UIView] = []
        if let picker = splitPicker?.view { views.append(picker) }
        for side in SplitSide.allCases { if let cover = splitPaneCovers[side] { views.append(cover) } }
        for side in SplitSide.allCases { if let shelf = splitShelves[side] { views.append(shelf) } }
        if let curtain = splitCurtain { views.append(curtain) }
        for side in SplitSide.allCases { if let handle = splitHandles[side] { views.append(handle) } }
        if let divider = splitDivider { views.append(divider) }
        var below: UIView = windowHostingView
        for view in views where view.superview === host {
            host.insertSubview(view, aboveSubview: below)
            below = view
        }
    }

    private func makeSplitDivider() -> SplitDividerView {
        let divider = SplitDividerView(gap: Self.splitGap)
        divider.addGestureRecognizer(UIPanGestureRecognizer(target: self,
                                                            action: #selector(splitDividerPanned(_:))))
        divider.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                            action: #selector(splitDividerTapped)))
        divider.menuProvider = { [weak self] in self?.splitDividerMenu() }
        splitDivider = divider
        return divider
    }

    // MARK: The handles

    /// A handle under each app, where its home indicator would be on a Duo of its
    /// own. iOS's own indicator, in the middle of the screen, still goes to the
    /// iPhone's home screen; these act on their own side.
    private func syncSplitHandles(shown: Bool, faded: Bool) {
        guard shown, let pair = splitPair, let host = windowHostingView.superview else {
            removeSplitHandles()
            return
        }
        for side in SplitSide.allCases {
            guard pair.app(on: side) != nil else {
                splitHandles.removeValue(forKey: side)?.removeFromSuperview()
                continue
            }
            let handle: SplitHandleView
            let isNew = splitHandles[side] == nil
            if let existing = splitHandles[side] {
                handle = existing
            } else {
                handle = SplitHandleView()
                handle.onUse = { [weak self] in self?.splitSideHandleUsed(side) }
                handle.onLiftBegan = { [weak self] point in
                    self?.splitHandleLiftBegan(side, at: point) ?? false
                }
                handle.onLiftMoved = { [weak self] point in self?.splitLiftMoved(to: point) }
                handle.onLiftEnded = { [weak self] point, _ in
                    self?.splitLiftEnded(at: point)
                }
                handle.onLiftCancelled = { [weak self] in self?.splitLiftCancelled() }
                host.addSubview(handle)
                splitHandles[side] = handle
            }
            let content = splitContentFrame(side)
            let height = max(windowHostingView.window?.safeAreaInsets.bottom ?? 0, 20)
            let width: CGFloat = 160
            let frame = CGRect(x: content.midX - width / 2, y: content.maxY - height,
                               width: width, height: height)
            if isNew {
                // Faded in where it belongs, rather than flown there from nowhere
                // by whatever animation this was called in.
                UIView.performWithoutAnimation {
                    handle.frame = self.windowHostingView.convert(frame, to: host)
                    handle.alpha = 0
                }
                if !faded {
                    UIView.animate(withDuration: 0.2, delay: 0,
                                   options: [.allowUserInteraction, .beginFromCurrentState]) {
                        handle.alpha = 1
                    }
                }
            } else {
                handle.alpha = faded ? 0 : 1
                handle.frame = windowHostingView.convert(frame, to: host)
            }
        }
        arrangeSplitChrome()
    }

    /// The handles taken away, faded out where they stand rather than snatched:
    /// with the windows setting off home, or the bar put away.
    private func removeSplitHandles() {
        let leaving = Array(splitHandles.values)
        splitHandles = [:]
        guard !leaving.isEmpty else { return }
        for handle in leaving { handle.isUserInteractionEnabled = false }
        UIView.animate(withDuration: Self.splitChromeFadeOut, delay: 0, options: [.beginFromCurrentState]) {
            for handle in leaving { handle.alpha = 0 }
        } completion: { _ in
            for handle in leaving { handle.removeFromSuperview() }
        }
    }

    /// The floating button come up in the bar's place, or gone again. The
    /// handles go and come with the bar (see `syncSplitChrome`).
    fileprivate func splitControlChanged() {
        guard splitPair != nil else { return }
        syncSplitChrome()
    }

    /// A side's handle swiped up, or tapped: that side's app is put away, still
    /// running, and the side shows the apps to choose from. With no app on the
    /// other side either, it is the way home.
    private func splitSideHandleUsed(_ side: SplitSide) {
        guard isSplitShowing, let pair = splitPair, let uuid = pair.app(on: side),
              let view = splitWindow(of: uuid) else { return }
        let rest = pair.with(nil, on: side)
        guard let other = rest.members.first else {
            // Gone home from the page it was on, given the whole screen once out
            // of sight.
            splitPair = nil
            splitLeftovers.insert(uuid)
            syncSplitChrome()
            goHome()
            return
        }
        MultitaskDockManager.buttonHaptic()
        splitPair = rest
        splitLaunch = nil
        if frontmostAppUUID != other { windowTookStage(uuid: other) }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        } completion: { _ in
            self.putAwayInPlace(uuid)
            self.syncSplitChrome()
        }
    }

    // MARK: The divider

    /// The divider follows the finger across one side, darkening it. Let go far
    /// enough across, or flicked that way, and that side's app is put away;
    /// otherwise the divider goes back to the fold.
    @objc private func splitDividerPanned(_ pan: UIPanGestureRecognizer) {
        guard isSplitShowing, let divider = splitDivider, let host = divider.superview else {
            hideSplitPaneCovers(after: 0)
            settleSplitDivider()
            return
        }
        if splitIsResizable, let pair = splitPair, pair.left != nil, pair.right != nil {
            resizeSplit(with: pan)
            return
        }
        let left = splitPaneFrame(.left)
        let right = splitPaneFrame(.right)
        let offset = min(max(pan.translation(in: host).x, -left.width), right.width)
        let side: SplitSide = offset < 0 ? .left : .right
        let width = side == .left ? left.width : right.width
        let progress = width > 0 ? abs(offset) / width : 0
        switch pan.state {
        case .began, .changed:
            divider.transform = CGAffineTransform(translationX: offset, y: 0)
            let curtain: UIView
            if let existing = splitCurtain {
                curtain = existing
            } else {
                curtain = UIView()
                curtain.backgroundColor = .black
                curtain.isUserInteractionEnabled = false
                host.addSubview(curtain)
                splitCurtain = curtain
                arrangeSplitChrome()
            }
            curtain.frame = windowHostingView.convert(side == .left ? left : right, to: host)
            curtain.alpha = min(progress * 1.4, 0.85)
        case .ended:
            let velocity = pan.velocity(in: host).x
            let towards = side == .left ? -velocity : velocity
            if progress > 0.4 || (progress > 0.08 && towards > 800) {
                closeSplitSide(side)
            } else {
                settleSplitDivider()
            }
        default:
            settleSplitDivider()
        }
    }

    /// The divider dragged on an iPad, with an app on each side: it follows the
    /// finger, and both sides are veiled as they would be, each its app's icon on
    /// a blur, as iPadOS veils apps being resized. Let go, it rests on the nearest
    /// of a third, half or two thirds, the finger's speed carrying it on a little,
    /// and both apps are laid out for their new sides under the veils. Carried
    /// almost to an edge, the side it crossed is closed, as on the Duo.
    private func resizeSplit(with pan: UIPanGestureRecognizer) {
        guard let divider = splitDivider, let host = divider.superview, let pair = splitPair,
              let leftApp = pair.left, let rightApp = pair.right else {
            hideSplitPaneCovers(after: 0)
            settleSplitDivider()
            return
        }
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let area = bounds.inset(by: barReservedInsets)
        let fold = bounds.width * splitFoldFraction
        let x = min(max(fold + pan.translation(in: host).x, area.minX), area.maxX)
        let half = Self.splitGap / 2
        let leftWidth = x - half - area.minX
        let rightWidth = area.maxX - x - half
        let shrinking: SplitSide = leftWidth < rightWidth ? .left : .right
        let shrinkingWidth = max(min(leftWidth, rightWidth), 0)
        // Narrower than this, a side is on its way out.
        let closing = Self.splitMinimumPaneWidth * 0.7
        switch pan.state {
        case .began, .changed:
            divider.transform = CGAffineTransform(translationX: x - fold, y: 0)
            showSplitPaneCovers(left: leftApp, right: rightApp)
            layoutSplitPaneCovers(fold: x, area: area)
            let progress = max(0, (closing - shrinkingWidth) / closing)
            if progress > 0 {
                let curtain: UIView
                if let existing = splitCurtain {
                    curtain = existing
                } else {
                    curtain = UIView()
                    curtain.backgroundColor = .black
                    curtain.isUserInteractionEnabled = false
                    host.addSubview(curtain)
                    splitCurtain = curtain
                    arrangeSplitChrome()
                }
                let frame = shrinking == .left
                    ? CGRect(x: area.minX, y: area.minY, width: shrinkingWidth, height: area.height)
                    : CGRect(x: x + half, y: area.minY, width: shrinkingWidth, height: area.height)
                curtain.frame = windowHostingView.convert(frame, to: host)
                curtain.alpha = min(progress * 1.4, 0.85)
            } else {
                splitCurtain?.alpha = 0
            }
        case .ended:
            let velocity = pan.velocity(in: host).x
            let towards = shrinking == .left ? -velocity : velocity
            if shrinkingWidth < closing
                || (shrinkingWidth < Self.splitMinimumPaneWidth && towards > 800) {
                // The other app grows over the screen under its veil, which goes
                // once it has.
                hideSplitPaneCovers(after: 0.5)
                closeSplitSide(shrinking)
                return
            }
            let projected = min(max(x + velocity * 0.12, area.minX), area.maxX)
            let target = splitSnapFractions(width: bounds.width).min {
                abs(bounds.width * $0 - projected) < abs(bounds.width * $1 - projected)
            } ?? 0.5
            settleSplitFold(at: target, for: pair)
        default:
            hideSplitPaneCovers(after: 0)
            settleSplitDivider()
        }
    }

    /// The divider let go on an iPad, where it is to rest: the two laid out for
    /// their new sides, the divider carried from the finger to its place, and the
    /// veils over them until the apps have had time to draw at their new sizes.
    private func settleSplitFold(at fraction: CGFloat, for pair: SplitPair) {
        guard let left = pair.left, let right = pair.right else { return }
        if abs(fraction - splitFoldFraction) > 0.001 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        splitFractions[Self.splitFractionKey(left, right)] = fraction
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let area = bounds.inset(by: barReservedInsets)
        let fold = bounds.width * splitFoldFraction
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.layoutSplitPaneCovers(fold: fold, area: area)
        }
        // Moved to its place at once, then shown arriving there from where the
        // finger left it.
        if let divider = splitDivider {
            let shownAt = divider.center.x + divider.transform.tx
            divider.transform = .identity
            syncSplitChrome()
            divider.transform = CGAffineTransform(translationX: shownAt - divider.center.x, y: 0)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                divider.transform = .identity
            }
        } else {
            syncSplitChrome()
        }
        for uuid in pair.members { relayoutSplitWindow(of: uuid, animated: true) }
        // A side on its way out, and brought back.
        let curtain = splitCurtain
        splitCurtain = nil
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
            curtain?.alpha = 0
        } completion: { _ in
            curtain?.removeFromSuperview()
        }
        hideSplitPaneCovers(after: 0.45)
    }

    /// A veil over each side, up and ready to follow the divider.
    private func showSplitPaneCovers(left: String, right: String) {
        guard let host = windowHostingView.superview else { return }
        var added = false
        for (side, uuid) in [(SplitSide.left, left), (SplitSide.right, right)] where splitPaneCovers[side] == nil {
            let icon = apps.first(where: { $0.appUUID == uuid }).flatMap(SwitcherBarContentView.cachedIcon(for:))
            let cover = SplitPaneCoverView(icon: icon)
            host.addSubview(cover)
            splitPaneCovers[side] = cover
            added = true
        }
        guard added else { return }
        arrangeSplitChrome()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
            for cover in self.splitPaneCovers.values { cover.setShown(true) }
        }
    }

    /// The veils over the two sides as they would be with the fold at `fold`.
    private func layoutSplitPaneCovers(fold: CGFloat, area: CGRect) {
        guard let host = windowHostingView.superview else { return }
        let half = Self.splitGap / 2
        let frames: [SplitSide: CGRect] = [
            .left: CGRect(x: area.minX, y: area.minY, width: max(fold - half - area.minX, 0), height: area.height),
            .right: CGRect(x: fold + half, y: area.minY, width: max(area.maxX - fold - half, 0), height: area.height),
        ]
        for (side, cover) in splitPaneCovers {
            guard let frame = frames[side] else { continue }
            cover.frame = windowHostingView.convert(frame, to: host)
        }
    }

    /// The veils lifted, `delay` from now, and gone.
    private func hideSplitPaneCovers(after delay: TimeInterval) {
        let covers = Array(splitPaneCovers.values)
        guard !covers.isEmpty else { return }
        splitPaneCovers = [:]
        UIView.animate(withDuration: 0.25, delay: delay, options: [.allowUserInteraction]) {
            for cover in covers { cover.setShown(false) }
        } completion: { _ in
            covers.forEach { $0.removeFromSuperview() }
        }
    }

    private func settleSplitDivider() {
        let curtain = splitCurtain
        splitCurtain = nil
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.splitDivider?.transform = .identity
            curtain?.alpha = 0
        } completion: { _ in
            curtain?.removeFromSuperview()
        }
    }

    /// The divider let go across `side`: that side goes dark and its app is put
    /// away, still running, and the other app grows over the screen. A pair is
    /// parted this way. With no app on the other side, only the apps to choose
    /// from, it is the way home.
    private func closeSplitSide(_ side: SplitSide) {
        guard let pair = splitPair else { return }
        let leaving = pair.app(on: side)
        let staying = pair.app(on: side.opposite)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let leaving, let staying,
           let leavingID = splitItemID(of: leaving), let stayingID = splitItemID(of: staying) {
            forgetSplitPair(leavingID, stayingID)
        }
        // Parted, and when they are put together again it is half and half.
        if let leaving, let staying {
            splitFractions.removeValue(forKey: Self.splitFractionKey(leaving, staying))
        }
        let curtain = splitCurtain
        splitCurtain = nil
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut]) {
            curtain?.alpha = 1
        } completion: { _ in
            defer { curtain?.removeFromSuperview() }
            guard self.splitPair == pair else { return }
            // Gone with the side it closed, from where the finger left it: put
            // back on the fold to fade there, it would jump back to the middle.
            self.splitDivider?.removeFromSuperview()
            self.splitDivider = nil
            self.splitPair = nil
            self.splitLaunch = nil
            guard let staying else {
                if let leaving { self.splitLeftovers.insert(leaving) }
                self.syncSplitChrome()
                self.goHome()
                return
            }
            if let leaving { self.putAwayInPlace(leaving) }
            self.syncSplitChrome()
            if let view = self.splitWindow(of: staying) {
                view.superview?.bringSubviewToFront(view)
            }
            self.windowTookStage(uuid: staying)
            self.relayoutSplitWindow(of: staying, animated: true)
        }
    }

    // MARK: Pairs

    /// Pairs of apps that open together, as home screen items, left then right.
    private var savedSplitPairs: [[String]] {
        get { FlekSplitPairStore.shared.pairs }
        set { FlekSplitPairStore.shared.pairs = newValue }
    }

    /// The two side by side as home screen items, left then right, where each
    /// side has an app.
    private var splitPairItemIDs: (left: String, right: String)? {
        guard let pair = splitPair, let left = pair.left, let right = pair.right,
              let leftID = splitItemID(of: left), let rightID = splitItemID(of: right) else { return nil }
        return (leftID, rightID)
    }

    /// Whether the two side by side are paired, whichever way round.
    private var isSplitPairSaved: Bool {
        guard let ids = splitPairItemIDs else { return false }
        return savedSplitPairs.contains { $0.count == 2 && $0.contains(ids.left) && $0.contains(ids.right) }
    }

    /// The two's pair, if they have one, turned the way round they are now: the
    /// way they open next time.
    private func turnSavedSplitPairToSides() {
        guard let ids = splitPairItemIDs else { return }
        var pairs = savedSplitPairs
        guard let index = pairs.firstIndex(of: [ids.right, ids.left]) else { return }
        pairs[index] = [ids.left, ids.right]
        savedSplitPairs = pairs
    }

    /// The app `itemID` is paired with, and the side it opens on.
    private func savedSplitPartner(of itemID: String) -> (itemID: String, side: SplitSide)? {
        for pair in savedSplitPairs where pair.count == 2 {
            if pair[0] == itemID { return (pair[1], .right) }
            if pair[1] == itemID { return (pair[0], .left) }
        }
        return nil
    }

    private func forgetSplitPair(_ a: String, _ b: String) {
        savedSplitPairs = savedSplitPairs.filter { !($0.contains(a) && $0.contains(b)) }
    }

    /// The two paired from the divider's menu: from now on opening either opens
    /// both, each on its side. An app is in one pair at a time.
    private func pairSplitApps() {
        guard let ids = splitPairItemIDs else { return }
        FlekSplitPairStore.shared.pair(ids.left, ids.right)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        splitDivider?.showsPaired = true
    }

    /// Unpaired from the divider's menu: each opens on its own again. The two
    /// stay side by side.
    private func unpairSplitApps() {
        guard let ids = splitPairItemIDs else { return }
        forgetSplitPair(ids.left, ids.right)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        splitDivider?.showsPaired = false
    }

    // MARK: The divider's menu

    /// The divider tapped: its menu, as iPadOS opens a menu from a window's
    /// controls. Not while it is being let go of after a drag.
    @objc private func splitDividerTapped() {
        guard isSplitShowing, splitLift == nil, let divider = splitDivider,
              divider.transform == .identity else { return }
        divider.showMenu()
    }

    /// What the divider's menu offers for the two beside it: to pair them, or
    /// unpair them, to swap their sides, and to close either. Built as it opens,
    /// for what is on each side then. Beside the apps to choose from, only the
    /// swap and the app's own side.
    private func splitDividerMenu() -> UIMenu? {
        guard isSplitShowing, splitLift == nil, let pair = splitPair else { return nil }
        var arrange: [UIMenuElement] = []
        if splitPairItemIDs != nil {
            if isSplitPairSaved {
                arrange.append(UIAction(title: "lc.flek.splitMenu.unpair".loc,
                                        subtitle: "lc.flek.splitMenu.unpairDetail".loc,
                                        image: UIImage(systemName: "personalhotspot.slash")
                                            ?? UIImage(systemName: "xmark")) { [weak self] _ in
                    self?.unpairSplitApps()
                })
            } else {
                arrange.append(UIAction(title: "lc.flek.splitMenu.pair".loc,
                                        subtitle: "lc.flek.splitMenu.pairDetail".loc,
                                        image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.pairSplitApps()
                })
            }
        }
        arrange.append(UIAction(title: "lc.flek.splitMenu.swap".loc,
                                image: UIImage(systemName: "rectangle.2.swap")) { [weak self] _ in
            self?.swapSplitSides()
        })
        var close: [UIMenuElement] = []
        for side in SplitSide.allCases where pair.app(on: side) != nil {
            let title = side == .left ? "lc.flek.splitMenu.closeLeft".loc : "lc.flek.splitMenu.closeRight".loc
            close.append(UIAction(title: title, image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.closeSplitSideFromMenu(side)
            })
        }
        return UIMenu(title: "", children: [
            UIMenu(title: "", options: .displayInline, children: arrange),
            UIMenu(title: "", options: .displayInline, children: close),
        ])
    }

    /// The two swap sides from the divider's menu, each sliding across to the
    /// other's; on an iPad the sides keep their sizes (see `splitFoldFraction`).
    /// Paired, they open this way round from now on. Beside the apps to choose
    /// from, the app and the apps change sides.
    private func swapSplitSides() {
        guard isSplitShowing, splitLift == nil, let pair = splitPair else { return }
        let next = pair.swapped
        // An app chosen for the other side and still starting goes where that
        // side has gone.
        if let launch = splitLaunch {
            splitLaunch = SplitLaunch(side: launch.side.opposite, itemID: launch.itemID, source: nil)
        }
        // The apps to choose from go while the app crosses, and come back on
        // the other side once it has. Two apps cross with all else left as it
        // is: the divider stays where it is, and each side keeps its handle.
        let settles = next.choosingSide != nil
        if settles { splitSettlingCount += 1 }
        splitPair = next
        turnSavedSplitPairToSides()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        for uuid in next.members { relayoutSplitWindow(of: uuid, animated: true) }
        syncSplitChrome()
        guard settles else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.splitSettlingCount = max(self.splitSettlingCount - 1, 0)
            self.syncSplitChrome()
        }
    }

    /// A side closed from the divider's menu, as it closes when the divider is
    /// let go across it: the side goes dark, its app is put away, still
    /// running, and the other app grows over the screen.
    private func closeSplitSideFromMenu(_ side: SplitSide) {
        guard isSplitShowing, splitLift == nil, splitPair?.app(on: side) != nil else { return }
        if splitCurtain == nil, let host = windowHostingView.superview {
            let curtain = UIView()
            curtain.backgroundColor = .black
            curtain.isUserInteractionEnabled = false
            curtain.alpha = 0
            curtain.frame = windowHostingView.convert(splitPaneFrame(side), to: host)
            host.addSubview(curtain)
            splitCurtain = curtain
            arrangeSplitChrome()
        }
        // Faded with the side, rather than gone from the middle all at once.
        if let divider = splitDivider {
            UIView.animate(withDuration: 0.15) { divider.alpha = 0 }
        }
        closeSplitSide(side)
    }

    /// Whether `uuid` is paired with another app, and so has to open beside it.
    /// If it is, it is given its side now, before it comes forward or opens, and
    /// what is returned opens the other app beside it once it has. A partner gone
    /// from the home screen takes the pair with it.
    func splitPartnerOpener(for uuid: String) -> (() -> Void)? {
        guard splitPair == nil, splitLift == nil, canSplitNow,
              let itemID = splitItemID(of: uuid),
              let partner = savedSplitPartner(of: itemID) else { return nil }
        let running = runningApp(forItemID: partner.itemID)
        let item = running == nil ? splitHomeItems?().first(where: { $0.id == partner.itemID }) : nil
        guard running != nil || (item != nil && splitOpenHomeItem != nil) else {
            forgetSplitPair(itemID, partner.itemID)
            return nil
        }
        splitPair = SplitPair.empty.with(uuid, on: partner.side.opposite)
        let inView = splitWindow(of: uuid).map { !$0.isHidden && $0.alpha > 0.1 } ?? false
        relayoutSplitWindow(of: uuid, animated: inView)
        return { [weak self] in
            guard let self, self.splitPair?.contains(uuid) == true,
                  self.splitPair?.app(on: partner.side) == nil else { return }
            if let running, running.appUUID != uuid {
                self.placeInSplit(running.appUUID, on: partner.side, from: nil)
            } else if let item, let open = self.splitOpenHomeItem {
                self.splitLaunch = SplitLaunch(side: partner.side, itemID: partner.itemID, source: nil)
                self.splitPickerModel.launchingID = partner.itemID
                self.syncSplitChrome()
                open(item)
            }
        }
    }

    // MARK: In the switcher

    /// A switcher card tapped: its app comes forward out of the card, with the app
    /// beside it too where the two were kept together (see `restoreSuspendedSplit`).
    func openFromSwitcherCard(_ uuid: String, fromRect: CGRect?, fromRectRadius: CGFloat?) {
        dismissAppSwitcher()
        _ = bringMultitaskViewToFront(uuid: uuid, fromRect: fromRect, fromRectRadius: fromRectRadius)
    }

    /// Two kept from going home, together again because `uuid`, one of them, is
    /// coming forward, however it was opened: from the switcher, the home screen,
    /// the dock or the home button. The other comes forward first, so `uuid` ends
    /// in front and in use. Folded, the two come back one in front of the other,
    /// to be side by side once the phone is opened out.
    ///
    /// The other comes out of the same kind of place as `uuid`: its own icon in
    /// the home dock beside the one pressed (`fromDock`), or its own half of the
    /// switcher's card (`fromCard`). Left to find its own way, it came out of its
    /// icon on the home screen while the one pressed grew out of the dock.
    private func restoreSuspendedSplit(_ pair: SplitPair, bringingForward uuid: String,
                                       fromDock: Bool = false, fromCard: Bool = false,
                                       cardRadius: CGFloat? = nil) {
        splitSuspended = nil
        guard pair.members.allSatisfy({ splitWindow(of: $0) != nil }) else { return }
        splitPair = pair
        for member in pair.members { relayoutSplitWindow(of: member, animated: false) }
        syncSplitChrome()
        for other in pair.members where other != uuid {
            if fromCard, let card = switcherCardFrames[other] {
                _ = bringMultitaskViewToFront(uuid: other, fromRect: card, fromRectRadius: cardRadius)
            } else if fromDock, let icon = splitItemID(of: other).flatMap(dockIconFrame(forItemID:)) {
                _ = bringMultitaskViewToFront(uuid: other, fromIcon: icon)
            } else {
                _ = bringMultitaskViewToFront(uuid: other)
            }
        }
    }

    /// Where `itemID`'s icon is in the home dock: as it is laid out now, or as the
    /// home state that has just ended left it, the home button having ended it
    /// before bringing an app back out of its icon.
    private func dockIconFrame(forItemID itemID: String) -> CGRect? {
        homeDockIconFrames[itemID] ?? (isHomeState ? nil : lastHomeDockIconFrames[itemID])
    }

    /// Whether `frame` is `itemID`'s icon in the home dock, now or as the home
    /// state that has just ended left it. Two kept side by side come back one
    /// after the other, and the first to come forward ends the home state: the
    /// second's own icon, passed in a moment before, was taken for a card's.
    func isHomeDockIcon(_ frame: CGRect, forItemID itemID: String) -> Bool {
        dockIconFrame(forItemID: itemID) == frame
    }

    /// Two kept from going home become apps of their own: those still put away
    /// lose their pictures from half the screen (see `putAwayInPlace`). `shown`
    /// is coming forward, and is pictured again on screen.
    private func dissolveSuspendedSplit(except shown: String? = nil) {
        guard let pair = splitSuspended else { return }
        splitSuspended = nil
        for uuid in pair.members where uuid != shown && splitWindow(of: uuid)?.isHidden == true {
            forgetSplitSnapshot(uuid)
        }
        // Kept in their places while they were kept (see `framedSplitPair`): the
        // whole screen each, from here.
        for uuid in pair.members where splitPair?.contains(uuid) != true {
            restoreWholeScreen(uuid)
        }
    }

    private func forgetSplitSnapshot(_ uuid: String) {
        appSnapshotViews.removeValue(forKey: uuid)
        appSnapshotImages.removeValue(forKey: uuid)
        appSnapshotSizes.removeValue(forKey: uuid)
        appSnapshotRotations.removeValue(forKey: uuid)
        splitPaneSnapshots.remove(uuid)
        appSnapshotDisplays.removeValue(forKey: uuid)
    }

    /// The shape of a picture of `side`'s app, taken as `captureSnapshot` takes one
    /// beside another app: its page, less the safe area on the screen's edges it
    /// reaches, but for the side a picture of the whole screen keeps (where the
    /// status bar's column stands). What shapes a half of the two's card with no
    /// picture to show, and what the fold between the halves is measured against.
    func splitPictureShape(_ side: SplitSide) -> CGSize {
        let pane = splitPaneFrame(side)
        let bounds = CGRect(origin: .zero, size: splitHostSize)
        let safe = windowHostingView.window?.safeAreaInsets ?? .zero
        // The screen's safe area, on the edges the page shares with the screen.
        let insets = UIEdgeInsets(top: pane.minY <= bounds.minY + 1 ? safe.top : 0,
                                  left: pane.minX <= bounds.minX + 1 ? safe.left : 0,
                                  bottom: pane.maxY >= bounds.maxY - 1 ? safe.bottom : 0,
                                  right: pane.maxX >= bounds.maxX - 1 ? safe.right : 0)
        let trim = Self.pictureTrim(of: insets, turn: landscapePictureTurn(of: windowHostingView))
        return CGSize(width: max(pane.width - trim.left - trim.right, 1),
                      height: max(pane.height - trim.top - trim.bottom, 1))
    }

    // MARK: Keeping up

    /// `uuid` in front and in use, where it is already on screen.
    private func bringSplitAppForward(_ uuid: String) {
        guard let view = splitWindow(of: uuid), !view.isHidden else { return }
        view.superview?.bringSubviewToFront(view)
        if frontmostAppUUID != uuid { windowTookStage(uuid: uuid) }
    }

    /// A finger came down on `window`: a built-in page's, or a window's own
    /// edges. Of two side by side, the one touched is the one in use.
    @objc func windowTouched(_ window: UIView) {
        guard let uuid = apps.first(where: { $0.view === window })?.appUUID else { return }
        splitAppTouched(uuid)
    }

    /// An app said it was touched. Its own content's touches go to it straight,
    /// never through FlekDeck's views, so for a guest app this is the only way
    /// to know (see LCGuestSideBar.m).
    @objc func guestTouched(_ uuid: String) {
        splitAppTouched(uuid)
    }

    /// Of two side by side, the one touched is the one in use: in front, and the
    /// one the bar's buttons act on and its icon shows.
    private func splitAppTouched(_ uuid: String) {
        guard let pair = splitPair, isSplitShowing, splitLift == nil,
              pair.contains(uuid), uuid != frontmostAppUUID else { return }
        DispatchQueue.main.async {
            guard self.splitPair == pair, self.splitLift == nil, self.frontmostAppUUID != uuid,
                  let view = self.splitWindow(of: uuid) else { return }
            view.superview?.bringSubviewToFront(view)
            self.windowTookStage(uuid: uuid)
        }
    }

    /// A window set off to or from an icon, or arrived (see
    /// `LCMinimizeToIconAnimator.isLeaving` and `isArriving`). Checked after the
    /// burst, as for a window hidden or shown: a landing hides its window straight
    /// after saying so.
    func windowTravelDidChange() {
        windowVisibilityDidChange()
    }

    /// A window has set off into its icon. Checked at once rather than after the
    /// burst: nothing about it changes with the next runloop, and what is drawn
    /// around two side by side goes in the frame the two start to move.
    func windowDidDepart() {
        guard splitPair != nil else { return }
        syncSplitChrome()
    }

    /// A window was hidden or shown, or faded. Checked once, after the burst.
    @objc func windowVisibilityDidChange() {
        guard splitPair != nil || !splitLeftovers.isEmpty, !splitCheckQueued else { return }
        splitCheckQueued = true
        DispatchQueue.main.async {
            self.splitCheckQueued = false
            self.reconcileSplit()
        }
    }

    private func reconcileSplit() {
        for uuid in splitLeftovers {
            guard let view = splitWindow(of: uuid) else {
                splitLeftovers.remove(uuid)
                continue
            }
            if view.isHidden {
                splitLeftovers.remove(uuid)
                relayoutSplitWindow(of: uuid, animated: false)
            } else if view.alpha >= 0.1, !LCMinimizeToIconAnimator.holdsGeometry(of: view) {
                splitLeftovers.remove(uuid)
                relayoutSplitWindow(of: uuid, animated: true)
            }
        }
        guard let pair = splitPair else { return }
        // An app on either side put away, or gone: the split is over. Gone home
        // from with both still open, it is kept, as it was, for the switcher.
        if pair.members.contains(where: { splitWindow(of: $0)?.isHidden ?? true }) {
            if isHomeState, pair.left != nil, pair.right != nil,
               pair.members.allSatisfy({ splitWindow(of: $0) != nil }) {
                splitSuspended = pair
            } else {
                // Put away some other way: pictured at half the screen, which its
                // card on its own has no use for (see `putAwayInPlace`).
                for uuid in pair.members where splitWindow(of: uuid)?.isHidden == true {
                    forgetSplitSnapshot(uuid)
                }
            }
            endSplit()
            return
        }
        syncSplitChrome()
    }

    /// The window host changed size: folded onto the cover display, or turned.
    /// Folded, or turned upright while open, there is room for one app: the two
    /// stay together, the app last used fills the screen in front and in use, and
    /// the other waits behind it, still running. Opened out again, or turned
    /// back, they are side by side as they were. iOS keeps the app on the right,
    /// whichever was in use, and drops the other on folding; the app the user was
    /// in is the one they mean to carry on with, and the two are the user's to part.
    /// With no second app chosen yet, the one app there is is the one in front.
    /// The host re-frames every guest straight after this.
    @objc func windowHostDidResize() {
        if splitLift != nil { splitLiftCancelled() }
        refreshSplitLight()
        // Two kept are kept in their places where there is room for two, and
        // given the whole screen each where there is not (see `framedSplitPair`).
        // Guests are re-framed by the host; built-in pages are not.
        if let kept = splitSuspended {
            for uuid in kept.members where apps.first(where: { $0.appUUID == uuid })?.isInternalPage == true {
                relayoutSplitWindow(of: uuid, animated: false)
            }
        }
        guard let pair = splitPair else { return }
        let keeper = frontmostAppUUID.flatMap { pair.contains($0) ? $0 : nil } ?? pair.right ?? pair.left
        syncSplitChrome()
        // Side by side or not any more, another app may be under the column.
        refreshSideColumnRoom()
        // Not for a turn the switcher makes, for itself and back.
        if !isSplitShowing, !isOpeningAppSwitcher, !isAppSwitcherOpen, let keeper {
            DispatchQueue.main.async { self.bringSplitAppForward(keeper) }
        }
        // Guests are re-framed by the host; built-in pages are not.
        for uuid in pair.members where apps.first(where: { $0.appUUID == uuid })?.isInternalPage == true {
            relayoutSplitWindow(of: uuid, animated: false)
        }
    }
}

/// The app button held, then dragged: the app in use lifts off the screen under
/// the finger, to be dropped on a side of an iPhone Duo opened out. iOS lifts an
/// app the same way, with a swipe up from its home indicator held a moment; here
/// the app button is the home indicator, since that swipe is iOS's own.
///
/// The same press and drag on a running app's icon in the home dock carries that
/// app out of the dock instead (`dockAppUUID`, see `MultitaskDockManager.DockLift`).
@available(iOS 16.0, *)
private struct SplitLiftGesture: ViewModifier {
    /// The running app a home dock icon stands for; nil for the app button, which
    /// lifts the app in use.
    let dockAppUUID: String?
    /// The one manager there is, which is also what the bar is handed as its
    /// environment object; read directly so the home dock, which is not, can use
    /// this too.
    private var dockManager: MultitaskDockManager { .shared }
    @State private var reading = SplitLiftReading()
    /// True while the press is live, so a gesture the system takes over, which
    /// SwiftUI never ends, still puts the app back.
    @GestureState private var isPressing = false

    /// Written out: with private state beside it, the one Swift would make is
    /// private too, and the home dock's icon could not call it.
    init(dockAppUUID: String? = nil) {
        self.dockAppUUID = dockAppUUID
    }

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3, maximumDistance: 12)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($isPressing) { _, pressing, _ in pressing = true }
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if !reading.armed {
                        reading.armed = true
                        reading.canLift = arm()
                    }
                    guard reading.canLift, let drag else { return }
                    if !reading.lifted {
                        reading.lifted = begin(at: drag.startLocation)
                        if !reading.lifted { reading.canLift = false }
                    }
                    if reading.lifted { move(to: drag.location) }
                }
                .onEnded { value in
                    defer { reading.reset() }
                    guard reading.lifted else {
                        if reading.armed { disarm() }
                        return
                    }
                    if case .second(true, let drag?) = value {
                        end(at: drag.location)
                    } else {
                        cancel()
                    }
                }
        )
        .onChange(of: isPressing) { pressing in
            if !pressing { cancelUnended() }
        }
        // Nor does a bar torn down mid-lift tell its gesture anything.
        .onDisappear { cancelUnended() }
    }

    /// Puts back what a cancelled lift moved, a turn of the run loop later: a
    /// press that ended has been through onEnded by then.
    private func cancelUnended() {
        let reading = reading, gesture = self
        DispatchQueue.main.async {
            defer { reading.reset() }
            if reading.lifted {
                gesture.cancel()
            } else if reading.armed {
                gesture.disarm()
            }
        }
    }

    // The lift this press drives: the app in use's, or a dock app's.

    private func arm() -> Bool {
        dockAppUUID.map { dockManager.dockLiftArm(uuid: $0) } ?? dockManager.splitLiftArm()
    }

    private func disarm() {
        if dockAppUUID != nil { dockManager.dockLiftDisarm() } else { dockManager.splitLiftDisarm() }
    }

    private func begin(at point: CGPoint) -> Bool {
        if let uuid = dockAppUUID { return dockManager.dockLiftBegan(uuid: uuid, at: point) }
        return dockManager.splitLiftBegan(at: point)
    }

    private func move(to point: CGPoint) {
        if dockAppUUID != nil { dockManager.dockLiftMoved(to: point) } else { dockManager.splitLiftMoved(to: point) }
    }

    private func end(at point: CGPoint) {
        if dockAppUUID != nil {
            dockManager.dockLiftEnded(at: point)
        } else {
            dockManager.splitLiftEnded(at: point)
        }
    }

    private func cancel() {
        if dockAppUUID != nil { dockManager.dockLiftCancelled() } else { dockManager.splitLiftCancelled() }
    }
}

/// The lift's reading of the press under way, kept in a reference so that
/// updating it is not a change of view state.
private final class SplitLiftReading {
    var armed = false
    var canLift = false
    var lifted = false

    func reset() {
        armed = false
        canLift = false
        lifted = false
    }
}

/// The apps the side with no app chooses from.
final class SplitPickerModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: UIImage?
        let isOpen: Bool
    }

    @Published var entries: [Entry] = []
    /// The app chosen and starting up, shown as such until its window arrives.
    @Published var launchingID: String?
}

/// The apps to choose from on a side of the screen with no app: a page of the
/// home screen on the wallpaper, as iOS shows on its own Duo, with the apps
/// already open first, since this is that side's switcher too.
struct SplitAppPicker: View {
    static let iconSize: CGFloat = 58
    static let iconCornerRadius: CGFloat = SplitAppPicker.iconSize * 0.225

    @ObservedObject var model: SplitPickerModel
    let choose: (String, CGRect) -> Void

    var body: some View {
        let open = model.entries.filter(\.isOpen)
        let others = model.entries.filter { !$0.isOpen }
        ZStack {
            FlekWallpaperView()
                .overlay(Color.black.opacity(0.2))
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !open.isEmpty {
                        section("Open", open)
                    }
                    section(open.isEmpty ? nil : "Apps", others)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func section(_ title: String?, _ entries: [SplitPickerModel.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 10)],
                      spacing: 18) {
                ForEach(entries) { entry in
                    SplitPickerCell(entry: entry,
                                    isLaunching: model.launchingID == entry.id,
                                    choose: choose)
                }
            }
        }
    }
}

private struct SplitPickerCell: View {
    let entry: SplitPickerModel.Entry
    let isLaunching: Bool
    let choose: (String, CGRect) -> Void
    /// Where the icon is in the window: the app opens out of it.
    @State private var iconFrame: CGRect = .zero

    var body: some View {
        Button {
            choose(entry.id, iconFrame)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let icon = entry.icon {
                        Image(uiImage: icon).resizable()
                    } else {
                        Color.white.opacity(0.2)
                    }
                    if isLaunching {
                        Color.black.opacity(0.35)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                }
                .frame(width: SplitAppPicker.iconSize, height: SplitAppPicker.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: SplitAppPicker.iconCornerRadius,
                                            style: .continuous))
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { iconFrame = geometry.frame(in: .global) }
                            .onChange(of: geometry.frame(in: .global)) { iconFrame = $0 }
                    }
                )
                Text(entry.name)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
    }
}

/// The black on the fold between two apps side by side: the gap itself, the
/// corners that round each app off on its side of it, and a handle to drag.
/// Drawn over the two windows rather than cut out of them, so whatever a window
/// is doing — opening out of an icon, flying home — its own corners are left
/// alone. Tapped, it opens a menu for the two (`showMenu`); while they are
/// paired, the handle parts round a small link.
final class SplitDividerView: UIView, UIContextMenuInteractionDelegate {
    /// The corners each app is rounded off by beside the fold.
    static let cornerRadius: CGFloat = 14
    /// The handle's grey: white at 0.55 over the line's black, but opaque, so
    /// its two halves can overlap unseen.
    private static let handleColor = UIColor(white: 0.55, alpha: 1)
    private static let handleLength: CGFloat = 44
    /// From the middle of the handle to each half's inner end while the two are
    /// paired: room for the link, and a little either side of it.
    private static let linkClearance: CGFloat = 10
    /// The link stood upright, one loop above the other, to fit inside the gap:
    /// the symbol leans from bottom left to top right.
    private static let linkUpright = CGAffineTransform(rotationAngle: -.pi / 4)
    private static let presentMenuSelector = NSSelectorFromString("_presentMenuAtLocation:")
    /// Whether a tap can open the menu: through the call UIKit itself opens a
    /// button's menu with. Where it cannot, holding the line opens it instead.
    private static let opensMenuOnTap =
        UIContextMenuInteraction.instancesRespond(to: SplitDividerView.presentMenuSelector)

    let gap: CGFloat
    /// The two are paired, and opening either opens both. Shown in the handle:
    /// its two halves part, and a link stands between them.
    var showsPaired = false {
        didSet {
            guard showsPaired != oldValue else { return }
            accessibilityValue = showsPaired ? "Paired" : nil
            let shown = showsPaired
            let apply = {
                self.layoutHandle()
                self.link.alpha = shown ? 1 : 0
                self.link.transform = shown ? Self.linkUpright : Self.linkUpright.scaledBy(x: 0.5, y: 0.5)
            }
            // Parting where it can be seen; set as it is otherwise.
            if window != nil, !isHidden, alpha > 0.01 {
                UIView.animate(withDuration: 0.45, delay: 0,
                               usingSpringWithDamping: shown ? 0.7 : 1, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState],
                               animations: apply)
            } else {
                UIView.performWithoutAnimation(apply)
            }
        }
    }
    /// What the menu offers, asked for as it opens: it depends on what is on
    /// each side at the time.
    var menuProvider: (() -> UIMenu?)?

    private let shape = CAShapeLayer()
    /// The handle, in two halves, which overlap into one while the two are not
    /// paired.
    private let handleTop = UIView()
    private let handleBottom = UIView()
    private let link = UIImageView(image: UIImage(systemName: "link",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 10,
                                                                                                 weight: .semibold)))
    /// What the menu hangs from: the handle.
    private let menuAnchor = UIView()
    private lazy var menuInteraction = UIContextMenuInteraction(delegate: self)
    /// A tap asked for the menu. A finger held on the line is a drag that has
    /// yet to move, and opens nothing.
    private var menuRequested = false

    init(gap: CGFloat) {
        self.gap = gap
        super.init(frame: .zero)
        backgroundColor = .clear
        shape.fillColor = UIColor.black.cgColor
        layer.addSublayer(shape)
        for half in [handleTop, handleBottom] {
            half.backgroundColor = Self.handleColor
            half.layer.cornerRadius = 2
            half.isUserInteractionEnabled = false
            addSubview(half)
        }
        link.tintColor = Self.handleColor
        link.contentMode = .center
        link.isUserInteractionEnabled = false
        link.alpha = 0
        link.transform = Self.linkUpright.scaledBy(x: 0.5, y: 0.5)
        addSubview(link)
        menuAnchor.isUserInteractionEnabled = false
        addSubview(menuAnchor)
        addInteraction(menuInteraction)
        isAccessibilityElement = true
        accessibilityLabel = "Split View Divider"
        accessibilityHint = "Shows options for the two apps."
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        let r = Self.cornerRadius
        let width = bounds.width, height = bounds.height
        // The gap, and beside it at the top and bottom the four corners that round
        // each app off: each the corner of its app's side less a quarter circle.
        // Drawn as pieces rather than cut out of the whole strip with the even-odd
        // rule, whose cut edges, lying along the strip's own, left a hairline down
        // each side of it.
        let path = UIBezierPath(rect: CGRect(x: r, y: 0, width: width - 2 * r, height: height))
        func corner(_ point: CGPoint, center: CGPoint, from start: CGFloat, to end: CGFloat, clockwise: Bool) {
            let piece = UIBezierPath()
            piece.move(to: point)
            piece.addArc(withCenter: center, radius: r, startAngle: start, endAngle: end, clockwise: clockwise)
            piece.close()
            path.append(piece)
        }
        corner(CGPoint(x: r, y: 0), center: CGPoint(x: 0, y: r), from: 0, to: -.pi / 2, clockwise: false)
        corner(CGPoint(x: r, y: height), center: CGPoint(x: 0, y: height - r), from: 0, to: .pi / 2, clockwise: true)
        corner(CGPoint(x: width - r, y: 0), center: CGPoint(x: width, y: r), from: .pi, to: .pi * 1.5, clockwise: true)
        corner(CGPoint(x: width - r, y: height), center: CGPoint(x: width, y: height - r), from: .pi, to: .pi / 2, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path.cgPath
        CATransaction.commit()
        layoutHandle()
        menuAnchor.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - Self.handleLength / 2 - 6,
                                  width: 32, height: Self.handleLength + 12)
    }

    /// The handle's halves: apart round the link while the two are paired, and
    /// otherwise overlapping into one, far enough that each half's rounded inner
    /// end lies along the other's straight, so no waist shows where they meet.
    private func layoutHandle() {
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let half = Self.handleLength / 2
        let inner = showsPaired ? -Self.linkClearance : 4
        handleTop.frame = CGRect(x: mid.x - 2, y: mid.y - half, width: 4, height: half + inner)
        handleBottom.frame = CGRect(x: mid.x - 2, y: mid.y - inner, width: 4, height: half + inner)
        link.center = mid
    }

    /// The gap and a few points either side of it: enough to take hold of,
    /// without taking touches meant for the apps' edges.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        abs(point.x - bounds.midX) <= gap / 2 + 8 && point.y >= 0 && point.y <= bounds.height
    }

    // MARK: The menu

    /// Opens the menu, hanging from the handle as a button's menu hangs from
    /// the button.
    func showMenu() {
        guard Self.opensMenuOnTap, window != nil else { return }
        let selector = Self.presentMenuSelector
        guard let implementation = menuInteraction.method(for: selector) else { return }
        layoutIfNeeded()
        menuRequested = true
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(implementation, to: Present.self)
        present(menuInteraction, selector, CGPoint(x: menuAnchor.frame.midX, y: menuAnchor.frame.midY))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard menuRequested || !Self.opensMenuOnTap, let menu = menuProvider?() else { return nil }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        // Pairing first and closing last, whether the menu opens above the
        // handle or below it.
        if #available(iOS 16.0, *) { configuration.preferredMenuElementOrder = .fixed }
        return configuration
    }

    @available(iOS 16.0, *)
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuAnchorPreview()
    }

    @available(iOS 16.0, *)
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuAnchorPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        menuRequested = false
    }

    /// The menu hangs from the handle as a button's does, rather than the whole
    /// line lifting out of the screen, as a view held for its menu does: UIKit's
    /// own compact layout, where it has it.
    @objc(_contextMenuInteraction:styleForMenuWithConfiguration:)
    func contextMenuStyle(_ interaction: UIContextMenuInteraction,
                          configuration: UIContextMenuConfiguration) -> NSObject? {
        let defaultStyle = NSSelectorFromString("defaultStyle")
        guard let styleClass = NSClassFromString("_UIContextMenuStyle") as? NSObject.Type,
              styleClass.responds(to: defaultStyle),
              let style = styleClass.perform(defaultStyle)?.takeUnretainedValue() as? NSObject,
              style.responds(to: NSSelectorFromString("setPreferredLayout:")) else { return nil }
        style.setValue(3, forKey: "preferredLayout")
        return style
    }

    /// Clear: the menu only needs somewhere to hang from.
    private func menuAnchorPreview() -> UITargetedPreview? {
        guard menuAnchor.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: menuAnchor.bounds,
                                              cornerRadius: menuAnchor.bounds.width / 2)
        return UITargetedPreview(view: menuAnchor, parameters: parameters)
    }
}

/// The handle under one of two apps side by side, where its home indicator
/// would be on a Duo of its own: swiped up, or tapped, that side shows the apps
/// to choose from.
/// How Split View works, for someone who has not used it: shown in a popover
/// when the home screen's split light is tapped. Where things stand first, and
/// what would make it ready; then how to start, other ways in, what can be done
/// with two side by side, what the light's colours mean, and the switch that
/// hides the light (Personalization brings it back).
@available(iOS 16.0, *)
struct SplitHelpCard: View {
    /// One column, the card's natural shape; or two side by side where one
    /// would be taller than the room above the light: an iPad held sideways
    /// leaves little height between the status bar and the pill, and plenty
    /// across.
    enum Layout {
        case column, columns

        var width: CGFloat { self == .column ? 340 : 680 }
    }

    let layout: Layout
    /// Scrolls where even its layout is taller than the popover can be, rather
    /// than being cut off at the top and bottom.
    let scrolls: Bool

    @ObservedObject private var dockManager = MultitaskDockManager.shared
    @AppStorage(FlekDeckKeys.splitLightShown, store: LCUtils.appGroupUserDefault)
    private var showsLight = true

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            status
            switch layout {
            case .column:
                howTo
                moreWays
                sideBySide
                legend
            case .columns:
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        howTo
                        moreWays
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 18) {
                        sideBySide
                        legend
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("lc.flek.splitHelp.toggle".loc, isOn: $showsLight)
                Text("lc.flek.splitHelp.toggleFooter".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: layout.width, alignment: .leading)
    }

    /// Where things stand, and what would make it ready.
    private var status: some View {
        let light = dockManager.splitLight ?? .available
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(light.isAvailable ? Color(uiColor: .systemGreen) : Color(uiColor: .systemRed))
                    .frame(width: 9, height: 9)
                Text(light.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = light.reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lc.flek.splitHelp.intro".loc)
                .font(.subheadline.weight(.semibold))
            step(1, "lc.flek.splitHelp.step1".loc)
            step(2, "lc.flek.splitHelp.step2".loc)
            step(3, "lc.flek.splitHelp.step3".loc)
        }
    }

    private var moreWays: some View {
        section("lc.flek.splitHelp.moreWays".loc, rows: [
            ("hand.draw", "lc.flek.splitHelp.more1".loc),
            ("square.grid.2x2", "lc.flek.splitHelp.more2".loc),
        ])
    }

    private var sideBySide: some View {
        section("lc.flek.splitHelp.sideBySide".loc, rows: [
            ("arrow.left.and.right", "lc.flek.splitHelp.side1".loc),
            ("xmark.rectangle", "lc.flek.splitHelp.side2".loc),
            ("link", "lc.flek.splitHelp.side3".loc),
        ])
    }

    private var legend: some View {
        Text("lc.flek.splitHelp.legend".loc)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, rows: [(symbol: String, text: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(row.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A side's drop zone while an app is lifted: dark frosted, outlined and marked,
/// so it reads over anything under it, the home screen's wallpaper and icons
/// included. Shown and aimed at through its blur and its marks, never its own
/// alpha, under which a blur draws wrongly.
final class SplitShelfView: UIView {
    private static let cornerRadius: CGFloat = 26
    private static let blurEffect = UIBlurEffect(style: .systemThinMaterialDark)

    private let blur = UIVisualEffectView(effect: nil)
    private let fill = UIView()
    private let outline = UIView()
    private let glyph: UIImageView
    private var isShown = false

    init(frame: CGRect, symbol: String) {
        glyph = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)))
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for part in [blur, fill, outline] {
            part.frame = bounds
            part.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            part.layer.cornerRadius = Self.cornerRadius
            part.layer.cornerCurve = .continuous
            part.isUserInteractionEnabled = false
            addSubview(part)
        }
        blur.clipsToBounds = true
        fill.backgroundColor = .white
        outline.layer.borderWidth = 2
        outline.layer.borderColor = UIColor.white.cgColor
        glyph.tintColor = .white
        glyph.sizeToFit()
        glyph.center = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                  .flexibleTopMargin, .flexibleBottomMargin]
        addSubview(glyph)
        applyMarks(aimed: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Up or gone, in whatever animation it is called in.
    func setShown(_ shown: Bool) {
        isShown = shown
        blur.effect = shown ? Self.blurEffect : nil
        applyMarks(aimed: false)
    }

    /// The one the app is over: brighter, and a little bigger. The blur is left
    /// alone, so aiming never restarts it.
    func setAimed(_ aimed: Bool) {
        guard isShown else { return }
        applyMarks(aimed: aimed)
    }

    private func applyMarks(aimed: Bool) {
        fill.alpha = !isShown ? 0 : aimed ? 0.24 : 0.06
        outline.alpha = !isShown ? 0 : aimed ? 1 : 0.7
        glyph.alpha = !isShown ? 0 : aimed ? 1 : 0.9
        transform = aimed ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
    }
}

/// A side veiled while the divider is dragged on an iPad: what is under it
/// blurred, and its app's icon in the middle, as iPadOS shows an app being
/// resized. Shown and hidden through its blur and its icon, never its own alpha.
final class SplitPaneCoverView: UIView {
    private static let blurEffect = UIBlurEffect(style: .systemThickMaterial)
    private let blur = UIVisualEffectView(effect: nil)
    private let iconView = UIImageView()

    init(icon: UIImage?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerRadius = SplitDividerView.cornerRadius
        layer.cornerCurve = .continuous
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        iconView.image = icon
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 16
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.alpha = 0
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        let side: CGFloat = 72
        iconView.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                width: side, height: side)
    }

    /// Up or gone, in whatever animation it is called in.
    func setShown(_ shown: Bool) {
        blur.effect = shown ? Self.blurEffect : nil
        iconView.alpha = shown ? 1 : 0
    }
}

final class SplitHandleView: UIView {
    var onUse: (() -> Void)?
    /// Lifting the app from the handle: where the finger is, in the window.
    var onLiftBegan: ((CGPoint) -> Bool)?
    var onLiftMoved: ((CGPoint) -> Void)?
    var onLiftEnded: ((CGPoint, CGFloat) -> Void)?
    var onLiftCancelled: (() -> Void)?
    private var lifting = false
    private var pause: Timer?
    private let pill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        pill.backgroundColor = UIColor(white: 0.5, alpha: 0.8)
        pill.layer.cornerRadius = 2.5
        pill.isUserInteractionEnabled = false
        addSubview(pill)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "Choose Another App"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Where iOS draws its own indicator, a little above the bottom edge.
        pill.frame = CGRect(x: bounds.midX - 50, y: bounds.maxY - 13, width: 100, height: 5)
    }

    @objc private func tapped() { onUse?() }

    /// Up and let go, as a swipe: `onUse`. Up and held a moment, or up and carried
    /// aside: the app lifts, as iOS lifts an app with a swipe up from its home
    /// indicator held a moment, and the drag carries it from there.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        // In the view it stands in, the space the windows are placed in, rather
        // than the window's base coordinates, which on the iPhone Duo's inner
        // display can come out a quarter turned (see `navAssistLiftPoint`).
        let point = pan.location(in: superview)
        let translation = pan.translation(in: self)
        switch pan.state {
        case .changed:
            if lifting {
                onLiftMoved?(point)
                return
            }
            guard translation.y < -30 else { return }
            if abs(translation.x) > 40 {
                beginLift(at: point)
            } else {
                waitForPause(of: pan)
            }
        case .ended:
            pause?.invalidate()
            if lifting {
                lifting = false
                onLiftEnded?(point, pan.velocity(in: superview).x)
                return
            }
            let velocity = pan.velocity(in: self)
            if translation.y < -24 || velocity.y < -500 { onUse?() }
        case .cancelled, .failed:
            pause?.invalidate()
            if lifting {
                lifting = false
                onLiftCancelled?()
            }
        default:
            break
        }
    }

    /// The finger held still for a moment, up from the edge: the app lifts there.
    /// Started again by every move, so it only fires on a pause.
    private func waitForPause(of pan: UIPanGestureRecognizer) {
        pause?.invalidate()
        pause = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self, weak pan] _ in
            guard let self, let pan, !self.lifting,
                  pan.state == .began || pan.state == .changed else { return }
            self.beginLift(at: pan.location(in: self.superview))
        }
    }

    private func beginLift(at point: CGPoint) {
        pause?.invalidate()
        lifting = onLiftBegan?(point) ?? false
        if lifting { onLiftMoved?(point) }
    }
}

@available(iOS 16.0, *)
extension MultitaskDockManager: UIPopoverPresentationControllerDelegate {
    /// The split help stays a popover pointing at its light, also in a window
    /// narrow enough that iOS would otherwise make it a sheet.
    public func adaptivePresentationStyle(for controller: UIPresentationController,
                                          traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

@available(iOS 16.0, *)
extension MultitaskDockManager: UIGestureRecognizerDelegate {
    /// The floating button's lift starts only where it can lift something; a
    /// hold anywhere else is left to the drag that moves the button.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UILongPressGestureRecognizer,
              gestureRecognizer.view === navAssistButton else { return true }
        return !isNavAssistStashed && canSplitNow && !isHomeState && !isAppSwitcherOpen
            && splitLift == nil
    }
}
