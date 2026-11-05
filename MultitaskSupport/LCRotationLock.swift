//
//  LCRotationLock.swift
//  LiveContainer
//
//  One place that decides whether a guest's geometry may be re-derived, and a
//  small on-screen panel showing that decision and letting it be forced.
//

import UIKit

/// Whether guest geometry is currently allowed to change.
///
/// The multitask geometry paths all ask this before re-deriving a guest's frame
/// or orientation. It answers yes for two separate reasons that behave
/// identically once made:
///
///  - **Flat.** The phone is face-up, face-down, or not yet reporting. In that
///    state the device is not saying which way the screen is being read, so
///    anything derived from it is a guess. Deriving is suspended and whatever the
///    guest had is reasserted.
///  - **Manual.** Held on deliberately from the panel below.
///
/// Deliberately one predicate rather than two: a manual lock that took a
/// different path through the geometry code would be a second thing to get right,
/// and the point of it is to reproduce the automatic behaviour exactly.
@objc public final class LCRotationLock: NSObject {

    /// True while the phone is lying flat and cannot say how it is being read.
    ///
    /// Reads a continuously refreshed cache rather than `UIDevice.current.orientation`
    /// directly. That property proved unreliable when nothing was reading it often:
    /// the geometry paths sampled a value that still said landscape when the phone
    /// was already flat, so the lock never engaged. Whatever the mechanism inside
    /// UIKit, the fix is not to depend on it — `beginTracking()` keeps the reading
    /// warm whenever anything can depend on it: see `updatePolling()`.
    @objc public static var isFlat: Bool {
        !cachedOrientation.isValidInterfaceOrientation
    }

    // MARK: - Keeping the device reading live

    private static var cachedOrientation: UIDeviceOrientation = .unknown
    private static var tracker: Tracker?

    /// Whether a guest app is open in a window, minimized ones included. Only
    /// the geometry of guests in windows asks the lock, so with none open the
    /// poll has nothing to keep warm. Kept up to date by the dock.
    @objc public static var hasGuestWindows = false {
        didSet {
            guard oldValue != hasGuestWindows else { return }
            updatePolling()
        }
    }

    private static var isInForeground = true

    /// Starts refreshing the device reading and keeps it refreshed. Idempotent.
    @objc public static func beginTracking() {
        guard tracker == nil else { return }
        // On main, whoever called. Both the notification generation and the timer
        // below are main-run-loop concerns, and this is reached from a lazily
        // initialised singleton whose thread is not guaranteed.
        if Thread.isMainThread {
            startTracking()
        } else {
            DispatchQueue.main.async { startTracking() }
        }
    }

    private static func startTracking() {
        guard tracker == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isInForeground = UIApplication.shared.applicationState != .background
        tracker = Tracker()
        sample()
        updatePolling()
    }

    fileprivate static func sample() {
        cachedOrientation = UIDevice.current.orientation
    }

    /// Polls only while something can depend on the reading: a guest in a
    /// window, or the panel showing it, with FlekDeck in the foreground. Each
    /// poll wakes the processor, ten times a second for the lock and ten for the
    /// overlay's readout, and both used to run for as long as FlekDeck did,
    /// background included. Meanwhile the orientation notification keeps the
    /// reading current, and polling starts with a fresh sample.
    fileprivate static func updatePolling() {
        let polling = isInForeground && (hasGuestWindows || LCRotationLockOverlay.isPanelVisible)
        tracker?.setPolling(polling)
        LCRotationLockOverlay.shared.setPolling(polling)
    }

    /// Owns the timer and the notification observers, all of which need a target.
    private final class Tracker: NSObject {
        private var timer: Timer?

