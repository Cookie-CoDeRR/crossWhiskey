//
//  DiagnosticSubprocessCaptureTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Darwin
import Dispatch
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Diagnostic subprocess capture: controlled subprocess, verified readers, reducer bridge, and in-memory metadata")
struct DiagnosticSubprocessCaptureTests {

    // MARK: - 1. Single-Owner Child Process Handle (Gate 1 & Section C)

    enum ChildExitOutcome: Equatable, Sendable {
        case exited(code: Int32)
        case signaled(signal: Int32)
        case waitFailed(errno: Int32)
        case cleanupUnconfirmed
    }

    struct SignalAttempt: Equatable, Sendable {
        let pid: pid_t
        let signal: Int32
        let result: Int32
        let errno: Int32
    }

    struct ChildCleanupReport: Equatable, Sendable {
        let outcome: ChildExitOutcome?
        let isReaped: Bool
        let timerCleaned: Bool
        let signalsIssued: [SignalAttempt]
    }

    struct ChildProcessSyscallSeam: Sendable {
        var waitpid: @Sendable (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> pid_t
        var kill: @Sendable (pid_t, Int32) -> Int32

        static let live = ChildProcessSyscallSeam(
            waitpid: { Darwin.waitpid($0, $1, $2) },
            kill: { Darwin.kill($0, $1) }
        )
    }

    /// Authoritative child lifecycle state confined to one serial DispatchQueue.
    ///
    /// Contracts (Gate 1 & Section C):
    /// - Serial execution confined strictly to `lifecycleQueue`.
    /// - Timer is created, scheduled, and cancelled strictly on `lifecycleQueue`.
    /// - `isReaped` read uses NSLock for non-blocking synchronous inspection across queues.
    /// - Non-blocking `waitpid(WNOHANG)` polled periodically via a bounded DispatchSourceTimer.
    /// - If `waitpid` reaps the child, `activePID` is cleared to `nil` in the exact same serialized turn.
    /// - Once `activePID` is cleared, `kill` is NEVER called again for that PID.
    /// - Before each signal or escalation, authoritative state verifies `activePID != nil`.
    /// - State remains alive until real reap; cleanup requests on deinit do not stop the timer prematurely.
    /// - Wait errors are recorded truthfully as `.waitFailed(errno)` and never converted to successful reaps.
    final class ChildLifecycleState: @unchecked Sendable {
        private let lifecycleQueue: DispatchQueue
        private let syscallSeam: ChildProcessSyscallSeam
        private let stateLock = NSLock()
        private var activePID: pid_t?
        private var _isReaped: Bool = false
        private var successfulReapCount: Int = 0
        private var terminalOutcome: ChildExitOutcome?
        private var timer: DispatchSourceTimer?
        private var cleanupSelfHold: ChildLifecycleState?
        private var onTimerCleanedHandlers: [@Sendable (Bool) -> Void] = []
        private var isTimerCleaned: Bool = false
        private var onExitHandlers: [(ChildExitOutcome) -> Void] = []
        private let outcomeBox = WaitBox<ChildExitOutcome>()
        private let timerCleanedBox = WaitBox<Bool>()
        private var signalLog: [SignalAttempt] = []

        var isReaped: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isReaped
        }

        init(pid: pid_t, queue: DispatchQueue, seam: ChildProcessSyscallSeam = .live) {
            self.activePID = pid
            self.lifecycleQueue = queue
            self.syscallSeam = seam

            // Hold cleanup ownership until terminal reap and cancel acknowledgement
            self.cleanupSelfHold = self

            // Initialize and start timer strictly on lifecycleQueue
            self.lifecycleQueue.async { [self] in
                self.setupAndStartTimerOnOwner()
            }
        }

        private func setupAndStartTimerOnOwner() {
            guard !isReaped && terminalOutcome == nil else {
                timerCleanedBox.signal(with: true)
                notifyTimerCleanedHandlersOnOwner(true)
                releaseCleanupHoldOnOwner()
                return
            }
            let t = DispatchSource.makeTimerSource(queue: lifecycleQueue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in
                self?.pollReapOnOwner()
            }
            t.setCancelHandler { [self, timerCleanedBox] in
                timerCleanedBox.signal(with: true)
                self.notifyTimerCleanedHandlersOnOwner(true)
                self.releaseCleanupHoldOnOwner()
            }
            t.resume()
            self.timer = t
        }

        func pollReapOnOwner() {
            guard let pid = activePID, !isReaped else { return }
            var status: Int32 = 0
            let ret = syscallSeam.waitpid(pid, &status, WNOHANG)
            if ret == pid {
                stateLock.lock()
                _isReaped = true
                successfulReapCount += 1
                stateLock.unlock()
                activePID = nil // Relinquish PID immediately in same serialized turn; never signal again!
                let outcome: ChildExitOutcome
                if (status & 0x7f) == 0 {
                    outcome = .exited(code: (status >> 8) & 0xff)
                } else {
                    outcome = .signaled(signal: status & 0x7f)
                }
                transitionToTerminalOnOwner(outcome: outcome)
            } else if ret == -1 {
                let err = Darwin.errno
                if err == EINTR {
                    return
                }
                // Wait error is NOT a successful reap!
                activePID = nil
                transitionToTerminalOnOwner(outcome: .waitFailed(errno: err))
            }
        }

        private func transitionToTerminalOnOwner(outcome: ChildExitOutcome) {
            guard terminalOutcome == nil else { return }
            terminalOutcome = outcome
            if let t = timer {
                timer = nil
                t.cancel()
            } else {
                timerCleanedBox.signal(with: true)
                notifyTimerCleanedHandlersOnOwner(true)
                releaseCleanupHoldOnOwner()
            }
            outcomeBox.signal(with: outcome)
            let handlers = onExitHandlers
            onExitHandlers.removeAll()
            for handler in handlers {
                handler(outcome)
            }
        }

        private func notifyTimerCleanedHandlersOnOwner(_ cleaned: Bool) {
            isTimerCleaned = true
            let handlers = onTimerCleanedHandlers
            onTimerCleanedHandlers.removeAll()
            for handler in handlers {
                handler(cleaned)
            }
        }

        private func releaseCleanupHoldOnOwner() {
            cleanupSelfHold = nil
        }

        func onTimerCleaned(_ handler: @escaping @Sendable (Bool) -> Void) {
            lifecycleQueue.async { [self] in
                if self.isTimerCleaned {
                    handler(true)
                } else {
                    self.onTimerCleanedHandlers.append(handler)
                }
            }
        }

        func onExit(_ handler: @escaping @Sendable (ChildExitOutcome) -> Void) {
            lifecycleQueue.async { [self] in
                if let outcome = self.terminalOutcome {
                    handler(outcome)
                } else {
                    self.onExitHandlers.append(handler)
                }
            }
        }

        func waitForExit(timeoutSeconds: Double = 5.0) -> ChildExitOutcome? {
            outcomeBox.wait(timeoutSeconds: timeoutSeconds)
        }

        func waitForTimerCleaned(timeoutSeconds: Double = 3.0) -> Bool {
            timerCleanedBox.wait(timeoutSeconds: timeoutSeconds) ?? false
        }

        func terminateAndReap(signal: Int32 = SIGTERM, timeoutSeconds: Double = 5.0) -> ChildExitOutcome? {
            lifecycleQueue.async { [self] in
                self.pollReapOnOwner()
                guard let pid = self.activePID, !self.isReaped else { return }
                let ret = self.syscallSeam.kill(pid, signal)
                let err = (ret == -1) ? Darwin.errno : 0
                self.signalLog.append(SignalAttempt(pid: pid, signal: signal, result: ret, errno: err))
                self.pollReapOnOwner()
            }

            if let outcome = outcomeBox.wait(timeoutSeconds: timeoutSeconds) {
                lifecycleQueue.sync {}
                return outcome
            }

            // Escalation to SIGKILL on lifecycleQueue
            lifecycleQueue.async { [self] in
                self.pollReapOnOwner()
                guard let pid = self.activePID, !self.isReaped else { return }
                let ret = self.syscallSeam.kill(pid, SIGKILL)
                let err = (ret == -1) ? Darwin.errno : 0
                self.signalLog.append(SignalAttempt(pid: pid, signal: SIGKILL, result: ret, errno: err))
                self.pollReapOnOwner()
            }

            let outcome = outcomeBox.wait(timeoutSeconds: 2.0)
            lifecycleQueue.sync {}
            return outcome
        }

        func requestCleanupOnDeinit() {
            lifecycleQueue.async { [self] in
                self.pollReapOnOwner()
                if let pid = self.activePID, !self.isReaped {
                    let ret = self.syscallSeam.kill(pid, SIGKILL)
                    let err = (ret == -1) ? Darwin.errno : 0
                    self.signalLog.append(SignalAttempt(pid: pid, signal: SIGKILL, result: ret, errno: err))
                    self.pollReapOnOwner()
                }
                // Do NOT stop the timer here!
                // Strong capture keeps state alive until pollReapOnOwner reaps child and transitions to terminal.
            }
        }

        func explicitCleanup(timeoutSeconds: Double = 5.0) -> ChildCleanupReport {
            _ = terminateAndReap(signal: SIGKILL, timeoutSeconds: timeoutSeconds)
            let timerStopped = timerCleanedBox.wait(timeoutSeconds: 2.0) ?? false
            return lifecycleQueue.sync {
                ChildCleanupReport(
                    outcome: terminalOutcome,
                    isReaped: isReaped,
                    timerCleaned: timerStopped,
                    signalsIssued: signalLog
                )
            }
        }

        var authoritativeSnapshot: (isReaped: Bool, reapCount: Int, outcome: ChildExitOutcome?, signals: [SignalAttempt]) {
            lifecycleQueue.sync {
                (isReaped, successfulReapCount, terminalOutcome, signalLog)
            }
        }
    }

    final class ChildProcessHandle: @unchecked Sendable {
        let pid: pid_t
        private let state: ChildLifecycleState

        init(pid: pid_t, queue: DispatchQueue, seam: ChildProcessSyscallSeam = .live) {
            self.pid = pid
            self.state = ChildLifecycleState(pid: pid, queue: queue, seam: seam)
        }

        var lifecycleState: ChildLifecycleState {
            state
        }

        var isReaped: Bool {
            state.isReaped
        }

