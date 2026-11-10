//
//  LCMinimizeToIconAnimator.swift
//  LiveContainerSwiftUI
//
//  The way iOS closes and opens an app: the window shrinks into its icon keeping
//  its proportions, cut down from the screen's rounded shape to the icon's as it
//  goes, and the icon's picture comes up over it on the last part of the way, so
//  that what lands is the icon. The icon's own place stands empty until then, as
//  the window is carrying it, and the grid behind settles forward out of a zoom.
//  Opening is the same move run backwards: the icon grows into the window and
//  gives way to the app as it does.
//
//  Everything here runs off ONE number — `flightDuration`, how long a window
//  takes to cross in either direction. The critically damped spring that carries
//  it is derived from that, per flight, so that each direction's own finish
//  lands exactly on it: a closing window is done when it matches its icon, an
//  opening one when it has all but reached full size. Opening and closing are
//  therefore the same speed by construction, on every screen, rather than by two
//  numbers kept in agreement by hand. Window, shape and grid all move on the
//  flight's spring.
//
//  The icon's picture and the handoff to the real icon are driven by watching
//  where the window actually is, not by a timer that predicts it — which is what
//  keeps the parts in step on a slow device, a dropped frame or a 120Hz display
//  alike.
//
//  Used for every window going home or coming back: guest apps and built-in
//  pages from the multitask home button and the home dock, the installer's own
//  close button, and the full-screen cover the pre-multitask path presents
//  pages in.
//

import UIKit

enum LCMinimizeToIconAnimator {

    // MARK: - The spring

    /// How long a window takes to cross, in either direction and on any screen.
    ///
    /// One number for the whole feature. Opening and closing are the same move
    /// reversed and should take the same time, but "done" means something
    /// different at each end: a closing window is finished when it matches the
    /// icon and disappears, while an opening one is finished when it has all but
    /// reached full size. Timing both to the same spring made the opening feel
    /// the slower of the two, because it goes on visibly growing after the point
    /// at which a closing window would already have gone.
    ///
    /// So the spring is derived from this, rather than the other way round: each
    /// direction gets the spring that puts *its own* finish exactly here.
    ///
    /// Nearer iOS's own than it was at 0.21: a window that changes shape and
    /// becomes its icon on the way needs the time for that to be seen.
    private static let flightDuration: TimeInterval = 0.35

    /// How much of the way counts as there, in either direction. The last
    /// half-percent of a critically damped spring is sub-pixel, and waiting for it
    /// is what made a window feel as though it were settling in rather than
    /// arriving. A closing window hands over to the real icon here.
    private static let arrivalProgress: CGFloat = 0.995

    /// How far through a window's way in it counts as arrived for what waits on
    /// it: the divider between two side by side starts to come in here. At the
    /// end of the spring, half a second, it came in well after the windows had
    /// visibly landed, and at the moment they were all but full size, 0.35s,
    /// ahead of them.
    private static let arrivalShare: Double = 0.8

    /// A critically damped spring, described by its angular frequency.
    ///
    /// Critical damping (ζ = 1) is the point of the choice: stiffness = ω²,
    /// damping = 2ω, and a window going into an icon cannot overshoot it and swing
    /// back, which any springier ratio would do.
    private struct Spring {
        let omega: CGFloat

        var timing: UISpringTimingParameters {
            UISpringTimingParameters(mass: 1,
                                     stiffness: omega * omega,
                                     damping: 2 * omega,
                                     initialVelocity: .zero)
        }

        func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = omega * omega
            animation.damping = 2 * omega
            animation.initialVelocity = 0
            return animation
        }

