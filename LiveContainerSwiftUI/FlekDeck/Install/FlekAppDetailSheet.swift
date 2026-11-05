//
//  FlekAppDetailSheet.swift
//  LiveContainerSwiftUI
//
//  The app page behind an installer row: icon, developer, install button, the
//  app's setup warning, stat chips (version / size / updated / downloads),
//  screenshots and the full description.
//
//  The header is drawn from the `FSAppModel` the row already holds, so it is on
//  screen the instant the sheet opens; everything below it comes from
//  `GET /app/{app_id}` and fades in when it lands. That endpoint is FlekSt0re's
//  own — a custom repo's `app_id` is only its index in that repo's catalog, so
//  for those the page is built from the row alone. It carries what the repo's
//  catalog said (`FSAppModel`'s custom-repo fields), which for the better-filled
//  repos is most of the same page: developer, size, release date, screenshots.
//

import SwiftUI
import Kingfisher

// MARK: - Loader

@MainActor
final class FlekAppDetailModel: ObservableObject {
    @Published private(set) var detail: FSAppDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    /// The description, parsed once on arrival. Re-parsing it in `body` would
    /// run a regex over several KB of markup on every redraw.
    @Published private(set) var descriptionBlocks: [FSDescriptionBlock] = []

    private var loadedID: Int?

    func load(appID: Int) async {
        // The sheet's `task` re-runs on re-entry; don't re-fetch what we have.
        guard loadedID != appID else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }

        guard let url = URL(string: "\(FlekStoreAPI.base)/app/\(appID)") else {
            failed = true
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(FSAppDetail.self, from: data)
            guard !Task.isCancelled else { return }
            detail = decoded
            descriptionBlocks = FSDescriptionParser.blocks(from: decoded.description ?? "")
            loadedID = appID
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    func retry(appID: Int) async {
        loadedID = nil
        await load(appID: appID)
    }

    /// Custom repos have no detail page, so their listing description is used
    /// instead. It goes through the same parser, which leaves plain text alone
    /// but still copes with a repo that puts markup in the field.
    func useListingDescription(_ text: String) {
        guard descriptionBlocks.isEmpty else { return }
        descriptionBlocks = FSDescriptionParser.blocks(from: text)
    }

    /// Aspect (w/h) the screenshot row is laid out at, resolved from the first
    /// shot *before* the row is shown. Nil while it is still being worked out.
    @Published private(set) var galleryAspect: CGFloat?

    /// Assumed when the first screenshot can't be measured — a portrait phone.
    static let fallbackAspect: CGFloat = 0.46

    /// Measures the first screenshot so the row can be laid out at its final
    /// height immediately.
    ///
    /// The row can't just adopt each image's aspect as it decodes: with five
    /// shots that resizes the gallery up to five times, and again later when a
    /// shot the user scrolls to finally loads. Settling it once, off-screen,
    /// makes it a single layout instead of a staircase — and because the probe
    /// warms Kingfisher's cache, the first shot paints the moment it appears.
    func loadGalleryAspect(photos: [String]) async {
        guard galleryAspect == nil else { return }
        guard let first = photos.first, let url = URL(string: first) else {
            galleryAspect = Self.fallbackAspect
            return
        }
        let size = await Self.imageSize(url: url)
        guard !Task.isCancelled else { return }
        if let size, size.width > 0, size.height > 0 {
            galleryAspect = size.width / size.height
        } else {
            galleryAspect = Self.fallbackAspect
        }
    }

    private static func imageSize(url: URL) async -> CGSize? {
        await withCheckedContinuation { continuation in
            // Memory only, to match how the gallery and the viewer load these —
            // otherwise measuring the first shot would be the one thing that
            // writes a screenshot to disk. Decoded here too, and at the same
            // size, as the gallery's are, since the gallery then shows this copy.
            let decoding = FlekImageMemory.screenshotDecoding(height: FlekAppDetailSheet.maxScreenshotHeight)
            let options: KingfisherOptionsInfo = [.cacheMemoryOnly, .backgroundDecode,
                                                  .processor(decoding.processor), .scaleFactor(decoding.scale)]
            KingfisherManager.shared.retrieveImage(with: url, options: options) { result in
                continuation.resume(returning: (try? result.get())?.image.size)
            }
        }
    }
}

// MARK: - Sheet

struct FlekAppDetailSheet: View {
    let app: FSAppModel
    /// Only FlekSt0re apps have a detail page to fetch — see the file header.
    let isFlekstore: Bool
    let accent: Color
    /// Queues the install, with any pre-install changes chosen via the gear.
    var onInstall: (FlekInstallOverrides?) -> Void

