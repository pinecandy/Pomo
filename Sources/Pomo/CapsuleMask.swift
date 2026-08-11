import AppKit

/// Rasterizes the pill's capsule shape as an `NSImage` for use as the
/// `NSVisualEffectView.maskImage`.
///
/// The VEV cannot be clipped by SwiftUI — a `clipShape` on it freezes the blur
/// — so its corners come from this native circular mask instead.
enum CapsuleMask {
    /// A capsule mask for a glass rect of `size`. `capInsets` + `.stretch` let
    /// AppKit resize the image without distorting the corners.
    static func image(size: NSSize) -> NSImage {
        let radius = size.height * Tokens.Decor.cornerFactor
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius,
                                       bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
