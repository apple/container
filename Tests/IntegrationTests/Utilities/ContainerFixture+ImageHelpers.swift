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

import Foundation
import Testing

// MARK: - Image inspect types

extension ContainerFixture {
    /// Decoded output of `container image inspect` or `container image list --format json`.
    struct ImageInspectOutput: Codable {
        struct Configuration: Codable { let name: String }
        struct Variant: Codable {
            struct Platform: Codable {
                let os: String
                let architecture: String
            }
            let platform: Platform
        }
        let configuration: Configuration
        let variants: [Variant]
    }
}

// MARK: - Image lifecycle helpers

extension ContainerFixture {

    /// Pulls an image. Passes optional extra args (e.g. `["--platform", "linux/amd64"]`).
    func doPull(_ imageName: String, args: [String] = []) throws {
        var pullArgs = ["image", "pull"] + args
        pullArgs.append(imageName)
        try run(pullArgs).check()
    }

    /// Returns all images currently in the local store.
    func doListImages() throws -> [ImageInspectOutput] {
        let result = try run(["image", "list", "--format", "json"]).check()
        return try JSONDecoder().decode([ImageInspectOutput].self, from: result.outputData)
    }

    /// Returns true if an image with the given exact reference is present.
    func isImagePresent(_ targetImage: String) throws -> Bool {
        try doListImages().contains { $0.configuration.name == targetImage }
    }

    /// Tags `image` with `newName`.
    func doImageTag(_ image: String, newName: String) throws {
        try run(["image", "tag", image, newName]).check()
    }

    /// Removes the given images, or all images when `images` is `nil`.
    func doRemoveImages(_ images: [String]? = nil) throws {
        var args = ["image", "rm"]
        if let images { args.append(contentsOf: images) } else { args.append("--all") }
        try run(args).check()
    }

    /// Returns the full inspect output for an image, including variant information.
    func doInspectImages(_ name: String) throws -> [ImageInspectOutput] {
        let result = try run(["image", "inspect", name]).check()
        return try JSONDecoder().decode([ImageInspectOutput].self, from: result.outputData)
    }

    /// Returns the `configuration.name` of an image.
    func inspectImage(_ name: String) throws -> String {
        let outputs = try doInspectImages(name)
        guard let first = outputs.first else {
            throw CommandError.executionFailed("image '\(name)' not found in inspect output")
        }
        return first.configuration.name
    }

    /// Asserts that the image was successfully built and is present in the image store.
    func assertImageBuilt(_ image: String) throws {
        let name = try inspectImage(image)
        #expect(name == image, "expected image \(image) to be present")
    }
}
