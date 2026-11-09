//
//  AppsWidgetView.swift
//  WidgetExtension
//

import SwiftUI
import WidgetKit

struct AppsWidgetView: View {
    let entry: AppsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                // Clear over the home screen's own glass (SystemGlassBackground);
                // the usual grey should iOS ever stop taking the glass request.
                if SystemGlassBackground.isInstalled {
                    Color.clear
                } else {
                    Rectangle().fill(.fill.tertiary)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        let grid = family.iconGrid
        switch entry.content {
        case .placeholder:
            IconGrid(columns: grid.columns, rows: grid.rows, count: grid.columns * grid.rows) { _ in
                Rectangle().fill(.quaternary)
            }
        case .apps(let apps) where apps.isEmpty:
            Message(title: "No apps yet", caption: "Apps you install in FlekDeck show up here.")
        case .apps(let apps):
            IconGrid(columns: grid.columns, rows: grid.rows, count: apps.count) { index in
                AppIcon(app: apps[index])
            }
        case .noneChosen:
            Message(title: "No apps chosen", caption: "Hold the widget, then tap Edit Widget.")
        case .noList:
            Message(title: "Open FlekDeck", caption: "Your apps show up here once it has been opened.")
        case .noAppGroup:
            Message(title: "Not available", caption: "This copy of FlekDeck can't share its apps with widgets.")
        }
    }
}

/// Icons spread evenly over the widget, the gaps between them and at the edges
/// in proportion to the icons, as on a page of the home screen. Slots past
/// `count` stay empty, like the end of a home screen page.
private struct IconGrid<Tile: View>: View {
    let columns: Int
    let rows: Int
    let count: Int
    @ViewBuilder let tile: (Int) -> Tile

    /// A gap's width as a share of an icon's.
    private let gapRatio: CGFloat = 0.28

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let side = min(size.width / (CGFloat(columns) + CGFloat(columns + 1) * gapRatio),
                           size.height / (CGFloat(rows) + CGFloat(rows + 1) * gapRatio))
            let columnGap = (size.width - CGFloat(columns) * side) / CGFloat(columns + 1)
            let rowGap = (size.height - CGFloat(rows) * side) / CGFloat(rows + 1)
            VStack(spacing: rowGap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: columnGap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            Group {
                                if index < count {
                                    tile(index)
                                        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: side, height: side)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

private struct AppIcon: View {
    let app: WidgetApp

    var body: some View {
        tile
            .accessibilityHidden(true)
            // Laid over the icon rather than around it: from iOS 26, a Link
            // whose label holds an image with an accented rendering mode opens
            // FlekDeck without its URL, as a tap on the widget's background does.
            .overlay {
                Link(destination: app.url) {
                    Color.clear.contentShape(Rectangle())
                }
                .accessibilityLabel(app.name)
            }
    }

    @ViewBuilder
    private var tile: some View {
        if let icon = app.icon {
            IconImage(icon: icon)
        } else {
            // The icon could not be read: the app's initial on a plain tile.
            ZStack {
                Rectangle().fill(.quaternary)
                Text(app.name.prefix(1))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IconImage: View {
    let icon: UIImage

    var body: some View {
        if #available(iOS 18.0, *) {
            // On a tinted or clear home screen, a grey icon in the tint, as iOS
            // draws the icons around it, rather than a white silhouette.
            Image(uiImage: icon)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
        } else {
            Image(uiImage: icon)
                .resizable()
        }
    }
}

private struct Message: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
