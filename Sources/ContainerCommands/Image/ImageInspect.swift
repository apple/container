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
import ContainerizationError
import Foundation
import SwiftProtobuf

extension Application {
    public struct ImageInspect: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more images")

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Images to inspect")
        var images: [String]

        public init() {}

        public func run() async throws {
            var printable = [any Codable]()
            let result = try await ClientImage.get(names: images)
            let notFound = result.error
            for image in result.images {
                guard !Utility.isInfraImage(name: image.reference) else {
                    continue
                }
                printable.append(try await image.details())
            }
            if printable.count > 0 {
                print(try printable.jsonArray())
            }
            if notFound.count > 0 {
                throw ContainerizationError(.notFound, message: "images: \(notFound.joined(separator: "\n"))")
            }
        }
    }
}
