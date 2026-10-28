//
//  DiagnosticCaptureCore.swift
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

import Foundation

// MARK: - 1. BottleID & Admission Tokens

/// Opaque validated identifier for a bottle.
///
/// Aliases (symlinks, relative paths) must be resolved to the same canonical `BottleID`
/// before entering the core.
public struct BottleID: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

/// Opaque, uniquely minted token representing an admitted diagnostic capture reservation.
public struct DiagnosticAdmissionToken: Hashable, Sendable, Identifiable {
    public let id: UInt64
    public let bottleID: BottleID

    // Internal initializer restricts token construction so callers cannot forge arbitrary tokens.
    init(id: UInt64, bottleID: BottleID) {
        self.id = id
        self.bottleID = bottleID
    }
}

/// Errors raised by the admission registry.
public enum DiagnosticAdmissionError: Error, Equatable, Sendable {
    case perBottleLimitReached(BottleID)
    case globalLimitReached(Int)
    case appTerminating
    case duplicateExternalSessionID(UUID)
    case invalidToken(DiagnosticAdmissionToken)
    case invalidMaxGlobalAdmissions(Int)
    case tokenGeneratorExhausted
}

/// Synchronous, pure admission registry core managing capture reservations.
///
/// Enforces:
/// - At most 1 active/reserved capture per `BottleID`.
/// - At most 2 active/reserved captures globally across all bottles.
/// - Monotonic, non-wrapping registry-minted token IDs with checked exhaustion.
/// - Atomic admission barrier on quit snapshotting active tokens into a cohort.
///
/// - Note: This core is synchronous and owner-confined. Concurrent callers must serialize access.
public final class DiagnosticAdmissionRegistry {
    public static let maxAllowedGlobalAdmissions: Int = 2
    public let maxGlobalAdmissions: Int

    private var activeTokens: [DiagnosticAdmissionToken: BottleID] = [:]
    private var activeBottles: [BottleID: DiagnosticAdmissionToken] = [:]
    private var activeExternalIDs: [UUID: DiagnosticAdmissionToken] = [:]
    private var isTerminating: Bool = false
    private var quitCohort: Set<DiagnosticAdmissionToken>? = nil

    private var tokenCounter: UInt64

    public init(
        maxGlobalAdmissions: Int = 2,
        initialCounter: UInt64 = 0
    ) throws {
        guard maxGlobalAdmissions >= 1 && maxGlobalAdmissions <= Self.maxAllowedGlobalAdmissions else {
            throw DiagnosticAdmissionError.invalidMaxGlobalAdmissions(maxGlobalAdmissions)
        }
        self.maxGlobalAdmissions = maxGlobalAdmissions
        self.tokenCounter = initialCounter
    }

    public convenience init() {
        try! self.init(maxGlobalAdmissions: Self.maxAllowedGlobalAdmissions, initialCounter: 0)
    }

    /// Reserves an admission slot for a bottle before process setup begins.
    ///
    /// - Parameters:
    ///   - bottleID: The validated canonical bottle identifier.
    ///   - externalSessionID: Optional external caller tracking ID.
    /// - Returns: A uniquely minted `DiagnosticAdmissionToken`.
    /// - Throws: `DiagnosticAdmissionError` if limits are exceeded, app is terminating, or token counter exhausts.
    public func reserve(
        bottleID: BottleID,
        externalSessionID: UUID? = nil
    ) throws -> DiagnosticAdmissionToken {
        if isTerminating {
            throw DiagnosticAdmissionError.appTerminating
        }
        if activeBottles[bottleID] != nil {
            throw DiagnosticAdmissionError.perBottleLimitReached(bottleID)
        }
        if activeTokens.count >= maxGlobalAdmissions {
            throw DiagnosticAdmissionError.globalLimitReached(maxGlobalAdmissions)
        }
        if let externalID = externalSessionID, activeExternalIDs[externalID] != nil {
            throw DiagnosticAdmissionError.duplicateExternalSessionID(externalID)
        }

        // Monotonic checked token counter without wrapping
        guard tokenCounter < UInt64.max else {
            throw DiagnosticAdmissionError.tokenGeneratorExhausted
        }
        tokenCounter += 1
        let nextID = tokenCounter

        let token = DiagnosticAdmissionToken(id: nextID, bottleID: bottleID)
        activeTokens[token] = bottleID
        activeBottles[bottleID] = token
        if let externalID = externalSessionID {
            activeExternalIDs[externalID] = token
        }

        return token
    }

    /// Releases an admitted reservation upon acknowledged resource teardown or setup failure.
    ///
    /// - Parameter token: The exact token minted by `reserve`.
    /// - Returns: `true` if the token was recognized and released; `false` if unknown or already released.
    @discardableResult
    public func release(token: DiagnosticAdmissionToken) -> Bool {
        guard let bottleID = activeTokens[token] else {
            return false
        }

        activeTokens.removeValue(forKey: token)
        activeBottles.removeValue(forKey: bottleID)

        // Remove from external tracking
        for (extID, mappedToken) in activeExternalIDs where mappedToken == token {
            activeExternalIDs.removeValue(forKey: extID)
        }

        // Drain from quit cohort if terminating
        if quitCohort != nil {
            quitCohort?.remove(token)
        }

        return true
    }

