import AppKit
import Metal
import MultiemuGraphics
import MultiemuInput
import MultiemuSupport
import QuartzCore

/// The macOS view that shows the guest display.
///
/// The only piece of Multiemu that knows about both AppKit and Metal. It knows
/// nothing about QEMU, D-Bus or backends: it is handed `GuestFrame` values and
/// draws them, so the presentation layer survives a backend change untouched.
@MainActor
public final class GuestDisplayView: NSView {

    /// How the guest image is fitted into the view. Changing it redraws.
    public var scaling: GuestDisplayScaling = .aspectFit {
        didSet { if scaling != oldValue { redraw() } }
    }

    /// Linear filtering for non-integer scales.
    public var smoothScaling = true {
        didSet { if smoothScaling != oldValue { redraw() } }
    }

    /// The guest's logical resolution, independent of the view's size.
    public private(set) var guestResolution: CGSize = .zero

    private let renderer: GuestDisplayRenderer
    private var lastFrame: GuestFrame?
    /// Set once an input channel exists; until then the view is display-only.
    var inputClient: QEMUInputClient?
    /// The active key mapping, when the device has one. A bound key becomes a
    /// touch instead of a keystroke.
    public var inputRouter: InputRouter?
    /// Keys the mapping claimed at press time.
    ///
    /// The route has to be decided once. Re-asking at release means a profile
    /// changed mid-press sends the press one way and the release the other,
    /// stranding a key down in the guest.
    private var keysClaimedByMapping: Set<LinuxKeyCode> = []
    /// True between a button press and its release, so a drag that leaves the
    /// image keeps tracking instead of dropping events.
    var isTrackingDrag = false
    /// Turns host mouse events into guest touches. Stateful: it has to know
    /// whether a finger is down to tell a drag from a hover.
    private var pointerTranslator = PointerTouchTranslator()

    private var metalLayer: CAMetalLayer {
        // `layer` is the backing layer created below, so this cast is total.
        layer as! CAMetalLayer
    }

    public init(renderer: GuestDisplayRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        // The guest drives redraws; drawing on the display link would waste
        // power re-presenting frames that have not changed.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GuestDisplayView is created in code") }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // The guest image is opaque; declaring that lets the compositor skip
        // blending the whole display area every frame.
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    public override var isOpaque: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    // MARK: - Sizing

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        installTrackingAreaIfNeeded()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingAreaIfNeeded()
    }

    /// Keeps the drawable sized in **pixels**, not points.
    ///
    /// This is the whole of HiDPI correctness: on a Retina display the backing
    /// scale factor is 2, so a 960-point-wide view needs a 1920-pixel drawable.
    /// Sizing the drawable in points renders at half resolution and looks soft —
    /// a bug that is easy to miss because the image is otherwise correct.
    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: max(1, bounds.width * scale),
                               height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != pixelSize {
            metalLayer.drawableSize = pixelSize
            redraw()
        }
    }

    /// The drawable size in pixels, for diagnostics and tests.
    public var drawableSizeInPixels: CGSize { metalLayer.drawableSize }
    public var backingScaleFactor: CGFloat { metalLayer.contentsScale }

    // MARK: - Frames

    /// Displays a guest frame.
    public func display(_ frame: GuestFrame) {
        do {
            try renderer.upload(frame)
            lastFrame = frame
            guestResolution = CGSize(width: frame.width, height: frame.height)
            redraw()
        } catch {
            MultiemuLog.graphics.error("Could not display a guest frame: \(String(describing: error), privacy: .public)")
        }
    }

    private func redraw() {
        guard lastFrame != nil, metalLayer.drawableSize.width > 0 else { return }
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(
            into: drawable.texture,
            scaling: scaling,
            smooth: smoothScaling,
            drawable: drawable
        )
    }

    /// Captures what is currently displayed, at the guest's own resolution.
    ///
    /// Screenshots are taken at guest resolution rather than window resolution,
    /// so a screenshot does not change meaning when the user resizes the window.
    public func captureGuestResolutionFrame() throws -> GuestFrame {
        guard guestResolution.width > 0 else {
            throw GuestDisplayRenderer.Failure.textureCreationFailed(width: 0, height: 0)
        }
        return try renderer.renderOffscreen(
            width: Int(guestResolution.width),
            height: Int(guestResolution.height),
            scaling: .stretch,
            smooth: false
        ).readBackAsFrame()
    }
}

// MARK: - Input

extension GuestDisplayView {

    /// Attaches an input client, making the view interactive.
    ///
    /// Separate from initialisation because the display can render before the
    /// input channel exists, and a view that shows frames but silently drops
    /// keystrokes is better than one that refuses to show anything.
    public func attachInput(_ client: QEMUInputClient) {
        inputClient = client
        window?.makeFirstResponder(self)
        installTrackingAreaIfNeeded()
    }

