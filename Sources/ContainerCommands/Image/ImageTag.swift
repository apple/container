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

extension Application {
    public struct ImageTag: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "tag",
            abstract: "Create a new reference for an existing image")

        @Argument(help: "The existing image reference (format: image-name[:tag])")
        var source: String

        @Argument(help: "The new image reference")
        var target: String

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let existing = try await ClientImage.get(reference: source)
            let targetReference = try ClientImage.normalizeReference(target)
            try await existing.tag(new: targetReference)
            print(target)
        }
    }
}
