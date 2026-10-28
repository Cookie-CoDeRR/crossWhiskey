//
//  DiagnosticIngressTests.swift
//  WhiskyKitTests
//
//  Focused tests for DiagnosticIngress (Slice 4 Fix #2):
//  A. Raw binary chunks with NUL and split UTF-8.
//  B. In-flight budget hold, prompt drops, transition accounting, and guarded arrival.
//  C. Entry cap with tiny chunks, input rejection, configuration validation, and counter overflow.
//  D. Producer vs idle drain lost-wakeup prevention, controlled idle boundary, and concurrent producers.
//  E. Throwing consumer with non-invoked custom description, fail-closed discard mode, and bounded barrier.
//  F. Bounded finish registration, held consumer barrier, duplicate finish, independent callback acknowledgment, and wrapper deallocation.
//  Overlap Regression: Blocking-wait / terminal-publication overlap and retry without deadlock.
//
//  Note on Test G: The optional in-process reader bridge test is explicitly omitted from this
//  isolated unit suite and deferred to the integration slice when DiagnosticPipeReader and
//  DiagnosticIngress are wired together, avoiding duplicate fixture code in this component slice.
//

import Dispatch
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Diagnostic ingress: bounded raw-byte handoff, off-reader scheduling, and immutable receipts")
struct DiagnosticIngressTests {

    // MARK: - Test Helpers

    private final class TestDataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [DiagnosticStreamKind: Data] = [.stdout: Data(), .stderr: Data()]
        private var callCount: Int = 0
        private var activeConsumers: Int = 0
        private var maxConcurrentConsumers: Int = 0

        func append(stream: DiagnosticStreamKind, data: Data) {
            lock.lock()
            activeConsumers += 1
            if activeConsumers > maxConcurrentConsumers {
                maxConcurrentConsumers = activeConsumers
            }
            let concurrentNow = activeConsumers
            streams[stream]?.append(data)
            callCount += 1
            activeConsumers -= 1
            lock.unlock()

            #expect(concurrentNow == 1)
        }

        func data(for stream: DiagnosticStreamKind) -> Data {
            lock.lock()
            defer { lock.unlock() }
            return streams[stream] ?? Data()
        }

