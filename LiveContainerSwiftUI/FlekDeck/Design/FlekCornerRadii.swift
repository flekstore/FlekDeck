//
//  FlekCornerRadii.swift
//  LiveContainerSwiftUI
//
//  A window shaped like the display it is on, corner by corner.
//
//  Most displays round their four corners alike, and the one radius the system
//  gives for a screen says all there is to say. The iPhone Duo's cover display
//  doesn't: its two corners on the hinge side are far tighter than the other two,
//  so a window cut to a single radius on the move is cut wrong at half its corners.
//

import UIKit

/// A rounded rectangle's radius at each of its corners, as the interface is turned.
struct FlekCornerRadii: Equatable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    static func uniform(_ radius: CGFloat) -> FlekCornerRadii {
        FlekCornerRadii(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    /// Each corner put through `transform`.
    func map(_ transform: (CGFloat) -> CGFloat) -> FlekCornerRadii {
        FlekCornerRadii(topLeft: transform(topLeft), topRight: transform(topRight),
                        bottomLeft: transform(bottomLeft), bottomRight: transform(bottomRight))
    }

    /// The corners in the layer's own terms, which on iOS run downwards: its
    /// minimum Y is the top.
    private var corners: [(mask: CACornerMask, radius: CGFloat)] {
        [(.layerMinXMinYCorner, topLeft), (.layerMaxXMinYCorner, topRight),
         (.layerMinXMaxYCorner, bottomLeft), (.layerMaxXMaxYCorner, bottomRight)]
    }

    /// The corners gathered by the radius each starts at and ends at, going from
    /// `start` to `end`: a layer can round any of its corners, but all of them to
    /// the one radius. A screen rounded alike all round, going to an icon rounded
    /// alike, is a single group.
    static func groups(from start: FlekCornerRadii, to end: FlekCornerRadii)
        -> [(corners: CACornerMask, from: CGFloat, to: CGFloat)] {
        var groups: [(corners: CACornerMask, from: CGFloat, to: CGFloat)] = []
        for (corner, finish) in zip(start.corners, end.corners) {
            if let index = groups.firstIndex(where: { $0.from == corner.radius && $0.to == finish.radius }) {
                groups[index].corners.insert(corner.mask)
            } else {
                groups.append((corner.mask, corner.radius, finish.radius))
            }
        }
        return groups
    }

    /// The layers that cut something to these radii, a corner at a time: one per
    /// group of corners rounded alike, each rounding only those, and each the mask
    /// of the one before it. What is left is what all of them leave — every corner
    /// at its own radius, on the curve the display's own corners follow — and the
    /// first is the one to use as the mask. Each fills the one before, which is the
    /// size given, so they stay in step for whoever changes that size.
    static func cut(size: CGSize, from start: FlekCornerRadii, to end: FlekCornerRadii) -> [(layer: CALayer, from: CGFloat, to: CGFloat)] {
        let layers = groups(from: start, to: end).map { group -> (layer: CALayer, from: CGFloat, to: CGFloat) in
            let layer = CALayer()
            layer.backgroundColor = UIColor.black.cgColor
            layer.cornerCurve = .continuous
            layer.maskedCorners = group.corners
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            layer.cornerRadius = group.to
            return (layer, group.from, group.to)
        }
        for (outer, inner) in zip(layers, layers.dropFirst()) {
            outer.layer.mask = inner.layer
        }
        return layers
    }
}

extension FlekDeviceModel {
    /// The radius at each corner of `screen`, as the interface is turned now, for
    /// a display FlekDeck knows the corners of; nil for any other, which the
    /// screen's own single radius describes.
    ///
    /// The iPhone Duo's two displays, as Apple's own profile of the device has
    /// them (its simulator's: `cornerRadiusUL` and so on). The system gives an app
    /// no corner but the one. The cover display, held upright, is 8pt at its two
    /// corners on the left, the hinge side, and 59pt at the two on the right; the
    /// inner display is 55pt all round.
    static func displayCornerRadii(of screen: UIScreen) -> FlekCornerRadii? {
        switch duoDisplay(of: screen) {
        case nil: return nil
        case .inner: return .uniform(55)
        case .cover: break
        }
        let upright = screen.fixedCoordinateSpace
        let size = upright.bounds.size
        let uprightCorners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 0, y: 0), 8),
            (CGPoint(x: size.width, y: 0), 59),
            (CGPoint(x: 0, y: size.height), 8),
            (CGPoint(x: size.width, y: size.height), 59),
        ]
        // Each corner wherever the interface, turned as it is now, has it.
        let current = screen.coordinateSpace
        let middle = CGPoint(x: current.bounds.midX, y: current.bounds.midY)
        var radii = FlekCornerRadii.uniform(0)
        for (corner, radius) in uprightCorners {
            let point = upright.convert(corner, to: current)
            switch (point.y < middle.y, point.x < middle.x) {
            case (true, true):   radii.topLeft = radius
            case (true, false):  radii.topRight = radius
            case (false, true):  radii.bottomLeft = radius
            case (false, false): radii.bottomRight = radius
            }
        }
        return radii
    }
}
