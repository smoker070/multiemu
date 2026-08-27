import Foundation
import Testing
@testable import MultiemuBackend
import MultiemuHost
import MultiemuSupport

/// Admission control once more than one device can run.
///
/// A single-device product never needed these: every check was "does this
/// request fit the Mac?". The moment two devices run, the real question becomes
/// "does it fit the Mac *alongside what is already running?*", and the answer
/// differs.
@Suite("Multi-instance admission")
struct CommittedResourceTests {

    private func request(memoryGiB: UInt64, storageGiB: UInt64 = 32, vcpus: Int = 4)
        -> GuestResourceRequest {
        GuestResourceRequest(
            memoryBytes: memoryGiB * ByteCount.giB,
            storageBytes: storageGiB * ByteCount.giB,
            vcpuCount: vcpus
        )
    }

    @Test("Nothing committed is the default, so single-device behaviour is unchanged")
    func defaultIsNoCommitment() {
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 16 * ByteCount.giB)
        let withDefault = ResourceValidator.validate(request(memoryGiB: 4), host: host)
        let withExplicitNone = ResourceValidator.validate(
            request(memoryGiB: 4), host: host, committed: .none)
        #expect(withDefault.isAllowed)
        #expect(withDefault.errors.count == withExplicitNone.errors.count)
        #expect(CommittedResources.none.deviceCount == 0)
    }

    @Test("A second device is refused once the host memory budget is spent")
    func secondDeviceRefusedOnMemory() {
        // 16 GiB: budget is min(60% = 9.6, 16 - 4 reserve = 12) = 9.6 GiB.
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 16 * ByteCount.giB)
        let budget = ResourceValidator.maximumAllowedGuestMemory(physicalBytes: 16 * ByteCount.giB)

        // 6 GiB running + 4 GiB requested = 10 GiB, past the 9.6 GiB budget.
        let committed = CommittedResources.summing([request(memoryGiB: 6)])
        let result = ResourceValidator.validate(request(memoryGiB: 4), host: host, committed: committed)

        #expect(!result.isAllowed)
        #expect(committed.memoryBytes + 4 * ByteCount.giB > budget)
        // It must say the budget is spent, not that the device is too big --
        // the remedy is to stop a device, not to reconfigure this one.
        guard case .hostBudgetExhausted(_, _, let committedBytes, _, let running)? =
            result.errors.first(where: {
                if case .hostBudgetExhausted = $0 { return true } else { return false }
            })
        else {
            Issue.record("expected hostBudgetExhausted, got \(result.errors)")
            return
        }
        #expect(committedBytes == 6 * ByteCount.giB)
        #expect(running == 1)
    }

    @Test("A second device that still fits the budget is admitted")
    func secondDeviceAdmittedWhenItFits() {
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 32 * ByteCount.giB)
        let committed = CommittedResources.summing([request(memoryGiB: 4)])
        let result = ResourceValidator.validate(request(memoryGiB: 4), host: host, committed: committed)
        #expect(result.isAllowed)
    }

    @Test("The same request that is refused alongside a running device is allowed alone")
    func admissionDependsOnlyOnWhatIsRunning() {
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 16 * ByteCount.giB)
        let alone = ResourceValidator.validate(request(memoryGiB: 6), host: host)
        let alongside = ResourceValidator.validate(
            request(memoryGiB: 6), host: host,
            committed: CommittedResources.summing([request(memoryGiB: 6)]))
        #expect(alone.isAllowed)
        #expect(!alongside.isAllowed)
    }

    @Test("Summing totals memory, vCPUs and ports — and deliberately not storage")
    func summingSemantics() {
        let running = [request(memoryGiB: 4, storageGiB: 32, vcpus: 4),
                       request(memoryGiB: 2, storageGiB: 16, vcpus: 2)]

        let committed = CommittedResources.summing(running, hostPorts: [5555, 5556])
        #expect(committed.deviceCount == 2)
        #expect(committed.memoryBytes == 6 * ByteCount.giB)
        #expect(committed.vcpuCount == 6)
        #expect(committed.hostPorts == [5555, 5556])
        // Storage is absent on purpose: a device's disk is created with the
        // device, and `qemu-img` does not preallocate a qcow2 — a 64 GiB device
        // occupies about 200 KiB until a guest writes to it. Counting configured
        // sizes would refuse admissions on space nobody took.
    }

    @Test("A configured disk size does not consume the storage budget of another device")
    func configuredStorageIsNotACommitment() {
        let host = HostCapabilities.makeFixture(
            physicalMemoryBytes: 64 * ByteCount.giB,
            availableStorageBytes: 100 * ByteCount.giB
        )
        // Two 64 GiB devices sum to more than the 100 GiB free, and both are
        // still admitted: neither has written anything.
        let committed = CommittedResources.summing([request(memoryGiB: 4, storageGiB: 64)])
        let result = ResourceValidator.validate(
            request(memoryGiB: 4, storageGiB: 64), host: host, committed: committed)
        #expect(result.isAllowed)
    }

    @Test("Total vCPU oversubscription warns rather than refusing")
    func vcpuOversubscriptionWarns() {
        // Measured on the M5: four 2-vCPU guests on 10 logical cores cost 1.51x
        // the solo boot time. Contention is real but mild, so refusing would be
        // wrong; saying nothing would also be wrong.
        let host = HostCapabilities.makeFixture(logicalCores: 10, performanceCores: 4, efficiencyCores: 6)
        let committed = CommittedResources.summing(
            [request(memoryGiB: 2, vcpus: 8)])
        let result = ResourceValidator.validate(request(memoryGiB: 2, vcpus: 4), host: host, committed: committed)

        #expect(result.isAllowed)
        #expect(result.warnings.contains { $0.contains("already running") })
    }

    @Test("A device excluded from its own committed total is admitted; included, it refuses itself")
    func selfExclusionIsRequired() {
        // Admission takes the claim and runs the check together, so by the time
        // the check runs the device is already counted as running. Weighing it
        // against its own claim is the difference between a device that starts
        // and one that refuses itself for no reason.
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 16 * ByteCount.giB)
        let mine = request(memoryGiB: 6)

        let excludingSelf = ResourceValidator.validate(mine, host: host, committed: .none)
        #expect(excludingSelf.isAllowed)

        let countingSelf = ResourceValidator.validate(
            mine, host: host, committed: CommittedResources.summing([mine]))
        #expect(!countingSelf.isAllowed)
    }

    @Test("Devices admitted one at a time never exceed the budget in total")
    func sequentialAdmissionStaysWithinBudget() {
        // Models the admission loop: each device is checked against the ones
        // already admitted, and only an allowed one is added.
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 16 * ByteCount.giB)
        let budget = ResourceValidator.maximumAllowedGuestMemory(physicalBytes: 16 * ByteCount.giB)

        var admitted: [GuestResourceRequest] = []
        var refused = 0
        for _ in 1...6 {
            let candidate = request(memoryGiB: 2)
            let committed = CommittedResources.summing(admitted)
            if ResourceValidator.validate(candidate, host: host, committed: committed).isAllowed {
                admitted.append(candidate)
            } else {
                refused += 1
            }
        }

        // 9.6 GiB budget, 2 GiB each: four fit, the last two do not.
        #expect(admitted.count == 4)
        #expect(refused == 2)
        let total = admitted.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        #expect(total <= budget)
    }

    @Test("Devices sharing one pool of free space are warned, not refused")
    func sharedFreeSpaceWarnsRatherThanRefuses() {
        // 12 GiB free clears the 8 GiB floor. A second device starting consumes
        // a few hundred kilobytes, so refusing it would be wrong — but the two
        // of them do drain one pool, and that is worth saying.
        let host = HostCapabilities.makeFixture(
            physicalMemoryBytes: 32 * ByteCount.giB,
            availableStorageBytes: 12 * ByteCount.giB
        )
        let alone = ResourceValidator.validate(request(memoryGiB: 4), host: host)
        #expect(alone.isAllowed)
        #expect(!alone.warnings.contains { $0.contains("same") })

        let committed = CommittedResources.summing([request(memoryGiB: 4)])
        let alongside = ResourceValidator.validate(request(memoryGiB: 4), host: host, committed: committed)
        #expect(alongside.isAllowed)
        #expect(alongside.warnings.contains { $0.contains("free space") })
    }
}
