//
//  FlekInstallingCard.swift
//  LiveContainerSwiftUI
//
//  The "app installing" tile shown on the home screen while a download/sign is
//  in progress. Matches the FlekSign design: a dimmed app icon with a centered
//  percentage + progress bar while downloading, or a round spinner during
//  intermediate steps (request / decompress / signing).
//

import SwiftUI
import Kingfisher

private let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)

/// Dimmed-icon + progress overlay, reused by the grid card and the list row.
struct FlekInstallIcon: View {
    let state: FlekInstallState
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            Group {
                if let urlStr = state.iconURL, let url = URL(string: urlStr) {
                    KFImage(url)
                        // Not pulsing: the ring and percentage drawn over this
                        // are already moving.
                        .placeholder { FlekImagePlaceholder(pulses: false) }
                        .cacheOriginalImage()
                        .fade(duration: 0.15)
                        .resizable()
                        .scaledToFill()
                } else {
                    FlekImagePlaceholder(pulses: false)
                }
            }
            .overlay(Color.black.opacity(0.5))

            if state.failed {
                // Failed install — red warning mark over the dimmed icon.
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            } else if state.indeterminate {
                // Spinning partial ring matching the install ring style
                FlekSpinningRing(size: size * 0.55, lineWidth: size > 60 ? 5 : 4)
            } else if state.isInstalling {
                // Circular ring progress during install phase (counter-clockwise)
                let ringSize = size * 0.55
                let lineW: CGFloat = size > 60 ? 5 : 4
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: lineW)
                    Circle()
                        .trim(from: 0, to: max(0.02, state.installFraction))
                        .stroke(flekBlue, style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
            } else {
                // Centered percentage during download
                let fontSize: CGFloat = size > 60 ? 18 : 13
                // Both branches erased to AnyView so the conditional's type is
                // _ConditionalContent<AnyView, AnyView>. `contentTransition` is
                // iOS 16+, and leaving it in the static type traps on iOS 15,
                // where the runtime resolves that type before the availability
                // check runs.
                if #available(iOS 16.0, *) {
                    AnyView(
                        Text("\(Int((state.fraction * 100).rounded()))%")
                            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.default, value: Int((state.fraction * 100).rounded()))
                            .frame(width: "100%".size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)]).width)
                    )
                } else {
                    AnyView(
                        Text("\(Int((state.fraction * 100).rounded()))%")
                            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: "100%".size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)]).width)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            // Progress pill near the bottom of the icon (only during download on large icon)
            if !state.failed && !state.indeterminate && !state.isInstalling && size > 60 {
                let trackW = size * 0.78          // ≈ 58 on a 74pt icon
                let trackH: CGFloat = 18
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.white.opacity(0.5)))
                        .frame(width: trackW, height: trackH)
                    Capsule()
                        .fill(flekBlue)
                        .frame(width: max(trackH - 4, (trackW - 4) * state.fraction), height: trackH - 4)
                        .padding(.leading, 2)
                }
                .padding(.bottom, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Springboard grid card for the in-progress install.
struct FlekInstallingCard: View {
    let state: FlekInstallState
    var cardHeight: CGFloat = FlekTheme.cardHeight

    private var scale: CGFloat { cardHeight / FlekTheme.cardHeight }

    var body: some View {
        VStack(spacing: FlekTheme.cardInnerSpacing * scale) {
            FlekInstallIcon(state: state, size: FlekTheme.iconSize * scale, corner: FlekTheme.iconCorner * scale)
            Text(state.name ?? "lc.flek.installing".loc)
                .font(.system(size: FlekTheme.labelSize * scale, weight: .medium))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, FlekTheme.cardTopPadding * scale)
        .padding(.bottom, FlekTheme.cardBottomPadding * scale)
        .padding(.horizontal, FlekTheme.cardHPadding)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .flekGlassCard(cornerRadius: FlekTheme.cardCorner * min(1, scale))
    }
}

/// A partial ring that spins continuously, matching the install ring style.
private struct FlekSpinningRing: View {
    let size: CGFloat
    let lineWidth: CGFloat

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(flekBlue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .flekRepeating(.linear(duration: 1.0).repeatForever(autoreverses: false), phase: $spinning)
    }
}
