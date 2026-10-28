//
//  DiagnosticIngress.swift
//  WhiskyKit
//
//  Isolated bounded diagnostic ingress for verified reader callbacks before disk/Wine wiring.
//

import Foundation

// MARK: - Ingress Configuration Errors & Validation

public enum DiagnosticIngressConfigurationError: Error, Equatable, Sendable {
    case invalidMaxQueuedBytes(Int)
    case invalidMaxQueuedEntries(Int)
    case invalidMaxChunkBytes(Int)
    case invalidDrainQuotaBytes(Int)
    case invalidDrainQuotaEntries(Int)
}

public struct DiagnosticIngressConfiguration: Sendable, Equatable {
    public let maxQueuedBytes: Int
    public let maxQueuedEntries: Int
    public let maxChunkBytes: Int
    public let drainQuotaBytes: Int
    public let drainQuotaEntries: Int

    public init(
        maxQueuedBytes: Int = 1_048_576, // 1 MiB hard ceiling per capture component this slice
        maxQueuedEntries: Int = 1_024,
        maxChunkBytes: Int = 65_536,    // 64 KiB callback limit matching reader contract
        drainQuotaBytes: Int? = nil,
        drainQuotaEntries: Int? = nil
    ) throws {
        guard maxChunkBytes > 0 && maxChunkBytes <= 65_536 else {
            throw DiagnosticIngressConfigurationError.invalidMaxChunkBytes(maxChunkBytes)
        }
        guard maxQueuedBytes > 0 && maxQueuedBytes <= 1_048_576 else {
            throw DiagnosticIngressConfigurationError.invalidMaxQueuedBytes(maxQueuedBytes)
        }
        guard maxQueuedEntries > 0 && maxQueuedEntries <= 1_024 else {
            throw DiagnosticIngressConfigurationError.invalidMaxQueuedEntries(maxQueuedEntries)
        }
        let resolvedDrainQuotaBytes = drainQuotaBytes ?? min(65_536, maxQueuedBytes)
        let resolvedDrainQuotaEntries = drainQuotaEntries ?? min(16, maxQueuedEntries)
        guard resolvedDrainQuotaBytes > 0 && resolvedDrainQuotaBytes <= maxQueuedBytes else {
            throw DiagnosticIngressConfigurationError.invalidDrainQuotaBytes(resolvedDrainQuotaBytes)
        }
        guard resolvedDrainQuotaEntries > 0 && resolvedDrainQuotaEntries <= maxQueuedEntries else {
            throw DiagnosticIngressConfigurationError.invalidDrainQuotaEntries(resolvedDrainQuotaEntries)
        }
        self.maxQueuedBytes = maxQueuedBytes
        self.maxQueuedEntries = maxQueuedEntries
        self.maxChunkBytes = maxChunkBytes
        self.drainQuotaBytes = resolvedDrainQuotaBytes
        self.drainQuotaEntries = resolvedDrainQuotaEntries
    }

    public static let defaultConfiguration: DiagnosticIngressConfiguration = {
        // Safe: Default configuration is within validated bounds
        try! DiagnosticIngressConfiguration()
    }()

    public static let `default`: DiagnosticIngressConfiguration = defaultConfiguration
}

// MARK: - Admission & Rejection Types

public enum DiagnosticIngressAdmissionResult: Sendable, Equatable {
    case accepted
    case dropped(reason: DropReason)
    case rejected(reason: RejectReason)

    public enum DropReason: Sendable, Equatable {
        case byteCapacityExceeded(requestedBytes: Int, currentQueuedAndInFlight: Int, maxQueuedBytes: Int)
        case entryCapacityExceeded(currentEntries: Int, maxQueuedEntries: Int)
        case sinkDisabled(errorDescription: String)
    }

    public enum RejectReason: Sendable, Equatable {
        case emptyChunk
        case oversizedChunk(byteCount: Int, maxChunkBytes: Int)
        case sealed
    }
}

// MARK: - Finish Registration Disposition

public enum DiagnosticIngressFinishDisposition: Sendable, Equatable {
    case registered
    case alreadyPending
    case alreadyFinished(DiagnosticIngressReceipt)
}

// MARK: - Immutable Terminal Receipt

