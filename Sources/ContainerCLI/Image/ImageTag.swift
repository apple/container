//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient

extension Application {
    struct ImageTag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tag",
            abstract: "Tag an image")

        @Argument(help: "SOURCE_IMAGE[:TAG]")
        var source: String

        @Argument(help: "TARGET_IMAGE[:TAG]")
        var target: String

        @OptionGroup
        var global: Flags.Global

        func run() async throws {
            let existing = try await ClientImage.get(reference: source)
            let targetReference = try ClientImage.normalizeReference(target)
            try await existing.tag(new: targetReference)
            print("Image \(source) tagged as \(target)")
        }
    }
}
