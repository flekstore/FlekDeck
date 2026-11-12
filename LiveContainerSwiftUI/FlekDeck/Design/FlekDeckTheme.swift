//
//  FlekDeckTheme.swift
//  LiveContainerSwiftUI
//
//  Design tokens and reusable glass building blocks for the FlekDeck
//  springboard home screen. Values are taken from the FlekSign Figma design
//  (file paCG8NHeIWaCsxJ8ThkcEw).
//

import SwiftUI

/// SF Symbol names resolved against what the running system actually ships.
///
/// A too-new symbol name is not an error: `Image(systemName:)` just draws nothing
/// and `UIImage(systemName:)` returns nil, so the failure mode is a silently blank
/// icon rather than a crash. Names are plain strings, so picking one by
/// availability is free at the type level — unlike view types, which have to be
/// erased (see `flekGlassCard`).
enum FlekSymbol {
    /// `iphone.app.switcher` is iOS 18+.
    static var appSwitcher: String {
        if #available(iOS 18.0, *) { return "iphone.app.switcher" }
        return "rectangle.stack"
    }

    /// iOS 18 introduced `document.fill` alongside the older `doc.fill`.
    static var document: String {
        if #available(iOS 18.0, *) { return "document.fill" }
        return "doc.fill"
    }

    /// `photo.badge.plus` is iOS 17+.
    static var addPhoto: String {
        if #available(iOS 17.0, *) { return "photo.badge.plus" }
        return "photo.on.rectangle"
    }

    /// `iphone.gen3` is iOS 16.1+.
    static var device: String {
        if #available(iOS 16.1, *) { return "iphone.gen3" }
        return "iphone"
    }

    /// `app.grid` is iOS 26+.
    static var appGrid: String {
        if #available(iOS 26.0, *) { return "app.grid" }
        return "square.grid.2x2"
    }

    /// `arrow.down.circle.badge.xmark` is iOS 26+.
    static var cancelDownload: String {
        if #available(iOS 26.0, *) { return "arrow.down.circle.badge.xmark" }
        return "xmark.circle"
    }

    /// A signing certificate: a page under a seal. `checkmark.seal.text.page.fill`
    /// is iOS 18+; before it, the page alone.
    static var certificate: String {
        if #available(iOS 18.0, *) { return "checkmark.seal.text.page.fill" }
        return "doc.text.fill"
    }

    /// Marks an app kept in the shared folder rather than privately. The same
    /// arrow the app list's banner badge uses, in its circled form so it reads
    /// as a mark beside a name rather than as a stray glyph.
    static let shared = "arrowshape.turn.up.left.circle.fill"

    /// Marks an app set to launch with JIT, on its icon and where JIT is set up.
    static let jit = "bolt.fill"
}

enum FlekTheme {
    /// The display the app is on, which the sizes worked out from "the screen"
    /// are measured against.
    ///
    /// Not `UIScreen.main`. That is not tied to any scene, and the iPhone Duo moves
    /// the app between its cover display and its inner one as it folds and unfolds,
    /// so a size taken from it can be the size of the display that is switched off.
    /// The foreground scene's own screen is the one the app is drawn on;
    /// `UIScreen.main` only stands in before the first scene has connected.
    static var screen: UIScreen {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen ?? UIScreen.main
    }

    // Springboard grid
    static let gridColumns = 3
    static let gridSpacing: CGFloat = 8
    static let screenHPadding: CGFloat = 16
    static let gridTopPadding: CGFloat = 12

    // App card (frosted tile holding icon + label)
    static let cardCorner: CGFloat = 20
    static let cardHeight: CGFloat = 128
    static let cardTopPadding: CGFloat = 16
    static let cardBottomPadding: CGFloat = 8
    static let cardHPadding: CGFloat = 8
    static let cardInnerSpacing: CGFloat = 8

    // Icon (Figma: 74×74 squircle)
    static let iconSize: CGFloat = 74
    static let iconCorner: CGFloat = 17   // continuous squircle approximation (~0.2237 * size)

    // Label
    static let labelSize: CGFloat = 14

