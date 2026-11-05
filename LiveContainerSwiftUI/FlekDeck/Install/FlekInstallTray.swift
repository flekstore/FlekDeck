//
//  FlekInstallTray.swift
//  LiveContainerSwiftUI
//
//  Progress cards for installs the user started by hand from the installer —
//  "Install IPA File" and "Install from URL".
//
//  Catalog installs report progress on their own row (FlekInstallerRow), but a
//  hand-picked IPA or URL has no row to attach to, so until the app appeared on
//  the home screen nothing in the installer acknowledged the tap. These cards
//  float just above the installer's bottom bar and use the same frosted-capsule
//  surface as it, with the familiar dimmed-icon progress treatment from the home
//  screen so it reads as the same install in two places.
//

import SwiftUI

/// The stack of hand-started installs shown above the installer's bottom bar.
struct FlekInstallTray: View {
    let items: [InstallItem]
    let accent: Color
    /// Cancels an in-flight install, or clears a failed one.
    var onDismiss: (InstallItem) -> Void

    /// Beyond this the tray would start eating the app list, so the rest are
    /// summarised on a single line.
    private static let maxRows = 3

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items.prefix(Self.maxRows)) { item in
                FlekInstallTrayRow(
                    state: item.installState,
                    phase: item.phase,
                    accent: accent,
                    onDismiss: { onDismiss(item) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if items.count > Self.maxRows {
                Text("lc.flek.install.more %lld".localizeWithFormat(items.count - Self.maxRows))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(FlekInstallTraySurface(shape: Capsule()))
            }
        }
    }
}

/// One hand-started install: dimmed icon with its progress, name, phase, and a
/// bar. Cancelling is the same gesture as on a catalog row — the ✕ on the right.
struct FlekInstallTrayRow: View {
    let state: FlekInstallState
    let phase: InstallPhase
    let accent: Color
    var onDismiss: () -> Void

    private var isCompleted: Bool { phase == .completed }

    /// Nothing left to cancel once the install has landed.
    private var showsDismiss: Bool { !isCompleted }

    /// The bar only means something while the install is still moving.
    private var showsProgressBar: Bool { !isCompleted && !state.failed }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(state.name ?? "lc.flek.installing".loc)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)

                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(state.failed ? Color.red.opacity(0.9) : Color.secondary)
                    .lineLimit(2)

                if showsProgressBar {
                    FlekInstallTrayProgressBar(
                        fraction: state.fraction,
                        indeterminate: state.indeterminate,
                        accent: accent
                    )
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 4)

            if showsDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("lc.flek.cancelInstall".loc)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(FlekInstallTraySurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
    }

    @ViewBuilder
    private var icon: some View {
        if isCompleted {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
        } else {
            // Same treatment as the home-screen card for this install: dimmed
            // icon with the percentage while downloading, a ring while signing.
            FlekInstallIcon(state: state, size: 46, corner: 12)
        }
    }

    private var statusText: String {
        switch phase {
        case .queued:
            return "lc.flek.install.waiting".loc
        case .downloading:
            return "lc.flek.install.downloading".loc
        case .waitingForInstall:
            return "lc.flek.install.preparing".loc
        case .installing:
            return "lc.flek.installing".loc
        case .completed:
            return "lc.flek.installed".loc
        case .failed(let message):
            return message.isEmpty ? "lc.flek.installFailedGeneric".loc : message
        case .cancelled:
            // Cancelled items leave the queue immediately, so this never shows.
            return "lc.flek.install.waiting".loc
        }
    }
}

/// Thin progress bar under the status line. Determinate phases fill left to
/// right; the phases with no measurable progress (queueing, decompressing,
/// signing) get a travelling segment so the card never looks stalled.
private struct FlekInstallTrayProgressBar: View {
    let fraction: Double
    let indeterminate: Bool
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if indeterminate {
                    FlekTravellingSegment(width: width, accent: accent)
                        // Restart the travel once the real width is known —
                        // onAppear can land on a first pass that measures zero.
                        .id(width)
                } else {
                    Capsule()
                        .fill(accent)
                        .frame(width: max(5, width * min(max(fraction, 0), 1)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            }
        }
        .frame(height: 5)
    }
}

/// The indeterminate bar's segment, sliding back and forth.
private struct FlekTravellingSegment: View {
    let width: CGFloat
    let accent: Color

    @State private var travelling = false

    var body: some View {
        Capsule()
            .fill(accent)
            .frame(width: width * 0.35)
            .offset(x: travelling ? width * 0.65 : 0)
            .flekRepeating(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), phase: $travelling)
    }
}

/// The tray's frosted surface — the installer's bottom-bar capsule, reshaped.
private struct FlekInstallTraySurface<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(Color(.systemBackground).opacity(0.5)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the list
    }
}
