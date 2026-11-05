//
//  FlekDeckModel.swift
//  LiveContainerSwiftUI
//
//  Shared model + value types for the FlekDeck springboard.
//

import SwiftUI

/// AppStorage keys used by the launcher. Stored in the app group so they are
/// shared across LiveContainer instances, matching the rest of the app.
enum FlekDeckKeys {
    static let wallpaperName = "FlekWallpaperName"   // bundled wallpaper asset name
    static let wallpaperPhoto = "FlekWallpaperPhoto" // file name of a user-picked photo wallpaper
    static let homeLayout = "FlekHomeLayout"         // "grid" | "list"
    static let homeBarPosition = "FlekHomeBarPosition" // "bottom" | "side" — iPhone Duo only
    static let launchedApps = "FlekLaunchedApps"     // bundle paths that have been opened at least once
    static let homeScreenOrder = "FlekHomeScreenOrder" // ordered IDs of all home screen items (default apps + installed)
    static let homeScreenPageSizes = "FlekHomeScreenPageSizes" // per-page item counts for custom page layouts
    static let cardStyleGlass = "FlekCardStyleGlass" // true = liquid glass, false = thin material
    static let glassStyle = "FlekGlassStyle"         // "liquid" | "frosted"
}

/// Home screen layout chosen on the Personalization page.
enum FlekHomeLayout: String {
    case grid
    case list
}

/// Where the home screen keeps its search button and running apps, chosen on the
/// Personalization page. Offered only on the iPhone Duo, whose status bar runs down
/// one side of the display: `side` stands them in that same column, below it, and
/// gives the room they took at the bottom back to the grid.
enum FlekHomeBarPosition: String {
    case bottom
    case side
}

/// How FlekDeck draws its own glass, chosen on the Personalization page: Liquid
/// Glass, or frosted — the simpler blur the same surfaces have before iOS 26.
/// Offered from iOS 26 on; before it, everything is frosted either way.
enum FlekGlassStyle: String {
    case liquid
    case frosted
}

/// The three built-in "apps" pinned at the start of the home screen.
/// They open internal FlekDeck pages instead of a guest app.
enum FlekDefaultAppKind: String, CaseIterable, Identifiable {
    case flekstore
    case settings
    case installer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flekstore: return "FlekSt0re"
        case .settings: return "lc.tabView.settings".loc
        case .installer: return "Installer"
        }
    }

    var iconAssetName: String {
        switch self {
        case .flekstore: return "FlekIconFlekStore"
        case .settings: return "FlekIconSettings"
        case .installer: return "FlekIconInstaller"
        }
    }

    /// The number in the corner of this app's home screen icon, as iOS badges
    /// an app with something waiting; 0 draws none. Settings counts what it is
    /// waiting on the user for: a certificate missing or no longer working,
    /// and an end of Premium not looked at yet.
    func badgeCount(in model: SharedModel) -> Int {
        switch self {
        case .settings: return model.settingsAttentionCount
        case .flekstore, .installer: return 0
        }
    }
}

/// The control edit mode draws in an item's corner.
enum FlekEditBadge {
    /// No control — the item is not an app the user manages.
    case none
    /// The minus, which uninstalls.
    case remove
}

/// One tile on the springboard: a built-in app, an installed guest app, the
/// app currently being installed, or an empty grid slot (placeholder).
enum FlekHomeItem: Identifiable, DragulaItem {
    case defaultApp(FlekDefaultAppKind)
    case installed(LCAppModel)
    case installing(InstallItem)
    /// Empty grid slot that preserves an item's position on the grid.
    case placeholder(String)

    var id: String {
        switch self {
        case .defaultApp(let kind): return "default.\(kind.rawValue)"
        case .installed(let app): return Self.installedID(for: app.appInfo)
        case .installing(let item): return "installing.\(item.id)"
        case .placeholder(let uid): return "placeholder.\(uid)"
        }
    }

    /// The id an installed app's tile is filed under, derived from its bundle
    /// alone. Callers holding only an `LCAppInfo` — the multitask dock registers
    /// its windows by app info, not by model — can name the same tile without
    /// building an `LCAppModel` just to ask it, and cannot drift from the id the
    /// springboard actually uses, because this is where that id comes from.
    static func installedID(for appInfo: LCAppInfo) -> String {
        "app.\(appInfo.relativeBundlePath ?? appInfo.bundlePath() ?? "unknown")"
    }

    /// What a tile draws, beyond which tile it is. Two items with the same
    /// `id` but different signatures are one tile showing something new — an
    /// app converted to shared or renamed, set to launch with JIT, a badge on
    /// Settings coming or going
    /// — which the springboard has to be told about: its cells are configured
    /// once and then left alone, so a change that adds and removes nothing
    /// never reaches them otherwise. Install progress is deliberately absent;
    /// the queue drives that itself.
    var displaySignature: String {
        switch self {
        case .installed(let app):
            return "\(id)|\(app.uiIsShared ? "s" : "p")|\(app.uiIsJITNeeded ? "j" : "")|\(app.appInfo.displayName() ?? "")"
        case .defaultApp(let kind):
            return "\(id)|\(kind.badgeCount(in: DataManager.shared.model))"
        default:
            return id
        }
    }

