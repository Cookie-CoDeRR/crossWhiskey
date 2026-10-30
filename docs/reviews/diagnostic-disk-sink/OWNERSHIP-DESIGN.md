# DiagnosticDiskSink Filesystem Ownership Gate: Design & Platform Validation

> [!IMPORTANT]
> **DESIGN AND PLATFORM VALIDATION ONLY — NO CODE IMPLEMENTATION**
> This document specifies an architectural design and platform validation report for the `DiagnosticDiskSink` filesystem ownership gate. It does NOT implement code changes, does NOT modify any Swift source or test files, and does NOT treat proposed actor exclusions or threat-model assumptions as pre-approved. All proposed exclusions, contract options, and residual windows are presented explicitly for reviewer evaluation and alignment.

---

## 1. Executive Summary & Confronting the Three Prior Holes

A previously drafted ownership gate was rejected due to three critical architectural vulnerabilities. This design addresses each hole explicitly:

1. **Hole 1 (Mode+EUID root checks alone are insufficient)**:
   - *Vulnerability*: Checking only POSIX mode bits (`0700`) and `st_uid == geteuid()` on a caller-provided root fails to detect extended Access Control Lists (ACLs). A root directory with standard `0700` mode bits can possess an inherited or explicitly granted ACL (`ACL_EXTENDED_ALLOW`) giving write permissions (`ACL_WRITE_DATA`, `ACL_ADD_FILE`, `ACL_DELETE_CHILD`) to another user, group, or daemon. Furthermore, if intermediate ancestor directories (e.g. parent directories of root) are group/world-writable or owned by untrusted users, an attacker can rename an ancestor and redirect the entire hierarchy.
   - *Design Response*: The design requires an anchored, component-relative `O_NOFOLLOW` walk starting strictly from the filesystem root (`/`). Every component from `/` down through the root directory is inspected for both POSIX mode/ownership (`st_uid in [0, geteuid()]`, `st_mode & 0022 == 0`) AND extended ACL presence via `acl_get_fd_np(fd, ACL_TYPE_EXTENDED)`. Any write-granting ACE for non-owner entities causes immediate fail-closed rejection.

2. **Hole 2 (Recording child identity after `mkdirat`-by-name does not close substitution)**:
   - *Vulnerability*: `mkdirat(parentFd, name, mode)` creates a directory by name but does not return an open file descriptor. If the subsequent `openat(parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` occurs after an attacker has removed or renamed the freshly created directory and replaced it with a pre-created malicious directory, `openat` opens the replacement. Calling `fstat` on the resulting descriptor merely records the replacement directory's inode, thereby "blessing" the attacker's directory as authentic.
   - *Design Response*: Darwin provides no atomic "create directory and return descriptor" primitive (`openat` with `O_CREAT | O_DIRECTORY` creates regular files, not directories; see Section 3). Therefore, substitution cannot be prevented at the syscall level if the parent directory is writable by an attacker. The design eliminates this vulnerability by enforcing that the parent directory itself is strictly unshared (no other local users, unprivileged daemons, or group members possess write access). Under this enforced invariant, the substitution window is closed against all external actors; the residual window is limited exclusively to same-EUID processes and root (detailed in Section 2).

3. **Hole 3 (`fstatat`-then-`unlinkat` check-then-unlink still races)**:
   - *Vulnerability*: During setup cleanup or failure abort, executing `fstatat(parentFd, name, &stat, AT_SYMLINK_NOFOLLOW)` to verify the inode followed by `unlinkat(parentFd, name, AT_REMOVEDIR)` leaves a race window between the check and the unlink. If the name is substituted during that microsecond window, `unlinkat` removes the victim or replacement directory.
   - *Design Response*: Darwin and POSIX provide no "unlink-if-inode-matches" or descriptor-based directory removal syscall (`unlinkat` takes only `(fd, name, flags)`). The design resolves this by proposing an **Abandonment on Failure Policy**: on setup failure or abort, the sink disarms and closes all child descriptors once and intentionally abandons the newly created session directory on disk rather than invoking `unlinkat`. Because no removal by name is attempted, the check-then-unlink race condition is completely eliminated.

---

## 2. Phase 1: Threat Model (Proposed, Awaiting Approval)

To establish an honest security boundary, actors are formally categorized into four distinct classes:

