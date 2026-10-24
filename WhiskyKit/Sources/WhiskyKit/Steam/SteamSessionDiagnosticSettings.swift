//
//  SteamSessionDiagnosticSettings.swift
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

public extension SteamSessionDiagnostics {
    /// The settings that carry a preset into one Wine run, or `nil` when no
    /// preset is requested (which must behave exactly as before).
    ///
    /// The returned value is built fresh for the call and is never written to
    /// the program's persisted settings: diagnostics are session-scoped and
    /// default off. This is the ONLY place the launch path turns a preset
    /// into settings, so the launch code and the tests share one source.
    static func transientProgramSettings(for preset: WineDebugPreset?) -> ProgramSettings? {
        guard let preset else { return nil }
        var settings = ProgramSettings()
        settings.activeWineDebugPreset = preset
        return settings
    }
}
