//
//  LCSpringboardIconCell.swift
//  LiveContainerSwiftUI
//
//  UICollectionViewCell rendering a single app icon in the UIKit springboard.
//  Simple iOS-style: squircle icon + name label underneath.
//

import UIKit
import SwiftUI

final class LCSpringboardIconCell: UICollectionViewCell {

    // MARK: - Subviews

    let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = false
        iv.backgroundColor = .clear
        return iv
    }()

    /// The font is set in `layoutSubviews`, where the card's width is known.
    let nameLabel: UILabel = {
        let label = UILabel()
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        // A name too long for its box is cut short rather than shrunk: the
        // titles across a page read as one size that way, and an ellipsis says
        // there is more name plainly enough.
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    

    /// Delete button shown in edit mode (top-left of icon).
    let deleteButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        btn.setImage(UIImage(systemName: "minus", withConfiguration: config), for: .normal)
        btn.isHidden = true
        btn.alpha = 0
        return btn
    }()

    /// Badge for single-mode apps (top-right corner of glass card).
    private let singleBadge: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iv.image = UIImage(systemName: "app.dashed", withConfiguration: config)
        iv.tintColor = .secondaryLabel
        iv.contentMode = .center
        iv.isHidden = true
        return iv
    }()

    /// Badge for apps set to launch with JIT (top-left corner of glass card).
    /// The delete button takes that corner in edit mode, and the badge makes
    /// way for it.
    private let jitBadge: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iv.image = UIImage(systemName: FlekSymbol.jit, withConfiguration: config)
        iv.tintColor = .secondaryLabel
        iv.contentMode = .center
        iv.isHidden = true
        return iv
    }()

    /// The red count on the icon's corner, as an iOS home screen badges an app:
    /// Settings shows 1 while no certificate is imported. A label rather than
    /// an image, so a count of two digits widens into a capsule.
    private let notificationBadge: UILabel = {
        let label = UILabel()
        label.backgroundColor = .systemRed
        label.textColor = .white
        label.textAlignment = .center
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    /// Dimming overlay for `.installing` state (covers icon).
    private let installOverlay: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.isHidden = true
        return v
    }()

    /// Red warning mark shown (centered on the dimmed icon) when an install failed.
    private let failedSymbol: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
        let img = UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: config)?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        iv.image = img
        iv.contentMode = .center
        iv.isHidden = true
        return iv
    }()

    /// Spinning ring for indeterminate install state.
    private let spinnerRingView: UIView = {
        let v = UIView()
        v.isHidden = true
        return v
    }()

    private let spinnerTrackLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.lineWidth = 5
        return layer
    }()

    private let spinnerFillLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor(red: 0/255, green: 117/255, blue: 255/255, alpha: 1).cgColor
        layer.lineWidth = 5
        layer.lineCap = .round
        layer.strokeStart = 0
        layer.strokeEnd = 0.7
        return layer
    }()

    /// Hosted SwiftUI percentage view with `.contentTransition(.numericText())`.
    /// Made the first time this cell shows a download: every icon on the home
    /// screen is one of these cells, and only one being installed ever shows a
    /// percentage. See `percentHost()`.
    private var percentHostingController: UIHostingController<PercentageText>?
    private var percentHostView: UIView? { percentHostingController?.view }

    /// Blue progress bar near bottom of icon (download phase).
    private let progressTrack: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        v.isHidden = true
        return v
    }()

    private let progressFill: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0/255, green: 117/255, blue: 255/255, alpha: 1)
        return v
    }()

    /// Circular ring progress shown during install phase.
    private let ringTrackLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.lineWidth = 5
        layer.isHidden = true
        return layer
    }()

    private let ringFillLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor(red: 0/255, green: 117/255, blue: 255/255, alpha: 1).cgColor
        layer.lineWidth = 5
        layer.lineCap = .round
        layer.strokeStart = 0
        layer.strokeEnd = 0
        layer.isHidden = true
        return layer
    }()

    /// Current icon URL loading task.
    private var iconLoadTask: URLSessionDataTask?
    /// URL string of the icon currently being loaded (or already loaded).
    /// Used to avoid cancelling + restarting the same load on every
    /// progress update (configureInstallState is called very frequently).
    private var loadingIconURL: String?

    // MARK: - State

    private(set) var isAnimating = false
    var onDeleteTap: (() -> Void)?
    var onTap: (() -> Void)?

    /// Whether this cell represents a placeholder (invisible).
    private(set) var isPlaceholderCell = false

    /// The item this cell was last configured with.
    /// Used by the drag manager to read back cell order after moves.
    private(set) var configuredItem: FlekHomeItem?

    /// Liquid Glass (iOS 26+) or thin material card background.
    private var glassBackgroundView: UIVisualEffectView?

    // MARK: - Layout constants

    /// What the icon and its title take up inside the card, as fractions of the
    /// card's width rather than fixed sizes: a wider screen gets a bigger icon
    /// instead of the same icon adrift in a bigger card. Read off the design's
    /// 110×120 card — a 66pt icon, a 77×14 title, and 8pt between the two —
    /// which leaves 16pt above the icon and 16pt below the title.
    private static let iconWidthFraction: CGFloat = 66.0 / 110.0
    private static let labelWidthFraction: CGFloat = 77.0 / 110.0
    private static let labelHeightFraction: CGFloat = 14.0 / 110.0
    private static let labelTopSpacingFraction: CGFloat = 8.0 / 110.0
    /// 11pt against the design's card, and the same share of a wider one.
    private static let labelFontFraction: CGFloat = 11.0 / 110.0
    /// The squircle's corner as a share of its side — the same ratio
    /// `LCMinimizeToIconAnimator` rounds a landing window to.
    private static let iconCornerFraction: CGFloat = 0.2237

    /// Width of the card this cell is, which everything inside it is a share of.
    ///
    /// The card's own width, not one worked out from the screen. A page can be
    /// narrower than the display it is on: the iPhone Duo's cover display keeps a
    /// vertical status bar down one side, and icons measured against the whole
    /// display came out sized for cards a quarter wider than the ones they sat in.
    /// Handed over by the page with each item, since the icon is rasterised as the
    /// item arrives, before the cell has been laid out; layout then reads it off the
    /// cell's own bounds, which a turned iPad grid can make a few points narrower.
    private var cardWidth: CGFloat = 0

    private var iconSize: CGFloat { (cardWidth * Self.iconWidthFraction).rounded() }
    private var iconCornerRadius: CGFloat { Self.iconCornerRadius(forIconSize: iconSize) }
    private var labelSize: CGSize {
        CGSize(width: (cardWidth * Self.labelWidthFraction).rounded(),
               height: (cardWidth * Self.labelHeightFraction).rounded())
    }
    private var labelTopSpacing: CGFloat {
        (cardWidth * Self.labelTopSpacingFraction).rounded()
    }
    private var labelFont: UIFont {
        .systemFont(ofSize: (cardWidth * Self.labelFontFraction).rounded(), weight: .medium)
    }

    /// The squircle corner of an icon this many points across.
    static func iconCornerRadius(forIconSize size: CGFloat) -> CGFloat {
        (size * iconCornerFraction).rounded()
    }

    /// The notification badge's height as a share of the icon's side, so it
    /// grows with the icon, and its figure's size as a share of that height.
    private static let badgeHeightFraction: CGFloat = 24.0 / 66.0
    private static let badgeFontFraction: CGFloat = 16.0 / 24.0

    private static let deleteButtonSize: CGFloat = 24
    private static let cardCorner: CGFloat = 24

    // MARK: - Suppress default highlight

    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set { /* No highlight visual for springboard icons */ }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        setupGlassBackground()

        contentView.addSubview(iconImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(singleBadge)
        contentView.addSubview(jitBadge)
        contentView.addSubview(notificationBadge)
        contentView.addSubview(deleteButton)

        // Install overlay on top of icon
        iconImageView.addSubview(installOverlay)
        spinnerRingView.layer.addSublayer(spinnerTrackLayer)
        spinnerRingView.layer.addSublayer(spinnerFillLayer)
        installOverlay.addSubview(spinnerRingView)
        installOverlay.addSubview(failedSymbol)

        progressTrack.addSubview(progressFill)
        installOverlay.addSubview(progressTrack)
        installOverlay.layer.addSublayer(ringTrackLayer)
        installOverlay.layer.addSublayer(ringFillLayer)

        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
        contentView.addGestureRecognizer(tap)
    }

    private func setupGlassBackground() {
        let effectView: UIVisualEffectView
        if #available(iOS 26, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        effectView.layer.cornerRadius = Self.cardCorner
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true

        // On pre-iOS 26, add a tint overlay for the frosted look
        if #unavailable(iOS 26) {
            let tint = UIView()
            tint.backgroundColor = UIColor.label.withAlphaComponent(0.15)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            effectView.contentView.addSubview(tint)

            // Subtle border
            effectView.layer.borderWidth = 0.5
            effectView.layer.borderColor = UIColor.label.withAlphaComponent(0.15).cgColor
        }

        contentView.insertSubview(effectView, at: 0)
        glassBackgroundView = effectView
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentView.bounds
        if bounds.width > 0 { cardWidth = bounds.width }

        // Glass card fills the full cell bounds
        glassBackgroundView?.frame = bounds
        glassBackgroundView?.layer.cornerRadius = Self.cardCorner

        // Content block: icon + spacing + label, centred in the card, so the
        // room left over falls equally above the icon and below the title.
        let iconS = iconSize
        let labelS = labelSize
        let labelGap = labelTopSpacing
        let contentHeight = iconS + labelGap + labelS.height
        let contentY = ((bounds.height - contentHeight) / 2).rounded()

        let iconX = ((bounds.width - iconS) / 2).rounded()
        iconImageView.frame = CGRect(x: iconX, y: contentY, width: iconS, height: iconS)

        installOverlay.frame = iconImageView.bounds
        installOverlay.layer.cornerRadius = iconCornerRadius
        installOverlay.clipsToBounds = true
        failedSymbol.frame = installOverlay.bounds
        // Spinning ring (indeterminate state)
        let spinnerSize = iconS * 0.55
        let spinnerFrame = CGRect(
            x: (iconS - spinnerSize) / 2,
            y: (iconS - spinnerSize) / 2,
            width: spinnerSize,
            height: spinnerSize
        )
        spinnerRingView.frame = spinnerFrame
        let spinnerBounds = CGRect(origin: .zero, size: spinnerFrame.size)
        let spinnerPath = UIBezierPath(ovalIn: spinnerBounds)
        spinnerTrackLayer.path = spinnerPath.cgPath
        spinnerTrackLayer.frame = spinnerBounds
        spinnerFillLayer.path = spinnerPath.cgPath
        spinnerFillLayer.frame = spinnerBounds

        percentHostView?.frame = CGRect(x: 0, y: 0, width: iconS, height: iconS)

        // Progress bar near bottom of icon (download phase)
        let trackW = iconS * 0.78
        let trackH: CGFloat = 18
        let trackX = (iconS - trackW) / 2
        let trackY = iconS - trackH - 6
        progressTrack.frame = CGRect(x: trackX, y: trackY, width: trackW, height: trackH)
        progressTrack.layer.cornerRadius = trackH / 2
        progressTrack.clipsToBounds = true
        updateProgressFillWidth()

        // Circular ring (install phase)
        let ringSize = iconS * 0.55
        let ringRect = CGRect(
            x: (iconS - ringSize) / 2,
            y: (iconS - ringSize) / 2,
            width: ringSize,
            height: ringSize
        )
        let ringPath = UIBezierPath(ovalIn: ringRect)
        ringTrackLayer.path = ringPath.cgPath
        ringTrackLayer.frame = installOverlay.bounds
        ringFillLayer.path = ringPath.cgPath
        ringFillLayer.frame = installOverlay.bounds
        // Rotate so stroke starts at top (clockwise)
        ringFillLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)

        nameLabel.font = labelFont
        nameLabel.frame = CGRect(
            x: ((bounds.width - labelS.width) / 2).rounded(),
            y: contentY + iconS + labelGap,
            width: labelS.width,
            height: labelS.height
        )

        // Single-mode badge (top-right corner of glass card)
        let badgeSize: CGFloat = 16
        singleBadge.frame = CGRect(
            x: bounds.maxX - badgeSize - 8,
            y: 8,
            width: badgeSize,
            height: badgeSize
        )
        // JIT badge (top-left corner of glass card)
        jitBadge.frame = CGRect(x: 8, y: 8, width: badgeSize, height: badgeSize)

        // Notification badge: hung off the icon's top-right corner the way iOS
        // hangs one, mostly over the icon. A count wider than a circle grows
        // it to the left, so its right edge stays put.
        let countHeight = (iconS * Self.badgeHeightFraction).rounded()
        notificationBadge.font = .systemFont(ofSize: (countHeight * Self.badgeFontFraction).rounded())
        let countWidth = max(countHeight,
                             ceil(notificationBadge.intrinsicContentSize.width) + countHeight / 2)
        let overhang = (countHeight * 0.4).rounded()
        notificationBadge.frame = CGRect(
            x: iconX + iconS + overhang - countWidth,
            y: contentY - overhang,
            width: countWidth,
            height: countHeight
        )
        notificationBadge.layer.cornerRadius = countHeight / 2

        let dbSize = Self.deleteButtonSize
        deleteButton.frame = CGRect(
            x: -(dbSize / 3),
            y: -(dbSize / 3),
            width: dbSize,
            height: dbSize
        )
        deleteButton.layer.cornerRadius = dbSize / 2
        deleteButton.layer.masksToBounds = true

        updateDeleteButtonColors()
    }

    private func updateDeleteButtonColors() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        deleteButton.tintColor = isDark ? .white : .black
        deleteButton.backgroundColor = isDark
            ? UIColor(white: 0.25, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateDeleteButtonColors()
            if currentNameIsShared { setName(currentName, shared: true) }
        }
    }

    /// Pre-renders an image with rounded corners baked into the pixels.
    /// Avoids using a layer mask which iOS 26 detects and applies an
    /// unwanted Liquid Glass specular highlight to.
    /// Rounded icons, keyed so a cell being recycled reuses one instead of drawing it
    /// again. `configure` runs for every dequeued cell, so paging a full screen of
    /// icons was re-rendering each of them — up to a page's worth per swipe.
    private static let roundedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func clearRoundedImageCache() {
        roundedCache.removeAllObjects()
    }

    private static func roundedImage(_ image: UIImage?, size: CGFloat, radius: CGFloat,
                                     scale: CGFloat, cacheKey: String? = nil) -> UIImage? {
        guard let image, size > 0 else { return nil }
        let key = cacheKey.map { "\($0)|\(size)|\(radius)" as NSString }
        if let key, let cached = roundedCache.object(forKey: key) { return cached }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            image.draw(in: rect)
        }
        if let key { roundedCache.setObject(rendered, forKey: key) }
        return rendered
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopJiggle()
        iconImageView.image = nil
        // Undoes the delete animation in `LCSpringboardPageCell.safeReloadItems`,
        // which shrinks the icon to nothing and fades the name before the row
        // closes up. It restores all three in its batch-update completion, but a
        // completion that never fires -- a reload landing on top of the update,
        // the page recycled mid-flight -- used to leave the shrunk icon and the
        // faded name on the cell. Only `contentView.alpha` was reset here, so
        // the next app to be handed that cell drew its name over no icon at all,
        // and kept doing so: nothing else ever put the transform back.
        iconImageView.transform = .identity
        // And the icon a window was flying into or out of when the page was
        // recycled, which stood aside for the flight and would otherwise stay gone.
        iconImageView.alpha = 1
        nameLabel.alpha = 1
        setName(nil, shared: false)
        deleteButton.isHidden = true
        deleteButton.alpha = 0
        singleBadge.isHidden = true
        jitBadge.isHidden = true
        jitBadge.alpha = 1
        setNotificationCount(0)
        installOverlay.isHidden = true
        spinnerRingView.isHidden = true
        stopSpinnerAnimation()
        percentHostView?.isHidden = true
        percentHostingController?.rootView = PercentageText(percent: 0)
        progressTrack.isHidden = true
        ringTrackLayer.isHidden = true
        ringFillLayer.isHidden = true
        iconLoadTask?.cancel()
        iconLoadTask = nil
        loadingIconURL = nil
        currentFraction = 0
        contentView.alpha = 1
        contentView.isHidden = false
        glassBackgroundView?.isHidden = false
        isUserInteractionEnabled = true
        isPlaceholderCell = false
        onDeleteTap = nil
        onTap = nil
    }

    // MARK: - Configuration

    /// Current install fraction for progress fill layout.
    private var currentFraction: Double = 0

    /// The title currently shown and whether it carries the shared mark. Kept
    /// so a colour appearance change can redraw it: the mark is an image baked
    /// into the label, and an image does not resolve a dynamic colour the way
    /// the label's own text does.
    private var currentName: String?
    private var currentNameIsShared = false

    /// - Parameter cardWidth: the width the page lays this card out at — see
    ///   `cardWidth`.
    func configure(with item: FlekHomeItem, darkMode: Bool, cardWidth: CGFloat) {
        configuredItem = item
        if cardWidth > 0 { self.cardWidth = cardWidth }
        // Only a built-in app carries a count. Worked out for every item, as a
        // cell refreshed in place for another item must not keep the last one's.
        var notificationCount = 0
        switch item {
        case .defaultApp(let kind):
            iconImageView.image = Self.roundedImage(UIImage(named: kind.iconAssetName),
                                                    size: iconSize,
                                                    radius: iconCornerRadius,
                                                    scale: FlekTheme.screen.scale,
                                                    cacheKey: "builtin:\(kind.iconAssetName)")
            setName(kind.title, shared: false)
            notificationCount = kind.badgeCount(in: DataManager.shared.model)
            isPlaceholderCell = false

        case .installed(let app):
            iconImageView.image = Self.roundedImage(app.appInfo.iconIsDarkIcon(darkMode),
                                                    size: iconSize,
                                                    radius: iconCornerRadius,
                                                    scale: FlekTheme.screen.scale,
                                                    cacheKey: (app.appInfo.relativeBundlePath).map { "app:\($0):\(app.uiIsShared):\(darkMode)" })
            setName(app.appInfo.displayName(), shared: app.uiIsShared)
            showBadges(for: app)
            isPlaceholderCell = false

        case .installing(let inst):
            isPlaceholderCell = false
            configureInstallState(inst.installState)

        case .placeholder:
            iconImageView.image = nil
            setName(nil, shared: false)
            contentView.alpha = 0
            glassBackgroundView?.isHidden = true
            isUserInteractionEnabled = false
            isPlaceholderCell = true
        }
        setNotificationCount(notificationCount)
    }

    /// Shows `count` in the notification badge, or no badge at all for 0.
    private func setNotificationCount(_ count: Int) {
        notificationBadge.text = count > 0 ? "\(count)" : nil
        notificationBadge.isHidden = count <= 0
        // The badge's width follows its figure.
        setNeedsLayout()
    }

    /// Sets the title, prefixed with the shared mark when the app's data lives
    /// in the shared folder rather than privately. The mark is drawn inside the
    /// label as an attachment rather than as a view of its own: the label is
    /// centred under the icon and truncates its own tail, and both keep working
    /// when the mark is part of the same line.
    private func setName(_ name: String?, shared: Bool) {
        currentName = name
        currentNameIsShared = shared
        // Cleared explicitly: the label may be carrying a marked title from
        // the cell this one is being reused from.
        nameLabel.attributedText = nil
        guard let name else {
            nameLabel.text = nil
            return
        }
        guard shared else {
            nameLabel.text = name
            return
        }
        let font = labelFont
        let attachment = NSTextAttachment()
        // A font-based configuration sizes the symbol to the title and sits it
        // on the same baseline.
        attachment.image = UIImage(
            systemName: FlekSymbol.shared,
            withConfiguration: UIImage.SymbolConfiguration(font: font)
        )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        let line = NSMutableAttributedString(attachment: attachment)
        // A thin space: the mark belongs to the name, not next to it.
        line.append(NSAttributedString(string: "\u{2009}" + name))
        line.addAttributes(
            [.font: font, .foregroundColor: UIColor.label],
            range: NSRange(location: 0, length: line.length)
        )
        nameLabel.attributedText = line
    }

    /// Update just the corner badges' visibility without full reconfigure.
    func updateBadge() {
        guard case .installed(let app) = configuredItem else { return }
        showBadges(for: app)
    }

    private func showBadges(for app: LCAppModel) {
        singleBadge.isHidden = !FlekLaunchModeStore.shared.showsSingleBadge(for: app)
        jitBadge.isHidden = !app.uiIsJITNeeded
    }

    /// Update just the install state (progress/icon) without full reconfigure.
    func updateInstallState() {
        guard case .installing(let inst) = configuredItem else { return }
        configureInstallState(inst.installState)
    }

    private func configureInstallState(_ state: FlekInstallState) {
        // Name
        setName(state.name ?? "Installing...", shared: false)

        // Icon from URL — only start a new load when the URL changes.
        // configureInstallState is called on every progress tick, so
        // cancelling + restarting the load each time prevented the
        // icon from ever finishing its download.
        if let urlStr = state.iconURL, let url = URL(string: urlStr) {
            if urlStr != loadingIconURL || iconImageView.image == nil {
                loadingIconURL = urlStr
                iconLoadTask?.cancel()
                // Measured here, on the main thread, rather than in the completion
                // handler: the sizes are read off the app's scene, which UIKit only
                // answers for on the main thread.
                let size = iconSize
                let radius = iconCornerRadius
                let scale = FlekTheme.screen.scale
                iconLoadTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    let rounded = LCSpringboardIconCell.roundedImage(image, size: size, radius: radius, scale: scale)
                    DispatchQueue.main.async {
                        self?.iconImageView.image = rounded
                    }
                }
                iconLoadTask?.resume()
            }
        } else if state.iconURL == nil && loadingIconURL != nil {
            // URL was removed — clear the icon
            loadingIconURL = nil
            iconLoadTask?.cancel()
            iconLoadTask = nil
            iconImageView.image = nil
        }

        // Show overlay
        installOverlay.isHidden = false

        if state.failed {
            // Failed install — hide all progress indicators, show the warning mark.
            failedSymbol.isHidden = false
            spinnerRingView.isHidden = true
            stopSpinnerAnimation()
            percentHostView?.isHidden = true
            progressTrack.isHidden = true
            ringTrackLayer.isHidden = true
            ringFillLayer.isHidden = true
            currentFraction = 0
            return
        }
        failedSymbol.isHidden = true

        if state.indeterminate {
            // Indeterminate: show spinning ring, hide everything else
            spinnerRingView.isHidden = false
            startSpinnerAnimation()
            percentHostView?.isHidden = true
            progressTrack.isHidden = true
            ringTrackLayer.isHidden = true
            ringFillLayer.isHidden = true
            currentFraction = 0
        } else if state.isInstalling {
            // Install phase: show circular ring
            spinnerRingView.isHidden = true
            stopSpinnerAnimation()
            percentHostView?.isHidden = true
            progressTrack.isHidden = true
            ringTrackLayer.isHidden = false
            ringFillLayer.isHidden = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ringFillLayer.strokeEnd = max(0.02, state.installFraction)
            CATransaction.commit()
            currentFraction = state.fraction
        } else {
            // Download phase: show percentage + progress bar
            spinnerRingView.isHidden = true
            stopSpinnerAnimation()
            let percent = percentHost()
            percent.view.isHidden = false
            percent.rootView = PercentageText(percent: Int((state.fraction * 100).rounded()))
            progressTrack.isHidden = false
            ringTrackLayer.isHidden = true
            ringFillLayer.isHidden = true
            currentFraction = state.fraction
            updateProgressFillWidth()
        }
    }

    /// The percentage view, made on first use, below the progress bar where it
    /// has always stood.
    private func percentHost() -> UIHostingController<PercentageText> {
        if let percentHostingController { return percentHostingController }
        let hostingVC = UIHostingController(rootView: PercentageText(percent: 0))
        hostingVC.view.backgroundColor = .clear
        installOverlay.insertSubview(hostingVC.view, belowSubview: progressTrack)
        percentHostingController = hostingVC
        setNeedsLayout()
        return hostingVC
    }

    private func updateProgressFillWidth() {
        let trackW = progressTrack.bounds.width
        let trackH = progressTrack.bounds.height
        guard trackW > 0 else { return }
        let fillW = max(trackH - 4, (trackW - 4) * currentFraction)
        progressFill.frame = CGRect(x: 2, y: 2, width: fillW, height: trackH - 4)
        progressFill.layer.cornerRadius = (trackH - 4) / 2
    }

    private static let spinnerAnimationKey = "spinnerRotation"

    private func startSpinnerAnimation() {
        guard spinnerFillLayer.animation(forKey: Self.spinnerAnimationKey) == nil else { return }
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = CGFloat.pi * 2
        anim.duration = 1.0
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        spinnerFillLayer.add(anim, forKey: Self.spinnerAnimationKey)
    }

    private func stopSpinnerAnimation() {
        spinnerFillLayer.removeAnimation(forKey: Self.spinnerAnimationKey)
    }

    // MARK: - Edit mode

    func setDeleteButtonVisible(_ visible: Bool, animated: Bool = true) {
        if visible {
            let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            deleteButton.setImage(
                UIImage(systemName: "minus", withConfiguration: config),
                for: .normal
            )
            deleteButton.isHidden = false
            if animated {
                UIView.animate(withDuration: 0.25) {
                    self.deleteButton.alpha = 1
                    self.jitBadge.alpha = 0
                }
            } else {
                deleteButton.alpha = 1
                jitBadge.alpha = 0
            }
        } else {
            if animated {
                UIView.animate(withDuration: 0.25, animations: {
                    self.deleteButton.alpha = 0
                    self.jitBadge.alpha = 1
                }, completion: { _ in
                    self.deleteButton.isHidden = true
                })
            } else {
                deleteButton.alpha = 0
                deleteButton.isHidden = true
                jitBadge.alpha = 1
            }
        }
    }

    // MARK: - Jiggle animation (from jSpringBoard)

    func startJiggle(force: Bool = false) {
        guard !isAnimating || force else { return }
        isAnimating = true

        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.values = [
            CGPoint(x: -1, y: -1),
            CGPoint(x: 0, y: 0),
            CGPoint(x: -1, y: 0),
            CGPoint(x: 0, y: -1),
            CGPoint(x: -1, y: -1)
        ]
        posAnim.calculationMode = .linear
        posAnim.isAdditive = true

        let rotAnim = CAKeyframeAnimation(keyPath: "transform")
        rotAnim.valueFunction = CAValueFunction(name: .rotateZ)
        rotAnim.values = [-0.03525565, 0.03525565, -0.03525565]
        rotAnim.calculationMode = .linear
        rotAnim.isAdditive = true

        let group = CAAnimationGroup()
        group.duration = 0.25
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        // jSpringBoard: small absolute time (far in the past) makes CA start
        // instantly at a random phase offset.
        group.beginTime = Double.random(in: 0...0.25)
        group.animations = [posAnim, rotAnim]

        contentView.layer.add(group, forKey: "jitterAnimation")
    }

    func stopJiggle() {
        isAnimating = false
        contentView.layer.removeAllAnimations()
        contentView.transform = .identity
    }

    // MARK: - Custom snapshot (mirrors jSpringBoard's HomeItemCell.snapshotView())

    /// Creates a snapshot by individually snapshotting each subview and
    /// reconstructing them in a custom container. This avoids the dark/black
    /// artefact that `UIView.snapshotView(afterScreenUpdates:)` produces
    /// when capturing `UIVisualEffectView` blur/glass backgrounds.
    func dragSnapshotView() -> LCIconCellSnapshotView {
        let container = LCIconCellSnapshotView(frame: bounds)
        container.clipsToBounds = false

        // 1. Card background — recreate instead of snapshotting
        // (UIVisualEffectView snapshots are unreliable, especially UIGlassEffect)
        if let glass = glassBackgroundView {
            let bgCopy: UIVisualEffectView
            if #available(iOS 26, *) {
                bgCopy = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            } else {
                bgCopy = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
                let tint = UIView()
                tint.backgroundColor = UIColor.label.withAlphaComponent(0.15)
                tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                bgCopy.contentView.addSubview(tint)
                bgCopy.layer.borderWidth = 0.5
                bgCopy.layer.borderColor = UIColor.label.withAlphaComponent(0.15).cgColor
            }
            bgCopy.frame = glass.frame
            bgCopy.layer.cornerRadius = Self.cardCorner
            bgCopy.layer.cornerCurve = .continuous
            bgCopy.clipsToBounds = true
            container.addSubview(bgCopy)
        }

        // 2. Icon
        if let snap = iconImageView.snapshotView(afterScreenUpdates: true) {
            snap.frame = iconImageView.frame
            container.addSubview(snap)
        }

        // 3. Notification badge, over the icon's corner
        if !notificationBadge.isHidden,
           let snap = notificationBadge.snapshotView(afterScreenUpdates: true) {
            snap.frame = notificationBadge.frame
            container.addSubview(snap)
        }

        // 4. Name label
        if let snap = nameLabel.snapshotView(afterScreenUpdates: true) {
            snap.frame = nameLabel.frame
            container.addSubview(snap)
        }

        // 5. Delete button — capture with identity transform, then restore
        let originalTransform = deleteButton.transform
        deleteButton.transform = .identity
        if let snap = deleteButton.snapshotView(afterScreenUpdates: true) {
            snap.frame = deleteButton.frame
            snap.transform = originalTransform
            snap.alpha = deleteButton.alpha
            snap.isHidden = deleteButton.isHidden
            container.addSubview(snap)
            container.deleteButtonSnapshot = snap
        }
        deleteButton.transform = originalTransform

        return container
    }

    // MARK: - Actions

    @objc private func deleteTapped() {
        onDeleteTap?()
    }

    @objc private func cellTapped() {
        onTap?()
    }
}

// MARK: - Snapshot container (mirrors jSpringBoard's HomeItemCellSnapshotView)

final class LCIconCellSnapshotView: UIView {
    /// Reference to the delete button snapshot for animate-in during drag.
    var deleteButtonSnapshot: UIView?
}
// MARK: - SwiftUI percentage text with numeric content transition

/// Lightweight SwiftUI view showing a download percentage with
/// `.contentTransition(.numericText())` for smooth digit animations.
private struct PercentageText: View {
    let percent: Int

    private static let font = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
    private static let fixedWidth = "100%".size(withAttributes: [.font: font]).width

    var body: some View {
        // Both branches erased to AnyView so the conditional's type is
        // _ConditionalContent<AnyView, AnyView>. `contentTransition` is iOS 16+,
        // and leaving it in the static type traps on iOS 15, where the runtime
        // resolves that type before the availability check runs.
        Group {
            if #available(iOS 16.0, *) {
                AnyView(
                    Text("\(percent)%")
                        .contentTransition(.numericText())
                        .animation(.default, value: percent)
                )
            } else {
                AnyView(Text("\(percent)%"))
            }
        }
        .font(.system(size: 18, weight: .bold).monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: Self.fixedWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

