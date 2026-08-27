import Foundation
import Testing
@testable import MultiemuGuestServices

@Suite("Sensors service")
struct SensorsServiceTests {

    private func answer(_ service: SensorsService, _ command: String) -> String? {
        let message = QemudFrame.Message(type: 0, payload: Data(command.utf8))
        guard let data = service.reply(to: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test("list-sensors is answered with a decimal bitmask, not an empty payload")
    func listSensorsIsParseable() {
        // The HAL runs the reply through sscanf("%u"). An empty payload is not
        // a valid "no sensors" — it is the abort the boot used to die on.
        let reply = answer(SensorsService(), "list-sensors")
        #expect(reply == "0")
        #expect(UInt32(reply ?? "") != nil, "the HAL must be able to parse this with %u")
    }

    @Test("A configured sensor mask is reported as decimal")
    func reportsConfiguredMask() {
        #expect(answer(SensorsService(availableSensors: 0), "list-sensors") == "0")
        #expect(answer(SensorsService(availableSensors: 1), "list-sensors") == "1")
        #expect(answer(SensorsService(availableSensors: 0b1011), "list-sensors") == "11")
    }

    @Test("A wake is echoed back verbatim, which is how the guest unblocks its own read")
    func wakeIsEchoed() {
        #expect(answer(SensorsService(), "wake") == "wake")
    }

    @Test("Configuration commands get no reply, because the guest does not wait on one")
    func configurationCommandsAreSilent() {
        // The port a HAL configures over is the one it reads events from, so an
        // unsolicited reply is a frame arriving where an event is expected.
        let service = SensorsService()
        for command in ["set-delay:200", "set:accel:1", "time:182147297753", "unknown-command", ""] {
            #expect(answer(service, command) == nil, "\"\(command)\" should go unanswered")
        }
    }

    @Test("A command that is not UTF-8 is not answered with a guess")
    func nonUTF8CommandIsNotAnswered() {
        let message = QemudFrame.Message(type: 0, payload: Data([0xFF, 0xFE]))
        #expect(SensorsService().reply(to: message) == nil)
    }

    @Test("Surrounding whitespace does not stop a command being recognised")
    func trimsWhitespace() {
        #expect(answer(SensorsService(), "  list-sensors\n") == "0")
    }

    @Test("A command is never treated as anything but a lookup key")
    func commandIsOnlyData() {
        // Nothing about these should reach a shell, a path, or a format string.
        // Matching is exact, so none of them is even recognised — including the
        // one that begins with a real command.
        let service = SensorsService()
        for hostile in ["list-sensors; rm -rf /", "../../etc/passwd", "%s%s%s%n",
                        "$(whoami)", "`id`", String(repeating: "A", count: 4096)] {
            #expect(answer(service, hostile) == nil,
                    "unexpected handling of \"\(hostile.prefix(24))\"")
        }
    }
}