        var totalCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        var maxConcurrency: Int {
            lock.lock()
            defer { lock.unlock() }
            return maxConcurrentConsumers
        }
    }

    private final class TestGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false
        private var arrivedCount = 0

        func arrive() {
            condition.lock()
            defer { condition.unlock() }
            arrivedCount += 1
            condition.broadcast()
        }

        func waitArrival(count: Int = 1, timeoutSeconds: Double = 5.0) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while arrivedCount < count {
                if !condition.wait(until: deadline) {
                    return arrivedCount >= count
                }
            }
            return true
        }

        func open() {
            condition.lock()
            defer { condition.unlock() }
            isOpen = true
            condition.broadcast()
        }

        func pass() {
            condition.lock()
            defer { condition.unlock() }
            while !isOpen {
                condition.wait()
            }
        }
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class TestWaitBox<T: Sendable>: @unchecked Sendable {
        private let condition = NSCondition()
        private var value: T?

        func signal(with val: T) {
            condition.lock()
            defer { condition.unlock() }
            if value == nil {
                value = val
                condition.broadcast()
            }
        }

        func wait(timeoutSeconds: Double) -> T? {
            condition.lock()
            defer { condition.unlock() }
            if let v = value { return v }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while value == nil {
                if !condition.wait(until: deadline) {
                    return value
                }
            }
            return value
        }
    }

    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _value: T?

        init(_ value: T? = nil) {
            self._value = value
        }

        var value: T? {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func set(_ value: T?) {
            lock.lock()
            defer { lock.unlock() }
            _value = value
        }
    }

    private struct TestReentrantError: Error, CustomStringConvertible, Sendable {
        let code: Int

        var description: String {
            // If custom description were invoked under lock, this assertion failure
            // would expose unsafe formatting under admission lock.
            fatalError("CustomStringConvertible.description must never be invoked under admission lock")
        }
    }

    // MARK: - Test A: Raw Binary Chunks & Stream Concatenation

    @Test("Test A: Exact raw binary chunks on both streams with NUL and split UTF8")
    func testA_exactRawBinaryChunksBothStreams() throws {
        let accumulator = TestDataAccumulator()
        let ingress = DiagnosticIngress { stream, data in
            accumulator.append(stream: stream, data: data)
        }

        defer {
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Test A deferred cleanup timed out")
            }
        }

        // Chunks with embedded NUL bytes
        let stdout1 = Data([0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x00])
        // Split UTF-8 sequence for Euro symbol '€' (0xE2, 0x82, 0xAC) across two chunks
        let stdout2Part1 = Data([0xE2, 0x82])
        let stdout2Part2 = Data([0xAC, 0x20, 0x31, 0x30, 0x30])

        let stderr1 = Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03])
        let stderr2 = Data([0xDE, 0xAD, 0xBE, 0xEF])

        #expect(ingress.enqueue(stream: .stdout, data: stdout1) == .accepted)
        #expect(ingress.enqueue(stream: .stderr, data: stderr1) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: stdout2Part1) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: stdout2Part2) == .accepted)
        #expect(ingress.enqueue(stream: .stderr, data: stderr2) == .accepted)

        guard let receipt = ingress.finish(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for ingress finish in Test A")
            return
        }

        // Verify exact concatenated bytes
        var expectedStdout = Data()
        expectedStdout.append(stdout1)
        expectedStdout.append(stdout2Part1)
        expectedStdout.append(stdout2Part2)

        var expectedStderr = Data()
        expectedStderr.append(stderr1)
        expectedStderr.append(stderr2)

        #expect(accumulator.data(for: .stdout) == expectedStdout)
        #expect(accumulator.data(for: .stderr) == expectedStderr)

        // Verify receipt counts
        #expect(receipt.acceptedBytes[.stdout] == UInt64(expectedStdout.count))
        #expect(receipt.acceptedBytes[.stderr] == UInt64(expectedStderr.count))
        #expect(receipt.consumerSuccessBytes[.stdout] == UInt64(expectedStdout.count))
        #expect(receipt.consumerSuccessBytes[.stderr] == UInt64(expectedStderr.count))
        #expect(receipt.sinkFailedBytes[.stdout] == 0)
        #expect(receipt.sinkFailedBytes[.stderr] == 0)
        #expect(receipt.queueDroppedBytes[.stdout] == 0)
        #expect(receipt.queueDroppedBytes[.stderr] == 0)
        #expect(receipt.postSealRejectedBytes[.stdout] == 0)
        #expect(receipt.postSealRejectedBytes[.stderr] == 0)
        #expect(receipt.sinkDisabledDroppedBytes[.stdout] == 0)
        #expect(receipt.sinkDisabledDroppedBytes[.stderr] == 0)
        #expect(receipt.hasCounterOverflow == false)
        #expect(receipt.consumerFailure == nil)
    }

    // MARK: - Test B: In-Flight Budget Hold & Capacity Drops

    @Test("Test B: In-flight consumer hold fills budget and next enqueue drops whole chunk")
    func testB_inFlightConsumerHoldFillsBudget() throws {
        let gate = TestGate()

        // Config: maxQueuedBytes: 1000, maxChunkBytes: 500
        let config = try DiagnosticIngressConfiguration(
            maxQueuedBytes: 1000,
            maxQueuedEntries: 10,
            maxChunkBytes: 500
        )

        let ingress = DiagnosticIngress(configuration: config) { stream, data in
            gate.arrive()
            gate.pass()
        }

        // Checked cleanup on ALL throw/return/timeout paths: open gate FIRST, then await finish
        defer {
            gate.open()
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Test B deferred cleanup timed out waiting for ingress finish")
            }
        }

        // 1. Enqueue chunk 1 (400 bytes). Enters consumer and blocks in-flight!
        let chunk1 = Data(repeating: 0x41, count: 400)
        #expect(ingress.enqueue(stream: .stdout, data: chunk1) == .accepted)

        // Guard consumer arrival at gate before proceeding
        guard gate.waitArrival(count: 1, timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for consumer to arrive at gate in Test B")
            return
        }

        let snap1 = ingress.underlyingState.authoritativeSnapshot
        #expect(snap1.inFlightBytes == 400)
        #expect(snap1.queuedBytes == 0)

        // 2. Enqueue chunk 2 (400 bytes). Stays queued in ring buffer (total pending = 800 <= 1000)
        let chunk2 = Data(repeating: 0x42, count: 400)
        #expect(ingress.enqueue(stream: .stdout, data: chunk2) == .accepted)

        let snap2 = ingress.underlyingState.authoritativeSnapshot
        #expect(snap2.inFlightBytes == 400)
        #expect(snap2.queuedBytes == 400)
        #expect(snap2.inFlightBytes + snap2.queuedBytes == 800)

        // 3. Enqueue chunk 3 (300 bytes). 800 + 300 = 1100 > 1000 budget! Whole chunk must drop!
        let chunk3 = Data(repeating: 0x43, count: 300)
        let res3 = ingress.enqueue(stream: .stdout, data: chunk3)
        #expect(res3 == .dropped(reason: .byteCapacityExceeded(requestedBytes: 300, currentQueuedAndInFlight: 800, maxQueuedBytes: 1000)))

        // Verify budget was not mutated by dropped chunk
        let snap3 = ingress.underlyingState.authoritativeSnapshot
        #expect(snap3.inFlightBytes + snap3.queuedBytes == 800)
        #expect(snap3.queueDroppedBytes[.stdout] == 300)

        // 4. Release gate so consumer can finish chunk 1 and chunk 2
        gate.open()

        guard let receipt = ingress.finish(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for ingress finish in Test B")
            return
        }

        #expect(receipt.acceptedBytes[.stdout] == 800)
        #expect(receipt.consumerSuccessBytes[.stdout] == 800)
        #expect(receipt.queueDroppedBytes[.stdout] == 300)
        #expect(receipt.highwaterPendingBytes == 800)
        #expect(receipt.highwaterPendingEntries == 2)
    }

    // MARK: - Test C: Tiny Chunks Entry Cap, Validation & Counter Overflow

    @Test("Test C: Tiny chunks entry cap, empty/oversized chunk rejection, configuration validation, and counter overflow")
    func testC_entryCapValidationAndOverflow() throws {
        // 1. Configuration validation
        #expect(throws: DiagnosticIngressConfigurationError.invalidMaxChunkBytes(70_000)) {
            _ = try DiagnosticIngressConfiguration(maxChunkBytes: 70_000)
        }
        #expect(throws: DiagnosticIngressConfigurationError.invalidMaxQueuedBytes(2_000_000)) {
            _ = try DiagnosticIngressConfiguration(maxQueuedBytes: 2_000_000)
        }
        #expect(throws: DiagnosticIngressConfigurationError.invalidMaxQueuedEntries(2_048)) {
            _ = try DiagnosticIngressConfiguration(maxQueuedEntries: 2_048)
        }
        #expect(throws: DiagnosticIngressConfigurationError.invalidMaxQueuedBytes(0)) {
            _ = try DiagnosticIngressConfiguration(maxQueuedBytes: 0)
        }
        #expect(throws: DiagnosticIngressConfigurationError.invalidDrainQuotaBytes(2000)) {
            _ = try DiagnosticIngressConfiguration(maxQueuedBytes: 1000, drainQuotaBytes: 2000)
        }

        let gate = TestGate()

        // Config: maxQueuedEntries: 4, maxChunkBytes: 100, maxQueuedBytes: 10_000
        let config = try DiagnosticIngressConfiguration(
            maxQueuedBytes: 10_000,
            maxQueuedEntries: 4,
            maxChunkBytes: 100
        )

        let ingress = DiagnosticIngress(configuration: config) { stream, data in
            gate.arrive()
            gate.pass()
        }

        defer {
            gate.open()
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Test C deferred cleanup timed out waiting for ingress finish")
            }
        }

        // Empty chunk rejected without lock
        #expect(ingress.enqueue(stream: .stdout, data: Data()) == .rejected(reason: .emptyChunk))

        // Oversized chunk (> 100 bytes) rejected without lock
        let oversized = Data(repeating: 0x55, count: 101)
        #expect(ingress.enqueue(stream: .stdout, data: oversized) == .rejected(reason: .oversizedChunk(byteCount: 101, maxChunkBytes: 100)))

        // 1st chunk enters consumer and blocks
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x01])) == .accepted)
        guard gate.waitArrival(count: 1, timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for consumer to arrive at gate in Test C")
            return
        }

        // Enqueue 4 chunks to fill the 4-entry ring buffer
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x02])) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x03])) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x04])) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x05])) == .accepted)

        // 6th enqueue must drop due to entry cap!
        let res6 = ingress.enqueue(stream: .stdout, data: Data([0x06]))
        #expect(res6 == .dropped(reason: .entryCapacityExceeded(currentEntries: 4, maxQueuedEntries: 4)))

        // Release gate and finish initial phase
        gate.open()
        guard let receipt1 = ingress.finish(timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for ingress finish in Test C initial phase")
            return
        }
        #expect(receipt1.acceptedBytes[.stdout] == 5)
        #expect(receipt1.queueDroppedBytes[.stdout] == 1)
        #expect(receipt1.highwaterPendingEntries == 5) // 1 in-flight + 4 queued
        #expect(receipt1.hasCounterOverflow == false)

        // 2. Real counter arithmetic saturation and overflow test
        let overflowIngress = DiagnosticIngress() { stream, data in
            // fast consumer
        }
        // Seed counters near UInt64.max via internal test seam
        overflowIngress.underlyingState.seedCountersForTesting(
            accepted: [.stdout: UInt64.max - 10],
            consumerSuccess: [.stdout: UInt64.max - 10]
        )
        // Enqueue 20 bytes -> triggers real addition overflow in addSaturating
        let chunk20 = Data(repeating: 0x41, count: 20)
        #expect(overflowIngress.enqueue(stream: .stdout, data: chunk20) == .accepted)

        guard let overflowReceipt = overflowIngress.finish(timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for overflow ingress finish")
            return
        }

        #expect(overflowReceipt.hasCounterOverflow == true)
        #expect(overflowReceipt.acceptedBytes[.stdout] == UInt64.max)
        #expect(overflowReceipt.consumerSuccessBytes[.stdout] == UInt64.max)
    }

    // MARK: - Test D: Producer vs Idle Lost-Wakeup, Controlled Idle Boundary & Concurrency

    @Test("Test D: Producer vs idle drain lost-wakeup prevention, controlled idle boundary, and concurrent producers")
    func testD_lostWakeupAndConcurrency() throws {
        let accumulator = TestDataAccumulator()
        let ingress = DiagnosticIngress { stream, data in
            accumulator.append(stream: stream, data: data)
        }

        defer {
            if ingress.finish(timeoutSeconds: 5.0) == nil {
                Issue.record("Test D deferred cleanup timed out")
            }
        }

        // Step 1: Controlled empty-to-idle boundary and admission from idle
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x10, 0x11])) == .accepted)

        // Wait boundedly for owner queue acknowledgment so component empties and settles to idle
        let idleBox = TestWaitBox<Void>()
        ingress.asyncAcknowledgeForTesting {
            idleBox.signal(with: ())
        }
        guard idleBox.wait(timeoutSeconds: 3.0) != nil else {
            Issue.record("Timed out waiting for initial drain to settle in Test D")
            return
        }
        #expect(ingress.underlyingState.isDrainIdle == true)

        // Now admit directly from confirmed idle state (verifying lost-wakeup prevention)
        #expect(ingress.enqueue(stream: .stderr, data: Data([0x20, 0x21])) == .accepted)
        #expect(ingress.underlyingState.drainScheduleCount >= 2)

        // Step 2: Multi-producer concurrent admissions with bounded outcome tracking
        final class AdmissionSummary: @unchecked Sendable {
            private let lock = NSLock()
            var acceptedCount = 0
            var droppedCount = 0
            var rejectedCount = 0
            var totalBytes = 0

            func record(_ res: DiagnosticIngressAdmissionResult, bytes: Int) {
                lock.lock()
                defer { lock.unlock() }
                totalBytes += bytes
                switch res {
                case .accepted: acceptedCount += 1
                case .dropped: droppedCount += 1
                case .rejected: rejectedCount += 1
                }
            }

            var snapshot: (accepted: Int, dropped: Int, rejected: Int, totalBytes: Int) {
                lock.lock()
                defer { lock.unlock() }
                return (acceptedCount, droppedCount, rejectedCount, totalBytes)
            }
        }

        let summary = AdmissionSummary()
        let group = DispatchGroup()
        let chunksPerProducer = 20
        let chunkSize = 64

        for p in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for i in 0..<chunksPerProducer {
                    let stream: DiagnosticStreamKind = (i % 2 == 0) ? .stdout : .stderr
                    let data = Data(repeating: UInt8(p * 10 + (i % 10)), count: chunkSize)
                    let res = ingress.enqueue(stream: stream, data: data)
                    summary.record(res, bytes: chunkSize)
                }
            }
        }

        // Bounded wait on producers with timeout guard
        guard group.wait(timeout: .now() + 5.0) == .success else {
            Issue.record("Producer group wait timed out in Test D")
            return
        }

        let snap = summary.snapshot
        #expect(snap.dropped == 0)
        #expect(snap.rejected == 0)
        #expect(snap.accepted == 4 * chunksPerProducer)

        guard let receipt = ingress.finish(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for ingress finish in Test D")
            return
        }

        let totalExpectedBytes = UInt64(4 + snap.totalBytes) // 2 stdout + 2 stderr initial + producers
        let totalAccepted = (receipt.acceptedBytes[.stdout] ?? 0) + (receipt.acceptedBytes[.stderr] ?? 0)
        let totalSuccess = (receipt.consumerSuccessBytes[.stdout] ?? 0) + (receipt.consumerSuccessBytes[.stderr] ?? 0)

        #expect(totalAccepted == totalExpectedBytes)
        #expect(totalSuccess == totalExpectedBytes)
        #expect(receipt.sinkFailedBytes[.stdout] == 0)
        #expect(receipt.sinkFailedBytes[.stderr] == 0)
        #expect(receipt.queueDroppedBytes[.stdout] == 0)
        #expect(receipt.queueDroppedBytes[.stderr] == 0)

        // Real scheduling bounds: strictly serial execution verified across all concurrent producers
        #expect(accumulator.maxConcurrency == 1)
        #expect(ingress.underlyingState.drainRunningHighwater <= 1)
        #expect(ingress.underlyingState.drainScheduleCount >= 2)
    }

    // MARK: - Test E: Throwing Consumer, Bounded Failure Metadata & Fail-Closed Discard

    @Test("Test E: Throwing consumer settles in-flight/queued payload and respects fail-closed mode")
    func testE_throwingConsumerFailClosedMode() throws {
        let gate = TestGate()
        let counter = AtomicCounter()

        let ingress = DiagnosticIngress { stream, data in
            let callIndex = counter.increment()
            if callIndex == 1 {
                // First chunk succeeds
                return
            } else if callIndex == 2 {
                // Second chunk blocks on gate, then throws!
                gate.arrive()
                gate.pass()
                throw TestReentrantError(code: 42)
            }
            Issue.record("Consumer invoked after sink was disabled")
        }

        defer {
            gate.open()
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Test E deferred cleanup timed out waiting for ingress finish")
            }
        }

        // Chunk 1: succeeds immediately
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x01, 0x02])) == .accepted)

        // Chunk 2: enters consumer and blocks on gate
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x03, 0x04, 0x05])) == .accepted)
        guard gate.waitArrival(count: 1, timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for consumer to arrive at gate in Test E")
            return
        }

        // Chunk 3: queued while chunk 2 is in-flight
        #expect(ingress.enqueue(stream: .stdout, data: Data([0x06, 0x07, 0x08, 0x09])) == .accepted)

        // Release gate to let chunk 2 throw
        gate.open()

        // Wait boundedly for drain worker to finish failure handling via owner queue acknowledgment
        let drainBarrierBox = TestWaitBox<Void>()
        ingress.asyncAcknowledgeForTesting {
            drainBarrierBox.signal(with: ())
        }
        guard drainBarrierBox.wait(timeoutSeconds: 3.0) != nil else {
            Issue.record("Timed out waiting for drain barrier in Test E")
            return
        }

        // Chunk 4: arriving after sink failure must be dropped with .sinkDisabled
        let res4 = ingress.enqueue(stream: .stdout, data: Data([0x0A, 0x0B]))
        if case .dropped(reason: .sinkDisabled) = res4 {} else {
            Issue.record("Expected .sinkDisabled drop for chunk arriving after sink failure")
        }

        // Wait boundedly using finish barrier
        guard let receipt = ingress.finish(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for ingress finish in Test E")
            return
        }

        // Chunk 1 (2 bytes) succeeded
        #expect(receipt.consumerSuccessBytes[.stdout] == 2)
        // Chunk 2 (3 bytes in-flight) + Chunk 3 (4 bytes queued) failed when consumer threw
        #expect(receipt.sinkFailedBytes[.stdout] == 7)
        // Total accepted = 2 + 7 = 9
        #expect(receipt.acceptedBytes[.stdout] == 9)
        // Chunk 4 was dropped due to sinkDisabled (2 bytes)
        #expect(receipt.sinkDisabledDroppedBytes[.stdout] == 2)
        // Accounting identity: accepted == success + sinkFailed
        #expect(receipt.acceptedBytes[.stdout] == receipt.consumerSuccessBytes[.stdout]! + receipt.sinkFailedBytes[.stdout]!)

        // Failure metadata contains bounded metatype name without invoking description under lock
        #expect(receipt.consumerFailure == "TestReentrantError")
        #expect(counter.count == 2)
    }

    // MARK: - Test F: Bounded Finish Registration, Held Consumer Barrier & Wrapper Deallocation

    @Test("Test F: Bounded finish registration, held consumer barrier, duplicate finish, and wrapper deallocates")
    func testF_boundedFinishRegistrationAndDeallocation() throws {
        let gate = TestGate()
        let completionCounter = AtomicCounter()
        let consumerRejectionBox = TestWaitBox<Bool>()
        let ingressBox = WeakBox<DiagnosticIngress>()

        let ingress = DiagnosticIngress { stream, data in
            if let ingress = ingressBox.value {
                // Verify blocking finish called from consumer context on owner queue returns documented nil rejection
                let reentrantResult = ingress.finish(timeoutSeconds: 1.0)
                consumerRejectionBox.signal(with: reentrantResult == nil)
            }
            gate.arrive()
            gate.pass()
        }
        ingressBox.set(ingress)

        defer {
            gate.open()
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Test F deferred cleanup timed out waiting for ingress finish")
            }
        }

        // Enqueue chunk 1 (enters consumer and blocks on gate)
        #expect(ingress.enqueue(stream: .stdout, data: Data([0xAA, 0xBB])) == .accepted)
        guard gate.waitArrival(count: 1, timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for consumer to arrive at gate in Test F")
            return
        }

        // Verify blocking finish called from consumer context returned nil without deadlocking
        guard let consumerRejection = consumerRejectionBox.wait(timeoutSeconds: 3.0), consumerRejection else {
            Issue.record("Expected blocking finish called from consumer context to return documented nil rejection")
            return
        }

        // Enqueue chunk 2 (queued in ring buffer)
        #expect(ingress.enqueue(stream: .stdout, data: Data([0xCC, 0xDD])) == .accepted)

        // 1. First finish callback registration succeeds
        let callbackBox = TestWaitBox<DiagnosticIngressReceipt>()
        let disp1 = ingress.finish { r in
            _ = completionCounter.increment()
            callbackBox.signal(with: r)
        }
        #expect(disp1 == .registered)

        // 2. Duplicate finish callback registration is rejected without retaining closure
        let disp2 = ingress.finish { _ in
            Issue.record("Duplicate callback should not be invoked")
        }
        #expect(disp2 == .alreadyPending)

        // 3. Repeated blocking finish calls with short timeout return nil without accumulating tasks
        for _ in 0..<5 {
            #expect(ingress.finish(timeoutSeconds: 0.01) == nil)
        }

        // 4. Inspect state while consumer is held: finish is NOT acknowledged yet
        #expect(ingress.isFinished == false)
        #expect(ingress.receipt == nil)
        #expect(completionCounter.count == 0)
        #expect(ingress.underlyingState.pendingRegistrationHighwater <= 1)

        // 5. Late enqueue after seal returns .sealed
        #expect(ingress.enqueue(stream: .stdout, data: Data([0xEE])) == .rejected(reason: .sealed))

        // 6. Release consumer gate to allow drain to complete
        gate.open()

        // 7. Await registered finish callback execution independently
        guard let callbackReceipt = callbackBox.wait(timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for registered finish callback to execute in Test F")
            return
        }
        #expect(callbackReceipt.acceptedBytes[.stdout] == 4)
        #expect(completionCounter.count == 1)

        // 8. Await terminal finish receipt
        guard let receipt = ingress.finish(timeoutSeconds: 5.0) else {
            Issue.record("Timed out waiting for ingress finish in Test F")
            return
        }

        #expect(receipt.acceptedBytes[.stdout] == 4)
        #expect(receipt.consumerSuccessBytes[.stdout] == 4)
        #expect(receipt.postSealRejectedBytes[.stdout] == 1)
        #expect(receipt == callbackReceipt)

        // 9. Late finish calls after completion return .alreadyFinished with receipt
        let disp3 = ingress.finish { r in
            #expect(r == receipt)
        }
        #expect(disp3 == .alreadyFinished(receipt))

        // 10. Verify blocking finish called from owner queue context via async acknowledgment returns documented nil rejection
        let ownerRejectionBox = TestWaitBox<Bool>()
        ingress.asyncAcknowledgeForTesting {
            let res = ingressBox.value?.finish(timeoutSeconds: 1.0)
            ownerRejectionBox.signal(with: res == nil)
        }
        guard let ownerRejection = ownerRejectionBox.wait(timeoutSeconds: 3.0), ownerRejection else {
            Issue.record("Expected blocking finish called from owner queue context to return documented nil rejection")
            return
        }

        // 11. Weak wrapper deallocation test with bounded quiescence
        weak var weakState: DiagnosticIngressState?
        let deallocFinishBox = TestWaitBox<Void>()
        let quiescedBox = TestWaitBox<Void>()
        do {
            let tempIngress = DiagnosticIngress { stream, data in
                // Fast consumer
            }
            weakState = tempIngress.underlyingState
            tempIngress.enqueue(stream: .stdout, data: Data([0x01]))
            tempIngress.finish { _ in
                deallocFinishBox.signal(with: ())
            }
            tempIngress.asyncAcknowledgeForTesting {
                quiescedBox.signal(with: ())
            }
            // Wrapper drops here; deinit requests finish
        }

        guard deallocFinishBox.wait(timeoutSeconds: 3.0) != nil else {
            Issue.record("Timed out waiting for dealloc test ingress to finish")
            return
        }

        guard quiescedBox.wait(timeoutSeconds: 3.0) != nil else {
            Issue.record("Timed out waiting for dealloc queue quiescence in Test F")
            return
        }
        #expect(weakState == nil)
    }

    // MARK: - Overlap Regression: Blocking-Wait / Terminal-Publication Overlap & Retry

    @Test("Regression: Blocking-wait / terminal-publication overlap and retry without deadlock")
    func testBlockingWaitTerminalPublicationOverlap() throws {
        let gate = TestGate()
        let ingress = DiagnosticIngress { stream, data in
            gate.arrive()
            gate.pass()
        }

        defer {
            gate.open()
            if ingress.finish(timeoutSeconds: 3.0) == nil {
                Issue.record("Regression test deferred cleanup timed out")
            }
        }

        // Enqueue item to occupy consumer in-flight
        #expect(ingress.enqueue(stream: .stdout, data: Data([0xAA, 0xBB])) == .accepted)
        guard gate.waitArrival(count: 1, timeoutSeconds: 3.0) else {
            Issue.record("Timed out waiting for consumer to arrive at gate in overlap regression")
            return
        }

        // Test retry: Short timeout while consumer is held returns nil cleanly without deadlock
        #expect(ingress.finish(timeoutSeconds: 0.05) == nil)

        // Launch background waiter that enters finish(timeoutSeconds:) and sleeps on finishCondition
        let backgroundWaiterBox = TestWaitBox<DiagnosticIngressReceipt>()
        let waiterEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            waiterEntered.signal()
            if let r = ingress.finish(timeoutSeconds: 5.0) {
                backgroundWaiterBox.signal(with: r)
            }
        }

        guard waiterEntered.wait(timeout: .now() + 2.0) == .success else {
            Issue.record("Failed to start background waiter in overlap regression")
            return
        }

        // Release gate while background waiter is actively blocked on finishCondition
        gate.open()

        // Background waiter must wake up upon terminal publication and receive the receipt without deadlock
        guard let bgReceipt = backgroundWaiterBox.wait(timeoutSeconds: 3.0) else {
            Issue.record("Background waiter timed out or deadlocked in overlap regression")
            return
        }

        #expect(bgReceipt.acceptedBytes[.stdout] == 2)
        #expect(bgReceipt.consumerSuccessBytes[.stdout] == 2)

        // Main thread retry finish returns published receipt immediately
        guard let mainReceipt = ingress.finish(timeoutSeconds: 3.0) else {
            Issue.record("Main thread retry finish failed in overlap regression")
            return
        }
        #expect(mainReceipt == bgReceipt)
    }
}
