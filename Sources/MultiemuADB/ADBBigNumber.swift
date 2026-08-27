import Foundation

/// Just enough fixed-width arithmetic to build Android's public-key blob.
///
/// The blob adbd expects is not a standard encoding: it carries two values that
/// only make sense to a Montgomery multiplier — `n0inv` and `rr` — so a public
/// key cannot be handed over without computing them. Both need arithmetic on a
/// 2048-bit modulus, and this project takes no third-party dependencies, so the
/// two operations it needs are here and nothing else is.
///
/// Words are little-endian, which is the order the blob stores and the order
/// AOSP's `android_pubkey.c` reads. Everything is fixed width: no allocation,
/// no normalisation, no general-purpose bignum to misuse elsewhere.
enum ADBBigNumber {

    /// 2048-bit values, as 64 little-endian 32-bit words.
    static let wordCount = 64

    /// `-1 / n[0] mod 2^32`, the `n0inv` field of the blob.
    ///
    /// Newton's iteration doubles the number of correct bits each round, so
    /// five rounds take a 2-bit inverse to a full 32-bit one. `n` is odd for
    /// any RSA modulus, which is what makes the inverse exist at all.
    static func negativeInverse(ofLowWord low: UInt32) -> UInt32 {
        var inverse: UInt32 = 1
        for _ in 0..<5 {
            inverse = inverse &* (2 &- low &* inverse)
        }
        // Two's-complement negation: -inverse mod 2^32.
        return ~inverse &+ 1
    }

    /// `2^4096 mod modulus`, the `rr` field of the blob.
    ///
    /// Computed as 4096 modular doublings starting from 1 rather than by
    /// exponentiation. It is the plainest correct method — one shift and at
    /// most one conditional subtraction per bit — and at 4096 iterations on 64
    /// words the cost does not matter; this runs once per key.
    static func montgomeryR2(modulus: [UInt32]) -> [UInt32] {
        precondition(modulus.count == wordCount, "the modulus must be \(wordCount) words")
        // One extra word so a doubling that carries out of the top bit is not
        // lost before the reduction can see it.
        var value = [UInt32](repeating: 0, count: wordCount + 1)
        value[0] = 1
        for _ in 0..<(32 * wordCount * 2) {
            shiftLeftOne(&value)
            if isGreaterOrEqual(value, modulus) { subtract(modulus, from: &value) }
        }
        return Array(value.prefix(wordCount))
    }

    private static func shiftLeftOne(_ value: inout [UInt32]) {
        var carry: UInt32 = 0
        for index in value.indices {
            let next = value[index] >> 31
            value[index] = (value[index] << 1) | carry
            carry = next
        }
    }

    /// Is `value` (wordCount+1 words) at least `modulus` (wordCount words)?
    private static func isGreaterOrEqual(_ value: [UInt32], _ modulus: [UInt32]) -> Bool {
        if value[wordCount] != 0 { return true }
        for index in stride(from: wordCount - 1, through: 0, by: -1) {
            if value[index] != modulus[index] { return value[index] > modulus[index] }
        }
        return true
    }

    private static func subtract(_ modulus: [UInt32], from value: inout [UInt32]) {
        var borrow: UInt64 = 0
        for index in 0..<wordCount {
            let difference = UInt64(value[index]) &- UInt64(modulus[index]) &- borrow
            value[index] = UInt32(truncatingIfNeeded: difference)
            borrow = (difference >> 63) & 1
        }
        value[wordCount] = UInt32(truncatingIfNeeded: UInt64(value[wordCount]) &- borrow)
    }

    /// Big-endian bytes (the order DER stores an INTEGER) to little-endian
    /// words (the order the blob wants), zero-extended to `wordCount`.
    static func words(fromBigEndian bytes: [UInt8]) -> [UInt32]? {
        var trimmed = bytes
        while trimmed.first == 0 { trimmed.removeFirst() }
        guard trimmed.count <= wordCount * 4 else { return nil }
        var little = [UInt8](trimmed.reversed())
        little.append(contentsOf: [UInt8](repeating: 0, count: wordCount * 4 - little.count))
        return (0..<wordCount).map { index in
            let base = index * 4
            return UInt32(little[base])
                | UInt32(little[base + 1]) << 8
                | UInt32(little[base + 2]) << 16
                | UInt32(little[base + 3]) << 24
        }
    }

    /// The little-endian byte form the blob stores for a word array.
    static func littleEndianBytes(_ words: [UInt32]) -> Data {
        var data = Data(capacity: words.count * 4)
        for word in words {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
