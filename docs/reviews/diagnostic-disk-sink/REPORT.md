# Slice 5: Partial Candidate Validation & Filesystem Ownership Audit

> [!WARNING]
> **PARTIAL CANDIDATE / FILESYSTEM OWNERSHIP GATE STILL OPEN**
> Even though all 88 test cases across the 4 active test suites pass, this candidate is a partial accounting and descriptor-cleanup improvement only. It does NOT close the filesystem ownership gate, does NOT eliminate all race conditions on shared parent directories, and does NOT justify advancing to integration or merging to main.

---

## 1. Candidate Changes & Architectural Accounting Contract

### 1.1 Scope of Applied Candidate
- **Source Changes**:
  - Replaced duplicate append and compaction catch blocks with a unified `writePayload` progress helper that applies confirmed progress once, whether the underlying file adapter returns a short write count or throws an `ioError`/`shortWrite`.
  - Compaction distinguishes first-time landings of incoming head/suffix bytes from rewrites of existing on-disk content.
  - Failures during seek or truncate clear `diskPayloadKnown = false`.
  - Monotonic lifetime counters saturate at `UInt64.max` and set `hasCounterOverflow = true`.
  - Secondary cleanup errors during descriptor closing or unlinking are bounded and recorded as the first secondary cleanup error (`cleanupError`), avoiding unbounded error collection while ensuring primary errors are not overwritten.
  - Parent directory descriptor closure failure during setup reports failure and closes child descriptors once, leaving the freshly created directory in place rather than attempting unsafe reuse of the consumed parent descriptor.
- **Test Additions**:
  - Added coverage for head partial progress (`failOnWriteCommittedBytes = 37`), thrown short writes across head, suffix, and under-cap streams.
  - Added ambiguous head failure and truncate failure testing (`diskPayloadKnown == false`).
  - Added second-compaction seek error testing.
  - Added metadata primary error plus secondary cleanup error verification, ensuring close attempts on temporary files occur exactly once.
  - Added directory-sync failure and independent payload sync and close outcome tracking.

### 1.2 Honest Accounting Identities & Knownness Limits
- **Accounting Values Preserve Only Confirmed Progress**:
  - When `diskPayloadKnown == false` (e.g. following an ambiguous write, seek, or truncate error), on-disk byte values reflect last-confirmed progress rather than exact physical totals.
  - When `hasCounterOverflow == true`, lifetime counters (`totalAdmittedBytes`, `landedUniqueBytes`, `neverWrittenDiscardedBytes`, `retentionTrimmedBytes`) are saturated and cannot claim exact arithmetic precision.
- **Bounded Error Accounting**:
  - Secondary error tracking captures the primary failure plus the first secondary cleanup failure. It does not maintain an exhaustive error history.
- **Sidecar Snapshot Semantics**:
  - The written `persistence.json` sidecar represents a **pre-publication snapshot** of persistence state.
  - Subsequent terminal outcomes (such as sidecar directory sync, final descriptor closes, or rename outcome) exist only in the terminal `PersistenceReceipt` returned to the in-memory caller; the on-disk sidecar does not know its own subsequent publication result.

---

## 2. Filesystem Ownership: Concrete Security Limitations

> [!IMPORTANT]
> **Filesystem Ownership Gate Remains Open**
> No directory permission or ACL enforcement is added by this patch.

1. **Shared Writable Root Vulnerability**:
   - `DiagnosticDiskSink` enforces `O_NOFOLLOW` on traversal and rejects pre-existing child directories via `mkdirat` `EEXIST`.
   - However, if the caller specifies a root directory in a location writable by other processes (e.g., shared temporary directories or unconfined user paths), an attacker or concurrent process can rename, substitute, or delete the parent directory between `mkdirat` and `openat`, or before cleanup operations occur.
2. **Mode-Bit Insufficiency**:
   - Requesting `0o700` mode bits on `mkdirat` does not guarantee isolation on macOS filesystems where inherited ACLs, group permissions, or volume mount flags override standard POSIX permissions.
   - Plain `fstat` mode checks and check-then-unlink patterns are vulnerable to race conditions and cannot guarantee hostile-filesystem safety.
3. **Requirements Before Production Integration**:
   - Enforce a strict root boundary: root must reside in an authenticated, caller-owned private directory hierarchy where no ancestor is writable by untrusted processes.
   - Formal validation of Darwin volume behaviors, ACL inheritance, and same-EUID process isolation must be specified and verified before any production wiring or lifecycle integration is permitted.

---

## 3. Review Base & Frozen Foundation Hashes

- **Base Commit**: `24c2ff5408d29dda0c65cf73a9d8a87f8c1d4f05`
- **Frozen File Verification (All 7 Byte-Identical)**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticCaptureCore.swift`: `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticCaptureCoreTests.swift`: `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticPipeReader.swift`: `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticPipeReaderTests.swift`: `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticSubprocessCaptureTests.swift`: `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticIngress.swift`: `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticIngressTests.swift`: `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58`

---

## 4. Implementation Files & Hashes

- **Candidate Incoming Hashes**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift`: `883d3c5061b54856398604d62cd401d945ccccedb9e47756bd4d32c69ccad6ca`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift`: `5d6a4b7ae4311913822e34fd3e7f6afcca36ef5b32e073d1860634f6b709f594`
- **Candidate Post-Apply Hashes (Zero Post-Apply Corrections Needed)**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift`: `176bc0ea013a0dc59e264640528706bddbc2909bac93aa8a47d74de1e24bd218` (1434 lines)
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift`: `b6840f311eb6311998863e0822e6a1cc3c7af9b1c03c5c5c216402774326ce27` (807 lines)

---

## 5. Test Suite Verification Summary

Executed using worktree-local caches with zero network calls and isolated file fixtures:
- `DiagnosticDiskSinkTests`: 7/7 passed (0.110s)
- `DiagnosticIngressTests`: 7/7 passed (0.064s)
- `DiagnosticCaptureCoreTests`: 47/47 passed (0.006s)
- `DiagnosticPipeReaderTests`: 27/27 passed (0.012s)
- **Total**: 88 passed, 0 failed.

Notice:
- `DiagnosticSubprocessCaptureTests` excluded per bounded scope instructions.
- Zero whole-app build or Wine/game execution was performed.
- Production wiring remains blocked pending closure of the filesystem ownership gate.
