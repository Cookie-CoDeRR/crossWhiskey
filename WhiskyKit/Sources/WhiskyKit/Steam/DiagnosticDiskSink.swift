//
//  DiagnosticDiskSink.swift
//  WhiskyKit
//
//  Isolated bounded disk sink and persistence receipt for diagnostic captures.
//  Preserves raw binary byte streams under cap and executes bounded in-place
//  compaction with observable failure and two-phase sidecar publication.
//

import Darwin
import Foundation

// MARK: - Configuration & Validation

public enum DiagnosticDiskSinkConfigurationError: Error, Equatable, Sendable {
    case invalidMaxBytesPerStream(Int64)
    case invalidHeadBudget(Int)
    case invalidTailBudget(Int)
    case invalidMaxChunkBytes(Int)
    case invalidTailTrimThreshold(Int)
    case invalidMaxSidecarBytes(Int)
    case budgetArithmeticOverflow
    case maxBytesInsufficientForHeadAndTail(maxBytes: Int64, requiredMinimum: Int64)
}

public struct DiagnosticDiskSinkConfiguration: Sendable, Equatable {
    public static let defaultMaxBytesPerStream: Int64 = 20 * 1024 * 1024   // 20 MiB per stream (Wine.maxLogFileBytes policy)
    public static let defaultHeadBudget: Int = 4 * 1024 * 1024            // 4 MiB startup head
    public static let defaultTailBudget: Int = 12 * 1024 * 1024           // 12 MiB recent tail target
    public static let defaultMaxChunkBytes: Int = 65_536                  // 64 KiB matching reader & ingress chunk ceiling
    public static let defaultTailTrimThreshold: Int = 16 * 1024 * 1024    // 16 MiB lazy trim boundary
    public static let defaultMaxSidecarBytes: Int = 65_536                // 64 KiB sidecar hard limit
    public static let discardMarkerOverheadEstimate: Int = 128            // Bounded discard notice allocation inside cap

    public let maxBytesPerStream: Int64
    public let headBudget: Int
    public let tailBudget: Int
    public let maxChunkBytes: Int
    public let tailTrimThreshold: Int
    public let maxSidecarBytes: Int

    public init(
        maxBytesPerStream: Int64 = defaultMaxBytesPerStream,
        headBudget: Int = defaultHeadBudget,
        tailBudget: Int = defaultTailBudget,
        maxChunkBytes: Int = defaultMaxChunkBytes,
        tailTrimThreshold: Int? = nil,
        maxSidecarBytes: Int = defaultMaxSidecarBytes
    ) throws {
        guard maxBytesPerStream > 0 && maxBytesPerStream <= 100 * 1024 * 1024 else {
            throw DiagnosticDiskSinkConfigurationError.invalidMaxBytesPerStream(maxBytesPerStream)
        }
        guard headBudget > 0 && headBudget <= 50 * 1024 * 1024 else {
            throw DiagnosticDiskSinkConfigurationError.invalidHeadBudget(headBudget)
        }
        guard tailBudget > 0 && tailBudget <= 50 * 1024 * 1024 else {
            throw DiagnosticDiskSinkConfigurationError.invalidTailBudget(tailBudget)
        }
        guard maxChunkBytes > 0 && maxChunkBytes <= 65_536 else {
            throw DiagnosticDiskSinkConfigurationError.invalidMaxChunkBytes(maxChunkBytes)
        }
        guard maxSidecarBytes > 0 && maxSidecarBytes <= 1_048_576 else {
            throw DiagnosticDiskSinkConfigurationError.invalidMaxSidecarBytes(maxSidecarBytes)
        }

        let (budgetSum, overflow) = headBudget.addingReportingOverflow(tailBudget)
        guard !overflow else {
            throw DiagnosticDiskSinkConfigurationError.budgetArithmeticOverflow
        }
        let (requiredTotal, totalOverflow) = budgetSum.addingReportingOverflow(Self.discardMarkerOverheadEstimate)
        guard !totalOverflow else {
            throw DiagnosticDiskSinkConfigurationError.budgetArithmeticOverflow
        }

        let requiredMinimum = Int64(requiredTotal)
        guard maxBytesPerStream >= requiredMinimum else {
            throw DiagnosticDiskSinkConfigurationError.maxBytesInsufficientForHeadAndTail(
                maxBytes: maxBytesPerStream,
                requiredMinimum: requiredMinimum
            )
        }

        let resolvedTailTrimThreshold = tailTrimThreshold ?? max(tailBudget, tailBudget + maxChunkBytes * 4)
        guard resolvedTailTrimThreshold >= tailBudget && resolvedTailTrimThreshold <= 100 * 1024 * 1024 else {
            throw DiagnosticDiskSinkConfigurationError.invalidTailTrimThreshold(resolvedTailTrimThreshold)
        }

        self.maxBytesPerStream = maxBytesPerStream
        self.headBudget = headBudget
        self.tailBudget = tailBudget
        self.maxChunkBytes = maxChunkBytes
        self.tailTrimThreshold = resolvedTailTrimThreshold
        self.maxSidecarBytes = maxSidecarBytes
    }

