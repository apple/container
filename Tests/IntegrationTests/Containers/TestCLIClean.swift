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
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct TestCLIClean {
    private struct StatusJSON: Codable {
        struct Paths: Codable {
            let appRoot: String
        }

        let paths: Paths
    }

    private func appRoot(_ f: ContainerFixture) throws -> URL {
        let result = try f.run(["system", "status", "--format", "json"]).check()
        let status = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
        return URL(fileURLWithPath: status.paths.appRoot, isDirectory: true)
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            throw CommandError.executionFailed("failed to read allocated size for \(url.path)")
        }
        return fileStatus.st_blocks * 512
    }

    private func containerRootfsBlockURL(_ f: ContainerFixture, name: String) throws -> URL {
        let id = try f.getContainerId(name)
        return try appRoot(f)
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("rootfs.ext4", isDirectory: false)
    }

    private func volumeBlockURL(_ f: ContainerFixture, name: String) throws -> URL {
        try appRoot(f)
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("volume.img", isDirectory: false)
    }

    private func assertCleanReclaimedSpace(beforeWrite: Int64, afterWrite: Int64, afterClean: Int64) {
        let writeAllocated = afterWrite - beforeWrite
        #expect(writeAllocated > 0)

        let reclaimed = afterWrite - afterClean
        #expect(reclaimed > 0)

        let minExpectedReclaimed = Int64(Double(writeAllocated) * 0.8)
        #expect(reclaimed >= minExpectedReclaimed)
    }

    @Test func testCleanStoppedContainerFails() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue, autoRemove: false) { name in
                try f.doStop(name)
                #expect(try f.getContainerStatus(name) == "stopped")
                #expect(try f.run(["clean", name]).status != 0, "clean should fail for a stopped container")
            }
        }
    }

    @Test func testCleanMultipleContainers() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue, tag: "c1") { name1 in
                try await f.withContainer(image: WarmupImage.alpine320.rawValue, tag: "c2") { name2 in
                    try f.run(["clean", name1, name2]).check()
                    #expect(try f.getContainerStatus(name1) == "running")
                    #expect(try f.getContainerStatus(name2) == "running")
                }
            }
        }
    }

    @Test func testCleanAfterFileCreation() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let rootfsBlockURL = try containerRootfsBlockURL(f, name: name)
                let beforeWrite = try allocatedBytes(at: rootfsBlockURL)

                try f.doExec(name, cmd: ["sh", "-c", "dd if=/dev/urandom of=/test-file bs=1M count=10"])
                try f.doExec(name, cmd: ["sync"])
                let afterWrite = try allocatedBytes(at: rootfsBlockURL)
                try f.doExec(name, cmd: ["rm", "/test-file"])

                try f.doClean(name)
                try f.doExec(name, cmd: ["sync"])
                let afterClean = try allocatedBytes(at: rootfsBlockURL)
                assertCleanReclaimedSpace(beforeWrite: beforeWrite, afterWrite: afterWrite, afterClean: afterClean)
                #expect(try f.getContainerStatus(name) == "running")
            }
        }
    }

    @Test func testCleanWithReadOnlyRootfs() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue, runArgs: ["--read-only"]) { name in
                try f.doClean(name)
                #expect(try f.getContainerStatus(name) == "running")
            }
        }
    }

    @Test func testCleanWithMixedVolumes() async throws {
        try await ContainerFixture.with { f in
            let rwVolume = "\(f.testID)-rw-vol"
            let roVolume = "\(f.testID)-ro-vol"
            try f.doVolumeCreate(rwVolume)
            try f.doVolumeCreate(roVolume)
            f.addCleanup { f.doVolumeDeleteIfExists(rwVolume) }
            f.addCleanup { f.doVolumeDeleteIfExists(roVolume) }

            try await f.withContainer(
                image: WarmupImage.alpine320.rawValue,
                runArgs: ["-v", "\(rwVolume):/rw", "-v", "\(roVolume):/ro:ro"]
            ) { name in
                let rwBlockURL = try volumeBlockURL(f, name: rwVolume)
                let beforeWrite = try allocatedBytes(at: rwBlockURL)

                try f.doExec(name, cmd: ["sh", "-c", "dd if=/dev/urandom of=/rw/test bs=1M count=5"])
                try f.doExec(name, cmd: ["sync"])
                let afterWrite = try allocatedBytes(at: rwBlockURL)
                try f.doExec(name, cmd: ["rm", "/rw/test"])

                try f.doClean(name)
                try f.doExec(name, cmd: ["sync"])
                let afterClean = try allocatedBytes(at: rwBlockURL)
                assertCleanReclaimedSpace(beforeWrite: beforeWrite, afterWrite: afterWrite, afterClean: afterClean)
                #expect(try f.getContainerStatus(name) == "running")
            }
        }
    }

    @Test func testCleanWithReadOnlyVolume() async throws {
        try await ContainerFixture.with { f in
            let volumeName = "\(f.testID)-ro-vol"
            try f.doVolumeCreate(volumeName)
            f.addCleanup { f.doVolumeDeleteIfExists(volumeName) }

            try await f.withContainer(
                image: WarmupImage.alpine320.rawValue,
                runArgs: ["-v", "\(volumeName):/mnt/vol:ro"]
            ) { name in
                try f.doClean(name)
                #expect(try f.getContainerStatus(name) == "running")
            }
        }
    }

    @Test func testCleanWithVolume() async throws {
        try await ContainerFixture.with { f in
            let volumeName = "\(f.testID)-vol"
            try f.doVolumeCreate(volumeName)
            f.addCleanup { f.doVolumeDeleteIfExists(volumeName) }

            try await f.withContainer(
                image: WarmupImage.alpine320.rawValue,
                runArgs: ["-v", "\(volumeName):/mnt/vol"]
            ) { name in
                let volumeBlockURL = try volumeBlockURL(f, name: volumeName)
                let beforeWrite = try allocatedBytes(at: volumeBlockURL)

                try f.doExec(name, cmd: ["sh", "-c", "dd if=/dev/urandom of=/mnt/vol/test bs=1M count=5"])
                try f.doExec(name, cmd: ["sync"])
                let afterWrite = try allocatedBytes(at: volumeBlockURL)
                try f.doExec(name, cmd: ["rm", "/mnt/vol/test"])

                try f.doClean(name)
                try f.doExec(name, cmd: ["sync"])
                let afterClean = try allocatedBytes(at: volumeBlockURL)
                assertCleanReclaimedSpace(beforeWrite: beforeWrite, afterWrite: afterWrite, afterClean: afterClean)
                #expect(try f.getContainerStatus(name) == "running")
            }
        }
    }
}
