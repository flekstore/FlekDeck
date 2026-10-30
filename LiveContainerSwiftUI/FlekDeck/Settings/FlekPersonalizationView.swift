//
//  FlekPersonalizationView.swift
//  LiveContainerSwiftUI
//
//  New "Personalization" settings page (not present in LiveContainer). Lets the
//  user pick a home screen wallpaper (built-in collection or a photo) and choose
//  the home screen layout (grid of cards or a list).
//

import SwiftUI
import PhotosUI

struct FlekPersonalizationView: View {
    @AppStorage("LCBetaBannerOverride", store: LCUtils.appGroupUserDefault) private var betaBannerOverride: Int = 0
    // 0 = auto (show on beta), 1 = force on, 2 = force off
    /// Set when a run of title taps turns the beta warning on: keeps its toggle
    /// on offer on a device that isn't on a beta, so switching the warning off
    /// again does not take away the switch that put it there.
    @AppStorage("LCBetaBannerToggleRevealed", store: LCUtils.appGroupUserDefault) private var betaToggleRevealed = false

    @AppStorage(FlekDeckKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekDeckKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""
    @AppStorage(FlekDeckKeys.homeLayout, store: LCUtils.appGroupUserDefault)
    private var homeLayout: String = FlekHomeLayout.grid.rawValue

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    @AppStorage("LCFrameShortcutIcons", store: LCUtils.appGroupUserDefault) private var frameShortIcon = false

    @State private var showCollection = false
    @State private var showPhotoPicker = false
    @State private var headerTapRun = HeaderTapRun()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: Wallpapers
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("lc.flek.wallpapers".loc)

                    HStack(alignment: .top, spacing: 8) {
                        currentPreview
                        VStack(spacing: 8) {
                            actionTile(title: "lc.flek.chooseFromCollection".loc, systemImage: "rectangle.grid.3x2.fill") {
                                showCollection = true
                            }
                            actionTile(title: "lc.flek.chooseFromPhotos".loc, systemImage: FlekSymbol.addPhoto) {
                                showPhotoPicker = true
                            }
                        }
                        .frame(height: 226)
                    }
                    .padding(16)
                    .background(card)
                }

                // MARK: Home Screen Layout
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("lc.flek.homeScreenLayout".loc)