    public override var acceptsFirstResponder: Bool { true }
    /// Clicking into the view should both focus it and reach the guest, rather
    /// than being swallowed as a focus-granting click.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func installTrackingAreaIfNeeded() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// Converts an event location into a guest framebuffer pixel.
    private func guestPoint(for event: NSEvent) -> CGPoint? {
        guard guestResolution.width > 0 else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let location = PointerCoordinateMapper.locate(
            viewPoint: viewPoint,
            viewSize: bounds.size,
            backingScale: backingScaleFactor,
            guestSize: guestResolution,
            scaling: scaling,
            // AppKit views are bottom-left origin unless flipped; the guest
            // framebuffer is top-left.
            flipped: isFlipped
        )
        switch location {
        case .inside(let point): return point
        // Outside the image during a drag still tracks at the edge, so a drag
        // that leaves the letterbox does not simply stop.
        case .outside(let point): return isTrackingDrag ? point : nil
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let key = MacKeyboardMap.linuxKey(forVirtualKey: event.keyCode) else {
            MultiemuLog.input.debug("Unmapped macOS key code \(event.keyCode, privacy: .public)")
            return
        }
        // A mapped key becomes a touch and must NOT also reach the guest
        // keyboard, or one press arrives as two different inputs.
        if let router = inputRouter, router.handles(key) {
            keysClaimedByMapping.insert(key)
            router.keyDown(key)
            return
        }
        send { try await $0.press(key) }
    }

    public override func keyUp(with event: NSEvent) {
        guard let key = MacKeyboardMap.linuxKey(forVirtualKey: event.keyCode) else { return }
        if keysClaimedByMapping.remove(key) != nil {
            inputRouter?.keyUp(key)
            return
        }
        send { try await $0.release(key) }
    }

    /// Modifiers arrive as a state snapshot rather than as press/release, so the
    /// transition has to be derived by diffing against the previous state.
    public override func flagsChanged(with event: NSEvent) {
        guard let key = MacKeyboardMap.linuxKey(forVirtualKey: event.keyCode) else { return }
        let isDown = isModifierDown(key, in: event.modifierFlags)
        send { client in
            if isDown { try await client.press(key) } else { try await client.release(key) }
        }
    }

    private func isModifierDown(_ key: LinuxKeyCode, in flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .leftShift, .rightShift: return flags.contains(.shift)
        case .leftControl, .rightControl: return flags.contains(.control)
        case .leftAlt, .rightAlt: return flags.contains(.option)
        case .leftMeta, .rightMeta: return flags.contains(.command)
        case .capsLock: return flags.contains(.capsLock)
        default: return false
        }
    }

    // MARK: Pointer

    public override func mouseMoved(with event: NSEvent) { movePointer(event) }

    public override func mouseDragged(with event: NSEvent) { movePointer(event) }
    public override func rightMouseDragged(with event: NSEvent) { movePointer(event) }
    public override func otherMouseDragged(with event: NSEvent) { movePointer(event) }

    public override func mouseDown(with event: NSEvent) { pressButton(.left, event) }
    public override func mouseUp(with event: NSEvent) { releaseButton(.left, event) }
    public override func rightMouseDown(with event: NSEvent) { pressButton(.right, event) }
    public override func rightMouseUp(with event: NSEvent) { releaseButton(.right, event) }
    public override func otherMouseDown(with event: NSEvent) { pressButton(.middle, event) }
    public override func otherMouseUp(with event: NSEvent) { releaseButton(.middle, event) }

    public override func scrollWheel(with event: NSEvent) {
        let lines = Int(event.scrollingDeltaY.rounded())
        guard lines != 0, guestResolution.width > 0 else { return }
        let point = guestPoint(for: event)
            ?? CGPoint(x: guestResolution.width / 2, y: guestResolution.height / 2)
        let commands = pointerTranslator.scrolled(
            lines: lines, at: point, guestSize: guestResolution
        )
        send { try await $0.perform(commands) }
    }

    private func movePointer(_ event: NSEvent) {
        guard let point = guestPoint(for: event) else { return }
        let commands = pointerTranslator.moved(to: point)
        send { try await $0.perform(commands) }
    }

    /// A host mouse reaches the guest as a finger, not as a pointer button.
    /// `PointerTouchTranslator` documents why, with the `getevent` capture that
    /// showed the button and the position arriving on two different devices.
    private func pressButton(_ button: QEMUPointerButton, _ event: NSEvent) {
        guard let point = guestPoint(for: event) else { return }
        isTrackingDrag = true
        let commands = pointerTranslator.pressed(button, at: point)
        send { try await $0.perform(commands) }
    }

    private func releaseButton(_ button: QEMUPointerButton, _ event: NSEvent) {
        let point = guestPoint(for: event)
        isTrackingDrag = false
        let commands = pointerTranslator.released(button, at: point)
        send { try await $0.perform(commands) }
    }

    // MARK: Focus

    public override func resignFirstResponder() -> Bool {
        // A modifier held while focus moves away stays down in the guest and
        // makes the emulator look hung, so everything is released on focus loss.
        releaseAllInput()
        return super.resignFirstResponder()
    }

    public func releaseAllInput() {
        // The mapping first: it is holding touches the client knows nothing
        // about, and `releaseAll` on the client does not lift them.
        inputRouter?.releaseAll()
        keysClaimedByMapping.removeAll()
        // A finger is not a button: `releaseAll` lifts the pointer buttons and
        // keys but leaves a multitouch slot down, which reads in the guest as a
        // held press that never ends.
        let cancellation = pointerTranslator.cancelled()
        isTrackingDrag = false
        guard let client = inputClient else { return }
        Task {
            try? await client.perform(cancellation)
            await client.releaseAll()
        }
    }

    private func send(_ body: @escaping @Sendable (QEMUInputClient) async throws -> Void) {
        guard let client = inputClient else { return }
        Task {
            do { try await body(client) }
            catch { MultiemuLog.input.error("Input delivery failed: \(String(describing: error), privacy: .public)") }
        }
    }
}
