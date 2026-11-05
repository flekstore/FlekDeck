//
//  FlekScreenshotViewer.swift
//  LiveContainerSwiftUI
//
//  Full-screen screenshot browser opened by tapping a shot on an app's page,
//  or a picture in the StikDebug guide. Pages between them, zooms into one, and
//  drags away downwards like the system photo viewer.
//

import SwiftUI
import UIKit
import Kingfisher

struct FlekScreenshotViewer: View {
    /// A shot, from the web or from the app's own asset catalog.
    enum Photo {
        case remote(String)
        case asset(String)
    }

    let photos: [Photo]
    /// Which shot is on screen. Owned by the page that opened the viewer, so the
    /// zoom transition knows which thumbnail to shrink back into after paging.
    @Binding var index: Int
    /// Shape of the gallery this opened from, so a shot still loading is held by
    /// a block of roughly the right size rather than a spinner in empty space.
    var aspect: CGFloat = FlekAppDetailModel.fallbackAspect

    /// Shots at these web addresses.
    init(photos: [String], index: Binding<Int>, aspect: CGFloat = FlekAppDetailModel.fallbackAspect) {
        self.init(photos: photos.map(Photo.remote), index: index, aspect: aspect)
    }

    init(photos: [Photo], index: Binding<Int>, aspect: CGFloat = FlekAppDetailModel.fallbackAspect) {
        self.photos = photos
        self._index = index
        self.aspect = aspect
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Room the multitask bar's chin takes along the bottom of the screen.
    ///
    /// The viewer is a full-screen cover — its own controller, which doesn't
    /// inherit the `additionalSafeAreaInsets` the host reserves for the bar — so
    /// the page dots have to be lifted clear of it here, or the bar cuts them in
    /// half.
    @State private var barInset: CGFloat = 0

    /// Beyond this a row of dots stops being readable — and on the narrowest
    /// screen still on iOS 15 it stops fitting — so the count is spelled out.
    private static let maxDots = 10

    /// Page position, drawn here rather than by the pager so it can clear the
    /// multitask bar. Faint track behind it, since a screenshot now runs the
    /// full height of the screen underneath.
    @ViewBuilder
    private var pageDots: some View {
        if photos.count > 1 {
            Group {
                if photos.count <= Self.maxDots {
                    HStack(spacing: 7) {
                        ForEach(photos.indices, id: \.self) { position in
                            Circle()
                                .fill(Color.white.opacity(position == index ? 0.95 : 0.35))
                                .frame(width: 7, height: 7)
                        }
                    }
                } else {
                    // Digits rather than words, so it needs no translating and
                    // takes the same room in every language.
                    Text("\(index + 1)/\(photos.count)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.95))
                }
            }
            .animation(.easeOut(duration: 0.2), value: index)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .padding(.bottom, barInset + 10)
            .allowsHitTesting(false)
        }
    }

    /// Reads how much of the bottom edge the switcher bar is covering.
    ///
    /// Resolving this walks the scenes, so it runs on appear and on the bar's own
    /// change notifications — never from the body.
    private func updateBarInset() {
        // The bar itself is iOS 16 and up, so below that there is nothing there
        // to clear.
        guard #available(iOS 16.0, *) else {
            barInset = 0
            return
        }
        let manager = MultitaskDockManager.shared
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
        // Same rule as the dock's: when the height is short — an iPhone or the
        // iPhone Duo's cover display in landscape — the bar moves to a side edge,
        // where it takes nothing from the bottom. On iPad, and on the unfolded
        // Duo, it stays put — unless it stands in the side column beside the Duo's
        // status bar, which takes nothing from the bottom either.
        let onSideEdge = ((scene?.interfaceOrientation.isLandscape ?? false)
            && scene?.traitCollection.userInterfaceIdiom != .pad
            && scene?.traitCollection.verticalSizeClass == .compact)
            || MultitaskDockManager.barStandsInSideColumn(for: scene?.traitCollection)
        guard manager.isVisible, manager.isSwitcherBarVisible, !onSideEdge else {
            barInset = 0
            return
        }
        // The bar's solid region is measured from the screen edge, and the dots
        // already sit above the home indicator — so only the rest needs reserving.
        barInset = max(manager.barFlatRegion - LCDeviceSafeArea.bottomInset(), 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    FlekZoomableScreenshot(
                        photo: photo,
                        aspect: aspect,
                        isActive: position == index,
                        onDismiss: { dismiss() }
                    )
                    .tag(position)
                }
            }
            // Dots of our own, in the overlay below: the built-in ones sit at
            // the very bottom of the pager, where the multitask bar cuts them
            // in half.
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Edge to edge, the close button sitting over the shot rather than
            // the shot being held clear of it — except along the bottom when the
            // multitask bar is up, where the shot stops above the chin instead
            // of running its last stretch underneath.
            //
            // The bottom edge is dropped from the set rather than left to the
            // padding below to hold it off: a view that ignores an edge expands
            // back into that inset, and how much of the padding that eats back
            // is not something to leave to chance.
            .ignoresSafeArea(edges: barInset > 0 ? [.top, .horizontal] : .all)
            .padding(.bottom, barInset)
        }
        .overlay(alignment: .bottom) { pageDots }
        .overlay(alignment: .topTrailing) { closeButton }
        .onAppear(perform: updateBarInset)
        .onReceive(NotificationCenter.default.publisher(for: .multitaskBarVisibilityChanged)) { _ in
            // In step with the bar's own slide, so the dots ride it up and down
            // instead of jumping.
            withAnimation(.easeInOut(duration: 0.2)) { updateBarInset() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Face-up and face-down say nothing about how the viewer is being
            // held, and re-deriving the bar's edge from one only asks its
            // fallbacks the question again.
            guard UIDevice.current.orientation.isValidInterfaceOrientation else { return }
            updateBarInset()
        }
        // Folding or unfolding an iPhone Duo moves the bar without turning the
        // device.
        .onChange(of: verticalSizeClass) { _ in updateBarInset() }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                // The backdrop is black whatever the color scheme, so the glyph
                // is white in both — on glass as well, which tracks what is
                // behind it rather than the system appearance.
                .foregroundStyle(.white)
                // A navigation control's size, matching the circle buttons the
                // rest of the app puts in that role.
                .frame(width: FlekTheme.navControlSize, height: FlekTheme.navControlSize)
                .closeButtonGlass()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .accessibilityLabel("lc.common.close".loc)
    }
}

