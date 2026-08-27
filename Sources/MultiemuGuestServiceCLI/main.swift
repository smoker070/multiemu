import Foundation
import MultiemuGuestServices

// Line-buffered, because this is normally run with its output redirected to a
// log while a guest boots. Swift's default full buffering on a non-tty means
// nothing appears until the process exits — which, for something that runs
// until interrupted, is never.
setvbuf(stdout, nil, _IOLBF, 0)

// Serves guest console services against a QEMU already running, which is what
// image bring-up needs: the emulator app wires these itself, but working out
// what a new image expects means driving QEMU by hand.

let usage = """
USAGE:
  multiemu-guest-service --sensors <socket-path> [--sensors <socket-path>]...
                         [--sensor-mask <n>]

Connects to UNIX sockets that QEMU is listening on for virtio-console ports and
answers the protocols an Android guest speaks on them. Runs until interrupted.

OPTIONS:
  --sensors <path>     Serve the goldfish `qemud` sensors protocol on this port.
                       The guest's sensors HAL will not register
                       android.hardware.sensors.ISensors until it is answered,
                       and system_server waits on that interface, so an
                       unanswered port stalls the whole boot.
  --sensor-mask <n>    Bitmask of sensors to report. Default 0, meaning none —
                       which is the truth unless something is producing samples.
  -h, --help           Show this help.

EXIT CODES:
  0  interrupted after serving
  64 bad usage
  70 a responder could not be started
"""

var arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("multiemu-guest-service: \(message)\n".utf8))
    exit(code)
}

var sensorPaths: [String] = []
var sensorMask: UInt32 = 0

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--sensors":
        guard index + 1 < arguments.count else { fail("--sensors needs a socket path.", code: 64) }
        sensorPaths.append(arguments[index + 1])
        index += 2
    case "--sensor-mask":
        guard index + 1 < arguments.count, let value = UInt32(arguments[index + 1]) else {
            fail("--sensor-mask needs a number.", code: 64)
        }
        sensorMask = value
        index += 2
    default:
        fail("Unrecognised argument \"\(arguments[index])\".", code: 64)
    }
}

guard !sensorPaths.isEmpty else { fail("Nothing to serve.", code: 64) }

let responders = sensorPaths.map {
    GuestConsoleResponder(socketPath: $0, service: SensorsService(availableSensors: sensorMask))
}

for (path, responder) in zip(sensorPaths, responders) {
    do {
        try await responder.start()
        print("serving sensors on \(path) (mask \(sensorMask))")
    } catch {
        fail("Could not serve \(path): \(error)", code: 70)
    }
}

print("Serving. Interrupt to stop.")

// Nothing to do on this task but stay alive; the responders own their own work.
while true {
    try? await Task.sleep(for: .seconds(3600))
}
