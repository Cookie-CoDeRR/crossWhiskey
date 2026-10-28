# Slice 5 Fix #1: Raw Retention, Honest Outcomes & Owned Resources

## 1. Specification & Corrected Architectural Contract

### 1.1 Scope & Non-Goals
- **Component Scope**: Synchronous, single-owner disk sink (`DiagnosticDiskSink`) responsible for streaming raw bytes to disk (`stdout.bin` and `stderr.bin`), executing bounded in-place retention compaction when disk caps are reached, sealing persistence state, and publishing an atomic, non-overwriting versioned sidecar (`persistence.json`).
- **Boundaries**:
  - **No concurrency or internal queue**: `DiagnosticDiskSink` does NOT perform internal thread dispatch or task hopping. A caller/owner component (e.g. `DiagnosticIngress` serial drain queue or capture owner) must serialize invocations. Disk I/O must never run on the pipe reader callback queue.
  - **No production wiring**: This slice does not wire the sink into `SteamSessionDiagnostics`, `Wine.swift`, or `DiagnosticIngress` production paths.
  - **No whole-app or launcher modifications**: Existing launch/session/retention/UI files and `Package.swift` remain untouched.
  - **No power-loss durability claim**: Successful completion of POSIX `write`, `fsync`, `close`, and `rename` operations certifies that the operating system accepted and synced the data to the storage controller; it does not claim universal hardware power-loss survival.

