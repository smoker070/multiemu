import Foundation

/// Writes D-Bus values in little-endian wire format.
///
/// Alignment is the whole difficulty here: every type must start at a multiple
/// of its alignment, measured from the **start of the message**, and padding
/// bytes must be zero. An off-by-one in padding does not fail locally — it
/// shifts every subsequent value, so the peer decodes plausible garbage.
public struct DBusMarshaller {

    public private(set) var bytes: [UInt8] = []
    /// Offset of the first byte written, so alignment can be computed relative
    /// to the message start even when a body is marshalled separately.
    private let baseOffset: Int

    public init(baseOffset: Int = 0) {
        self.baseOffset = baseOffset
    }

    private var absoluteOffset: Int { baseOffset + bytes.count }

    public mutating func align(to alignment: Int) {
        guard alignment > 1 else { return }
        let remainder = absoluteOffset % alignment
        if remainder != 0 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: alignment - remainder))
        }
    }

    public mutating func appendRaw(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    public mutating func append(_ value: UInt8) { bytes.append(value) }

    public mutating func append(_ value: UInt16) {
        align(to: 2)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public mutating func append(_ value: UInt32) {
        align(to: 4)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public mutating func append(_ value: UInt64) {
        align(to: 8)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// Strings and object paths: 4-byte length, UTF-8 bytes, trailing NUL.
    public mutating func appendString(_ text: String) {
        let utf8 = Array(text.utf8)
        append(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    /// Signatures: single-byte length, bytes, trailing NUL. No alignment.
    public mutating func appendSignature(_ text: String) {
        let utf8 = Array(text.utf8)
        bytes.append(UInt8(utf8.count))
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    public mutating func append(_ value: DBusValue) {
        switch value {
        case .byte(let raw): append(raw)
        case .boolean(let raw): append(UInt32(raw ? 1 : 0))
        case .int16(let raw): append(UInt16(bitPattern: raw))
        case .uint16(let raw): append(raw)
        case .int32(let raw): append(UInt32(bitPattern: raw))
        case .uint32(let raw): append(raw)
        case .unixFD(let raw): append(raw)
        case .int64(let raw): append(UInt64(bitPattern: raw))
        case .uint64(let raw): append(raw)
        case .double(let raw): append(raw.bitPattern)
        case .string(let raw), .objectPath(let raw): appendString(raw)
        case .signature(let raw): appendSignature(raw)

        case .array(let element, let values):
            // Length counts the element data only, and is measured after the
            // element alignment padding — which is why the padding is emitted
            // before the length is known and then patched in.
            align(to: 4)
            let lengthIndex = bytes.count
            bytes.append(contentsOf: [0, 0, 0, 0])
            align(to: DBusSignature.alignment(of: element))
            let dataStart = bytes.count
            for item in values { append(item) }
            let length = UInt32(bytes.count - dataStart)
            withUnsafeBytes(of: length.littleEndian) { raw in
                for (offset, byte) in raw.enumerated() { bytes[lengthIndex + offset] = byte }
            }

        case .byteArray(let raw):
            // Same wire format as any `ay`, written in bulk.
            align(to: 4)
            append(UInt32(raw.count))
            bytes.append(contentsOf: raw)

        case .structure(let members):
            align(to: 8)
            for member in members { append(member) }

        case .variant(let inner):
            appendSignature(inner.signature)
            append(inner)

        case .dictEntry(let key, let entryValue):
            align(to: 8)
            append(key)
            append(entryValue)
        }
    }
}