    @StateObject private var model = FlekAppDetailModel()
    @ObservedObject private var installQueue = LCInstallQueue.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdvanced = false
    /// Icon / name / bundle ID chosen via the gear, handed to the queue on install.
    ///
    /// The name is seeded with the app's own, so the gear's field holds real
    /// text the user can edit or clear rather than an empty box. Seeded here
    /// rather than in the gear sheet so that clearing it *stays* cleared when
    /// that sheet is reopened.
    @State private var overrides = FlekInstallOverrides()
    @State private var didSeedOverrides = false

    /// Whether anything actually differs from what the app would install as.
    /// Clearing the name counts — that asks for the IPA's own name instead of
    /// the listing's, which is a deliberate change too.
    private var hasCustomisation: Bool {
        overrides.iconFileURL != nil
            || overrides.bundleID != nil
            || overrides.displayName != app.app_name
    }
    /// Brief "Installed" confirmation after a successful install, mirroring the
    /// row's checkmark. It is deliberately not sticky: the queue only remembers
    /// what was installed *this session*, so a permanent "Installed" here would
    /// claim something the app can't actually know about an app installed
    /// yesterday, and would leave a green button that silently re-installs.
    @State private var showDone = false
    /// The screenshot gallery opened full screen, if any.
    @State private var viewer: ViewerTarget?
    /// The shot the open viewer is on. Followed as the user pages, so the zoom
    /// transition returns to the thumbnail they are actually looking at rather
    /// than the one they came in from.
    @State private var viewerIndex = 0
    /// Ties each thumbnail to the viewer it opens, for the zoom transition.
    @Namespace private var screenshotZoom
    /// Which thumbnail the zoom transition grows out of and shrinks back into.
    ///
    /// Separate from `viewerIndex`, which the pager writes to directly: a
    /// `TabView(.page)` opened on a non-zero page briefly reports page 0 through
    /// its selection binding while it lays out, and read live that stray write
    /// reached the transition mid-flight — tapping the third shot could visibly
    /// start the animation from the first. This is set from the tap and left
    /// alone until the opening animation is over, after which it follows the
    /// pager so dismissing still returns to the shot actually on screen.
    @State private var zoomSourceID = 0
    /// False until the opening transition has finished, while `zoomSourceID`
    /// stays pinned to the thumbnail that was tapped.
    @State private var zoomSourceFollowsPager = false

    /// Which shot was tapped, and the set to page through from there.
    private struct ViewerTarget: Identifiable {
        let photos: [String]
        let index: Int
        var id: Int { index }
    }

    /// Sets the height of the whole header — the name/developer/button column is
    /// pinned to it. 130 is what a two-line app name needs to still fit beside
    /// it; at 116 the button was pushed ~6pt below the icon whenever the name
    /// wrapped.
    private static let iconSize: CGFloat = 130
    /// Tallest the screenshot row is allowed to get. Portrait shots reach it;
    /// landscape ones are limited by width instead.
    fileprivate static let maxScreenshotHeight: CGFloat = 380
    /// Gap between shots, shared with the skeleton row so the two are laid out
    /// alike and the swap from one to the other moves nothing.
    private static let gallerySpacing: CGFloat = 10
    private static let hPadding: CGFloat = 16
    /// The install capsule's width. Fixed, so the label is what gives way in a
    /// language that needs more room, not the button.
    private static let installButtonWidth: CGFloat = 80
    /// Height of the pinned dismiss strip the content scrolls beneath.
    private static let headerStripHeight: CGFloat = 44

