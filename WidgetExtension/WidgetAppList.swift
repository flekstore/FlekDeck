//
//  WidgetAppList.swift
//  WidgetExtension
//
//  What FlekDeck hands its Apps widget: its apps, and when each was opened.
//  FlekDeck writes both into the app group and the widget reads them back, so
//  this file is built into both targets: WidgetExtension and
//  LiveContainerSwiftUI.
//

import Foundation

struct WidgetAppList: Codable, Equatable {
    struct App: Codable, Equatable {
        /// The app's folder in FlekDeck, which its launch link names as well.
        var id: String
        var name: String
        /// Opens the app as tapping it on FlekDeck's home screen does.
        var url: URL
        /// When FlekDeck last opened the app. It stands in for the launch
        /// history of an app last opened before launches were kept.
        var lastLaunched: Date?
    }

    /// Every app on FlekDeck's home screen, in its order.
    var apps: [App]

    /// The widget's kind, which FlekDeck reloads by.
    static let widgetKind = "FlekDeckApps"

    /// The folder one copy of FlekDeck keeps its list in, inside an app group
    /// container. It is named after the app because a signer can give the same
    /// group to two copies of FlekDeck, and each widget must show its own apps.
    static func folder(in groupContainer: URL, appBundleID: String) -> URL {
        groupContainer
            .appendingPathComponent("LiveContainer/Widget", isDirectory: true)
            .appendingPathComponent(appBundleID, isDirectory: true)
    }

    static func listURL(in folder: URL) -> URL {
        folder.appendingPathComponent("Apps.json")
    }

    static func iconFolder(in folder: URL) -> URL {
        folder.appendingPathComponent("Icons", isDirectory: true)
    }

    static func iconURL(in folder: URL, for id: String) -> URL {
        iconFolder(in: folder).appendingPathComponent(id + ".png")
    }
}

/// When each app was opened, as Unix times, oldest first: what the widget's
/// Most Used order is worked out from. FlekDeck adds to it as it opens an app.
/// So does `LCSharedUtils` when an app running in single mode switches to
/// another, writing this same file in Objective-C; keep the two alike.
struct WidgetLaunchHistory {
    var launches: [String: [Double]] = [:]

    /// Launches older than this no longer count, and are dropped.
    static let window: TimeInterval = 60 * 24 * 60 * 60
    /// The most launches kept for one app.
    static let limit = 100

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent("Launches.json")
    }

    static func load(from folder: URL) -> WidgetLaunchHistory {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let launches = try? JSONDecoder().decode([String: [Double]].self, from: data) else {
            return WidgetLaunchHistory()
        }
        return WidgetLaunchHistory(launches: launches)
    }

    /// Adds a launch, unless the app was opened less than a minute ago: a
    /// second tap, or a launch tried again after a failed one, is the same
    /// use. Says whether it was added.
    mutating func record(_ id: String, at date: Date = Date()) -> Bool {
        let now = date.timeIntervalSince1970
        var times = (launches[id] ?? []).filter { now - $0 < Self.window }
        if let last = times.last, now - last < 60 {
            return false
        }
        times.append(now)
        launches[id] = Array(times.suffix(Self.limit))
        return true
    }

    func write(to folder: URL) {
        guard let data = try? JSONEncoder().encode(launches) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: Self.url(in: folder), options: .atomic)
    }
}
