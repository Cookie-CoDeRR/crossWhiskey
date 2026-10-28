//
//  DiagnosticPipeReaderTests.swift
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

@Suite("Diagnostic pipe reader: real descriptor ownership, nonblocking discipline, and pure core bridge")
struct DiagnosticPipeReaderTests {

    // MARK: - 1. Scoped Descriptor Ownership Fixtures

    /// Scoped, generation-tracked handle providing single-owner descriptor discipline.
    ///
    /// Contracts:
    /// - Generation is assigned atomically via `incrementAndGet()`.
    /// - `transfer()` invalidates this handle synchronously and hands sole ownership to the caller.
    /// - `close()` invalidates this handle BEFORE calling Darwin.close, preventing double-close races.
    /// - Deinit closes the descriptor only if still owned (e.g. on early throw or test failure).
    private final class TestOwnedFD: @unchecked Sendable {
        private static let generationCounter = LockedCounter()
        private static let releasedGenerations = LockedSet<Int>()

        let generation: Int
        private let lock = NSLock()
        private var rawFD: Int32?
        private var isTransferred: Bool = false

        init(rawFD: Int32) {
            self.rawFD = rawFD
            self.generation = TestOwnedFD.generationCounter.incrementAndGet()
        }

        /// Consumes and returns the raw descriptor, transferring ownership out of this handle.
        /// Synchronously invalidates this handle so it can never close or transfer again.
        func transfer() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard let fd = rawFD, !isTransferred else {
                fatalError("Attempted to transfer already transferred/closed FD (generation: \(generation))")
            }
            isTransferred = true
            self.rawFD = nil
            return fd
        }

        /// Idempotently closes the descriptor if still owned.
        /// Synchronously invalidates the descriptor BEFORE calling Darwin.close.
        @discardableResult
        func close() -> Int32? {
            lock.lock()
            guard let fd = rawFD, !isTransferred else {
                lock.unlock()
                return nil
            }
            self.rawFD = nil
            let gen = self.generation
            lock.unlock()

            TestOwnedFD.releasedGenerations.insert(gen)

            let ret = Darwin.close(fd)
            if ret != 0 {
                return Darwin.errno
            }
            return nil
        }

