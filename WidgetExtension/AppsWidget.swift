//
//  AppsWidget.swift
//  WidgetExtension
//
//  A home screen widget of FlekDeck's apps: a grid of their icons, each of
//  which opens its app in FlekDeck. Which apps it shows is set per widget
//  (AppsWidgetConfiguration); FlekDeck hands them over through the app group.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct FlekDeckWidgets: WidgetBundle {
    init() {
        _ = SystemGlassBackground.isInstalled
    }

    // One widget for each size, 2×2, 2×4, 4×4 and from iOS 27 on 4×6, rather
    // than one widget in four sizes. The home screen only offers to resize a
    // widget into another size of its own, so these can't be resized in place:
    // a resized widget loses its glass (SystemGlassBackground), while one
    // added at its size always has it.
    var body: some Widget {
        AppsWidget<SmallAppsWidget>()
        AppsWidget<MediumAppsWidget>()
        AppsWidget<LargeAppsWidget>()
        if #available(iOS 27.0, *) {
            AppsWidget<ExtraLargeAppsWidget>()
        }
    }
}

/// The one size an Apps widget comes in, and the kind it goes by.
protocol AppsWidgetSize {
    static var kind: String { get }
    static var family: WidgetFamily { get }
}

enum SmallAppsWidget: AppsWidgetSize {
    static let kind = WidgetAppList.Kind.small
    static let family = WidgetFamily.systemSmall
}

enum MediumAppsWidget: AppsWidgetSize {
    static let kind = WidgetAppList.Kind.medium
    static let family = WidgetFamily.systemMedium
}

enum LargeAppsWidget: AppsWidgetSize {
    static let kind = WidgetAppList.Kind.large
    static let family = WidgetFamily.systemLarge
}

@available(iOS 27.0, *)
enum ExtraLargeAppsWidget: AppsWidgetSize {
    static let kind = WidgetAppList.Kind.extraLargePortrait
    static let family = WidgetFamily.systemExtraLargePortrait
}

struct AppsWidget<Size: AppsWidgetSize>: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Size.kind, intent: AppsWidgetConfiguration.self,
                               provider: AppsProvider()) { entry in
            AppsWidgetView(entry: entry)
        }
        .configurationDisplayName("Apps")
        .description("Open your FlekDeck apps from the Home Screen.")
        .supportedFamilies([Size.family])
        // The grid spaces its icons out to the widget's edges itself.
        .contentMarginsDisabled()
    }
}

extension WidgetFamily {
    /// The icons a widget of this size holds, as columns by rows: as many as
    /// the home screen fits in the same space.
    var iconGrid: (columns: Int, rows: Int) {
        if #available(iOS 27.0, *), self == .systemExtraLargePortrait {
            return (4, 6)
        }
        switch self {
        case .systemSmall: return (2, 2)
        case .systemMedium: return (4, 2)
        default: return (4, 4)
        }
    }
}

struct WidgetApp: Identifiable {
    let id: String
    let name: String
    let url: URL
    let icon: UIImage?
}

struct AppsEntry: TimelineEntry {
    enum Content {
        /// Grey tiles where icons go, for the gallery and while loading.
        case placeholder
        case apps([WidgetApp])
        /// Set to show chosen apps, with none chosen or none still installed.
        case noneChosen
        /// FlekDeck has not handed a list over yet.
        case noList
        /// The widget was signed without an app group, so no list can reach it.
        case noAppGroup
    }

    let date: Date
    let content: Content
}

extension AppsEntry.Content {
    var hasApps: Bool {
        if case .apps(let apps) = self { return !apps.isEmpty }
        return false
    }
}

struct AppsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AppsEntry {
        AppsEntry(date: .now, content: .placeholder)
    }

    func snapshot(for configuration: AppsWidgetConfiguration, in context: Context) async -> AppsEntry {
        var content = AppListReader.content(for: context.family, showing: configuration)
        // The gallery shows the user's own apps when it can, and the shape of
        // the widget when there are none to show.
        if context.isPreview && !content.hasApps {
            content = .placeholder
        }
        return AppsEntry(date: .now, content: content)
    }

    func timeline(for configuration: AppsWidgetConfiguration, in context: Context) async -> Timeline<AppsEntry> {
        let entry = AppsEntry(date: .now, content: AppListReader.content(for: context.family, showing: configuration))
        // FlekDeck reloads the widget whenever it writes a new list or opens an
        // app. Most Used also looks again within the hour, since an app opened
        // from inside another one is recorded where nothing can reload it.
        let policy: TimelineReloadPolicy = configuration.show == .mostUsed
            ? .after(Date().addingTimeInterval(60 * 60))
            : .never
        return Timeline(entries: [entry], policy: policy)
    }
}

