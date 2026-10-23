//
//  GameCard.swift
//  WhiskyCmd
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

import ArgumentParser
import Foundation
import WhiskyKit

extension Whisky {
    struct GameCard: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gamecard",
            abstract: "Export an environment snapshot for a bottle or program."
        )

        @Option(name: .long, help: "Name of the bottle")
        var bottle: String

        @Option(name: .long, help: "Program executable name or path inside the bottle")
        var program: String?

        @Option(name: .long, help: "Output file path (default: stdout)")
        var out: String?

        @MainActor
        mutating func run() async throws {
            var bottlesList = BottleData()
            let bottles = bottlesList.loadBottles()

            guard let matchedBottle = bottles.first(where: { $0.settings.name == bottle }) else {
                throw DomainError("A bottle with that name doesn't exist.")
            }

            let snapshot: GameCardSnapshot
            do {
                snapshot = try GameCardSnapshot.capture(
                    bottle: matchedBottle,
                    program: program
                )
            } catch let error as GameCardError {
                throw DomainError(error.localizedDescription)
            } catch {
                throw DomainError("\(error.localizedDescription)")
            }

            let jsonString = try snapshot.jsonString()

            if let outPath = out {
                let outURL = URL(fileURLWithPath: outPath)
                do {
                    try FileManager.default.createDirectory(
                        at: outURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try jsonString.write(to: outURL, atomically: true, encoding: .utf8)
                } catch {
                    throw DomainError("Failed to write output to \(outPath): \(error.localizedDescription)")
                }
            } else {
                print(jsonString)
            }
        }
    }
}