### 1.2 Directory Safety & Anchored File Operations
- Operates strictly in a caller-provided session directory.
- **Symlink Ancestor & Path Rejection**: Rejects symlinks along the entire ancestor path hierarchy as well as the final directory component (`O_NOFOLLOW` and recursive `lstat` ancestor checks).
- **Directory Descriptor Anchoring**: The session directory is opened with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW` to obtain an owned directory file descriptor (`dirFd`). All subsequent file operations (`openat`, `unlinkat`, `renameatx_np`, directory `fsync`) are anchored directly to this descriptor, eliminating pathname-based race conditions and symlink hijacking.
- **Collision Resistance**: Target files (`stdout.bin`, `stderr.bin`, `persistence.json`, and temporary staging files) must not pre-exist. They are created with `O_CREAT | O_EXCL` with private POSIX permissions (`0o600` for files, `0o700` for directories).
- **Cleanup Confinement**: On initialization failure, explicit `abort()`, or unrecoverable error during setup, the sink removes only the resources it explicitly created, never touching pre-existing user files.

### 1.3 Verbatim Raw Byte Retention & Zero In-Band Markers
- Independent stream files:
  - `DiagnosticStreamKind.stdout` -> `<sessionDir>/stdout.bin`
  - `DiagnosticStreamKind.stderr` -> `<sessionDir>/stderr.bin`
- **Zero In-Band Markers**:
  - `stdout.bin` and `stderr.bin` contain **ONLY** original payload bytes: exact original startup prefix (`head`) and most recent suffix (`tail`) after cuts.
  - No inserted ASCII markers, delimiter text, UTF-8 snapping, or text decoding are applied to payload files under any circumstances.
  - Under cap, reopened files equal the exact original stream byte-for-byte, including binary sequences, NUL bytes (`0x00`), invalid UTF-8, and split multibyte codepoints.
  - Gap disclosure and discard counts are strictly segregated to the sidecar (`persistence.json`) so concatenated fragments are never mistaken for complete continuous output.

### 1.4 Bounded Retention & Exact Accounting
- **Budgets** (configurable via `DiagnosticDiskSinkConfiguration`):
  - `maxBytesPerStream`: 20 MiB (`20,971,520` bytes, matching `Wine.maxLogFileBytes`).
  - `headBudget`: 4 MiB (`4,194,304` bytes).
  - `tailBudget`: 12 MiB (`12,582,912` bytes).
  - `maxChunkBytes`: 64 KiB (`65,536` bytes).
  - `tailTrimThreshold`: 16 MiB (`16,777,216` bytes).
  - `maxSidecarBytes`: 64 KiB (`65,536` bytes).
  - Total payload disk cap for two streams: at most 40 MiB.
- **Compaction & Startup Head Invariants**:
  - The startup head (first `headBudget` bytes) is preserved verbatim even if the very first incoming chunk exceeds the stream cap (`firstChunk > cap`).
  - The rolling tail buffer is sliced strictly from bytes beyond the head, preventing prefix/suffix overlap or double-counting.
  - On compaction:
    1. Startup head is written at offset 0 (if not already committed).
    2. File is truncated to `head.count`.
    3. The most recent suffix (up to `tailBudget`) is written starting at offset `head.count`.
    4. Disk size is strictly bounded: `head.count + suffix.count <= maxBytesPerStream`.
- **Accounting Identities**:
  - `totalAdmittedBytes`: Unique admitted payload bytes.
  - `committedBytes`: Known unique admitted payload bytes successfully landed on disk; never exceeds `totalAdmittedBytes`.
  - `retainedBytesOnDisk`: Actual byte size physically on disk (`head.count + tail.count`).
  - `discardedBytes`: Admitted payload bytes dropped by retention (`totalAdmittedBytes - retainedBytesOnDisk` when state is known).
  - `physicalRewriteBytes`: Disk rewrite counter tracked separately from admitted/committed payload.
  - All counters use saturating arithmetic (`addingReportingOverflow`) to expose overflow rather than wrap.

### 1.5 Bounded Stage Outcomes & Partial Progress Preservation
- POSIX write operations capture partial progress on short writes and errors. If a write lands partial bytes before failing (e.g. storage exhaustion), `committedBytes` and `retainedBytesOnDisk` reflect the exact committed count without double-counting or false zero reporting.
- Independent stage outcomes are tracked per stream (`openOutcome`, `writeOutcome`, `compactionOutcome`, `syncOutcome`, `closeOutcome`) and per metadata publication (`createOutcome`, `writeOutcome`, `syncOutcome`, `closeOutcome`, `publishOutcome`, `directorySyncOutcome`).
- An earlier payload write error does not hide a later metadata error; a close failure does not erase a write or sync failure.

### 1.6 Descriptor Ownership & Atomic No-Overwrite Publication
- **Explicit Descriptor Ownership**: Every file descriptor (`stdout`, `stderr`, `dirFd`, `tmpFd`) has exactly one owner and receives exactly one close attempt on all paths. Ownership is immediately disarmed upon close attempt to prevent descriptor reuse issues.
- **Explicit Abort (`abort()`)**: Callers/tests can safely abort an in-flight sink, closing all descriptors and cleaning up staging files.
- **Atomic No-Overwrite Publication**:
  - The sidecar (`persistence.json`) is staged in `.persistence.json.tmp.<uuid>`.
  - Published using Darwin `renameatx_np(dirFd, tmp, dirFd, "persistence.json", RENAME_EXCL)`.
  - If `persistence.json` already exists at publication time, the call fails with `EEXIST` and refuses to overwrite the destination. The pre-existing file is preserved intact.

---

## 2. Review Base & Frozen Hashes

- **Base Commit**: `029570c40c54510cdbd17f46125f565091633532`
- **Frozen File Verification**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticCaptureCore.swift`: `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticCaptureCoreTests.swift`: `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticPipeReader.swift`: `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticPipeReaderTests.swift`: `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticSubprocessCaptureTests.swift`: `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticIngress.swift`: `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticIngressTests.swift`: `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58`

---

## 3. Implementation Files & Hashes

- `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift` (1137 lines)
  - SHA256: `1fa93db2e0de3e3dfd47f920ac0b091f730e1abc6b23a069acee0b04b91951dc`
- `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift` (516 lines)
  - SHA256: `3278a6741f4c91cce1769fe15eacb10c51cac09efbd045360822220c5a32b88a`

---

## 4. Test Verification Summary

All focused test suites were executed with worktree-local caches and zero network access:
- `DiagnosticDiskSinkTests`: 5/5 passed (0.069s)
- `DiagnosticIngressTests`: 7/7 passed (0.084s)
- `DiagnosticCaptureCoreTests`: 47/47 passed (0.020s)
- `DiagnosticPipeReaderTests`: 27/27 passed (0.038s)
Total: 86 passed, 0 failed.

Notice:
- `DiagnosticSubprocessCaptureTests` was intentionally excluded per bounded scope instructions.
- Whole-app build was not attempted.
- The disk sink remains unwired in production pending owner/lifecycle integration.
