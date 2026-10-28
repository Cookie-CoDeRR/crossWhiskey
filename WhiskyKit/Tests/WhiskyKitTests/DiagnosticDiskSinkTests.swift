//
//  DiagnosticDiskSinkTests.swift
//  WhiskyKitTests
//
//  Isolated test suite for DiagnosticDiskSink: verbatim raw byte retention,
//  compaction without in-band markers, first-chunk-over-cap preservation,
//  deterministic fault injection, symlink rejection, and atomic no-overwrite publish.
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
        defer { _ = sink.abort() }

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

    // MARK: - Test B: Raw Retention & Compaction (Startup Head Preserved, Suffix Kept, No In-Band Markers)

    @Test("Test B: Bounded retention keeps exact startup head, suffix, without in-band markers, and handles first chunk > cap")
    func testBoundedRetentionRawIntegrity() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testB")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        // --- Case 1: Multiple boundaries under incremental writes ---
        // Max stream cap: 1000 bytes, Head budget: 200 bytes, Tail budget: 400 bytes, Max chunk: 100 bytes
        let config = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 1000,
            headBudget: 200,
            tailBudget: 400,
            maxChunkBytes: 100,
            tailTrimThreshold: 500,
            maxSidecarBytes: 16384
        )

        let sink = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("incremental"),
            configuration: config
        )
        defer { _ = sink.abort() }

        // Write first 200 bytes (fills head exactly: 100 x 'A' + 100 x 'B')
        let headChunk1 = Data(repeating: 0x41, count: 100)
        let headChunk2 = Data(repeating: 0x42, count: 100)
        try sink.write(stream: .stdout, data: headChunk1)
        try sink.write(stream: .stdout, data: headChunk2)

        // Write 7 more chunks of 100 bytes (total admitted: 200 + 700 = 900 bytes <= 1000)
        for i in 0..<7 {
            let chunk = Data(repeating: UInt8(0x30 + i), count: 100)
            try sink.write(stream: .stdout, data: chunk)
        }

        // Up to here, no compaction has occurred: 900 bytes on disk
        let preCompactSize = try Data(contentsOf: fixtureDir.appendingPathComponent("incremental/stdout.bin")).count
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
        #expect(receipt.stdoutRecord.retainedHeadBytes == 200)
        #expect(receipt.stdoutRecord.retainedTailBytes == 400)
        #expect(receipt.stdoutRecord.retainedBytesOnDisk == 600)
        #expect(receipt.stdoutRecord.totalAdmittedBytes == 1100)
        #expect(receipt.stdoutRecord.committedBytes == 1100) // Does not exceed total admitted

        // Verify stream isolation: stderr was untouched
        #expect(receipt.stderrRecord.committedBytes == 0)
        #expect(!receipt.stderrRecord.isCompacted)

        let compactedStdout = try Data(contentsOf: fixtureDir.appendingPathComponent("incremental/stdout.bin"))
        #expect(compactedStdout.count == 600)

        // Verbatim payload check: NO marker bytes anywhere
        let stringContent = String(decoding: compactedStdout, as: UTF8.self)
        #expect(!stringContent.contains("DIAGNOSTIC RETENTION"))
        #expect(!stringContent.contains("DISCARDED"))

        // Head check: First 200 bytes must match headChunk1 + headChunk2 exactly
        let preservedHead = compactedStdout.prefix(200)
        #expect(preservedHead == headChunk1 + headChunk2)

        // Tail check: Last 400 bytes must match exactly the last 400 admitted bytes
        // The last 400 bytes admitted were: chunk5 (100) + chunk6 (100) + triggerChunk1 (100) + triggerChunk2 (100)
        let expectedTail = Data(repeating: UInt8(0x30 + 5), count: 100)
            + Data(repeating: UInt8(0x30 + 6), count: 100)
            + triggerChunk1
            + triggerChunk2
        let preservedTail = compactedStdout.suffix(400)
        #expect(preservedTail == expectedTail)

        // --- Case 2: First incoming chunk exceeds stream cap ---
        let configSmall = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxChunkBytes: 600,
            tailTrimThreshold: 300,
            maxSidecarBytes: 16384
        )
        let firstChunkSink = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("first-chunk-large"),
            configuration: configSmall
        )
        defer { _ = firstChunkSink.abort() }

        // A single 600-byte chunk exceeds the 500-byte cap
        var bigChunk = Data()
        for i in 0..<600 {
            bigChunk.append(UInt8(i % 256))
        }

        try firstChunkSink.write(stream: .stdout, data: bigChunk)
        let firstChunkReceipt = firstChunkSink.finish()

        #expect(firstChunkReceipt.stdoutRecord.isCompacted)
        #expect(firstChunkReceipt.stdoutRecord.retainedHeadBytes == 100)
        #expect(firstChunkReceipt.stdoutRecord.retainedTailBytes == 200)
        #expect(firstChunkReceipt.stdoutRecord.retainedBytesOnDisk == 300)
        #expect(firstChunkReceipt.stdoutRecord.discardedBytes == 300)

        let firstChunkOnDisk = try Data(contentsOf: fixtureDir.appendingPathComponent("first-chunk-large/stdout.bin"))
        #expect(firstChunkOnDisk.count == 300)
        // Check startup head: first 100 bytes match original chunk prefix
        #expect(firstChunkOnDisk.prefix(100) == bigChunk.prefix(100))
        // Check tail: last 200 bytes match original chunk suffix
        #expect(firstChunkOnDisk.suffix(200) == bigChunk.suffix(200))
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

        // Max bytes less than head + tail
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
        failingOpenAdapter.failOnOpenFileName = "stderr.bin"
        failingOpenAdapter.openErrno = EACCES

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: case1Dir, fileAdapter: failingOpenAdapter)
        }
        // Verify stdout.bin was cleaned up and directory was removed
        #expect(!FileManager.default.fileExists(atPath: case1Dir.appendingPathComponent("stdout.bin").path))
        #expect(!FileManager.default.fileExists(atPath: case1Dir.path))

        // Case 2: Short write under cap fails closed, records committed bytes, and marks writeOutcome failed
        let shortWriteAdapter = MockFaultInjectingFileAdapter()
        shortWriteAdapter.shortWriteLimit = 30 // Accepts only 30 bytes of a 50-byte chunk

        let sinkShort = try DiagnosticDiskSink(
            directoryURL: fixtureDir.appendingPathComponent("short"),
            fileAdapter: shortWriteAdapter
        )
        defer { _ = sinkShort.abort() }

        let sample50 = Data(repeating: 0x55, count: 50)
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkShort.write(stream: .stdout, data: sample50)
        }

        let receiptShort = sinkShort.finish()
        #expect(receiptShort.stdoutRecord.committedBytes == 30)
        #expect(receiptShort.stdoutRecord.retainedBytesOnDisk == 30)
        #expect(receiptShort.stdoutRecord.status == .failed)
        if case let .failed(op, errno, _) = receiptShort.stdoutRecord.writeOutcome {
            #expect(op == .write)
            #expect(errno == ENOSPC)
        } else {
            Issue.record("Expected writeOutcome to be failed")
        }
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
        defer { _ = sinkTruncate.abort() }

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
        if case let .failed(op, errno, _) = receiptTruncate.stdoutRecord.compactionOutcome {
            #expect(op == .truncate)
            #expect(errno == EIO)
        } else {
            Issue.record("Expected compactionOutcome to be failed with truncate")
        }

        // Case 4: No-overwrite publication fails when destination persistence.json already exists
        let publishCollisionDir = fixtureDir.appendingPathComponent("publish-collision")
        let sinkPublishCollision = try DiagnosticDiskSink(directoryURL: publishCollisionDir)
        defer { _ = sinkPublishCollision.abort() }

        try sinkPublishCollision.write(stream: .stdout, data: Data("valid".utf8))

        // Someone creates persistence.json concurrently before finish
        let collidingTarget = publishCollisionDir.appendingPathComponent("persistence.json")
        try Data("pre-existing content".utf8).write(to: collidingTarget)

        let receiptCollision = sinkPublishCollision.finish()
        #expect(!receiptCollision.sidecarPublished)
        #expect(receiptCollision.sidecarURL == nil)
        #expect(receiptCollision.failure != nil)
        if case let .failed(op, errno, _) = receiptCollision.metadataRecord.publishOutcome {
            #expect(op == .rename)
            #expect(errno == EEXIST)
        } else {
            Issue.record("Expected publishOutcome to be failed with EEXIST")
        }
        // Verify pre-existing file was NOT overwritten
        let preservedContent = try String(contentsOf: collidingTarget, encoding: .utf8)
        #expect(preservedContent == "pre-existing content")
    }

    // MARK: - Test E: Symlink Rejection, Ancestor Symlink Rejection & File Collisions

    @Test("Test E: Symlink rejection, ancestor symlink rejection, file collisions, and empty/oversized chunk policies")
    func testDirectoryAndChunkRejections() throws {
        let fixtureDir = try Self.makeOwnedFixtureDirectory(testName: "testE")
        defer { Self.cleanupFixtureDirectory(fixtureDir) }

        // 1. Direct symlink rejection
        let symlinkAdapter = MockFaultInjectingFileAdapter()
        symlinkAdapter.isSymlinkResponse = true
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: fixtureDir, fileAdapter: symlinkAdapter)
        }

        // 2. Ancestor symlink rejection
        let ancestorSymlinkAdapter = MockFaultInjectingFileAdapter()
        ancestorSymlinkAdapter.ancestorSymlinkResponse = true
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: fixtureDir, fileAdapter: ancestorSymlinkAdapter)
        }

        // 3. File collision rejection at setup
        let collisionDir = fixtureDir.appendingPathComponent("collision")
        try FileManager.default.createDirectory(at: collisionDir, withIntermediateDirectories: true)
        // Pre-create stdout.bin
        try Data("pre-existing".utf8).write(to: collisionDir.appendingPathComponent("stdout.bin"))

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: collisionDir)
        }

        // 4. Chunk validation
        let validDir = fixtureDir.appendingPathComponent("valid")
        let sink = try DiagnosticDiskSink(directoryURL: validDir)
        defer { _ = sink.abort() }

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
}

