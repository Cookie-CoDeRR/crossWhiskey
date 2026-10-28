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
    case shortWrite(operation: IOOperation, bytesCommitted: Int, expectedBytes: Int)
    case sidecarTooLarge(byteCount: Int, maxBytes: Int)
    indirect case setupFailed(primary: DiagnosticDiskSinkError, cleanupFailure: DiagnosticDiskSinkError?)
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
    public let landedUniqueBytes: UInt64
    public let retainedBytesOnDisk: UInt64
    public let retainedHeadBytes: Int
    public let retainedTailBytes: Int
    public let neverWrittenDiscardedBytes: UInt64
    public let retentionTrimmedBytes: UInt64
    public let discardEvents: Int
    public let discardedBytes: UInt64
    public let physicalWriteBytes: UInt64
    public let physicalRewriteBytes: UInt64
    public let isCompacted: Bool
    public let diskPayloadKnown: Bool
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
        landedUniqueBytes: UInt64,
        retainedBytesOnDisk: UInt64,
        retainedHeadBytes: Int,
        retainedTailBytes: Int,
        neverWrittenDiscardedBytes: UInt64,
        retentionTrimmedBytes: UInt64,
        discardEvents: Int,
        discardedBytes: UInt64,
        physicalWriteBytes: UInt64,
        physicalRewriteBytes: UInt64,
        isCompacted: Bool,
        diskPayloadKnown: Bool,
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
        self.landedUniqueBytes = landedUniqueBytes
        self.retainedBytesOnDisk = retainedBytesOnDisk
        self.retainedHeadBytes = retainedHeadBytes
        self.retainedTailBytes = retainedTailBytes
        self.neverWrittenDiscardedBytes = neverWrittenDiscardedBytes
        self.retentionTrimmedBytes = retentionTrimmedBytes
        self.discardEvents = discardEvents
        self.discardedBytes = discardedBytes
        self.physicalWriteBytes = physicalWriteBytes
        self.physicalRewriteBytes = physicalRewriteBytes
        self.isCompacted = isCompacted
        self.diskPayloadKnown = diskPayloadKnown
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
    public let cleanupError: DiagnosticDiskSinkError?
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
        cleanupError: DiagnosticDiskSinkError? = nil,
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
        self.cleanupError = cleanupError
        self.hasCounterOverflow = hasCounterOverflow
    }
}

// MARK: - Injectable File Operation Adapter

public protocol DiskSinkFileAdapter: AnyObject, Sendable {
    func openRootDirectory() throws -> Int32
    func openDirectoryAt(parentFd: Int32, component: String) throws -> Int32
    func createDirectoryAt(parentFd: Int32, component: String, mode: mode_t) throws
    func removeDirectoryAt(parentFd: Int32, component: String) throws
    func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32
    func write(fd: Int32, data: Data) throws -> Int
    func seek(fd: Int32, offset: off_t, whence: Int32) throws -> off_t
    func truncate(fd: Int32, length: off_t) throws
    func sync(fd: Int32) throws
    func close(fd: Int32) throws
    func publishSidecar(dirFd: Int32, tmpName: String, targetName: String) throws
    func syncDirectory(dirFd: Int32) throws
    func unlinkAt(dirFd: Int32, fileName: String) throws
    func fileExistsAt(dirFd: Int32, fileName: String) -> Bool
}

public final class POSIXDiskSinkFileAdapter: DiskSinkFileAdapter, @unchecked Sendable {
    public init() {}

