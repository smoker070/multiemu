import AVFoundation
import Darwin
import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDBus
import MultiemuGraphics
import MultiemuHost
import MultiemuInput
import MultiemuQEMU
import MultiemuRecording
import MultiemuSupport

// multiemu-recording-spike — Milestone 13 verification.
//
// Records a real guest to a file, changes the guest's resolution while
// recording, then reads the file back with AVFoundation. The file is the
// evidence: a recorder that reports success and produces something no player
// can open has failed.

setvbuf(stdout, nil, _IONBF, 0)

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(value)")
}
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-recording-spike: \(message)\n".utf8))
    exit(code)
}

var kernelURL: URL?
var initrdURL: URL?
var seconds = 6
var frameRate = 30
var argv = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < argv.count {
    func next() -> String { index += 1; return index < argv.count ? argv[index] : "" }
    switch argv[index] {
    case "--kernel": kernelURL = URL(fileURLWithPath: next())
    case "--initrd": initrdURL = URL(fileURLWithPath: next())
    case "--seconds": seconds = Int(next()) ?? 6
    case "--fps": frameRate = Int(next()) ?? 30
    default: break
    }
    index += 1
}
guard let kernel = kernelURL else { fail("--kernel is required", code: 64) }
guard let qemuPath = ExternalToolProbe.resolve("qemu-system-aarch64") else {
    fail("qemu-system-aarch64 not found", code: 65)
}

let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu-recording-\(UUID().uuidString).mov")

print("multiemu-recording-spike")
row("qemu", qemuPath)
row("target", "\(seconds) s at \(frameRate) fps")
print("")

let socketPath = QMPClient.makeSocketPath(role: "recording")
let side = DisplayProfile.runtimeFramebufferSide
var arguments = [
    "-machine", "virt", "-accel", "hvf", "-cpu", "host",
    "-smp", "2", "-m", "1024",
    "-device", "virtio-gpu-pci,xres=\(side),yres=\(side)",
    "-display", "dbus,p2p=on",
    "-kernel", kernel.path,
    "-append", "console=ttyAMA0",
    "-serial", "null",
    "-qmp", "unix:\(socketPath),server=on,wait=off",
    "-no-reboot",
]
if let initrd = initrdURL { arguments += ["-initrd", initrd.path] }

let qemu = QEMUProcess(executableURL: URL(fileURLWithPath: qemuPath), arguments: arguments)
let qemuEvents = qemu.events
let drain = Task { for await _ in qemuEvents {} }
do { try qemu.start() } catch { fail("could not start QEMU: \(error)") }

@MainActor
func shutDown(_ code: Int32) -> Never {
    qemu.kill()
    drain.cancel()
    try? FileManager.default.removeItem(at: outputURL)
    exit(code)
}

let control = QMPClient()
do { _ = try await control.connect(toSocketAt: socketPath, timeout: .seconds(20)) }
catch { qemu.kill(); drain.cancel(); fail("QMP did not connect: \(error)") }

var descriptors: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { shutDown(2) }
do {
    try await control.sendFileDescriptor(descriptors[1], named: "displayfd")
    try await control.addClient(protocolName: "@dbus-display", fileDescriptorName: "displayfd")
} catch {
    Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
    qemu.kill(); drain.cancel(); fail("display channel refused: \(error)")
}
Darwin.close(descriptors[1])

let connection = DBusConnection(descriptor: descriptors[0], role: .client)
do { try await connection.authenticate() } catch {
    qemu.kill(); drain.cancel(); fail("D-Bus handshake failed: \(error)")
}
let display = QEMUDisplayClient(consoleConnection: connection)
let frames = display.events
do { try await display.registerListener() } catch {
    qemu.kill(); drain.cancel(); fail("could not register a display listener: \(error)")
}
let input = QEMUInputClient(connection: connection)

/// Holds the recording session so the frame reader can feed it.
actor Feeder {
    private var session: RecordingSession?
    private var framesSeen = 0
    private var sizes: Set<String> = []
    private var newest: GuestFrame?
    func attach(_ session: RecordingSession) { self.session = session }
    func detach() { session = nil }
    func submit(_ frame: GuestFrame) {
        newest = frame
        framesSeen += 1
        sizes.insert("\(frame.width)×\(frame.height)")
        session?.submit(frame)
    }
    func stats() -> (frames: Int, sizes: [String]) { (framesSeen, sizes.sorted()) }
    func latestFrame() -> GuestFrame? { newest }
}
let feeder = Feeder()

let reader = Task {
    for await event in frames {
        if case let .scanout(frame) = event { await feeder.submit(frame) }
    }
}

// Settle the display, then start at whatever the guest is showing.
let firstMode = DisplayProfile(widthInPixels: 1280, heightInPixels: 720, densityDPI: 240)
try? await input.setUIInfo(width: UInt32(firstMode.widthInPixels), height: UInt32(firstMode.heightInPixels))
try? await Task.sleep(for: .seconds(4))

