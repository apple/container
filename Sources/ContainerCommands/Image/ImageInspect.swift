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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation

extension Application {
    public struct ImageInspect: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more images")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Images to inspect")
        var images: [String]

        public init() {}

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            let uniqueNames = Set(images)
            let result = try await ClientImage.get(
                names: Array(uniqueNames), containerSystemConfig: containerSystemConfig
            )

            if !result.error.isEmpty {
                let missing = result.error.sorted()
                throw ContainerizationError(
                    .notFound,
                    message: "image not found: \(missing.joined(separator: ", "))"
                )
            }

            var printable: [ImageResource] = []
            for image in result.images {
                guard
                    !Utility.isInfraImage(
                        name: image.reference,
                        builderImage: containerSystemConfig.build.image,
                        initImage: containerSystemConfig.vminit.image
                    )
                else { continue }
                printable.append(
                    try await image.toImageResource(containerSystemConfig: containerSystemConfig)
                )
            }

            try Output.emit(Output.renderJSON(printable, options: .pretty))
        }
    }
}
