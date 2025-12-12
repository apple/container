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
import ContainerXPC
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
            var snapshots = [ContainerSnapshot]()
            if self.all {
                snapshots = try await ClientContainer.list()
            } else {
                snapshots = try await ClientContainer.list().filter { c in
                    set.contains(c.configuration.id)
                }
            }

            let opts = ContainerStopOptions(
                timeoutInSeconds: self.time,
                signal: try Signals.parseSignal(self.signal)
            )
            let failed = try await Self.stopContainers(snapshots: snapshots, stopOptions: opts)
            if failed.count > 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "stop failed for one or more containers \(failed.joined(separator: ","))"
                )
            }
        }

        static func stopContainers(snapshots: [ContainerSnapshot], stopOptions: ContainerStopOptions) async throws -> [String] {
            var failed: [String] = []
            let sharedClient = XPCClient(service: ClientContainer.serviceIdentifier)

            try await withThrowingTaskGroup(of: String?.self) { group in
                for snapshot in snapshots {
                    group.addTask {
                        do {
                            let container = ClientContainer(snapshot: snapshot, xpcClient: sharedClient)
                            try await container.stop(opts: stopOptions)
                            print(snapshot.configuration.id)
                            return nil
                        } catch {
                            log.error("failed to stop container \(snapshot.configuration.id): \(error)")
                            return snapshot.configuration.id
                        }
                    }
                }

                for try await id in group {
                    guard let id else {
                        continue
                    }
                    failed.append(id)
                }
            }

            return failed
        }
    }
}
