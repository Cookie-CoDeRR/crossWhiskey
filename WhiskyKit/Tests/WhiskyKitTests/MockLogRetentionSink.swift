//
//  MockLogRetentionSink.swift
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
import Foundation

/// In-memory `LogRetentionSink` for tests, with deterministic fault injection:
/// one-shot flags make the NEXT call of an operation throw (for writes optionally
/// after splicing only `partialNextWrite` bytes).
final class MockLogRetentionSink: LogRetentionSink {
    struct InjectedFault: Error {}

    private(set) var storage = Data()
    private(set) var offset = 0
    private(set) var writeCallCount = 0
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

/// Shared helpers for the log-retention test suites.
enum LogRetentionTestSupport {
    static let markerToken = "[Whisky] Log retention: discarded output (event #"

    /// Small budgets so boundary behavior is exercised with tiny inputs.
    static func smallConfig(maxBytes: Int64 = 2_048) -> LogRetention.Config {
        LogRetention.Config(maxBytes: maxBytes, headBudget: 64, tailBudget: 128, tailTrimThreshold: 256)
    }

    static func markerOccurrences(in data: Data) -> Int {
        (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: markerToken).count - 1
    }

    /// Event number carried by the LAST marker still present in the file.
    static func lastMarkerEvent(in data: Data) -> Int? {
        let parts = (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: markerToken)
        guard parts.count > 1, let last = parts.last,
              let close = last.firstIndex(of: ")")
        else { return nil }
        return Int(last[last.startIndex ..< close])
    }

    static func strictDecode(_ data: Data) -> String? {
        String(bytes: data, encoding: .utf8)
    }

    /// Independent oracle: character-boundary offsets of a known-valid string.
    static func boundaries(of string: String) -> [Int] {
        var result = [0]
        var offset = 0
        for character in string {
            offset += String(character).utf8.count
            result.append(offset)
        }
        return result
    }
}