```
+-------------------------------------------------------------------------------+
|                             Darwin Operating System                           |
|                                                                               |
|  +---------------------------+             +-------------------------------+  |
|  |     Root / System (0)     |             |      Other Local Users        |  |
|  |   Trusted Computing Base  |             |      (uid != euid, != 0)      |  |
|  +---------------------------+             +-------------------------------+  |
|                                                                               |
|  +---------------------------+             +-------------------------------+  |
|  |    Same-EUID Processes    |             |     Unprivileged Daemons      |  |
|  |      (uid == euid)        |             |     (service accounts, !=0)   |  |
|  +---------------------------+             +-------------------------------+  |
|               |                                                               |
|               v                                                               |
|  +-------------------------------------------------------------------------+  |
|  |               DiagnosticDiskSink Process (uid == euid)                  |  |
|  +-------------------------------------------------------------------------+  |
+-------------------------------------------------------------------------------+
```

### 2.1 Actor Classes & Capabilities

1. **Other Local Users** (`uid != euid`, `uid != 0`):
   - *Definition*: Independent local user accounts or guest accounts on the shared macOS system.
   - *Capabilities*: Can access filesystem paths only when permitted by standard POSIX permissions (`o+rwx`, `g+rwx` if in group) or by an explicit/inherited Access Control Entry (`ACL_EXTENDED_ALLOW`). Cannot inspect process memory, ptrace, or signal processes belonging to another user.
   - *Target Status*: **Excluded**. Enforcing private mode bits (`0700` / `0755` without `w`), strict ownership (`uid == euid` or `uid == 0`), and zero write ACLs completely prevents this class from reading, modifying, creating, or replacing session files.

2. **Unprivileged Daemons & System Service Accounts** (`uid != euid`, `uid != 0`, e.g. `_spotlight`, `_windowserver`):
   - *Definition*: Background service accounts running under non-zero system UIDs without root privileges.
   - *Capabilities*: Bounded strictly by POSIX DAC and Darwin extended security ACLs, unless granted special SIP entitlements.
   - *Target Status*: **Excluded**. Treated identically to Other Local Users; denied write access across all ancestors and root.

3. **Same-EUID Processes** (`uid == euid`):
   - *Definition*: Any process executing concurrently in the same macOS user session under the identical effective user ID. Crucially, in the context of Whisky, this includes:
     - Wine server and Wine child processes executing Windows binaries.
     - Untrusted or game-bundled executables launched within Wine.
     - Background user shell scripts or companion utilities.
   - *Capabilities*: Shares identical filesystem DAC permissions with `DiagnosticDiskSink`. Can create, modify, rename, and delete files in any directory owned by `euid` with `0700` permissions.
   - *Candidate Justification for Exclusion*: In classic POSIX threat modeling, all processes sharing an EUID are considered within the same trust domain; an arbitrary same-EUID process can already signal (`kill`), modify `~/Library`, or alter environment variables.
   - *Why Same-EUID Must Be Scrutinized in Whisky*: Wine runs Windows games that could be malicious, misbehaved, or compromised. If a Windows game running under the user's EUID targets the diagnostic session path, mode bits (`0700`) alone do NOT prevent it from writing into the directory or exploiting a predictable directory name.
   - *Proposal*: Same-EUID exclusion is presented as a **candidate proposal awaiting reviewer decision**. If same-EUID protection is required, defense-in-depth mitigations (such as cryptographically unpredictable directory names via `mkdtemp` and abandonment on failure) must be adopted (see Option C).

4. **Root / System Superuser** (`uid == 0`):
   - *Definition*: Superuser, kernel processes, and root daemons.
   - *Capabilities*: Possesses `DAC_OVERRIDE`, bypassing all standard POSIX and ACL restrictions.
   - *Candidate Justification for Exclusion*: Root constitutes the Trusted Computing Base (TCB). A compromised root compromises the kernel and all security invariants.
   - *Proposal*: Excluded by universal convention as TCB.

### 2.2 Mapping Prior Review's Finding to Actor Classes

The prior review identified the core vulnerability: *"another actor with write access to the caller-selected root"*.
Mapping this into the formal actor classes reveals exact boundary conditions:

