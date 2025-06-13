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
import Foundation

extension Application {
    struct ContainerDelete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more containers",
            aliases: ["rm"])

        @Flag(name: .shortAndLong, help: "Force the removal of one or more running containers")
        var force = false

        @Flag(name: .shortAndLong, help: "Remove all containers")
        var all = false

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Container IDs/names")
        var containerIDs: [String] = []

        func validate() throws {
            if containerIDs.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if containerIDs.count > 0 && all {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "explicitly supplied container IDs conflicts with the --all flag"
                )
            }
        }

        mutating func run() async throws {
            let set = Set<String>(containerIDs)
            var containers = [ClientContainer]()

            if all {
                containers = try await ClientContainer.list()
            } else {
                let ctrs = try await ClientContainer.list()
                containers = ctrs.filter { c in
                    set.contains(c.id)
                }
                // If one of the containers requested isn't present, let's throw. We don't need to do
                // this for --all as --all should be perfectly usable with no containers to remove; otherwise,
                // it'd be quite clunky.
                if containers.count != set.count {
                    let missing = set.filter { id in
                        !containers.contains { c in
                            c.id == id
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
            try await withThrowingTaskGroup(of: ClientContainer?.self) { group in
                for container in containers {
                    group.addTask {
                        do {
                            // First we need to find if the container supports auto-remove
                            // and if so we need to skip deletion.
                            if container.status == .running {
                                if !force {
                                    // We don't want to error if the user just wants all containers deleted.
                                    // It's implied we'll skip containers we can't actually delete.
                                    if all {
                                        return nil
                                    }
                                    throw ContainerizationError(.invalidState, message: "container is running")
                                }
                                let stopOpts = ContainerStopOptions(
                                    timeoutInSeconds: 5,
                                    signal: SIGKILL
                                )
                                try await container.stop(opts: stopOpts)
                            }
                            try await container.delete()
                            print(container.id)
                            return nil
                        } catch {
                            log.error("failed to delete container \(container.id): \(error)")
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

            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "delete failed for one or more containers: \(failed)")
            }
        }
    }
}