    public static let `default`: DiagnosticDiskSinkConfiguration = {
        try! DiagnosticDiskSinkConfiguration()
    }()
}

// MARK: - Error Types & Operation Codes

public enum IOOperation: String, Sendable, Codable, Equatable {
    case directoryCheck
    case directoryCreate
    case fileCheck
    case open
    case write
    case seek
    case truncate
    case sync
    case close
    case rename
    case directorySync
    case cleanup
}

public enum DiagnosticDiskSinkError: Error, Sendable, Equatable {
    case directoryError(String)
    case symlinkRejected(String)
    case fileCollision(String)
    case emptyChunk
    case oversizedChunk(byteCount: Int, maxChunkBytes: Int)
    case sealed
    case ioError(operation: IOOperation, errno: Int32, message: String)
    case sidecarTooLarge(byteCount: Int, maxBytes: Int)
}

// MARK: - Stream & Persistence Status

public enum StreamPersistenceStatus: String, Sendable, Codable, Equatable {
    case active
    case sealed
    case partiallyCompacted
    case failed
}

public struct StreamDiskRecord: Sendable, Codable, Equatable {
    public let stream: DiagnosticStreamKind
    public let fileName: String
    public let totalAdmittedBytes: UInt64
    public let committedBytes: UInt64
    public let retainedBytesOnDisk: UInt64
    public let discardEvents: Int
    public let discardedBytes: UInt64
    public let isCompacted: Bool
    public let status: StreamPersistenceStatus
    public let lastErrorCode: Int32?
    public let lastFailedOperation: IOOperation?

    public init(
        stream: DiagnosticStreamKind,
        fileName: String,
        totalAdmittedBytes: UInt64,
        committedBytes: UInt64,
        retainedBytesOnDisk: UInt64,
        discardEvents: Int,
        discardedBytes: UInt64,
        isCompacted: Bool,
        status: StreamPersistenceStatus,
        lastErrorCode: Int32?,
        lastFailedOperation: IOOperation?
    ) {
        self.stream = stream
        self.fileName = fileName
        self.totalAdmittedBytes = totalAdmittedBytes
        self.committedBytes = committedBytes
        self.retainedBytesOnDisk = retainedBytesOnDisk
        self.discardEvents = discardEvents
        self.discardedBytes = discardedBytes
        self.isCompacted = isCompacted
        self.status = status
        self.lastErrorCode = lastErrorCode
        self.lastFailedOperation = lastFailedOperation
    }
}

// MARK: - Versioned Persistence Sidecar

public struct DiagnosticPersistenceSidecar: Sendable, Codable, Equatable {
    public static let currentFormatVersion: Int = 1

    public let formatVersion: Int
    public let sinkSessionId: UUID
    public let stdoutRecord: StreamDiskRecord
    public let stderrRecord: StreamDiskRecord
    public let maxBytesPerStream: Int64
    public let headBudget: Int
    public let tailBudget: Int
    public let isSealed: Bool
    public let finalOutcome: String