    private var detail: FSAppDetail? { model.detail }

    // The detail page's answer where there is one, the row's otherwise — a
    // custom repo's listing is the only source its page has.

    private var developer: String? {
        guard let name = detail?.developer ?? app.app_developer, !name.isEmpty else { return nil }
        return name
    }

    private var photos: [String] {
        if let photos = detail?.photos, !photos.isEmpty { return photos }
        return app.app_screenshots ?? []
    }

    private var installItem: InstallItem? { installQueue.item(for: app.install_url) }
    private var isCompleted: Bool { installQueue.completedURLs.contains(app.install_url) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let warning = detail?.warningText {
                            warningCard(warning)
                                .transition(.opacity)
                        }
                        statChips
                        screenshots(containerWidth: geo.size.width)
                        description
                        if model.failed {
                            loadFailed
                        }
                    }
                    .padding(.top, Self.headerStripHeight + 4)
                    .padding(.bottom, 40)
                    .animation(reduceMotion ? .easeInOut(duration: 0.2)
                                            : .spring(response: 0.4, dampingFraction: 0.9),
                               value: detail?.id)
                    // The skeleton stands at the portrait height; a landscape
                    // gallery comes in shorter. Settle into the measured height
                    // rather than snapping the page to it.
                    .animation(.easeInOut(duration: 0.25), value: model.galleryAspect)
                }

