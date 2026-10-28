# Slice 5 Fix #2: Finish Existing Accounting and Ownership Gates

## 1. Specification & Corrected Architectural Contract

### 1.1 Scope & Non-Goals
- **Component Scope**: Synchronous, single-owner disk sink (`DiagnosticDiskSink`) responsible for streaming raw bytes to disk (`stdout.bin` and `stderr.bin`), executing bounded in-place retention compaction when disk caps are reached, sealing persistence state, and publishing an atomic, non-overwriting versioned sidecar (`persistence.json`).
- **Boundaries**:
  - **Single synchronous owner**: `DiagnosticDiskSink` does NOT perform internal thread dispatch or task hopping. A caller/owner component (e.g. `DiagnosticIngress` serial drain queue or capture owner) must serialize invocations. Disk I/O must never run on the pipe reader callback queue.
  - **No production wiring**: This slice does not wire the sink into `SteamSessionDiagnostics`, `Wine.swift`, or `DiagnosticIngress` production paths.
  - **No whole-app or launcher modifications**: Existing launch/session/retention/UI files and `Package.swift` remain untouched.
  - **Honest receipt semantics**: Successful completion of POSIX `write`, `fsync`, `close`, and `rename` operations certifies that the operating system accepted and synced the data to the storage controller; it does not claim universal hardware power-loss survival.

