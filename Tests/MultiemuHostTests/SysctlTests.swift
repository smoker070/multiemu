import Foundation
import Testing
@testable import MultiemuHost

@Suite("Sysctl")
struct SysctlTests {

    @Test("Known integer keys are readable on every supported macOS host")
    func knownIntegerKeys() {
        #expect((Sysctl.unsigned("hw.memsize") ?? 0) > 0)
        #expect((Sysctl.integer("hw.logicalcpu") ?? 0) > 0)
        #expect((Sysctl.integer("hw.physicalcpu") ?? 0) > 0)
        #expect((Sysctl.unsigned("hw.pagesize") ?? 0) > 0)
    }

    @Test("Known string keys are readable")
    func knownStringKeys() {
        let brand = Sysctl.string("machdep.cpu.brand_string")
        #expect(brand?.isEmpty == false)
        #expect(Sysctl.string("kern.osproductversion")?.isEmpty == false)
    }

    @Test("Absent keys return nil rather than trapping")
    func absentKeys() {
        #expect(Sysctl.string("multiemu.definitely.not.a.key") == nil)
        #expect(Sysctl.integer("multiemu.definitely.not.a.key") == nil)
        #expect(Sysctl.flag("multiemu.definitely.not.a.key") == nil)
        #expect(Sysctl.raw("multiemu.definitely.not.a.key") == nil)
    }

    @Test("kern.hv_support is present and parses as a flag")
    func hypervisorSupportFlag() {
        // Every Mac that can run macOS 14 reports this key. Its *value* may be
        // 0 or 1; only presence and parseability are asserted here so the test
        // stays valid on hosts without virtualization.
        #expect(Sysctl.flag("kern.hv_support") != nil)
    }

    @Test("vm.swapusage decodes to a plausible structure")
    func swapUsageShape() {
        let raw = Sysctl.raw("vm.swapusage")
        #expect(raw != nil)
        #expect((raw?.count ?? 0) >= 24)
    }
}