/// Finds the list FlekDeck wrote for this widget and loads as much of it as
/// one widget shows.
enum AppListReader {
    enum Source {
        case list(WidgetAppList, folder: URL)
        /// FlekDeck has not written a list yet.
        case noList
        case noAppGroup
    }

    static func content(for family: WidgetFamily, showing configuration: AppsWidgetConfiguration) -> AppsEntry.Content {
        let list: WidgetAppList
        let folder: URL
        switch source() {
        case .list(let found, let foundIn):
            list = found
            folder = foundIn
        case .noList:
            return .noList
        case .noAppGroup:
            return .noAppGroup
        }

        let apps: [WidgetAppList.App]
        switch configuration.show {
        case .flekDeckOrder:
            apps = list.apps
        case .mostUsed:
            apps = WidgetLaunchHistory.load(from: folder).mostUsed(list.apps)
        case .chosen:
            // In the order they were picked, leaving out any since removed.
            let installed = Dictionary(list.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            apps = (configuration.apps ?? []).compactMap { installed[$0.id] }
            if apps.isEmpty {
                return .noneChosen
            }
        }

        let grid = family.iconGrid
        return .apps(apps.prefix(grid.columns * grid.rows).map { app in
            WidgetApp(id: app.id, name: app.name, url: app.url,
                      icon: UIImage(contentsOfFile: WidgetAppList.iconURL(in: folder, for: app.id).path))
        })
    }

    static func source() -> Source {
        let groups = appGroups
        guard !groups.isEmpty else { return .noAppGroup }
        guard let appBundleID = containingAppBundleID else { return .noList }

        // FlekDeck writes into the one group it uses; the widget looks in every
        // group it has, and should several hold a list, takes the newest.
        var newest: (list: WidgetAppList, folder: URL, date: Date)?
        for group in groups {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                continue
            }
            let folder = WidgetAppList.folder(in: container, appBundleID: appBundleID)
            let listURL = WidgetAppList.listURL(in: folder)
            guard let data = try? Data(contentsOf: listURL),
                  let list = try? JSONDecoder().decode(WidgetAppList.self, from: data) else {
                continue
            }
            let date = (try? listURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest.map({ date > $0.date }) ?? true {
                newest = (list, folder, date)
            }
        }
        guard let newest else { return .noList }
        return .list(newest.list, folder: newest.folder)
    }

    /// The app groups the widget was signed with. Signers give them names of
    /// their own, so they are read off the widget's entitlements.
    private static var appGroups: [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String] ?? []
    }

    /// The bundle ID of the FlekDeck this widget came with, which FlekDeck files
    /// its list under. Read off the app itself, since signers rename both.
    private static var containingAppBundleID: String? {
        // The widget is FlekDeck.app/PlugIns/WidgetExtension.appex.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: appURL)?.bundleIdentifier
    }
}

extension WidgetLaunchHistory {
    /// A week: the time it takes a launch to count for half as much.
    static let halfLife: TimeInterval = 7 * 24 * 60 * 60

    /// The apps, most used first. Every launch counts, a recent one for more,
    /// its weight halving with each week since. Apps never opened follow in
    /// FlekDeck's order.
    func mostUsed(_ apps: [WidgetAppList.App], now: Date = Date()) -> [WidgetAppList.App] {
        let current = now.timeIntervalSince1970
        let scored = apps.enumerated().map { (index, app) -> (app: WidgetAppList.App, score: Double, last: Double, index: Int) in
            // An app last opened before launches were kept has only that time.
            let times = launches[app.id] ?? app.lastLaunched.map { [$0.timeIntervalSince1970] } ?? []
            let score = times.reduce(0) { $0 + pow(0.5, (current - $1) / Self.halfLife) }
            return (app, score, times.max() ?? 0, index)
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.last != b.last { return a.last > b.last }
            return a.index < b.index
        }.map(\.app)
    }
}
