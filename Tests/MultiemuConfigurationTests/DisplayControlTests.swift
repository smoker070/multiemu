import Foundation
import Testing
@testable import MultiemuConfiguration
import MultiemuBackend
import MultiemuSupport

/// Runtime display control. The rule these protect is measured, not assumed:
/// a guest cannot select a mode larger than the EDID built from the GPU's boot
/// allocation, per axis, so what is allocated at boot decides what can be
/// applied later without restarting.
@Suite("Display control")
struct DisplayControlTests {

    @Test("The boot allocation covers every preset, in either orientation")
    func framebufferCoversEveryPreset() {
        let largest = DisplayProfile.allPresets
            .flatMap { [$0.profile.widthInPixels, $0.profile.heightInPixels] }
            .max() ?? 0
        // Square, because rotation swaps the axes: a 2560x1440 allocation
        // cannot display 1440x2560, which was observed failing.
        #expect(DisplayProfile.runtimeFramebufferSide >= largest)
        for preset in DisplayProfile.allPresets {
            #expect(preset.profile.widthInPixels <= DisplayProfile.runtimeFramebufferSide)
            #expect(preset.profile.heightInPixels <= DisplayProfile.runtimeFramebufferSide)
        }
    }

    @Test("An attached display asks for a square at least as large as its mode")
    func attachedModeReportsItsAllocation() {
        let mode = GuestDisplayMode.attached(
            widthInPixels: 1920, heightInPixels: 1080,
            framebufferSide: DisplayProfile.runtimeFramebufferSide)
        #expect(mode.bootFramebufferSide == DisplayProfile.runtimeFramebufferSide)

        // Asking for no growth still has to cover the mode itself.
        let pinned = GuestDisplayMode.attached(widthInPixels: 1920, heightInPixels: 1080)
        #expect(pinned.bootFramebufferSide == 1920)

        // A mode taller than the requested square still fits.
        let tall = GuestDisplayMode.attached(
            widthInPixels: 1440, heightInPixels: 2560, framebufferSide: 1920)
        #expect(tall.bootFramebufferSide == 2560)

        #expect(GuestDisplayMode.headless.bootFramebufferSide == nil)
    }

    @Test("Rotating swaps the axes and keeps the density")
    func rotationSwapsAxes() {
        let landscape = DisplayProfile(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 240)
        let portrait = landscape.rotated()
        #expect(portrait.widthInPixels == 1080)
        #expect(portrait.heightInPixels == 1920)
        #expect(portrait.densityDPI == landscape.densityDPI)
        // Turning it twice returns to where it started.
        #expect(portrait.rotated() == landscape)
    }

    @Test("Every preset rotates into another valid profile")
    func everyPresetRotatesValidly() {
        for preset in DisplayProfile.allPresets {
            let rotated = preset.profile.rotated()
            #expect(rotated.problems().isEmpty, "\(preset.name) rotated is invalid")
            // Even dimensions on both axes: virtio-gpu scanouts and video
            // encoders require them, and rotation must not break that.
            #expect(rotated.widthInPixels % 2 == 0)
            #expect(rotated.heightInPixels % 2 == 0)
        }
    }

    @Test("Custom sizes are checked against the documented limits")
    func customSizesAreValidated() {
        // Below the floor.
        #expect(!DisplayProfile(
            widthInPixels: 200, heightInPixels: 200, densityDPI: 240).problems().isEmpty)
        // Above the ceiling.
        #expect(!DisplayProfile(
            widthInPixels: 4096, heightInPixels: 2160, densityDPI: 240).problems().isEmpty)
        // Odd dimensions.
        #expect(!DisplayProfile(
            widthInPixels: 1281, heightInPixels: 720, densityDPI: 240).problems().isEmpty)
        // Density outside the supported band.
        #expect(!DisplayProfile(
            widthInPixels: 1280, heightInPixels: 720, densityDPI: 40).problems().isEmpty)
        // And one that is fine.
        #expect(DisplayProfile(
            widthInPixels: 1600, heightInPixels: 900, densityDPI: 240).problems().isEmpty)
    }
}