// MARK: - Mock Fault-Injecting File Adapter

private final class MockFaultInjectingFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    private let underlying = POSIXDiskSinkFileAdapter()

    var failOnOpenFileName: String? = nil
    var openErrno: Int32 = EACCES

    var shortWriteLimit: Int? = nil

    var failOnTruncate: Bool = false
    var truncateErrno: Int32 = EIO

    var isSymlinkResponse: Bool = false
    var ancestorSymlinkResponse: Bool = false

    func openDirectory(path: String) throws -> Int32 {
        try underlying.openDirectory(path: path)
    }

    func createDirectory(path: String, mode: mode_t) throws {
        try underlying.createDirectory(path: path, mode: mode)
    }

    func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32 {
        if let failName = failOnOpenFileName, fileName.contains(failName) {
            throw DiagnosticDiskSinkError.ioError(operation: .open, errno: openErrno, message: "Mock open error")
        }
        return try underlying.openAt(dirFd: dirFd, fileName: fileName, flags: flags, mode: mode)
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

    func publishSidecar(dirFd: Int32, tmpName: String, targetName: String) throws {
        try underlying.publishSidecar(dirFd: dirFd, tmpName: tmpName, targetName: targetName)
    }

    func syncDirectory(dirFd: Int32) throws {
        try underlying.syncDirectory(dirFd: dirFd)
    }

    func unlinkAt(dirFd: Int32, fileName: String) throws {
        try underlying.unlinkAt(dirFd: dirFd, fileName: fileName)
    }

    func removeDirectory(path: String) throws {
        try underlying.removeDirectory(path: path)
    }

    func fileExistsAt(dirFd: Int32, fileName: String) -> Bool {
        underlying.fileExistsAt(dirFd: dirFd, fileName: fileName)
    }

    func isDirectory(path: String) -> Bool {
        underlying.isDirectory(path: path)
    }

    func isSymbolicLink(path: String) -> Bool {
        if isSymlinkResponse { return true }
        return underlying.isSymbolicLink(path: path)
    }

    func checkSymlinkAncestors(path: String) -> Bool {
        if ancestorSymlinkResponse { return true }
        return underlying.checkSymlinkAncestors(path: path)
    }
}
