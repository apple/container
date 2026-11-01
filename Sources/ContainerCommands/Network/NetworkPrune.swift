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
import Foundation

extension Application.NetworkCommand {
    public struct NetworkPrune: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove networks with no container connections"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let networkClient = NetworkClient()
            let result = try await networkClient.prune()

            for failure in result.failed {
                log.error(
                    "failed to prune network",
                    metadata: [
                        "id": "\(failure.id)",
                        "error": "\(failure.error)",
                    ])
            }

            for name in result.pruned {
                print(name)
            }
        }
    }
}
