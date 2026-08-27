import Foundation
import Security
import Testing
@testable import MultiemuADB

@Suite("The ADB key and the blob adbd expects")
struct ADBKeyTests {

    /// A fixed 2048-bit odd modulus, with `n0inv` and `rr` computed by an
    /// independent implementation (Python's arbitrary-precision integers).
    ///
    /// Checking the Swift result against values this code did not produce is
    /// the whole point: a Montgomery parameter that is wrong in a consistent
    /// way would pass any test written in terms of the same arithmetic, and
    /// would then fail only against a real device, as an unexplained refusal.
    static let modulusHex = """
    8b2f100f0590f81ce21bc9b3c80458d1b1d58d489333cbfadacd61eee832e160\
    09b7653ef21b5a33d9bb0d2cac90b0e2e8f59b17562faa3a6d24519e78d6f67c\
    23a56db24fe7d584bb8290b87f6daaee8f5bebec9f2e0520feab919b1a06f6b4\
    eb0608017162d263174b0bf2faf28318b5f298c6a5631014c3a495aff766133a\
    2c3835c8412b1df2765cd0aa28077aa3e23c5ddec36b13e9db5a9e7339a2a893\
    adb85977f3ec2834cfd566d658c79d5a0d3ab3d21858b5e351a57b31f8da4a8f\
    a98969144753e99e31747f470139aa5adf509d1913751029d5db91206d891ebb\
    d2767b475655ba37cfdf3e662ee27a06cfd44aeaa33b9ad54585404711f46351
    """
    static let expectedN0Inv: UInt32 = 512_047_695
    static let expectedRRHex = """
    84f6f77fd69624937125ae783047b904116f83bc8e1807bdcb66c4d9f1bc909a\
    255aa3052dec424d15492350466ac2a80931a23f0cf944b42187e1e54510533f\
    fc9370cdf1b9c25ddbe631ae6560969c9db095016bbf206ac2eb94d187134ad7\
    070dfe79870bdf866ba63761469877865c7a9101a17116b52eeb3ee1e348bb28\
    cf435e53ecfa9fefe60541be453fc23fcb47dfbc74d743d104700cf38dd9cc50\
    40431fd8f748e089c426682fa6a0cfc6793473f1c0d4e43d375b4c0e7d4f9092\
    8ab29c50ea4ef45549c8c8a407e011426e6b5f91d5560cfc9d03d09964d9dce2\
    7f6d8b53fc746f4827f3540e1e1bfd7b575d2dbfa42a7b78120d51413f29e5aa
    """

    static func bytes(fromHex hex: String) -> [UInt8] {
        let compact = hex.filter { !$0.isWhitespace }
        return stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return UInt8(compact[start..<end], radix: 16)!
        }
    }

    @Test("n0inv matches an independent computation, and its defining identity")
    func negativeInverseIsCorrect() throws {
        let words = try #require(ADBBigNumber.words(fromBigEndian: Self.bytes(fromHex: Self.modulusHex)))
        let inverse = ADBBigNumber.negativeInverse(ofLowWord: words[0])
        #expect(inverse == Self.expectedN0Inv)
        // n[0] * n0inv == -1 mod 2^32 is what the value means; checking the
        // identity as well as the number catches a right answer arrived at by
        // the wrong route.
        #expect(words[0] &* inverse == UInt32.max)
    }

    @Test("rr is 2^4096 mod n, against an independent computation")
    func montgomeryR2IsCorrect() throws {
        let words = try #require(ADBBigNumber.words(fromBigEndian: Self.bytes(fromHex: Self.modulusHex)))
        let rr = ADBBigNumber.montgomeryR2(modulus: words)
        let expected = try #require(ADBBigNumber.words(fromBigEndian: Self.bytes(fromHex: Self.expectedRRHex)))
        #expect(rr == expected)
    }

    @Test("Big-endian bytes become little-endian words and back")
    func wordConversionRoundTrips() throws {
        let original = Self.bytes(fromHex: Self.modulusHex)
        let words = try #require(ADBBigNumber.words(fromBigEndian: original))
        let little = [UInt8](ADBBigNumber.littleEndianBytes(words))
        #expect(little.count == 256)
        #expect([UInt8](little.reversed()) == original)
    }

    @Test("A modulus wider than 2048 bits is refused rather than truncated")
    func oversizedModulusIsRefused() {
        #expect(ADBBigNumber.words(fromBigEndian: [UInt8](repeating: 0xAB, count: 257)) == nil)
    }

    @Test("A generated key signs a token in the form adbd verifies")
    func signsToken() throws {
        let key = try ADBKey.generate()
        let token = Data((0..<ADBKey.tokenSize).map { UInt8($0) })
        let signature = try key.signature(forToken: token)

        // adbd verifies with PKCS#1 v1.5 over the token treated as a SHA-1
        // digest. Verifying the same way here is what proves the *algorithm*
        // choice, not just that some bytes came back.
        #expect(signature.count == ADBKey.modulusBytes)
        let publicKey = try #require(key.publicKey)
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey, .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData, signature as CFData, &error)
        #expect(verified, "the signature must verify under the algorithm adbd uses")
    }

    @Test("The public key blob has the layout adbd parses")
    func publicKeyBlobLayout() throws {
        let key = try ADBKey.generate()
        let blob = try key.androidPublicKeyBlob(identity: "multiemu@test")

        // "<base64> multiemu@test\0"
        #expect(blob.last == 0)
        let text = String(decoding: blob.dropLast(), as: UTF8.self)
        let parts = text.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts[1] == "multiemu@test")

        let decoded = try #require(Data(base64Encoded: String(parts[0])))
        // 3 words + 2 * 256 bytes, exactly what android_pubkey.c reads.
        #expect(decoded.count == 3 * 4 + 2 * ADBKey.modulusBytes)

        func word(at offset: Int) -> UInt32 {
            decoded.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        #expect(word(at: 0) == 64, "the modulus is 64 words")
        #expect(word(at: decoded.count - 4) == ADBKey.publicExponent)

        // The modulus in the blob must be this key's, little-endian.
        let modulus = try key.modulusBigEndian()
        let blobModulus = [UInt8](decoded[8..<(8 + ADBKey.modulusBytes)])
        #expect([UInt8](blobModulus.reversed()) == modulus)
    }

    @Test("A key written to disk is readable back and only by its owner")
    func keyPersistsWithTightPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-adbkey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("adbkey")

        let created = try ADBKey.loadOrCreate(at: url)
        let reloaded = try ADBKey.loadOrCreate(at: url)
        #expect(try created.modulusBigEndian() == reloaded.modulusBigEndian(),
                "loading must return the same key, not make a new one")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        #expect(permissions == 0o600, "a private key must not be group- or world-readable")
    }
}
