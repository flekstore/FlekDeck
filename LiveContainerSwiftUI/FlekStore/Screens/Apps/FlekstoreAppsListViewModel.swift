//
//  FlekstoreAppsListViewModel.swift
//  LiveContainer
//
//  Created by Alexander Grigoryev on 30.09.2025.
//

// FlekstoreAppsListViewModel.swift
import SwiftUI
import QuartzCore

@MainActor
class FlekstoreAppsListViewModel: ObservableObject {
    @Published var apps: [FSAppModel] = [] {
        didSet {
            appsStamp = CACurrentMediaTime()
            // A page append leaves the rows already on screen alone, so only the
            // new tail is a fresh arrival. Anything else (reset, repo/category
            // switch, refresh) is a new batch starting at the first row.
            appsBatchStart = Self.isAppend(oldValue, apps) ? oldValue.count : 0
        }
    }

    /// When `apps` last changed, and where the newest batch starts in it.
    ///
    /// The installer's list uses these to run its row-entrance animation for
    /// freshly arrived rows only — rows the lazy stack rebuilds while the user
    /// scrolls just appear, the way a system list behaves.
    private(set) var appsStamp: TimeInterval = 0
    private(set) var appsBatchStart: Int = 0

    /// Cheap O(1) check for "the new list is the old one plus a page".
    private static func isAppend(_ old: [FSAppModel], _ new: [FSAppModel]) -> Bool {
        guard !old.isEmpty, new.count > old.count else { return false }
        return new[0].id == old[0].id && new[old.count - 1].id == old[old.count - 1].id
    }

    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @AppStorage("isAdult") private var isAdult: Bool = false
    
    @Published var hasSubscription: Bool = false
    @Published var subscriptionEndDate: String?
    @Published var isBanned: Bool = false
    @Published var banReason: String = "Unavailable"
    @Published var banMessage: String = "Your access has been limited by the service."

    @Published var deviceDateErrorMessage: String? = nil
    
    //for checking subscription status
    private enum SubscriptionKeys {
        static let endDate = "subscriptionEndDate"
        static let lastCheckDate = "lastSubscriptionCheckDate"
        static let hasActive = "hasActiveSubscription"
    }

    @AppStorage("FSEncryptedUDID")
    private var encryptedUDID: String = ""

    @AppStorage("FSSubscriptionEndDate")
    private var subscriptionEndDateStored: String = ""

    @AppStorage("FSSubscriptionStatus")
    private var subscriptionStatusStored: Bool = false

    @AppStorage("FSSubscriptionInitialized")
    private var subscriptionInitialized: Bool = false

    @AppStorage("FSDeviceUDID")
    private var deviceUDID: String = ""
    
    //for alt store repos
    enum RepositorySource: Equatable {
        case flekstore
        case custom(url: String)
    }
    @Published var repository: RepositorySource = .flekstore
    
    private func currentEndpoint() -> URL? {
        switch repository {
        case .flekstore:
            return URL(string: "\(FlekStoreAPI.base)/app/with-link")

        case .custom(let url):
            return URL(string: url)
        }
    }
    
    //computed property for search for custom repos
    var visibleApps: [FSAppModel] {
        switch repository {
        case .flekstore:
            return apps

        case .custom:
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !query.isEmpty else { return apps }

            return apps.filter {
                $0.app_name.localizedCaseInsensitiveContains(query)
            }
        }
    }
    
    @Published var searchQuery: String = ""
     
    @Published var allCategories: [FSCategory] = [
        .init(id: "32", name: " Arcade"),
        .init(id: "15", name: "Social media"),
        .init(id: "31", name: "Games"),
        .init(id: "1", name: "Emulators"),
        .init(id: "7", name: "Music"),
        .init(id: "30", name: "Photo & Video"),
        .init(id: "3", name: "Adult"),
        .init(id: "16", name: "Movies"),
        .init(id: "23", name: "Tools"),
        .init(id: "42", name: "AI tools"),
        .init(id: "24", name: "Jailbreak"),
        .init(id: "45", name: "Sport")
    ]
    
