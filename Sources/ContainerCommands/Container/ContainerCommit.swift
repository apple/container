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
import Foundation

extension Application {
    public struct ContainerCommit: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "commit",
                abstract: "Create a new image from a container's filesystem",
            )
        }

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "container ID")
        var id: String

        @Argument(help: "image reference for the committed image")
        var reference: String

        public func run() async throws {
            let client = ContainerClient()
            let image = try await client.commit(id: id, reference: reference)
            try await image.unpack(platform: nil)
            print(image.reference)
        }
    }
}