    /// Atomically closes admissions and snapshots all active and reserved tokens into a quit cohort.
    ///
    /// Repeated calls do not reopen admissions or reset the existing cohort.
    ///
    /// - Returns: Snapshot of admitted tokens that must finalize before app termination completes.
    public func beginQuit() -> Set<DiagnosticAdmissionToken> {
        isTerminating = true
        if quitCohort == nil {
            quitCohort = Set(activeTokens.keys)
        }
        return quitCohort ?? []
    }

    /// Returns `true` if quit has begun and all tokens in the quit cohort have released.
    public var isQuitCohortDrained: Bool {
        isTerminating && (quitCohort?.isEmpty ?? true)
    }

    /// Number of currently active or reserved capture sessions.
    public var activeCount: Int {
        activeTokens.count
    }

    /// Returns whether the admission barrier has closed.
    public var isAdmissionsClosed: Bool {
        isTerminating
    }

    /// Checks if a specific bottle has an active reservation.
    public func isBottleActive(_ bottleID: BottleID) -> Bool {
        activeBottles[bottleID] != nil
    }
}

// MARK: - 2. Monotonic Time & Capture State Machine

/// Monotonic instant for deterministic, virtual time progression.
public struct MonotonicInstant: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public var description: String {
        "\(nanoseconds)ns"
    }

    /// Adds seconds to the instant, safely returning nil on negative, NaN, infinity,
    /// conversion overflow, or UInt64 arithmetic overflow.
    public func adding(seconds: Double) -> MonotonicInstant? {
        guard seconds >= 0, seconds.isFinite, !seconds.isNaN else { return nil }
        let deltaNsDouble = seconds * 1_000_000_000.0
        // In Double, 2^64 is 18446744073709551616.0. Any Double >= 2^64 traps when converted to UInt64.
        guard deltaNsDouble.isFinite, deltaNsDouble < 18446744073709551616.0 else { return nil }
        let deltaNs = UInt64(deltaNsDouble)
        let (res, overflow) = nanoseconds.addingReportingOverflow(deltaNs)
        guard !overflow else { return nil }
        return MonotonicInstant(nanoseconds: res)
    }
}

/// Identifies the output stream.
public enum DiagnosticStreamKind: String, Codable, Sendable, CaseIterable {
    case stdout
    case stderr
}

/// Terminal outcome of reading from a stream.
public enum DiagnosticStreamReadOutcome: Equatable, Sendable {
    case none
    case cleanEOF
    case readError(errorCode: Int32)

    public var isEnded: Bool {
        switch self {
        case .none:
            return false
        case .cleanEOF, .readError:
            return true
        }
    }
}

/// Lifecycle state of the stream's file descriptor / reader.
public enum DiagnosticStreamClosureStatus: Equatable, Sendable {
    case notStarted
    case open
    case closeRequested
    case closeAcknowledged

    public var isClosed: Bool {
        self == .closeAcknowledged
    }
}

/// Combined status view of an individual capture stream.
public enum DiagnosticStreamStatus: Equatable, Sendable {
    case notStarted
    case open
    case cleanEOF
    case readError(errorCode: Int32)
    case closeRequested
    case closeAcknowledged

    public var isEnded: Bool {
        switch self {
        case .cleanEOF, .readError, .closeRequested, .closeAcknowledged:
            return true
        case .notStarted, .open:
            return false
        }
    }
}

/// Trigger causing teardown grace to commence.
public enum DiagnosticGraceTrigger: String, Codable, Sendable, Equatable {
    case appQuitRequest
    case explicitCaptureDeadlineReached
}

/// Reason explaining why a capture session finalized incompletely.
public enum DiagnosticIncompleteReason: Hashable, Sendable, Codable {
    case graceExpiredWithOpenWriters
    case streamReadError(stream: DiagnosticStreamKind, code: Int32)
    case spawnFailure(String)
}

/// Terminal outcome of finalization.
public enum DiagnosticFinalizationOutcome: Hashable, Sendable, Codable {
    case clean
    case incomplete(reasons: Set<DiagnosticIncompleteReason>)
}

/// Launcher process status.
public enum DiagnosticLauncherStatus: Equatable, Sendable {
    case running
    case exited(status: Int32, at: MonotonicInstant)
}

/// Grace period state.
public enum DiagnosticGraceStatus: Equatable, Sendable {
    case notStarted
    case running(trigger: DiagnosticGraceTrigger, startedAt: MonotonicInstant, expiry: MonotonicInstant)
    case expired(trigger: DiagnosticGraceTrigger, startedAt: MonotonicInstant, expiry: MonotonicInstant)
    case cancelledEarly(trigger: DiagnosticGraceTrigger, startedAt: MonotonicInstant, expiry: MonotonicInstant)
}

/// Finalization phase state.
public enum DiagnosticFinalizationStatus: Equatable, Sendable {
    case none
    case requested(outcome: DiagnosticFinalizationOutcome)
    case sealed(outcome: DiagnosticFinalizationOutcome)
    case failed(outcome: DiagnosticFinalizationOutcome, errorDescription: String)
}

