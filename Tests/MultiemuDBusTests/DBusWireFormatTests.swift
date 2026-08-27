import Foundation
import Testing
@testable import MultiemuDBus

@Suite("D-Bus signatures")
struct DBusSignatureTests {

    @Test("Signatures split into complete types")
    func splitting() throws {
        #expect(try DBusSignature.split("") == [])
        #expect(try DBusSignature.split("uuay") == ["u", "u", "ay"])
        #expect(try DBusSignature.split("a(ii)s") == ["a(ii)", "s"])
        #expect(try DBusSignature.split("a{sv}") == ["a{sv}"])
        #expect(try DBusSignature.split("(yv)") == ["(yv)"])
        #expect(try DBusSignature.split("aay") == ["aay"])
        #expect(try DBusSignature.split("huuuuay") == ["h", "u", "u", "u", "u", "ay"])
    }

    @Test("Malformed signatures are rejected")
    func malformed() {
        #expect(throws: DBusSignature.Failure.self) { try DBusSignature.split("(ii") }
        #expect(throws: DBusSignature.Failure.self) { try DBusSignature.split("a") }
        #expect(throws: DBusSignature.Failure.self) { try DBusSignature.split("Z") }
    }

    @Test("Alignments match the specification")
    func alignments() {
        // Getting one of these wrong shifts every subsequent value rather than
        // failing locally, so they are pinned directly.
        #expect(DBusSignature.alignment(of: "y") == 1)
        #expect(DBusSignature.alignment(of: "g") == 1)
        #expect(DBusSignature.alignment(of: "v") == 1)
        #expect(DBusSignature.alignment(of: "q") == 2)
        #expect(DBusSignature.alignment(of: "u") == 4)
        #expect(DBusSignature.alignment(of: "s") == 4)
        #expect(DBusSignature.alignment(of: "o") == 4)
        #expect(DBusSignature.alignment(of: "h") == 4)
        #expect(DBusSignature.alignment(of: "ay") == 4)
        #expect(DBusSignature.alignment(of: "t") == 8)
        #expect(DBusSignature.alignment(of: "d") == 8)
        #expect(DBusSignature.alignment(of: "(ii)") == 8)
        #expect(DBusSignature.alignment(of: "{sv}") == 8)
    }
}

@Suite("D-Bus marshalling")
struct DBusMarshallingTests {

    private func roundTrip(_ value: DBusValue) throws -> DBusValue {
        var marshaller = DBusMarshaller()
        marshaller.append(value)
        var unmarshaller = DBusUnmarshaller(marshaller.bytes)
        return try unmarshaller.read(signature: value.signature)
    }

    @Test("Every modelled type round-trips")
    func roundTripAllTypes() throws {
        let values: [DBusValue] = [
            .byte(0xAB), .boolean(true), .boolean(false),
            .int16(-1234), .uint16(4321),
            .int32(-70000), .uint32(3_000_000_000),
            .int64(-1 << 40), .uint64(1 << 62),
            .double(3.5),
            .string("hello"), .string(""), .string("ünïcødé"),
            .objectPath("/org/qemu/Display1/Console_0"),
            .signature("a{sv}"),
            .unixFD(0),
            .array(element: "u", values: [.uint32(1), .uint32(2), .uint32(3)]),
            .byteArray([]), .byteArray([1, 2, 3]),
            .structure([.uint32(7), .string("x")]),
            .variant(.uint32(42)),
            .dictEntry(key: .string("k"), value: .variant(.boolean(true))),
        ]
        for value in values {
            #expect(try roundTrip(value) == value, "\(value.signature) did not round-trip")
        }
    }