                dismissStrip
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task {
            if !didSeedOverrides {
                didSeedOverrides = true
                overrides.displayName = app.app_name
            }
            guard isFlekstore else {
                model.useListingDescription(app.app_short_description)
                await model.loadGalleryAspect(photos: app.app_screenshots ?? [])
                return
            }
            await model.load(appID: app.app_id)
            await model.loadGalleryAspect(photos: model.detail?.photos ?? [])
        }
        .fullScreenCover(item: $viewer) { target in
            FlekScreenshotViewer(photos: target.photos, index: $viewerIndex,
                                 aspect: model.galleryAspect ?? FlekAppDetailModel.fallbackAspect)
                .screenshotZoomTransition(id: zoomSourceID, in: screenshotZoom)
                .onAppear {
                    // Long enough for the zoom to finish, which is the only
                    // window the pager's settling write can land in. Nobody
                    // pages a screenshot while it is still growing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        zoomSourceFollowsPager = true
                    }
                }
                .onDisappear { zoomSourceFollowsPager = false }
        }
        .onChange(of: viewerIndex) { newValue in
            guard zoomSourceFollowsPager else { return }
            zoomSourceID = newValue
        }
        .onChange(of: isCompleted) { completed in
            guard completed else { return }
            showDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { showDone = false }
        }
    }

    // MARK: Dismiss strip

    private var dismissStrip: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.compact.down")
                // Larger than the plain chevron it replaces: the compact glyph
                // is a wide, shallow stroke, and at the old size it read as a
                // smudge rather than as a direction to pull the sheet in.
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .frame(maxWidth: .infinity)
                .frame(height: Self.headerStripHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Opaque so the content scrolls cleanly beneath it rather than showing
        // through the chevron.
        .background(Color(.systemGroupedBackground))
        .accessibilityLabel("lc.common.close".loc)
    }

    // MARK: Header

    /// Icon on the left, with the name / developer / install button stacked
    /// beside it. The column is pinned to the icon's height so the icon frames
    /// the whole header — the title box is capped at two lines and the button
    /// sits on the baseline of the icon rather than hanging below it.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            // Progress rides on the icon, exactly as it does on a list row and
            // on the springboard, so an install looks the same wherever it is
            // being watched from.
            ZStack {
                if let state = installItem?.installState {
                    FlekInstallIcon(state: state, size: Self.iconSize, corner: 29)
                        .transition(.opacity)
                } else {
                    FlekRemoteIcon(url: app.app_icon, size: Self.iconSize, corner: 29)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            .animation(.easeInOut(duration: 0.2), value: installItem == nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.app_name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                if let developer {
                    Text(String(format: "lc.flek.detail.by %@".loc, developer))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                // Collapsible: with a two-line name there is nothing to spare,
                // and the button must still land on the icon's bottom edge.
                Spacer(minLength: 0)

                // Half a control's width between them, rather than the tight
                // pairing 10 gave: the gear reads as its own control instead of
                // an appendix to the install button.
                HStack(spacing: 16) {
                    installButton
                    advancedButton
                }
            }
            .frame(height: Self.iconSize, alignment: .topLeading)
        }
        .padding(.horizontal, Self.hPadding)
    }

    // MARK: Install button

    private var installButton: some View {
        Button {
            if installItem != nil {
                installQueue.cancel(url: app.install_url)
            } else {
                onInstall(overrides.isEmpty ? nil : overrides)
            }
        } label: {
            installButtonLabel
                .foregroundStyle(installButtonForeground)
            // Sized to its label rather than filling the column: the phase
            // labels ("Downloading…") are longer than "Install", so a minimum
            // width keeps the idle button from looking cramped without letting
            // it stretch the full width of the header.
            .padding(.horizontal, 3)
            .frame(width: Self.installButtonWidth, height: 38)
            .background(Capsule().fill(installButtonFill))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A little bounce, so finishing reads as a flash of green rather than a
        // quiet recolour.
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                                : .spring(response: 0.32, dampingFraction: 0.6),
                   value: installButtonState)
    }

    /// Every state's label laid out at once, all but the current one invisible,
    /// so the capsule is as wide as the widest of the three and holds that width
    /// throughout: a button that resizes under the finger pressing it reads as a
    /// different button, and the colour and the word have enough to do already.
    ///
    /// Measured rather than pinned to a number, because the number would have to
    /// be the widest label in the widest language — "Installieren" is half again
    /// "Install", and the finished state carries a checkmark besides — and every
    /// other language would then sit in a capsule sized for German.
    private var installButtonLabel: some View {
        ZStack {
            ForEach(InstallButtonState.allCases, id: \.self) { state in
                installButtonContent(state)
                    .hidden()
                    .accessibilityHidden(true)
            }
            installButtonContent(installButtonState)
        }
    }

    private func installButtonContent(_ state: InstallButtonState) -> some View {
        HStack(spacing: 3) {
            if state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    // Arrives with the green rather than after it.
                    .transition(reduceMotion ? .opacity
                                             : .scale.combined(with: .opacity))
            }
            Text(installButtonTitle(state))
                // Uppercased through `textCase` rather than in the string,
                // so each language is raised by its own rules.
                .textCase(.uppercase)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                // The capsule is a fixed 80 wide, and the labels are not: a
                // German "Installieren" is half again an English "Install".
                // Rather than let one language be clipped, the word gives way
                // and shrinks into the room there is.
                .minimumScaleFactor(0.6)
                .interpolatesContentIfAvailable()
        }
    }

    /// Opens the pre-install customisations. Badged once anything is set, so a
    /// change made here isn't invisible from the page it applies to.
    private var advancedButton: some View {
        Button {
            showAdvanced = true
        } label: {
            Image(systemName: "gear")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .detailSurface(Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if hasCustomisation {
                        Circle()
                            .fill(accent)
                            .frame(width: 9, height: 9)
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("lc.flek.advanced.title".loc)
        // Attached here rather than to the sheet's root: two `.sheet` modifiers
        // on the same view is the classic way to end up with only one of them
        // ever presenting.
        .sheet(isPresented: $showAdvanced) {
            FlekAppAdvancedSheet(app: app, overrides: $overrides)
        }
    }

    private enum InstallButtonState: Hashable, CaseIterable { case idle, active, done }

    private var installButtonState: InstallButtonState {
        if installItem != nil { return .active }
        return showDone ? .done : .idle
    }

    /// The button carries no progress of its own — that is on the icon. While an
    /// install runs it is simply the way to stop it, which matters here because
    /// the sheet covers the row that would otherwise offer that.
    private func installButtonTitle(_ state: InstallButtonState) -> String {
        switch state {
        case .idle:   return "lc.common.install".loc
        case .active: return "lc.common.cancel".loc
        case .done:   return "lc.flek.installed".loc
        }
    }

    private var installButtonForeground: Color {
        switch installButtonState {
        case .idle: return Color(.systemBackground)   // inverse of the fill below
        case .active: return .white
        case .done: return .white
        }
    }

    /// One capsule that changes colour, rather than a capsule per state: a
    /// `switch` in a background builder hands SwiftUI a different view each
    /// time, which can only cross-dissolve one over the other. A single fill
    /// interpolates instead, so the button travels through the colours between
    /// — dark to red on tapping install, red to green on finishing.
    private var installButtonFill: Color {
        switch installButtonState {
        // The design's white-on-dark pill, mirrored for light mode.
        case .idle: return Color(.label)
        // Cancelling is the destructive half of this button, so it takes the
        // system's own destructive red rather than a hand-picked one — it
        // shifts with the display's appearance and accessibility contrast the
        // way every other red in iOS does.
        case .active: return Color(.systemRed)
        case .done: return .green
        }
    }

    // MARK: Warning

    private func warningCard(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal, Self.hPadding)
    }

    // MARK: Stats

    private struct Stat: Identifiable {
        let id = UUID()
        let value: String
        let label: String
    }

    private var stats: [Stat] {
        var out: [Stat] = [
            Stat(value: detail?.version ?? app.app_version, label: "lc.flek.detail.version".loc)
        ]
        if let size = detail?.formattedSize ?? app.formattedSize {
            out.append(Stat(value: size, label: "lc.flek.detail.size".loc))
        }
        if let date = detail?.formattedDate ?? app.formattedDate {
            out.append(Stat(value: date, label: "lc.flek.detail.updated".loc))
        }
        if let downloads = detail?.formattedDownloads ?? app.formattedDownloads {
            out.append(Stat(value: downloads, label: "lc.flek.detail.downloads".loc))
        }
        return out
    }

    private var statChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.value)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(stat.label)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 15)
                    .detailSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.horizontal, Self.hPadding)
        }
    }

    // MARK: Screenshots

    /// One height for the whole row, with each shot's width following its own
    /// aspect — the way a system gallery behaves.
    ///
    /// The height can't be a constant: at a portrait height a landscape
    /// screenshot comes out wider than the screen, so a single shot fills the
    /// row and is clipped on both sides. It is derived from the first shot's
    /// aspect, resolved before the row is laid out.
    private func galleryHeight(aspect: CGFloat, containerWidth: CGFloat) -> CGFloat {
        // Leave a sliver of the next shot visible, so the row reads as scrollable.
        let maxItemWidth = max(containerWidth - Self.hPadding * 2 - 28, 120)
        return min(Self.maxScreenshotHeight, maxItemWidth / max(aspect, 0.05))
    }

    @ViewBuilder
    private func screenshots(containerWidth: CGFloat) -> some View {
        if !photos.isEmpty {
            if let aspect = model.galleryAspect {
                let height = galleryHeight(aspect: aspect, containerWidth: containerWidth)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.gallerySpacing) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                            Button {
                                viewerIndex = position
                                zoomSourceID = position
                                zoomSourceFollowsPager = false
                                viewer = ViewerTarget(photos: photos, index: position)
                            } label: {
                                FlekScreenshotThumb(photo: photo,
                                                    slotWidth: height * aspect,
                                                    height: height)
                            }
                            .buttonStyle(FlekScreenshotPressStyle())
                            .screenshotZoomSource(id: position, in: screenshotZoom)
                        }
                    }
                    .padding(.horizontal, Self.hPadding)
                }
                .frame(height: height)
            } else {
                // Measuring the first shot. Held at the portrait height so the
                // page doesn't reflow twice — once here and again on arrival.
                skeletonGallery(containerWidth: containerWidth)
            }
        } else if isFlekstore && model.isLoading {
            skeletonGallery(containerWidth: containerWidth)
        }
    }

    /// The row before there is anything to put in it — blocks the shape the
    /// shots will be, rather than a spinner alone in 380pt of empty page.
    ///
    /// They are the same blocks each shot then holds its own slot with, laid out
    /// at the same spacing and inset, so when the real row takes over nothing
    /// jumps: the images simply arrive on top of the blocks already there.
    private func skeletonGallery(containerWidth: CGFloat) -> some View {
        let aspect = FlekAppDetailModel.fallbackAspect
        let height = galleryHeight(aspect: aspect, containerWidth: containerWidth)
        let itemWidth = height * aspect
        // One past what fits, so the row is cut off at the edge the way the real
        // one is and reads as scrollable before it can be scrolled.
        let count = max(2, Int((containerWidth / (itemWidth + Self.gallerySpacing)).rounded(.up)) + 1)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.gallerySpacing) {
                ForEach(Array(0..<count), id: \.self) { _ in
                    FlekImagePlaceholder(cornerRadius: 14)
                        .frame(width: itemWidth, height: height)
                }
            }
            .padding(.horizontal, Self.hPadding)
        }
        // There is nothing here to scroll to yet, and nothing to tap.
        .allowsHitTesting(false)
        .frame(height: height)
    }

    // MARK: Description

    @ViewBuilder
    private var description: some View {
        if !model.descriptionBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("lc.flek.detail.description".loc)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)

                // Tight by default so consecutive bullets read as one list;
                // paragraphs and headings add their own leading space below.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.descriptionBlocks) { block in
                        descriptionBlock(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.hPadding)
            // Links carry the app's accent rather than the system blue.
            .tint(accent)
        }
    }

    @ViewBuilder
    private func descriptionBlock(_ block: FSDescriptionBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .heading:
            Text(block.text)
                // The source's own heading font is ignored — sizing it here
                // keeps headings consistent whatever the editor emitted.
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        case .listItem(let marker):
            // Hanging indent, so a wrapped bullet lines up under its own text
            // instead of under the marker.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: FSDescriptionParser.baseSize))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .leading)
                Text(block.text)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 2)
        }
    }

    // MARK: Failure

    private var loadFailed: some View {
        VStack(spacing: 12) {
            Text("lc.flek.detail.loadFailed".loc)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.retry(appID: app.app_id) }
            } label: {
                Text("lc.flek.retry".loc)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                    .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.horizontal, Self.hPadding)
    }
}