    public init(
        formatVersion: Int = currentFormatVersion,
        sinkSessionId: UUID,
        stdoutRecord: StreamDiskRecord,
        stderrRecord: StreamDiskRecord,
        maxBytesPerStream: Int64,
        headBudget: Int,
        tailBudget: Int,
        isSealed: Bool,
        finalOutcome: String
    ) {
        self.formatVersion = formatVersion
        self.sinkSessionId = sinkSessionId
        self.stdoutRecord = stdoutRecord
        self.stderrRecord = stderrRecord
        self.maxBytesPerStream = maxBytesPerStream
        self.headBudget = headBudget
        self.tailBudget = tailBudget
        self.isSealed = isSealed
        self.finalOutcome = finalOutcome
    }
}

// MARK: - Immutable Terminal Receipt

public struct DiagnosticDiskSinkReceipt: Sendable, Equatable {
    public let sessionId: UUID
    public let directoryURL: URL
    public let stdoutRecord: StreamDiskRecord
    public let stderrRecord: StreamDiskRecord
    public let sidecarPublished: Bool
    public let sidecarURL: URL?
    public let parentDirectorySynced: Bool
    public let isSealed: Bool
    public let failure: DiagnosticDiskSinkError?
    public let hasCounterOverflow: Bool

    public init(
        sessionId: UUID,
        directoryURL: URL,
        stdoutRecord: StreamDiskRecord,
        stderrRecord: StreamDiskRecord,
        sidecarPublished: Bool,
        sidecarURL: URL?,
        parentDirectorySynced: Bool,
        isSealed: Bool,
        failure: DiagnosticDiskSinkError?,
        hasCounterOverflow: Bool
    ) {
        self.sessionId = sessionId
        self.directoryURL = directoryURL
        self.stdoutRecord = stdoutRecord
        self.stderrRecord = stderrRecord
        self.sidecarPublished = sidecarPublished
        self.sidecarURL = sidecarURL
        self.parentDirectorySynced = parentDirectorySynced
        self.isSealed = isSealed
        self.failure = failure
        self.hasCounterOverflow = hasCounterOverflow
    }
}

// MARK: - Injectable File Operation Adapter

public protocol DiskSinkFileAdapter: AnyObject, Sendable {
    func open(path: String, flags: Int32, mode: mode_t) throws -> Int32
    func write(fd: Int32, data: Data) throws -> Int
    func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t
    func truncate(fd: Int32, length: off_t) throws
    func sync(fd: Int32) throws
    func close(fd: Int32) throws
    func rename(from: String, to: String) throws
    func syncDirectory(path: String) throws
    func fileExists(path: String) -> Bool
    func isDirectory(path: String) -> Bool
    func isSymbolicLink(path: String) -> Bool
    func createDirectory(path: String, mode: mode_t) throws
    func removeItem(path: String) throws
}

