//
//  FlekWallpaperView.swift
//  LiveContainerSwiftUI
//
//  Renders the home screen wallpaper. Supports a bundled wallpaper, a built-in
//  gradient preset, or a user-picked photo stored in the app group.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// A selectable wallpaper. Persisted as a single string descriptor:
///   - "asset:<name>"     bundled image asset
///   - "gradient:<id>"    built-in gradient preset
/// Photo wallpapers are tracked separately via `FlekDeckKeys.wallpaperPhoto`.
enum FlekWallpaper: Identifiable, Equatable {
    case asset(String)
    case gradient(String, [Color])

    var id: String {
        switch self {
        case .asset(let n): return "asset:\(n)"
        case .gradient(let g, _): return "gradient:\(g)"
        }
    }

    static let defaultDescriptor = "asset:wallpaper0"

    static let collection: [FlekWallpaper] = [
        .asset("wallpaper0"),
        .asset("FlekWallpaperDefault"),
        .asset("wallpaper1"),
        .asset("wallpaper2"),
        .asset("wallpaper3"),
        .asset("wallpaper4"),
        .asset("wallpaper5"),
        .asset("wallpaper6"),
        .asset("wallpaper7"),
        .asset("wallpaper8"),
        .asset("wallpaper9"),
        .asset("wallpaper10"),
        .asset("wallpaper11"),
        .asset("wallpaper12"),
        .asset("wallpaper13"),
        .asset("wallpaper14"),
        .gradient("sunset", [Color(red: 1.0, green: 0.45, blue: 0.45), Color(red: 0.6, green: 0.2, blue: 0.6)]),
        .gradient("ocean", [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.05, green: 0.20, blue: 0.45)]),
        .gradient("mint", [Color(red: 0.35, green: 0.85, blue: 0.70), Color(red: 0.10, green: 0.45, blue: 0.55)]),
        .gradient("dusk", [Color(red: 0.35, green: 0.30, blue: 0.55), Color(red: 0.10, green: 0.10, blue: 0.20)]),
        .gradient("peach", [Color(red: 1.0, green: 0.75, blue: 0.55), Color(red: 0.95, green: 0.45, blue: 0.55)]),
        .gradient("graphite", [Color(red: 0.30, green: 0.30, blue: 0.33), Color(red: 0.08, green: 0.08, blue: 0.10)]),
    ]

    static func from(descriptor: String) -> FlekWallpaper {
        if descriptor.hasPrefix("gradient:") {
            let id = String(descriptor.dropFirst("gradient:".count))
            if let match = collection.first(where: { if case .gradient(let g, _) = $0 { return g == id } else { return false } }) {
                return match
            }
        }
        if descriptor.hasPrefix("asset:") {
            return .asset(String(descriptor.dropFirst("asset:".count)))
        }
        return .asset("wallpaper0")
    }

    /// Small, cached rendering for the picker grid and the personalization
    /// preview. Both draw many wallpapers at tile size at once, so neither may
    /// touch the full-resolution asset — see `FlekWallpaperImages`.
    @ViewBuilder
    func thumbnail() -> some View {
        switch self {
        case .asset(let name):
            if let small = FlekWallpaperImages.assetThumbnail(named: name) {
                Image(uiImage: small).resizable().scaledToFill()
            } else {
                Image(name).resizable().scaledToFill()
            }
        case .gradient(_, let colors):
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Full-resolution rendering, for the single wallpaper actually filling the
    /// screen. Only ever one of these is on screen at a time.
    @ViewBuilder
    func fullSize() -> some View {
        switch self {
        case .asset(let name):
            Image(name).resizable().scaledToFill()
        case .gradient(_, let colors):
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Downsampling

/// Wallpapers are stored at screen resolution, which is the right size for the
/// one filling the screen and far too big for everything else. A `UIImage` costs
/// `width * height * 4` bytes the moment it is drawn no matter how small the file
/// is, so a 1912x2868 wallpaper is 21 MB of bitmap whether it fills the display
/// or a 110pt preview. The picker grid shows a dozen at once; drawing those at
/// full size is roughly a quarter of a gigabyte for a few thousand visible
/// pixels, and LiveContainer is sharing the device with a guest app that needs
/// that memory more than the grid does.
enum FlekWallpaperImages {
    /// Longest edge of a cached thumbnail. The picker tile is 180pt tall and the
    /// personalization preview 226pt; 600px covers both at 3x with room to spare.
    static let thumbnailMaxPixel: CGFloat = 600

    /// Longest edge of the display the app is on, in real pixels — the most a
    /// full-screen wallpaper can show there.
    static var screenMaxPixel: CGFloat {
        let b = FlekTheme.screen.nativeBounds
        return max(b.width, b.height)
    }

    private static let assetCache = NSCache<NSString, UIImage>()

    /// Downsampled copy of a bundled asset, decoded once and kept small.
    ///
    /// Asset catalog images have no file URL, so the full decode cannot be
    /// skipped outright — but it happens once per wallpaper and is released
    /// straight away, instead of a dozen full bitmaps staying resident for as
    /// long as the grid is open.
    static func assetThumbnail(named name: String) -> UIImage? {
        if let hit = assetCache.object(forKey: name as NSString) { return hit }
        guard let full = UIImage(named: name) else { return nil }
        let longest = max(full.size.width, full.size.height)
        guard longest > 0 else { return nil }
        let small: UIImage
        if longest > thumbnailMaxPixel {
            let ratio = thumbnailMaxPixel / longest
            let target = CGSize(width: full.size.width * ratio, height: full.size.height * ratio)
            small = full.preparingThumbnail(of: target) ?? full
        } else {
            small = full
        }
        assetCache.setObject(small, forKey: name as NSString)
        return small
    }

    static func clearAssetCache() {
        assetCache.removeAllObjects()
    }

    /// Decodes a file straight to the size actually needed. Unlike the asset
    /// path this never materialises the full bitmap: ImageIO reads the JPEG at a
    /// reduced scale, so a 48 MP camera photo never costs its 190 MB.
    static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Bakes in the EXIF orientation. Without it a photo taken in portrait
            // comes back on its side, since the thumbnail drops the metadata that
            // would otherwise have told the renderer to rotate it.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Shrinks an in-memory image so its longest edge is at most `maxPixel`.
    /// Returns the original when it is already small enough.
    static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixel, longest > 0 else { return image }
        let ratio = maxPixel / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return image.preparingThumbnail(of: target) ?? image
    }
}

struct FlekWallpaperView: View {
    @AppStorage(FlekDeckKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekDeckKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""

    var body: some View {
        GeometryReader { geo in
            Group {
                if !wallpaperPhoto.isEmpty, let img = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    FlekWallpaper.from(descriptor: wallpaperDescriptor).fullSize()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Stores user-picked photo wallpapers in the app group container.
enum FlekWallpaperStore {
    static var directory: URL {
        let url = LCPath.lcGroupDocPath.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Loads a stored photo, decoded no larger than it will be drawn. The default
    /// caps it at the display's own pixel count; the picker and preview pass
    /// `FlekWallpaperImages.thumbnailMaxPixel` instead.
    static func loadPhoto(named name: String,
                          maxPixel: CGFloat = FlekWallpaperImages.screenMaxPixel) -> UIImage? {
        let url = directory.appendingPathComponent(name)
        return FlekWallpaperImages.downsample(url: url, maxPixel: maxPixel)
    }

    @discardableResult
    static func savePhoto(_ image: UIImage) -> String? {
        let name = "wallpaper-\(Int(Date().timeIntervalSince1970)).jpg"
        // Stored at the size it was picked at, not shrunk to the display in use.
        // On an iPhone Duo that is the cover display while folded, and a photo
        // shrunk to it goes soft on the inner one once unfolded. The full photo is
        // never drawn: every load decodes it straight to the display's size
        // through `downsample(url:maxPixel:)`, and the blur reads it smaller still.
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }
}

// MARK: - CIGaussianBlur helper

private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

/// Applies CIGaussianBlur to a UIImage. Returns nil on failure.
func ciGaussianBlur(_ image: UIImage, radius: CGFloat) -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let filter = CIFilter.gaussianBlur()
    // Edge pixels stretched outward before blurring, so the kernel has something
    // to average against out there. An image has nothing beyond its bounds — the
    // filter reads transparent black — and near an edge more and more of the
    // kernel falls into that emptiness, darkening and fading the border into the
    // vignette that framed every blurred wallpaper and switcher backdrop.
    // Clamping is free: the extended image is infinite but only the part the crop
    // below asks for is ever rendered.
    filter.inputImage = ciImage.clampedToExtent()
    filter.radius = Float(radius)
    guard let output = filter.outputImage else { return nil }
    // CIGaussianBlur expands the image; crop back to original extent
    let cropped = output.cropped(to: ciImage.extent)
    guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
    return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
}

/// Renders a gradient to a UIImage so it can be blurred with CIGaussianBlur.
private func renderGradient(colors: [Color], size: CGSize) -> UIImage? {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        let cgColors = colors.map { UIColor($0).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: cgColors as CFArray,
                                        locations: nil) else { return }
        ctx.cgContext.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size.width, y: size.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}

/// Bottom gradient blur overlay using CIGaussianBlur — pure blur, no tint.
struct FlekBlurredWallpaperOverlay: View {
    @AppStorage(FlekDeckKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekDeckKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""

    var radius: CGFloat = 20

    @State private var blurredImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            if let blurred = blurredImage {
                Image(uiImage: blurred)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height + 6)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.8),
                                .init(color: .white, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear { generateBlurred() }
        .onChange(of: wallpaperDescriptor) { _ in generateBlurred() }
        .onChange(of: wallpaperPhoto) { _ in generateBlurred() }
    }

    /// Blurred wallpapers, keyed by what produced them. `generateBlurred` runs on
    /// every appear — including each return from an app — and a Gaussian blur over a
    /// full-screen image is not cheap to repeat for a result that cannot have changed.
    private static let blurCache = NSCache<NSString, UIImage>()

    static func clearBlurCache() {
        blurCache.removeAllObjects()
    }

    private func generateBlurred() {
        let cacheKey = "\(wallpaperPhoto)|\(wallpaperDescriptor)|\(radius)" as NSString
        if let cached = Self.blurCache.object(forKey: cacheKey) {
            blurredImage = cached
            return
        }

        let screenSize = FlekTheme.screen.bounds.size
        let sourceImage: UIImage?

        // A Gaussian blur is a lowpass filter: everything it is about to throw
        // away is exactly the detail that full resolution buys. Running it over a
        // 1912x2868 wallpaper costs 21 MB of bitmap and millions of pixel reads
        // to produce something indistinguishable from the same blur done small
        // and scaled back up — and the result is only ever shown as a soft strip
        // along the bottom edge. Shrink first, and scale the radius to match so
        // the blur keeps the same apparent softness.
        if !wallpaperPhoto.isEmpty {
            sourceImage = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto,
                                                       maxPixel: Self.blurMaxPixel)
        } else {
            let wp = FlekWallpaper.from(descriptor: wallpaperDescriptor)
            switch wp {
            case .asset(let name):
                sourceImage = UIImage(named: name).map {
                    FlekWallpaperImages.downscale($0, maxPixel: Self.blurMaxPixel)
                }
            case .gradient(_, let colors):
                sourceImage = renderGradient(colors: colors, size: screenSize)
            }
        }

        guard let source = sourceImage else {
            blurredImage = nil
            return
        }

        // How far the source was shrunk, so the radius can follow it down.
        let longest = max(source.size.width, source.size.height)
        let scaledRadius = longest > 0
            ? radius * min(1, longest / FlekWallpaperImages.screenMaxPixel)
            : radius

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ciGaussianBlur(source, radius: scaledRadius)
            DispatchQueue.main.async {
                if let result { Self.blurCache.setObject(result, forKey: cacheKey) }
                blurredImage = result
            }
        }
    }

    /// Longest edge the blur works at. The output is soft by definition, so it
    /// upscales back to the screen with nothing visibly lost.
    private static let blurMaxPixel: CGFloat = 720
}

