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

@Suite
struct TestCLIClean {
    private struct StatusJSON: Codable {
        let appRoot: String
    }

    private func appRoot(_ fixture: ContainerFixture) throws -> URL {
        let result = try fixture.run(["system", "status", "--format", "json"]).check()
        let status = try JSONDecoder().decode(StatusJSON.self, from: result.outputData)
        return URL(filePath: status.appRoot, directoryHint: .isDirectory)
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int64(fileStatus.st_blocks) * 512
    }

    private func containerRootfsBlockURL(_ fixture: ContainerFixture, name: String) throws -> URL {
        let id = try fixture.getContainerId(name)
        return try appRoot(fixture)
            .appending(path: "containers", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: "rootfs.ext4", directoryHint: .notDirectory)
    }

    private func volumeBlockURL(_ fixture: ContainerFixture, name: String) throws -> URL {
        try appRoot(fixture)
            .appending(path: "volumes", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: "volume.img", directoryHint: .notDirectory)
    }

    private func expectReclaimedSpace(beforeWrite: Int64, afterWrite: Int64, afterClean: Int64) {
        let allocatedByWrite = afterWrite - beforeWrite
        #expect(allocatedByWrite > 0, "test write should allocate host storage")

        let reclaimed = afterWrite - afterClean
        #expect(reclaimed > 0, "clean should reclaim host storage")

        let minimumExpectedReclaimed = Int64(Double(allocatedByWrite) * 0.8)
        #expect(
            reclaimed >= minimumExpectedReclaimed,
            "clean should reclaim at least 80% of storage allocated by the test write")
    }

    private func waitForStableAllocatedSpace(
        at url: URL,
        timeout: TimeInterval = 10
    ) async throws -> Int64 {
        let deadline = Date.now.addingTimeInterval(timeout)
        var previous = try allocatedBytes(at: url)
        var unchangedSamples = 0

        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let current = try allocatedBytes(at: url)
            if current == previous {
                unchangedSamples += 1
                if unchangedSamples == 4 {
                    return current
                }
            } else {
                previous = current
                unchangedSamples = 0
            }
        }
        return previous
    }

    private func waitForAllocatedSpace(
        after baseline: Int64,
        at url: URL,
        timeout: TimeInterval = 10
    ) async throws -> Int64 {
        let deadline = Date.now.addingTimeInterval(timeout)
        var allocated = try allocatedBytes(at: url)

        while allocated <= baseline, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            allocated = try allocatedBytes(at: url)
        }
        return allocated
    }

    private func waitForReclaimedSpace(
        beforeWrite: Int64,
        afterWrite: Int64,
        at url: URL,
        timeout: TimeInterval = 10
    ) async throws -> Int64 {
        let allocatedByWrite = afterWrite - beforeWrite
        let minimumExpectedReclaimed = Int64(Double(allocatedByWrite) * 0.8)
        let deadline = Date.now.addingTimeInterval(timeout)
        var afterClean = try allocatedBytes(at: url)

        while afterWrite - afterClean < minimumExpectedReclaimed, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            afterClean = try allocatedBytes(at: url)
        }
        return afterClean
    }

    @Test func cleanRejectsStoppedContainer() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-clean-stopped"
            try await fixture.doLongRun(
                name: name,
                autoRemove: false,
                waitUntilRunning: true)
            fixture.addCleanup { try? fixture.doRemove(name, force: true) }

            try fixture.doStop(name)
            #expect(try fixture.getContainerStatus(name) == "stopped")

            let result = try fixture.run(["clean", name])
            #expect(result.status != 0, "clean should reject a stopped container")
            #expect(
                result.error.contains("not running"),
                "clean should report that the stopped container is not running; stderr: \(result.error)")
        }
    }

    @Test func cleanSupportsMultipleRunningContainers() async throws {
        try await ContainerFixture.with { fixture in
            let primary = "\(fixture.testID)-clean-primary"
            let secondary = "\(fixture.testID)-clean-secondary"

            try await fixture.doLongRun(
                name: primary,
                autoRemove: false,
                waitUntilRunning: true)
            fixture.addCleanup { try? fixture.doRemove(primary, force: true) }

            try await fixture.doLongRun(
                name: secondary,
                autoRemove: false,
                waitUntilRunning: true)
            fixture.addCleanup { try? fixture.doRemove(secondary, force: true) }

            try fixture.run(["clean", primary, secondary]).check()
            #expect(try fixture.getContainerStatus(primary) == "running")
            #expect(try fixture.getContainerStatus(secondary) == "running")
        }
    }

    @Test func cleanReclaimsRootFilesystemSpace() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-clean-rootfs-reclaim"
            try await fixture.doLongRun(
                name: name,
                autoRemove: false,
                waitUntilRunning: true)
            fixture.addCleanup { try? fixture.doRemove(name, force: true) }

            let rootfsBlockURL = try containerRootfsBlockURL(fixture, name: name)
            try fixture.doClean(name)
            let beforeWrite = try await waitForStableAllocatedSpace(at: rootfsBlockURL)

            try fixture.doExec(
                name,
                cmd: ["sh", "-c", "dd if=/dev/urandom of=/rootfs-reclaim.dat bs=1M count=256"])
            try fixture.doExec(name, cmd: ["sync"])
            let afterWrite = try await waitForAllocatedSpace(after: beforeWrite, at: rootfsBlockURL)

            try fixture.doExec(name, cmd: ["rm", "/rootfs-reclaim.dat"])
            try fixture.doExec(name, cmd: ["sync"])
            try fixture.doClean(name)
            let afterClean = try await waitForReclaimedSpace(
                beforeWrite: beforeWrite,
                afterWrite: afterWrite,
                at: rootfsBlockURL)
            print("rootfs allocated bytes before=\(beforeWrite) afterWrite=\(afterWrite) afterClean=\(afterClean)")

            expectReclaimedSpace(
                beforeWrite: beforeWrite,
                afterWrite: afterWrite,
                afterClean: afterClean)
            #expect(try fixture.getContainerStatus(name) == "running")
        }
    }

    @Test func cleanReclaimsNamedVolumeSpace() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-clean-volume-reclaim"
            let volumeName = "\(fixture.testID)-clean-reclaim-data"

            try fixture.doVolumeCreate(volumeName)
            fixture.addCleanup { fixture.doVolumeDeleteIfExists(volumeName) }

            try fixture.doCreate(
                name: name,
                volumes: ["\(volumeName):/mnt/reclaim-data"])
            fixture.addCleanup { try? fixture.doRemove(name, force: true) }
            try fixture.doStart(name)
            try await fixture.waitForContainerRunning(name)

            let volumeBlockURL = try volumeBlockURL(fixture, name: volumeName)
            try fixture.doClean(name)
            let beforeWrite = try await waitForStableAllocatedSpace(at: volumeBlockURL)

            try fixture.doExec(
                name,
                cmd: ["sh", "-c", "dd if=/dev/urandom of=/mnt/reclaim-data/volume-reclaim.dat bs=1M count=256"])
            try fixture.doExec(name, cmd: ["sync"])
            let afterWrite = try await waitForAllocatedSpace(after: beforeWrite, at: volumeBlockURL)

            try fixture.doExec(name, cmd: ["rm", "/mnt/reclaim-data/volume-reclaim.dat"])
            try fixture.doExec(name, cmd: ["sync"])
            try fixture.doClean(name)
            let afterClean = try await waitForReclaimedSpace(
                beforeWrite: beforeWrite,
                afterWrite: afterWrite,
                at: volumeBlockURL)
            print("volume allocated bytes before=\(beforeWrite) afterWrite=\(afterWrite) afterClean=\(afterClean)")

            expectReclaimedSpace(
                beforeWrite: beforeWrite,
                afterWrite: afterWrite,
                afterClean: afterClean)
            #expect(try fixture.getContainerStatus(name) == "running")
        }
    }
}
