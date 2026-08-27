import Foundation

/// Answers one command from the guest.
///
/// A service only ever *answers*. A command from the guest is data to be
/// matched against a known vocabulary — never a string handed to a shell, a
/// path opened on the host, or anything else that would let the guest act
/// outside itself.
public protocol QemudService: Sendable {
    /// The reply payload for one command, or `nil` to send nothing.
    func reply(to command: QemudFrame.Message) -> Data?
    /// Used in logs.
    var name: String { get }
}

/// The sensors service an Android guest expects on its virtio-console port.
///
/// The guest's `sensors-service.multihal` opens the port and asks
/// `list-sensors` before it will register `android.hardware.sensors.ISensors`.
/// The reply is an **ASCII decimal bitmask** of available sensors, and the HAL
/// runs it through `sscanf("%u")`: an empty payload is not a valid "none", it
/// is a parse failure, and the HAL aborts with
///
///     MultihalSensors:80: Can't parse qemud response
///
/// which loops forever because `system_server` is waiting on the interface.
/// `0` — no sensors — is a well-formed answer and is the truth for a guest with
/// no sensor hardware behind it.
public struct SensorsService: QemudService {

    public let name = "sensors"

    /// Bitmask of sensors offered to the guest, one bit per goldfish sensor id.
    ///
    /// Zero means "this device has none", which is honest today: nothing on the
    /// host is producing sensor samples. It is a stored value rather than a
    /// constant so that wiring real sensors later is a change of data, not a
    /// change of protocol code.
    public var availableSensors: UInt32

    public init(availableSensors: UInt32 = 0) {
        self.availableSensors = availableSensors
    }

    public func reply(to command: QemudFrame.Message) -> Data? {
        // A command that is not UTF-8 is not one of ours, and a guess would be
        // worse than silence.
        guard let text = command.command?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        // Matched against a fixed vocabulary. The guest's bytes select an
        // answer; they never become one.
        //
        // Silence is the correct answer to most of these. An earlier version
        // replied "OK" to configuration commands and "0" to anything it did not
        // recognise, on the reasoning that a HAL blocked in `read` is what
        // stalls a boot. That was wrong in the other direction: the port a HAL
        // configures over is the same one it reads sensor events from, so an
        // unsolicited reply is a frame arriving where an event is expected.
        // Harmless while the mask is zero and there are no events; wrong the
        // moment there are.
        // Matched exactly, not by prefix. A prefix match answers
        // "list-sensors<anything>" as though it were the command, which has no
        // upside: a real guest sends the command alone, and being lenient only
        // widens what an odd or hostile guest can get a reply to.
        if text == "list-sensors" {
            // Parsed by the guest with sscanf("%u"), so it must be a decimal
            // number and nothing else. An empty payload is not a valid "none" —
            // it is the parse failure the HAL aborts on.
            return Data(String(availableSensors).utf8)
        }
        if text == "wake" {
            // Echoed back verbatim. This is how the HAL unblocks its own
            // blocking read at teardown or reconfiguration: it writes `wake`
            // and waits to see it come back.
            return Data("wake".utf8)
        }

        // `set:`, `set-delay:`, and anything else: no reply. The guest does not
        // wait on one.
        return nil
    }
}
