//
//  FileHandle+Extensions.swift
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

import Darwin
import Foundation
@preconcurrency import ObjectiveC
import os.log
import SemanticVersion

private final class WineLogCapRegistry: @unchecked Sendable {
    static let shared = WineLogCapRegistry()

    private let lock = NSLock()
    private var retentions: [ObjectIdentifier: LogRetention] = [:]
    private nonisolated(unsafe) static var deinitObserverKey: UInt8 = 0

    private final class DeinitObserver {
        let onDeinit: () -> Void
        init(onDeinit: @escaping () -> Void) {
            self.onDeinit = onDeinit
        }

        deinit { onDeinit() }
    }

    private init() {}

    func write(_ data: Data, to handle: FileHandle) {
        let key = ObjectIdentifier(handle)
        attachDeinitObserverIfNeeded(to: handle, key: key)

        lock.lock()
        defer { lock.unlock() }

        // `LogRetention` holds reference-owned buffers, so copying it out of the
        // dictionary per write is pointer-cheap and does not copy log content.
        let retention = retentions[key] ?? LogRetention(
            sink: FileHandleLogRetentionSink(handle: handle),
            config: LogRetention.Config(maxBytes: Wine.maxLogFileBytes),
            existingBytes: currentSizeBytes(for: handle)
        )
        retentions[key] = retention
        retention.write(data)
    }

    func removeState(for handle: FileHandle) {
        removeState(forKey: ObjectIdentifier(handle))
    }

    private func removeState(forKey key: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        retentions.removeValue(forKey: key)
    }

    private func attachDeinitObserverIfNeeded(to handle: FileHandle, key: ObjectIdentifier) {
        // Ensure state is cleared even if `closeWineLog()` isn't called (e.g., early returns / errors).
        if objc_getAssociatedObject(handle, &Self.deinitObserverKey) != nil { return }
        let observer = DeinitObserver { [weak self] in
            self?.removeState(forKey: key)
        }
        objc_setAssociatedObject(handle, &Self.deinitObserverKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func currentSizeBytes(for handle: FileHandle) -> Int64 {
        do {
            // Ensures subsequent writes remain append-only.
            let offset = try handle.seekToEnd()
            return Int64(offset)
        } catch {
            Logger.wineKit.info("Failed to determine current file size; seekToEnd() threw: \(error)")
            // Fall back to `fstat` (doesn't require seeking) to avoid unnecessarily disabling logging.
            var fileStat = stat()
            if fstat(handle.fileDescriptor, &fileStat) == 0 {
                return Int64(fileStat.st_size)
            }

            // If we still can't determine the current size, assume the cap is already reached to avoid writing past it.
            return Wine.maxLogFileBytes
        }
    }
}

extension FileHandle {
    private enum Constants {
        /// Prevents extremely large environments from bloating logs while still providing useful diagnostics.
        static let maxEnvironmentKeysToLog = 200
    }

    func extract<T>(_ type: T.Type, offset: UInt64 = 0) -> T? {
        do {
            try self.seek(toOffset: offset)
            // A read straddling EOF returns fewer bytes than requested;
            // loading T from the short buffer would read out of bounds.
            if let data = try self.read(upToCount: MemoryLayout<T>.size),
               data.count >= MemoryLayout<T>.size {
                return data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    func write(line: String) {
        do {
            guard let data = line.data(using: .utf8) else { return }
            try write(contentsOf: data)
        } catch {
            Logger.wineKit.info("Failed to write line: \(error)")
        }
    }

    /// Writes a line to a Whisky log file while enforcing the log size cap.
    ///
    /// This method is thread-safe across concurrent stdout/stderr writers for the same file handle.
    /// When a write would exceed the per-file cap, the log is compacted in place to its
    /// startup section plus the most recent output, with a numbered discard marker; writing
    /// then continues. On any logging I/O error the policy freezes and drops further output.
    func writeWineLog(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        WineLogCapRegistry.shared.write(data, to: self)
    }

    /// Closes a Whisky log file handle and clears any associated in-memory cap state.
    func closeWineLog() throws {
        defer {
            WineLogCapRegistry.shared.removeState(for: self)
        }
        try close()
    }

    func writeApplicationInfo() {
        var header = String()
        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersionString =
            "\(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)"

        header += "Whisky Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")\n"
        header += "Date: \(ISO8601DateFormatter().string(from: Date.now))\n"
        header += "macOS Version: \(macOSVersionString)\n\n"
        writeWineLog(line: header)
    }

    func writeInfo(for process: Process) {
        var header = String()

        if let arguments = process.arguments {
            header += "Arguments: \(arguments.joined(separator: " "))\n\n"
        }

        if let environment = process.environment, !environment.isEmpty {
            // Avoid persisting raw environment values to logs (can contain secrets like tokens, API keys, etc.).
            let maxKeysToLog = Constants.maxEnvironmentKeysToLog
            let sortedKeys = environment.keys.sorted()
            let keysToLog = sortedKeys.prefix(maxKeysToLog)
            let keysDescription = keysToLog.joined(separator: ", ")
            header += "Environment (keys only):\n\(keysDescription)"
            if sortedKeys.count > maxKeysToLog {
                header += "\n... (\(sortedKeys.count - maxKeysToLog) more)"
            }
            header += "\n\n"
        }

        writeWineLog(line: header)
    }

    @MainActor
    func writeInfo(for bottle: Bottle) {
        var header = String()
        header += "Bottle Name: \(bottle.settings.name)\n"
        header += "Bottle URL: \(bottle.url.path)\n\n"

        if let version = WhiskyWineInstaller.whiskyWineVersion() {
            header += "WhiskyWine Version: \(version.major).\(version.minor).\(version.patch)\n"
        }
        header += "Windows Version: \(bottle.settings.windowsVersion)\n"
        header += "Enhanced Sync: \(bottle.settings.enhancedSync)\n\n"

        header += "Metal HUD: \(bottle.settings.metalHud)\n"
        header += "Metal Trace: \(bottle.settings.metalTrace)\n\n"

        if bottle.settings.dxvk {
            header += "DXVK: \(bottle.settings.dxvk)\n"
            header += "DXVK Async: \(bottle.settings.dxvkAsync)\n"
            header += "DXVK HUD: \(bottle.settings.dxvkHud)\n\n"
        }

        writeWineLog(line: header)
    }
}