    // Bottom bar. The search button and the multitask bar sit side by side, so
    // one size covers both: it is the diameter of either when round, and the
    // height of the multitask bar once it grows into a capsule around the apps
    // it is running.

    /// Sized off the screen rather than fixed, the way the grid's cards are:
    /// 58pt on the 402pt-wide screen the design is drawn for, and the same share
    /// of the width on anything else.
    private static let bottomBarControlRatio: CGFloat = 58.0 / 402.0
    /// Bounds on that share. A tablet is wide enough to work out a search button
    /// the size of an app icon, and the narrowest phones a control too small to
    /// comfortably hit.
    private static let bottomBarControlRange: ClosedRange<CGFloat> = 50...72

    static var bottomBarControlSize: CGFloat {
        let screen = Self.screen.bounds.size
        // The narrow side of the screen, so that turning the device — or running
        // in a window that is wider than it is tall — does not resize the bar.
        let width = min(screen.width, screen.height)
        let scaled = (width * bottomBarControlRatio).rounded()
        return min(max(scaled, bottomBarControlRange.lowerBound),
                   bottomBarControlRange.upperBound)
    }

    /// The glyph inside one of those controls, and a running app's icon in the
    /// multitask bar. Both are fractions of the control rather than sizes of
    /// their own, so the bar keeps its proportions at every size it takes.
    static var bottomBarGlyphSize: CGFloat { bottomBarControlSize * 0.42 }
    static var bottomBarAppIconSize: CGFloat { bottomBarControlSize * 0.72 }

    /// How far the bar sits from the bottom edge of the screen. Measured to the
    /// edge itself rather than to the safe area, so on a device with a home
    /// indicator the bar reaches back down past it.
    static let bottomBarScreenMargin: CGFloat = 28

    // The side bar: the search button and the running apps stood on end in the
    // column the iPhone Duo's vertical status bar runs down, when Personalization
    // puts them there. The system gives no geometry for that column, so these are
    // measured off it in iOS 27.2, folded and unfolded alike: it is centred 48pt in
    // from the edge of the display, its pill is 56pt across, and the Wi-Fi glyph in
    // it is 41pt.

    /// From the edge of the display to the middle of the column.
    static let sideBarCentreInset: CGFloat = 48
    /// Across the column: the search button's diameter, and the running apps' pill —
    /// the width of the status bar's own pill.
    static let sideBarWidth: CGFloat = 56
    /// A running app's icon in the column, the size of the status bar's Wi-Fi glyph.
    static let sideBarAppIconSize: CGFloat = 41
    /// A button in the column over an app, and in the switcher's: the size of iOS's
    /// own buttons in that column, the back button above them among them.
    static let sideBarButtonSize: CGFloat = 48
    /// The glyph in the column's buttons: the same share of them as the bottom
    /// bar's glyph is of its controls.
    static var sideBarGlyphSize: CGFloat { sideBarWidth * 0.42 }
    /// The glyph on a button in the column over an app: the share of it the
    /// search button's glyph is of the search button.
    static var sideBarButtonGlyphSize: CGFloat { sideBarButtonSize * 0.42 }
    /// The app's icon on the app button in that column: 30pt in the 48pt circle,
    /// leaving a ring of the button's glass round it. As large a share as the
    /// running apps' icon is of the pill, it nearly touched the circle's edge.
    static var sideBarButtonIconSize: CGFloat { sideBarButtonSize * 0.625 }

    /// A navigation control: the circle a back or close button occupies, at the
    /// size the system gives the same buttons in a navigation bar. Fixed rather
    /// than a share of the width — a back button is the size it is on every
    /// device, which is what makes one on a page read as the system's own.
    static let navControlSize: CGFloat = 44
}

/// Frosted "liquid glass" surface used by cards, pills and popups.
/// The design specifies a white 60% fill over the wallpaper; we approximate the
/// iOS-26 liquid-glass look with a thin material plus a strong white tint.
struct FlekGlassBackground: View {
    var cornerRadius: CGFloat = FlekTheme.cardCorner
    var tint: Double = 0.45

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            )
    }
}

