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

import ContainerAPIClient
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Testing

class TestCLIImagesCommand: CLITest {
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
            let (_, _, error, status) = try run(arguments: saveArgs)
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
            let (_, _, loadErr, loadStatus) = try run(arguments: loadArgs)
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

    @Test func testMaxConcurrentDownloadsValidation() throws {
        // Test that invalid maxConcurrentDownloads value is rejected
        let (_, _, error, status) = try run(arguments: [
            "image",
            "pull",
            "--max-concurrent-downloads", "0",
            "alpine:latest",
        ])

        #expect(status != 0, "Expected command to fail with maxConcurrentDownloads=0")
        #expect(
            error.contains("maximum number of concurrent downloads must be greater than 0"),
            "Expected validation error message in output")
    }

    @Test func testImageLoadRejectsInvalidMembersWithoutForce() throws {
        do {
            // 0. Generate unique malicious filename for this test run
            let maliciousFilename = "pwned-\(UUID().uuidString).txt"
            let maliciousPath = "/tmp/\(maliciousFilename)"

            // 1. Pull image
            try doPull(imageName: alpine)

            // 2. Tag image so we can safely remove later
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testImageLoadRejectsInvalidMembers"
            try doImageTag(image: alpine, newName: alpineTagged)
            let taggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(taggedImagePresent, "expected to see image \(alpineTagged) tagged")

            // 3. Save the image as a tarball
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
                "--output",
                tempFile.path(),
            ]
            let (_, _, saveError, saveStatus) = try run(arguments: saveArgs)
            if saveStatus != 0 {
                throw CLIError.executionFailed("save command failed: \(saveError)")
            }

            // 4. Add malicious member to the tar
            try addInvalidMemberToTar(tarPath: tempFile.path(), maliciousFilename: maliciousFilename)

            // 5. Remove the image
            try doRemoveImages(images: [alpineTagged])
            let imageRemoved = try !isImagePresent(targetImage: alpineTagged)
            #expect(imageRemoved, "expected image \(alpineTagged) to be removed")

            // 6. Try to load the modified tar without force - should fail
            let loadArgs = [
                "image",
                "load",
                "-i",
                tempFile.path(),
            ]
            let (_, _, loadError, loadStatus) = try run(arguments: loadArgs)
            #expect(loadStatus != 0, "expected load to fail without force flag")
            #expect(loadError.contains("rejected paths") || loadError.contains(maliciousFilename), "expected error about invalid member path")

            // 7. Verify that malicious file was NOT created
            let maliciousFileExists = FileManager.default.fileExists(atPath: maliciousPath)
            #expect(!maliciousFileExists, "malicious file should not have been created at \(maliciousPath)")
        } catch {
            Issue.record("failed to test image load with invalid members: \(error)")
            return
        }
    }

    @Test func testImageLoadAcceptsInvalidMembersWithForce() throws {
        do {
            // 0. Generate unique malicious filename for this test run
            let maliciousFilename = "pwned-\(UUID().uuidString).txt"
            let maliciousPath = "/tmp/\(maliciousFilename)"

            // 1. Pull image
            try doPull(imageName: alpine)

            // 2. Tag image so we can safely remove later
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testImageLoadAcceptsInvalidMembers"
            try doImageTag(image: alpine, newName: alpineTagged)
            let taggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(taggedImagePresent, "expected to see image \(alpineTagged) tagged")

            // 3. Save the image as a tarball
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
                "--output",
                tempFile.path(),
            ]
            let (_, _, saveError, saveStatus) = try run(arguments: saveArgs)
            if saveStatus != 0 {
                throw CLIError.executionFailed("save command failed: \(saveError)")
            }

            // 4. Add malicious member to the tar
            try addInvalidMemberToTar(tarPath: tempFile.path(), maliciousFilename: maliciousFilename)

            // 5. Remove the image
            try doRemoveImages(images: [alpineTagged])
            let imageRemoved = try !isImagePresent(targetImage: alpineTagged)
            #expect(imageRemoved, "expected image \(alpineTagged) to be removed")

            // 6. Try to load the modified tar with force - should succeed with warning
            let loadArgs = [
                "image",
                "load",
                "-i",
                tempFile.path(),
                "--force",
            ]
            let (_, _, loadError, loadStatus) = try run(arguments: loadArgs)
            #expect(loadStatus == 0, "expected load to succeed with force flag")

            // Check that warning was logged about rejected member
            #expect(loadError.contains("invalid members") || loadError.contains(maliciousFilename), "expected warning about rejected member path")

            // 7. Verify image is loaded
            let imageLoaded = try isImagePresent(targetImage: alpineTagged)
            #expect(imageLoaded, "expected image \(alpineTagged) to be loaded")

            // 8. Verify that malicious file was NOT created
            let maliciousFileExists = FileManager.default.fileExists(atPath: maliciousPath)
            #expect(!maliciousFileExists, "malicious file should not have been created at \(maliciousPath)")
        } catch {
            Issue.record("failed to test image load with force and invalid members: \(error)")
            return
        }
    }

    @Test func testImageSaveAndLoadStdinStdout() throws {
        do {
            // 1. pull image
            try doPull(imageName: alpine)
            try doPull(imageName: busybox)

            // 2. Tag image so we can safely remove later
            let alpineRef: Reference = try Reference.parse(alpine)
            let alpineTagged = "\(alpineRef.name):testImageSaveAndLoadStdinStdout"
            try doImageTag(image: alpine, newName: alpineTagged)
            let alpineTaggedImagePresent = try isImagePresent(targetImage: alpineTagged)
            #expect(alpineTaggedImagePresent, "expected to see image \(alpineTagged) tagged")

            let busyboxRef: Reference = try Reference.parse(busybox)
            let busyboxTagged = "\(busyboxRef.name):testImageSaveAndLoadStdinStdout"
            try doImageTag(image: busybox, newName: busyboxTagged)
            let busyboxTaggedImagePresent = try isImagePresent(targetImage: busyboxTagged)
            #expect(busyboxTaggedImagePresent, "expected to see image \(busyboxTagged) tagged")

            // 3. save the image and output to stdout
            let saveArgs = [
                "image",
                "save",
                alpineTagged,
                busyboxTagged,
            ]
            let (stdoutData, _, error, status) = try run(arguments: saveArgs)
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

            // 6. load the tarball from the stdout data as stdin
            let loadArgs = [
                "image",
                "load",
            ]
            let (_, _, loadErr, loadStatus) = try run(arguments: loadArgs, stdin: stdoutData)
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

    @Test func testImageFullSizeFieldExists() throws {
        // 1. pull image
        try doPull(imageName: alpine)

        // 2. run the image ls command
        let (_, output, error, status) = try run(arguments: ["image", "ls", "--format", "json"])
        if status != 0 {
            throw CLIError.executionFailed("failed to list images: \(error)")
        }

        // 3. parse the json output
        guard let data = output.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]],
            let image = json.first
        else {
            Issue.record("failed to parse JSON output or no images found: \(output)")
            return
        }

        // 4. check that the output has a non-empty 'fullSize' field
        let size = image["fullSize"] as? String ?? ""
        #expect(!size.isEmpty, "expected image to have non-empty 'fullSize' field: \(image)")
    }

    private func addInvalidMemberToTar(tarPath: String, maliciousFilename: String) throws {
        // Create a malicious entry with path traversal
        let evilEntryName = "../../../../../../../../../../../tmp/\(maliciousFilename)"
        let evilEntryContent = "pwned\n".data(using: .utf8)!

        // Create a temporary file for the modified tar
        let tempModifiedTar = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")

        // Open the modified tar for writing
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: tempModifiedTar)

        // First, copy all existing members from the input tar
        let reader = try ArchiveReader(file: URL(fileURLWithPath: tarPath))
        for (entry, data) in reader {
            if entry.fileType == .regular {
                try writer.writeEntry(entry: entry, data: data)
            } else {
                try writer.writeEntry(entry: entry, data: nil)
            }
        }

        // Now add the evil entry
        let evilEntry = WriteEntry()
        evilEntry.path = evilEntryName
        evilEntry.size = Int64(evilEntryContent.count)
        evilEntry.modificationDate = Date()
        evilEntry.fileType = .regular
        evilEntry.permissions = 0o644

        try writer.writeEntry(entry: evilEntry, data: evilEntryContent)
        try writer.finishEncoding()

        // Replace the original tar with the modified one
        try FileManager.default.removeItem(atPath: tarPath)
        try FileManager.default.moveItem(at: tempModifiedTar, to: URL(fileURLWithPath: tarPath))
    }
}