/// Side-effect intents returned by the pure reducer.
public enum DiagnosticCaptureEffect: Equatable, Sendable {
    /// Request scheduling a timer at the specified monotonic instant.
    case requestTimer(expiry: MonotonicInstant)
    /// Request cancelling any existing scheduled timer.
    case cancelTimer
    /// Request closing the specified stream read descriptor.
    case requestReaderClose(stream: DiagnosticStreamKind)
    /// Request sealing finalization with the specified outcome.
    case requestFinalization(outcome: DiagnosticFinalizationOutcome)
    /// Discard payload arriving at or after grace expiry, or for an inactive/closed stream.
    case discardPayload(stream: DiagnosticStreamKind, byteCount: Int)
}

/// Events processed by the capture state reducer.
public enum DiagnosticCaptureEvent: Equatable, Sendable {
    case spawnSucceeded(at: MonotonicInstant)
    case spawnFailed(errorDescription: String, at: MonotonicInstant)

    case dataChunk(stream: DiagnosticStreamKind, byteCount: Int, at: MonotonicInstant)
    case cleanEOF(stream: DiagnosticStreamKind, at: MonotonicInstant)
    case readError(stream: DiagnosticStreamKind, errorCode: Int32, at: MonotonicInstant)

    case appQuitRequest(at: MonotonicInstant)
    case explicitCaptureDeadlineReached(at: MonotonicInstant)
    case graceDeadlineFired(at: MonotonicInstant)

    case launcherExited(status: Int32, at: MonotonicInstant)
    case readerCloseAcknowledged(stream: DiagnosticStreamKind, at: MonotonicInstant)
    case finalizationAcknowledged(at: MonotonicInstant)
    case finalizationFailed(errorDescription: String, at: MonotonicInstant)

    case observerCancelled(at: MonotonicInstant)
    case sinkFailure(errorDescription: String, at: MonotonicInstant)
    case sinkWriteDropped(stream: DiagnosticStreamKind, droppedBytes: Int, at: MonotonicInstant)
    case queueOverflow(stream: DiagnosticStreamKind, droppedBytes: Int, at: MonotonicInstant)
    case retentionDiscard(droppedBytes: Int, at: MonotonicInstant)
}

/// Pure state of an active diagnostic capture session.
public struct DiagnosticCaptureState: Equatable, Sendable {
    public var isSpawned: Bool
    public var streamReadOutcomes: [DiagnosticStreamKind: DiagnosticStreamReadOutcome]
    public var streamClosureStatuses: [DiagnosticStreamKind: DiagnosticStreamClosureStatus]
    public var launcherStatus: DiagnosticLauncherStatus
    public var graceStatus: DiagnosticGraceStatus
    public var finalizationStatus: DiagnosticFinalizationStatus

    public var bytesRead: [DiagnosticStreamKind: UInt64]
    public var queueDroppedBytes: UInt64
    public var sinkDroppedBytes: UInt64
    public var retentionDroppedBytes: UInt64
    public var unknownUnreadTail: Bool
    public var sinkDegraded: Bool
    public var hasCounterOverflow: Bool

    public var lastEventTime: MonotonicInstant?

    public var isFinalizationSealed: Bool {
        switch finalizationStatus {
        case .sealed, .failed:
            return true
        case .none, .requested:
            return false
        }
    }

    /// Pure resource readiness predicate:
    /// Returns true only when finalization outcome is in a terminal state (.sealed or .failed)
    /// AND all stream descriptors are confirmed closed (or never started).
    public var isResourceTeardownComplete: Bool {
        switch finalizationStatus {
        case .sealed, .failed:
            break
        case .none, .requested:
            return false
        }
        for (_, status) in streamClosureStatuses {
            if status != .notStarted && status != .closeAcknowledged {
                return false
            }
        }
        return true
    }

    /// Combined status property for convenience and backward compatibility.
    public var streamStatuses: [DiagnosticStreamKind: DiagnosticStreamStatus] {
        get {
            var result: [DiagnosticStreamKind: DiagnosticStreamStatus] = [:]
            for stream in DiagnosticStreamKind.allCases {
                let closure = streamClosureStatuses[stream] ?? .notStarted
                let outcome = streamReadOutcomes[stream] ?? .none
                switch (closure, outcome) {
                case (.notStarted, _):
                    result[stream] = .notStarted
                case (.closeAcknowledged, _):
                    result[stream] = .closeAcknowledged
                case (.closeRequested, _):
                    result[stream] = .closeRequested
                case (.open, .cleanEOF):
                    result[stream] = .cleanEOF
                case (.open, .readError(let code)):
                    result[stream] = .readError(errorCode: code)
                case (.open, .none):
                    result[stream] = .open
                }
            }
            return result
        }
        set {
            for (stream, status) in newValue {
                switch status {
                case .notStarted:
                    streamClosureStatuses[stream] = .notStarted
                    streamReadOutcomes[stream] = .none
                case .open:
                    streamClosureStatuses[stream] = .open
                    streamReadOutcomes[stream] = .none
                case .cleanEOF:
                    streamClosureStatuses[stream] = .open
                    streamReadOutcomes[stream] = .cleanEOF
                case .readError(let code):
                    streamClosureStatuses[stream] = .open
                    streamReadOutcomes[stream] = .readError(errorCode: code)
                case .closeRequested:
                    streamClosureStatuses[stream] = .closeRequested
                case .closeAcknowledged:
                    streamClosureStatuses[stream] = .closeAcknowledged
                }
            }
        }
    }