/// The pre-iOS 26 frosted surface shared by the bottom-bar controls.
///
/// The springboard search button and the multitask dock pill sit side by side in
/// the same bar, so they have to be the same material. They previously carried
/// their own copies — white 0.45 for the search button, `Color.primary` 0.15 for
/// the pill — which read as two different materials on anything below iOS 26,
/// where both get real Liquid Glass and the difference disappears.
///
/// The pill's tint is the one kept: `Color.primary` tracks the color scheme, so
/// the surface stays subtle in both themes instead of always washing toward
/// white. Keeping it in one place stops the two drifting apart again.
struct FlekFrostedSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .primary
    var fill: Double = 0.15
    var stroke: Double = 0.15

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(tint.opacity(fill)))
            .overlay(shape.strokeBorder(tint.opacity(stroke), lineWidth: 0.5))
    }
}

extension View {
    /// Applies the standard frosted card surface.
    /// Uses Liquid Glass on iOS 26+ when the user preference is enabled,
    /// otherwise falls back to the thin-material style.
    // Erased to AnyView: an opaque return type would bake the iOS 26-only type
    // `glassEffect` produces into this function's static type, and the runtime
    // resolves that type before the availability check runs — which traps on
    // iOS 17.x, where the type is absent from the system SwiftUI.
    func flekGlassCard(cornerRadius: CGFloat = FlekTheme.cardCorner, tint: Double = 0.22) -> AnyView {
        let useGlass = LCUtils.appGroupUserDefault.object(forKey: FlekDeckKeys.cardStyleGlass) as? Bool ?? true
        if #available(iOS 26, *), useGlass {
            return AnyView(self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        }
        return AnyView(self.background(FlekGlassBackground(cornerRadius: cornerRadius, tint: tint)))
    }
}

/// Keeps the pages under it to a column of readable width on an iPad and on an
/// iPhone Duo opened out: their displays are a tablet's width, and a page laid
/// out for a phone otherwise stretches its rows and tiles across all of it, an
/// iPad held sideways most of all. The column is centred, as iPadOS centres the
/// content of a page too wide for it. Narrower than the column (FlekDeck beside
/// another app, a folded Duo) and on an iPhone, the pages keep the system's own
/// margins.
///
/// Through the scroll views' content margins rather than a narrower frame, so a
/// page's background, its navigation bar and the scrolling itself still span the
/// whole window, and only what scrolls is held to the column. The modifier is
/// always there, with the system's margins when the page is narrower than the
/// column, so folding and unfolding change a number rather than the view, and a
/// page pushed in Settings stays where it is.
struct FlekReadableColumn: ViewModifier {
    /// The column's width: about the width of a page in a form sheet on iPad.
    static let width: CGFloat = 640

    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        let spare = available - Self.width
        let wide = FlekDeviceModel.isDuo || UIDevice.current.userInterfaceIdiom == .pad
        let margin: CGFloat? = wide && spare > 0 ? spare / 2 : nil
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.horizontal, margin, for: .scrollContent)
                .background(widthReader)
        } else {
            content
        }
    }

    @available(iOS 17.0, *)
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { available = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in available = width }
        }
    }
}

/// Reports the edge the system's vertical bar runs down — nil where it places
/// none — once on appearing and again whenever the edge changes.
///
/// The vertical bar, and the environment value that names its edge, arrived in
/// iOS 27.1; before that there is never one to report.
struct FlekVerticalBarEdgeReader: View {
    @Binding var edge: HorizontalEdge?

    var body: some View {
        if #available(iOS 27.1, *) {
            Observer(edge: $edge)
        }
    }

    @available(iOS 27.1, *)
    private struct Observer: View {
        @Environment(\.toolbarVerticalEdge) private var current
        @Binding var edge: HorizontalEdge?

        var body: some View {
            Color.clear
                .onAppear { edge = current }
                .onChange(of: current) { _, new in edge = new }
        }
    }
}

/// A circular glass button used for the bottom search pill and the
/// "back to home" affordance shown over full-screen internal pages.
struct FlekGlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = FlekTheme.bottomBarControlSize
    var iconScale: CGFloat = 0.42
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                FlekFrostedSurface(shape: Circle())
                Image(systemName: systemImage)
                    .font(.system(size: size * iconScale, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}
