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
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Darwin

extension Application {
    public struct ContainerKill: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "kill",
            abstract: "Kill or signal one or more running containers")

        @Flag(name: .shortAndLong, help: "Kill or signal all running containers")
        var all = false

        @Option(name: .shortAndLong, help: "Signal to send to the container(s)")
        var signal: String = "KILL"

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        public func validate() throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        public mutating func run() async throws {
            let client = ContainerClient()

            let containers: [String]
            if self.all {
                containers = try await client.list(filters: ContainerListFilters(status: .running)).map { $0.id }
            } else {
                containers = containerIds
            }

            let signalNumber = try Signals.parseSignal(signal)

            var errors: [any Error] = []
            for container in containers {
                do {
                    try await client.kill(id: container, signal: signalNumber)
                    print(container)
                } catch {
                    errors.append(error)
                }
            }
            if !errors.isEmpty {
                throw AggregateError(errors)
            }
        }
    }
}
