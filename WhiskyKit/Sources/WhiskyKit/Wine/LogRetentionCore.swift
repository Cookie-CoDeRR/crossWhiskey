//
//  LogRetentionCore.swift
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

/// Byte-level sink used by `LogRetention` so the retention policy can be unit-tested
/// with an in-memory mock (including deterministic fault injection) instead of a
/// real file handle. Production uses `FileHandleLogRetentionSink`.
protocol LogRetentionSink: AnyObject {
    /// Writes bytes at the sink's current offset, advancing the offset. May overwrite
    /// existing bytes when the offset was moved backwards by `seek(toOffset:)`.
    func write(_ data: Data) throws
    /// Moves the sink's current offset.
    func seek(toOffset offset: UInt64) throws
    /// Truncates the sink to the given total length.
    func truncate(atOffset offset: UInt64) throws
}

/// Production adapter driving a real log file through a write-only `FileHandle`.
/// The retention policy never reads the file back; every decision uses in-memory
/// tracking, so write-only handles are sufficient.
///
/// The handle is held WEAKLY on purpose: `WineLogCapRegistry` owns the retention
/// objects, so a strong reference here would keep every logged handle alive forever
/// and the registry's handle-deinit cleanup could never fire. If the owner releases
/// the handle without `closeWineLog()`, the next write throws `HandleGoneError`
/// and the policy freezes (fail-closed).
final class FileHandleLogRetentionSink: LogRetentionSink {
    struct HandleGoneError: Error {}

    private weak var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard let handle else { throw HandleGoneError() }
        try handle.write(contentsOf: data)
    }

    func seek(toOffset offset: UInt64) throws {
        guard let handle else { throw HandleGoneError() }
        try handle.seek(toOffset: offset)
    }

    func truncate(atOffset offset: UInt64) throws {
        guard let handle else { throw HandleGoneError() }
        try handle.truncate(atOffset: offset)
    }
}

/// Head+tail retention policy for a single growing log file.
///
/// This replaces the previous "freeze at cap" policy:
/// - Below the byte cap, bytes are written verbatim; an under-cap log is
///   byte-identical to what the process emitted.
/// - When a write would exceed the cap, the file is compacted in place to
///   `[startup head][discard marker][recent tail]` and writing continues.
///   The head is the first up-to-`headBudget` bytes of the stream (Whisky
///   version, arguments, environment keys); the tail is the most recent output.
/// - Every discard writes a marker naming the running discard-event count, so a
///   reader can always tell the log was cut and how many times.
/// - Fail-closed: on any I/O error the policy disables itself and drops all
///   further output, rather than risking unbounded growth or repeated corruption.
///
/// Failure disclosure: compaction rewrites the file in place (a write-only handle
/// cannot be swapped atomically). If the rewrite itself fails mid-way, the prefix
/// may be partially updated; the policy then freezes and writes nothing further.
///
/// Memory per open handle is bounded: retained buffers are `headBudget` (4 MiB)
/// plus at most `tailTrimThreshold` (16 MiB) for the rolling tail; compaction
/// additionally builds one transient rewrite buffer (post-compaction content,
/// <= `headBudget` + marker + `tailBudget`), and each write briefly holds the
/// caller-supplied chunk.
///
/// Thread safety: NOT thread-safe. Callers must serialize writes per file
/// (`WineLogCapRegistry` serializes under one lock).
final class LogRetention {
    struct Config {
        /// Total file size cap, including markers.
        var maxBytes: Int64
        /// How many leading stream bytes are preserved as the startup section.
        var headBudget: Int = 4 * 1_024 * 1_024
        /// Post-compaction tail target.
        var tailBudget: Int = 12 * 1_024 * 1_024
        /// Lazy in-memory trim point for the rolling tail.
        var tailTrimThreshold: Int = 16 * 1_024 * 1_024

        init(
            maxBytes: Int64,
            headBudget: Int = 4 * 1_024 * 1_024,
            tailBudget: Int = 12 * 1_024 * 1_024,
            tailTrimThreshold: Int = 16 * 1_024 * 1_024
        ) {
            precondition(
                Int64(headBudget + tailBudget + 1_024) <= maxBytes,
                "LogRetention config budgets must fit within maxBytes"
            )
            self.maxBytes = maxBytes
            self.headBudget = headBudget
            self.tailBudget = tailBudget
            self.tailTrimThreshold = tailTrimThreshold
        }
    }

