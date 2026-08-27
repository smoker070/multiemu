import Foundation
import Testing
@testable import MultiemuConfiguration

@Suite("Display profiles")
struct DisplayProfileTests {

    @Test("The product's landscape presets are all present and valid")
    func landscapePresets() {
        let sizes = DisplayProfile.landscapePresets.map { ($0.profile.widthInPixels, $0.profile.heightInPixels) }
        #expect(sizes.contains { $0 == (1280, 720) })
        #expect(sizes.contains { $0 == (1600, 900) })
        #expect(sizes.contains { $0 == (1920, 1080) })
        #expect(sizes.contains { $0 == (2560, 1440) })
        for preset in DisplayProfile.landscapePresets {
            #expect(preset.profile.isValid, "\(preset.name) is invalid: \(preset.profile.problems())")
            #expect(preset.profile.orientation == .landscape)
        }
    }

    @Test("The product's portrait presets are all present and valid")
    func portraitPresets() {
        let sizes = DisplayProfile.portraitPresets.map { ($0.profile.widthInPixels, $0.profile.heightInPixels) }
        #expect(sizes.contains { $0 == (720, 1280) })
        #expect(sizes.contains { $0 == (900, 1600) })
        #expect(sizes.contains { $0 == (1080, 1920) })
        #expect(sizes.contains { $0 == (1440, 2560) })
        for preset in DisplayProfile.portraitPresets {
            #expect(preset.profile.isValid)
            #expect(preset.profile.orientation == .portrait)
        }
    }

    @Test("The default is 1920×1080 landscape, as the product specifies")
    func defaultProfile() {
        #expect(DisplayProfile.default.widthInPixels == 1920)
        #expect(DisplayProfile.default.heightInPixels == 1080)
        #expect(DisplayProfile.default.orientation == .landscape)
        #expect(DisplayProfile.default.isValid)
    }

    @Test("Rotation swaps the axes and preserves density")
    func rotation() {
        let landscape = DisplayProfile(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 240)
        let portrait = landscape.rotated()
        #expect(portrait.widthInPixels == 1080 && portrait.heightInPixels == 1920)
        #expect(portrait.densityDPI == 240)
        #expect(portrait.orientation == .portrait)
        #expect(portrait.rotated() == landscape)
    }

    @Test("A square display counts as landscape rather than being ambiguous")
    func squareIsLandscape() {
        #expect(DisplayProfile(widthInPixels: 1024, heightInPixels: 1024, densityDPI: 160).orientation == .landscape)
    }

    @Test("Custom resolutions are validated against safe limits")
    func customValidation() {
        // Too small for Android's own layouts.
        #expect(!DisplayProfile(widthInPixels: 200, heightInPixels: 200, densityDPI: 160).isValid)
        // Beyond the frame budget established in Milestone 5.
        #expect(!DisplayProfile(widthInPixels: 7680, heightInPixels: 4320, densityDPI: 320).isValid)
        // Density outside Android's buckets.
        #expect(!DisplayProfile(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 20).isValid)
        #expect(!DisplayProfile(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 5000).isValid)
        // A valid custom size is accepted.
        #expect(DisplayProfile(widthInPixels: 1440, heightInPixels: 960, densityDPI: 213).isValid)
    }

    @Test("Odd dimensions are rejected, because scanouts and encoders need even ones")
    func oddDimensionsRejected() {
        let profile = DisplayProfile(widthInPixels: 1921, heightInPixels: 1080, densityDPI: 240)
        #expect(profile.problems().contains { $0.contains("must be even") })
    }

    @Test("Presets can be looked up by name")
    func presetLookup() {
        #expect(DisplayProfile.preset(named: "1920 × 1080") == DisplayProfile.default)
        #expect(DisplayProfile.preset(named: "not a preset") == nil)
        #expect(DisplayProfile.allPresets.count == 8)
    }

    @Test("A profile round-trips through JSON")
    func codableRoundTrip() throws {
        let original = DisplayProfile(widthInPixels: 1600, heightInPixels: 900, densityDPI: 200)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DisplayProfile.self, from: data) == original)
    }
}
