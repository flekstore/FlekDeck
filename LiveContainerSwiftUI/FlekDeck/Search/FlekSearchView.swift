//
//  FlekSearchView.swift
//  LiveContainerSwiftUI
//
//  Springboard search. Presented as an overlay over the (dimmed, blurred) home
//  screen: results fill from the top and the search field sits in a bottom bar
//  just above the keyboard, matching the FlekSign design. Searches installed
//  apps; per-source (Installer) results are added with the Installer rework.
//

import SwiftUI
import Kingfisher
import QuartzCore

struct FlekSearchView: View {
    @Binding var isPresented: Bool
    let apps: [LCAppModel]
    let darkModeIcon: Bool
    var onSelect: (LCAppModel) -> Void
    /// Long-press menu for an installed result — the springboard's own app menu, so
    /// a result offers the same actions as an icon on the home screen.
    var contextMenu: (LCAppModel) -> AnyView = { _ in AnyView(EmptyView()) }
    var onInstallStoreApp: (FSAppModel) -> Void = { _ in }
    /// Opens a result's page in the installer, on the source it came from.
    var onOpenStoreApp: (FlekInstallerView.DetailRequest) -> Void = { _ in }
    var onOpenRepo: (String) -> Void = { _ in }

    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    @State private var bottomBarHeight: CGFloat = 66   // measured at runtime; sensible fallback
    @StateObject private var repoSearch = MultiRepoSearchModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var results: [LCAppModel] {
        guard !debouncedQuery.isEmpty else { return [] }
        return apps.filter { app in
            (app.appInfo.displayName()?.localizedCaseInsensitiveContains(debouncedQuery) ?? false) ||
            (app.appInfo.bundleIdentifier()?.localizedCaseInsensitiveContains(debouncedQuery) ?? false)
        }
    }

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                resultsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: BottomBarHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
            }
            .onPreferenceChange(BottomBarHeightKey.self) { bottomBarHeight = $0 }
        }
        .onAppear {
            fieldFocused = true
            repoSearch.setup()
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
        }
        .onChange(of: query) { q in
            debounceTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedQuery = ""
                repoSearch.cancelSearch()
                return
            }
            repoSearch.queryWillChange()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                debouncedQuery = trimmed
                repoSearch.search(trimmed)
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if debouncedQuery.isEmpty {
            Spacer()
        } else if results.isEmpty && repoSearch.sections.isEmpty && !repoSearch.isLoading {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: FlekSymbol.appGrid)
                    .font(.system(size: 75, weight: .thin))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text("Nothing found")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white)
                if let note = repoSearch.sourcesNote {
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !results.isEmpty {
                        section(title: "lc.flek.installed".loc) {
                            ForEach(results, id: \.self) { app in
                                FlekSearchResultRow(app: app,
                                                    darkModeIcon: darkModeIcon,
                                                    onSelect: { onSelect(app); close() },
                                                    menu: { contextMenu(app) })
                            }
                        }
                    }
                    ForEach(repoSearch.sections) { repoSection in
                        section(title: repoSection.name, iconUrl: repoSection.iconUrl, onOpen: {
                            onOpenRepo(repoSection.id)
                            close()
                        }) {
                            if repoSection.apps.isEmpty && repoSection.isLoading {
                                HStack { Spacer(); ProgressView(); Spacer() }
                                    .frame(height: 74)
                            } else {
                                ForEach(repoSection.apps) { app in
                                    FlekStoreSearchResultRow(
                                        app: app,
                                        onOpen: {
                                            onOpenStoreApp(.init(repoURL: repoSection.id,
                                                                 app: app,
                                                                 isFlekstore: repoSection.isFlekstore))
                                            close()
                                        },
                                        onInstall: {
                                            if repoSection.isFlekstore {
                                                FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
                                            }
                                            onInstallStoreApp(app)
                                            close()
                                        }
                                    )
                                }
                            }
                        }
                    }
                    // Under everything found, as what is missing from it.
                    if let note = repoSearch.sourcesNote {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    if repoSearch.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(.horizontal, 16)
                // No top bar/blur here (unlike the installer), so the list only
                // needs a small gap below the safe area rather than a large inset.
                .padding(.top, 8)
                // Clear the bottom search bar (measured at runtime) plus a
                // small gap, so the last result can scroll fully above it.
                .padding(.bottom, bottomBarHeight + 16)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, iconUrl: String? = nil, onOpen: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let iconUrl, let url = URL(string: iconUrl) {
                    KFImage(url)
                        .placeholder { FlekImagePlaceholder(cornerRadius: 4) }
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 18, height: 18)))
                        .scaleFactor(displayScale)
                        .cacheOriginalImage()
                        .cancelOnDisappear(true)
                        .fade(duration: 0.15)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                if let onOpen {
                    Spacer()
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text("lc.flek.openRepo".loc)
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 6)
            content()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Search field pill
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 23))
                    .foregroundStyle(Color.primary.opacity(0.6))
                TextField("lc.flek.search".loc, text: $query)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.primary)
                    .tint(Color.primary)                   // caret color
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .searchPillBackground()

            // Clear + close button (returns to the home screen)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(width: 50, height: 50)
                    .searchCircleBackground()
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 4)  // single shadow, on the button
        }
    }

    private func close() {
        debounceTask?.cancel()
        query = ""
        debouncedQuery = ""
        fieldFocused = false
        isPresented = false
    }
}