        override init() {
            super.init()
            // Both a notification and a poll. The notification carries most
            // changes; the poll is what makes the value dependable when nothing
            // else in the process happens to be reading it, which is the case
            // that failed.
            NotificationCenter.default.addObserver(
                self, selector: #selector(orientationChanged),
                name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(didEnterBackground),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(willEnterForeground),
                name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        func setPolling(_ polling: Bool) {
            guard polling != (timer != nil) else { return }
            guard polling else {
                timer?.invalidate()
                timer = nil
                return
            }
            // Built unscheduled and added to the main run loop explicitly, never
            // with `Timer.scheduledTimer`.
            //
            // `scheduledTimer` attaches to *the current thread's* run loop, and this
            // is reached from `MultitaskDockManager.init` — a `static let shared`,
            // so it is initialised by whichever thread touches it first, and ObjC
            // reaches it from `LCUtils`. On a background thread the run loop never
            // runs and the timer never fires; adding it to the main run loop
            // afterwards cannot rescue it, because a timer lives in exactly one run
            // loop. Nothing then reads `UIDevice.current.orientation` periodically,
            // which is what keeps UIKit reporting it, so the cache stays stale and
            // the lock never engages.
            //
            // Common modes because a default-mode timer stops firing while a scroll
            // view is tracking, and a guest being scrolled is exactly when the
            // reading must not go stale.
            let t = Timer(timeInterval: 0.1, repeats: true) { _ in
                LCRotationLock.sample()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            LCRotationLock.sample()
        }

        @objc private func orientationChanged() { LCRotationLock.sample() }

        @objc private func didEnterBackground() {
            LCRotationLock.isInForeground = false
            LCRotationLock.updatePolling()
        }

        @objc private func willEnterForeground() {
            LCRotationLock.isInForeground = true
            LCRotationLock.updatePolling()
        }
    }

    /// Forced on from the panel. Survives the phone being picked up.
    @objc public static var isManual: Bool = false {
        didSet {
            guard oldValue != isManual else { return }
            // Releasing a lock has to actively provoke a re-derivation. The paths
            // that would normally repair the geometry are driven by a bounds
            // change, and nothing about unlocking changes any bounds — so without
            // this the guest keeps the frozen shape until something else happens
            // to lay out.
            if !isManual { requestRelayout() }
        }
    }

    /// The single question every geometry guard asks.
    @objc public static var isLocked: Bool { isFlat || isManual }

    /// Why it is locked, for the panel.
    @objc public static var reason: String {
        if isManual && isFlat { return "MANUAL + FLAT" }
        if isManual { return "MANUAL" }
        if isFlat { return "FACE UP" }
        return "FREE"
    }

    /// How the phone is being held, in words rather than enum names.
    @objc public static var positionDescription: String {
        switch UIDevice.current.orientation {
        case .portrait:           return "VERTICAL"
        case .portraitUpsideDown: return "VERTICAL (upside down)"
        case .landscapeLeft:      return "HORIZONTAL (left)"
        case .landscapeRight:     return "HORIZONTAL (right)"
        case .faceUp:             return "FACE UP"
        case .faceDown:           return "FACE DOWN"
        default:                  return "UNKNOWN"
        }
    }

    private static func requestRelayout() {
        guard #available(iOS 16.0, *) else { return }
        DispatchQueue.main.async {
            let host = MultitaskDockManager.shared.windowHostingView
            host.setNeedsLayout()
            host.layoutIfNeeded()
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        }
    }
}

// MARK: - On-screen panel

/// A compact always-on-top readout of how the phone is being held, whether
/// rotation is locked, and a button to hold it locked by hand.
@objc public final class LCRotationLockOverlay: NSObject {

    @objc public static let shared = LCRotationLockOverlay()

    private var window: UIWindow?
    private var panelView: UIView?
    private var label: UILabel?
    private var button: UIButton?
    private var timer: Timer?

    /// Whether the panel is drawn. Everything else about the overlay happens
    /// either way: the window is created, attached to the scene, laid out and
    /// composited, and its timer runs whenever the lock polls. Only the panel's
    /// contents are hidden. A panel on screen keeps both polling with no guest
    /// open, so that what it shows is live.
    ///
    /// A workaround, and labelled as one. Ruled out by experiment: the lock's own
    /// value (identical either way, and the overlay never writes it); the panel
    /// polling `UIDevice.current.orientation` (the lock polls it too, on the main
    /// run loop); the window's root view controller (removed, no change); key
    /// window theft (the effect needs no touch); and creating the window once and
    /// destroying it (not enough — it has to still be there).
    ///
    /// What remains untested is which of the window's ongoing effects matters.
    /// Bisecting `start()` would answer it.
    @objc public static var isPanelVisible: Bool = false {
        didSet {
            guard oldValue != isPanelVisible else { return }
            LCRotationLock.updatePolling()
        }
    }

    /// Shows or hides the panel on an overlay that is already running.
    ///
    /// Only the panel's alpha changes — the window stays created, attached and
    /// composited either way, because that is the part that the rotation lock
    /// turns out to depend on.
    @objc public static func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        shared.panelView?.alpha = visible ? 1 : 0
    }

    @objc public func start() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            // No foreground scene yet. Retry rather than fail silently — a panel
            // that is simply absent looks the same as one reporting nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            return
        }

        let win = LockPassthroughWindow(windowScene: scene)
        // Above the multitask overlay window, so a maximized guest cannot bury it.
        win.windowLevel = .alert + 100
        win.backgroundColor = .clear
        win.isHidden = false
        // Always rendered. An alpha-zero window may never be composited at all,
        // and compositing is one of the effects that might be the load-bearing
        // one. The background is clear, so a rendered window with a hidden panel
        // shows nothing.
        win.alpha = 1

        let panel = UIView()
        panel.alpha = Self.isPanelVisible ? 1 : 0
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        panel.layer.cornerRadius = 8
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor

        let text = UILabel()
        text.numberOfLines = 0
        text.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        text.textColor = .white