    var categories: [FSCategory] {
            // Filter out "Adult" if user is not adult
            allCategories.filter { category in
                if category.id == "3" {
                    return isAdult
                }
                return true
            }
        }
    // Selected category — `nil` meaning "All / updates"
    @Published var selectedCategoryID: String? = nil
    
    // Pagination
    private var currentPage = 0
    private var canLoadMore = true
    
    // Debounce task for search
    private var searchDebounceTask: Task<Void, Never>?
    
    // Public: call this when user types in the TextField (from the View `.onChange`)
    func debounceSearch(_ newQuery: String) {
        // Cancel any pending debounce
        searchDebounceTask?.cancel()
        
        // Schedule new debounce
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms
            guard !Task.isCancelled else { return }
            await self?.resetAndFetchApps()
        }
    }
    
    // Public: call when category button pressed
    func selectCategory(_ id: String?) {
        // If selecting same category, do nothing (optional)
        if selectedCategoryID == id { return }
        
        // Cancel pending debounce (so a pending search won't race)
        searchDebounceTask?.cancel()
        
        selectedCategoryID = id
        Task { await resetAndFetchApps() }
    }
    
    // Reset paging and fetch first page
    // Monotonic token so a fresh reset/search always supersedes an in-flight page
    // load instead of being dropped by it (or clobbering its results).
    private var loadGeneration = 0

    func resetAndFetchApps() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        currentPage = 0
        canLoadMore = true
        keptAwaitingRefresh = nil
        apps = []
        isLoading = false   // a stale in-flight page load must not block this reset
        await fetchApps(generation: generation)
    }
    
    // Fetch next page (pagination entry point)
    func fetchApps() async {
        await fetchApps(generation: loadGeneration)
    }

    /// Pull-to-refresh: reload the first page *in place*.
    ///
    /// `resetAndFetchApps` empties the list before the request goes out, which
    /// collapses the whole list under the refresh spinner and snaps the scroll
    /// offset back to the top. Here the visible rows stay put and are swapped for
    /// the fresh ones when they land, so unchanged rows never move.
    func refreshCurrentRepository() async {
        guard !apps.isEmpty else {
            await resetAndFetchApps()
            return
        }
        // Supersede any in-flight page load, and drop its `isLoading` claim with
        // it — that load will be discarded on return and would otherwise leave
        // pagination blocked forever.
        loadGeneration &+= 1
        isLoading = false
        await silentRefresh(expecting: repository)
    }

    private func fetchApps(generation: Int) async {
        guard !isLoading, canLoadMore else { return }
        guard generation == loadGeneration else { return }
        isLoading = true
        errorMessage = nil

        guard let baseURL = currentEndpoint() else {
            errorMessage = "Invalid repository URL"
            isLoading = false
            return
        }

        do {
            let data: Data

            switch repository {

            // Normal Flekstore API
            case .flekstore:
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)

                var queryItems: [URLQueryItem] = []
                let filterValue = selectedCategoryID ?? "updates"

                queryItems.append(.init(name: "filter", value: filterValue))
                queryItems.append(.init(name: "page", value: "\(currentPage)"))

                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                queryItems.append(.init(name: "search", value: trimmed.isEmpty ? "false" : trimmed))

                components?.queryItems = queryItems

                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (responseData, _) = try await URLSession.shared.data(from: url)
                data = responseData

                // A newer reset/search started while awaiting — drop this result.
                guard generation == loadGeneration else { return }

                let decoded = try JSONDecoder().decode([FSAppModel].self, from: data)
                let filtered = isAdult ? decoded : decoded.filter { $0.app_isAdult != 1 }

                if filtered.isEmpty {
                    canLoadMore = false
                } else {
                    apps.append(contentsOf: filtered)
                    currentPage += 1
                }

            // Custom repository: through the loader, which search and the
            // refresh at launch share, so that a source is downloaded once
            // whoever asks, and read off the main thread.
            case .custom(let url):
                guard let mappedApps = await RepoCatalogLoader.shared.catalog(for: url) else {
                    throw URLError(.cannotLoadFromNetwork)
                }
                // A newer load may have started meanwhile.
                guard generation == loadGeneration else { return }

                apps = mappedApps
                canLoadMore = false
            }

        } catch {
            if generation == loadGeneration {
                errorMessage = "lc.flek.loadFailed".loc
            }
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    // MARK: - Instant source switching

    /// A source's list as it was last shown, with how far it had been paged.
    private struct KeptList {
        let apps: [FSAppModel]
        let currentPage: Int
        let canLoadMore: Bool
    }

    /// In-memory cache of the last-shown apps per source, so switching back to a
    /// source shows its list instantly instead of reloading from scratch.
    private var memoryCache: [String: KeptList] = [:]

    /// The kept list on screen while the refresh that is to replace it is on
    /// its way. Paging is held off until it lands, so this is where paging
    /// really stands, should the source be left or the refresh fail.
    private var keptAwaitingRefresh: KeptList?

    /// Whether the source's last-shown list is held in memory.
    func hasMemoryCache(for source: RepositorySource) -> Bool {
        memoryCache[repoCacheKey(source)] != nil
    }

    /// The source's last-shown list, if it is held in memory.
    func cachedApps(for source: RepositorySource) -> [FSAppModel]? {
        memoryCache[repoCacheKey(source)]?.apps
    }

    /// Fetches FlekSt0re's first page and keeps it, where no list of it is
    /// kept yet, so that a swipe to FlekSt0re finds a list to show rather than
    /// loading one when it lands. Returns the list kept.
    func keepFlekstoreFirstPage() async -> [FSAppModel]? {
        let key = repoCacheKey(.flekstore)
        if let kept = memoryCache[key] { return kept.apps }
        if let fetch = firstPageFetch { return await fetch.value }
        let fetch = Task { () -> [FSAppModel]? in
            guard var components = URLComponents(string: "\(FlekStoreAPI.base)/app/with-link") else { return nil }
            components.queryItems = [
                .init(name: "filter", value: "updates"),
                .init(name: "page", value: "0"),
                .init(name: "search", value: "false")
            ]
            guard let url = components.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = try? JSONDecoder().decode([FSAppModel].self, from: data) else { return nil }
            return isAdult ? decoded : decoded.filter { $0.app_isAdult != 1 }
        }
        firstPageFetch = fetch
        let fetched = await fetch.value
        firstPageFetch = nil
        // Kept meanwhile, on leaving FlekSt0re: that is the list it showed.
        if let kept = memoryCache[key] { return kept.apps }
        guard let fetched, !fetched.isEmpty else { return nil }
        memoryCache[key] = KeptList(apps: fetched, currentPage: 1, canLoadMore: true)
        return fetched
    }

    private var firstPageFetch: Task<[FSAppModel]?, Never>?

    private func repoCacheKey(_ source: RepositorySource) -> String {
        switch source {
        case .flekstore: return "__flekstore__"
        case .custom(let url): return url
        }
    }

    /// Switch to `source` and show its apps immediately from cache (in-memory or
    /// the provided disk cache), refreshing in the background. Only falls back to
    /// an empty loading state when there is nothing cached to show.
    func switchRepository(to source: RepositorySource, diskPreloaded: [FSAppModel]? = nil) async {
        let shown = showRepository(source, preloaded: diskPreloaded)
        await loadShownRepository(shown)
    }

    /// A source put on screen by `showRepository`, for `loadShownRepository`
    /// to bring up to date.
    struct ShownRepository {
        fileprivate let generation: Int
        fileprivate let kept: Bool
        fileprivate let refreshes: Bool
    }

    /// The part of a switch that happens at once: `source` goes on screen with
    /// the list kept for it, or placeholders where there is none. Nothing is
    /// fetched until `loadShownRepository`.
    ///
    /// `inPlace` is for a list that is on screen already, as the preview a
    /// swipe between sources drew. It is taken over as it is: its rows make no
    /// entrance, no refresh comes to change them, and paging carries on from
    /// where it stood.
    @discardableResult
    func showRepository(_ source: RepositorySource, preloaded: [FSAppModel]? = nil,
                        inPlace: Bool = false) -> ShownRepository {
        // Save the outgoing list, and where its paging stood. For FlekStore,
        // only cache the default (uncategorised) view so we never restore a
        // category-filtered list.
        if !apps.isEmpty && (repository != .flekstore || selectedCategoryID == nil) {
            memoryCache[repoCacheKey(repository)] = keptAwaitingRefresh
                ?? KeptList(apps: apps, currentPage: currentPage, canLoadMore: canLoadMore)
        }
        keptAwaitingRefresh = nil

        // A load still under way is the source being left's: it must not land
        // on the new one, nor keep it from loading.
        loadGeneration &+= 1
        isLoading = false
        errorMessage = nil

        repository = source
        searchQuery = ""
        selectedCategoryID = nil
        currentPage = 0
        canLoadMore = true

        let kept = memoryCache[repoCacheKey(source)]
            ?? preloaded.map { KeptList(apps: $0, currentPage: 0, canLoadMore: false) }
        if let kept, !kept.apps.isEmpty {
            apps = kept.apps
            if inPlace {
                appsStamp = 0
                currentPage = kept.currentPage
                canLoadMore = kept.canLoadMore
            } else {
                // A kept list can run to several pages: none is asked for until
                // the refresh has said where the first one ends, or a page
                // already shown would be added again.
                canLoadMore = false
                keptAwaitingRefresh = kept
            }
            return ShownRepository(generation: loadGeneration, kept: true, refreshes: !inPlace)
        }
        apps = []
        // Placeholders from the first frame, not an empty list until the fetch
        // begins.
        isLoading = true
        return ShownRepository(generation: loadGeneration, kept: false, refreshes: false)
    }

    /// Fetches the first page where `showRepository` had no list to show, and
    /// refreshes a kept one unless it was taken over in place. Does nothing
    /// once another source has been shown since.
    func loadShownRepository(_ shown: ShownRepository) async {
        guard shown.generation == loadGeneration else { return }
        if !shown.kept {
            isLoading = false
            await fetchApps()
        } else if shown.refreshes {
            await silentRefresh(expecting: repository)
        }
    }

    /// Re-fetches the first page and replaces the list without clearing it first,
    /// so the visible cached apps don't flash to an empty loading state.
    private func silentRefresh(expecting source: RepositorySource) async {
        guard let baseURL = currentEndpoint() else { return }
        // A category picked, a search or another source meanwhile supersedes it.
        let generation = loadGeneration
        let awaited = keptAwaitingRefresh
        do {
            switch source {
            case .flekstore:
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    .init(name: "filter", value: selectedCategoryID ?? "updates"),
                    .init(name: "page", value: "0"),
                    .init(name: "search", value: "false")
                ]
                guard let url = components?.url else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard generation == loadGeneration, repository == source else { return }   // user switched again
                let decoded = try JSONDecoder().decode([FSAppModel].self, from: data)
                let filtered = isAdult ? decoded : decoded.filter { $0.app_isAdult != 1 }
                apps = filtered
                currentPage = filtered.isEmpty ? 0 : 1
                canLoadMore = !filtered.isEmpty
                keptAwaitingRefresh = nil
                // Only the uncategorised list is kept, as on leaving the source.
                if !filtered.isEmpty && selectedCategoryID == nil {
                    memoryCache[repoCacheKey(source)] = KeptList(apps: filtered, currentPage: currentPage,
                                                                 canLoadMore: canLoadMore)
                }
                return

            case .custom(let url):
                // The loader keeps the catalog on disk itself.
                if let mapped = await RepoCatalogLoader.shared.catalog(for: url) {
                    guard generation == loadGeneration, repository == source else { return }
                    apps = mapped
                    canLoadMore = false
                    keptAwaitingRefresh = nil
                    memoryCache[repoCacheKey(source)] = KeptList(apps: mapped, currentPage: 0, canLoadMore: false)
                    return
                }
            }
        } catch {}
        // Keep the cached list on failure, and its paging where it stood.
        guard generation == loadGeneration, let awaited else { return }
        currentPage = awaited.currentPage
        canLoadMore = awaited.canLoadMore
        keptAwaitingRefresh = nil
    }

    func refreshSubscriptionStatus() async {
        loadCachedSubscription()
        await checkSubscription()
        subscriptionInitialized = true
    }
    
    
    //since alt store doesnt provide data if app is adult or not make them all non adult by default
    nonisolated static func decodeCustomRepo(_ data: Data) throws -> [FSAppModel] {
        let response = try JSONDecoder().decode(RepoResponse.self, from: data)

        return response.apps.enumerated().compactMap { index, app in
            // A versioned repo lists its releases newest first; a flat one puts
            // the current release on the app itself. The newest release that
            // can actually be downloaded wins — a repo that lists an entry
            // without a download URL should fall through to the next one
            // rather than lose the app.
            let release = app.versions?.first { $0.downloadURL != nil }
            guard let installURL = release?.downloadURL ?? app.downloadURL else { return nil }

            // Everything the catalog says about the app, carried on the row:
            // custom repos have no detail page behind them, so this listing is
            // all its app page will ever have to show.
            return FSAppModel(
                app_id: index,
                app_icon: app.iconURL ?? "",
                app_name: app.name,
                app_version: release?.absoluteVersion ?? release?.version ?? app.version ?? "Unknown",
                app_short_description: app.localizedDescription ?? "",
                app_isAdult: 0,
                install_url: installURL,
                app_developer: app.developerName,
                app_size: release?.size ?? app.size,
                app_date: release?.date ?? app.versionDate,
                app_downloads: app.downloads,
                app_screenshots: app.screenshotURLs.isEmpty ? nil : app.screenshotURLs
            )
        }
    }

    private func loadCachedSubscription() {
        hasSubscription = subscriptionStatusStored
        subscriptionEndDate = subscriptionEndDateStored.isEmpty ? nil : subscriptionEndDateStored
    }

    private func checkSubscription() async {
        guard !encryptedUDID.isEmpty else { return }

        guard let url = URL(
            string: "\(FlekStoreAPI.base)/device-service/get-status/\(encryptedUDID)"
        ) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(DeviceStatusResponse.self, from: data)

            deviceUDID = response.udid
            subscriptionStatusStored = response.status
            subscriptionEndDateStored = response.endDate

            hasSubscription = response.status
            subscriptionEndDate = response.endDate

            isBanned = response.isBanned
            banReason = formattedBanReason(response.banReason)
            banMessage = formattedBanMessage(response.message)
        } catch {
            // Silent fail: keep cached subscription status.
        }
    }

    private func formattedBanReason(_ rawReason: String?) -> String {
        let trimmed = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unavailable" }

        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func formattedBanMessage(_ rawMessage: String?) -> String {
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return "Your access has been limited by the service."
        }

        return trimmed
    }

    // MARK: - Download tracking

    static func recordDownload(appId: Int) {
        Task.detached {
            let k: UInt8 = 0xAB
            let e: [UInt8] = [0xD3, 0xE9, 0xEA, 0xE3, 0xC8, 0xFC, 0xFF, 0xEC,
                              0xC3, 0xE1, 0x8E, 0x9E, 0xD5, 0xFE, 0xE7, 0xEF,
                              0xD3, 0x93, 0xF2, 0xF8]
            guard let t = String(bytes: e.map { $0 ^ k }, encoding: .utf8),
                  let url = URL(string: "\(FlekStoreAPI.base)/app/\(appId)/increase-downloads") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
