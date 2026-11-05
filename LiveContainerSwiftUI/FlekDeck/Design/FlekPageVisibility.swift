//
//  FlekPageVisibility.swift
//  LiveContainerSwiftUI
//
//  Lets a FlekDeck page's views know whether the page is on screen, so that
//  animations which never end on their own stop while it is not.
//

import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Whether the page this view is on is on screen. False while the multitask
    /// dock has the page minimized: there it is only hidden, and SwiftUI goes on
    /// animating what nobody can see, every frame, for as long as FlekDeck is in
    /// front. True everywhere else.
    var flekPageIsShown: Bool {
        get { self[FlekPageIsShownKey.self] }
        set { self[FlekPageIsShownKey.self] = newValue }
    }
}

private struct FlekPageIsShownKey: EnvironmentKey {
    static let defaultValue = true
}

/// Follows whether a page the dock keeps is on screen, from its view's layer:
/// every way the dock has of putting a page away or bringing it back hides the
/// view or fades it out, and the layer reports both.
final class FlekPageVisibility: ObservableObject {
    @Published private(set) var isShown = true
    private var observations: [NSKeyValueObservation] = []

    func track(_ view: UIView) {
        observations = [
            view.layer.observe(\.isHidden) { [weak self] layer, _ in self?.layerChanged(layer) },
            view.layer.observe(\.opacity) { [weak self] layer, _ in self?.layerChanged(layer) },
        ]
        read(view.layer)
    }

    /// Read a turn later: the dock can hide a page from inside a SwiftUI update,
    /// where publishing a change is not allowed.
    private func layerChanged(_ layer: CALayer) {
        DispatchQueue.main.async { [weak self] in self?.read(layer) }
    }

    private func read(_ layer: CALayer) {
        let shown = !layer.isHidden && layer.opacity > 0.01
        if shown != isShown {
            isShown = shown
        }
    }
}

/// A page's content, told by `visibility` whether it is on screen.
struct FlekPageVisibilityRoot<Content: View>: View {
    @ObservedObject var visibility: FlekPageVisibility
    let content: Content

    var body: some View {
        content.environment(\.flekPageIsShown, visibility.isShown)
    }
}

extension View {
    /// Runs `animation`, a repeating one, by turning `phase` on, for as long as
    /// `active` holds and the page this view is on is shown, and turns it off
    /// otherwise.
    func flekRepeating(_ animation: Animation?, phase: Binding<Bool>, while active: Bool = true) -> some View {
        modifier(FlekRepeatingAnimation(animation: animation, phase: phase, active: active))
    }
}

private struct FlekRepeatingAnimation: ViewModifier {
    let animation: Animation?
    @Binding var phase: Bool
    let active: Bool

    @Environment(\.flekPageIsShown) private var pageIsShown

    private var runs: Bool { active && pageIsShown && animation != nil }

    func body(content: Content) -> some View {
        content
            // A new view each time it starts or stops. A repeating animation ends
            // only with the view it runs on: turning `phase` back, even without
            // animation, left it running, on a hidden page as on a shown one.
            .id(runs)
            .onAppear { apply(runs) }
            .onChange(of: runs) { apply($0) }
    }

    private func apply(_ runs: Bool) {
        if runs, let animation {
            withAnimation(animation) { phase = true }
        } else if phase {
            // So the new view rests where an idle one does.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { phase = false }
        }
    }
}
