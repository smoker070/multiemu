import Foundation
import MultiemuDBus
import MultiemuSupport

/// The host half of QEMU's clipboard channel.
///
/// Signatures taken from QEMU's own introspection, not from memory:
///
/// ```
/// org.qemu.Display1.Clipboard
///   Register()
///   Unregister()
///   Grab(u selection, u serial, as mimes)
///   Release(u selection)
///   Request(u selection, as mimes) -> (s reply_mime, ay data)
/// ```
///
/// Clipboard content is untrusted in both directions. Guest text is data to be
/// pasted, never something to interpret: it is size-limited, and only text
/// types are asked for or offered.
public actor QEMUClipboardClient {

    public static let interface = "org.qemu.Display1.Clipboard"
    public static let objectPath = "/org/qemu/Display1/Clipboard"

    /// QEMU's `QemuClipboardSelection`.
    public enum Selection: UInt32, Sendable, CaseIterable {
        case clipboard = 0
        case primary = 1
        case secondary = 2
    }

    /// The only types exchanged. Offering arbitrary types invites a guest to
    /// hand back something the host would try to interpret.
    public static let textMimeTypes = ["text/plain;charset=utf-8", "text/plain"]

    /// A clipboard is for text a person is moving between two places. A cap
    /// keeps a hostile or broken guest from handing over something enormous,
    /// and it is enforced on what is received, not merely requested.
    public static let maximumTextBytes = 1 << 20   // 1 MiB

    public enum Failure: Error, CustomStringConvertible {
        case notRegistered
        case tooLarge(bytes: Int)
        case notText(mime: String)
        case notDecodable

        public var description: String {
            switch self {
            case .notRegistered:
                return "The clipboard channel has not been registered with QEMU."
            case let .tooLarge(bytes):
                return "The guest offered \(ByteCount.describe(UInt64(bytes))) of clipboard text, which is more than Multiemu accepts."
            case let .notText(mime):
                return "The guest offered clipboard content as \(mime), which is not text."
            case .notDecodable:
                return "The guest's clipboard content is not valid UTF-8 text."
            }
        }
    }

    private let connection: DBusConnection
    private var isRegistered = false
    private var grabSerial: UInt32 = 0

    public init(connection: DBusConnection) {
        self.connection = connection
    }

    /// Announces this process as a clipboard peer.
    public func register() async throws {
        try await connection.call(
            path: Self.objectPath, interface: Self.interface, member: "Register", body: [])
        isRegistered = true
    }

    public func unregister() async {
        guard isRegistered else { return }
        try? await connection.call(
            path: Self.objectPath, interface: Self.interface, member: "Unregister", body: [])
        isRegistered = false
    }

    /// Offers host text to the guest.
    ///
    /// Announce-then-serve, as the protocol expects: this says text is
    /// available, and the guest asks for it if something wants to paste.
    public func offerText(selection: Selection = .clipboard) async throws {
        guard isRegistered else { throw Failure.notRegistered }
        grabSerial &+= 1
        try await connection.call(
            path: Self.objectPath, interface: Self.interface, member: "Grab",
            body: [
                .uint32(selection.rawValue),
                .uint32(grabSerial),
                .array(element: "s", values: Self.textMimeTypes.map { .string($0) }),
            ])
    }

    /// Withdraws a previous offer.
    public func releaseOffer(selection: Selection = .clipboard) async throws {
        guard isRegistered else { throw Failure.notRegistered }
        try await connection.call(
            path: Self.objectPath, interface: Self.interface, member: "Release",
            body: [.uint32(selection.rawValue)])
    }

    /// Asks the guest for its clipboard text.
    ///
    /// Everything the guest returns is checked before it is treated as text:
    /// the type it claims, the size, and whether the bytes decode. A guest that
    /// answers with something else gets a named error, not a best effort.
    public func requestText(selection: Selection = .clipboard) async throws -> String {
        guard isRegistered else { throw Failure.notRegistered }
        let reply = try await connection.call(
            path: Self.objectPath, interface: Self.interface, member: "Request",
            body: [
                .uint32(selection.rawValue),
                .array(element: "s", values: Self.textMimeTypes.map { .string($0) }),
            ])

        var mime = ""
        var bytes: [UInt8] = []
        for value in reply.body {
            if case let .string(text) = value, mime.isEmpty { mime = text }
            if case let .byteArray(data) = value { bytes = data }
        }

        guard mime.hasPrefix("text/") else { throw Failure.notText(mime: mime) }
        guard bytes.count <= Self.maximumTextBytes else { throw Failure.tooLarge(bytes: bytes.count) }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.notDecodable }
        return text
    }
}
