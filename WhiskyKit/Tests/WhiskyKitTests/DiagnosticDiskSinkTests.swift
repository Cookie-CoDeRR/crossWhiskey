//
//  DiagnosticDiskSinkTests.swift
//  WhiskyKitTests
//
//  Isolated test suite for DiagnosticDiskSink: verbatim raw byte retention,
//  compaction without in-band markers, honest accounting, single-close ownership state machine,
//  preserved pre-existing files, component-relative directory acquisition, deterministic fault injection,
//  and platform security/storage admission verification.
//

import Darwin
import Foundation
import Testing
@testable import WhiskyKit

// MARK: - Mock Fault-Injecting File Adapter

private final class MockFaultInjectingFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    private let underlying = POSIXDiskSinkFileAdapter()

    // Recorded operations
    var closeAttempts: [Int32: Int] = [:]
    var closeInvocationCount = 0
    var failOnCloseInvocation: Int? = nil
    var closeAttemptsByResource: [String: Int] = [:]
    var openedDescriptors: Set<Int32> = []
    var fdFileNames: [Int32: String] = [:]
    var unlinkInvocationCount = 0
    var removeDirectoryInvocationCount = 0
    var statInvocationCount = 0

    // Injected faults
    var failOnOpenFileName: String? = nil
    var openErrno: Int32 = EACCES

    var writeInvocationCount: Int = 0
    var failOnWriteInvocation: Int? = nil
    var failOnWriteCommittedBytes: Int? = nil
    var failOnWriteAmbiguous: Bool = false
    var shortWriteLimit: Int? = nil
    var throwShortWriteOnInvocation: Int? = nil
    var failOnSyncFileName: String? = nil

    var failOnSeek: Bool = false
    var seekErrno: Int32 = EIO

    var failOnTruncate: Bool = false
    var truncateErrno: Int32 = EIO

    var failOnSync: Bool = false
    var syncErrno: Int32 = EIO

    var failOnCloseFileName: String? = nil
    var closeErrno: Int32 = EIO

    var failOnPublish: Bool = false
    var publishErrno: Int32 = EEXIST

    var failOnDirectorySync: Bool = false
    var directorySyncErrno: Int32 = EIO

    var failOnUnlinkAt: Bool = false
    var unlinkErrno: Int32 = EIO

    var failOnCreateDirectory: Bool = false
    var createDirectoryErrno: Int32 = EEXIST

    var failOnOpenDirectory: Bool = false
    var openDirectoryErrno: Int32 = EACCES

    var failOnRemoveDirectory: Bool = false
    var removeDirectoryErrno: Int32 = EIO

    // Ownership & platform security hooks
    var statHandler: ((Int32) throws -> Darwin.stat)? = nil
    var mockStat: [Int32: Darwin.stat] = [:]
    var mockChildStat: Darwin.stat? = nil
    var failOnStat: Bool = false
    var statErrno: Int32 = EIO

    var aclHandler: ((Int32) -> (acl: acl_t?, errno: Int32))? = nil
    var mockExtendedAcl: acl_t? = nil
    var mockExtendedAclErrno: Int32? = nil

    var statfsHandler: ((Int32) throws -> (typeName: String, flags: UInt32))? = nil
    var mockStatfsTypeName: String? = nil
    var mockStatfsFlags: UInt32? = nil
    var failOnStatfs: Bool = false
    var statfsErrno: Int32 = EIO

    var scanUsageHandler: ((Int32, Int) throws -> UInt64)? = nil
    var mockDirectoryUsage: UInt64? = nil
    var failOnDirectoryUsage: Bool = false
    var directoryUsageErrno: Int32 = EIO

    func openRootDirectory() throws -> Int32 {
        try underlying.openRootDirectory()
    }

    func openDirectoryAt(parentFd: Int32, component: String) throws -> Int32 {
        if failOnOpenDirectory {
            throw DiagnosticDiskSinkError.ioError(operation: .directoryOpen, errno: openDirectoryErrno, message: "Mock open directory error")
        }
        let fd = try underlying.openDirectoryAt(parentFd: parentFd, component: component)
        openedDescriptors.insert(fd)
        return fd
    }

    func createDirectoryAt(parentFd: Int32, component: String, mode: mode_t) throws {
        if failOnCreateDirectory {
            if createDirectoryErrno == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("Session directory child '\(component)' already exists")
            }
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCreate, errno: createDirectoryErrno, message: "Mock create directory error")
        }
        try underlying.createDirectoryAt(parentFd: parentFd, component: component, mode: mode)
    }

    func removeDirectoryAt(parentFd: Int32, component: String) throws {
        removeDirectoryInvocationCount += 1
        if failOnRemoveDirectory {
            throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: removeDirectoryErrno, message: "Mock remove directory error")
        }
        try underlying.removeDirectoryAt(parentFd: parentFd, component: component)
    }

    func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32 {
        if let failName = failOnOpenFileName, fileName.contains(failName) {
            if openErrno == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("File '\(fileName)' already exists")
            }
            throw DiagnosticDiskSinkError.ioError(operation: .open, errno: openErrno, message: "Mock open error for \(fileName)")
        }
        let fd = try underlying.openAt(dirFd: dirFd, fileName: fileName, flags: flags, mode: mode)
        fdFileNames[fd] = fileName
        openedDescriptors.insert(fd)
        return fd
    }

    func write(fd: Int32, data: Data) throws -> Int {
        writeInvocationCount += 1
        if writeInvocationCount == throwShortWriteOnInvocation {
            let count = min(37, data.count)
            _ = try underlying.write(fd: fd, data: Data(data.prefix(count)))
            throw DiagnosticDiskSinkError.shortWrite(operation: .write, bytesCommitted: count, expectedBytes: data.count)
        }
        if let targetInvocation = failOnWriteInvocation, writeInvocationCount == targetInvocation {
            if failOnWriteAmbiguous {
                throw DiagnosticDiskSinkError.ioError(
                    operation: .write,
                    errno: EIO,
                    message: "Simulated ambiguous write error",
                    bytesCommitted: nil
                )
            }
            if let committed = failOnWriteCommittedBytes {
                let piece = data.prefix(committed)
                _ = try underlying.write(fd: fd, data: piece)
                throw DiagnosticDiskSinkError.ioError(
                    operation: .write,
                    errno: EIO,
                    message: "Simulated partial write error",
                    bytesCommitted: committed
                )
            }
        }
        if let limit = shortWriteLimit {
            shortWriteLimit = nil
            let piece = data.prefix(limit)
            return try underlying.write(fd: fd, data: piece)
        }
        return try underlying.write(fd: fd, data: data)
    }

    func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t {
        if failOnSeek {
            throw DiagnosticDiskSinkError.ioError(operation: .seek, errno: seekErrno, message: "Mock seek error")
        }
        return try underlying.seek(fd: fd, offset: offset, whence: whence)
    }

    func truncate(fd: Int32, length: off_t) throws {
        if failOnTruncate {
            throw DiagnosticDiskSinkError.ioError(operation: .truncate, errno: truncateErrno, message: "Mock truncate error")
        }
        try underlying.truncate(fd: fd, length: length)
    }

    func sync(fd: Int32) throws {
        if failOnSync || (failOnSyncFileName != nil && fdFileNames[fd]?.contains(failOnSyncFileName!) == true) {
            throw DiagnosticDiskSinkError.ioError(operation: .sync, errno: syncErrno, message: "Mock sync error")
        }
        try underlying.sync(fd: fd)
    }

    func close(fd: Int32) throws {
        closeInvocationCount += 1
        closeAttempts[fd, default: 0] += 1
        if closeInvocationCount == failOnCloseInvocation {
            _ = try? underlying.close(fd: fd)
            throw DiagnosticDiskSinkError.ioError(operation: .close, errno: EIO, message: "Consumed traversal descriptor")
        }
        if let name = fdFileNames[fd] {
            closeAttemptsByResource[name, default: 0] += 1
        }
        if let failTarget = failOnCloseFileName, let name = fdFileNames[fd], name.contains(failTarget) {
            _ = try? underlying.close(fd: fd)
            throw DiagnosticDiskSinkError.ioError(operation: .close, errno: closeErrno, message: "Mock close error on fd \(fd) for \(name)")
        }
        try underlying.close(fd: fd)
    }

    func publishSidecar(dirFd: Int32, tmpName: String, targetName: String) throws {
        if failOnPublish {
            if publishErrno == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("Destination '\(targetName)' already exists")
            }
            throw DiagnosticDiskSinkError.ioError(operation: .rename, errno: publishErrno, message: "Mock rename error")
        }
        try underlying.publishSidecar(dirFd: dirFd, tmpName: tmpName, targetName: targetName)
    }

    func syncDirectory(dirFd: Int32) throws {
        if failOnDirectorySync {
            throw DiagnosticDiskSinkError.ioError(operation: .directorySync, errno: directorySyncErrno, message: "Mock directory sync error")
        }
        try underlying.syncDirectory(dirFd: dirFd)
    }

    func unlinkAt(dirFd: Int32, fileName: String) throws {
        unlinkInvocationCount += 1
        if failOnUnlinkAt {
            throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: unlinkErrno, message: "Mock unlink error")
        }
        try underlying.unlinkAt(dirFd: dirFd, fileName: fileName)
    }

    func fileExistsAt(dirFd: Int32, fileName: String) -> Bool {
        underlying.fileExistsAt(dirFd: dirFd, fileName: fileName)
    }

    func stat(fd: Int32) throws -> Darwin.stat {
        statInvocationCount += 1
        if let handler = statHandler {
            return try handler(fd)
        }
        if failOnStat {
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: statErrno, message: "Mock stat error")
        }
        if let s = mockStat[fd] {
            return s
        }
        if let child = mockChildStat {
            return child
        }
        return try underlying.stat(fd: fd)
    }

    func getExtendedAcl(fd: Int32) -> (acl: acl_t?, errno: Int32) {
        if let handler = aclHandler {
            return handler(fd)
        }
        if let acl = mockExtendedAcl {
            return (acl, mockExtendedAclErrno ?? 0)
        }
        if let err = mockExtendedAclErrno {
            return (nil, err)
        }
        return underlying.getExtendedAcl(fd: fd)
    }

    func statfs(fd: Int32) throws -> (typeName: String, flags: UInt32) {
        if let handler = statfsHandler {
            return try handler(fd)
        }
        if failOnStatfs {
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: statfsErrno, message: "Mock statfs error")
        }
        if let flags = mockStatfsFlags {
            let type = mockStatfsTypeName ?? "apfs"
            return (type, flags)
        }
        return try underlying.statfs(fd: fd)
    }

    func scanDirectoryUsage(dirFd: Int32, maxEntries: Int) throws -> UInt64 {
        if let handler = scanUsageHandler {
            return try handler(dirFd, maxEntries)
        }
        if failOnDirectoryUsage {
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: directoryUsageErrno, message: "Mock directory usage error")
        }
        if let usage = mockDirectoryUsage {
            return usage
        }
        return try underlying.scanDirectoryUsage(dirFd: dirFd, maxEntries: maxEntries)
    }
}