public final class POSIXDiskSinkFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    public init() {}

    public func open(path: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let fd = Darwin.open(path, flags, mode)
        if fd < 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .open, errno: err, message: "open failed: \(err)")
        }
        return fd
    }

    public func write(fd: Int32, data: Data) throws -> Int {
        guard !data.isEmpty else { return 0 }
        return try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            var writtenTotal = 0
            while writtenTotal < data.count {
                let remaining = data.count - writtenTotal
                let ptr = baseAddress.advanced(by: writtenTotal)
                let result = Darwin.write(fd, ptr, remaining)
                if result < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw DiagnosticDiskSinkError.ioError(operation: .write, errno: err, message: "write failed: \(err)")
                }
                if result == 0 {
                    // Short write or zero bytes accepted
                    break
                }
                writtenTotal += result
            }
            return writtenTotal
        }
    }

    public func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t {
        let result = Darwin.lseek(fd, offset, whence)
        if result == -1 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .seek, errno: err, message: "lseek failed: \(err)")
        }
        return result
    }

    public func truncate(fd: Int32, length: off_t) throws {
        let result = Darwin.ftruncate(fd, length)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .truncate, errno: err, message: "ftruncate failed: \(err)")
        }
    }

    public func sync(fd: Int32) throws {
        // Darwin fcntl(F_FULLFSYNC) requests a hardware barrier when supported; falls back to fsync
        if Darwin.fcntl(fd, F_FULLFSYNC) == -1 {
            if Darwin.fsync(fd) != 0 {
                let err = errno
                throw DiagnosticDiskSinkError.ioError(operation: .sync, errno: err, message: "fsync failed: \(err)")
            }
        }
    }

    public func close(fd: Int32) throws {
        let result = Darwin.close(fd)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .close, errno: err, message: "close failed: \(err)")
        }
    }

    public func rename(from: String, to: String) throws {
        let result = Darwin.rename(from, to)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .rename, errno: err, message: "rename failed: \(err)")
        }
    }

    public func syncDirectory(path: String) throws {
        let dirFd = Darwin.open(path, O_RDONLY)
        guard dirFd >= 0 else {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directorySync, errno: err, message: "open directory failed: \(err)")
        }
        defer { _ = Darwin.close(dirFd) }
        if Darwin.fsync(dirFd) != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directorySync, errno: err, message: "fsync directory failed: \(err)")
        }
    }

    public func fileExists(path: String) -> Bool {
        var statBuf = stat()
        return Darwin.lstat(path, &statBuf) == 0
    }

    public func isDirectory(path: String) -> Bool {
        var statBuf = stat()
        if Darwin.lstat(path, &statBuf) == 0 {
            return (statBuf.st_mode & S_IFMT) == S_IFDIR
        }
        return false
    }

    public func isSymbolicLink(path: String) -> Bool {
        var statBuf = stat()
        if Darwin.lstat(path, &statBuf) == 0 {
            return (statBuf.st_mode & S_IFMT) == S_IFLNK
        }
        return false
    }

    public func createDirectory(path: String, mode: mode_t) throws {
        let result = Darwin.mkdir(path, mode)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCreate, errno: err, message: "mkdir failed: \(err)")
        }
    }

    public func removeItem(path: String) throws {
        var statBuf = stat()
        if Darwin.lstat(path, &statBuf) == 0 {
            if (statBuf.st_mode & S_IFMT) == S_IFDIR {
                if Darwin.rmdir(path) != 0 {
                    let err = errno
                    throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: err, message: "rmdir failed: \(err)")
                }
            } else {
                if Darwin.unlink(path) != 0 {
                    let err = errno
                    throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: err, message: "unlink failed: \(err)")
                }
            }
        }
    }
}

// MARK: - Stream State Container

private final class StreamState {
    let stream: DiagnosticStreamKind
    let fileName: String
    var fd: Int32 = -1
    var totalAdmittedBytes: UInt64 = 0
    var committedBytes: UInt64 = 0
    var retainedBytesOnDisk: UInt64 = 0
    var discardEvents: Int = 0
    var discardedBytes: UInt64 = 0
    var isCompacted: Bool = false
    var status: StreamPersistenceStatus = .active
    var lastErrorCode: Int32? = nil
    var lastFailedOperation: IOOperation? = nil

    // In-memory retention buffers
    var headBuffer = Data()
    var headComplete = false
    var tailBuffer = Data()

    init(stream: DiagnosticStreamKind, fileName: String) {
        self.stream = stream
        self.fileName = fileName
    }

    func toRecord() -> StreamDiskRecord {
        StreamDiskRecord(
            stream: stream,
            fileName: fileName,
            totalAdmittedBytes: totalAdmittedBytes,
            committedBytes: committedBytes,
            retainedBytesOnDisk: retainedBytesOnDisk,
            discardEvents: discardEvents,
            discardedBytes: discardedBytes,
            isCompacted: isCompacted,
            status: status,
            lastErrorCode: lastErrorCode,
            lastFailedOperation: lastFailedOperation
        )
    }
}

// MARK: - Synchronous Single-Owner Diagnostic Disk Sink

/// Synchronous, single-owner disk sink for diagnostic stdout and stderr capture.
///
/// **Threading Contract**: This sink is synchronous and NOT internally thread-safe.
/// A single calling owner (such as a dedicated serial queue or state machine) must
/// serialize all invocations of `write` and `finish`. Disk I/O operations must NEVER
/// run directly on pipe reader callback queues.
public final class DiagnosticDiskSink: @unchecked Sendable {
    public let sessionId: UUID
    public let directoryURL: URL
    public let configuration: DiagnosticDiskSinkConfiguration
    private let fileAdapter: DiskSinkFileAdapter

