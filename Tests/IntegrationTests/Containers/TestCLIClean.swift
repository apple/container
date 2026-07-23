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

@Suite
class TestCLIClean: CLITest {
    private struct StatusJSON: Codable {
        let appRoot: String
    }

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    private func appRoot() throws -> URL {
        let result = try run(arguments: ["system", "status", "--format", "json"]).check()
        let status = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
        return URL(fileURLWithPath: status.appRoot, isDirectory: true)
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        guard let allocated else {
            throw CLIError.executionFailed("failed to read allocated size for \(url.path)")
        }
        return Int64(allocated)
    }

    private func containerRootfsBlockURL(name: String) throws -> URL {
        let id = try getContainerId(name)
        return try appRoot()
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("rootfs.ext4", isDirectory: false)
    }

    private func volumeBlockURL(name: String) throws -> URL {
        try appRoot()
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

    @Test func testCleanStoppedContainerFails() throws {
        let name = getTestName()
        try doLongRun(name: name, autoRemove: false)
        defer { try? doRemove(name: name) }

        try waitForContainerRunning(name)
        try doStop(name: name)

        let status = try getContainerStatus(name)
        #expect(status == "stopped")

        // Clean should fail on stopped container
        let (_, _, _, exitStatus) = try run(arguments: ["clean", name])
        #expect(exitStatus != 0)
    }

    @Test func testCleanMultipleContainers() throws {
        let name1 = getTestName() + "1"
        let name2 = getTestName() + "2"

        try doLongRun(name: name1, autoRemove: false)
        try doLongRun(name: name2, autoRemove: false)

        defer {
            try? doStop(name: name1)
            try? doStop(name: name2)
            try? doRemove(name: name1)
            try? doRemove(name: name2)
        }

        try waitForContainerRunning(name1)
        try waitForContainerRunning(name2)

        // Clean both containers
        let (_, _, _, exitStatus1) = try run(arguments: ["clean", name1, name2])
        #expect(exitStatus1 == 0)

        // Both containers should still be running
        let status1 = try getContainerStatus(name1)
        let status2 = try getContainerStatus(name2)
        #expect(status1 == "running")
        #expect(status2 == "running")
    }

    @Test func testCleanAfterFileCreation() throws {
        let name = getTestName()
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }

        try waitForContainerRunning(name)

        let rootfsBlockURL = try containerRootfsBlockURL(name: name)
        let beforeWrite = try allocatedBytes(at: rootfsBlockURL)

        // Create some files to exercise the filesystem trim path
        _ = try doExec(name: name, cmd: ["sh", "-c", "dd if=/dev/urandom of=/test-file bs=1M count=10"])
        _ = try doExec(name: name, cmd: ["sync"])
        let afterWrite = try allocatedBytes(at: rootfsBlockURL)

        _ = try doExec(name: name, cmd: ["rm", "/test-file"])

        // Clean should succeed
        try doClean(name: name)
        _ = try doExec(name: name, cmd: ["sync"])
        let afterClean = try allocatedBytes(at: rootfsBlockURL)
        assertCleanReclaimedSpace(beforeWrite: beforeWrite, afterWrite: afterWrite, afterClean: afterClean)

        // Container should still be running
        let status = try getContainerStatus(name)
        #expect(status == "running")
    }

    @Test func testCleanWithVolume() throws {
        let name = getTestName()
        let volumeName = name + "-vol"

        // Create a volume
        let (_, _, volError, volStatus) = try run(arguments: ["volume", "create", volumeName])
        guard volStatus == 0 else {
            throw CLIError.executionFailed("volume create failed: \(volError)")
        }

        defer {
            try? run(arguments: ["volume", "rm", volumeName])
        }

        // Create container with volume mount
        try doCreate(
            name: name,
            image: nil,
            args: nil,
            volumes: ["\(volumeName):/mnt/vol"],
            networks: [],
            ports: []
        )

        try doStart(name: name)

        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }

        try waitForContainerRunning(name)

        let volumeBlockURL = try volumeBlockURL(name: volumeName)
        let beforeWrite = try allocatedBytes(at: volumeBlockURL)

        // Write to volume
        _ = try doExec(name: name, cmd: ["sh", "-c", "dd if=/dev/urandom of=/mnt/vol/test bs=1M count=5"])
        _ = try doExec(name: name, cmd: ["sync"])
        let afterWrite = try allocatedBytes(at: volumeBlockURL)

        _ = try doExec(name: name, cmd: ["rm", "/mnt/vol/test"])

        // Clean should succeed and also trim the volume
        try doClean(name: name)
        _ = try doExec(name: name, cmd: ["sync"])
        let afterClean = try allocatedBytes(at: volumeBlockURL)
        assertCleanReclaimedSpace(beforeWrite: beforeWrite, afterWrite: afterWrite, afterClean: afterClean)

        // Container should still be running
        let status = try getContainerStatus(name)
        #expect(status == "running")
    }
}
