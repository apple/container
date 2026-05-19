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
import ContainerResource
import ContainerizationError
import Foundation

extension Application.VolumeCommand {
    public struct VolumeInspect: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more volumes"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Volumes to inspect")
        var names: [String]

        public init() {}

        public func run() async throws {
            let uniqueNames = Set(names)
            let volumes = try await ClientVolume.list().filter { uniqueNames.contains($0.id) }

            if volumes.count != uniqueNames.count {
                let found = Set(volumes.map { $0.id })
                let missing = uniqueNames.subtracting(found).sorted()
                throw ContainerizationError(
                    .notFound,
                    message: "volume not found: \(missing.joined(separator: ", "))"
                )
            }

            let options = JSONOptions(
                outputFormatting: [.prettyPrinted, .sortedKeys],
                dateEncodingStrategy: .iso8601
            )
            try Output.emit(Output.renderJSON(volumes, options: options))
        }
    }
}
