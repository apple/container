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

/// Integration tests for container machine runtime commands: stop, inspect, run, set.
/// Serialized because VM operations share system resources (memory, CPU) and concurrent
/// VMs could interfere with each other or exhaust available resources.
@Suite(.serialized)
struct TestCLIMachineRuntimeSerial {
    private let machineImage = "ghcr.io/linuxcontainers/alpine:3.20"

    // MARK: - Stop tests

    @Test func testStopRunningMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let before = try f.doMachineInspect(name: name)
            #expect(before.startedDate != nil, "running machine should have startedDate")

            let output = try f.doMachineStop(name: name)
            #expect(output == name, "stop should output the machine name")

            let after = try f.doMachineInspect(name: name)
            #expect(after.status == "stopped")
            #expect(after.startedDate == nil, "stopped machine should not have startedDate")
        }
    }

    @Test func testStopIdempotent() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let output = try f.doMachineStop(name: name)
            #expect(output == name, "stop on already-stopped machine should succeed")

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "stopped")
        }
    }

    @Test func testStopNonExistentMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "nonexistent-\(f.testID)"
            let result = try f.runMachine(["stop", name])
            #expect(result.status != 0)
            #expect(result.error.contains("not found"))
        }
    }

    // MARK: - Inspect tests

    @Test func testInspectStoppedMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "stopped")
            #expect(snapshot.startedDate == nil)
            #expect(snapshot.id == name)
            #expect(snapshot.image.reference.contains("alpine"))
            #expect(snapshot.createdDate != nil)
            #expect(snapshot.ipAddress == nil)
            #expect(snapshot.cpus > 0)
            #expect(snapshot.memory > 0)
        }
    }

    @Test func testInspectRunningMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "running")
            #expect(snapshot.startedDate != nil)
            #expect(snapshot.id == name)
            #expect(snapshot.platform.os == "linux")
            #expect(snapshot.ipAddress != nil)
        }
    }

    @Test func testInspectNonExistentMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "nonexistent-\(f.testID)"
            let result = try f.runMachine(["inspect", name])
            #expect(result.status != 0)
            #expect(result.error.contains("not found"))
        }
    }

    // MARK: - Run tests

    @Test func testRunSimpleCommand() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let output = try f.doMachineRun(name: name, root: true, command: ["echo", "hello"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        }
    }

    @Test func testRunAutoBoots() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let before = try f.doMachineInspect(name: name)
            #expect(before.status == "stopped")

            let output = try f.doMachineRun(name: name, root: true, command: ["echo", "autoboot"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "autoboot")

            let after = try f.doMachineInspect(name: name)
            #expect(after.status == "running")
        }
    }

    @Test func testRunAsRoot() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let uid = try f.doMachineRun(name: name, root: true, command: ["id", "-u"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(uid == "0", "running with --root should execute as uid 0")
        }
    }

    @Test func testRunAsHostUser() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let hostUid = getuid()
            let uid = try f.doMachineRun(name: name, command: ["id", "-u"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(uid == "\(hostUid)", "default run should use host user's UID")
        }
    }

    @Test func testRunWithEnvironment() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let output = try f.doMachineRun(
                name: name, root: true, env: ["MY_VAR=hello_world"],
                command: ["echo", "$MY_VAR"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello_world")
        }
    }

    @Test func testRunWithCwd() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let output = try f.doMachineRun(name: name, root: true, cwd: "/tmp", command: ["pwd"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp")
        }
    }

    @Test func testRunNonExistentMachine() async throws {
        try await ContainerFixture.with { f in
            let name = "nonexistent-\(f.testID)"
            let result = try f.runMachine(["run", "-n", name, "echo", "test"])
            #expect(result.status != 0)
            #expect(result.error.contains("not found"))
        }
    }

    @Test func testRunDefaultHostsEntries() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let ip = try #require(inspect.ipAddress, "running machine should have an IP address")

            let output = try f.doMachineRun(name: name, root: true, command: ["cat", "/etc/hosts"])
            let lines = output.split(separator: "\n")
            let expectedEntries = [("127.0.0.1", "localhost"), (ip, name)]
            for (i, line) in lines.enumerated() {
                guard i < expectedEntries.count else { break }
                let words = line.split(separator: " ").map { String($0) }
                #expect(words.count >= 2)
                #expect(expectedEntries[i].0 == words[0])
                #expect(expectedEntries[i].1 == words[1])
            }
        }
    }

    @Test func testRunCommandInShell() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let output = try f.doMachineRun(name: name, root: true, command: ["echo", "$0"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "/bin/sh", "alpine shell should expand $0 to /bin/sh")
        }
    }

    @Test func testRunCommandExitCode() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["run", "-n", name, "--root", "exit", "42"])
            #expect(result.status == 42, "exit code should propagate from command")
        }
    }

    @Test func testRunMultipleEnvVars() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine([
                "run", "-n", name, "--root",
                "-e", "VAR1=one", "-e", "VAR2=two", "-e", "VAR3=three",
                "echo", "$VAR1-$VAR2-$VAR3",
            ])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "one-two-three")
        }
    }

    @Test func testRunWithUid() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["run", "-n", name, "--uid", "1000", "id", "-u"])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")
        }
    }

    @Test func testRunWithGid() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["run", "-n", name, "--root", "--gid", "1000", "id", "-G"])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0 1000")
        }
    }

    @Test func testRunWithUserFlag() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine([
                "run", "-n", name, "--user", "1000:1000",
                "echo", "$(id -u):$(id -g)",
            ])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1000:1000")
        }
    }

    @Test func testRunWithEnvFile() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let envFile = f.testDir.appending("test.env")
            try "TEST_VAR=from_file\n".write(toFile: envFile.string, atomically: true, encoding: .utf8)

            let result = try f.runMachine([
                "run", "-n", name, "--root", "--env-file", envFile.string, "echo", "$TEST_VAR",
            ])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "from_file")
        }
    }

    // MARK: - List tests

    @Test func testListRunningMachines() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["ls"]).check()
            #expect(result.output.contains(name))
        }
    }

    @Test func testListAllMachines() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let result = try f.runMachine(["ls"]).check()
            #expect(result.output.contains(name), "stopped machine should appear in list")
        }
    }

    @Test func testListQuietMode() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["ls", "-q"]).check()
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name)
        }
    }

    @Test func testListJsonFormat() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["ls", "--format", "json"]).check()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([MachineListItem].self, from: result.outputData)
            let item = items.first { $0.id == name }
            try #require(item != nil)
            #expect(item?.status == "running")
            #expect(item?.ipAddress != nil)
            #expect(item?.cpus ?? 0 > 0)
            #expect(item?.memory ?? 0 > 0)
            #expect(item?.createdDate != nil)
        }
    }

    // MARK: - set-default tests

    @Test func testSetDefault() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let result = try f.runMachine(["set-default", name]).check()
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name)

            let list = try f.runMachine(["ls"]).check()
            #expect(list.output.contains("*"), "machine should be marked as default in list")
        }
    }

    @Test func testSetDefaultNonExistent() async throws {
        try await ContainerFixture.with { f in
            let result = try f.runMachine(["set-default", "nonexistent-\(f.testID)"])
            #expect(result.status != 0)
            #expect(result.error.contains("not found"))
        }
    }

    @Test func testSetDefaultSwitching() async throws {
        try await ContainerFixture.with { f in
            let name1 = "\(f.testID)-m1"
            let name2 = "\(f.testID)-m2"
            f.addCleanup {
                f.cleanupMachine(name1)
                f.cleanupMachine(name2)
            }
            try f.doMachineCreate(name: name1, image: machineImage)
            try f.doMachineCreate(name: name2, image: machineImage)

            try f.runMachine(["set-default", name1]).check()
            let result = try f.runMachine(["set-default", name2]).check()
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name2)

            let snapshot = try f.doMachineInspect()
            #expect(snapshot.id == name2, "inspect without ID should use the new default")
        }
    }

    @Test func testInspectUsesDefault() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.runMachine(["set-default", name]).check()

            let snapshot = try f.doMachineInspect()
            #expect(snapshot.id == name)
        }
    }

    @Test func testRunUsesDefault() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.runMachine(["set-default", name]).check()
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["run", "--root", "echo", "default-test"])
            #expect(result.status == 0)
            #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "default-test")
        }
    }

    // MARK: - User / home tests

    @Test func testFirstBootCreatesSudoersEntry() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let username = NSUserName()
            let output = try f.doMachineRun(
                name: name, root: true,
                command: ["cat", "/etc/sudoers.d/\(username)"]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "\(username) ALL=(ALL) NOPASSWD:ALL")
        }
    }

    @Test func testUserSetupIdempotent() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let uid1 = try f.doMachineRun(name: name, command: ["id", "-u"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let uid2 = try f.doMachineRun(name: name, command: ["id", "-u"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(uid1 == uid2)
            #expect(uid1 == "\(getuid())")
        }
    }

    @Test func testHostUserHasCorrectHome() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let home = try f.doMachineRun(name: name, command: ["echo", "$HOME"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(home == "/home/\(NSUserName())")
        }
    }

    // MARK: - set tests

    @Test func testSetCpus() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            try f.runMachine(["set", "--name", name, "cpus=4"]).check()
            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.cpus == 4)
        }
    }

    @Test func testSetMemory() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            try f.runMachine(["set", "--name", name, "memory=8G"]).check()
            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.memory == UInt64(8 * 1024 * 1024 * 1024))
        }
    }

    @Test func testSetMultiple() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            try f.runMachine(["set", "--name", name, "cpus=2", "memory=4G"]).check()
            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.cpus == 2)
            #expect(snapshot.memory == UInt64(4 * 1024 * 1024 * 1024))
        }
    }

    @Test func testSetInvalidKey() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let result = try f.runMachine(["set", "--name", name, "bogus=value"])
            #expect(result.status != 0)
        }
    }

    @Test func testSetRunningWarning() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let result = try f.runMachine(["set", "--name", name, "cpus=2"])
            #expect(result.status == 0)
            #expect(result.error.contains("will take effect"))
        }
    }

    @Test func testSetHomeMount() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            try f.runMachine(["set", "--name", name, "home-mount=ro"]).check()
            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.homeMount == "ro")
        }
    }

    @Test func testSetHomeMountInvalid() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            let result = try f.runMachine(["set", "--name", name, "home-mount=badvalue"])
            #expect(result.status != 0)
        }
    }

    // MARK: - Create config flag tests

    @Test func testCreateWithCpus() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage, extraArgs: ["--cpus", "2"])

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.cpus == 2)
        }
    }

    @Test func testGuestCpuCountMatchesRequested() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage, extraArgs: ["--cpus", "2"])
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let guestCpus = try f.doMachineRun(name: name, root: true, command: ["nproc"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(guestCpus == "2")
        }
    }

    @Test func testCreateWithMemory() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage, extraArgs: ["--memory", "2G"])

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.memory == UInt64(2 * 1024 * 1024 * 1024))
        }
    }

    @Test func testCreateWithHomeMount() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage, extraArgs: ["--home-mount", "none"])

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.homeMount == "none")
        }
    }

    @Test func testCreateAutoBoots() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            // Omit --no-boot so the machine boots automatically.
            try f.runMachine(["create", "--name", name, machineImage]).check()

            let snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "running")
            #expect(snapshot.startedDate != nil)
        }
    }

    @Test func testAmd64PlatformSupported() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(
                name: name, image: "alpine:3.22",
                extraArgs: ["--platform", "linux/amd64"])
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let arch = try f.doMachineRun(name: name, root: true, command: ["uname", "-m"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(arch == "x86_64")
        }
    }

    // MARK: - Logs tests

    @Test func testLogs() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")
            try f.doMachineStop(name: name)

            let boot = try f.runMachine(["logs", "--boot", name]).check()
            #expect(!boot.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let stdio = try f.runMachine(["logs", name])
            #expect(stdio.status == 0)
        }
    }

    @Test func testLogsWhileRunning() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let boot = try f.runMachine(["logs", "--boot", name]).check()
            #expect(!boot.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let stdio = try f.runMachine(["logs", name])
            #expect(stdio.status == 0)
        }
    }

    @Test func testLogsNonExistentMachine() async throws {
        try await ContainerFixture.with { f in
            let result = try f.runMachine(["logs", "nonexistent-\(f.testID)"])
            #expect(result.status != 0)
            #expect(result.error.contains("not found"))
        }
    }

    // MARK: - Machine isolation from container commands

    @Test func testMachineNotInContainerList() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let containerId = try #require(inspect.containerId)

            let running = try f.run(["ls", "-q"]).check()
            #expect(!running.output.contains(containerId))

            let all = try f.run(["ls", "-a", "-q"]).check()
            #expect(!all.output.contains(containerId))
        }
    }

    @Test func testMachineNotDeletedByRmAll() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let containerId = try #require(inspect.containerId)

            try f.run(["delete", "--all"]).check()

            let containerInspect = try f.inspectContainer(containerId)
            #expect(
                containerInspect.status.state == "running",
                "machine container should survive 'container delete --all'")
        }
    }

    @Test func testMachineNotKilledByKillAll() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let containerId = try #require(inspect.containerId)

            try f.run(["kill", "--all"]).check()

            let containerInspect = try f.inspectContainer(containerId)
            #expect(
                containerInspect.status.state == "running",
                "machine container should survive 'container kill --all'")
        }
    }

    @Test func testMachineNotStoppedByStopAll() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let containerId = try #require(inspect.containerId)

            try f.run(["stop", "--all"]).check()

            let containerInspect = try f.inspectContainer(containerId)
            #expect(
                containerInspect.status.state == "running",
                "machine container should survive 'container stop --all'")
        }
    }

    @Test func testContainerExitState() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")

            let inspect = try f.doMachineInspect(name: name)
            let containerId = try #require(
                inspect.containerId,
                "running machine should have a containerId")

            try f.doStop(containerId)
            try await f.waitForMachineStatus(name, status: "stopped")

            let after = try f.doMachineInspect(name: name)
            #expect(after.status == "stopped")
            #expect(after.containerId == nil)
            #expect(after.startedDate == nil)
        }
    }

    // MARK: - Lifecycle test

    @Test func testFullLifecycle() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)

            var snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "stopped")

            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")
            snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "running")

            let output = try f.doMachineRun(name: name, root: true, command: ["hostname"])
            #expect(!output.isEmpty)

            try f.doMachineStop(name: name)
            snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "stopped")

            try f.doMachineBoot(name: name)
            try await f.waitForMachineStatus(name, status: "running")
            snapshot = try f.doMachineInspect(name: name)
            #expect(snapshot.status == "running")
        }
    }

    // MARK: - SSH forwarding

    @Test func testSSHForwarding() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }

            let socketPath = try f.makeFakeSSHAgentSocket()
            try await Task.sleep(for: .seconds(1))

            try f.doMachineCreate(name: name, image: machineImage)
            try f.runMachine(
                ["run", "--root", "-n", name, "true"],
                env: ["SSH_AUTH_SOCK": socketPath]
            ).check()
            try await f.waitForMachineStatus(name, status: "running")

            let sockValue = try f.doMachineRun(
                name: name, root: true,
                command: ["echo", "$SSH_AUTH_SOCK"]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(sockValue == "/var/host-services/ssh-auth.sock")

            let exists = try f.doMachineRun(
                name: name, root: true,
                command: [
                    "[ -S /var/host-services/ssh-auth.sock ]", "&&", "echo", "exists", "||", "echo", "missing",
                ]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(exists == "exists")
        }
    }
}
