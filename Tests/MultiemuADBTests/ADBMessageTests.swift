import Foundation
import Testing
@testable import MultiemuADB

@Suite("ADB wire messages")
struct ADBMessageTests {

    @Test("A message survives a round trip through the wire form")
    func roundTrip() throws {
        let payload = Data("shell:id\0".utf8)
        let message = ADBMessage(.open, arg0: 1, arg1: 0, payload: payload)
        let encoded = message.encoded

        #expect(encoded.count == ADBMessage.headerSize + payload.count)
        let header = try ADBMessage.decodeHeader(encoded)
        #expect(header.command == ADBMessage.Command.open.code)
        #expect(header.arg0 == 1)
        #expect(header.payloadLength == payload.count)
        try ADBMessage.verify(payload: payload, against: header,
                              negotiatedVersion: ADBMessage.Version.minimum)
    }

    @Test("Command codes are little-endian, which is the direction easy to get backwards")
    func commandEncoding() {
        // "CNXN" -> 'C' in the low byte.
        #expect(ADBMessage.code(for: "CNXN") == 0x4E58_4E43)
        #expect(ADBMessage.name(of: 0x4E58_4E43) == "CNXN")
        for command in ADBMessage.Command.allCases {
            #expect(ADBMessage.name(of: command.code) == command.rawValue)
        }
    }

    @Test("An unprintable command is reported as hex rather than mojibake")
    func unprintableCommandName() {
        #expect(ADBMessage.name(of: 0x0000_0001) == "0x00000001")
    }

    @Test("A header whose magic does not match its command is refused")
    func magicMismatchIsRefused() {
        var encoded = ADBMessage(.okay).encoded
        // Corrupt the magic word, leaving everything else valid.
        encoded[20] ^= 0xFF
        #expect(throws: ADBMessage.Failure.self) {
            try ADBMessage.decodeHeader(encoded)
        }
    }

    @Test("A header shorter than 24 bytes is refused rather than read past")
    func shortHeaderIsRefused() {
        #expect(throws: ADBMessage.Failure.self) {
            try ADBMessage.decodeHeader(Data(repeating: 0, count: 23))
        }
    }

    @Test("A payload length beyond the announced maximum is refused")
    func oversizedPayloadIsRefused() throws {
        // Build a header by hand claiming a payload far larger than the limit.
        // The guest is a security boundary: a length field is a claim, and
        // believing it would let a guest make this client allocate at will.
        var data = Data()
        let command = ADBMessage.Command.write.code
        let words: [UInt32] = [command, 1, 1, UInt32(ADBMessage.maximumPayload + 1), 0,
                               command ^ 0xFFFF_FFFF]
        for word in words {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        #expect(throws: ADBMessage.Failure.self) { try ADBMessage.decodeHeader(data) }
    }

    @Test("A payload that does not match its checksum is refused")
    func checksumMismatchIsRefused() throws {
        let message = ADBMessage(.write, payload: Data("hello".utf8))
        let header = try ADBMessage.decodeHeader(message.encoded)
        #expect(throws: ADBMessage.Failure.self) {
            try ADBMessage.verify(payload: Data("hellp".utf8), against: header,
                                  negotiatedVersion: ADBMessage.Version.minimum)
        }
    }

    @Test("The checksum wraps rather than trapping on a large payload")
    func checksumWraps() {
        // 0xFF repeated enough times to pass 2^32 if it were not wrapping.
        // A trapping add here would crash the client on a big transfer, which
        // is exactly when it matters.
        let payload = Data(repeating: 0xFF, count: 200_000)
        let expected = UInt32(truncatingIfNeeded: 0xFF * 200_000)
        #expect(ADBMessage.checksum(of: payload) == expected)
    }

    @Test("A zero checksum is accepted once the negotiated version drops it")
    func checksumIsNotCheckedAtTheSkipVersion() throws {
        // The failure this encodes was found against a real guest, not in
        // review: adbd answered CNXN with a correct banner and a zero checksum,
        // and a client that verified unconditionally called it corruption.
        let message = ADBMessage(.connect, payload: Data("device::ro.product.name=x".utf8))
        var encoded = message.encoded
        for offset in 16..<20 { encoded[offset] = 0 }
        let header = try ADBMessage.decodeHeader(encoded)

        try ADBMessage.verify(payload: message.payload, against: header,
                              negotiatedVersion: ADBMessage.Version.skipsChecksums)
        #expect(throws: ADBMessage.Failure.self) {
            try ADBMessage.verify(payload: message.payload, against: header,
                                  negotiatedVersion: ADBMessage.Version.minimum)
        }
    }

    @Test("An empty payload has a zero checksum and a zero length")
    func emptyPayload() throws {
        let header = try ADBMessage.decodeHeader(ADBMessage(.okay, arg0: 1, arg1: 7).encoded)
        #expect(header.payloadLength == 0)
        #expect(header.payloadChecksum == 0)
        try ADBMessage.verify(payload: Data(), against: header,
                              negotiatedVersion: ADBMessage.Version.minimum)
    }
}
