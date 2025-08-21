//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient
import ContainerPlugin

struct DefaultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: nil,
        shouldDisplay: false
    )

    @OptionGroup(visibility: .hidden)
    var global: Flags.Global

    @Argument(parsing: .captureForPassthrough)
    var remaining: [String] = []

    func run() async throws {
        // See if we have a possible plugin command.
        let pluginLoader = try? await Application.createPluginLoader()
        guard let command = remaining.first else {
            await Application.printModifiedHelpText(pluginLoader: pluginLoader)
            return
        }

        // Check for edge cases and unknown options to match the behavior in the absence of plugins.
        if command.isEmpty {
            throw ValidationError("Unknown argument '\(command)'")
        } else if command.starts(with: "-") {
            throw ValidationError("Unknown option '\(command)'")
        }

        guard let plugin = pluginLoader?.findPlugin(name: command), plugin.config.isCLI else {
            throw ValidationError("failed to find plugin named container-\(command)")
        }
        // Exec performs execvp (with no fork).
        try plugin.exec(args: remaining)
    }
}
