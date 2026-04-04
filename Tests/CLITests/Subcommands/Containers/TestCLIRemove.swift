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

class TestCLIRemove: CLITest {

    @Test func testDeleteStopped() async throws {
        let name = testName
        defer { try? doRemove(name: name, force: true) }

        // Create without --rm so the container persists after being stopped
        let (_, _, createError, createStatus) = try run(arguments: ["create", "--name", name, alpine, "sleep", "infinity"])
        #expect(createStatus == 0, "create failed: \(createError)")

        let (_, _, deleteError, deleteStatus) = try run(arguments: ["delete", name])
        #expect(deleteStatus == 0, "delete failed: \(deleteError)")
        #expect(throws: CLIError.self) { try self.inspectContainer(name) }
    }

    @Test func testDeleteAlias() async throws {
        let name = testName
        defer { try? doRemove(name: name, force: true) }

        let (_, _, createError, createStatus) = try run(arguments: ["create", "--name", name, alpine, "sleep", "infinity"])
        #expect(createStatus == 0, "create failed: \(createError)")

        let (_, _, rmError, rmStatus) = try run(arguments: ["rm", name])
        #expect(rmStatus == 0, "rm failed: \(rmError)")
        #expect(throws: CLIError.self) { try self.inspectContainer(name) }
    }

    @Test func testDeleteForceRunning() async throws {
        let name = testName
        defer { try? doRemove(name: name, force: true) }

        try doLongRun(name: name, autoRemove: false)
        try waitForContainerRunning(name)

        try doRemove(name: name, force: true)
        #expect(throws: CLIError.self) { try self.inspectContainer(name) }
    }

    @Test func testDeleteAllStopped() async throws {
        let name1 = testName + "-1"
        let name2 = testName + "-2"
        defer {
            try? doRemove(name: name1, force: true)
            try? doRemove(name: name2, force: true)
        }

        let (_, _, e1, s1) = try run(arguments: ["create", "--name", name1, alpine, "sleep", "infinity"])
        #expect(s1 == 0, "create \(name1) failed: \(e1)")
        let (_, _, e2, s2) = try run(arguments: ["create", "--name", name2, alpine, "sleep", "infinity"])
        #expect(s2 == 0, "create \(name2) failed: \(e2)")

        let (_, _, deleteError, deleteStatus) = try run(arguments: ["delete", "--all"])
        #expect(deleteStatus == 0, "delete --all failed: \(deleteError)")
        #expect(throws: CLIError.self) { try self.inspectContainer(name1) }
        #expect(throws: CLIError.self) { try self.inspectContainer(name2) }
    }

    @Test func testDeleteAllSkipsRunning() async throws {
        let runningName = testName + "-running"
        let stoppedName = testName + "-stopped"
        defer {
            try? doRemove(name: runningName, force: true)
            try? doRemove(name: stoppedName, force: true)
        }

        try doLongRun(name: runningName, autoRemove: false)
        try waitForContainerRunning(runningName)

        let (_, _, createError, createStatus) = try run(arguments: ["create", "--name", stoppedName, alpine, "sleep", "infinity"])
        #expect(createStatus == 0, "create failed: \(createError)")

        let (_, _, deleteError, deleteStatus) = try run(arguments: ["delete", "--all"])
        #expect(deleteStatus == 0, "delete --all failed: \(deleteError)")

        // Running container should be untouched
        #expect(try getContainerStatus(runningName) == "running")
        // Stopped container should be gone
        #expect(throws: CLIError.self) { try self.inspectContainer(stoppedName) }
    }

    @Test func testDeleteAllForce() async throws {
        let name = testName
        defer { try? doRemove(name: name, force: true) }

        try doLongRun(name: name, autoRemove: false)
        try waitForContainerRunning(name)

        let (_, _, deleteError, deleteStatus) = try run(arguments: ["delete", "--all", "--force"])
        #expect(deleteStatus == 0, "delete --all --force failed: \(deleteError)")
        #expect(throws: CLIError.self) { try self.inspectContainer(name) }
    }

    @Test func testDeleteNoArgs() throws {
        let (_, _, _, status) = try run(arguments: ["delete"])
        #expect(status != 0, "Expected non-zero exit when no args and no --all")
    }

    @Test func testDeleteExplicitIdsConflictWithAll() throws {
        let (_, _, error, status) = try run(arguments: ["delete", "--all", "some-container"])
        #expect(status != 0, "Expected non-zero exit for conflicting flags")
        #expect(error.contains("conflict"))
    }

    @Test func testDeleteDuplicateIds() async throws {
        let name = testName
        defer { try? doRemove(name: name, force: true) }

        let (_, _, createError, createStatus) = try run(arguments: ["create", "--name", name, alpine, "sleep", "infinity"])
        #expect(createStatus == 0, "create failed: \(createError)")

        let (_, output, deleteError, deleteStatus) = try run(arguments: ["delete", name, name])
        #expect(deleteStatus == 0, "delete with duplicate IDs failed: \(deleteError)")
        let lines = output.split(separator: "\n").filter { $0.contains(name) }
        #expect(lines.count == 1, "Expected container to be deleted exactly once, got \(lines.count) lines")
    }
}