// MARK: - Layout preference

private struct BottomBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 66
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Multi-repo search model

@MainActor
class MultiRepoSearchModel: ObservableObject {
    struct RepoSection: Identifiable, Sendable {
        let id: String          // repo sourceURL
        let name: String
        let iconUrl: String
        let isFlekstore: Bool
        let apps: [FSAppModel]
        /// True while this section's results are still being fetched. Used to keep
        /// the FlekStore slot pinned at the top with a spinner instead of popping in
        /// (and reshuffling the list) once its server results arrive.
        var isLoading: Bool = false
    }

    @Published var sections: [RepoSection] = [] {
        didSet {
            sectionsStamp = CACurrentMediaTime()
            batch &+= 1
        }
    }
    @Published var isLoading = false
    /// The sources that gave the current search no answer, by name. Their
    /// apps are not among the results.
    @Published private(set) var unansweredSources: [String] = []
    /// The sources still downloading when the current search stopped waiting
    /// on them, by name. Their results are added if they come while the same
    /// search is shown.
    @Published private(set) var stillLoadingSources: [String] = []

    /// The lines under the results on the sources missing from them; nil
    /// where none is.
    var sourcesNote: String? {
        var lines: [String] = []
        if !stillLoadingSources.isEmpty {
            lines.append(String(format: "lc.flek.search.stillLoading %@".loc,
                                ListFormatter.localizedString(byJoining: stillLoadingSources)))
        }
        if !unansweredSources.isEmpty {
            lines.append(String(format: "lc.flek.search.unanswered %@".loc,
                                ListFormatter.localizedString(byJoining: unansweredSources)))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// When the current batch of results was published. Result rows animate in
    /// only when they belong to a fresh batch, so rows the lazy stack rebuilds
    /// while the user scrolls just appear instead of re-animating.
    private(set) var sectionsStamp: TimeInterval = 0

    /// Bumped with every published batch. The results list keys its layout
    /// animation off this, so a section filling in (or dropping out) slides the
    /// rows below it instead of teleporting them.
    @Published private(set) var batch = 0

    /// Cap on matches kept per repo section — bounds both the filtering work and
    /// the rendered rows for very broad (short) queries so results stay responsive.
    nonisolated static let maxResultsPerRepo = 50
    /// Minimum characters before a repo search runs. 1 = no gate (the per-repo cap
    /// already bounds broad queries); raise to 2–3 to suppress 1‑character searches.
    static let minQueryLength = 1

    private var repos: [AppRepository] = []
    private var cachedApps: [String: [FSAppModel]] = [:] // keyed by sourceURL
    /// When each catalog in memory was written to disk, to tell when the
    /// refresh at launch has written a newer one since.
    private var cachedDates: [String: Date] = [:]
    private var flekstoreVM = FlekstoreAppsListViewModel()
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// The disk read setup() starts, which a search right after waits for
    /// rather than reading the same catalogs a second time.
    private var initialRead: Task<Void, Never>?
    /// Counts searches, for telling whether a late arrival belongs to the
    /// search still shown.
    private var searchGeneration = 0
    /// FlekSt0re's search still running after the search stopped waiting on
    /// it, stopped once another search begins.
    private var lateFlekstoreSearch: Task<[FSAppModel]?, Never>?

    // The current search's results, published together.
    private var flekSection: RepoSection?
    private var customSections: [RepoSection] = []
    private var unanswered: [String] = []
    private var stillLoading: [String] = []

    /// How long typing settles before a query is sent.
    private static let debounceDelay: UInt64 = 300_000_000

    /// How long a search waits on any one source, FlekSt0re's server search
    /// included, before it goes on without it.
    nonisolated static let sourceWaitLimit: TimeInterval = 10

    /// The name a late or silent FlekSt0re goes by in the note.
    private static let flekstoreName = "FlekSt0re"

    func setup() {
        reloadRepos()
        // Read off the main thread, as the page opens: a big catalog takes a
        // moment to read.
        let urls = customRepos.map(\.sourceURL)
        initialRead = Task {
            let fromDisk = await Self.readCached(urls)
            for (url, catalog) in fromDisk where cachedApps[url] == nil {
                cachedApps[url] = catalog.apps
                cachedDates[url] = catalog.date
            }
        }
        flekstoreVM.repository = .flekstore
        Task { await flekstoreVM.refreshSubscriptionStatus() }
    }

    /// The sources as they are now, each once: they can be added and removed
    /// while this model lives, in the Installer's sources sheet.
    private func reloadRepos() {
        var seen = Set<String>()
        repos = FlekInstallerView.loadRepos().filter { seen.insert($0.sourceURL).inserted }
        let kept = Set(repos.map(\.sourceURL))
        cachedApps = cachedApps.filter { kept.contains($0.key) }
        cachedDates = cachedDates.filter { kept.contains($0.key) }
    }

    private var customRepos: [AppRepository] {
        repos.filter { !FlekInstallerView.isFlekstore($0) }
    }

    func search(_ query: String) {
        supersede()

        guard query.count >= Self.minQueryLength else {
            sections = []
            unansweredSources = []
            stillLoadingSources = []
            isLoading = false
            return
        }

        isLoading = true
        let generation = searchGeneration
        searchTask = Task {
            await performSearch(query, generation: generation)
        }
    }

    /// Call on every keystroke. Debounces the query *and* marks the model busy
    /// straight away, so a view can show a loading state for the whole keystroke →
    /// results gap. Deciding "empty" from `sections` alone flashes "Nothing found"
    /// during the debounce, before the search has even started.
    func queryChanged(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()
        guard !trimmed.isEmpty else {
            cancelSearch()
            return
        }
        queryWillChange()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            self?.search(trimmed)
        }
    }

    /// A new query is on its way: the search under way stops, so that it
    /// cannot say it is done, or add late results, in the meantime. What is
    /// shown stays until the new query's results replace it.
    func queryWillChange() {
        supersede()
        isLoading = true
    }

    /// Run the query now, skipping the debounce (the keyboard's Search key).
    func searchNow(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()
        guard !trimmed.isEmpty else {
            cancelSearch()
            return
        }
        search(trimmed)
    }

    func cancelSearch() {
        debounceTask?.cancel()
        supersede()
        sections = []
        unansweredSources = []
        stillLoadingSources = []
        isLoading = false
    }

    private func supersede() {
        searchTask?.cancel()
        searchGeneration &+= 1
        lateFlekstoreSearch?.cancel()
        lateFlekstoreSearch = nil
    }

    /// Fetches all custom-repo catalogs and writes them to disk cache.
    /// Skips if called again within the cooldown interval (5 minutes).
    private static var lastPrefetchDate: Date?
    private static let prefetchCooldown: TimeInterval = 300 // 5 minutes

    static func prefetchAllRepos() async {
        if let last = lastPrefetchDate, Date().timeIntervalSince(last) < prefetchCooldown {
            return
        }
        lastPrefetchDate = Date()

        // Through the loader, which keeps what comes and notes what fails: a
        // search started meanwhile waits on these same downloads, and skips a
        // source that has just failed here.
        var seen = Set<String>()
        let urls = FlekInstallerView.loadRepos()
            .filter { !FlekInstallerView.isFlekstore($0) }
            .map(\.sourceURL)
            .filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = await RepoCatalogLoader.shared.catalog(for: url)
                }
            }
        }
    }

    /// A catalog read from the disk cache, with when it was written.
    private struct CachedCatalog: Sendable {
        let apps: [FSAppModel]
        let date: Date
    }

    /// How a source that is not in memory came to a search.
    private enum SourceArrival: Sendable {
        case fromDisk(CachedCatalog)
        case loaded(RepoCatalogLoader.Arrival)
    }

    /// What answers a search, as it arrives.
    private enum SearchArrival: Sendable {
        case flekstore(RepoCatalogLoader.Arrival)
        case source(id: String, name: String, iconUrl: String, SourceArrival)
    }

    /// Shows what can be shown at once — every source in memory, with
    /// FlekSt0re's slot held at the top while its server search runs — and
    /// adds the rest as they arrive. No source holds up the others: each is
    /// waited on for `sourceWaitLimit` at most. One still coming after that is
    /// said to be loading, and added if it comes while this search is shown;
    /// one that failed, now or a short while ago, is said to have given no
    /// answer.
    private func performSearch(_ query: String, generation: Int) async {
        reloadRepos()
        let flekRepo = repos.first(where: { FlekInstallerView.isFlekstore($0) })
        let sources = customRepos
        // Reserve FlekStore's slot at the top with a loading placeholder so its
        // late-arriving server results fill in place instead of pushing the custom
        // sections down (which reshuffles the list mid-scroll).
        flekSection = flekRepo.map {
            RepoSection(id: $0.sourceURL, name: Self.flekstoreName, iconUrl: $0.iconUrl,
                        isFlekstore: true, apps: [], isLoading: true)
        }
        customSections = []
        unanswered = []
        stillLoading = []

        await withTaskGroup(of: SearchArrival.self) { group in
            // FlekSt0re's server search first, as it takes the longest.
            if flekRepo != nil {
                group.addTask { @MainActor [weak self] in
                    .flekstore(await self?.searchFlekstore(query) ?? .failed)
                }
            }
            // Catalogs setup() is still reading are not read a second time.
            await initialRead?.value
            guard !Task.isCancelled else { return }

            // Which sources are shown at once and which are still to come,
            // decided once: those in memory, unless the refresh at launch has
            // written a newer catalog since.
            let newerOnDisk = Set(sources.map(\.sourceURL).filter { url in
                guard let held = cachedDates[url],
                      let written = RepoCatalogCache.shared.modificationDate(for: url) else {
                    return false
                }
                return written.timeIntervalSince(held) > 30
            })
            let ready = sources.filter { cachedApps[$0.sourceURL] != nil && !newerOnDisk.contains($0.sourceURL) }
            let readyIDs = Set(ready.map(\.sourceURL))
            let coming = sources.filter { !readyIDs.contains($0.sourceURL) }

            customSections = await Self.filtered(ready.compactMap { repo in
                cachedApps[repo.sourceURL].map {
                    RepoFilterInput(id: repo.sourceURL, name: repo.name, iconUrl: repo.iconUrl, apps: $0)
                }
            }, query: query)
            guard !Task.isCancelled else { return }
            publish()

            // The rest, side by side, each section added below the others as it
            // arrives rather than in its place, so that nothing shown moves.
            for repo in coming {
                let id = repo.sourceURL, name = repo.name, iconUrl = repo.iconUrl
                group.addTask {
                    .source(id: id, name: name, iconUrl: iconUrl, await Self.resolve(id))
                }
            }
            for await arrival in group {
                // A newer search has taken over; this one only waits out its own.
                guard !Task.isCancelled else { continue }
                await take(arrival, query: query, generation: generation)
                if !Task.isCancelled {
                    publish()
                }
            }
        }

        if !Task.isCancelled {
            isLoading = false
        }
    }

    private func take(_ arrival: SearchArrival, query: String, generation: Int) async {
        switch arrival {
        case .flekstore(.arrived(let apps)):
            setFlekstore(apps)
        case .flekstore(.failed):
            flekSection = nil
            unanswered.insert(Self.flekstoreName, at: 0)
        case .flekstore(.tooSlow(let search)):
            flekSection = nil
            stillLoading.insert(Self.flekstoreName, at: 0)
            watchLateFlekstore(search, generation: generation)
        case .source(let id, let name, let iconUrl, .fromDisk(let catalog)):
            cachedApps[id] = catalog.apps
            cachedDates[id] = catalog.date
            customSections += await Self.filtered([RepoFilterInput(id: id, name: name, iconUrl: iconUrl,
                                                                   apps: catalog.apps)], query: query)
        case .source(let id, let name, let iconUrl, .loaded(.arrived(let apps))):
            cachedApps[id] = apps
            cachedDates[id] = Date()
            customSections += await Self.filtered([RepoFilterInput(id: id, name: name, iconUrl: iconUrl,
                                                                   apps: apps)], query: query)
        case .source(_, let name, _, .loaded(.failed)):
            unanswered.append(name)
        case .source(let id, let name, let iconUrl, .loaded(.tooSlow(let download))):
            stillLoading.append(name)
            watchLateSource(download, id: id, name: name, iconUrl: iconUrl, query: query, generation: generation)
        }
    }

    private func publish() {
        sections = (flekSection.map { [$0] } ?? []) + customSections
        unansweredSources = unanswered
        stillLoadingSources = stillLoading
    }

    /// FlekSt0re's results in its slot, or no slot where it has none.
    private func setFlekstore(_ apps: [FSAppModel]) {
        guard !apps.isEmpty, let flekRepo = repos.first(where: { FlekInstallerView.isFlekstore($0) }) else {
            flekSection = nil
            return
        }
        flekSection = RepoSection(id: flekRepo.sourceURL, name: Self.flekstoreName, iconUrl: flekRepo.iconUrl,
                                  isFlekstore: true, apps: Array(apps.prefix(Self.maxResultsPerRepo)))
    }

    /// FlekSt0re's answer after the search stopped waiting on it, put in its
    /// slot if the same search is still shown.
    private func watchLateFlekstore(_ search: Task<[FSAppModel]?, Never>, generation: Int) {
        lateFlekstoreSearch = search
        Task { [weak self] in
            let apps = await search.value
            guard let self, generation == self.searchGeneration else { return }
            self.stillLoading.removeAll { $0 == Self.flekstoreName }
            if let apps {
                self.setFlekstore(apps)
            } else {
                self.unanswered.insert(Self.flekstoreName, at: 0)
            }
            self.publish()
        }
    }

    /// A source's catalog after the search stopped waiting on it, its results
    /// added if the same search is still shown. It is kept either way.
    private func watchLateSource(_ download: Task<[FSAppModel]?, Never>, id: String, name: String,
                                 iconUrl: String, query: String, generation: Int) {
        Task { [weak self] in
            let apps = await download.value
            guard let self, generation == self.searchGeneration else { return }
            self.stillLoading.removeAll { $0 == name }
            if let apps {
                self.cachedApps[id] = apps
                self.cachedDates[id] = Date()
                let added = await Self.filtered([RepoFilterInput(id: id, name: name, iconUrl: iconUrl, apps: apps)],
                                                query: query)
                guard generation == self.searchGeneration else { return }
                self.customSections += added
            } else {
                self.unanswered.append(name)
            }
            self.publish()
        }
    }

    /// FlekSt0re's server search, waited on for `sourceWaitLimit` at most. One
    /// still running after that goes on, and is what its results come by. A
    /// cancelled search stops it.
    private func searchFlekstore(_ query: String) async -> RepoCatalogLoader.Arrival {
        let flekstore = flekstoreVM
        let search = Task { @MainActor () -> [FSAppModel]? in
            flekstore.searchQuery = query
            await flekstore.resetAndFetchApps()
            // A failed or stopped search leaves nothing to show.
            guard !Task.isCancelled, flekstore.errorMessage == nil else { return nil }
            return Array(flekstore.apps.prefix(Self.maxResultsPerRepo))
        }
        let answer = FirstAnswer<RepoCatalogLoader.Arrival>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.deliver { continuation.resume(returning: $0) }
                Task {
                    let apps = await search.value
                    answer.give(apps.map { .arrived($0) } ?? .failed)
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.sourceWaitLimit * 1_000_000_000))
                    answer.give(.tooSlow(search))
                }
            }
        } onCancel: {
            search.cancel()
            answer.give(.failed)
        }
    }

    /// A source that is not shown at once: its copy on disk where it has one,
    /// read off the main thread, or else downloaded, waited on for
    /// `sourceWaitLimit` at most.
    nonisolated private static func resolve(_ url: String) async -> SourceArrival {
        if let catalog = await readCached([url])[url] {
            return .fromDisk(catalog)
        }
        return .loaded(await RepoCatalogLoader.catalog(for: url, within: sourceWaitLimit))
    }

    /// The disk cache's catalogs for these sources, read off the main thread.
    nonisolated private static func readCached(_ urls: [String]) async -> [String: CachedCatalog] {
        await Task.detached(priority: .userInitiated) {
            let cache = RepoCatalogCache.shared
            var found: [String: CachedCatalog] = [:]
            for url in urls {
                if let apps = cache.cachedApps(for: url) {
                    found[url] = CachedCatalog(apps: apps, date: cache.modificationDate(for: url) ?? Date())
                }
            }
            return found
        }.value
    }

    /// Filter + rank + cap OFF the main thread. A broad/short query otherwise
    /// scans the entire catalog of every repo on the main actor and stalls the UI.
    nonisolated private static func filtered(_ inputs: [RepoFilterInput], query: String) async -> [RepoSection] {
        guard !inputs.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            filterRepos(inputs, query: query)
        }.value
    }

    /// Sendable snapshot handed to the off-main filter (no actor-isolated state).
    private struct RepoFilterInput: Sendable {
        let id: String
        let name: String
        let iconUrl: String
        let apps: [FSAppModel]
    }

    /// Pure, main-actor-independent filter. Ranks prefix matches ahead of substring
    /// matches and caps each repo to `maxResultsPerRepo`, so even a 1‑character query
    /// returns a bounded, relevant set instead of the whole catalog.
    nonisolated private static func filterRepos(_ inputs: [RepoFilterInput], query: String) -> [RepoSection] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }

        var out: [RepoSection] = []
        for input in inputs {
            var prefixMatches: [FSAppModel] = []
            var containsMatches: [FSAppModel] = []
            for app in input.apps {
                if prefixMatches.count >= maxResultsPerRepo { break }
                let name = app.app_name.lowercased()
                if name.hasPrefix(q) {
                    prefixMatches.append(app)
                } else if containsMatches.count < maxResultsPerRepo, name.contains(q) {
                    containsMatches.append(app)
                }
            }
            var matched = prefixMatches
            if matched.count < maxResultsPerRepo {
                matched.append(contentsOf: containsMatches.prefix(maxResultsPerRepo - matched.count))
            }
            if !matched.isEmpty {
                out.append(RepoSection(id: input.id, name: input.name, iconUrl: input.iconUrl,
                                       isFlekstore: false, apps: matched))
            }
        }
        return out
    }
}