    @Test("A string is length-prefixed and NUL-terminated")
    func stringEncoding() {
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.string("abc"))
        // 4-byte length, then "abc", then NUL.
        #expect(marshaller.bytes == [3, 0, 0, 0, 0x61, 0x62, 0x63, 0x00])
    }

    @Test("A signature is byte-prefixed and needs no alignment")
    func signatureEncoding() {
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.byte(0xFF))
        marshaller.append(DBusValue.signature("au"))
        // No padding after the byte, because 'g' aligns to 1.
        #expect(marshaller.bytes == [0xFF, 2, 0x61, 0x75, 0x00])
    }

    @Test("Padding is inserted before aligned types and is zero")
    func paddingIsInsertedAndZero() {
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.byte(1))
        marshaller.append(DBusValue.uint32(0x11223344))
        // Three zero pad bytes take the offset from 1 to 4.
        #expect(marshaller.bytes == [1, 0, 0, 0, 0x44, 0x33, 0x22, 0x11])
    }

    @Test("A struct aligns to 8 even when its members would not")
    func structAlignment() {
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.byte(1))
        marshaller.append(DBusValue.structure([.byte(2)]))
        #expect(marshaller.bytes.count == 9)
        #expect(marshaller.bytes[0] == 1)
        #expect(marshaller.bytes[1...7].allSatisfy { $0 == 0 })
        #expect(marshaller.bytes[8] == 2)
    }

    @Test("An array's length counts element data only, not its own padding")
    func arrayLengthExcludesPadding() throws {
        // 'at' elements align to 8, so there is padding between the length word
        // and the first element that must NOT be counted in the length.
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.array(element: "t", values: [.uint64(1)]))
        #expect(marshaller.bytes.count == 16)          // 4 length + 4 pad + 8 data
        let length = marshaller.bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        #expect(length == 8, "length must be 8 (the element), not 12")

        var unmarshaller = DBusUnmarshaller(marshaller.bytes)
        #expect(try unmarshaller.read(signature: "at") == .array(element: "t", values: [.uint64(1)]))
    }

    @Test("An empty array still records its element type")
    func emptyArray() throws {
        let value = DBusValue.array(element: "(ii)", values: [])
        var marshaller = DBusMarshaller()
        marshaller.append(value)
        var unmarshaller = DBusUnmarshaller(marshaller.bytes)
        #expect(try unmarshaller.read(signature: "a(ii)") == value)
    }

    @Test("Alignment is measured from the message start, not the buffer start")
    func baseOffsetAffectsAlignment() {
        // A body marshalled separately must still pad relative to the whole
        // message, which is what the base offset expresses.
        var atZero = DBusMarshaller(baseOffset: 0)
        atZero.append(DBusValue.uint32(1))
        #expect(atZero.bytes.count == 4)

        var atOne = DBusMarshaller(baseOffset: 1)
        atOne.append(DBusValue.uint32(1))
        #expect(atOne.bytes.count == 7, "expected 3 pad bytes then 4 data bytes")
    }

    @Test("Truncated input is rejected rather than read out of bounds")
    func truncatedInput() {
        var marshaller = DBusMarshaller()
        marshaller.append(DBusValue.string("hello"))
        for length in 0..<marshaller.bytes.count {
            var unmarshaller = DBusUnmarshaller(Array(marshaller.bytes.prefix(length)))
            #expect(throws: (any Error).self) { try unmarshaller.read(signature: "s") }
        }
    }

    @Test("A boolean outside 0 and 1 is rejected")
    func invalidBoolean() {
        var unmarshaller = DBusUnmarshaller([7, 0, 0, 0])
        #expect(throws: DBusUnmarshaller.Failure.self) { try unmarshaller.read(signature: "b") }
    }

    @Test("Byte arrays survive intact, which is how pixels arrive")
    func byteArrayFidelity() throws {
        let pixels = (0..<4096).map { UInt8($0 % 251) }
        let decoded = try roundTrip(.byteArray(pixels))
        #expect(decoded == .byteArray(pixels))
        #expect(decoded.byteArrayValue?.count == 4096)
        #expect(decoded.byteArrayValue?[100] == UInt8(100 % 251))
    }

    @Test("Both `ay` spellings produce identical bytes and decode the same")
    func byteArraySpellingsAgree() throws {
        // The generic spelling stays supported so nothing that constructs it by
        // hand silently changes meaning.
        let raw: [UInt8] = [9, 8, 7, 6, 5]
        var fast = DBusMarshaller(); fast.append(DBusValue.byteArray(raw))
        var slow = DBusMarshaller()
        slow.append(DBusValue.array(element: "y", values: raw.map { .byte($0) }))
        #expect(fast.bytes == slow.bytes)
        #expect(try roundTrip(.array(element: "y", values: raw.map { .byte($0) })).byteArrayValue == raw)
    }
}

@Suite("D-Bus messages")
struct DBusMessageTests {

