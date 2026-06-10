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

import Containerization
import Darwin
import Foundation
import MachineAPIClient
import Testing

@Suite(.serialSuites)
class TestCLIMachineCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    func runMachine(arguments: [String], stdin: Data? = nil) throws -> (outputData: Data, output: String, error: String, status: Int32) {
        try run(arguments: ["machine"] + arguments, stdin: stdin)
    }

    private func doCreate(
        name: String,
        image: String? = nil
    ) throws {
        let image = image ?? alpine

        var args = ["create", "--no-boot", "--name", name]

        args += [image]

        let (_, _, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doMachineDelete(name: String) throws {
        let args = ["rm", name]

        let (_, _, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    @Test func testCreate() throws {
        let name = getTestName()

        #expect(throws: Never.self, "expected container machine create to succeed") {
            try doCreate(name: name)
            try doMachineDelete(name: name)
        }
    }

    @Test func testCreateRejectsDots() throws {
        let (_, _, error, status) = try runMachine(arguments: ["create", "--name", "my.bad.name", "alpine:latest"])
        #expect(status != 0, "create should reject names with dots")
        #expect(error.contains("must start and end"), "error should explain the constraint")
    }
}

/// Integration tests for container machine runtime commands: stop, inspect, run, set.
/// Tests are serialized since container machine operations share system resources and
/// concurrent VM operations could interfere with each other.
@Suite(.serialSuites, .serialized)
class TestCLIMachineRuntime: CLITest {
    let machineImage = "ghcr.io/linuxcontainers/alpine:3.20"

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    func runMachine(arguments: [String], env: [String: String]) throws -> (outputData: Data, output: String, error: String, status: Int32) {
        try run(arguments: ["machine"] + arguments, tty: true, env: env)
    }

    func runMachine(arguments: [String]) throws -> (outputData: Data, output: String, error: String, status: Int32) {
        try run(arguments: ["machine"] + arguments, tty: true)
    }

    private func doMachineCreate(name: String, image: String? = nil) throws {
        cleanupMachine(name)
        let img = image ?? machineImage
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, img])
        if status != 0 {
            throw CLIError.executionFailed("container machine create failed: \(error)")
        }
    }

    private func doMachineBoot(name: String? = nil) throws -> String {
        // Boot by running a trivial command (run auto-boots)
        var args = ["run", "--root"]
        if let name { args.append(contentsOf: ["-n", name]) }
        args.append(contentsOf: ["true"])
        let (_, _, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("container machine boot (via run) failed: \(error)")
        }
        // Return the container machine name for compatibility with existing tests
        return name ?? ""
    }

    private func doMachineStop(name: String? = nil) throws -> String {
        var args = ["stop"]
        if let name { args.append(name) }
        let (_, output, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("container machine stop failed: \(error)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func doMachineInspect(name: String? = nil) throws -> MachineInspectOutput {
        var args = ["inspect"]
        if let name { args.append(name) }
        let (outputData, _, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("container machine inspect failed: \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let results = try decoder.decode([MachineInspectOutput].self, from: outputData)
        guard let result = results.first else {
            throw CLIError.executionFailed("container machine inspect returned empty array")
        }
        return result
    }

    private func doMachineRun(
        name: String? = nil,
        root: Bool = false,
        env: [String] = [],
        cwd: String? = nil,
        command: [String]
    ) throws -> String {
        var args = ["run"]
        if let name { args.append(contentsOf: ["-n", name]) }
        if root { args.append("--root") }
        if let cwd { args.append(contentsOf: ["--cwd", cwd]) }
        for e in env { args.append(contentsOf: ["-e", e]) }
        args.append(contentsOf: command)
        let (_, output, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("container machine run failed: \(error)")
        }
        return output
    }

    private func doMachineRemove(name: String) throws {
        let args = ["rm", name]
        let (_, _, error, status) = try runMachine(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("container machine rm failed: \(error)")
        }
    }

    private func waitForMachineStatus(_ name: String, status: String, maxAttempts: Int = 30) throws {
        for _ in 0..<maxAttempts {
            let snapshot = try doMachineInspect(name: name)
            if snapshot.status == status {
                return
            }
            sleep(1)
        }
        throw CLIError.executionFailed("container machine \(name) did not reach status \(status)")
    }

    private func cleanupMachine(_ name: String) {
        _ = try? doMachineStop(name: name)
        _ = try? doMachineRemove(name: name)
    }

    @Test func testCreateNameLongestValid() throws {
        let maxNameLength = LinuxContainer.maxIDLength - MachineConfiguration.containerUUIDLength - 1

        let name = String(repeating: "a", count: maxNameLength)
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        #expect(throws: Never.self) {
            _ = try doMachineBoot(name: name)
        }
    }

    @Test func testCreateNameLongerThanMax() throws {
        let maxNameLength = LinuxContainer.maxIDLength - MachineConfiguration.containerUUIDLength - 1

        let name = String(repeating: "a", count: maxNameLength + 1)
        #expect(throws: Error.self) {
            try doMachineCreate(name: name)
        }
    }

    @Test func testStopRunningMachine() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let beforeSnapshot = try doMachineInspect(name: name)
        #expect(beforeSnapshot.startedDate != nil, "running container machine should have startedDate")

        let output = try doMachineStop(name: name)
        #expect(output == name, "stop should output the container machine ID")

        let afterSnapshot = try doMachineInspect(name: name)
        #expect(afterSnapshot.status == "stopped", "container machine should be stopped after stop")
        #expect(afterSnapshot.startedDate == nil, "stopped container machine should not have startedDate")
    }

    /// Verifies that stopping an already-stopped container machine is a no-op and succeeds.
    @Test func testStopIdempotent() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let output = try doMachineStop(name: name)
        #expect(output == name, "stop on stopped container machine should succeed")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "stopped", "container machine should remain stopped")
    }

    @Test func testStopNonExistentMachine() throws {
        let name = "nonexistent-machine-\(UUID().uuidString.lowercased())"

        let (_, _, error, status) = try runMachine(arguments: ["stop", name])
        #expect(status != 0, "stop should fail for non-existent container machine")
        #expect(error.contains("not found"), "error should mention 'not found'")
    }

    @Test func testInspectStoppedMachine() throws {
        let name = getTestName()
        try doMachineCreate(name: name, image: machineImage)
        defer { cleanupMachine(name) }

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "stopped", "new container machine should be stopped")
        #expect(snapshot.startedDate == nil, "stopped container machine should not have startedDate")
        #expect(snapshot.id == name, "configuration should have correct ID")
        #expect(snapshot.image.reference.contains("alpine"), "configuration should show image")
        #expect(snapshot.createdDate != nil, "should have createdDate")
        #expect(snapshot.ipAddress == nil, "stopped machine should not have address")
        #expect(snapshot.cpus > 0, "should have resolved cpus")
        #expect(snapshot.memory > 0, "should have resolved memory")
    }

    @Test func testInspectRunningMachine() throws {
        let name = getTestName()
        try doMachineCreate(name: name, image: machineImage)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "running", "booted container machine should be running")
        #expect(snapshot.startedDate != nil, "running container machine should have startedDate")
        #expect(snapshot.id == name, "configuration should have correct ID")
        #expect(snapshot.platform.os == "linux", "platform OS should be linux")
        #expect(snapshot.ipAddress != nil, "running machine should have IP address")
    }

    @Test func testInspectNonExistentMachine() throws {
        let name = "nonexistent-machine-\(UUID().uuidString.lowercased())"

        let (_, _, error, status) = try runMachine(arguments: ["inspect", name])
        #expect(status != 0, "inspect should fail for non-existent container machine")
        #expect(error.contains("not found"), "error should mention 'not found'")
    }

    @Test func testRunSimpleCommand() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(name: name, root: true, command: ["echo", "hello"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello",
            "run should execute command and return output"
        )
    }

    /// Verifies that running a command on a stopped container machine automatically boots it.
    @Test func testRunDefaultHostsEntries() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let inspect = try doMachineInspect(name: name)
        let ip = try #require(inspect.ipAddress, "running machine should have an IP address")

        let output = try doMachineRun(name: name, root: true, command: ["cat", "/etc/hosts"])
        let lines = output.split(separator: "\n")

        let expectedEntries = [("127.0.0.1", "localhost"), (ip, name)]

        for (i, line) in lines.enumerated() {
            let words = line.split(separator: " ").map { String($0) }
            #expect(words.count >= 2, "expected /etc/hosts entry to have 2 or more entries")
            let expected = expectedEntries[i]
            #expect(expected.0 == words[0], "expected /etc/hosts entry IP to be \(expected.0), got \(words[0])")
            #expect(expected.1 == words[1], "expected /etc/hosts entry hostname to be \(expected.1), got \(words[1])")
        }
    }

    @Test func testRunAutoBoots() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let beforeSnapshot = try doMachineInspect(name: name)
        #expect(beforeSnapshot.status == "stopped", "container machine should start stopped")

        let output = try doMachineRun(name: name, root: true, command: ["echo", "autoboot"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "autoboot",
            "run should auto-boot and execute command"
        )

        let afterSnapshot = try doMachineInspect(name: name)
        #expect(afterSnapshot.status == "running", "container machine should be running after auto-boot")
    }

    @Test func testRunAsRoot() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(name: name, root: true, command: ["id", "-u"])
        let uid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(uid == "0", "running with --root should execute as uid 0")
    }

    /// Verifies that the default run mode creates a user matching the host UID/GID.
    @Test func testRunAsHostUser() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let hostUid = getuid()
        let output = try doMachineRun(name: name, command: ["id", "-u"])
        let actualUid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(actualUid == "\(hostUid)", "default run should use host user's UID")
    }

    /// Verifies that first-boot bootstrap creates the NOPASSWD sudoers entry
    /// for the host user, even on minimal images that ship without /etc/sudoers.d.
    @Test func testFirstBootCreatesSudoersEntry() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let username = NSUserName()
        let output = try doMachineRun(
            name: name,
            root: true,
            command: ["cat", "/etc/sudoers.d/\(username)"]
        )
        let content = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            content == "\(username) ALL=(ALL) NOPASSWD:ALL",
            "first-boot bootstrap should create NOPASSWD sudoers entry for host user"
        )
    }

    @Test func testRunWithEnvironment() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(
            name: name,
            root: true,
            env: ["MY_VAR=hello_world"],
            command: ["echo", "$MY_VAR"]
        )
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello_world",
            "run should set environment variables"
        )
    }

    @Test func testRunWithCwd() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(name: name, root: true, cwd: "/tmp", command: ["pwd"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp",
            "run should use specified working directory"
        )
    }

    @Test func testRunNonExistentMachine() throws {
        let name = "nonexistent-machine-\(UUID().uuidString.lowercased())"

        let (_, _, error, status) = try runMachine(arguments: ["run", "-n", name, "echo", "test"])
        #expect(status != 0, "run should fail for non-existent container machine")
        #expect(error.contains("not found"), "error should mention 'not found'")
    }

    /// End-to-end test covering the full container machine lifecycle including re-boot after stop.
    @Test func testFullLifecycle() throws {
        let name = getTestName()

        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        var snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "stopped", "new container machine should be stopped")

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "running", "container machine should be running after boot")

        let output = try doMachineRun(name: name, root: true, command: ["hostname"])
        #expect(!output.isEmpty, "should be able to run commands")

        _ = try doMachineStop(name: name)

        snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "stopped", "container machine should be stopped after stop")

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "running", "container machine should be running after re-boot")
    }

    /// Verifies that user setup is idempotent - running multiple commands doesn't fail.
    @Test func testUserSetupIdempotent() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output1 = try doMachineRun(name: name, command: ["id", "-u"])
        let output2 = try doMachineRun(name: name, command: ["id", "-u"])

        let uid1 = output1.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid2 = output2.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(uid1 == uid2, "user setup should be idempotent")
        #expect(uid1 == "\(getuid())", "should run as host user")
    }

    /// Verifies that the HOME environment variable is correctly set for the host user.
    @Test func testHostUserHasCorrectHome() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let hostUsername = NSUserName()

        let output = try doMachineRun(name: name, command: ["echo", "$HOME"])
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(home == "/home/\(hostUsername)", "HOME should be set to /home/<username>")
    }

    @Test func testListRunningMachines() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, output, _, status) = try runMachine(arguments: ["ls"])
        #expect(status == 0, "list should succeed")
        #expect(output.contains(name), "list should show running container machine")
    }

    @Test func testListAllMachines() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, output, _, status) = try runMachine(arguments: ["ls"])
        #expect(status == 0, "list should succeed")
        #expect(output.contains(name), "stopped container machine should appear in list")
    }

    @Test func testListQuietMode() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, output, _, status) = try runMachine(arguments: ["ls", "-q"])
        #expect(status == 0, "list -q should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name, "quiet mode should output only ID")
    }

    @Test func testListJsonFormat() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (outputData, _, _, status) = try runMachine(arguments: ["ls", "--format", "json"])
        #expect(status == 0, "list --format json should succeed")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([MachineListItem].self, from: outputData)
        let item = items.first { $0.id == name }
        #expect(item != nil, "JSON output should contain the machine")
        #expect(item?.status == "running")
        #expect(item?.ipAddress != nil, "running machine should have an address")
        #expect(item?.cpus ?? 0 > 0, "cpus should be resolved")
        #expect(item?.memory ?? 0 > 0, "memory should be resolved")
        #expect(item?.createdDate != nil, "createdDate should be set")
    }

    @Test func testListEmpty() throws {
        // List with no running container machines
        let (_, output, _, status) = try runMachine(arguments: ["ls"])
        #expect(status == 0, "list should succeed even with no running container machines")
        // Output should just be header or empty
        #expect(!output.contains("error"), "should not contain error")
    }

    @Test func testSetDefault() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, output, _, status) = try runMachine(arguments: ["set-default", name])
        #expect(status == 0, "set default should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name, "should output the container machine ID")

        // Verify it's now the default by listing
        let (_, listOutput, _, _) = try runMachine(arguments: ["ls"])
        #expect(listOutput.contains("*"), "container machine should be marked as default in list")
    }

    @Test func testSetDefaultNonExistent() throws {
        let name = "nonexistent-machine-\(UUID().uuidString.lowercased())"

        let (_, _, error, status) = try runMachine(arguments: ["set-default", name])
        #expect(status != 0, "set default should fail for non-existent container machine")
        #expect(error.contains("not found"), "error should mention 'not found'")
    }

    @Test func testSetDefaultSwitching() throws {
        let name1 = "\(getTestName())-1"
        let name2 = "\(getTestName())-2"
        try doMachineCreate(name: name1)
        try doMachineCreate(name: name2)
        defer {
            cleanupMachine(name1)
            cleanupMachine(name2)
        }

        // Set first as default
        _ = try runMachine(arguments: ["set-default", name1])

        // Set second as default
        let (_, output, _, status) = try runMachine(arguments: ["set-default", name2])
        #expect(status == 0, "switching default should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name2)

        // Verify by inspecting without specifying ID (uses default)
        let snapshot = try doMachineInspect()
        #expect(snapshot.id == name2, "inspect without ID should use new default")
    }

    @Test func testInspectUsesDefault() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try runMachine(arguments: ["set-default", name])

        // Inspect without specifying name
        let snapshot = try doMachineInspect()
        #expect(snapshot.id == name, "inspect should use default container machine")
    }

    @Test func testRunUsesDefault() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try runMachine(arguments: ["set-default", name])
        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        // Run without specifying -n
        let args = ["run", "--root", "echo", "default-test"]
        let (_, output, _, status) = try runMachine(arguments: args)
        #expect(status == 0, "run should succeed using default")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "default-test")
    }

    @Test func testRunWithUid() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, output, _, status) = try runMachine(arguments: ["run", "-n", name, "--uid", "1000", "id", "-u"])
        #expect(status == 0, "run with --uid should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "1000", "should run as specified UID")
    }

    @Test func testRunWithGid() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, output, _, status) = try runMachine(arguments: ["run", "-n", name, "--root", "--gid", "1000", "id", "-G"])
        #expect(status == 0, "run with --gid should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "0 1000", "should run with specified GID")
    }

    @Test func testRunWithEnvFile() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        // Create a temp env file
        let tempDir = FileManager.default.temporaryDirectory
        let envFile = tempDir.appendingPathComponent("test-\(name).env")
        try "TEST_VAR=from_file\nANOTHER_VAR=value2\n".write(to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }

        let (_, output, _, status) = try runMachine(arguments: [
            "run", "-n", name, "--root",
            "--env-file", envFile.path,
            "echo", "$TEST_VAR",
        ])
        #expect(status == 0, "run with --env-file should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "from_file", "should load env from file")
    }

    /// Verifies that machine run executes commands through a shell, enabling variable expansion.
    @Test func testRunCommandInShell() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        // $0 is passed as a literal string by the test; if the command is run
        // through a shell, the shell expands it to a real path (e.g. /bin/bash).
        let output = try doMachineRun(name: name, root: true, command: ["echo", "$0"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "should produce output")
        #expect(trimmed == "/bin/sh", "alpine shell should expand $0 to /bin/sh")
    }

    @Test func testRunCommandExitCode() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        // Run a command that exits with non-zero
        let (_, _, _, status) = try runMachine(arguments: ["run", "-n", name, "--root", "exit", "42"])
        #expect(status == 42, "exit code should propagate from command")
    }

    @Test func testRunMultipleEnvVars() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, output, _, status) = try runMachine(arguments: [
            "run", "-n", name, "--root",
            "-e", "VAR1=one",
            "-e", "VAR2=two",
            "-e", "VAR3=three",
            "echo", "$VAR1-$VAR2-$VAR3",
        ])
        #expect(status == 0, "run with multiple -e flags should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "one-two-three")
    }

    @Test func testRunWithUserFlag() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        // Test --user with uid:gid format
        let (_, output, _, status) = try runMachine(arguments: [
            "run", "-n", name,
            "--user", "1000:1000",
            "echo", "$(id -u):$(id -g)",
        ])
        #expect(status == 0, "run with --user uid:gid should succeed")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "1000:1000")
    }

    /// Verifies that killing a container machine's backing container updates the container machine state to stopped.
    @Test func testContainerExitState() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let snapshot = try doMachineInspect(name: name)
        guard let containerId = snapshot.containerId else {
            throw CLIError.executionFailed("running container machine has no containerId")
        }

        try doStop(name: containerId)
        try waitForMachineStatus(name, status: "stopped")

        let after = try doMachineInspect(name: name)
        #expect(after.status == "stopped", "container machine should be stopped after container is killed")
        #expect(after.containerId == nil, "stopped container machine should have no containerId")
        #expect(after.startedDate == nil, "stopped container machine should have no startedDate")
    }

    // MARK: - SSH forwarding tests

    @Test func testSSHForwarding() throws {
        let name = getTestName()

        let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }

        let socketPath = socketDir.appendingPathComponent("ssh-auth.sock").path

        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(serverFd >= 0, "socket() failed")
        defer { Darwin.close(serverFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            socketPath.withCString { cStr in
                bytes.copyMemory(from: UnsafeRawBufferPointer(start: cStr, count: socketPath.utf8.count + 1))
            }
        }
        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bindResult == 0, "bind() failed: \(errno)")
        precondition(listen(serverFd, 5) == 0, "listen() failed")

        let acceptThread = Thread {
            while true {
                let clientFd = accept(serverFd, nil, nil)
                if clientFd < 0 { break }
                Darwin.close(clientFd)
            }
        }
        acceptThread.start()

        sleep(1)

        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        // Boot the container machine with SSH_AUTH_SOCK set in the process environment.
        let (_, _, bootError, bootStatus) = try runMachine(
            arguments: ["run", "--root", "-n", name, "true"],
            env: ["SSH_AUTH_SOCK": socketPath]
        )
        if bootStatus != 0 {
            throw CLIError.executionFailed("container machine boot with SSH_AUTH_SOCK failed: \(bootError)")
        }
        try waitForMachineStatus(name, status: "running")

        let sshSockValue = try doMachineRun(name: name, root: true, command: ["echo", "$SSH_AUTH_SOCK"])
        #expect(
            sshSockValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/var/host-services/ssh-auth.sock",
            "expected SSH_AUTH_SOCK to point to guest socket path"
        )

        let socketCheck = try doMachineRun(
            name: name,
            root: true,
            command: ["[ -S /var/host-services/ssh-auth.sock ]", "&&", "echo", "exists", "||", "echo", "missing"]
        )
        #expect(
            socketCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "exists",
            "expected forwarded SSH socket to exist in container machine"
        )
    }

    // MARK: - Set tests

    @Test func testSetCpus() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, error, status) = try runMachine(arguments: ["set", "--name", name, "cpus=4"])
        #expect(status == 0, "set cpus should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.cpus == 4, "should have cpus=4")
    }

    @Test func testSetMemory() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, error, status) = try runMachine(arguments: ["set", "--name", name, "memory=8G"])
        #expect(status == 0, "set memory should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.memory == UInt64(8 * 1024 * 1024 * 1024), "should have 8G memory")
    }

    @Test func testSetMultiple() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, error, status) = try runMachine(arguments: ["set", "--name", name, "cpus=2", "memory=4G"])
        #expect(status == 0, "set multiple should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.cpus == 2, "should have cpus=2")
        #expect(snapshot.memory == UInt64(4 * 1024 * 1024 * 1024), "should have 4G memory")
    }

    @Test func testSetInvalidKey() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, _, status) = try runMachine(arguments: ["set", "--name", name, "bogus=value"])
        #expect(status != 0, "set with unknown key should fail")
    }

    @Test func testSetRunningWarning() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, _, error, status) = try runMachine(arguments: ["set", "--name", name, "cpus=2"])
        #expect(status == 0, "set on running VM should succeed")
        #expect(error.contains("will take effect"), "should warn about restart needed")
    }

    // MARK: - Create with config flags

    @Test func testCreateWithCpus() throws {
        let name = getTestName()
        cleanupMachine(name)
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, "--cpus", "2", machineImage])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create with --cpus should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.cpus == 2, "should have cpus=2")
    }

    @Test func testGuestCpuCountMatchesRequested() throws {
        let name = getTestName()
        cleanupMachine(name)
        let cpus = 2
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, "--cpus", "\(cpus)", machineImage])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create with --cpus should succeed: \(error)")

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(name: name, root: true, command: ["nproc"])
        let guestCpus = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(guestCpus == "\(cpus)", "guest should see exactly \(cpus) CPUs, got \(guestCpus)")
    }

    @Test func testCreateWithMemory() throws {
        let name = getTestName()
        cleanupMachine(name)
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, "--memory", "2G", machineImage])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create with --memory should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.memory == UInt64(2 * 1024 * 1024 * 1024), "should have 2G memory")
    }

    @Test func testCreateWithHomeMount() throws {
        let name = getTestName()
        cleanupMachine(name)
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, "--home-mount", "none", machineImage])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create with --home-mount should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.homeMount == "none", "should have homeMount=none")
    }

    /// Verifies that `container machine create` boots the machine by default.
    /// The `--no-boot` path is covered by `testInspectStoppedMachine` via the
    /// `doMachineCreate` helper, which passes `--no-boot`.
    @Test func testCreateAutoBoots() throws {
        let name = getTestName()
        cleanupMachine(name)
        let (_, _, error, status) = try runMachine(arguments: ["create", "--name", name, machineImage])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create without --no-boot should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.status == "running", "default create should leave machine running")
        #expect(snapshot.startedDate != nil, "auto-booted machine should have startedDate")
    }

    @Test func testAmd64PlatformSupported() throws {
        let name = getTestName()
        cleanupMachine(name)
        let (_, _, error, status) = try runMachine(arguments: ["create", "--no-boot", "--name", name, "--platform", "linux/amd64", "alpine:3.22"])
        defer { cleanupMachine(name) }
        #expect(status == 0, "create with --platform linux/amd64 should succeed: \(error)")

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let output = try doMachineRun(name: name, root: true, command: ["uname", "-m"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64",
            "amd64 machine should report x86_64 architecture"
        )
    }

    @Test func testSetHomeMount() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, error, status) = try runMachine(arguments: ["set", "--name", name, "home-mount=ro"])
        #expect(status == 0, "set home-mount should succeed: \(error)")

        let snapshot = try doMachineInspect(name: name)
        #expect(snapshot.homeMount == "ro", "should have homeMount=ro")
    }

    @Test func testSetHomeMountInvalid() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        let (_, _, _, status) = try runMachine(arguments: ["set", "--name", name, "home-mount=badvalue"])
        #expect(status != 0, "set with invalid home-mount value should fail")
    }

    // MARK: - Logs tests

    @Test func testLogs() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        _ = try doMachineStop(name: name)

        let (_, bootOutput, _, bootStatus) = try runMachine(arguments: ["logs", "--boot", name])
        #expect(bootStatus == 0, "logs --boot should succeed for stopped container machine")
        #expect(
            !bootOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "boot log should have content after VM boot"
        )

        let (_, _, _, stdioStatus) = try runMachine(arguments: ["logs", name])
        #expect(stdioStatus == 0, "logs should succeed for stopped container machine")
    }

    @Test func testLogsWhileRunning() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let (_, bootOutput, _, bootStatus) = try runMachine(arguments: ["logs", "--boot", name])
        #expect(bootStatus == 0, "logs --boot should succeed while container machine is running")
        #expect(
            !bootOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "boot log should have content while running"
        )

        let (_, _, _, stdioStatus) = try runMachine(arguments: ["logs", name])
        #expect(stdioStatus == 0, "logs should succeed while container machine is running")
    }

    @Test func testLogsNonExistentMachine() throws {
        let name = "nonexistent-machine-\(UUID().uuidString.lowercased())"

        let (_, _, error, status) = try runMachine(arguments: ["logs", name])
        #expect(status != 0, "logs should fail for non-existent machine")
        #expect(error.contains("not found"), "error should mention 'not found'")
    }

    @Test func testMachineNotInContainerList() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let inspect = try doMachineInspect(name: name)
        let containerId = try #require(inspect.containerId, "machine should have an underlying container ID")

        let (_, runningOutput, _, runningStatus) = try run(arguments: ["ls", "-q"])
        #expect(runningStatus == 0, "container ls failed")
        #expect(!runningOutput.contains(containerId), "machine container should not appear in 'container ls'")

        let (_, allOutput, _, allStatus) = try run(arguments: ["ls", "-a", "-q"])
        #expect(allStatus == 0, "container ls -a failed")
        #expect(!allOutput.contains(containerId), "machine container should not appear in 'container ls -a'")
    }

    @Test func testMachineNotDeletedByRmAll() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let inspect = try doMachineInspect(name: name)
        let containerId = try #require(inspect.containerId, "running machine should have an underlying container ID")

        let (_, _, deleteError, deleteStatus) = try run(arguments: ["delete", "--all"])
        #expect(deleteStatus == 0, "container delete --all failed: \(deleteError)")

        let containerInspect = try inspectContainer(containerId)
        #expect(containerInspect.status.state == "running", "machine container should still be running after 'container delete --all'")
    }

    @Test func testMachineNotKilledByKillAll() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let inspect = try doMachineInspect(name: name)
        let containerId = try #require(inspect.containerId, "running machine should have an underlying container ID")

        let (_, _, killError, killStatus) = try run(arguments: ["kill", "--all"])
        #expect(killStatus == 0, "container kill --all failed: \(killError)")

        let containerInspect = try inspectContainer(containerId)
        #expect(containerInspect.status.state == "running", "machine container should still be running after 'container kill --all'")
    }

    @Test func testMachineNotStoppedByStopAll() throws {
        let name = getTestName()
        try doMachineCreate(name: name)
        defer { cleanupMachine(name) }

        _ = try doMachineBoot(name: name)
        try waitForMachineStatus(name, status: "running")

        let inspect = try doMachineInspect(name: name)
        let containerId = try #require(inspect.containerId, "running machine should have an underlying container ID")

        let (_, _, stopError, stopStatus) = try run(arguments: ["stop", "--all"])
        #expect(stopStatus == 0, "container stop --all failed: \(stopError)")

        let containerInspect = try inspectContainer(containerId)
        #expect(containerInspect.status.state == "running", "machine container should still be running after 'container stop --all'")
    }
}

struct MachineListItem: Codable {
    let id: String
    let status: String
    let `default`: Bool
    let ipAddress: String?
    let cpus: Int
    let memory: UInt64
    let diskSize: UInt64?
    let createdDate: Date?
}

struct MachineInspectOutput: Codable {
    let id: String
    let image: ImageDescription
    let platform: Platform
    let status: String
    let startedDate: Date?
    let createdDate: Date?
    let containerId: String?
    let cpus: Int
    let memory: UInt64
    let homeMount: String?
    let diskSize: UInt64?
    let ipAddress: String?

    struct ImageDescription: Codable {
        let reference: String
    }

    struct Platform: Codable {
        let os: String
        let architecture: String
    }
}
