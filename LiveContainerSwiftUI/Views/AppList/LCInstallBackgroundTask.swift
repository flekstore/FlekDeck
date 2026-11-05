//
//  LCInstallBackgroundTask.swift
//  LiveContainerSwiftUI
//
//  Keeps queued downloads and installs running once the user leaves the app.
//

import BackgroundTasks
import Combine
import SwiftUI

/// Asks the system to keep an install running while the app is in the background.
///
/// Call this when the user starts an install, from the foreground; everything after
/// that is automatic. On anything older than iOS 26 — and on Mac Catalyst and the
/// simulator, where the API doesn't exist — this does nothing and the queue behaves
/// exactly as it always has.
enum LCInstallBackgroundTask {
    @MainActor
    static func begin(for item: InstallItem) {
        #if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        record("Unsupported", detail: "No continued-processing scheduler on this platform")
        #else
        if #available(iOS 26.0, *) {
            LCInstallBackgroundTaskManager.shared.begin(for: item)
        } else {
            record("Unsupported", detail: "Needs iOS 26 or later")
        }
        #endif
    }

    /// What the identifier of a continued-processing task has to start with in
    /// this install, for other work kept running the same way. Nil where there
    /// is no such scheduler, or nothing can be permitted.
    ///
    /// It is the installs' own prefix, and has to be: the scheduler reads the
    /// permitted identifiers once, so a second wildcard added later for some
    /// other kind of task would never be seen.
    @MainActor
    static func taskIdentifierPrefix() -> String? {
        #if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        return nil
        #else
        guard #available(iOS 26.0, *) else {
            return nil
        }
        var failure: String?
        return LCInstallBackgroundTaskManager.shared
            .permittedWildcard(for: Bundle.main.bundleIdentifier ?? "", failure: &failure)?
            .replacingOccurrences(of: ".*", with: ".")
        #endif
    }

    /// Records the last outcome for the Settings row. Logging alone isn't enough:
    /// this only ever fails on someone else's phone, with no Mac attached to read
    /// the console from — the same reason `LCHostIdentity` reports this way.
    static func record(_ status: String, detail: String = "") {
        let defaults = LCUtils.appGroupUserDefault
        defaults.set(status, forKey: "LCBackgroundInstallStatus")
        defaults.set(detail, forKey: "LCBackgroundInstallDetail")
        defaults.set(Date(), forKey: "LCBackgroundInstallDate")
        NSLog("[LC] background install task: \(status)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

#if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)

/// Bridges `LCInstallQueue` to the system's continued-processing scheduler.
///
/// `BGContinuedProcessingTask` is built for this exact shape of work: the user taps
/// Install in the foreground, the job takes minutes, and the system shows its own
/// Live Activity — the app's name, the current phase, a progress bar and a Cancel
/// button — for as long as the app is away. Without it the queue only has
/// `isIdleTimerDisabled`, which holds off auto-lock but can't keep anything running
/// once the app is actually suspended.
///
/// The system task *adopts* work the queue is already doing rather than containing
/// it: a submission can be refused, or sit queued for a while, so the download has
/// to run either way. The launch handler binds the task to an existing
/// `InstallItem`, mirrors its progress and reports the outcome; nothing in the
/// queue's own flow moves inside it.
@available(iOS 26.0, *)
@MainActor
private final class LCInstallBackgroundTaskManager {
    static let shared = LCInstallBackgroundTaskManager()

    /// Resolution of the progress bar the system draws: whole percents, the same
    /// steps the percentage in the text moves in.
    private static let progressUnits: Int64 = 100

    private struct Entry {
        let identifier: String
        weak var item: InstallItem?
        var task: BGContinuedProcessingTask?
        /// What the row last showed, so `updateTitle` only fires on a real change.
        var title: String?
        var subtitle: String?
        var phase: InstallPhase?
        var textUpdatedAt: Date?
        var progressUpdatedAt: Date?
    }

    /// The least time between two text changes within one phase. The percentage
    /// moves every whole percent; the row doesn't need to redraw faster than this
    /// to read as live, and every update is a round trip to the system.
    private static let textInterval: TimeInterval = 1

    /// The same for the bar. The task passes every change of its progress on to
    /// the system, which redraws its card for each one.
    private static let progressInterval: TimeInterval = 0.5

    /// How long a finished row stays up showing "Installed" before it goes, so
    /// the install ends on a visible success instead of the row just vanishing.
    private static let finishedHold: TimeInterval = 1.5

    /// For a download of unknown size, the byte count at which the bar is about
    /// two-thirds of the way through its share — roughly a typical IPA.
    private static let unknownSizeScale: Double = 100_000_000

    /// Live tasks keyed by `InstallItem.id`, plus the reverse lookup the launch
    /// handler needs — it's handed back only the identifier it registered with.
    private var entries: [UUID: Entry] = [:]
    private var itemIDs: [String: UUID] = [:]
    private var queueObserver: AnyCancellable?

    /// The wildcard added to the in-memory Info.plist, if one had to be. Reported
    /// with every outcome: a signed entry that happens to match proves nothing about
    /// the runtime path, which is the one every other user depends on.
    private var addedAtRuntime: String?

    private static var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    /// The wildcard this install composes its identifier under.
    ///
    /// The scheduler applies two rules to `BGTaskSchedulerPermittedIdentifiers`: an
    /// entry has to end in `.*`, and the *running* bundle identifier has to be a
    /// prefix of it. The second is the one that bites. Every user's copy is re-signed
    /// under a bundle ID of its own, so the entry built in from
    /// `PRODUCT_BUNDLE_IDENTIFIER` only ever fits a build run from Xcode, and an
    /// entry that doesn't fit is dropped — leaving nothing to compose against and
    /// every registration refused, with no other symptom.
    ///
    /// So when no signed entry fits, `<bundle ID>.install.*` is added to the
    /// in-memory Info.plist, which is where the scheduler reads the list from (see
    /// LCPermittedTaskIdentifier.m). This runs before any registration, and has to:
    /// the scheduler reads the list once, on the first one, and keeps it.
    fileprivate func permittedWildcard(for bundleID: String, failure: inout String?) -> String? {
        if let signed = Self.permittedIdentifiers.first(where: { $0.hasSuffix(".*") && $0.hasPrefix(bundleID) }) {
            return signed
        }
        guard !bundleID.isEmpty else {
            failure = "no bundle identifier"
            return nil
        }
        let wildcard = bundleID + ".install.*"
        if let reason = LCPermitBackgroundTaskIdentifier(wildcard) {
            failure = reason
            return nil
        }
        addedAtRuntime = wildcard
        return wildcard
    }

    /// Both halves of that rule, for the diagnostics row — a refusal is unreadable
    /// without them.
    private static func inputs(for bundleID: String) -> String {
        let listed = permittedIdentifiers.isEmpty ? "—" : permittedIdentifiers.joined(separator: " ")
        return "bundle \(bundleID.isEmpty ? "—" : bundleID) · plist \(listed)"
    }

    private init() {}

    // MARK: Starting

    func begin(for item: InstallItem) {
        guard entries[item.id] == nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        var failure: String?
        guard let wildcard = permittedWildcard(for: bundleID, failure: &failure) else {
            LCInstallBackgroundTask.record("No permitted identifier",
                                           detail: "\(failure ?? "none fits") · \(Self.inputs(for: bundleID))")
            return
        }
        // The scheduler turns `a.b.*` into the base `a.b.` and prefix-matches.
        let prefix = wildcard.replacingOccurrences(of: ".*", with: ".")
        let permittedBy = wildcard == addedAtRuntime ? "permitted at runtime" : "signed into Info.plist"
        // The scheduler only takes a submission made from the foreground on behalf
        // of something the user just did. An install kicked off by a URL the app was
        // launched with doesn't qualify; skipping it is the whole handling needed.
        guard UIApplication.shared.applicationState == .active else {
            LCInstallBackgroundTask.record("Not started", detail: "App was not foreground when the install began")
            return
        }

        // An identifier can never be reused: registering the same one twice kills
        // the app, and there is no way to unregister. Hence a fresh one per install.
        let identifier = prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Runs on a scheduler-owned queue. The registration outlives the install
            // for good, so this captures nothing heavier than the identifier.
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                LCInstallBackgroundTaskManager.shared.adopt(task, identifier: identifier)
            }
        }
        guard registered else {
            LCInstallBackgroundTask.record("Registration refused",
                                           detail: "\(identifier) · \(permittedBy) · \(Self.inputs(for: bundleID))")
            return
        }

        entries[item.id] = Entry(identifier: identifier, item: item)
        itemIDs[identifier] = item.id

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: Self.title(for: item),
            subtitle: Self.subtitle(for: item, fraction: Self.fraction(for: item))
        )
        // .queue rather than .fail: the install runs either way, so a task that only
        // gets going once the system has room for it is still worth having.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            LCInstallBackgroundTask.record("Submitted", detail: "\(identifier) · \(permittedBy)")
            startObservingQueue()
        } catch {
            let nsError = error as NSError
            // The code is the whole diagnosis: 1 unavailable, 2 too many pending,
            // 3 not permitted, 4 no room to start right now.
            LCInstallBackgroundTask.record("Submit failed",
                                           detail: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            forget(itemID: item.id)
        }
    }

    /// Binds a task the system just launched to the install it was submitted for.
    private func adopt(_ task: BGContinuedProcessingTask, identifier: String) {
        guard let itemID = itemIDs[identifier], let entry = entries[itemID], let item = entry.item else {
            // The install finished, failed or was cancelled before the system got
            // round to launching the task.
            task.setTaskCompleted(success: true)
            if let itemID = itemIDs.removeValue(forKey: identifier) {
                entries.removeValue(forKey: itemID)
            }
            return
        }

        task.progress.totalUnitCount = Self.progressUnits
        task.expirationHandler = {
            Task { @MainActor in
                LCInstallBackgroundTaskManager.shared.expire(identifier: identifier)
            }
        }
        entries[itemID]?.task = task
        LCInstallBackgroundTask.record("Running", detail: Self.title(for: item))
        update(item)
    }

    // MARK: Tracking the queue

    private func startObservingQueue() {
        guard queueObserver == nil else { return }
        // Every queue mutation funnels through objectWillChange — phase changes at
        // once, progress as often as it visibly moves — so a single subscription
        // can't miss a transition the way hand-placed calls would. It fires just
        // *before* the change lands, hence reading the state one hop later.
        queueObserver = LCInstallQueue.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                LCInstallBackgroundTaskManager.shared.refresh()
            }
        }
    }

    private func refresh() {
        for (itemID, entry) in entries {
            guard let item = entry.item else {
                end(itemID: itemID, success: false)
                continue
            }
            switch item.phase {
            case .completed:
                end(itemID: itemID, success: true)
            case .failed, .cancelled:
                end(itemID: itemID, success: false)
            default:
                update(item)
            }
        }
        if entries.isEmpty {
            queueObserver = nil
        }
    }

    private func update(_ item: InstallItem) {
        guard let entry = entries[item.id], let task = entry.task else { return }
        // A new phase shows at once; within one, the bar keeps to progressInterval
        // and the text to textInterval.
        let now = Date()
        let newPhase = item.phase != entry.phase

        // Accurate progress isn't cosmetic: the system expires tasks that look
        // stalled before it expires ones that are visibly moving. The bar and the
        // percentage in the text come from the same number, so they always agree.
        let fraction = Self.fraction(for: item)
        let units = Int64((fraction * Double(Self.progressUnits)).rounded())
        if units != task.progress.completedUnitCount,
           newPhase || Self.hasElapsed(Self.progressInterval, since: entry.progressUpdatedAt, now: now) {
            task.progress.completedUnitCount = units
            entries[item.id]?.progressUpdatedAt = now
        }

        guard newPhase || Self.hasElapsed(Self.textInterval, since: entry.textUpdatedAt, now: now) else { return }
        entries[item.id]?.phase = item.phase
        let title = Self.title(for: item)
        let subtitle = Self.subtitle(for: item, fraction: fraction)
        guard title != entry.title || subtitle != entry.subtitle else { return }
        entries[item.id]?.title = title
        entries[item.id]?.subtitle = subtitle
        entries[item.id]?.textUpdatedAt = now
        task.updateTitle(title, subtitle: subtitle)
    }

    private static func hasElapsed(_ interval: TimeInterval, since last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private static func fraction(for item: InstallItem) -> Double {
        let state = item.installState
        guard item.phase == .downloading, item.totalBytes <= 0 else {
            return min(max(state.fraction, 0), 1)
        }
        // The server never said how big the file is, so there's nothing to divide
        // by — and a bar parked at zero reads as stalled, which the system expires
        // first. Move it along a curve that never reaches the end of the download's
        // share (the 0.8 `installState` gives it) and let the text carry the exact
        // byte count instead of a percentage.
        let guess = 1 - exp(-Double(item.downloadedBytes) / unknownSizeScale)
        return 0.8 * guess
    }

    // MARK: Finishing

    private func end(itemID: UUID, success: Bool) {
        guard let entry = entries[itemID] else { return }
        forget(itemID: itemID)
        guard let task = entry.task else { return }
        LCInstallBackgroundTask.record(success ? "Finished" : "Install failed")
        guard success else {
            task.setTaskCompleted(success: false)
            return
        }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle(entry.title ?? task.title, subtitle: "lc.flek.installed".loc)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedHold) {
            task.setTaskCompleted(success: true)
        }
    }

    /// The user tapped Cancel in the Live Activity, or the system reclaimed the task
    /// under load.
    private func expire(identifier: String) {
        guard let itemID = itemIDs[identifier], let entry = entries[itemID] else { return }
        forget(itemID: itemID)
        entry.task?.setTaskCompleted(success: false)

        // There's no background time left. If the app is still on screen the install
        // can simply carry on without a task; if it isn't, the install can't make
        // progress, and stopping it beats leaving it wedged at 40% until the user
        // comes back.
        guard UIApplication.shared.applicationState != .active, let item = entry.item else {
            LCInstallBackgroundTask.record("Expired", detail: "App was on screen — install left running")
            return
        }
        LCInstallBackgroundTask.record("Expired", detail: "Cancelled while backgrounded")
        LCInstallQueue.shared.cancel(item)
    }

    private func forget(itemID: UUID) {
        if let entry = entries.removeValue(forKey: itemID) {
            itemIDs.removeValue(forKey: entry.identifier)
        }
    }

    // MARK: Text shown by the system

    /// The app's name as the rest of the app shows it: a rename chosen on its page,
    /// else the catalog's name, else the name read from the bundle once it's
    /// extracted, else the file name of a hand-picked IPA.
    private static func title(for item: InstallItem) -> String {
        let candidates = [item.overrides?.displayName, item.name, item.resolvedName, fileName(of: item)]
        for candidate in candidates {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return "lc.appList.installation".loc
    }

    /// `TikTok_35.2.ipa` → `TikTok_35.2`. Only for an actual .ipa: a download URL
    /// that ends in something like `download?id=4` names nothing.
    private static func fileName(of item: InstallItem) -> String? {
        guard let url = URL(string: item.url) else { return nil }
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension == "ipa" || pathExtension == "tipa" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return name.removingPercentEncoding ?? name
    }

    /// Phase, then the same percentage the bar shows. While downloading, the size
    /// too; when the server never said how big the file is there's no percentage
    /// to show, so it says how much has arrived instead. Numbers and units come
    /// from the system formatters, so they read right in every language the phase
    /// words are already translated into.
    private static func subtitle(for item: InstallItem, fraction: Double) -> String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        switch item.phase {
        case .queued, .cancelled:
            return "lc.flek.install.waiting".loc
        case .downloading:
            let downloading = "lc.flek.install.downloading".loc
            guard item.totalBytes > 0 else {
                return "\(downloading) \(byteCount(item.downloadedBytes))"
            }
            return "\(downloading) \(percent) · \(byteCount(item.totalBytes))"
        case .waitingForInstall:
            return "lc.flek.install.preparing".loc
        case .installing:
            return "\("lc.flek.installing".loc) \(percent)"
        case .completed:
            return "lc.flek.installed".loc
        case .failed:
            return "lc.flek.installFailedGeneric".loc
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#endif