// MARK: - Test Suite

@Suite("Diagnostic disk sink: bounded raw byte storage, retention compaction, and persistence receipt")
struct DiagnosticDiskSinkTests {

    // MARK: - Worktree-Owned Fixture Root Helper

    private static func makeOwnedFixtureRoot(testName: String) throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let worktreeRoot = thisFile
            .deletingLastPathComponent() // WhiskyKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WhiskyKit
            .deletingLastPathComponent() // worktree
        let fixtureRoot = worktreeRoot.appendingPathComponent(".scratch/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let testRoot = fixtureRoot.appendingPathComponent("\(testName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        chmod(testRoot.path, 0o700)
        return testRoot
    }

    private static func cleanupFixtureDirectory(_ url: URL) {
        _ = try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Darwin Extended ACL Test Helpers

    private static func makeAllowWriteAcl() -> acl_t? {
        var acl: acl_t? = acl_init(1)
        guard acl != nil else { return nil }
        var entry: acl_entry_t? = nil
        guard acl_create_entry(&acl, &entry) == 0, let e = entry else {
            if let a = acl { acl_free(UnsafeMutableRawPointer(a)) }
            return nil
        }
        acl_set_tag_type(e, ACL_EXTENDED_ALLOW)
        let perms: acl_permset_mask_t = UInt64(ACL_WRITE_DATA.rawValue | ACL_ADD_FILE.rawValue)
        acl_set_permset_mask_np(e, perms)
        return acl
    }

    private static func makeDenyDeleteAcl() -> acl_t? {
        var acl: acl_t? = acl_init(1)
        guard acl != nil else { return nil }
        var entry: acl_entry_t? = nil
        guard acl_create_entry(&acl, &entry) == 0, let e = entry else {
            if let a = acl { acl_free(UnsafeMutableRawPointer(a)) }
            return nil
        }
        acl_set_tag_type(e, ACL_EXTENDED_DENY)
        let perms: acl_permset_mask_t = UInt64(ACL_DELETE.rawValue | ACL_DELETE_CHILD.rawValue)
        acl_set_permset_mask_np(e, perms)
        return acl
    }

    // MARK: - Test A: Real Owned Files Under Cap

    @Test("Test A: Real owned files raw roundtrip under cap with NUL, split UTF8, reopen, and idempotent seal")
    func testRealOwnedFilesUnderCap() throws {
        let fixtureRoot = try Self.makeOwnedFixtureRoot(testName: "testA")
        defer { Self.cleanupFixtureDirectory(fixtureRoot) }

        let sink = try DiagnosticDiskSink(rootDirectoryURL: fixtureRoot, sessionName: "session")
        defer { _ = sink.abort() }

        // Raw chunks with NUL bytes, high ASCII, and arbitrary byte sequences
        let stdoutChunk1 = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let stdoutChunk2 = Data("Standard output message with unicode: 🚀\n".utf8)
        let stderrChunk1 = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00])
        let stderrChunk2 = Data("Standard error diagnostics stream\n".utf8)

        try sink.write(stream: .stdout, data: stdoutChunk1)
        try sink.write(stream: .stdout, data: stdoutChunk2)
        try sink.write(stream: .stderr, data: stderrChunk1)
        try sink.write(stream: .stderr, data: stderrChunk2)

        let expectedStdoutBytes = stdoutChunk1 + stdoutChunk2
        let expectedStderrBytes = stderrChunk1 + stderrChunk2

        // Seal the sink
        let receipt1 = sink.finish()
        #expect(receipt1.isSealed)
        #expect(receipt1.sidecarPublished)
        #expect(receipt1.parentDirectorySynced)
        #expect(receipt1.failure == nil)
        #expect(receipt1.sidecarURL != nil)

        // Idempotent finish call returns same receipt
        let receipt2 = sink.finish()
        #expect(receipt1 == receipt2)

        // Verify accounting on both streams
        #expect(receipt1.stdoutRecord.totalAdmittedBytes == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stdoutRecord.committedBytes == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stdoutRecord.landedUniqueBytes == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stdoutRecord.retainedBytesOnDisk == UInt64(expectedStdoutBytes.count))
        #expect(receipt1.stdoutRecord.discardedBytes == 0)
        #expect(receipt1.stdoutRecord.neverWrittenDiscardedBytes == 0)
        #expect(receipt1.stdoutRecord.retentionTrimmedBytes == 0)
        #expect(receipt1.stdoutRecord.isCompacted == false)
        #expect(receipt1.stdoutRecord.diskPayloadKnown == true)
        #expect(receipt1.stdoutRecord.status == StreamPersistenceStatus.sealed)

        #expect(receipt1.stderrRecord.totalAdmittedBytes == UInt64(expectedStderrBytes.count))
        #expect(receipt1.stderrRecord.committedBytes == UInt64(expectedStderrBytes.count))
        #expect(receipt1.stderrRecord.landedUniqueBytes == UInt64(expectedStderrBytes.count))
        #expect(receipt1.stderrRecord.retainedBytesOnDisk == UInt64(expectedStderrBytes.count))
        #expect(receipt1.stderrRecord.discardedBytes == 0)

        // Verify real on-disk files match exact raw bytes byte-for-byte
        let stdoutOnDisk = try Data(contentsOf: receipt1.directoryURL.appendingPathComponent("stdout.bin"))
        let stderrOnDisk = try Data(contentsOf: receipt1.directoryURL.appendingPathComponent("stderr.bin"))
        #expect(stdoutOnDisk == expectedStdoutBytes)
        #expect(stderrOnDisk == expectedStderrBytes)

        // Verify sidecar contents
        guard let sidecarURL = receipt1.sidecarURL else {
            Issue.record("Missing sidecar URL in receipt")
            return
        }
        let sidecarData = try Data(contentsOf: sidecarURL)
        let decoder = JSONDecoder()
        let sidecar = try decoder.decode(DiagnosticPersistenceSidecar.self, from: sidecarData)
        #expect(sidecar.sinkSessionId == receipt1.sessionId)
        #expect(sidecar.formatVersion == DiagnosticPersistenceSidecar.currentFormatVersion)
        #expect(sidecar.stdoutRecord.retainedBytesOnDisk == UInt64(expectedStdoutBytes.count))
        #expect(sidecar.stderrRecord.retainedBytesOnDisk == UInt64(expectedStderrBytes.count))
        #expect(sidecar.stdoutRecord.committedBytes == UInt64(expectedStdoutBytes.count))
        #expect(sidecar.stderrRecord.committedBytes == UInt64(expectedStderrBytes.count))
        #expect(sidecar.isSealed)
        #expect(sidecar.finalOutcome == "success")
        #expect(receipt1.sessionDevice != 0)
        #expect(receipt1.sessionInode != 0)
    }

