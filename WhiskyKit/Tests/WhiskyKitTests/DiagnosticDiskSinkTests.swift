//
//  DiagnosticDiskSinkTests.swift
//  WhiskyKitTests
//
//  Isolated test suite for DiagnosticDiskSink: raw roundtrip, bounded retention,
//  fault injection table, directory isolation, and controlled ingress integration.
//

import Darwin
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Diagnostic disk sink: bounded raw byte storage, retention compaction, and persistence receipt")
struct DiagnosticDiskSinkTests {

    // MARK: - Worktree-Owned Fixture Root Helper

    private static func makeOwnedFixtureDirectory(testName: String) throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let worktreeRoot = thisFile
            .deletingLastPathComponent() // WhiskyKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WhiskyKit
            .deletingLastPathComponent() // worktree
        let fixtureRoot = worktreeRoot.appendingPathComponent(".scratch/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let sessionDir = fixtureRoot.appendingPathComponent("\(testName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir
    }

    private static func cleanupFixtureDirectory(_ url: URL) {
        _ = try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Test A: Real Owned Files Under Cap

    @Test("Test A: Real owned files raw roundtrip under cap with NUL, split UTF8, reopen, and idempotent seal")
    func testRealOwnedFilesUnderCap() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testA")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        let sink = try DiagnosticDiskSink(directoryURL: fixtureDir)

        // Raw chunks with NUL bytes, high ASCII, and arbitrary byte sequences
        let stdoutChunk1 = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let stdoutChunk2 = Data("Standard output message with unicode: 🚀\n".utf8)
        let stderrChunk1 = Data([0x80, 0x81, 0x82, 0x00, 0x00]) // Invalid UTF8 standalone continuation bytes
        let stderrChunk2 = Data("Standard error alert: failure code 42\n".utf8)

        try sink.write(stream: .stdout, data: stdoutChunk1)
        try sink.write(stream: .stdout, data: stdoutChunk2)
        try sink.write(stream: .stderr, data: stderrChunk1)
        try sink.write(stream: .stderr, data: stderrChunk2)

        let receipt1 = sink.finish()
        #expect(receipt1.isSealed)
        #expect(receipt1.sidecarPublished)
        #expect(receipt1.failure == nil)
        #expect(receipt1.stdoutRecord.status == .sealed)
        #expect(receipt1.stderrRecord.status == .sealed)

        let expectedStdoutBytes = stdoutChunk1 + stdoutChunk2
        let expectedStderrBytes = stderrChunk1 + stderrChunk2

        #expect(receipt1.stdoutRecord.committedBytes == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stderrRecord.committedBytes == UInt64(expectedStderrBytes.count))
        #expect(receipt1.stdoutRecord.retainedBytesOnDisk == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stderrRecord.retainedBytesOnDisk == UInt64(expectedStderrBytes.count))

        // Idempotency check: Calling finish again returns the same receipt
        let receipt2 = sink.finish()
        #expect(receipt1 == receipt2)

        // Post-seal rejection: Further writes must fail closed with .sealed
        #expect(throws: DiagnosticDiskSinkError.sealed) {
            try sink.write(stream: .stdout, data: Data([0x01]))
        }

        // Reopen and compare exact bytes on disk
        let stdoutOnDisk = try Data(contentsOf: fixtureDir.appendingPathComponent("stdout.bin"))
        let stderrOnDisk = try Data(contentsOf: fixtureDir.appendingPathComponent("stderr.bin"))
        #expect(stdoutOnDisk == expectedStdoutBytes)
        #expect(stderrOnDisk == expectedStderrBytes)

        // Decodable sidecar validation
        guard let sidecarURL = receipt1.sidecarURL else {
            Issue.record("Missing sidecar URL in receipt")
            return
        }
        let sidecarData = try Data(contentsOf: sidecarURL)
        let decoder = JSONDecoder()
        let sidecar = try decoder.decode(DiagnosticPersistenceSidecar.self, from: sidecarData)
        #expect(sidecar.formatVersion == 1)
        #expect(sidecar.stdoutRecord.committedBytes == UInt64(expectedStdoutBytes.count))
        #expect(sidecar.stderrRecord.committedBytes == UInt64(expectedStderrBytes.count))
        #expect(sidecar.finalOutcome == "clean")
    }

    // MARK: - Test B: Bounded Retention Over Multiple Boundaries

