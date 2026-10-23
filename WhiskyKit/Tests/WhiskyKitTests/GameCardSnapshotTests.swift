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
    var tempDir: URL?
    var bottleURL: URL?

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
    func makeFixtureBottle() throws -> Bottle {
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
        XCTAssertTrue(decoded.bottleDllOverrides.isEmpty)
        XCTAssertTrue(decoded.programDllOverrides.isEmpty)
        XCTAssertTrue(decoded.programOverridesApplied.isEmpty)
        XCTAssertNil(decoded.program)
        XCTAssertEqual(decoded.notes, ["Snapshot of settings only; no test was run."])
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
            "bottleDllOverrides",
            "programDllOverrides",
            "effectiveDllOverridesString",
            "environmentVariables",
            "programOverridesApplied",
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

        XCTAssertFalse(dict.keys.contains("dllOverrides"), "Obsolete dllOverrides should not be in JSON")
        XCTAssertFalse(dict.keys.contains("program"), "Omitted program should not be in JSON")

        // Environment key verification: runtimeVersion present, wineVersion absent
        guard let envDict = dict["environment"] as? [String: Any] else {
            XCTFail("Missing environment dictionary in JSON")
            return
        }
        XCTAssertTrue(envDict.keys.contains("runtimeVersion"), "environment should contain runtimeVersion")
        XCTAssertFalse(envDict.keys.contains("wineVersion"), "environment should not contain wineVersion")
        XCTAssertTrue(envDict.keys.contains("macOSVersion"), "environment should contain macOSVersion")
        XCTAssertTrue(envDict.keys.contains("cpuArchitecture"), "environment should contain cpuArchitecture")
        XCTAssertTrue(envDict.keys.contains("dxvkVersion"), "environment should contain dxvkVersion")
        XCTAssertTrue(envDict.keys.contains("dxmtVersion"), "environment should contain dxmtVersion")
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
            <key>dxmtVersion</key>
            <string>0.80</string>
            <key>dxvkVersion</key>
            <string>1.10.3</string>
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
        XCTAssertEqual(snapshot.environment.runtimeVersion, "3.1.1")
        XCTAssertEqual(snapshot.environment.dxvkVersion, "1.10.3")
        XCTAssertEqual(snapshot.environment.dxmtVersion, "0.80")
        XCTAssertEqual(snapshot.environment.macOSVersion, MacOSVersion.current.description)
        XCTAssertTrue(
            snapshot.environment.cpuArchitecture == "arm64" || snapshot.environment.cpuArchitecture == "x86_64"
        )
    }

    // MARK: - Test 4: testResult and rating are null, notes has settings snapshot note

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

        if let notes = dict["notes"] as? [String] {
            XCTAssertEqual(notes, ["Snapshot of settings only; no test was run."])
        } else {
            XCTFail("notes should be an array of strings")
        }
    }
}

// MARK: - Program Overrides and Error Handling Tests

extension GameCardSnapshotTests {
    // MARK: - Test 5: Program snapshot with overrides applied

    @MainActor
    func testProgramSnapshotWithOverrides() throws {
        let targetBottle = try makeFixtureBottle()
        targetBottle.settings.dllOverrides = [DLLOverrideEntry(dllName: "d3dcompiler_43", mode: .builtin)]
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
        overrides.metal4Enabled = true
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

        // Split DLL overrides assertions
        XCTAssertEqual(snapshot.bottleDllOverrides, [DLLOverrideEntry(dllName: "d3dcompiler_43", mode: .builtin)])
        XCTAssertEqual(snapshot.programDllOverrides, [DLLOverrideEntry(dllName: "d3dcompiler_47", mode: .native)])

        // Effective DLL overrides string contains both
        let effectiveDLLs = try XCTUnwrap(snapshot.effectiveDllOverridesString)
        XCTAssertTrue(effectiveDLLs.contains("d3dcompiler_43"), "Should contain bottle DLL override")
        XCTAssertTrue(effectiveDLLs.contains("d3dcompiler_47"), "Should contain program DLL override")

        // programOverridesApplied list
        XCTAssertTrue(snapshot.programOverridesApplied.contains("graphicsBackend"))
        XCTAssertTrue(snapshot.programOverridesApplied.contains("enhancedSync"))
        XCTAssertTrue(snapshot.programOverridesApplied.contains("metal4Enabled"))
        XCTAssertTrue(snapshot.programOverridesApplied.contains("dllOverrides"))

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

    // MARK: - Test 9: Corrupt program settings throws programSettingsUnreadable

    @MainActor
    func testCorruptProgramSettingsThrowsError() throws {
        let targetBottle = try makeFixtureBottle()
        let bURL = try XCTUnwrap(bottleURL)

        let windowsDir = bURL.appending(path: "drive_c").appending(path: "windows")
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let exeURL = windowsDir.appending(path: "corrupt.exe")
        try Data().write(to: exeURL)

        let locations = Program.settingsLocations(for: exeURL, bottleURL: bURL, legacyName: "corrupt.exe")
        try FileManager.default.createDirectory(
            at: locations.identity.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("NOT_A_VALID_PLIST_DATA".utf8).write(to: locations.identity)

        let progPath = "C:\\windows\\corrupt.exe"
        XCTAssertThrowsError(try GameCardSnapshot.capture(bottle: targetBottle, program: progPath)) { error in
            guard let cardError = error as? GameCardError else {
                XCTFail("Expected GameCardError, got \(error)")
                return
            }
            switch cardError {
            case .programSettingsUnreadable:
                break
            default:
                XCTFail("Expected .programSettingsUnreadable, got \(cardError)")
            }
        }
    }
}
