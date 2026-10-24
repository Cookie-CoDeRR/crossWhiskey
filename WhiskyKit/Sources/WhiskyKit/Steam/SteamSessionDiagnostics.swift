//
//  SteamSessionDiagnostics.swift
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

/// The transport half of opt-in Steam session diagnostics: which launches may
/// carry a ``WineDebugPreset``, and the transient settings that carry it.
///
/// There is deliberately no capture here yet. Collecting logs and presenting
/// an opt-in surface are follow-up stages; this file only holds the decisions
/// and values the launch path needs, so they can be tested without Wine.
public enum SteamSessionDiagnostics {
    /// Whether a launch may carry a diagnostic preset.
    public enum LaunchGate: Equatable, Sendable {
        /// The launch may proceed (with or without a preset).
        case proceed
        /// A preset was requested but the Steam client is already running, so
        /// there is no client start left for the preset to ride on. Wine is
        /// EXPECTED to pass a process's environment to the children it spawns
        /// (not verified against Steam's own launcher chain), which means a
        /// client that is already up cannot take the preset afterward.
        case blockedClientRunning
        /// A preset was requested but the driver cannot carry one.
        case blockedDriverUnsupported
    }

    /// The decision for one launch. Pure, so the launch path and the tests
    /// share exactly one implementation.
    public static func gate(
        preset: WineDebugPreset?,
        clientIsRunning: Bool,
        driverSupportsDiagnostics: Bool
    ) -> LaunchGate {
        guard preset != nil else { return .proceed }
        if !driverSupportsDiagnostics { return .blockedDriverUnsupported }
        if clientIsRunning { return .blockedClientRunning }
        return .proceed
    }

    /// What users must hear alongside any diagnostic output.
    ///
    /// A plain literal on purpose, not a localized key: the localization
    /// wiring belongs to the opt-in surface stage, and this stage must not
    /// touch uncommitted localization work.
    public static let propagationNote = "Expected, not verified: Wine should pass the client's environment"
        + " to games it starts, so the preset should reach the game. Steam's own launcher chain has"
        + " not been verified, so treat any collected output as coming from an unconfirmed route."
}
