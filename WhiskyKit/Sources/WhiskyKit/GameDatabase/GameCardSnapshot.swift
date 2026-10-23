// swiftlint:disable file_length
//
//  GameCardSnapshot.swift
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

/// Errors thrown when generating a GameCard snapshot.
public enum GameCardError: LocalizedError, Equatable, Sendable {
    case bottleNotFound(String)
    case programNotFound(String)
    case programSettingsUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .bottleNotFound(bottle):
            "A bottle named \"\(bottle)\" doesn't exist."
        case let .programNotFound(program):
            "Program \"\(program)\" not found in bottle."
        case let .programSettingsUnreadable(message):
            "Program settings could not be read: \(message)"
        }
    }
}

/// Host system and runtime environment metadata captured in a GameCard snapshot.
public struct GameCardEnvironment: Codable, Equatable, Sendable {
    public let macOSVersion: String
    /// The WhiskyWine runtime bundle version (e.g. 3.1.1), not the underlying Wine version.
    public let runtimeVersion: String
    public let dxvkVersion: String?
    public let dxmtVersion: String?
    public let cpuArchitecture: String

    enum CodingKeys: String, CodingKey {
        case macOSVersion
        case runtimeVersion
        case dxvkVersion
        case dxmtVersion
        case cpuArchitecture
    }

    public init(
        macOSVersion: String,
        runtimeVersion: String,
        dxvkVersion: String? = nil,
        dxmtVersion: String? = nil,
        cpuArchitecture: String
    ) {
        self.macOSVersion = macOSVersion
        self.runtimeVersion = runtimeVersion
        self.dxvkVersion = dxvkVersion
        self.dxmtVersion = dxmtVersion
        self.cpuArchitecture = cpuArchitecture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.macOSVersion = try container.decode(String.self, forKey: .macOSVersion)
        self.runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        self.dxvkVersion = try container.decodeIfPresent(String.self, forKey: .dxvkVersion)
        self.dxmtVersion = try container.decodeIfPresent(String.self, forKey: .dxmtVersion)
        self.cpuArchitecture = try container.decode(String.self, forKey: .cpuArchitecture)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(macOSVersion, forKey: .macOSVersion)
        try container.encode(runtimeVersion, forKey: .runtimeVersion)
        if let dxvkVersion {
            try container.encode(dxvkVersion, forKey: .dxvkVersion)
        } else {
            try container.encodeNil(forKey: .dxvkVersion)
        }
        if let dxmtVersion {
            try container.encode(dxmtVersion, forKey: .dxmtVersion)
        } else {
            try container.encodeNil(forKey: .dxmtVersion)
        }
        try container.encode(cpuArchitecture, forKey: .cpuArchitecture)
    }
}

/// An environment snapshot capturing the effective configuration a game would launch with.
///
/// Diagnostic groundwork tool for the `whisky gamecard` command. It records configuration
/// state without launching anything, changing disk state, or rating performance.
public struct GameCardSnapshot: Codable, Equatable, Sendable {
    public let bottleName: String
    public let program: String?
    public let windowsVersion: String
    public let graphicsBackend: String
    public let enhancedSync: String
    public let avxEnabled: Bool
    public let metalFX: Bool
    public let sequoiaCompatMode: Bool
    public let bottleDllOverrides: [DLLOverrideEntry]
    public let programDllOverrides: [DLLOverrideEntry]
    public let effectiveDllOverridesString: String?
    public let environmentVariables: [String: String]
    public let programOverridesApplied: [String]
    public let collectedAt: String
    public let environment: GameCardEnvironment
    public let testResult: String?
    public let rating: String?
    public let knownIssues: [String]
    public let notes: [String]

    enum CodingKeys: String, CodingKey {
        case bottleName
        case program
        case windowsVersion
        case graphicsBackend
        case enhancedSync
        case avxEnabled
        case metalFX
        case sequoiaCompatMode
        case bottleDllOverrides
        case programDllOverrides
        case effectiveDllOverridesString
        case environmentVariables
        case programOverridesApplied
        case collectedAt
        case environment
        case testResult
        case rating
        case knownIssues
        case notes
    }