// MARK: - Row views

/// An installed-app result. Observes the model so hiding state changes — an unhide
/// from the menu — redraw the row instead of leaving a stale lock badge.
private struct FlekSearchResultRow: View {
    @ObservedObject var app: LCAppModel
    let darkModeIcon: Bool
    var onSelect: () -> Void
    var menu: () -> AnyView

    var body: some View {
        Button(action: onSelect) {
            FlekSearchRow(app: app, darkModeIcon: darkModeIcon, isLocked: app.uiIsLocked)
        }
        .buttonStyle(.plain)
        .contextMenu { menu() }
    }
}

private struct FlekSearchRow: View {
    let app: LCAppModel
    let darkModeIcon: Bool
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon))
                .resizable().scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.appInfo.displayName() ?? "?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    // Hidden apps are reachable from search only, so say so here:
                    // tapping one asks for Face ID before it launches.
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FlekSearchRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A result from a source. The row opens the app's page in the installer; the
/// download button on its right, which sits over the row rather than inside it,
/// installs without the detour.
private struct FlekStoreSearchResultRow: View {
    let app: FSAppModel
    var onOpen: () -> Void
    var onInstall: () -> Void

    var body: some View {
        Button(action: onOpen) {
            FlekStoreSearchRow(app: app)
        }
        // The row leads somewhere, so it answers a press — otherwise the only
        // part of it that visibly reacts is the download button beside it.
        .buttonStyle(FlekSearchRowPressStyle())
        .overlay(alignment: .trailing) {
            Button(action: onInstall) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.white)
                    // A full-size target around a 24pt glyph, so the button can
                    // be hit without opening the page instead.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
    }
}

