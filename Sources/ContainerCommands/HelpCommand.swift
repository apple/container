//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import ContainerAPIClient

struct HelpCommand: AsyncLoggableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "help",
        shouldDisplay: false
    )

    @OptionGroup(visibility: .hidden)
    public var logOptions: Flags.Logging

    @Argument(parsing: .captureForPassthrough)
    var subcommandPath: [String] = []

    func run() async throws {
        if subcommandPath.isEmpty {
            let pluginLoader = try? await Application.createPluginLoader()
            await Application.printModifiedHelpText(pluginLoader: pluginLoader)
            return
        }
        guard let target = Self.resolveSubcommand(path: subcommandPath) else {
            throw ValidationError("unknown command '\(subcommandPath.joined(separator: " "))'")
        }
        print(Application.helpMessage(for: target))
    }

    static func resolveSubcommand(path: [String]) -> ParsableCommand.Type? {
        var current: ParsableCommand.Type = Application.self
        for name in path {
            guard let next = childSubcommands(of: current).first(where: { matches($0, name: name) }) else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func childSubcommands(of command: ParsableCommand.Type) -> [ParsableCommand.Type] {
        var all = command.configuration.subcommands
        for group in command.configuration.groupedSubcommands {
            all.append(contentsOf: group.subcommands)
        }
        return all
    }

    private static func matches(_ command: ParsableCommand.Type, name: String) -> Bool {
        let cfg = command.configuration
        if cfg.commandName == name { return true }
        return cfg.aliases.contains(name)
    }
}
