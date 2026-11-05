//
//  FlekGameWarningView.swift
//  LiveContainerSwiftUI
//
//  Shown when launching a game for the first time (no remembered launch mode).
//  Recommends Single Mode; the "remember my choice" toggle is on by default.
//

import SwiftUI

/// Measures the intrinsic content height so the sheet detent can fit it exactly
/// (no wasted empty space, and the description never gets compressed/truncated).
private struct FlekGameSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FlekGameWarningView: View {
    let appName: String
    var onChoose: (_ parallel: Bool, _ remember: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FlekDeckKeys.glassStyle, store: LCUtils.appGroupUserDefault) private var glassStyle: FlekGlassStyle = .liquid

    @State private var remember = true
    @State private var sheetHeight: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            // Header: game icon on the left, close (X) button on the right,
            // vertically centered on the icon.
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.26, green: 0.6, blue: 1.0),
                                                      Color(red: 0/255, green: 117/255, blue: 255/255)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 64, height: 64)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color(white: 0.95))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 51, height: 51)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 22)

            VStack(alignment: .leading, spacing: 12) {
                Text("lc.flek.game.title".loc)
                    .font(.system(size: 20, weight: .semibold))
                Text("lc.flek.game.desc".loc)
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 20)

            Button {
                remember.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: remember ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28))
                        .foregroundStyle(remember ? Color.accentColor : .secondary)
                    Text("lc.flek.game.remember".loc).font(.system(size: 18)).foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.vertical, 18)

            VStack(spacing: 12) {
                Button {
                    onChoose(true, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runParallel".loc, systemImage: "macwindow.on.rectangle")
                        .font(.system(size: 19, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)

                Button {
                    onChoose(false, remember); dismiss()
                } label: {
                    Label("lc.flek.game.runSingle".loc, systemImage: "app.dashed")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 26)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FlekGameSheetHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(FlekGameSheetHeightKey.self) { h in
            if h > 0 { sheetHeight = h }
        }
        .apply { v in
            // A clear presentation background leaves the sheet with no backdrop of
            // its own, which only reads as intentional under Liquid Glass. Below
            // iOS 26 that renders as bare text over the dimmed springboard, so
            // those versions get a material instead, as does the frosted glass style.
            if #available(iOS 26.0, *), glassStyle == .liquid {
                v.presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
            } else if #available(iOS 16.4, *) {
                v.presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            } else if #available(iOS 16.0, *) {
                v.presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
            } else {
                v
            }
        }
    }
}
