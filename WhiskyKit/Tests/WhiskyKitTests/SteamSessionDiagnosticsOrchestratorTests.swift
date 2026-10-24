//
//  SteamSessionDiagnosticsOrchestratorTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Steam session diagnostics: orchestrator route")
@MainActor
struct SteamSessionDiagnosticsOrchestratorTests {
    private typealias Fixture = SteamOrchestratorFixture

    @Test("The preset reaches startClient and launchGame through the driver protocol")
    func presetTravelsToDriver() async throws {
        let (bottle, games) = try Fixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [[]])
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        driver.onStartClient = { driver.script = [["steam.exe"]] }
        driver.onLaunchGame = { _ in driver.script = [["steam.exe", "game1.exe"]] }
        orchestrator.diagnosticsPreset = .crash

        orchestrator.launch(games[0])
        await Fixture.awaitIdle(orchestrator)

        #expect(orchestrator.launchError == nil)
        #expect(driver.startClientPresets == [.crash])
        #expect(driver.launchPresets == [.crash])
        #expect(driver.launched == [games[0].appId])
    }

    @Test("No preset keeps the legacy flow")
    func nilPresetUnchanged() async throws {
        let (bottle, games) = try Fixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [[]])
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        driver.onStartClient = { driver.script = [["steam.exe"]] }
        driver.onLaunchGame = { _ in driver.script = [["steam.exe", "game1.exe"]] }

        orchestrator.launch(games[0])
        await Fixture.awaitIdle(orchestrator)

        #expect(orchestrator.launchError == nil)
        #expect(driver.startClientPresets == [nil])
        #expect(driver.launchPresets == [nil])
        #expect(driver.startClientCalls == 1)
        #expect(driver.launched == [games[0].appId])
    }

    @Test("A running client refuses a diagnostic session before any start")
    func runningClientRefused() async throws {
        let (bottle, games) = try Fixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        orchestrator.diagnosticsPreset = .crash

        orchestrator.launch(games[0])
        await Fixture.awaitIdle(orchestrator)

        let expected = SteamLaunchError.diagnosticsRequiresClientRestart.errorDescription
        #expect(orchestrator.launchError == expected)
        #expect(driver.startClientCalls == 0)
        #expect(driver.startClientPresets.isEmpty)
        #expect(driver.launched.isEmpty)
    }

    @Test("A driver without diagnostics support refuses the session")
    func unsupportedDriverRefused() async throws {
        let (bottle, games) = try Fixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [[]])
        driver.diagnosticsSupported = false
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        orchestrator.diagnosticsPreset = .crash

        orchestrator.launch(games[0])
        await Fixture.awaitIdle(orchestrator)

        #expect(orchestrator.launchError == SteamLaunchError.diagnosticsUnsupported.errorDescription)
        #expect(driver.startClientCalls == 0)
        #expect(driver.launched.isEmpty)
    }

    @Test("Transient settings carry only the preset, and none are built for nil")
    func transientSettingsMapping() throws {
        // ProgramSettings is not Equatable, so nil is checked by pattern.
        if case .some = SteamSessionDiagnostics.transientProgramSettings(for: nil) {
            Issue.record("A nil preset must build no settings at all")
        }
        let settings = try #require(SteamSessionDiagnostics.transientProgramSettings(for: .crash))
        #expect(settings.activeWineDebugPreset == .crash)
        // Everything else stays at the ProgramSettings defaults (verified
        // against ProgramSettings.swift: locale, environment, arguments,
        // overrides all default empty or nil).
        #expect(settings.locale == .auto)
        #expect(settings.environment.isEmpty)
        #expect(settings.arguments.isEmpty)
        #expect(settings.overrides == nil)
    }

    @Test("A preset changed mid-launch does not split the session")
    func presetChangeMidLaunch() async throws {
        let (bottle, games) = try Fixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [[]])
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        driver.onStartClient = {
            // The user turns diagnostics off while the client is starting;
            // this launch must still carry the preset it began with.
            orchestrator.diagnosticsPreset = nil
            driver.script = [["steam.exe"]]
        }
        driver.onLaunchGame = { _ in driver.script = [["steam.exe", "game1.exe"]] }
        orchestrator.diagnosticsPreset = .crash

        orchestrator.launch(games[0])
        await Fixture.awaitIdle(orchestrator)

        #expect(orchestrator.launchError == nil)
        #expect(driver.startClientPresets == [.crash])
        #expect(driver.launchPresets == [.crash])
    }

    @Test("A launch with a different preset does not reuse a client start made without it")
    func mixedPresetConcurrentLaunchRefused() async throws {
        let (bottle, games) = try Fixture.makeBottle(games: [1_086_940, 1_245_620])
        let driver = FakeSteamClientDriver(script: [[]])
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: Fixture.patient)
        driver.onStartClient = {
            // Deterministic barrier: the plain launch's client startup is
            // provably in flight when this callback runs. A diagnostic launch
            // requested now must be refused, not ride the preset-less startup.
            orchestrator.diagnosticsPreset = .crash
            orchestrator.launch(games[1])
        }

        orchestrator.launch(games[0])
        await Fixture.eventually("the diagnostic launch should be refused") {
            orchestrator.launchError != nil
        }
        // Only now let the client and the first game appear.
        driver.script = [["steam.exe", "game1.exe"]]
        await Fixture.awaitIdle(orchestrator)

        // The plain launch went through; the diagnostic one was refused
        // instead of misattributing a session to a client started without it.
        #expect(driver.startClientCalls == 1)
        #expect(driver.launched == [games[0].appId])
        #expect(driver.launchPresets == [nil])
        let expected = SteamLaunchError.diagnosticsRequiresClientRestart.errorDescription
        #expect(orchestrator.launchError == expected)
    }
}
