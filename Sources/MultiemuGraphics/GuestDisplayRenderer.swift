import CoreGraphics
import Foundation
import Metal
import MultiemuSupport

/// How the guest's framebuffer is fitted into the destination surface.
///
/// The product requirement is that the guest's logical resolution stays
/// independent of the macOS window size, so the default preserves aspect ratio
/// and letterboxes rather than distorting or cropping.
public enum GuestDisplayScaling: String, Sendable, CaseIterable {
    /// Fit entirely, preserving aspect ratio. Unused area is filled with the
    /// background colour. The default.
    case aspectFit
    /// Fill the surface, preserving aspect ratio, cropping the overflow.
    case aspectFill
    /// Stretch to the surface, ignoring aspect ratio.
    case stretch
    /// Preserve aspect ratio and snap to the largest whole-number scale that
    /// fits, so guest pixels map to an exact block of host pixels.
    case integerScale
}

/// Renders guest frames with Metal.
///
/// Deliberately renders into any `MTLTexture` rather than owning a view or a
/// drawable. The same code path therefore serves the on-screen layer, offscreen
/// screenshot capture, and the headless tests — which is what makes the
/// presentation pipeline verifiable without a window.
public final class GuestDisplayRenderer {

    public enum Failure: Error, CustomStringConvertible {
        case noMetalDevice
        case shaderCompilationFailed(String)
        case pipelineCreationFailed(String)
        case textureCreationFailed(width: Int, height: Int)
        case unsupportedFormat(PixmanFormat)
        case frameTooSmall(expected: Int, actual: Int)

        public var description: String {
            switch self {
            case .noMetalDevice:
                return "No Metal device is available; the display pipeline requires Metal."
            case let .shaderCompilationFailed(detail):
                return "The display shaders failed to compile: \(detail)"
            case let .pipelineCreationFailed(detail):
                return "The display render pipeline could not be created: \(detail)"
            case let .textureCreationFailed(width, height):
                return "Could not allocate a \(width)×\(height) guest display texture."
            case let .unsupportedFormat(format):
                return "Guest frame format \(format) is not supported by the renderer."
            case let .frameTooSmall(expected, actual):
                return "Guest frame carries \(actual) bytes; its geometry implies \(expected)."
            }
        }
    }

