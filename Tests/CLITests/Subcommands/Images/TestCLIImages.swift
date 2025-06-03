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

//

import Foundation
import Testing

class TestCLIImagesCommand: CLITest {
    struct Image: Codable {
        let reference: String
    }

    struct InspectOutput: Codable {
        let name: String
        let variants: [variant]
        struct variant: Codable {
            let platform: imagePlatform
            struct imagePlatform: Codable {
                let os: String
                let architecture: String
            }
        }
    }

    func doRemoveImages(images: [String]? = nil) throws {
        var args = [
            "images",
            "rm",
        ]

        if let images {
            args.append(contentsOf: images)
        } else {
            args.append("--all")
        }

        let (_, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func isImagePresent(targetImage: String) throws -> Bool {
        let images = try doListImages()
        return images.contains(where: { image in
            if image.reference == targetImage {
                return true
            }
            return false
        })
    }

    func doListImages() throws -> [Image] {
        let (output, error, status) = try run(arguments: [
            "images",
            "list",
            "--format",
            "json",
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }

        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("image list output invalid \(output)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode([Image].self, from: jsonData)
    }

    func doInspectImages(image: String) throws -> [InspectOutput] {
        let (output, error, status) = try run(arguments: [
            "images",
            "inspect",
            image,
        ])

        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }

        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("image inspect output invalid \(output)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode([InspectOutput].self, from: jsonData)
    }

    func doImageTag(image: String, newName: String) throws {
        let tagArgs = [
            "images",
            "tag",
            image,
            newName,
        ]

        let (_, error, status) = try run(arguments: tagArgs)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

}

extension TestCLIImagesCommand {

    @Test func testPull() throws {
        do {
            try doPull(imageName: alpine)
            let imagePresent = try isImagePresent(targetImage: alpine)
            #expect(imagePresent, "expected to see \(alpine) pulled")
        } catch {
            Issue.record("failed to pull alpine image \(error)")
            return
        }
    }

    @Test func testPullMulti() throws {
        do {
            try doPull(imageName: alpine)
            try doPull(imageName: busybox)

            let alpinePresent = try isImagePresent(targetImage: alpine)
            #expect(alpinePresent, "expected to see \(alpine) pulled")

            let busyPresent = try isImagePresent(targetImage: busybox)
            #expect(busyPresent, "expected to see \(busybox) pulled")
        } catch {
            Issue.record("failed to pull images \(error)")
            return
        }
    }

    @Test func testPullPlatform() throws {
        do {
            let os = "linux"
            let arch = "amd64"
            let pullArgs = [
                "--platform",
                "\(os)/\(arch)",
            ]

            try doPull(imageName: alpine, args: pullArgs)

            let output = try doInspectImages(image: alpine)
            #expect(output.count == 1, "expected a single image inspect output, got \(output)")

            var found = false
            for v in output[0].variants {
                if v.platform.os == os && v.platform.architecture == arch {
                    found = true
                }
            }
            #expect(found, "expected to find image with os \(os) and architecture \(arch), instead got \(output[0])")
        } catch {
            Issue.record("failed to pull and inspect image \(error)")
            return
        }
    }

    @Test func testPullRemoveSingle() throws {
        do {
            try doPull(imageName: alpine)
            let imagePulled = try isImagePresent(targetImage: alpine)
            #expect(imagePulled, "expected to see image \(alpine) pulled")

            // tag image so we can safely remove later
            let alpineTagged = "\(alpine.dropLast("3.21".count))testPullRemoveSingle"
            try doImageTag(image: alpine, newName: alpineTagged)
            let taggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(taggedImagePresent, "expected to see image \(alpineTagged) tagged")

            try doRemoveImages(images: [alpineTagged])
            let imageRemoved = try !isImagePresent(targetImage: alpineTagged)
            #expect(imageRemoved, "expected not to see image \(alpineTagged)")
        } catch {
            Issue.record("failed to pull and remove image \(error)")
            return
        }
    }

    @Test func testImageTag() throws {
        do {
            try doPull(imageName: alpine)
            let alpineTagged = "\(alpine.dropLast("3.21".count))testImageTag"
            try doImageTag(image: alpine, newName: alpineTagged)
            let imagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(imagePresent, "expected to see image \(alpineTagged) tagged")
        } catch {
            Issue.record("failed to pull and tag image \(error)")
            return
        }
    }

    @Test func testImageDefaultRegistry() throws {
        do {
            let defaultDomain = "ghcr.io"
            let imageName = "apple-uat/test-images/alpine:3.21"
            defer {
                try? doDefaultRegistrySet(domain: "docker.io")
            }
            try doDefaultRegistrySet(domain: defaultDomain)
            try doPull(imageName: imageName, args: ["--platform", "linux/arm64"])
            guard let alpineImageDetails = try doInspectImages(image: imageName).first else {
                Issue.record("alpine image not found")
                return
            }
            #expect(alpineImageDetails.name == "\(defaultDomain)/\(imageName)")

            try doImageTag(image: imageName, newName: "username/image-name:mytag")
            guard let taggedImage = try doInspectImages(image: "username/image-name:mytag").first else {
                Issue.record("Tagged image not found")
                return
            }
            #expect(taggedImage.name == "\(defaultDomain)/username/image-name:mytag")

            let listOutput = try doImageListQuite()
            #expect(listOutput.contains("username/image-name:mytag"))
            #expect(listOutput.contains(imageName))
        } catch {
            Issue.record("failed default registry test")
            return
        }
    }

    @Test func testImageSaveAndLoad() throws {
        do {
            // 1. pull image
            try doPull(imageName: alpine)

            // 2. Tag image so we can safely remove later
            let alpineTagged = "\(alpine.dropLast("3.21".count))testImageSaveAndLoad"
            try doImageTag(image: alpine, newName: alpineTagged)
            let taggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(taggedImagePresent, "expected to see image \(alpineTagged) tagged")

            // 3. save the image as a tarball
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
            let saveArgs = [
                "images",
                "save",
                alpineTagged,
                "--output",
                tempFile.path(),
            ]
            let (_, error, status) = try run(arguments: saveArgs)
            if status != 0 {
                throw CLIError.executionFailed("command failed: \(error)")
            }

            // 4. remove the image through container
            try doRemoveImages(images: [alpineTagged])

            // 5. verify image is no longer present
            let imageRemoved = try !isImagePresent(targetImage: alpineTagged)
            #expect(imageRemoved, "expected image \(alpineTagged) to be removed")

            // 6. load the tarball
            let loadArgs = [
                "images",
                "load",
                "-i",
                tempFile.path(),
            ]
            let (_, loadErr, loadStatus) = try run(arguments: loadArgs)
            if loadStatus != 0 {
                throw CLIError.executionFailed("command failed: \(loadErr)")
            }

            // 7. verify image is in the list again
            let imagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(imagePresent, "expected \(alpineTagged) to be present")
        } catch {
            Issue.record("failed to save and load image \(error)")
            return
        }
    }
}
