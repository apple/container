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
import ContainerizationError
import ContainerizationOS
import Darwin

extension Application {
    public struct ContainerKill: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "kill",
            abstract: "Kill or signal one or more running containers")

        @Flag(name: .shortAndLong, help: "Kill or signal all running containers")
        var all = false

        @Option(name: .shortAndLong, help: "Signal to send to the container(s)")
        var signal: String = "KILL"

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        struct KillError: Error {
            let succeeded: [String]
            let failed: [(String, Error)]
        }

        public func validate() throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        public mutating func run() async throws {
            var containers = [ClientContainer]()
            var allErrors: [String] = []

            let allContainers = try await ClientContainer.list()

            if self.all {
                containers = allContainers.filter { c in
                    c.status == .running
                }
            } else {
                let containerMap = Dictionary(uniqueKeysWithValues: allContainers.map { ($0.id, $0) })

                for id in containerIds {
                    if let container = containerMap[id] {
                        containers.append(container)
                    } else {
                        allErrors.append("Error: No such container: \(id)")
                    }
                }
            }

            let signalNumber = try Signals.parseSignal(signal)

            do {
                try await Self.killContainers(containers: containers, signal: signalNumber)
                for container in containers {
                    print(container.id)
                }
            } catch let error as KillError {
                for id in error.succeeded {
                    print(id)
                }

                for (_, err) in error.failed {
                    allErrors.append("Error from APIServer: \(err.localizedDescription)")
                }
            }
            if !allErrors.isEmpty {
                var stderr = StandardError()
                for error in allErrors {
                    print(error, to: &stderr)
                }
                throw ExitCode(1)
            }
        }

        static func killContainers(containers: [ClientContainer], signal: Int32) async throws {
            var succeeded: [String] = []
            var failed: [(String, Error)] = []

            for container in containers {
                do {
                    try await container.kill(signal)
                    succeeded.append(container.id)
                } catch {
                    failed.append((container.id, error))
                }
            }

            if !failed.isEmpty {
                throw KillError(succeeded: succeeded, failed: failed)
            }
        }
    }
}
