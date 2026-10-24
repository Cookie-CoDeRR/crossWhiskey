//
//  WineLogCompactionTests.swift
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

#if canImport(WhiskyKit)
@testable import WhiskyKit
#else
@testable import WhiskyKitLogRetention
#endif
import XCTest

/// Tests for `LogRetention`, the head+tail log retention core.
///
/// These tests run against an in-memory sink (and a real `FileHandle` for the
/// end-to-end case) and need no macOS-only APIs.
final class WineLogCompactionTests: XCTestCase {
    // MARK: - Mock sink

    private struct InjectedFault: Error {}

    private final class MockSink: LogRetentionSink {
        private(set) var storage = Data()
        private(set) var offset = 0
        private(set) var writeCallCount = 0
        /// One-shot fault flags: the NEXT call of that operation throws
        /// (for writes optionally after splicing only `partialBytes`).
        var failNextWrite = false
        var failNextSeek = false
        var failNextTruncate = false
        var partialNextWrite: Int?

        func write(_ data: Data) throws {
            writeCallCount += 1
            if failNextWrite {
                failNextWrite = false
                throw InjectedFault()
            }
            if let partial = partialNextWrite {
                partialNextWrite = nil
                splice(data.prefix(partial))
                throw InjectedFault()
            }
            splice(data)
        }

        func seek(toOffset newOffset: UInt64) throws {
            if failNextSeek {
                failNextSeek = false
                throw InjectedFault()
            }
            offset = Int(newOffset)
        }

        func truncate(atOffset newOffset: UInt64) throws {
            if failNextTruncate {
                failNextTruncate = false
                throw InjectedFault()
            }
            storage = Data(storage.prefix(Int(newOffset)))
            if offset > storage.count { offset = storage.count }
        }

        func splice(_ data: Data) {
            if offset + data.count > storage.count {
                storage.append(Data(count: offset + data.count - storage.count))
            }
            storage.replaceSubrange(offset ..< offset + data.count, with: data)
            offset += data.count
        }
    }

    // Small config so boundary behavior is exercised with tiny inputs.
    private func smallConfig(maxBytes: Int64 = 2_048) -> LogRetention.Config {
        LogRetention.Config(maxBytes: maxBytes, headBudget: 64, tailBudget: 128, tailTrimThreshold: 256)
    }

    private let markerToken = "[Whisky] Log retention: discarded output (event #"