    /// Shaders are compiled from source at initialisation rather than shipped as
    /// a precompiled library.
    ///
    /// It costs a few milliseconds once, and it removes a build-system
    /// dependency on `.metallib` generation from a Swift package — which would
    /// otherwise have to work identically for the package, the test bundle and
    /// the application.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // `rect` is the destination quad in normalised device coordinates:
    // (originX, originY, width, height), origin at the bottom-left corner.
    vertex VertexOut guestVertex(uint vertexID [[vertex_id]],
                                 constant float4 &rect [[buffer(0)]]) {
        const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 corner = corners[vertexID];
        VertexOut out;
        out.position = float4(rect.x + corner.x * rect.z,
                              rect.y + corner.y * rect.w,
                              0.0, 1.0);
        // NDC y points up and texture v points down, so v is flipped.
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 guestFragment(VertexOut in [[stage_in]],
                                  texture2d<float> guest [[texture(0)]],
                                  sampler guestSampler [[sampler(0)]]) {
        // Alpha is forced opaque: an x8 padding byte carries no transparency,
        // and treating it as alpha renders a correct framebuffer as invisible.
        return float4(guest.sample(guestSampler, in.uv).rgb, 1.0);
    }
    """

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState

    private var guestTexture: MTLTexture?
    /// Size of the guest framebuffer currently uploaded, in guest pixels.
    public private(set) var guestSize: CGSize = .zero

    /// Colour behind the guest image, used for letterbox bars.
    public var backgroundColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    public init(device: MTLDevice? = nil, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw Failure.noMetalDevice
        }
        self.device = resolved

        guard let queue = resolved.makeCommandQueue() else {
            throw Failure.pipelineCreationFailed("command queue")
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try resolved.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw Failure.shaderCompilationFailed(String(describing: error))
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "guestVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "guestFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            pipelineState = try resolved.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.pipelineCreationFailed(String(describing: error))
        }

        func makeSampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = filter
            sampler.magFilter = filter
            // Clamp, so sampling at the edge never wraps a row of guest pixels
            // around to the opposite side of the image.
            sampler.sAddressMode = .clampToEdge
            sampler.tAddressMode = .clampToEdge
            guard let state = resolved.makeSamplerState(descriptor: sampler) else {
                throw Failure.pipelineCreationFailed("sampler")
            }
            return state
        }
        linearSampler = try makeSampler(.linear)
        nearestSampler = try makeSampler(.nearest)
    }

    // MARK: - Frame upload

    /// Uploads a guest frame into the GPU texture, reallocating only when the
    /// guest's resolution changes.
    public func upload(_ frame: GuestFrame) throws {
        guard frame.format.isSupported else { throw Failure.unsupportedFormat(frame.format) }
        let required = frame.stride * frame.height
        guard frame.pixels.count >= required else {
            throw Failure.frameTooSmall(expected: required, actual: frame.pixels.count)
        }

        if guestTexture == nil || guestTexture?.width != frame.width || guestTexture?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                // QEMU's x8r8g8b8 is little-endian in memory, i.e. B,G,R,X byte
                // order, which is exactly bgra8Unorm.
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw Failure.textureCreationFailed(width: frame.width, height: frame.height)
            }
            guestTexture = texture
            guestSize = CGSize(width: frame.width, height: frame.height)
            MultiemuLog.graphics.info("Guest display texture: \(frame.width, privacy: .public)×\(frame.height, privacy: .public)")
        }

        guestTexture?.replace(
            region: MTLRegionMake2D(0, 0, frame.width, frame.height),
            mipmapLevel: 0,
            withBytes: frame.pixels,
            bytesPerRow: frame.stride
        )
    }

    // MARK: - Drawing

    /// Destination rectangle in normalised device coordinates.
    ///
    /// Pure and separately testable: every scaling rule is decided here, so the
    /// geometry can be checked without a GPU.
    public static func destinationRect(
        guestSize: CGSize,
        surfaceSize: CGSize,
        scaling: GuestDisplayScaling
    ) -> CGRect {
        guard guestSize.width > 0, guestSize.height > 0,
              surfaceSize.width > 0, surfaceSize.height > 0 else {
            return CGRect(x: -1, y: -1, width: 2, height: 2)
        }

        let widthRatio = surfaceSize.width / guestSize.width
        let heightRatio = surfaceSize.height / guestSize.height

        let scale: CGFloat
        switch scaling {
        case .stretch:
            return CGRect(x: -1, y: -1, width: 2, height: 2)
        case .aspectFit:
            scale = min(widthRatio, heightRatio)
        case .aspectFill:
            scale = max(widthRatio, heightRatio)
        case .integerScale:
            // At least 1, so a guest larger than the surface still displays
            // (downscaled) rather than vanishing.
            scale = max(1, floor(min(widthRatio, heightRatio)))
        }

        let drawWidth = guestSize.width * scale
        let drawHeight = guestSize.height * scale
        // Convert a centred pixel rectangle into NDC, where the surface spans
        // -1...1 on both axes.
        let ndcWidth = 2 * drawWidth / surfaceSize.width
        let ndcHeight = 2 * drawHeight / surfaceSize.height
        return CGRect(x: -ndcWidth / 2, y: -ndcHeight / 2, width: ndcWidth, height: ndcHeight)
    }

    /// Renders the uploaded guest frame into `target`.
    ///
    /// `smooth` selects linear filtering. Nearest is correct for integer scaling
    /// and for pixel-accurate capture; linear looks better for arbitrary sizes.
    public func render(
        into target: MTLTexture,
        scaling: GuestDisplayScaling = .aspectFit,
        smooth: Bool = true,
        drawable: (any MTLDrawable)? = nil,
        waitUntilCompleted: Bool = false
    ) {
        guard let guestTexture, let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = backgroundColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let rect = Self.destinationRect(
            guestSize: guestSize,
            surfaceSize: CGSize(width: target.width, height: target.height),
            scaling: scaling
        )
        var ndc = SIMD4<Float>(Float(rect.origin.x), Float(rect.origin.y),
                               Float(rect.size.width), Float(rect.size.height))

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(guestTexture, index: 0)
        encoder.setFragmentSamplerState(
            (smooth && scaling != .integerScale) ? linearSampler : nearestSampler,
            index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
        if waitUntilCompleted { commandBuffer.waitUntilCompleted() }
    }

    /// Renders into a fresh offscreen texture and returns it.
    ///
    /// Used by screenshot capture and by the tests, so both exercise exactly the
    /// code path the on-screen layer uses.
    public func renderOffscreen(
        width: Int,
        height: Int,
        scaling: GuestDisplayScaling = .aspectFit,
        smooth: Bool = true
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureCreationFailed(width: width, height: height)
        }
        render(into: target, scaling: scaling, smooth: smooth, waitUntilCompleted: true)
        return target
    }
}

public extension MTLTexture {
    /// Reads the texture back as a `GuestFrame`, for capture and verification.
    func readBackAsFrame() -> GuestFrame {
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        pixels.withUnsafeMutableBytes { raw in
            getBytes(raw.baseAddress!, bytesPerRow: stride,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return GuestFrame(
            width: width, height: height, stride: stride,
            // Read back as the same x8r8g8b8 the guest produced, so a captured
            // frame and a received frame are directly comparable.
            format: PixmanFormat(rawValue: 0x2002_0888),
            pixels: pixels
        )
    }
}