    /// Only real app items can be dragged.
    var isDraggable: Bool {
        switch self {
        case .placeholder: return false
        default: return true
        }
    }

    /// Whether this item is an empty grid slot.
    var isPlaceholder: Bool {
        if case .placeholder = self { return true }
        return false
    }

    /// What edit mode puts in the corner of this item.
    ///
    /// Every installed app gets the minus, a shared one included: a shared
    /// bundle is not this install's to take away, so deleting it converts it to
    /// a private app first, which `requestUninstall` asks about and does. Only
    /// the built-in pages and empty slots have nothing to remove.
    var editBadge: FlekEditBadge {
        if case .installed = self { return .remove }
        return .none
    }

    func getItemProvider() -> NSItemProvider {
        NSItemProvider(object: id as NSString)
    }
}

/// Snapshot of the in-progress install, used to render the install card/row.
struct FlekInstallState: Equatable {
    var name: String?
    var iconURL: String?
    var fraction: Double        // 0...1, combined progress for download bar
    var indeterminate: Bool     // true during prepare / decompress / signing
    var isInstalling: Bool      // true during install (post-download) phases
    var installFraction: Double // 0...1, install-only progress for circular ring
    var failed: Bool = false    // install/download failed — show failed icon
    var errorMessage: String? = nil // reason to show in the failed-install alert
}

/// Per-app launch mode chosen from the home screen context menu. "Single"
/// launches the app on its own (full screen); "Parallel" uses the existing
/// multitasking window engine. A `nil` value means the user never picked one
/// (uses the global default from settings, not badged).
enum FlekLaunchMode: String {
    case single
    case parallel
}

final class FlekLaunchModeStore {
    static let shared = FlekLaunchModeStore()
    private let store = LCUtils.appGroupUserDefault
    private let key = "FlekAppLaunchModes"

    /// In-memory cache of the launch-mode map. mode()/showsSingleBadge() are
    /// called for every home cell on every render pass, so reading UserDefaults
    /// each time was needless work during scroll. Seed lazily from disk and
    /// refresh only on write.
    private lazy var cache: [String: String] = (store.dictionary(forKey: key) as? [String: String]) ?? [:]

    private func persist() {
        store.set(cache, forKey: key)
    }

    /// Reload from disk (e.g. if another LiveContainer instance changed it).
    func refresh() {
        cache = (store.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func mode(for app: LCAppModel) -> FlekLaunchMode? {
        guard let id = app.appInfo.relativeBundlePath, let raw = cache[id] else { return nil }
        return FlekLaunchMode(rawValue: raw)
    }

    func set(_ mode: FlekLaunchMode, for app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath else { return }
        cache[id] = mode.rawValue
        persist()
    }

    /// Whether the single-mode badge should be shown (user explicitly chose single).
    func showsSingleBadge(for app: LCAppModel) -> Bool {
        mode(for: app) == .single
    }

    /// Drops the app's stored mode when it is uninstalled. The key is the folder
    /// name, so a later install of the same app would otherwise silently adopt
    /// the choice made for the copy that is being removed.
    func forget(_ app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath, cache.removeValue(forKey: id) != nil else { return }
        persist()
    }
}

/// Tracks which guest apps have been launched at least once, so freshly
/// installed apps can show the blue "new" dot until first launch.
final class FlekLaunchTracker {
    static let shared = FlekLaunchTracker()
    private let store = LCUtils.appGroupUserDefault

    /// In-memory cache so isNew() doesn't read UserDefaults and rebuild a Set for
    /// every row on every render. Seeded lazily from disk; updated on write.
    private lazy var cache: Set<String> = Set(store.stringArray(forKey: FlekDeckKeys.launchedApps) ?? [])

    private func persist() {
        store.set(Array(cache), forKey: FlekDeckKeys.launchedApps)
    }

    /// Reload from disk (e.g. if another LiveContainer instance changed it).
    func refresh() {
        cache = Set(store.stringArray(forKey: FlekDeckKeys.launchedApps) ?? [])
    }

    func isNew(_ app: LCAppModel) -> Bool {
        guard let key = app.appInfo.relativeBundlePath else { return false }
        return !cache.contains(key)
    }

    func markLaunched(_ app: LCAppModel) {
        guard let key = app.appInfo.relativeBundlePath else { return }
        if cache.insert(key).inserted {
            persist()
        }
    }

    /// Forgets an uninstalled app, so a later install of the same one is new
    /// again rather than inheriting the launched state of the copy it replaced.
    func forget(_ app: LCAppModel) {
        guard let key = app.appInfo.relativeBundlePath, cache.remove(key) != nil else { return }
        persist()
    }
}