    public func openRootDirectory() throws -> Int32 {
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryOpen, errno: err, message: "open root failed: \(err)")
        }
        return fd
    }

    public func openDirectoryAt(parentFd: Int32, component: String) throws -> Int32 {
        var statBuf = stat()
        let statRes = Darwin.fstatat(parentFd, component, &statBuf, AT_SYMLINK_NOFOLLOW)
        if statRes == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK {
            throw DiagnosticDiskSinkError.symlinkRejected("Path component '\(component)' is a symbolic link")
        }
        let fd = Darwin.openat(parentFd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            let err = errno
            if err == ELOOP || (err == ENOTDIR && statRes == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK) {
                throw DiagnosticDiskSinkError.symlinkRejected("Path component '\(component)' is a symbolic link")
            }
            throw DiagnosticDiskSinkError.ioError(operation: .directoryOpen, errno: err, message: "openat failed for directory component '\(component)': \(err)")
        }
        return fd
    }

    public func createDirectoryAt(parentFd: Int32, component: String, mode: mode_t) throws {
        let result = Darwin.mkdirat(parentFd, component, mode)
        if result != 0 {
            let err = errno
            if err == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("Session directory child '\(component)' already exists")
            }
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCreate, errno: err, message: "mkdirat failed for '\(component)': \(err)")
        }
    }

    public func removeDirectoryAt(parentFd: Int32, component: String) throws {
        let result = Darwin.unlinkat(parentFd, component, AT_REMOVEDIR)
        if result != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .cleanup, errno: err, message: "unlinkat AT_REMOVEDIR failed for directory '\(component)': \(err)")
        }
    }

    public func openAt(dirFd: Int32, fileName: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let fd = Darwin.openat(dirFd, fileName, flags | O_NOFOLLOW, mode)
        if fd < 0 {
            let err = errno
            if err == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("File '\(fileName)' already exists")
            }
            if err == ELOOP {
                throw DiagnosticDiskSinkError.symlinkRejected("File '\(fileName)' is a symlink")
            }
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
                        bytesCommitted: writtenTotal > 0 ? writtenTotal : nil
                    )
                }
                if result == 0 {
                    throw DiagnosticDiskSinkError.shortWrite(
                        operation: .write,
                        bytesCommitted: writtenTotal,
                        expectedBytes: data.count
                    )
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
        let ret = Darwin.renameatx_np(dirFd, tmpName, dirFd, targetName, UInt32(RENAME_EXCL))
        if ret != 0 {
            let err = errno
            if err == EEXIST {
                throw DiagnosticDiskSinkError.fileCollision("Destination '\(targetName)' already exists")
            }
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

    public func fileExistsAt(dirFd: Int32, fileName: String) -> Bool {
        var statBuf = stat()
        return Darwin.fstatat(dirFd, fileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0
    }
}

// MARK: - Stream State Container

private final class StreamState {
    let stream: DiagnosticStreamKind
    let fileName: String
    var fd: Int32 = -1

    var totalAdmittedBytes: UInt64 = 0
    var landedUniqueBytes: UInt64 = 0
    var retainedBytesOnDisk: UInt64 = 0
    var retainedHeadBytes: Int = 0
    var retainedTailBytes: Int = 0
    var neverWrittenDiscardedBytes: UInt64 = 0
    var retentionTrimmedBytes: UInt64 = 0
    var discardEvents: Int = 0
    var physicalWriteBytes: UInt64 = 0
    var physicalRewriteBytes: UInt64 = 0
    var isCompacted: Bool = false
    var diskPayloadKnown: Bool = true
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

    var committedBytes: UInt64 { landedUniqueBytes }
    var discardedBytes: UInt64 {
        let (value, overflow) = neverWrittenDiscardedBytes.addingReportingOverflow(retentionTrimmedBytes)
        return overflow ? UInt64.max : value
    }

    init(stream: DiagnosticStreamKind, fileName: String) {
        self.stream = stream
        self.fileName = fileName
    }

    func addPhysicalWrite(bytes: Int, sink: DiagnosticDiskSink) {
        guard bytes > 0 else { return }
        let (newVal, overflow) = physicalWriteBytes.addingReportingOverflow(UInt64(bytes))
        if overflow {
            sink.hasCounterOverflow = true
            physicalWriteBytes = UInt64.max
        } else {
            physicalWriteBytes = newVal
        }
    }

    func addPhysicalRewrite(bytes: Int, sink: DiagnosticDiskSink) {
        guard bytes > 0 else { return }
        let (newVal, overflow) = physicalRewriteBytes.addingReportingOverflow(UInt64(bytes))
        if overflow {
            sink.hasCounterOverflow = true
            physicalRewriteBytes = UInt64.max
        } else {
            physicalRewriteBytes = newVal
        }
    }

    func toRecord() -> StreamDiskRecord {
        StreamDiskRecord(
            stream: stream,
            fileName: fileName,
            totalAdmittedBytes: totalAdmittedBytes,
            committedBytes: committedBytes,
            landedUniqueBytes: landedUniqueBytes,
            retainedBytesOnDisk: retainedBytesOnDisk,
            retainedHeadBytes: retainedHeadBytes,
            retainedTailBytes: retainedTailBytes,
            neverWrittenDiscardedBytes: neverWrittenDiscardedBytes,
            retentionTrimmedBytes: retentionTrimmedBytes,
            discardEvents: discardEvents,
            discardedBytes: discardedBytes,
            physicalWriteBytes: physicalWriteBytes,
            physicalRewriteBytes: physicalRewriteBytes,
            isCompacted: isCompacted,
            diskPayloadKnown: diskPayloadKnown,
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
    private var cleanupError: DiagnosticDiskSinkError?
    fileprivate(set) var hasCounterOverflow: Bool = false

    // Metadata stage outcomes
    private var metadataRecord = MetadataPublicationRecord()

    // Resource tracking for bounded cleanup
    private var createdDirectory: Bool = false
    private var createdFileNames: Set<String> = []

    public init(
        rootDirectoryURL: URL,
        sessionName: String? = nil,
        sessionId: UUID = UUID(),
        configuration: DiagnosticDiskSinkConfiguration = .default,
        fileAdapter: DiskSinkFileAdapter = POSIXDiskSinkFileAdapter()
    ) throws {
        self.sessionId = sessionId
        self.configuration = configuration
        self.fileAdapter = fileAdapter

        let stdoutState = StreamState(stream: .stdout, fileName: "stdout.bin")
        let stderrState = StreamState(stream: .stderr, fileName: "stderr.bin")
        self.streams = [
            .stdout: stdoutState,
            .stderr: stderrState
        ]

        guard rootDirectoryURL.isFileURL else {
            throw DiagnosticDiskSinkError.directoryError("Root directory URL must be a file URL: \(rootDirectoryURL)")
        }
        let rootPath = rootDirectoryURL.standardizedFileURL.path
        guard rootPath.hasPrefix("/") else {
            throw DiagnosticDiskSinkError.directoryError("Root directory must be an absolute path: \(rootPath)")
        }
        let rootComponents = rootDirectoryURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if rootComponents.contains("..") || rootComponents.contains(".") {
            throw DiagnosticDiskSinkError.directoryError("Root path contains invalid components (. or ..)")
        }

        let childName = sessionName ?? "session-\(sessionId.uuidString)"
        if childName.isEmpty || childName.contains("/") || childName == "." || childName == ".." {
            throw DiagnosticDiskSinkError.directoryError("Invalid session name: '\(childName)'")
        }

        self.directoryURL = rootDirectoryURL.appendingPathComponent(childName)

        try setupDirectoryAndFiles(rootComponents: rootComponents, childName: childName)
    }

    public convenience init(
        directoryURL: URL,
        sessionId: UUID = UUID(),
        configuration: DiagnosticDiskSinkConfiguration = .default,
        fileAdapter: DiskSinkFileAdapter = POSIXDiskSinkFileAdapter()
    ) throws {
        let parent = directoryURL.deletingLastPathComponent()
        let child = directoryURL.lastPathComponent
        try self.init(
            rootDirectoryURL: parent,
            sessionName: child,
            sessionId: sessionId,
            configuration: configuration,
            fileAdapter: fileAdapter
        )
    }

    deinit {
        for state in streams.values {
            if state.fd >= 0 {
                let fdToClose = state.fd
                state.fd = -1
                _ = try? fileAdapter.close(fd: fdToClose)
            }
        }
        if dirFd >= 0 {
            let fdToClose = dirFd
            dirFd = -1
            _ = try? fileAdapter.close(fd: fdToClose)
        }
    }

    // MARK: - Setup & Directory Acquisition

    private func setupDirectoryAndFiles(rootComponents: [String], childName: String) throws {
        // 1. Component-relative walk of rootComponents starting from /
        var currentFd = try fileAdapter.openRootDirectory()
        for comp in rootComponents {
            do {
                let nextFd = try fileAdapter.openDirectoryAt(parentFd: currentFd, component: comp)
                let oldFd = currentFd
                currentFd = -1
                do {
                    try fileAdapter.close(fd: oldFd)
                } catch {
                    let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .close, errno: EIO, message: "\(error)")
                    var secondary: DiagnosticDiskSinkError? = nil
                    do { try fileAdapter.close(fd: nextFd) }
                    catch { secondary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .close, errno: EIO, message: "\(error)") }
                    throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: secondary)
                }
                currentFd = nextFd
            } catch {
                if currentFd >= 0 {
                    let oldFd = currentFd
                    currentFd = -1
                    do { try fileAdapter.close(fd: oldFd) }
                    catch { recordCleanup(error, operation: .close) }
                }
                let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .directoryOpen, errno: EIO, message: "\(error)")
                throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
            }
        }
        let parentFd = currentFd

        // 2. Exclusively create fresh private session child
        do {
            try fileAdapter.createDirectoryAt(parentFd: parentFd, component: childName, mode: 0o700)
            self.createdDirectory = true
        } catch {
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .directoryCreate, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }

        // 3. Acquire child directory handle
        do {
            self.dirFd = try fileAdapter.openDirectoryAt(parentFd: parentFd, component: childName)
        } catch {
            if createdDirectory {
                do { try fileAdapter.removeDirectoryAt(parentFd: parentFd, component: childName) }
                catch { recordCleanup(error, operation: .cleanup) }
                createdDirectory = false
            }
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .directoryOpen, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }

        // 4. Open stream payload files inside dirFd
        for streamKind in DiagnosticStreamKind.allCases {
            guard let state = streams[streamKind] else { continue }
            do {
                if fileAdapter.fileExistsAt(dirFd: dirFd, fileName: state.fileName) {
                    throw DiagnosticDiskSinkError.fileCollision("Target file collision: \(state.fileName)")
                }
                let fd = try fileAdapter.openAt(dirFd: dirFd, fileName: state.fileName, flags: O_RDWR | O_CREAT | O_EXCL, mode: 0o600)
                state.fd = fd
                state.openOutcome = .succeeded
                createdFileNames.insert(state.fileName)
            } catch let err as DiagnosticDiskSinkError {
                if case let .ioError(op, code, msg, _) = err {
                    state.openOutcome = .failed(operation: op, errno: code, message: msg)
                } else if case .fileCollision = err {
                    state.openOutcome = .failed(operation: .open, errno: EEXIST, message: "\(err)")
                } else {
                    state.openOutcome = .failed(operation: .open, errno: EACCES, message: "\(err)")
                }
                self.activeError = err
                let cleanupErr = cleanupResourcesOnSetupFailure(parentFd: parentFd, childName: childName)
                let oldFd = parentFd
                do { try fileAdapter.close(fd: oldFd) }
                catch { recordCleanup(error, operation: .close) }
                throw DiagnosticDiskSinkError.setupFailed(primary: err, cleanupFailure: cleanupErr ?? cleanupError)
            } catch {
                let wrapped = DiagnosticDiskSinkError.ioError(operation: .open, errno: EIO, message: "\(error)")
                state.openOutcome = .failed(operation: .open, errno: EIO, message: "\(error)")
                self.activeError = wrapped
                let cleanupErr = cleanupResourcesOnSetupFailure(parentFd: parentFd, childName: childName)
                let oldFd = parentFd
                do { try fileAdapter.close(fd: oldFd) }
                catch { recordCleanup(error, operation: .close) }
                throw DiagnosticDiskSinkError.setupFailed(primary: wrapped, cleanupFailure: cleanupErr ?? cleanupError)
            }
        }

        // 5. Setup succeeded: close parentFd
        let oldFd = parentFd
        do {
            try fileAdapter.close(fd: oldFd)
        } catch {
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .close, errno: EIO, message: "\(error)")
            // Parent descriptor has been consumed. Leave the fresh directory in
            // place, close acquired children once, and report bounded cleanup.
            for state in streams.values where state.fd >= 0 {
                let fd = state.fd
                state.fd = -1
                do { try fileAdapter.close(fd: fd) }
                catch { recordCleanup(error, operation: .close) }
            }
            let fd = dirFd
            dirFd = -1
            do { try fileAdapter.close(fd: fd) }
            catch { recordCleanup(error, operation: .close) }
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }
    }

    private func cleanupResourcesOnSetupFailure(parentFd: Int32, childName: String) -> DiagnosticDiskSinkError? {
        var firstCleanupErr: DiagnosticDiskSinkError? = nil

        for state in streams.values {
            if state.fd >= 0 {
                let fdToClose = state.fd
                state.fd = -1
                do {
                    try fileAdapter.close(fd: fdToClose)
                } catch let err as DiagnosticDiskSinkError {
                    if firstCleanupErr == nil { firstCleanupErr = err }
                } catch {
                    if firstCleanupErr == nil {
                        firstCleanupErr = .ioError(operation: .close, errno: EIO, message: "\(error)")
                    }
                }
            }
        }

        for fileName in createdFileNames {
            if dirFd >= 0 {
                do {
                    try fileAdapter.unlinkAt(dirFd: dirFd, fileName: fileName)
                } catch let err as DiagnosticDiskSinkError {
                    if firstCleanupErr == nil { firstCleanupErr = err }
                } catch {
                    if firstCleanupErr == nil {
                        firstCleanupErr = .ioError(operation: .cleanup, errno: EIO, message: "\(error)")
                    }
                }
            }
        }
        createdFileNames.removeAll()

        if dirFd >= 0 {
            let fdToClose = dirFd
            dirFd = -1
            do {
                try fileAdapter.close(fd: fdToClose)
            } catch let err as DiagnosticDiskSinkError {
                if firstCleanupErr == nil { firstCleanupErr = err }
            } catch {
                if firstCleanupErr == nil {
                    firstCleanupErr = .ioError(operation: .close, errno: EIO, message: "\(error)")
                }
            }
        }

        if createdDirectory {
            do {
                try fileAdapter.removeDirectoryAt(parentFd: parentFd, component: childName)
                createdDirectory = false
            } catch let err as DiagnosticDiskSinkError {
                if firstCleanupErr == nil { firstCleanupErr = err }
            } catch {
                if firstCleanupErr == nil {
                    firstCleanupErr = .ioError(operation: .cleanup, errno: EIO, message: "\(error)")
                }
            }
        }

        return firstCleanupErr
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

        let prospectiveDiskBytes = Int64(state.retainedBytesOnDisk) + Int64(data.count)
        if prospectiveDiskBytes <= configuration.maxBytesPerStream {
            ingestIntoMemoryBuffers(state: state, chunk: data)
            try writeUnderCap(state: state, data: data)
        } else {
            try compactAndRewrite(state: state, incomingChunk: data)
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

    // Reported counts are exact only while diskPayloadKnown is true and
    // hasCounterOverflow is false. Unknown I/O makes both payload and lifetime
    // accounting uncertain; values then preserve last confirmed progress only.
    private func addCount(_ current: UInt64, _ amount: UInt64) -> UInt64 {
        let (value, overflow) = current.addingReportingOverflow(amount)
        if overflow { hasCounterOverflow = true }
        return overflow ? UInt64.max : value
    }

    /// Applies known progress exactly once, whether the adapter returns or throws.
    /// A short return is converted to an error AFTER applying its progress.
    private func writePayload(
        state: StreamState, data: Data, rewrite: Bool,
        progress: (Int) -> Void
    ) throws {
        let written: Int
        do {
            written = try fileAdapter.write(fd: state.fd, data: data)
        } catch {
            var partial: Int? = nil
            if let err = error as? DiagnosticDiskSinkError {
                switch err {
                case let .ioError(_, _, _, count): partial = count
                case let .shortWrite(_, count, _): partial = count
                default: break
                }
            }
            if let count = partial, count >= 0, count <= data.count {
                state.addPhysicalWrite(bytes: count, sink: self)
                if rewrite { state.addPhysicalRewrite(bytes: count, sink: self) }
                progress(count)
            } else {
                state.diskPayloadKnown = false
            }
            throw error
        }
        guard written >= 0, written <= data.count else {
            state.diskPayloadKnown = false
            throw DiagnosticDiskSinkError.ioError(operation: .write, errno: EIO, message: "Invalid adapter progress")
        }
        state.addPhysicalWrite(bytes: written, sink: self)
        if rewrite { state.addPhysicalRewrite(bytes: written, sink: self) }
        progress(written)
        if written != data.count {
            throw DiagnosticDiskSinkError.shortWrite(operation: .write, bytesCommitted: written, expectedBytes: data.count)
        }
    }

    private func failedOutcome(_ error: Error, operation: IOOperation) -> StageOutcome {
        if let err = error as? DiagnosticDiskSinkError {
            switch err {
            case let .ioError(op, code, message, _):
                return .failed(operation: op, errno: code, message: message)
            case let .shortWrite(op, count, expected):
                return .failed(operation: op, errno: 0, message: "Short write: committed \(count) of \(expected) bytes")
            default: break
            }
        }
        return .failed(operation: operation, errno: EIO, message: "\(error)")
    }

    private func writeUnderCap(state: StreamState, data: Data) throws {
        do {
            try writePayload(state: state, data: data, rewrite: false) { count in
                state.landedUniqueBytes = addCount(state.landedUniqueBytes, UInt64(count))
                state.retainedBytesOnDisk += UInt64(count) // bounded by configured stream cap
                state.retainedHeadBytes = min(configuration.headBudget, Int(state.retainedBytesOnDisk))
                state.retainedTailBytes = Int(state.retainedBytesOnDisk) - state.retainedHeadBytes
            }
            state.writeOutcome = .succeeded
        } catch {
            state.status = .failed
            state.writeOutcome = failedOutcome(error, operation: .write)
            let wrapped = error as? DiagnosticDiskSinkError ?? .ioError(operation: .write, errno: EIO, message: "\(error)")
            failClosed(error: wrapped)
            throw wrapped
        }
    }

    // MARK: - Bounded Compaction Without Markers

    private func compactAndRewrite(state: StreamState, incomingChunk: Data) throws {
        let (events, overflow) = state.discardEvents.addingReportingOverflow(1)
        if overflow { hasCounterOverflow = true }
        state.discardEvents = overflow ? Int.max : events
        state.compactionOutcome = .notAttempted
        let oldHead = state.retainedHeadBytes
        let oldRetained = state.retainedBytesOnDisk
        let headContribution = min(incomingChunk.count, max(0, configuration.headBudget - state.headBuffer.count))
        let tailPortionCount = incomingChunk.count - headContribution
        ingestIntoMemoryBuffers(state: state, chunk: incomingChunk)
        let headCount = state.headBuffer.count
        let tailCount = min(configuration.tailBudget, Int(configuration.maxBytesPerStream) - headCount)
        let suffixData = Data(state.tailBuffer.suffix(tailCount))
        let incomingSuffixCount = min(tailPortionCount, suffixData.count)
        let oldSuffixCount = suffixData.count - incomingSuffixCount
        let skipped = incomingChunk.count - headContribution - incomingSuffixCount
        state.neverWrittenDiscardedBytes = addCount(state.neverWrittenDiscardedBytes, UInt64(skipped))
        var phase: IOOperation = .seek
        do {
            _ = try fileAdapter.seek(fd: state.fd, offset: 0, whence: SEEK_SET)
            phase = .write
            try writePayload(state: state, data: state.headBuffer, rewrite: true) { count in
                // Only a newly extended startup head is a first-time landing.
                state.landedUniqueBytes = addCount(state.landedUniqueBytes, UInt64(max(0, count - oldHead)))
                state.retainedBytesOnDisk = max(oldRetained, UInt64(count))
                state.retainedHeadBytes = min(headCount, Int(state.retainedBytesOnDisk))
                state.retainedTailBytes = Int(state.retainedBytesOnDisk) - state.retainedHeadBytes
            }
            phase = .truncate
            try fileAdapter.truncate(fd: state.fd, length: off_t(headCount))
            state.retainedBytesOnDisk = UInt64(headCount)
            state.retainedHeadBytes = headCount
            state.retainedTailBytes = 0
            phase = .write
            if !suffixData.isEmpty {
                try writePayload(state: state, data: suffixData, rewrite: true) { count in
                    // Old suffix precedes incoming suffix in chronological order.
                    state.landedUniqueBytes = addCount(state.landedUniqueBytes, UInt64(max(0, count - oldSuffixCount)))
                    state.retainedBytesOnDisk = UInt64(headCount + count)
                    state.retainedTailBytes = count
                }
            }
            state.tailBuffer = suffixData
            state.isCompacted = true
            state.compactionOutcome = .succeeded
            state.retentionTrimmedBytes = state.landedUniqueBytes >= state.retainedBytesOnDisk
                ? state.landedUniqueBytes - state.retainedBytesOnDisk : 0
        } catch {
            if phase == .seek || phase == .truncate { state.diskPayloadKnown = false }
            if state.diskPayloadKnown {
                state.retentionTrimmedBytes = state.landedUniqueBytes >= state.retainedBytesOnDisk
                    ? state.landedUniqueBytes - state.retainedBytesOnDisk : 0
            }
            state.status = .partiallyCompacted
            state.compactionOutcome = failedOutcome(error, operation: phase)
            let wrapped = error as? DiagnosticDiskSinkError ?? .ioError(operation: phase, errno: EIO, message: "\(error)")
            failClosed(error: wrapped)
            throw wrapped
        }
    }

    private func recordCleanup(_ error: Error, operation: IOOperation) {
        if cleanupError == nil {
            cleanupError = error as? DiagnosticDiskSinkError ?? .ioError(operation: operation, errno: EIO, message: "\(error)")
        }
    }

    private func failClosed(error: DiagnosticDiskSinkError) {
        if self.activeError == nil {
            self.activeError = error
        }
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
                let fdToClose = state.fd
                state.fd = -1
                do {
                    try fileAdapter.close(fd: fdToClose)
                    state.closeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        state.closeOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(err)")
                    }
                    if activeError == nil { activeError = err }
                } catch {
                    state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(error)")
                    if activeError == nil {
                        activeError = .ioError(operation: .close, errno: EIO, message: "\(error)")
                    }
                }
            }
            if state.status == .active {
                state.status = .failed
            }
        }

        if dirFd >= 0 {
            let fdToClose = dirFd
            dirFd = -1
            do {
                try fileAdapter.close(fd: fdToClose)
            } catch let err as DiagnosticDiskSinkError {
                if cleanupError == nil { cleanupError = err }
            } catch {
                if cleanupError == nil {
                    cleanupError = .ioError(operation: .close, errno: EIO, message: "\(error)")
                }
            }
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
            cleanupError: cleanupError,
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

        // 1. Flush & close payload streams
        for state in streams.values {
            if state.fd >= 0 {
                // Sync
                do {
                    try fileAdapter.sync(fd: state.fd)
                    state.syncOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, msg, _) = err {
                        state.syncOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        state.syncOutcome = .failed(operation: .sync, errno: EIO, message: "\(err)")
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .sync, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.syncOutcome = .failed(operation: .sync, errno: EIO, message: "\(error)")
                    state.status = .failed
                }

                // Close: disarm BEFORE close
                let fdToClose = state.fd
                state.fd = -1
                do {
                    try fileAdapter.close(fd: fdToClose)
                    state.closeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if activeError == nil { activeError = err }
                    if case let .ioError(op, code, msg, _) = err {
                        state.closeOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(err)")
                    }
                    state.status = .failed
                } catch {
                    let wrapped = DiagnosticDiskSinkError.ioError(operation: .close, errno: EIO, message: "\(error)")
                    if activeError == nil { activeError = wrapped }
                    state.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(error)")
                    state.status = .failed
                }
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

        if dirFd >= 0 {
            let tmpFileName = ".persistence.json.tmp.\(sessionId.uuidString)"
            let targetFileName = "persistence.json"
            var didCreateTempSidecar = false
            var tmpFd: Int32 = -1

            let sidecar = DiagnosticPersistenceSidecar(
                sinkSessionId: sessionId,
                stdoutRecord: stdoutRecord,
                stderrRecord: stderrRecord,
                metadataRecord: metadataRecord,
                maxBytesPerStream: configuration.maxBytesPerStream,
                headBudget: configuration.headBudget,
                tailBudget: configuration.tailBudget,
                isSealed: true,
                finalOutcome: activeError == nil ? "success" : "failure"
            )

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(sidecar)
                guard jsonData.count <= configuration.maxSidecarBytes else {
                    throw DiagnosticDiskSinkError.sidecarTooLarge(byteCount: jsonData.count, maxBytes: configuration.maxSidecarBytes)
                }

                // Open temp file exclusively
                do {
                    tmpFd = try fileAdapter.openAt(dirFd: dirFd, fileName: tmpFileName, flags: O_RDWR | O_CREAT | O_EXCL, mode: 0o600)
                    didCreateTempSidecar = true
                    metadataRecord.createOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.createOutcome = .failed(operation: op, errno: code, message: msg)
                    } else if case .fileCollision = err {
                        metadataRecord.createOutcome = .failed(operation: .open, errno: EEXIST, message: "\(err)")
                    } else {
                        metadataRecord.createOutcome = .failed(operation: .open, errno: EACCES, message: "\(err)")
                    }
                    throw err
                } catch {
                    metadataRecord.createOutcome = .failed(operation: .open, errno: EIO, message: "\(error)")
                    throw error
                }

                // Write sidecar data
                do {
                    let written = try fileAdapter.write(fd: tmpFd, data: jsonData)
                    if written < jsonData.count {
                        throw DiagnosticDiskSinkError.shortWrite(operation: .write, bytesCommitted: written, expectedBytes: jsonData.count)
                    }
                    metadataRecord.writeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.writeOutcome = .failed(operation: op, errno: code, message: msg)
                    } else if case let .shortWrite(op, written, expected) = err {
                        metadataRecord.writeOutcome = .failed(operation: op, errno: 0, message: "Short write: committed \(written) of \(expected) bytes")
                    } else {
                        metadataRecord.writeOutcome = .failed(operation: .write, errno: EIO, message: "\(err)")
                    }
                    throw err
                } catch {
                    metadataRecord.writeOutcome = .failed(operation: .write, errno: EIO, message: "\(error)")
                    throw error
                }

                // Sync sidecar
                do {
                    try fileAdapter.sync(fd: tmpFd)
                    metadataRecord.syncOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.syncOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        metadataRecord.syncOutcome = .failed(operation: .sync, errno: EIO, message: "\(err)")
                    }
                    throw err
                } catch {
                    metadataRecord.syncOutcome = .failed(operation: .sync, errno: EIO, message: "\(error)")
                    throw error
                }

                // Close sidecar: disarm BEFORE close
                let sidecarFdToClose = tmpFd
                tmpFd = -1
                do {
                    try fileAdapter.close(fd: sidecarFdToClose)
                    metadataRecord.closeOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.closeOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        metadataRecord.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(err)")
                    }
                    throw err
                } catch {
                    metadataRecord.closeOutcome = .failed(operation: .close, errno: EIO, message: "\(error)")
                    throw error
                }

                // Publish sidecar via atomic rename
                do {
                    try fileAdapter.publishSidecar(dirFd: dirFd, tmpName: tmpFileName, targetName: targetFileName)
                    sidecarPublished = true
                    sidecarURL = directoryURL.appendingPathComponent(targetFileName)
                    createdFileNames.insert(targetFileName)
                    metadataRecord.publishOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.publishOutcome = .failed(operation: op, errno: code, message: msg)
                    } else if case .fileCollision = err {
                        metadataRecord.publishOutcome = .failed(operation: .rename, errno: EEXIST, message: "\(err)")
                    } else {
                        metadataRecord.publishOutcome = .failed(operation: .rename, errno: EIO, message: "\(err)")
                    }
                    throw err
                } catch {
                    metadataRecord.publishOutcome = .failed(operation: .rename, errno: EIO, message: "\(error)")
                    throw error
                }

                // Directory sync
                do {
                    try fileAdapter.syncDirectory(dirFd: dirFd)
                    parentDirSynced = true
                    metadataRecord.directorySyncOutcome = .succeeded
                } catch let err as DiagnosticDiskSinkError {
                    if case let .ioError(op, code, msg, _) = err {
                        metadataRecord.directorySyncOutcome = .failed(operation: op, errno: code, message: msg)
                    } else {
                        metadataRecord.directorySyncOutcome = .failed(operation: .directorySync, errno: EIO, message: "\(err)")
                    }
                } catch {
                    metadataRecord.directorySyncOutcome = .failed(operation: .directorySync, errno: EIO, message: "\(error)")
                }
            } catch {
                if activeError == nil {
                    if let diskErr = error as? DiagnosticDiskSinkError {
                        activeError = diskErr
                    } else {
                        activeError = DiagnosticDiskSinkError.ioError(operation: .rename, errno: EIO, message: "\(error)")
                    }
                }
                // Cleanup tmpFd if still open
                if tmpFd >= 0 {
                    let fdToClose = tmpFd
                    tmpFd = -1
                    do {
                        try fileAdapter.close(fd: fdToClose)
                        metadataRecord.closeOutcome = .succeeded
                    } catch {
                        metadataRecord.closeOutcome = failedOutcome(error, operation: .close)
                        recordCleanup(error, operation: .close)
                    }
                }
                // ONLY unlink tmp file if creation actually succeeded!
                if didCreateTempSidecar {
                    do {
                        try fileAdapter.unlinkAt(dirFd: dirFd, fileName: tmpFileName)
                    } catch {
                        recordCleanup(error, operation: .cleanup)
                    }
                    didCreateTempSidecar = false
                }
            }

            // Close dirFd: disarm BEFORE close
            let dirFdToClose = dirFd
            dirFd = -1
            do {
                try fileAdapter.close(fd: dirFdToClose)
            } catch let err as DiagnosticDiskSinkError {
                if cleanupError == nil { cleanupError = err }
            } catch {
                if cleanupError == nil {
                    cleanupError = .ioError(operation: .close, errno: EIO, message: "\(error)")
                }
            }
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
            cleanupError: cleanupError,
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
            landedUniqueBytes: 0,
            retainedBytesOnDisk: 0,
            retainedHeadBytes: 0,
            retainedTailBytes: 0,
            neverWrittenDiscardedBytes: 0,
            retentionTrimmedBytes: 0,
            discardEvents: 0,
            discardedBytes: 0,
            physicalWriteBytes: 0,
            physicalRewriteBytes: 0,
            isCompacted: false,
            diskPayloadKnown: false,
            status: .failed,
            openOutcome: .notAttempted,
            writeOutcome: .notAttempted,
            compactionOutcome: .notAttempted,
            syncOutcome: .notAttempted,
            closeOutcome: .notAttempted
        )
    }
}