### 1.2 Component-Relative Directory Acquisition & Collision Safety
- **Component-by-Component Traversal from `/`**:
  - Path resolution begins by opening `/` with `O_RDONLY | O_DIRECTORY`.
  - Every path component is traversed sequentially using `openat` with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`.
  - Any symbolic link encountered at any ancestor directory or at the target directory fails immediately with `DiagnosticDiskSinkError.symlinkEncountered`.
- **Private Session Directory Creation**:
  - Session directory creation uses `mkdirat` with private POSIX permissions `0o700`.
  - Collision Resistance: If the session directory already exists, `openat` fails with `EEXIST` (or `mkdirat` fails with `EEXIST`). The sink immediately rejects the session, refusing to adopt, chmod, inspect, or delete pre-existing directories.
  - Parent Directory Holding: The parent directory descriptor is held during session setup so that if setup fails prior to completion, the freshly created session directory is cleanly unlinked with `unlinkat(parentFd, sessionDirName, AT_REMOVEDIR)` without touching any sibling or pre-existing files.
- **Directory Descriptor Anchoring**:
  - Once opened, the session directory descriptor (`dirFd`) anchors all subsequent file operations (`openat`, `unlinkat`, `renameatx_np`, directory `fsync`), eliminating pathname-based race conditions and symlink hijacking.

### 1.3 Descriptor Ownership State Machine
- **Disarm Strictly Before Close**:
  - Every file descriptor (`stdoutFd`, `stderrFd`, `dirFd`, `tmpFd`) is disarmed (assigned `-1`) strictly **before** calling `fileAdapter.close()`.
  - If closing encounters an error (e.g., `EIO` or `EBADF`), no retry is ever attempted, avoiding descriptor recycling bugs where another thread might have reallocated the descriptor.
- **Staging Sidecar Creation Tracking (`didCreateTempSidecar`)**:
  - Opening the temporary sidecar (`.persistence.json.tmp.<uuid>`) with `O_CREAT | O_EXCL` sets `didCreateTempSidecar = true` only upon successful creation.
  - If open fails (e.g. collision with `EEXIST`), `didCreateTempSidecar` remains `false`. Cleanup will never unlink a pre-existing temporary file.
- **Independent Error Retention**:
  - Failures in primary payload write operations and secondary cleanup operations (like closing or unlinking) are recorded independently without erasing either failure outcome.

### 1.4 Verbatim Raw Byte Retention & Zero In-Band Markers
- **Zero In-Band Markers**:
  - `stdout.bin` and `stderr.bin` contain **ONLY** original verbatim payload bytes: exact startup prefix (`head`) and most recent suffix (`tail`) after cuts.
  - No inserted ASCII markers, delimiter text, UTF-8 snapping, or text decoding are applied to payload files under any circumstances.
  - Under cap, reopened files equal the exact original stream byte-for-byte, including binary sequences, NUL bytes (`0x00`), invalid UTF-8, and split multibyte codepoints.
  - Discard counts and retention gap boundaries are strictly segregated to `persistence.json` so concatenated fragments are never mistaken for continuous output.

### 1.5 Honest Accounting Contract
- **Accounting Identities**:
  - `totalAdmittedBytes`: Monotonically increasing count of all valid payload bytes passed into the sink.
  - `landedUniqueBytes`: Total unique payload bytes successfully written to storage; identical to `committedBytes`. Never exceeds `totalAdmittedBytes`.
  - `retainedBytesOnDisk`: Actual current byte count physically present on disk (`retainedHeadBytes + retainedTailBytes`).
  - `retainedHeadBytes`: Startup head bytes retained on disk.
  - `retainedTailBytes`: Rolling suffix bytes retained on disk.
  - `neverWrittenDiscardedBytes`: Admitted payload bytes dropped without ever being written to disk (e.g., middle bytes dropped when a chunk exceeds capacity).
  - `retentionTrimmedBytes`: Admitted bytes originally written to disk that were subsequently removed by compaction.
  - `discardedBytes`: Total dropped bytes (`neverWrittenDiscardedBytes + retentionTrimmedBytes`).
  - `physicalWriteBytes`: Total raw bytes transferred across all `write` syscalls.
  - `physicalRewriteBytes`: Total raw bytes written during compaction rewrites.
  - `diskPayloadKnown`: Boolean flag indicating if the on-disk payload size and state are known with certainty. Any ambiguous write, seek, or truncate error clears this flag to `false`.
- **First Chunk Exceeding Stream Cap (Case 1)**:
  - If the very first chunk exceeds `maxBytesPerStream` (e.g., 600 bytes with cap 500, head 100, tail 200):
    - Head commits 100 bytes.
    - Suffix commits latest 200 bytes.
    - Middle 300 bytes are never written to disk.
    - Exact accounting: `totalAdmittedBytes = 600`, `landedUniqueBytes = 300`, `committedBytes = 300`, `retainedBytesOnDisk = 300`, `neverWrittenDiscardedBytes = 300`, `retentionTrimmedBytes = 0`, `discardedBytes = 300`.
    - Subsequent appends (e.g. 50 bytes) land smoothly (`retainedBytesOnDisk = 350`). Later compaction retains head and newest suffix budget.
- **Partial Compaction & Suffix Progress (Case 2)**:
  - When compaction writes a head (100 bytes) and then experiences a short write or failure while writing suffix (e.g., lands 37 bytes of 200):
    - Suffix progress is preserved: `retainedHeadBytes = 100`, `retainedTailBytes = 37`, `retainedBytesOnDisk = 137`.
    - Stage outcome records partial progress with `.failed` status and landed byte count.
- **Ambiguous Failure Handling (Case 3)**:
  - An unverified write or truncate error marks `diskPayloadKnown = false` and preserves state without asserting inaccurate disk sizes.
- **Accurate Error Classification (Case 4)**:
  - Short writes are classified specifically as `DiagnosticDiskSinkError.shortWrite(attempted:actual:)` rather than fabricating an artificial `ENOSPC`.

### 1.6 Publication Discipline
- Temporary sidecar staged as `.persistence.json.tmp.<uuid>`.
- Published using Darwin `renameatx_np(dirFd, tmp, dirFd, "persistence.json", RENAME_EXCL)`.
- Rejects overwriting if `persistence.json` already exists (`EEXIST`), leaving the pre-existing file unmodified and failing safely.

---

## 2. Review Base & Frozen Hashes

- **Base Commit**: `8cb0eb6404c0bd95bc563b9cb3bcccc224a56633`
- **Frozen Foundation Files Verification**:
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticCaptureCore.swift`: `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticCaptureCoreTests.swift`: `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticPipeReader.swift`: `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticPipeReaderTests.swift`: `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticSubprocessCaptureTests.swift`: `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f`
  - `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticIngress.swift`: `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775`
  - `WhiskyKit/Tests/WhiskyKitTests/DiagnosticIngressTests.swift`: `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58`

---

## 3. Implementation Files & Hashes

- `WhiskyKit/Sources/WhiskyKit/Steam/DiagnosticDiskSink.swift` (1450 lines)
  - SHA256: `883d3c5061b54856398604d62cd401d945ccccedb9e47756bd4d32c69ccad6ca`
- `WhiskyKit/Tests/WhiskyKitTests/DiagnosticDiskSinkTests.swift` (689 lines)
  - SHA256: `5d6a4b7ae4311913822e34fd3e7f6afcca36ef5b32e073d1860634f6b709f594`

---

## 4. Test Verification Summary

All test suites were executed with worktree-local caches and zero network access:
- `DiagnosticDiskSinkTests`: 5/5 passed (0.055s)
- `DiagnosticIngressTests`: 7/7 passed (0.056s)
- `DiagnosticCaptureCoreTests`: 47/47 passed (0.005s)
- `DiagnosticPipeReaderTests`: 27/27 passed (0.008s)
Total: 86 passed, 0 failed.

Notice:
- `DiagnosticSubprocessCaptureTests` was intentionally excluded per bounded scope instructions.
- Whole-app build was not attempted.
- The disk sink remains unwired in production pending owner/lifecycle integration.
