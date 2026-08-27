import Foundation
import MultiemuBackend
import Testing
@testable import MultiemuConfiguration

@Suite("Audio on a device profile")
struct VirtualDeviceAudioTests {

    @Test("A device file written before audio existed still decodes")
    func olderProfileStillDecodes() throws {
        // The synthesised decoder requires every non-optional key, so a plain
        // `Bool` here would make every previously saved device fail to decode
        // and disappear from the library. `inputProfiles` carries the same
        // scar; this is the second time, so it is worth a test rather than a
        // comment.
        let json = """
        {
          "schemaVersion": 1,
          "id": "8A1D0B2C-3E4F-4A5B-9C6D-7E8F9A0B1C2D",
          "name": "Pixel-ish",
          "imageIdentifier": "cuttlefish-arm64-1",
          "guestArchitecture": "arm64",
          "memoryBytes": 4294967296,
          "storageBytes": 34359738368,
          "vcpuCount": 4,
          "display": {"widthInPixels": 1080, "heightInPixels": 1920, "densityDPI": 420,
                      "refreshHertz": 60, "orientation": "portrait"},
          "network": {"mode": "userMode", "portForwards": []},
          "createdAt": 750000000,
          "modifiedAt": 750000000
        }
        """
        let decoder = JSONDecoder()
        let profile = try decoder.decode(VirtualDeviceProfile.self, from: Data(json.utf8))
        #expect(profile.audioEnabled == nil)
        #expect(profile.audioMode == .disabled, "a profile that never mentioned audio has none")
    }

    @Test("Audio is off unless the device asked for it")
    func audioIsOptIn() {
        var profile = VirtualDeviceProfile(
            name: "Test", imageIdentifier: "x", guestArchitecture: .arm64)
        #expect(profile.audioMode == .disabled)
        profile.audioEnabled = true
        #expect(profile.audioMode == .hostOutput)
        profile.audioEnabled = false
        #expect(profile.audioMode == .disabled)
    }
}
