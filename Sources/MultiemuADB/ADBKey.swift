import Foundation
import Security

/// The RSA identity this client presents when a guest demands authentication.
///
/// **Why a key exists at all.** adbd on a production image sets `ro.adb.secure`
/// and answers `CNXN` with `AUTH TOKEN` — twenty random bytes to sign. A client
/// with no key cannot get past that. The images this project runs are
/// `userdebug` with `ro.adb.secure` unset and never ask, so this path is
/// exercised against a test double rather than the fixture; see
/// `ADBAuthenticationTests`.
///
/// **Where the key lives.** In a file the caller names, written `0600`, never
/// in source control — the brief is explicit about machine-specific secrets.
/// It is deliberately *not* in the Keychain: the Keychain would prompt, and an
/// emulator that raises an authentication dialog to talk to its own guest is
/// worse than one that keeps a file only its owner can read.
/// `@unchecked Sendable` because `SecKey` is a CoreFoundation type Swift does
/// not know is safe to share. Its operations are immutable reads of an opaque
/// key object — sign and export — and this type never mutates it, so the
/// guarantee holds by construction rather than by convention.
public struct ADBKey: @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case generationFailed(String)
        case keyUnreadable(String)
        case notRSA2048(bits: Int)
        case malformedKeyData(String)
        case signingFailed(String)

        public var description: String {
            switch self {
            case let .generationFailed(detail): return "Could not create an ADB key: \(detail)"
            case let .keyUnreadable(detail): return "Could not read the ADB key: \(detail)"
            case let .notRSA2048(bits):
                return "adbd accepts only 2048-bit RSA keys; this one is \(bits)-bit."
            case let .malformedKeyData(detail): return "The ADB key data is malformed: \(detail)"
            case let .signingFailed(detail): return "Could not sign the adbd token: \(detail)"
            }
        }
    }

    /// adbd's fixed expectations, from AOSP's `android_pubkey.c`.
    public static let modulusBits = 2048
    public static let modulusBytes = modulusBits / 8
    /// The only exponent adbd's blob format can carry.
    public static let publicExponent: UInt32 = 65537
    /// The digest adbd sends for signing, in bytes.
    public static let tokenSize = 20

    private let privateKey: SecKey

    public init(privateKey: SecKey) {
        self.privateKey = privateKey
    }

    /// Loads the key at `url`, creating one if there is none.
    ///
    /// Create-if-absent rather than a separate setup step: a missing key is the
    /// normal state on first run, not an error a user should have to resolve.
    public static func loadOrCreate(at url: URL) throws -> ADBKey {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try ADBKey(pkcs1PrivateKey: data)
        }
        let key = try generate()
        try key.write(to: url)
        return key
    }

    public static func generate() throws -> ADBKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: modulusBits,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Failure.generationFailed(Self.describe(error))
        }
        return ADBKey(privateKey: key)
    }

    public init(pkcs1PrivateKey data: Data) throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw Failure.keyUnreadable(Self.describe(error))
        }
        self.privateKey = key
    }

    /// Writes the private key `0600`.
    ///
    /// The permissions are set in the create call rather than afterwards, so
    /// the key is never briefly readable by anyone else.
    public func write(to url: URL) throws {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw Failure.keyUnreadable(Self.describe(error))
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path, contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    }

    /// Signs adbd's token.
    ///
    /// The token is already a SHA-1 digest, so this signs the digest directly
    /// with PKCS#1 v1.5 padding — `rsaSignatureDigestPKCS1v15SHA1`. Hashing it
    /// again would produce a signature adbd rejects without saying why.
    public func signature(forToken token: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) as Data?
        else {
            throw Failure.signingFailed(Self.describe(error))
        }
        return signature
    }

    public var publicKey: SecKey? { SecKeyCopyPublicKey(privateKey) }

    /// The modulus, big-endian, as adbd's blob and DER both order it.
    public func modulusBigEndian() throws -> [UInt8] {
        guard let publicKey else { throw Failure.keyUnreadable("no public key") }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Failure.keyUnreadable(Self.describe(error))
        }
        let parsed = try Self.parsePKCS1PublicKey(der)
        guard parsed.modulus.count == Self.modulusBytes else {
            throw Failure.notRSA2048(bits: parsed.modulus.count * 8)
        }
        return parsed.modulus
    }

    /// The `RSAPublicKey` blob adbd stores in `adb_keys`, base64-encoded with a
    /// trailing identity.
    ///
    /// Layout, from AOSP `android_pubkey.c` — every field little-endian:
    ///
    ///     uint32 modulus_size_words   (64)
    ///     uint32 n0inv                (-1 / n[0] mod 2^32)
    ///     uint8  modulus[256]
    ///     uint8  rr[256]              (2^4096 mod n)
    ///     uint32 exponent             (65537)
    ///
    /// `n0inv` and `rr` are Montgomery parameters. adbd could derive them and
    /// does not; a blob without them is rejected.
    public func androidPublicKeyBlob(identity: String = "multiemu@localhost") throws -> Data {
        let modulus = try modulusBigEndian()
        guard let words = ADBBigNumber.words(fromBigEndian: modulus) else {
            throw Failure.malformedKeyData("the modulus does not fit 2048 bits")
        }
        var blob = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { blob.append(contentsOf: $0) }
        }
        append(UInt32(ADBBigNumber.wordCount))
        append(ADBBigNumber.negativeInverse(ofLowWord: words[0]))
        blob.append(ADBBigNumber.littleEndianBytes(words))
        blob.append(ADBBigNumber.littleEndianBytes(ADBBigNumber.montgomeryR2(modulus: words)))
        append(Self.publicExponent)

        var encoded = Data(blob.base64EncodedString().utf8)
        encoded.append(contentsOf: Data(" \(identity)".utf8))
        // adbd reads this as a C string.
        encoded.append(0)
        return encoded
    }

    // MARK: - DER

    struct PKCS1PublicKey {
        var modulus: [UInt8]
        var exponent: [UInt8]
    }

    /// Parses `SEQUENCE { INTEGER modulus, INTEGER exponent }`.
    ///
    /// A deliberately tiny parser: it accepts exactly the one shape
    /// `SecKeyCopyExternalRepresentation` returns for an RSA public key and
    /// refuses everything else, rather than being a general DER reader that
    /// would need to be right about far more.
    static func parsePKCS1PublicKey(_ der: Data) throws -> PKCS1PublicKey {
        var index = der.startIndex

        func byte() throws -> UInt8 {
            guard index < der.endIndex else { throw Failure.malformedKeyData("ran off the end") }
            defer { index = der.index(after: index) }
            return der[index]
        }

        func length() throws -> Int {
            let first = try byte()
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4 else {
                throw Failure.malformedKeyData("unsupported length form")
            }
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(try byte()) }
            return value
        }

        func integer() throws -> [UInt8] {
            guard try byte() == 0x02 else { throw Failure.malformedKeyData("expected an INTEGER") }
            let count = try length()
            guard der.distance(from: index, to: der.endIndex) >= count else {
                throw Failure.malformedKeyData("INTEGER runs past the end")
            }
            let end = der.index(index, offsetBy: count)
            var bytes = [UInt8](der[index..<end])
            index = end
            // DER prefixes a zero byte when the high bit would make the value
            // look negative. The modulus is unsigned, so drop it.
            if bytes.first == 0 { bytes.removeFirst() }
            return bytes
        }

        guard try byte() == 0x30 else { throw Failure.malformedKeyData("expected a SEQUENCE") }
        _ = try length()
        let modulus = try integer()
        let exponent = try integer()
        return PKCS1PublicKey(modulus: modulus, exponent: exponent)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "no detail" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}
