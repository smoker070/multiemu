import Foundation
import MultiemuSupport
import Testing
@testable import MultiemuDBus

/// Guards the one D-Bus path where performance is a product requirement:
/// decoding a full framebuffer out of a `Scanout` message.
///
/// At 1280×800×4 this is a 4 MiB byte array arriving up to 60 times a second.
/// A representation that allocates per byte cannot meet that, so the cost is
/// measured rather than assumed.
@Suite("D-Bus framebuffer decoding")
struct DBusFramePerformanceTests {

    static let width = 1280, height = 800
    static var frameBytes: Int { width * height * 4 }

    private func makeScanoutMessage() throws -> [UInt8] {
        let pixels = [UInt8](repeating: 0xA5, count: Self.frameBytes)
        let message = DBusMessage(
            kind: .methodCall, serial: 1,
            path: "/org/qemu/Display1/Listener",
            interface: "org.qemu.Display1.Listener",
            member: "Scanout",
            body: [
                .uint32(UInt32(Self.width)), .uint32(UInt32(Self.height)),
                .uint32(UInt32(Self.width * 4)), .uint32(0x2002_0888),
                .byteArray(pixels),
            ]
        )
        return try message.encoded()
    }

    @Test("A 4 MiB Scanout decodes fast enough for a 60 fps pipeline")
    func decodeCost() throws {
        let bytes = try makeScanoutMessage()
        // Warm up, so the first-call cost of any lazy initialisation is excluded.
        _ = try DBusMessage.decode(bytes)

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            let decoded = try DBusMessage.decode(bytes)
            samples.append((clock.now - start).milliseconds)
            #expect(decoded.body.last?.byteArrayValue?.count == Self.frameBytes)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("  Scanout decode: median \(String(format: "%.2f", median)) ms for \(Self.frameBytes / 1_048_576) MiB "
              + "(\(String(format: "%.0f", 1000 / median)) fps ceiling)")

        // 16.7 ms is one frame at 60 fps, and decoding must be a small part of
        // that budget, not all of it.
        #expect(median < 8.0, "decoding one frame took \(median) ms, which cannot sustain 60 fps")
    }

    @Test("Encoding a Scanout is also within budget")
    func encodeCost() throws {
        let pixels = [UInt8](repeating: 0x5A, count: Self.frameBytes)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            let message = DBusMessage(
                kind: .methodCall, serial: 1,
                path: "/p", interface: "i", member: "Scanout",
                body: [.uint32(1), .byteArray(pixels)]
            )
            _ = try message.encoded()
            samples.append((clock.now - start).milliseconds)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("  Scanout encode: median \(String(format: "%.2f", median)) ms")
        #expect(median < 12.0)
    }

    @Test("Byte arrays survive a full round trip unchanged")
    func fidelity() throws {
        let pixels = (0..<(64 * 64 * 4)).map { UInt8($0 & 0xFF) }
        let message = DBusMessage(
            kind: .methodCall, serial: 2,
            path: "/p", interface: "i", member: "Scanout",
            body: [.byteArray(pixels)]
        )
        let decoded = try DBusMessage.decode(try message.encoded())
        #expect(decoded.body.first?.byteArrayValue == pixels)
    }
}