    public init(
        bottleName: String,
        program: String? = nil,
        windowsVersion: String,
        graphicsBackend: String,
        enhancedSync: String,
        avxEnabled: Bool,
        metalFX: Bool,
        sequoiaCompatMode: Bool,
        bottleDllOverrides: [DLLOverrideEntry] = [],
        programDllOverrides: [DLLOverrideEntry] = [],
        effectiveDllOverridesString: String? = nil,
        environmentVariables: [String: String] = [:],
        programOverridesApplied: [String] = [],
        collectedAt: String,
        environment: GameCardEnvironment,
        testResult: String? = nil,
        rating: String? = nil,
        knownIssues: [String] = [],
        notes: [String] = ["Snapshot of settings only; no test was run."]
    ) {
        self.bottleName = bottleName
        self.program = program
        self.windowsVersion = windowsVersion
        self.graphicsBackend = graphicsBackend
        self.enhancedSync = enhancedSync
        self.avxEnabled = avxEnabled
        self.metalFX = metalFX
        self.sequoiaCompatMode = sequoiaCompatMode
        self.bottleDllOverrides = bottleDllOverrides
        self.programDllOverrides = programDllOverrides
        self.effectiveDllOverridesString = effectiveDllOverridesString
        self.environmentVariables = environmentVariables
        self.programOverridesApplied = programOverridesApplied
        self.collectedAt = collectedAt
        self.environment = environment
        self.testResult = testResult
        self.rating = rating
        self.knownIssues = knownIssues
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bottleName = try container.decode(String.self, forKey: .bottleName)
        self.program = try container.decodeIfPresent(String.self, forKey: .program)
        self.windowsVersion = try container.decode(String.self, forKey: .windowsVersion)
        self.graphicsBackend = try container.decode(String.self, forKey: .graphicsBackend)
        self.enhancedSync = try container.decode(String.self, forKey: .enhancedSync)
        self.avxEnabled = try container.decode(Bool.self, forKey: .avxEnabled)
        self.metalFX = try container.decode(Bool.self, forKey: .metalFX)
        self.sequoiaCompatMode = try container.decode(Bool.self, forKey: .sequoiaCompatMode)
        self.bottleDllOverrides = try container.decode([DLLOverrideEntry].self, forKey: .bottleDllOverrides)
        self.programDllOverrides = try container.decode([DLLOverrideEntry].self, forKey: .programDllOverrides)
        self.effectiveDllOverridesString = try container.decodeIfPresent(
            String.self, forKey: .effectiveDllOverridesString
        )
        self.environmentVariables = try container.decode([String: String].self, forKey: .environmentVariables)
        self.programOverridesApplied = try container.decode([String].self, forKey: .programOverridesApplied)
        self.collectedAt = try container.decode(String.self, forKey: .collectedAt)
        self.environment = try container.decode(GameCardEnvironment.self, forKey: .environment)
        self.testResult = try container.decodeIfPresent(String.self, forKey: .testResult)
        self.rating = try container.decodeIfPresent(String.self, forKey: .rating)
        self.knownIssues = try container.decode([String].self, forKey: .knownIssues)
        self.notes = try container.decode([String].self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bottleName, forKey: .bottleName)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encode(windowsVersion, forKey: .windowsVersion)
        try container.encode(graphicsBackend, forKey: .graphicsBackend)
        try container.encode(enhancedSync, forKey: .enhancedSync)
        try container.encode(avxEnabled, forKey: .avxEnabled)
        try container.encode(metalFX, forKey: .metalFX)
        try container.encode(sequoiaCompatMode, forKey: .sequoiaCompatMode)
        try container.encode(bottleDllOverrides, forKey: .bottleDllOverrides)
        try container.encode(programDllOverrides, forKey: .programDllOverrides)
        if let effectiveDllOverridesString {
            try container.encode(effectiveDllOverridesString, forKey: .effectiveDllOverridesString)
        } else {
            try container.encodeNil(forKey: .effectiveDllOverridesString)
        }
        try container.encode(environmentVariables, forKey: .environmentVariables)
        try container.encode(programOverridesApplied, forKey: .programOverridesApplied)
        try container.encode(collectedAt, forKey: .collectedAt)
        try container.encode(environment, forKey: .environment)
        if let testResult {
            try container.encode(testResult, forKey: .testResult)
        } else {
            try container.encodeNil(forKey: .testResult)
        }
        if let rating {
            try container.encode(rating, forKey: .rating)
        } else {
            try container.encodeNil(forKey: .rating)
        }
        try container.encode(knownIssues, forKey: .knownIssues)
        try container.encode(notes, forKey: .notes)
    }

    /// Serializes the snapshot to valid, pretty-printed JSON with stable sorted key order.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string
    }
}

@MainActor
extension GameCardSnapshot {
    /// Resolves a user-supplied program name or path inside a bottle to its executable file URL.
    public static func resolveProgramURL(for program: String, in bottle: Bottle) -> URL? {
        let fileManager = FileManager.default

        if let url = resolveDirectPath(program, in: bottle, fileManager: fileManager) {
            return url
        }
        if let url = resolvePinnedProgram(program, in: bottle, fileManager: fileManager) {
            return url
        }
        return searchDriveC(for: program, in: bottle, fileManager: fileManager)
    }