    private func markerOccurrences(in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: markerToken).count - 1
    }

    /// Event number carried by the LAST marker still present in the file.
    private func lastMarkerEvent(in data: Data) -> Int? {
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: markerToken)
        guard parts.count > 1, let last = parts.last,
              let close = last.firstIndex(of: ")")
        else { return nil }
        return Int(last[last.startIndex ..< close])
    }

    private func strictDecode(_ data: Data) -> String? {
        String(bytes: data, encoding: .utf8)
    }

    // MARK: - utf8SafePrefixLength

    /// Independent oracle: character-boundary offsets of a known-valid string.
    private func boundaries(of string: String) -> [Int] {
        var result = [0]
        var offset = 0
        for character in string {
            offset += String(character).utf8.count
            result.append(offset)
        }
        return result
    }

    func testUTF8SafePrefixLengthExhaustiveOverValidStrings() {
        // 1-, 2-, 3- and 4-byte characters, including range edges.
        let samples = [
            "a",
            "\u{7F}",
            "\u{80}",
            "\u{7FF}",
            "\u{800}",
            "\u{FFFF}",
            "\u{10000}",
            "\u{10FFFF}",
            "é",
            "€",
            "😀",
            "ab\u{80}cd\u{FFFF}e\u{10FFFF}fg",
        ]
        for sample in samples {
            let data = Data(sample.utf8)
            let valid = boundaries(of: sample)
            for cut in 0 ... data.count {
                let result = LogRetention.utf8SafePrefixLength(data, maxLength: cut)
                let expected = valid.filter { $0 <= cut }.max() ?? 0
                XCTAssertEqual(result, expected, "cut=\(cut) in \(sample.debugDescription)")
                XCTAssertNotNil(strictDecode(data.prefix(result)))
            }
        }
    }

    func testUTF8SafePrefixLengthSystematicLeadBytes() {
        // Every lead-byte bit pattern (C0...F7) with canonical continuation bytes,
        // at all cut positions. (C0/C1/F5-F7 are out-of-range per RFC 3629, but the
        // helper detects boundaries by bit pattern; validation is the caller's job.)
        for leadByte in UInt8(0xC0) ... UInt8(0xF7) {
            let length = (leadByte & 0xE0 == 0xC0) ? 2 : (leadByte & 0xF0 == 0xE0) ? 3 : 4
            var bytes = [leadByte] + [UInt8](repeating: 0x80, count: length - 1)
            bytes.insert(0x41, at: 0) // ASCII prefix so a boundary always exists
            let data = Data(bytes)
            for cut in 0 ... data.count {
                let result = LogRetention.utf8SafePrefixLength(data, maxLength: cut)
                let expected = cut <= 1 ? cut : (cut == data.count ? data.count : 1)
                XCTAssertEqual(result, expected, "lead=\(String(format: "%02X", leadByte)) cut=\(cut)")
            }
        }
        // Bytes matching no lead pattern (F8...FF) are treated as malformed: the
        // helper drops back to the last good boundary rather than trusting them.
        for leadByte in UInt8(0xF8) ... UInt8(0xFF) {
            let data = Data([0x41, leadByte, 0x80, 0x80, 0x80])
            for cut in 0 ... data.count {
                let result = LogRetention.utf8SafePrefixLength(data, maxLength: cut)
                XCTAssertGreaterThanOrEqual(result, 0)
                XCTAssertLessThanOrEqual(
                    result,
                    Swift.min(cut, 1),
                    "invalid lead must not be trusted: lead=\(String(format: "%02X", leadByte)) cut=\(cut)"
                )
            }
        }
    }

    func testUTF8SafePrefixLengthMalformedInputStaysInBounds() {
        let malformed: [[UInt8]] = [
            [0xA9],
            [0xA9, 0xA9],
            [0xC3],
            [0x41, 0xC3],
            [0x41, 0xA9, 0xA9, 0xA9, 0xA9, 0xA9], // 5 continuations
            [0xC3, 0xC3, 0xA9],
        ]
        for bytes in malformed {
            let data = Data(bytes)
            for cut in 0 ... data.count {
                let result = LogRetention.utf8SafePrefixLength(data, maxLength: cut)
                XCTAssertGreaterThanOrEqual(result, 0)
                XCTAssertLessThanOrEqual(result, cut, "bytes=\(bytes) cut=\(cut)")
            }
        }
    }

    func testUTF8SafePrefixLengthCompleteSequenceAtCut() {
        // Regression: C3 A9 with cut 2 must retain both bytes.
        let data = Data([0xC3, 0xA9])
        XCTAssertEqual(LogRetention.utf8SafePrefixLength(data, maxLength: 2), 2)
        XCTAssertEqual(LogRetention.utf8SafePrefixLength(data, maxLength: 1), 0)
        // E2 82 AC (euro sign): cut 2 drops the partial sequence.
        let euro = Data("€".utf8)
        XCTAssertEqual(LogRetention.utf8SafePrefixLength(euro, maxLength: 3), 3)
        XCTAssertEqual(LogRetention.utf8SafePrefixLength(euro, maxLength: 2), 0)
        XCTAssertEqual(LogRetention.utf8SafePrefixLength(euro, maxLength: 1), 0)
    }

    // MARK: - contentCut / safeSuffixStart

    func testContentCutPrefersNewline() {
        let data = Data("aaa\nbbb\nccc".utf8)
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 9), 8) // after second \n
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 3), 3) // no newline, ASCII
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 0), 0)
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 100), data.count)
    }

    func testContentCutNoNewlineUsesUTF8Boundary() {
        let data = Data("abé".utf8) // 61 62 C3 A9
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 3), 2)
        XCTAssertEqual(LogRetention.contentCut(data, maxLength: 4), 4)
    }

    func testSafeSuffixStartPrefersNewlineThenBoundary() {
        let data = Data("xx\nyy\nzz".utf8)
        XCTAssertEqual(LogRetention.safeSuffixStart(data, dropFirst: 1), 3)
        let multibyte = Data("é€😀".utf8) // 2+3+4 bytes, no newlines
        XCTAssertEqual(LogRetention.safeSuffixStart(multibyte, dropFirst: 1), 2)
        XCTAssertEqual(LogRetention.safeSuffixStart(multibyte, dropFirst: 3), 5)
        XCTAssertEqual(LogRetention.safeSuffixStart(multibyte, dropFirst: 100), multibyte.count)
    }

    // MARK: - Policy: verbatim under cap

    func testUnderCapWritesAreVerbatim() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig())
        retention.write(Data("header line\n".utf8))
        retention.write(Data("body é€😀\n".utf8))
        XCTAssertEqual(sink.storage, Data("header line\nbody é€😀\n".utf8))
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertFalse(retention.disabled)
    }

    // MARK: - Policy: compaction

    func testCompactionPreservesHeadMarkerAndTail() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_600))
        retention.write(Data("STARTUP-HEADER-LINE\n".utf8))
        var lineNumber = 0
        while lineNumber < 500, sink.storage.count < 10_000 {
            retention.write(Data("line-\(lineNumber)-xxxxxxxxxx\n".utf8))
            lineNumber += 1
            XCTAssertLessThanOrEqual(sink.storage.count, 1_600)
        }
        retention.write(Data("TAIL-SENTINEL-FINAL\n".utf8))
        XCTAssertGreaterThan(retention.discardEvents, 0)
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text, "compacted log must remain strict UTF-8")
        XCTAssertTrue(text?.hasPrefix("STARTUP-HEADER-LINE\n") == true)
        // The file ends with the true final bytes of the stream.
        XCTAssertTrue(text?.hasSuffix("TAIL-SENTINEL-FINAL\n") == true)
        XCTAssertEqual(lastMarkerEvent(in: sink.storage), retention.discardEvents)
    }

    func testRepeatedCompactionsStayUnderCapAndDecodable() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 2_048))
        for i in 0 ..< 2_000 {
            retention.write(Data("entry \(i) é€😀 padding padding padding\n".utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 2_048, "cap exceeded at write \(i)")
        }
        XCTAssertGreaterThan(retention.discardEvents, 5)
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertEqual(lastMarkerEvent(in: sink.storage), retention.discardEvents)
        XCTAssertTrue(text?.contains("entry 1999 ") == true)
    }

    func testExactCapBoundary() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        retention.write(Data(count: 1_300)) // exactly at cap: verbatim
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertEqual(sink.storage.count, 1_300)
        retention.write(Data([0x41])) // one byte over: compacts, byte still fits
        XCTAssertEqual(retention.discardEvents, 1)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
    }

    func testHugeSingleWriteKeepsRecentSuffix() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        retention.write(Data("intro\n".utf8))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x42, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        XCTAssertGreaterThanOrEqual(retention.discardEvents, 1)
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text)
        // The RECENT end of the oversized write is retained; its start is discarded.
        XCTAssertTrue(text?.contains("HUGE-CHUNK-END") == true)
        XCTAssertFalse(text?.contains("HUGE-CHUNK-START") == true)
        XCTAssertEqual(markerOccurrences(in: sink.storage), retention.discardEvents)
    }

    func testHugeFirstWriteWritesSingleMarkerAndKeepsSuffix() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x43, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("HUGE-CHUNK-END") == true)
        XCTAssertFalse(text?.contains("HUGE-CHUNK-START") == true)
        // Nothing was retained before the cut, so exactly one marker is written.
        XCTAssertEqual(markerOccurrences(in: sink.storage), 1)
        XCTAssertEqual(retention.discardEvents, 1)
    }

    func testMultibyteSplitAcrossCompactionsStaysValid() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        for _ in 0 ..< 2_000 {
            retention.write(Data("é€😀\n".utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        }
        XCTAssertNotNil(strictDecode(sink.storage))
    }

    // MARK: - Policy: huge first write then repeated compaction

    func testHugeFirstWriteThenRepeatedCompactions() {
        // Regression: after a huge FIRST write (file starts with a marker, head
        // holds the earliest retained content), later compactions must still keep
        // the latest tail, strict UTF-8, and honest disclosure as the leading
        // marker is replaced.
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x44, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertEqual(markerOccurrences(in: sink.storage), 1)

        var lastLine = ""
        for i in 0 ..< 2_000 {
            lastLine = "after-\(i)-line\n"
            retention.write(Data(lastLine.utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 1_300, "cap exceeded at write \(i)")
        }
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text, "log must remain strict UTF-8 after repeated compactions")
        XCTAssertTrue(text?.hasSuffix(lastLine) == true, "latest stream tail must survive")
        // Disclosure persists: the current marker reflects the total event count.
        XCTAssertEqual(lastMarkerEvent(in: sink.storage), retention.discardEvents)
        XCTAssertGreaterThan(retention.discardEvents, 5)
    }

    // MARK: - Policy: pre-existing oversize file

    func testPreExistingOversizeFileFreezesWithoutTrap() {
        // existingBytes already over the cap: no room for any marker. The policy
        // must freeze safely (no negative-prefix trap), write nothing, and leave
        // the unknown oversize content untouched and unrepaired.
        let sink = MockSink()
        let existing = Data(repeating: 0x45, count: 2_000)
        sink.splice(existing)
        let retention = LogRetention(
            sink: sink,
            config: smallConfig(maxBytes: 1_300),
            existingBytes: Int64(existing.count)
        )
        retention.write(Data("new data\n".utf8))
        XCTAssertTrue(retention.disabled)
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertEqual(sink.storage, existing, "no bytes may be written to an oversize pre-existing file")
        retention.write(Data("more\n".utf8))
        XCTAssertEqual(sink.storage, existing)
    }

    // MARK: - Policy: no compaction churn

    func testCompactionLeavesDeterministicHeadroom() {
        // Scaled-down production ratios: tailTrimThreshold (16) exceeds the room a
        // small write leaves after compaction, which would re-trigger a compaction
        // nearly every write if the tail were not explicitly capped at tailBudget.
        let sink = MockSink()
        let config = LogRetention.Config(
            maxBytes: 20_480,
            headBudget: 4_096,
            tailBudget: 12_288,
            tailTrimThreshold: 16_384
        )
        let retention = LogRetention(sink: sink, config: config)
        let line = Data((String(repeating: "q", count: 39) + "\n").utf8) // 40 bytes
        for _ in 0 ..< 1_200 { // ~48 KB, over 2x the cap
            retention.write(line)
        }
        XCTAssertLessThanOrEqual(sink.storage.count, 20_480)
        // ~1 compaction per (cap - head - marker - tailBudget) / 40 bytes ~= 100 writes;
        // without the explicit tailBudget cap this would churn near 1 per write.
        XCTAssertLessThanOrEqual(
            retention.discardEvents,
            15,
            "compaction churn: \(retention.discardEvents) events for 1_200 writes"
        )
        XCTAssertNotNil(strictDecode(sink.storage))
    }

    // MARK: - Policy: handle lifecycle

    func testSinkDoesNotRetainHandleAndFreezesWhenHandleDies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-retention-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        var handle: FileHandle? = try FileHandle(forWritingTo: file)
        weak var weakHandle = handle
        let retention = LogRetention(
            sink: FileHandleLogRetentionSink(handle: handle!),
            config: smallConfig()
        )
        retention.write(Data("before\n".utf8))
        XCTAssertFalse(retention.disabled)

        try handle?.closeFile()
        handle = nil
        XCTAssertNil(weakHandle, "the sink must not retain the file handle")

        retention.write(Data("after\n".utf8))
        XCTAssertTrue(retention.disabled, "writes after handle death must freeze the policy")
        let onDisk = try Data(contentsOf: file)
        XCTAssertEqual(onDisk, Data("before\n".utf8))
    }

    // MARK: - Policy: untracked prefix fallback

    func testPreExistingFileFreezesWithoutDestroyingContent() {
        let sink = MockSink()
        let existing = Data("PRE-EXISTING-UNKNOWN-CONTENT\n".utf8)
        sink.splice(existing)
        let retention = LogRetention(
            sink: sink,
            config: smallConfig(maxBytes: 1_600),
            existingBytes: Int64(existing.count)
        )
        for i in 0 ..< 200 {
            retention.write(Data("more \(i)\n".utf8))
        }
        XCTAssertTrue(sink.storage.starts(with: existing), "unknown existing content must be preserved")
        XCTAssertLessThanOrEqual(sink.storage.count, 1_600)
        XCTAssertEqual(markerOccurrences(in: sink.storage), 1)
        XCTAssertTrue(retention.disabled)
    }

    // MARK: - Policy: fault injection

    func testNormalWriteFailureFreezesWithoutDrift() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig())
        retention.write(Data("ok\n".utf8))
        sink.failNextWrite = true
        retention.write(Data("boom\n".utf8))
        XCTAssertTrue(retention.disabled)
        retention.write(Data("dropped\n".utf8))
        XCTAssertEqual(sink.storage, Data("ok\n".utf8))
        XCTAssertEqual(retention.discardEvents, 0)
    }

    func testCompactionSeekFailureFreezes() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        retention.write(Data("head\n".utf8))
        sink.failNextSeek = true
        for _ in 0 ..< 200 {
            retention.write(Data(repeating: 0x41, count: 20))
        }
        XCTAssertTrue(retention.disabled)
        XCTAssertEqual(retention.discardEvents, 0, "failed compaction must not count as a discard event")
        // head(5) + 64 x 20 bytes fit (1285); the 65th write triggered the failed compaction.
        XCTAssertEqual(sink.storage, Data("head\n".utf8) + Data(repeating: 0x41, count: 64 * 20))
    }

    func testCompactionPartialWriteFailureFreezes() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        retention.write(Data("head\n".utf8))
        for _ in 0 ..< 64 {
            retention.write(Data(repeating: 0x41, count: 20)) // total now 1285
        }
        // The next write crosses the cap; make the compaction's content write
        // splice 3 bytes and then throw.
        sink.partialNextWrite = 3
        retention.write(Data(repeating: 0x43, count: 20))
        XCTAssertTrue(retention.disabled)
        XCTAssertEqual(retention.discardEvents, 0)
        retention.write(Data("later\n".utf8))
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
    }

    func testCompactionTruncateFailureFreezes() {
        let sink = MockSink()
        let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: 1_300))
        retention.write(Data("head\n".utf8))
        sink.failNextTruncate = true
        for _ in 0 ..< 200 {
            retention.write(Data(repeating: 0x41, count: 20))
        }
        XCTAssertTrue(retention.disabled)
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
    }

    // MARK: - Policy: seeded fuzz

    func testSeededFuzzInvariants() {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func nextRandom(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["a", "\n", "line of text here\n", "é", "€", "😀", String(repeating: "x", count: 50)]
        for configMax in [Int64(1_300), 2_048, 4_096] {
            let sink = MockSink()
            let retention = LogRetention(sink: sink, config: smallConfig(maxBytes: configMax))
            for step in 0 ..< 3_000 {
                let piece = pieces[nextRandom(pieces.count)]
                retention.write(Data(piece.utf8))
                XCTAssertLessThanOrEqual(sink.storage.count, Int(configMax), "cap exceeded at step \(step)")
            }
            XCTAssertNotNil(strictDecode(sink.storage), "storage not strict UTF-8 for cap \(configMax)")
            XCTAssertEqual(lastMarkerEvent(in: sink.storage), retention.discardEvents)
        }
    }

    // MARK: - Policy: production-scale config

    func testProductionScaleConfig() {
        // The real budgets: 20 MiB cap, 4 MiB head, 12 MiB tail.
        let sink = MockSink()
        let retention = LogRetention(
            sink: sink,
            config: LogRetention.Config(maxBytes: 20 * 1_024 * 1_024)
        )
        retention.write(Data("Whisky Version: test\nArguments: wine game.exe\n\n".utf8))
        let chunk = Data((String(repeating: "y", count: 4_095) + "\n").utf8) // 4 KiB
        let writes = (25 * 1_024 * 1_024) / chunk.count // ~25 MiB of output
        for _ in 0 ..< writes {
            retention.write(chunk)
        }
        XCTAssertLessThanOrEqual(sink.storage.count, 20 * 1_024 * 1_024)
        XCTAssertGreaterThanOrEqual(retention.discardEvents, 1)
        let text = strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("Whisky Version: test\nArguments: wine game.exe\n\n") == true)
        XCTAssertEqual(lastMarkerEvent(in: sink.storage), retention.discardEvents)
        // Tail retains roughly the most recent tailBudget of output.
        XCTAssertGreaterThan(sink.storage.count, 10 * 1_024 * 1_024)
    }

    // MARK: - End-to-end through a real FileHandle

    func testFileHandleSinkEndToEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-retention-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let retention = LogRetention(
            sink: FileHandleLogRetentionSink(handle: handle),
            config: smallConfig(maxBytes: 2_048)
        )
        retention.write(Data("STARTUP\n".utf8))
        for i in 0 ..< 500 {
            retention.write(Data("row \(i) with some bytes é€😀\n".utf8))
        }
        try handle.closeFile()
        let onDisk = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(onDisk.count, 2_048)
        let text = strictDecode(onDisk)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("STARTUP\n") == true)
        XCTAssertTrue(text?.contains("row 499 ") == true)
        XCTAssertEqual(lastMarkerEvent(in: onDisk), retention.discardEvents)
    }
}
