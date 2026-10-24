//
//  SteamSessionDiagnosticsTests.swift
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
#if canImport(WhiskyKit)
@testable import WhiskyKit
#else
@testable import WhiskyKitSteamDiag
#endif

@Suite("Steam session diagnostics: launch gate")
struct SteamSessionDiagnosticsTests {
    @Test("No preset always proceeds, whatever the client or driver state")
    func noPresetAlwaysProceeds() {
        for running in [true, false] {
            for supported in [true, false] {
                let gate = SteamSessionDiagnostics.gate(
                    preset: nil, clientIsRunning: running, driverSupportsDiagnostics: supported
                )
                #expect(gate == .proceed)
            }
        }
    }

    @Test("A preset proceeds only with a supported driver and no running client")
    func presetProceeds() {
        let gate = SteamSessionDiagnostics.gate(
            preset: .crash, clientIsRunning: false, driverSupportsDiagnostics: true
        )
        #expect(gate == .proceed)
    }

    @Test("A running client blocks a diagnostic session")
    func runningClientBlocks() {
        let gate = SteamSessionDiagnostics.gate(
            preset: .crash, clientIsRunning: true, driverSupportsDiagnostics: true
        )
        #expect(gate == .blockedClientRunning)
    }

    @Test("An unsupported driver blocks a diagnostic session")
    func unsupportedDriverBlocks() {
        for running in [true, false] {
            let gate = SteamSessionDiagnostics.gate(
                preset: .crash, clientIsRunning: running, driverSupportsDiagnostics: false
            )
            #expect(gate == .blockedDriverUnsupported)
        }
    }

    @Test("The propagation note discloses the unverified route")
    func propagationNoteDisclosesUncertainty() {
        #expect(SteamSessionDiagnostics.propagationNote.contains("not verified"))
        #expect(SteamSessionDiagnostics.propagationNote.isEmpty == false)
    }
}
