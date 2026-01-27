//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerPlugin
import Darwin
import Foundation

struct DefaultCommand: AsyncLoggableCommand {
    public static let configuration = CommandConfiguration(
        commandName: nil,
        shouldDisplay: false
    )

    @OptionGroup(visibility: .hidden)
    public var logOptions: Flags.Logging

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
            throw ValidationError("unknown argument '\(command)'")
        } else if command.starts(with: "-") {
            throw ValidationError("unknown option '\(command)'")
        }

        // Compute canonical plugin directories to show in helpful errors (avoid hard-coded paths)
        let installRoot = CommandLine.executablePathUrl
            .deletingLastPathComponent()
            .appendingPathComponent("..")
            .standardized
        let userPluginsURL = PluginLoader.userPluginsDir(installRoot: installRoot)
        let installRootPluginsURL =
            installRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("container")
            .appendingPathComponent("plugins")
            .standardized
        let hintPaths = [userPluginsURL, installRootPluginsURL]
            .map { $0.appendingPathComponent(command).path(percentEncoded: false) }
            .joined(separator: "\n  - ")

        // If plugin loader couldn't be created, the system/APIServer likely isn't running.
        if pluginLoader == nil {
            throw ValidationError(
                """
                Plugins are unavailable. Start the container system services and retry:

                    container system start

                Check to see that the plugin exists under:
                  - \(hintPaths)

                """
            )
        }

        guard let plugin = pluginLoader?.findPlugin(name: command), plugin.config.isCLI else {
            throw ValidationError(
                """
                Plugin 'container-\(command)' not found.

                - If system services are not running, start them with: container system start
                - If the plugin isn't installed, ensure it exists under:

                Check to see that the plugin exists under:
                  - \(hintPaths)

                """
            )
        }
        // Before execing into the plugin, restore default SIGINT/SIGTERM so the plugin can manage signals.
        Self.resetSignalsForPluginExec()
        // Exec performs execvp (with no fork).
        try plugin.exec(args: remaining)
    }
}

extension DefaultCommand {
    // Exposed for tests to verify signal reset semantics.
    static func resetSignalsForPluginExec() {
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
