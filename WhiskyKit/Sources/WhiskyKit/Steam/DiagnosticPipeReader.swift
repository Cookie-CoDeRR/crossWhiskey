//
//  DiagnosticPipeReader.swift
//  WhiskyKit
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

/// Terminal outcome reason reported by a `DiagnosticPipeReader`.
public enum DiagnosticReaderTerminalReason: Equatable, Sendable {
    case cleanEOF
    case readError(errno: Int32)
    case cancelled
}

/// Error captured when closing a descriptor fails.
public struct DiagnosticCloseError: Error, Equatable, Sendable {
    public let errno: Int32
    public init(errno: Int32) {
        self.errno = errno
    }
}

/// Setup failure when transferring descriptor ownership to `DiagnosticPipeReader`.
///
/// Preserves both the primary error code from flag inspection/configuration and any
/// secondary error that occurred during cleanup close of the transferred descriptor.
/// Note: When `cleanupError` is non-nil, descriptor closure was ATTEMPTED during cleanup
/// but returned an error; release was not confirmed.
public enum DiagnosticReaderSetupError: Error, Equatable, Sendable {
    case invalidDescriptor
    case getFlagsFailed(errno: Int32, cleanupError: Int32? = nil)
    case setFlagsFailed(errno: Int32, cleanupError: Int32? = nil)
}

/// POSIX system call abstraction for test isolation and deterministic failure injection.
internal protocol DiagnosticPosixSyscalls: Sendable {
    func getFlags(fd: Int32) -> (flags: Int32, error: Int32?)
    func setFlags(fd: Int32, flags: Int32) -> Int32?
    func read(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) -> (bytesRead: Int, error: Int32?)
    func close(fd: Int32) -> Int32?
}

/// Production implementation of POSIX syscalls on Darwin.
///
/// Grounded close(2) handling:
/// - Under Darwin (macOS/iOS) `man 2 close` conforming to IEEE Std 1003.1-1988 ("POSIX.1")
///   and Apple XNU kernel semantics (`bsd/kern/kern_descrip.c`), when `close()` is invoked
///   on a valid, open file descriptor owned by the process, the kernel releases the descriptor
///   slot before returning. If interrupted by a signal (`EINTR`), the file descriptor is already
///   closed and released.
/// - Retrying `close()` on Darwin is an ownership violation: the descriptor number may have
///   already been concurrently reassigned to another thread, leading to double-close or closing
///   an unrelated descriptor. Therefore, close is called exactly once and never retried.
///   Any failure errno is preserved and returned.
internal struct DefaultPosixSyscalls: DiagnosticPosixSyscalls {
    func getFlags(fd: Int32) -> (flags: Int32, error: Int32?) {
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags == -1 {
            return (-1, Darwin.errno)
        }
        return (flags, nil)
    }

    func setFlags(fd: Int32, flags: Int32) -> Int32? {
        let ret = Darwin.fcntl(fd, F_SETFL, flags)
        if ret == -1 {
            return Darwin.errno
        }
        return nil
    }

    func read(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) -> (bytesRead: Int, error: Int32?) {
        let ret = Darwin.read(fd, buffer, count)
        if ret < 0 {
            return (-1, Darwin.errno)
        }
        return (ret, nil)
    }

    func close(fd: Int32) -> Int32? {
        let ret = Darwin.close(fd)
        if ret != 0 {
            return Darwin.errno
        }
        return nil
    }
}

/// Isolated per-stream reader taking single consuming ownership of one nonblocking file descriptor.
///
/// Ownership contract:
/// - Takes consuming ownership of ONE already-open read FD upon entry.
/// - If initialization fails (invalid FD, F_GETFL, or F_SETFL failure), descriptor closure is attempted
///   immediately in setup cleanup, preserving both the primary setup error and any cleanup close error.
/// - Once activated, the descriptor is owned by `DiagnosticPipeReader` and closed strictly in the `DispatchSource`
///   cancellation handler after read callbacks quiesce.
/// - State mutations, read callbacks, and closure notifications are strictly confined to the owner's serial `DispatchQueue`.
///
/// Serial Queue & Concurrency Contract:
/// - `queue`: The caller-provided queue (or the default queue created) MUST be a SERIAL queue.
///   Accepting arbitrary concurrent queues is prohibited because single-ownership mutations and read-ordering
///   guarantees require serialized execution.
/// - Initializer & Callback Ordering:
///   Because `source.activate()` is called before `init` returns, event callbacks MAY execute on `queue`
///   before the caller receives the initialized reader reference if `queue` is already running or data is
///   already available. Consumers should establish any holder or weak reference while confined to `queue`
///   before allowing data to arrive. Do not promise or rely on post-return callback ordering.
/// - Cancellation Discipline:
///   `cancel()` is thread-safe and idempotent. When invoked from outside `queue`, a synchronized one-shot submission gate
///   ensures at most one cancellation work item is enqueued onto `queue`. When invoked on `queue` (re-entrantly), it
///   executes immediately.
public final class DiagnosticPipeReader: @unchecked Sendable {
    public let stream: DiagnosticStreamKind
    public let queue: DispatchQueue

