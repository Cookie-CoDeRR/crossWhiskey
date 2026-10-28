# Slice 5: Isolated Bounded Disk Sink & Persistence Receipt

## 1. Specification & Architectural Contract

### 1.1 Scope & Non-Goals
- **Component Scope**: Synchronous, single-owner disk sink (`DiagnosticDiskSink`) responsible for streaming raw bytes to disk (`stdout.bin` and `stderr.bin`), executing bounded in-place retention compaction when disk caps are reached, sealing persistence state, and publishing an atomic, versioned sidecar (`persistence.json`).
- **Boundaries**:
  - **No concurrency or internal queue**: `DiagnosticDiskSink` does NOT perform internal thread dispatch or task hopping. A caller/owner component (e.g. `DiagnosticIngress` serial drain queue or capture owner) must serialize invocations. Disk I/O must never run on the pipe reader callback queue.
  - **No production wiring**: This slice does not wire the sink into `SteamSessionDiagnostics`, `Wine.swift`, or `DiagnosticIngress` production paths.
  - **No whole-app or launcher modifications**: Existing launch/session/retention/UI files and `Package.swift` remain untouched.
  - **No power-loss durability claim**: Successful completion of POSIX `write`, `fsync`, `close`, and `rename` operations certifies that the operating system accepted and synced the data to the storage controller; it does not claim universal hardware power-loss survival.

### 1.2 Directory Safety & File Ownership
- Operates strictly in a caller-provided session directory.
- **Symlink Rejection**: Rejects symlinks at the directory level (`lstat` check) to prevent directory traversal and symlink hijacking.
- **Collision Resistance**: Target files (`stdout.bin`, `stderr.bin`, `persistence.json`, and temporary staging files) must not pre-exist. They are created with `O_CREAT | O_EXCL` with private POSIX permissions (`0o600` for files, `0o700` for directories).
- **Cleanup Confinement**: On initialization failure or unrecoverable error during setup, the sink removes only the resources it explicitly created, never touching pre-existing user files.

### 1.3 Payload Streaming & Byte Integrity
- Independent stream files:
  - `DiagnosticStreamKind.stdout` -> `<sessionDir>/stdout.bin`
  - `DiagnosticStreamKind.stderr` -> `<sessionDir>/stderr.bin`
- **Chunk Handling**:
  - Chunks up to `maxChunkBytes` (default: 64 KiB = 65,536 bytes).
  - Empty chunks (`data.isEmpty`) are explicitly rejected (`DiagnosticDiskSinkError.emptyChunk`).
  - Oversized chunks (`data.count > maxChunkBytes`) are explicitly rejected (`DiagnosticDiskSinkError.oversizedChunk`).
- **Verbatim Raw Retention**:
  - Under cap, bytes are written exactly as supplied, preserving binary sequences, NUL bytes (`0x00`), invalid UTF-8, and split multibyte codepoints without text parsing or newline snapping.
  - Metadata is strictly segregated to the sidecar (`persistence.json`) and is never interleaved into raw streams under cap.

### 1.4 Budgets, In-Memory Bounds & Retention Compaction
- **Budgets** (configurable via `DiagnosticDiskSinkConfiguration`):
  - `maxBytesPerStream`: 20 MiB (`20,971,520` bytes, matching `Wine.maxLogFileBytes`).
  - `headBudget`: 4 MiB (`4,194,304` bytes).
  - `tailBudget`: 12 MiB (`12,582,912` bytes).
  - `maxChunkBytes`: 64 KiB (`65,536` bytes).
  - `tailTrimThreshold`: 16 MiB (`16,777,216` bytes).
  - `maxSidecarBytes`: 64 KiB (`65,536` bytes).
- **Compaction Algorithm**:
  - When writing a chunk would cause stream disk size to exceed `maxBytesPerStream`:
    1. Startup head (first `headBudget` bytes) is preserved verbatim.
    2. A bounded raw discard marker discloses the retention event and discarded byte count:
       `"\n--- [DIAGNOSTIC RETENTION: <bytes> BYTES DISCARDED (EVENT <count>)] ---\n"`.
    3. The most recent suffix from the rolling tail buffer is written after the marker, fitting within `maxBytesPerStream`.
    4. Truncation ordering: File is truncated to `head.count` BEFORE writing the marker and suffix to guarantee that disk usage never exceeds `maxBytesPerStream` during rewrite.
    5. Partial-write disclosure: If compaction rewrite encounters an I/O error, the stream is marked `partiallyCompacted` / failed, disclosing potential discontinuity rather than claiming atomic rewrite.

### 1.5 Observable Failure & Fail-Closed Semantics
- POSIX I/O errors (`errno`) and operations (`open`, `write`, `seek`, `truncate`, `sync`, `close`, `rename`) are captured with bounded codes.
- On any I/O failure (including short writes or disk exhaustion), the sink transitions immediately to a sealed/failed state. Subsequent write calls fail closed without retry storms.
- Saturating arithmetic is enforced for all byte counters to expose overflow rather than wrap.

### 1.6 Two-Phase Sidecar Publication & Terminal Receipt
- `finish()` seals the sink and executes the following sequence:
  1. Flushes and syncs (`fsync`) all open payload stream file descriptors.
  2. Closes all open payload stream file descriptors.
  3. Prepares the persistence sidecar (`persistence.json`) containing stream accounting and final statuses.
  4. Writes sidecar to a temporary staging file (`.persistence.json.tmp.<uuid>`) in the session directory.
  5. Syncs and closes the staging file.
  6. Atomically renames the staging file to `persistence.json` (`rename(2)`).
  7. Best-effort parent directory sync (`fsync` / `F_FULLFSYNC` on directory descriptor).
- Returns an immutable, idempotent `DiagnosticDiskSinkReceipt`.
- The returned receipt is the sole authority on publication success; the sidecar file cannot self-certify its subsequent rename or directory-sync outcome.
- **Parent Directory Sync Coverage & Limitations**: Darwin APFS flushes directory container structures during directory fsync; this ensures namespace consistency against process crashes, but does not offer universal storage controller durability across all external file systems.

---

## 2. Review Base & Frozen Hashes

- **Base Commit**: `e0fd83a098a67b143786aa972934a9b6f96444d9`
- **Frozen File Verification**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticCaptureCore.swift`: `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticCaptureCoreTests.swift`: `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticPipeReader.swift`: `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticPipeReaderTests.swift`: `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticSubprocessCaptureTests.swift`: `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticIngress.swift`: `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticIngressTests.swift`: `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58`

---

## 3. New Implementation Files & Hashes

- `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift` (939 lines)
  - SHA256: `245948d8c44343c3ce7cb28e359946ed02fdb902ac66c9aa708ff881a833afd4`
- `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift` (518 lines)
  - SHA256: `353cd2836f1b8daf411fca62b3c2b8b6136c701d9358f124edda493531828b85`

---

## 4. Test Verification Summary

All focused test suites were executed with worktree-local caches and zero network access:
- `DiagnosticDiskSinkTests`: 6/6 passed (0.077s)
- `DiagnosticIngressTests`: 7/7 passed (0.062s)
- `DiagnosticCaptureCoreTests`: 47/47 passed (0.004s)
- `DiagnosticPipeReaderTests`: 27/27 passed (0.020s)
Total: 87 passed, 0 failed.

Notice:
- `DiagnosticSubprocessCaptureTests` was intentionally excluded per bounded scope instructions.
- Whole-app build was not attempted.
- The disk sink remains unwired in production pending owner/lifecycle integration.
