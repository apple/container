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
import Foundation
import Testing

@Suite(.serialized)
class TestCLIVolumes: CLITest {

    func doVolumeCreate(name: String) throws {
        let (_, _, error, status) = try run(arguments: ["volume", "create", name])
        if status != 0 {
            throw CLIError.executionFailed("volume create failed: \(error)")
        }
    }

    func doVolumeDelete(name: String) throws {
        let (_, _, error, status) = try run(arguments: ["volume", "rm", name])
        if status != 0 {
            throw CLIError.executionFailed("volume delete failed: \(error)")
        }
    }

    func doVolumeDeleteIfExists(name: String) {
        let (_, _, _, _) = (try? run(arguments: ["volume", "rm", name])) ?? (nil, "", "", 1)
    }

    func doRemoveIfExists(name: String, force: Bool = false) {
        var args = ["delete"]
        if force {
            args.append("--force")
        }
        args.append(name)
        let (_, _, _, _) = (try? run(arguments: args)) ?? (nil, "", "", 1)
    }

    func doesVolumeDeleteFail(name: String) throws -> Bool {
        let (_, _, _, status) = try run(arguments: ["volume", "rm", name])
        return status != 0
    }

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testVolumeDataPersistenceAcrossContainers() throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"
        let container1Name = "\(testName)_c1"
        let container2Name = "\(testName)_c2"
        let testData = "persistent-data-test"
        let testFile = "/data/test.txt"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)
        doRemoveIfExists(name: container1Name, force: true)
        doRemoveIfExists(name: container2Name, force: true)

        defer {
            // Cleanup containers and volume
            try? doStop(name: container1Name)
            doRemoveIfExists(name: container1Name, force: true)
            try? doStop(name: container2Name)
            doRemoveIfExists(name: container2Name, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // Run first container with volume, write data, then stop
        try doLongRun(name: container1Name, args: ["-v", "\(volumeName):/data"])
        try waitForContainerRunning(container1Name)

        // Write test data to the volume
        _ = try doExec(name: container1Name, cmd: ["sh", "-c", "echo '\(testData)' > \(testFile)"])

        // Stop first container
        try doStop(name: container1Name)

        // Run second container with same volume
        try doLongRun(name: container2Name, args: ["-v", "\(volumeName):/data"])
        try waitForContainerRunning(container2Name)

        // Verify data persisted
        var output = try doExec(name: container2Name, cmd: ["cat", testFile])
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output == testData, "expected persisted data '\(testData)', instead got '\(output)'")

        try doStop(name: container2Name)
        try doVolumeDelete(name: volumeName)
    }

    @Test func testVolumeSharedAccessConflict() throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"
        let container1Name = "\(testName)_c1"
        let container2Name = "\(testName)_c2"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)
        doRemoveIfExists(name: container1Name, force: true)
        doRemoveIfExists(name: container2Name, force: true)

        defer {
            // Cleanup containers and volume
            try? doStop(name: container1Name)
            doRemoveIfExists(name: container1Name, force: true)
            try? doStop(name: container2Name)
            doRemoveIfExists(name: container2Name, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // Run first container with volume
        try doLongRun(name: container1Name, args: ["-v", "\(volumeName):/data"])
        try waitForContainerRunning(container1Name)

        // Try to run second container with same volume - should fail
        let (_, _, _, status) = try run(arguments: ["run", "--name", container2Name, "-v", "\(volumeName):/data", alpine] + defaultContainerArgs)

        #expect(status != 0, "second container should fail when trying to use volume already in use")

        // Cleanup
        try doStop(name: container1Name)
        doRemoveIfExists(name: container1Name, force: true)
        doVolumeDeleteIfExists(name: volumeName)
    }

    @Test func testVolumeDeleteProtectionWhileInUse() throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"
        let containerName = "\(testName)_c1"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)
        doRemoveIfExists(name: containerName, force: true)

        defer {
            // Cleanup container and volume
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // Run container with volume
        try doLongRun(name: containerName, args: ["-v", "\(volumeName):/data"])
        try waitForContainerRunning(containerName)

        // Try to delete volume while container is running - should fail
        let deleteFailedWhileInUse = try doesVolumeDeleteFail(name: volumeName)
        #expect(deleteFailedWhileInUse, "volume delete should fail while volume is in use")

        // Stop container
        try doStop(name: containerName)
        doRemoveIfExists(name: containerName, force: true)

        // Now volume delete should succeed
        try doVolumeDelete(name: volumeName)
    }

    @Test func testVolumeDeleteProtectionWithCreatedContainer() async throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"
        let containerName = "\(testName)_c1"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)
        doRemoveIfExists(name: containerName, force: true)

        defer {
            // Cleanup container and volume
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // Create (but don't start) container with volume
        try doCreate(name: containerName, image: alpine, volumes: ["\(volumeName):/mnt/data"])

        // Give some time for container to be fully registered
        try await Task.sleep(for: .seconds(1))

        // Try to delete volume while container is created - should fail
        let deleteFailedWhileInUse = try doesVolumeDeleteFail(name: volumeName)
        #expect(deleteFailedWhileInUse, "volume delete should fail when volume is used by created container")

        // Remove the container
        doRemoveIfExists(name: containerName, force: true)

        // Now volume delete should succeed
        doVolumeDeleteIfExists(name: volumeName)
    }

    @Test func testVolumeBasicOperations() throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)

        defer {
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // List volumes and verify it exists
        let (_, output, error, status) = try run(arguments: ["volume", "list", "--quiet"])
        if status != 0 {
            throw CLIError.executionFailed("volume list failed: \(error)")
        }

        let volumes = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        #expect(volumes.contains(volumeName), "created volume should appear in list")

        // Inspect volume
        let (_, inspectOutput, inspectError, inspectStatus) = try run(arguments: ["volume", "inspect", volumeName])
        if inspectStatus != 0 {
            throw CLIError.executionFailed("volume inspect failed: \(inspectError)")
        }

        #expect(inspectOutput.contains(volumeName), "volume inspect should contain volume name")

        // Delete volume
        try doVolumeDelete(name: volumeName)
    }

    @Test func testImplicitNamedVolumeCreation() throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let volumeName = "\(testName)_autovolume"

        defer {
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // Verify volume doesn't exist yet
        let (_, listOutput, _, _) = try run(arguments: ["volume", "list", "--quiet"])
        let volumeExistsBefore = listOutput.contains(volumeName)
        #expect(!volumeExistsBefore, "volume should not exist initially")

        // Run container with non-existent named volume - should auto-create
        let (_, output, _, status) = try run(arguments: [
            "run",
            "--name",
            containerName,
            "-v", "\(volumeName):/data",
            alpine,
            "echo", "test",
        ])

        // Should succeed and create volume automatically
        #expect(status == 0, "should succeed and auto-create named volume")
        #expect(output.contains("test"), "container should run successfully")

        // Volume should now exist
        let (_, listOutputAfter, _, _) = try run(arguments: ["volume", "list", "--quiet"])
        let volumeExistsAfter = listOutputAfter.contains(volumeName)
        #expect(volumeExistsAfter, "volume should be created")
    }

    @Test func testImplicitNamedVolumeReuse() throws {
        let testName = getTestName()
        let containerName1 = "\(testName)_c1"
        let containerName2 = "\(testName)_c2"
        let volumeName = "\(testName)_sharedvolume"

        defer {
            doRemoveIfExists(name: containerName1, force: true)
            doRemoveIfExists(name: containerName2, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        // First container - should auto-create volume
        let (_, _, _, status1) = try run(arguments: [
            "run",
            "--name",
            containerName1,
            "-v", "\(volumeName):/data",
            alpine,
            "sh", "-c", "echo 'first' > /data/test.txt",
        ])

        #expect(status1 == 0, "first container should succeed")

        // Second container - should reuse existing volume
        let (_, _, _, status2) = try run(arguments: [
            "run",
            "--name",
            containerName2,
            "-v", "\(volumeName):/data",
            alpine,
            "cat", "/data/test.txt",
        ])

        #expect(status2 == 0, "second container should succeed")
    }

    @Test func testVolumePruneNoVolumes() throws {
        // Prune with no volumes should succeed with 0 reclaimed
        let (_, output, error, status) = try run(arguments: ["volume", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("volume prune failed: \(error)")
        }

        #expect(output.contains("Zero KB"), "should show no space reclaimed")
    }

    @Test func testVolumePruneUnusedVolumes() throws {
        let testName = getTestName()
        let volumeName1 = "\(testName)_vol1"
        let volumeName2 = "\(testName)_vol2"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName1)
        doVolumeDeleteIfExists(name: volumeName2)

        defer {
            doVolumeDeleteIfExists(name: volumeName1)
            doVolumeDeleteIfExists(name: volumeName2)
        }

        try doVolumeCreate(name: volumeName1)
        try doVolumeCreate(name: volumeName2)
        let (_, listBefore, _, statusBefore) = try run(arguments: ["volume", "list", "--quiet"])
        #expect(statusBefore == 0)
        #expect(listBefore.contains(volumeName1))
        #expect(listBefore.contains(volumeName2))

        // Prune should remove both
        let (_, output, error, status) = try run(arguments: ["volume", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("volume prune failed: \(error)")
        }

        #expect(output.contains(volumeName1) || !output.contains("No volumes to prune"), "should prune volume1")
        #expect(output.contains(volumeName2) || !output.contains("No volumes to prune"), "should prune volume2")
        #expect(output.contains("Reclaimed"), "should show reclaimed space")

        // Verify volumes are gone
        let (_, listAfter, _, statusAfter) = try run(arguments: ["volume", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(!listAfter.contains(volumeName1), "volume1 should be pruned")
        #expect(!listAfter.contains(volumeName2), "volume2 should be pruned")
    }

    @Test func testVolumePruneSkipsVolumeInUse() throws {
        let testName = getTestName()
        let volumeInUse = "\(testName)_inuse"
        let volumeUnused = "\(testName)_unused"
        let containerName = "\(testName)_c1"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeInUse)
        doVolumeDeleteIfExists(name: volumeUnused)
        doRemoveIfExists(name: containerName, force: true)

        defer {
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: volumeInUse)
            doVolumeDeleteIfExists(name: volumeUnused)
        }

        try doVolumeCreate(name: volumeInUse)
        try doVolumeCreate(name: volumeUnused)
        try doLongRun(name: containerName, args: ["-v", "\(volumeInUse):/data"])
        try waitForContainerRunning(containerName)

        // Prune should only remove the unused volume
        let (_, _, error, status) = try run(arguments: ["volume", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("volume prune failed: \(error)")
        }

        // Verify in-use volume still exists
        let (_, listAfter, _, statusAfter) = try run(arguments: ["volume", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(volumeInUse), "volume in use should NOT be pruned")
        #expect(!listAfter.contains(volumeUnused), "unused volume should be pruned")

        try doStop(name: containerName)
        doRemoveIfExists(name: containerName, force: true)
        doVolumeDeleteIfExists(name: volumeInUse)
    }

    @Test func testVolumePruneSkipsVolumeAttachedToStoppedContainer() async throws {
        let testName = getTestName()
        let volumeName = "\(testName)_vol"
        let containerName = "\(testName)_c1"

        // Clean up any existing resources from previous runs
        doVolumeDeleteIfExists(name: volumeName)
        doRemoveIfExists(name: containerName, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: volumeName)
        }

        try doVolumeCreate(name: volumeName)
        try doCreate(name: containerName, image: alpine, volumes: ["\(volumeName):/data"])
        try await Task.sleep(for: .seconds(1))

        // Prune should NOT remove the volume (container exists, even if stopped)
        let (_, _, error, status) = try run(arguments: ["volume", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("volume prune failed: \(error)")
        }

        let (_, listAfter, _, statusAfter) = try run(arguments: ["volume", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(volumeName), "volume attached to stopped container should NOT be pruned")

        doRemoveIfExists(name: containerName, force: true)
        let (_, _, error2, status2) = try run(arguments: ["volume", "prune"])
        if status2 != 0 {
            throw CLIError.executionFailed("volume prune failed: \(error2)")
        }

        // Verify volume is gone
        let (_, listFinal, _, statusFinal) = try run(arguments: ["volume", "list", "--quiet"])
        #expect(statusFinal == 0)
        #expect(!listFinal.contains(volumeName), "volume should be pruned after container is deleted")
    }
}