    private let state: ReaderState
    private let source: DispatchSourceRead
    private let queueKey: DispatchSpecificKey<Void>
    private let cancelSubmissionLock = NSLock()
    private var isCancelEnqueued: Bool = false
    private var cancelEnqueueCount: Int = 0

    /// Synchronized count of off-owner async cancellation submissions admitted through the gate.
    /// Used internally by tests to verify bounded submission discipline without global state.
    internal var offOwnerCancelEnqueueCount: Int {
        cancelSubmissionLock.lock()
        defer { cancelSubmissionLock.unlock() }
        return cancelEnqueueCount
    }

    /// Borrowed descriptor for internal non-destructive inspection (e.g. `F_GETFL`)
    /// while actively owned by this reader. Callers must NOT close this descriptor externally
    /// or inspect it after reader closure, as the descriptor slot may have been released or reassigned.
    internal var rawFileDescriptor: Int32 {
        state.fileDescriptor
    }

    public convenience init(
        stream: DiagnosticStreamKind,
        fileDescriptor: Int32,
        queue: DispatchQueue? = nil,
        onData: @escaping @Sendable (Data) -> Void,
        onTerminal: @escaping @Sendable (DiagnosticReaderTerminalReason) -> Void,
        onCloseAcknowledged: @escaping @Sendable (Result<Void, DiagnosticCloseError>) -> Void
    ) throws {
        try self.init(
            stream: stream,
            fileDescriptor: fileDescriptor,
            queue: queue,
            syscalls: DefaultPosixSyscalls(),
            onData: onData,
            onTerminal: onTerminal,
            onCloseAcknowledged: onCloseAcknowledged
        )
    }

    internal init(
        stream: DiagnosticStreamKind,
        fileDescriptor: Int32,
        queue: DispatchQueue? = nil,
        syscalls: DiagnosticPosixSyscalls,
        onData: @escaping @Sendable (Data) -> Void,
        onTerminal: @escaping @Sendable (DiagnosticReaderTerminalReason) -> Void,
        onCloseAcknowledged: @escaping @Sendable (Result<Void, DiagnosticCloseError>) -> Void
    ) throws {
        guard fileDescriptor >= 0 else {
            throw DiagnosticReaderSetupError.invalidDescriptor
        }

        // 1. Check F_GETFL and F_SETFL, preserving existing flags
        let (currentFlags, getErr) = syscalls.getFlags(fd: fileDescriptor)
        if let err = getErr {
            let cleanupErr = syscalls.close(fd: fileDescriptor)
            throw DiagnosticReaderSetupError.getFlagsFailed(errno: err, cleanupError: cleanupErr)
        }

        let newFlags = currentFlags | O_NONBLOCK
        if let setErr = syscalls.setFlags(fd: fileDescriptor, flags: newFlags) {
            let cleanupErr = syscalls.close(fd: fileDescriptor)
            throw DiagnosticReaderSetupError.setFlagsFailed(errno: setErr, cleanupError: cleanupErr)
        }

        // 2. Queue confinement: ensure serial queue discipline
        let actualQueue = queue ?? DispatchQueue(label: "com.whiskykit.diagnostic-pipe-reader.\(stream)")
        let key = DispatchSpecificKey<Void>()
        actualQueue.setSpecific(key: key, value: ())

        self.stream = stream
        self.queue = actualQueue
        self.queueKey = key

        // 3. Reader state holding scratch buffer and descriptor
        let state = ReaderState(
            stream: stream,
            fileDescriptor: fileDescriptor,
            queue: actualQueue,
            syscalls: syscalls,
            onData: onData,
            onTerminal: onTerminal,
            onCloseAcknowledged: onCloseAcknowledged
        )
        self.state = state

        // 4. Create and configure level-triggered DispatchSourceRead
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: actualQueue)
        self.source = source
        state.attachSource(source)

        source.setEventHandler { [weak state] in
            state?.handleRead()
        }

        source.setCancelHandler { [state] in
            state.handleCancel()
        }

