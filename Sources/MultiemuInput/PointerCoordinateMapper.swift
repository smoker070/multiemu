import CoreGraphics
import Foundation
import MultiemuGraphics

/// Converts a point in the display view into a guest framebuffer pixel.
///
/// This is the exact inverse of the presentation transform, and it has to be:
/// if a click lands one pixel off, every tap in the guest is wrong in a way that
/// is maddening to diagnose and invisible in a screenshot. Keeping it pure —
/// no view, no GPU, no D-Bus — is what makes it testable against the same
/// geometry the renderer uses.
public enum PointerCoordinateMapper {

    /// Where a view point lands.
    public enum Location: Sendable, Equatable {
        /// Inside the guest image, at this framebuffer pixel.
        case inside(CGPoint)
        /// In the letterbox or pillarbox area, with the nearest guest pixel.
        case outside(nearest: CGPoint)
    }

    /// Maps a point in **view coordinates** to a guest framebuffer pixel.
    ///
    /// - Parameters:
    ///   - viewPoint: point in the view's coordinate space.
    ///   - viewSize: view size in **points**.
    ///   - backingScale: the display's backing scale factor. Included because
    ///     the destination rectangle is computed in pixels; on a 2× display a
    ///     transform done in points is silently half-scale.
    ///   - flipped: `true` when the view's origin is top-left. AppKit views are
    ///     bottom-left by default, which is the opposite of the guest's
    ///     framebuffer, so this conversion is where that gets reconciled.
    public static func locate(
        viewPoint: CGPoint,
        viewSize: CGSize,
        backingScale: CGFloat,
        guestSize: CGSize,
        scaling: GuestDisplayScaling,
        flipped: Bool = false
    ) -> Location {
        guard guestSize.width > 0, guestSize.height > 0,
              viewSize.width > 0, viewSize.height > 0, backingScale > 0 else {
            return .outside(nearest: .zero)
        }

        let surface = CGSize(width: viewSize.width * backingScale,
                             height: viewSize.height * backingScale)
        let ndc = GuestDisplayRenderer.destinationRect(
            guestSize: guestSize, surfaceSize: surface, scaling: scaling
        )

        // Normalised device coordinates -> pixels, top-left origin.
        let imageX = (ndc.origin.x + 1) / 2 * surface.width
        let imageWidth = ndc.size.width / 2 * surface.width
        let imageTop = (1 - (ndc.origin.y + ndc.size.height)) / 2 * surface.height
        let imageHeight = ndc.size.height / 2 * surface.height

        guard imageWidth > 0, imageHeight > 0 else { return .outside(nearest: .zero) }

        let pixelX = viewPoint.x * backingScale
        let pixelY = (flipped ? viewPoint.y : (viewSize.height - viewPoint.y)) * backingScale

        let u = (pixelX - imageX) / imageWidth
        let v = (pixelY - imageTop) / imageHeight

        let guestX = u * guestSize.width
        let guestY = v * guestSize.height

        // The guest's last addressable pixel is width-1, so a click on the
        // right edge must not produce a coordinate one past the framebuffer.
        let clamped = CGPoint(
            x: min(max(guestX, 0), guestSize.width - 1),
            y: min(max(guestY, 0), guestSize.height - 1)
        )

        if (0...1).contains(u) && (0...1).contains(v) {
            return .inside(clamped)
        }
        return .outside(nearest: clamped)
    }

    /// Convenience returning a clamped guest point regardless of location.
    ///
    /// Used for drags: once a drag starts inside the image, leaving it must
    /// keep tracking at the edge rather than dropping events.
    public static func clampedGuestPoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        backingScale: CGFloat,
        guestSize: CGSize,
        scaling: GuestDisplayScaling,
        flipped: Bool = false
    ) -> CGPoint {
        switch locate(viewPoint: viewPoint, viewSize: viewSize, backingScale: backingScale,
                      guestSize: guestSize, scaling: scaling, flipped: flipped) {
        case .inside(let point), .outside(let point): return point
        }
    }
}