        /// How long it takes to settle completely, as Core Animation works it out
        /// from the same parameters. Always longer than the flight, because the
        /// tail is sub-pixel — which is exactly why nothing visible is timed to it.
        var settlingDuration: TimeInterval {
            animation(keyPath: "transform").settlingDuration
        }
    }

    /// The spring that covers `progress` of its distance in exactly
    /// `flightDuration` — the one piece of arithmetic that makes the two
    /// directions the same speed while letting each define its own finish.
    private static func spring(reaching progress: CGFloat) -> Spring {
        Spring(omega: CGFloat(omegaT(forProgress: progress) / flightDuration))
    }

    /// ωt at which a critically damped spring has covered `progress` of its
    /// distance: the solution of (1 + ωt)·e^(−ωt) = 1 − progress. It has no
    /// elementary inverse, so it is bisected — two dozen iterations of
    /// arithmetic, once per flight.
    private static func omegaT(forProgress progress: CGFloat) -> Double {
        let target = Double(min(max(progress, 0), 0.999))
        var low = 0.0
        var high = 20.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if 1 - (1 + mid) * exp(-mid) < target { low = mid } else { high = mid }
        }
        return low
    }

    // MARK: - The icon's picture

    /// Where the icon's picture takes over from the window, by how many times
    /// the icon's own size the window is on screen: none of it at the larger
    /// figure, all of it at the smaller. Sized against the icon rather than the
    /// screen, so the picture comes up at the same point on every device.
    ///
    /// Closing, it comes in over the last part of the way, so that what lands is
    /// the icon rather than a window shrunk to its size. Opening, the icon is what
    /// leaves first and gives way to the app soon after, as the window clears it.
    private static let pictureOnClosing = (whole: CGFloat(1.15), none: CGFloat(2.5))
    private static let pictureOnOpening = (whole: CGFloat(1), none: CGFloat(3.5))

    /// The window's opacity, for a flight with no icon's picture to become — the
    /// dock as a whole, or the middle of the screen: it crosses its whole range
    /// over the whole flight, at an even rate. Linear rather than on the flight's
    /// spring, because the spring covers most of its distance early — riding it
    /// would put nearly all of the fade in the first third and leave the rest of
    /// the move at a fixed opacity, which is the opposite of fading throughout.
    private static let fadeCurve: UIView.AnimationCurve = .linear

    // MARK: - Shape

    /// Where the grid starts the flight — zoomed in and dimmed, settling back to
    /// rest on the same spring as the window. Without that counter-move the
    /// icons read as wallpaper behind a shrinking rectangle instead of a home
    /// screen coming forward to meet it. Stronger than the 4% it once was, now
    /// that the window stays solid on its way and covers the grid for longer, so
    /// most of the move happens under it.
    private static let gridZoom: CGFloat = 1.1
    private static let gridStartAlpha: CGFloat = 0.6
    /// An icon's corner radius as a share of its width — the springboard's own
    /// proportion, taken from the frame it lands on so the page rounds off to the
    /// right shape on both the phone and the iPad grid.
    private static let iconCornerRadiusRatio: CGFloat = 0.2237
    /// The square a page shrinks into when there is no icon to aim at — the list
    /// layout, or a page with no home-screen icon of its own. It still recedes
    /// rather than blinking out.
    private static let fallbackTargetSize: CGFloat = 78

    /// How many looks to give a destination to appear before giving up on one.
    /// One a screen refresh, rather than one a turn of the run loop or a sixtieth
    /// of a second: the home dock is rendered by SwiftUI in response to the home
    /// state it belongs to, and several run-loop hops can pass inside a single
    /// frame before it has been laid out at all — and two looks a clock's interval
    /// apart can still both fall inside one frame, reading the same unfinished
    /// layout twice. Costs nothing in the common case, where the icon is already on
    /// screen and the first look finds it.
    private static let targetAttempts = 3
    /// The same for a window put away into the home dock, which is always waited
    /// for: the dock is only laid out once the home state it belongs to has taken
    /// effect, and that is after the flight is asked for, and then read twice to
    /// be sure it has stopped moving. A few frames in practice; the rest is for a
    /// slow one, and for a display refreshing twice as often.
    private static let homeDockAttempts = 12

    /// Names for what a flight lays on a window, so one left by a flight that was
    /// overtaken can be told apart and taken off by the next.
    private static let flightMaskName = "lcFlightShape"
    private static let flightPictureName = "lcFlightIconPicture"

    /// How long the page takes to go when Reduce Motion is on. Exactly the flight
    /// it stands in for, so turning the setting on changes how getting home
    /// *looks*, not how long it takes.
    private static var dissolveDuration: TimeInterval { flightDuration }

    /// Whether to go home without the flight. A full-screen surface scaling to a
    /// fifth of its size, over a grid scaling underneath it, is exactly the
    /// large-field motion the setting exists to suppress — and it is the most
    /// motion this app produces anywhere. Read per flight, so the setting takes
    /// effect on the next minimize rather than the next launch.
    private static var prefersDissolve: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// The flights in the air, keyed by the window each is carrying, so every one
    /// of them lands on its own frame. Going
    /// home with several windows open starts several at once. A window's next
    /// move cancels the watcher of the one it overtakes, which is what stops a
    /// window reopened mid-flight from being handed to its icon after all.
    private static var progressWatchers: [ObjectIdentifier: LCFlightProgressWatcher] = [:]

    /// The icons standing aside for a flight, counted, keyed by kind and item:
    /// a window going into an icon or coming out of it is carrying that icon, so
    /// its own place stands empty until the window lands, as on iOS. Counted
    /// because a window reopened on its way in starts the next flight from the
    /// same icon before the first has let go of it.
    private static var iconsStandingAside: [String: Int] = [:]

    /// Whether the grid is already on the move. Every flight asks it to go, and
    /// without this the second and third would each snap it back to its starting
    /// point while the first was still running.
    /// How many windows are in the air. The host view blacks out everything
    /// behind a visible window so a guest that does not fill the screen is
    /// letterboxed rather than fringed with white — but a window in flight is
    /// visible and small, and that backdrop would cover the springboard the
    /// flight is crossing, arriving in one frame because opacity reaches its
    /// final value as soon as the animation is committed. So it is held back for
    /// the length of the flight. Counted, not flagged: pressing home with several
    /// windows open puts several in the air at once, and the backdrop comes back
    /// only when the last of them has landed.
    private static var flightsInProgress = 0

    private static func beginFlight() {
        flightsInProgress += 1
        if flightsInProgress == 1 { setBackdropSuspended(true) }
    }

    private static func endFlight() {
        flightsInProgress = max(0, flightsInProgress - 1)
        if flightsInProgress == 0 { setBackdropSuspended(false) }
    }

    private static func setBackdropSuspended(_ suspended: Bool) {
        guard #available(iOS 16.0, *) else { return }
        MultitaskDockManager.shared.windowHostingView.backdropSuspended = suspended
    }

    private static var isGridSettling = false
    /// Identifies the move the grid is currently making, so the backstop that
    /// releases it cannot release a later one that has since claimed it.
    private static var gridMove = 0

    /// The operation each window is currently in the middle of, so a completion
    /// belonging to a superseded one cannot undo the newer. Opening and closing
    /// are the same view travelling in opposite directions and either can begin
    /// while the other is still finishing — minimizing a window that is still
    /// growing, or reopening one that is still on its way out.
    private static var operations: [ObjectIdentifier: Int] = [:]
    private static var lastOperation = 0

    private static func beginOperation(on view: UIView) -> Int {
        lastOperation &+= 1
        operations[ObjectIdentifier(view)] = lastOperation
        return lastOperation
    }

    private static func isCurrentOperation(_ token: Int, on view: UIView) -> Bool {
        operations[ObjectIdentifier(view)] == token
    }

    private static func endOperation(_ token: Int, on view: UIView) {
        if operations[ObjectIdentifier(view)] == token {
            operations.removeValue(forKey: ObjectIdentifier(view))
        }
    }

    /// The operations that are windows going into their icons. A window stands
    /// still for the length of one: see `holdsGeometry(of:)`.
    private static var closings: Set<Int> = []

    /// The windows growing out of an icon or a card that have yet to arrive.
    /// Held weakly, so a window closed in the air is not counted as on its way for
    /// ever, nor one that later takes its address.
    private static let arriving = NSHashTable<UIView>.weakObjects()

    /// Whether `view` is growing out of an icon or a card and has yet to land,
    /// its flight finished. What the multitask dock draws around two windows side
    /// by side, the divider between them, waits for that: shown as they set off,
    /// it stood at the fold on its own before they got there.
    static func isArriving(_ view: UIView) -> Bool {
        arriving.contains(view)
    }

    /// The windows whose flight into an icon has set off: moving, not waiting
    /// for the dock to say where their icons are. Held weakly, as `arriving` is.
    private static let departed = NSHashTable<UIView>.weakObjects()

    /// Whether `view` is flying into an icon. The divider between two side by
    /// side goes as they start to move: left up, it was the one thing still at
    /// the fold as the two flew home, and taken away as soon as they were sent,
    /// it went while they still stood waiting for the dock.
    static func isLeaving(_ view: UIView) -> Bool {
        departed.contains(view)
    }

    private static func setDeparted(_ view: UIView, _ isDeparted: Bool) {
        guard departed.contains(view) != isDeparted else { return }
        if isDeparted {
            departed.add(view)
            // Told at once, so what is drawn around the window starts to go in
            // the frame the window starts to move: a frame later, it stood on
            // over windows already shrinking fast.
            if #available(iOS 16.0, *) { MultitaskDockManager.shared.windowDidDepart() }
        } else {
            departed.remove(view)
            travelDidChange()
        }
    }

    private static func setArriving(_ view: UIView, _ isArriving: Bool) {
        guard arriving.contains(view) != isArriving else { return }
        if isArriving {
            arriving.add(view)
        } else {
            arriving.remove(view)
        }
        travelDidChange()
    }

    /// A window set off, or arrived: the multitask dock checks what it draws
    /// around the windows.
    private static func travelDidChange() {
        guard #available(iOS 16.0, *) else { return }
        MultitaskDockManager.shared.windowTravelDidChange()
    }

    /// Whether `view` is on its way into an icon, and so has to be left where it
    /// stands until it lands. The flight is aimed from where the window set off,
    /// and a window moved under it carries its landing with it, off its icon by as
    /// far as it moved. A guest window is re-framed from more places than a flight
    /// can rule out: the host's settings arriving on a tilt of the phone, a
    /// relayout, the bar announcing itself. And while the bar slides away on the
    /// way home its strip measures nothing, so a window re-framed then takes the
    /// bar's height on at the bottom and drops by half of it.
    static func holdsGeometry(of view: UIView) -> Bool {
        operations[ObjectIdentifier(view)].map(closings.contains) ?? false
    }

    // MARK: - Entry points

    /// Flies `view` into the icon for `itemID` in the home dock, then hides it:
    /// the app is still running, and the dock is where running apps are, whatever
    /// page the springboard is on. The view is left hidden, untransformed and fully
    /// opaque, ready to be shown again by whatever brings the page back.
    static func minimize(_ view: UIView, toItemID itemID: String, completion: (() -> Void)? = nil) {
        guard let container = view.superview, !view.isHidden,
              view.bounds.width > 1, view.bounds.height > 1 else {
            view.isHidden = true
            completion?()
            return
        }

        view.layer.removeAllAnimations()
        takeOffFlight(from: view)
        view.transform = .identity
        view.alpha = 1

        let token = beginOperation(on: view)
        closings.insert(token)
        // No longer arriving if it was still on its way in. Leaving once it moves.
        setArriving(view, false)
        let finish = {
            // Free to be re-framed again, whichever way the flight ended: the
            // window has landed and is about to be hidden, or something newer has
            // it.
            closings.remove(token)
            if isCurrentOperation(token, on: view) { setDeparted(view, false) }
            travelDidChange()
            // Something may have brought the window back while it was still on its
            // way out. A newer operation on the same view owns it now, and hiding
            // it here would take away a window the user has just asked for — as
            // would finishing after a restore that bypasses this file altogether,
            // which is what the alpha says: the window only goes out on landing.
            // (`minimizeWindow`'s `if (!finished) return` guarded the same case; a
            // property animator finishes on schedule regardless, so the state has
            // to be the test.)
            guard isCurrentOperation(token, on: view), view.alpha < 0.5 else { return }
            endOperation(token, on: view)

            view.isHidden = true
            view.transform = .identity
            view.alpha = 1
            completion?()
        }

        if prefersDissolve {
            setDeparted(view, true)
            dissolve(view, completion: finish)
        } else {
            flyWhenTargetIsReady(view, in: container, toItemID: itemID, intoHomeDock: true,
                                 attemptsLeft: homeDockAttempts,
                                 isCurrent: { isCurrentOperation(token, on: view) },
                                 completion: finish)
        }
    }

    /// The same flight for a page that is going away rather than being hidden:
    /// the page is replaced by a snapshot, `teardown` runs straight away so the
    /// rest of the UI updates on time, and the snapshot makes the trip in its
    /// place. Into its springboard icon, closed as it is: it has no place in the
    /// dock any more.
    static func minimizeByReplacing(_ view: UIView, toItemID itemID: String, teardown: @escaping () -> Void) {
        guard let window = view.window, view.bounds.width > 1, view.bounds.height > 1,
              let snapshot = view.snapshotView(afterScreenUpdates: false) else {
            teardown()
            return
        }

        snapshot.frame = view.convert(view.bounds, to: window)
        window.addSubview(snapshot)
        teardown()

        // Nothing to aim at under Reduce Motion, so nothing to wait for either:
        // the page can start going the moment it is replaced.
        if prefersDissolve {
            dissolve(snapshot) { snapshot.removeFromSuperview() }
            return
        }

        // The springboard is uncovered by the teardown, and needs a turn of the
        // run loop (sometimes two) to be back on screen before its icons can be
        // measured — hence the wait rather than a flight straight from here.
        DispatchQueue.main.async {
            flyWhenTargetIsReady(snapshot, in: window, toItemID: itemID, intoHomeDock: false,
                                 attemptsLeft: targetAttempts, isCurrent: { true }) {
                snapshot.removeFromSuperview()
            }
        }
    }

    // MARK: - The flight, for those who would rather not have one

    /// Going home under Reduce Motion: the page gives way where it stands and the
    /// springboard is simply behind it. No shrink, no change of shape, no counter-
    /// zoom on the grid, and no icon taking over — there is no arrival. The grid
    /// is also left on whatever page it was on, since nothing needs an icon to
    /// aim at any more.
    private static func dissolve(_ view: UIView, completion: @escaping () -> Void) {
        let fade = UIViewPropertyAnimator(duration: dissolveDuration, curve: .easeInOut) {
            view.alpha = 0
        }
        fade.addCompletion { _ in completion() }
        fade.startAnimation()
    }

    // MARK: - Opening

    /// The flight in reverse: a window grows out of the icon it belongs to, on the
    /// same spring, from the icon's rounded square to the screen's shape. It starts
    /// as the icon's picture, which gives way to the app as the window clears it,
    /// and the icon's own place stands empty meanwhile. The window is left visible,
    /// untransformed and opaque.
    ///
    /// `sourceInWindow` overrides the icon lookup for a caller that knows where the
    /// window is coming from: the home dock's icon, which was what was pressed, or
    /// the switcher, where the card the user just pressed is the thing that should
    /// become the window. `sourceCornerRadius` is that card's own rounding on
    /// screen, which the window starts out with, so its corners carry straight on
    /// from the card's; an icon's is worked out from its size. `fadesIn` is what a
    /// window coming out of an *icon* needs: the app comes up through the icon. A
    /// window coming out of a switcher card wants the opposite — the card is
    /// already showing that app, so fading in over it is fading the app in over a
    /// picture of itself. It grows opaque instead, and the card simply becomes the
    /// window.
    static func expand(
        _ view: UIView,
        fromItemID itemID: String?,
        sourceInWindow: CGRect? = nil,
        sourceCornerRadius: CGFloat? = nil,
        fadesIn: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        guard let container = view.superview,
              view.bounds.width > 1, view.bounds.height > 1 else {
            view.isHidden = false
            view.alpha = 1
            completion?()
            return
        }

        view.layer.removeAllAnimations()
        takeOffFlight(from: view)
        view.transform = .identity
        view.isHidden = false

        let token = beginOperation(on: view)
        // Reopened on its way out: coming back now, until it has landed.
        setDeparted(view, false)
        setArriving(view, true)
        let finish = {
            // A window minimized while it was still opening belongs to that
            // newer operation; putting it back to full size here would undo it.
            guard isCurrentOperation(token, on: view) else { return }
            endOperation(token, on: view)
            setArriving(view, false)

            view.transform = .identity
            view.alpha = 1
            completion?()
        }

        // Counted as arrived a little before the way in is wholly done (see
        // `arrivalShare`); the end itself only makes sure.
        func arrives(after duration: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * arrivalShare) {
                if isCurrentOperation(token, on: view) { setArriving(view, false) }
            }
        }

        if prefersDissolve {
            view.alpha = 0
            let fade = UIViewPropertyAnimator(duration: dissolveDuration, curve: .easeInOut) {
                view.alpha = 1
            }
            fade.addCompletion { _ in finish() }
            fade.startAnimation()
            arrives(after: dissolveDuration)
            return
        }

        let full = view.frame
        let source = openingSource(forItemID: itemID, sourceInWindow: sourceInWindow, in: container)
        let size = view.bounds.size
        // One scale for both axes, as on the way home: the window keeps its
        // proportions, and starts cut down to the icon's shape rather than squeezed
        // into it.
        let scale = uniformScale(fitting: source.frame.size, into: size)
        let collapsed = CGSize(width: source.frame.width / scale, height: source.frame.height / scale)
        // The spring that has the window all but full size at `flightDuration` —
        // the opening's own definition of arriving, landed on the same clock the
        // closing one uses for its handoff, so the two read as one speed.
        let spring = spring(reaching: arrivalProgress)
        let settling = spring.settlingDuration

        // From the icon's rounded square, or the card's own rounding, to the
        // screen's shape. The radius renders through the transform, so the value
        // that *starts* at the source's is the source's divided by the scale the
        // window starts at. A card's is its own: worked out like an icon's, from
        // its width, a phone's card came out nearly twice as round as the card
        // being pressed, and its corners jumped as the window took over.
        let halfSide = min(source.frame.width, source.frame.height) / 2
        let sourceRadius: CGFloat
        if case .card = source, let sourceCornerRadius {
            sourceRadius = min(sourceCornerRadius, halfSide)
        } else {
            sourceRadius = min(source.frame.width * iconCornerRadiusRatio, halfSide)
        }
        let shape = FlightShape(on: view,
                                from: collapsed, radii: .uniform(sourceRadius / scale),
                                to: size, radii: fullSizeRadii(of: view, in: container),
                                spring: spring, settling: settling)
        // The icon's picture, which the app comes up through. With no picture to
        // be had, the window fades in over the icon as it used to.
        let picture = fadesIn && source.isIcon
            ? iconPicture(forItemID: itemID, on: view, size: collapsed) : nil
        if let picture {
            fade(picture, on: spring, settling: settling,
                 from: scale, to: 1, iconScale: scale, between: pictureOnOpening)
        }

        // Collapsed onto the icon to begin with, and released from there.
        view.transform = CGAffineTransform(
            translationX: source.frame.midX - full.midX,
            y: source.frame.midY - full.midY
        ).scaledBy(x: scale, y: scale)
        let fadesWindow = fadesIn && picture == nil
        view.alpha = fadesWindow ? 0 : 1

        standAside(itemID, for: source)
        zoomGridAway(on: spring, settling: settling, under: view, in: container)

        let flight = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        flight.addAnimations { view.transform = .identity }
        flight.addCompletion { _ in
            shape.remove()
            picture?.removeFromSuperlayer()
            stepBack(itemID, for: source)
            endFlight()
            finish()
        }

        // The mirror of the closing fade, for a window with no picture to come up
        // through: fully transparent at icon size, so the icon shows through where
        // the window is going to be, and fully opaque as it arrives at full size.
        let windowFade = fadesWindow
            ? UIViewPropertyAnimator(duration: flightDuration, curve: fadeCurve) { view.alpha = 1 }
            : nil

        beginFlight()
        flight.startAnimation()
        windowFade?.startAnimation()
        arrives(after: settling)
    }

    /// An icon-sized source around a point, for a caller that knows where a window
    /// is coming from but not how big the thing it came from was.
    static func sourceRect(around pointInWindow: CGPoint) -> CGRect {
        CGRect(x: pointInWindow.x - fallbackTargetSize / 2,
               y: pointInWindow.y - fallbackTargetSize / 2,
               width: fallbackTargetSize,
               height: fallbackTargetSize)
    }

    // MARK: - The flight

    /// Waits, briefly, for somewhere to fly to. Both possible destinations arrive
    /// a turn of the run loop late in their own way: the springboard is still
    /// behind a cover that has only just been dismissed, and the home dock is only
    /// laid out as the home state it belongs to takes effect. A few turns is the
    /// difference between landing on an icon and shrinking into the middle of the
    /// screen for want of waiting.
    ///
    /// A window going into the dock also waits for the dock to stop moving. It
    /// comes in with an entrance of its own, however short, and an icon measured
    /// on its first frame is where the dock was rather than where it will be; so
    /// the dock is only taken once the same place is read twice running.
    private static func flyWhenTargetIsReady(
        _ view: UIView,
        in container: UIView,
        toItemID itemID: String,
        intoHomeDock: Bool,
        attemptsLeft: Int,
        lastDockFrame: CGRect? = nil,
        isCurrent: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        // Reopened while it waited for somewhere to go: the window is staying.
        guard isCurrent() else {
            completion()
            return
        }
        let isLastLook = attemptsLeft == 0
        let found = destination(forItemID: itemID, in: container,
                                intoHomeDock: intoHomeDock, isLastLook: isLastLook)
        let settled = !intoHomeDock || isLastLook
            || found.map { !$0.isHomeDock || $0.frame == lastDockFrame } == true
        guard let destination = found, settled else {
            if attemptsLeft > 0 {
                LCNextFrame.run {
                    flyWhenTargetIsReady(view, in: container, toItemID: itemID,
                                         intoHomeDock: intoHomeDock,
                                         attemptsLeft: attemptsLeft - 1,
                                         lastDockFrame: found?.frame,
                                         isCurrent: isCurrent, completion: completion)
                }
            } else {
                fly(view, in: container, to: screenCentreDestination(in: container),
                    itemID: itemID, isCurrent: isCurrent, completion: completion)
            }
            return
        }
        fly(view, in: container, to: destination, itemID: itemID,
            isCurrent: isCurrent, completion: completion)
    }

    private static func fly(
        _ view: UIView,
        in container: UIView,
        to destination: Destination,
        itemID: String,
        isCurrent: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        let start = view.frame
        let target = destination.frame
        let size = view.bounds.size
        // One scale for both axes, so the window keeps its proportions as it
        // shrinks rather than being squeezed into the icon's square: its shape is
        // cut down to the square instead, as iOS does.
        let scale = uniformScale(fitting: target.size, into: size)
        let landed = CGSize(width: target.width / scale, height: target.height / scale)
        let landedTransform = CGAffineTransform(translationX: target.midX - start.midX,
                                                y: target.midY - start.midY)
            .scaledBy(x: scale, y: scale)

        // The spring that has the window all but on its icon at `flightDuration`,
        // on any screen — which is what holds the speed steady from an iPhone SE to
        // an iPad in landscape, where the same window has half again as far to go.
        let spring = spring(reaching: arrivalProgress)
        let settling = spring.settlingDuration

        // Rounded like the screen from the moment it lifts off, as iOS shows an app
        // leaving, and like the icon by the time it lands — on the flight's spring,
        // so the shape keeps step with the shrink. The radius renders through the
        // transform, so the value that lands at the icon's is the icon's divided by
        // the scale. Clamped to half the target's shorter side: the dock as a whole
        // is a wide pill, and an icon's proportion of its width would round the
        // corners past its own height.
        let landedRadius = min(target.width * iconCornerRadiusRatio,
                               min(target.width, target.height) / 2)
        let shape = FlightShape(on: view,
                                from: size, radii: fullSizeRadii(of: view, in: container),
                                to: landed, radii: .uniform(landedRadius / scale),
                                spring: spring, settling: settling)
        // The icon's picture, brought up over the last part of the way so that it is
        // the icon that lands rather than a window shrunk to its size. A flight with
        // no icon to become — the dock as a whole, the middle of the screen — fades
        // the window out instead.
        let picture = destination.isIcon
            ? iconPicture(forItemID: itemID, on: view, size: landed) : nil
        if let picture {
            fade(picture, on: spring, settling: settling,
                 from: 1, to: scale, iconScale: scale, between: pictureOnClosing)
        }

        standAside(itemID, for: destination)
        settleGrid(on: spring, settling: settling)

        // The window has become its icon: the real one takes over, the place it
        // stood empty in filled again. Not the window's part of it for a window
        // something else has since moved or reopened.
        var hasLanded = false
        let land = {
            guard !hasLanded else { return }
            hasLanded = true
            if picture != nil, isCurrent(), view.transform == landedTransform {
                view.alpha = 0
            }
            stepBack(itemID, for: destination)
        }

        let key = ObjectIdentifier(view)
        let flight = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        flight.addAnimations { view.transform = landedTransform }
        var watcher: LCFlightProgressWatcher?
        flight.addCompletion { _ in
            // Here as well, for a flight whose landing the watcher never saw.
            land()
            if let watcher, progressWatchers[key] === watcher {
                progressWatchers[key] = nil
                watcher.cancel()
            }
            shape.remove()
            picture?.removeFromSuperlayer()
            endFlight()
            completion()
        }

        // Its own animator so it can end on the landing instead of trailing the
        // spring's long asymptotic tail: the window is gone the instant it reaches
        // the dock, rather than fading for a further quarter of a second over the
        // top of it. It goes the whole way down over the whole flight.
        let windowFade = picture == nil
            ? UIViewPropertyAnimator(duration: flightDuration, curve: fadeCurve) { view.alpha = 0 }
            : nil

        // The landing goes by where the window actually is. A timer set to fire
        // near the end only predicts it — and predicts it differently on every
        // device — where this watches the flight's own presentation layer and acts
        // on the frame the window reaches the icon. Landing late, with the main
        // thread busy, shows nothing: by then the window is drawn as the icon.
        progressWatchers.removeValue(forKey: key)?.cancel()
        watcher = LCFlightProgressWatcher(view: view, timeout: settling + 0.2) { rendered in
            let travelled = (1 - rendered) / max(1 - scale, 0.01)
            guard travelled >= arrivalProgress else { return true }
            land()
            return false
        }
        progressWatchers[key] = watcher

        // On its way now, the dock having said where to: what is drawn around the
        // window goes with it from here.
        if isCurrent() { setDeparted(view, true) }
        beginFlight()
        flight.startAnimation()
        windowFade?.startAnimation()
    }

    // MARK: - The window's shape and the icon's picture

    /// The one scale, for both axes, at which a window's middle is cut down to
    /// `target`: the larger of the two axes' ratios, so that what is left of the
    /// window still lies wholly within it.
    private static func uniformScale(fitting target: CGSize, into size: CGSize) -> CGFloat {
        max(0.01, max(target.width / max(size.width, 1), target.height / max(size.height, 1)))
    }

    /// The corners a window has in flight at its own full size: the screen's for
    /// one that spans the screen, as iOS shows an app on the move — corner by
    /// corner where the display's differ, as the iPhone Duo's cover display's do —
    /// and its own for a smaller one. Back to its own as it comes to rest, when the
    /// shape is taken off.
    private static func fullSizeRadii(of view: UIView, in container: UIView) -> FlekCornerRadii {
        let resting = view.layer.cornerRadius
        guard #available(iOS 16.0, *), view.bounds.width >= container.bounds.width - 1 else { return .uniform(resting) }
        let limit = min(view.bounds.width, view.bounds.height) / 2
        return MultitaskDockManager.shared.deviceScreenCornerRadii.map { min(max(resting, $0), limit) }
    }

    /// The shape a window is cut to in flight: a mask over the whole of it, a
    /// rounded rectangle kept centred that changes size and radius on the flight's
    /// spring. The window changes shape without being squeezed, and without its
    /// own bounds — a guest's, which it would lay out again for — being touched.
    ///
    /// One layer where the corners go from and to the same radius all round, as
    /// most screens' do; where they don't, a layer for each group of corners
    /// rounded alike, each the mask of the one before (see `FlekCornerRadii.cut`),
    /// all changing together on the same spring.
    private final class FlightShape {
        private let mask: CALayer
        private weak var view: UIView?

        init(on view: UIView, from: CGSize, radii fromRadii: FlekCornerRadii,
             to: CGSize, radii toRadii: FlekCornerRadii, spring: Spring, settling: TimeInterval) {
            self.view = view
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let parts = FlekCornerRadii.cut(size: to, from: fromRadii, to: toRadii)
            mask = parts[0].layer
            mask.name = LCMinimizeToIconAnimator.flightMaskName
            mask.position = CGPoint(x: view.layer.bounds.midX, y: view.layer.bounds.midY)
            CATransaction.commit()

            for (index, part) in parts.enumerated() {
                let resize = spring.animation(keyPath: "bounds.size")
                resize.fromValue = NSValue(cgSize: from)
                resize.toValue = NSValue(cgSize: to)
                resize.duration = settling
                part.layer.add(resize, forKey: "resize")
                let round = spring.animation(keyPath: "cornerRadius")
                round.fromValue = part.from
                round.toValue = part.to
                round.duration = settling
                part.layer.add(round, forKey: "round")
                // Each after the first fills the one before, whose middle moves
                // as it changes size.
                if index > 0 {
                    let centre = spring.animation(keyPath: "position")
                    centre.fromValue = NSValue(cgPoint: CGPoint(x: from.width / 2, y: from.height / 2))
                    centre.toValue = NSValue(cgPoint: CGPoint(x: to.width / 2, y: to.height / 2))
                    centre.duration = settling
                    part.layer.add(centre, forKey: "centre")
                }
            }
            view.layer.mask = mask
        }

        /// Off again, unless a later flight has put its own shape on in the meantime.
        func remove() {
            guard let view, view.layer.mask === mask else { return }
            view.layer.mask = nil
        }
    }

    /// Takes off whatever an overtaken flight left on a window — its shape and the
    /// icon's picture — and stops it watching.
    private static func takeOffFlight(from view: UIView) {
        progressWatchers.removeValue(forKey: ObjectIdentifier(view))?.cancel()
        if view.layer.mask?.name == flightMaskName { view.layer.mask = nil }
        view.layer.sublayers?
            .filter { $0.name == flightPictureName }
            .forEach { $0.removeFromSuperlayer() }
    }

    /// The icon's picture laid over a window for its flight, centred and the size
    /// it has on screen as the icon, and transparent until its fade brings it up.
    private static func iconPicture(forItemID itemID: String?, on view: UIView, size: CGSize) -> CALayer? {
        guard let itemID, let image = iconImage(forItemID: itemID),
              let cgImage = image.cgImage else { return nil }
        let picture = CALayer()
        picture.name = flightPictureName
        picture.contents = cgImage
        picture.contentsScale = image.scale
        picture.contentsGravity = .resizeAspectFill
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.bounds = CGRect(origin: .zero, size: size)
        picture.position = CGPoint(x: view.layer.bounds.midX, y: view.layer.bounds.midY)
        picture.opacity = 0
        view.layer.addSublayer(picture)
        CATransaction.commit()
        return picture
    }

    /// The item's icon as the home screen draws it: the springboard's own picture
    /// when its page is in view, or the one the home dock shows.
    private static func iconImage(forItemID itemID: String) -> UIImage? {
        if let image = LCSpringboardViewController.current?.iconCell(forItemID: itemID)?.iconImageView.image {
            return image
        }
        guard #available(iOS 16.0, *),
              let app = MultitaskDockManager.shared.apps.first(where: { $0.springboardItemID == itemID })
        else { return nil }
        return SwitcherBarContentView.cachedIcon(for: app)
    }

    /// How much of the icon's picture shows with the window `ratio` times the
    /// icon's size on screen.
    private static func pictureOpacity(atSizeRatio ratio: CGFloat,
                                       between range: (whole: CGFloat, none: CGFloat)) -> CGFloat {
        min(max((range.none - ratio) / (range.none - range.whole), 0), 1)
    }

    /// Brings the icon's picture up or takes it away over the flight, as the
    /// window's size on screen passes through `range`. Worked out ahead from the
    /// spring's own curve and handed to Core Animation with the move itself, so the
    /// two keep step on the render server whatever the main thread is doing.
    ///
    /// Faded from the main thread a frame at a time, it fell behind whenever that
    /// thread was busy — and an app's first launch is the busiest moment there is:
    /// the window grew to full size with the icon's picture still standing over
    /// the app, until the thread came back to take it off.
    private static func fade(_ picture: CALayer, on spring: Spring, settling: TimeInterval,
                             from startScale: CGFloat, to endScale: CGFloat, iconScale: CGFloat,
                             between range: (whole: CGFloat, none: CGFloat)) {
        let samples = 90
        let omega = Double(spring.omega)
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        for step in 0...samples {
            let fraction = Double(step) / Double(samples)
            let omegaT = omega * fraction * settling
            // How far a critically damped spring from rest has gone by now —
            // the curve the window's own move follows.
            let travelled = CGFloat(1 - (1 + omegaT) * exp(-omegaT))
            let rendered = startScale + (endScale - startScale) * travelled
            let opacity = pictureOpacity(atSizeRatio: rendered / iconScale, between: range)
            values.append(NSNumber(value: Float(opacity)))
            keyTimes.append(NSNumber(value: fraction))
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = settling
        animation.calculationMode = .linear
        setOpacity(picture, CGFloat(values.last?.floatValue ?? 0))
        picture.add(animation, forKey: "fade")
    }

    private static func setOpacity(_ layer: CALayer, _ opacity: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(opacity)
        CATransaction.commit()
    }

    // MARK: - The icon's own place

    /// The icon a window is flying into or out of stands aside for the flight, as
    /// on iOS: the window is carrying it, and two would show. Only an icon, and
    /// only the one the window is headed for.
    private static func standAside(_ itemID: String?, for place: Destination) {
        guard let (key, itemID) = asideKey(itemID, place) else { return }
        iconsStandingAside[key, default: 0] += 1
        if iconsStandingAside[key] == 1 { showIcon(itemID, at: place, false) }
    }

    /// Its place filled again, once the last flight it stood aside for is done.
    private static func stepBack(_ itemID: String?, for place: Destination) {
        guard let (key, itemID) = asideKey(itemID, place),
              let count = iconsStandingAside[key] else { return }
        if count > 1 {
            iconsStandingAside[key] = count - 1
            return
        }
        iconsStandingAside[key] = nil
        showIcon(itemID, at: place, true)
    }

    private static func asideKey(_ itemID: String?, _ place: Destination) -> (String, String)? {
        guard let itemID else { return nil }
        switch place {
        case .springboardIcon: return ("springboard:" + itemID, itemID)
        case .dockIcon: return ("dock:" + itemID, itemID)
        case .dockPill, .card, .screenCentre: return nil
        }
    }

    private static func showIcon(_ itemID: String, at place: Destination, _ shown: Bool) {
        switch place {
        case .springboardIcon:
            // Looked up now, so it is the cell actually on screen; one recycled
            // in the meantime is put back by its own reuse.
            LCSpringboardViewController.current?.iconCell(forItemID: itemID)?
                .iconImageView.alpha = shown ? 1 : 0
        case .dockIcon:
            // A SwiftUI view, with no UIView of ours to hide: the dock reads this.
            guard #available(iOS 16.0, *) else { return }
            let dock = MultitaskDockManager.shared
            if shown {
                dock.homeDockIconsStandingAside.remove(itemID)
            } else {
                dock.homeDockIconsStandingAside.insert(itemID)
            }
        case .dockPill, .card, .screenCentre:
            break
        }
    }

    // MARK: - The home screen's half of it

    /// Brings the grid forward as the page recedes, on the same spring, so the
    /// two halves of the move land together.
    private static func settleGrid(on spring: Spring, settling: TimeInterval) {
        guard let grid = LCSpringboardViewController.current?.viewIfLoaded,
              grid.window != nil, claimGrid() else { return }

        grid.transform = CGAffineTransform(scaleX: gridZoom, y: gridZoom)
        grid.alpha = gridStartAlpha

        let settle = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        settle.addAnimations {
            grid.transform = .identity
            grid.alpha = 1
        }
        settle.addCompletion { _ in isGridSettling = false }
        settle.startAnimation()
        scheduleGridRelease(settling: settling)
    }

    /// Claims the grid for a move, and returns whether it was free to take.
    private static func claimGrid() -> Bool {
        guard !isGridSettling else { return false }
        isGridSettling = true
        gridMove &+= 1
        return true
    }

    /// A backstop for the grid flag. If the animation that should clear it is
    /// interrupted and never reports, the flag stays on and quietly disables the
    /// counter-move for the rest of the session — the kind of fault nobody
    /// notices except that the animation has felt flat for a week. Tied to the
    /// move that scheduled it, so a stale backstop cannot free a grid that a
    /// later move has since claimed.
    private static func scheduleGridRelease(settling: TimeInterval) {
        let move = gridMove
        DispatchQueue.main.asyncAfter(deadline: .now() + settling + 0.5) {
            if gridMove == move { isGridSettling = false }
        }
    }

    /// The grid's half of an opening: it draws back and dims as the window grows
    /// out of it, the same move `settleGrid` plays coming home, run the other way.
    ///
    /// Only when the window will cover the grid, because the grid has to be put
    /// back at the end — it is left zoomed otherwise, and a later minimize would
    /// start from the wrong place. Under a window that covers the screen that
    /// reset is unseen; under a smaller one it would be a visible snap, so a
    /// window that does not cover the grid leaves it alone.
    private static func zoomGridAway(on spring: Spring, settling: TimeInterval, under view: UIView, in container: UIView) {
        guard view.frame.union(container.bounds) == view.frame,
              let grid = LCSpringboardViewController.current?.viewIfLoaded,
              grid.window != nil, claimGrid() else { return }

        grid.transform = .identity
        grid.alpha = 1

        let zoom = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        zoom.addAnimations {
            grid.transform = CGAffineTransform(scaleX: gridZoom, y: gridZoom)
            grid.alpha = gridStartAlpha
        }
        zoom.addCompletion { _ in
            // Behind the open window now, so putting it back is unseen — and it
            // has to be back before the window is ever minimized again.
            grid.transform = .identity
            grid.alpha = 1
            isGridSettling = false
        }
        zoom.startAnimation()
        scheduleGridRelease(settling: settling)
    }

    // MARK: - Where the page is headed

    /// Where a window is going, or where it is coming out of.
    private enum Destination {
        /// The item's own icon on the springboard, in front of the user now.
        case springboardIcon(CGRect)
        /// Its icon in the home dock — where a window that is put away goes, its
        /// app still running, and where a closing page goes when its springboard
        /// icon is on a page the user is not looking at. Flying to an icon they
        /// cannot see means flying off the side of the display, and scrolling the
        /// home screen to it means moving them somewhere they never asked to go.
        case dockIcon(CGRect)
        /// The dock itself, for a window that belongs there but has no icon in it:
        /// the dock shows the four most recent apps, and a fifth still went to the
        /// same place.
        case dockPill(CGRect)
        /// Somewhere a window opens out of that is no icon: the switcher card the
        /// user pressed, or a finger's landing place.
        case card(CGRect)
        /// Nothing on screen to aim at: the middle, so it recedes rather than
        /// blinking out.
        case screenCentre(CGRect)

        var frame: CGRect {
            switch self {
            case .springboardIcon(let frame), .dockIcon(let frame),
                 .dockPill(let frame), .card(let frame), .screenCentre(let frame):
                return frame
            }
        }

        /// Whether this is the home dock, an icon in it or the whole of it.
        var isHomeDock: Bool {
            switch self {
            case .dockIcon, .dockPill: return true
            case .springboardIcon, .card, .screenCentre: return false
            }
        }

        /// Whether this is an icon: something a window can become on the way in
        /// and start out as on the way out, carrying its picture.
        var isIcon: Bool {
            switch self {
            case .springboardIcon, .dockIcon: return true
            case .dockPill, .card, .screenCentre: return false
            }
        }
    }

    /// What an opening grows out of. A caller's own rect comes first: the home
    /// dock's icon passes its own frame, and that is the icon that was pressed, so
    /// it is treated as one; the switcher passes its card, which is not. Otherwise
    /// the item's icon, the springboard's first, as before.
    private static func openingSource(forItemID itemID: String?, sourceInWindow: CGRect?,
                                      in container: UIView) -> Destination {
        if let sourceInWindow, let frame = onScreenFrame(sourceInWindow, in: container) {
            if #available(iOS 16.0, *), let itemID,
               MultitaskDockManager.shared.isHomeDockIcon(sourceInWindow, forItemID: itemID) {
                return .dockIcon(frame)
            }
            return .card(frame)
        }
        if let itemID, let found = destination(forItemID: itemID, in: container) {
            return found
        }
        return screenCentreDestination(in: container)
    }

    /// The best destination available right now, or nil if none can be found yet
    /// — which is a reason to wait a moment, since the home dock only appears as
    /// the window leaves.
    ///
    /// `intoHomeDock` is a window being put away rather than closed. Its app is
    /// still running, so the dock is where it goes even with its springboard icon
    /// in view, and a dock not laid out yet is waited for rather than passed over:
    /// the springboard is only the last look's answer, for a dock that never came.
    /// The opening goes the other way round, out of a springboard icon first, for
    /// the callers that leave the icon to be found — the dock's own icon passes
    /// itself.
    private static func destination(forItemID itemID: String, in container: UIView,
                                    intoHomeDock: Bool = false,
                                    isLastLook: Bool = true) -> Destination? {
        if intoHomeDock {
            if let dock = homeDockDestination(forItemID: itemID, in: container) { return dock }
            guard isLastLook else { return nil }
        }
        if let icon = springboardDestination(forItemID: itemID, in: container) { return icon }
        return homeDockDestination(forItemID: itemID, in: container)
    }

    /// The item's icon on the springboard page in front of the user, if it is there.
    private static func springboardDestination(forItemID itemID: String,
                                               in container: UIView) -> Destination? {
        // Same window, not merely some window: on iPad a second scene has a
        // springboard of its own, and `current` is whichever loaded last.
        guard let window = container.window,
              let cell = LCSpringboardViewController.current?.iconCell(forItemID: itemID),
              cell.window === window else { return nil }
        let icon = cell.iconImageView
        let frame = icon.convert(icon.bounds, to: container)
        // Fully on screen, not just overlapping it. A grid still laid out for
        // the orientation the interface has just left reports icons half off
        // the edge, and those are not somewhere to send a window.
        guard frame.width > 1, frame.height > 1, container.bounds.contains(frame) else { return nil }
        return .springboardIcon(frame)
    }

    /// The item's icon in the home dock, or the dock itself for an app that has no
    /// icon there, once the dock has been laid out.
    private static func homeDockDestination(forItemID itemID: String,
                                            in container: UIView) -> Destination? {
        guard container.window != nil, #available(iOS 16.0, *) else { return nil }
        let dock = MultitaskDockManager.shared
        // Reported in window coordinates by whatever drew itself there.
        if let frame = onScreenFrame(dock.homeDockIconFrames[itemID], in: container) {
            return .dockIcon(frame)
        }
        // The dock as a whole only for an app it holds no icon for. One of the
        // apps it does show, whose icon has not reported in yet, is waited for:
        // the dock can be laid out a beat before its icons say where they are.
        let hasIcon = dock.apps.suffix(MultitaskDockManager.homeDockIconCount)
            .contains { $0.springboardItemID == itemID }
        if !hasIcon, let frame = onScreenFrame(dock.homeDockPillFrame, in: container) {
            return .dockPill(frame)
        }
        return nil
    }

    /// A frame reported in window coordinates, converted for `container` and
    /// confirmed to be somewhere the user can actually see.
    ///
    /// Required to be wholly on screen rather than merely overlapping it. These
    /// come from SwiftUI, whose global space is documented as the screen, and on
    /// an iPad in Split View or Stage Manager the window is not the screen — a
    /// frame measured in one and used in the other is offset by the window's own
    /// origin. Insisting it lands entirely within the container turns that into a
    /// fall through to the next destination rather than a window flying somewhere
    /// senseless.
    private static func onScreenFrame(_ inWindow: CGRect?, in container: UIView) -> CGRect? {
        guard let inWindow, inWindow.width > 1, inWindow.height > 1 else { return nil }
        let frame = container.convert(inWindow, from: nil)
        return container.bounds.contains(frame) ? frame : nil
    }

    private static func screenCentreDestination(in container: UIView) -> Destination {
        .screenCentre(CGRect(x: container.bounds.midX - fallbackTargetSize / 2,
                             y: container.bounds.midY - fallbackTargetSize / 2,
                             width: fallbackTargetSize,
                             height: fallbackTargetSize))
    }

}