    private static func resolveDirectPath(_ program: String, in bottle: Bottle, fileManager: FileManager) -> URL? {
        // Drive letter Windows path (e.g., C:\windows\notepad.exe)
        if let match = program.range(of: #"^([A-Za-z]):[\\/]"#, options: .regularExpression) {
            let drive = program[match.lowerBound].lowercased()
            let rest = program[match.upperBound...].replacingOccurrences(of: "\\", with: "/")
            let candidate = bottle.url.appending(path: "drive_\(drive)").appending(path: rest)
            return fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
        }

        // Absolute path
        if program.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: program)
            return fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
        }

        // Relative to bottle or drive_c
        let normalized = program.replacingOccurrences(of: "\\", with: "/")
        let relativeToBottle = bottle.url.appending(path: normalized)
        if fileManager.fileExists(atPath: relativeToBottle.path(percentEncoded: false)) {
            return relativeToBottle
        }
        let relativeToDriveC = bottle.url.appending(path: "drive_c").appending(path: normalized)
        if fileManager.fileExists(atPath: relativeToDriveC.path(percentEncoded: false)) {
            return relativeToDriveC
        }
        return nil
    }

    private static func resolvePinnedProgram(_ program: String, in bottle: Bottle, fileManager: FileManager) -> URL? {
        for pin in bottle.settings.pins {
            guard let pinURL = pin.url else { continue }
            let nameMatches = pin.name.caseInsensitiveCompare(program) == .orderedSame
            let fileMatches = pinURL.lastPathComponent.caseInsensitiveCompare(program) == .orderedSame
            let stem = pinURL.deletingPathExtension().lastPathComponent
            let stemMatches = stem.caseInsensitiveCompare(program) == .orderedSame
            if (nameMatches || fileMatches || stemMatches)
                && fileManager.fileExists(atPath: pinURL.path(percentEncoded: false)) {
                return pinURL
            }
        }
        return nil
    }

    private static func searchDriveC(for program: String, in bottle: Bottle, fileManager: FileManager) -> URL? {
        let searchDir = bottle.url.appending(path: "drive_c")
        guard let enumerator = fileManager.enumerator(
            at: searchDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let target = (program as NSString).lastPathComponent.lowercased()
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent.lowercased() == target {
            return fileURL
        }
        return nil
    }

    private struct ProgramConfig {
        let settings: ProgramSettings?
        let overrides: ProgramOverrides?
        let environment: [String: String]
    }

    private static func loadProgramSettings(
        for url: URL,
        in bottle: Bottle
    ) throws -> ProgramConfig {
        let locations = Program.settingsLocations(
            for: url,
            bottleURL: bottle.url,
            legacyName: url.lastPathComponent
        )
        let settingsURL = FileManager.default.fileExists(atPath: locations.identity.path(percentEncoded: false))
            ? locations.identity
            : locations.legacy

        let settings: ProgramSettings?
        do {
            settings = try ProgramSettings.decodeIfPresent(from: settingsURL)
        } catch {
            throw GameCardError.programSettingsUnreadable(
                "Failed to decode program settings at \(settingsURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        guard let settings else {
            return ProgramConfig(settings: nil, overrides: nil, environment: [:])
        }

        var env = settings.environment
        if settings.locale != .auto {
            env["LC_ALL"] = settings.locale.rawValue
        }
        return ProgramConfig(settings: settings, overrides: settings.overrides, environment: env)
    }

    private static func listAppliedOverrides(_ overrides: ProgramOverrides?) -> [String] {
        guard let overrides else { return [] }
        let checks: [(String, (ProgramOverrides) -> Bool)] = [
            ("graphicsBackend", { $0.graphicsBackend != nil }),
            ("dxvk", { $0.dxvk != nil }),
            ("dxvkAsync", { $0.dxvkAsync != nil }),
            ("dxvkHud", { $0.dxvkHud != nil }),
            ("enhancedSync", { $0.enhancedSync != nil }),
            ("metal4Enabled", { $0.metal4Enabled != nil }),
            ("shaderCacheEnabled", { $0.shaderCacheEnabled != nil }),
            ("controllerCompatibilityMode", { $0.controllerCompatibilityMode != nil }),
            ("disableHIDAPI", { $0.disableHIDAPI != nil }),
            ("allowBackgroundEvents", { $0.allowBackgroundEvents != nil }),
            ("disableControllerMapping", { $0.disableControllerMapping != nil }),
            ("useButtonLabels", { $0.useButtonLabels != nil }),
            ("virtualDesktopEnabled", { $0.virtualDesktopEnabled != nil }),
            ("resolutionPreset", { $0.resolutionPreset != nil }),
            ("customResolutionWidth", { $0.customResolutionWidth != nil }),
            ("customResolutionHeight", { $0.customResolutionHeight != nil }),
            ("dllOverrides", { $0.dllOverrides != nil }),
            ("taggedVerbs", { $0.taggedVerbs != nil })
        ]
        return checks.compactMap { name, isPresent in
            isPresent(overrides) ? name : nil
        }
    }

    private static func formatISO8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func resolveHostEnvironment(wineVersionPlistURL: URL?) -> GameCardEnvironment {
        let info: WhiskyWineVersion? = {
            if let plistURL = wineVersionPlistURL {
                return WhiskyWineInstaller.whiskyWineInfo(at: plistURL)
            }
            return WhiskyWineInstaller.whiskyWineInfo()
        }()
        let runtimeVer = info?.version.description ?? "unknown"
        return GameCardEnvironment(
            macOSVersion: MacOSVersion.current.description,
            runtimeVersion: runtimeVer,
            dxvkVersion: info?.dxvkVersion,
            dxmtVersion: info?.dxmtVersion,
            cpuArchitecture: HostArchitecture.isAppleSilicon ? "arm64" : "x86_64"
        )
    }

    /// Captures the environment snapshot for a bottle and optional program.
    @MainActor
    public static func capture(
        bottle: Bottle,
        program: String? = nil,
        date: Date = Date(),
        wineVersionPlistURL: URL? = nil
    ) throws -> GameCardSnapshot {
        var programOverrides: ProgramOverrides?
        var programSettings: ProgramSettings?
        var programEnv: [String: String] = [:]

        if let prog = program {
            guard let url = resolveProgramURL(for: prog, in: bottle) else {
                throw GameCardError.programNotFound(prog)
            }
            let loaded = try loadProgramSettings(for: url, in: bottle)
            programSettings = loaded.settings
            programOverrides = loaded.overrides
            programEnv = loaded.environment
        }

        let effectiveBackend = programOverrides?.graphicsBackend ?? bottle.settings.graphicsBackend
        let effectiveSync = programOverrides?.enhancedSync ?? bottle.settings.enhancedSync
        let syncString: String = switch effectiveSync {
        case .none: "none"
        case .esync: "esync"
        case .msync: "msync"
        }

        let resolvedEnv = Wine.constructWineEnvironment(
            for: bottle,
            environment: programEnv,
            programOverrides: programOverrides,
            programSettings: programSettings
        )

        return GameCardSnapshot(
            bottleName: bottle.settings.name,
            program: program,
            windowsVersion: bottle.settings.windowsVersion.rawValue,
            graphicsBackend: effectiveBackend.rawValue,
            enhancedSync: syncString,
            avxEnabled: bottle.settings.avxEnabled,
            metalFX: bottle.settings.metalFX,
            sequoiaCompatMode: bottle.settings.sequoiaCompatMode,
            bottleDllOverrides: bottle.settings.dllOverrides,
            programDllOverrides: programOverrides?.dllOverrides ?? [],
            effectiveDllOverridesString: resolvedEnv["WINEDLLOVERRIDES"],
            environmentVariables: filterAllowedEnvironment(resolvedEnv),
            programOverridesApplied: listAppliedOverrides(programOverrides),
            collectedAt: formatISO8601UTC(date),
            environment: resolveHostEnvironment(wineVersionPlistURL: wineVersionPlistURL),
            testResult: nil,
            rating: nil,
            knownIssues: [],
            notes: ["Snapshot of settings only; no test was run."]
        )
    }

    private static func filterAllowedEnvironment(_ env: [String: String]) -> [String: String] {
        var filtered: [String: String] = [:]
        for key in Wine.launchSummaryAllowedKeys where env[key] != nil {
            if let value = env[key] {
                filtered[key] = value
            }
        }
        return filtered
    }

    /// Captures the environment snapshot for a named bottle from a list of bottles.
    @MainActor
    public static func capture(
        bottleName: String,
        in bottles: [Bottle],
        program: String? = nil,
        date: Date = Date(),
        wineVersionPlistURL: URL? = nil
    ) throws -> GameCardSnapshot {
        guard let bottle = bottles.first(where: { $0.settings.name == bottleName }) else {
            throw GameCardError.bottleNotFound(bottleName)
        }
        return try capture(
            bottle: bottle,
            program: program,
            date: date,
            wineVersionPlistURL: wineVersionPlistURL
        )
    }
}
