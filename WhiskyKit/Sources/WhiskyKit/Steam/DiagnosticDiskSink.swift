//
//  DiagnosticDiskSink.swift
//  WhiskyKit
//
//  Isolated bounded disk sink and persistence receipt for diagnostic captures.
//  Preserves raw binary byte streams without in-band markers or text decoding,
//  executes bounded in-place compaction, enforces directory-anchored descriptors,
//  and publishes an atomic, non-overwriting persistence sidecar.
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

        let requiredMinimum = Int64(budgetSum)
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
    case directoryOpen
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

public enum StageOutcome: Sendable, Codable, Equatable {
    case notAttempted
    case succeeded
    case failed(operation: IOOperation, errno: Int32, message: String)
    case unknown
}

public enum DiagnosticDiskSinkError: Error, Sendable, Equatable {
    case directoryError(String)
    case symlinkRejected(String)
    case fileCollision(String)
    case emptyChunk
    case oversizedChunk(byteCount: Int, maxChunkBytes: Int)
    case sealed
    case ioError(operation: IOOperation, errno: Int32, message: String, bytesCommitted: Int? = nil)
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
    public let retainedHeadBytes: Int
    public let retainedTailBytes: Int
    public let discardEvents: Int
    public let discardedBytes: UInt64
    public let physicalRewriteBytes: UInt64
    public let isCompacted: Bool
    public let status: StreamPersistenceStatus

    // Stage outcomes
    public let openOutcome: StageOutcome
    public let writeOutcome: StageOutcome
    public let compactionOutcome: StageOutcome
    public let syncOutcome: StageOutcome
    public let closeOutcome: StageOutcome

    public init(
        stream: DiagnosticStreamKind,
        fileName: String,
        totalAdmittedBytes: UInt64,
        committedBytes: UInt64,
        retainedBytesOnDisk: UInt64,
        retainedHeadBytes: Int,
        retainedTailBytes: Int,
        discardEvents: Int,
        discardedBytes: UInt64,
        physicalRewriteBytes: UInt64,
        isCompacted: Bool,
        status: StreamPersistenceStatus,
        openOutcome: StageOutcome,
        writeOutcome: StageOutcome,
        compactionOutcome: StageOutcome,
        syncOutcome: StageOutcome,
        closeOutcome: StageOutcome
    ) {
        self.stream = stream
        self.fileName = fileName
        self.totalAdmittedBytes = totalAdmittedBytes
        self.committedBytes = committedBytes
        self.retainedBytesOnDisk = retainedBytesOnDisk
        self.retainedHeadBytes = retainedHeadBytes
        self.retainedTailBytes = retainedTailBytes
        self.discardEvents = discardEvents
        self.discardedBytes = discardedBytes
        self.physicalRewriteBytes = physicalRewriteBytes
        self.isCompacted = isCompacted
        self.status = status
        self.openOutcome = openOutcome
        self.writeOutcome = writeOutcome
        self.compactionOutcome = compactionOutcome
        self.syncOutcome = syncOutcome
        self.closeOutcome = closeOutcome
    }
}

public struct MetadataPublicationRecord: Sendable, Codable, Equatable {
    public var createOutcome: StageOutcome
    public var writeOutcome: StageOutcome
    public var syncOutcome: StageOutcome
    public var closeOutcome: StageOutcome
    public var publishOutcome: StageOutcome
    public var directorySyncOutcome: StageOutcome

    public init(
        createOutcome: StageOutcome = .notAttempted,
        writeOutcome: StageOutcome = .notAttempted,
        syncOutcome: StageOutcome = .notAttempted,
        closeOutcome: StageOutcome = .notAttempted,
        publishOutcome: StageOutcome = .notAttempted,
        directorySyncOutcome: StageOutcome = .notAttempted
    ) {
        self.createOutcome = createOutcome
        self.writeOutcome = writeOutcome
        self.syncOutcome = syncOutcome
        self.closeOutcome = closeOutcome
        self.publishOutcome = publishOutcome
        self.directorySyncOutcome = directorySyncOutcome
    }
}

// MARK: - Versioned Persistence Sidecar

public struct DiagnosticPersistenceSidecar: Sendable, Codable, Equatable {
    public static let currentFormatVersion: Int = 1

