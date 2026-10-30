//
//  DiagnosticDiskSink.swift
//  WhiskyKit
//
//  Isolated bounded disk sink and persistence receipt for diagnostic captures.
//  Preserves raw binary byte streams without in-band markers or text decoding,
//  executes bounded in-place compaction, enforces directory-anchored descriptors,
//  validates ancestor and root security (DAC and Darwin extended ACLs),
//  enforces cooperative storage admission, and publishes an atomic, non-overwriting
//  persistence sidecar with an abandonment-on-failure policy.
//

import Darwin
import Darwin.membership
import Foundation

// MARK: - Configuration & Validation

public enum DiagnosticDiskSinkConfigurationError: Error, Equatable, Sendable {
    case invalidMaxBytesPerStream(Int64)
    case invalidHeadBudget(Int)
    case invalidTailBudget(Int)
    case invalidMaxChunkBytes(Int)
    case invalidTailTrimThreshold(Int)
    case invalidMaxSidecarBytes(Int)
    case invalidMaxStorageBudgetPerRoot(UInt64)
    case invalidMaxRootScanEntries(Int)
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
    public static let defaultMaxStorageBudgetPerRoot: UInt64 = 100 * 1024 * 1024 // 100 MiB default storage budget per root
    public static let defaultMaxRootScanEntries: Int = 1024               // Max directory entries examined during usage scan

    public let maxBytesPerStream: Int64
    public let headBudget: Int
    public let tailBudget: Int
    public let maxChunkBytes: Int
    public let tailTrimThreshold: Int
    public let maxSidecarBytes: Int
    public let maxStorageBudgetPerRoot: UInt64
    public let maxRootScanEntries: Int

    public init(
        maxBytesPerStream: Int64 = defaultMaxBytesPerStream,
        headBudget: Int = defaultHeadBudget,
        tailBudget: Int = defaultTailBudget,
        maxChunkBytes: Int = defaultMaxChunkBytes,
        tailTrimThreshold: Int? = nil,
        maxSidecarBytes: Int = defaultMaxSidecarBytes,
        maxStorageBudgetPerRoot: UInt64 = defaultMaxStorageBudgetPerRoot,
        maxRootScanEntries: Int = defaultMaxRootScanEntries
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
        guard maxStorageBudgetPerRoot > 0 else {
            throw DiagnosticDiskSinkConfigurationError.invalidMaxStorageBudgetPerRoot(maxStorageBudgetPerRoot)
        }
        guard maxRootScanEntries > 0 && maxRootScanEntries <= 100_000 else {
            throw DiagnosticDiskSinkConfigurationError.invalidMaxRootScanEntries(maxRootScanEntries)
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
        self.maxStorageBudgetPerRoot = maxStorageBudgetPerRoot
        self.maxRootScanEntries = maxRootScanEntries
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
    case insecureDirectoryPath(component: String, reason: String)
    case unsupportedFilesystem(typeName: String, flags: UInt32, message: String)
    case childVerificationFailed(reason: String)
    case storageBudgetExceeded(scannedUsage: UInt64, activeReservations: UInt64, requestedReservation: UInt64, budget: UInt64)
    case storageScanIncomplete(reason: String)
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

    // Diagnostic metadata only (NOT tamper-evidence)
    public let sessionDevice: UInt64
    public let sessionInode: UInt64

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
        finalOutcome: String,
        sessionDevice: UInt64 = 0,
        sessionInode: UInt64 = 0
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
        self.sessionDevice = sessionDevice
        self.sessionInode = sessionInode
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

    // Diagnostic metadata only (NOT tamper-evidence without trusted baseline)
    public let sessionDevice: UInt64
    public let sessionInode: UInt64

    // Storage admission accounting (soft admission bound, cross-instance cooperative)
    public let storageBudget: UInt64
    public let initialScannedUsage: UInt64
    public let storageReservation: UInt64

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
        hasCounterOverflow: Bool,
        sessionDevice: UInt64 = 0,
        sessionInode: UInt64 = 0,
        storageBudget: UInt64 = 0,
        initialScannedUsage: UInt64 = 0,
        storageReservation: UInt64 = 0
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
        self.sessionDevice = sessionDevice
        self.sessionInode = sessionInode
        self.storageBudget = storageBudget
        self.initialScannedUsage = initialScannedUsage
        self.storageReservation = storageReservation
    }
}

// MARK: - Process-Wide Storage Admission Ledger

public final class DiagnosticDiskSinkStorageLedger: @unchecked Sendable {
    public static let shared = DiagnosticDiskSinkStorageLedger()