private extension View {
    /// The close button's surface: real Liquid Glass where the system has it,
    /// and the frosted circle it had before everywhere else, the frosted glass
    /// style included. Interactive, so a press deforms the glass the way every
    /// other system control does. The style is read rather than watched: it can't
    /// be changed while the viewer is up.
    // Erased to AnyView so the iOS 26-only type `glassEffect` produces isn't
    // baked into this function's static type — the runtime resolves that type
    // before the availability check runs, and traps on older systems where the
    // type is absent.
    func closeButtonGlass() -> AnyView {
        if #available(iOS 26, *), LCUtils.appGroupUserDefault.string(forKey: FlekDeckKeys.glassStyle) != FlekGlassStyle.frosted.rawValue {
            return AnyView(self.glassEffect(.regular.interactive(), in: .circle))
        }
        return AnyView(
            self
                .background(Circle().fill(Color.white.opacity(0.18)))
                .background(Circle().fill(.ultraThinMaterial))
        )
    }
}

/// One shot in the viewer: the zoom container, with the gallery's placeholder
/// block behind it until the shot has loaded.
private struct FlekZoomableScreenshot: View {
    let photo: FlekScreenshotViewer.Photo
    let aspect: CGFloat
    /// Whether this is the shot on screen. One paged away from drops back to
    /// 1x, so coming back to it starts fitted rather than where it was left.
    let isActive: Bool
    let onDismiss: () -> Void

    @State private var image: UIImage?

    init(photo: FlekScreenshotViewer.Photo, aspect: CGFloat, isActive: Bool, onDismiss: @escaping () -> Void) {
        self.photo = photo
        self.aspect = aspect
        self.isActive = isActive
        self.onDismiss = onDismiss
        // There from the first frame, so the zoom transition grows the picture
        // itself rather than the placeholder.
        if case .asset(let name) = photo {
            _image = State(initialValue: UIImage(named: name))
        }
    }

