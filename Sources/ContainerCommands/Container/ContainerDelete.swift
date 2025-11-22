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
import Foundation

extension Application {
    public struct ContainerDelete: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more containers",
            aliases: ["rm"])

        @Flag(name: .shortAndLong, help: "Delete all containers")
        var all = false

        @Flag(name: .shortAndLong, help: "Delete containers even if they are running")
        var force = false

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
                    .invalidArgument,
                    message: "explicitly supplied container ID(s) conflict with the --all flag"
                )
            }
        }

        public mutating func run() async throws {
            let set = Set<String>(containerIds)
            var snapshots = [ContainerSnapshot]()

            if all {
                snapshots = try await ClientContainer.list()
            } else {
                let ctrs = try await ClientContainer.list()
                snapshots = ctrs.filter { c in
                    set.contains(c.configuration.id)
                }
                // If one of the containers requested isn't present, let's throw. We don't need to do
                // this for --all as --all should be perfectly usable with no containers to remove; otherwise,
                // it'd be quite clunky.
                if snapshots.count != set.count {
                    let missing = set.filter { id in
                        !snapshots.contains { c in
                            c.configuration.id == id
                        }
                    }
                    throw ContainerizationError(
                        .notFound,
                        message: "failed to delete one or more containers: \(missing)"
                    )
                }
            }

            var failed = [String]()
            let force = self.force
            let all = self.all
            let sharedClient = XPCClient(service: ClientContainer.serviceIdentifier)

            try await withThrowingTaskGroup(of: String?.self) { group in
                for snapshot in snapshots {
                    group.addTask {
                        do {
                            if snapshot.status == .running && !force {
                                guard all else {
                                    throw ContainerizationError(.invalidState, message: "container is running")
                                }
                                return nil  // Skip running container when using --all
                            }

                            let container = ClientContainer(snapshot: snapshot, xpcClient: sharedClient)
                            try await container.delete(force: force)
                            print(snapshot.configuration.id)
                            return nil
                        } catch {
                            log.error("failed to delete container \(snapshot.configuration.id): \(error)")
                            return snapshot.configuration.id
                        }
                    }
                }

                for try await ctr in group {
                    guard let ctr else {
                        continue
                    }
                    failed.append(ctr)
                }
            }

            if failed.count > 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "delete failed for one or more containers: \(failed)"
                )
            }
        }
    }
}