    public init(
        isSpawned: Bool = false,
        streamStatuses: [DiagnosticStreamKind: DiagnosticStreamStatus] = [
            .stdout: .notStarted,
            .stderr: .notStarted
        ],
        launcherStatus: DiagnosticLauncherStatus = .running,
        graceStatus: DiagnosticGraceStatus = .notStarted,
        finalizationStatus: DiagnosticFinalizationStatus = .none,
        bytesRead: [DiagnosticStreamKind: UInt64] = [.stdout: 0, .stderr: 0],
        queueDroppedBytes: UInt64 = 0,
        sinkDroppedBytes: UInt64 = 0,
        retentionDroppedBytes: UInt64 = 0,
        unknownUnreadTail: Bool = false,
        sinkDegraded: Bool = false,
        hasCounterOverflow: Bool = false,
        lastEventTime: MonotonicInstant? = nil
    ) {
        self.isSpawned = isSpawned
        self.launcherStatus = launcherStatus
        self.graceStatus = graceStatus
        self.finalizationStatus = finalizationStatus
        self.bytesRead = bytesRead
        self.queueDroppedBytes = queueDroppedBytes
        self.sinkDroppedBytes = sinkDroppedBytes
        self.retentionDroppedBytes = retentionDroppedBytes
        self.unknownUnreadTail = unknownUnreadTail
        self.sinkDegraded = sinkDegraded
        self.hasCounterOverflow = hasCounterOverflow
        self.lastEventTime = lastEventTime

        self.streamReadOutcomes = [.stdout: .none, .stderr: .none]
        self.streamClosureStatuses = [.stdout: .notStarted, .stderr: .notStarted]
        self.streamStatuses = streamStatuses
    }
}

/// Pure deterministic reducer governing capture lifecycle, grace timing, and stream state.
public enum DiagnosticCaptureReducer {
    private static func saturatingAdd(_ a: UInt64, _ b: UInt64, overflowFlag: inout Bool) -> UInt64 {
        let (res, overflow) = a.addingReportingOverflow(b)
        if overflow {
            overflowFlag = true
            return UInt64.max
        }
        return res
    }

