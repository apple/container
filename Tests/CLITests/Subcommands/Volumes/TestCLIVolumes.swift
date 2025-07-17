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

import ContainerClient
import Foundation
import Testing

class TestCLIVolumes: CLITest {

    func doVolumeCreate(name: String) throws {
        let (_, error, status) = try run(arguments: ["volume", "create", name])
        if status != 0 {
            throw CLIError.executionFailed("volume create failed: \(error)")
        }
    }

    func doVolumeDelete(name: String) throws {
        let (_, error, status) = try run(arguments: ["volume", "rm", name])
        if status != 0 {
            throw CLIError.executionFailed("volume delete failed: \(error)")
        }
    }

    func doesVolumeDeleteFail(name: String) throws -> Bool {
        let (_, _, status) = try run(arguments: ["volume", "rm", name])
        return status != 0
    }

    @Test func testVolumeDataPersistenceAcrossContainers() throws {
        let testName: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        let volumeName = "\(testName!)_vol"
        let container1Name = "\(testName!)_c1"
        let container2Name = "\(testName!)_c2"
        let testData = "persistent-data-test"
        let testFile = "/data/test.txt"

        defer {
            // Cleanup containers and volume
            try? doStop(name: container1Name)
            try? doStop(name: container2Name)
            try? doVolumeDelete(name: volumeName)
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
        let testName: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        let volumeName = "\(testName!)_vol"
        let container1Name = "\(testName!)_c1"
        let container2Name = "\(testName!)_c2"

        defer {
            // Cleanup containers and volume
            try? doStop(name: container1Name)
            try? doStop(name: container2Name)
            try? doVolumeDelete(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // Run first container with volume
        try doLongRun(name: container1Name, args: ["-v", "\(volumeName):/data"])
        try waitForContainerRunning(container1Name)

        // Try to run second container with same volume - should fail
        let (_, _, status) = try run(arguments: ["run", "--name", container2Name, "-v", "\(volumeName):/data", alpine] + defaultContainerArgs)

        #expect(status != 0, "second container should fail when trying to use volume already in use")

        // Cleanup
        try doStop(name: container1Name)
        try doVolumeDelete(name: volumeName)
    }

    @Test func testVolumeDeleteProtectionWhileInUse() throws {
        let testName: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        let volumeName = "\(testName!)_vol"
        let containerName = "\(testName!)_c1"

        defer {
            // Cleanup container and volume
            try? doStop(name: containerName)
            try? doVolumeDelete(name: volumeName)
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

        // Now volume delete should succeed
        try doVolumeDelete(name: volumeName)
    }

    @Test func testVolumeBasicOperations() throws {
        let testName: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        let volumeName = "\(testName!)_vol"

        defer {
            try? doVolumeDelete(name: volumeName)
        }

        // Create volume
        try doVolumeCreate(name: volumeName)

        // List volumes and verify it exists
        let (output, error, status) = try run(arguments: ["volume", "list", "--quiet"])
        if status != 0 {
            throw CLIError.executionFailed("volume list failed: \(error)")
        }

        let volumes = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        #expect(volumes.contains(volumeName), "created volume should appear in list")

        // Inspect volume
        let (inspectOutput, inspectError, inspectStatus) = try run(arguments: ["volume", "inspect", volumeName])
        if inspectStatus != 0 {
            throw CLIError.executionFailed("volume inspect failed: \(inspectError)")
        }

        #expect(inspectOutput.contains(volumeName), "volume inspect should contain volume name")

        // Delete volume
        try doVolumeDelete(name: volumeName)
    }
}
