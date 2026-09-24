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

import ContainerTestSupport
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@Suite
struct TestCLICommitCommand {
    @Test func testCommitStoppedContainer() async throws {
        try await testCommit(stopBeforeCommit: true)
    }

    @Test func testCommitRunningContainer() async throws {
        try await testCommit(stopBeforeCommit: false)
    }

    private func testCommit(stopBeforeCommit: Bool) async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let reference = "localhost/committed-\(f.testID):latest"
            f.addCleanup { try? f.doRemoveImages([reference]) }

            let environment = "COMMIT_TEST=preserved"
            let workingDirectory = "/tmp"
            try await f.withContainer(
                image: image,
                runArgs: ["--env", environment, "--workdir", workingDirectory],
                autoRemove: false
            ) { name in
                let expected = "must-be-in-committed-image"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(expected) > /committed-file"])

                if stopBeforeCommit {
                    try f.doStop(name)
                }

                let result = try f.run(["commit", name, reference])
                try result.check("commit failed")
                #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == reference)
                #expect(try f.isImagePresent(reference))
                try assertCommittedImageMetadata(f, reference: reference)

                try await f.withContainer(image: reference) { committedName in
                    let output = try f.doExec(committedName, cmd: ["cat", "/committed-file"])
                    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == expected)

                    let committedEnvironment = try f.doExec(committedName, cmd: ["printenv", "COMMIT_TEST"])
                    #expect(committedEnvironment.trimmingCharacters(in: .whitespacesAndNewlines) == "preserved")

                    let committedWorkingDirectory = try f.doExec(committedName, cmd: ["pwd"])
                    #expect(committedWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == workingDirectory)
                }
            }
        }
    }

    private func assertCommittedImageMetadata(_ fixture: ContainerFixture, reference: String) throws {
        let archivePath = fixture.testDir.appending("committed-image.tar")
        try fixture.run(["image", "save", "--output", archivePath.string, reference]).check()

        let extractedDirectory = fixture.testDir.appending("committed-image")
        let reader = try ArchiveReader(file: URL(filePath: archivePath.string))
        let rejectedMembers = try reader.extractContents(to: URL(filePath: extractedDirectory.string))
        #expect(rejectedMembers.isEmpty)

        let decoder = JSONDecoder()
        let index = try decoder.decode(Index.self, from: Data(contentsOf: URL(filePath: extractedDirectory.appending("index.json").string)))
        let manifestDescriptor = try #require(index.manifests.first)
        #expect(manifestDescriptor.annotations?["org.opencontainers.image.ref.name"] == reference)

        let manifest = try decoder.decode(Manifest.self, from: blobData(manifestDescriptor, in: extractedDirectory))
        #expect(manifest.layers.count == 1)

        let image = try decoder.decode(Image.self, from: blobData(manifest.config, in: extractedDirectory))
        #expect(image.rootfs.diffIDs == manifest.layers.map { $0.digest })
        #expect(image.history?.count == manifest.layers.count)
    }

    private func blobData(_ descriptor: Descriptor, in directory: FilePath) throws -> Data {
        let digest = try #require(descriptor.digest.split(separator: ":").last)
        return try Data(contentsOf: URL(filePath: directory.appending("blobs/sha256/\(digest)").string))
    }
}