    // MARK: - Test B: Reproducing Case 1 - Honest Accounting Across Compaction, Append & Second Compaction

    @Test("Test B: Case 1 - First 600 / cap 500 / head 100 / tail 200 exact 300 retained bytes and honest never-written middle accounting")
    func testReproducingCase1_ExactRetainedAndNeverWrittenMiddleCompaction() throws {
        let fixtureRoot = try Self.makeOwnedFixtureRoot(testName: "testB")
        defer { Self.cleanupFixtureDirectory(fixtureRoot) }

        // Bounded configuration: maxBytesPerStream = 500, headBudget = 100, tailBudget = 200
        let config = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxChunkBytes: 65536,
            tailTrimThreshold: 200
        )

        let sink = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "session",
            configuration: config
        )
        defer { _ = sink.abort() }

        // Step 1: First chunk of 600 unique bytes (> cap 500)
        let first600 = Data((0..<600).map { UInt8($0 % 256) })
        try sink.write(stream: .stdout, data: first600)

        let fileURL = sink.directoryURL.appendingPathComponent("stdout.bin")

        // Invariant checks after first chunk:
        let diskDataStep1 = try Data(contentsOf: fileURL)
        #expect(diskDataStep1.count == 300)
        #expect(diskDataStep1.prefix(100) == first600.prefix(100))
        #expect(diskDataStep1.suffix(200) == first600.suffix(200))

        // Step 2: Subsequent append of 50 bytes (300 + 50 = 350 <= 500, under-cap append)
        let append50 = Data((0..<50).map { UInt8(($0 + 100) % 256) })
        try sink.write(stream: .stdout, data: append50)

        let diskDataStep2 = try Data(contentsOf: fileURL)
        #expect(diskDataStep2.count == 350)
        #expect(diskDataStep2.prefix(100) == first600.prefix(100))
        #expect(diskDataStep2.suffix(50) == append50)

        // Step 3: Second compaction with 200 bytes (350 + 200 = 550 > 500, triggers second compaction)
        let append200 = Data((0..<200).map { UInt8(($0 + 200) % 256) })
        try sink.write(stream: .stdout, data: append200)

        let diskDataStep3 = try Data(contentsOf: fileURL)
        #expect(diskDataStep3.count == 300)
        #expect(diskDataStep3.prefix(100) == first600.prefix(100)) // Startup head is preserved verbatim!
        #expect(diskDataStep3.suffix(200) == append200)           // Recent tail is preserved!

        let receipt = sink.finish()
        #expect(receipt.stdoutRecord.totalAdmittedBytes == 850) // 600 + 50 + 200
        #expect(receipt.stdoutRecord.retainedBytesOnDisk == 300)
        #expect(receipt.stdoutRecord.retainedHeadBytes == 100)
        #expect(receipt.stdoutRecord.retainedTailBytes == 200)
        #expect(receipt.stdoutRecord.neverWrittenDiscardedBytes == 300) // From first 600 chunk
        #expect(receipt.stdoutRecord.retentionTrimmedBytes == 250)      // Trimmed during second compaction
        #expect(receipt.stdoutRecord.discardedBytes == 550)            // 300 + 250
        #expect(receipt.stdoutRecord.landedUniqueBytes == 550)         // 850 - 300
        #expect(receipt.stdoutRecord.committedBytes == 550)            // Matches landedUniqueBytes
        #expect(receipt.stdoutRecord.isCompacted == true)
        #expect(receipt.stdoutRecord.diskPayloadKnown == true)
        #expect(receipt.stdoutRecord.physicalRewriteBytes >= 500)
    }

    // MARK: - Test C: Configuration Validation

    @Test("Test C: Configuration validation rejects negative, zero, overflow, and huge allocations")
    func testConfigurationValidation() {
        // Negative / zero maxBytesPerStream
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxBytesPerStream: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxBytesPerStream: -10)
        }

        // Head budget <= 0 or > 50 MiB
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(headBudget: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(headBudget: 51 * 1024 * 1024)
        }

        // Tail budget <= 0 or > 50 MiB
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(tailBudget: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(tailBudget: 51 * 1024 * 1024)
        }

        // Max chunk bytes <= 0 or > 64 KiB
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxChunkBytes: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxChunkBytes: 65_537)
        }

        // Max sidecar bytes <= 0 or > 1 MiB
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxSidecarBytes: 0)
        }
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(maxSidecarBytes: 2 * 1024 * 1024)
        }

        // maxBytesPerStream insufficient for headBudget + tailBudget
        #expect(throws: DiagnosticDiskSinkConfigurationError.self) {
            _ = try DiagnosticDiskSinkConfiguration(
                maxBytesPerStream: 1000,
                headBudget: 600,
                tailBudget: 500
            )
        }
    }

    // MARK: - Test D: Reproducing Cases 2-5 - Fault Injection, Partial Progress & Ownership State Machine

    @Test("Test D: Reproducing Cases 2 to 5 - Suffix 37-byte progress, ambiguous failure, single close attempt, preserved temp file, and targeted faults")
    func testReproducingCases2to5_DeterministicFaultsAndOwnershipStateMachine() throws {
        let fixtureRoot = try Self.makeOwnedFixtureRoot(testName: "testD")
        defer { Self.cleanupFixtureDirectory(fixtureRoot) }

        let configSmall = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxChunkBytes: 65536,
            tailTrimThreshold: 200
        )

        // Case 2a: Suffix partial write 37 bytes then error -> matches actual 137-byte file on disk
        let partialSuffixAdapter = MockFaultInjectingFileAdapter()
        partialSuffixAdapter.failOnWriteInvocation = 2
        partialSuffixAdapter.failOnWriteCommittedBytes = 37

        let sinkPartialSuffix = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "suffix-37-fail",
            configuration: configSmall,
            fileAdapter: partialSuffixAdapter
        )

        let chunk600 = Data((0..<600).map { UInt8($0 % 256) })
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkPartialSuffix.write(stream: .stdout, data: chunk600)
        }

        let receiptPartialSuffix = sinkPartialSuffix.abort()
        #expect(receiptPartialSuffix.stdoutRecord.landedUniqueBytes == 137)
        #expect(receiptPartialSuffix.stdoutRecord.physicalWriteBytes == 137)
        #expect(receiptPartialSuffix.stdoutRecord.retainedBytesOnDisk == 137)
        #expect(receiptPartialSuffix.stdoutRecord.retainedHeadBytes == 100)
        #expect(receiptPartialSuffix.stdoutRecord.retainedTailBytes == 37)
        #expect(receiptPartialSuffix.stdoutRecord.diskPayloadKnown == true)
        #expect(receiptPartialSuffix.stdoutRecord.status == StreamPersistenceStatus.partiallyCompacted)

        let file37 = try Data(contentsOf: sinkPartialSuffix.directoryURL.appendingPathComponent("stdout.bin"))
        #expect(file37.count == 137)
        #expect(file37.prefix(100) == chunk600.prefix(100))
        #expect(file37.suffix(37) == chunk600.suffix(200).prefix(37))

        // Case 2b: Ambiguous suffix progress -> diskPayloadKnown == false
        let ambiguousAdapter = MockFaultInjectingFileAdapter()
        ambiguousAdapter.failOnWriteInvocation = 2
        ambiguousAdapter.failOnWriteAmbiguous = true

        let sinkAmbiguous = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "ambiguous-fail",
            configuration: configSmall,
            fileAdapter: ambiguousAdapter
        )

        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkAmbiguous.write(stream: .stdout, data: chunk600)
        }
        let receiptAmbiguous = sinkAmbiguous.abort()
        #expect(receiptAmbiguous.stdoutRecord.diskPayloadKnown == false)

        // Case 2c: Under-cap partial write progress
        let shortAdapter = MockFaultInjectingFileAdapter()
        shortAdapter.shortWriteLimit = 30

        let sinkShort = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "short-undercap",
            configuration: configSmall,
            fileAdapter: shortAdapter
        )

        let sample50 = Data(repeating: 0x42, count: 50)
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkShort.write(stream: .stdout, data: sample50)
        }
        let receiptShort = sinkShort.abort()
        #expect(receiptShort.stdoutRecord.retainedBytesOnDisk == 30)
        #expect(receiptShort.stdoutRecord.landedUniqueBytes == 30)
        #expect(receiptShort.stdoutRecord.diskPayloadKnown == true)
        let fileShort = try Data(contentsOf: sinkShort.directoryURL.appendingPathComponent("stdout.bin"))
        #expect(fileShort.count == 30)

        // Case 3: Simulate close consumed fd error -> exactly ONE close attempt per descriptor
        let closeFailAdapter = MockFaultInjectingFileAdapter()
        closeFailAdapter.failOnCloseFileName = ".persistence.json.tmp"

        let sinkCloseFail = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "close-fail",
            configuration: configSmall,
            fileAdapter: closeFailAdapter
        )
        try sinkCloseFail.write(stream: .stdout, data: Data("Testing close fail\n".utf8))

        let receiptClose = sinkCloseFail.finish()
        #expect(receiptClose.metadataRecord.closeOutcome != StageOutcome.succeeded)

        var foundTmp = false
        for (name, count) in closeFailAdapter.closeAttemptsByResource {
            if name.contains(".persistence.json.tmp") {
                foundTmp = true
                #expect(count == 1, "Expected exactly 1 close attempt for \(name), got \(count)")
            }
        }
        #expect(foundTmp, "Expected tmp sidecar descriptor to be registered and closed")

        // Case 4: Precreate .persistence.json.tmp.<chosen-sessionId> AFTER setup
        // finish must reject safely, preserve its bytes, report create failure and not claim an unlink of it.
        let precreateSessionId = UUID()
        let sinkPrecreate = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "precreate-tmp-test",
            sessionId: precreateSessionId,
            configuration: configSmall
        )

        let foreignTmpName = ".persistence.json.tmp.\(precreateSessionId.uuidString)"
        let foreignTmpURL = sinkPrecreate.directoryURL.appendingPathComponent(foreignTmpName)
        let foreignPayload = Data("FOREIGN_TEMP_PAYLOAD_MUST_BE_PRESERVED".utf8)
        try foreignPayload.write(to: foreignTmpURL)

        let receiptPrecreate = sinkPrecreate.finish()
        #expect(receiptPrecreate.sidecarPublished == false)
        if case let .failed(op, errno, _) = receiptPrecreate.metadataRecord.createOutcome {
            #expect(op == .open)
            #expect(errno == EEXIST)
        } else {
            Issue.record("Expected createOutcome to be failed with EEXIST, got \(receiptPrecreate.metadataRecord.createOutcome)")
        }

        #expect(FileManager.default.fileExists(atPath: foreignTmpURL.path))
        let remainingForeignBytes = try Data(contentsOf: foreignTmpURL)
        #expect(remainingForeignBytes == foreignPayload)

        // Case 5: Fixed targeted fault rows
        // 5a. Payload truncate fault
        let truncateFailAdapter = MockFaultInjectingFileAdapter()
        truncateFailAdapter.failOnTruncate = true
        let sinkTruncate = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "truncate-fault",
            configuration: configSmall,
            fileAdapter: truncateFailAdapter
        )
        #expect(throws: DiagnosticDiskSinkError.self) {
            try sinkTruncate.write(stream: .stdout, data: chunk600)
        }
        let receiptTruncate = sinkTruncate.abort()
        if case let .failed(op, errno, _) = receiptTruncate.stdoutRecord.compactionOutcome {
            #expect(op == .truncate)
            #expect(errno == EIO)
        } else {
            Issue.record("Expected truncate compactionOutcome failure")
        }

        // 5b. Publish collision: destination persistence.json already exists
        let publishCollisionSink = try DiagnosticDiskSink(
            rootDirectoryURL: fixtureRoot,
            sessionName: "publish-collision"
        )
        let targetSidecarURL = publishCollisionSink.directoryURL.appendingPathComponent("persistence.json")
        let foreignSidecarBytes = Data("FOREIGN_PERSISTENCE_SIDECAR".utf8)
        try foreignSidecarBytes.write(to: targetSidecarURL)

        let receiptPublish = publishCollisionSink.finish()
        #expect(!receiptPublish.sidecarPublished)
        if case let .failed(op, errno, _) = receiptPublish.metadataRecord.publishOutcome {
            #expect(op == .rename)
            #expect(errno == EEXIST)
        } else {
            Issue.record("Expected publishOutcome to fail with EEXIST")
        }
        let preservedSidecar = try Data(contentsOf: targetSidecarURL)
        #expect(preservedSidecar == foreignSidecarBytes)

        // 5c. Setup cleanup error reporting (via descriptor close error on cleanup)
        let setupCleanupFailAdapter = MockFaultInjectingFileAdapter()
        setupCleanupFailAdapter.failOnOpenFileName = "stderr.bin"
        setupCleanupFailAdapter.failOnCloseFileName = "stdout.bin"

        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: fixtureRoot, sessionName: "setup-cleanup-fail", fileAdapter: setupCleanupFailAdapter)
            Issue.record("Expected setup failure")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, cleanup) {
            if case let .ioError(operation, code, _, _) = primary {
                #expect(operation == .open)
                #expect(code == EACCES)
            } else { Issue.record("Lost primary open failure") }
            #expect(cleanup != nil)
        }
    }

    // MARK: - Test E: Reproducing Case 6 - Symlink Rejection & Existing Session Directory Rejection

    @Test("Test E: Case 6 - Real owned-fixture ancestor symlinks, final symlinks, existing-session rejection, and chunk policies")
    func testReproducingCase6_RealFixtureSymlinksAndExistingSessionRejection() throws {
        let fixtureRoot = try Self.makeOwnedFixtureRoot(testName: "testE")
        defer { Self.cleanupFixtureDirectory(fixtureRoot) }

        // 1. Real ancestor symlink rejection
        let realAncestorDir = fixtureRoot.appendingPathComponent("real-ancestor", isDirectory: true)
        try FileManager.default.createDirectory(at: realAncestorDir, withIntermediateDirectories: true)
        chmod(realAncestorDir.path, 0o700)
        let symlinkAncestorDir = fixtureRoot.appendingPathComponent("symlink-ancestor")
        try FileManager.default.createSymbolicLink(at: symlinkAncestorDir, withDestinationURL: realAncestorDir)

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: symlinkAncestorDir, sessionName: "child")
        }

        // 2. Real final session symlink rejection
        let realTargetDir = fixtureRoot.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: realTargetDir, withIntermediateDirectories: true)
        chmod(realTargetDir.path, 0o700)
        let symlinkChild = fixtureRoot.appendingPathComponent("symlink-child")
        try FileManager.default.createSymbolicLink(at: symlinkChild, withDestinationURL: realTargetDir)

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: symlinkChild)
        }

        // 3. Existing session directory collision rejection
        let existingSessionDir = fixtureRoot.appendingPathComponent("existing-session", isDirectory: true)
        try FileManager.default.createDirectory(at: existingSessionDir, withIntermediateDirectories: true)
        chmod(existingSessionDir.path, 0o700)
        let canaryFile = existingSessionDir.appendingPathComponent("canary.txt")
        try Data("CANARY_PAYLOAD".utf8).write(to: canaryFile)

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(directoryURL: existingSessionDir)
        }

        #expect(FileManager.default.fileExists(atPath: existingSessionDir.path))
        #expect(FileManager.default.fileExists(atPath: canaryFile.path))
        let canaryContent = try String(contentsOf: canaryFile, encoding: .utf8)
        #expect(canaryContent == "CANARY_PAYLOAD")

        // 4. Chunk validation policies
        let validSink = try DiagnosticDiskSink(rootDirectoryURL: fixtureRoot, sessionName: "chunk-policies")
        defer { _ = validSink.abort() }

        #expect(throws: DiagnosticDiskSinkError.emptyChunk) {
            try validSink.write(stream: .stdout, data: Data())
        }

        let oversizedData = Data(repeating: 0xAA, count: 65_537)
        #expect(throws: DiagnosticDiskSinkError.self) {
            try validSink.write(stream: .stdout, data: oversizedData)
        }
    }

    // MARK: - Regressions: Progress and Cleanup

    @Test("Partial candidate: head/suffix returned and thrown progress, ambiguous head, repeated compaction failure")
    func testRemainingProgressRegressions() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "remaining-progress")
        defer { Self.cleanupFixtureDirectory(root) }
        let config = try DiagnosticDiskSinkConfiguration(maxBytesPerStream: 500, headBudget: 100, tailBudget: 200, tailTrimThreshold: 200)
        let chunk = Data((0..<600).map { UInt8($0 % 251) })

        for row in 0..<5 {
            let adapter = MockFaultInjectingFileAdapter()
            if row == 0 { adapter.failOnWriteInvocation = 1; adapter.failOnWriteCommittedBytes = 37 }
            if row == 1 { adapter.throwShortWriteOnInvocation = 1 }
            if row == 2 { adapter.throwShortWriteOnInvocation = 2 }
            if row == 3 { adapter.failOnWriteInvocation = 1; adapter.failOnWriteAmbiguous = true }
            if row == 4 { adapter.failOnTruncate = true }
            let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "row-\(row)", configuration: config, fileAdapter: adapter)
            defer { _ = sink.abort() }
            #expect(throws: DiagnosticDiskSinkError.self) { try sink.write(stream: .stdout, data: chunk) }
            let record = sink.abort().stdoutRecord
            if row <= 2 {
                let expected = row == 2 ? 137 : 37
                let bytes = try Data(contentsOf: sink.directoryURL.appendingPathComponent("stdout.bin"))
                #expect(record.diskPayloadKnown)
                #expect(record.retainedBytesOnDisk == UInt64(expected))
                #expect(record.landedUniqueBytes == UInt64(expected))
                #expect(record.physicalWriteBytes == UInt64(expected))
                #expect(bytes.count == expected)
                #expect(bytes.prefix(min(100, expected)) == chunk.prefix(min(100, expected)))
            } else {
                #expect(!record.diskPayloadKnown)
            }
            #expect(record.compactionOutcome != .succeeded)
        }
        let underAdapter = MockFaultInjectingFileAdapter()
        underAdapter.throwShortWriteOnInvocation = 1
        let under = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "under", configuration: config, fileAdapter: underAdapter)
        defer { _ = under.abort() }
        #expect(throws: DiagnosticDiskSinkError.self) { try under.write(stream: .stdout, data: Data(chunk.prefix(50))) }
        let underRecord = under.abort().stdoutRecord
        #expect(underRecord.landedUniqueBytes == 37)
        #expect(underRecord.retainedBytesOnDisk == 37)
        #expect(underRecord.diskPayloadKnown)

        let repeatAdapter = MockFaultInjectingFileAdapter()
        let repeated = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "repeat", configuration: config, fileAdapter: repeatAdapter)
        defer { _ = repeated.abort() }
        try repeated.write(stream: .stdout, data: chunk)
        repeatAdapter.failOnSeek = true
        #expect(throws: DiagnosticDiskSinkError.self) { try repeated.write(stream: .stdout, data: chunk) }
        let repeatedRecord = repeated.abort().stdoutRecord
        if case let .failed(operation, _, _) = repeatedRecord.compactionOutcome {
            #expect(operation == .seek)
        } else { Issue.record("Second compaction failure was not recorded") }
        #expect(!repeatedRecord.diskPayloadKnown)
    }

    @Test("Partial candidate: metadata primary and cleanup failures stay separate; payload sync and close outcomes; no deletion")
    func testRemainingCleanupRegressions() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "remaining-cleanup")
        defer { Self.cleanupFixtureDirectory(root) }
        for row in 0..<3 {
            let adapter = MockFaultInjectingFileAdapter()
            if row == 0 {
                adapter.failOnWriteInvocation = 1
                adapter.failOnWriteCommittedBytes = 0
                adapter.failOnCloseFileName = ".persistence.json.tmp"
            } else {
                adapter.failOnSyncFileName = ".persistence.json.tmp"
                adapter.failOnCloseFileName = ".persistence.json.tmp"
            }
            let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "metadata-\(row)", fileAdapter: adapter)
            defer { _ = sink.abort() }
            let receipt = sink.finish()
            #expect(receipt.failure != nil)
            #expect(receipt.cleanupError != nil)
            #expect(!receipt.sidecarPublished)
            if row == 0 { #expect(receipt.metadataRecord.writeOutcome != .succeeded) }
            else { #expect(receipt.metadataRecord.syncOutcome != .succeeded) }
            #expect(receipt.metadataRecord.closeOutcome != .notAttempted)
            for (name, count) in adapter.closeAttemptsByResource where name.contains(".persistence.json.tmp") {
                #expect(count == 1)
            }
            // Ensure no deletion calls were made for own objects
            #expect(adapter.unlinkInvocationCount == 0)
            #expect(adapter.removeDirectoryInvocationCount == 0)
        }
        let setupAdapter = MockFaultInjectingFileAdapter()
        setupAdapter.failOnCloseInvocation = 1
        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "traversal", fileAdapter: setupAdapter)
            Issue.record("Traversal close failure must fail setup")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            if case .setupFailed = primary {} else {
                if case let .ioError(operation, _, _, _) = primary {
                    #expect(operation == .close)
                } else { Issue.record("Lost traversal close error") }
            }
        }
        let directoryAdapter = MockFaultInjectingFileAdapter()
        directoryAdapter.failOnDirectorySync = true
        let directorySink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "directory-sync", fileAdapter: directoryAdapter)
        defer { _ = directorySink.abort() }
        let directoryReceipt = directorySink.finish()
        #expect(directoryReceipt.sidecarPublished)
        #expect(!directoryReceipt.parentDirectorySynced)
        #expect(directoryReceipt.metadataRecord.directorySyncOutcome != .succeeded)
        let adapter = MockFaultInjectingFileAdapter()
        adapter.failOnSyncFileName = "stdout.bin"
        adapter.failOnCloseFileName = "stdout.bin"
        let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "payload", fileAdapter: adapter)
        defer { _ = sink.abort() }
        let receipt = sink.finish()
        #expect(receipt.stdoutRecord.syncOutcome != .succeeded)
        #expect(receipt.stdoutRecord.closeOutcome != .succeeded)
        #expect(adapter.closeAttemptsByResource["stdout.bin"] == 1)
    }

    // MARK: - Phase T: Platform Security & Root Ownership Rejection Rows

    @Test("Ownership Rejection: Group-writable (0770), world-writable (0777), untrusted owner, allow-write ACE, inheritable allow ACE, untrusted ancestor, compliant deny-delete ACE")
    func testOwnershipRejectionRows() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "rejection-rows")
        defer { Self.cleanupFixtureDirectory(root) }

        // 1. Group-writable root (0770) fails closed
        let groupWritableDir = root.appendingPathComponent("group-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: groupWritableDir, withIntermediateDirectories: true)
        chmod(groupWritableDir.path, 0o770)

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: groupWritableDir, sessionName: "gw-session")
        }

        // 2. World-writable root (0777) fails closed
        let worldWritableDir = root.appendingPathComponent("world-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: worldWritableDir, withIntermediateDirectories: true)
        chmod(worldWritableDir.path, 0o777)

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: worldWritableDir, sessionName: "ww-session")
        }

        // 3. Untrusted owner (uid != 0 && uid != euid) fails closed
        let untrustedOwnerAdapter = MockFaultInjectingFileAdapter()
        untrustedOwnerAdapter.statHandler = { fd in
            var sb = Darwin.stat()
            _ = Darwin.fstat(fd, &sb)
            sb.st_uid = 9999 // Untrusted UID
            return sb
        }
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "bad-owner", fileAdapter: untrustedOwnerAdapter)
        }

        // 4. Root with allow-write ACE fails closed
        let aclAllowDir = root.appendingPathComponent("acl-allow-write", isDirectory: true)
        try FileManager.default.createDirectory(at: aclAllowDir, withIntermediateDirectories: true)
        chmod(aclAllowDir.path, 0o700)
        if let allowAcl = Self.makeAllowWriteAcl() {
            defer { acl_free(UnsafeMutableRawPointer(allowAcl)) }
            let setRc = acl_set_file(aclAllowDir.path, ACL_TYPE_EXTENDED, allowAcl)
            if setRc == 0 {
                #expect(throws: DiagnosticDiskSinkError.self) {
                    _ = try DiagnosticDiskSink(rootDirectoryURL: aclAllowDir, sessionName: "acl-allow-test")
                }
            }
        }

        // 5. Inheritable allow-write ACE causes child verification to fail closed
        let inheritAllowAdapter = MockFaultInjectingFileAdapter()
        inheritAllowAdapter.aclHandler = { fd in
            // Return allow ACL on child inspection
            let acl = Self.makeAllowWriteAcl()
            return (acl, 0)
        }
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "inherit-allow-test", fileAdapter: inheritAllowAdapter)
        }

        // 6. Writable ancestor above compliant root fails closed
        let ancestorParent = root.appendingPathComponent("untrusted-ancestor", isDirectory: true)
        let compliantChildRoot = ancestorParent.appendingPathComponent("compliant-root", isDirectory: true)
        try FileManager.default.createDirectory(at: compliantChildRoot, withIntermediateDirectories: true)
        chmod(compliantChildRoot.path, 0o700)
        chmod(ancestorParent.path, 0o777) // Insecure ancestor

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: compliantChildRoot, sessionName: "insecure-ancestor-test")
        }

        // 7. Compliant root WITH deny-delete ACE passes
        let denyDeleteDir = root.appendingPathComponent("deny-delete-root", isDirectory: true)
        try FileManager.default.createDirectory(at: denyDeleteDir, withIntermediateDirectories: true)
        chmod(denyDeleteDir.path, 0o700)
        if let denyAcl = Self.makeDenyDeleteAcl() {
            defer { acl_free(UnsafeMutableRawPointer(denyAcl)) }
            let setRc = acl_set_file(denyDeleteDir.path, ACL_TYPE_EXTENDED, denyAcl)
            if setRc == 0 {
                let compliantSink = try DiagnosticDiskSink(rootDirectoryURL: denyDeleteDir, sessionName: "deny-delete-pass")
                defer { _ = compliantSink.abort() }
                let receipt = compliantSink.finish()
                #expect(receipt.isSealed)
                #expect(receipt.sidecarPublished)
            }
        }
    }

    // MARK: - Phase T: Child Verification Rows

    @Test("Child Verification: Substituted child owner, wrong mode, or allow ACL fails closed")
    func testChildVerificationRows() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "child-verify")
        defer { Self.cleanupFixtureDirectory(root) }

        // 1. Child owner mismatch (uid != euid)
        let wrongOwnerAdapter = MockFaultInjectingFileAdapter()
        wrongOwnerAdapter.mockChildStat = {
            var sb = Darwin.stat()
            sb.st_mode = S_IFDIR | 0o700
            sb.st_uid = 9999
            return sb
        }()
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "child-bad-owner", fileAdapter: wrongOwnerAdapter)
        }

        // 2. Child mode mismatch (not 0700)
        let wrongModeAdapter = MockFaultInjectingFileAdapter()
        wrongModeAdapter.mockChildStat = {
            var sb = Darwin.stat()
            sb.st_mode = S_IFDIR | 0o755 // Group/other readable/executable
            sb.st_uid = geteuid()
            return sb
        }()
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "child-bad-mode", fileAdapter: wrongModeAdapter)
        }
    }

    // MARK: - Phase T: Storage Admission & Ledger Rows

    @Test("Storage Admission: Budget enforcement, exact ledger release, distinct root keys, abandoned dir scan, concurrency limit, and scan entry cap")
    func testStorageAdmissionAndLedgerRows() throws {
        let rootA = try Self.makeOwnedFixtureRoot(testName: "admission-rootA")
        let rootB = try Self.makeOwnedFixtureRoot(testName: "admission-rootB")
        defer {
            Self.cleanupFixtureDirectory(rootA)
            Self.cleanupFixtureDirectory(rootB)
        }

        DiagnosticDiskSinkStorageLedger.shared.resetForTesting()

        // 1. Storage budget exceeded fails closed
        let tightConfig = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxSidecarBytes: 1000,
            maxStorageBudgetPerRoot: 10_000 // 10 KiB budget
        )
        let overBudgetAdapter = MockFaultInjectingFileAdapter()
        overBudgetAdapter.mockDirectoryUsage = 9_000 // 9,000 + reservation (~68 KiB) > 10,000

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(
                rootDirectoryURL: rootA,
                sessionName: "over-budget",
                configuration: tightConfig,
                fileAdapter: overBudgetAdapter
            )
        }

        // 2. Once-only release proven across initializer failure, finish, abort, and deinit
        var sbA = Darwin.stat()
        let fdA = Darwin.open(rootA.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(fdA) }
        _ = Darwin.fstat(fdA, &sbA)
        let rootIdA = DiagnosticDiskSinkStorageLedger.RootIdentifier(dev: sbA.st_dev, ino: sbA.st_ino)

        // (a) Initializer failure releases reservation
        let initFailAdapter = MockFaultInjectingFileAdapter()
        initFailAdapter.mockChildStat = {
            var sb = Darwin.stat()
            sb.st_mode = S_IFDIR | 0o777
            sb.st_uid = geteuid()
            return sb
        }()
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "init-fail", fileAdapter: initFailAdapter)
        }
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)

        // (b) Finish releases reservation once
        let finishSink = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "finish-release")
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) > 0)
        _ = finishSink.finish()
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)
        _ = finishSink.finish() // Idempotent finish does not double-release or underflow
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)

        // (c) Abort releases reservation once
        let abortSink = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "abort-release")
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) > 0)
        _ = abortSink.abort()
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)
        _ = abortSink.abort() // Idempotent abort does not underflow
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)

        // (d) Deinit releases reservation if not explicitly sealed
        do {
            let scopedSink = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "deinit-release")
            #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) > 0)
            _ = scopedSink
        }
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) == 0)

        // 3. Ledger keys distinct roots by (dev, ino)
        var sbB = Darwin.stat()
        let fdB = Darwin.open(rootB.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(fdB) }
        _ = Darwin.fstat(fdB, &sbB)
        let rootIdB = DiagnosticDiskSinkStorageLedger.RootIdentifier(dev: sbB.st_dev, ino: sbB.st_ino)

        let sinkA = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "session-rootA")
        defer { _ = sinkA.abort() }
        let sinkB = try DiagnosticDiskSink(rootDirectoryURL: rootB, sessionName: "session-rootB")
        defer { _ = sinkB.abort() }

        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdA) > 0)
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdB) > 0)

        // 4. Abandoned fixture dir counted in subsequent scan
        let abandonedSink = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "abandoned-session")
        let payload10k = Data(repeating: 0x55, count: 10_000)
        try abandonedSink.write(stream: .stdout, data: payload10k)
        _ = abandonedSink.abort() // Session is abandoned on disk!

        let subsequentSink = try DiagnosticDiskSink(rootDirectoryURL: rootA, sessionName: "subsequent-session")
        defer { _ = subsequentSink.abort() }
        #expect(subsequentSink.initialScannedUsage >= 10_000)

        // 5. Concurrent in-process admissions cannot exceed budget
        let rootConc = try Self.makeOwnedFixtureRoot(testName: "conc-root")
        defer { Self.cleanupFixtureDirectory(rootConc) }
        var sbConc = Darwin.stat()
        let fdConc = Darwin.open(rootConc.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(fdConc) }
        _ = Darwin.fstat(fdConc, &sbConc)
        let rootIdConc = DiagnosticDiskSinkStorageLedger.RootIdentifier(dev: sbConc.st_dev, ino: sbConc.st_ino)

        let moderateConfig = try DiagnosticDiskSinkConfiguration(
            maxBytesPerStream: 500,
            headBudget: 100,
            tailBudget: 200,
            maxSidecarBytes: 1000,
            maxStorageBudgetPerRoot: 100_000 // 100 KiB budget; each session reserves ~68 KiB
        )
        let concSink1 = try DiagnosticDiskSink(rootDirectoryURL: rootConc, sessionName: "conc1", configuration: moderateConfig)
        // Second concurrent session in same root exceeds budget
        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: rootConc, sessionName: "conc2", configuration: moderateConfig)
        }
        _ = concSink1.finish()

        // After conc1 finishes and releases reservation, conc3 succeeds
        let concSink3 = try DiagnosticDiskSink(rootDirectoryURL: rootConc, sessionName: "conc3", configuration: moderateConfig)
        defer { _ = concSink3.abort() }
        #expect(DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootIdConc) > 0)

        // 6. Scan respects maxRootScanEntries
        let rootCap = try Self.makeOwnedFixtureRoot(testName: "cap-root")
        defer { Self.cleanupFixtureDirectory(rootCap) }
        let scanAdapter = MockFaultInjectingFileAdapter()
        var scannedMaxEntries = 0
        scanAdapter.scanUsageHandler = { dirFd, maxEntries in
            scannedMaxEntries = maxEntries
            return 100
        }
        let capConfig = try DiagnosticDiskSinkConfiguration(maxRootScanEntries: 42)
        let capSink = try DiagnosticDiskSink(rootDirectoryURL: rootCap, sessionName: "cap-test", configuration: capConfig, fileAdapter: scanAdapter)
        defer { _ = capSink.abort() }
        #expect(scannedMaxEntries == 42)
    }

    @Test("Storage admission fails closed when root entry count exceeds maxRootScanEntries")
    func testStorageAdmissionScanCapFailsClosed() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "capfail-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let sessionName = "capfail-session"
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("a.bin").path, contents: Data(repeating: 0x41, count: 64))
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("b.bin").path, contents: Data(repeating: 0x42, count: 64))

        let tinyCap = try DiagnosticDiskSinkConfiguration(maxRootScanEntries: 1)
        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: sessionName, configuration: tinyCap)
            Issue.record("Expected scan to fail closed on entry-count cap")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            guard case .storageScanIncomplete = primary else {
                Issue.record("Expected storageScanIncomplete as primary error, got \(primary)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionName).path))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Storage admission accepts exactly-at-cap root entry count")
    func testStorageAdmissionExactlyAtCapSucceeds() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "atcap-root")
        defer { Self.cleanupFixtureDirectory(root) }
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("a.bin").path, contents: Data(repeating: 0x41, count: 64))
        _ = FileManager.default.createFile(atPath: root.appendingPathComponent("b.bin").path, contents: Data(repeating: 0x42, count: 64))

        let cap = try DiagnosticDiskSinkConfiguration(maxRootScanEntries: 2)
        let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "atcap-session", configuration: cap)
        _ = sink.abort()
    }

    @Test("Storage admission accepts session child with exactly 64 accounted entries")
    func testStorageAdmissionChildExactlyAtBoundarySucceeds() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "child64-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let abandoned = root.appendingPathComponent("abandoned-session")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        for i in 0..<64 {
            _ = FileManager.default.createFile(atPath: abandoned.appendingPathComponent("f\(i).bin").path, contents: Data(repeating: 0x43, count: 8))
        }

        let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "child64-session")
        _ = sink.abort()
    }

    @Test("Storage admission fails closed when session child exceeds 64 accounted entries")
    func testStorageAdmissionChildBoundaryExceededFailsClosed() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "child65-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let sessionName = "child65-session"
        let abandoned = root.appendingPathComponent("abandoned-session")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        for i in 0..<65 {
            _ = FileManager.default.createFile(atPath: abandoned.appendingPathComponent("f\(i).bin").path, contents: Data(repeating: 0x44, count: 8))
        }

        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: sessionName)
            Issue.record("Expected scan to fail closed on child entry boundary")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            guard case .storageScanIncomplete = primary else {
                Issue.record("Expected storageScanIncomplete as primary error, got \(primary)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionName).path))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Storage admission fails closed on nested directory deeper than accounted layout")
    func testStorageAdmissionNestedDirectoryFailsClosed() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "nested-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let sessionName = "nestedfail-session"
        let abandoned = root.appendingPathComponent("abandoned-session")
        try FileManager.default.createDirectory(at: abandoned.appendingPathComponent("nested"), withIntermediateDirectories: true)

        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: sessionName)
            Issue.record("Expected scan to fail closed on nested directory")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            guard case .storageScanIncomplete = primary else {
                Issue.record("Expected storageScanIncomplete as primary error, got \(primary)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionName).path))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Storage admission rejects injected incomplete scan")
    func testStorageAdmissionRejectsIncompleteScanResult() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "incomplete-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let sessionName = "incomplete-session"
        let scanAdapter = MockFaultInjectingFileAdapter()
        scanAdapter.scanUsageHandler = { _, _ in
            throw DiagnosticDiskSinkError.storageScanIncomplete(reason: "injected truncation")
        }

        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: sessionName, fileAdapter: scanAdapter)
            Issue.record("Expected admission to reject an incomplete scan")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            guard case .storageScanIncomplete = primary else {
                Issue.record("Expected storageScanIncomplete as primary error, got \(primary)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionName).path))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Storage admission rejects injected scan read error")
    func testStorageAdmissionRejectsScanReadError() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "scanerr-root")
        defer { Self.cleanupFixtureDirectory(root) }
        let sessionName = "scanerr-session"
        let scanAdapter = MockFaultInjectingFileAdapter()
        scanAdapter.scanUsageHandler = { _, _ in
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: EIO, message: "injected read failure")
        }

        do {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: sessionName, fileAdapter: scanAdapter)
            Issue.record("Expected admission to reject a scan read error")
        } catch let DiagnosticDiskSinkError.setupFailed(primary, _) {
            guard case .ioError = primary else {
                Issue.record("Expected ioError as primary error, got \(primary)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionName).path))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Phase T: Local Volume Check

    @Test("Local Volume Check: Non-local filesystem (e.g. NFS / SMB) fails closed with unsupportedFilesystem")
    func testLocalVolumeFilesystemCheck() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "nfs-root")
        defer { Self.cleanupFixtureDirectory(root) }

        let nfsAdapter = MockFaultInjectingFileAdapter()
        nfsAdapter.mockStatfsTypeName = "nfs"
        nfsAdapter.mockStatfsFlags = 0 // Does NOT include MNT_LOCAL

        #expect(throws: DiagnosticDiskSinkError.self) {
            _ = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "nfs-session", fileAdapter: nfsAdapter)
        }
    }

    // MARK: - Phase T: No-Deletion Storage Contract

    @Test("Storage Policy: Failed/aborted sessions abandon files without deletion; descriptors closed once; foreign files preserved")
    func testNoDeletionContract() throws {
        let root = try Self.makeOwnedFixtureRoot(testName: "no-deletion")
        defer { Self.cleanupFixtureDirectory(root) }

        let adapter = MockFaultInjectingFileAdapter()
        let sink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "abort-abandon", fileAdapter: adapter)

        let testData = Data(repeating: 0x41, count: 500)
        try sink.write(stream: .stdout, data: testData)

        let sessionDirURL = sink.directoryURL
        let stdoutFileURL = sessionDirURL.appendingPathComponent("stdout.bin")

        // Abort sink
        let receipt = sink.abort()
        #expect(receipt.isSealed)

        // Verify that NO unlink or rmdir operations were performed!
        #expect(adapter.unlinkInvocationCount == 0)
        #expect(adapter.removeDirectoryInvocationCount == 0)

        // Verify session directory and payload files are completely abandoned on disk
        #expect(FileManager.default.fileExists(atPath: sessionDirURL.path))
        #expect(FileManager.default.fileExists(atPath: stdoutFileURL.path))
        let abandonedBytes = try Data(contentsOf: stdoutFileURL)
        #expect(abandonedBytes == testData)

        // Verify sidecar tmp failure abandons tmp sidecar file without unlinking
        let sidecarFailAdapter = MockFaultInjectingFileAdapter()
        sidecarFailAdapter.failOnPublish = true
        sidecarFailAdapter.publishErrno = EIO

        let sidecarSink = try DiagnosticDiskSink(rootDirectoryURL: root, sessionName: "sidecar-abandon", fileAdapter: sidecarFailAdapter)
        let sidecarReceipt = sidecarSink.finish()
        #expect(!sidecarReceipt.sidecarPublished)
        #expect(sidecarFailAdapter.unlinkInvocationCount == 0)
        #expect(sidecarFailAdapter.removeDirectoryInvocationCount == 0)

        // Descriptors were closed exactly once
        #expect(sidecarFailAdapter.closeAttemptsByResource["stdout.bin"] == 1)
        #expect(sidecarFailAdapter.closeAttemptsByResource["stderr.bin"] == 1)
    }
}
