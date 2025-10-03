//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerClient
import ContainerizationOCI
import Foundation
import Testing

class TestCLIImagesCommand: CLITest {
    func doRemoveImages(images: [String]? = nil) throws {
        var args = [
            "image",
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
            "image",
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

    func doImageTag(image: String, newName: String) throws {
        let tagArgs = [
            "image",
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

    @Test func testPullOsArch() throws {
        do {
            let os = "linux"
            let arch = "amd64"
            let pullArgs = [
                "--os",
                os,
                "--arch",
                arch,
            ]

            try doPull(imageName: alpine318, args: pullArgs)

            let output = try doInspectImages(image: alpine318)
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

    @Test func testPullOs() throws {
        do {
            let os = "linux"
            let arch = Arch.hostArchitecture().rawValue
            let pullArgs = [
                "--os",
                os,
            ]

            try doPull(imageName: alpine318, args: pullArgs)

            let output = try doInspectImages(image: alpine318)
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

    @Test func testPullArch() throws {
        do {
            let os = "linux"
            let arch = "amd64"
            let pullArgs = [
                "--arch",
                arch,
            ]

            try doPull(imageName: alpine318, args: pullArgs)

            let output = try doInspectImages(image: alpine318)
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
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testPullRemoveSingle"
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
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testImageTag"
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
            let imageName = "linuxcontainers/alpine:3.20"
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
            try doPull(imageName: busybox)

            // 2. Tag image so we can safely remove later
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testImageSaveAndLoad"
            try doImageTag(image: alpine, newName: alpineTagged)
            let alpineTaggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(alpineTaggedImagePresent, "expected to see image \(alpineTagged) tagged")

            let busyboxRef: Reference = try Reference.parse(busybox)
            let busyboxTagged = "\(busyboxRef.name):testImageSaveAndLoad"
            try doImageTag(image: busybox, newName: busyboxTagged)
            let busyboxTaggedImagePresent = try isImagePresent(targetImage: busyboxTagged)
            #expect(busyboxTaggedImagePresent, "expected to see image \(busyboxTagged) tagged")

            // 3. save the image as a tarball
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
            let saveArgs = [
                "image",
                "save",
                alpineTagged,
                busyboxTagged,
                "--output",
                tempFile.path(),
            ]
            let (_, error, status) = try run(arguments: saveArgs)
            if status != 0 {
                throw CLIError.executionFailed("command failed: \(error)")
            }

            // 4. remove the image through container
            try doRemoveImages(images: [alpineTagged, busyboxTagged])

            // 5. verify image is no longer present
            let alpineImageRemoved = try !isImagePresent(targetImage: alpineTagged)
            #expect(alpineImageRemoved, "expected image \(alpineTagged) to be removed")
            let busyboxImageRemoved = try !isImagePresent(targetImage: busyboxTagged)
            #expect(busyboxImageRemoved, "expected image \(busyboxTagged) to be removed")

            // 6. load the tarball
            let loadArgs = [
                "image",
                "load",
                "-i",
                tempFile.path(),
            ]
            let (_, loadErr, loadStatus) = try run(arguments: loadArgs)
            if loadStatus != 0 {
                throw CLIError.executionFailed("command failed: \(loadErr)")
            }

            // 7. verify image is in the list again
            let alpineImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(alpineImagePresent, "expected \(alpineTagged) to be present")
            let busyboxImagePresent = try isImagePresent(targetImage: busyboxTagged)
            #expect(busyboxImagePresent, "expected \(busyboxTagged) to be present")
        } catch {
            Issue.record("failed to save and load image \(error)")
            return
        }
    }
}
