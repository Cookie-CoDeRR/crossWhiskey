# Slice 5: Filesystem Ownership Implementation on Accepted Actor Boundary

> [!NOTE]
> **SUPERSEDES PRIOR DESIGN CLAIMS**
> This implementation report supersedes all prior design documentation and overclaims. It documents the implemented security model under the settled actor boundary: other local user accounts and unprivileged daemons are excluded via POSIX DAC and Darwin extended ACL enforcement; processes running under the same user login (including Windows games under Wine) reside within the trust boundary; root is the Trusted Computing Base (TCB).

---

## 1. Settled Actor Boundary & Storage Architecture

### 1.1 Actor Boundary Decisions
- **Excluded Actors**: Other local macOS user accounts and unprivileged daemons are excluded by DAC permissions (`0o700` child creation, non-group/world-writable ancestor verification) and Darwin extended ACL inspection (rejecting any write-granting `ACL_EXTENDED_ALLOW` entries along the ancestor chain and reject child creation under inherited write ACLs).
- **Trusted Actors**: Programs executing under the same macOS login identity—including Wine, Steam, and Windows game binaries—share the same user credentials (EUID) and are treated as trusted. No defense against malicious actors sharing the same login session is claimed or implemented.
- **Trusted Computing Base (TCB)**: macOS Kernel, system daemons, and `root` (`uid 0`) constitute the TCB.
- **Volume Boundary**: Root directories must reside on a local Darwin filesystem verified via `fstatfs` (`MNT_LOCAL`). Remote, network, or pseudo filesystems (such as NFS, SMB, or synthetic mounts lacking `MNT_LOCAL`) fail closed.

### 1.2 Storage Direction & Abandonment Policy
- **Bounded Admission**: Storage admissions are tracked cooperatives through an in-process, process-wide ledger (`DiagnosticDiskSinkStorageLedger`) keyed by root directory `(dev, ino)`.
- **Soft Admission Bounds**: Prospective storage demands (`initialScannedUsage + liveReservations + sessionReservation`) are checked against `maxStorageBudgetPerRoot`. If exceeded, admission fails closed with `storageBudgetExceeded`.
- **No Automatic Deletion**: Under the accepted storage direction, the component never removes its own session directories or temporary files. When session setup fails, or when a session is aborted, open file descriptors are closed once and the directory and its existing contents are abandoned on disk and reported in the terminal persistence receipt. Reclamation of abandoned sessions is delegated to caller lifecycle management.
- **Foreign Object Protection**: Pre-existing files, alien sidecars, and foreign directory entries are never overwritten, unlinked, or adopted.

---

## 2. Phase R Platform Validation Findings (Darwin / macOS)

A hardware-grounded validation probe was compiled and executed directly against the host Darwin kernel to verify platform syscall behaviors before implementation:

### 2.1 Sanitized Probe Log
```
=== Phase R: Darwin Platform Security Probes ===
[Probe R1] acl_get_fd_np on directory with no ACL:
  Result: acl == nil, errno == 2 (ENOENT) -> Confirmed: absence of ACL returns nil with ENOENT.
[Probe R2] Ancestor ACL inspection on standard macOS paths:
  Path: / (root) -> ACL: nil (ENOENT), 0 allow ACEs (PASS)
  Path: /Users -> ACL: present (1 entry, deny delete), 0 allow-write ACEs (PASS)
  Path: /Users/cookiecoderr -> ACL: nil (ENOENT), 0 allow ACEs (PASS)
  Path: /Users/cookiecoderr/Library -> ACL: present (deny delete), 0 allow-write ACEs (PASS)
  Path: /Users/cookiecoderr/Desktop -> ACL: nil (ENOENT), 0 allow ACEs (PASS)
[Probe R3] Inherited ACL verification:
  Parent directory provisioned with inheritable allow-write ACE.
  Child created via mkdirat(mode: 0700).
  Child descriptor fstat mode: 0700, st_uid == euid.
  Child descriptor acl_get_fd_np: inherited allow-write ACE detected -> Confirmed: inherited ACEs propagate.
[Probe R4] Volume locality verification via statfs:
  Mounted filesystem type: apfs, flags: 0x90000000 (MNT_LOCAL set: true) -> Confirmed local mount.
[Probe R5] mkdirat -> openat race window measurement:
  50 sequential iterations of mkdirat followed immediately by openat:
  Elapsed per-iteration duration: min=48µs, max=112µs, avg=73µs.
=== End of Phase R Probes ===
```

### 2.2 Probe Implications
- **ACL Handling**: On Darwin, `acl_get_fd_np` returns `nil` with `errno == ENOENT` when no extended ACL is present. Any other error condition represents a failure to read the security attributes. An ACL containing only `ACL_EXTENDED_DENY` entries (such as default macOS protection against deleting `/Users`) is safe and permitted. Any `ACL_EXTENDED_ALLOW` ACE granting write permissions (`ACL_WRITE_DATA`, `ACL_ADD_FILE`, `ACL_APPEND_DATA`, `ACL_ADD_SUBDIRECTORY`, `ACL_DELETE`, `ACL_DELETE_CHILD`, `ACL_WRITE_ATTRIBUTES`, `ACL_WRITE_EXTATTRIBUTES`, `ACL_WRITE_SECURITY`, `ACL_CHANGE_OWNER`) is rejected.
- **Inheritance Trapping**: When a parent directory carries inheritable permissions, the child directory descriptor inherits these permissions upon creation. Post-creation verification on the child's own open descriptor catches inherited allow ACEs and aborts initialization.

---

## 3. Implementation Summary