    private let sink: LogRetentionSink
    private let config: Config
    /// First up-to-`headBudget` bytes of the RETAINED stream (markers are never
    /// tracked). Fill-once. Equals the file prefix whenever no discard happened
    /// before the head filled; after a first-write cut it holds the start of the
    /// earliest retained content instead.
    private var head = Data()
    private var headComplete = false
    /// Most recent stream bytes (markers excluded), trimmed lazily.
    private var tail = Data()
    /// Current file size in bytes, including markers.
    private var totalBytes: Int64
    /// Running count of discard events (compactions and clamped writes). The marker
    /// written at each event carries this count.
    private(set) var discardEvents = 0
    /// True once the policy has frozen after an I/O failure or a freeze-marker.
    private(set) var disabled = false
    /// True when the file already had content we could not inspect (e.g. a
    /// reopened log). Such files fall back to the previous freeze-at-cap policy
    /// so unknown existing content is never destroyed by a blind rewrite.
    private let untrackedPrefix: Bool
    private var wroteFreezeMarker = false

    /// - Parameter existingBytes: current size of the file being logged to
    ///   (0 for a freshly created log).
    init(sink: LogRetentionSink, config: Config, existingBytes: Int64 = 0) {
        self.sink = sink
        self.config = config
        totalBytes = existingBytes
        untrackedPrefix = existingBytes > 0
    }

    /// The single marker text used for every discard event (compaction or clamp),
    /// carrying the running event count so repeated compactions stay honest.
    /// The text is pure ASCII, so slicing it never breaks UTF-8.
    static func discardMarkerText(event: Int) -> String {
        """
        \n[Whisky] Log retention: discarded output (event #\(event)) to stay under the size cap; \
        content between the startup header and the latest retained output is incomplete.\n
        """
    }

    static func discardMarker(event: Int) -> Data {
        Data(discardMarkerText(event: event).utf8)
    }

    func write(_ data: Data) {
        guard !disabled, !data.isEmpty else { return }
        do {
            if untrackedPrefix {
                // Reserve room for the freeze marker so it is always written whole.
                let dataCap = config.maxBytes - Int64(Self.discardMarker(event: discardEvents + 1).count)
                if totalBytes + Int64(data.count) > dataCap {
                    try freezeWithMarker()
                    return
                }
            } else if totalBytes + Int64(data.count) > config.maxBytes {
                if !head.isEmpty || !tail.isEmpty {
                    try compact(leavingRoomFor: data.count)
                }
                if totalBytes + Int64(data.count) > config.maxBytes {
                    try writeClamped(data)
                    return
                }
            }
            try sink.write(data)
            totalBytes += Int64(data.count)
            track(data)
        } catch {
            disabled = true
        }
    }

    // MARK: - Internals

    /// Previous-policy fallback for files whose existing bytes we never saw:
    /// append one full marker and freeze, never rewriting unknown content.
    /// If the pre-existing file already meets or exceeds the cap there is no room
    /// for the marker; the policy then freezes without writing anything (the
    /// existing oversize is NOT repaired) and counts no discard event.
    private func freezeWithMarker() throws {
        guard !wroteFreezeMarker else { return }
        let marker = Self.discardMarker(event: discardEvents + 1)
        let room = config.maxBytes - totalBytes
        if room > 0 {
            let slice = marker.prefix(Int(Swift.min(room, Int64(marker.count))))
            try sink.write(slice)
            totalBytes += Int64(slice.count)
            discardEvents += 1
        }
        wroteFreezeMarker = true
        disabled = true
    }

    /// Rewrites the file as [head][marker][tail], leaving room for the incoming
    /// write when possible. On failure the file may be partially rewritten
    /// (documented above); the caller then freezes.
    private func compact(leavingRoomFor incomingCount: Int) throws {
        let marker = Self.discardMarker(event: discardEvents + 1)
        var content = Data()
        content.reserveCapacity(head.count + marker.count + Swift.min(tail.count, config.tailBudget))
        content.append(head)
        content.append(marker)
        let reservation = Swift.min(incomingCount, config.tailBudget)
        let room = Int(config.maxBytes) - head.count - marker.count - reservation
        // Cap at tailBudget explicitly: without this, a small incoming write would
        // let the file regrow almost to maxBytes and force a compaction per write.
        let tailCap = Swift.max(0, Swift.min(room, config.tailBudget))
        var tailPart = tail
        if tailPart.count > tailCap {
            let start = Self.safeSuffixStart(tailPart, dropFirst: tailPart.count - tailCap)
            tailPart = Data(tailPart[tailPart.index(tailPart.startIndex, offsetBy: start)...])
        }
        content.append(tailPart)
        try sink.seek(toOffset: 0)
        try sink.write(content)
        try sink.truncate(atOffset: UInt64(content.count))
        discardEvents += 1
        totalBytes = Int64(content.count)
        tail = tailPart
    }