/// One shot in the gallery: a skeleton block the image then fades in over.
///
/// The crossfade is held here rather than left to Kingfisher's own placeholder
/// and `.fade`, which drop the placeholder the frame the image lands and fade
/// the image up from whatever is behind it — grey, then bare page, then the
/// shot. Keeping the block underneath gives the image something to arrive on.
private struct FlekScreenshotThumb: View {
    let photo: String
    /// What the skeleton holds: the row's aspect, since this shot's own isn't
    /// known until it decodes.
    let slotWidth: CGFloat
    let height: CGFloat

    /// Deliberately not gated on Reduce Motion: a cross-dissolve is what that
    /// setting asks for in place of movement, not something it asks to remove.
    private static let fadeDuration: TimeInterval = 0.28

    @State private var loaded = false
    @State private var failed = false

    private static let decoding = FlekImageMemory.screenshotDecoding(height: FlekAppDetailSheet.maxScreenshotHeight)

    var body: some View {
        ZStack {
            // A shot that never arrives keeps its block but stops breathing —
            // a pulse outlasting the request would read as still loading.
            FlekImagePlaceholder(cornerRadius: 14, pulses: !failed)
                // Collapses as the image takes over, so a shot narrower than
                // the row's slot isn't left padded out to it afterwards.
                .frame(width: loaded ? 0 : slotWidth, height: height)
                .opacity(loaded ? 0 : 1)

            KFImage(URL(string: photo))
                // Kingfisher's own placeholder is left clear — the block above
                // is the one on show. It still stands in the slot, at the full
                // size: `scaledToFit` below reads its ratio off whatever is in
                // here while the shot is loading, and a placeholder with no
                // height of its own gives it a wild one, which blows the item
                // up to thousands of points wide and pushes the rest of the row
                // off the screen.
                .placeholder { Color.clear.frame(width: slotWidth, height: height) }
                // Full size, unless the phone is short of memory: see
                // `FlekImageMemory.screenshotDecoding`.
                .setProcessor(Self.decoding.processor)
                .scaleFactor(Self.decoding.scale)
                // Never written to disk. Screenshots are far larger than icons,
                // and browsing app pages would fill the disk cache with images
                // only worth keeping while the page is open.
                .cacheMemoryOnly()
                // Decoded on Kingfisher's queue rather than by the first frame
                // that draws it, on the main thread: a full-size shot is some
                // 14 MB of pixels.
                .backgroundDecode()
                .cancelOnDisappear(true)
                .onSuccess { _ in reveal() }
                // Scrolling a shot off the row cancels its request; that isn't a
                // failure, and it will start again when it comes back.
                .onFailure { error in failed = !error.isTaskCancelled }
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(loaded ? 1 : 0)
        }
    }

