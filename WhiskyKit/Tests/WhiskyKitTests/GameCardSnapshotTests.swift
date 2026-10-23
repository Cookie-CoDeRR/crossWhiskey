//
//  GameCardSnapshotTests.swift
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

import Foundation
import SemanticVersion
@testable import WhiskyKit
import XCTest

final class GameCardSnapshotTests: XCTestCase {
    private var tempDir: URL?
    private var bottleURL: URL?

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gamecard_test_\(UUID().uuidString)")
        tempDir = root
        let bURL = root.appending(path: "TestBottle")
        bottleURL = bURL
        try? FileManager.default.createDirectory(
            at: bURL.appending(path: "drive_c"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    @MainActor
    private func makeFixtureBottle() throws -> Bottle {
        let bURL = try XCTUnwrap(bottleURL)
        let testBottle = Bottle(bottleUrl: bURL)
        testBottle.settings.name = "TestBottle"
        testBottle.settings.windowsVersion = .win11
        testBottle.settings.graphicsBackend = .dxvk
        testBottle.settings.enhancedSync = .msync
        testBottle.settings.avxEnabled = false
        testBottle.settings.metalFX = true
        testBottle.settings.sequoiaCompatMode = true
        return testBottle
    }

    // MARK: - Test 1: Snapshot for fixture bottle is valid JSON

    @MainActor
    func testSnapshotForFixtureBottleIsValidJSON() throws {
        let targetBottle = try makeFixtureBottle()

        let snapshot = try GameCardSnapshot.capture(bottle: targetBottle)
        let json = try snapshot.jsonString()

        guard let data = json.data(using: .utf8) else {
            XCTFail("JSON string could not be converted to UTF-8 data")
            return
        }

        let decoded = try JSONDecoder().decode(GameCardSnapshot.self, from: data)
        XCTAssertEqual(decoded.bottleName, "TestBottle")
        XCTAssertEqual(decoded.windowsVersion, "win11")
        XCTAssertEqual(decoded.graphicsBackend, "dxvk")
        XCTAssertEqual(decoded.enhancedSync, "msync")
        XCTAssertFalse(decoded.avxEnabled)
        XCTAssertTrue(decoded.metalFX)
        XCTAssertTrue(decoded.sequoiaCompatMode)
        XCTAssertNil(decoded.program)
    }

    // MARK: - Test 2: Required keys are present in JSON output

    @MainActor
    func testRequiredKeysPresentInJSON() throws {
        let targetBottle = try makeFixtureBottle()

        let snapshot = try GameCardSnapshot.capture(bottle: targetBottle)
        let json = try snapshot.jsonString()
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to deserialize JSON dictionary")
            return
        }

        let requiredKeys = [
            "bottleName",
            "windowsVersion",
            "graphicsBackend",
            "enhancedSync",
            "avxEnabled",
            "metalFX",
            "sequoiaCompatMode",
            "dllOverrides",
            "environmentVariables",
            "collectedAt",
            "environment",
            "testResult",
            "rating",
            "knownIssues",
            "notes"
        ]

        for key in requiredKeys {
            XCTAssertTrue(dict.keys.contains(key), "Missing required key: \(key)")
        }

        XCTAssertFalse(dict.keys.contains("program"), "Omitted program should not be in JSON")
    }

    // MARK: - Test 3: collectedAt and environment fields are populated

    @MainActor
    func testCollectedAtAndEnvironmentFieldsPopulated() throws {
        let targetBottle = try makeFixtureBottle()
        let root = try XCTUnwrap(tempDir)

        // Create a mock WhiskyWineVersion.plist to verify plist decoding
        let versionPlistURL = root.appending(path: "WhiskyWineVersion.plist")
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>version</key>
            <dict>
                <key>major</key>
                <integer>3</integer>
                <key>minor</key>
                <integer>1</integer>
                <key>patch</key>
                <integer>1</integer>
            </dict>
        </dict>
        </plist>
        """
        try plistXML.write(to: versionPlistURL, atomically: true, encoding: .utf8)

        let fixedDate = Date(timeIntervalSince1970: 1776902400) // 2026-04-23T00:00:00Z
        let snapshot = try GameCardSnapshot.capture(
            bottle: targetBottle,
            date: fixedDate,
            wineVersionPlistURL: versionPlistURL
        )

        XCTAssertEqual(snapshot.collectedAt, "2026-04-23T00:00:00Z")
        XCTAssertEqual(snapshot.environment.wineVersion, "3.1.1")
        XCTAssertEqual(snapshot.environment.macOSVersion, MacOSVersion.current.description)
        XCTAssertTrue(
            snapshot.environment.cpuArchitecture == "arm64" || snapshot.environment.cpuArchitecture == "x86_64"
        )
    }

    // MARK: - Test 4: testResult and rating are null, notes and knownIssues are empty

    @MainActor
    func testNullAndEmptyFieldsInJSON() throws {
        let targetBottle = try makeFixtureBottle()

        let snapshot = try GameCardSnapshot.capture(bottle: targetBottle)
        let json = try snapshot.jsonString()
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to deserialize JSON dictionary")
            return
        }

        XCTAssertTrue(dict["testResult"] is NSNull, "testResult should be null in JSON")
        XCTAssertTrue(dict["rating"] is NSNull, "rating should be null in JSON")

        if let issues = dict["knownIssues"] as? [Any] {
            XCTAssertTrue(issues.isEmpty, "knownIssues should be empty")
        } else {
            XCTFail("knownIssues should be an array")
        }

        if let notes = dict["notes"] as? [Any] {
            XCTAssertTrue(notes.isEmpty, "notes should be empty")
        } else {
            XCTFail("notes should be an array")
        }
    }

    // MARK: - Test 5: Program snapshot with overrides applied

    @MainActor
    func testProgramSnapshotWithOverrides() throws {
        let targetBottle = try makeFixtureBottle()
        let bURL = try XCTUnwrap(bottleURL)

        // Create program binary in bottle
        let windowsDir = bURL.appending(path: "drive_c").appending(path: "windows")
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let exeURL = windowsDir.appending(path: "notepad.exe")
        try Data().write(to: exeURL)

        // Save program settings with overrides
        var programSettings = ProgramSettings()
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .d3dMetal
        overrides.enhancedSync = .esync
        overrides.dllOverrides = [DLLOverrideEntry(dllName: "d3dcompiler_47", mode: .native)]
        programSettings.overrides = overrides

        let locations = Program.settingsLocations(for: exeURL, bottleURL: bURL, legacyName: "notepad.exe")
        try FileManager.default.createDirectory(
            at: locations.identity.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try programSettings.encode(to: locations.identity)

        let snapshot = try GameCardSnapshot.capture(bottle: targetBottle, program: "C:\\windows\\notepad.exe")

        XCTAssertEqual(snapshot.program, "C:\\windows\\notepad.exe")
        XCTAssertEqual(snapshot.graphicsBackend, "d3dMetal")
        XCTAssertEqual(snapshot.enhancedSync, "esync")
        XCTAssertEqual(snapshot.dllOverrides.count, 1)
        XCTAssertEqual(snapshot.dllOverrides.first?.dllName, "d3dcompiler_47")

        let json = try snapshot.jsonString()
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to deserialize JSON")
            return
        }
        XCTAssertEqual(dict["program"] as? String, "C:\\windows\\notepad.exe")
    }

    // MARK: - Test 6: Unknown program throws error

    @MainActor
    func testUnknownProgramThrowsError() throws {
        let targetBottle = try makeFixtureBottle()

        XCTAssertThrowsError(try GameCardSnapshot.capture(bottle: targetBottle, program: "missing_game.exe")) { error in
            guard let cardError = error as? GameCardError else {
                XCTFail("Expected GameCardError, got \(error)")
                return
            }
            XCTAssertEqual(cardError, .programNotFound("missing_game.exe"))
        }
    }

    // MARK: - Test 7: Unknown bottle throws error

    @MainActor
    func testUnknownBottleThrowsError() {
        let bottles: [Bottle] = []
        XCTAssertThrowsError(try GameCardSnapshot.capture(bottleName: "GhostBottle", in: bottles)) { error in
            guard let cardError = error as? GameCardError else {
                XCTFail("Expected GameCardError, got \(error)")
                return
            }
            XCTAssertEqual(cardError, .bottleNotFound("GhostBottle"))
        }
    }

    // MARK: - Test 8: Allowlisted environment variables only

    @MainActor
    func testAllowlistedEnvironmentVariablesSubset() throws {
        let targetBottle = try makeFixtureBottle()

        let snapshot = try GameCardSnapshot.capture(bottle: targetBottle)
        let allowed = Set(Wine.launchSummaryAllowedKeys)

        for key in snapshot.environmentVariables.keys {
            XCTAssertTrue(allowed.contains(key), "Key '\(key)' is not in allowlisted subset")
        }
    }
}