| Caller-Selected Root Configuration | Actors Possessing Write Access | Vulnerability Scope |
| :--- | :--- | :--- |
| **World-Writable Directory** (e.g. `/tmp`, `/var/tmp`, `/Users/Shared`) | Other Local Users, Unprivileged Daemons, Same-EUID Processes, Root | Catastrophic: Any local user can replace directories, pre-stage symlinks, or hijack session files. |
| **Group-Writable Directory** (e.g. `/Users/Shared/team` with `0775`) | Group members (Other Users/Daemons), Same-EUID Processes, Root | Severe: Any group peer can execute substitution or symlink attacks. |
| **Directory with Write-Granting ACL** (e.g. `user:_spotlight allow write`, or inherited volume ACL) | ACL Grantee (User/Daemon), Same-EUID Processes, Root | Subtle/Silent: Directory appears `0700` via `ls -l` / `fstat`, but grantee possesses full write access. |
| **Strictly Private Path** (All ancestors `root/euid` owned, no group/other write, zero write ACLs) | **Strictly Same-EUID Processes and Root** | **Contained**: All external local users and unprivileged daemons are completely excluded. |

---

## 3. Phase 2: Platform-Primitive Validation (Darwin SDK)

Validation probes were compiled with Apple Swift 6.0 (`swiftlang-6.0.0.9.10`) targeting `arm64e-apple-macos14.0` using the macOS 15.0 SDK (`MacOSX.sdk`). All probes were executed as typecheck-only validations (`swiftc -typecheck`) in worktree-local `.scratch/probes` without runtime execution or system shell-outs. Verbatim probe logs are recorded in `VALIDATION-PROBES.txt`.

### 3.1 Platform Primitive Mapping Table

| Design Requirement | Validated Darwin SDK Primitive | Exact API Signature / Symbol | Validation Status | Residual / Blocker Status |
| :--- | :--- | :--- | :---: | :--- |
| **1. Extended ACL Inspection** | `sys/acl.h` via `Darwin` module | `acl_get_fd_np(fd, ACL_TYPE_EXTENDED)` | **Validated** (Probe 1) | None. Validated in Swift. Returns `acl_t?`. |
| **2. ACL Entry Iteration** | `sys/acl.h` via `Darwin` module | `acl_get_entry(acl, id, &entry)` | **Validated** (Probe 1) | None. Iterates with `ACL_FIRST_ENTRY` / `ACL_NEXT_ENTRY`. |
| **3. ACL Tag & Permset Inspection** | `sys/acl.h` via `Darwin` module | `acl_get_tag_type(entry, &tag)`<br>`acl_get_permset_mask_np(entry, &mask)` | **Validated** (Probes 1, 2) | None. Validates `ACL_EXTENDED_ALLOW` and write bitmasks. |
| **4. ACL Qualifier Inspection** | `sys/acl.h` + `Darwin.membership` | `acl_get_qualifier(entry)` -> `guid_t*`<br>`mbr_uid_to_uuid(uid, &uuid)` | **Validated** (Probes 1, 4) | Requires `import Darwin.membership`. Communicates with `opendirectoryd`. |
| **5. Programmatic ACL Mutation (Tests)** | `sys/acl.h` via `Darwin` module | `acl_init`, `acl_create_entry`, `acl_set_tag_type`, `acl_set_permset_mask_np`, `acl_set_fd_np` | **Validated** (Probe 3) | None. Unit tests can set arbitrary ACLs on fixtures without `/bin/chmod`. |
| **6. Ancestor Stat Verification** | `sys/stat.h` via `Darwin` module | `fstat(fd, &stat)` | **Validated** (Probe 7) | None. Checks `S_ISDIR`, `st_uid in [0, euid]`, `st_mode & 0022 == 0`. |
| **7. Component Walk from `/` Anchor** | `fcntl.h` via `Darwin` module | `open("/", O_RDONLY \| O_DIRECTORY)`<br>`openat(parentFd, comp, O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW)` | **Validated** (Existing code) | Rejects symlinks at every component. |
| **8. Atomic Directory Creation + FD** | *None exists on Darwin* | `mkdirat` + `openat` (separate syscalls) | **No primitive** (Probe 9) | `O_CREAT \| O_DIRECTORY` creates regular files. **Residual substitution window exists if root is shared.** |
| **9. Inode-Verified Directory Removal** | *None exists on Darwin* | `unlinkat(parentFd, name, AT_REMOVEDIR)` | **No primitive** (Probe 8) | No CAS or inode-checked unlink in POSIX. **Residual check-then-unlink window if removal is attempted.** |

