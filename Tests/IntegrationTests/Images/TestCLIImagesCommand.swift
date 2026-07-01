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

import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Testing

@Suite
struct TestCLIImagesCommand {
    private let alpine = ContainerFixture.warmupImages[0]  // ghcr.io/linuxcontainers/alpine:3.20
    private let alpine318 = ContainerFixture.warmupImages[1]  // ghcr.io/linuxcontainers/alpine:3.18
    private let busybox = ContainerFixture.warmupImages[2]  // ghcr.io/containerd/busybox:1.36

    /// Host architecture string for platform tests.
    private var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    @Test func testPull() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            #expect(try f.isImagePresent(alpine), "expected \(alpine) to be present")
        }
    }

    @Test func testPullMulti() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            try f.doPull(busybox)
            #expect(try f.isImagePresent(alpine), "expected \(alpine) to be present")
            #expect(try f.isImagePresent(busybox), "expected \(busybox) to be present")
        }
    }

    @Test func testPullPlatform() async throws {
        try await ContainerFixture.with { f in
            let os = "linux"
            let arch = "amd64"
            try f.doPull(alpine, args: ["--platform", "\(os)/\(arch)"])
            let output = try f.doInspectImages(alpine)
            #expect(output.count == 1)
            #expect(
                output[0].variants.contains { $0.platform.os == os && $0.platform.architecture == arch },
                "expected variant for \(os)/\(arch) in \(output[0])")
        }
    }

    @Test func testPullOsArch() async throws {
        try await ContainerFixture.with { f in
            let os = "linux"
            let arch = "amd64"
            try f.doPull(alpine318, args: ["--os", os, "--arch", arch])
            let output = try f.doInspectImages(alpine318)
            #expect(output.count == 1)
            #expect(
                output[0].variants.contains { $0.platform.os == os && $0.platform.architecture == arch },
                "expected variant for \(os)/\(arch)")
        }
    }

    @Test func testPullOs() async throws {
        try await ContainerFixture.with { f in
            let os = "linux"
            let arch = hostArchitecture
            try f.doPull(alpine318, args: ["--os", os])
            let output = try f.doInspectImages(alpine318)
            #expect(output.count == 1)
            #expect(
                output[0].variants.contains { $0.platform.os == os && $0.platform.architecture == arch },
                "expected variant for \(os)/\(arch)")
        }
    }

    @Test func testPullArch() async throws {
        try await ContainerFixture.with { f in
            let os = "linux"
            let arch = "amd64"
            try f.doPull(alpine318, args: ["--arch", arch])
            let output = try f.doInspectImages(alpine318)
            #expect(output.count == 1)
            #expect(
                output[0].variants.contains { $0.platform.os == os && $0.platform.architecture == arch },
                "expected variant for \(os)/\(arch)")
        }
    }

    @Test func testPullRemoveSingle() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            #expect(try f.isImagePresent(alpine))
            let tagged = "\((try Reference.parse(alpine)).name):testPullRemoveSingle"
            try f.doImageTag(alpine, newName: tagged)
            #expect(try f.isImagePresent(tagged))
            try f.doRemoveImages([tagged])
            #expect(!(try f.isImagePresent(tagged)), "expected \(tagged) to be removed")
        }
    }

    @Test func testImageTag() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let tagged = "\((try Reference.parse(alpine)).name):testImageTag"
            try f.doImageTag(alpine, newName: tagged)
            #expect(try f.isImagePresent(tagged))
        }
    }

    @Test func testImageSaveAndLoad() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            try f.doPull(busybox)

            let alpineTagged = "\((try Reference.parse(alpine)).name):testImageSaveAndLoad"
            let busyboxTagged = "\((try Reference.parse(busybox)).name):testImageSaveAndLoad"
            try f.doImageTag(alpine, newName: alpineTagged)
            try f.doImageTag(busybox, newName: busyboxTagged)
            #expect(try f.isImagePresent(alpineTagged))
            #expect(try f.isImagePresent(busyboxTagged))

            let tempFile = f.testDir.appending("save-\(UUID().uuidString).tar")
            try f.run(["image", "save", alpineTagged, busyboxTagged, "--output", tempFile.string]).check()

            try f.doRemoveImages([alpineTagged, busyboxTagged])
            #expect(!(try f.isImagePresent(alpineTagged)))
            #expect(!(try f.isImagePresent(busyboxTagged)))

            try f.run(["image", "load", "-i", tempFile.string]).check()
            #expect(try f.isImagePresent(alpineTagged))
            #expect(try f.isImagePresent(busyboxTagged))
        }
    }

    @Test func testImageSaveToStdoutProducesCleanArchive() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let tagged = "\((try Reference.parse(alpine)).name):testImageSaveToStdout"
            try f.doImageTag(alpine, newName: tagged)
            f.addCleanup { try? f.doRemoveImages([tagged]) }

            let result = try f.run(["image", "save", tagged])
            try result.check("save to stdout failed")

            #expect(result.outputData.count >= 1024, "stdout archive too small to contain tar EOF marker")
            let trailer = result.outputData.suffix(1024)
            #expect(trailer.allSatisfy { $0 == 0 }, "stdout archive has trailing non-archive bytes after tar EOF marker")
            #expect(result.error.contains(tagged), "expected saved image reference on stderr")
        }
    }

    @Test func testImageSaveMissingPlatform() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let tagged = "\((try Reference.parse(alpine)).name):testImageSaveMissingPlatform"
            try f.doImageTag(alpine, newName: tagged)
            f.addCleanup { try? f.doRemoveImages([tagged]) }

            let tempFile = f.testDir.appending("save-missing.tar")
            let result = try f.run([
                "image", "save", tagged,
                "--platform", "linux/arm/v5",
                "--output", tempFile.string,
            ])
            #expect(result.status != 0, "expected save to fail for missing platform")
            #expect(result.error.contains("has no content for platform"))
            #expect(result.error.contains("available platforms:"))
        }
    }

    @Test func testMaxConcurrentDownloadsValidation() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "pull", "--max-concurrent-downloads", "0", "alpine:latest"])
            #expect(result.status != 0)
            #expect(result.error.contains("maximum number of concurrent downloads must be greater than 0"))
        }
    }

    @Test func testImageLoadRejectsInvalidMembersWithoutForce() async throws {
        try await ContainerFixture.with { f in
            let maliciousFilename = "pwned-\(UUID().uuidString).txt"
            try f.doPull(alpine)
            let tagged = "\((try Reference.parse(alpine)).name):testImageLoadRejectsInvalidMembers"
            try f.doImageTag(alpine, newName: tagged)
            #expect(try f.isImagePresent(tagged))

            let tempFile = f.testDir.appending("save.tar")
            try f.run(["image", "save", tagged, "--output", tempFile.string]).check()
            try addInvalidMemberToTar(tarPath: tempFile.string, maliciousFilename: maliciousFilename)

            try f.doRemoveImages([tagged])
            #expect(!(try f.isImagePresent(tagged)))

            let loadResult = try f.run(["image", "load", "-i", tempFile.string])
            #expect(loadResult.status != 0, "expected load to fail without force flag")
            #expect(loadResult.error.contains("rejected paths") || loadResult.error.contains(maliciousFilename))
            #expect(
                !FileManager.default.fileExists(atPath: "/tmp/\(maliciousFilename)"),
                "malicious file should not have been created")
        }
    }

    @Test func testImageLoadAcceptsInvalidMembersWithForce() async throws {
        try await ContainerFixture.with { f in
            let maliciousFilename = "pwned-\(UUID().uuidString).txt"
            try f.doPull(alpine)
            let tagged = "\((try Reference.parse(alpine)).name):testImageLoadAcceptsInvalidMembers"
            try f.doImageTag(alpine, newName: tagged)
            f.addCleanup { try? f.doRemoveImages([tagged]) }

            let tempFile = f.testDir.appending("save.tar")
            try f.run(["image", "save", tagged, "--output", tempFile.string]).check()
            try addInvalidMemberToTar(tarPath: tempFile.string, maliciousFilename: maliciousFilename)

            try f.doRemoveImages([tagged])
            let loadResult = try f.run(["image", "load", "-i", tempFile.string, "--force"])
            #expect(loadResult.status == 0, "expected load to succeed with force flag")
            #expect(loadResult.error.contains("invalid members") || loadResult.error.contains(maliciousFilename))
            #expect(try f.isImagePresent(tagged))
            #expect(
                !FileManager.default.fileExists(atPath: "/tmp/\(maliciousFilename)"),
                "malicious file should not have been created")
        }
    }

    @Test func testImageSaveAndLoadStdinStdout() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            try f.doPull(busybox)

            let alpineTagged = "\((try Reference.parse(alpine)).name):testImageSaveAndLoadStdinStdout"
            let busyboxTagged = "\((try Reference.parse(busybox)).name):testImageSaveAndLoadStdinStdout"
            try f.doImageTag(alpine, newName: alpineTagged)
            try f.doImageTag(busybox, newName: busyboxTagged)
            #expect(try f.isImagePresent(alpineTagged))
            #expect(try f.isImagePresent(busyboxTagged))

            let saveResult = try f.run(["image", "save", alpineTagged, busyboxTagged]).check()
            try f.doRemoveImages([alpineTagged, busyboxTagged])
            #expect(!(try f.isImagePresent(alpineTagged)))
            #expect(!(try f.isImagePresent(busyboxTagged)))

            try f.run(["image", "load"], stdin: saveResult.outputData).check()
            #expect(try f.isImagePresent(alpineTagged))
            #expect(try f.isImagePresent(busyboxTagged))
        }
    }

    @Test func testImageVariantSizeFieldExists() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let result = try f.run(["image", "ls", "--format", "json"]).check()
            guard let json = try JSONSerialization.jsonObject(with: result.outputData) as? [[String: Any]],
                let image = json.first
            else {
                Issue.record("failed to parse image list JSON or no images found")
                return
            }
            let variants = image["variants"] as? [[String: Any]] ?? []
            #expect(!variants.isEmpty, "expected at least one variant")
            #expect(
                variants.contains { ($0["size"] as? Int ?? 0) > 0 },
                "expected at least one variant with non-zero size")
        }
    }

    @Test func testImageListTableFormat() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let result = try f.run(["image", "ls"]).check()
            #expect(["NAME", "TAG", "DIGEST"].allSatisfy { result.output.contains($0) })
            #expect(result.output.contains("alpine"))
        }
    }

    @Test func testInspectMissingImageFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "inspect", "definitely-missing-image:latest"])
            #expect(result.status != 0)
            #expect(result.error.contains("image not found"))
        }
    }

    @Test func testImageLoadMissingFileErrorToStderr() async throws {
        try await ContainerFixture.with { f in
            let missingPath = "/path/that/does/not/exist-\(UUID().uuidString)"
            let result = try f.run(["image", "load", "-i", missingPath])
            #expect(result.status != 0)
            #expect(result.output.isEmpty, "stdout should be empty")
            #expect(result.error.contains("file does not exist") && result.error.contains(missingPath))
        }
    }

    // MARK: - Private helpers

    private func addInvalidMemberToTar(tarPath: String, maliciousFilename: String) throws {
        let evilEntryName = "../../../../../../../../../../../tmp/\(maliciousFilename)"
        let evilEntryContent = "pwned\n".data(using: .utf8)!
        let tempModifiedTar = URL(filePath: tarPath + ".modified")

        let writer = try ArchiveWriter(format: .pax, filter: .none, file: tempModifiedTar)
        let reader = try ArchiveReader(file: URL(fileURLWithPath: tarPath))
        for (entry, data) in reader {
            if entry.fileType == .regular {
                try writer.writeEntry(entry: entry, data: data)
            } else {
                try writer.writeEntry(entry: entry, data: nil)
            }
        }
        let evilEntry = WriteEntry()
        evilEntry.path = evilEntryName
        evilEntry.size = Int64(evilEntryContent.count)
        evilEntry.modificationDate = Date()
        evilEntry.fileType = .regular
        evilEntry.permissions = 0o644
        try writer.writeEntry(entry: evilEntry, data: evilEntryContent)
        try writer.finishEncoding()

        try FileManager.default.removeItem(atPath: tarPath)
        try FileManager.default.moveItem(at: tempModifiedTar, to: URL(fileURLWithPath: tarPath))
    }
}
