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

extension Application {
    public struct ContainerStop: AsyncParsableCommand {
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
        var global: Flags.Global

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
            var containers = [ClientContainer]()
            if self.all {
                containers = try await ClientContainer.list()
            } else {
                containers = try await ClientContainer.list().filter { c in
                    set.contains(c.id)
                }
            }

            let opts = ContainerStopOptions(
                timeoutInSeconds: self.time,
                signal: try Signals.parseSignal(self.signal)
            )
            let failed = try await Self.stopContainers(containers: containers, stopOptions: opts)
            if failed.count > 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "stop failed for one or more containers \(failed.joined(separator: ","))"
                )
            }
        }

        static func stopContainers(containers: [ClientContainer], stopOptions: ContainerStopOptions) async throws -> [String] {
            var failed: [String] = []
            try await withThrowingTaskGroup(of: ClientContainer?.self) { group in
                for container in containers {
                    group.addTask {
                        do {
                            try await container.stop(opts: stopOptions)
                            print(container.id)
                            return nil
                        } catch {
                            log.error("failed to stop container \(container.id): \(error)")
                            return container
                        }
                    }
                }

                for try await ctr in group {
                    guard let ctr else {
                        continue
                    }
                    failed.append(ctr.id)
                }
            }

            return failed
        }
    }
}