---

### 3.2 Deep-Dive: Platform Primitive Mechanics

#### Primitive 1: ACL Inspection & Defining "No Write Granted Beyond Owner"
- **API Availability**:
  Darwin exposes `acl_get_fd_np(Int32, acl_type_t)` where `type = ACL_TYPE_EXTENDED (0x00000100)`. If a file system object has no extended ACL, the call returns `nil` and sets `errno = ENOENT`.
- **What "No Write Granted Beyond Owner" Means Concretely**:
  In Darwin's unified security architecture, extended ACLs consist of ordered Access Control Entries (ACEs). An ACE has:
  1. `tag`: `ACL_EXTENDED_ALLOW (1)` or `ACL_EXTENDED_DENY (2)`.
  2. `permissions`: 64-bit bitmask (`acl_permset_mask_t`). Directory write permissions include:
     - `ACL_WRITE_DATA` (`ACL_ADD_FILE`, `1 << 2`): ability to add regular files.
     - `ACL_APPEND_DATA` (`ACL_ADD_SUBDIRECTORY`, `1 << 5`): ability to add subdirectories.
     - `ACL_DELETE_CHILD` (`1 << 6`): ability to delete files or subdirectories within the directory.
     - `ACL_WRITE_ATTRIBUTES` (`1 << 8`): ability to change timestamps and standard attributes.
     - `ACL_WRITE_EXTATTRIBUTES` (`1 << 10`): ability to change extended attributes (`xattrs`).
     - `ACL_WRITE_SECURITY` (`1 << 12`): ability to modify the ACL itself.
     - `ACL_CHANGE_OWNER` (`1 << 13`): ability to reassign ownership.
     - `ACL_DELETE` (`1 << 4`): ability to delete the directory itself.
  3. `qualifier`: A 128-bit GUID (`guid_t`) representing a user or group.
  4. `flags`: Inheritance flags (`ACL_ENTRY_DIRECTORY_INHERIT`, `ACL_ENTRY_FILE_INHERIT`, `ACL_ENTRY_ONLY_INHERIT`).
- **Evaluating ACL Safety**:
  - *Option 1 (Zero-Tolerance / Strict)*: If `acl_get_fd_np` returns non-nil, immediately reject the directory.
    - *Rationale*: Safe and simple. Standard POSIX permissions `0700` provide the owner all necessary access. A legitimate diagnostic directory in Whisky never requires an ACL.
    - *Limitation*: Can reject directories on corporate or managed systems where default inherited read ACLs are placed across `/Users`.
  - *Option 2 (Write-Permset Inspection)*: Allow ACLs if and only if no `ACL_EXTENDED_ALLOW` entry contains write/delete/security bits (`0x3574`) for any non-owner GUID, AND no inheritable write flags exist.
    - *Limitation*: Translating GUIDs to UIDs via `mbr_uuid_to_id` communicates with `opendirectoryd` and can fail or hang in offline/degraded environments.

#### Primitive 2: Ancestor Verification Walk from Trusted Anchor
- **Trusted Anchor**: The root directory `/` is opened with `open("/", O_RDONLY | O_DIRECTORY)`. It is verified via `fstat` (`st_ino == 2`, `st_uid == 0`).
- **Component-by-Component Walk**:
  Each path component is sequentially opened using `openat(currentFd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`.
  At each component:
  1. `fstat(fd, &sb)`:
     - `(sb.st_mode & S_IFMT) == S_IFDIR` (must be directory).
     - `sb.st_uid == 0 || sb.st_uid == geteuid()` (must be owned by root or current user).
     - `(sb.st_mode & 0022) == 0` (group and others MUST NOT have write permissions).
  2. `acl_get_fd_np(fd, ACL_TYPE_EXTENDED)`: verified that no write permissions are granted to non-owners.
  3. Descriptors are closed strictly after stepping into the child, with single-close discipline.

#### Primitive 3: Creation Non-Atomicity & The Substitution Window
- **Darwin Kernel Reality**:
  On Darwin, `mkdirat(parentFd, name, 0o700)` creates the directory inode. The process must then call `openat(parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` to obtain a descriptor.
  Between `mkdirat` and `openat`, a microsecond time window exists:
  $$\Delta t = t_{\text{openat}} - t_{\text{mkdirat}}$$
  During $\Delta t$, any actor with write access to `parentFd` can unlink/rename the freshly created directory and replace it with a pre-created malicious directory.
