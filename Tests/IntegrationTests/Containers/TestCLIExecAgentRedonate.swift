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

import ContainerPersistence
import ContainerTestSupport
import Foundation
import Testing

@Suite
struct TestCLIExecAgentRedonate {
    /// Spawn an ssh-agent listening at a fresh socket path, returning the path
    /// and the process holding it, so a test can end that agent where it
    /// matters. Any agent still running dies with the fixture.
    private func spawnAgent(_ f: ContainerFixture, _ name: String) async throws -> (socket: String, process: Process) {
        let dir = try f.makeShortSocketDir(name)
        let socket = "\(dir)/agent.sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        // -D keeps the agent in the foreground so the process seen here is
        // the agent itself, not a forked child the fixture cannot reach.
        process.arguments = ["-D", "-a", socket]
        try process.run()
        f.addCleanup { process.terminate() }
        // The socket appears when the agent is ready.
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: socket) {
                return (socket, process)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommandError.executionFailed("ssh-agent socket never appeared at \(socket)")
    }

    /// The container's agent link inside its bundle, resolved on the host.
    private func agentLinkTarget(container: String) throws -> String {
        let bundle =
            PathUtils.BaseConfigPath.appRoot.basePath()
            .appending("containers")
            .appending(container)
        return try FileManager.default.destinationOfSymbolicLink(
            atPath: bundle.appending("ssh-auth.sock.link").string)
    }

    @Test func testAForwardingFollowsTheAgentItsCallerNames() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            f.addCleanup { try? f.doRemoveIfExists(c, force: true, ignoreFailure: true) }

            let agentA = try await spawnAgent(f, "aa")
            let agentB = try await spawnAgent(f, "ab")

            // The runtime takes the CLI process's own agent, so the run
            // command carries it in its environment rather than the
            // container's.
            try f.run(
                ["run", "--name", c, "-d", "--ssh", WarmupImage.alpine320.rawValue, "sleep", "infinity"],
                env: ["SSH_AUTH_SOCK": agentA.socket]
            ).check()
            try await f.waitForContainerRunning(c)
            #expect(try agentLinkTarget(container: c) == agentA.socket, "a boot takes the agent its caller names")

            _ = try f.run(["exec", c, "true"], env: ["SSH_AUTH_SOCK": agentB.socket]).check()
            #expect(
                try agentLinkTarget(container: c) == agentB.socket,
                "an exec takes the agent its own caller names")

            // Naming no agent asks for nothing, so the forwarding stays where
            // the last caller who named one put it. The variable is taken out
            // of the environment rather than left unmentioned, because the
            // suite runs holding an agent of its own and the command would
            // otherwise name that one.
            _ = try f.run(["exec", c, "true"], unsetEnv: ["SSH_AUTH_SOCK"]).check()
            #expect(
                try agentLinkTarget(container: c) == agentB.socket,
                "a caller naming no agent leaves the forwarding as it was")

            try f.doStop(c)
        }
    }
}
