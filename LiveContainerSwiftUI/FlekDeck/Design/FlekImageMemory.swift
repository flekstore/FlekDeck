//
//  FlekImageMemory.swift
//  LiveContainerSwiftUI
//
//  How much memory images may hold, by how much the device has.
//

import Kingfisher
import UIKit

enum FlekImageMemory {
    /// Phones with 4 GB or less: the iPhone 13 and older, and the SEs. Memory
    /// runs short on them first, and iOS meets that by ending the apps open in
    /// windows. The figure iOS reports falls a little short of the label,
    /// hence the margin.
    static let isLow = ProcessInfo.processInfo.physicalMemory < 5 << 30

    /// Kingfisher's defaults let its memory cache grow to a quarter of the
    /// device's memory and its disk cache without limit, every icon's original
    /// kept beside its downsized copy. Memory is held to a fiftieth of the
    /// device's, between 32 and 150 MB: 150 on a phone with 8 GB, some 75 on
    /// one with 4. An image let go of is read back from disk or fetched again
    /// when it is next shown.
    static func configureCaches() {
        let share = Int(clamping: ProcessInfo.processInfo.physicalMemory / 50)
        ImageCache.default.memoryStorage.config.totalCostLimit = min(max(share, 32 << 20), 150 << 20)
        ImageCache.default.diskStorage.config.sizeLimit = 300 << 20
    }

    /// How app page screenshots are decoded, for a gallery whose shots stand
    /// at most `height` points tall. Full size where memory allows, because
    /// the screenshot viewer opens on the gallery's copy. With little memory,
    /// at the size the gallery shows them, some six times fewer pixels; the
    /// viewer then fetches the full-size shot itself.
    static func screenshotDecoding(height: CGFloat) -> (processor: ImageProcessor, scale: CGFloat) {
        guard isLow else {
            return (DefaultImageProcessor.default, 1)
        }
        return (DownsamplingImageProcessor(size: CGSize(width: height, height: height)), FlekTheme.screen.scale)
    }
}
