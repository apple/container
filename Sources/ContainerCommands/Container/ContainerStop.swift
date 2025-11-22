//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

        package struct StopError: Error {
            let succeeded: [String]
            let failed: [(String, Error)]
        }

        public func validate() throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no containers specified and --all not supplied"
                )
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "explicitly supplied container IDs conflict with the --all flag"
                )
            }
        }

        public mutating func run() async throws {
            var containers = [ClientContainer]()
            var allErrors: [String] = []

            if self.all {
                containers = try await ClientContainer.list()
            } else {
                let allContainers = try await ClientContainer.list()
                let containerMap = Dictionary(uniqueKeysWithValues: allContainers.map { ($0.id, $0) })

                for id in containerIds {
                    if let container = containerMap[id] {
                        containers.append(container)
                    } else {
                        allErrors.append("Error: No such container: \(id)")
                    }
                }
            }

            let opts = ContainerStopOptions(
                timeoutInSeconds: self.time,
                signal: try Signals.parseSignal(self.signal)
            )

            do {
                try await Self.stopContainers(containers: containers, stopOptions: opts)
                for container in containers {
                    print(container.id)
                }
            } catch let error as ContainerStop.StopError {
                for id in error.succeeded {
                    print(id)
                }

                for (_, err) in error.failed {
                    allErrors.append("Error from APIServer: \(err)")
                }
            }

            if !allErrors.isEmpty {
                var stderr = StandardError()
                for err in allErrors {
                    print(err, to: &stderr)
                }
                throw ExitCode(1)
            }
        }

        static func stopContainers(containers: [ClientContainer], stopOptions: ContainerStopOptions) async throws {
            var succeeded: [String] = []
            var failed: [(String, Error)] = []
            try await withThrowingTaskGroup(of: (String, Error?).self) { group in
                for container in containers {
                    group.addTask {
                        do {
                            try await container.stop(opts: stopOptions)
                            return (container.id, nil)
                        } catch {
                            return (container.id, error)
                        }
                    }
                }

                for try await (id, error) in group {
                    if let error = error {
                        failed.append((id, error))
                    } else {
                        succeeded.append(id)
                    }
                }
            }

            if !failed.isEmpty {
                throw StopError(succeeded: succeeded, failed: failed)
            }
        }
    }
}
