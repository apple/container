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
    public struct ContainerPrune: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove all stopped containers"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let client = ContainerClient()
            let result = try await client.prune()

            for failure in result.failed {
                log.error(
                    "failed to prune container",
                    metadata: [
                        "id": "\(failure.id)",
                        "error": "\(failure.error)"
                    ]
                )
            }

            for name in result.pruned {
                print(name)
            }
            let formatter = ByteCountFormatter()
            let freed = formatter.string(fromByteCount: Int64(result.reclaimedBytes))
            print("Reclaimed \(freed) in disk space")
        }
    }
}