public struct DiagnosticIngressReceipt: Sendable, Equatable {
    public let acceptedBytes: [DiagnosticStreamKind: UInt64]
    public let consumerSuccessBytes: [DiagnosticStreamKind: UInt64]
    public let sinkFailedBytes: [DiagnosticStreamKind: UInt64]
    public let queueDroppedBytes: [DiagnosticStreamKind: UInt64]
    public let postSealRejectedBytes: [DiagnosticStreamKind: UInt64]
    public let sinkDisabledDroppedBytes: [DiagnosticStreamKind: UInt64]
    public let highwaterPendingBytes: Int
    public let highwaterPendingEntries: Int
    public let hasCounterOverflow: Bool
    public let consumerFailure: String?

    public init(
        acceptedBytes: [DiagnosticStreamKind: UInt64],
        consumerSuccessBytes: [DiagnosticStreamKind: UInt64],
        sinkFailedBytes: [DiagnosticStreamKind: UInt64],
        queueDroppedBytes: [DiagnosticStreamKind: UInt64],
        postSealRejectedBytes: [DiagnosticStreamKind: UInt64],
        sinkDisabledDroppedBytes: [DiagnosticStreamKind: UInt64],
        highwaterPendingBytes: Int,
        highwaterPendingEntries: Int,
        hasCounterOverflow: Bool,
        consumerFailure: String?
    ) {
        self.acceptedBytes = acceptedBytes
        self.consumerSuccessBytes = consumerSuccessBytes
        self.sinkFailedBytes = sinkFailedBytes
        self.queueDroppedBytes = queueDroppedBytes
        self.postSealRejectedBytes = postSealRejectedBytes
        self.sinkDisabledDroppedBytes = sinkDisabledDroppedBytes
        self.highwaterPendingBytes = highwaterPendingBytes
        self.highwaterPendingEntries = highwaterPendingEntries
        self.hasCounterOverflow = hasCounterOverflow
        self.consumerFailure = consumerFailure
    }
}

// MARK: - Ingress Queue Entry & Circular Ring Buffer

struct IngressQueueEntry: Sendable {
    let stream: DiagnosticStreamKind
    let data: Data
}

final class IngressRingBuffer {
    private var storage: [IngressQueueEntry?]
    private let capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [IngressQueueEntry?](repeating: nil, count: capacity)
    }

    var isEmpty: Bool {
        count == 0
    }

    var isFull: Bool {
        count == capacity
    }

    func enqueue(_ entry: IngressQueueEntry) -> Bool {
        guard count < capacity else { return false }
        storage[tail] = entry
        tail = (tail + 1) % capacity
        count += 1
        return true
    }

    func dequeue() -> IngressQueueEntry? {
        guard count > 0 else { return nil }
        let entry = storage[head]
        storage[head] = nil // Promptly release Data reference
        head = (head + 1) % capacity
        count -= 1
        return entry
    }

    func drainAll() -> [IngressQueueEntry] {
        var items: [IngressQueueEntry] = []
        items.reserveCapacity(count)
        while let item = dequeue() {
            items.append(item)
        }
        return items
    }
}

// MARK: - Internal Ingress State

public final class DiagnosticIngressState: @unchecked Sendable {
    public typealias Consumer = @Sendable (DiagnosticStreamKind, Data) throws -> Void

    // Lock ordering invariant:
    // 1. `lock` protects internal state, queue, counters, and drain scheduling.
    // 2. `finishCondition` protects `isTerminalReceiptPublished` and blocking waiter notifications.
    // 3. `lock` and `finishCondition` are NEVER held simultaneously by any thread.
    //    Terminal publisher releases `lock` BEFORE acquiring `finishCondition` to broadcast.
    //    Blocking waiters release `lock` BEFORE acquiring `finishCondition` to wait.
    private let lock = NSLock()
    private let config: DiagnosticIngressConfiguration
    private let consumer: Consumer
    private let drainQueue: DispatchQueue
    private let drainQueueKey = DispatchSpecificKey<Void>()

    // Ring buffer queue
    private let ringBuffer: IngressRingBuffer
    private var currentQueuedBytes: Int = 0
    private var inFlightBytes: Int = 0

