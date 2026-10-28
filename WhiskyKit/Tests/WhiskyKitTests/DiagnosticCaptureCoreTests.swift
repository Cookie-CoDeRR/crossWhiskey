//
//  DiagnosticCaptureCoreTests.swift
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

import Foundation
import Testing
@testable import WhiskyKit

@Suite("Diagnostic capture pure core: admission registry, grace reducer, and metadata")
struct DiagnosticCaptureCoreTests {

    // MARK: - 1. Admission Registry Tests

    @Test("Registry enforces 1 reservation per bottle and max 2 global admissions")
    func admissionLimitsPerBottleAndGlobal() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)

        let bottleA = BottleID("bottle-A")
        let bottleB = BottleID("bottle-B")
        let bottleC = BottleID("bottle-C")

        // First bottle admitted
        let tokenA = try registry.reserve(bottleID: bottleA)
        #expect(tokenA.bottleID == bottleA)
        #expect(registry.activeCount == 1)

        // Same bottle concurrently admitted is rejected
        #expect(throws: DiagnosticAdmissionError.perBottleLimitReached(bottleA)) {
            try registry.reserve(bottleID: bottleA)
        }

        // Second bottle admitted
        let tokenB = try registry.reserve(bottleID: bottleB)
        #expect(tokenB.bottleID == bottleB)
        #expect(registry.activeCount == 2)

        // Third bottle exceeds global limit of 2
        #expect(throws: DiagnosticAdmissionError.globalLimitReached(2)) {
            try registry.reserve(bottleID: bottleC)
        }

        // Release bottle A; bottle C can now be admitted
        let releasedA = registry.release(token: tokenA)
        #expect(releasedA == true)
        #expect(registry.activeCount == 1)

        let tokenC = try registry.reserve(bottleID: bottleC)
        #expect(tokenC.bottleID == bottleC)
        #expect(registry.activeCount == 2)
    }

    @Test("Canonical identity mapping treats aliases as the same bottle")
    func admissionCanonicalBottleAliases() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)

        // Injected canonical mapping table (pure test model)
        let aliasMap: [String: BottleID] = [
            "/Bottles/Bottle1": BottleID("canonical-bottle-1"),
            "/Bottles/Bottle1/": BottleID("canonical-bottle-1"),
            "/symlinks/Bottle1": BottleID("canonical-bottle-1")
        ]

        let canonicalID1 = aliasMap["/Bottles/Bottle1"]!
        let canonicalID2 = aliasMap["/symlinks/Bottle1"]!

        #expect(canonicalID1 == canonicalID2)

        let token = try registry.reserve(bottleID: canonicalID1)
        #expect(token.bottleID == BottleID("canonical-bottle-1"))

        // Attempting to reserve through an alias maps to same BottleID and is rejected
        #expect(throws: DiagnosticAdmissionError.perBottleLimitReached(canonicalID2)) {
            try registry.reserve(bottleID: canonicalID2)
        }
    }

    @Test("Registry mints unique deterministic tokens from monotonic counter")
    func admissionDeterministicUniqueTokens() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2, initialCounter: 100)

        let token1 = try registry.reserve(bottleID: BottleID("b1"))
        #expect(token1.id == 101)

        let token2 = try registry.reserve(bottleID: BottleID("b2"))
        #expect(token2.id == 102)
        #expect(token1 != token2)
    }

    @Test("Duplicate external session IDs are rejected and cannot inflate count")
    func admissionDuplicateExternalSessionIDs() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let extID = UUID()

        _ = try registry.reserve(bottleID: BottleID("b1"), externalSessionID: extID)

        #expect(throws: DiagnosticAdmissionError.duplicateExternalSessionID(extID)) {
            try registry.reserve(bottleID: BottleID("b2"), externalSessionID: extID)
        }
        #expect(registry.activeCount == 1)
    }

    @Test("Stale token release after readmission is rejected harmlessly and does not release new capture")
    func admissionStaleReleaseAfterReadmission() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let bottle = BottleID("b1")

        let token1 = try registry.reserve(bottleID: bottle)
        #expect(registry.release(token: token1) == true)
        #expect(registry.activeCount == 0)

        // Readmit same bottle with new token
        let token2 = try registry.reserve(bottleID: bottle)
        #expect(token2 != token1)
        #expect(registry.activeCount == 1)

        // Stale release with token1 must fail and NOT release token2
        let staleReleaseResult = registry.release(token: token1)
        #expect(staleReleaseResult == false)
        #expect(registry.activeCount == 1)
        #expect(registry.isBottleActive(bottle) == true)

        // Releasing token2 succeeds
        #expect(registry.release(token: token2) == true)
        #expect(registry.activeCount == 0)
    }

    @Test("Wrong token for a bottle cannot release another bottle's admission")
    func admissionWrongTokenRelease() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let tokenA = try registry.reserve(bottleID: BottleID("bottle-A"))
        let tokenB = try registry.reserve(bottleID: BottleID("bottle-B"))

        // Releasing bottle A using token B fails
        #expect(registry.release(token: DiagnosticAdmissionToken(id: tokenB.id, bottleID: BottleID("bottle-A"))) == false)
        #expect(registry.activeCount == 2)
        #expect(registry.isBottleActive(BottleID("bottle-A")) == true)
        #expect(registry.release(token: tokenA) == true)
        #expect(registry.release(token: tokenB) == true)
    }

    @Test("Repeated release of the same token is harmless and idempotent")
    func admissionRepeatedReleaseIdempotent() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let token = try registry.reserve(bottleID: BottleID("b1"))

        #expect(registry.release(token: token) == true)
        #expect(registry.release(token: token) == false)
        #expect(registry.release(token: token) == false)
    }

    @Test("beginQuit closes admissions and snapshots admitted tokens into a draining cohort")
    func admissionQuitBarrierAndCohort() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let token1 = try registry.reserve(bottleID: BottleID("b1"))
        let token2 = try registry.reserve(bottleID: BottleID("b2"))

        let cohort = registry.beginQuit()
        #expect(cohort.count == 2)
        #expect(cohort.contains(token1))
        #expect(cohort.contains(token2))
        #expect(registry.isAdmissionsClosed == true)
        #expect(registry.isQuitCohortDrained == false)

        // Admissions after quit barrier fail fast
        #expect(throws: DiagnosticAdmissionError.appTerminating) {
            try registry.reserve(bottleID: BottleID("b3"))
        }

        // Release token1
        registry.release(token: token1)
        #expect(registry.isQuitCohortDrained == false)

        // Release token2 -> cohort is drained
        registry.release(token: token2)
        #expect(registry.isQuitCohortDrained == true)
    }

    @Test("Setup failure during quit releases token and drains cohort properly")
    func admissionSetupFailureDuringQuit() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let midSetupToken = try registry.reserve(bottleID: BottleID("b1"))

        _ = registry.beginQuit()

        // Mid-setup failure triggers release during quit
        #expect(registry.release(token: midSetupToken) == true)
        #expect(registry.isQuitCohortDrained == true)
    }

    @Test("Repeated beginQuit calls are idempotent and do not reset cohort or lose tokens")
    func admissionRepeatedBeginQuit() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let token = try registry.reserve(bottleID: BottleID("b1"))

        let cohort1 = registry.beginQuit()
        let cohort2 = registry.beginQuit()

        #expect(cohort1 == cohort2)
        #expect(cohort1.contains(token))

        registry.release(token: token)
        #expect(registry.isQuitCohortDrained == true)
    }

    @Test("Registry rejects invalid maxGlobalAdmissions configuration")
    func admissionInvalidConfiguration() {
        #expect(throws: DiagnosticAdmissionError.invalidMaxGlobalAdmissions(0)) {
            _ = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 0)
        }
        #expect(throws: DiagnosticAdmissionError.invalidMaxGlobalAdmissions(3)) {
            _ = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 3)
        }
        #expect(throws: DiagnosticAdmissionError.invalidMaxGlobalAdmissions(-1)) {
            _ = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: -1)
        }
    }

    @Test("Registry checks token counter exhaustion and rejects without state corruption")
    func admissionTokenCounterExhaustion() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2, initialCounter: UInt64.max)
        #expect(throws: DiagnosticAdmissionError.tokenGeneratorExhausted) {
            try registry.reserve(bottleID: BottleID("b1"))
        }
        #expect(registry.activeCount == 0)
        #expect(registry.isBottleActive(BottleID("b1")) == false)
    }

    @Test("Repeated beginQuit after partial drain preserves remaining cohort")
    func admissionRepeatedBeginQuitAfterPartialDrain() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let t1 = try registry.reserve(bottleID: BottleID("b1"))
        let t2 = try registry.reserve(bottleID: BottleID("b2"))

        let cohort1 = registry.beginQuit()
        #expect(cohort1.count == 2)

        #expect(registry.release(token: t1) == true)
        #expect(registry.isQuitCohortDrained == false)

        let cohort2 = registry.beginQuit()
        #expect(cohort2 == [t2])
        #expect(cohort2.count == 1)
        #expect(cohort2.contains(t2))
        #expect(!cohort2.contains(t1))
        #expect(registry.isQuitCohortDrained == false)

        #expect(registry.release(token: t2) == true)
        #expect(registry.isQuitCohortDrained == true)

        let cohort3 = registry.beginQuit()
        #expect(cohort3.isEmpty)
        #expect(registry.isQuitCohortDrained == true)
    }

    // MARK: - 2. Capture & Grace Reducer Tests

    @Test("First trigger quitRequest at t=10s sets grace expiry to t=40s")
    func reducerFirstTriggerQuitArmsGrace() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (newState, effects) = DiagnosticCaptureReducer.reduce(
            state: state,
            event: .appQuitRequest(at: t10)
        )

        let expectedExpiry = MonotonicInstant(nanoseconds: 40_000_000_000)
        #expect(newState.graceStatus == .running(
            trigger: .appQuitRequest,
            startedAt: t10,
            expiry: expectedExpiry
        ))
        #expect(effects == [.requestTimer(expiry: expectedExpiry)])
    }

    @Test("First trigger explicitCaptureDeadlineReached at t=15s sets grace expiry to t=45s")
    func reducerFirstTriggerExplicitDeadlineArmsGrace() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t15 = MonotonicInstant(nanoseconds: 15_000_000_000)
        let (newState, effects) = DiagnosticCaptureReducer.reduce(
            state: state,
            event: .explicitCaptureDeadlineReached(at: t15)
        )

        let expectedExpiry = MonotonicInstant(nanoseconds: 45_000_000_000)
        #expect(newState.graceStatus == .running(
            trigger: .explicitCaptureDeadlineReached,
            startedAt: t15,
            expiry: expectedExpiry
        ))
        #expect(effects == [.requestTimer(expiry: expectedExpiry)])
    }

    @Test("First trigger rule: quit at t=10s sets expiry=40s; later explicit at 15s or 25s leaves 40s")
    func reducerFirstTriggerRuleEarlierWins() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t10))
        let expiry40 = MonotonicInstant(nanoseconds: 40_000_000_000)
        #expect(s1.graceStatus == .running(trigger: .appQuitRequest, startedAt: t10, expiry: expiry40))
        #expect(e1 == [.requestTimer(expiry: expiry40)])

        // Later explicit deadline at t=15s does not alter expiry=40s
        let t15 = MonotonicInstant(nanoseconds: 15_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .explicitCaptureDeadlineReached(at: t15))
        #expect(s2.graceStatus == .running(trigger: .appQuitRequest, startedAt: t10, expiry: expiry40))
        #expect(e2.isEmpty)

        // Later explicit deadline at t=25s also leaves expiry=40s
        let t25 = MonotonicInstant(nanoseconds: 25_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .explicitCaptureDeadlineReached(at: t25))
        #expect(s3.graceStatus == .running(trigger: .appQuitRequest, startedAt: t10, expiry: expiry40))
        #expect(e3.isEmpty)
    }

    @Test("Repeated quit triggers do not extend or reset expiry")
    func reducerRepeatedQuitTriggersNoop() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t10))

        let t20 = MonotonicInstant(nanoseconds: 20_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .appQuitRequest(at: t20))

        let expiry40 = MonotonicInstant(nanoseconds: 40_000_000_000)
        #expect(s2.graceStatus == .running(trigger: .appQuitRequest, startedAt: t10, expiry: expiry40))
        #expect(e2.isEmpty)
    }

    @Test("Non-trigger events do not start or shorten grace")
    func reducerNonTriggerEventsDoNotStartGrace() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .launcherExited(status: 0, at: t1))
        #expect(s1.graceStatus == .notStarted)
        #expect(e1.isEmpty)

        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .sinkFailure(errorDescription: "disk full", at: t2))
        #expect(s2.graceStatus == .notStarted)
        #expect(s2.sinkDegraded == true)
        #expect(e2.isEmpty)

        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .readError(stream: .stdout, errorCode: 32, at: t3))
        #expect(s3.graceStatus == .notStarted)
        #expect(e3 == [.requestReaderClose(stream: .stdout)])
    }

    @Test("Exact deadline tie boundary: chunk at t==expiry before expiry event is accepted; chunk after expiry event is rejected")
    func reducerExactTieBoundary() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t0 = MonotonicInstant(nanoseconds: 0)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0))
        let expiry30 = MonotonicInstant(nanoseconds: 30_000_000_000)

        // Case A: Chunk arrives at t==expiry BEFORE expiry event is processed
        let (s2a, e2a) = DiagnosticCaptureReducer.reduce(state: s1, event: .dataChunk(stream: .stdout, byteCount: 1024, at: expiry30))
        #expect(s2a.bytesRead[.stdout] == 1024)
        #expect(e2a.isEmpty)

        // Case B: Expiry event is processed at t==expiry
        let (s2b, e2b) = DiagnosticCaptureReducer.reduce(state: s1, event: .graceDeadlineFired(at: expiry30))
        #expect(s2b.graceStatus == .expired(trigger: .appQuitRequest, startedAt: t0, expiry: expiry30))
        #expect(e2b.contains(.requestFinalization(outcome: .incomplete(reasons: [.graceExpiredWithOpenWriters]))))

        // Subsequent chunk at t==expiry AFTER expiry event is rejected and discarded
        let (s3b, e3b) = DiagnosticCaptureReducer.reduce(state: s2b, event: .dataChunk(stream: .stdout, byteCount: 512, at: expiry30))
        #expect(s3b.bytesRead[.stdout] == 0)
        #expect(e3b == [.discardPayload(stream: .stdout, byteCount: 512)])
    }

    @Test("Late data payload arriving at t > expiry before delayed timer delivery triggers expiry and is discarded")
    func reducerLatePayloadArrivingAfterExpiry() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t0 = MonotonicInstant(nanoseconds: 0)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0)) // expiry is t=30s

        // Late chunk arrives at t=35s before graceDeadlineFired timer was delivered
        let t35 = MonotonicInstant(nanoseconds: 35_000_000_000)
        let (s2, effects2) = DiagnosticCaptureReducer.reduce(state: s1, event: .dataChunk(stream: .stderr, byteCount: 2048, at: t35))

        #expect(s2.bytesRead[.stderr] == 0)
        #expect(s2.unknownUnreadTail == true)
        #expect(effects2.contains(.discardPayload(stream: .stderr, byteCount: 2048)))
        #expect(effects2.contains(.requestReaderClose(stream: .stdout)))
        #expect(effects2.contains(.requestReaderClose(stream: .stderr)))
        #expect(effects2.contains(.requestFinalization(outcome: .incomplete(reasons: [.graceExpiredWithOpenWriters]))))
    }

    @Test("Time input safety: backward event time and overflow duration are safely rejected without wrapping")
    func reducerTimeInputSafety() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .dataChunk(stream: .stdout, byteCount: 100, at: t10))

        // Backward timestamp event is ignored
        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .dataChunk(stream: .stdout, byteCount: 50, at: t5))
        #expect(s2.bytesRead[.stdout] == 100)
        #expect(e2.isEmpty)

        // Overflow check on adding
        let nearMax = MonotonicInstant(nanoseconds: UInt64.max - 100)
        #expect(nearMax.adding(seconds: 30.0) == nil)
        #expect(t10.adding(seconds: -5.0) == nil)
        #expect(t10.adding(seconds: Double.nan) == nil)
        #expect(t10.adding(seconds: Double.infinity) == nil)
        #expect(t10.adding(seconds: Double.greatestFiniteMagnitude) == nil)
    }

    @Test("Both clean EOFs before any trigger request reader closure and clean finalization")
    func reducerBothCleanEOFsBeforeTrigger() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .cleanEOF(stream: .stdout, at: t1))
        #expect(s1.streamReadOutcomes[.stdout] == .cleanEOF)
        #expect(s1.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(s1.streamClosureStatuses[.stderr] == .open)
        #expect(e1 == [.requestReaderClose(stream: .stdout)])

        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .cleanEOF(stream: .stderr, at: t2))
        #expect(s2.streamReadOutcomes[.stderr] == .cleanEOF)
        #expect(s2.streamClosureStatuses[.stderr] == .closeRequested)
        #expect(e2.contains(.requestReaderClose(stream: .stderr)))
        #expect(e2.contains(.requestFinalization(outcome: .clean)))
    }

    @Test("Both clean EOFs before parent launcher exit requests clean finalization; parent wait completes independently")
    func reducerBothCleanEOFsBeforeLauncherExit() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .cleanEOF(stream: .stdout, at: t1))
        #expect(e1 == [.requestReaderClose(stream: .stdout)])

        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .cleanEOF(stream: .stderr, at: t1))
        #expect(e2.contains(.requestReaderClose(stream: .stderr)))
        #expect(e2.contains(.requestFinalization(outcome: .clean)))

        // Parent exits later at t=5s
        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .launcherExited(status: 0, at: t5))
        #expect(s3.launcherStatus == .exited(status: 0, at: t5))
        #expect(e3.isEmpty)
    }

    @Test("One stream read error + other clean EOF in both orders requests incomplete finalization once both end")
    func reducerOneErrorOneHealthyBothOrders() {
        // Order 1: stdout error at t=5s, stderr clean EOF at t=20s
        var state1 = DiagnosticCaptureState(isSpawned: true)
        state1.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (s1a, e1a) = DiagnosticCaptureReducer.reduce(state: state1, event: .readError(stream: .stdout, errorCode: 5, at: t5))
        #expect(s1a.streamReadOutcomes[.stdout] == .readError(errorCode: 5))
        #expect(s1a.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(s1a.streamClosureStatuses[.stderr] == .open)
        #expect(e1a == [.requestReaderClose(stream: .stdout)])

        let t20 = MonotonicInstant(nanoseconds: 20_000_000_000)
        let (_, e1b) = DiagnosticCaptureReducer.reduce(state: s1a, event: .cleanEOF(stream: .stderr, at: t20))
        #expect(e1b.contains(.requestReaderClose(stream: .stderr)))
        #expect(e1b.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stdout, code: 5)]))))

        // Order 2: stderr error at t=5s, stdout clean EOF at t=20s
        var state2 = DiagnosticCaptureState(isSpawned: true)
        state2.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let (s2a, e2a) = DiagnosticCaptureReducer.reduce(state: state2, event: .readError(stream: .stderr, errorCode: 9, at: t5))
        #expect(s2a.streamReadOutcomes[.stderr] == .readError(errorCode: 9))
        #expect(s2a.streamClosureStatuses[.stderr] == .closeRequested)
        #expect(s2a.streamClosureStatuses[.stdout] == .open)
        #expect(e2a == [.requestReaderClose(stream: .stderr)])

        let (_, e2b) = DiagnosticCaptureReducer.reduce(state: s2a, event: .cleanEOF(stream: .stdout, at: t20))
        #expect(e2b.contains(.requestReaderClose(stream: .stdout)))
        #expect(e2b.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stderr, code: 9)]))))
    }

    @Test("Mixed error + EOF during grace in both temporal orders finalize incomplete immediately")
    func reducerMixedErrorAndEOFDuringGraceBothTemporalOrders() {
        // Temporal Order 1: Clean EOF on stdout at 15s, then readError on stderr at 20s
        var state1 = DiagnosticCaptureState(isSpawned: true)
        state1.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state1, event: .appQuitRequest(at: t10))

        let t15 = MonotonicInstant(nanoseconds: 15_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .cleanEOF(stream: .stdout, at: t15))
        #expect(e2 == [.requestReaderClose(stream: .stdout)])

        let t20 = MonotonicInstant(nanoseconds: 20_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .readError(stream: .stderr, errorCode: 5, at: t20))

        #expect(e3.contains(.cancelTimer))
        #expect(e3.contains(.requestReaderClose(stream: .stderr)))
        #expect(e3.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stderr, code: 5)]))))
        #expect(s3.graceStatus == .cancelledEarly(
            trigger: .appQuitRequest,
            startedAt: t10,
            expiry: MonotonicInstant(nanoseconds: 40_000_000_000)
        ))

        // Temporal Order 2: Read error on stdout at 15s, then clean EOF on stderr at 20s
        var state2 = DiagnosticCaptureState(isSpawned: true)
        state2.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let (sa, _) = DiagnosticCaptureReducer.reduce(state: state2, event: .appQuitRequest(at: t10))
        let (sb, eb) = DiagnosticCaptureReducer.reduce(state: sa, event: .readError(stream: .stdout, errorCode: 9, at: t15))
        #expect(eb == [.requestReaderClose(stream: .stdout)])

        let (sc, ec) = DiagnosticCaptureReducer.reduce(state: sb, event: .cleanEOF(stream: .stderr, at: t20))
        #expect(ec.contains(.cancelTimer))
        #expect(ec.contains(.requestReaderClose(stream: .stderr)))
        #expect(ec.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stdout, code: 9)]))))
        #expect(sc.graceStatus == .cancelledEarly(
            trigger: .appQuitRequest,
            startedAt: t10,
            expiry: MonotonicInstant(nanoseconds: 40_000_000_000)
        ))
    }

    @Test("Two stream errors during grace finalize incomplete immediately without waiting for timer expiry")
    func reducerTwoErrorsDuringGraceFinalizeImmediately() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t0 = MonotonicInstant(nanoseconds: 0)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0))
        let expiry = MonotonicInstant(nanoseconds: 30_000_000_000)
        #expect(e1 == [.requestTimer(expiry: expiry)])

        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .readError(stream: .stdout, errorCode: 5, at: t5))
        #expect(e2 == [.requestReaderClose(stream: .stdout)])

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (_, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .readError(stream: .stderr, errorCode: 6, at: t10))

        #expect(e3.contains(.cancelTimer))
        #expect(e3.contains(.requestReaderClose(stream: .stderr)))
        let expectedReasons: Set<DiagnosticIncompleteReason> = [
            .streamReadError(stream: .stdout, code: 5),
            .streamReadError(stream: .stderr, code: 6)
        ]
        #expect(e3.contains(.requestFinalization(outcome: .incomplete(reasons: expectedReasons))))
    }

    @Test("Grace expiry emits close intents for ONLY remaining open readers")
    func reducerGraceExpiryEmitsCloseForOnlyRemainingReaders() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t0 = MonotonicInstant(nanoseconds: 0)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0))

        // stdout ends cleanly at t=10s and emits close request
        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .cleanEOF(stream: .stdout, at: t10))
        #expect(e2 == [.requestReaderClose(stream: .stdout)])

        // Grace expires at t=30s with ONLY stderr still open: emits close for stderr only
        let t30 = MonotonicInstant(nanoseconds: 30_000_000_000)
        let (s3, effects) = DiagnosticCaptureReducer.reduce(state: s2, event: .graceDeadlineFired(at: t30))

        #expect(effects.contains(.requestReaderClose(stream: .stderr)))
        #expect(!effects.contains(.requestReaderClose(stream: .stdout)))
        #expect(s3.unknownUnreadTail == true)
        #expect(effects.contains(.requestFinalization(outcome: .incomplete(reasons: [.graceExpiredWithOpenWriters]))))
    }

    @Test("Closure and finalization acknowledgement seals terminal state and gates resource readiness")
    func reducerClosureAndFinalizationAcknowledgement() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .closeRequested, .stderr: .closeRequested]
        state.finalizationStatus = .requested(outcome: .clean)

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .finalizationAcknowledged(at: t1))
        #expect(s1.finalizationStatus == .sealed(outcome: .clean))
        #expect(e1.isEmpty)
        // Finalization acknowledged alone does NOT mean resources are closed
        #expect(s1.isResourceTeardownComplete == false)

        // Close stdout reader
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (s2, _) = DiagnosticCaptureReducer.reduce(state: s1, event: .readerCloseAcknowledged(stream: .stdout, at: t2))
        #expect(s2.streamClosureStatuses[.stdout] == .closeAcknowledged)
        #expect(s2.isResourceTeardownComplete == false) // stderr still open

        // Close stderr reader
        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (s3, _) = DiagnosticCaptureReducer.reduce(state: s2, event: .readerCloseAcknowledged(stream: .stderr, at: t3))
        #expect(s3.streamClosureStatuses[.stderr] == .closeAcknowledged)
        #expect(s3.isResourceTeardownComplete == true) // Both closed and sealed! Ready for registry release

        // Repeated acknowledgement is idempotent
        let (s4, e4) = DiagnosticCaptureReducer.reduce(state: s3, event: .finalizationAcknowledged(at: t3))
        #expect(s4.finalizationStatus == .sealed(outcome: .clean))
        #expect(e4.isEmpty)
    }

    @Test("Spawn failure immediately emits incomplete finalization with failure reason")
    func reducerSpawnFailure() {
        let state = DiagnosticCaptureState(isSpawned: false)
        let t0 = MonotonicInstant(nanoseconds: 0)

        let (newState, effects) = DiagnosticCaptureReducer.reduce(
            state: state,
            event: .spawnFailed(errorDescription: "pipe creation failed", at: t0)
        )

        let expectedReasons: Set<DiagnosticIncompleteReason> = [.spawnFailure("pipe creation failed")]
        #expect(effects == [.requestFinalization(outcome: .incomplete(reasons: expectedReasons))])
        #expect(newState.finalizationStatus == .requested(outcome: .incomplete(reasons: expectedReasons)))
    }

    @Test("Late launcher exit observation updates launcher record without mutating sealed capture outcome")
    func reducerIndependentLateLauncherObservation() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.finalizationStatus = .sealed(outcome: .clean)

        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .launcherExited(status: 137, at: t10))

        #expect(s1.finalizationStatus == .sealed(outcome: .clean))
        #expect(s1.launcherStatus == .exited(status: 137, at: t10))
        #expect(e1.isEmpty)
    }

    @Test("Observer cancellation does not affect diagnostic capture state")
    func reducerObserverCancellationDoesNotAffectCapture() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .observerCancelled(at: t1))

        #expect(s1.streamClosureStatuses[.stdout] == .open)
        #expect(s1.streamClosureStatuses[.stderr] == .open)
        #expect(s1.graceStatus == .notStarted)
        #expect(e1.isEmpty)
    }

    // MARK: - 3. Gate 1-5 Regressions and Full Event Lifecycle Tests

    @Test("Gate 1: Event-driven end-to-end lifecycle from spawn to clean finalization and closure acks in both orders")
    func gate1_eventDrivenLifecycleBothOrders() throws {
        // Lifecycle order 1: stdout closeAck before stderr closeAck, finalizationAck before closureAcks
        let unspawned = DiagnosticCaptureState(isSpawned: false)
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (sSpawn, _) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .spawnSucceeded(at: t0))

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (sEOF1, eEOF1) = DiagnosticCaptureReducer.reduce(state: sSpawn, event: .cleanEOF(stream: .stdout, at: t1))
        #expect(eEOF1 == [.requestReaderClose(stream: .stdout)])
        #expect(sEOF1.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(sEOF1.isResourceTeardownComplete == false)

        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (sEOF2, eEOF2) = DiagnosticCaptureReducer.reduce(state: sEOF1, event: .cleanEOF(stream: .stderr, at: t2))
        #expect(eEOF2.contains(.requestReaderClose(stream: .stderr)))
        #expect(eEOF2.contains(.requestFinalization(outcome: .clean)))
        #expect(sEOF2.streamClosureStatuses[.stderr] == .closeRequested)
        #expect(sEOF2.isResourceTeardownComplete == false)

        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (sFinAck, eFinAck) = DiagnosticCaptureReducer.reduce(state: sEOF2, event: .finalizationAcknowledged(at: t3))
        #expect(eFinAck.isEmpty)
        #expect(sFinAck.finalizationStatus == .sealed(outcome: .clean))
        #expect(sFinAck.isResourceTeardownComplete == false) // Readers not acknowledged yet!

        let t4 = MonotonicInstant(nanoseconds: 4_000_000_000)
        let (sClose1, _) = DiagnosticCaptureReducer.reduce(state: sFinAck, event: .readerCloseAcknowledged(stream: .stdout, at: t4))
        #expect(sClose1.isResourceTeardownComplete == false)

        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (sClose2, _) = DiagnosticCaptureReducer.reduce(state: sClose1, event: .readerCloseAcknowledged(stream: .stderr, at: t5))
        #expect(sClose2.isResourceTeardownComplete == true) // Both closed and sealed!

        // Lifecycle order 2: reader closure acks arrive BEFORE finalizationAck
        let (sEarlyClose1, _) = DiagnosticCaptureReducer.reduce(state: sEOF2, event: .readerCloseAcknowledged(stream: .stdout, at: t3))
        let (sEarlyClose2, _) = DiagnosticCaptureReducer.reduce(state: sEarlyClose1, event: .readerCloseAcknowledged(stream: .stderr, at: t4))
        #expect(sEarlyClose2.isResourceTeardownComplete == false) // Readers closed but finalization still requested!

        let (sFinalSealed, _) = DiagnosticCaptureReducer.reduce(state: sEarlyClose2, event: .finalizationAcknowledged(at: t5))
        #expect(sFinalSealed.isResourceTeardownComplete == true)
    }

    @Test("Gate 1: Read error followed by closure ack leaves healthy stream open until its own end")
    func gate1_readErrorClosureAckLeavesHealthyOpen() {
        let unspawned = DiagnosticCaptureState(isSpawned: false)
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (sSpawn, _) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .spawnSucceeded(at: t0))

        // stdout read error at t=1s emits close for stdout only
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (sErr, eErr) = DiagnosticCaptureReducer.reduce(state: sSpawn, event: .readError(stream: .stdout, errorCode: 5, at: t1))
        #expect(eErr == [.requestReaderClose(stream: .stdout)])
        #expect(sErr.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(sErr.streamClosureStatuses[.stderr] == .open)

        // Close ack for stdout at t=2s
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (sCloseStdout, _) = DiagnosticCaptureReducer.reduce(state: sErr, event: .readerCloseAcknowledged(stream: .stdout, at: t2))
        #expect(sCloseStdout.streamClosureStatuses[.stdout] == .closeAcknowledged)
        #expect(sCloseStdout.streamClosureStatuses[.stderr] == .open)

        // Stderr can still receive data chunks
        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (sDataStderr, eDataStderr) = DiagnosticCaptureReducer.reduce(state: sCloseStdout, event: .dataChunk(stream: .stderr, byteCount: 512, at: t3))
        #expect(sDataStderr.bytesRead[.stderr] == 512)
        #expect(eDataStderr.isEmpty)

        // Stderr clean EOF at t=4s completes capture and preserves error 5
        let t4 = MonotonicInstant(nanoseconds: 4_000_000_000)
        let (sEOFStderr, eEOFStderr) = DiagnosticCaptureReducer.reduce(state: sDataStderr, event: .cleanEOF(stream: .stderr, at: t4))
        #expect(eEOFStderr.contains(.requestReaderClose(stream: .stderr)))
        #expect(eEOFStderr.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stdout, code: 5)]))))
    }

    @Test("Gate 1: Terminal finalizationFailed allows resource release and cohort drain once readers close")
    func gate1_finalizationFailedAllowsResourceRelease() throws {
        // Lifecycle Order A: Finalization fails BEFORE reader closures acknowledge
        let registryA = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let tokenA = try registryA.reserve(bottleID: BottleID("b1"))
        _ = registryA.beginQuit()

        let unspawnedA = DiagnosticCaptureState(isSpawned: false)
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (sSpawnA, _) = DiagnosticCaptureReducer.reduce(state: unspawnedA, event: .spawnSucceeded(at: t0))
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (sEOF1A, _) = DiagnosticCaptureReducer.reduce(state: sSpawnA, event: .cleanEOF(stream: .stdout, at: t1))
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (sEOF2A, _) = DiagnosticCaptureReducer.reduce(state: sEOF1A, event: .cleanEOF(stream: .stderr, at: t2))
        #expect(sEOF2A.finalizationStatus == .requested(outcome: .clean))
        #expect(sEOF2A.streamClosureStatuses[.stdout] == .closeRequested)
        #expect(sEOF2A.streamClosureStatuses[.stderr] == .closeRequested)

        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (sFailedA, _) = DiagnosticCaptureReducer.reduce(state: sEOF2A, event: .finalizationFailed(errorDescription: "disk write error", at: t3))
        #expect(sFailedA.finalizationStatus == .failed(outcome: .clean, errorDescription: "disk write error"))
        #expect(sFailedA.isResourceTeardownComplete == false) // Descriptors still not acknowledged closed!

        // Model registry release gating: cannot release token while teardown incomplete
        #expect(registryA.isQuitCohortDrained == false)

        // Close stdout reader
        let t4 = MonotonicInstant(nanoseconds: 4_000_000_000)
        let (sClose1A, _) = DiagnosticCaptureReducer.reduce(state: sFailedA, event: .readerCloseAcknowledged(stream: .stdout, at: t4))
        #expect(sClose1A.isResourceTeardownComplete == false)

        // Close stderr reader
        let t5 = MonotonicInstant(nanoseconds: 5_000_000_000)
        let (sClose2A, _) = DiagnosticCaptureReducer.reduce(state: sClose1A, event: .readerCloseAcknowledged(stream: .stderr, at: t5))
        #expect(sClose2A.isResourceTeardownComplete == true) // Terminal failure + all descriptors closed enables release!

        // Now release succeeds and cohort drains
        #expect(registryA.release(token: tokenA) == true)
        #expect(registryA.isQuitCohortDrained == true)

        // Lifecycle Order B: Reader closures acknowledge BEFORE finalization fails
        let registryB = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let tokenB = try registryB.reserve(bottleID: BottleID("b2"))
        _ = registryB.beginQuit()

        let (sClose1B, _) = DiagnosticCaptureReducer.reduce(state: sEOF2A, event: .readerCloseAcknowledged(stream: .stdout, at: t3))
        let (sClose2B, _) = DiagnosticCaptureReducer.reduce(state: sClose1B, event: .readerCloseAcknowledged(stream: .stderr, at: t4))
        #expect(sClose2B.isResourceTeardownComplete == false) // Finalization still pending (.requested), so readiness is false!

        let (sFailedB, _) = DiagnosticCaptureReducer.reduce(state: sClose2B, event: .finalizationFailed(errorDescription: "disk write error", at: t5))
        #expect(sFailedB.finalizationStatus == .failed(outcome: .clean, errorDescription: "disk write error"))
        #expect(sFailedB.isResourceTeardownComplete == true) // Now terminal!
        #expect(registryB.release(token: tokenB) == true)
        #expect(registryB.isQuitCohortDrained == true)
    }

    @Test("Gate 2: Central expiry must not overwrite pending, sealed or failed finalization on late events")
    func gate2_centralExpiryDoesNotOverwriteFinalization() {
        let unspawned = DiagnosticCaptureState(isSpawned: false)

        // 1. Quit request at t=0s arms grace to t=30s
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (sQuit, eQuit) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .appQuitRequest(at: t0))
        #expect(eQuit == [.requestTimer(expiry: MonotonicInstant(nanoseconds: 30_000_000_000))])

        // 2. Spawn fails at t=1s: cancels timer and requests incomplete finalization
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (sSpawnFail, eSpawnFail) = DiagnosticCaptureReducer.reduce(state: sQuit, event: .spawnFailed(errorDescription: "posix_spawn failed", at: t1))
        #expect(eSpawnFail.contains(.cancelTimer))
        #expect(eSpawnFail.contains(.requestFinalization(outcome: .incomplete(reasons: [.spawnFailure("posix_spawn failed")]))))
        #expect(sSpawnFail.finalizationStatus == .requested(outcome: .incomplete(reasons: [.spawnFailure("posix_spawn failed")])))

        // Phase 1 (Requested): late event at t=31s (> old expiry) arriving while finalization is requested
        let t31 = MonotonicInstant(nanoseconds: 31_000_000_000)
        let (sLateReq, eLateReq) = DiagnosticCaptureReducer.reduce(state: sSpawnFail, event: .observerCancelled(at: t31))
        #expect(eLateReq.isEmpty)
        #expect(sLateReq.finalizationStatus == sSpawnFail.finalizationStatus)

        // Phase 2 (Sealed): finalization acknowledged at t=2s seals the spawn failure
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (sSealed, _) = DiagnosticCaptureReducer.reduce(state: sSpawnFail, event: .finalizationAcknowledged(at: t2))
        #expect(sSealed.finalizationStatus == .sealed(outcome: .incomplete(reasons: [.spawnFailure("posix_spawn failed")])))

        // Late observerCancelled at t=31s on sealed state: must NOT re-run expiry or emit effects
        let (sLateSealed, eLateSealed) = DiagnosticCaptureReducer.reduce(state: sSealed, event: .observerCancelled(at: t31))
        #expect(eLateSealed.isEmpty)
        #expect(sLateSealed.finalizationStatus == sSealed.finalizationStatus)

        // Late cleanEOF arriving at t=35s on sealed state: cannot overwrite
        let t35 = MonotonicInstant(nanoseconds: 35_000_000_000)
        let (sLateEOF, eLateEOF) = DiagnosticCaptureReducer.reduce(state: sSealed, event: .cleanEOF(stream: .stdout, at: t35))
        #expect(eLateEOF.isEmpty)
        #expect(sLateEOF.finalizationStatus == sSealed.finalizationStatus)

        // Phase 3 (Failed): finalization failed at t=2s
        let (sFailed, _) = DiagnosticCaptureReducer.reduce(state: sSpawnFail, event: .finalizationFailed(errorDescription: "storage failure", at: t2))
        #expect(sFailed.finalizationStatus == .failed(outcome: .incomplete(reasons: [.spawnFailure("posix_spawn failed")]), errorDescription: "storage failure"))

        // Late events on failed state cannot overwrite
        let (sLateFailed, eLateFailed) = DiagnosticCaptureReducer.reduce(state: sFailed, event: .observerCancelled(at: t31))
        #expect(eLateFailed.isEmpty)
        #expect(sLateFailed.finalizationStatus == sFailed.finalizationStatus)

        // First terminal acknowledgement semantics:
        // Order 1: Acknowledged first -> duplicate finalizationFailed ignored
        let (sDupFail, eDupFail) = DiagnosticCaptureReducer.reduce(state: sSealed, event: .finalizationFailed(errorDescription: "late error", at: t31))
        #expect(eDupFail.isEmpty)
        #expect(sDupFail.finalizationStatus == sSealed.finalizationStatus)

        // Order 2: Failed first -> duplicate finalizationAcknowledged ignored
        let (sDupAck, eDupAck) = DiagnosticCaptureReducer.reduce(state: sFailed, event: .finalizationAcknowledged(at: t31))
        #expect(eDupAck.isEmpty)
        #expect(sDupAck.finalizationStatus == sFailed.finalizationStatus)
    }

    @Test("Gate 3: Floating conversion boundary safety and hostile duration values")
    func gate3_floatingConversionBoundarySafety() {
        let t0 = MonotonicInstant(nanoseconds: 0)

        // Double(UInt64.max) / 1e9 computes 2^64 / 1e9, which scales to 2^64 and traps if unchecked
        let boundarySeconds = Double(UInt64.max) / 1_000_000_000.0
        #expect(t0.adding(seconds: boundarySeconds) == nil)

        // nextUp is strictly beyond representable bound
        #expect(t0.adding(seconds: boundarySeconds.nextUp) == nil)

        // nextDown is below 2^64 and converts safely without trapping
        let safeDown = boundarySeconds.nextDown
        let addedDown = t0.adding(seconds: safeDown)
        #expect(addedDown != nil)

        // Tiny fractional duration
        let tiny = t0.adding(seconds: 1e-9)
        #expect(tiny?.nanoseconds == 1)

        // Zero duration returns identity
        let zero = t0.adding(seconds: 0.0)
        #expect(zero?.nanoseconds == 0)

        // Hostile inputs
        #expect(t0.adding(seconds: Double.greatestFiniteMagnitude) == nil)
        #expect(t0.adding(seconds: -1.0) == nil)
        #expect(t0.adding(seconds: Double.nan) == nil)
        #expect(t0.adding(seconds: Double.infinity) == nil)
    }

    @Test("Gate 4: Rejected negative inputs at t > expiry do not trigger due-expiry or mutate receipt")
    func gate4_rejectedInputsBeforeExpiryDoNotTriggerEffects() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (sQuit, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0)) // expiry = 30s

        // Negative queueOverflow at t=31s (> expiry)
        let t31 = MonotonicInstant(nanoseconds: 31_000_000_000)
        let (sNeg, eNeg) = DiagnosticCaptureReducer.reduce(state: sQuit, event: .queueOverflow(stream: .stdout, droppedBytes: -50, at: t31))

        // State must remain completely unchanged and effects empty
        #expect(sNeg == sQuit)
        #expect(eNeg.isEmpty)
        #expect(sNeg.graceStatus == sQuit.graceStatus)
        #expect(sNeg.streamClosureStatuses[.stdout] == .open)
        #expect(sNeg.streamClosureStatuses[.stderr] == .open)
        #expect(sNeg.finalizationStatus == .none)

        // Negative data chunk at t=31s is also rejected with unchanged state
        let (sNegData, eNegData) = DiagnosticCaptureReducer.reduce(state: sQuit, event: .dataChunk(stream: .stdout, byteCount: -100, at: t31))
        #expect(sNegData == sQuit)
        #expect(eNegData.isEmpty)

        // Valid event at t=32s now triggers expiry exactly once
        let t32 = MonotonicInstant(nanoseconds: 32_000_000_000)
        let (sValid, eValid) = DiagnosticCaptureReducer.reduce(state: sQuit, event: .observerCancelled(at: t32))
        #expect(eValid.contains(.requestReaderClose(stream: .stdout)))
        #expect(eValid.contains(.requestReaderClose(stream: .stderr)))
        #expect(sValid.graceStatus == .expired(trigger: .appQuitRequest, startedAt: t0, expiry: MonotonicInstant(nanoseconds: 30_000_000_000)))
    }

    @Test("Gate 5: Pure metadata mapper preserves reducer-generated spawnError across requested, sealed, and failed phases")
    func gate5_pureMetadataMapperPreservesSpawnErrorAcrossPhases() {
        let unspawned = DiagnosticCaptureState(isSpawned: false)
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (sRequested, _) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .spawnFailed(errorDescription: "execve ENOENT", at: t1))

        // Phase 1: requested
        let metaRequested = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("b1"),
            requestedPreset: "default",
            winedebugValue: "",
            launcherCommand: ["wine64"],
            state: sRequested,
            retainedBytesOnDisk: nil
        )
        #expect(metaRequested.launcher.spawnError == "execve ENOENT")
        #expect(metaRequested.launcher.spawnSuccess == false)

        // Phase 2: sealed
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (sSealed, _) = DiagnosticCaptureReducer.reduce(state: sRequested, event: .finalizationAcknowledged(at: t2))
        let metaSealed = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("b1"),
            requestedPreset: "default",
            winedebugValue: "",
            launcherCommand: ["wine64"],
            state: sSealed,
            retainedBytesOnDisk: nil
        )
        #expect(metaSealed.launcher.spawnError == "execve ENOENT")

        // Phase 3: failed
        let (sFailed, _) = DiagnosticCaptureReducer.reduce(state: sRequested, event: .finalizationFailed(errorDescription: "receipt write error", at: t2))
        let metaFailed = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("b1"),
            requestedPreset: "default",
            winedebugValue: "",
            launcherCommand: ["wine64"],
            state: sFailed,
            retainedBytesOnDisk: nil
        )
        #expect(metaFailed.launcher.spawnError == "execve ENOENT")
    }

    @Test("Metadata mapper preserves custom preset, winedebug values, and launcher command")
    func metadataPreservesCustomPresetAndWinedebug() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.finalizationStatus = .sealed(outcome: .clean)

        let meta = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("bottle-custom"),
            requestedPreset: "fps-debug",
            winedebugValue: "+fps,+loaddll",
            launcherCommand: ["wine64", "game.exe", "--debug"],
            state: state,
            retainedBytesOnDisk: 1024
        )
        #expect(meta.bottleID == "bottle-custom")
        #expect(meta.requestedPreset == "fps-debug")
        #expect(meta.winedebugValue == "+fps,+loaddll")
        #expect(meta.launcher.command == ["wine64", "game.exe", "--debug"])
        #expect(meta.accounting.retainedBytesOnDisk == 1024)
    }

    @Test("Metadata accounting maps queue, sink, and retention drops accurately with overflow flag and optional disk count")
    func metadataAccountingMapsCountsAndOverflow() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.queueDroppedBytes = 128
        state.sinkDroppedBytes = 64
        state.retentionDroppedBytes = 32
        state.unknownUnreadTail = true
        state.hasCounterOverflow = true
        state.finalizationStatus = .sealed(outcome: .incomplete(reasons: [.graceExpiredWithOpenWriters]))

        // Case A: retainedBytesOnDisk provided as measured 0 vs unknown nil
        let metaUnknownDisk = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("b1"),
            requestedPreset: "default",
            winedebugValue: "",
            launcherCommand: ["wine64"],
            state: state,
            retainedBytesOnDisk: nil
        )
        #expect(metaUnknownDisk.accounting.queueDroppedBytes == 128)
        #expect(metaUnknownDisk.accounting.sinkDroppedBytes == 64)
        #expect(metaUnknownDisk.accounting.retentionDroppedBytes == 32)
        #expect(metaUnknownDisk.accounting.unknownUnreadTail == true)
        #expect(metaUnknownDisk.accounting.hasCounterOverflow == true)
        #expect(metaUnknownDisk.accounting.retainedBytesOnDisk == nil)

        let metaMeasuredZero = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("b1"),
            requestedPreset: "default",
            winedebugValue: "",
            launcherCommand: ["wine64"],
            state: state,
            retainedBytesOnDisk: 0
        )
        #expect(metaMeasuredZero.accounting.retainedBytesOnDisk == 0)
    }

    @Test("Metadata record encodes and decodes losslessly via JSON")
    func metadataJSONCodableRoundtrip() throws {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.queueDroppedBytes = 500
        state.sinkDroppedBytes = 250
        state.retentionDroppedBytes = 100
        state.hasCounterOverflow = true
        state.unknownUnreadTail = false
        state.finalizationStatus = .sealed(outcome: .clean)

        let meta = DiagnosticSessionMetadata.make(
            sessionID: UUID(),
            bottleID: BottleID("bottle-json"),
            requestedPreset: "custom-preset",
            winedebugValue: "+relay",
            launcherCommand: ["wine64", "app.exe"],
            state: state,
            retainedBytesOnDisk: 2048
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DiagnosticSessionMetadata.self, from: data)

        #expect(decoded == meta)
        #expect(decoded.accounting.retainedBytesOnDisk == 2048)
        #expect(decoded.accounting.hasCounterOverflow == true)
        #expect(decoded.requestedPreset == "custom-preset")
        #expect(decoded.winedebugValue == "+relay")
    }

    // MARK: - 4. Regressions A1-A6

    @Test("Regression A1: Repeated injected generator values across same-bottle release/readmit do not reuse token identity")
    func regressionA1_tokenReuseAcrossReleaseAndReadmit() throws {
        let registry = try DiagnosticAdmissionRegistry(maxGlobalAdmissions: 2)
        let t1 = try registry.reserve(bottleID: BottleID("b1"))
        #expect(registry.release(token: t1) == true)

        let t2 = try registry.reserve(bottleID: BottleID("b1"))
        #expect(t1 != t2)
        #expect(t2.id > t1.id)

        // Attempting to release with stale t1 must NOT release t2
        #expect(registry.release(token: t1) == false)
        #expect(registry.isBottleActive(BottleID("b1")) == true)
    }

    @Test("Regression A2: Early grace timer event at t < expiry is ignored and does not shorten grace")
    func regressionA2_earlyGraceTimerIsIgnored() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let t10 = MonotonicInstant(nanoseconds: 10_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t10))
        #expect(e1 == [.requestTimer(expiry: MonotonicInstant(nanoseconds: 40_000_000_000))])

        // Early timer at t = 11s (expiry is 40s)
        let t11 = MonotonicInstant(nanoseconds: 11_000_000_000)
        let (s2, e2) = DiagnosticCaptureReducer.reduce(state: s1, event: .graceDeadlineFired(at: t11))
        #expect(e2.isEmpty)
        #expect(s2.streamClosureStatuses[.stdout] == .open)
        #expect(s2.streamClosureStatuses[.stderr] == .open)
        #expect(s2.finalizationStatus == .none)
        if case let .running(_, _, expiry) = s2.graceStatus {
            #expect(expiry == MonotonicInstant(nanoseconds: 40_000_000_000))
        } else {
            Issue.record("Expected grace status to still be running with expiry=40s")
        }

        // Early timer at t = 39s is also ignored
        let t39 = MonotonicInstant(nanoseconds: 39_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .graceDeadlineFired(at: t39))
        #expect(e3.isEmpty)
        #expect(s3.finalizationStatus == .none)

        // Timer at t = 40s expires grace exactly once
        let t40 = MonotonicInstant(nanoseconds: 40_000_000_000)
        let (s4, e4) = DiagnosticCaptureReducer.reduce(state: s3, event: .graceDeadlineFired(at: t40))
        #expect(s4.graceStatus == .expired(trigger: .appQuitRequest, startedAt: t10, expiry: t40))
        #expect(e4.contains(.requestReaderClose(stream: .stdout)))
        #expect(e4.contains(.requestReaderClose(stream: .stderr)))

        // Duplicate timer at t = 41s does not re-emit
        let t41 = MonotonicInstant(nanoseconds: 41_000_000_000)
        let (_, e5) = DiagnosticCaptureReducer.reduce(state: s4, event: .graceDeadlineFired(at: t41))
        #expect(e5.isEmpty)
    }

    @Test("Regression A3: Late non-data events (cleanEOF at t > expiry) cannot bypass deadline or yield clean")
    func regressionA3_lateNonDataEventsCannotBypassDeadline() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let t0 = MonotonicInstant(nanoseconds: 0)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .appQuitRequest(at: t0)) // expiry = 30s

        let t31 = MonotonicInstant(nanoseconds: 31_000_000_000)
        let (s2, _) = DiagnosticCaptureReducer.reduce(state: s1, event: .cleanEOF(stream: .stdout, at: t31))
        let t32 = MonotonicInstant(nanoseconds: 32_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .cleanEOF(stream: .stderr, at: t32))

        #expect(s3.unknownUnreadTail == true)
        #expect(s3.finalizationStatus == .requested(outcome: .incomplete(reasons: [.graceExpiredWithOpenWriters])))
        #expect(!e3.contains(.requestFinalization(outcome: .clean)))
    }

    @Test("Regression A4: Reader close acknowledgement does not erase stream readError and unsolicited ack is ignored")
    func regressionA4_closeAckDoesNotEraseErrorAndUnsolicitedAckIgnored() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: state, event: .readError(stream: .stdout, errorCode: 5, at: t1))
        #expect(e1 == [.requestReaderClose(stream: .stdout)])
        #expect(s1.streamClosureStatuses[.stdout] == .closeRequested)

        // Valid reader close acknowledged for stdout
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (s2, _) = DiagnosticCaptureReducer.reduce(state: s1, event: .readerCloseAcknowledged(stream: .stdout, at: t2))
        #expect(s2.streamClosureStatuses[.stdout] == .closeAcknowledged)

        // Clean EOF for stderr at t=3s
        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (_, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .cleanEOF(stream: .stderr, at: t3))

        // Outcome MUST remain incomplete with stdout error code 5, NOT clean!
        #expect(e3.contains(.requestFinalization(outcome: .incomplete(reasons: [.streamReadError(stream: .stdout, code: 5)]))))

        // Unsolicited close ack on an open stream where close was not requested must be ignored
        var freshState = DiagnosticCaptureState(isSpawned: true)
        freshState.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let (unsolicitedState, unsolicitedEffects) = DiagnosticCaptureReducer.reduce(
            state: freshState,
            event: .readerCloseAcknowledged(stream: .stdout, at: t1)
        )
        #expect(unsolicitedEffects.isEmpty)
        #expect(unsolicitedState.streamClosureStatuses[.stdout] == .open)
    }

    @Test("Regression A5: Data chunk rejected outside open stream and late spawnSucceeded cannot reopen sealed capture")
    func regressionA5_invalidPhaseEventsAndSealedMutations() {
        // 1. Data chunk on notStarted stream is discarded
        let unspawned = DiagnosticCaptureState(isSpawned: false)
        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, e1) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .dataChunk(stream: .stdout, byteCount: 100, at: t1))
        #expect(s1.bytesRead[.stdout] == 0)
        #expect(e1 == [.discardPayload(stream: .stdout, byteCount: 100)])

        // 2. Data chunk after cleanEOF is discarded
        var spawned = DiagnosticCaptureState(isSpawned: true)
        spawned.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        let (s2, _) = DiagnosticCaptureReducer.reduce(state: spawned, event: .cleanEOF(stream: .stdout, at: t1))
        let t2 = MonotonicInstant(nanoseconds: 2_000_000_000)
        let (s3, e3) = DiagnosticCaptureReducer.reduce(state: s2, event: .dataChunk(stream: .stdout, byteCount: 50, at: t2))
        #expect(s3.bytesRead[.stdout] == 0)
        #expect(e3 == [.discardPayload(stream: .stdout, byteCount: 50)])

        // 3. Late spawnSucceeded after spawnFailed + finalizationAck is rejected
        let (s4, _) = DiagnosticCaptureReducer.reduce(state: unspawned, event: .spawnFailed(errorDescription: "spawn failed", at: t1))
        let (s5, _) = DiagnosticCaptureReducer.reduce(state: s4, event: .finalizationAcknowledged(at: t2))
        let t3 = MonotonicInstant(nanoseconds: 3_000_000_000)
        let (s6, e6) = DiagnosticCaptureReducer.reduce(state: s5, event: .spawnSucceeded(at: t3))
        #expect(s6.isSpawned == false)
        #expect(s6.streamClosureStatuses[.stdout] == .notStarted)
        #expect(e6.isEmpty)

        // 4. Sealed capture rejects mutations from late events
        var sealedState = s5
        sealedState.finalizationStatus = .sealed(outcome: .clean)
        let (s7, _) = DiagnosticCaptureReducer.reduce(state: sealedState, event: .sinkFailure(errorDescription: "io error", at: t3))
        #expect(s7.sinkDegraded == false)
        let (s8, _) = DiagnosticCaptureReducer.reduce(state: sealedState, event: .queueOverflow(stream: .stdout, droppedBytes: 50, at: t3))
        #expect(s8.queueDroppedBytes == 0)
    }

    @Test("Regression A6: Counters saturate at UInt64.max instead of wrapping and hostile inputs are safely handled")
    func regressionA6_numericSafetyAndHostileInputs() {
        var state = DiagnosticCaptureState(isSpawned: true)
        state.streamClosureStatuses = [.stdout: .open, .stderr: .open]
        state.bytesRead[.stdout] = UInt64.max - 10

        let t1 = MonotonicInstant(nanoseconds: 1_000_000_000)
        let (s1, _) = DiagnosticCaptureReducer.reduce(state: state, event: .dataChunk(stream: .stdout, byteCount: 100, at: t1))
        #expect(s1.bytesRead[.stdout] == UInt64.max)
        #expect(s1.hasCounterOverflow == true)

        // Negative drop counts leave counters unchanged without trapping
        let (s2, _) = DiagnosticCaptureReducer.reduce(state: state, event: .queueOverflow(stream: .stdout, droppedBytes: -50, at: t1))
        #expect(s2.queueDroppedBytes == 0)

        let (s3, _) = DiagnosticCaptureReducer.reduce(state: state, event: .retentionDiscard(droppedBytes: -20, at: t1))
        #expect(s3.retentionDroppedBytes == 0)

        let (s4, _) = DiagnosticCaptureReducer.reduce(state: state, event: .sinkWriteDropped(stream: .stdout, droppedBytes: -10, at: t1))
        #expect(s4.sinkDroppedBytes == 0)

        // Explicit sink write drop event updates sinkDroppedBytes
        let (s5, _) = DiagnosticCaptureReducer.reduce(state: state, event: .sinkWriteDropped(stream: .stdout, droppedBytes: 256, at: t1))
        #expect(s5.sinkDroppedBytes == 256)
    }
}