    private var streams: [DiagnosticStreamKind: StreamState]
    private var isSealed: Bool = false
    private var terminalReceipt: DiagnosticDiskSinkReceipt?
    private var activeError: DiagnosticDiskSinkError?
    private var hasCounterOverflow: Bool = false

    // Resource tracking for bounded cleanup
    private var createdDirectory: Bool = false
    private var createdFilePaths: Set<String> = []

    public init(
        directoryURL: URL,
        sessionId: UUID = UUID(),
        configuration: DiagnosticDiskSinkConfiguration = .default,
        fileAdapter: DiskSinkFileAdapter = POSIXDiskSinkFileAdapter()
    ) throws {
        self.sessionId = sessionId
        self.directoryURL = directoryURL
        self.configuration = configuration
        self.fileAdapter = fileAdapter

        let stdoutState = StreamState(stream: .stdout, fileName: "stdout.bin")
        let stderrState = StreamState(stream: .stderr, fileName: "stderr.bin")
        self.streams = [
            .stdout: stdoutState,
            .stderr: stderrState
        ]

        try setupDirectoryAndFiles()
    }

    // MARK: - Setup & Validation

    private func setupDirectoryAndFiles() throws {
        let dirPath = directoryURL.path

        if fileAdapter.isSymbolicLink(path: dirPath) {
            let error = DiagnosticDiskSinkError.symlinkRejected("Directory path is a symbolic link: \(dirPath)")
            self.activeError = error
            throw error
        }

        if fileAdapter.fileExists(path: dirPath) {
            if !fileAdapter.isDirectory(path: dirPath) {
                let error = DiagnosticDiskSinkError.directoryError("Path exists and is not a directory: \(dirPath)")
                self.activeError = error
                throw error
            }
        } else {
            do {
                try fileAdapter.createDirectory(path: dirPath, mode: 0o700)
                self.createdDirectory = true
            } catch let err as DiagnosticDiskSinkError {
                self.activeError = err
                throw err
            } catch {
                let wrapped = DiagnosticDiskSinkError.directoryError("Failed to create session directory: \(error)")
                self.activeError = wrapped
                throw wrapped
            }
        }

        // Verify destination files and sidecars do NOT collide
        let expectedFiles = ["stdout.bin", "stderr.bin", "persistence.json"]
        for file in expectedFiles {
            let filePath = directoryURL.appendingPathComponent(file).path
            if fileAdapter.fileExists(path: filePath) {
                let error = DiagnosticDiskSinkError.fileCollision("File collision detected; target already exists: \(filePath)")
                self.activeError = error
                cleanupCreatedResourcesOnSetupFailure()
                throw error
            }
        }

        // Open payload stream files with exclusive creation
        do {
            for streamKind in DiagnosticStreamKind.allCases {
                guard let state = streams[streamKind] else { continue }
                let filePath = directoryURL.appendingPathComponent(state.fileName).path
                let fd = try fileAdapter.open(path: filePath, flags: O_RDWR | O_CREAT | O_EXCL, mode: 0o600)
                state.fd = fd
                createdFilePaths.insert(filePath)
            }
        } catch let err as DiagnosticDiskSinkError {
            self.activeError = err
            cleanupCreatedResourcesOnSetupFailure()
            throw err
        } catch {
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .open, errno: EIO, message: "\(error)")
            self.activeError = wrapped
            cleanupCreatedResourcesOnSetupFailure()
            throw wrapped
        }
    }

    private func cleanupCreatedResourcesOnSetupFailure() {
        for path in createdFilePaths {
            // Close if open
            for state in streams.values where directoryURL.appendingPathComponent(state.fileName).path == path {
                if state.fd >= 0 {
                    _ = try? fileAdapter.close(fd: state.fd)
                    state.fd = -1
                }
            }
            _ = try? fileAdapter.removeItem(path: path)
        }
        createdFilePaths.removeAll()

        if createdDirectory {
            _ = try? fileAdapter.removeItem(path: directoryURL.path)
            createdDirectory = false
        }
    }

    // MARK: - Synchronous Ingress Writing

    /// Writes raw chunk bytes for the given stream.
    ///
    /// - Parameters:
    ///   - stream: Target stream (.stdout or .stderr)
    ///   - data: Raw chunk bytes (must be <= maxChunkBytes and non-empty)
    /// - Throws: `DiagnosticDiskSinkError` if rejected, sealed, or on disk I/O failure.
    public func write(stream: DiagnosticStreamKind, data: Data) throws {
        if isSealed {
            throw DiagnosticDiskSinkError.sealed
        }
        if let err = activeError {
            throw err
        }
        guard !data.isEmpty else {
            throw DiagnosticDiskSinkError.emptyChunk
        }
        guard data.count <= configuration.maxChunkBytes else {
            throw DiagnosticDiskSinkError.oversizedChunk(byteCount: data.count, maxChunkBytes: configuration.maxChunkBytes)
        }
        guard let state = streams[stream] else {
            throw DiagnosticDiskSinkError.sealed
        }

        // Account admitted bytes with saturating overflow detection
        let (newAdmitted, admittedOverflow) = state.totalAdmittedBytes.addingReportingOverflow(UInt64(data.count))
        if admittedOverflow {
            hasCounterOverflow = true
            state.totalAdmittedBytes = UInt64.max
        } else {
            state.totalAdmittedBytes = newAdmitted
        }

        let prospectiveDiskBytes = Int64(state.retainedBytesOnDisk) + Int64(data.count)
        if prospectiveDiskBytes <= configuration.maxBytesPerStream {
            try writeUnderCap(state: state, data: data)
        } else {
            try compactAndWrite(state: state, incomingChunk: data)
        }
    }

    // MARK: - Under-Cap Appending

    private func writeUnderCap(state: StreamState, data: Data) throws {
        do {
            let written = try fileAdapter.write(fd: state.fd, data: data)
            state.committedBytes += UInt64(written)
            state.retainedBytesOnDisk += UInt64(written)

            if written < data.count {
                // Short write: partial data landed on disk
                state.status = .failed
                let shortError = DiagnosticDiskSinkError.ioError(
                    operation: .write,
                    errno: ENOSPC,
                    message: "Short write: wrote \(written) of \(data.count) bytes"
                )
                failClosed(error: shortError, state: state, operation: .write, errno: ENOSPC)
                throw shortError
            }

            // Track in-memory buffers for potential future compaction
            trackInMemory(state: state, data: data)
        } catch let err as DiagnosticDiskSinkError {
            if case let .ioError(op, code, _) = err {
                failClosed(error: err, state: state, operation: op, errno: code)
            } else {
                failClosed(error: err, state: state, operation: .write, errno: EIO)
            }
            throw err
        } catch {
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .write, errno: EIO, message: "\(error)")
            failClosed(error: wrapped, state: state, operation: .write, errno: EIO)
            throw wrapped
        }
    }

    // MARK: - Bounded Compaction

    private func compactAndWrite(state: StreamState, incomingChunk: Data) throws {
        state.discardEvents += 1

        // Ingest incomingChunk into rolling tail buffer
        state.tailBuffer.append(incomingChunk)

        let headCount = state.headBuffer.count
        let totalAdmitted = state.totalAdmittedBytes

        // Estimate marker length to calculate available suffix budget
        // Target: headCount + markerCount + suffixCount <= maxBytesPerStream
        let availableForMarkerAndTail = max(0, Int(configuration.maxBytesPerStream) - headCount)
        let maxAllowedTail = max(0, min(configuration.tailBudget, availableForMarkerAndTail - ConfigurationConstants.markerEstimate))

        let suffixCount = min(state.tailBuffer.count, maxAllowedTail)
        let discardedBytes = totalAdmitted > UInt64(headCount + suffixCount)
            ? totalAdmitted - UInt64(headCount + suffixCount)
            : 0

        state.discardedBytes = discardedBytes

        // Build exact discard marker
        let markerString = "\n--- [DIAGNOSTIC RETENTION: \(discardedBytes) BYTES DISCARDED (EVENT \(state.discardEvents))] ---\n"
        let markerData = markerString.data(using: .utf8) ?? Data(markerString.utf8)

        // Ensure head + marker + suffix strictly fits inside maxBytesPerStream
        var finalSuffixCount = suffixCount
        if headCount + markerData.count + finalSuffixCount > Int(configuration.maxBytesPerStream) {
            finalSuffixCount = max(0, Int(configuration.maxBytesPerStream) - headCount - markerData.count)
        }

        let suffixData: Data
        if finalSuffixCount > 0 {
            suffixData = state.tailBuffer.suffix(finalSuffixCount)
        } else {
            suffixData = Data()
        }

        // Execute in-place compaction:
        // 1. Truncate file to headCount first, bounding disk usage immediately
        // 2. Seek to headCount
        // 3. Write markerData
        // 4. Write suffixData
        do {
            _ = try fileAdapter.seek(fd: state.fd, offset: off_t(headCount), whence: SEEK_SET)
            try fileAdapter.truncate(fd: state.fd, length: off_t(headCount))
            state.retainedBytesOnDisk = UInt64(headCount)

            let markerWritten = try fileAdapter.write(fd: state.fd, data: markerData)
            state.committedBytes += UInt64(markerWritten)
            state.retainedBytesOnDisk += UInt64(markerWritten)
            if markerWritten < markerData.count {
                throw DiagnosticDiskSinkError.ioError(operation: .write, errno: ENOSPC, message: "Short write while writing discard marker")
            }

            if !suffixData.isEmpty {
                let suffixWritten = try fileAdapter.write(fd: state.fd, data: suffixData)
                state.committedBytes += UInt64(suffixWritten)
                state.retainedBytesOnDisk += UInt64(suffixWritten)
                if suffixWritten < suffixData.count {
                    throw DiagnosticDiskSinkError.ioError(operation: .write, errno: ENOSPC, message: "Short write while writing compacted tail")
                }
            }

            state.isCompacted = true
            state.tailBuffer = suffixData
        } catch let err as DiagnosticDiskSinkError {
            state.status = .partiallyCompacted
            if case let .ioError(op, code, _) = err {
                failClosed(error: err, state: state, operation: op, errno: code)
            } else {
                failClosed(error: err, state: state, operation: .write, errno: EIO)
            }
            throw err
        } catch {
            state.status = .partiallyCompacted
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .write, errno: EIO, message: "\(error)")
            failClosed(error: wrapped, state: state, operation: .write, errno: EIO)
            throw wrapped
        }
    }

    private func trackInMemory(state: StreamState, data: Data) {
        if !state.headComplete {
            let roomInHead = configuration.headBudget - state.headBuffer.count
            if roomInHead >= data.count {
                state.headBuffer.append(data)
            } else {
                state.headBuffer.append(data.prefix(roomInHead))
                state.headComplete = true
            }
        }

        state.tailBuffer.append(data)
        if state.tailBuffer.count > configuration.tailTrimThreshold {
            let excess = state.tailBuffer.count - configuration.tailBudget
            state.tailBuffer.removeFirst(excess)
        }
    }

    private func failClosed(error: DiagnosticDiskSinkError, state: StreamState, operation: IOOperation, errno: Int32) {
        self.activeError = error
        state.status = (state.status == .partiallyCompacted) ? .partiallyCompacted : .failed
        state.lastFailedOperation = operation
        state.lastErrorCode = errno
    }

    // MARK: - Sealing & Finish

    /// Seals the sink, flushes and closes stream files, publishes the versioned sidecar, and returns an immutable receipt.
    ///
    /// This method is idempotent: subsequent calls return the existing receipt.
    public func finish() -> DiagnosticDiskSinkReceipt {
        if let existing = terminalReceipt {
            return existing
        }

        isSealed = true

        // 1. Flush & sync open streams
        for state in streams.values {
            if state.fd >= 0 {
                do {
                    try fileAdapter.sync(fd: state.fd)
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, _) = err {
                        state.lastFailedOperation = op
                        state.lastErrorCode = code
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .sync, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.lastFailedOperation = .sync
                    state.lastErrorCode = EIO
                    state.status = .failed
                }

                do {
                    try fileAdapter.close(fd: state.fd)
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, _) = err {
                        state.lastFailedOperation = op
                        state.lastErrorCode = code
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .close, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.lastFailedOperation = .close
                    state.lastErrorCode = EIO
                    state.status = .failed
                }
                state.fd = -1
            }

            if state.status == .active {
                state.status = .sealed
            }
        }

        let stdoutRecord = streams[.stdout]?.toRecord() ?? StreamDiskRecord(
            stream: .stdout,
            fileName: "stdout.bin",
            totalAdmittedBytes: 0,
            committedBytes: 0,
            retainedBytesOnDisk: 0,
            discardEvents: 0,
            discardedBytes: 0,
            isCompacted: false,
            status: .failed,
            lastErrorCode: nil,
            lastFailedOperation: nil
        )

        let stderrRecord = streams[.stderr]?.toRecord() ?? StreamDiskRecord(
            stream: .stderr,
            fileName: "stderr.bin",
            totalAdmittedBytes: 0,
            committedBytes: 0,
            retainedBytesOnDisk: 0,
            discardEvents: 0,
            discardedBytes: 0,
            isCompacted: false,
            status: .failed,
            lastErrorCode: nil,
            lastFailedOperation: nil
        )

        // 2. Publish sidecar via temp-file write, sync, close, and rename
        var sidecarPublished = false
        var sidecarURL: URL? = nil
        var parentDirSynced = false

        let sidecar = DiagnosticPersistenceSidecar(
            sinkSessionId: sessionId,
            stdoutRecord: stdoutRecord,
            stderrRecord: stderrRecord,
            maxBytesPerStream: configuration.maxBytesPerStream,
            headBudget: configuration.headBudget,
            tailBudget: configuration.tailBudget,
            isSealed: true,
            finalOutcome: (activeError == nil) ? "clean" : "failed"
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(sidecar)

            if jsonData.count > configuration.maxSidecarBytes {
                throw DiagnosticDiskSinkError.sidecarTooLarge(
                    byteCount: jsonData.count,
                    maxBytes: configuration.maxSidecarBytes
                )
            }

            let tmpFileName = ".persistence.json.tmp.\(sessionId.uuidString)"
            let tmpPath = directoryURL.appendingPathComponent(tmpFileName).path
            let targetPath = directoryURL.appendingPathComponent("persistence.json").path

            let tmpFd = try fileAdapter.open(path: tmpPath, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
            createdFilePaths.insert(tmpPath)

            let written = try fileAdapter.write(fd: tmpFd, data: jsonData)
            if written < jsonData.count {
                _ = try? fileAdapter.close(fd: tmpFd)
                _ = try? fileAdapter.removeItem(path: tmpPath)
                throw DiagnosticDiskSinkError.ioError(operation: .write, errno: ENOSPC, message: "Short write on sidecar")
            }

            try fileAdapter.sync(fd: tmpFd)
            try fileAdapter.close(fd: tmpFd)

            try fileAdapter.rename(from: tmpPath, to: targetPath)
            sidecarPublished = true
            sidecarURL = URL(fileURLWithPath: targetPath)
            createdFilePaths.remove(tmpPath)
            createdFilePaths.insert(targetPath)

            // 3. Best-effort parent directory sync
            do {
                try fileAdapter.syncDirectory(path: directoryURL.path)
                parentDirSynced = true
            } catch {
                parentDirSynced = false
            }
        } catch let err as DiagnosticDiskSinkError {
            if activeError == nil { activeError = err }
        } catch {
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .rename, errno: EIO, message: "\(error)")
            if activeError == nil { activeError = wrapped }
        }

        let receipt = DiagnosticDiskSinkReceipt(
            sessionId: sessionId,
            directoryURL: directoryURL,
            stdoutRecord: stdoutRecord,
            stderrRecord: stderrRecord,
            sidecarPublished: sidecarPublished,
            sidecarURL: sidecarURL,
            parentDirectorySynced: parentDirSynced,
            isSealed: true,
            failure: activeError,
            hasCounterOverflow: hasCounterOverflow
        )

        self.terminalReceipt = receipt
        return receipt
    }
}

private enum ConfigurationConstants {
    static let markerEstimate: Int = 128
}
