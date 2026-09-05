import Foundation
import XCTest
@testable import MultiemuBackend

/// The record exists so a launch after a crash can clear its own leftover
/// backend — the case `OrphanReaper` cannot reach, because a `SIGKILL` runs
/// none of our code. It hands a pid to `kill(2)`, so most of what is worth
/// testing is what it **refuses** to do.
final class BackendRunRecordTests: XCTestCase {

    private var directory: URL!
    private var disk: URL!
    private var spawned: [Process] = []

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        disk = directory.appendingPathComponent("composite.qcow2")
        try Data(count: 4096).write(to: disk)
    }

    override func tearDownWithError() throws {
        for process in spawned where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        spawned.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in for a leftover backend: long-lived, harmless, killable.
    @discardableResult
    private func spawnSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        try process.run()
        spawned.append(process)
        return process
    }

    private func record(for process: Process, executable: String = "/bin/sleep") throws -> BackendRunRecord {
        let live = try XCTUnwrap(BackendRunRecord.liveProcess(process.processIdentifier))
        return BackendRunRecord(
            processIdentifier: process.processIdentifier,
            startedAtSeconds: live.seconds,
            startedAtMicroseconds: live.microseconds,
            executablePath: executable,
            processName: live.name
        )
    }

    // MARK: What it recognises

    func testARecordRecognisesTheProcessItDescribes() throws {
        let process = try spawnSleeper()
        XCTAssertTrue(try record(for: process).namesALiveBackend)
    }

    func testARecordSurvivesAWriteAndReadRoundTrip() throws {
        let process = try spawnSleeper()
        let written = try record(for: process)
        BackendRunRecord.write(written, besideDisk: disk)
        let read = try XCTUnwrap(BackendRunRecord.read(besideDisk: disk))
        // Microsecond precision must survive JSON, or every identity check
        // fails and the feature silently stops working.
        XCTAssertEqual(read.startedAtSeconds, written.startedAtSeconds)
        XCTAssertEqual(read.startedAtMicroseconds, written.startedAtMicroseconds)
        XCTAssertEqual(read.processIdentifier, written.processIdentifier)
    }

    // MARK: What it refuses

    func testAPidWhoseStartTimeDiffersIsNotOurs() throws {
        // The pid-reuse case, which is the whole reason the start time is
        // stored. A record naming a live pid that started at a different
        // moment describes a process that has since been replaced.
        let process = try spawnSleeper()
        var forged = try record(for: process)
        forged.startedAtMicroseconds &+= 1
        XCTAssertFalse(forged.namesALiveBackend,
                       "a one-microsecond difference must be enough to disown the pid")
    }

    func testAPidRunningADifferentProgramIsNotOurs() throws {
        let process = try spawnSleeper()
        var wrong = try record(for: process)
        wrong.processName = "some-editor"
        XCTAssertFalse(wrong.namesALiveBackend)
    }

    func testTheRecordedNameSurvivesTheRoundTripExactly() throws {
        // The name is compared with `==`, so a record that loses or mangles it
        // would make the reclaim quietly stop recognising its own backend and
        // the wedge would come back. (An earlier version of this test tried to
        // prove the shim case with /usr/bin/python3, whose `p_comm` is "Python"
        // from a shell but "python3" via `Process` — it was sampling a re-exec
        // race, not this code. The behaviour it meant to protect is the exact
        // comparison below.)
        let process = try spawnSleeper()
        let written = try record(for: process)
        BackendRunRecord.write(written, besideDisk: disk)
        let read = try XCTUnwrap(BackendRunRecord.read(besideDisk: disk))
        XCTAssertEqual(read.processName, written.processName)
        XCTAssertTrue(read.namesALiveBackend)
    }

    func testADeadPidIsNotOurs() throws {
        let process = try spawnSleeper()
        let stale = try record(for: process)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertFalse(stale.namesALiveBackend)
    }

    func testTheRecordNeverNamesThisProcess() {
        // A corrupted record pointing at us must not persuade the reclaim to
        // signal the app itself.
        let live = BackendRunRecord.liveProcess(getpid())
        let suicidal = BackendRunRecord(
            processIdentifier: getpid(),
            startedAtSeconds: live?.seconds ?? 0,
            startedAtMicroseconds: live?.microseconds ?? 0,
            executablePath: ProcessInfo.processInfo.arguments.first ?? "xctest",
            processName: live?.name ?? "xctest"
        )
        XCTAssertFalse(suicidal.namesALiveBackend)
    }

    /// The most important test here: a stale record must not get an innocent
    /// process killed.
    func testAStaleRecordDoesNotKillTheProcessNowHoldingThatPid() async throws {
        let innocent = try spawnSleeper()
        // Same pid, wrong start time — exactly what pid reuse produces.
        var forged = try record(for: innocent)
        forged.startedAtSeconds &-= 500
        BackendRunRecord.write(forged, besideDisk: disk)

        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .refusedToActOnAStaleRecord)
        XCTAssertTrue(innocent.isRunning, "an unrelated process must not be signalled")
        XCTAssertNil(BackendRunRecord.read(besideDisk: disk),
                     "the stale record should be deleted rather than retried forever")
    }

    // MARK: What it does

    func testReclaimStopsAProcessItCanProveIsOurs() async throws {
        let leftover = try spawnSleeper()
        BackendRunRecord.write(try record(for: leftover), besideDisk: disk)

        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .stoppedGracefully(pid: leftover.processIdentifier))
        XCTAssertFalse(leftover.isRunning)
        XCTAssertNil(BackendRunRecord.read(besideDisk: disk),
                     "a reclaimed record must not be left for the next launch")
    }

    func testReclaimWithNoRecordDoesNothing() async {
        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .nothingToReclaim)
    }

    func testARecordForAnExitedProcessIsQuietlyDiscarded() async throws {
        let process = try spawnSleeper()
        BackendRunRecord.write(try record(for: process), besideDisk: disk)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .nothingToReclaim)
        XCTAssertNil(BackendRunRecord.read(besideDisk: disk))
    }

    func testAGarbageRecordIsIgnoredRatherThanCrashing() async throws {
        try Data("not json at all".utf8)
            .write(to: BackendRunRecord.url(besideDisk: disk))
        XCTAssertNil(BackendRunRecord.read(besideDisk: disk))
        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .nothingToReclaim)
    }

    /// End to end: the field failure, reproduced and then healed.
    func testAnOrphanHoldingTheDiskIsClearedAndTheDiskFreed() async throws {
        // A leftover backend holding the write lock, exactly as an orphan does.
        let leftover = try spawnSleeper()
        let descriptor = open(disk.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var lock = flock()
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 101
        lock.l_len = 1
        lock.l_type = Int16(F_WRLCK)
        XCTAssertEqual(fcntl(descriptor, F_OFD_SETLK, &lock), 0)
        XCTAssertTrue(DiskImageLock.hasWriter(at: disk), "precondition: the disk is held")

        BackendRunRecord.write(try record(for: leftover), besideDisk: disk)
        let outcome = await BackendRunRecord.reclaim(besideDisk: disk)
        XCTAssertEqual(outcome, .stoppedGracefully(pid: leftover.processIdentifier))

        // The lock in this test is held by the test's own descriptor rather
        // than by the sleeper, so release it the way the killed process would
        // and confirm the disk is usable again.
        close(descriptor)
        XCTAssertFalse(DiskImageLock.hasWriter(at: disk))
    }
}