    var body: some View {
        ZStack {
            if image == nil {
                GeometryReader { geo in
                    let width = min(geo.size.width, geo.size.height * aspect)
                    FlekImagePlaceholder(cornerRadius: 10)
                        .frame(width: width, height: width / aspect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Mounted from the start, empty or not, so a shot still loading can
            // be flicked away like any other.
            FlekZoomableImage(image: image, isActive: isActive, onDismiss: onDismiss)
        }
        .onAppear(perform: load)
    }

    /// Memory only, as in the gallery this opens from — so the shot tapped is
    /// already there, and nothing about it is left on disk afterwards. One in
    /// the asset catalog is simply there.
    private func load() {
        guard image == nil else { return }
        let address: String
        switch photo {
        case .asset(let name):
            image = UIImage(named: name)
            return
        case .remote(let string):
            address = string
        }
        guard let url = URL(string: address) else { return }
        KingfisherManager.shared.retrieveImage(with: url, options: [.cacheMemoryOnly]) { result in
            guard case .success(let value) = result else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = value.image }
        }
    }
}

/// Pinch, double-tap and pan zoom for one shot, and the drag that throws it
/// away.
///
/// Both gestures are UIKit's. The zoom is a `UIScrollView` because the
/// rubber-banding past the limits, the settle after a pinch and the pan momentum
/// all come with it. The dismiss drag is a pan recogniser moving the shot by a
/// layer transform, because that is what makes it smooth: a SwiftUI `offset`
/// driven by gesture state re-runs the body that owns the state on every frame,
/// which here means rebuilding the pager, its pages and the scroll view inside
/// each one — and a transform lays out nothing at all.
private struct FlekZoomableImage: UIViewRepresentable {
    /// Nil until the shot has loaded; the scroll view is mounted either way.
    let image: UIImage?
    let isActive: Bool
    let onDismiss: () -> Void

    /// Where a double tap lands, short of the ceiling a pinch can reach.
    static let doubleTapScale: CGFloat = 2.5

    /// Whether to leave the dismiss drag to the system.
    ///
    /// From iOS 18 the viewer is presented with a zoom transition, which comes
    /// with the system's own interactive dismissal — a drag from anywhere that
    /// rubber-bands the shot back into the thumbnail it grew out of. Two pans
    /// reading the same finger would fight, so ours stands down and only stands
    /// in below that. Flip this to `false` to take it back on every system.
    static var systemOwnsDismissDrag: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
    /// How far down the shot has to travel before letting go dismisses it, or
    /// how fast it has to be moving for a flick to count on its own.
    static let dismissDistance: CGFloat = 120
    static let dismissVelocity: CGFloat = 800

    func makeUIView(context: Context) -> FlekZoomScrollView {
        let scrollView = FlekZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.imageView.image = image

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(FlekZoomableImage.Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(FlekZoomableImage.Coordinator.handleDismissPan(_:))
        )
        dismissPan.delegate = context.coordinator
        dismissPan.isEnabled = !Self.systemOwnsDismissDrag
        scrollView.addGestureRecognizer(dismissPan)

        return scrollView
    }

    func updateUIView(_ scrollView: FlekZoomScrollView, context: Context) {
        context.coordinator.onDismiss = onDismiss

        if scrollView.imageView.image !== image {
            scrollView.imageView.image = image
            scrollView.fitContent()
        }
        if !isActive && scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var onDismiss: (() -> Void)?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? FlekZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? FlekZoomScrollView)?.centerContent()
        }

        /// Double tap zooms to where the finger landed, or back out if the shot
        /// is already zoomed — the same two-state toggle Photos has.
        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? FlekZoomScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let target = min(scrollView.maximumZoomScale, FlekZoomableImage.doubleTapScale)
            let point = recognizer.location(in: scrollView.imageView)
            let size = CGSize(width: scrollView.bounds.width / target,
                              height: scrollView.bounds.height / target)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2,
                                       y: point.y - size.height / 2,
                                       width: size.width,
                                       height: size.height),
                            animated: true)
        }

        /// The shot follows the finger down and shrinks a little as it goes,
        /// then is either let go of or springs back.
        @objc func handleDismissPan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view, let space = view.superview else { return }
            let travelled = pan.translation(in: space).y

            switch pan.state {
            case .changed:
                // Downwards follows the finger; upwards is rubber-banded so the
                // gesture doesn't feel dead in the wrong direction.
                let offset = travelled > 0 ? travelled : travelled / 4
                let shrink = 1 - min(max(offset, 0) / 1600, 0.12)
                view.transform = CGAffineTransform(translationX: 0, y: offset)
                    .scaledBy(x: shrink, y: shrink)
            case .ended, .cancelled, .failed:
                let velocity = pan.velocity(in: space).y
                let thrown = velocity > FlekZoomableImage.dismissVelocity
                if pan.state == .ended,
                   travelled > FlekZoomableImage.dismissDistance || thrown {
                    onDismiss?()
                    return
                }
                UIView.animate(withDuration: 0.35,
                               delay: 0,
                               usingSpringWithDamping: 0.85,
                               initialSpringVelocity: min(abs(velocity) / 500, 4),
                               // Interaction stays live, so a second drag can
                               // pick the shot up while it is still settling.
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    view.transform = .identity
                }
            default:
                break
            }
        }

        /// Only vertical drags, and only while the shot fits the screen: sideways
        /// belongs to the pager, and a zoomed shot pans instead.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  let scrollView = pan.view as? FlekZoomScrollView,
                  let space = scrollView.superview else { return true }
            guard scrollView.zoomScale <= scrollView.minimumZoomScale else { return false }
            let velocity = pan.velocity(in: space)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The pager and the double tap carry on alongside this one.
            true
        }
    }
}