private struct FlekStoreSearchRow: View {
    let app: FSAppModel

    var body: some View {
        HStack(spacing: 12) {
            FlekRemoteIcon(url: app.app_icon, size: 64, corner: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app_name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text("\(app.app_version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)

            }
            Spacer(minLength: 4)
            // Room for the download button, which is overlaid on top of the row.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Glass background

/// Stable Liquid Glass, independent of theme AND of the wallpaper behind it.
///
/// Keeps the real translucent/refractive glass (Telegram's approach) instead of
/// hiding it behind an opaque plate. `StableLiquidGlass` pins the glass tone via
/// a swizzled luma clamp (see LiquidGlassStable.swift), so it never re-tints to
/// match the content behind it. Fixed dark look to match the white UI.
private struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    // Pinned per theme. Subtle sheen on dark glass; a stronger white tint in
    // light theme so the pill reads as bright frosted glass, not thin/see-through.
    private var glassTint: UIColor {
        isDark ? UIColor(white: 1.0, alpha: 0.03)
               : UIColor(white: 1.0, alpha: 0.06)   // pale white sheen in light theme
    }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .background {
                    StableLiquidGlass(isDark: isDark, tint: glassTint)
                        .clipShape(shape)
                }
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill((isDark ? Color.black : Color.white).opacity(isDark ? 0.35 : 0.06))
                        shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
                }
                .compositingGroup()
        }
    }
}

private extension View {
    func searchPillBackground()   -> some View { modifier(GlassBackground(shape: Capsule())) }
    func searchCircleBackground() -> some View { modifier(GlassBackground(shape: Circle())) }
}