    public struct RootIdentifier: Hashable, Sendable {
        public let dev: dev_t
        public let ino: ino_t
        public init(dev: dev_t, ino: ino_t) {
            self.dev = dev
            self.ino = ino
        }
    }

    private let lock = NSLock()
    private var reservations: [RootIdentifier: UInt64] = [:]

    public init() {}

    public func reserve(root: RootIdentifier, amount: UInt64, scannedUsage: UInt64, budget: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let currentReserved = reservations[root, default: 0]
        let (committedAndReserved, overflow1) = scannedUsage.addingReportingOverflow(currentReserved)
        let (totalProspective, overflow2) = committedAndReserved.addingReportingOverflow(amount)
        if overflow1 || overflow2 || totalProspective > budget {
            return false
        }
        reservations[root] = currentReserved + amount
        return true
    }

    public func release(root: RootIdentifier, amount: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let currentReserved = reservations[root, default: 0]
        if currentReserved <= amount {
            reservations.removeValue(forKey: root)
        } else {
            reservations[root] = currentReserved - amount
        }
    }

    public func activeReservation(for root: RootIdentifier) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return reservations[root, default: 0]
    }

    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        reservations.removeAll()
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

    // Ownership & platform security primitives
    func stat(fd: Int32) throws -> Darwin.stat
    func getExtendedAcl(fd: Int32) -> (acl: acl_t?, errno: Int32)
    func statfs(fd: Int32) throws -> (typeName: String, flags: UInt32)
    func scanDirectoryUsage(dirFd: Int32, maxEntries: Int) throws -> UInt64
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
        var statBuf = Darwin.stat()
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
        var statBuf = Darwin.stat()
        return Darwin.fstatat(dirFd, fileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0
    }

