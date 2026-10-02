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
import MachineAPIClient
import Testing

/// Exercises `MachineUserSetup.script` directly against a plain, ephemeral
/// container instead of a full container machine (persistent VM, systemd,
/// virtiofs mounts). The script only depends on a Linux userland with
/// `getent`/passwd semantics, so this is a much cheaper way to cover its
/// collision-handling logic than booting a real machine.
@Suite
struct TestCLIMachineUserSetupScript {
    private let image = WarmupImage.alpine320.rawValue

    /// Runs `MachineUserSetup.script` inside `name` with the given identity, returning
    /// the raw exec result (not `.check()`ed, so failure cases can be asserted on directly).
    private func runSetup(_ f: ContainerFixture, name: String, user: UserSetup) throws -> CommandResult {
        let exports = user.processEnvironment.map { "export \($0)" }.joined(separator: "\n")
        return try f.run(["exec", name, "sh", "-c", exports + "\n" + MachineUserSetup.script])
    }

    @Test func testSetupCreatesAccountAndSudoers() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try await f.waitForContainerRunning(name)

            let user = UserSetup(username: "devuser", uid: 1500, gid: 1600, home: "/home/devuser")
            try runSetup(f, name: name, user: user).check()

            let passwd = try f.doExec(name, cmd: ["grep", "^devuser:", "/etc/passwd"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(passwd == "devuser:x:1500:1600::/home/devuser:/bin/sh")

            let sudoers = try f.doExec(name, cmd: ["cat", "/etc/sudoers.d/devuser"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(sudoers == "devuser ALL=(ALL) NOPASSWD:ALL")
        }
    }

    @Test func testSetupIsIdempotent() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try await f.waitForContainerRunning(name)

            let user = UserSetup(username: "devuser", uid: 1500, gid: 1600, home: "/home/devuser")
            try runSetup(f, name: name, user: user).check()
            try runSetup(f, name: name, user: user).check()

            let count = try f.doExec(name, cmd: ["grep", "-c", "^devuser:", "/etc/passwd"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(count == "1", "re-running setup with the same identity should not duplicate the passwd entry")
        }
    }

    @Test func testSetupFailsOnUidCollision() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try await f.waitForContainerRunning(name)

            // uid 0 always belongs to root already.
            let user = UserSetup(username: "devuser", uid: 0, gid: 0, home: "/home/devuser")
            let result = try runSetup(f, name: name, user: user)
            #expect(result.status != 0)
            #expect(result.error.contains("already uses this uid or username"))
        }
    }

    @Test func testSetupFailsOnUsernameCollision() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try await f.waitForContainerRunning(name)

            // "root" already exists, but at uid 0, not this free uid.
            let user = UserSetup(username: "root", uid: 1500, gid: 1600, home: "/home/root2")
            let result = try runSetup(f, name: name, user: user)
            #expect(result.status != 0)
            #expect(result.error.contains("already uses this uid or username"))

            // Must not have created a duplicate "root" entry.
            let count = try f.doExec(name, cmd: ["grep", "-c", "^root:", "/etc/passwd"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(count == "1")
        }
    }

    @Test func testSetupFailsOnHomeCollision() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await f.doLongRun(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try await f.waitForContainerRunning(name)

            // /etc definitely already exists and has content.
            let user = UserSetup(username: "devuser", uid: 1500, gid: 1600, home: "/etc")
            let result = try runSetup(f, name: name, user: user)
            #expect(result.status != 0)
            #expect(result.error.contains("refusing to use existing path"))

            // Must not have touched /etc's ownership.
            let owner = try f.doExec(name, cmd: ["stat", "-c", "%u:%g", "/etc/passwd"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(owner == "0:0", "pre-existing /etc content must not be chowned")
        }
    }
}
