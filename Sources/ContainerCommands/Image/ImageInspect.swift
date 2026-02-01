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
import ContainerResource
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

        public func run() async throws {
            var printable = [any Codable]()
            var found: [ClientImage] = []
            var failures: [ManagedResourceError<ImageResource>] = []

            do {
                found = try await ClientImage.getWithPartialErrors(names: images)
            } catch let partial as ManagedResourcePartialError<ClientImage, ManagedResourceError<ImageResource>> {
                found = partial.successes
                failures = partial.failures
            }

            for image in found {
                guard !Utility.isInfraImage(name: image.reference) else { continue }
                printable.append(try await image.details())
            }

            if !printable.isEmpty {
                print(try printable.jsonArray())
            }

            if !failures.isEmpty {
                let logger = Logger(label: "ImageInspect", factory: { _ in StderrLogHandler() })
                for failure in failures {
                    logger.error(
                        "\(failure.localizedDescription)"
                    )
                }

                throw ManagedResourcePartialError<ClientImage, ManagedResourceError<ImageResource>>(
                    successes: found,
                    failures: failures
                )
            }
        }
    }
}
