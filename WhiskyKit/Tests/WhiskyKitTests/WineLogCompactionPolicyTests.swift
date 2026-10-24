//
//  WineLogCompactionPolicyTests.swift
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
final class WineLogCompactionPolicyTests: XCTestCase {
    func testCompactionPreservesHeadMarkerAndTail() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_600))
        retention.write(Data("STARTUP-HEADER-LINE\n".utf8))
        var lineNumber = 0
        while lineNumber < 500, sink.storage.count < 10_000 {
            retention.write(Data("line-\(lineNumber)-xxxxxxxxxx\n".utf8))
            lineNumber += 1
            XCTAssertLessThanOrEqual(sink.storage.count, 1_600)
        }
        retention.write(Data("TAIL-SENTINEL-FINAL\n".utf8))
        XCTAssertGreaterThan(retention.discardEvents, 0)
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text, "compacted log must remain strict UTF-8")
        XCTAssertTrue(text?.hasPrefix("STARTUP-HEADER-LINE\n") == true)
        // The file ends with the true final bytes of the stream.
        XCTAssertTrue(text?.hasSuffix("TAIL-SENTINEL-FINAL\n") == true)
        XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: sink.storage), retention.discardEvents)
    }

    func testRepeatedCompactionsStayUnderCapAndDecodable() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 2_048))
        for index in 0 ..< 2_000 {
            retention.write(Data("entry \(index) é€😀 padding padding padding\n".utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 2_048, "cap exceeded at write \(index)")
        }
        XCTAssertGreaterThan(retention.discardEvents, 5)
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: sink.storage), retention.discardEvents)
        XCTAssertTrue(text?.contains("entry 1999 ") == true)
    }

    func testHugeFirstWriteThenRepeatedCompactions() {
        // Regression: after a huge FIRST write (file starts with a marker, head
        // holds the earliest retained content), later compactions must still keep
        // the latest tail, strict UTF-8, and honest disclosure as the leading
        // marker is replaced.
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
        let huge = Data("HUGE-CHUNK-START\n".utf8)
            + Data(repeating: 0x44, count: 100_000)
            + Data("\nHUGE-CHUNK-END\n".utf8)
        retention.write(huge)
        XCTAssertEqual(LogRetentionTestSupport.markerOccurrences(in: sink.storage), 1)

        var lastLine = ""
        for index in 0 ..< 2_000 {
            lastLine = "after-\(index)-line\n"
            retention.write(Data(lastLine.utf8))
            XCTAssertLessThanOrEqual(sink.storage.count, 1_300, "cap exceeded at write \(index)")
        }
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text, "log must remain strict UTF-8 after repeated compactions")
        XCTAssertTrue(text?.hasSuffix(lastLine) == true, "latest stream tail must survive")
        // Disclosure persists: the current marker reflects the total event count.
        XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: sink.storage), retention.discardEvents)
        XCTAssertGreaterThan(retention.discardEvents, 5)
    }

    // MARK: - Policy: pre-existing oversize file

    func testPreExistingOversizeFileFreezesWithoutTrap() {
        // existingBytes already over the cap: no room for any marker. The policy
        // must freeze safely (no negative-prefix trap), write nothing, and leave
        // the unknown oversize content untouched and unrepaired.
        let sink = MockLogRetentionSink()
        let existing = Data(repeating: 0x45, count: 2_000)
        sink.splice(existing)
        let retention = LogRetention(
            sink: sink,
            config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300),
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
        let sink = MockLogRetentionSink()
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
        XCTAssertNotNil(LogRetentionTestSupport.strictDecode(sink.storage))
    }

    // MARK: - Policy: handle lifecycle

    func testPreExistingFileFreezesWithoutDestroyingContent() {
        let sink = MockLogRetentionSink()
        let existing = Data("PRE-EXISTING-UNKNOWN-CONTENT\n".utf8)
        sink.splice(existing)
        let retention = LogRetention(
            sink: sink,
            config: LogRetentionTestSupport.smallConfig(maxBytes: 1_600),
            existingBytes: Int64(existing.count)
        )
        for index in 0 ..< 200 {
            retention.write(Data("more \(index)\n".utf8))
        }
        XCTAssertTrue(sink.storage.starts(with: existing), "unknown existing content must be preserved")
        XCTAssertLessThanOrEqual(sink.storage.count, 1_600)
        XCTAssertEqual(LogRetentionTestSupport.markerOccurrences(in: sink.storage), 1)
        XCTAssertTrue(retention.disabled)
    }

    // MARK: - Policy: fault injection

    func testNormalWriteFailureFreezesWithoutDrift() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig())
        retention.write(Data("ok\n".utf8))
        sink.failNextWrite = true
        retention.write(Data("boom\n".utf8))
        XCTAssertTrue(retention.disabled)
        retention.write(Data("dropped\n".utf8))
        XCTAssertEqual(sink.storage, Data("ok\n".utf8))
        XCTAssertEqual(retention.discardEvents, 0)
    }

    func testCompactionSeekFailureFreezes() {
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
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
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
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
        let sink = MockLogRetentionSink()
        let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: 1_300))
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
            let sink = MockLogRetentionSink()
            let retention = LogRetention(sink: sink, config: LogRetentionTestSupport.smallConfig(maxBytes: configMax))
            for step in 0 ..< 3_000 {
                let piece = pieces[nextRandom(pieces.count)]
                retention.write(Data(piece.utf8))
                XCTAssertLessThanOrEqual(sink.storage.count, Int(configMax), "cap exceeded at step \(step)")
            }
            XCTAssertNotNil(
                LogRetentionTestSupport.strictDecode(sink.storage),
                "storage not strict UTF-8 for cap \(configMax)"
            )
            XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: sink.storage), retention.discardEvents)
        }
    }

    // MARK: - Policy: production-scale config

    func testProductionScaleConfig() {
        // The real budgets: 20 MiB cap, 4 MiB head, 12 MiB tail.
        let sink = MockLogRetentionSink()
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
        let text = LogRetentionTestSupport.strictDecode(sink.storage)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("Whisky Version: test\nArguments: wine game.exe\n\n") == true)
        XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: sink.storage), retention.discardEvents)
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
            config: LogRetentionTestSupport.smallConfig(maxBytes: 2_048)
        )
        retention.write(Data("STARTUP\n".utf8))
        for index in 0 ..< 500 {
            retention.write(Data("row \(index) with some bytes é€😀\n".utf8))
        }
        try handle.closeFile()
        let onDisk = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(onDisk.count, 2_048)
        let text = LogRetentionTestSupport.strictDecode(onDisk)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("STARTUP\n") == true)
        XCTAssertTrue(text?.contains("row 499 ") == true)
        XCTAssertEqual(LogRetentionTestSupport.lastMarkerEvent(in: onDisk), retention.discardEvents)
    }

    func testSinkDoesNotRetainHandleAndFreezesWhenHandleDies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-retention-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        weak var weakHandle: FileHandle?
        let retention = try { () -> LogRetention in
            let handle = try FileHandle(forWritingTo: file)
            weakHandle = handle
            let retention = LogRetention(
                sink: FileHandleLogRetentionSink(handle: handle),
                config: LogRetentionTestSupport.smallConfig()
            )
            retention.write(Data("before\n".utf8))
            try handle.closeFile()
            return retention
        }()
        XCTAssertFalse(retention.disabled)
        XCTAssertNil(weakHandle, "the sink must not retain the file handle")

        retention.write(Data("after\n".utf8))
        XCTAssertTrue(retention.disabled, "writes after handle death must freeze the policy")
        let onDisk = try Data(contentsOf: file)
        XCTAssertEqual(onDisk, Data("before\n".utf8))
    }
}