        func waitForExit(timeoutSeconds: Double = 5.0) -> ChildExitOutcome? {
            state.waitForExit(timeoutSeconds: timeoutSeconds)
        }

        @discardableResult
        func terminateAndReap(signal: Int32 = SIGTERM, timeoutSeconds: Double = 5.0) -> ChildExitOutcome? {
            state.terminateAndReap(signal: signal, timeoutSeconds: timeoutSeconds)
        }

        func onExit(_ handler: @escaping @Sendable (ChildExitOutcome) -> Void) {
            state.onExit(handler)
        }

        func onTimerCleaned(_ handler: @escaping @Sendable (Bool) -> Void) {
            state.onTimerCleaned(handler)
        }

        @discardableResult
        func cleanup(timeoutSeconds: Double = 5.0) -> ChildCleanupReport {
            state.explicitCleanup(timeoutSeconds: timeoutSeconds)
        }

        var authoritativeSnapshot: (isReaped: Bool, reapCount: Int, outcome: ChildExitOutcome?, signals: [SignalAttempt]) {
            state.authoritativeSnapshot
        }

        deinit {
            state.requestCleanupOnDeinit()
        }
    }

    // MARK: - 2. Scoped Raw Descriptor Management & Descriptor Journal (Gate 4 & Sections A, D)

    struct FDCloseRecord: Equatable, Sendable {
        let generation: Int
        let fd: Int32
        let result: Int32
        let errno: Int32
        let reason: String
    }

    final class DescriptorJournal: @unchecked Sendable {
        private let lock = NSLock()
        private var nextGeneration: Int = 1
        private var records: [FDCloseRecord] = []

        func mintGeneration() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let gen = nextGeneration
            nextGeneration += 1
            return gen
        }

        func recordClose(generation: Int, fd: Int32, result: Int32, errno: Int32, reason: String) {
            lock.lock()
            defer { lock.unlock() }
            records.append(FDCloseRecord(
                generation: generation,
                fd: fd,
                result: result,
                errno: errno,
                reason: reason
            ))
        }

        var snapshot: [FDCloseRecord] {
            lock.lock()
            defer { lock.unlock() }
            return records
        }