    public let formatVersion: Int
    public let sinkSessionId: UUID
    public let stdoutRecord: StreamDiskRecord
    public let stderrRecord: StreamDiskRecord
    public let metadataRecord: MetadataPublicationRecord
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
        metadataRecord: MetadataPublicationRecord,
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
        self.metadataRecord = metadataRecord
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
    public let metadataRecord: MetadataPublicationRecord
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
        metadataRecord: MetadataPublicationRecord,
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
        self.metadataRecord = metadataRecord
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
    func openDirectory(path: String) throws -> Int32
    func createDirectory(path: String, mode: mode_t) throws
    func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32
    func write(fd: Int32, data: Data) throws -> Int
    func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t
    func truncate(fd: Int32, length: off_t) throws
    func sync(fd: Int32) throws
    func close(fd: Int32) throws
    func publishSidecar(dirFd: Int32, tmpName: String, targetName: String) throws
    func syncDirectory(dirFd: Int32) throws
    func unlinkAt(dirFd: Int32, fileName: String) throws
    func removeDirectory(path: String) throws
    func fileExistsAt(dirFd: Int32, fileName: String) -> Bool
    func isDirectory(path: String) -> Bool
    func isSymbolicLink(path: String) -> Bool
    func checkSymlinkAncestors(path: String) -> Bool
}

