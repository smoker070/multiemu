import Darwin
import Foundation
import MultiemuDBus
import MultiemuSupport

/// Receives guest display output over QEMU's D-Bus display interface.
///
/// The channel is deliberately two connections, because that is how QEMU models
/// it:
///
/// 1. The **console** connection, obtained from QMP `add_client`, on which we
///    are the D-Bus client and call `RegisterListener`.
/// 2. The **listener** connection, a socket pair whose far end we hand to QEMU
///    inside that call. QEMU opens a fresh D-Bus connection over it as the
///    *client*, which makes Multiemu the *server* — it is QEMU that calls
///    `Scanout` and `Update` on us, not the other way around.
public actor QEMUDisplayClient {

    public static let consoleInterface = "org.qemu.Display1.Console"
    public static let listenerInterface = "org.qemu.Display1.Listener"
    public static let defaultConsolePath = "/org/qemu/Display1/Console_0"

    public enum Event: Sendable {
        case scanout(GuestFrame)
        case update(x: Int, y: Int, frame: GuestFrame)
        case disabled
        /// A listener method we do not implement, reported rather than hidden.
        case unhandled(member: String, signature: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case socketPairFailed(errnoValue: Int32)
        case registerListenerFailed(String)

        public var description: String {
            switch self {
            case let .socketPairFailed(errnoValue):
                return "Could not create the listener socket pair: \(String(cString: strerror(errnoValue)))"
            case let .registerListenerFailed(detail):
                return "RegisterListener was refused: \(detail)"
            }
        }
    }

    private let console: DBusConnection
    private var listener: DBusConnection?
    private let eventContinuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    public init(consoleConnection: DBusConnection) {
        self.console = consoleConnection
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { captured = $0 }
        self.eventContinuation = captured
    }

    /// Returns the introspection XML for an object.
    ///
    /// The authoritative description of what QEMU actually exposes on this
    /// build, rather than what a document says it should. Interface and
    /// signature guesses are the main risk in a hand-written D-Bus client, and
    /// this removes it.
    public func introspect(path: String = defaultConsolePath) async throws -> String {
        let reply = try await console.call(
            path: path,
            interface: "org.freedesktop.DBus.Introspectable",
            member: "Introspect"
        )
        return reply.body.first?.stringValue ?? ""
    }

    /// Registers a listener and begins receiving frames.
    public func registerListener(consolePath: String = defaultConsolePath) async throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw Failure.socketPairFailed(errnoValue: errno)
        }
        let ourEnd = descriptors[0], qemuEnd = descriptors[1]

        // The SASL role and the message role are independent, and they are
        // opposite here. QEMU authenticates as the *server* on the listener
        // connection, so Multiemu drives the handshake as the *client* — while
        // still being the side that *implements* the Listener interface and
        // receives QEMU's method calls.
        //
        // Assuming the roles matched cost a debugging cycle: QEMU replied to
        // RegisterListener and then simply never spoke, because both ends were
        // waiting for the other to open the handshake.
        let listenerConnection = DBusConnection(descriptor: ourEnd, role: .client)
        self.listener = listenerConnection

        let continuation = eventContinuation
        await listenerConnection.setMethodHandler { [weak self] message in
            await self?.handleListenerCall(message, continuation: continuation)
        }

        do {
            try await console.call(
                path: consolePath,
                interface: Self.consoleInterface,
                member: "RegisterListener",
                body: [.unixFD(0)],
                descriptors: [qemuEnd]
            )
        } catch {
            Darwin.close(ourEnd)
            Darwin.close(qemuEnd)
            throw Failure.registerListenerFailed(String(describing: error))
        }

        Darwin.close(qemuEnd)   // QEMU owns its copy now

        // Only now can the handshake run: QEMU sets its end up while handling
        // RegisterListener, so opening the SASL exchange earlier would write
        // into a socket nothing is reading yet.
        try await listenerConnection.authenticate()
        MultiemuLog.graphics.info("Display listener registered on \(consolePath, privacy: .public)")
    }

    /// Handles a method call from QEMU on the listener interface.
    private func handleListenerCall(
        _ message: DBusMessage,
        continuation: AsyncStream<Event>.Continuation
    ) -> DBusMessage? {
        // Values are read positionally and coerced, rather than by matching an
        // exact signature. QEMU's interface has grown variants over releases;
        // reading positionally keeps a slightly different signature usable
        // instead of dropping the frame entirely.
        func number(_ index: Int) -> Int? {
            guard index < message.body.count else { return nil }
            switch message.body[index] {
            case .uint32(let value): return Int(value)
            case .int32(let value): return Int(value)
            case .uint16(let value): return Int(value)
            case .int16(let value): return Int(value)
            case .uint64(let value): return Int(value)
            case .int64(let value): return Int(value)
            case .byte(let value): return Int(value)
            default: return nil
            }
        }
        func pixels(_ index: Int) -> [UInt8]? {
            guard index < message.body.count else { return nil }
            return message.body[index].byteArrayValue
        }

        let ok = DBusMessage(kind: .methodReturn)

        switch message.member {
        case "Scanout":
            // Scanout(u width, u height, u stride, u pixman_format, ay data)
            guard let width = number(0), let height = number(1),
                  let stride = number(2), let formatCode = number(3),
                  let data = pixels(4) else {
                return errorReply(to: message, detail: "malformed Scanout body")
            }
            continuation.yield(.scanout(GuestFrame(
                width: width, height: height, stride: stride,
                format: PixmanFormat(rawValue: UInt32(truncatingIfNeeded: formatCode)),
                pixels: data
            )))
            return ok

        case "Update":
            // Update(i x, i y, i w, i h, u stride, u pixman_format, ay data)
            guard let x = number(0), let y = number(1),
                  let width = number(2), let height = number(3),
                  let stride = number(4), let formatCode = number(5),
                  let data = pixels(6) else {
                return errorReply(to: message, detail: "malformed Update body")
            }
            continuation.yield(.update(x: x, y: y, frame: GuestFrame(
                width: width, height: height, stride: stride,
                format: PixmanFormat(rawValue: UInt32(truncatingIfNeeded: formatCode)),
                pixels: data
            )))
            return ok

        case "Disable":
            continuation.yield(.disabled)
            return ok

        // Accepted and ignored: cursor and pointer state belong to the input
        // milestone, and DMABUF variants cannot occur on macOS. Replying
        // successfully keeps QEMU from treating the listener as broken.
        case "MouseSet", "CursorDefine", "ScanoutDMABUF", "UpdateDMABUF", "ScanoutMap", "UpdateMap":
            continuation.yield(.unhandled(
                member: message.member ?? "?",
                signature: message.body.map(\.signature).joined()
            ))
            return ok

        default:
            if message.interface == "org.freedesktop.DBus.Peer", message.member == "Ping" { return ok }
            return errorReply(to: message, detail: "unimplemented")
        }
    }

    private func errorReply(to message: DBusMessage, detail: String) -> DBusMessage {
        DBusMessage(
            kind: .error,
            errorName: "org.freedesktop.DBus.Error.Failed",
            body: [.string("\(message.member ?? "?"): \(detail)")]
        )
    }

    public func close() async {
        await listener?.close()
        await console.close()
        eventContinuation.finish()
    }
}