                    HStack(spacing: 8) {
                        layoutOption(.grid, title: "lc.flek.layoutGrid".loc)
                        layoutOption(.list, title: "lc.flek.layoutList".loc)
                    }
                    .padding(16)
                    .background(card)
                }

                // MARK: App Icons
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("lc.flek.appIcons".loc)
                    VStack(spacing: 0) {
                        Toggle("lc.settings.dynamicColors".loc, isOn: $dynamicColors)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        if #available(iOS 18.0, *) {
                            Divider().padding(.leading, 16)
                            Toggle("lc.settings.darkModeIcon".loc, isOn: $darkModeIcon)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        Divider().padding(.leading, 16)
                        Toggle("lc.settings.FrameIcon".loc, isOn: $frameShortIcon)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .background(card)
                }

                // MARK: iOS Beta
                if showsBetaToggle {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("lc.flek.iosBeta".loc)
                        Toggle("lc.flek.showBetaWarning".loc, isOn: betaWarningEnabled)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(card)
                    }
                }

            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("lc.flek.personalization".loc)
                    .font(.headline)
                    .onTapGesture { countHeaderTap() }
            }
        }
        .sheet(isPresented: $showCollection) {
            FlekWallpaperCollectionView(selectedDescriptor: $wallpaperDescriptor, photoWallpaper: $wallpaperPhoto)
        }
        .sheet(isPresented: $showPhotoPicker) {
            FlekPhotoPicker { image in
                if let name = FlekWallpaperStore.savePhoto(image) {
                    wallpaperPhoto = name
                }
            }
        }
    }

    // MARK: iOS Beta Warning

    /// Whether the beta warning's toggle is on offer: on a beta, where the warning
    /// is the default, and anywhere the warning is currently up — a device with it
    /// forced on has to be able to turn it off again. Sticky once a run of title
    /// taps has turned it on, so the switch does not vanish the moment it is used.
    private var showsBetaToggle: Bool {
        BetaOverlayManager.isBetaiOS
            || BetaOverlayManager.isEnabled(override: betaBannerOverride)
            || betaToggleRevealed
    }

    /// The beta warning as one switch, over whichever of auto, on and off is
    /// stored behind it.
    private var betaWarningEnabled: Binding<Bool> {
        Binding(
            get: { BetaOverlayManager.isEnabled(override: betaBannerOverride) },
            set: { betaBannerOverride = BetaOverlayManager.override(enabled: $0) }
        )
    }

    /// Counts a run of quick taps on the title, the hidden controls for the beta
    /// warning. One running count rather than two multi-tap gestures, because a
    /// 10-tap gesture would fire ten times on the way to 100. The 10th tap flips
    /// the warning, which is the only way to turn it on where the toggle is still
    /// hidden; the 100th turns it on outright. Either way, turning it on puts the
    /// toggle on offer for good, even on a device that isn't on a beta. A run that
    /// goes on to 100 passes 10 first, so the warning flips there before it is
    /// turned on.
    private func countHeaderTap() {
        let run = headerTapRun
        let now = Date()
        run.count = now.timeIntervalSince(run.lastTap) <= Self.headerTapGap ? run.count + 1 : 1
        run.lastTap = now

        switch run.count {
        case 10:
            let enabled = BetaOverlayManager.isEnabled(override: betaBannerOverride)
            betaBannerOverride = BetaOverlayManager.override(enabled: !enabled)
            if !enabled { betaToggleRevealed = true }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case 100:
            betaBannerOverride = BetaOverlayManager.override(enabled: true)
            betaToggleRevealed = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        default:
            break
        }
    }

    /// The longest pause between two taps that still continues a run. Looser than
    /// the system's multi-tap timing, which is hard to keep up for 100 taps.
    private static let headerTapGap: TimeInterval = 0.6

    /// The run of taps being counted. A class, so that counting a tap does not
    /// re-render the page — its body decodes the wallpaper preview from disk, and
    /// a run of 100 would do that 100 times.
    private final class HeaderTapRun {
        var count = 0
        var lastTap = Date.distantPast
    }

    // MARK: Pieces

    /// The corner radius of the display the app is on (private UIScreen value),
    /// clamped into the slider's range, used as the default so the bar starts
    /// matching the device.
    private static var deviceCornerRadiusDefault: Double {
        let r = (FlekTheme.screen.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        let v = r > 0 ? Double(r) : 39
        return min(max(v, 10), 60)
    }

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255) // #0075ff
    private static let tileFill = Color(red: 136/255, green: 136/255, blue: 136/255).opacity(0.15)

    private var currentPreview: some View {
        ZStack(alignment: .top) {
            Group {
                if !wallpaperPhoto.isEmpty,
                   let img = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto,
                                                          maxPixel: FlekWallpaperImages.thumbnailMaxPixel) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    FlekWallpaper.from(descriptor: wallpaperDescriptor).thumbnail()
                }
            }
            .frame(width: 110, height: 226)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("lc.flek.current".loc)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 16).frame(height: 21)
                .background(Capsule().fill(Color.black.opacity(0.2)))
                .padding(.top, 8)
        }
    }

    private func actionTile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: systemImage).font(.system(size: 28))
                Text(title).font(.system(size: 14)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Self.flekBlue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.tileFill))
        }
        .buttonStyle(.plain)
    }

    private func layoutOption(_ layout: FlekHomeLayout, title: String) -> some View {
        let selected = homeLayout == layout.rawValue
        return Button {
            homeLayout = layout.rawValue
        } label: {
            VStack(spacing: 16) {
                LayoutGlyph(layout: layout, selected: selected)
                    .frame(width: 59, height: 100)
                if selected {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Capsule().fill(Self.flekBlue))
                } else {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Self.tileFill))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
    }
}

/// Small phone illustration showing a grid or list arrangement using SF Symbols.
private struct LayoutGlyph: View {
    let layout: FlekHomeLayout
    let selected: Bool

    var body: some View {
        let tint = selected ? Color.accentColor : Color.secondary
        ZStack {
            Image(systemName: FlekSymbol.device)
                .font(.system(size: 80, weight: .thin))
                .foregroundStyle(tint)

            Group {
                if layout == .grid {
                    Image(systemName: "square.grid.4x3.fill")
                        .font(.system(size: 24))
                        .rotationEffect(.degrees(90))
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 24, weight: .bold))
                }
            }
            .foregroundStyle(tint)
            .offset(y: -2)
        }
    }
}

/// PHPicker wrapper that returns a single chosen image.
struct FlekPhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: FlekPhotoPicker
        init(_ parent: FlekPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let img = obj as? UIImage else { return }
                DispatchQueue.main.async { self?.parent.onPick(img) }
            }
        }
    }
}