    /// Pure state transition function.
    public static func reduce(
        state: DiagnosticCaptureState,
        event: DiagnosticCaptureEvent
    ) -> (DiagnosticCaptureState, [DiagnosticCaptureEffect]) {
        var state = state
        var effects: [DiagnosticCaptureEffect] = []

        // Extract event timestamp
        let eventTime: MonotonicInstant
        switch event {
        case let .spawnSucceeded(at),
             let .spawnFailed(_, at),
             let .dataChunk(_, _, at),
             let .cleanEOF(_, at),
             let .readError(_, _, at),
             let .appQuitRequest(at),
             let .explicitCaptureDeadlineReached(at),
             let .graceDeadlineFired(at),
             let .launcherExited(_, at),
             let .readerCloseAcknowledged(_, at),
             let .finalizationAcknowledged(at),
             let .finalizationFailed(_, at),
             let .observerCancelled(at),
             let .sinkFailure(_, at),
             let .sinkWriteDropped(_, _, at),
             let .queueOverflow(_, _, at),
             let .retentionDiscard(_, at):
            eventTime = at
        }

        // 1. Validate monotonic ordering: reject backwards time immediately without effects
        if let lastTime = state.lastEventTime, eventTime < lastTime {
            return (state, effects)
        }

        // 2. Validate signed input arguments: rejected inputs return unchanged state and empty effects immediately
        switch event {
        case let .dataChunk(_, byteCount, _):
            guard byteCount > 0 else { return (state, effects) }
        case let .queueOverflow(_, droppedBytes, _):
            guard droppedBytes > 0 else { return (state, effects) }
        case let .retentionDiscard(droppedBytes, _):
            guard droppedBytes > 0 else { return (state, effects) }
        case let .sinkWriteDropped(_, droppedBytes, _):
            guard droppedBytes > 0 else { return (state, effects) }
        default:
            break
        }

        // 3. Advance capture event time watermark for valid event
        state.lastEventTime = eventTime

        // 4. Centralized due-expiry transition:
        // Eligible ONLY if capture is active and has not begun finalization!
        if case let .running(trigger, startedAt, expiry) = state.graceStatus,
           state.finalizationStatus == .none,
           eventTime > expiry {
            expireDueGrace(expiry: expiry, trigger: trigger, startedAt: startedAt, state: &state, effects: &effects)
        }

        switch event {
        case .spawnSucceeded:
            guard !state.isSpawned && state.finalizationStatus == .none && state.graceStatus == .notStarted else {
                return (state, effects)
            }
            state.isSpawned = true
            state.streamClosureStatuses[.stdout] = .open
            state.streamClosureStatuses[.stderr] = .open
            state.streamReadOutcomes[.stdout] = .none
            state.streamReadOutcomes[.stderr] = .none

        case let .spawnFailed(errorDesc, _):
            guard !state.isSpawned && state.finalizationStatus == .none else {
                return (state, effects)
            }
            if case let .running(trigger, startedAt, expiry) = state.graceStatus {
                effects.append(.cancelTimer)
                state.graceStatus = .cancelledEarly(trigger: trigger, startedAt: startedAt, expiry: expiry)
            }
            let outcome = DiagnosticFinalizationOutcome.incomplete(reasons: [.spawnFailure(errorDesc)])
            state.finalizationStatus = .requested(outcome: outcome)
            effects.append(.requestFinalization(outcome: outcome))

        case let .dataChunk(stream, byteCount, _):
            // Accept chunk ONLY IF spawned, capture not finalizing/sealed, closure is open, and readOutcome is none
            let closure = state.streamClosureStatuses[stream] ?? .notStarted
            let outcome = state.streamReadOutcomes[stream] ?? .none
            guard state.isSpawned && state.finalizationStatus == .none && closure == .open && outcome == .none else {
                effects.append(.discardPayload(stream: stream, byteCount: byteCount))
                return (state, effects)
            }

            // In-flight chunk is accepted
            let current = state.bytesRead[stream] ?? 0
            state.bytesRead[stream] = saturatingAdd(current, UInt64(byteCount), overflowFlag: &state.hasCounterOverflow)

        case let .cleanEOF(stream, _):
            guard state.isSpawned && state.finalizationStatus == .none else {
                return (state, effects)
            }
            let closure = state.streamClosureStatuses[stream] ?? .notStarted
            let outcome = state.streamReadOutcomes[stream] ?? .none
            guard closure == .open && outcome == .none else {
                return (state, effects)
            }
            state.streamReadOutcomes[stream] = .cleanEOF
            state.streamClosureStatuses[stream] = .closeRequested
            effects.append(.requestReaderClose(stream: stream))
            checkStreamCompletion(state: &state, effects: &effects)

        case let .readError(stream, errorCode, _):
            guard state.isSpawned && state.finalizationStatus == .none else {
                return (state, effects)
            }
            let closure = state.streamClosureStatuses[stream] ?? .notStarted
            let outcome = state.streamReadOutcomes[stream] ?? .none
            guard closure == .open && outcome == .none else {
                return (state, effects)
            }
            state.streamReadOutcomes[stream] = .readError(errorCode: errorCode)
            state.streamClosureStatuses[stream] = .closeRequested
            effects.append(.requestReaderClose(stream: stream))
            checkStreamCompletion(state: &state, effects: &effects)

        case let .appQuitRequest(at):
            handleFirstTrigger(trigger: .appQuitRequest, at: at, state: &state, effects: &effects)

        case let .explicitCaptureDeadlineReached(at):
            handleFirstTrigger(trigger: .explicitCaptureDeadlineReached, at: at, state: &state, effects: &effects)

        case let .graceDeadlineFired(at):
            guard state.finalizationStatus == .none else { return (state, effects) }
            guard case let .running(trigger, startedAt, expiry) = state.graceStatus else {
                return (state, effects)
            }
            // Guard: early timer event at at < expiry is ignored
            guard at >= expiry else {
                return (state, effects)
            }
            expireDueGrace(expiry: expiry, trigger: trigger, startedAt: startedAt, state: &state, effects: &effects)

        case let .launcherExited(status, at):
            // Launcher observation is recorded independently; does not start grace or mutate finalization outcome
            state.launcherStatus = .exited(status: status, at: at)

        case let .readerCloseAcknowledged(stream, _):
            // Only accept close acknowledgement if close was requested!
            let currentClosure = state.streamClosureStatuses[stream] ?? .notStarted
            guard currentClosure == .closeRequested else {
                return (state, effects)
            }
            state.streamClosureStatuses[stream] = .closeAcknowledged

        case .finalizationAcknowledged:
            if case let .requested(outcome) = state.finalizationStatus {
                state.finalizationStatus = .sealed(outcome: outcome)
            }

        case let .finalizationFailed(errorDesc, _):
            if case let .requested(outcome) = state.finalizationStatus {
                state.finalizationStatus = .failed(outcome: outcome, errorDescription: errorDesc)
            }

        case .observerCancelled:
            // Observer cancellation affects only observation; capture continues running
            break

        case .sinkFailure:
            guard !state.isFinalizationSealed else { return (state, effects) }
            state.sinkDegraded = true

        case let .sinkWriteDropped(_, droppedBytes, _):
            guard !state.isFinalizationSealed else { return (state, effects) }
            state.sinkDroppedBytes = saturatingAdd(state.sinkDroppedBytes, UInt64(droppedBytes), overflowFlag: &state.hasCounterOverflow)

        case let .queueOverflow(_, droppedBytes, _):
            guard !state.isFinalizationSealed else { return (state, effects) }
            state.queueDroppedBytes = saturatingAdd(state.queueDroppedBytes, UInt64(droppedBytes), overflowFlag: &state.hasCounterOverflow)

        case let .retentionDiscard(droppedBytes, _):
            guard !state.isFinalizationSealed else { return (state, effects) }
            state.retentionDroppedBytes = saturatingAdd(state.retentionDroppedBytes, UInt64(droppedBytes), overflowFlag: &state.hasCounterOverflow)
        }

        return (state, effects)
    }

