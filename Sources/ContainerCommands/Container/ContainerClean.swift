//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import Foundation

extension Application {
    public struct ContainerClean: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Clean one or more running containers"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        public func validate() throws {
            if containerIds.count == 0 {
                throw ContainerizationError(.invalidArgument, message: "no containers specified")
            }
        }

        public mutating func run() async throws {
            let client = ContainerClient()
            let containers = Array(Set(containerIds))

            var errors: [any Error] = []
            try await withThrowingTaskGroup(of: (any Error)?.self) { group in
                for container in containers {
                    group.addTask {
                        do {
                            try await client.clean(id: container)
                            print(container)
                            return nil
                        } catch {
                            return error
                        }
                    }
                }

                for try await error in group {
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
