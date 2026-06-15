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
import ContainerPersistence
import ContainerizationError
import Foundation
import MachineAPIClient

extension Application {
    public struct MachineSet: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set container machine configuration values"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: [.short, .long], help: "Container machine ID (uses default if not specified)")
        public var name: String?

        @Argument(
            parsing: .remaining,
            help: ArgumentHelp(
                "Configuration values",
                discussion: MachineConfig.helpText(),
                valueName: "setting"
            )
        )
        public var rawArgs: [String] = []

        public func run() async throws {
            guard !rawArgs.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "expected at least one configuration value (e.g., machine set cpus=4)")
            }

            let client = MachineClient()
            let resolvedName = try await resolveMachineId(name, client: client)
            let snapshot = try await client.inspect(id: resolvedName)

            let kwargs = Dictionary(
                try rawArgs.map { arg in
                    let parts = arg.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else {
                        throw ContainerizationError(.invalidArgument, message: "invalid argument format '\(arg)'. Expected 'key=value'")
                    }

                    return (String(parts[0]), String(parts[1]))
                },
                uniquingKeysWith: { _, last in last }
            )
            let newConfig = try snapshot.bootConfig.with(kwargs)

            try await client.setConfig(id: resolvedName, bootConfig: newConfig)

            if snapshot.status == .running {
                FileHandle.standardError.write(
                    Data("Note: Changes will take effect after stopping and restarting '\(resolvedName)'.\n".utf8))
            }

            print(resolvedName)
        }
    }
}
