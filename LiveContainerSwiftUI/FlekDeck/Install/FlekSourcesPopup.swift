//
//  FlekSourcesPopup.swift
//  LiveContainerSwiftUI
//
//  Source management popup for the Installer. Lets the user add a repository
//  (validated by fetching its manifest), pick one (which opens its catalog),
//  and — in edit mode — delete sources or drag them into a new order (the
//  default FlekSt0re source is protected and stays on top). Persists to the
//  same UserDefaults("savedRepositories") store used elsewhere, so the
//  Installer's source pills follow the same order.
//

import SwiftUI

struct FlekSourcesPopup: View {
    @Binding var repos: [AppRepository]
    var onSelect: (AppRepository) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var newRepoURL = ""
    @State private var isAdding = false
    @State private var editing = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var pendingDelete: AppRepository?
    /// The source being dragged by its handle, and how far it has been pulled
    /// from the slot it now sits in.
    @State private var draggedRepoID: UUID?
    @State private var dragOffset: CGFloat = 0
    /// Where the dragged source started, so the translation can be read
    /// against it however many slots it has moved since.
    @State private var dragStartIndex = 0
    @State private var rowHeight: CGFloat = 60

    private static let rowSpacing: CGFloat = 8

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)
    private static let fieldFill = Color(red: 136/255, green: 136/255, blue: 136/255).opacity(0.15)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addSourceSection
                    connectedSourcesSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("lc.flek.appSources".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editing ? "lc.common.done".loc : "lc.flek.edit".loc) {
                        withAnimation { editing.toggle() }
                    }
                    .disabled(draggedRepoID != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
            .alert("lc.common.error".loc, isPresented: $showError) {
                Button("lc.common.ok".loc) {}
            } message: { Text(errorMessage) }
            .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })) {
                Button("lc.common.delete".loc, role: .destructive) {
                    if let r = pendingDelete { delete(r) }
                    pendingDelete = nil
                }
                Button("lc.common.cancel".loc, role: .cancel) { pendingDelete = nil }
            } message: {
                Text("lc.flek.confirmDeleteSource".loc)
            }
        }
    }

    // MARK: Add source

    private var addSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lc.flek.addSource".loc).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image(systemName: "link").font(.system(size: 22)).foregroundStyle(Color(white: 0.45))
                TextField("", text: $newRepoURL)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .overlay(alignment: .leading) {
                        if newRepoURL.isEmpty {
                            Text(verbatim: "https://fleksign.com/repo")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                                .allowsHitTesting(false)
                        }
                    }
                if isAdding {
                    ProgressView().frame(width: 33, height: 33)
                } else {
                    Button { Task { await addRepository() } } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Self.flekBlue)
                    }
                    .buttonStyle(.plain)
                    .disabled(newRepoURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(Capsule().fill(Self.fieldFill))
        }
    }

    // MARK: Connected sources

    private var connectedSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lc.flek.connectedSources".loc).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: Self.rowSpacing) {
                ForEach(repos) { repo in
                    let dragged = repo.id == draggedRepoID
                    sourceRow(repo)
                        .scaleEffect(dragged ? 1.03 : 1)
                        .shadow(color: .black.opacity(dragged ? 0.18 : 0), radius: 12, y: 4)
                        .offset(y: dragged ? dragOffset : 0)
                        .zIndex(dragged ? 1 : 0)
                }
            }
            .coordinateSpace(name: Self.listSpace)
        }
    }

    private func sourceRow(_ repo: AppRepository) -> some View {
        let isDefault = FlekInstallerView.isFlekstore(repo)
        return HStack(spacing: 8) {
            if editing && !isDefault {
                Button { pendingDelete = repo } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
            }
            FlekRemoteIcon(url: repo.iconUrl, size: 44, corner: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.name).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(isDefault ? "lc.flek.defaultSource".loc : repo.sourceURL)
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if editing && !isDefault {
                reorderHandle(repo)
            } else if !editing {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color(.separator), lineWidth: 1))
        .background(GeometryReader { geo in
            Color.clear.onAppear { rowHeight = geo.size.height }
        })
        .contentShape(Rectangle())
        .onTapGesture {
            if editing { return }
            select(repo)
            dismiss()
        }
    }

    // MARK: Reordering

    private static let listSpace = "sourcesList"

    /// Drag handle of a third-party source: pulling it moves the row, and the
    /// rows it passes step aside, as in a system list.
    private func reorderHandle(_ repo: AppRepository) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            // Ahead of the scroll view's own pan, so pulling the handle moves
            // the row rather than the page.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace))
                    .onChanged { value in dragChanged(repo, translation: value.translation.height) }
                    .onEnded { _ in dragEnded() }
            )
    }

    private func dragChanged(_ repo: AppRepository, translation: CGFloat) {
        if draggedRepoID == nil {
            guard let start = repos.firstIndex(where: { $0.id == repo.id }) else { return }
            dragStartIndex = start
            withAnimation(.easeOut(duration: 0.15)) { draggedRepoID = repo.id }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard draggedRepoID == repo.id,
              let current = repos.firstIndex(where: { $0.id == repo.id }) else { return }

        let pitch = rowHeight + Self.rowSpacing
        // FlekSt0re stays on top: nothing is dropped above it.
        let firstMovable = (repos.lastIndex(where: { FlekInstallerView.isFlekstore($0) }) ?? -1) + 1
        let target = min(max(dragStartIndex + Int((translation / pitch).rounded()), firstMovable),
                         repos.count - 1)
        if target != current {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                let moved = repos.remove(at: current)
                repos.insert(moved, at: target)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        dragOffset = translation - CGFloat(target - dragStartIndex) * pitch
    }

    private func dragEnded() {
        guard draggedRepoID != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            draggedRepoID = nil
            dragOffset = 0
        }
        save()
    }

    // MARK: Logic

    private func select(_ repo: AppRepository) {
        repos = repos.map { var r = $0; r.isSelected = (r.id == repo.id); return r }
        save()
        onSelect(repo)
    }

    private func delete(_ repo: AppRepository) {
        repos.removeAll { $0.id == repo.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: "savedRepositories")
        }
    }

    /// What a new source's address answered with, read off the main thread.
    private struct CheckedSource: Sendable {
        let name: String?
        let iconUrl: String
        let apps: [FSAppModel]
    }

    private func addRepository() async {
        var trimmed = newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address typed without its scheme is a web address.
        if !trimmed.isEmpty, !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else {
            showErr("lc.appList.urlInvalidError".loc); return
        }
        // A source is listed once: twice, its apps would show twice everywhere.
        if repos.contains(where: { $0.sourceURL == trimmed }) {
            showErr("lc.flek.sourceAlreadyAdded".loc); return
        }
        await MainActor.run { isAdding = true }
        defer { Task { @MainActor in isAdding = false } }
        do {
            // Not left waiting a minute on an address that does not answer.
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
            // Read as the catalog it is to be, off the main thread, as a big
            // one takes a moment: an object without apps is no source.
            let checked = await Task.detached(priority: .userInitiated) { () -> CheckedSource? in
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let apps = try? FlekstoreAppsListViewModel.decodeCustomRepo(data) else {
                    return nil
                }
                var iconUrl = (json["iconURL"] as? String) ?? ""
                if iconUrl.isEmpty, let meta = json["META"] as? [String: Any] {
                    iconUrl = (meta["repoIcon"] as? String) ?? ""
                }
                return CheckedSource(name: json["name"] as? String, iconUrl: iconUrl, apps: apps)
            }.value
            guard let checked else {
                showErr("lc.flek.invalidSource".loc); return
            }
            // What was read is kept, so that the source shows and is searched
            // at once rather than downloaded again.
            let source = trimmed
            Task.detached(priority: .utility) {
                RepoCatalogCache.shared.store(apps: checked.apps, for: source)
            }
            let repo = AppRepository(name: checked.name ?? url.host ?? trimmed, iconUrl: checked.iconUrl,
                                     sourceURL: trimmed, isSelected: false)
            await MainActor.run {
                repos.append(repo)
                save()
                newRepoURL = ""
            }
        } catch {
            showErr(error.localizedDescription)
        }
    }

    @MainActor private func showErr(_ msg: String) {
        errorMessage = msg
        showError = true
    }
}