    public func stat(fd: Int32) throws -> Darwin.stat {
        var statBuf = Darwin.stat()
        if Darwin.fstat(fd, &statBuf) != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fstat failed: \(err)")
        }
        return statBuf
    }

    public func getExtendedAcl(fd: Int32) -> (acl: acl_t?, errno: Int32) {
        errno = 0
        let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        return (acl, errno)
    }

    public func statfs(fd: Int32) throws -> (typeName: String, flags: UInt32) {
        var fs = Darwin.statfs()
        if Darwin.fstatfs(fd, &fs) != 0 {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fstatfs failed: \(err)")
        }
        var typeNameBytes = fs.f_fstypename
        let typeName = withUnsafeBytes(of: &typeNameBytes) { ptr -> String in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        return (typeName, fs.f_flags)
    }

    public func scanDirectoryUsage(dirFd: Int32, maxEntries: Int) throws -> UInt64 {
        // FAIL-CLOSED CONTRACT: fully account root usage or throw. Truncation at entry
        // caps, readdir/fstatat errors, accounting overflow, unreadable entries and
        // structures deeper than the accounted one-level session layout are all
        // reported; a partial total is never returned. A completed scan reflects usage
        // at observation time under the cooperative same-login boundary.
        let dupFd = Darwin.dup(dirFd)
        guard dupFd >= 0 else {
            let err = errno
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "dup for scan failed: \(err)")
        }
        guard let dir = Darwin.fdopendir(dupFd) else {
            let err = errno
            _ = Darwin.close(dupFd)
            throw DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fdopendir failed: \(err)")
        }

        var totalUsage: UInt64 = 0
        var entryCount = 0
        var scanError: Error? = nil

        while true {
            errno = 0
            guard let entry = Darwin.readdir(dir) else {
                let err = errno
                if err != 0 {
                    scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "readdir failed on root scan: \(err)")
                }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { ptr -> String in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
            if name == "." || name == ".." { continue }
            entryCount += 1
            if entryCount > maxEntries {
                scanError = DiagnosticDiskSinkError.storageScanIncomplete(reason: "Root directory entry count exceeded maxEntries \(maxEntries); usage is not fully accounted")
                break
            }

            var sb = Darwin.stat()
            guard Darwin.fstatat(dirFd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
                let err = errno
                scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fstatat failed during scan for '\(name)': \(err)")
                break
            }

            if (sb.st_mode & S_IFMT) == S_IFDIR {
                let subFd = Darwin.openat(dirFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard subFd >= 0 else {
                    let err = errno
                    scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "openat failed during scan for directory '\(name)': \(err)")
                    break
                }
                guard let subDir = Darwin.fdopendir(subFd) else {
                    let err = errno
                    _ = Darwin.close(subFd)
                    scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fdopendir failed during scan for '\(name)': \(err)")
                    break
                }
                var subEntries = 0
                while true {
                    errno = 0
                    guard let subEntry = Darwin.readdir(subDir) else {
                        let err = errno
                        if err != 0 {
                            scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "readdir failed scanning '\(name)': \(err)")
                        }
                        break
                    }
                    let subName = withUnsafeBytes(of: subEntry.pointee.d_name) { ptr -> String in
                        guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                        return String(cString: base)
                    }
                    if subName == "." || subName == ".." { continue }
                    subEntries += 1
                    if subEntries > 64 {
                        scanError = DiagnosticDiskSinkError.storageScanIncomplete(reason: "Session directory '\(name)' exceeds 64 accounted entries; usage is not fully accounted")
                        break
                    }
                    var subSb = Darwin.stat()
                    guard Darwin.fstatat(subFd, subName, &subSb, AT_SYMLINK_NOFOLLOW) == 0 else {
                        let err = errno
                        scanError = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: err, message: "fstatat failed during scan for '\(name)/\(subName)': \(err)")
                        break
                    }
                    if (subSb.st_mode & S_IFMT) == S_IFDIR {
                        scanError = DiagnosticDiskSinkError.storageScanIncomplete(reason: "Nested directory '\(name)/\(subName)' is deeper than the accounted layout; usage is not fully accounted")
                        break
                    }
                    let (subTotal, subOverflow) = totalUsage.addingReportingOverflow(UInt64(max(0, subSb.st_size)))
                    if subOverflow {
                        scanError = DiagnosticDiskSinkError.storageScanIncomplete(reason: "Usage accounting overflow while scanning '\(name)/\(subName)'")
                        break
                    }
                    totalUsage = subTotal
                    if scanError != nil { break }
                }
                let subCloseRc = Darwin.closedir(subDir)
                let subCloseErrno = subCloseRc != 0 ? errno : 0
                scanError = combineScanFailure(scanError, closeErrno: subCloseErrno, label: name)
                if scanError != nil { break }
            } else {
                // Regular files, symlinks (own link size via NOFOLLOW) and other
                // non-directory entries contribute their own size; nothing is skipped.
                let (newTotal, overflow) = totalUsage.addingReportingOverflow(UInt64(max(0, sb.st_size)))
                if overflow {
                    scanError = DiagnosticDiskSinkError.storageScanIncomplete(reason: "Usage accounting overflow at root entry '\(name)'")
                    break
                }
                totalUsage = newTotal
            }
        }

        let dirCloseRc = Darwin.closedir(dir)
        let dirCloseErrno = dirCloseRc != 0 ? errno : 0
        scanError = combineScanFailure(scanError, closeErrno: dirCloseErrno, label: "root")
        if let scanError { throw scanError }
        return totalUsage
    }

    private func combineScanFailure(_ primary: Error?, closeErrno: Int32, label: String) -> Error? {
        guard closeErrno != 0 else { return primary }
        let note = "additionally closedir(\(label)) failed with errno \(closeErrno)"
        if let primary = primary {
            if case let DiagnosticDiskSinkError.storageScanIncomplete(reason) = primary {
                return DiagnosticDiskSinkError.storageScanIncomplete(reason: reason + "; " + note)
            }
            if case let DiagnosticDiskSinkError.ioError(op, code, msg, _) = primary {
                return DiagnosticDiskSinkError.ioError(operation: op, errno: code, message: msg + "; " + note)
            }
            return primary
        }
        return DiagnosticDiskSinkError.ioError(operation: .close, errno: closeErrno, message: "closedir(\(label)) failed: \(closeErrno)")
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
        let (val, ovf) = physicalWriteBytes.addingReportingOverflow(UInt64(bytes))
        if ovf { sink.hasCounterOverflow = true }
        physicalWriteBytes = ovf ? UInt64.max : val
    }

    func addPhysicalRewrite(bytes: Int, sink: DiagnosticDiskSink) {
        let (val, ovf) = physicalRewriteBytes.addingReportingOverflow(UInt64(bytes))
        if ovf { sink.hasCounterOverflow = true }
        physicalRewriteBytes = ovf ? UInt64.max : val
    }

    func snapshot() -> StreamDiskRecord {
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

// MARK: - Diagnostic Disk Sink Implementation

public final class DiagnosticDiskSink {
    public let sessionId: UUID
    public let configuration: DiagnosticDiskSinkConfiguration
    public let directoryURL: URL

    private let fileAdapter: DiskSinkFileAdapter
    private var dirFd: Int32 = -1
    private var isSealed: Bool = false
    private var terminalReceipt: DiagnosticDiskSinkReceipt?
    private var activeError: DiagnosticDiskSinkError?
    private var cleanupError: DiagnosticDiskSinkError?
    var hasCounterOverflow: Bool = false

    private var streams: [DiagnosticStreamKind: StreamState] = [:]
    private var metadataRecord = MetadataPublicationRecord()

    // Tracking for abandoned resources
    private var createdFileNames: Set<String> = []
    private var createdDirectory: Bool = false
    private var didCreateTempSidecar: Bool = false

    // Diagnostic metadata
    public private(set) var acquiredDevice: UInt64 = 0
    public private(set) var acquiredInode: UInt64 = 0

    // Storage admission tracking
    private var storageLedgerRootId: DiagnosticDiskSinkStorageLedger.RootIdentifier? = nil
    private var reservedStorageAmount: UInt64 = 0
    private var isStorageReservationHeld: Bool = false
    public private(set) var initialScannedUsage: UInt64 = 0
    public private(set) var effectiveStorageBudget: UInt64 = 0

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
        self.effectiveStorageBudget = configuration.maxStorageBudgetPerRoot

        for streamKind in DiagnosticStreamKind.allCases {
            let fileName = "\(streamKind.rawValue).bin"
            self.streams[streamKind] = StreamState(stream: streamKind, fileName: fileName)
        }

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

        do {
            try setupDirectoryAndFiles(rootComponents: rootComponents, childName: childName)
        } catch {
            releaseStorageReservationOnce()
            throw error
        }
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
        releaseStorageReservationOnce()
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

    private func releaseStorageReservationOnce() {
        if isStorageReservationHeld, let rootId = storageLedgerRootId {
            isStorageReservationHeld = false
            DiagnosticDiskSinkStorageLedger.shared.release(root: rootId, amount: reservedStorageAmount)
        }
    }

    // MARK: - Setup & Directory Acquisition

    private func setupDirectoryAndFiles(rootComponents: [String], childName: String) throws {
        // 1. Component-relative walk of rootComponents anchored at /
        var currentFd = try fileAdapter.openRootDirectory()
        do {
            try verifyDirectorySecurity(fd: currentFd, component: "/", isFinalRoot: rootComponents.isEmpty)
        } catch {
            let oldFd = currentFd
            currentFd = -1
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .directoryOpen, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }

        for (index, comp) in rootComponents.enumerated() {
            let isFinalComponent = (index == rootComponents.count - 1)
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
                try verifyDirectorySecurity(fd: currentFd, component: comp, isFinalRoot: isFinalComponent)
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

        // 2. Validate volume locality (fstatfs MNT_LOCAL) on the root directory
        do {
            let (fsTypeName, fsFlags) = try fileAdapter.statfs(fd: parentFd)
            guard (fsFlags & UInt32(MNT_LOCAL)) != 0 else {
                throw DiagnosticDiskSinkError.unsupportedFilesystem(
                    typeName: fsTypeName,
                    flags: fsFlags,
                    message: "Root directory must reside on a local volume (MNT_LOCAL required, found '\(fsTypeName)')"
                )
            }
        } catch let err as DiagnosticDiskSinkError {
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            throw DiagnosticDiskSinkError.setupFailed(primary: err, cleanupFailure: cleanupError)
        } catch {
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }

        // 3. Storage admission & reservation ledger
        do {
            let rootStat = try fileAdapter.stat(fd: parentFd)
            let rootId = DiagnosticDiskSinkStorageLedger.RootIdentifier(dev: rootStat.st_dev, ino: rootStat.st_ino)
            self.storageLedgerRootId = rootId

            let scannedBytes = try fileAdapter.scanDirectoryUsage(dirFd: parentFd, maxEntries: configuration.maxRootScanEntries)
            self.initialScannedUsage = scannedBytes

            let sessionReservation: UInt64 = UInt64(configuration.maxBytesPerStream * 2) +
                                             UInt64(configuration.maxSidecarBytes * 2) +
                                             65_536
            self.reservedStorageAmount = sessionReservation

            let admitted = DiagnosticDiskSinkStorageLedger.shared.reserve(
                root: rootId,
                amount: sessionReservation,
                scannedUsage: scannedBytes,
                budget: configuration.maxStorageBudgetPerRoot
            )

            guard admitted else {
                let activeRes = DiagnosticDiskSinkStorageLedger.shared.activeReservation(for: rootId)
                throw DiagnosticDiskSinkError.storageBudgetExceeded(
                    scannedUsage: scannedBytes,
                    activeReservations: activeRes,
                    requestedReservation: sessionReservation,
                    budget: configuration.maxStorageBudgetPerRoot
                )
            }
            self.isStorageReservationHeld = true
        } catch let err as DiagnosticDiskSinkError {
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            throw DiagnosticDiskSinkError.setupFailed(primary: err, cleanupFailure: cleanupError)
        } catch {
            let oldFd = parentFd
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = DiagnosticDiskSinkError.ioError(operation: .directoryCheck, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupError)
        }

        // 4. Exclusively create fresh private session child (0o700)
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

        // 5. Acquire child directory handle & post-creation child verification on its own fd
        do {
            self.dirFd = try fileAdapter.openDirectoryAt(parentFd: parentFd, component: childName)
            try verifyChildDirectorySecurity(dirFd: dirFd, childName: childName)
            let childStat = try fileAdapter.stat(fd: dirFd)
            self.acquiredDevice = UInt64(childStat.st_dev)
            self.acquiredInode = UInt64(childStat.st_ino)
        } catch {
            let oldFd = parentFd
            let cleanupErr = cleanupResourcesOnSetupFailure(parentFd: parentFd, childName: childName)
            do { try fileAdapter.close(fd: oldFd) }
            catch { recordCleanup(error, operation: .close) }
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .directoryOpen, errno: EIO, message: "\(error)")
            throw DiagnosticDiskSinkError.setupFailed(primary: primary, cleanupFailure: cleanupErr ?? cleanupError)
        }

        // 6. Open stream payload files inside dirFd
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

        // 7. Setup succeeded: close parentFd
        let oldFd = parentFd
        do {
            try fileAdapter.close(fd: oldFd)
        } catch {
            let primary = error as? DiagnosticDiskSinkError ?? .ioError(operation: .close, errno: EIO, message: "\(error)")
            // Parent descriptor has been consumed. Disarm and close acquired children once, abandoning directory.
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

    private func verifyDirectorySecurity(fd: Int32, component: String, isFinalRoot: Bool) throws {
        let sb = try fileAdapter.stat(fd: fd)
        guard (sb.st_mode & S_IFMT) == S_IFDIR else {
            throw DiagnosticDiskSinkError.insecureDirectoryPath(
                component: component,
                reason: "Path component is not a directory"
            )
        }

        let euid = geteuid()
        guard sb.st_uid == 0 || sb.st_uid == euid else {
            throw DiagnosticDiskSinkError.insecureDirectoryPath(
                component: component,
                reason: "Directory owned by untrusted uid \(sb.st_uid) (expected 0 or \(euid))"
            )
        }

        guard (sb.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            let modeOctal = String(sb.st_mode & 0o777, radix: 8)
            throw DiagnosticDiskSinkError.insecureDirectoryPath(
                component: component,
                reason: "Directory has insecure permissions 0o\(modeOctal) (group/other writable)"
            )
        }

        let (acl, aclErrno) = fileAdapter.getExtendedAcl(fd: fd)
        if let acl = acl {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t? = nil
            var rc = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)

            let writeMask: UInt64 = UInt64(ACL_WRITE_DATA.rawValue) |
                                   UInt64(ACL_ADD_FILE.rawValue) |
                                   UInt64(ACL_APPEND_DATA.rawValue) |
                                   UInt64(ACL_ADD_SUBDIRECTORY.rawValue) |
                                   UInt64(ACL_DELETE.rawValue) |
                                   UInt64(ACL_DELETE_CHILD.rawValue) |
                                   UInt64(ACL_WRITE_ATTRIBUTES.rawValue) |
                                   UInt64(ACL_WRITE_EXTATTRIBUTES.rawValue) |
                                   UInt64(ACL_WRITE_SECURITY.rawValue) |
                                   UInt64(ACL_CHANGE_OWNER.rawValue)

            let readMask: UInt64 = UInt64(ACL_READ_DATA.rawValue) |
                                  UInt64(ACL_LIST_DIRECTORY.rawValue) |
                                  UInt64(ACL_READ_ATTRIBUTES.rawValue) |
                                  UInt64(ACL_READ_EXTATTRIBUTES.rawValue)

            while rc == 0, let currentEntry = entry {
                var tag: acl_tag_t = ACL_UNDEFINED_TAG
                _ = acl_get_tag_type(currentEntry, &tag)

                if tag == ACL_EXTENDED_ALLOW {
                    var mask: acl_permset_mask_t = 0
                    _ = acl_get_permset_mask_np(currentEntry, &mask)

                    if (mask & writeMask) != 0 {
                        throw DiagnosticDiskSinkError.insecureDirectoryPath(
                            component: component,
                            reason: "Directory has write-granting extended ACL entry"
                        )
                    }

                    if isFinalRoot && (mask & readMask) != 0 {
                        throw DiagnosticDiskSinkError.insecureDirectoryPath(
                            component: component,
                            reason: "Root directory has read-granting extended ACL entry violating log confidentiality"
                        )
                    }
                }
                rc = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
            }
        } else {
            guard aclErrno == ENOENT else {
                throw DiagnosticDiskSinkError.insecureDirectoryPath(
                    component: component,
                    reason: "ACL inspection failed with errno \(aclErrno)"
                )
            }
        }
    }

    private func verifyChildDirectorySecurity(dirFd: Int32, childName: String) throws {
        let sb = try fileAdapter.stat(fd: dirFd)
        guard (sb.st_mode & S_IFMT) == S_IFDIR else {
            throw DiagnosticDiskSinkError.childVerificationFailed(reason: "Created child is not a directory")
        }
        let euid = geteuid()
        guard sb.st_uid == euid else {
            throw DiagnosticDiskSinkError.childVerificationFailed(reason: "Created child owned by uid \(sb.st_uid), expected \(euid)")
        }
        guard (sb.st_mode & 0o777) == 0o700 else {
            let modeOctal = String(sb.st_mode & 0o777, radix: 8)
            throw DiagnosticDiskSinkError.childVerificationFailed(reason: "Created child has mode 0o\(modeOctal), expected 0o700")
        }

        let (acl, aclErrno) = fileAdapter.getExtendedAcl(fd: dirFd)
        if let acl = acl {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t? = nil
            var rc = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)

            let disallowedMask: UInt64 = UInt64(ACL_WRITE_DATA.rawValue) |
                                        UInt64(ACL_ADD_FILE.rawValue) |
                                        UInt64(ACL_APPEND_DATA.rawValue) |
                                        UInt64(ACL_ADD_SUBDIRECTORY.rawValue) |
                                        UInt64(ACL_DELETE.rawValue) |
                                        UInt64(ACL_DELETE_CHILD.rawValue) |
                                        UInt64(ACL_WRITE_ATTRIBUTES.rawValue) |
                                        UInt64(ACL_WRITE_EXTATTRIBUTES.rawValue) |
                                        UInt64(ACL_WRITE_SECURITY.rawValue) |
                                        UInt64(ACL_CHANGE_OWNER.rawValue) |
                                        UInt64(ACL_READ_DATA.rawValue) |
                                        UInt64(ACL_LIST_DIRECTORY.rawValue) |
                                        UInt64(ACL_READ_ATTRIBUTES.rawValue) |
                                        UInt64(ACL_READ_EXTATTRIBUTES.rawValue)

            while rc == 0, let currentEntry = entry {
                var tag: acl_tag_t = ACL_UNDEFINED_TAG
                _ = acl_get_tag_type(currentEntry, &tag)
                if tag == ACL_EXTENDED_ALLOW {
                    var mask: acl_permset_mask_t = 0
                    _ = acl_get_permset_mask_np(currentEntry, &mask)
                    if (mask & disallowedMask) != 0 {
                        throw DiagnosticDiskSinkError.childVerificationFailed(
                            reason: "Created child has inherited or explicit allow-permission ACL entry"
                        )
                    }
                }
                rc = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
            }
        } else {
            guard aclErrno == ENOENT else {
                throw DiagnosticDiskSinkError.childVerificationFailed(reason: "ACL inspection failed with errno \(aclErrno)")
            }
        }
    }

    private func cleanupResourcesOnSetupFailure(parentFd: Int32, childName: String) -> DiagnosticDiskSinkError? {
        var firstCleanupErr: DiagnosticDiskSinkError? = nil

        // Disarm and close open stream descriptors once
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

        // Disarm and close dirFd once
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

        // ABANDONMENT POLICY: The sink never removes its own session directories or files.
        // Owned objects are abandoned on disk and reported.
        return firstCleanupErr
    }

    // MARK: - Synchronous Ingress Writing

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

        if state.tailBuffer.count > configuration.tailTrimThreshold {
            let excess = state.tailBuffer.count - configuration.tailBudget
            state.tailBuffer.removeFirst(excess)
        }
    }

    // MARK: - Under-Cap Appending

    private func addCount(_ current: UInt64, _ amount: UInt64) -> UInt64 {
        let (value, overflow) = current.addingReportingOverflow(amount)
        if overflow { hasCounterOverflow = true }
        return overflow ? UInt64.max : value
    }

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
                state.retainedBytesOnDisk += UInt64(count)
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
        if activeError == nil {
            activeError = error
        }
    }

    // MARK: - Controlled Seal, Abort, and Terminal Publication

    public func abort() -> DiagnosticDiskSinkReceipt {
        if isSealed, let receipt = terminalReceipt {
            return receipt
        }
        isSealed = true
        releaseStorageReservationOnce()

        let stdoutRecord = streams[.stdout]?.snapshot() ?? fallbackRecord(stream: .stdout)
        let stderrRecord = streams[.stderr]?.snapshot() ?? fallbackRecord(stream: .stderr)

        for state in streams.values where state.fd >= 0 {
            let fdToClose = state.fd
            state.fd = -1
            do {
                try fileAdapter.close(fd: fdToClose)
                state.closeOutcome = .succeeded
            } catch {
                state.closeOutcome = failedOutcome(error, operation: .close)
                recordCleanup(error, operation: .close)
            }
        }

        if dirFd >= 0 {
            let fdToClose = dirFd
            dirFd = -1
            do {
                try fileAdapter.close(fd: fdToClose)
            } catch {
                recordCleanup(error, operation: .close)
            }
        }

        for state in streams.values {
            if state.status == .active {
                state.status = .failed
            }
        }

        let receipt = DiagnosticDiskSinkReceipt(
            sessionId: sessionId,
            directoryURL: directoryURL,
            stdoutRecord: stdoutRecord,
            stderrRecord: stderrRecord,
            metadataRecord: metadataRecord,
            sidecarPublished: false,
            sidecarURL: nil,
            parentDirectorySynced: false,
            isSealed: true,
            failure: activeError ?? .ioError(operation: .close, errno: EIO, message: "Sink aborted"),
            cleanupError: cleanupError,
            hasCounterOverflow: hasCounterOverflow,
            sessionDevice: acquiredDevice,
            sessionInode: acquiredInode,
            storageBudget: effectiveStorageBudget,
            initialScannedUsage: initialScannedUsage,
            storageReservation: reservedStorageAmount
        )
        self.terminalReceipt = receipt
        return receipt
    }

    public func finish() -> DiagnosticDiskSinkReceipt {
        if isSealed, let receipt = terminalReceipt {
            return receipt
        }
        isSealed = true
        releaseStorageReservationOnce()

        // Sync streams
        for streamKind in DiagnosticStreamKind.allCases {
            guard let state = streams[streamKind] else { continue }
            if state.fd >= 0 {
                do {
                    try fileAdapter.sync(fd: state.fd)
                    state.syncOutcome = .succeeded
                } catch {
                    state.syncOutcome = failedOutcome(error, operation: .sync)
                    failClosed(error: error as? DiagnosticDiskSinkError ?? .ioError(operation: .sync, errno: EIO, message: "\(error)"))
                }
            }
        }

        // Close stream descriptors: disarm BEFORE close
        for streamKind in DiagnosticStreamKind.allCases {
            guard let state = streams[streamKind] else { continue }
            if state.fd >= 0 {
                let fdToClose = state.fd
                state.fd = -1
                do {
                    try fileAdapter.close(fd: fdToClose)
                    state.closeOutcome = .succeeded
                    if state.status == .active {
                        state.status = .sealed
                    }
                } catch {
                    state.closeOutcome = failedOutcome(error, operation: .close)
                    recordCleanup(error, operation: .close)
                    failClosed(error: error as? DiagnosticDiskSinkError ?? .ioError(operation: .close, errno: EIO, message: "\(error)"))
                }
            }
        }

        let stdoutRecord = streams[.stdout]?.snapshot() ?? fallbackRecord(stream: .stdout)
        let stderrRecord = streams[.stderr]?.snapshot() ?? fallbackRecord(stream: .stderr)

        var sidecarPublished = false
        var sidecarURL: URL? = nil
        var parentDirSynced = false

        if dirFd >= 0 {
            let tmpFileName = ".persistence.json.tmp.\(sessionId.uuidString)"
            let targetFileName = "persistence.json"

            var tmpFd: Int32 = -1
            didCreateTempSidecar = false

            do {
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

                let sidecar = DiagnosticPersistenceSidecar(
                    formatVersion: DiagnosticPersistenceSidecar.currentFormatVersion,
                    sinkSessionId: sessionId,
                    stdoutRecord: stdoutRecord,
                    stderrRecord: stderrRecord,
                    metadataRecord: metadataRecord,
                    maxBytesPerStream: configuration.maxBytesPerStream,
                    headBudget: configuration.headBudget,
                    tailBudget: configuration.tailBudget,
                    isSealed: true,
                    finalOutcome: activeError == nil ? "success" : "failure",
                    sessionDevice: acquiredDevice,
                    sessionInode: acquiredInode
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let encodedData = try encoder.encode(sidecar)

                guard encodedData.count <= configuration.maxSidecarBytes else {
                    throw DiagnosticDiskSinkError.sidecarTooLarge(
                        byteCount: encodedData.count,
                        maxBytes: configuration.maxSidecarBytes
                    )
                }

                do {
                    let written = try fileAdapter.write(fd: tmpFd, data: encodedData)
                    guard written == encodedData.count else {
                        throw DiagnosticDiskSinkError.shortWrite(
                            operation: .write,
                            bytesCommitted: written,
                            expectedBytes: encodedData.count
                        )
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

                let fdToClose = tmpFd
                tmpFd = -1
                do {
                    try fileAdapter.close(fd: fdToClose)
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

                do {
                    try fileAdapter.publishSidecar(dirFd: dirFd, tmpName: tmpFileName, targetName: targetFileName)
                    sidecarPublished = true
                    sidecarURL = directoryURL.appendingPathComponent(targetFileName)
                    metadataRecord.publishOutcome = .succeeded
                    didCreateTempSidecar = false
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
                // ABANDONMENT POLICY: Do not unlink tmp file if creation succeeded.
                // Leave it on disk abandoned and reported.
            }

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
            hasCounterOverflow: hasCounterOverflow,
            sessionDevice: acquiredDevice,
            sessionInode: acquiredInode,
            storageBudget: effectiveStorageBudget,
            initialScannedUsage: initialScannedUsage,
            storageReservation: reservedStorageAmount
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