    @Test("Test B: Bounded retention compaction keeps startup head, advances suffix, and updates sidecar")
    func testBoundedRetentionOverMultipleBoundaries() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testB")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        // Small deterministic configuration:
        // Max stream cap: 1000 bytes
        // Head budget: 200 bytes
        // Tail budget: 400 bytes
        // Max chunk: 100 bytes
        let config = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 1000,
            headBudget: 200,
            tailBudget: 400,
            maxChunkBytes: 100,
            tailTrimThreshold: 500,
            maxSidecarBytes: 16384
        )

        let sink = try DiagnosticDiskSink(directoryURL: fixtureDir, configuration: config)

        // Write first 200 bytes (fills head exactly)
        let headChunk1 = Data(repeating: 0x41, count: 100) // 100 x 'A'
        let headChunk2 = Data(repeating: 0x42, count: 100) // 100 x 'B'
        try sink.write(stream: .stdout, data: headChunk1)
        try sink.write(stream: .stdout, data: headChunk2)

        // Write 7 more chunks of 100 bytes (total admitted: 200 + 700 = 900 bytes <= 1000)
        for i in 0..<7 {
            let chunk = Data(repeating: UInt8(0x30 + i), count: 100)
            try sink.write(stream: .stdout, data: chunk)
        }

        // Up to here, no compaction has occurred: 900 bytes on disk
        let preCompactSize = try Data(contentsOf: fixtureDir.appendingPathComponent("stdout.bin")).count
        #expect(preCompactSize == 900)

        // Write 2 more chunks (200 bytes). This pushes prospective size to 1100 > 1000, triggering compaction!
        let triggerChunk1 = Data(repeating: 0x58, count: 100) // 100 x 'X'
        let triggerChunk2 = Data(repeating: 0x59, count: 100) // 100 x 'Y'
        try sink.write(stream: .stdout, data: triggerChunk1)
        try sink.write(stream: .stdout, data: triggerChunk2)

        let receipt = sink.finish()
        #expect(receipt.stdoutRecord.isCompacted)
        #expect(receipt.stdoutRecord.discardEvents > 0)
        #expect(receipt.stdoutRecord.discardedBytes > 0)
        #expect(receipt.stdoutRecord.retainedBytesOnDisk <= 1000)

        // Verify stream isolation: stderr was untouched
        #expect(receipt.stderrRecord.committedBytes == 0)
        #expect(!receipt.stderrRecord.isCompacted)

        let compactedStdout = try Data(contentsOf: fixtureDir.appendingPathComponent("stdout.bin"))
        #expect(compactedStdout.count <= 1000)

        // Check head bytes: First 200 bytes must match headChunk1 + headChunk2 exactly
        let preservedHead = compactedStdout.prefix(200)
        #expect(preservedHead == headChunk1 + headChunk2)

        // Check suffix bytes: Must end with triggerChunk2 ('Y's)
        #expect(compactedStdout.suffix(50) == triggerChunk2.suffix(50))

        // Check discard marker presence
        let stringContent = String(decoding: compactedStdout, as: UTF8.self)
        #expect(stringContent.contains("DIAGNOSTIC RETENTION:"))
        #expect(stringContent.contains("BYTES DISCARDED"))
    }

    // MARK: - Test C: Configuration Validation & Overflow Rejection

    @Test("Test C: Configuration validation rejects negative, zero, overflow, and huge allocations")
    func testConfigurationValidation() {
        // Zero or negative limits
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(maxBytesPerStream: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(headBudget: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(tailBudget: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(maxChunkBytes: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(maxChunkBytes: 70_000) // Exceeds 64 KiB
        }

        // Max bytes less than head + tail + marker
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(
                maxBytesPerStream: 1000,
                headBudget: 600,
                tailBudget: 600
            )
        }

        // Unbounded / huge configuration rejection
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            try DiagnosticDiskSinkConfiguration(maxBytesPerStream: 200 * 1024 * 1024) // 200 MiB exceeds 100 MiB limit
        }
    }

    // MARK: - Test D: Deterministic Fault Injection Table

    @Test("Test D: Deterministic file-operation faults for setup, short-write, compaction, and rename")
    func testFaultInjectionTable() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testD")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        // Case 1: Setup failure on open cleans up created resources
        let case1Dir = fixtureDir.appendingPathComponent("case1-open-fail")
        let failingOpenAdapter = MockFaultInjectingFileAdapter()
        failingOpenAdapter.failOnOpenPath = "stderr.bin"
        failingOpenAdapter.openErrno = EACCES

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: case1Dir, fileAdapter: failingOpenAdapter)
        }
        // Verify stdout.bin was cleaned up and directory was removed
        #expect(!FileManager.default.fileExists(atPath: case1Dir.appendingPathComponent("stdout.bin").path))
        #expect(!FileManager.default.fileExists(atPath: case1Dir.path))

        // Case 2: Short write under cap fails closed and records committed bytes
        let shortWriteAdapter = MockFaultInjectingFileAdapter()
        shortWriteAdapter.shortWriteLimit = 30 // Accepts only 30 bytes of a 50-byte chunk

        let sinkShort = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("short"),
            fileAdapter: shortWriteAdapter
        )
        let sample50 = Data(repeating: 0x55, count: 50)
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkShort.write(stream: .stdout, data: sample50)
        }

        let receiptShort = sinkShort.finish()
        #expect(receiptShort.stdoutRecord.committedBytes == 30)
        #expect(receiptShort.stdoutRecord.status == .failed)
        #expect(receiptShort.failure != nil)

        // Further writes fail closed immediately
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkShort.write(stream: .stdout, data: Data([0x01]))
        }

        // Case 3: Truncate failure during compaction marks stream partiallyCompacted
        let configSmall = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxChunkBytes: 100,
            tailTrimThreshold: 300,
            maxSidecarBytes: 16384
        )
        let truncateFailAdapter = MockFaultInjectingFileAdapter()
        let sinkTruncate = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("truncate-fail"),
            configuration: configSmall,
            fileAdapter: truncateFailAdapter
        )
        try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x41, count: 100))
        try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x42, count: 100))
        try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x43, count: 100))
        try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x44, count: 100))
        try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x45, count: 100))

        // Enable truncate fault before triggering compaction (500 + 100 > 500)
        truncateFailAdapter.failOnTruncate = true
        truncateFailAdapter.truncateErrno = EIO

        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkTruncate.write(stream: .stdout, data: Data(repeating: 0x46, count: 100))
        }
        let receiptTruncate = sinkTruncate.finish()
        #expect(receiptTruncate.stdoutRecord.status == .partiallyCompacted)
        #expect(receiptTruncate.stdoutRecord.lastFailedOperation == .truncate)

        // Case 4: Rename failure leaves sidecar unpublished
        let renameFailAdapter = MockFaultInjectingFileAdapter()
        renameFailAdapter.failOnRename = true
        renameFailAdapter.renameErrno = EXDEV

        let sinkRename = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("rename-fail"),
            fileAdapter: renameFailAdapter
        )
        try sinkRename.write(stream: .stdout, data: Data("valid".utf8))
        let receiptRename = sinkRename.finish()
        #expect(!receiptRename.sidecarPublished)
        #expect(receiptRename.sidecarURL == nil)
        #expect(receiptRename.failure != nil)
    }

    // MARK: - Test E: Collision, Symlink Rejection & Chunk Validation

    @Test("Test E: Symlink rejection, file collision, and empty/oversized chunk policies")
    func testDirectoryAndChunkRejections() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testE")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        // Symlink rejection
        let symlinkAdapter = MockFaultInjectingFileAdapter()
        symlinkAdapter.isSymlinkResponse = true
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: fixtureDir, fileAdapter: symlinkAdapter)
        }

        // File collision rejection
        let collisionDir = fixtureDir.appendingPathComponent("collision")
        try FileManager.default.createDirectory(at: collisionDir, withIntermediateDirectories: true)
        // Pre-create stdout.bin
        try Data("pre-existing".utf8).write(to: collisionDir.appendingPathComponent("stdout.bin"))

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: collisionDir)
        }

        // Chunk validation
        let validDir = fixtureDir.appendingPathComponent("valid")
        let sink = try DiagnosticDiskSink(directoryURL: validDir)

        // Empty chunk rejection
        #expect(throws: DiagnosticDiskSinkError.emptyChunk) {
            try sink.write(stream: .stdout, data: Data())
        }

        // Oversized chunk rejection (> 64 KiB)
        let oversizedData = Data(repeating: 0xAA, count: 65_537)
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sink.write(stream: .stdout, data: oversizedData)
        }
    }

    // MARK: - Test F: Controlled Stalled Consumer Integration with Ingress

    @Test("Test F: Controlled disk stall under ingress maintains bounded admission and accounts drops")
    func testStalledConsumerWithIngress() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testF")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        let sink = try DiagnosticDiskSink(directoryURL: fixtureDir)

        // Configure ingress with small bounds: 1024 bytes queued, max chunk 256 bytes
        let ingressConfig = try DiagnosticIngressConfiguration(
            maxQueuedBytes: 1024,
            maxQueuedEntries: 16,
            maxChunkBytes: 256
        )

        let gate = TestGate()

        // Ensure gate is always opened in defer to prevent hanging tests
        defer {
            gate.open()
        }

        let ingress = DiagnosticIngress(
            configuration: ingressConfig,
            consumer: { stream, data in
                // Stall write until gate is released
                gate.waitIfClosed()
                try sink.write(stream: stream, data: data)
            }
        )

        // 1. Enqueue chunk 1 (256 bytes). This gets picked up by drain and held by gate
        let chunk1 = Data(repeating: 0x11, count: 256)
        let r1 = ingress.enqueue(stream: .stdout, data: chunk1)
        #expect(r1 == .accepted)

        // Small yield to let drain pick up chunk1 and enter gate
        Thread.sleep(forTimeInterval: 0.02)

        // 2. Enqueue chunks 2, 3, 4 (256 * 3 = 768 bytes). Queued bytes = 768.
        #expect(ingress.enqueue(stream: .stdout, data: Data(repeating: 0x22, count: 256)) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: Data(repeating: 0x33, count: 256)) == .accepted)
        #expect(ingress.enqueue(stream: .stdout, data: Data(repeating: 0x44, count: 256)) == .accepted)

        // 3. Next enqueue would exceed 1024-byte capacity; must drop!
        let overflowChunk = Data(repeating: 0x99, count: 256)
        let dropResult = ingress.enqueue(stream: .stdout, data: overflowChunk)
        if case .dropped = dropResult {
            // Expected
        } else {
            Issue.record("Expected chunk to be dropped due to capacity, got \(dropResult)")
        }

        // 4. Open gate to allow drain to proceed and finish
        gate.open()

        // 5. Seal ingress and wait for receipt
        guard let ingressReceipt = ingress.finish(timeoutSeconds: 2.0) else {
            Issue.record("Timed out waiting for ingress finish receipt")
            return
        }
        #expect(ingressReceipt.queueDroppedBytes[.stdout] == 256)
        #expect((ingressReceipt.consumerSuccessBytes[.stdout] ?? 0) > 0)

        // 6. Seal sink and verify persistence receipt
        let sinkReceipt = sink.finish()
        #expect(sinkReceipt.isSealed)
        #expect(sinkReceipt.sidecarPublished)
        #expect(sinkReceipt.stdoutRecord.committedBytes == (ingressReceipt.consumerSuccessBytes[.stdout] ?? 0))
    }
}

