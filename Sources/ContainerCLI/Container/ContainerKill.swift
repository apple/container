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
import ContainerizationError
import ContainerizationOS
import Darwin

extension Application {
    struct ContainerKill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kill",
            abstract: "Kill one or more running containers")

        @Option(name: .shortAndLong, help: "Signal to send the container(s)")
        var signal: String = "KILL"

        @Flag(name: .shortAndLong, help: "Kill all running containers")
        var all = false

        @Argument(help: "Container IDs")
        var containerIDs: [String] = []

        @OptionGroup
        var global: Flags.Global

        func validate() throws {
            if containerIDs.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIDs.count > 0 && all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied container IDs conflicts with the --all flag")
            }
        }

        mutating func run() async throws {
            let set = Set<String>(containerIDs)

            var containers = try await ClientContainer.list().filter { c in
                c.status == .running
            }
            if !self.all {
                containers = containers.filter { c in
                    set.contains(c.id)
                }
            }

            let signalNumber = try Signals.parseSignal(signal)

            var failed: [String] = []
            for container in containers {
                do {
                    try await container.kill(signalNumber)
                    print(container.id)
                } catch {
                    log.error("failed to kill container \(container.id): \(error)")
                    failed.append(container.id)
                }
            }
            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "kill failed for one or more containers")
            }
        }
    }
}