    // Drain scheduling flags & scheduler discipline counters
    private var isDrainScheduled: Bool = false
    private var isDraining: Bool = false
    private var activeDrainWorkers: Int = 0
    internal private(set) var drainScheduleCount: Int = 0
    internal private(set) var drainExecutionCount: Int = 0
    internal private(set) var drainRunningHighwater: Int = 0

    // Lifecycle & sink status
    private var isSealed: Bool = false
    private var isFinished: Bool = false
    private var sinkDisabled: Bool = false
    private var consumerFailureDescription: String?

    // Counters (per stream)
    private var acceptedBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]
    private var consumerSuccessBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]
    private var sinkFailedBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]
    private var queueDroppedBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]
    private var postSealRejectedBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]
    private var sinkDisabledDroppedBytes: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0]

    // Highwater & overflow
    private var highwaterPendingBytes: Int = 0
    private var highwaterPendingEntries: Int = 0
    private var hasCounterOverflow: Bool = false

    // Bounded finish registration: capacity 1 pending callback
    private var pendingFinishCompletion: (@Sendable (DiagnosticIngressReceipt) -> Void)?
    internal private(set) var pendingRegistrationHighwater: Int = 0

    // Blocking wait synchronization (protected strictly by finishCondition, never under lock)
    private let finishCondition = NSCondition()
    private var isTerminalReceiptPublished: Bool = false
    private var terminalReceipt: DiagnosticIngressReceipt?
    private var selfRetain: DiagnosticIngressState?

    init(
        config: DiagnosticIngressConfiguration,
        drainQueue: DispatchQueue,
        consumer: @escaping Consumer
    ) {
        self.config = config
        self.drainQueue = drainQueue
        self.drainQueue.setSpecific(key: drainQueueKey, value: ())
        self.consumer = consumer
        self.ringBuffer = IngressRingBuffer(capacity: config.maxQueuedEntries)

        // Hold self-retain until terminal finish receipt completes
        self.selfRetain = self
    }

    // Saturating addition helper
    private func addSaturating(_ current: UInt64, _ delta: Int) -> UInt64 {
        guard delta > 0 else { return current }
        let uDelta = UInt64(delta)
        let (res, overflow) = current.addingReportingOverflow(uDelta)
        if overflow {
            hasCounterOverflow = true
            return UInt64.max
        }
        return res
    }

    // Internal seam for testing counter saturation and overflow with real arithmetic
    internal func seedCountersForTesting(
        accepted: [DiagnosticStreamKind: UInt64]? = nil,
        consumerSuccess: [DiagnosticStreamKind: UInt64]? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let accepted = accepted {
            self.acceptedBytes = accepted
        }
        if let consumerSuccess = consumerSuccess {
            self.consumerSuccessBytes = consumerSuccess
        }
    }

    internal var isDrainIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isDraining && !isDrainScheduled && ringBuffer.isEmpty
    }

    // MARK: - Admission Path

    public func enqueue(stream: DiagnosticStreamKind, data: Data) -> DiagnosticIngressAdmissionResult {
        // Fast-path validations without lock
        guard !data.isEmpty else {
            return .rejected(reason: .emptyChunk)
        }
        guard data.count <= config.maxChunkBytes else {
            return .rejected(reason: .oversizedChunk(byteCount: data.count, maxChunkBytes: config.maxChunkBytes))
        }

        lock.lock()

        // 1. Check if sealed
        if isSealed {
            postSealRejectedBytes[stream] = addSaturating(postSealRejectedBytes[stream] ?? 0, data.count)
            lock.unlock()
            return .rejected(reason: .sealed)
        }

        // 2. Check if sink is disabled (fail-closed mode)
        if sinkDisabled {
            let err = consumerFailureDescription ?? "sinkDisabled"
            sinkDisabledDroppedBytes[stream] = addSaturating(sinkDisabledDroppedBytes[stream] ?? 0, data.count)
            lock.unlock()
            return .dropped(reason: .sinkDisabled(errorDescription: err))
        }

        // 3. Check entry capacity (snapshot count under lock BEFORE unlocking)
        if ringBuffer.isFull {
            queueDroppedBytes[stream] = addSaturating(queueDroppedBytes[stream] ?? 0, data.count)
            let currentCount = ringBuffer.count
            lock.unlock()
            return .dropped(reason: .entryCapacityExceeded(currentEntries: currentCount, maxQueuedEntries: config.maxQueuedEntries))
        }

        // 4. Check byte capacity using overflow-safe subtraction (budget covers queued + in-flight payload)
        let pending = currentQueuedBytes + inFlightBytes
        let budget = config.maxQueuedBytes
        if pending >= budget || data.count > (budget - pending) {
            queueDroppedBytes[stream] = addSaturating(queueDroppedBytes[stream] ?? 0, data.count)
            let pendingSnapshot = pending
            let requestedSnapshot = data.count
            lock.unlock()
            return .dropped(reason: .byteCapacityExceeded(
                requestedBytes: requestedSnapshot,
                currentQueuedAndInFlight: pendingSnapshot,
                maxQueuedBytes: budget
            ))
        }

        // 5. Admitted!
        let enqueued = ringBuffer.enqueue(IngressQueueEntry(stream: stream, data: data))
        precondition(enqueued, "RingBuffer enqueue failed unexpectedly when not full")

        currentQueuedBytes += data.count
        acceptedBytes[stream] = addSaturating(acceptedBytes[stream] ?? 0, data.count)

        // Update highwater marks
        let newPending = currentQueuedBytes + inFlightBytes
        if newPending > highwaterPendingBytes {
            highwaterPendingBytes = newPending
        }
        let pendingEntries = ringBuffer.count + (inFlightBytes > 0 ? 1 : 0)
        if pendingEntries > highwaterPendingEntries {
            highwaterPendingEntries = pendingEntries
        }

        // Schedule drain worker if needed
        scheduleDrainOnOwnerLocked()

        lock.unlock()
        return .accepted
    }

    // MARK: - Drain Scheduling (Lock-Protected)

    private func scheduleDrainOnOwnerLocked() {
        guard !isDrainScheduled && !isDraining else { return }
        guard !ringBuffer.isEmpty || (isSealed && inFlightBytes == 0) else { return }
        isDrainScheduled = true
        drainScheduleCount += 1
        drainQueue.async { [weak self] in
            self?.performDrain()
        }
    }

    private func performDrain() {
        var turnBytes = 0
        var turnEntries = 0
        let quotaBytes = config.drainQuotaBytes
        let quotaEntries = config.drainQuotaEntries

        lock.lock()
        activeDrainWorkers += 1
        drainExecutionCount += 1
        if activeDrainWorkers > drainRunningHighwater {
            drainRunningHighwater = activeDrainWorkers
        }
        lock.unlock()

        defer {
            lock.lock()
            activeDrainWorkers -= 1
            isDraining = false
            lock.unlock()
        }

        while true {
            lock.lock()
            isDrainScheduled = false
            isDraining = true

            if sinkDisabled {
                // If sink was disabled, discard any remaining queued items to sinkFailed
                let discarded = ringBuffer.drainAll()
                for item in discarded {
                    sinkFailedBytes[item.stream] = addSaturating(sinkFailedBytes[item.stream] ?? 0, item.data.count)
                }
                currentQueuedBytes = 0
                let finishOutcome = checkFinishCompletionLocked()
                isDraining = false
                lock.unlock()

                if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
                    publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
                }
                return
            }

            if turnBytes >= quotaBytes || turnEntries >= quotaEntries {
                // Quota reached for this turn; reschedule at most once if work remains
                isDraining = false
                var finishOutcome: (didComplete: Bool, receipt: DiagnosticIngressReceipt?, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) = (false, nil, nil)
                if !ringBuffer.isEmpty {
                    scheduleDrainOnOwnerLocked()
                } else {
                    finishOutcome = checkFinishCompletionLocked()
                }
                lock.unlock()

                if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
                    publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
                }
                return
            }

            guard let item = ringBuffer.dequeue() else {
                // Queue is empty
                let finishOutcome = checkFinishCompletionLocked()
                isDraining = false
                lock.unlock()

                if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
                    publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
                }
                return
            }

            // Move from queued to inFlight (capacity continues to be charged!)
            currentQueuedBytes -= item.data.count
            inFlightBytes += item.data.count
            lock.unlock()

            // Invoke consumer OUTSIDE lock
            var consumerError: Error? = nil
            do {
                try consumer(item.stream, item.data)
            } catch {
                consumerError = error
            }

            // Pre-compute bounded failure metadata OUTSIDE lock using metatype to avoid invoking description
            let precomputedFailure: String?
            if let err = consumerError {
                let typeName = String(describing: type(of: err))
                precomputedFailure = String(typeName.prefix(64))
            } else {
                precomputedFailure = nil
            }

            lock.lock()
            inFlightBytes -= item.data.count
            turnBytes += item.data.count
            turnEntries += 1

            if let failureSummary = precomputedFailure {
                // Consumer failed! Record sink failure and disable sink permanently
                sinkFailedBytes[item.stream] = addSaturating(sinkFailedBytes[item.stream] ?? 0, item.data.count)
                sinkDisabled = true
                consumerFailureDescription = failureSummary

                // Discard all remaining queued entries to sinkFailed
                let discarded = ringBuffer.drainAll()
                for d in discarded {
                    sinkFailedBytes[d.stream] = addSaturating(sinkFailedBytes[d.stream] ?? 0, d.data.count)
                }
                currentQueuedBytes = 0
                let finishOutcome = checkFinishCompletionLocked()
                isDraining = false
                lock.unlock()

                if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
                    publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
                }
                return
            } else {
                consumerSuccessBytes[item.stream] = addSaturating(consumerSuccessBytes[item.stream] ?? 0, item.data.count)
            }
            lock.unlock()
        }
    }

    // MARK: - Finish & Barrier

    public func requestFinish() {
        var finishOutcome: (didComplete: Bool, receipt: DiagnosticIngressReceipt?, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) = (false, nil, nil)
        lock.lock()
        if !isSealed {
            isSealed = true
            scheduleDrainOnOwnerLocked()
        } else {
            finishOutcome = checkFinishCompletionLocked()
        }
        lock.unlock()

        if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
            publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
        }
    }

    @discardableResult
    public func finish(completion: @escaping @Sendable (DiagnosticIngressReceipt) -> Void) -> DiagnosticIngressFinishDisposition {
        lock.lock()
        if let existing = terminalReceipt {
            lock.unlock()
            completion(existing)
            return .alreadyFinished(existing)
        }

        if pendingFinishCompletion != nil {
            // Already have a pending completion registered; do not retain a duplicate callback
            lock.unlock()
            return .alreadyPending
        }

        // Register the single allowed pending completion
        pendingFinishCompletion = completion
        pendingRegistrationHighwater = 1

        var finishOutcome: (didComplete: Bool, receipt: DiagnosticIngressReceipt?, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) = (false, nil, nil)
        if !isSealed {
            isSealed = true
            scheduleDrainOnOwnerLocked()
        } else {
            finishOutcome = checkFinishCompletionLocked()
        }
        lock.unlock()

        if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
            publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
        }
        return .registered
    }

    public func finish(timeoutSeconds: Double = 5.0) -> DiagnosticIngressReceipt? {
        // Reject wait on drainQueue to prevent worker deadlock
        guard DispatchQueue.getSpecific(key: drainQueueKey) == nil else {
            return nil
        }

        var finishOutcome: (didComplete: Bool, receipt: DiagnosticIngressReceipt?, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) = (false, nil, nil)
        lock.lock()
        if let receipt = terminalReceipt {
            lock.unlock()
            return receipt
        }
        if !isSealed {
            isSealed = true
            scheduleDrainOnOwnerLocked()
        } else {
            finishOutcome = checkFinishCompletionLocked()
        }
        lock.unlock()

        if finishOutcome.didComplete, let receipt = finishOutcome.receipt {
            publishFinishOutsideLock(receipt: receipt, completion: finishOutcome.completion)
            return receipt
        }

        // Wait on finishCondition strictly outside lock
        finishCondition.lock()
        defer { finishCondition.unlock() }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !isTerminalReceiptPublished {
            if !finishCondition.wait(until: deadline) {
                // Timed out: exit wait loop without accumulating tasks or callbacks
                break
            }
        }

        // Read published receipt under state lock
        lock.lock()
        let finalReceipt = terminalReceipt
        lock.unlock()
        return finalReceipt
    }

    private func checkFinishCompletionLocked() -> (didComplete: Bool, receipt: DiagnosticIngressReceipt?, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) {
        guard isSealed && !isFinished else { return (false, nil, nil) }
        guard ringBuffer.isEmpty && inFlightBytes == 0 else { return (false, nil, nil) }

        isFinished = true
        let receipt = DiagnosticIngressReceipt(
            acceptedBytes: acceptedBytes,
            consumerSuccessBytes: consumerSuccessBytes,
            sinkFailedBytes: sinkFailedBytes,
            queueDroppedBytes: queueDroppedBytes,
            postSealRejectedBytes: postSealRejectedBytes,
            sinkDisabledDroppedBytes: sinkDisabledDroppedBytes,
            highwaterPendingBytes: highwaterPendingBytes,
            highwaterPendingEntries: highwaterPendingEntries,
            hasCounterOverflow: hasCounterOverflow,
            consumerFailure: consumerFailureDescription
        )
        self.terminalReceipt = receipt

        let completion = pendingFinishCompletion
        pendingFinishCompletion = nil

        // Release selfRetain so state can deallocate cleanly
        selfRetain = nil

        return (true, receipt, completion)
    }

    private func publishFinishOutsideLock(receipt: DiagnosticIngressReceipt, completion: (@Sendable (DiagnosticIngressReceipt) -> Void)?) {
        finishCondition.lock()
        isTerminalReceiptPublished = true
        finishCondition.broadcast()
        finishCondition.unlock()

        if let completion = completion {
            drainQueue.async {
                completion(receipt)
            }
        }
    }

    // MARK: - Snapshots for Testing

    public var authoritativeSnapshot: (
        queuedBytes: Int,
        inFlightBytes: Int,
        queuedEntries: Int,
        acceptedBytes: [DiagnosticStreamKind: UInt64],
        consumerSuccessBytes: [DiagnosticStreamKind: UInt64],
        sinkFailedBytes: [DiagnosticStreamKind: UInt64],
        queueDroppedBytes: [DiagnosticStreamKind: UInt64],
        isSealed: Bool,
        isFinished: Bool,
        sinkDisabled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            currentQueuedBytes,
            inFlightBytes,
            ringBuffer.count,
            acceptedBytes,
            consumerSuccessBytes,
            sinkFailedBytes,
            queueDroppedBytes,
            isSealed,
            isFinished,
            sinkDisabled
        )
    }

    public var receipt: DiagnosticIngressReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return terminalReceipt
    }

    public var isTerminalFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }
}