        let toggle = UIButton(type: .system)
        toggle.titleLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        toggle.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)
        toggle.layer.cornerRadius = 5
        toggle.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        // EXPERIMENT (hypothesis A): no root view controller.
        //
        // `application(_:supportedInterfaceOrientationsFor:)` is asked about every
        // window, and this one's root controller was a bare `UIViewController` —
        // an opinion about orientation with no constraints on it at all, sitting
        // beside the app's own constrained hierarchy. When the device goes flat and
        // UIKit re-resolves, a bare controller resolves face-up to portrait, which
        // is the same "unknown falls back to portrait" pattern behind every bug in
        // this area. Rotating the host that way puts the turn one level above the
        // geometry guards, which is why the lock can be engaged and correct while
        // the guest still turns.
        //
        // A window shows subviews perfectly well without a root controller, so this
        // removes the opinion while leaving the window, its level and its timer
        // exactly as they were — the point being to change one thing.
        win.addSubview(panel)
        panel.addSubview(text)
        panel.addSubview(toggle)

        for v in [panel, text, toggle] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: win.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            panel.topAnchor.constraint(equalTo: win.safeAreaLayoutGuide.topAnchor, constant: 6),

            text.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),

            toggle.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            toggle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 6),
            toggle.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        window = win
        panelView = panel
        label = text
        button = toggle

        if wantsPolling {
            startTimer()
        }
        refresh()
    }

    /// Whether the lock is polling, and the readout's timer with it. Kept from
    /// before `start()`, which only then has a readout to refresh.
    private var wantsPolling = false

    fileprivate func setPolling(_ polling: Bool) {
        wantsPolling = polling
        guard window != nil, polling != (timer != nil) else { return }
        if polling {
            startTimer()
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc public func stop() {
        timer?.invalidate()
        timer = nil
        window?.isHidden = true
        window = nil
        panelView = nil
        label = nil
        button = nil
        // Cleared so a panel built later starts by writing its state rather than
        // comparing against values belonging to views that no longer exist.
        lastText = nil
        lastManual = nil
        lastLocked = nil
    }

    @objc private func toggleLock() {
        LCRotationLock.isManual.toggle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refresh()
    }

    /// Last values written, so an unchanged tick writes nothing.
    private var lastText: String?
    private var lastManual: Bool?
    private var lastLocked: Bool?

    private func refresh() {
        // Read unconditionally, every tick, including while the panel is hidden.
        //
        // These reads are not just for display: `positionDescription` samples
        // `UIDevice.current.orientation`, and something reading that property
        // periodically is one of the live candidates for why this overlay has to
        // exist at all for the rotation lock to engage. Whatever is skipped below
        // to save work, the reads are not.
        let locked = LCRotationLock.isLocked
        let manual = LCRotationLock.isManual
        let text = """
        POSITION  \(LCRotationLock.positionDescription)
        ROTATION  \(locked ? "LOCKED" : "FREE")
        REASON    \(LCRotationLock.reason)
        """

        // Assigning an equal string still invalidates layout — UIKit does not
        // compare for you — so at 10 Hz that is a text measurement and a layout
        // pass ten times a second, forever, whether or not anything is visible.
        // The readout only changes when the orientation or the lock does, which is
        // rare, so guarding collapses the common tick to a string build and a
        // comparison.
        if text != lastText {
            lastText = text
            label?.text = text
        }
        if manual != lastManual {
            lastManual = manual
            button?.setTitle(manual ? "UNLOCK" : "LOCK", for: .normal)
            button?.backgroundColor = manual
                ? UIColor.systemRed.withAlphaComponent(0.85)
                : UIColor.systemBlue.withAlphaComponent(0.85)
            button?.setTitleColor(.white, for: .normal)
        }
        if locked != lastLocked {
            lastLocked = locked
            // Border tracks the effective state, so a lock held by the phone lying
            // flat reads the same at a glance as one held by hand.
            panelView?.layer.borderColor = locked
                ? UIColor.systemRed.withAlphaComponent(0.8).cgColor
                : UIColor.white.withAlphaComponent(0.25).cgColor
        }
    }
}

/// Transparent to touches everywhere except the panel, so the app underneath
/// stays fully usable.
private final class LockPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The window itself takes no touches — only the panel and its button do,
        // so everything outside them reaches the app underneath. Compared against
        // `self` rather than a root controller's view, since there is no longer a
        // root controller.
        return hit === self ? nil : hit
    }

    /// Leaves the system's appearance to the app's own windows. UIKit takes it from
    /// the topmost window that can affect it: the status bar's visibility, and the
    /// screen edges where iOS holds its own gestures back. This one sits above
    /// everything with no view controller to ask, so the status bar was shown
    /// wherever iOS would have hidden it (on the iPhone Duo's cover display, the
    /// time and Wi-Fi over the top corner of an app held in landscape), and no
    /// edge was ever held back: the first swipe up always went home, past the
    /// bottom swipe that opens the switcher. A private UIKit method, overridden
    /// the way UIKit's own overlay windows (the text effects window and others)
    /// opt out; the window is otherwise untouched, since its being there is what
    /// the rotation lock depends on.
    @objc(_canAffectStatusBarAppearance)
    private func canAffectStatusBarAppearance() -> Bool { false }
}