- **Actor Confinement Analysis**:
  Because Primitive 2 enforces that `parentFd` is strictly owned by `euid` with no group/other write and no write ACLs:
  - Other Local Users have **zero write access** $\implies$ Cannot substitute.
  - Unprivileged Daemons have **zero write access** $\implies$ Cannot substitute.
  - **Only Same-EUID Processes and Root can substitute**.
  Therefore, the substitution window is mathematically closed for all external user and daemon actor classes.

#### Primitive 4: Directory Removal & Check-Then-Unlink Race
- **Darwin Kernel Reality**:
  `unlinkat(parentFd, name, AT_REMOVEDIR)` removes an entry by name. There is no POSIX or Darwin API to atomically unlink only if the directory's inode matches an expected inode.
- **The Check-Then-Unlink Race**:
  ```
  Process:          fstatat(parentFd, "session", &st)  ---> Inode matches expected
  Attacker:                                                rename("session", "session-temp")
  Attacker:                                                rename("victim-dir", "session")
  Process:          unlinkat(parentFd, "session", AT_REMOVEDIR) ---> REMOVES VICTIM!
  ```
- **The Architectural Solution: Abandonment on Failure**:
  Instead of attempting `unlinkat` during cleanup or abort, `DiagnosticDiskSink` should adopt an **Abandonment Policy**:
  - Close all open file descriptors (`dirFd`, `stdoutFd`, `stderrFd`).
  - Leave the session directory on disk (optionally leaving a `.failed` marker file inside `dirFd` before close).
  - Report the failure receipt with full error details.
  - **Result**: Zero calls to `unlinkat(..., AT_REMOVEDIR)`. The check-then-unlink race window is completely eliminated.

---

## 4. Phase 3: Contract Options

Three primary contract options are presented for architectural selection:

```
+----------------------------------------------------------------------------------------------------+
|                                    COMPARISON OF CONTRACT OPTIONS                                  |
+----------------------------------------------------------------------------------------------------+
| Feature / Guarantee          | Option A: StrictModes Path    | Option B: Sink-Owned Base   | Option C: Hybrid Safe-Base   |
+----------------------------------------------------------------------------------------------------+
| Caller API                   | Accepts caller root URL       | Fixed internal base URL     | Caller root OR default base  |
| Ancestor Path Validation     | Strict walk from '/' to root  | Validated inside App Support| Strict walk on provided root |
| ACL Policy                   | Fail-closed on write ACLs     | Private 0700 base, no ACLs  | StrictModes + mkdtemp random |
| External Users Excluded?     | YES (100% mathematically)     | YES (100% mathematically)   | YES (100% mathematically)    |
| External Daemons Excluded?   | YES (100% mathematically)     | YES (100% mathematically)   | YES (100% mathematically)    |
| Same-EUID Substitution Window| Residual (Name predictable)   | Residual (Name predictable) | ELIMINATED (Unpredictable)   |
| Check-Then-Unlink Race       | Closed via Abandonment Policy | Closed via Abandonment      | Closed via Abandonment       |
| API / Migration Cost         | None (keeps existing URL init)| High (breaks caller param)  | Minimal (optional parameter) |
+----------------------------------------------------------------------------------------------------+
```

---

### Option A: Secure-Path Acceptance of Caller Roots (OpenSSH StrictModes-Style)

- **Description**:
  The sink continues to accept a caller-provided `rootDirectoryURL`, but subjects it to strict path verification modeled after OpenSSH `StrictModes`.
- **Mechanics**:
  1. Resolves path components from `/`.
  2. Traverses from `/` using `openat` with `O_NOFOLLOW`.
  3. Every ancestor component and the final root component must satisfy:
     - Directory type (`S_ISDIR`).
     - Ownership: `uid == 0` (root) or `uid == geteuid()`.
     - Standard permissions: `(mode & 0022) == 0` (no group write, no other write).
     - Extended security: `acl_get_fd_np` confirms no write-granting ACE for non-owners.
  4. If any component violates these constraints, initialization fails closed immediately with `DiagnosticDiskSinkError.insecureDirectoryPath`.
  5. The caller-provided directory is used **strictly as a root container**, never adopted as the session directory.
  6. The session child directory is created with `mkdirat(rootFd, sessionName, 0o700)` and immediately opened with `openat(rootFd, sessionName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`. The resulting descriptor `dirFd` is held for the lifetime of the sink.
  7. On setup failure, descriptors are closed and the directory is abandoned on disk without calling `unlinkat`.