let session = RecordingSession(configuration: .init(
    url: outputURL,
    width: firstMode.widthInPixels, height: firstMode.heightInPixels,
    framesPerSecond: frameRate))
// Seeded with the frame already on screen, exactly as the application does.
let seedFrame = await feeder.latestFrame()
do { try session.start(initialFrame: seedFrame) } catch {
    reader.cancel(); qemu.kill(); drain.cancel(); fail("could not start recording: \(error)")
}
await feeder.attach(session)
row("recording started", "\(firstMode.widthInPixels)×\(firstMode.heightInPixels) at \(frameRate) fps")

// Halfway through, rotate the guest. A file cannot change size, so this
// exercises the path that fits a differently-shaped frame into the recording.
try? await Task.sleep(for: .seconds(Double(seconds) / 2))
let rotated = firstMode.rotated()
try? await input.setUIInfo(width: UInt32(rotated.widthInPixels), height: UInt32(rotated.heightInPixels))
row("rotated mid-recording", "\(rotated.widthInPixels)×\(rotated.heightInPixels)")
try? await Task.sleep(for: .seconds(Double(seconds) / 2))

await feeder.detach()
let summary: GuestRecorder.Summary
do { summary = try await session.stop() } catch {
    reader.cancel(); qemu.kill(); drain.cancel(); fail("could not finish the recording: \(error)")
}
reader.cancel()

let seen = await feeder.stats()
print("")
print("What the recorder reported")
row("frames written", "\(summary.framesWritten)")
row("frames held (guest was still)", "\(summary.framesHeld)")
row("frames dropped (guest outran us)", "\(summary.framesDropped)")
row("ticks skipped (encoder behind)", "\(summary.ticksSkipped)")
row("ticks failed (no buffer / rejected)", "\(summary.ticksFailed)")
row("ticks with no frame yet", "\(summary.ticksWithoutAFrame)")
row("timer ticks", String(format: "%d in %.2f s = %.1f Hz",
    summary.timerTicks, summary.wallClockSeconds,
    Double(summary.timerTicks) / max(0.001, summary.wallClockSeconds)))
row("handler duration", String(format: "avg %.2f ms, slowest %.2f ms",
    summary.averageHandlerSeconds * 1000, summary.slowestHandlerSeconds * 1000))
row("ticks that waited for the encoder",
    String(format: "%d, %.2f s in total", summary.ticksWaited, summary.totalWaitSeconds))
row("guest scanouts seen", "\(seen.frames) at \(seen.sizes.joined(separator: ", "))")
row("file size", ByteCount.describe(summary.fileSizeBytes))
row("wall clock", String(format: "%.2f s", summary.wallClockSeconds))

// --- The file is the evidence ---
print("")
print("What the file says, read back with AVFoundation")
let asset = AVURLAsset(url: outputURL)
guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
    print("  the file has no video track")
    shutDown(1)
}
let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
let duration = (try? await asset.load(.duration))?.seconds ?? 0
let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 0

// Count real samples rather than trusting the header.
var decoded = 0
if let assetReader = try? AVAssetReader(asset: asset) {
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    if assetReader.canAdd(output) {
        assetReader.add(output)
        assetReader.startReading()
        while let buffer = output.copyNextSampleBuffer() {
            decoded += 1
            _ = buffer
        }
    }
}

row("track size", "\(Int(naturalSize.width))×\(Int(naturalSize.height))")
row("duration", String(format: "%.2f s", duration))
row("nominal frame rate", String(format: "%.1f fps", nominalRate))
row("samples decoded from the file", "\(decoded)")

let expectedDuration = Double(summary.framesWritten) / Double(frameRate)
let checks: [(String, Bool)] = [
    ("the file opens and has a video track", true),
    ("track size matches what was requested",
     Int(naturalSize.width) == firstMode.widthInPixels
        && Int(naturalSize.height) == firstMode.heightInPixels),
    ("frame rate matches what was requested", abs(Double(nominalRate) - Double(frameRate)) < 1.5),
    // The container can carry a few extra access units, so this asks that
    // nothing was lost rather than that the counts match exactly.
    ("every written frame is in the file", decoded >= summary.framesWritten),
    ("duration matches the frames written", abs(duration - expectedDuration) < 0.2),
    ("the encoder never fell behind", summary.ticksSkipped == 0),
    ("the guest really changed shape mid-recording", seen.sizes.count > 1),
    // The property a viewer actually notices: six seconds of guest must be six
    // seconds of video. A cadence that slips produces a file that plays fast.
    ("the file plays back in real time",
     abs(duration - summary.wallClockSeconds) < max(0.5, summary.wallClockSeconds * 0.1)),
]

print("")
print("Result")
for (name, ok) in checks { row(name, ok ? "PASS" : "FAIL") }
print("")
row("recording ran for", String(format: "%.2f s of wall clock", summary.wallClockSeconds))
row("file plays back", String(format: "%.2f s", duration))

try? FileManager.default.removeItem(at: outputURL)
shutDown(checks.allSatisfy(\.1) ? 0 : 1)
