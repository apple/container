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
import SystemPackage
import Testing

// MARK: - Image inspect types

extension ContainerFixture {
    /// Decoded output of `container image inspect` or `container image list --format json`.
    public struct ImageInspectOutput: Codable {
        public struct Configuration: Codable { public let name: String }
        public struct Variant: Codable {
            public struct Platform: Codable {
                public let os: String
                public let architecture: String
            }
            public let platform: Platform
        }
        public let configuration: Configuration
        public let variants: [Variant]
    }
}

// MARK: - Image lifecycle helpers

extension ContainerFixture {

    /// Pulls an image. Passes optional extra args (e.g. `["--platform", "linux/amd64"]`).
    public func doPull(_ imageName: String, args: [String] = []) throws {
        var pullArgs = ["image", "pull"] + args
        pullArgs.append(imageName)
        try run(pullArgs).check()
    }

    /// Returns all images currently in the local store.
    public func doListImages() throws -> [ImageInspectOutput] {
        let result = try run(["image", "list", "--format", "json"]).check()
        return try JSONDecoder().decode([ImageInspectOutput].self, from: result.outputData)
    }

    /// Returns true if an image with the given exact reference is present.
    public func isImagePresent(_ targetImage: String) throws -> Bool {
        try doListImages().contains { $0.configuration.name == targetImage }
    }

    /// Tags `image` with `newName`.
    public func doImageTag(_ image: String, newName: String) throws {
        try run(["image", "tag", image, newName]).check()
    }

    /// Removes the given images, or all images when `images` is `nil`.
    public func doRemoveImages(_ images: [String]? = nil) throws {
        var args = ["image", "rm"]
        if let images { args.append(contentsOf: images) } else { args.append("--all") }
        try run(args).check()
    }

    /// Saves `image` to ``WarmupImage/cacheTarPath``, overwriting any existing archive.
    ///
    /// Called once per image by the `ImageWarmup` suite. No `--platform`/`--os`/`--arch`
    /// is passed, so `image save` captures every platform the image supports.
    public func cacheWarmupImage(_ image: WarmupImage) throws {
        try FileManager.default.createDirectory(
            atPath: WarmupImage.cacheDirectory.string, withIntermediateDirectories: true)
        try run(["image", "save", "--output", image.cacheTarPath.string, image.rawValue])
            .check("failed to cache \(image.rawValue)")
    }

    /// Reloads `image` from its cached tar archive rather than pulling over the network.
    ///
    /// Use this in serial tests to restore a warmup image after a destructive operation
    /// (`image rm --all`, `image prune`) removes it from the store. Requires the
    /// `ImageWarmup` suite to have already run and populated the cache.
    public func restoreWarmupImage(_ image: WarmupImage) throws {
        try run(["image", "load", "--input", image.cacheTarPath.string])
            .check("failed to restore \(image.rawValue) from cache")
    }

    /// Returns the full inspect output for an image, including variant information.
    public func doInspectImages(_ name: String) throws -> [ImageInspectOutput] {
        let result = try run(["image", "inspect", name]).check()
        return try JSONDecoder().decode([ImageInspectOutput].self, from: result.outputData)
    }

    /// Returns the `configuration.name` of an image.
    public func inspectImage(_ name: String) throws -> String {
        let outputs = try doInspectImages(name)
        guard let first = outputs.first else {
            throw CommandError.executionFailed("image '\(name)' not found in inspect output")
        }
        return first.configuration.name
    }

    /// Asserts that the image was successfully built and is present in the image store.
    public func assertImageBuilt(_ image: String) throws {
        let name = try inspectImage(image)
        #expect(name == image, "expected image \(image) to be present")
    }
}