public final class POSIXDiskSinkFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    public init() {}

    public func openDirectory(path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryOpen, errno: err, message: "open directory failed: \(err)")
        }
        return fd
    }

    public func createDirectory(path: String, mode: mode_t) throws {
        let result = Darwin.mkdir(path, mode)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCreate, errno: err, message: "mkdir failed: \(err)")
        }
    }

    public func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let fd = Darwin.openat(dirFd, fileName, flags | O_NOFOLLOW, mode)
        if fd < 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .open, errno: err, message: "openat failed for \(fileName): \(err)")
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
                    throw DiagnosticDiskSinkError.ioError(
                        operation: .write,
                        errno: err,
                        message: "write failed: \(err)",
                        bytesCommitted: writtenTotal
                    )
                }
                if result == 0 {
                    // Reached zero write (e.g. storage exhaustion)
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

    public func publishSidecar(dirFd: Int32, tmpName: String, targetName: String) throws {
        // Darwin atomic non-overwriting rename using RENAME_EXCL
        let ret = Darwin.renameatx_np(dirFd, tmpName, dirFd, targetName, UInt32(RENAME_EXCL))
        if ret != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .rename, errno: err, message: "renameatx_np failed: \(err)")
        }
    }

    public func syncDirectory(dirFd: Int32) throws {
        if Darwin.fsync(dirFd) != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directorySync, errno: err, message: "fsync directory failed: \(err)")
        }
    }

    public func unlinkAt(dirFd: Int32, fileName: String) throws {
        let ret = Darwin.unlinkat(dirFd, fileName, 0)
        if ret != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: err, message: "unlinkat failed: \(err)")
        }
    }

    public func removeDirectory(path: String) throws {
        let ret = Darwin.rmdir(path)
        if ret != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: err, message: "rmdir failed: \(err)")
        }
    }

    public func fileExistsAt(dirFd: Int32, fileName: String) -> Bool {
        var statBuf = stat()
        return Darwin.fstatat(dirFd, fileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0
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

    public func checkSymlinkAncestors(path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardized
        while current.path != "/" && !current.path.isEmpty {
            var statBuf = stat()
            if Darwin.lstat(current.path, &statBuf) == 0 {
                if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                    return true
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return false
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
    var physicalRewriteBytes: UInt64 = 0
    var isCompacted: Bool = false
    var status: StreamPersistenceStatus = .active

    // Stage outcomes
    var openOutcome: StageOutcome = .notAttempted
    var writeOutcome: StageOutcome = .notAttempted
    var compactionOutcome: StageOutcome = .notAttempted
    var syncOutcome: StageOutcome = .notAttempted
    var closeOutcome: StageOutcome = .notAttempted

    // In-memory retention buffers
    var headBuffer = Data()
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
            retainedHeadBytes: headBuffer.count,
            retainedTailBytes: tailBuffer.count,
            discardEvents: discardEvents,
            discardedBytes: discardedBytes,
            physicalRewriteBytes: physicalRewriteBytes,
            isCompacted: isCompacted,
            status: status,
            openOutcome: openOutcome,
            writeOutcome: writeOutcome,
            compactionOutcome: compactionOutcome,
            syncOutcome: syncOutcome,
            closeOutcome: closeOutcome
        )
    }
}

// MARK: - Synchronous Single-Owner Diagnostic Disk Sink

/// Synchronous, single-owner disk sink for diagnostic stdout and stderr capture.
///
/// **Threading Contract**: This sink is synchronous and NOT internally thread-safe.
/// A single calling owner (such as a dedicated serial queue or state machine) must
/// serialize all invocations of `write`, `abort`, and `finish`. Disk I/O operations must NEVER
/// run directly on pipe reader callback queues.
public final class DiagnosticDiskSink: @unchecked Sendable {
    public let sessionId: UUID
    public let directoryURL: URL
    public let configuration: DiagnosticDiskSinkConfiguration
    private let fileAdapter: DiskSinkFileAdapter

    private var dirFd: Int32 = -1
    private var streams: [DiagnosticStreamKind: StreamState]
    private var isSealed: Bool = false
    private var terminalReceipt: DiagnosticDiskSinkReceipt?
    private var activeError: DiagnosticDiskSinkError?
    private var hasCounterOverflow: Bool = false

    // Metadata stage outcomes
    private var metadataRecord = MetadataPublicationRecord()

    // Resource tracking for bounded cleanup
    private var createdDirectory: Bool = false
    private var createdFileNames: Set<String> = []

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

    deinit {
        // Safe, non-throwing cleanup of still-open descriptors
        for state in streams.values {
            if state.fd >= 0 {
                _ = try? fileAdapter.close(fd: state.fd)
                state.fd = -1
            }
        }
        if dirFd >= 0 {
            _ = try? fileAdapter.close(fd: dirFd)
            dirFd = -1
        }
    }

    // MARK: - Setup & Validation

    private func setupDirectoryAndFiles() throws {
        let dirPath = directoryURL.path

        // Check symlinks along the path
        if fileAdapter.checkSymlinkAncestors(path: dirPath) || fileAdapter.isSymbolicLink(path: dirPath) {
            let error = DiagnosticDiskSinkError.symlinkRejected("Directory path or ancestor is a symbolic link: \(dirPath)")
            self.activeError = error
            throw error
        }

        // Fresh session directory creation or verification
        do {
            try fileAdapter.createDirectory(path: dirPath, mode: 0o700)
            self.createdDirectory = true
        } catch let err as DiagnosticDiskSinkError {
            if case let .ioError(_, errno, _, _) = err, errno == EEXIST {
                // Directory exists: verify it is a valid directory
                if !fileAdapter.isDirectory(path: dirPath) {
                    let error = DiagnosticDiskSinkError.directoryError("Path exists and is not a directory: \(dirPath)")
                    self.activeError = error
                    throw error
                }
            } else {
                self.activeError = err
                throw err
            }
        }

        // Open and anchor on directory descriptor
        do {
            self.dirFd = try fileAdapter.openDirectory(path: dirPath)
        } catch let err as DiagnosticDiskSinkError {
            self.activeError = err
            cleanupCreatedResourcesOnSetupFailure()
            throw err
        } catch {
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .directoryOpen, errno: EIO, message: "\(error)")
            self.activeError = wrapped
            cleanupCreatedResourcesOnSetupFailure()
            throw wrapped
        }

        // Verify destination files do not collide inside directory
        let expectedFiles = ["stdout.bin", "stderr.bin", "persistence.json"]
        for file in expectedFiles {
            if fileAdapter.fileExistsAt(dirFd: dirFd, fileName: file) {
                let error = DiagnosticDiskSinkError.fileCollision("File collision detected; target already exists: \(file)")
                self.activeError = error
                cleanupCreatedResourcesOnSetupFailure()
                throw error
            }
        }

        // Open payload stream files anchored to dirFd
        for streamKind in DiagnosticStreamKind.allCases {
            guard let state = streams[streamKind] else { continue }
            do {
                let fd = try fileAdapter.openAt(dirFd: dirFd, fileName: state.fileName, flags: O_RDWR | O_CREAT | O_EXCL, mode: 0o600)
                state.fd = fd
                state.openOutcome = .succeeded
                createdFileNames.insert(state.fileName)
            } catch let err as DiagnosticDiskSinkError {
                if case let .ioError(op, code, msg, _) = err {
                    state.openOutcome = .failed(operation: op, errno: code, message: msg)
                } else {
                    state.openOutcome = .failed(operation: .open, errno: EACCES, message: "\(err)")
                }
                self.activeError = err
                cleanupCreatedResourcesOnSetupFailure()
                throw err
            } catch {
                let wrapped = DiagnosticDiskSinkError.ioError(operation: .open, errno: EIO, message: "\(error)")
                state.openOutcome = .failed(operation: .open, errno: EIO, message: "\(error)")
                self.activeError = wrapped
                cleanupCreatedResourcesOnSetupFailure()
                throw wrapped
            }
        }
    }

    private func cleanupCreatedResourcesOnSetupFailure() {
        for state in streams.values {
            if state.fd >= 0 {
                _ = try? fileAdapter.close(fd: state.fd)
                state.fd = -1
            }
        }
        for fileName in createdFileNames {
            if dirFd >= 0 {
                _ = try? fileAdapter.unlinkAt(dirFd: dirFd, fileName: fileName)
            }
        }
        createdFileNames.removeAll()

        if dirFd >= 0 {
            _ = try? fileAdapter.close(fd: dirFd)
            dirFd = -1
        }

        if createdDirectory {
            _ = try? fileAdapter.removeDirectory(path: directoryURL.path)
            createdDirectory = false
        }
    }

    // MARK: - Synchronous Ingress Writing

    /// Writes raw chunk bytes for the given stream without any inserted in-band markers or text decoding.
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

        // Ingest into in-memory buffers (preserving startup head before any truncation)
        ingestIntoMemoryBuffers(state: state, chunk: data)

        let prospectiveDiskBytes = Int64(state.retainedBytesOnDisk) + Int64(data.count)
        if prospectiveDiskBytes <= configuration.maxBytesPerStream {
            try writeUnderCap(state: state, data: data)
        } else {
            try compactAndRewrite(state: state)
        }
    }

    private func ingestIntoMemoryBuffers(state: StreamState, chunk: Data) {
        if state.headBuffer.count < configuration.headBudget {
            let roomInHead = configuration.headBudget - state.headBuffer.count
            let headPiece = chunk.prefix(roomInHead)
            state.headBuffer.append(headPiece)

            let tailPiece = chunk.dropFirst(headPiece.count)
            if !tailPiece.isEmpty {
                state.tailBuffer.append(tailPiece)
            }
        } else {
            state.tailBuffer.append(chunk)
        }

        // Lazy trim tailBuffer in memory
        if state.tailBuffer.count > configuration.tailTrimThreshold {
            let excess = state.tailBuffer.count - configuration.tailBudget
            state.tailBuffer.removeFirst(excess)
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
                    message: "Short write: committed \(written) of \(data.count) bytes",
                    bytesCommitted: nil // Already added above
                )
                state.writeOutcome = .failed(operation: .write, errno: ENOSPC, message: "Short write: \(written)/\(data.count)")
                failClosed(error: shortError)
                throw shortError
            }
            state.writeOutcome = .succeeded
        } catch let err as DiagnosticDiskSinkError {
            if case let .ioError(op, code, msg, partial) = err {
                if let partialCount = partial {
                    state.committedBytes += UInt64(partialCount)
                    state.retainedBytesOnDisk += UInt64(partialCount)
                }
                state.writeOutcome = .failed(operation: op, errno: code, message: msg)
            } else {
                state.writeOutcome = .failed(operation: .write, errno: EIO, message: "\(err)")
            }
            state.status = .failed
            failClosed(error: err)
            throw err
        } catch {
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .write, errno: EIO, message: "\(error)")
            state.writeOutcome = .failed(operation: .write, errno: EIO, message: "\(error)")
            state.status = .failed
            failClosed(error: wrapped)
            throw wrapped
        }
    }

    // MARK: - Bounded Compaction Without Markers

    private func compactAndRewrite(state: StreamState) throws {
        state.discardEvents += 1

        let headCount = state.headBuffer.count
        let maxAllowedTail = max(0, min(configuration.tailBudget, Int(configuration.maxBytesPerStream) - headCount))
        let suffixData = Data(state.tailBuffer.suffix(maxAllowedTail))

        // Discarded payload bytes = total admitted - (head + suffix)
        let retainedTotal = UInt64(headCount + suffixData.count)
        if state.totalAdmittedBytes >= retainedTotal {
            state.discardedBytes = state.totalAdmittedBytes - retainedTotal
        }

        // On-disk in-place compaction:
        // 1. Ensure startup head is on disk at offset 0
        // 2. Truncate file to headCount first (drops prior tail)
        // 3. Write suffixData at offset headCount
        do {
            _ = try fileAdapter.seek(fd: state.fd, offset: 0, whence: SEEK_SET)
            let headWritten = try fileAdapter.write(fd: state.fd, data: state.headBuffer)
            if headWritten < headCount {
                throw DiagnosticDiskSinkError.ioError(
                    operation: .write,
                    errno: ENOSPC,
                    message: "Short write while writing head during compaction",
                    bytesCommitted: headWritten
                )
            }
            try fileAdapter.truncate(fd: state.fd, length: off_t(headCount))
            state.retainedBytesOnDisk = UInt64(headCount)

            if !suffixData.isEmpty {
                let suffixWritten = try fileAdapter.write(fd: state.fd, data: suffixData)
                state.physicalRewriteBytes += UInt64(suffixWritten)
                state.retainedBytesOnDisk += UInt64(suffixWritten)

                if suffixWritten < suffixData.count {
                    throw DiagnosticDiskSinkError.ioError(
                        operation: .write,
                        errno: ENOSPC,
                        message: "Short write during compaction: wrote \(suffixWritten)/\(suffixData.count)",
                        bytesCommitted: suffixWritten
                    )
                }
            }

            state.isCompacted = true
            state.tailBuffer = suffixData
            state.committedBytes = state.totalAdmittedBytes
            state.compactionOutcome = .succeeded
        } catch let err as DiagnosticDiskSinkError {
            state.status = .partiallyCompacted
            if case let .ioError(op, code, msg, _) = err {
                state.compactionOutcome = .failed(operation: op, errno: code, message: msg)
            } else {
                state.compactionOutcome = .failed(operation: .write, errno: EIO, message: "\(err)")
            }
            failClosed(error: err)
            throw err
        } catch {
            state.status = .partiallyCompacted
            let wrapped = DiagnosticDiskSinkError.ioError(operation: .write, errno: EIO, message: "\(error)")
            state.compactionOutcome = .failed(operation: .write, errno: EIO, message: "\(error)")
            failClosed(error: wrapped)
            throw wrapped
        }
    }

    private func failClosed(error: DiagnosticDiskSinkError) {
        self.activeError = error
    }

    // MARK: - Explicit Abort / Abandonment

    /// Explicitly aborts the sink, safely closing all owned file and directory descriptors.
    @discardableResult
    public func abort() -> DiagnosticDiskSinkReceipt {
        if let existing = terminalReceipt {
            return existing
        }
        isSealed = true

        for state in streams.values {
            if state.fd >= 0 {
                do {
                    try fileAdapter.close(fd: state.fd)
                    state.closeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        state.closeOutcome = .failed(operation: op, errno: code, message: msg)
                    }
                } catch {
                    state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(error)")
                }
                state.fd = -1
            }
            state.status = .failed
        }

        if dirFd >= 0 {
            _ = try? fileAdapter.close(fd: dirFd)
            dirFd = -1
        }

        let receipt = DiagnosticDiskSinkReceipt(
            sessionId: sessionId,
            directoryURL: directoryURL,
            stdoutRecord: streams[.stdout]?.toRecord() ?? fallbackRecord(stream: .stdout),
            stderrRecord: streams[.stderr]?.toRecord() ?? fallbackRecord(stream: .stderr),
            metadataRecord: metadataRecord,
            sidecarPublished: false,
            sidecarURL: nil,
            parentDirectorySynced: false,
            isSealed: true,
            failure: activeError ?? DiagnosticDiskSinkError.sealed,
            hasCounterOverflow: hasCounterOverflow
        )
        self.terminalReceipt = receipt
        return receipt
    }

    // MARK: - Sealing & Finish

    /// Seals the sink, flushes and closes stream files, publishes the versioned sidecar without overwriting, and returns an immutable receipt.
    public func finish() -> DiagnosticDiskSinkReceipt {
        if let existing = terminalReceipt {
            return existing
        }
        isSealed = true

        // 1. Flush & sync open payload streams
        for state in streams.values {
            if state.fd >= 0 {
                do {
                    try fileAdapter.sync(fd: state.fd)
                    state.syncOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, msg, _) = err {
                        state.syncOutcome = .failed(operation: op, errno: code, message: msg)
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .sync, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.syncOutcome = .failed(operation: .sync, errno: EIO, message: "\(error)")
                    state.status = .failed
                }

                do {
                    try fileAdapter.close(fd: state.fd)
                    state.closeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, msg, _) = err {
                        state.closeOutcome = .failed(operation: op, errno: code, message: msg)
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .close, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(error)")
                    state.status = .failed
                }
                state.fd = -1
            }

            if state.status == .active {
                state.status = .sealed
            }
        }

        let stdoutRecord = streams[.stdout]?.toRecord() ?? fallbackRecord(stream: .stdout)
        let stderrRecord = streams[.stderr]?.toRecord() ?? fallbackRecord(stream: .stderr)

        // 2. Publish sidecar via temp-file write, sync, close, and atomic no-replace publish
        var sidecarPublished = false
        var sidecarURL: URL? = nil
        var parentDirSynced = false

        let sidecar = DiagnosticPersistenceSidecar(
            sinkSessionId: sessionId,
            stdoutRecord: stdoutRecord,
            stderrRecord: stderrRecord,
            metadataRecord: metadataRecord,
            maxBytesPerStream: configuration.maxBytesPerStream,
            headBudget: configuration.headBudget,
            tailBudget: configuration.tailBudget,
            isSealed: true,
            finalOutcome: (activeError == nil) ? "clean" : "failed"
        )

        let tmpFileName = ".persistence.json.tmp.\(sessionId.uuidString)"
        let targetFileName = "persistence.json"

        if dirFd >= 0 {
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

                // Open temporary staging file anchored to dirFd
                let tmpFd = try fileAdapter.openAt(dirFd: dirFd, fileName: tmpFileName, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
                metadataRecord.createOutcome = .succeeded

                // Write and sync sidecar with strict ownership cleanup
                do {
                    let written = try fileAdapter.write(fd: tmpFd, data: jsonData)
                    if written < jsonData.count {
                        throw DiagnosticDiskSinkError.ioError(operation: .write, errno: ENOSPC, message: "Short write on sidecar")
                    }
                    metadataRecord.writeOutcome = .succeeded

                    try fileAdapter.sync(fd: tmpFd)
                    metadataRecord.syncOutcome = .succeeded

                    try fileAdapter.close(fd: tmpFd)
                    metadataRecord.closeOutcome = .succeeded
                } catch {
                    _ = try? fileAdapter.close(fd: tmpFd)
                    _ = try? fileAdapter.unlinkAt(dirFd: dirFd, fileName: tmpFileName)
                    throw error
                }

                // Atomic no-overwrite publish
                do {
                    try fileAdapter.publishSidecar(dirFd: dirFd, tmpName: tmpFileName, targetName: targetFileName)
                    sidecarPublished = true
                    sidecarURL = directoryURL.appendingPathComponent(targetFileName)
                    createdFileNames.insert(targetFileName)
                    metadataRecord.publishOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.publishOutcome = .failed(operation: op, errno: code, message: msg)
                    }
                    throw err
                } catch {
                    metadataRecord.publishOutcome = .failed(operation: .rename, errno: EIO, message: "\(error)")
                    throw error
                }

                // 3. Best-effort directory sync
                do {
                    try fileAdapter.syncDirectory(dirFd: dirFd)
                    parentDirSynced = true
                    metadataRecord.directorySyncOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.directorySyncOutcome = .failed(operation: op, errno: code, message: msg)
                    }
                } catch {
                    metadataRecord.directorySyncOutcome = .failed(operation: .directorySync, errno: EIO, message: "\(error)")
                }
            } catch let err as DiagnosticDiskSinkError {
                if activeError == nil { activeError = err }
                _ = try? fileAdapter.unlinkAt(dirFd: dirFd, fileName: tmpFileName)
            } catch {
                let wrapped = DiagnosticDiskSinkError.ioError(operation: .rename, errno: EIO, message: "\(error)")
                if activeError == nil { activeError = wrapped }
                _ = try? fileAdapter.unlinkAt(dirFd: dirFd, fileName: tmpFileName)
            }

            // Close dirFd on exit
            _ = try? fileAdapter.close(fd: dirFd)
            dirFd = -1
        }

        let receipt = DiagnosticDiskSinkReceipt(
            sessionId: sessionId,
            directoryURL: directoryURL,
            stdoutRecord: stdoutRecord,
            stderrRecord: stderrRecord,
            metadataRecord: metadataRecord,
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

    private func fallbackRecord(stream: DiagnosticStreamKind) -> StreamDiskRecord {
        StreamDiskRecord(
            stream: stream,
            fileName: "\(stream.rawValue).bin",
            totalAdmittedBytes: 0,
            committedBytes: 0,
            retainedBytesOnDisk: 0,
            retainedHeadBytes: 0,
            retainedTailBytes: 0,
            discardEvents: 0,
            discardedBytes: 0,
            physicalRewriteBytes: 0,
            isCompacted: false,
            status: .failed,
            openOutcome: .notAttempted,
            writeOutcome: .notAttempted,
            compactionOutcome: .notAttempted,
            syncOutcome: .notAttempted,
            closeOutcome: .notAttempted
        )
    }
}