// MARK: - Test Synchronization Gate

private final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func waitIfClosed() {
        condition.lock()
        defer { condition.unlock() }
        while !isOpen {
            condition.wait()
        }
    }

    func open() {
        condition.lock()
        defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
    }
}

// MARK: - Mock Fault-Injecting File Adapter

private final class MockFaultInjectingFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    private let underlying = POSIXDiskSinkFileAdapter()

    var failOnOpenPath: String? = nil
    var openErrno: Int32 = EACCES

    var shortWriteLimit: Int? = nil

    var failOnTruncate: Bool = false
    var truncateErrno: Int32 = EIO

    var failOnRename: Bool = false
    var renameErrno: Int32 = EXDEV

    var isSymlinkResponse: Bool = false

    func open(path: String, flags: Int32, mode: mode_t) throws -> Int32 {
        if let failPath = failOnOpenPath, path.contains(failPath) {
            throw DiagnosticDiskSinkError.ioError(operation: .open, errno: openErrno, message: "Mock open error")
        }
        return try underlying.open(path: path, flags: flags, mode: mode)
    }

    func write(fd: Int32, data: Data) throws -> Int {
        if let limit = shortWriteLimit {
            shortWriteLimit = nil // Trigger once
            let piece = data.prefix(limit)
            return try underlying.write(fd: fd, data: piece)
        }
        return try underlying.write(fd: fd, data: data)
    }

    func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t {
        try underlying.seek(fd: fd, offset: offset, whence: whence)
    }

    func truncate(fd: Int32, length: off_t) throws {
        if failOnTruncate {
            throw DiagnosticDiskSinkError.ioError(operation: .truncate, errno: truncateErrno, message: "Mock truncate error")
        }
        try underlying.truncate(fd: fd, length: length)
    }

    func sync(fd: Int32) throws {
        try underlying.sync(fd: fd)
    }

    func close(fd: Int32) throws {
        try underlying.close(fd: fd)
    }

    func rename(from: String, to: String) throws {
        if failOnRename {
            throw DiagnosticDiskSinkError.ioError(operation: .rename, errno: renameErrno, message: "Mock rename error")
        }
        try underlying.rename(from: from, to: to)
    }

    func syncDirectory(path: String) throws {
        try underlying.syncDirectory(path: path)
    }

    func fileExists(path: String) -> Bool {
        underlying.fileExists(path: path)
    }

    func isDirectory(path: String) -> Bool {
        underlying.isDirectory(path: path)
    }

    func isSymbolicLink(path: String) -> Bool {
        if isSymlinkResponse { return true }
        return underlying.isSymbolicLink(path: path)
    }

    func createDirectory(path: String, mode: mode_t) throws {
        try underlying.createDirectory(path: path, mode: mode)
    }

    func removeItem(path: String) throws {
        try underlying.removeItem(path: path)
    }
}