        // 5. Activate source (callbacks may dispatch immediately if queue is active)
        source.activate()
    }

    /// Manually pumps the read cycle on the owner queue.
    ///
    /// Used for deterministic testing of syscall sequences, quota exhaustion, and readiness resumption.
    internal func pump() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            state.handleRead()
        } else {
            let capturedState = state
            queue.sync {
                capturedState.handleRead()
            }
        }
    }

    /// Requests cancellation of the reader.
    ///
    /// Thread-safe and idempotent:
    /// - If invoked on `queue`, executes synchronously.
    /// - If invoked from outside `queue`, enqueues at most one cancellation request on `queue` via a synchronized gate.
    /// - First terminal outcome wins: does not overwrite prior cleanEOF or readError.
    public func cancel() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            state.requestCancel()
        } else {
            cancelSubmissionLock.lock()
            if isCancelEnqueued {
                cancelSubmissionLock.unlock()
                return
            }
            isCancelEnqueued = true
            cancelEnqueueCount += 1
            cancelSubmissionLock.unlock()

            let capturedState = state
            queue.async {
                capturedState.requestCancel()
            }
        }
    }

    deinit {
        cancel()
    }
}

// MARK: - Internal Reader State

private final class ReaderState: @unchecked Sendable {
    let stream: DiagnosticStreamKind
    let fileDescriptor: Int32
    let queue: DispatchQueue
    let syscalls: DiagnosticPosixSyscalls
    let onData: @Sendable (Data) -> Void
    let onTerminal: @Sendable (DiagnosticReaderTerminalReason) -> Void
    let onCloseAcknowledged: @Sendable (Result<Void, DiagnosticCloseError>) -> Void

    private let scratchBuffer: UnsafeMutableRawPointer
    private let scratchBufferSize: Int = 8192
    private let maxBytesPerEvent: Int = 65536
    private let maxOpsPerEvent: Int = 32

    private(set) var terminalReason: DiagnosticReaderTerminalReason?
    private(set) var isSourceCancelled: Bool = false
    private(set) var isClosed: Bool = false
    private(set) weak var source: DispatchSourceRead?

    init(
        stream: DiagnosticStreamKind,
        fileDescriptor: Int32,
        queue: DispatchQueue,
        syscalls: DiagnosticPosixSyscalls,
        onData: @escaping @Sendable (Data) -> Void,
        onTerminal: @escaping @Sendable (DiagnosticReaderTerminalReason) -> Void,
        onCloseAcknowledged: @escaping @Sendable (Result<Void, DiagnosticCloseError>) -> Void
    ) {
        self.stream = stream
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.syscalls = syscalls
        self.onData = onData
        self.onTerminal = onTerminal
        self.onCloseAcknowledged = onCloseAcknowledged
        self.scratchBuffer = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 16)
    }

    deinit {
        scratchBuffer.deallocate()
    }

    func attachSource(_ source: DispatchSourceRead) {
        self.source = source
    }

    /// Read event handler running synchronously on `queue`.
    ///
    /// Bounds each callback by at most 64KiB and at most 32 syscall operations.
    /// Yields to the queue if quota is exhausted; level-triggered DispatchSource resumes later.
    func handleRead() {
        guard !isSourceCancelled && terminalReason == nil else { return }

        var bytesReadThisEvent = 0
        var opsThisEvent = 0

        while bytesReadThisEvent < maxBytesPerEvent && opsThisEvent < maxOpsPerEvent {
            let toRead = min(scratchBufferSize, maxBytesPerEvent - bytesReadThisEvent)
            let result = syscalls.read(fd: fileDescriptor, buffer: scratchBuffer, count: toRead)
            opsThisEvent += 1

            if result.bytesRead > 0 {
                bytesReadThisEvent += result.bytesRead
                let chunk = Data(bytes: scratchBuffer, count: result.bytesRead)
                onData(chunk)

                // Check if onData initiated cancellation
                if isSourceCancelled || terminalReason != nil {
                    return
                }
            } else if result.bytesRead == 0 {
                // Clean EOF: writer closed
                reportTerminal(.cleanEOF)
                cancelSource()
                return
            } else {
                let err = result.error ?? Darwin.errno
                if err == EINTR {
                    // Retry within operation quota
                    continue
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    // Temporary lack of data: yield until next notification
                    return
                } else {
                    // Fatal read error
                    reportTerminal(.readError(errno: err))
                    cancelSource()
                    return
                }
            }
        }
    }

    func requestCancel() {
        if terminalReason == nil {
            reportTerminal(.cancelled)
        }
        cancelSource()
    }

    func cancelSource() {
        guard !isSourceCancelled else { return }
        isSourceCancelled = true
        source?.cancel()
    }

    func reportTerminal(_ reason: DiagnosticReaderTerminalReason) {
        guard terminalReason == nil else { return }
        terminalReason = reason
        onTerminal(reason)
    }

    func handleCancel() {
        guard !isClosed else { return }
        isClosed = true
        let closeErr = syscalls.close(fd: fileDescriptor)
        if let err = closeErr {
            onCloseAcknowledged(.failure(DiagnosticCloseError(errno: err)))
        } else {
            onCloseAcknowledged(.success(()))
        }
        source = nil
    }
}
