# Entitlements

**Do not put XML comments in these `.plist` files.**

`codesign --entitlements` hands the file to AMFI's XML parser, which is stricter
than `plutil` and **rejects `<!-- -->` comments**:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 10
```

`plutil -lint` accepts a commented file happily, so this failure only appears at
signing time. Discovered in Milestone 2. All explanation therefore lives in this
file, and the plists stay bare.

## `Multiemu.app.entitlements`

The application deliberately carries **no** virtualization entitlement. It
cannot create a VM, and that is the design: hypervisor privilege lives on the
helper that needs it and nowhere else.

Absent on purpose:

| Entitlement | Why it is not here |
| --- | --- |
| `com.apple.security.hypervisor` | QEMU helper only |
| `com.apple.security.virtualization` | VZ prototype helper only |
| `com.apple.vm.networking` | Managed entitlement requiring Apple's approval; avoided by defaulting to user-mode networking |
| `com.apple.security.cs.disable-library-validation` | Never needed — helpers are separate processes, not dylibs loaded into ours |

## `MultiemuQEMUHelper.entitlements`

Applied to the bundled `qemu-system-*` executables. Required for `-accel hvf`,
which calls Hypervisor.framework.

**Verified in Milestone 2 (`VERIFY.md` → `HVF-ENTITLEMENT-SET`):**
`com.apple.security.hypervisor` alone, on an **ad-hoc** signature, is sufficient
to create a VM, map guest memory, create a vCPU and execute guest instructions
on macOS 26.5.2 / Apple M5. Without it, `hv_vm_create` returns `HV_DENIED`.

## `MultiemuVZHelper.entitlements`

Applied to the Virtualization.framework comparison prototype.
`VZVirtualMachine` refuses to start without it.

## Usage

```bash
scripts/sign-helper.sh <binary> <entitlements.plist> [identity]
```

Identity defaults to `-` (ad-hoc) for local development. Release builds pass a
Developer ID identity, and the script then adds `--options runtime --timestamp`
because notarization requires the hardened runtime and a secure timestamp.
