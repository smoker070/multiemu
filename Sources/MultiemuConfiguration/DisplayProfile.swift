import CoreGraphics
import Foundation
import MultiemuSupport

/// A guest display configuration.
///
/// This is the guest's **logical** resolution, which is deliberately independent
/// of the macOS window size — resizing the window changes only how the image is
/// fitted, never what the guest believes its screen to be.
public struct DisplayProfile: Sendable, Equatable, Codable {

    public enum Orientation: String, Sendable, Codable, CaseIterable {
        case landscape
        case portrait
    }

    public var widthInPixels: Int
    public var heightInPixels: Int
    /// Android density in dots per inch.
    public var densityDPI: Int

    public init(widthInPixels: Int, heightInPixels: Int, densityDPI: Int) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.densityDPI = densityDPI
    }

    public var orientation: Orientation {
        widthInPixels >= heightInPixels ? .landscape : .portrait
    }

    public var pixelCount: Int { widthInPixels * heightInPixels }

    /// The same profile rotated a quarter turn.
    public func rotated() -> DisplayProfile {
        DisplayProfile(widthInPixels: heightInPixels, heightInPixels: widthInPixels, densityDPI: densityDPI)
    }

    // MARK: - Limits

    /// Below this Android's own layouts stop working.
    public static let minimumDimension = 320
    /// A 3840×2160 framebuffer is 33 MiB per frame; beyond that the frame budget
    /// established in Milestone 5 stops being achievable.
    public static let maximumDimension = 3840
    public static let maximumPixelCount = 3840 * 2160

    /// The square framebuffer a guest must be given at boot to reach any preset,
    /// in either orientation, without restarting.
    ///
    /// Measured, not assumed. QEMU builds the EDID it advertises from the
    /// virtio-GPU's boot `xres`/`yres`, and a guest will not select a mode
    /// larger than that EDID offers — the limit is per axis and is fixed at
    /// boot, not raised when a later resize is requested.
    ///
    /// | Boot allocation | Presets the guest honoured |
    /// | --- | --- |
    /// | 1280×720 | 1 of 10 — everything larger fell back to 800×600 |
    /// | 2560×1440 | 6 of 10 — every failure had a height above 1440 |
    /// | **2560×2560** | **10 of 10**, rotation included |
    ///
    /// Square because rotation swaps the axes: a 2560×1440 allocation cannot
    /// display 1440×2560. At 4 bytes a pixel this costs about 26 MB of host
    /// memory, well inside virtio-GPU's 256 MB `max_hostmem` default.
    ///
    /// See `docs/VERIFY.md` → `GUEST-MODE-IS-BOUNDED-BY-THE-BOOT-FRAMEBUFFER`.
    public static let runtimeFramebufferSide = 2560
    /// Android's density buckets run from ldpi to xxxhdpi.
    public static let minimumDPI = 120
    public static let maximumDPI = 640

    public func problems() -> [String] {
        var problems: [String] = []
        for (name, value) in [("Width", widthInPixels), ("Height", heightInPixels)] {
            if value < Self.minimumDimension || value > Self.maximumDimension {
                problems.append("\(name) must be between \(Self.minimumDimension) and \(Self.maximumDimension); got \(value).")
            }
            // virtio-gpu scanouts and most video encoders require even
            // dimensions; an odd one produces a skewed or rejected surface.
            if value % 2 != 0 {
                problems.append("\(name) must be even; got \(value).")
            }
        }
        if pixelCount > Self.maximumPixelCount {
            problems.append("\(widthInPixels)×\(heightInPixels) exceeds the supported maximum of 3840×2160.")
        }
        if densityDPI < Self.minimumDPI || densityDPI > Self.maximumDPI {
            problems.append("Density must be between \(Self.minimumDPI) and \(Self.maximumDPI) dpi; got \(densityDPI).")
        }
        return problems
    }

    public var isValid: Bool { problems().isEmpty }

    // MARK: - Presets

    public struct Preset: Sendable, Equatable {
        public var name: String
        public var profile: DisplayProfile
    }

    /// Densities are chosen so a desktop-sized window shows a sensible amount of
    /// Android UI rather than phone-sized controls blown up. They are a starting
    /// point to be validated against a real Android guest in Milestone 12, not a
    /// measured optimum.
    public static let landscapePresets: [Preset] = [
        Preset(name: "1280 × 720", profile: .init(widthInPixels: 1280, heightInPixels: 720, densityDPI: 160)),
        Preset(name: "1600 × 900", profile: .init(widthInPixels: 1600, heightInPixels: 900, densityDPI: 200)),
        Preset(name: "1920 × 1080", profile: .init(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 240)),
        Preset(name: "2560 × 1440", profile: .init(widthInPixels: 2560, heightInPixels: 1440, densityDPI: 320)),
    ]

    public static let portraitPresets: [Preset] = landscapePresets.map {
        Preset(name: "\($0.profile.heightInPixels) × \($0.profile.widthInPixels)", profile: $0.profile.rotated())
    }

    public static var allPresets: [Preset] { landscapePresets + portraitPresets }

    /// Product default: 1920×1080 landscape.
    public static let `default` = DisplayProfile(widthInPixels: 1920, heightInPixels: 1080, densityDPI: 240)

    public static func preset(named name: String) -> DisplayProfile? {
        allPresets.first { $0.name == name }?.profile
    }
}
