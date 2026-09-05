import Foundation
import XCTest
@testable import MultiemuBackend

/// The condition these cover was found in the field, not in review: a QEMU
/// orphaned by a dead app held a device's `composite.qcow2` for 44 hours, and
/// because preflight only checked *readability* — a locked image is perfectly
/// readable — the app spawned a backend that died on the write lock and handed
/// the user raw engine stderr about a process it could not name.
///
/// The lock bytes come from QEMU's `block/file-posix.c` (`RAW_LOCK_PERM_BASE`
/// 100, `RAW_LOCK_SHARED_BASE` 200, `BLK_PERM_WRITE == 1 << 1`), so these tests
/// hold the real bytes rather than asserting against a copy of the logic.
final class DiskImageLockTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage(_ name: String = "disk.qcow2") throws -> URL {
        let url = directory.appendingPathComponent(name)
        // Large enough to contain the lock bytes at offsets 101 and 201.
        try Data(count: 4096).write(to: url)
        return url
    }

    /// Takes the same OFD lock QEMU takes, on the same byte.
    private func lockWriteByte(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR)
        try XCTUnwrap(descriptor >= 0 ? true : nil, "could not open the image")
        var lock = flock()
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 101
        lock.l_len = 1
        lock.l_type = Int16(F_WRLCK)
        XCTAssertEqual(fcntl(descriptor, F_OFD_SETLK, &lock), 0,
                       "the test could not take the lock it means to detect")
        return descriptor
    }

    func testAnUnlockedImageHasNoWriter() throws {
        let image = try makeImage()
        XCTAssertFalse(DiskImageLock.hasWriter(at: image))
    }

    func testALockedImageIsDetected() throws {
        let image = try makeImage()
        let descriptor = try lockWriteByte(image)
        defer { close(descriptor) }
        XCTAssertTrue(DiskImageLock.hasWriter(at: image),
                      "a held write byte must be visible to the probe")
    }

    func testTheLockIsReleasedWithTheDescriptor() throws {
        let image = try makeImage()
        let descriptor = try lockWriteByte(image)
        XCTAssertTrue(DiskImageLock.hasWriter(at: image))
        close(descriptor)
        // An OFD lock dies with the last descriptor referring to it, so a
        // crashed writer must not leave the image looking permanently taken.
        XCTAssertFalse(DiskImageLock.hasWriter(at: image),
                       "closing the holder must free the image")
    }

    func testProbingIsNotItselfALock() throws {
        let image = try makeImage()
        // If the probe took a lock instead of testing for one, the second call
        // would see the first — and preflight would refuse every start after
        // the first one it ever ran.
        XCTAssertFalse(DiskImageLock.hasWriter(at: image))
        XCTAssertFalse(DiskImageLock.hasWriter(at: image))
        let descriptor = try lockWriteByte(image)
        defer { close(descriptor) }
        XCTAssertTrue(DiskImageLock.hasWriter(at: image),
                      "the probe must not have consumed the lock it tests for")
    }

    func testAMissingImageIsNotReportedAsLocked() {
        // An unreadable or absent image is a different fault with its own
        // message. Reporting it as "in use" would send the user hunting for a
        // process that does not exist.
        XCTAssertFalse(DiskImageLock.hasWriter(at: directory.appendingPathComponent("absent.qcow2")))
    }

    func testTheHolderOfAnUnheldImageIsNotNamed() throws {
        let image = try makeImage()
        // Naming a process that is not holding anything would be worse than
        // saying nothing; the message falls back to "could not be identified".
        XCTAssertNil(DiskImageLock.holderDescription(of: image))
    }

    func testTheHolderIsNamedWhenOneExists() throws {
        let image = try makeImage()
        let descriptor = try lockWriteByte(image)
        defer { close(descriptor) }
        // This test process is the holder, so its own name should come back.
        let holder = DiskImageLock.holderDescription(of: image)
        XCTAssertNotNil(holder, "an open holder should be nameable via lsof")
        if let holder {
            XCTAssertTrue(holder.contains("pid \(getpid())"),
                          "expected this process to be named, got: \(holder)")
            // `ps -o comm=` truncates to 16 characters, which once turned a
            // process running from /Applications/Xcode.app into a program
            // called "Xc". The name must come from the kernel instead.
            let expected = BackendRunRecord.liveProcess(getpid())?.name
            XCTAssertNotNil(expected)
            if let expected {
                XCTAssertTrue(holder.contains(expected),
                              "expected the kernel's name '\(expected)', got: \(holder)")
            }
            XCTAssertFalse(holder.contains("/"),
                           "a truncated path leaked into the message: \(holder)")
        }
    }
}
