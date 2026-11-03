//
//  FlekWidgetSync.swift
//  LiveContainerSwiftUI
//
//  Hands the Apps widget what it shows: the home screen's apps in their
//  order, with icons and launch links, and a history of when each was opened.
//

import UIKit
import WidgetKit

/// Keeps the Apps widget's copy of the home screen in step with it.
///
/// The widget runs in an extension of its own, which can reach nothing of
/// FlekDeck's but the app group, so everything is written there
/// (`WidgetAppList`, which both sides build, says where). The apps' names and
/// launch links go in a JSON file with their icons beside it, scaled down for
/// a widget's small memory. Every app is written, not only as many as a widget
/// holds, since any of them can be picked for one. A file is only written when
/// it would change, and the widget is only reloaded when one was.
final class FlekWidgetSync {
    static let shared = FlekWidgetSync()

    /// The size icons are saved at, in pixels: enough for an icon in the
    /// largest widget at 3x.
    private static let iconPixels: CGFloat = 192

    private let queue = DispatchQueue(label: "FlekWidgetSync", qos: .utility)
    /// Launches are written apart from the list, so recording one never waits
    /// for icons being drawn.
    private let launchQueue = DispatchQueue(label: "FlekWidgetSync.launches", qos: .userInitiated)
    private var apps: [LCAppModel] = []
    private var pendingSync: DispatchWorkItem?
    /// The image each icon file was last drawn from, so an icon is drawn again
    /// only once the home screen has a new picture for it. Used on `queue`.
    private var writtenIcons: [String: UIImage] = [:]

    private init() {
        // Going to the background is when the widget comes into view, so the
        // list is brought up to date then as well. An icon changed in an app's
        // settings, or dark icons switched on, reach the widget this way.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    /// Takes the home screen's items, in order, each time they change. The
    /// write waits a moment, so a burst of changes makes one.
    func update(homeItems: [FlekHomeItem]) {
        apps = homeItems.compactMap { item in
            if case .installed(let app) = item { return app }
            return nil
        }
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Adds a launch of the app to the history the widget's Most Used order
    /// comes from, and has the widget look again. Written before returning:
    /// opening an app in single mode relaunches FlekDeck as that app.
    func recordLaunch(of app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath, let folder = Self.folder() else { return }
        launchQueue.sync {
            var history = WidgetLaunchHistory.load(from: folder)
            guard history.record(id) else { return }
            history.write(to: folder)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetAppList.widgetKind)
        }
    }

    private static func folder() -> URL? {
        guard let groupPath = LCSharedUtils.appGroupPath(),
              let appBundleID = Bundle.main.bundleIdentifier else {
            return nil
        }
        return WidgetAppList.folder(in: groupPath, appBundleID: appBundleID)
    }

    private func sync() {
        pendingSync?.cancel()
        pendingSync = nil
        guard let folder = Self.folder() else { return }

        let darkIcons = LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")
        let scheme = LCUtils.appUrlScheme() ?? "flekdeck"
        var list = WidgetAppList(apps: [])
        var icons: [String: UIImage] = [:]
        for app in apps {
            guard let id = app.appInfo.relativeBundlePath else { continue }
            // The link FlekDeck's web clips open their app with.
            var link = URLComponents()
            link.scheme = scheme
            link.host = "livecontainer-launch"
            link.queryItems = [URLQueryItem(name: "bundle-name", value: id)]
            guard let url = link.url else { continue }
            list.apps.append(WidgetAppList.App(id: id, name: app.appInfo.displayName() ?? id, url: url,
                                               lastLaunched: app.appInfo.lastLaunched))
            // Read here, on the main thread, where the home screen reads them.
            icons[id] = app.appInfo.iconIsDarkIcon(darkIcons)
        }

        queue.async { [self] in
            if write(list, icons: icons, to: folder) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetAppList.widgetKind)
            }
        }
    }

    /// Writes whatever differs from what is already there, the icons before the
    /// list so that it never names an icon not yet written. Says whether
    /// anything was written.
    private func write(_ list: WidgetAppList, icons: [String: UIImage], to folder: URL) -> Bool {
        let fileManager = FileManager.default
        let iconFolder = WidgetAppList.iconFolder(in: folder)
        do {
            try fileManager.createDirectory(at: iconFolder, withIntermediateDirectories: true)
        } catch {
            return false
        }

        var wroteAny = false
        for (id, icon) in icons {
            let url = WidgetAppList.iconURL(in: folder, for: id)
            if writtenIcons[id] === icon, fileManager.fileExists(atPath: url.path) {
                continue
            }
            guard let png = Self.widgetIcon(from: icon).pngData() else { continue }
            if (try? Data(contentsOf: url)) != png {
                guard (try? png.write(to: url, options: .atomic)) != nil else { continue }
                wroteAny = true
            }
            writtenIcons[id] = icon
        }
        // The icons of apps that have left the list.
        writtenIcons = writtenIcons.filter { icons[$0.key] != nil }
        let listed = Set(list.apps.map { WidgetAppList.iconURL(in: folder, for: $0.id).lastPathComponent })
        for name in (try? fileManager.contentsOfDirectory(atPath: iconFolder.path)) ?? [] where !listed.contains(name) {
            try? fileManager.removeItem(at: iconFolder.appendingPathComponent(name))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let listURL = WidgetAppList.listURL(in: folder)
        if let data = try? encoder.encode(list), (try? Data(contentsOf: listURL)) != data,
           (try? data.write(to: listURL, options: .atomic)) != nil {
            wroteAny = true
        }
        return wroteAny
    }

    /// The icon at the size the widget draws it, so that a full list of them
    /// stays well within the memory a widget is given.
    private static func widgetIcon(from icon: UIImage) -> UIImage {
        guard let cgImage = icon.cgImage else { return icon }
        let pixels = min(iconPixels, CGFloat(max(cgImage.width, cgImage.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { _ in
            icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }
}