        /// Inspects the raw FD without transferring or closing, for assertions while owned.
        var currentRawFD: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return rawFD
        }

        var isOwned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return rawFD != nil && !isTransferred
        }

        static var totalReleasedGenerationsCount: Int {
            releasedGenerations.count
        }

        deinit {
            close()
        }
    }

    /// Helper to create a POSIX pipe where both ends are wrapped in `TestOwnedFD`
    /// and the write end is made nonblocking.
    ///
    /// Cleanup guarantee:
    /// If F_GETFL or F_SETFL fails on the write end, both descriptors are closed immediately
    /// and exactly once before throwing.
    private func makeOwnedPipe() throws -> (readHandle: TestOwnedFD, writeHandle: TestOwnedFD) {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        let readHandle = TestOwnedFD(rawFD: fds[0])
        let writeHandle = TestOwnedFD(rawFD: fds[1])

        let writeFlags = Darwin.fcntl(fds[1], F_GETFL)
        if writeFlags == -1 {
            let err = Darwin.errno
            readHandle.close()
            writeHandle.close()
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if Darwin.fcntl(fds[1], F_SETFL, writeFlags | O_NONBLOCK) == -1 {
            let err = Darwin.errno
            readHandle.close()
            writeHandle.close()
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        return (readHandle, writeHandle)
    }

    /// Nonblocking, bounded-attempt writer for test fixtures.
    private func writeAll(handle: TestOwnedFD, data: Data, maxAttempts: Int = 1000) throws {
        guard let fd = handle.currentRawFD else {
            throw POSIXError(.EBADF)
        }
        var offset = 0
        let count = data.count
        var attempts = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < count {
                attempts += 1
                if attempts > maxAttempts {
                    throw POSIXError(.EAGAIN)
                }
                let chunkPointer = baseAddress.advanced(by: offset)
                let toWrite = count - offset
                let written = Darwin.write(fd, chunkPointer, toWrite)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    throw POSIXError(.EIO)
                } else {
                    let err = Darwin.errno
                    if err == EINTR {
                        continue
                    } else if err == EAGAIN || err == EWOULDBLOCK {
                        throw POSIXError(.EAGAIN)
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                    }
                }
            }
        }
    }

    // MARK: - 2. Structured Bulk Writer Fixture

    private enum BulkWriterResult: Equatable, Sendable {
        case completed(totalBytesWritten: Int)
        case zeroWriteFailure(offset: Int)
        case fatalSyscallError(errno: Int32, offset: Int)
        case aborted(offset: Int)
    }

    private struct BulkWriterTeardownReport: Equatable, Sendable {
        let primaryResult: BulkWriterResult
        let closeAttemptCount: Int
        let cleanupCloseError: Int32?
        let isQuiesced: Bool
    }

    private enum LifecycleEvent: Equatable, Sendable {
        case writeCallbackCompleted(offset: Int, bytesWritten: Int)
        case writerCloseAttempt(fd: Int32)
        case writerCloseResult(fd: Int32, isSuccess: Bool, errno: Int32?)
        case writerQuiescenceAcknowledged(primaryResult: BulkWriterResult)
        case readerCancelIntent
        case readerCloseAcknowledged(isSuccess: Bool, errno: Int32?)
    }

    private final class OrderedLifecycleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LifecycleEvent] = []
        private let maxCapacity: Int

        init(maxCapacity: Int = 100) {
            self.maxCapacity = maxCapacity
        }

        func record(_ event: LifecycleEvent) {
            lock.lock()
            defer { lock.unlock() }
            if events.count < maxCapacity {
                events.append(event)
            }
        }

        var snapshot: [LifecycleEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    /// Independent fixture state owning descriptor, results, and quiescence acknowledgement.
    ///
    /// Contracts:
    /// - Survives wrapper release because the DispatchSource cancel handler captures `state` strongly.
    /// - Holds `writeSource` weakly to prevent retain cycles.
    /// - Authoritative cancel handler performs single descriptor close and records cleanup results.
    /// - Unstarted disposal provides balanced, single-owner cleanup if wrapper is deallocated without start().
    private final class StructuredBulkWriterState: @unchecked Sendable {
        private let lock = NSLock()
        let queue: DispatchQueue
        let payload: Data
        private var rawFD: Int32?
        private var isActivated: Bool = false
        private var isCancelled: Bool = false
        private var offset: Int = 0

        // Source is held weakly to avoid retain cycles
        private weak var writeSource: DispatchSourceWrite?

        private var primaryResult: BulkWriterResult?
        private var closeAttemptCount: Int = 0
        private var cleanupCloseError: Int32? = nil
        private let quiescenceBox = WaitBox<BulkWriterTeardownReport>()

        private let simulatedFailure: (triggerAtOffset: Int, error: Int32)?
        private let simulatedCloseError: Int32?
        private let pauseAtOffset: Int?
        private let pauseReached: DispatchSemaphore?
        private let resumeGate: DispatchSemaphore?
        private let lifecycleRecorder: OrderedLifecycleRecorder?
        private var hasSignaledPause: Bool = false

        init(
            rawFD: Int32,
            payload: Data,
            queue: DispatchQueue,
            simulatedFailure: (triggerAtOffset: Int, error: Int32)? = nil,
            simulatedCloseError: Int32? = nil,
            pauseAtOffset: Int? = nil,
            pauseReached: DispatchSemaphore? = nil,
            resumeGate: DispatchSemaphore? = nil,
            lifecycleRecorder: OrderedLifecycleRecorder? = nil
        ) {
            self.rawFD = rawFD
            self.payload = payload
            self.queue = queue
            self.simulatedFailure = simulatedFailure
            self.simulatedCloseError = simulatedCloseError
            self.pauseAtOffset = pauseAtOffset
            self.pauseReached = pauseReached
            self.resumeGate = resumeGate
            self.lifecycleRecorder = lifecycleRecorder
        }

        var currentRawFD: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return rawFD
        }

        func setSource(_ source: DispatchSourceWrite) {
            lock.lock()
            defer { lock.unlock() }
            self.writeSource = source
            self.isActivated = true
        }

        func handleWriteEvent() {
            lock.lock()
            guard !isCancelled, primaryResult == nil, let fd = rawFD else {
                lock.unlock()
                return
            }

            let total = payload.count
            guard offset < total else {
                primaryResult = .completed(totalBytesWritten: offset)
                lock.unlock()
                requestCancel()
                return
            }

            // Bounded quota per event callback: up to 8KiB and up to 16 syscall attempts
            let quotaBytes = 8192
            var bytesWrittenThisEvent = 0
            var opsThisEvent = 0

            while offset < total && bytesWrittenThisEvent < quotaBytes && opsThisEvent < 16 {
                if let pauseOffset = pauseAtOffset, offset >= pauseOffset, !hasSignaledPause {
                    hasSignaledPause = true
                    pauseReached?.signal()
                    lock.unlock()
                    _ = resumeGate?.wait(timeout: .now() + 5.0)
                    lock.lock()
                    if isCancelled || primaryResult != nil {
                        lock.unlock()
                        return
                    }
                }

                if let sim = simulatedFailure, offset >= sim.triggerAtOffset {
                    if sim.error == 0 {
                        primaryResult = .zeroWriteFailure(offset: offset)
                    } else {
                        primaryResult = .fatalSyscallError(errno: sim.error, offset: offset)
                    }
                    lock.unlock()
                    requestCancel()
                    return
                }

                opsThisEvent += 1
                var toWrite = min(quotaBytes - bytesWrittenThisEvent, total - offset)
                if let pauseOffset = pauseAtOffset, pauseOffset > offset {
                    toWrite = min(toWrite, pauseOffset - offset)
                }
                if let sim = simulatedFailure, sim.triggerAtOffset > offset {
                    toWrite = min(toWrite, sim.triggerAtOffset - offset)
                }

                let chunkResult: (written: Int, err: Int32?) = payload.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return (0, nil) }
                    let ptr = base.advanced(by: offset)
                    let ret = Darwin.write(fd, ptr, toWrite)
                    if ret > 0 {
                        return (ret, nil)
                    } else if ret == 0 {
                        return (0, 0)
                    } else {
                        return (-1, Darwin.errno)
                    }
                }

                if chunkResult.written > 0 {
                    offset += chunkResult.written
                    bytesWrittenThisEvent += chunkResult.written
                    lifecycleRecorder?.record(.writeCallbackCompleted(offset: offset, bytesWritten: chunkResult.written))
                } else if chunkResult.written == 0 {
                    primaryResult = .zeroWriteFailure(offset: offset)
                    lock.unlock()
                    requestCancel()
                    return
                } else {
                    let err = chunkResult.err ?? Darwin.errno
                    if err == EINTR {
                        continue
                    } else if err == EAGAIN || err == EWOULDBLOCK {
                        lock.unlock()
                        return
                    } else {
                        primaryResult = .fatalSyscallError(errno: err, offset: offset)
                        lock.unlock()
                        requestCancel()
                        return
                    }
                }
            }

            if offset >= total {
                primaryResult = .completed(totalBytesWritten: offset)
                lock.unlock()
                requestCancel()
                return
            }

            lock.unlock()
        }

        func requestCancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            let src = writeSource
            lock.unlock()
            resumeGate?.signal()
            src?.cancel()
        }

        func handleCancelEvent() {
            lock.lock()
            performCloseUnderLock()
            if primaryResult == nil {
                primaryResult = .aborted(offset: offset)
            }
            let report = makeReportUnderLock()
            lock.unlock()

            lifecycleRecorder?.record(.writerQuiescenceAcknowledged(primaryResult: report.primaryResult))
            quiescenceBox.signal(with: report)
        }

        private func performCloseUnderLock() {
            guard let fd = rawFD else { return }
            rawFD = nil
            closeAttemptCount += 1
            lifecycleRecorder?.record(.writerCloseAttempt(fd: fd))

            let ret = Darwin.close(fd)
            var err: Int32? = nil
            if ret != 0 {
                err = Darwin.errno
            }
            if let sim = simulatedCloseError {
                err = sim
            }
            cleanupCloseError = err
            lifecycleRecorder?.record(.writerCloseResult(fd: fd, isSuccess: err == nil, errno: err))
        }

        private func makeReportUnderLock() -> BulkWriterTeardownReport {
            return BulkWriterTeardownReport(
                primaryResult: primaryResult ?? .aborted(offset: offset),
                closeAttemptCount: closeAttemptCount,
                cleanupCloseError: cleanupCloseError,
                isQuiesced: true
            )
        }

        func disposeIfNotStartedOrRequestCancel() {
            lock.lock()
            if !isActivated {
                isActivated = true
                isCancelled = true
                performCloseUnderLock()
                if primaryResult == nil {
                    primaryResult = .aborted(offset: 0)
                }
                let report = makeReportUnderLock()
                lock.unlock()
                quiescenceBox.signal(with: report)
                return
            }
            let alreadyCancelled = isCancelled
            let src = writeSource
            isCancelled = true
            lock.unlock()
            resumeGate?.signal()
            if !alreadyCancelled {
                src?.cancel()
            }
        }

        func awaitCompletion(timeoutSeconds: Double = 10.0) -> (completed: Bool, report: BulkWriterTeardownReport?) {
            if let rep = quiescenceBox.wait(timeoutSeconds: timeoutSeconds) {
                return (true, rep)
            }
            return (false, nil)
        }

        @discardableResult
        func stopAndAwaitQuiescence(timeoutSeconds: Double = 5.0) -> (quiesced: Bool, report: BulkWriterTeardownReport?) {
            lock.lock()
            if !isActivated {
                lock.unlock()
                disposeIfNotStartedOrRequestCancel()
                return (true, quiescenceBox.wait(timeoutSeconds: 0.1))
            }
            let alreadyCancelled = isCancelled
            let src = writeSource
            if !alreadyCancelled {
                isCancelled = true
            }
            lock.unlock()

            resumeGate?.signal()
            if !alreadyCancelled {
                src?.cancel()
            }

            if let rep = quiescenceBox.wait(timeoutSeconds: timeoutSeconds) {
                return (true, rep)
            }
            return (false, nil)
        }
    }

    /// Structured fixture writer providing single-owner descriptor discipline and bounded cancellation quiescence.
    ///
    /// Lifecycle guarantee:
    /// - Owns the write descriptor exclusively after `handle.transfer()`.
    /// - Transfers descriptor into independent `StructuredBulkWriterState`.
    /// - After activation, the cancel handler strongly owns `state`, ensuring cleanup completes even if wrapper is deallocated.
    /// - `deinit` requests cancellation or performs unstarted disposal without waiting on itself or the owner queue.
    private final class StructuredBulkWriter: @unchecked Sendable {
        let state: StructuredBulkWriterState
        private let lock = NSLock()
        private var writeSource: DispatchSourceWrite?
        private var isStarted: Bool = false

        init(
            handle: TestOwnedFD,
            payload: Data,
            queue: DispatchQueue? = nil,
            simulatedFailure: (triggerAtOffset: Int, error: Int32)? = nil,
            simulatedCloseError: Int32? = nil,
            pauseAtOffset: Int? = nil,
            pauseReached: DispatchSemaphore? = nil,
            resumeGate: DispatchSemaphore? = nil,
            lifecycleRecorder: OrderedLifecycleRecorder? = nil
        ) {
            let fd = handle.transfer()
            let q = queue ?? DispatchQueue(label: "test.fixture.bulk-writer")
            self.state = StructuredBulkWriterState(
                rawFD: fd,
                payload: payload,
                queue: q,
                simulatedFailure: simulatedFailure,
                simulatedCloseError: simulatedCloseError,
                pauseAtOffset: pauseAtOffset,
                pauseReached: pauseReached,
                resumeGate: resumeGate,
                lifecycleRecorder: lifecycleRecorder
            )
        }

        func start() {
            lock.lock()
            defer { lock.unlock() }
            guard !isStarted else { return }
            isStarted = true

            let state = self.state
            guard let fd = state.currentRawFD else { return }

            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: state.queue)
            self.writeSource = source
            state.setSource(source)

            // Cancel and event handlers capture `state` strongly, but NOT `self` (wrapper) and NOT `source`!
            source.setEventHandler { [state] in
                state.handleWriteEvent()
            }

            source.setCancelHandler { [state] in
                state.handleCancelEvent()
            }

            source.activate()
        }

        func requestCancel() {
            state.requestCancel()
        }

        func awaitCompletion(timeoutSeconds: Double = 10.0) -> (completed: Bool, report: BulkWriterTeardownReport?) {
            state.awaitCompletion(timeoutSeconds: timeoutSeconds)
        }

        @discardableResult
        func stopAndAwaitQuiescence(timeoutSeconds: Double = 5.0) -> (quiesced: Bool, report: BulkWriterTeardownReport?) {
            state.stopAndAwaitQuiescence(timeoutSeconds: timeoutSeconds)
        }

        deinit {
            // Wrapper deinit only requests cancellation or disposes unstarted state;
            // NEVER waits on itself or owner queue!
            state.disposeIfNotStartedOrRequestCancel()
        }
    }

    // MARK: - 3. Synchronization and Event Recording Helpers

    private enum RecordedEvent: Equatable, Sendable {
        case data(count: Int)
        case terminal(DiagnosticReaderTerminalReason)
        case closeAcknowledged(isSuccess: Bool, errno: Int32?)
    }

    /// Synchronized bounded event recorder counting terminal, data chunks, and close acknowledgements.
    /// Capped by explicit capacity to prevent unbounded memory growth while recording overflow flags.
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RecordedEvent] = []
        private let maxCapacity: Int
        private(set) var isOverflowed: Bool = false
        private let semaphore = DispatchSemaphore(value: 0)
        private var closeAckCount = 0
        private var terminalCount = 0

        init(maxCapacity: Int = 500) {
            self.maxCapacity = maxCapacity
        }

        private func appendEvent(_ event: RecordedEvent) {
            if events.count < maxCapacity {
                events.append(event)
            } else {
                isOverflowed = true
            }
        }

        func recordData(count: Int) {
            lock.lock()
            defer { lock.unlock() }
            appendEvent(.data(count: count))
        }

        func recordTerminal(_ reason: DiagnosticReaderTerminalReason) {
            lock.lock()
            appendEvent(.terminal(reason))
            terminalCount += 1
            lock.unlock()
        }

        func recordCloseAcknowledged(_ result: Result<Void, DiagnosticCloseError>) {
            lock.lock()
            switch result {
            case .success:
                appendEvent(.closeAcknowledged(isSuccess: true, errno: nil))
            case let .failure(err):
                appendEvent(.closeAcknowledged(isSuccess: false, errno: err.errno))
            }
            closeAckCount += 1
            lock.unlock()
            semaphore.signal()
        }

        func awaitCloseAcknowledged(timeoutSeconds: Double = 5.0) -> Bool {
            let res = semaphore.wait(timeout: .now() + timeoutSeconds)
            return res == .success
        }

        var snapshot: [RecordedEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var recordedTerminalCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return terminalCount
        }

        var recordedCloseAckCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return closeAckCount
        }
    }

    /// Thread-safe signal/wait box with bounded timeout.
    private final class WaitBox<T>: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: T?

        func signal(with val: T) {
            lock.lock()
            if value == nil {
                value = val
                lock.unlock()
                semaphore.signal()
            } else {
                lock.unlock()
            }
        }

        func wait(timeoutSeconds: Double = 5.0) -> T? {
            lock.lock()
            if let val = value {
                lock.unlock()
                return val
            }
            lock.unlock()

            let result = semaphore.wait(timeout: .now() + timeoutSeconds)
            if result == .success {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            return nil
        }
    }

    /// Weak reference box preventing retain cycles in re-entrant callbacks.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        private let lock = NSLock()
        private weak var value: T?

        init(_ value: T? = nil) {
            self.value = value
        }

        func set(_ val: T?) {
            lock.lock()
            defer { lock.unlock() }
            value = val
        }

        func get() -> T? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            value = nil
        }
    }

    /// Thread-safe data accumulator for Sendable closures.
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Thread-safe integer counter for Sendable closures with atomic increment-and-return.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func add(_ delta: Int) {
            lock.lock()
            defer { lock.unlock() }
            count += delta
        }

        func incrementAndGet() -> Int {
            lock.lock()
            defer { lock.unlock() }
            guard count < Int.max else {
                fatalError("LockedCounter overflow")
            }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Thread-safe set for generation and uniqueness assertions.
    private final class LockedSet<T: Hashable>: @unchecked Sendable {
        private let lock = NSLock()
        private var elements = Set<T>()

        func insert(_ element: T) {
            lock.lock()
            defer { lock.unlock() }
            elements.insert(element)
        }

        func contains(_ element: T) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return elements.contains(element)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return elements.count
        }
    }

    /// Thread-safe container box.
    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var val: T

        init(_ initial: T) {
            self.val = initial
        }

        func set(_ value: T) {
            lock.lock()
            defer { lock.unlock() }
            val = value
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return val
        }
    }

    private func expectCloseSuccess(_ result: Result<Void, DiagnosticCloseError>?) {
        guard let result = result else {
            Issue.record("Expected close result but received nil")
            return
        }
        switch result {
        case .success:
            #expect(true)
        case let .failure(err):
            Issue.record("Expected close success but got error: \(err)")
        }
    }

    private func expectCloseFailure(_ result: Result<Void, DiagnosticCloseError>?, expectedErrno: Int32) {
        guard let result = result else {
            Issue.record("Expected close result but received nil")
            return
        }
        switch result {
        case .success:
            Issue.record("Expected close failure but got success")
        case let .failure(err):
            #expect(err == DiagnosticCloseError(errno: expectedErrno))
        }
    }

    // MARK: - 4. Real Raw-Pipe Tests

    @Test("Real pipe: Known binary payload with embedded NUL and split UTF8 sequence preserves exact bytes")
    func realPipeExactBinaryPayloadWithSplitUTF8AndNUL() throws {
        let (readHandle, writeHandle) = try makeOwnedPipe()
        defer {
            writeHandle.close()
            readHandle.close()
        }

        let ownerQueue = DispatchQueue(label: "test.reader.stdout")
        let recorder = EventRecorder()
        let accumulatedData = LockedData()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readHandle.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                accumulatedData.append(chunk)
                recorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in
                recorder.recordTerminal(reason)
            },
            onCloseAcknowledged: { result in
                recorder.recordCloseAcknowledged(result)
            }
        )

        let part1 = Data([0x01, 0x02, 0x00, 0xE2, 0x82])
        let part2 = Data([0xAC, 0x7F, 0x80, 0xFF])

        try writeAll(handle: writeHandle, data: part1)
        try writeAll(handle: writeHandle, data: part2)

        writeHandle.close()

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)

        let snapshot = recorder.snapshot
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
        #expect(snapshot.contains(.terminal(.cleanEOF)))
        #expect(snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))

        var expectedData = part1
        expectedData.append(part2)
        #expect(accumulatedData.value == expectedData)
        #expect(accumulatedData.value.count == 9)

        _ = reader
    }

    @Test("Real pipe: Two independent readers on shared queue allow healthy reader to coexist after peer EOF")
    func realPipeTwoIndependentReadersCoexistence() throws {
        let (stdoutReadH, stdoutWriteH) = try makeOwnedPipe()
        let (stderrReadH, stderrWriteH) = try makeOwnedPipe()
        defer {
            stdoutWriteH.close()
            stdoutReadH.close()
            stderrWriteH.close()
            stderrReadH.close()
        }

        let sharedOwnerQueue = DispatchQueue(label: "test.reader.shared")
        let stdoutRecorder = EventRecorder()
        let stderrRecorder = EventRecorder()

        let stdoutData = LockedData()
        let stderrData = LockedData()

        let stdoutReader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: stdoutReadH.transfer(),
            queue: sharedOwnerQueue,
            onData: { chunk in
                stdoutData.append(chunk)
                stdoutRecorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in
                stdoutRecorder.recordTerminal(reason)
            },
            onCloseAcknowledged: { res in
                stdoutRecorder.recordCloseAcknowledged(res)
            }
        )

        let stderrReader = try DiagnosticPipeReader(
            stream: .stderr,
            fileDescriptor: stderrReadH.transfer(),
            queue: sharedOwnerQueue,
            onData: { chunk in
                stderrData.append(chunk)
                stderrRecorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in
                stderrRecorder.recordTerminal(reason)
            },
            onCloseAcknowledged: { res in
                stderrRecorder.recordCloseAcknowledged(res)
            }
        )

        try withExtendedLifetime((stdoutReader, stderrReader)) {
            try writeAll(handle: stdoutWriteH, data: Data([0xAA, 0xBB]))
            try writeAll(handle: stderrWriteH, data: Data([0xCC, 0xDD]))

            stdoutWriteH.close()

            #expect(stdoutRecorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
            #expect(stdoutRecorder.snapshot.contains(.terminal(.cleanEOF)))
            #expect(stdoutRecorder.snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))

            try writeAll(handle: stderrWriteH, data: Data([0xEE, 0xFF]))

            stderrWriteH.close()

            #expect(stderrRecorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
            #expect(stderrRecorder.snapshot.contains(.terminal(.cleanEOF)))
            #expect(stderrRecorder.snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))

            #expect(stdoutData.value == Data([0xAA, 0xBB]))
            #expect(stderrData.value == Data([0xCC, 0xDD, 0xEE, 0xFF]))
        }
    }

    @Test("Real pipe: Explicit cancellation while writer is still alive reports cancelled and closes once")
    func realPipeExplicitCancellationWhileWriterAlive() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let ownerQueue = DispatchQueue(label: "test.reader.cancel")
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: ownerQueue,
            onData: { chunk in recorder.recordData(count: chunk.count) },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        try writeAll(handle: writeH, data: Data([0x10, 0x20]))

        reader.cancel()

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder.snapshot.contains(.terminal(.cancelled)))
        #expect(recorder.snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)

        reader.cancel()
        ownerQueue.sync { }
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)

        _ = reader
    }

    @Test("Real pipe: Cancellation requested from inside data callback does not deadlock")
    func realPipeCancellationFromInsideDataCallback() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let ownerQueue = DispatchQueue(label: "test.reader.reentrant")
        let recorder = EventRecorder()
        let weakReader = WeakBox<DiagnosticPipeReader>()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                recorder.recordData(count: chunk.count)
                weakReader.get()?.cancel()
            },
            onTerminal: { reason in
                recorder.recordTerminal(reason)
            },
            onCloseAcknowledged: { res in
                recorder.recordCloseAcknowledged(res)
            }
        )
        weakReader.set(reader)

        try writeAll(handle: writeH, data: Data([0x42, 0x43]))

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder.snapshot.contains(.terminal(.cancelled)))
        #expect(recorder.snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)

        weakReader.clear()
        _ = reader
    }

    @Test("Real pipe: Reader and scratch buffer deallocate without retain cycle after close acknowledgement")
    func realPipeDeallocationReleasesReaderAndScratchBuffer() throws {
        weak var weakReaderRef: DiagnosticPipeReader?
        let recorder = EventRecorder()

        try {
            let (readH, writeH) = try makeOwnedPipe()
            defer {
                writeH.close()
                readH.close()
            }

            let weakHolder = WeakBox<DiagnosticPipeReader>()
            let reader = try DiagnosticPipeReader(
                stream: .stdout,
                fileDescriptor: readH.transfer(),
                onData: { chunk in
                    recorder.recordData(count: chunk.count)
                },
                onTerminal: { reason in
                    recorder.recordTerminal(reason)
                },
                onCloseAcknowledged: { res in
                    recorder.recordCloseAcknowledged(res)
                }
            )
            weakHolder.set(reader)
            weakReaderRef = reader

            reader.cancel()
            #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
            weakHolder.clear()
        }()

        #expect(weakReaderRef == nil)
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
    }

    @Test("Real pipe: Non-destructive flag inspection on rawFileDescriptor preserves initial flags and O_NONBLOCK")
    func realPipeFlagPreservation() throws {
        #expect(throws: DiagnosticReaderSetupError.invalidDescriptor) {
            _ = try DiagnosticPipeReader(
                stream: .stdout,
                fileDescriptor: -1,
                onData: { _ in },
                onTerminal: { _ in },
                onCloseAcknowledged: { _ in }
            )
        }

        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let rawReadFD = readH.currentRawFD!
        let initialFlags = Darwin.fcntl(rawReadFD, F_GETFL)
        #expect(initialFlags != -1)

        let recorder = EventRecorder()
        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        let readerFD = reader.rawFileDescriptor
        let currentFlags = Darwin.fcntl(readerFD, F_GETFL)
        #expect(currentFlags != -1)
        #expect((currentFlags & O_NONBLOCK) != 0)
        #expect((currentFlags & ~O_NONBLOCK) == (initialFlags & ~O_NONBLOCK))

        reader.cancel()
        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
    }

    @Test("Real pipe: Level-triggered DispatchSource resumption above 64KiB via structured nonblocking writer")
    func realPipeLevelTriggeredContinuationAbove64KiB() throws {
        let (readHandle, writeHandle) = try makeOwnedPipe()
        let readerQueue = DispatchQueue(label: "test.fixture.reader")
        let recorder = EventRecorder()
        let receivedData = LockedData()

        let totalByteCount = 70_000
        var payload = Data(count: totalByteCount)
        for i in 0..<totalByteCount {
            payload[i] = UInt8(i & 0xFF)
        }

        // Structured bulk writer takes sole ownership of writeHandle
        let writer = StructuredBulkWriter(handle: writeHandle, payload: payload)

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readHandle.transfer(),
            queue: readerQueue,
            onData: { chunk in
                receivedData.append(chunk)
                recorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in
                recorder.recordTerminal(reason)
            },
            onCloseAcknowledged: { res in
                recorder.recordCloseAcknowledged(res)
            }
        )

        var writerQuiescedCleanly = false
        defer {
            // Guarantee structured writer quiescence and cleanup on any exit path
            if !writerQuiescedCleanly {
                let (q, _) = writer.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
                if !q {
                    Issue.record("Writer failed to quiesce in defer cleanup")
                }
            }
            readHandle.close()
        }

        writer.start()

        // Wait boundedly for writer to naturally complete transmission and close descriptor
        let (writerCompleted, writerReport) = writer.awaitCompletion(timeoutSeconds: 10.0)
        #expect(writerCompleted == true)
        guard writerCompleted, let report = writerReport else {
            Issue.record("Writer timed out during transmission")
            return
        }

        #expect(report.primaryResult == .completed(totalBytesWritten: totalByteCount))
        #expect(report.closeAttemptCount == 1)
        #expect(report.cleanupCloseError == nil)
        writerQuiescedCleanly = report.isQuiesced

        // Await reader close acknowledgement
        let readerClosed = recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0)
        #expect(readerClosed == true)
        guard readerClosed else {
            Issue.record("Reader failed to acknowledge close")
            return
        }

        #expect(receivedData.value == payload)
        #expect(receivedData.value.count == totalByteCount)
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
        #expect(recorder.snapshot.contains(.terminal(.cleanEOF)))
        #expect(recorder.snapshot.contains(.closeAcknowledged(isSuccess: true, errno: nil)))

        _ = reader
    }

    @Test("Structured Bulk Writer Safe Regression 1: Injected zero-write and fatal errno fail cleanly and quiesce")
    func bulkWriterInjectedZeroAndFatalWriteFailureHandling() throws {
        // Case A: Injected zero write failure
        let (readH1, writeH1) = try makeOwnedPipe()
        let dummyPayload = Data(repeating: 0x41, count: 10_000)
        let zeroWriter = StructuredBulkWriter(
            handle: writeH1,
            payload: dummyPayload,
            simulatedFailure: (triggerAtOffset: 200, error: 0)
        )
        var zeroQuiescedCleanly = false
        defer {
            if !zeroQuiescedCleanly {
                _ = zeroWriter.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
            }
            readH1.close()
        }

        zeroWriter.start()
        let (zeroCompleted, zeroReport) = zeroWriter.awaitCompletion(timeoutSeconds: 5.0)
        #expect(zeroCompleted == true)
        #expect(zeroReport?.primaryResult == .zeroWriteFailure(offset: 200))
        #expect(zeroReport?.closeAttemptCount == 1)
        #expect(zeroReport?.cleanupCloseError == nil)
        zeroQuiescedCleanly = zeroReport?.isQuiesced ?? false

        // Case B: Injected fatal write error (EIO)
        let (readH2, writeH2) = try makeOwnedPipe()
        let fatalWriter = StructuredBulkWriter(
            handle: writeH2,
            payload: dummyPayload,
            simulatedFailure: (triggerAtOffset: 400, error: EIO)
        )
        var fatalQuiescedCleanly = false
        defer {
            if !fatalQuiescedCleanly {
                _ = fatalWriter.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
            }
            readH2.close()
        }

        fatalWriter.start()
        let (fatalCompleted, fatalReport) = fatalWriter.awaitCompletion(timeoutSeconds: 5.0)
        #expect(fatalCompleted == true)
        #expect(fatalReport?.primaryResult == .fatalSyscallError(errno: EIO, offset: 400))
        #expect(fatalReport?.closeAttemptCount == 1)
        #expect(fatalReport?.cleanupCloseError == nil)
        fatalQuiescedCleanly = fatalReport?.isQuiesced ?? false
    }

    @Test("Structured Bulk Writer Safe Regression 2: Controlled abort ensures writer quiescence before reader cancel")
    func bulkWriterControlledAbortAndQuiescenceOrdering() throws {
        let (readH, writeH) = try makeOwnedPipe()
        let totalByteCount = 50_000
        let payload = Data(repeating: 0x5A, count: totalByteCount)
        let pauseOffset = 4096

        let pauseReached = DispatchSemaphore(value: 0)
        let resumeGate = DispatchSemaphore(value: 0)
        let lifecycleRecorder = OrderedLifecycleRecorder(maxCapacity: 100)

        let writer = StructuredBulkWriter(
            handle: writeH,
            payload: payload,
            pauseAtOffset: pauseOffset,
            pauseReached: pauseReached,
            resumeGate: resumeGate,
            lifecycleRecorder: lifecycleRecorder
        )

        let readerQueue = DispatchQueue(label: "test.reader.abort.ordering")
        let readerCloseBox = WaitBox<Result<Void, DiagnosticCloseError>>()

        let readerQueueHeld = DispatchSemaphore(value: 0)
        let releaseReaderQueue = DispatchSemaphore(value: 0)
        defer {
            releaseReaderQueue.signal()
        }

        readerQueue.async {
            readerQueueHeld.signal()
            _ = releaseReaderQueue.wait(timeout: .now() + 5.0)
        }

        let queueHoldResult = readerQueueHeld.wait(timeout: .now() + 5.0)
        #expect(queueHoldResult == .success)
        guard queueHoldResult == .success else {
            Issue.record("Failed to coordinate reader queue hold")
            return
        }

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: readerQueue,
            onData: { _ in },
            onTerminal: { _ in },
            onCloseAcknowledged: { res in
                let isSuccess: Bool
                let errno: Int32?
                switch res {
                case .success:
                    isSuccess = true
                    errno = nil
                case let .failure(err):
                    isSuccess = false
                    errno = err.errno
                }
                lifecycleRecorder.record(.readerCloseAcknowledged(isSuccess: isSuccess, errno: errno))
                readerCloseBox.signal(with: res)
            }
        )

        var writerQuiescedCleanly = false
        defer {
            if !writerQuiescedCleanly {
                resumeGate.signal()
                _ = writer.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
            }
            readH.close()
        }

        writer.start()

        // Bounded wait for writer to reach the injected pause point (offset == 4096)
        let pauseResult = pauseReached.wait(timeout: .now() + 5.0)
        #expect(pauseResult == .success)
        guard pauseResult == .success else {
            Issue.record("Writer failed to reach injected pause point within timeout")
            return
        }

        // Writer is now deterministically paused at 4096 bytes (< 50,000)
        // Request stop and await quiescence
        let (writerQuiesced, writerReport) = writer.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
        #expect(writerQuiesced == true)
        guard writerQuiesced, let report = writerReport else {
            Issue.record("Writer failed to quiesce within timeout")
            return
        }

        writerQuiescedCleanly = report.isQuiesced
        #expect(report.primaryResult == .aborted(offset: pauseOffset))
        #expect(pauseOffset < totalByteCount)
        #expect(report.closeAttemptCount == 1)
        #expect(report.cleanupCloseError == nil)

        // Writer is confirmed quiescent and closed BEFORE reader cancellation intent is initiated
        lifecycleRecorder.record(.readerCancelIntent)
        reader.cancel()

        // Release readerQueue so the cancellation block can execute and close reader
        releaseReaderQueue.signal()

        let readerCloseRes = readerCloseBox.wait(timeoutSeconds: 5.0)
        #expect(readerCloseRes != nil)
        guard let closeRes = readerCloseRes else {
            Issue.record("Reader failed to acknowledge close within timeout")
            return
        }
        switch closeRes {
        case .success:
            #expect(true)
        case let .failure(err):
            Issue.record("Unexpected reader close failure: \(err)")
        }

        // Assert strict chronological lifecycle event ordering
        let events = lifecycleRecorder.snapshot

        let lastWriteIdx = events.lastIndex(where: {
            if case .writeCallbackCompleted = $0 { return true }
            return false
        })
        let writerCloseAttemptIdx = events.firstIndex(where: {
            if case .writerCloseAttempt = $0 { return true }
            return false
        })
        let writerCloseResultIdx = events.firstIndex(where: {
            if case .writerCloseResult = $0 { return true }
            return false
        })
        let writerQuiescenceIdx = events.firstIndex(where: {
            if case .writerQuiescenceAcknowledged = $0 { return true }
            return false
        })
        let readerCancelIntentIdx = events.firstIndex(where: {
            if case .readerCancelIntent = $0 { return true }
            return false
        })
        let readerCloseAckIdx = events.firstIndex(where: {
            if case .readerCloseAcknowledged = $0 { return true }
            return false
        })

        #expect(lastWriteIdx != nil)
        #expect(writerCloseAttemptIdx != nil)
        #expect(writerCloseResultIdx != nil)
        #expect(writerQuiescenceIdx != nil)
        #expect(readerCancelIntentIdx != nil)
        #expect(readerCloseAckIdx != nil)

        if let w = lastWriteIdx,
           let ca = writerCloseAttemptIdx,
           let cr = writerCloseResultIdx,
           let q = writerQuiescenceIdx,
           let rci = readerCancelIntentIdx,
           let rca = readerCloseAckIdx {
            #expect(w < ca)
            #expect(ca < cr)
            #expect(cr < q)
            #expect(q < rci)
            #expect(rci < rca)
        }

        // Verify no write callbacks occurred after writerCloseAttempt or writerQuiescenceAcknowledged
        if let ca = writerCloseAttemptIdx {
            let postCloseWrites = events[ca...].filter {
                if case .writeCallbackCompleted = $0 { return true }
                return false
            }
            #expect(postCloseWrites.isEmpty)
        }

        _ = reader
    }

    @Test("Structured Bulk Writer Safe Regression 3: Cancel-handler-owned state survives wrapper deallocation")
    func bulkWriterCancelHandlerStateSurvivesWrapperDeallocation() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            readH.close()
        }

        let writerQueue = DispatchQueue(label: "test.writer.queue.survival")
        let payload = Data(repeating: 0x42, count: 10_000)

        let queueHeld = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        defer {
            releaseQueue.signal()
        }

        // Hold the writer queue
        writerQueue.async {
            queueHeld.signal()
            _ = releaseQueue.wait(timeout: .now() + 5.0)
        }

        let heldResult = queueHeld.wait(timeout: .now() + 5.0)
        #expect(heldResult == .success)
        guard heldResult == .success else {
            Issue.record("Failed to coordinate queue hold")
            return
        }

        weak var weakWriter: StructuredBulkWriter?
        let sharedState: StructuredBulkWriterState

        do {
            let writer = StructuredBulkWriter(
                handle: writeH,
                payload: payload,
                queue: writerQueue
            )
            weakWriter = writer
            sharedState = writer.state
            writer.start()
            writer.requestCancel()
            // Drop writer wrapper explicitly at end of scope
        }

        // Assert weak wrapper is deallocated immediately while queue is STILL held
        #expect(weakWriter == nil)

        // Release the writer queue so cancellation handler can execute
        releaseQueue.signal()

        // Await quiescence on sharedState which survived wrapper deallocation
        let (quiesced, report) = sharedState.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
        #expect(quiesced == true)
        #expect(report != nil)
        #expect(report?.closeAttemptCount == 1)
        #expect(report?.cleanupCloseError == nil)

        if let rep = report {
            switch rep.primaryResult {
            case .aborted, .completed:
                #expect(true)
            default:
                Issue.record("Unexpected primary result: \(rep.primaryResult)")
            }
        }
    }

    @Test("Structured Bulk Writer Safe Regression 4: Timeout branch prevents premature downstream reader close")
    func bulkWriterTimeoutBranchPreventsDownstreamClose() throws {
        let (readH, writeH) = try makeOwnedPipe()
        let writerQueue = DispatchQueue(label: "test.writer.queue.timeout")
        let payload = Data(repeating: 0x55, count: 20_000)

        let queueHeld = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        defer {
            releaseQueue.signal()
        }

        // Hold the writer queue so writer cannot quiesce yet
        writerQueue.async {
            queueHeld.signal()
            _ = releaseQueue.wait(timeout: .now() + 5.0)
        }

        let heldResult = queueHeld.wait(timeout: .now() + 5.0)
        #expect(heldResult == .success)
        guard heldResult == .success else {
            Issue.record("Failed to coordinate queue hold")
            return
        }

        let writer = StructuredBulkWriter(
            handle: writeH,
            payload: payload,
            queue: writerQueue
        )
        writer.start()

        let recorder = EventRecorder()
        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        // Attempt stop with zero/insufficient wait budget while writer queue is still held
        let (quiescedEarly, _) = writer.stopAndAwaitQuiescence(timeoutSeconds: 0.001)

        // Verify wait budget failed honestly
        #expect(quiescedEarly == false)

        var downstreamReaderCancelled = false
        if !quiescedEarly {
            // CHECKED BRANCH: Because writer quiescence is unconfirmed,
            // we explicitly DO NOT cancel the reader or close the read descriptor!
            #expect(recorder.recordedCloseAckCount == 0)
            #expect(recorder.recordedTerminalCount == 0)
        } else {
            reader.cancel()
            downstreamReaderCancelled = true
        }

        #expect(downstreamReaderCancelled == false)

        // Now release the held queue so real cleanup can finish
        releaseQueue.signal()

        // Bounded real cleanup MUST complete
        let (quiescedFinal, report) = writer.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
        #expect(quiescedFinal == true)
        #expect(report?.isQuiesced == true)
        #expect(report?.closeAttemptCount == 1)

        // NOW that writer is confirmed quiescent, it is safe to cancel reader
        reader.cancel()
        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder.recordedCloseAckCount == 1)

        _ = reader
    }

    @Test("Structured Bulk Writer Safe Regression 5: Primary write failure and cleanup failure are both preserved")
    func bulkWriterPrimaryFailureAndCleanupFailurePreserved() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            readH.close()
        }

        let payload = Data(repeating: 0xEE, count: 5000)
        let writer = StructuredBulkWriter(
            handle: writeH,
            payload: payload,
            simulatedFailure: (triggerAtOffset: 200, error: EIO),
            simulatedCloseError: EBADF
        )
        defer {
            writer.stopAndAwaitQuiescence(timeoutSeconds: 5.0)
        }

        writer.start()

        let (completed, report) = writer.awaitCompletion(timeoutSeconds: 5.0)
        #expect(completed == true)
        #expect(report != nil)
        guard let rep = report else {
            Issue.record("Expected writer report")
            return
        }

        // Both primary write failure AND cleanup failure are preserved
        #expect(rep.primaryResult == .fatalSyscallError(errno: EIO, offset: 200))
        #expect(rep.closeAttemptCount == 1)
        #expect(rep.cleanupCloseError == EBADF)
        #expect(rep.isQuiesced == true)
    }

    @Test("Structured Bulk Writer Safe Regression 6: Prestart disposal preserves cleanup outcome and unactivated state")
    func bulkWriterPrestartDisposalPreservesCleanupOutcome() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            readH.close()
        }

        let payload = Data(repeating: 0xAA, count: 1000)
        let writer = StructuredBulkWriter(
            handle: writeH,
            payload: payload,
            simulatedCloseError: EIO
        )

        // Dispose without calling start()
        let (quiesced, report) = writer.stopAndAwaitQuiescence(timeoutSeconds: 1.0)
        #expect(quiesced == true)
        #expect(report != nil)
        guard let rep = report else {
            Issue.record("Expected writer report on prestart disposal")
            return
        }

        #expect(rep.primaryResult == .aborted(offset: 0))
        #expect(rep.closeAttemptCount == 1)
        #expect(rep.cleanupCloseError == EIO)
        #expect(rep.isQuiesced == true)
    }

    // MARK: - 5. Bounded Off-Owner Cancellation Enqueue & Atomic Generation

    @Test("Bounded off-owner cancellation enqueue: 50 concurrent cancel callers enqueue exactly one async block")
    func cancellationBoundedOffOwnerEnqueue() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let ownerQueue = DispatchQueue(label: "test.bounded.cancel.owner")
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: ownerQueue,
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        let queueHeld = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)

        defer {
            releaseQueue.signal()
        }

        ownerQueue.async {
            queueHeld.signal()
            _ = releaseQueue.wait(timeout: .now() + 5.0)
        }

        let heldResult = queueHeld.wait(timeout: .now() + 5.0)
        #expect(heldResult == .success)
        guard heldResult == .success else {
            Issue.record("Failed to coordinate queue hold within bounded timeout")
            return
        }

        // 50 concurrent external cancel calls from background threads
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            reader.cancel()
        }

        // Release the owner queue
        releaseQueue.signal()

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)

        // Observe internal gate submission count: exactly ONE off-owner queue.async was enqueued!
        #expect(reader.offOwnerCancelEnqueueCount == 1)
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
        #expect(recorder.snapshot == [.terminal(.cancelled), .closeAcknowledged(isSuccess: true, errno: nil)])

        // Subsequent stale cancel does NOT increase submissions or touch descriptor
        reader.cancel()
        ownerQueue.sync { }
        #expect(reader.offOwnerCancelEnqueueCount == 1)
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
    }

    @Test("Atomic generation: 50 concurrent handle constructions produce 50 unique generations")
    func atomicGenerationConcurrentUniqueness() {
        let generations = LockedSet<Int>()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let handle = TestOwnedFD(rawFD: -1)
            generations.insert(handle.generation)
            handle.close()
        }
        #expect(generations.count == 50)
    }

    @Test("Event recorder: Reaching capacity trips overflow flag without silent unbounded growth")
    func eventRecorderCapacityCapAndOverflowFlag() {
        let recorder = EventRecorder(maxCapacity: 5)
        for i in 1...10 {
            recorder.recordData(count: i)
        }
        #expect(recorder.isOverflowed == true)
        #expect(recorder.snapshot.count == 5)
    }

    // MARK: - 6. Deterministic Syscall-Seam Tests

    /// Mock syscall implementation for deterministic fault injection.
    private final class MockSyscalls: DiagnosticPosixSyscalls, @unchecked Sendable {
        private let lock = NSLock()

        var getFlagsResult: (flags: Int32, error: Int32?) = (0, nil)
        var setFlagsResult: Int32? = nil
        var simulatedCloseError: Int32? = nil
        let performRealKernelClose: Bool

        var recordedGetFlagsFDs: [Int32] = []
        var recordedSetFlags: [(fd: Int32, flags: Int32)] = []
        var readScript: [(bytesRead: Int, error: Int32?, payload: [UInt8])] = []
        var totalReadOps: Int = 0
        var totalBytesRead: Int = 0
        var closedFDs: [Int32] = []
        var kernelCloseOutcomes: [Int32: Int32?] = [:]

        init(performRealKernelClose: Bool = false) {
            self.performRealKernelClose = performRealKernelClose
        }

        func getFlags(fd: Int32) -> (flags: Int32, error: Int32?) {
            lock.lock()
            defer { lock.unlock() }
            recordedGetFlagsFDs.append(fd)
            return getFlagsResult
        }

        func setFlags(fd: Int32, flags: Int32) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            recordedSetFlags.append((fd, flags))
            return setFlagsResult
        }

        func read(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) -> (bytesRead: Int, error: Int32?) {
            lock.lock()
            defer { lock.unlock() }
            totalReadOps += 1

            if !readScript.isEmpty {
                let next = readScript.removeFirst()
                if next.bytesRead > 0 {
                    let toCopy = min(count, next.payload.count)
                    next.payload.withUnsafeBytes { raw in
                        buffer.copyMemory(from: raw.baseAddress!, byteCount: toCopy)
                    }
                    totalBytesRead += toCopy
                    return (toCopy, nil)
                } else {
                    return (next.bytesRead, next.error)
                }
            }
            return (-1, EAGAIN)
        }

        func close(fd: Int32) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            closedFDs.append(fd)

            var kernelErr: Int32? = nil
            if performRealKernelClose {
                let ret = Darwin.close(fd)
                if ret != 0 {
                    kernelErr = Darwin.errno
                }
                kernelCloseOutcomes[fd] = kernelErr
            }

            if let simErr = simulatedCloseError {
                return simErr
            }
            return kernelErr
        }

        var recordedClosedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return closedFDs.count
        }
    }

    @Test("Syscall seam: EINTR then valid bytes then EAGAIN resumes without terminal callback")
    func seamEINTRThenBytesThenEAGAIN() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        mock.readScript = [
            (-1, EINTR, []),
            (4, nil, [0x01, 0x02, 0x03, 0x04]),
            (-1, EAGAIN, [])
        ]

        let queue = DispatchQueue(label: "seam.eintr")
        let received = LockedData()
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: queue,
            syscalls: mock,
            onData: { chunk in
                received.append(chunk)
                recorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        reader.pump()
        queue.sync { }

        #expect(received.value == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(mock.totalReadOps == 3)
        #expect(recorder.recordedTerminalCount == 0)

        reader.cancel()
        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(mock.recordedClosedCount == 1)
    }

    @Test("Syscall seam: All-EINTR exhausts 32-operation quota and yields without terminal or hang")
    func seamAllEINTROperationQuotaExhaustion() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        mock.readScript = Array(repeating: (-1, EINTR, []), count: 40)

        let queue = DispatchQueue(label: "seam.quota.ops")
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: queue,
            syscalls: mock,
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        reader.pump()
        queue.sync { }

        #expect(mock.totalReadOps == 32)
        #expect(recorder.recordedTerminalCount == 0)

        reader.cancel()
        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(mock.recordedClosedCount == 1)
    }

    @Test("Syscall seam: 64KiB byte quota yields and later pump resumes without data loss or reordering")
    func seam64KiBByteQuotaYieldsAndResumes() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        let chunk8k = [UInt8](repeating: 0x55, count: 8192)
        let chunkRemainder = [UInt8](repeating: 0xAA, count: 4096)
        mock.readScript = Array(repeating: (8192, nil, chunk8k), count: 8) + [(4096, nil, chunkRemainder), (-1, EAGAIN, [])]

        let queue = DispatchQueue(label: "seam.quota.bytes")
        let deliveredBytes = LockedCounter()
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: queue,
            syscalls: mock,
            onData: { chunk in
                #expect(chunk.count <= 8192)
                deliveredBytes.add(chunk.count)
                recorder.recordData(count: chunk.count)
            },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        reader.pump()
        #expect(deliveredBytes.value == 65536)
        #expect(mock.totalReadOps == 8)

        reader.pump()
        #expect(deliveredBytes.value == 65536 + 4096)
        #expect(mock.totalReadOps == 10)

        reader.cancel()
        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(mock.recordedClosedCount == 1)
    }

    @Test("Syscall seam: Fatal read error captures exact errno and terminates immediately")
    func seamFatalReadErrorCapturesExactErrno() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        mock.readScript = [
            (-1, EIO, [])
        ]

        let queue = DispatchQueue(label: "seam.fatal.error")
        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            queue: queue,
            syscalls: mock,
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        reader.pump()

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder.snapshot == [.terminal(.readError(errno: EIO)), .closeAcknowledged(isSuccess: true, errno: nil)])
        #expect(recorder.recordedTerminalCount == 1)
        #expect(recorder.recordedCloseAckCount == 1)
        #expect(mock.recordedClosedCount == 1)

        _ = reader
    }

    @Test("Syscall seam: Race permutations settle first terminal outcome and close occurs once")
    func seamRacePermutationsFirstTerminalWins() throws {
        let (readH1, writeH1) = try makeOwnedPipe()
        defer {
            writeH1.close()
            readH1.close()
        }

        let mock1 = MockSyscalls(performRealKernelClose: true)
        mock1.readScript = [(0, nil, [])]
        let recorder1 = EventRecorder()

        let reader1 = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH1.transfer(),
            syscalls: mock1,
            onData: { _ in },
            onTerminal: { reason in recorder1.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder1.recordCloseAcknowledged(res) }
        )

        reader1.pump()
        #expect(recorder1.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder1.snapshot == [.terminal(.cleanEOF), .closeAcknowledged(isSuccess: true, errno: nil)])

        reader1.cancel()
        #expect(recorder1.recordedTerminalCount == 1)
        #expect(recorder1.recordedCloseAckCount == 1)

        let (readH2, writeH2) = try makeOwnedPipe()
        defer {
            writeH2.close()
            readH2.close()
        }

        let mock2 = MockSyscalls(performRealKernelClose: true)
        mock2.readScript = [(0, nil, [])]
        let recorder2 = EventRecorder()

        let reader2 = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH2.transfer(),
            syscalls: mock2,
            onData: { _ in },
            onTerminal: { reason in recorder2.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder2.recordCloseAcknowledged(res) }
        )

        reader2.cancel()
        #expect(recorder2.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder2.snapshot == [.terminal(.cancelled), .closeAcknowledged(isSuccess: true, errno: nil)])

        reader2.pump()
        #expect(mock2.totalReadOps == 0)
        #expect(recorder2.recordedTerminalCount == 1)
        #expect(recorder2.recordedCloseAckCount == 1)
    }

    @Test("Syscall seam: Setup failure closes transferred descriptor exactly once before throwing")
    func seamSetupFailureCleansDescriptorOnce() throws {
        let mockGetFlFail = MockSyscalls(performRealKernelClose: false)
        mockGetFlFail.getFlagsResult = (-1, EBADF)

        #expect(throws: DiagnosticReaderSetupError.getFlagsFailed(errno: EBADF, cleanupError: nil)) {
            _ = try DiagnosticPipeReader(
                stream: .stdout,
                fileDescriptor: 100,
                syscalls: mockGetFlFail,
                onData: { _ in },
                onTerminal: { _ in },
                onCloseAcknowledged: { _ in }
            )
        }
        #expect(mockGetFlFail.closedFDs == [100])

        let mockSetFlFail = MockSyscalls(performRealKernelClose: false)
        mockSetFlFail.setFlagsResult = EINVAL

        #expect(throws: DiagnosticReaderSetupError.setFlagsFailed(errno: EINVAL, cleanupError: nil)) {
            _ = try DiagnosticPipeReader(
                stream: .stdout,
                fileDescriptor: 200,
                syscalls: mockSetFlFail,
                onData: { _ in },
                onTerminal: { _ in },
                onCloseAcknowledged: { _ in }
            )
        }
        #expect(mockSetFlFail.closedFDs == [200])
    }

    @Test("Syscall seam: Setup failure preserves both primary errno and cleanup close failure")
    func seamSetupFailureWithCleanupCloseErrorPreservesBoth() throws {
        let mock = MockSyscalls(performRealKernelClose: false)
        mock.setFlagsResult = EINVAL
        mock.simulatedCloseError = EIO

        #expect(throws: DiagnosticReaderSetupError.setFlagsFailed(errno: EINVAL, cleanupError: EIO)) {
            _ = try DiagnosticPipeReader(
                stream: .stdout,
                fileDescriptor: 300,
                syscalls: mock,
                onData: { _ in },
                onTerminal: { _ in },
                onCloseAcknowledged: { _ in }
            )
        }
        #expect(mock.closedFDs == [300])
    }

    @Test("Syscall seam: Close failure captures close error in acknowledgement without leaking kernel FD")
    func seamCloseFailureReportedInAcknowledgement() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        mock.simulatedCloseError = EIO

        let recorder = EventRecorder()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            syscalls: mock,
            onData: { _ in },
            onTerminal: { reason in recorder.recordTerminal(reason) },
            onCloseAcknowledged: { res in recorder.recordCloseAcknowledged(res) }
        )

        reader.cancel()

        #expect(recorder.awaitCloseAcknowledged(timeoutSeconds: 5.0) == true)
        #expect(recorder.snapshot == [.terminal(.cancelled), .closeAcknowledged(isSuccess: false, errno: EIO)])
        #expect(mock.recordedClosedCount == 1)
    }

    // MARK: - 7. Symmetric Pure-Core Bridge Tests

    private final class BridgeHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var state: DiagnosticCaptureState
        private var syntheticNs: UInt64 = 1_000_000_000

        init(state: DiagnosticCaptureState) {
            self.state = state
        }

        func advanceTime() -> MonotonicInstant {
            lock.lock()
            defer { lock.unlock() }
            syntheticNs += 1_000_000
            return MonotonicInstant(nanoseconds: syntheticNs)
        }

        func reduce(event: DiagnosticCaptureEvent) -> (DiagnosticCaptureState, [DiagnosticCaptureEffect]) {
            lock.lock()
            defer { lock.unlock() }
            let (newState, effects) = DiagnosticCaptureReducer.reduce(state: state, event: event)
            state = newState
            return (newState, effects)
        }

        var currentState: DiagnosticCaptureState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
    }

    private final class BridgeEffectInterpreter: @unchecked Sendable {
        private let lock = NSLock()
        private weak var stdoutReader: DiagnosticPipeReader?
        private weak var stderrReader: DiagnosticPipeReader?
        private let harness: BridgeHarness
        private let readinessBox: WaitBox<Bool>
        private let fakeFinalizerInvoked = LockedCounter()
        var recordFailureAsIssue: Bool = true

        init(
            harness: BridgeHarness,
            readinessBox: WaitBox<Bool>
        ) {
            self.harness = harness
            self.readinessBox = readinessBox
        }

        func setReaders(stdout: DiagnosticPipeReader, stderr: DiagnosticPipeReader) {
            lock.lock()
            defer { lock.unlock() }
            self.stdoutReader = stdout
            self.stderrReader = stderr
        }

        func handleEffects(_ effects: [DiagnosticCaptureEffect]) {
            for effect in effects {
                switch effect {
                case let .requestReaderClose(stream):
                    lock.lock()
                    let targetReader = (stream == .stdout) ? stdoutReader : stderrReader
                    lock.unlock()
                    targetReader?.cancel()

                case let .requestFinalization(outcome):
                    _ = outcome
                    fakeFinalizerInvoked.add(1)
                    let finalTime = harness.advanceTime()
                    let (finalState, subsequentEffects) = harness.reduce(event: .finalizationAcknowledged(at: finalTime))
                    if finalState.isResourceTeardownComplete {
                        readinessBox.signal(with: true)
                    }
                    handleEffects(subsequentEffects)

                case .requestTimer, .cancelTimer, .discardPayload:
                    break
                }
            }
        }

        func handleCloseAcknowledged(stream: DiagnosticStreamKind, result: Result<Void, DiagnosticCloseError>) {
            switch result {
            case .success:
                let time = harness.advanceTime()
                let (newState, effects) = harness.reduce(event: .readerCloseAcknowledged(stream: stream, at: time))
                if newState.isResourceTeardownComplete {
                    readinessBox.signal(with: true)
                }
                handleEffects(effects)
            case let .failure(error):
                if recordFailureAsIssue {
                    Issue.record("Simulated close failure on \(stream): \(error)")
                }
            }
        }
    }

    @Test("Pure-Core Bridge: Symmetric EOF order - stdout first, then stderr last with peer write")
    func pureCoreBridgeSymmetricStdoutFirstStderrLast() throws {
        let (stdoutReadH, stdoutWriteH) = try makeOwnedPipe()
        let (stderrReadH, stderrWriteH) = try makeOwnedPipe()
        defer {
            stdoutWriteH.close()
            stdoutReadH.close()
            stderrWriteH.close()
            stderrReadH.close()
        }

        let ownerQueue = DispatchQueue(label: "bridge.owner.queue.stdoutfirst")

        var initialState = DiagnosticCaptureState(isSpawned: true)
        initialState.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let harness = BridgeHarness(state: initialState)
        let readinessBox = WaitBox<Bool>()
        let interpreter = BridgeEffectInterpreter(harness: harness, readinessBox: readinessBox)

        let stdoutCloseBox = WaitBox<Result<Void, DiagnosticCloseError>>()
        let stderrCloseBox = WaitBox<Result<Void, DiagnosticCloseError>>()

        let stdoutReader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: stdoutReadH.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                let time = harness.advanceTime()
                let (_, effects) = harness.reduce(event: .dataChunk(stream: .stdout, byteCount: chunk.count, at: time))
                interpreter.handleEffects(effects)
            },
            onTerminal: { reason in
                let eventTime = harness.advanceTime()
                let event: DiagnosticCaptureEvent
                switch reason {
                case .cleanEOF:
                    event = .cleanEOF(stream: .stdout, at: eventTime)
                case let .readError(err):
                    event = .readError(stream: .stdout, errorCode: err, at: eventTime)
                case .cancelled:
                    return
                }
                let (_, effects) = harness.reduce(event: event)
                interpreter.handleEffects(effects)
            },
            onCloseAcknowledged: { res in
                stdoutCloseBox.signal(with: res)
                interpreter.handleCloseAcknowledged(stream: .stdout, result: res)
            }
        )

        let stderrReader = try DiagnosticPipeReader(
            stream: .stderr,
            fileDescriptor: stderrReadH.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                let time = harness.advanceTime()
                let (_, effects) = harness.reduce(event: .dataChunk(stream: .stderr, byteCount: chunk.count, at: time))
                interpreter.handleEffects(effects)
            },
            onTerminal: { reason in
                let eventTime = harness.advanceTime()
                let event: DiagnosticCaptureEvent
                switch reason {
                case .cleanEOF:
                    event = .cleanEOF(stream: .stderr, at: eventTime)
                case let .readError(err):
                    event = .readError(stream: .stderr, errorCode: err, at: eventTime)
                case .cancelled:
                    return
                }
                let (_, effects) = harness.reduce(event: event)
                interpreter.handleEffects(effects)
            },
            onCloseAcknowledged: { res in
                stderrCloseBox.signal(with: res)
                interpreter.handleCloseAcknowledged(stream: .stderr, result: res)
            }
        )

        interpreter.setReaders(stdout: stdoutReader, stderr: stderrReader)

        try writeAll(handle: stdoutWriteH, data: Data([0x01, 0x02]))
        try writeAll(handle: stderrWriteH, data: Data([0x03, 0x04]))

        stdoutWriteH.close()

        let stdoutCloseRes = stdoutCloseBox.wait(timeoutSeconds: 5.0)
        expectCloseSuccess(stdoutCloseRes)

        ownerQueue.sync {
            let midState = harness.currentState
            #expect(midState.streamClosureStatuses[.stdout] == .closeAcknowledged)
            #expect(midState.streamClosureStatuses[.stderr] == .open)
            #expect(midState.isResourceTeardownComplete == false)
            #expect(midState.isFinalizationSealed == false)
        }

        try writeAll(handle: stderrWriteH, data: Data([0x05, 0x06]))

        stderrWriteH.close()

        let stderrCloseRes = stderrCloseBox.wait(timeoutSeconds: 5.0)
        expectCloseSuccess(stderrCloseRes)

        let complete = readinessBox.wait(timeoutSeconds: 5.0)
        #expect(complete == true)

        ownerQueue.sync {
            let finalState = harness.currentState
            #expect(finalState.isFinalizationSealed == true)
            #expect(finalState.isResourceTeardownComplete == true)
            #expect(finalState.streamClosureStatuses[.stdout] == .closeAcknowledged)
            #expect(finalState.streamClosureStatuses[.stderr] == .closeAcknowledged)
            #expect(finalState.bytesRead[.stdout] == 2)
            #expect(finalState.bytesRead[.stderr] == 4)
        }

        _ = stdoutReader
        _ = stderrReader
    }

    @Test("Pure-Core Bridge: Symmetric EOF order - stderr first, then stdout last with peer write")
    func pureCoreBridgeSymmetricStderrFirstStdoutLast() throws {
        let (stdoutReadH, stdoutWriteH) = try makeOwnedPipe()
        let (stderrReadH, stderrWriteH) = try makeOwnedPipe()
        defer {
            stdoutWriteH.close()
            stdoutReadH.close()
            stderrWriteH.close()
            stderrReadH.close()
        }

        let ownerQueue = DispatchQueue(label: "bridge.owner.queue.stderrfirst")

        var initialState = DiagnosticCaptureState(isSpawned: true)
        initialState.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let harness = BridgeHarness(state: initialState)
        let readinessBox = WaitBox<Bool>()
        let interpreter = BridgeEffectInterpreter(harness: harness, readinessBox: readinessBox)

        let stdoutCloseBox = WaitBox<Result<Void, DiagnosticCloseError>>()
        let stderrCloseBox = WaitBox<Result<Void, DiagnosticCloseError>>()

        let stdoutReader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: stdoutReadH.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                let time = harness.advanceTime()
                let (_, effects) = harness.reduce(event: .dataChunk(stream: .stdout, byteCount: chunk.count, at: time))
                interpreter.handleEffects(effects)
            },
            onTerminal: { reason in
                let eventTime = harness.advanceTime()
                let event: DiagnosticCaptureEvent
                switch reason {
                case .cleanEOF:
                    event = .cleanEOF(stream: .stdout, at: eventTime)
                case let .readError(err):
                    event = .readError(stream: .stdout, errorCode: err, at: eventTime)
                case .cancelled:
                    return
                }
                let (_, effects) = harness.reduce(event: event)
                interpreter.handleEffects(effects)
            },
            onCloseAcknowledged: { res in
                stdoutCloseBox.signal(with: res)
                interpreter.handleCloseAcknowledged(stream: .stdout, result: res)
            }
        )

        let stderrReader = try DiagnosticPipeReader(
            stream: .stderr,
            fileDescriptor: stderrReadH.transfer(),
            queue: ownerQueue,
            onData: { chunk in
                let time = harness.advanceTime()
                let (_, effects) = harness.reduce(event: .dataChunk(stream: .stderr, byteCount: chunk.count, at: time))
                interpreter.handleEffects(effects)
            },
            onTerminal: { reason in
                let eventTime = harness.advanceTime()
                let event: DiagnosticCaptureEvent
                switch reason {
                case .cleanEOF:
                    event = .cleanEOF(stream: .stderr, at: eventTime)
                case let .readError(err):
                    event = .readError(stream: .stderr, errorCode: err, at: eventTime)
                case .cancelled:
                    return
                }
                let (_, effects) = harness.reduce(event: event)
                interpreter.handleEffects(effects)
            },
            onCloseAcknowledged: { res in
                stderrCloseBox.signal(with: res)
                interpreter.handleCloseAcknowledged(stream: .stderr, result: res)
            }
        )

        interpreter.setReaders(stdout: stdoutReader, stderr: stderrReader)

        try writeAll(handle: stdoutWriteH, data: Data([0x11, 0x22]))
        try writeAll(handle: stderrWriteH, data: Data([0x33, 0x44]))

        stderrWriteH.close()

        let stderrCloseRes = stderrCloseBox.wait(timeoutSeconds: 5.0)
        expectCloseSuccess(stderrCloseRes)

        ownerQueue.sync {
            let midState = harness.currentState
            #expect(midState.streamClosureStatuses[.stderr] == .closeAcknowledged)
            #expect(midState.streamClosureStatuses[.stdout] == .open)
            #expect(midState.isResourceTeardownComplete == false)
            #expect(midState.isFinalizationSealed == false)
        }

        try writeAll(handle: stdoutWriteH, data: Data([0x55, 0x66]))

        stdoutWriteH.close()

        let stdoutCloseRes = stdoutCloseBox.wait(timeoutSeconds: 5.0)
        expectCloseSuccess(stdoutCloseRes)

        let complete = readinessBox.wait(timeoutSeconds: 5.0)
        #expect(complete == true)

        ownerQueue.sync {
            let finalState = harness.currentState
            #expect(finalState.isFinalizationSealed == true)
            #expect(finalState.isResourceTeardownComplete == true)
            #expect(finalState.streamClosureStatuses[.stdout] == .closeAcknowledged)
            #expect(finalState.streamClosureStatuses[.stderr] == .closeAcknowledged)
            #expect(finalState.bytesRead[.stdout] == 4)
            #expect(finalState.bytesRead[.stderr] == 2)
        }

        _ = stdoutReader
        _ = stderrReader
    }

    @Test("Pure-Core Bridge: Negative seam test - close failure keeps stream unacknowledged in reducer")
    func pureCoreBridgeCloseFailureKeepsResourcesUnacknowledged() throws {
        let (readH, writeH) = try makeOwnedPipe()
        defer {
            writeH.close()
            readH.close()
        }

        let mock = MockSyscalls(performRealKernelClose: true)
        mock.simulatedCloseError = EIO
        mock.readScript = [(0, nil, [])]

        var initialState = DiagnosticCaptureState(isSpawned: true)
        initialState.streamClosureStatuses = [.stdout: .open]
        let harness = BridgeHarness(state: initialState)
        let readinessBox = WaitBox<Bool>()
        let interpreter = BridgeEffectInterpreter(harness: harness, readinessBox: readinessBox)
        interpreter.recordFailureAsIssue = false

        let closeBox = WaitBox<Result<Void, DiagnosticCloseError>>()

        let reader = try DiagnosticPipeReader(
            stream: .stdout,
            fileDescriptor: readH.transfer(),
            syscalls: mock,
            onData: { _ in },
            onTerminal: { reason in
                let time = harness.advanceTime()
                let (_, effects) = harness.reduce(event: .cleanEOF(stream: .stdout, at: time))
                interpreter.handleEffects(effects)
            },
            onCloseAcknowledged: { res in
                closeBox.signal(with: res)
                interpreter.handleCloseAcknowledged(stream: .stdout, result: res)
            }
        )
        interpreter.setReaders(stdout: reader, stderr: reader)

        reader.pump()

        let closeRes = closeBox.wait(timeoutSeconds: 5.0)
        expectCloseFailure(closeRes, expectedErrno: EIO)

        let state = harness.currentState
        #expect(state.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(state.isResourceTeardownComplete == false)

        _ = reader
    }
}
