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
import Foundation
import Logging

extension Application {
    public struct ContainerStop: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop one or more running containers")

        @Flag(name: .shortAndLong, help: "Stop all running containers")
        var all = false

        @Option(name: .shortAndLong, help: "Signal to send to the containers")
        var signal: String = "SIGTERM"

        @Option(name: .shortAndLong, help: "Seconds to wait before killing the containers")
        var time: Int32 = 5

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        public func validate() throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(
                    .invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        public mutating func run() async throws {
            let set = Set<String>(containerIds)
            let client = ContainerClient()
            var containers = [ContainerSnapshot]()
            if self.all {
                containers = try await client.list()
            } else {
                containers = try await client.list().filter { c in
                    set.contains(c.id)
                }
            }

            let opts = ContainerStopOptions(
                timeoutInSeconds: self.time,
                signal: try Signals.parseSignal(self.signal)
            )
            try await Self.stopContainers(
                client: client,
                containers: containers,
                stopOptions: opts
            )
        }

        static func stopContainers(client: ContainerClient, containers: [ContainerSnapshot], stopOptions: ContainerStopOptions) async throws {
            var errors: [any Error] = []
            await withTaskGroup(of: (any Error)?.self) { group in
                for container in containers {
                    group.addTask {
                        do {
                            try await client.stop(id: container.id, opts: stopOptions)
                            print(container.id)
                            return nil
                        } catch {
                            return error
                        }
                    }
                }

                for await error in group {
                    if let error {
                        errors.append(error)
                    }
                }
            }

            if !errors.isEmpty {
                throw AggregateError(errors)
            }
        }
    }
}
