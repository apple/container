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

/// Concurrent lifecycle tests for `container run` / `start` / `exec`.
@Suite
struct TestCLIRunLifecycle {
    @Test func testRunFailureCleanup() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-c"

            // First attempt with an invalid user — must fail.
            let failResult = try f.run([
                "run", "--rm", "--name", name, "-d",
                "--user", f.testID,  // f.testID won't exist in /etc/passwd
                image, "sleep", "infinity",
            ])
            #expect(failResult.status != 0, "expected run to fail with invalid user")

            // Second attempt with the same name and no user — must succeed.
            try await f.withContainer(image: image) { containerName in
                _ = try f.doExec(containerName, cmd: ["date"])
            }
        }
    }

    @Test func testStartIdempotent() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                let result = try f.run(["start", name])
                #expect(result.status == 0, "expected start to succeed on already running container")
                #expect(
                    result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                    "expected output to be container name")
                _ = try f.inspectContainer(name)
            }
        }
    }

    @Test func testStartIdempotentAttachFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                let result = try f.run(["start", "-a", name])
                #expect(
                    result.status != 0,
                    "expected start with attach to fail on already running container")
                #expect(result.error.contains("attach is currently unsupported on already running containers"))
            }
        }
    }

    @Test func testRunInvalidExecutable() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let name = "\(f.testID)-c"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let result = try f.run(["run", "--rm", "--name", name, "-d", image, "foobarbaz"])
            #expect(result.status != 0, "running invalid executable must fail, not hang")
        }
    }

    @Test func testExecInvalidExecutable() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                let result = try f.run(["exec", name, "foobarbaz"])
                #expect(result.status != 0, "executing invalid executable must fail, not hang")
            }
        }
    }

    @Test func testSSHForwarding() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])

            let socketPath = try f.makeFakeSSHAgentSocket()

            // Run container with --ssh; SSH_AUTH_SOCK must be in the CLI process environment.
            let name = "\(f.testID)-c"
            f.addCleanup { try? f.doStop(name) }
            try f.run(
                ["run", "--rm", "--name", name, "-d", "--ssh", image, "sleep", "infinity"],
                env: ["SSH_AUTH_SOCK": socketPath]
            ).check()
            try await f.waitForContainerRunning(name)

            let sshSockValue = try f.doExec(name, cmd: ["sh", "-c", "echo $SSH_AUTH_SOCK"])
            #expect(
                sshSockValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "/var/host-services/ssh-auth.sock",
                "expected SSH_AUTH_SOCK to point to guest socket path")

            let socketCheck = try f.doExec(
                name, cmd: ["sh", "-c", "[ -S /var/host-services/ssh-auth.sock ] && echo exists || echo missing"])
            #expect(
                socketCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "exists",
                "expected forwarded SSH socket to exist in container")

            try f.doStop(name)
        }
    }
}
