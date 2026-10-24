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
            "ab\u{80}cd\u{FFFF}e\u{10FFFF}fg"
        ]
        for sample in samples {
            let data = Data(sample.utf8)
            let valid = LogRetentionTestSupport.boundaries(of: sample)
            for cut in 0 ... data.count {
                let result = LogRetention.utf8SafePrefixLength(data, maxLength: cut)
                let expected = valid.filter { $0 <= cut }.max() ?? 0
                XCTAssertEqual(result, expected, "cut=\(cut) in \(sample.debugDescription)")
                XCTAssertNotNil(LogRetentionTestSupport.strictDecode(data.prefix(result)))
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
            [0xC3, 0xC3, 0xA9]
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
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig())
        retention.write(Data("header line\n".utf8))
        retention.write(Data("body é€😀\n".utf8))
        XCTAssertEqual(sink.storage, Data("header line\nbody é€😀\n".utf8))
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertFalse(retention.disabled)
    }

    // MARK: - Policy: compaction

    func testExactCapBoundary() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
        retention.write(Data(count: 1_300)) // exactly at cap: verbatim
        XCTAssertEqual(retention.discardEvents, 0)
        XCTAssertEqual(sink.storage.count, 1_300)
        retention.write(Data([0x41])) // one byte over: compacts, byte still fits
        XCTAssertEqual(retention.discardEvents, 1)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
    }

    func testHugeSingleWriteKeepsRecentSuffix() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
        retention.write(Data("intro\n".utf8))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x42, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        XCTAssertGreaterThanOrEqual(retention.discardEvents, 1)
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text)
        // The RECENT end of the oversized write is retained; its start is discarded.
        XCTAssertTrue(text?.contains("HUGE-CHUNK-END") == true)
        XCTAssertFalse(text?.contains("HUGE-CHUNK-START") == true)
        XCTAssertEqual(LogRetentionTestSupport.markerOccurrences(in: sink.storage), retention.discardEvents)
    }

    func testHugeFirstWriteWritesSingleMarkerAndKeepsSuffix() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x43, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("HUGE-CHUNK-END") == true)
        XCTAssertFalse(text?.contains("HUGE-CHUNK-START") == true)
        // Nothing was retained before the cut, so exactly one marker is written.
        XCTAssertEqual(LogRetentionTestSupport.markerOccurrences(in: sink.storage), 1)
        XCTAssertEqual(retention.discardEvents, 1)
    }

    func testMultibyteSplitAcrossCompactionsStaysValid() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
        for _ in 0 ..< 2_000 {
            retention.write(Data("é€😀\n".utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 1_300)
        }
        XCTAssertNotNil(LogRetentionTestSupport.strictDecode(sink.storage))
    }

    // MARK: - Policy: huge first write then repeated compaction
}