// MARK: - For the window controller

/// What the guest window's controller has to ask of a flight. It is written in
/// Objective-C, and the animator, an enum, is out of its reach.
@objc(LCWindowFlight) final class LCWindowFlight: NSObject {
    /// See `LCMinimizeToIconAnimator.holdsGeometry(of:)`.
    @objc(holdsGeometryOfView:) static func holdsGeometry(of view: UIView) -> Bool {
        LCMinimizeToIconAnimator.holdsGeometry(of: view)
    }
}

// MARK: - Next frame

/// Runs something once, on the next screen refresh: after the frame being drawn
/// now, rather than a fixed interval later that may still fall inside it.
private final class LCNextFrame: NSObject {
    private var link: CADisplayLink?
    private var body: (() -> Void)?

    static func run(_ body: @escaping () -> Void) {
        let next = LCNextFrame()
        next.body = body
        // The link keeps hold of its target until it is invalidated, on firing.
        let link = CADisplayLink(target: next, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        next.link = link
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        let body = self.body
        self.body = nil
        body?()
    }
}

// MARK: - Progress watcher

/// Watches a flight in progress and reports, every frame, the scale the window is
/// actually rendered at — what the landing on the icon is driven by.
///
/// The point is that it measures rather than predicts. Reading the presentation
/// layer each frame means the landing comes on the frame the window gets there,
/// whatever the spring or the refresh rate — and if the window never arrives,
/// because it was brought back or interrupted, it never comes. It runs on the
/// main thread, so anything that must keep step with the move frame for frame
/// goes to Core Animation instead, as the icon's picture does.
private final class LCFlightProgressWatcher {

    private var link: CADisplayLink?
    private weak var view: UIView?
    private let deadline: CFTimeInterval
    /// Called each frame with the window's rendered scale; returns whether to go on
    /// watching.
    private var onFrame: ((CGFloat) -> Bool)?

    init(view: UIView, timeout: TimeInterval, onFrame: @escaping (CGFloat) -> Bool) {
        self.view = view
        self.deadline = CACurrentMediaTime() + timeout
        self.onFrame = onFrame

        let link = CADisplayLink(target: self, selector: #selector(step))
        // Common modes: a flight started from a scrolling grid must still be
        // watched while that scroll is tracking.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops watching, and lets go of whatever the flight handed it.
    func cancel() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func step() {
        // Given up on, or gone: the flight's own end sees to the rest.
        guard let onFrame, let view, CACurrentMediaTime() < deadline else {
            cancel()
            return
        }
        // Not drawn yet, on the very first frame of a window just shown.
        guard let presentation = view.layer.presentation() else { return }
        if !onFrame(presentation.affineTransform().a) { cancel() }
    }
}
