import Darwin
import Foundation
import MultiemuSupport

/// Sends a file descriptor to QEMU alongside a QMP command, via `SCM_RIGHTS`.
///
/// QEMU's `getfd` takes its descriptor from the ancillary data of the very
/// message that carries the command, so the two cannot be sent separately.
/// The byte-level work lives in `UnixSocketMessaging`, shared with the D-Bus
/// display channel, which needs the same mechanism for `UNIX_FD` values.
enum QMPFileDescriptorTransfer {
    static func send(descriptor: Int32, with payload: Data, over socket: Int32) throws {
        try UnixSocketMessaging.send(
            payload: [UInt8](payload),
            descriptors: [descriptor],
            over: socket
        )
    }
}
