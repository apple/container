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

            // `network` and `kernel-arg` are repeatable list settings, which a
            // flat key/value map cannot express, so collect them separately. An
            // empty value resets the list; an absent key leaves it unchanged.
            let pairs = try MachineSetArguments.pairs(rawArgs)
            let networks = MachineSetArguments.list(forKey: "network", in: pairs)
            let kernelArgs = MachineSetArguments.list(forKey: "kernel-arg", in: pairs)

            // Validate network specs up front: syntax, and that the network
            // exists, for a clear error before the change is persisted.
            if let networks {
                let networkClient = NetworkClient()
                for spec in networks {
                    let parsed = try Parser.network(spec)
                    _ = try await networkClient.get(id: parsed.name)
                }
            }

            let kwargs = MachineSetArguments.scalars(pairs, excluding: ["network", "kernel-arg"])

            if kwargs["virtualization"] == "true" {
                try MachineCapabilities.requireNestedVirtualizationSupported()
            }
            var validatedKwargs = kwargs
            if let raw = kwargs["kernel"], !raw.isEmpty {
                validatedKwargs["kernel"] = try MachineConfig.validateKernelPath(raw).string
            }

            let newConfig = try snapshot.bootConfig.with(validatedKwargs, networks: networks, kernelArgs: kernelArgs)

            try await client.setConfig(id: resolvedName, bootConfig: newConfig)

            if snapshot.status == .running {
                FileHandle.standardError.write(
                    Data("Note: Changes will take effect after stopping and restarting '\(resolvedName)'.\n".utf8))
            }

            print(resolvedName)
        }
    }
}
