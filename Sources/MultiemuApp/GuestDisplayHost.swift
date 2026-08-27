import MultiemuGraphics
import MultiemuSupport
import MultiemuUI
import MultiemuViewModels
import SwiftUI

/// Bridges the Metal-backed guest display view into SwiftUI.
///
/// The only place AppKit meets SwiftUI in this application. It hands the view
/// frames and an input client; the view knows nothing about devices, sessions
/// or backends.
struct GuestDisplayHost: NSViewRepresentable {
    @Bindable var device: DeviceModel

    func makeNSView(context: Context) -> GuestDisplayView {
        // A renderer failure is not fatal to the app: the device keeps running
        // and the rest of the interface stays usable, which is better than
        // refusing to launch because one Metal call failed.
        guard let renderer = try? GuestDisplayRenderer() else {
            return GuestDisplayView(renderer: context.coordinator.fallbackRenderer)
        }
        let view = GuestDisplayView(renderer: renderer)
        view.scaling = device.scaling
        return view
    }

    func updateNSView(_ view: GuestDisplayView, context: Context) {
        view.scaling = device.scaling

        // The latch is per device, not per view. SwiftUI reuses this view across
        // a selection change, so a device-agnostic flag kept routing every
        // keystroke to whichever guest was attached first.
        if context.coordinator.attachedDeviceID != device.id {
            if context.coordinator.attachedDeviceID != nil {
                // Release into the outgoing guest, or a modifier held during the
                // switch stays down there forever.
                view.releaseAllInput()
                context.coordinator.lastFrameSequence = nil
            }
            if let client = device.inputClient() {
                view.attachInput(client)
                view.inputRouter = device.inputRouter()
                context.coordinator.attachedDeviceID = device.id
            }
        }

        // Compare a counter, not pixels: GuestFrame is Equatable over its whole
        // pixel array, so the old check memcmp'd ~8 MB per frame on the main
        // actor — and did it once per running device.
        if let frame = device.latestFrame,
           context.coordinator.lastFrameSequence != device.framesPresented {
            context.coordinator.lastFrameSequence = device.framesPresented
            view.display(frame)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastFrameSequence: Int?
        var attachedDeviceID: UUID?
        /// Used only if the real renderer could not be created, so the view
        /// still exists and the layout does not collapse.
        lazy var fallbackRenderer: GuestDisplayRenderer = {
            // Force-unwrap is confined to the already-degraded path; if Metal is
            // unavailable at all, the host probe has already reported it as a
            // blocking problem on the setup screen.
            try! GuestDisplayRenderer()
        }()
    }
}
