import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// multiemu-icon — generates Multiemu's application icon.
//
// The artwork is drawn in code rather than shipped as an asset: it is original
// to this project, it scales exactly at every size macOS asks for, and it stays
// reproducible from source, which matters for the signed release in M21.
//
// The mark is two offset rounded rectangles on a gradient field — abstract
// devices, suggesting more than one. It deliberately resembles no other
// emulator's branding and uses no third-party imagery.
//
//   multiemu-icon <output.iconset>

setvbuf(stdout, nil, _IONBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: multiemu-icon <output.iconset>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Colour stops, in the order they appear from top to bottom.
let backgroundTop = CGColor(red: 0.16, green: 0.18, blue: 0.35, alpha: 1)
let backgroundBottom = CGColor(red: 0.05, green: 0.34, blue: 0.42, alpha: 1)
let farDevice = CGColor(red: 1, green: 1, blue: 1, alpha: 0.30)
let nearDeviceTop = CGColor(red: 0.42, green: 0.92, blue: 0.86, alpha: 1)
let nearDeviceBottom = CGColor(red: 0.30, green: 0.72, blue: 0.95, alpha: 1)

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icons sit inside a rounded square with a margin around it.
    let inset = size * 0.09
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = plate.width * 0.225

    context.saveGState()
    context.addPath(roundedRectPath(plate, radius: plateRadius))
    context.clip()
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [backgroundTop, backgroundBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // Two offset device shapes. The rear one is translucent so it reads as
    // depth rather than as a second solid object.
    let deviceWidth = plate.width * 0.30
    let deviceHeight = plate.height * 0.50
    let deviceRadius = deviceWidth * 0.28
    let centre = CGPoint(x: plate.midX, y: plate.midY)

    let rear = CGRect(
        x: centre.x - deviceWidth * 0.95, y: centre.y - deviceHeight * 0.42,
        width: deviceWidth, height: deviceHeight
    )
    context.addPath(roundedRectPath(rear, radius: deviceRadius))
    context.setFillColor(farDevice)
    context.fillPath()

    let front = CGRect(
        x: centre.x - deviceWidth * 0.05, y: centre.y - deviceHeight * 0.58,
        width: deviceWidth, height: deviceHeight
    )
    context.saveGState()
    context.addPath(roundedRectPath(front, radius: deviceRadius))
    context.clip()
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [nearDeviceTop, nearDeviceBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: front.midX, y: front.maxY),
            end: CGPoint(x: front.midX, y: front.minY),
            options: []
        )
    }
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// The sizes `iconutil` expects in an iconset.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.pixels) else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
