import Foundation
import Testing
@testable import MultiemuGuestServices

@Suite("qemud framing")
struct QemudFrameTests {

    private func frame(type: UInt32 = 0, _ payload: String) -> Data {
        QemudFrame.encode(type: type, payload: Data(payload.utf8))
    }

    /// A header with a length word this process never wrote, which is the
    /// shape of every interesting case here: the guest chooses that number.
    private func forgedHeader(type: UInt32 = 0, declaredLength: UInt32) -> Data {
        var data = Data()
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: declaredLength.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    // MARK: Encoding

    @Test("A frame is a little-endian type, a little-endian length, then the payload")
    func encodingMatchesTheWire() {
        let encoded = frame("list-sensors")
        // Byte-for-byte what a booting guest was observed to send.
        #expect(Array(encoded.prefix(8)) == [0, 0, 0, 0, 12, 0, 0, 0])
        #expect(encoded.dropFirst(8) == Data("list-sensors".utf8))
        #expect(encoded.count == 20)
    }

    @Test("An empty payload still carries a header")
    func emptyPayloadEncodes() {
        let encoded = QemudFrame.encode(type: 7, payload: Data())
        #expect(encoded.count == 8)
        #expect(Array(encoded) == [7, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: Decoding

    @Test("A whole frame decodes to its type and payload")
    func decodesOneFrame() throws {
        var decoder = QemudDecoder()
        let messages = try decoder.ingest(frame(type: 3, "list-sensors"))
        #expect(messages.count == 1)
        #expect(messages[0].type == 3)
        #expect(messages[0].command == "list-sensors")
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Several frames in one read all come out, in order")
    func decodesSeveralFrames() throws {
        var decoder = QemudDecoder()
        let messages = try decoder.ingest(frame("list-sensors") + frame("time:12") + frame("set-delay:200"))
        #expect(messages.map(\.command) == ["list-sensors", "time:12", "set-delay:200"])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A frame split across reads is reassembled, byte by byte if need be")
    func reassemblesSplitFrame() throws {
        var decoder = QemudDecoder()
        let whole = frame("list-sensors")

        // One byte at a time is the worst case a stream socket can produce.
        for index in 0..<(whole.count - 1) {
            let produced = try decoder.ingest(whole.subdata(in: index..<(index + 1)))
            #expect(produced.isEmpty, "nothing is complete until the last byte")
        }
        let finished = try decoder.ingest(whole.suffix(1))
        #expect(finished.map(\.command) == ["list-sensors"])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A header split from its body is held, not misread")
    func holdsHeaderWithoutBody() throws {
        var decoder = QemudDecoder()
        #expect(try decoder.ingest(frame("list-sensors").prefix(8)).isEmpty)
        #expect(decoder.bufferedByteCount == 8)
        let rest = try decoder.ingest(frame("list-sensors").dropFirst(8))
        #expect(rest.map(\.command) == ["list-sensors"])
    }

    @Test("Trailing bytes of the next frame are kept for it")
    func keepsPartialTail() throws {
        var decoder = QemudDecoder()
        let messages = try decoder.ingest(frame("time:1") + frame("list-sensors").prefix(10))
        #expect(messages.map(\.command) == ["time:1"])
        #expect(decoder.bufferedByteCount == 10)
    }

    // MARK: Refusing what the guest declares

    @Test("A length larger than the cap is refused instead of allocated")
    func refusesOversizedLength() {
        var decoder = QemudDecoder()
        let header = forgedHeader(declaredLength: UInt32(QemudFrame.maximumPayloadBytes + 1))
        #expect(throws: QemudFrame.Failure.self) {
            _ = try decoder.ingest(header)
        }
    }

    @Test("A length near UInt32.max is refused, and does not wrap on the way")
    func refusesEnormousLength() {
        var decoder = QemudDecoder()
        // The case that matters: 4 GiB-ish declared, 8 bytes actually sent.
        let header = forgedHeader(declaredLength: UInt32.max)
        #expect(throws: QemudFrame.Failure.self) {
            _ = try decoder.ingest(header)
        }
    }

    @Test("A payload exactly at the cap is still accepted")
    func acceptsPayloadAtTheCap() throws {
        var decoder = QemudDecoder()
        let payload = Data(repeating: 0x41, count: QemudFrame.maximumPayloadBytes)
        let messages = try decoder.ingest(QemudFrame.encode(type: 0, payload: payload))
        #expect(messages.count == 1)
        #expect(messages[0].payload.count == QemudFrame.maximumPayloadBytes)
    }

    @Test("A guest that dribbles a frame it never finishes cannot grow the buffer without bound")
    func heldBytesStayBounded() throws {
        var decoder = QemudDecoder()

        // A header declaring the largest legal payload, then a body that stops
        // one byte short forever. This is the shape that would grow without
        // bound if the payload cap were not enforced before the length is used.
        let header = forgedHeader(declaredLength: UInt32(QemudFrame.maximumPayloadBytes))
        _ = try decoder.ingest(header)

        var sent = 0
        while sent < QemudFrame.maximumPayloadBytes - 1 {
            let chunk = min(4096, QemudFrame.maximumPayloadBytes - 1 - sent)
            let produced = try decoder.ingest(Data(repeating: 0, count: chunk))
            #expect(produced.isEmpty, "the frame is never complete")
            sent += chunk
            #expect(decoder.bufferedByteCount <= QemudFrame.maximumBufferedBytes)
        }
        // Held, bounded, and still nothing emitted.
        #expect(decoder.bufferedByteCount == QemudFrame.headerBytes + sent)
        #expect(decoder.bufferedByteCount < QemudFrame.maximumBufferedBytes)
    }

    @Test("A run of maximum-size frames is drained rather than accumulated")
    func backToBackMaximumFramesDoNotAccumulate() throws {
        var decoder = QemudDecoder()
        let payload = Data(repeating: 0x42, count: QemudFrame.maximumPayloadBytes)
        let frame = QemudFrame.encode(type: 0, payload: payload)

        // Delivered the way the responder actually reads: 4 KiB at a time. The
        // earlier version checked its cap against arriving bytes rather than
        // held bytes and rejected this — legal frames it advertises as legal.
        for round in 0..<3 {
            var offset = 0
            var produced: [QemudFrame.Message] = []
            while offset < frame.count {
                let end = min(offset + 4096, frame.count)
                produced += try decoder.ingest(frame.subdata(in: offset..<end))
                offset = end
                #expect(decoder.bufferedByteCount <= QemudFrame.maximumBufferedBytes)
            }
            #expect(produced.count == 1, "round \(round) should yield exactly one frame")
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A maximum-size frame with the next frame pipelined behind it is still accepted")
    func maximumFrameWithTrailingBytesIsAccepted() throws {
        var decoder = QemudDecoder()
        let big = QemudFrame.encode(type: 0, payload: Data(repeating: 1, count: QemudFrame.maximumPayloadBytes))
        let messages = try decoder.ingest(big + frame("list-sensors"))
        #expect(messages.count == 2)
        #expect(messages[1].command == "list-sensors")
    }

    // MARK: Payloads that are not text

    @Test("A payload that is not UTF-8 decodes as a message with no command")
    func nonUTF8PayloadHasNoCommand() throws {
        var decoder = QemudDecoder()
        let payload = Data([0xFF, 0xFE, 0xFD])
        let messages = try decoder.ingest(QemudFrame.encode(type: 0, payload: payload))
        #expect(messages.count == 1)
        #expect(messages[0].command == nil, "invalid UTF-8 must not be silently repaired")
        #expect(messages[0].payload == payload)
    }

    @Test("A payload containing NUL is carried through without truncation")
    func nulInPayloadIsNotATerminator() throws {
        var decoder = QemudDecoder()
        let payload = Data("list\u{0}-sensors".utf8)
        let messages = try decoder.ingest(QemudFrame.encode(type: 0, payload: payload))
        #expect(messages[0].payload.count == payload.count)
    }
}
