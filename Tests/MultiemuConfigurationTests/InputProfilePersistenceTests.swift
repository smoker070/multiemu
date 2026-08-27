import Foundation
import Testing
@testable import MultiemuConfiguration
import MultiemuInput
import MultiemuSupport

/// Input profiles are saved with the device, so the rules that matter are the
/// persistence ones: old files must still open, and a saved mapping must come
/// back exactly.
@Suite("Input profile persistence")
struct InputProfilePersistenceTests {

    @Test("A device file written before input mapping existed still decodes")
    func legacyDeviceFileStillDecodes() throws {
        // Exactly the shape `VirtualDeviceProfile` wrote before this milestone:
        // no `inputProfiles`, no `activeInputProfileID`. The synthesised decoder
        // requires every non-optional key, so getting this wrong would make a
        // user's existing devices vanish from the library.
        let legacy = """
        {
          "schemaVersion": 1,
          "id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "name": "Legacy device",
          "imageIdentifier": "aosp-arm64-14",
          "guestArchitecture": "arm64",
          "memoryBytes": 4294967296,
          "storageBytes": 34359738368,
          "vcpuCount": 4,
          "display": { "widthInPixels": 1920, "heightInPixels": 1080, "densityDPI": 240 },
          "network": { "mode": "userMode", "portForwards": [] },
          "createdAt": "2026-01-01T00:00:00.000Z",
          "modifiedAt": "2026-01-01T00:00:00.000Z"
        }
        """
        let profile = try ConfigurationCoders.makeDecoder().decode(
            VirtualDeviceProfile.self, from: Data(legacy.utf8))

        #expect(profile.name == "Legacy device")
        #expect(profile.inputProfiles == nil)
        // It still offers a usable mapping rather than an empty list.
        #expect(profile.effectiveInputProfiles.count == 1)
        #expect(profile.activeInputProfile != nil)
    }

    @Test("A saved mapping round-trips through the device file")
    func mappingRoundTrips() throws {
        var device = VirtualDeviceProfile(
            name: "Mapped", imageIdentifier: "aosp-arm64-14", guestArchitecture: .arm64)
        var custom = InputProfile.newProfile(named: "Racing")
        custom.bindings.append(InputBinding(
            label: "Boost", trigger: .key(.leftShift),
            action: .touch(NormalizedPoint(x: 0.62, y: 0.88))))
        device.upsertInputProfile(custom)

        let data = try ConfigurationCoders.makeEncoder().encode(device)
        let restored = try ConfigurationCoders.makeDecoder().decode(VirtualDeviceProfile.self, from: data)

        #expect(restored.activeInputProfileID == custom.id)
        #expect(restored.activeInputProfile == custom)
        #expect(restored.activeInputProfile?.bindings.contains { $0.label == "Boost" } == true)
    }

    @Test("Several profiles live on one device, and the active one is remembered")
    func severalProfilesPerDevice() throws {
        var device = VirtualDeviceProfile(
            name: "Multi", imageIdentifier: "aosp-arm64-14", guestArchitecture: .arm64)
        let racing = InputProfile.newProfile(named: "Racing")
        let shooter = InputProfile.newProfile(named: "Shooter")
        device.upsertInputProfile(racing)
        device.upsertInputProfile(shooter)

        // Three: the starter layout the device was seeded with, plus the two
        // added. Adding a profile does not silently discard the default.
        #expect(device.effectiveInputProfiles.count == 3)
        #expect(device.effectiveInputProfiles.contains { $0.name == "Default" })
        #expect(device.activeInputProfile?.name == "Shooter")

        device.activeInputProfileID = racing.id
        let data = try ConfigurationCoders.makeEncoder().encode(device)
        let restored = try ConfigurationCoders.makeDecoder().decode(VirtualDeviceProfile.self, from: data)
        #expect(restored.activeInputProfile?.name == "Racing")
    }

    @Test("The last profile cannot be removed, so a device always has a mapping")
    func lastProfileIsKept() {
        var device = VirtualDeviceProfile(
            name: "Multi", imageIdentifier: "aosp-arm64-14", guestArchitecture: .arm64)
        let only = InputProfile.newProfile(named: "Only")
        device.upsertInputProfile(only)

        device.removeInputProfile(only.id)
        #expect(device.effectiveInputProfiles.count == 1)
        #expect(device.activeInputProfile != nil)
    }

    @Test("The synthesised default is the SAME profile every time it is asked for")
    func synthesisedDefaultIsStable() {
        // `effectiveInputProfiles` synthesises a starter when a device has none.
        // If that carried a fresh identity each call, the active-profile id would
        // never match anything: selecting a mapping and showing which one is
        // active would both silently do nothing.
        let device = VirtualDeviceProfile(
            name: "Fresh", imageIdentifier: "aosp-arm64-14", guestArchitecture: .arm64)
        #expect(device.inputProfiles == nil)

        let first = device.effectiveInputProfiles
        let second = device.effectiveInputProfiles
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first == second)
        #expect(device.activeInputProfile?.id == device.activeInputProfile?.id)
    }

    @Test("The starter layout is internally consistent")
    func starterProfileIsValid() {
        // It ships with every device, so a mistake here reaches everyone.
        #expect(InputProfile.starter.problems().isEmpty)
        #expect(InputProfile.starter.bindings.count == 11)
    }
}
