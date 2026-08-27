import CoreGraphics
import Foundation
import MultiemuSupport

/// Routes keyboard and gamepad input through one mapping into one guest.
///
/// A single owner of the `InputMapper` matters: the keyboard and a gamepad can
/// drive the *same* virtual stick, and touch slots are a shared resource. Two
/// independent mappers would hand out the same slot twice and the guest would
/// see one finger where the user made two.
@MainActor
public final class InputRouter {

    public private(set) var mapper: InputMapper
    private let client: QEMUInputClient

    /// One queue, drained by one consumer.
    ///
    /// A Task per batch was wrong: a multi-event batch suspends on a D-Bus reply
    /// between its own events, and a later single-event batch could overtake it
    /// — delivering a stick's `touchUpdate` after the `touchEnd` that followed
    /// it, which leaves the guest holding a finger that was already lifted.
    private let queue: AsyncStream<[GuestInputEvent]>
    private let enqueue: AsyncStream<[GuestInputEvent]>.Continuation
    private var pump: Task<Void, Never>?

    /// Reports bindings that could not be honoured, so they reach the activity
    /// log rather than disappearing.
    public var onDiagnostics: (([String]) -> Void)?

    public init(
        profile: InputProfile,
        guestSize: CGSize,
        client: QEMUInputClient,
        maximumSlots: Int = 10
    ) {
        self.mapper = InputMapper(profile: profile, guestSize: guestSize, maximumSlots: maximumSlots)
        self.client = client
        (queue, enqueue) = AsyncStream<[GuestInputEvent]>.makeStream(
            bufferingPolicy: .bufferingNewest(512))
        startPump()
    }

    private func startPump() {
        let client = self.client
        let queue = self.queue
        pump = Task {
            for await batch in queue {
                for event in batch {
                    do {
                        switch event {
                        case let .touchBegin(slot, x, y):
                            try await client.touch(.begin, slot: slot, x: x, y: y)
                        case let .touchUpdate(slot, x, y):
                            try await client.touch(.update, slot: slot, x: x, y: y)
                        case let .touchEnd(slot, x, y):
                            try await client.touch(.end, slot: slot, x: x, y: y)
                        case let .keyPress(key):
                            try await client.press(key)
                        case let .keyRelease(key):
                            try await client.release(key)
                        }
                    } catch {
                        // Keep draining. Abandoning the batch would skip the
                        // touchEnd that lifts a finger already pressed.
                        MultiemuLog.input.error(
                            "Mapped input delivery failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    /// Stops delivery. Called when the display detaches.
    public func shutdown() {
        enqueue.finish()
        pump?.cancel()
        pump = nil
    }

    public var profile: InputProfile { mapper.profile }
    public var isMappingActive: Bool { !mapper.profile.bindings.isEmpty }

    /// True when the mapping claims this key, so the caller must not also send
    /// it to the guest keyboard — the guest would receive both a touch and a
    /// keystroke for one press.
    public func handles(_ key: LinuxKeyCode) -> Bool { mapper.handles(key) }

    public func keyDown(_ key: LinuxKeyCode) { deliver(mapper.keyDown(key)) }
    public func keyUp(_ key: LinuxKeyCode) { deliver(mapper.keyUp(key)) }
    public func apply(_ snapshot: GamepadSnapshot) { deliver(mapper.apply(snapshot)) }
    public func releaseAll() { deliver(mapper.releaseAll()) }

    public func setProfile(_ profile: InputProfile) {
        // Lifts whatever the old profile was holding first; a touch left down in
        // the guest is a finger nothing can raise.
        deliver(mapper.replaceProfile(profile))
    }

    /// Keeps the mapping in step with the guest's own resolution, so positions
    /// stay where the profile put them after a mode change.
    public func setGuestSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != mapper.guestSize else { return }
        // A touch begun at the old scale would end at the new one, so anything
        // held is lifted before the change rather than after it.
        deliver(mapper.releaseAll())
        mapper.guestSize = size
    }

    private func deliver(_ events: [GuestInputEvent]) {
        let diagnostics = mapper.takeDiagnostics()
        if !diagnostics.isEmpty { onDiagnostics?(diagnostics) }
        guard !events.isEmpty else { return }
        // Ordering is the whole point: batches are queued, never raced.
        enqueue.yield(events)
    }
}