    // MARK: - Helpers

    private static func expireDueGrace(
        expiry: MonotonicInstant,
        trigger: DiagnosticGraceTrigger,
        startedAt: MonotonicInstant,
        state: inout DiagnosticCaptureState,
        effects: inout [DiagnosticCaptureEffect]
    ) {
        guard state.finalizationStatus == .none else { return }
        guard case .running = state.graceStatus else { return }
        state.graceStatus = .expired(trigger: trigger, startedAt: startedAt, expiry: expiry)

        var reasons: Set<DiagnosticIncompleteReason> = []
        var hasOpenStream = false

        for stream in DiagnosticStreamKind.allCases {
            let outcome = state.streamReadOutcomes[stream] ?? .none
            let closure = state.streamClosureStatuses[stream] ?? .notStarted
            if closure == .open {
                hasOpenStream = true
                state.streamClosureStatuses[stream] = .closeRequested
                effects.append(.requestReaderClose(stream: stream))
            } else if case let .readError(code) = outcome {
                reasons.insert(.streamReadError(stream: stream, code: code))
            }
        }

        if hasOpenStream {
            state.unknownUnreadTail = true
            reasons.insert(.graceExpiredWithOpenWriters)
        }

        let outcome: DiagnosticFinalizationOutcome = reasons.isEmpty ? .clean : .incomplete(reasons: reasons)
        state.finalizationStatus = .requested(outcome: outcome)
        effects.append(.requestFinalization(outcome: outcome))
    }

    private static func handleFirstTrigger(
        trigger: DiagnosticGraceTrigger,
        at: MonotonicInstant,
        state: inout DiagnosticCaptureState,
        effects: inout [DiagnosticCaptureEffect]
    ) {
        guard state.finalizationStatus == .none else { return }
        guard state.graceStatus == .notStarted else { return }

        guard let expiry = at.adding(seconds: 30.0) else { return }
        state.graceStatus = .running(trigger: trigger, startedAt: at, expiry: expiry)
        effects.append(.requestTimer(expiry: expiry))
    }

    private static func checkStreamCompletion(
        state: inout DiagnosticCaptureState,
        effects: inout [DiagnosticCaptureEffect]
    ) {
        guard state.finalizationStatus == .none else { return }

        let stdoutEnded = state.streamReadOutcomes[.stdout]?.isEnded ?? false
        let stderrEnded = state.streamReadOutcomes[.stderr]?.isEnded ?? false

        // Both streams must be ended before finalization is requested
        guard stdoutEnded && stderrEnded else { return }

        // Both streams are ended: cancel running timer if armed
        if case let .running(trigger, startedAt, expiry) = state.graceStatus {
            effects.append(.cancelTimer)
            state.graceStatus = .cancelledEarly(trigger: trigger, startedAt: startedAt, expiry: expiry)
        }

        var reasons: Set<DiagnosticIncompleteReason> = []
        if case let .readError(code) = state.streamReadOutcomes[.stdout] {
            reasons.insert(.streamReadError(stream: .stdout, code: code))
        }
        if case let .readError(code) = state.streamReadOutcomes[.stderr] {
            reasons.insert(.streamReadError(stream: .stderr, code: code))
        }

        let outcome: DiagnosticFinalizationOutcome = reasons.isEmpty ? .clean : .incomplete(reasons: reasons)
        state.finalizationStatus = .requested(outcome: outcome)
        effects.append(.requestFinalization(outcome: outcome))
    }
}

public extension DiagnosticCaptureState {
    var graceTrigger: DiagnosticGraceTrigger? {
        switch graceStatus {
        case let .running(trigger, _, _),
             let .expired(trigger, _, _),
             let .cancelledEarly(trigger, _, _):
            trigger
        case .notStarted:
            nil
        }
    }

    var graceStartedAt: MonotonicInstant? {
        switch graceStatus {
        case let .running(_, startedAt, _),
             let .expired(_, startedAt, _),
             let .cancelledEarly(_, startedAt, _):
            startedAt
        case .notStarted:
            nil
        }
    }
}

// MARK: - 3. Metadata Value Types

/// Captured launcher state for metadata serialization.
public struct DiagnosticLauncherRecord: Codable, Sendable, Equatable {
    public var command: [String]
    public var spawnSuccess: Bool
    public var spawnError: String?
    public var parentExitObserved: Bool
    public var parentExitCode: Int32?
    public var parentExitedAtNanoseconds: UInt64?

