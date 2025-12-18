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

        public func validate() throws {
            if containerIds.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIds.count > 0 && all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        public mutating func run() async throws {
            let allContainers = try await ClientContainer.list()

            let containersToSignal = try self.all
                ? allContainers.filter { $0.status == .running }
                : ContainerStop.containers(matching: containerIds, in: allContainers)

            let runningContainers = containersToSignal.filter { $0.status == .running }

            let signalNumber = try Signals.parseSignal(signal)

            var failed: [String] = []
            for container in runningContainers {
                do {
                    try await container.kill(signalNumber)
                    print(container.id)
                } catch {
                    log.error("failed to kill container \(container.id): \(error)")
                    failed.append(container.id)
                }
            }
            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "kill failed for one or more containers \(failed.joined(separator: ","))")
            }
        }
    }
}