/// Scroll view that keeps the shot fitted to the screen at 1x and centred at
/// every zoom level past it.
private final class FlekZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    /// Bounds the shot was last fitted to, so zooming — which lays out on every
    /// frame — isn't mistaken for a size change and reset.
    private var fittedToBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // The shot is centred by its own frame, in `centerContent`.
        contentInset = .zero
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        // Zoom is the pinch recogniser's job and stays on throughout; only the
        // pan is switched on and off, in `updatePanAvailability`.
        panGestureRecognizer.isEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        lockPagerToItsOwnAxis()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only on a real bounds change: rotation, or the first pass with a size.
        if bounds.size != fittedToBounds {
            fittedToBounds = bounds.size
            fitContent()
        }
        centerContent()
        updatePanAvailability()
    }

    /// Sits the shot at 1x, aspect-fitted to the current bounds.
    func fitContent() {
        guard let image = imageView.image,
              bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        zoomScale = minimumZoomScale
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        contentOffset = .zero
        centerContent()
    }

    /// Centres the shot while it is smaller than the screen on either axis, by
    /// moving it — a scroll view rests at its top-left corner, so a shot even
    /// slightly narrower than the screen otherwise sits flush against the left
    /// with all of the slack showing as a black bar down the right.
    ///
    /// Insets would be the other way to do it, but they only centre what the
    /// scroll view is *scrolled* to: the resting offset stays the corner, which
    /// is exactly the bar this had.
    func centerContent() {
        var centred = imageView.frame
        centred.origin.x = centred.width < bounds.width
            ? ((bounds.width - centred.width) / 2).rounded()
            : 0
        centred.origin.y = centred.height < bounds.height
            ? ((bounds.height - centred.height) / 2).rounded()
            : 0
        if imageView.frame != centred {
            imageView.frame = centred
        }
    }

    /// The pan only earns the touch once there is something to scroll. Left on
    /// at 1x it still tracks the finger alongside the pager and the dismiss
    /// drag, and three recognisers reading one drag is what makes it stutter.
    private func updatePanAvailability() {
        let scrollable = zoomScale > minimumZoomScale
        if panGestureRecognizer.isEnabled != scrollable {
            panGestureRecognizer.isEnabled = scrollable
        }
    }

    /// Locks the pager this page sits in to its own axis, so a drag that starts
    /// downwards can't slide the page sideways at the same time — the diagonal
    /// drift that reads as the shot wobbling under the finger.
    private func lockPagerToItsOwnAxis() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                scrollView.isDirectionalLockEnabled = true
                return
            }
            ancestor = current.superview
        }
    }
}

extension View {
    /// Marks a thumbnail as the place the viewer grows out of, and shrinks back
    /// into. Nothing to do below iOS 18, which has no such thing.
    // Erased to AnyView: the iOS 18-only type this modifier produces would
    // otherwise be baked into the caller's static type, which the runtime
    // resolves before the availability check runs.
    func screenshotZoomSource(id: Int, in namespace: Namespace.ID) -> AnyView {
        if #available(iOS 18.0, *) {
            return AnyView(self.matchedTransitionSource(id: id, in: namespace))
        }
        return AnyView(self)
    }

    /// Presents with the system's zoom transition: the shot grows out of its
    /// thumbnail, and the drag that dismisses it — the system's own, from
    /// anywhere on the shot — rubber-bands it back into the place it came from.
    /// Erased to AnyView, as above.
    func screenshotZoomTransition(id: Int, in namespace: Namespace.ID) -> AnyView {
        if #available(iOS 18.0, *) {
            return AnyView(self.navigationTransition(.zoom(sourceID: id, in: namespace)))
        }
        return AnyView(self)
    }
}

/// Screenshots dim slightly under a finger, so it's clear they open.
struct FlekScreenshotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
