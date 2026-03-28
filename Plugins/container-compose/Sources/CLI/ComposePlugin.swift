//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import Foundation
import ContainerLog
import Logging

struct ComposeGlobalOptions: ParsableArguments {
    @OptionGroup
    var shared: Flags.Logging

    @Flag(name: .long, inversion: .prefixedNo, help: "Allow YAML anchors and merge keys in compose files")
    var allowAnchors = true

    var debug: Bool {
        shared.debug
    }

    func configureLogging() {
        let debugEnvVar = ProcessInfo.processInfo.environment["CONTAINER_DEBUG"]
        if debug || debugEnvVar != nil {
            log.logLevel = .debug
        } else {
            log.logLevel = .info
        }
    }
}

@main
struct ComposePlugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Manage multi-container applications",
        subcommands: [
            ComposeBuild.self,
            ComposeRun.self,
            ComposeUp.self,
            ComposeDown.self,
            ComposePS.self,
            ComposeStart.self,
            ComposeStop.self,
            ComposeRestart.self,
            ComposeLogs.self,
            ComposeExec.self,
            ComposeHealth.self,
            ComposeValidate.self,
            ComposeRm.self,
        ]
    )

    static func main() async throws {
        let args = ComposeArgumentNormalizer.normalize(Array(CommandLine.arguments.dropFirst()))

        do {
            var command = try Self.parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            Self.exit(withError: error)
        }
    }
}

enum ComposeArgumentNormalizer {
    static let subcommands: Set<String> = [
        "build", "run", "up", "down", "ps", "start", "stop", "restart", "logs", "exec", "health", "validate", "rm",
    ]

    private static let rootFlags: [String: String] = [
        "--debug": "--debug",
        "--allow-anchors": "--allow-anchors",
    ]

    private static let rootOptionsWithValues: [String: String] = [
        "-f": "--file",
        "--file": "--file",
        "-p": "--project",
        "--project": "--project",
        "--profile": "--profile",
        "--set-env": "--set-env",
        "--env-file": "--env-file",
    ]

    static func normalize(_ arguments: [String]) -> [String] {
        guard let subcommandIndex = arguments.firstIndex(where: { subcommands.contains($0) }) else {
            return arguments
        }

        var movedRootOptions: [String] = []
        var prefix: [String] = []
        var index = 0

        while index < subcommandIndex {
            let argument = arguments[index]

            if let rewritten = rewriteRootFlag(argument) {
                movedRootOptions.append(rewritten)
                index += 1
                continue
            }

            if let (tokens, consumed) = rewriteRootOption(argument, nextArgument: index + 1 < subcommandIndex ? arguments[index + 1] : nil) {
                movedRootOptions.append(contentsOf: tokens)
                index += consumed
                continue
            }

            prefix.append(argument)
            index += 1
        }

        let subcommand = arguments[subcommandIndex]
        let suffix = normalizeSubcommandArguments(Array(arguments.dropFirst(subcommandIndex + 1)), subcommand: subcommand)
        return prefix + [subcommand] + movedRootOptions + suffix
    }

    private static func rewriteRootFlag(_ argument: String) -> String? {
        rootFlags[argument]
    }

    private static func rewriteRootOption(_ argument: String, nextArgument: String?) -> ([String], Int)? {
        if let canonical = rootOptionsWithValues[argument] {
            guard let nextArgument else { return ([canonical], 1) }
            return ([canonical, nextArgument], 2)
        }

        for (option, canonical) in rootOptionsWithValues where argument.hasPrefix(option + "=") {
            let value = String(argument.dropFirst(option.count + 1))
            return ([canonical, value], 1)
        }

        return nil
    }

    private static func normalizeSubcommandArguments(_ arguments: [String], subcommand: String) -> [String] {
        guard subcommand == "logs" else {
            return arguments
        }

        return arguments.map { argument in
            argument == "-f" ? "--follow" : argument
        }
    }
}