    public init(
        command: [String],
        spawnSuccess: Bool = true,
        spawnError: String? = nil,
        parentExitObserved: Bool = false,
        parentExitCode: Int32? = nil,
        parentExitedAtNanoseconds: UInt64? = nil
    ) {
        self.command = command
        self.spawnSuccess = spawnSuccess
        self.spawnError = spawnError
        self.parentExitObserved = parentExitObserved
        self.parentExitCode = parentExitCode
        self.parentExitedAtNanoseconds = parentExitedAtNanoseconds
    }
}

/// Captured stream status for metadata serialization.
public struct DiagnosticStreamRecord: Codable, Sendable, Equatable {
    public var state: String
    public var bytesReadFromPipe: UInt64
    public var cleanEOF: Bool
    public var readErrorCode: Int32?

    public init(
        state: String,
        bytesReadFromPipe: UInt64 = 0,
        cleanEOF: Bool = false,
        readErrorCode: Int32? = nil
    ) {
        self.state = state
        self.bytesReadFromPipe = bytesReadFromPipe
        self.cleanEOF = cleanEOF
        self.readErrorCode = readErrorCode
    }
}

/// Known byte counts and unknown unread tail status.
public struct DiagnosticAccountingRecord: Codable, Sendable, Equatable {
    public var retainedBytesOnDisk: UInt64?
    public var queueDroppedBytes: UInt64
    public var sinkDroppedBytes: UInt64
    public var retentionDroppedBytes: UInt64
    public var unknownUnreadTail: Bool
    public var hasCounterOverflow: Bool

    public init(
        retainedBytesOnDisk: UInt64? = nil,
        queueDroppedBytes: UInt64 = 0,
        sinkDroppedBytes: UInt64 = 0,
        retentionDroppedBytes: UInt64 = 0,
        unknownUnreadTail: Bool = false,
        hasCounterOverflow: Bool = false
    ) {
        self.retainedBytesOnDisk = retainedBytesOnDisk
        self.queueDroppedBytes = queueDroppedBytes
        self.sinkDroppedBytes = sinkDroppedBytes
        self.retentionDroppedBytes = retentionDroppedBytes
        self.unknownUnreadTail = unknownUnreadTail
        self.hasCounterOverflow = hasCounterOverflow
    }
}

/// Teardown grace status for metadata serialization.
public struct DiagnosticTeardownRecord: Codable, Sendable, Equatable {
    public var trigger: String
    public var graceWindowSeconds: Double
    public var graceStartedAtNanoseconds: UInt64?
    public var graceDeadlineNanoseconds: UInt64?
    public var graceExpired: Bool
    public var finalizationState: String

    public init(
        trigger: String = "none",
        graceWindowSeconds: Double = 30.0,
        graceStartedAtNanoseconds: UInt64? = nil,
        graceDeadlineNanoseconds: UInt64? = nil,
        graceExpired: Bool = false,
        finalizationState: String = "pending"
    ) {
        self.trigger = trigger
        self.graceWindowSeconds = graceWindowSeconds
        self.graceStartedAtNanoseconds = graceStartedAtNanoseconds
        self.graceDeadlineNanoseconds = graceDeadlineNanoseconds
        self.graceExpired = graceExpired
        self.finalizationState = finalizationState
    }
}