        func records(forGeneration gen: Int) -> [FDCloseRecord] {
            lock.lock()
            defer { lock.unlock() }
            return records.filter { $0.generation == gen }
        }
    }

    final class ScopedOwnedFD: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        private(set) var generation: Int
        private let journal: DescriptorJournal?
        private(set) var closeRecord: FDCloseRecord?

        init(_ fd: Int32, generation: Int? = nil, journal: DescriptorJournal? = nil) {
            self.fd = fd
            self.journal = journal
            self.generation = generation ?? (journal?.mintGeneration() ?? 1)
        }

        var rawFD: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return fd
        }

        func transfer() -> (fd: Int32, generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            let target = fd
            let gen = generation
            fd = -1
            return (target, gen)
        }

        @discardableResult
        func close(reason: String = "explicitClose") -> FDCloseRecord {
            lock.lock()
            defer { lock.unlock() }
            guard fd >= 0 else {
                return closeRecord ?? FDCloseRecord(generation: generation, fd: -1, result: 0, errno: 0, reason: "alreadyClosed")
            }
            let target = fd
            let gen = generation
            fd = -1
            let ret = Darwin.close(target)
            let err = (ret == -1) ? Darwin.errno : 0
            let record = FDCloseRecord(generation: gen, fd: target, result: ret, errno: err, reason: reason)
            self.closeRecord = record
            journal?.recordClose(generation: gen, fd: target, result: ret, errno: err, reason: reason)
            return record
        }

        func ensureAbove2(reason: String = "normalizeAbove2") throws {
            lock.lock()
            defer { lock.unlock() }
            guard fd >= 0 && fd <= 2 else { return }
            let newFD = Darwin.fcntl(fd, F_DUPFD_CLOEXEC, 3)
            guard newFD >= 0 else {
                throw SubprocessSpawnError.fcntlError(errno: Darwin.errno)
            }
            let oldTarget = fd
            let oldGen = generation
            let ret = Darwin.close(oldTarget)
            let err = (ret == -1) ? Darwin.errno : 0
            journal?.recordClose(
                generation: oldGen,
                fd: oldTarget,
                result: ret,
                errno: err,
                reason: "\(reason):oldFDClosed"
            )
            fd = newFD
            generation = journal?.mintGeneration() ?? (oldGen + 1)
        }

        deinit {
            close(reason: "deinitFallback")
        }
    }

    struct ControlPipeConfig: Sendable {
        let consumingReadFD: Int32
        let consumingReadGeneration: Int
        let writeFD: Int32
    }

    private struct SubprocessSpawnConfig: Sendable {
        let executablePath: String
        let script: String
        let controlInputPipe: ControlPipeConfig?
        let testInjectedSetupFailure: Bool

        init(
            executablePath: String = "/bin/sh",
            script: String,
            controlInputPipe: ControlPipeConfig? = nil,
            testInjectedSetupFailure: Bool = false
        ) {
            self.executablePath = executablePath
            self.script = script
            self.controlInputPipe = controlInputPipe
            self.testInjectedSetupFailure = testInjectedSetupFailure
        }
    }

    private struct SpawnedSubprocessResult: Sendable {
        let handle: ChildProcessHandle
        let stdoutReadFD: Int32
        let stdoutReadGeneration: Int
        let stderrReadFD: Int32
        let stderrReadGeneration: Int
    }

    private enum SubprocessSpawnError: Error, Equatable, Sendable {
        case pipeCreationError(errno: Int32)
        case fcntlError(errno: Int32)
        case fileActionsError(code: Int32)
        case spawnAttrError(code: Int32)
        case allocationError
        case spawnError(code: Int32)
    }

    /// Minimal posix_spawn adapter with explicit single-owner raw-FD discipline.
    ///
    /// Contracts (Gate 4 & Section A):
    /// - Consumes `controlInputPipe.consumingReadFD` immediately at function entry into a scoped holder.
    /// - Scoped RAII holders guarantee no leaked descriptor on early throw or configuration failure.
    /// - Preserves FD_CLOEXEC on all parent-owned pipe ends.
    /// - Checks return codes on every posix_spawn action, attribute setter, and allocation.
    /// - Normalizes all pipe descriptors above 2 before spawn action configuration.
    /// - Parent write ends and parent copy of control read end are closed immediately after posix_spawn.
    /// - Read ends transfer exactly once to caller on spawn success.
    private static func spawnFixtureChild(
        config: SubprocessSpawnConfig,
        childQueue: DispatchQueue,
        lifecycleSeam: ChildProcessSyscallSeam = .live,
        journal: DescriptorJournal = DescriptorJournal()
    ) -> Result<SpawnedSubprocessResult, SubprocessSpawnError> {
        // Consuming read transfer: adapter wraps and owns consumingReadFD from entry
        let ctrlReadHolder = config.controlInputPipe.map {
            ScopedOwnedFD($0.consumingReadFD, generation: $0.consumingReadGeneration, journal: journal)
        }

        if config.testInjectedSetupFailure {
            ctrlReadHolder?.close(reason: "injectedSetupFailure")
            return .failure(.fileActionsError(code: EINVAL))
        }

        var stdoutPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&stdoutPipe) == 0 else {
            return .failure(.pipeCreationError(errno: Darwin.errno))
        }
        let stdoutRead = ScopedOwnedFD(stdoutPipe[0], journal: journal)
        let stdoutWrite = ScopedOwnedFD(stdoutPipe[1], journal: journal)

        var stderrPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&stderrPipe) == 0 else {
            return .failure(.pipeCreationError(errno: Darwin.errno))
        }
        let stderrRead = ScopedOwnedFD(stderrPipe[0], journal: journal)
        let stderrWrite = ScopedOwnedFD(stderrPipe[1], journal: journal)

        do {
            try stdoutRead.ensureAbove2(reason: "stdoutRead")
            try stdoutWrite.ensureAbove2(reason: "stdoutWrite")
            try stderrRead.ensureAbove2(reason: "stderrRead")
            try stderrWrite.ensureAbove2(reason: "stderrWrite")
            if let cr = ctrlReadHolder {
                try cr.ensureAbove2(reason: "ctrlRead")
            }
        } catch let err as SubprocessSpawnError {
            return .failure(err)
        } catch {
            return .failure(.fcntlError(errno: Darwin.errno))
        }

        var fdsToCloexec = [stdoutRead.rawFD, stdoutWrite.rawFD, stderrRead.rawFD, stderrWrite.rawFD]
        if let cr = ctrlReadHolder {
            fdsToCloexec.append(cr.rawFD)
        }
        if let ctrl = config.controlInputPipe {
            fdsToCloexec.append(ctrl.writeFD)
        }

        for fd in fdsToCloexec {
            let flags = Darwin.fcntl(fd, F_GETFD)
            if flags == -1 || Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1 {
                return .failure(.fcntlError(errno: Darwin.errno))
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        let faInit = posix_spawn_file_actions_init(&fileActions)
        guard faInit == 0 else {
            return .failure(.fileActionsError(code: faInit))
        }
        defer {
            _ = posix_spawn_file_actions_destroy(&fileActions)
        }

        var actErr: Int32 = 0
        if let cr = ctrlReadHolder, let ctrl = config.controlInputPipe {
            actErr = posix_spawn_file_actions_adddup2(&fileActions, cr.rawFD, 0)
            guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
            actErr = posix_spawn_file_actions_addclose(&fileActions, cr.rawFD)
            guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
            actErr = posix_spawn_file_actions_addclose(&fileActions, ctrl.writeFD)
            guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        } else {
            actErr = posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
            guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        }

        actErr = posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite.rawFD, 1)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        actErr = posix_spawn_file_actions_adddup2(&fileActions, stderrWrite.rawFD, 2)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }

        actErr = posix_spawn_file_actions_addclose(&fileActions, stdoutRead.rawFD)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        actErr = posix_spawn_file_actions_addclose(&fileActions, stdoutWrite.rawFD)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        actErr = posix_spawn_file_actions_addclose(&fileActions, stderrRead.rawFD)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }
        actErr = posix_spawn_file_actions_addclose(&fileActions, stderrWrite.rawFD)
        guard actErr == 0 else { return .failure(.fileActionsError(code: actErr)) }

        var attr: posix_spawnattr_t? = nil
        let attrInit = posix_spawnattr_init(&attr)
        guard attrInit == 0 else {
            return .failure(.spawnAttrError(code: attrInit))
        }
        defer {
            _ = posix_spawnattr_destroy(&attr)
        }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGHUP)
        sigaddset(&defaultSignals, SIGPIPE)
        let sigDefRet = posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        guard sigDefRet == 0 else { return .failure(.spawnAttrError(code: sigDefRet)) }

        var unblockedMask = sigset_t()
        sigemptyset(&unblockedMask)
        let sigMaskRet = posix_spawnattr_setsigmask(&attr, &unblockedMask)
        guard sigMaskRet == 0 else { return .failure(.spawnAttrError(code: sigMaskRet)) }

        let flagsRet = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        guard flagsRet == 0 else { return .failure(.spawnAttrError(code: flagsRet)) }

        let argvStrings = [config.executablePath, "-c", config.script]
        var cArgv: [UnsafeMutablePointer<CChar>?] = []
        for arg in argvStrings {
            guard let ptr = strdup(arg) else {
                for p in cArgv where p != nil { free(p) }
                return .failure(.allocationError)
            }
            cArgv.append(ptr)
        }
        cArgv.append(nil)
        defer {
            for ptr in cArgv where ptr != nil {
                free(ptr)
            }
        }

        let envStrings = ["PATH=/bin:/usr/bin"]
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for env in envStrings {
            guard let ptr = strdup(env) else {
                for p in cEnv where p != nil { free(p) }
                return .failure(.allocationError)
            }
            cEnv.append(ptr)
        }
        cEnv.append(nil)
        defer {
            for ptr in cEnv where ptr != nil {
                free(ptr)
            }
        }

        var pid: pid_t = 0
        let spawnRet = posix_spawn(&pid, config.executablePath, &fileActions, &attr, cArgv, cEnv)

        // Parent write descriptors close immediately after spawn attempt
        stdoutWrite.close(reason: "spawnParentStdoutWriteClose")
        stderrWrite.close(reason: "spawnParentStderrWriteClose")

        // Parent copy of control read descriptor closes immediately after spawn attempt
        ctrlReadHolder?.close(reason: "spawnParentCtrlReadClose")

        guard spawnRet == 0 else {
            stdoutRead.close(reason: "spawnFailureStdoutReadClose")
            stderrRead.close(reason: "spawnFailureStderrReadClose")
            return .failure(.spawnError(code: spawnRet))
        }

        let handle = ChildProcessHandle(pid: pid, queue: childQueue, seam: lifecycleSeam)
        let (stdoutFD, stdoutGen) = stdoutRead.transfer()
        let (stderrFD, stderrGen) = stderrRead.transfer()
        return .success(SpawnedSubprocessResult(
            handle: handle,
            stdoutReadFD: stdoutFD,
            stdoutReadGeneration: stdoutGen,
            stderrReadFD: stderrFD,
            stderrReadGeneration: stderrGen
        ))
    }

    // MARK: - 3. Synchronization and In-Memory Storage Helpers

    final class WaitBox<T>: @unchecked Sendable {
        private let condition = NSCondition()
        private var value: T?

        func signal(with val: T) {
            condition.lock()
            if value == nil {
                value = val
                condition.broadcast()
            }
            condition.unlock()
        }

        func wait(timeoutSeconds: Double = 5.0) -> T? {
            condition.lock()
            defer { condition.unlock() }
            if let val = value {
                return val
            }
            let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
            while value == nil {
                if !condition.wait(until: deadline) {
                    break
                }
            }
            return value
        }
    }

    final class LockedDataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let maxCapacity: Int
        private(set) var hasOverflowed: Bool = false

        init(maxCapacity: Int = 512 * 1024) {
            self.maxCapacity = maxCapacity
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if data.count + chunk.count <= maxCapacity {
                data.append(chunk)
            } else {
                hasOverflowed = true
                let remaining = maxCapacity - data.count
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
            }
        }

        var snapshot: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return data.count
        }
    }

    final class FakeInMemoryFinalizer: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requestedOutcome: DiagnosticFinalizationOutcome?
        private(set) var requestCount: Int = 0

        func requestFinalization(outcome: DiagnosticFinalizationOutcome) {
            lock.lock()
            defer { lock.unlock() }
            requestCount += 1
            if requestedOutcome == nil {
                requestedOutcome = outcome
            }
        }

        var snapshot: (requestedOutcome: DiagnosticFinalizationOutcome?, requestCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (requestedOutcome, requestCount)
        }
    }

    // MARK: - 4. Subprocess Capture Bridge Harness (Gate 2 & Sections B, D)

    struct ReaderFactorySeam: Sendable {
        var makeReader: @Sendable (
            _ stream: DiagnosticStreamKind,
            _ fd: Int32,
            _ queue: DispatchQueue,
            _ onData: @escaping @Sendable (Data) -> Void,
            _ onTerminal: @escaping @Sendable (DiagnosticReaderTerminalReason) -> Void,
            _ onCloseAcknowledged: @escaping @Sendable (Result<Void, DiagnosticCloseError>) -> Void
        ) throws -> DiagnosticPipeReader

        static let live = ReaderFactorySeam { stream, fd, queue, onData, onTerminal, onCloseAcknowledged in
            try DiagnosticPipeReader(
                stream: stream,
                fileDescriptor: fd,
                queue: queue,
                onData: onData,
                onTerminal: onTerminal,
                onCloseAcknowledged: onCloseAcknowledged
            )
        }
    }

    final class ReaderCleanupCoordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var expectedStreams: Set<DiagnosticStreamKind>? = nil
        private var closedStreams: Set<DiagnosticStreamKind> = []
        private let closeBox = WaitBox<Bool>()

        func setExpectedStreams(_ streams: Set<DiagnosticStreamKind>) {
            lock.lock()
            defer { lock.unlock() }
            expectedStreams = streams
            if streams.isEmpty || closedStreams.isSuperset(of: streams) {
                closeBox.signal(with: true)
            }
        }

        func recordCloseAcknowledged(stream: DiagnosticStreamKind) {
            lock.lock()
            defer { lock.unlock() }
            closedStreams.insert(stream)
            if let expected = expectedStreams, !expected.isEmpty, closedStreams.isSuperset(of: expected) {
                closeBox.signal(with: true)
            }
        }

        func waitForReaderClosures(timeoutSeconds: Double = 5.0) -> Bool {
            lock.lock()
            if let expected = expectedStreams {
                if expected.isEmpty || closedStreams.isSuperset(of: expected) {
                    lock.unlock()
                    return true
                }
            } else {
                // If expectedStreams was never set (e.g. bridge never started or zero readers activated),
                // no-reader-ack required!
                lock.unlock()
                return true
            }
            lock.unlock()
            return closeBox.wait(timeoutSeconds: timeoutSeconds) ?? false
        }
    }

    struct BridgeObservationsSnapshot: Sendable {
        let terminalReasons: [DiagnosticStreamKind: [DiagnosticReaderTerminalReason]]
        let closeResults: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]]
        let unexpectedDiscards: [(stream: DiagnosticStreamKind, byteCount: Int)]
        let unexpectedTimerRequests: [MonotonicInstant]
        let recordsOverflowed: Bool
    }

    final class SubprocessCaptureBridge: @unchecked Sendable {
        let ownerQueue: DispatchQueue
        private let readerFactory: ReaderFactorySeam
        private(set) var state: DiagnosticCaptureState
        private var stdoutReader: DiagnosticPipeReader?
        private var stderrReader: DiagnosticPipeReader?
        private var childHandle: ChildProcessHandle?

        let stdoutAccumulator = LockedDataAccumulator()
        let stderrAccumulator = LockedDataAccumulator()
        let finalizer = FakeInMemoryFinalizer()
        let teardownBox = WaitBox<Bool>()
        let bannerBox = WaitBox<Bool>()
        private let cleanupCoordinator = ReaderCleanupCoordinator()

        private var stdoutClosed: Bool = false
        private var stderrClosed: Bool = false
        private var closeErrors: [DiagnosticStreamKind: DiagnosticCloseError] = [:]

        // Bounded raw records (Section D)
        private static let maxRecordedEvents = 32
        private var rawTerminalReasons: [DiagnosticStreamKind: [DiagnosticReaderTerminalReason]] = [
            .stdout: [],
            .stderr: []
        ]
        private var rawCloseResults: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]] = [
            .stdout: [],
            .stderr: []
        ]
        private var unexpectedDiscards: [(stream: DiagnosticStreamKind, byteCount: Int)] = []
        private var unexpectedTimerRequests: [MonotonicInstant] = []
        private var recordsOverflowed: Bool = false

        init(ownerQueue: DispatchQueue, readerFactory: ReaderFactorySeam = .live) {
            self.ownerQueue = ownerQueue
            self.readerFactory = readerFactory
            self.state = DiagnosticCaptureState(isSpawned: false)
        }

        private func nextMonotonicInstant() -> MonotonicInstant {
            let raw = MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            if let last = state.lastEventTime, raw <= last {
                return MonotonicInstant(nanoseconds: last.nanoseconds + 1)
            }
            return raw
        }

        func start(
            childHandle: ChildProcessHandle,
            stdoutReadFD: Int32,
            stdoutReadGeneration: Int = 1,
            stderrReadFD: Int32,
            stderrReadGeneration: Int = 2,
            journal: DescriptorJournal? = nil
        ) throws {
            // Establish explicit owners for both acquired read FDs before first throw (Section B)
            let ownedStdout = ScopedOwnedFD(stdoutReadFD, generation: stdoutReadGeneration, journal: journal)
            let ownedStderr = ScopedOwnedFD(stderrReadFD, generation: stderrReadGeneration, journal: journal)

            try ownerQueue.sync {
                self.childHandle = childHandle

                // 1. Establish spawnSucceeded before readers activate
                let (s, fx) = DiagnosticCaptureReducer.reduce(
                    state: self.state,
                    event: .spawnSucceeded(at: self.nextMonotonicInstant())
                )
                self.state = s
                self.handleEffects(fx)

                // 2. Attach exit observer
                childHandle.onExit { [weak self] outcome in
                    self?.handleChildExit(outcome)
                }

                // 3. Install readers on ownerQueue with consuming transfer ownership
                var activeStreams = Set<DiagnosticStreamKind>()

                // Construct stdout reader
                let (rawStdout, _) = ownedStdout.transfer() // Consumed by reader init
                let r1: DiagnosticPipeReader
                do {
                    r1 = try self.readerFactory.makeReader(
                        .stdout,
                        rawStdout,
                        self.ownerQueue,
                        { [weak self] chunk in self?.handleData(stream: .stdout, chunk: chunk) },
                        { [weak self] reason in self?.handleTerminal(stream: .stdout, reason: reason) },
                        { [weak self, coordinator = self.cleanupCoordinator] result in
                            coordinator.recordCloseAcknowledged(stream: .stdout)
                            self?.handleCloseAcknowledged(stream: .stdout, result: result)
                        }
                    )
                    self.stdoutReader = r1
                    activeStreams.insert(.stdout)
                } catch {
                    // stdout reader init failed; ownedStderr is still owned and closes on return
                    self.cleanupCoordinator.setExpectedStreams([])
                    ownedStderr.close(reason: "firstReaderInitFailedStderrCleanup")
                    throw error
                }

                // Construct stderr reader
                let (rawStderr, _) = ownedStderr.transfer() // Consumed by reader init
                let r2: DiagnosticPipeReader
                do {
                    r2 = try self.readerFactory.makeReader(
                        .stderr,
                        rawStderr,
                        self.ownerQueue,
                        { [weak self] chunk in self?.handleData(stream: .stderr, chunk: chunk) },
                        { [weak self] reason in self?.handleTerminal(stream: .stderr, reason: reason) },
                        { [weak self, coordinator = self.cleanupCoordinator] result in
                            coordinator.recordCloseAcknowledged(stream: .stderr)
                            self?.handleCloseAcknowledged(stream: .stderr, result: result)
                        }
                    )
                    self.stderrReader = r2
                    activeStreams.insert(.stderr)
                    self.cleanupCoordinator.setExpectedStreams(activeStreams)
                } catch {
                    // stderr reader init failed. r1 was already activated!
                    // Retain r1, cancel it, and set expected streams to [.stdout] for cleanup:
                    self.cleanupCoordinator.setExpectedStreams(activeStreams)
                    r1.cancel()
                    throw error
                }
            }
        }

        func recordSpawnFailure(errorDescription: String) {
            dispatchOnOwner {
                let (s, fx) = DiagnosticCaptureReducer.reduce(
                    state: self.state,
                    event: .spawnFailed(errorDescription: errorDescription, at: self.nextMonotonicInstant())
                )
                self.state = s
                self.handleEffects(fx)
                self.checkTeardownCompleteness()
            }
        }

        private func handleChildExit(_ outcome: ChildExitOutcome) {
            ownerQueue.async { [self] in
                switch outcome {
                case let .exited(code):
                    let (s, fx) = DiagnosticCaptureReducer.reduce(
                        state: self.state,
                        event: .launcherExited(status: code, at: self.nextMonotonicInstant())
                    )
                    self.state = s
                    self.handleEffects(fx)
                case let .signaled(sig):
                    let (s, fx) = DiagnosticCaptureReducer.reduce(
                        state: self.state,
                        event: .launcherExited(status: 128 + sig, at: self.nextMonotonicInstant())
                    )
                    self.state = s
                    self.handleEffects(fx)
                case .waitFailed, .cleanupUnconfirmed:
                    // Truthful: wait error is NOT converted into launcher exit code
                    break
                }
                self.checkTeardownCompleteness()
            }
        }

        private func handleData(stream: DiagnosticStreamKind, chunk: Data) {
            if stream == .stdout {
                stdoutAccumulator.append(chunk)
                if stdoutAccumulator.count >= 14 && stdoutAccumulator.snapshot.starts(with: "BLOCKED_CHILD\n".utf8) {
                    bannerBox.signal(with: true)
                }
            } else {
                stderrAccumulator.append(chunk)
            }
            let (s, fx) = DiagnosticCaptureReducer.reduce(
                state: state,
                event: .dataChunk(stream: stream, byteCount: chunk.count, at: nextMonotonicInstant())
            )
            state = s
            handleEffects(fx)
        }

        private func handleTerminal(stream: DiagnosticStreamKind, reason: DiagnosticReaderTerminalReason) {
            if var list = rawTerminalReasons[stream], list.count < Self.maxRecordedEvents {
                list.append(reason)
                rawTerminalReasons[stream] = list
            } else {
                recordsOverflowed = true
            }

            let eventTime = nextMonotonicInstant()
            let event: DiagnosticCaptureEvent
            switch reason {
            case .cleanEOF:
                event = .cleanEOF(stream: stream, at: eventTime)
            case let .readError(errno):
                event = .readError(stream: stream, errorCode: errno, at: eventTime)
            case .cancelled:
                // Cancellation maps to cancellation semantics, not cleanEOF/readError0
                return
            }
            let (s, fx) = DiagnosticCaptureReducer.reduce(state: state, event: event)
            state = s
            handleEffects(fx)
        }

        private func handleCloseAcknowledged(stream: DiagnosticStreamKind, result: Result<Void, DiagnosticCloseError>) {
            if var list = rawCloseResults[stream], list.count < Self.maxRecordedEvents {
                list.append(result)
                rawCloseResults[stream] = list
            } else {
                recordsOverflowed = true
            }

            switch result {
            case .success:
                if stream == .stdout {
                    stdoutClosed = true
                } else {
                    stderrClosed = true
                }
                let (s, fx) = DiagnosticCaptureReducer.reduce(
                    state: state,
                    event: .readerCloseAcknowledged(stream: stream, at: nextMonotonicInstant())
                )
                state = s
                handleEffects(fx)
            case let .failure(err):
                closeErrors[stream] = err
            }

            checkTeardownCompleteness()
        }

        private func handleEffects(_ effects: [DiagnosticCaptureEffect]) {
            for effect in effects {
                switch effect {
                case let .requestReaderClose(stream):
                    let reader = (stream == .stdout) ? stdoutReader : stderrReader
                    reader?.cancel()

                case let .requestFinalization(outcome):
                    finalizer.requestFinalization(outcome: outcome)
                    ownerQueue.async { [weak self] in
                        guard let self = self else { return }
                        let t = self.nextMonotonicInstant()
                        let (s, fx) = DiagnosticCaptureReducer.reduce(
                            state: self.state,
                            event: .finalizationAcknowledged(at: t)
                        )
                        self.state = s
                        self.handleEffects(fx)
                        self.checkTeardownCompleteness()
                    }

                case let .discardPayload(stream, count):
                    if unexpectedDiscards.count < Self.maxRecordedEvents {
                        unexpectedDiscards.append((stream: stream, byteCount: count))
                    } else {
                        recordsOverflowed = true
                    }

                case let .requestTimer(expiry):
                    if unexpectedTimerRequests.count < Self.maxRecordedEvents {
                        unexpectedTimerRequests.append(expiry)
                    } else {
                        recordsOverflowed = true
                    }

                case .cancelTimer:
                    break
                }
            }
        }

        private func checkTeardownCompleteness() {
            let childDone = (childHandle == nil) || (childHandle?.isReaped == true)
            if childDone && state.isResourceTeardownComplete && state.isFinalizationSealed {
                teardownBox.signal(with: true)
            }
        }

        func cancelReaders() {
            dispatchOnOwner {
                self.stdoutReader?.cancel()
                self.stderrReader?.cancel()
            }
        }

        func waitForReaderClosures(timeoutSeconds: Double = 5.0) -> Bool {
            cleanupCoordinator.waitForReaderClosures(timeoutSeconds: timeoutSeconds)
        }

        var observationsSnapshot: BridgeObservationsSnapshot {
            ownerQueue.sync {
                BridgeObservationsSnapshot(
                    terminalReasons: rawTerminalReasons,
                    closeResults: rawCloseResults,
                    unexpectedDiscards: unexpectedDiscards,
                    unexpectedTimerRequests: unexpectedTimerRequests,
                    recordsOverflowed: recordsOverflowed
                )
            }
        }

        private func dispatchOnOwner(_ block: @escaping @Sendable () -> Void) {
            ownerQueue.async(execute: block)
        }

        var currentState: DiagnosticCaptureState {
            ownerQueue.sync { state }
        }
    }

    // MARK: - Scoped All-Exit Teardown Helper & Durable Receipt (Sections 1 & 2)

    enum ChildCleanupOutcome: Equatable, Sendable {
        case notApplicable
        case reaped(outcome: ChildExitOutcome, signalsIssued: [SignalAttempt], timerCleaned: Bool)
        case unconfirmed(outcome: ChildExitOutcome?, isReaped: Bool, signalsIssued: [SignalAttempt], timerCleaned: Bool)
    }

    struct SubprocessTeardownReceipt: Sendable {
        let readersClosed: Bool
        let readerCloseResults: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]]
        let childCleanup: ChildCleanupOutcome
        let fdCloseRecords: [FDCloseRecord]
        let isSuccess: Bool
    }

    static func areCloseResultsEqual(
        _ lhs: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]],
        _ rhs: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (stream, lList) in lhs {
            guard let rList = rhs[stream], lList.count == rList.count else { return false }
            for (l, r) in zip(lList, rList) {
                switch (l, r) {
                case (.success, .success): break
                case let (.failure(e1), .failure(e2)): if e1 != e2 { return false }
                default: return false
                }
            }
        }
        return true
    }

    static func evaluateTeardownSuccess(
        readersClosed: Bool,
        closeResults: [DiagnosticStreamKind: [Result<Void, DiagnosticCloseError>]],
        childCleanup: ChildCleanupOutcome,
        fdRecords: [FDCloseRecord]
    ) -> Bool {
        guard readersClosed else { return false }
        for (_, results) in closeResults {
            for res in results {
                if case .failure = res {
                    return false
                }
            }
        }

        switch childCleanup {
        case .notApplicable:
            break
        case let .reaped(_, _, timerCleaned):
            guard timerCleaned else { return false }
        case .unconfirmed:
            return false
        }

        for rec in fdRecords {
            if rec.result != 0 {
                return false
            }
        }

        return true
    }

    @discardableResult
    static func performScopedTeardown(
        bridge: SubprocessCaptureBridge,
        childHandle: ChildProcessHandle?,
        controlWrite: ScopedOwnedFD? = nil,
        journal: DescriptorJournal? = nil,
        recordIssues: Bool = true,
        timeoutSeconds: Double = 5.0
    ) -> SubprocessTeardownReceipt {
        var fdRecords: [FDCloseRecord] = []
        if let cw = controlWrite {
            let rec = cw.close(reason: "scopedTeardownControlWrite")
            fdRecords.append(rec)
        }

        bridge.cancelReaders()
        let readersClosed = bridge.waitForReaderClosures(timeoutSeconds: timeoutSeconds)
        let obs = bridge.observationsSnapshot

        let childOutcome: ChildCleanupOutcome
        if let child = childHandle {
            let report = child.cleanup(timeoutSeconds: 2.0)
            if report.isReaped, let outcome = report.outcome {
                childOutcome = .reaped(outcome: outcome, signalsIssued: report.signalsIssued, timerCleaned: report.timerCleaned)
            } else {
                childOutcome = .unconfirmed(outcome: report.outcome, isReaped: report.isReaped, signalsIssued: report.signalsIssued, timerCleaned: report.timerCleaned)
            }
        } else {
            childOutcome = .notApplicable
        }

        if let j = journal {
            let jSnap = j.snapshot
            for rec in jSnap where !fdRecords.contains(where: { $0.generation == rec.generation }) {
                fdRecords.append(rec)
            }
        }

        let success = evaluateTeardownSuccess(
            readersClosed: readersClosed,
            closeResults: obs.closeResults,
            childCleanup: childOutcome,
            fdRecords: fdRecords
        )

        let receipt = SubprocessTeardownReceipt(
            readersClosed: readersClosed,
            readerCloseResults: obs.closeResults,
            childCleanup: childOutcome,
            fdCloseRecords: fdRecords,
            isSuccess: success
        )

        if recordIssues && !success {
            Issue.record("Scoped teardown failed: readersClosed=\(readersClosed), childOutcome=\(childOutcome), fdRecords=\(fdRecords)")
        }

        return receipt
    }

    // MARK: - Shared Clean Capture Assertions

    private static func assertCleanCaptureInvariants(
        bridge: SubprocessCaptureBridge,
        expectedFinalizerOutcome: DiagnosticFinalizationOutcome = .clean
    ) {
        let finalState = bridge.currentState
        #expect(finalState.isSpawned == true)
        #expect(finalState.streamReadOutcomes[.stdout] == .cleanEOF)
        #expect(finalState.streamReadOutcomes[.stderr] == .cleanEOF)
        #expect(finalState.streamClosureStatuses[.stdout] == .closeAcknowledged)
        #expect(finalState.streamClosureStatuses[.stderr] == .closeAcknowledged)
        #expect(finalState.isFinalizationSealed == true)
        #expect(finalState.isResourceTeardownComplete == true)

        let finSnap = bridge.finalizer.snapshot
        #expect(finSnap.requestedOutcome == expectedFinalizerOutcome)
        #expect(finSnap.requestCount == 1)

        let obsSnap = bridge.observationsSnapshot
        #expect(obsSnap.recordsOverflowed == false)
        #expect(obsSnap.unexpectedDiscards.isEmpty == true)
        #expect(obsSnap.unexpectedTimerRequests.isEmpty == true)
        #expect(bridge.stdoutAccumulator.hasOverflowed == false)
        #expect(bridge.stderrAccumulator.hasOverflowed == false)
        #expect(finalState.queueDroppedBytes == 0)
        #expect(finalState.sinkDroppedBytes == 0)
        #expect(finalState.retentionDroppedBytes == 0)
        #expect(finalState.unknownUnreadTail == false)
        #expect(finalState.hasCounterOverflow == false)
        #expect(finalState.sinkDegraded == false)

        #expect(obsSnap.terminalReasons[.stdout] == [.cleanEOF])
        #expect(obsSnap.terminalReasons[.stderr] == [.cleanEOF])
        #expect(obsSnap.closeResults[.stdout]?.count == 1)
        #expect(obsSnap.closeResults[.stderr]?.count == 1)
        if case .success = obsSnap.closeResults[.stdout]?.first {} else {
            Issue.record("Expected stdout close success")
        }
        if case .success = obsSnap.closeResults[.stderr]?.first {} else {
            Issue.record("Expected stderr close success")
        }
    }

    // MARK: - 5. Required Focused Subprocess Capture Tests

    @Test("Case A: Successful finite child produces >64KiB binary payloads on both streams and clean finalization")
    func successfulFiniteChildBothStreamsActive() throws {
        let ownerQueue = DispatchQueue(label: "test.subprocess.owner.caseA")
        let childQueue = DispatchQueue(label: "test.subprocess.child.caseA")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)
        let journal = DescriptorJournal()

        // Builtin-only shell script emitting >64KiB with embedded NUL and UTF-8 on BOTH streams
        let script = """
        s="0123456789abcdef"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            s="$s$s"
        done
        printf "%sEXTRA_STDOUT_BYTES\\0NON_ASCII_\\303\\251" "$s"
        printf "%sEXTRA_STDERR_BYTES\\0NON_ASCII_\\303\\251" "$s" >&2
        exit 0
        """

        let config = SubprocessSpawnConfig(script: script)
        let spawnResult = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .success(res) = spawnResult else {
            Issue.record("Failed to spawn Case A child: \(spawnResult)")
            return
        }

        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: res.handle,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        try bridge.start(
            childHandle: res.handle,
            stdoutReadFD: res.stdoutReadFD,
            stdoutReadGeneration: res.stdoutReadGeneration,
            stderrReadFD: res.stderrReadFD,
            stderrReadGeneration: res.stderrReadGeneration,
            journal: journal
        )

        let childExit = res.handle.waitForExit(timeoutSeconds: 10.0)
        #expect(childExit == .exited(code: 0))

        guard let teardownDone = bridge.teardownBox.wait(timeoutSeconds: 10.0), teardownDone else {
            Issue.record("Case A teardown timed out")
            return
        }

        Self.assertCleanCaptureInvariants(bridge: bridge)

        let finalState = bridge.currentState
        if case let .exited(status, _) = finalState.launcherStatus {
            #expect(status == 0)
        } else {
            Issue.record("Expected launcherStatus to be .exited(0), got \(finalState.launcherStatus)")
        }

        // Compare raw byte payloads independently
        let stdoutData = bridge.stdoutAccumulator.snapshot
        let stderrData = bridge.stderrAccumulator.snapshot

        // Expected stdout: 65,536 + 18 + 1 (NUL) + 12 = 65,567 bytes
        let baseChunk = String(repeating: "0123456789abcdef", count: 4096)
        var expectedStdout = Data(baseChunk.utf8)
        expectedStdout.append(contentsOf: "EXTRA_STDOUT_BYTES".utf8)
        expectedStdout.append(0x00)
        expectedStdout.append(contentsOf: "NON_ASCII_é".utf8)
        #expect(stdoutData == expectedStdout)
        #expect(stdoutData.count == 65567)
        #expect(finalState.bytesRead[.stdout] == 65567)

        // Expected stderr: 65,536 + 18 + 1 (NUL) + 12 = 65,567 bytes
        var expectedStderr = Data(baseChunk.utf8)
        expectedStderr.append(contentsOf: "EXTRA_STDERR_BYTES".utf8)
        expectedStderr.append(0x00)
        expectedStderr.append(contentsOf: "NON_ASCII_é".utf8)
        #expect(stderrData == expectedStderr)
        #expect(stderrData.count == 65567)
        #expect(finalState.bytesRead[.stderr] == 65567)

        // Construct in-memory DiagnosticSessionMetadata and test Codable roundtrip
        let sessionID = UUID()
        let bottleID = BottleID("test-bottle-a")
        let metadata = DiagnosticSessionMetadata.make(
            sessionID: sessionID,
            bottleID: bottleID,
            requestedPreset: "default",
            winedebugValue: "fixme-all",
            launcherCommand: ["/bin/sh", "-c", script],
            state: finalState,
            retainedBytesOnDisk: nil
        )

        #expect(metadata.launcher.spawnSuccess == true)
        #expect(metadata.launcher.parentExitObserved == true)
        #expect(metadata.launcher.parentExitCode == 0)
        #expect(metadata.stdoutStream.cleanEOF == true)
        #expect(metadata.stdoutStream.bytesReadFromPipe == 65567)
        #expect(metadata.stderrStream.cleanEOF == true)
        #expect(metadata.stderrStream.bytesReadFromPipe == 65567)
        #expect(metadata.accounting.retainedBytesOnDisk == nil)

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DiagnosticSessionMetadata.self, from: encoded)
        #expect(decoded == metadata)
    }

    @Test("Case B: Child closes stdout then emits complete stderr and exits nonzero status 7")
    func childClosesStdoutThenEmitsCompleteStderrAndExitsNonzero() throws {
        let ownerQueue = DispatchQueue(label: "test.subprocess.owner.caseB")
        let childQueue = DispatchQueue(label: "test.subprocess.child.caseB")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)
        let journal = DescriptorJournal()

        // Child closes stdout descriptor (`exec 1>&-`) before emitting stderr and exiting 7
        let script = """
        printf "STDOUT_PAYLOAD_BEFORE_CLOSE\\n"
        exec 1>&-
        s="0123456789abcdef"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            s="$s$s"
        done
        printf "%sSTDERR_BYTES\\0NON_ASCII_\\303\\251" "$s" >&2
        exit 7
        """

        let config = SubprocessSpawnConfig(script: script)
        let spawnResult = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .success(res) = spawnResult else {
            Issue.record("Failed to spawn Case B child: \(spawnResult)")
            return
        }

        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: res.handle,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        try bridge.start(
            childHandle: res.handle,
            stdoutReadFD: res.stdoutReadFD,
            stdoutReadGeneration: res.stdoutReadGeneration,
            stderrReadFD: res.stderrReadFD,
            stderrReadGeneration: res.stderrReadGeneration,
            journal: journal
        )

        let childExit = res.handle.waitForExit(timeoutSeconds: 10.0)
        #expect(childExit == .exited(code: 7))

        guard let teardownDone = bridge.teardownBox.wait(timeoutSeconds: 10.0), teardownDone else {
            Issue.record("Case B teardown timed out")
            return
        }

        Self.assertCleanCaptureInvariants(bridge: bridge)

        let finalState = bridge.currentState
        if case let .exited(status, _) = finalState.launcherStatus {
            #expect(status == 7)
        } else {
            Issue.record("Expected launcher exit status 7")
        }

        let expectedStdout = Data("STDOUT_PAYLOAD_BEFORE_CLOSE\n".utf8)
        #expect(bridge.stdoutAccumulator.snapshot == expectedStdout)

        let baseChunk = String(repeating: "0123456789abcdef", count: 4096)
        var expectedStderr = Data(baseChunk.utf8)
        expectedStderr.append(contentsOf: "STDERR_BYTES".utf8)
        expectedStderr.append(0x00)
        expectedStderr.append(contentsOf: "NON_ASCII_é".utf8)
        #expect(bridge.stderrAccumulator.snapshot == expectedStderr)
        #expect(bridge.stderrAccumulator.snapshot.count == 65561)

        let sessionID = UUID()
        let bottleID = BottleID("test-bottle-b")
        let metadata = DiagnosticSessionMetadata.make(
            sessionID: sessionID,
            bottleID: bottleID,
            requestedPreset: "default",
            winedebugValue: "fixme-all",
            launcherCommand: ["/bin/sh", "-c", script],
            state: finalState,
            retainedBytesOnDisk: nil
        )

        #expect(metadata.launcher.parentExitObserved == true)
        #expect(metadata.launcher.parentExitCode == 7)
        #expect(metadata.captureStatus == "clean")
        #expect(metadata.stdoutStream.cleanEOF == true)
        #expect(metadata.stdoutStream.bytesReadFromPipe == 28)
        #expect(metadata.stderrStream.cleanEOF == true)
        #expect(metadata.stderrStream.bytesReadFromPipe == 65561)
        #expect(metadata.accounting.retainedBytesOnDisk == nil)

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DiagnosticSessionMetadata.self, from: encoded)
        #expect(decoded == metadata)
    }

    @Test("Case C: Genuine spawn failure releases descriptors and finalizes incomplete")
    func genuineSpawnFailureCleansResourcesAndFinalizesIncomplete() throws {
        let ownerQueue = DispatchQueue(label: "test.subprocess.owner.caseC")
        let childQueue = DispatchQueue(label: "test.subprocess.child.caseC")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)
        let journal = DescriptorJournal()

        // Confirmed absent executable in fresh OWNED WORKTREE-local scratch (no /tmp)
        let scratchDir = ".scratch/caseC_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: scratchDir)
        }
        let nonexistentPath = "\(scratchDir)/nonexistent_fixture_binary"
        #expect(FileManager.default.fileExists(atPath: nonexistentPath) == false)

        let config = SubprocessSpawnConfig(
            executablePath: nonexistentPath,
            script: "exit 0"
        )

        let spawnResult = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .failure(err) = spawnResult else {
            if case let .success(res) = spawnResult {
                let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                    bridge: bridge,
                    childHandle: res.handle,
                    journal: journal
                )
                _ = Darwin.close(res.stdoutReadFD)
                _ = Darwin.close(res.stderrReadFD)
                #expect(receipt.isSuccess == true)
            }
            Issue.record("Expected spawn failure for nonexistent binary")
            return
        }

        #expect(err == .spawnError(code: ENOENT))

        bridge.recordSpawnFailure(errorDescription: "posix_spawn failed with code \(ENOENT)")

        guard let teardownDone = bridge.teardownBox.wait(timeoutSeconds: 5.0), teardownDone else {
            Issue.record("Case C teardown timed out")
            return
        }

        let teardownReceipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
            bridge: bridge,
            childHandle: nil,
            journal: journal
        )
        #expect(teardownReceipt.isSuccess == true)
        #expect(teardownReceipt.childCleanup == .notApplicable)

        let finalState = bridge.currentState
        #expect(finalState.isSpawned == false)
        #expect(finalState.isFinalizationSealed == true)
        #expect(finalState.isResourceTeardownComplete == true)

        let finSnap = bridge.finalizer.snapshot
        if let outcome = finSnap.requestedOutcome {
            if case let .incomplete(reasons) = outcome {
                #expect(reasons.contains(.spawnFailure("posix_spawn failed with code 2")))
            } else {
                Issue.record("Expected incomplete finalization with spawnFailure")
            }
        }

        let metadata = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("test-bottle-c"),
            requestedPreset: "default",
            winedebugValue: "fixme-all",
            launcherCommand: [nonexistentPath],
            state: finalState,
            retainedBytesOnDisk: nil
        )

        #expect(metadata.launcher.spawnSuccess == false)
        #expect(metadata.launcher.spawnError == "posix_spawn failed with code 2")
        #expect(metadata.captureStatus == "incomplete")

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DiagnosticSessionMetadata.self, from: encoded)
        #expect(decoded == metadata)
    }

    @Test("Case D: Controlled watchdog timeout cancels readers, awaits close, then terminates and reaps child")
    func controlledTimeoutCleanupStopsAndReapsChild() throws {
        let ownerQueue = DispatchQueue(label: "test.subprocess.owner.caseD")
        let childQueue = DispatchQueue(label: "test.subprocess.child.caseD")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)
        let journal = DescriptorJournal()

        var ctrlPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&ctrlPipe) == 0 else {
            Issue.record("Failed to create control pipe: \(Darwin.errno)")
            return
        }
        let ctrlRead = ScopedOwnedFD(ctrlPipe[0], journal: journal)
        let ctrlWrite = ScopedOwnedFD(ctrlPipe[1], journal: journal)
        try ctrlRead.ensureAbove2(reason: "caseDCtrlRead")
        try ctrlWrite.ensureAbove2(reason: "caseDCtrlWrite")

        let (rawRead, readGen) = ctrlRead.transfer()
        let script = "printf 'BLOCKED_CHILD\\n'; read dummy; exit 0"
        let config = SubprocessSpawnConfig(
            script: script,
            controlInputPipe: ControlPipeConfig(consumingReadFD: rawRead, consumingReadGeneration: readGen, writeFD: ctrlWrite.rawFD)
        )

        var childToClean: ChildProcessHandle?
        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: childToClean,
                controlWrite: ctrlWrite,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        let spawnResult = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .success(res) = spawnResult else {
            Issue.record("Failed to spawn Case D child: \(spawnResult)")
            return
        }
        childToClean = res.handle

        try bridge.start(
            childHandle: res.handle,
            stdoutReadFD: res.stdoutReadFD,
            stdoutReadGeneration: res.stdoutReadGeneration,
            stderrReadFD: res.stderrReadFD,
            stderrReadGeneration: res.stderrReadGeneration,
            journal: journal
        )

        // Wait boundedly on bannerBox (signaled when exact BLOCKED_CHILD\n bytes arrive)
        guard let bannerReceived = bridge.bannerBox.wait(timeoutSeconds: 5.0), bannerReceived else {
            Issue.record("Timed out waiting for Case D blocked child banner")
            return
        }

        // Child is confirmed running and blocked on stdin
        #expect(res.handle.isReaped == false)

        // Gate 3 & Section D Contract: Cancel readers FIRST while child is still alive and blocked
        bridge.cancelReaders()
        guard bridge.waitForReaderClosures(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for reader close acknowledgements")
            return
        }

        // Assert: raw reader terminal was .cancelled, and close acknowledged successfully with count 1
        let obsSnap = bridge.observationsSnapshot
        #expect(obsSnap.recordsOverflowed == false)
        #expect(obsSnap.terminalReasons[.stdout] == [.cancelled])
        #expect(obsSnap.terminalReasons[.stderr] == [.cancelled])
        #expect(obsSnap.closeResults[.stdout]?.count == 1)
        #expect(obsSnap.closeResults[.stderr]?.count == 1)
        if case .success = obsSnap.closeResults[.stdout]?.first {} else {
            Issue.record("Expected stdout close success")
        }
        if case .success = obsSnap.closeResults[.stderr]?.first {} else {
            Issue.record("Expected stderr close success")
        }

        // Explicit structured cleanup: terminate and reap exact child via SIGTERM
        let termOutcome = res.handle.terminateAndReap(signal: SIGTERM, timeoutSeconds: 3.0)
        #expect(termOutcome == .signaled(signal: SIGTERM))
        #expect(res.handle.isReaped == true)

        let finalState = bridge.currentState
        // Verify timeout cancellation is truthfully recorded:
        // Reducer streams were cancelled, NOT cleanEOF; finalization is not sealed
        #expect((finalState.streamReadOutcomes[.stdout] ?? .none) != .cleanEOF)
        #expect((finalState.streamReadOutcomes[.stderr] ?? .none) != .cleanEOF)
        #expect(finalState.isFinalizationSealed == false)
        #expect(bridge.finalizer.requestedOutcome == nil)
    }

    // MARK: - 6. Focused Gate Regressions (Sections A, B, C)

    private final class TestSeamRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var waitpidCallCount = 0
        private var killCalls: [(pid: pid_t, sig: Int32)] = []
        private var reaped = false

        func handleWaitpid(pid: pid_t, statusPtr: UnsafeMutablePointer<Int32>?) -> pid_t {
            lock.lock()
            defer { lock.unlock() }
            waitpidCallCount += 1
            if !reaped {
                reaped = true
                statusPtr?.pointee = 0
                return pid
            }
            return 0
        }

        func handleKill(pid: pid_t, sig: Int32) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            killCalls.append((pid: pid, sig: sig))
            return 0
        }

        var snapshot: (kills: [(pid: pid_t, sig: Int32)], successfulReapCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (killCalls, reaped ? 1 : 0)
        }
    }

    @Test("Gate 1 Seam: Serialized lifecycle owner guarantees signal is never issued after reap")
    func lifecycleOwnerExcludesSignalAfterReap() throws {
        let queue = DispatchQueue(label: "test.lifecycle.seam")
        let dummyPID: pid_t = 99999
        let recorder = TestSeamRecorder()

        let seam = ChildProcessSyscallSeam(
            waitpid: { pid, statusPtr, _ in
                recorder.handleWaitpid(pid: pid, statusPtr: statusPtr)
            },
            kill: { pid, sig in
                recorder.handleKill(pid: pid, sig: sig)
            }
        )

        let handle = ChildProcessHandle(pid: dummyPID, queue: queue, seam: seam)

        let exitOutcome = handle.waitForExit(timeoutSeconds: 2.0)
        #expect(exitOutcome == .exited(code: 0))

        let termOutcome = handle.terminateAndReap(signal: SIGTERM, timeoutSeconds: 1.0)
        #expect(termOutcome == .exited(code: 0))

        // Drain queue before snapshot to ensure any queued blocks have settled
        queue.sync {}

        let snap = recorder.snapshot
        #expect(snap.kills.isEmpty == true)
        #expect(snap.successfulReapCount == 1) // Successful reaps exactly 1
        #expect(handle.isReaped == true)
    }

    private final class TestDelayedReapSeamRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var killReceived = false
        private var pollsAfterKill = 0
        private var kills: [(pid: pid_t, sig: Int32)] = []
        private var reaped = false

        func handleWaitpid(pid: pid_t, statusPtr: UnsafeMutablePointer<Int32>?) -> pid_t {
            lock.lock()
            defer { lock.unlock() }
            if reaped { return 0 }
            if killReceived {
                pollsAfterKill += 1
                if pollsAfterKill >= 2 {
                    reaped = true
                    statusPtr?.pointee = (SIGKILL & 0x7f)
                    return pid
                }
            }
            return 0
        }

        func handleKill(pid: pid_t, sig: Int32) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            kills.append((pid: pid, sig: sig))
            if sig == SIGKILL {
                killReceived = true
            }
            return 0
        }

        var snapshot: (killCalls: [(pid: pid_t, sig: Int32)], successfulReaps: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (kills, reaped ? 1 : 0)
        }
    }

    private final class IndependentCompletionRecord: @unchecked Sendable {
        private let outcomeBox = WaitBox<ChildExitOutcome>()
        private let timerCleanedBox = WaitBox<Bool>()

        func recordExit(_ outcome: ChildExitOutcome) {
            outcomeBox.signal(with: outcome)
        }

        func recordTimerCleaned(_ cleaned: Bool) {
            timerCleanedBox.signal(with: cleaned)
        }

        func waitForExit(timeoutSeconds: Double) -> ChildExitOutcome? {
            outcomeBox.wait(timeoutSeconds: timeoutSeconds)
        }

        func waitForTimerCleaned(timeoutSeconds: Double) -> Bool {
            timerCleanedBox.wait(timeoutSeconds: timeoutSeconds) ?? false
        }
    }

    @Test("Gate 1 Seam: Lifecycle owner keeps observing until actual reap after cleanup requested")
    func lifecycleOwnerKeepsObservingUntilActualReapAfterCleanupRequested() throws {
        let queue = DispatchQueue(label: "test.lifecycle.delayed.reap")
        let dummyPID: pid_t = 99998
        let recorder = TestDelayedReapSeamRecorder()

        let seam = ChildProcessSyscallSeam(
            waitpid: { pid, statusPtr, _ in
                recorder.handleWaitpid(pid: pid, statusPtr: statusPtr)
            },
            kill: { pid, sig in
                recorder.handleKill(pid: pid, sig: sig)
            }
        )

        let completionRecord = IndependentCompletionRecord()
        weak var weakState: ChildLifecycleState?

        do {
            let handle = ChildProcessHandle(pid: dummyPID, queue: queue, seam: seam)
            let s = handle.lifecycleState
            weakState = s
            s.onExit { outcome in
                completionRecord.recordExit(outcome)
            }
            s.onTimerCleaned { cleaned in
                completionRecord.recordTimerCleaned(cleaned)
            }
            // BOTH handle and s are released here before delayed reap becomes eligible!
        }

        let outcome = completionRecord.waitForExit(timeoutSeconds: 3.0)
        #expect(outcome == .signaled(signal: SIGKILL))

        let timerStopped = completionRecord.waitForTimerCleaned(timeoutSeconds: 2.0)
        #expect(timerStopped == true)

        let snap = recorder.snapshot
        #expect(snap.successfulReaps == 1)
        #expect(snap.killCalls.count == 1)
        #expect(snap.killCalls.first?.sig == SIGKILL)

        // Drain lifecycleQueue to ensure all deallocations have settled
        queue.sync {}

        #expect(weakState == nil)
    }

    @Test("Gate 1 Seam: Failed signal and wait error cannot produce successful cleanup receipt")
    func failedSignalAndWaitErrorCannotProduceSuccessfulCleanupReceipt() throws {
        let queue = DispatchQueue(label: "test.lifecycle.error.receipt")
        let dummyPID: pid_t = 99995

        final class ErrorSeamState: @unchecked Sendable {
            private let lock = NSLock()
            private var killed = false

            func recordKill() {
                lock.lock()
                defer { lock.unlock() }
                killed = true
            }

            var isKilled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return killed
            }
        }

        let seamState = ErrorSeamState()
        let seam = ChildProcessSyscallSeam(
            waitpid: { _, _, _ in
                if seamState.isKilled {
                    Darwin.errno = ECHILD
                    return -1
                }
                // Before kill attempt, child appears still alive (unreaped)
                return 0
            },
            kill: { _, _ in
                seamState.recordKill()
                Darwin.errno = EPERM
                return -1
            }
        )

        let handle = ChildProcessHandle(pid: dummyPID, queue: queue, seam: seam)
        let ownerQueue = DispatchQueue(label: "test.bridge.error.receipt")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)

        // performScopedTeardown with recordIssues: false so we can evaluate the failed receipt
        let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
            bridge: bridge,
            childHandle: handle,
            recordIssues: false
        )

        #expect(receipt.isSuccess == false)
        if case let .unconfirmed(outcome, isReaped, signals, timerCleaned) = receipt.childCleanup {
            #expect(isReaped == false)
            #expect(outcome == .waitFailed(errno: ECHILD))
            #expect(signals.count >= 1)
            #expect(signals.first?.result == -1)
            #expect(signals.first?.errno == EPERM)
            #expect(timerCleaned == true)
        } else {
            Issue.record("Expected unconfirmed child cleanup outcome, got \(receipt.childCleanup)")
        }
    }

    @Test("Gate 1 Seam: Teardown receipt success strictly requires timer cancellation acknowledgement")
    func teardownReceiptRequiresTimerAcknowledgement() throws {
        // Negative evaluation: child actually reaped with valid exit, but timerCleaned is false -> isSuccess MUST be false
        let negativeChildOutcome = ChildCleanupOutcome.reaped(
            outcome: .exited(code: 0),
            signalsIssued: [],
            timerCleaned: false
        )
        let negativeSuccess = DiagnosticSubprocessCaptureTests.evaluateTeardownSuccess(
            readersClosed: true,
            closeResults: [:],
            childCleanup: negativeChildOutcome,
            fdRecords: []
        )
        let negativeReceipt = SubprocessTeardownReceipt(
            readersClosed: true,
            readerCloseResults: [:],
            childCleanup: negativeChildOutcome,
            fdCloseRecords: [],
            isSuccess: negativeSuccess
        )
        #expect(negativeReceipt.isSuccess == false)
        if case let .reaped(outcome, signals, timerCleaned) = negativeReceipt.childCleanup {
            #expect(outcome == .exited(code: 0))
            #expect(signals.isEmpty == true)
            #expect(timerCleaned == false)
        } else {
            Issue.record("Expected reaped outcome with false timer ack")
        }

        // Positive evaluation: child actually reaped with valid exit, and timerCleaned is true -> isSuccess is true
        let positiveChildOutcome = ChildCleanupOutcome.reaped(
            outcome: .exited(code: 0),
            signalsIssued: [],
            timerCleaned: true
        )
        let positiveSuccess = DiagnosticSubprocessCaptureTests.evaluateTeardownSuccess(
            readersClosed: true,
            closeResults: [:],
            childCleanup: positiveChildOutcome,
            fdRecords: []
        )
        let positiveReceipt = SubprocessTeardownReceipt(
            readersClosed: true,
            readerCloseResults: [:],
            childCleanup: positiveChildOutcome,
            fdCloseRecords: [],
            isSuccess: positiveSuccess
        )
        #expect(positiveReceipt.isSuccess == true)
        if case let .reaped(outcome, signals, timerCleaned) = positiveReceipt.childCleanup {
            #expect(outcome == .exited(code: 0))
            #expect(signals.isEmpty == true)
            #expect(timerCleaned == true)
        } else {
            Issue.record("Expected reaped outcome with true timer ack")
        }
    }

    @Test("Gate 2 Ordering: Spawn event strictly precedes immediately buffered child data and EOF")
    func spawnEventPrecedesImmediatelyBufferedChildData() throws {
        let ownerQueue = DispatchQueue(label: "test.ordering.owner")
        let childQueue = DispatchQueue(label: "test.ordering.child")
        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue)
        let journal = DescriptorJournal()

        let script = "printf 'ORDERING_TEST_PAYLOAD'; exit 0"
        let config = SubprocessSpawnConfig(script: script)
        let spawnRes = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .success(res) = spawnRes else {
            Issue.record("Failed to spawn ordering test child")
            return
        }

        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: res.handle,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        try bridge.start(
            childHandle: res.handle,
            stdoutReadFD: res.stdoutReadFD,
            stdoutReadGeneration: res.stdoutReadGeneration,
            stderrReadFD: res.stderrReadFD,
            stderrReadGeneration: res.stderrReadGeneration,
            journal: journal
        )

        guard let teardownDone = bridge.teardownBox.wait(timeoutSeconds: 5.0), teardownDone else {
            Issue.record("Ordering test teardown timed out")
            return
        }

        let state = bridge.currentState
        let obsSnap = bridge.observationsSnapshot
        #expect(obsSnap.recordsOverflowed == false)
        #expect(obsSnap.unexpectedDiscards.isEmpty == true)
        #expect(state.bytesRead[.stdout] == 21) // "ORDERING_TEST_PAYLOAD".count
        #expect(bridge.stdoutAccumulator.snapshot == Data("ORDERING_TEST_PAYLOAD".utf8))
        #expect(state.isSpawned == true)
        #expect(state.streamReadOutcomes[.stdout] == .cleanEOF)
        #expect(bridge.finalizer.snapshot.requestedOutcome == .clean)
    }

    @Test("Gate 4 Seam: Control pipe consuming read ownership cleans on early setup failure")
    func controlPipeConsumingReadOwnershipCleansOnEarlySetupFailure() throws {
        let journal = DescriptorJournal()
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else {
            Issue.record("Failed to create pipe: \(Darwin.errno)")
            return
        }
        let ctrlRead = ScopedOwnedFD(pipe[0], journal: journal)
        let ctrlWrite = ScopedOwnedFD(pipe[1], journal: journal)
        try ctrlRead.ensureAbove2(reason: "ctrlFailRead")
        try ctrlWrite.ensureAbove2(reason: "ctrlFailWrite")

        let (rawRead, readGen) = ctrlRead.transfer()
        let childQueue = DispatchQueue(label: "test.ctrl.fail.child")

        // 1. Verify preconfiguration setup failure cleans consumingReadFD at entry
        let config = SubprocessSpawnConfig(
            script: "exit 0",
            controlInputPipe: ControlPipeConfig(consumingReadFD: rawRead, consumingReadGeneration: readGen, writeFD: ctrlWrite.rawFD),
            testInjectedSetupFailure: true
        )

        let res = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config,
            childQueue: childQueue,
            journal: journal
        )
        guard case .failure = res else {
            if case let .success(spawnRes) = res {
                _ = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                    bridge: SubprocessCaptureBridge(ownerQueue: childQueue),
                    childHandle: spawnRes.handle,
                    controlWrite: ctrlWrite,
                    journal: journal
                )
                _ = Darwin.close(spawnRes.stdoutReadFD)
                _ = Darwin.close(spawnRes.stderrReadFD)
            }
            Issue.record("Expected spawn failure")
            return
        }

        // Close write descriptor and verify close records via journal
        let writeRec = ctrlWrite.close(reason: "closeCtrlWrite")
        #expect(writeRec.result == 0)

        let readRecords = journal.records(forGeneration: readGen)
        #expect(readRecords.count == 1) // Closed exactly once
        #expect(readRecords.first?.result == 0)
        #expect(readRecords.first?.errno == 0)
        #expect(readRecords.first?.fd == rawRead)
        #expect(ctrlRead.rawFD == -1) // Relinquished by transfer

        // Drop ctrlRead and verify no second close attempt occurs
        _ = ctrlRead
        #expect(journal.records(forGeneration: readGen).count == 1)

        // 2. Also verify spawn failure with absent executable in owned scratch cleans consumingReadFD
        let scratchDir = ".scratch/ctrl_fail_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratchDir) }
        let absentBinary = "\(scratchDir)/absent"

        var pipe2: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe2) == 0 else {
            Issue.record("Failed to create pipe2: \(Darwin.errno)")
            return
        }
        let ctrlRead2 = ScopedOwnedFD(pipe2[0], journal: journal)
        let ctrlWrite2 = ScopedOwnedFD(pipe2[1], journal: journal)
        let (rawRead2, readGen2) = ctrlRead2.transfer()

        let config2 = SubprocessSpawnConfig(
            executablePath: absentBinary,
            script: "exit 0",
            controlInputPipe: ControlPipeConfig(consumingReadFD: rawRead2, consumingReadGeneration: readGen2, writeFD: ctrlWrite2.rawFD)
        )
        let res2 = DiagnosticSubprocessCaptureTests.spawnFixtureChild(
            config: config2,
            childQueue: childQueue,
            journal: journal
        )
        guard case let .failure(err) = res2 else {
            if case let .success(spawnRes) = res2 {
                _ = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                    bridge: SubprocessCaptureBridge(ownerQueue: childQueue),
                    childHandle: spawnRes.handle,
                    controlWrite: ctrlWrite2,
                    journal: journal
                )
                _ = Darwin.close(spawnRes.stdoutReadFD)
                _ = Darwin.close(spawnRes.stderrReadFD)
            }
            Issue.record("Expected spawn failure for absent binary")
            return
        }
        #expect(err == .spawnError(code: ENOENT))
        ctrlWrite2.close(reason: "closeCtrlWrite2")

        let readRecords2 = journal.records(forGeneration: readGen2)
        #expect(readRecords2.count == 1)
        #expect(readRecords2.first?.result == 0)
        #expect(readRecords2.first?.errno == 0)
        #expect(readRecords2.first?.fd == rawRead2)
        #expect(ctrlRead2.rawFD == -1)
    }

    @Test("Gate 4 Seam: Bridge start first reader failure cleans untransferred descriptor")
    func bridgeStartFirstReaderFailureCleansUntransferredDescriptor() throws {
        let journal = DescriptorJournal()
        var pipe1: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe1) == 0 else {
            Issue.record("Failed to create pipe1: \(Darwin.errno)")
            return
        }
        let stdoutRead = ScopedOwnedFD(pipe1[0], journal: journal)
        let stdoutWrite = ScopedOwnedFD(pipe1[1], journal: journal)

        var pipe2: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe2) == 0 else {
            Issue.record("Failed to create pipe2: \(Darwin.errno)")
            return
        }
        let stderrRead = ScopedOwnedFD(pipe2[0], journal: journal)
        let stderrWrite = ScopedOwnedFD(pipe2[1], journal: journal)

        let ownerQueue = DispatchQueue(label: "test.bridge.fail1.owner")
        let failingSeam = ReaderFactorySeam { stream, fd, queue, onData, onTerminal, onCloseAcknowledged in
            if stream == .stdout {
                Darwin.close(fd) // Reader consumes its FD even on throw
                throw SubprocessSpawnError.spawnError(code: 42)
            }
            return try DiagnosticPipeReader(
                stream: stream,
                fileDescriptor: fd,
                queue: queue,
                onData: onData,
                onTerminal: onTerminal,
                onCloseAcknowledged: onCloseAcknowledged
            )
        }

        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue, readerFactory: failingSeam)
        let dummyPID: pid_t = 99997
        let childQueue = DispatchQueue(label: "test.bridge.fail1.child")
        let seam = ChildProcessSyscallSeam(
            waitpid: { pid, statusPtr, _ in
                statusPtr?.pointee = 0
                return pid
            },
            kill: { _, _ in 0 }
        )
        let handle = ChildProcessHandle(pid: dummyPID, queue: childQueue, seam: seam)

        let (rawStdout, stdoutGen) = stdoutRead.transfer()
        let (rawStderr, stderrGen) = stderrRead.transfer()

        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: handle,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        var threw = false
        do {
            try bridge.start(
                childHandle: handle,
                stdoutReadFD: rawStdout,
                stdoutReadGeneration: stdoutGen,
                stderrReadFD: rawStderr,
                stderrReadGeneration: stderrGen,
                journal: journal
            )
        } catch {
            threw = true
        }

        #expect(threw == true)

        // Prove via journal that untransferred stderrRead was closed cleanly exactly once
        let records = journal.records(forGeneration: stderrGen)
        #expect(records.count == 1)
        #expect(records.first?.result == 0)
        #expect(records.first?.errno == 0)
        #expect(records.first?.fd == rawStderr)

        stdoutWrite.close()
        stderrWrite.close()
    }

    @Test("Gate 4 Seam: Bridge start second reader failure cancels and awaits first reader")
    func bridgeStartSecondReaderFailureCancelsAndAwaitsFirstReader() throws {
        let journal = DescriptorJournal()
        var pipe1: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe1) == 0 else {
            Issue.record("Failed to create pipe1: \(Darwin.errno)")
            return
        }
        let stdoutRead = ScopedOwnedFD(pipe1[0], journal: journal)
        let stdoutWrite = ScopedOwnedFD(pipe1[1], journal: journal)

        var pipe2: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe2) == 0 else {
            Issue.record("Failed to create pipe2: \(Darwin.errno)")
            return
        }
        let stderrRead = ScopedOwnedFD(pipe2[0], journal: journal)
        let stderrWrite = ScopedOwnedFD(pipe2[1], journal: journal)

        let ownerQueue = DispatchQueue(label: "test.bridge.fail2.owner")
        let failingSeam = ReaderFactorySeam { stream, fd, queue, onData, onTerminal, onCloseAcknowledged in
            if stream == .stderr {
                Darwin.close(fd) // Reader consumes its FD even on throw
                throw SubprocessSpawnError.spawnError(code: 99)
            }
            return try DiagnosticPipeReader(
                stream: stream,
                fileDescriptor: fd,
                queue: queue,
                onData: onData,
                onTerminal: onTerminal,
                onCloseAcknowledged: onCloseAcknowledged
            )
        }

        let bridge = SubprocessCaptureBridge(ownerQueue: ownerQueue, readerFactory: failingSeam)
        let dummyPID: pid_t = 99996
        let childQueue = DispatchQueue(label: "test.bridge.fail2.child")
        let seam = ChildProcessSyscallSeam(
            waitpid: { pid, statusPtr, _ in
                statusPtr?.pointee = 0
                return pid
            },
            kill: { _, _ in 0 }
        )
        let handle = ChildProcessHandle(pid: dummyPID, queue: childQueue, seam: seam)

        let (rawStdout, stdoutGen) = stdoutRead.transfer()
        let (rawStderr, stderrGen) = stderrRead.transfer()

        defer {
            let receipt = DiagnosticSubprocessCaptureTests.performScopedTeardown(
                bridge: bridge,
                childHandle: handle,
                journal: journal
            )
            #expect(receipt.isSuccess == true)
        }

        var threw = false
        do {
            try bridge.start(
                childHandle: handle,
                stdoutReadFD: rawStdout,
                stdoutReadGeneration: stdoutGen,
                stderrReadFD: rawStderr,
                stderrReadGeneration: stderrGen,
                journal: journal
            )
        } catch {
            threw = true
        }

        #expect(threw == true)

        // Await closure of activated reader 1 off-owner
        let closed = bridge.waitForReaderClosures(timeoutSeconds: 3.0)
        #expect(closed == true)

        let obsSnap = bridge.observationsSnapshot
        #expect(obsSnap.closeResults[.stdout]?.count == 1)
        if case .success = obsSnap.closeResults[.stdout]?.first {} else {
            Issue.record("Expected stdout close success")
        }
        #expect(obsSnap.terminalReasons[.stdout] == [.cancelled])

        stdoutWrite.close()
        stderrWrite.close()
    }
}

extension DiagnosticSubprocessCaptureTests.SubprocessTeardownReceipt: Equatable {
    static func == (
        lhs: DiagnosticSubprocessCaptureTests.SubprocessTeardownReceipt,
        rhs: DiagnosticSubprocessCaptureTests.SubprocessTeardownReceipt
    ) -> Bool {
        lhs.readersClosed == rhs.readersClosed &&
        lhs.childCleanup == rhs.childCleanup &&
        lhs.fdCloseRecords == rhs.fdCloseRecords &&
        lhs.isSuccess == rhs.isSuccess &&
        DiagnosticSubprocessCaptureTests.areCloseResultsEqual(lhs.readerCloseResults, rhs.readerCloseResults)
    }
}
