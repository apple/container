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

import ContainerAPIClient
import ContainerTestSupport
import Foundation
import Testing

/// Cluster nodes are managed by `container cluster` and must be isolated from the
/// container lifecycle commands, both in bulk (`--all`) and when named explicitly.
@Suite(.serialized)
struct TestClusterNodeIsolationSerial {

    private func ids(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Creates a single-node cluster and returns the node's container ID.
    private func createNode(_ f: ContainerFixture) throws -> String {
        let name = "cluster-\(f.testID)"
        try f.createCluster(name: name)
        try #require(try f.getContainerStatus(name) == "running")
        return name
    }

    /// Requires the node to still be in `expected` state, naming the command that changed it otherwise.
    private func requireNode(_ f: ContainerFixture, _ name: String, _ expected: String, after command: [String]) throws {
        let state = try f.inspectContainer(name).status.state
        try #require(state == expected, "cluster node should stay \(expected) after 'container \(command.joined(separator: " "))'")
    }

    /// Expects `container <command> <name>` to report the node as not found and leave it in `state`.
    private func expectNotFound(_ f: ContainerFixture, _ command: [String], node name: String, state: String) throws {
        let result = try f.run(command + [name])
        #expect(result.status != 0)
        #expect(result.error.contains("container with ID \(name) not found"))
        try requireNode(f, name, state, after: command + [name])
    }

    @Test func testClusterNodeHiddenFromListing() async throws {
        try await ContainerFixture.with { f in
            let name = try createNode(f)

            let running = try f.run(["ls", "-q"]).check()
            #expect(!ids(running.output).contains(name))

            let all = try f.run(["ls", "-a", "-q"]).check()
            #expect(!ids(all.output).contains(name))
        }
    }

    @Test func testClusterNodeNotFoundByExplicitId() async throws {
        try await ContainerFixture.with { f in
            let name = try createNode(f)

            for command in [["start"], ["stop"], ["kill"], ["delete", "--force"]] {
                try expectNotFound(f, command, node: name, state: "running")
            }

            // Other containers named alongside the node are still processed.
            let other = "\(f.testID)-other"
            f.addCleanup { try? f.doRemoveIfExists(other, force: true, ignoreFailure: true) }
            try await f.doLongRun(name: other, autoRemove: false, waitUntilRunning: true)
            try expectNotFound(f, ["stop", other], node: name, state: "running")
            #expect(try f.getContainerStatus(other) == "stopped")
        }
    }

    @Test func testClusterNodeSkippedByAllFlag() async throws {
        try await ContainerFixture.with { f in
            let name = try createNode(f)

            for command in [["stop", "--all"], ["kill", "--all"], ["delete", "--all", "--force"]] {
                try f.run(command).check()
                try requireNode(f, name, "running", after: command)
            }
        }
    }

    /// `prune` and `ls -a` act on stopped containers, so check a stopped node too.
    @Test func testStoppedClusterNodeIsolated() async throws {
        try await ContainerFixture.with { f in
            let name = try createNode(f)

            // Stop the node the way the cluster plugin does, since the CLI no longer can.
            try await ContainerClient().stop(id: name)
            try requireNode(f, name, "stopped", after: ["stop", name])

            let all = try f.run(["ls", "-a", "-q"]).check()
            #expect(!ids(all.output).contains(name))

            for command in [["start"], ["delete"]] {
                try expectNotFound(f, command, node: name, state: "stopped")
            }

            for command in [["prune"], ["delete", "--all"]] {
                try f.run(command).check()
                try requireNode(f, name, "stopped", after: command)
            }
        }
    }
}