/// Top-level value type representing diagnostic session metadata.
public struct DiagnosticSessionMetadata: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var schemaID: String
    public var sessionId: UUID
    public var bottleID: String
    public var requestedPreset: String
    public var winedebugValue: String
    public var launcher: DiagnosticLauncherRecord
    public var stdoutStream: DiagnosticStreamRecord
    public var stderrStream: DiagnosticStreamRecord
    public var accounting: DiagnosticAccountingRecord
    public var teardown: DiagnosticTeardownRecord
    public var captureStatus: String
    public var captureStatusReason: String?
    public var attributionNotice: String

    public static let currentSchemaVersion = 2
    public static let currentSchemaID = "whisky.diagnostic-session.v2"
    public static let standardAttributionNotice = "Expected, not verified: Wine should pass client environment to games; game child environment/output inheritance is unverified."

    public init(
        schemaVersion: Int = currentSchemaVersion,
        schemaID: String = currentSchemaID,
        sessionId: UUID,
        bottleID: String,
        requestedPreset: String,
        winedebugValue: String,
        launcher: DiagnosticLauncherRecord,
        stdoutStream: DiagnosticStreamRecord,
        stderrStream: DiagnosticStreamRecord,
        accounting: DiagnosticAccountingRecord,
        teardown: DiagnosticTeardownRecord,
        captureStatus: String,
        captureStatusReason: String? = nil,
        attributionNotice: String = standardAttributionNotice
    ) {
        self.schemaVersion = schemaVersion
        self.schemaID = schemaID
        self.sessionId = sessionId
        self.bottleID = bottleID
        self.requestedPreset = requestedPreset
        self.winedebugValue = winedebugValue
        self.launcher = launcher
        self.stdoutStream = stdoutStream
        self.stderrStream = stderrStream
        self.accounting = accounting
        self.teardown = teardown
        self.captureStatus = captureStatus
        self.captureStatusReason = captureStatusReason
        self.attributionNotice = attributionNotice
    }

    /// Pure mapping function constructing session metadata from capture state and launcher configuration.
    public static func make(
        sessionID: UUID,
        bottleID: BottleID,
        requestedPreset: String,
        winedebugValue: String,
        launcherCommand: [String],
        state: DiagnosticCaptureState,
        retainedBytesOnDisk: UInt64? = nil
    ) -> DiagnosticSessionMetadata {
        let launcherRecord = DiagnosticLauncherRecord(
            command: launcherCommand,
            spawnSuccess: state.isSpawned,
            spawnError: {
                let outcome: DiagnosticFinalizationOutcome?
                switch state.finalizationStatus {
                case let .requested(o), let .sealed(o), let .failed(o, _):
                    outcome = o
                case .none:
                    outcome = nil
                }
                if let outcome = outcome, case let .incomplete(reasons) = outcome {
                    for reason in reasons {
                        if case let .spawnFailure(err) = reason { return err }
                    }
                }
                return nil
            }(),
            parentExitObserved: {
                if case .exited = state.launcherStatus { return true }
                return false
            }(),
            parentExitCode: {
                if case let .exited(code, _) = state.launcherStatus { return code }
                return nil
            }(),
            parentExitedAtNanoseconds: {
                if case let .exited(_, at) = state.launcherStatus { return at.nanoseconds }
                return nil
            }()
        )

        let stdoutRecord = DiagnosticStreamRecord(
            state: {
                switch state.streamClosureStatuses[.stdout] {
                case .notStarted: return "notStarted"
                case .open: return "open"
                case .closeRequested: return "closeRequested"
                case .closeAcknowledged: return "closeAcknowledged"
                case nil: return "unknown"
                }
            }(),
            bytesReadFromPipe: state.bytesRead[.stdout] ?? 0,
            cleanEOF: state.streamReadOutcomes[.stdout] == .cleanEOF,
            readErrorCode: {
                if case let .readError(code) = state.streamReadOutcomes[.stdout] { return code }
                return nil
            }()
        )

        let stderrRecord = DiagnosticStreamRecord(
            state: {
                switch state.streamClosureStatuses[.stderr] {
                case .notStarted: return "notStarted"
                case .open: return "open"
                case .closeRequested: return "closeRequested"
                case .closeAcknowledged: return "closeAcknowledged"
                case nil: return "unknown"
                }
            }(),
            bytesReadFromPipe: state.bytesRead[.stderr] ?? 0,
            cleanEOF: state.streamReadOutcomes[.stderr] == .cleanEOF,
            readErrorCode: {
                if case let .readError(code) = state.streamReadOutcomes[.stderr] { return code }
                return nil
            }()
        )

        let accountingRecord = DiagnosticAccountingRecord(
            retainedBytesOnDisk: retainedBytesOnDisk,
            queueDroppedBytes: state.queueDroppedBytes,
            sinkDroppedBytes: state.sinkDroppedBytes,
            retentionDroppedBytes: state.retentionDroppedBytes,
            unknownUnreadTail: state.unknownUnreadTail,
            hasCounterOverflow: state.hasCounterOverflow
        )

        let teardownRecord = DiagnosticTeardownRecord(
            trigger: state.graceTrigger?.rawValue ?? "none",
            graceWindowSeconds: 30.0,
            graceStartedAtNanoseconds: state.graceStartedAt?.nanoseconds,
            graceDeadlineNanoseconds: {
                if case let .running(_, _, expiry) = state.graceStatus { return expiry.nanoseconds }
                if case let .expired(_, _, expiry) = state.graceStatus { return expiry.nanoseconds }
                if case let .cancelledEarly(_, _, expiry) = state.graceStatus { return expiry.nanoseconds }
                return nil
            }(),
            graceExpired: {
                if case .expired = state.graceStatus { return true }
                return false
            }(),
            finalizationState: {
                switch state.finalizationStatus {
                case .none: return "none"
                case .requested: return "requested"
                case .sealed: return "sealed"
                case .failed: return "failed"
                }
            }()
        )

        let (captureStatus, captureReason): (String, String?) = {
            switch state.finalizationStatus {
            case .none:
                return ("active", nil)
            case let .requested(outcome), let .sealed(outcome):
                switch outcome {
                case .clean:
                    return ("clean", nil)
                case let .incomplete(reasons):
                    let reasonStrings = reasons.map { r -> String in
                        switch r {
                        case .graceExpiredWithOpenWriters: return "graceExpiredWithOpenWriters"
                        case let .streamReadError(s, c): return "streamReadError(\(s.rawValue), \(c))"
                        case let .spawnFailure(msg): return "spawnFailure(\(msg))"
                        }
                    }.sorted()
                    return ("incomplete", reasonStrings.joined(separator: ", "))
                }
            case let .failed(_, errorDesc):
                return ("failed", errorDesc)
            }
        }()

        return DiagnosticSessionMetadata(
            sessionId: sessionID,
            bottleID: bottleID.rawValue,
            requestedPreset: requestedPreset,
            winedebugValue: winedebugValue,
            launcher: launcherRecord,
            stdoutStream: stdoutRecord,
            stderrStream: stderrRecord,
            accounting: accountingRecord,
            teardown: teardownRecord,
            captureStatus: captureStatus,
            captureStatusReason: captureReason
        )
    }
}