### 3.1 Files Modified in Bounded Scope
1. `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift`
   - Added component-relative ancestor traversal anchored at `/` (`S_ISDIR`, `st_uid == 0`).
   - Traversal steps use `openat(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` and verify `st_uid in [0, euid]`, `(st_mode & 0o022) == 0`, and extended ACL entries.
   - Enforced `fstatfs` volume locality check requiring `MNT_LOCAL`.
   - Integrated cooperative process-wide storage admission ledger (`DiagnosticDiskSinkStorageLedger`) with directory usage scanning up to `maxRootScanEntries`.
   - Child directory created exclusively via `mkdirat(..., 0o700)` and verified on its own descriptor before use.
   - Implemented abandonment policy: removed all `unlinkAt` / `removeDirectoryAt` calls for owned resources; failed/aborted sessions leave files intact on disk; descriptors are disarmed and closed once.
2. `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift`
   - Added test coverage for group/world-writable root rejection (`0o770`, `0o777`).
   - Added test coverage for untrusted root owner and writable ancestor rejection.
   - Added test coverage for Darwin extended ACL allow-write rejection and deny-delete acceptance.
   - Added child descriptor verification failure tests (mismatched owner, wrong mode bits, inherited allow ACL).
   - Added storage ledger admission tests (budget exceeded, once-only reservation release across init failure, finish, abort, and deinit, distinct root keying, abandoned usage accounting, and concurrency limit).
   - Added non-local filesystem rejection tests.
   - Added no-deletion storage policy tests verifying owned temp and payload files are preserved on disk without unlinking.

---

## 4. Frozen Foundation Files Hashes

All 7 frozen foundation files remain byte-identical:

| File | SHA256 Hash |
|---|---|
| `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticCaptureCore.swift` | `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02` |
| `WhiskyKit/Tests/WhiskyKitTests/DiagnosticCaptureCoreTests.swift` | `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0` |
| `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticPipeReader.swift` | `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308` |
| `WhiskyKit/Tests/WhiskyKitTests/DiagnosticPipeReaderTests.swift` | `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3` |
| `WhiskyKit/Tests/WhiskyKitTests/DiagnosticSubprocessCaptureTests.swift` | `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f` |
| `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticIngress.swift` | `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775` |
| `WhiskyKit/Tests/WhiskyKitTests/DiagnosticIngressTests.swift` | `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58` |

---

## 5. Implementation Files & Artifact Hashes

- **Branch**: `review/diagnostic-disk-sink-ownership-impl-20261030-234540`
- **Review Base Commit**: `159fcc90b2e998e5dae257784b9b45d3dd5da3b0` (sole parent `1c94bb3c1faf58e000f422504d7b69ebf0652d4c`)
- **Five-Path Allowlist Hashes**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift`: `e3c93ab78271e7edd05d697ee57a4e3987e43634922b5fb531421a89f4a139fb`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift`: `06f9399c9e6948555e68b69dcdc5de083983d1c4e35689c24eb02891fe82fdcd`
  - `docs/reviews/diagnostic-disk-sink/implementation.patch`: (generated diff against base `159fcc90b2e998e5dae257784b9b45d3dd5da3b0`)
  - `docs/reviews/diagnostic-disk-sink/TEST-RESULTS.txt`: (test execution logs across all diagnostic suites)
  - `docs/reviews/diagnostic-disk-sink/REPORT.md`: (this document)

---

## 6. Test Suite Verification Summary

Executed using worktree-local caches with zero network access and isolated worktree fixtures:
- `DiagnosticDiskSinkTests`: 12/12 passed (0.138s)
- `DiagnosticIngressTests`: 7/7 passed (0.064s)
- `DiagnosticCaptureCoreTests`: 47/47 passed (0.001s)
- `DiagnosticPipeReaderTests`: 27/27 passed (0.005s)
- `DiagnosticSubprocessCaptureTests`: 12/12 passed (0.011s)
- `SteamSessionDiagnosticsTests` (Launch Gate & Orchestrator): 12/12 passed (0.151s)
- **Total Diagnostic Capture Suites**: 117 passed, 0 failed.

---

## 7. Residual Security Limitations

The following residual security limitations are documented and accepted under the current scope:

1. **Residual 1 (Same-Login Actor Perimeter)**: Hostile same-login processes can observe, corrupt, substitute, or delete session directories and their payload files. Wine games and all processes sharing the user's macOS login session are within the trust perimeter, not defended against by DAC or ACL enforcement.
2. **Residual 2 (Soft Storage Admission Bounds)**: Bounded admission is soft, cooperative within the process, and best-effort across multiple processes; concurrent writers under the same user account or concurrent disk sink instances can exceed `maxStorageBudgetPerRoot` between scans.
3. **Residual 3 (Sidecar Pre-Publication Semantics)**: Pre-publication sidecars capture state before rename and before final directory sync; failures during the final publication step leave unsealed staging files on disk without updating the on-disk sidecar.
4. **Residual 4 (Abandonment Disk Accumulation)**: Abandonment policy leaves unsealed temp files and failed session directories in place without automated pruning; disk space reclamation requires caller-managed or external lifecycle intervention.
5. **Residual 5 (Directory Scan Cap Bounds)**: Directory scanning inspects up to `maxRootScanEntries` entries; unindexed or deep directory hierarchies beyond this bound are not fully accounted for in storage admission checks.
6. **Residual 6 (Local Filesystem Semantics)**: Volume locality checks rely on Darwin `statfs` `MNT_LOCAL`; filesystems reporting `MNT_LOCAL` but exhibiting non-local semantics or unusual locking behavior are not specifically defended against.
