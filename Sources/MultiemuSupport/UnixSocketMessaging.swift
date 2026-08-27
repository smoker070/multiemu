import Darwin
import Foundation

/// Sending and receiving file descriptors over a UNIX domain socket.
///
/// Both QEMU's QMP `getfd` and D-Bus's `UNIX_FD` type require descriptors to
/// travel as `SCM_RIGHTS` ancillary data on the same message as the payload, so
/// this cannot be expressed with ordinary reads and writes.
///
/// Darwin does not expose the `CMSG_*` macros to Swift, so control messages are
/// laid out by hand. `cmsghdr` is 12 bytes on Darwin and its 4-byte alignment
/// leaves it unpadded, so for `n` descriptors:
///
/// ```
///   cmsg_len   = 12 + 4n
///   cmsg_level = SOL_SOCKET
///   cmsg_type  = SCM_RIGHTS
///   payload    = n × int32, starting at offset 12
/// ```
public enum UnixSocketMessaging {

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case sendFailed(errnoValue: Int32)
        case receiveFailed(errnoValue: Int32)
        case partialSend(sent: Int, expected: Int)
        case tooManyDescriptors(Int, limit: Int)

        public var description: String {
            switch self {
            case let .sendFailed(errnoValue):
                return "Could not send over the UNIX socket: \(String(cString: strerror(errnoValue)))"
            case let .receiveFailed(errnoValue):
                return "Could not receive from the UNIX socket: \(String(cString: strerror(errnoValue)))"
            case let .partialSend(sent, expected):
                return "Only \(sent) of \(expected) bytes were sent with the ancillary data."
            case let .tooManyDescriptors(count, limit):
                return "\(count) descriptors exceeds the \(limit) this implementation carries per message."
            }
        }
    }

    private static let headerLength = 12
    /// Generous for our uses: QEMU passes at most a handful per message.
    public static let maximumDescriptorsPerMessage = 16

    /// Sends `payload`, attaching `descriptors` as `SCM_RIGHTS` ancillary data.
    ///
    /// The whole payload must be written in one `sendmsg`, because the ancillary
    /// data binds to the first byte of the message; a short write would separate
    /// the descriptors from the rest of the payload.
    public static func send(
        payload: [UInt8],
        descriptors: [Int32],
        over socket: Int32
    ) throws {
        guard descriptors.count <= maximumDescriptorsPerMessage else {
            throw Failure.tooManyDescriptors(descriptors.count, limit: maximumDescriptorsPerMessage)
        }

        var payloadBytes = payload
        let controlLength = descriptors.isEmpty ? 0 : headerLength + 4 * descriptors.count
        var control = [UInt8](repeating: 0, count: max(controlLength, 1))

        if !descriptors.isEmpty {
            control.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(controlLength), toByteOffset: 0, as: UInt32.self)
                raw.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
                raw.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
                for (index, descriptor) in descriptors.enumerated() {
                    raw.storeBytes(of: descriptor, toByteOffset: headerLength + 4 * index, as: Int32.self)
                }
            }
        }

        let sent: Int = payloadBytes.withUnsafeMutableBufferPointer { payloadBuffer in
            control.withUnsafeMutableBufferPointer { controlBuffer in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(payloadBuffer.baseAddress),
                    iov_len: payloadBuffer.count
                )
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    if controlLength > 0 {
                        message.msg_control = UnsafeMutableRawPointer(controlBuffer.baseAddress)
                        message.msg_controllen = socklen_t(controlLength)
                    }
                    return sendmsg(socket, &message, 0)
                }
            }
        }

        guard sent >= 0 else { throw Failure.sendFailed(errnoValue: errno) }
        guard sent == payload.count else {
            throw Failure.partialSend(sent: sent, expected: payload.count)
        }
    }

    /// Reads up to `capacity` bytes, collecting any descriptors that arrive.
    ///
    /// A control buffer is always supplied. Receiving without one silently
    /// discards descriptors the peer sent, leaking them in the sender and
    /// leaving us unable to use data they refer to.
    public static func receive(
        capacity: Int,
        over socket: Int32
    ) throws -> (bytes: [UInt8], descriptors: [Int32]) {
        var payload = [UInt8](repeating: 0, count: capacity)
        let controlCapacity = headerLength + 4 * maximumDescriptorsPerMessage
        var control = [UInt8](repeating: 0, count: controlCapacity)
        var controlLengthOut = 0
        var flagsOut: Int32 = 0

        let received: Int = payload.withUnsafeMutableBufferPointer { payloadBuffer in
            control.withUnsafeMutableBufferPointer { controlBuffer in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(payloadBuffer.baseAddress),
                    iov_len: payloadBuffer.count
                )
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr()
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = UnsafeMutableRawPointer(controlBuffer.baseAddress)
                    message.msg_controllen = socklen_t(controlCapacity)
                    let count = recvmsg(socket, &message, 0)
                    controlLengthOut = Int(message.msg_controllen)
                    flagsOut = message.msg_flags
                    return count
                }
            }
        }
        _ = flagsOut

        guard received >= 0 else { throw Failure.receiveFailed(errnoValue: errno) }

        var descriptors: [Int32] = []
        if controlLengthOut >= headerLength {
            control.withUnsafeBytes { raw in
                let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                let level = raw.loadUnaligned(fromByteOffset: 4, as: Int32.self)
                let type = raw.loadUnaligned(fromByteOffset: 8, as: Int32.self)
                guard level == SOL_SOCKET, type == SCM_RIGHTS, length >= headerLength else { return }
                let count = (min(length, controlLengthOut) - headerLength) / 4
                for index in 0..<count {
                    descriptors.append(raw.loadUnaligned(fromByteOffset: headerLength + 4 * index, as: Int32.self))
                }
            }
        }

        return (Array(payload[0..<received]), descriptors)
    }
}