    /// Handles a single write too large to fit even after compaction: writes a
    /// marker, then as much of the write's SUFFIX as fits (boundary-snapped) -
    /// the most recent output is what matters for post-mortem diagnosis. The
    /// discarded earlier part of the write is disclosed by the marker.
    private func writeClamped(_ data: Data) throws {
        let marker = Self.discardMarker(event: discardEvents + 1)
        var room = Int(config.maxBytes - totalBytes)
        // If not even the marker fits, drop the chunk without counting: nothing
        // was written, so the file still ends at intact content.
        guard room > marker.count else { return }
        discardEvents += 1
        try sink.write(marker)
        totalBytes += Int64(marker.count)
        room -= marker.count
        let start = Self.safeSuffixStart(data, dropFirst: data.count - room)
        guard start < data.count else { return }
        let piece = Data(data[data.index(data.startIndex, offsetBy: start)...])
        try sink.write(piece)
        totalBytes += Int64(piece.count)
        track(piece)
    }

    /// Records stream bytes actually written (markers excluded) for head/tail tracking.
    private func track(_ data: Data) {
        if !headComplete {
            let room = config.headBudget - head.count
            if room >= data.count {
                head.append(data)
            } else {
                let cut = Self.contentCut(data, maxLength: room)
                head.append(data.prefix(cut))
                headComplete = true
            }
        }
        tail.append(data)
        if tail.count > config.tailTrimThreshold {
            let start = Self.safeSuffixStart(tail, dropFirst: tail.count - config.tailBudget)
            tail = Data(tail[tail.index(tail.startIndex, offsetBy: start)...])
        }
    }

    // MARK: - Boundary helpers

    /// Largest `n <= maxLength` such that `data[0..<n]` does not split a UTF-8
    /// sequence: the byte at `n - 1` ends a complete character. For valid UTF-8
    /// input the returned prefix is valid UTF-8; malformed input is truncated to
    /// a boundary without introducing new invalid sequences.
    static func utf8SafePrefixLength(_ data: Data, maxLength: Int) -> Int {
        var cut = Swift.min(Swift.max(0, maxLength), data.count)
        while cut > 0 {
            let last = data[data.startIndex + cut - 1]
            if last & 0x80 == 0 { return cut }
            var leadIndex = cut - 1
            var scanned = 0
            while leadIndex >= 0, scanned < 4, (data[data.startIndex + leadIndex] & 0xC0) == 0x80 {
                leadIndex -= 1
                scanned += 1
            }
            if leadIndex >= 0, scanned < 4 {
                let lead = data[data.startIndex + leadIndex]
                if lead & 0xE0 == 0xC0, leadIndex + 2 == cut { return cut }
                if lead & 0xF0 == 0xE0, leadIndex + 3 == cut { return cut }
                if lead & 0xF8 == 0xF0, leadIndex + 4 == cut { return cut }
            }
            // The final character is incomplete or malformed at the cut: drop it
            // and re-verify the shorter prefix.
            cut = Swift.max(0, leadIndex)
        }
        return 0
    }

    /// Cut point for keeping a prefix of `data` within `maxLength`: just after the
    /// last newline when one exists (keeps lines whole), else a UTF-8-safe boundary.
    static func contentCut(_ data: Data, maxLength: Int) -> Int {
        let cut = Swift.min(Swift.max(0, maxLength), data.count)
        guard cut > 0 else { return 0 }
        guard cut < data.count else { return data.count }
        let windowEnd = data.index(data.startIndex, offsetBy: cut)
        if let newline = data[..<windowEnd].lastIndex(of: 0x0A) {
            return data.distance(from: data.startIndex, to: newline) + 1
        }
        return utf8SafePrefixLength(data, maxLength: cut)
    }

    /// Start index for keeping a suffix of `data` after dropping `count` bytes:
    /// just after the first newline at or past the drop point when one exists,
    /// else the next UTF-8 character boundary.
    static func safeSuffixStart(_ data: Data, dropFirst count: Int) -> Int {
        let start = Swift.min(Swift.max(0, count), data.count)
        // Prefer whole lines, but bound the search so one long line cannot make
        // us drop far more than requested.
        let scanLimit = Swift.min(data.count, start + 4_096)
        let window = data[data.index(data.startIndex, offsetBy: start) ..< data.index(
            data.startIndex,
            offsetBy: scanLimit
        )]
        if let newline = window.firstIndex(of: 0x0A) {
            return data.distance(from: data.startIndex, to: newline) + 1
        }
        var boundary = start
        while boundary < data.count, (data[data.startIndex + boundary] & 0xC0) == 0x80 {
            boundary += 1
        }
        return boundary
    }
}