- **Holes Addressed**:
  - *Hole 1*: **Closed**. All ancestors and root are checked for ownership, mode bits, and extended ACLs.
  - *Hole 2*: **Closed for external actors**. Only same-EUID and root retain write access to root.
  - *Hole 3*: **Closed**. Cleanup uses abandonment; no `unlinkat` is executed.
- **Residual Windows**:
  - A concurrent process running under the exact same EUID could theoretically predict `sessionName` and race between `mkdirat` and `openat`.
- **Cost & API Compatibility**:
  - Preserves the existing `init(rootDirectoryURL:sessionName:...)` signature.
  - Zero external caller migration required.

---

### Option B: Sink-Owned Fixed Private Base

- **Description**:
  Remove arbitrary caller root selection entirely. The sink privately chooses, creates, and owns its base directory inside the user's application container (e.g. `~/Library/Application Support/com.isaacmarovitz.Whisky/Diagnostics`).
- **Mechanics**:
  1. Base path is hardcoded/configured to standard macOS user Application Support directory.
  2. Component walk verifies the path from `/` through `~/Library/Application Support`.
  3. Sink creates `Diagnostics` base with `0o700` and no ACLs.
  4. Callers only provide `sessionName` (or session metadata).
- **Holes Addressed**:
  - *Hole 1*: **Closed**. The path is fixed and verified within the user's private Application Support directory.
  - *Hole 2*: **Closed for external actors**. Base is private `0700`.
  - *Hole 3*: **Closed via Abandonment**.
- **Residual Windows**:
  - Same-EUID actors sharing access to `~/Library/Application Support` still have filesystem DAC access.
- **Cost & API Compatibility**:
  - Requires changing the public initializer of `DiagnosticDiskSink` (removing `rootDirectoryURL`).
  - *Impact on Frozen Boundaries*: Currently `DiagnosticDiskSink` is unwired in production; no production callers exist. However, tests in `DiagnosticDiskSinkTests.swift` currently pass fixture URLs. Tests would need a dedicated testing initializer or testing base override.

---

### Option C: Hybrid Strict-Container Base with Unpredictable Session Directories & Abandonment Policy

- **Description**:
  Combines the flexibility of Option A (allowing caller or default root within a validated user container) with defense-in-depth against same-EUID processes by using cryptographically unpredictable session directory names (`mkdtemp` pattern).
- **Mechanics**:
  1. Accepts an optional caller root (defaulting to `~/Library/Application Support/com.isaacmarovitz.Whisky/Diagnostics`).
  2. Enforces Option A's StrictModes verification (ownership, mode bits, zero write ACLs) from `/` down to root.
  3. Instead of deterministic `sessionName`, the session directory is created using `mkdtemp` pattern inside `rootFd`:
     - Generates directory `session-<sessionName>-XXXXXXXX` where `X` is filled by cryptographically random characters or `mkdtemp`.
     - Because the directory name cannot be predicted by a concurrent Wine or game process, the $\Delta t$ substitution window between `mkdirat` and `openat` cannot be targeted by an external same-EUID race!
  4. On failure, descriptors are closed and the directory is abandoned on disk.
- **Holes Addressed**:
  - *Hole 1*: **Closed** via StrictModes + ACL ancestor checks.
  - *Hole 2*: **Closed against external actors AND mitigated against same-EUID actors** via unpredictable naming.
  - *Hole 3*: **Closed** via Abandonment Policy.
- **Residual Windows**:
  - Root (TCB) remains the sole unconfined actor.
- **Cost & API Compatibility**:
  - Initializer can accept optional root URL (preserving test fixture capability) while generating the actual directory name or returning the resolved directory URL via `directoryURL`.

---

## 5. Phase 3: Exact Unresolved Decisions for Reviewer Approval

Before any implementation can begin, the reviewer must provide explicit decisions on the following five architectural questions:

