//
//  SystemGlassBackground.swift
//  WidgetExtension
//
//  Has the home screen draw its own Liquid Glass behind the widget, in every
//  appearance. iOS keeps that choice on the widget's descriptor
//  (CHSBaseDescriptor's preferredBackgroundStyle) and lets only WidgetKit's
//  private configuration modifier set it:
//    0  opaque: the usual solid background.
//    1  transparent: plain clear glass, gone altogether while editing.
//    2  the system's own background, Liquid Glass from iOS 26, which bends
//       the wallpaper behind it like the dock does.
//  The descriptors are encoded in this process before they go to the system,
//  so the style is set on each one as it is encoded. The widget then leaves
//  its own background clear (AppsWidgetView), or it would cover the glass.
//

import Foundation
import ObjectiveC

enum SystemGlassBackground {
    /// CHSBaseDescriptor's value for the system's own (glass) background.
    private static let systemBackgroundStyle = 2

    /// Whether the hook is in place; read once, so it is installed once.
    static let isInstalled: Bool = install()

    private static func install() -> Bool {
        guard let baseClass = NSClassFromString("CHSBaseDescriptor"),
              let widgetClass = NSClassFromString("CHSWidgetDescriptor"),
              let ivar = class_getInstanceVariable(baseClass, "_preferredBackgroundStyle"),
              let encode = class_getInstanceMethod(widgetClass, NSSelectorFromString("encodeWithCoder:")) else {
            return false
        }
        // The ivar is an NSInteger (type encoding "q").
        guard let type = ivar_getTypeEncoding(ivar), String(cString: type) == "q" else {
            return false
        }
        let offset = ivar_getOffset(ivar)
        let selector = method_getName(encode)

        typealias Encode = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let original = unsafeBitCast(method_getImplementation(encode), to: Encode.self)
        let replacement: @convention(block) (AnyObject, NSCoder) -> Void = { descriptor, coder in
            let storage = Unmanaged.passUnretained(descriptor).toOpaque().advanced(by: offset)
            storage.assumingMemoryBound(to: Int.self).pointee = systemBackgroundStyle
            original(descriptor, selector, coder)
        }
        method_setImplementation(encode, imp_implementationWithBlock(replacement))
        return true
    }
}
