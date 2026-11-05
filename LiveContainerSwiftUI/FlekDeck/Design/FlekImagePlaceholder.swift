//
//  FlekImagePlaceholder.swift
//  LiveContainerSwiftUI
//
//  One grey stand-in for every remote image that hasn't loaded yet — app icons,
//  repo icons, screenshots — so the launcher shows a single loading treatment
//  rather than a different grey (or a spinner, or nothing) per call site.
//
//  Everything here is iOS 13/14-era API, so it needs no availability handling at
//  the project's iOS 15 deployment target.
//

import SwiftUI

/// Shared look and timing, so a placeholder sitting next to a skeleton row
/// reads as the same material.
enum FlekPlaceholderStyle {
    /// Adapts to light and dark — the reason a hardcoded grey is never right here.
    static let fill = Color(.systemGray5)
    static let dimmedOpacity: Double = 0.55
    static let pulseDuration: TimeInterval = 0.9

    /// The breathing animation, or nothing when the user has asked for less motion.
    static func pulse(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)
    }
}

struct FlekImagePlaceholder: View {
    /// Matches the corner the loaded image is clipped to.
    var cornerRadius: CGFloat = 0
    /// Off where something else on the same view is already animating — the
    /// install card's progress ring, for instance.
    var pulses: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(FlekPlaceholderStyle.fill)
            .opacity(dimmed ? FlekPlaceholderStyle.dimmedOpacity : 1)
            // Stops when `pulses` is turned off, and while the page is out of
            // sight, rather than running on for as long as the view exists.
            .flekRepeating(FlekPlaceholderStyle.pulse(reduceMotion: reduceMotion), phase: $dimmed, while: pulses)
            .accessibilityHidden(true)
    }
}