    @Test("A method call round-trips through the wire format")
    func methodCallRoundTrip() throws {
        let original = DBusMessage(
            kind: .methodCall,
            serial: 7,
            path: "/org/qemu/Display1/Console_0",
            interface: "org.qemu.Display1.Console",
            member: "RegisterListener",
            body: [.unixFD(0)],
            unixFDCount: 1
        )
        let decoded = try DBusMessage.decode(try original.encoded())
        #expect(decoded.kind == .methodCall)
        #expect(decoded.serial == 7)
        #expect(decoded.path == original.path)
        #expect(decoded.interface == original.interface)
        #expect(decoded.member == original.member)
        #expect(decoded.body == [.unixFD(0)])
        #expect(decoded.unixFDCount == 1)
    }

    @Test("The fixed header is 12 bytes and starts with little-endian 'l'")
    func headerPrefix() throws {
        let bytes = try DBusMessage(kind: .signal, serial: 1, path: "/a", interface: "b.c", member: "D").encoded()
        #expect(bytes[0] == 0x6C)
        #expect(bytes[1] == DBusMessage.Kind.signal.rawValue)
        #expect(bytes[3] == 1)
    }

    @Test("The body begins on an 8-byte boundary")
    func bodyIsEightAligned() throws {
        // Header field arrays vary in length, so this is the invariant that
        // keeps body alignment correct across every combination of fields.
        for member in ["A", "Scanout", "RegisterListener", "UpdateDMABUF"] {
            let message = DBusMessage(
                kind: .methodCall, serial: 3,
                path: "/org/qemu/Display1/Console_0",
                interface: "org.qemu.Display1.Console",
                member: member,
                body: [.uint32(0xAABBCCDD)]
            )
            let bytes = try message.encoded()
            let total = try #require(try DBusMessage.totalLength(of: bytes))
            #expect(total == bytes.count)
            let bodyStart = total - 4
            #expect(bodyStart % 8 == 0, "body for \(member) starts at \(bodyStart)")
            #expect(try DBusMessage.decode(bytes).body == [.uint32(0xAABBCCDD)])
        }
    }

    @Test("A large body round-trips, exercising the framebuffer path")
    func largeBody() throws {
        let pixels = (0..<(64 * 64 * 4)).map { UInt8($0 & 0xFF) }
        let message = DBusMessage(
            kind: .methodCall, serial: 11,
            path: "/org/qemu/Display1/Listener",
            interface: "org.qemu.Display1.Listener",
            member: "Scanout",
            body: [.uint32(64), .uint32(64), .uint32(256), .uint32(0x2002_0888),
                   .byteArray(pixels)]
        )
        let bytes = try message.encoded()
        let decoded = try DBusMessage.decode(bytes)
        #expect(decoded.member == "Scanout")
        #expect(decoded.body.count == 5)
        #expect(decoded.body[4].byteArrayValue?.count == 64 * 64 * 4)
    }

    @Test("totalLength reports nil until the fixed header has arrived")
    func partialHeader() throws {
        let bytes = try DBusMessage(kind: .signal, serial: 1, path: "/a", interface: "b.c", member: "D").encoded()
        for length in 0..<16 {
            #expect(try DBusMessage.totalLength(of: Array(bytes.prefix(length))) == nil)
        }
        #expect(try DBusMessage.totalLength(of: bytes) == bytes.count)
    }

    @Test("A non-little-endian message is rejected explicitly")
    func bigEndianRejected() throws {
        var bytes = try DBusMessage(kind: .signal, serial: 1, path: "/a", interface: "b.c", member: "D").encoded()
        bytes[0] = 0x42   // 'B'
        #expect(throws: DBusMessage.DecodeFailure.self) { try DBusMessage.totalLength(of: bytes) }
    }

    @Test("An error reply carries its name and message")
    func errorReply() throws {
        let message = DBusMessage(
            kind: .error, serial: 4,
            errorName: "org.freedesktop.DBus.Error.UnknownMethod",
            replySerial: 3,
            body: [.string("no such method")]
        )
        let decoded = try DBusMessage.decode(try message.encoded())
        #expect(decoded.kind == .error)
        #expect(decoded.errorName == "org.freedesktop.DBus.Error.UnknownMethod")
        #expect(decoded.replySerial == 3)
        #expect(decoded.body.first?.stringValue == "no such method")
    }
}