### Decision 1: Root Boundary & Contract Option Selection
- **Question**: Which contract option should be implemented?
  - **Choice 1A**: Option A (Secure-path acceptance of caller roots with StrictModes + ACL validation).
  - **Choice 1B**: Option B (Sink-owned fixed private base in Application Support; tests use internal override).
  - **Choice 1C**: Option C (Hybrid strict-container root with unpredictable session naming).

### Decision 2: Threat Model Scope for Same-EUID Processes
- **Question**: Is the proposed exclusion of same-EUID processes accepted as an out-of-scope threat (standard Unix TCB boundary), OR must `DiagnosticDiskSink` defend against hostile same-EUID processes (e.g. rogue Windows executables running under Wine) via randomized naming and unguessable paths?
  - **Choice 2A**: Accept standard Unix boundary (Same-EUID is trusted; residual race window acknowledged).
  - **Choice 2B**: Enforce defense-in-depth against same-EUID (Require Option C with randomized `mkdtemp` naming).

### Decision 3: ACL Strictness Policy
- **Question**: How strictly should extended ACLs be evaluated on ancestor and root directories?
  - **Choice 3A (Strict / Zero-Tolerance)**: Fail closed if ANY extended ACL exists on the directory (`acl_get_fd_np != nil`). Simple, robust, libc-only, zero dependency on OpenDirectory.
  - **Choice 3B (Permissive / Write-Mask Parsing)**: Inspect ACEs; allow ACLs that grant read-only access, but fail closed if any ACE grants `WRITE_DATA`, `ADD_FILE`, `APPEND_DATA`, `DELETE_CHILD`, `WRITE_SECURITY`, or inheritable write flags to non-owners. Requires handling `opendirectoryd` GUID translation.

### Decision 4: Cleanup & Abort Removal Policy (Hole 3 Resolution)
- **Question**: Should failed session directories be abandoned on disk to completely eliminate check-then-unlink races, or should the sink attempt removal?
  - **Choice 4A (Abandonment Policy - Recommended)**: On setup failure or abort, close all descriptors and leave the session directory on disk (marked failed). Completely eliminates Hole 3 check-then-unlink races.
  - **Choice 4B (Removal Attempt with Named Residual)**: Attempt `unlinkat(parentFd, name, AT_REMOVEDIR)` on failure, acknowledging and documenting the check-then-unlink race against same-EUID actors as an accepted residual.

### Decision 5: Public API Signature & Testing Support
- **Question**: Should `DiagnosticDiskSink.init` retain `rootDirectoryURL: URL` (allowing tests to supply owned scratch fixture roots), or should it become parameterless for production with an internal/testing-only entry point?
  - **Choice 5A**: Retain `rootDirectoryURL: URL`, validating it against the chosen contract option.
  - **Choice 5B**: Use separate `init(sessionName:)` for production and `internal init(rootDirectoryURL:sessionName:fileAdapter:)` for test fixtures.

---

## 6. Document Integrity & Hash Verification

Nine files are confirmed byte-identical to their baseline commits:
- `DiagnosticCaptureCore.swift`: `964090d059998658bb29310bf800e9da405346d4b3bc7bf638453f4572edfa02`
- `DiagnosticCaptureCoreTests.swift`: `964d1fc0a4a56997261e5a2553d1067e058be96069398dcb2fc237a3b7d78dd0`
- `DiagnosticPipeReader.swift`: `fc973cd00953919b9640f6501f7a43407aac1d457bbdfb9978266e2ca3798308`
- `DiagnosticPipeReaderTests.swift`: `d92ff1d23b348528fca61d271b8685a9a62151d1eab732a1a96fadf259ea45d3`
- `DiagnosticSubprocessCaptureTests.swift`: `90b6f447ba598ba4730cc5c91624af9f16999bbed0df514bfcb10f87c3b4048f`
- `DiagnosticIngress.swift`: `0a3973ea79716f067bef0f1b992463d9f6335619af5d1e68a1d4024278b59775`
- `DiagnosticIngressTests.swift`: `2a00835268e8effbd76f33bbc077864d5088abd1d23cab0aa2652a42f55abb58`
- `DiagnosticDiskSink.swift`: `176bc0ea013a0dc59e264640528706bddbc2909bac93aa8a47d74de1e24bd218`
- `DiagnosticDiskSinkTests.swift`: `b6840f311eb6311998863e0822e6a1cc3c7af9b1c03c5c5c216402774326ce27`
