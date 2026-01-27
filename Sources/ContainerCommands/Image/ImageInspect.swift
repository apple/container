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
import ContainerLog
import ContainerizationError
import Foundation
import Logging
import SwiftProtobuf

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

        struct InspectError: Error {
            let succeeded: [String]
            let failed: [(String, Error)]
        }

        public func run() async throws {
            var printable = [any Codable]()
            var succeededImages: [String] = []
            var allErrors: [(String, Error)] = []

            let result = try await ClientImage.get(names: images)

            for image in result.images {
                guard !Utility.isInfraImage(name: image.reference) else { continue }
                printable.append(try await image.details())
                succeededImages.append(image.reference)
            }

            for missing in result.error {
                allErrors.append((missing, ContainerizationError(.notFound, message: "Image not found")))
            }

            if !printable.isEmpty {
                print(try printable.jsonArray())
            }

            if !allErrors.isEmpty {
                let logger = Logger(label: "ImageInspect", factory: { _ in StderrLogHandler() })
                for (name, error) in allErrors {
                    logger.error("\(name): \(error.localizedDescription)")
                }

                throw InspectError(succeeded: succeededImages, failed: allErrors)
            }
        }
    }
}