// MARK: - Public DiagnosticIngress Handle

public final class DiagnosticIngress: Sendable {
    private let state: DiagnosticIngressState

    public init(
        configuration: DiagnosticIngressConfiguration = .default,
        drainQueue: DispatchQueue = DispatchQueue(label: "whiskykit.diagnostic.ingress.drain"),
        consumer: @escaping @Sendable (DiagnosticStreamKind, Data) throws -> Void
    ) {
        self.state = DiagnosticIngressState(config: configuration, drainQueue: drainQueue, consumer: consumer)
    }

    public var underlyingState: DiagnosticIngressState {
        state
    }

    @discardableResult
    public func enqueue(stream: DiagnosticStreamKind, data: Data) -> DiagnosticIngressAdmissionResult {
        state.enqueue(stream: stream, data: data)
    }

    @discardableResult
    public func finish(completion: @escaping @Sendable (DiagnosticIngressReceipt) -> Void) -> DiagnosticIngressFinishDisposition {
        state.finish(completion: completion)
    }

    public func finish(timeoutSeconds: Double = 5.0) -> DiagnosticIngressReceipt? {
        state.finish(timeoutSeconds: timeoutSeconds)
    }

    public func requestFinish() {
        state.requestFinish()
    }

    public var receipt: DiagnosticIngressReceipt? {
        state.receipt
    }

    public var isFinished: Bool {
        state.isTerminalFinished
    }

    deinit {
        // Automatically request finish upon wrapper deallocation so accepted work drains
        state.requestFinish()
    }
}