    private func reveal() {
        guard !loaded else { return }
        failed = false
        withAnimation(.easeOut(duration: Self.fadeDuration)) { loaded = true }
    }
}

private extension View {
    /// iOS 16+: a label whose text changes morphs into the new one in place —
    /// the glyphs are interpolated rather than one word being swapped for
    /// another between frames while the capsule around it is still travelling.
    /// Below that the text changes on the same beat as the colour, without it.
    // Erased to AnyView: an opaque return type would bake the iOS 16-only
    // modifier type into this function's static type, which the runtime
    // resolves before the availability check runs — the same hazard the
    // installer's own availability helpers document.
    func interpolatesContentIfAvailable() -> AnyView {
        if #available(iOS 16.0, *) { return AnyView(self.contentTransition(.interpolate)) }
        return AnyView(self)
    }

    /// See `DetailSurface`.
    func detailSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(DetailSurface(shape: shape, interactive: interactive))
    }
}

/// The page's control and tile surface: Liquid Glass in dark mode on the systems
/// that have it, and the grouped-background fill everywhere else.
///
/// A modifier rather than a plain `View` extension so it can read the
/// appearance itself — the surfaces then follow a switch between light and dark
/// without the page having to thread the colour scheme down to each of them.
///
/// `interactive` is for the ones that are buttons, whose glass then responds to
/// a press the way every other system control does.
private struct DetailSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    // Returns AnyView rather than an opaque type, so the iOS 26-only type
    // `glassEffect` produces stays out of this modifier's static type — the
    // runtime resolves that before the availability check runs, and traps on
    // older systems where the type is absent.
    func body(content: Content) -> AnyView {
        if #available(iOS 26, *), colorScheme == .dark {
            return AnyView(content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape))
        }
        return AnyView(content.background(shape.fill(Color(.secondarySystemGroupedBackground))))
    }
}
