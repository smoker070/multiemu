import CoreGraphics
import Foundation
import ImageIO
import MultiemuSupport
import UniformTypeIdentifiers

/// A pixman format code, as QEMU reports it on the wire.
///
/// The code packs the layout rather than enumerating it:
/// `(bpp << 24) | (type << 16) | (a << 12) | (r << 8) | (g << 4) | b`,
/// where each component nibble is that channel's **bit width**. Decoding the
/// fields is more robust than matching whole constants, because an unfamiliar
/// code still yields usable depth and channel information.
public struct PixmanFormat: Sendable, Equatable, CustomStringConvertible {

    /// pixman's `PIXMAN_TYPE_ARGB`.
    public static let typeARGB: UInt32 = 2
    /// pixman's `PIXMAN_TYPE_ABGR`.
    public static let typeABGR: UInt32 = 3

    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var bitsPerPixel: Int { Int((rawValue >> 24) & 0xFF) }
    public var layoutType: UInt32 { (rawValue >> 16) & 0xFF }
    public var alphaBits: Int { Int((rawValue >> 12) & 0xF) }
    public var redBits: Int { Int((rawValue >> 8) & 0xF) }
    public var greenBits: Int { Int((rawValue >> 4) & 0xF) }
    public var blueBits: Int { Int(rawValue & 0xF) }

    public var bytesPerPixel: Int { bitsPerPixel / 8 }
    public var hasAlpha: Bool { alphaBits > 0 }

    /// Whether `GuestFrame` can turn this into an image.
    ///
    /// Only the 32-bit ARGB family is handled, which is what QEMU's virtio-gpu
    /// produces. Anything else is reported rather than silently mis-rendered.
    public var isSupported: Bool {
        bitsPerPixel == 32 && layoutType == Self.typeARGB
            && redBits == 8 && greenBits == 8 && blueBits == 8
    }

    public var description: String {
        let name: String
        switch layoutType {
        case Self.typeARGB: name = hasAlpha ? "a\(alphaBits)r\(redBits)g\(greenBits)b\(blueBits)" : "x8r\(redBits)g\(greenBits)b\(blueBits)"
        case Self.typeABGR: name = hasAlpha ? "a\(alphaBits)b\(blueBits)g\(greenBits)r\(redBits)" : "x8b\(blueBits)g\(greenBits)r\(redBits)"
        default: name = "type\(layoutType)"
        }
        return "\(name) (\(bitsPerPixel)bpp, 0x\(String(rawValue, radix: 16)))"
    }
}

/// One frame of guest display output.
public struct GuestFrame: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Bytes per row, which is **not** necessarily `width * bytesPerPixel`.
    public var stride: Int
    public var format: PixmanFormat
    public var pixels: [UInt8]

    public init(width: Int, height: Int, stride: Int, format: PixmanFormat, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.pixels = pixels
    }

    public var byteCount: Int { pixels.count }

    public enum Failure: Error, CustomStringConvertible {
        case unsupportedFormat(PixmanFormat)
        case sizeMismatch(expected: Int, actual: Int)
        case imageCreationFailed

        public var description: String {
            switch self {
            case let .unsupportedFormat(format):
                return "Guest frame format \(format) is not supported by the image path."
            case let .sizeMismatch(expected, actual):
                return "Guest frame carries \(actual) bytes; the geometry implies \(expected)."
            case .imageCreationFailed:
                return "Could not build an image from the guest frame."
            }
        }
    }

    /// Builds a `CGImage`.
    ///
    /// QEMU's 32-bit ARGB is little-endian in memory, i.e. B,G,R,A byte order,
    /// which is exactly `byteOrder32Little` plus an alpha-first component order.
    /// `noneSkipFirst` is used when the format has no alpha, so an `x8` channel
    /// is never interpreted as transparency — that mistake renders a correct
    /// framebuffer as a fully transparent image.
    public func makeImage() throws -> CGImage {
        guard format.isSupported else { throw Failure.unsupportedFormat(format) }
        let required = stride * height
        guard pixels.count >= required else {
            throw Failure.sizeMismatch(expected: required, actual: pixels.count)
        }

        var bitmapInfo = CGBitmapInfo.byteOrder32Little
        bitmapInfo.insert(CGBitmapInfo(rawValue: (format.hasAlpha
            ? CGImageAlphaInfo.premultipliedFirst
            : CGImageAlphaInfo.noneSkipFirst).rawValue))

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: format.bitsPerPixel,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw Failure.imageCreationFailed
        }
        return image
    }

    /// Writes the frame as a PNG.
    public func writePNG(to url: URL) throws {
        let image = try makeImage()
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw Failure.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.imageCreationFailed
        }
    }

    /// Fraction of pixels that are not fully black.
    ///
    /// A cheap sanity check: a frame that decoded correctly but shows nothing is
    /// indistinguishable from a broken pipeline without it.
    public func nonBlackFraction() -> Double {
        guard format.bytesPerPixel == 4, height > 0, width > 0 else { return 0 }
        var lit = 0
        for row in 0..<height {
            let base = row * stride
            for column in 0..<width {
                let offset = base + column * 4
                guard offset + 2 < pixels.count else { continue }
                if pixels[offset] != 0 || pixels[offset + 1] != 0 || pixels[offset + 2] != 0 { lit += 1 }
            }
        }
        return Double(lit) / Double(width * height)
    }
}
