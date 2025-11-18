//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// Tests for container search functionality with partial ID matching
@Suite(.serialized)
class TestCLIContainerSearch: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    // MARK: - Container Logs with Partial ID Tests

    @Test func testLogsWithPartialID() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected container logs with partial ID to succeed") {
            try doCreate(name: name)
            try doStart(name: name)
            defer {
                try? doStop(name: name)
                try? doRemove(name: name)
            }

            // Use first 8 characters of the container ID as partial match
            let partialID = String(name.prefix(8))
            let result = try run(arguments: ["logs", partialID])
            #expect(result.status == 0, "expected logs to succeed with partial ID")
        }
    }

    @Test func testLogsWithAmbiguousID() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-1"
        let name2 = "\(baseName)-2"

        #expect(throws: Never.self, "expected ambiguous container logs to fail gracefully") {
            try doCreate(name: name1)
            try doCreate(name: name2)
            defer {
                try? doRemove(name: name1)
                try? doRemove(name: name2)
            }

            // Use a prefix that matches both containers
            let partialID = String(baseName.prefix(min(8, baseName.count)))
            let result = try run(arguments: ["logs", partialID])

            // Should fail with an error about ambiguous match
            #expect(result.status != 0, "expected logs to fail with ambiguous ID")
            #expect(result.error.contains("Ambiguous") || result.error.contains("ambiguous"),
                    "expected error message to mention ambiguity")
        }
    }

    @Test func testLogsWithExactMatch() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected container logs with exact ID to succeed") {
            try doCreate(name: name)
            try doStart(name: name)
            defer {
                try? doStop(name: name)
                try? doRemove(name: name)
            }

            // Use exact container name
            let result = try run(arguments: ["logs", name])
            #expect(result.status == 0, "expected logs to succeed with exact ID")
        }
    }

    // MARK: - Container Start with Partial ID Tests

    @Test func testStartWithPartialID() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected container start with partial ID to succeed") {
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
                try? doRemove(name: name)
            }

            // Use first 8 characters of the container ID as partial match
            let partialID = String(name.prefix(8))
            let result = try run(arguments: ["start", partialID])
            #expect(result.status == 0, "expected start to succeed with partial ID")

            // Verify container is running
            try waitForContainerRunning(name)
        }
    }

    @Test func testStartWithAmbiguousID() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-1"
        let name2 = "\(baseName)-2"

        #expect(throws: Never.self, "expected ambiguous container start to fail gracefully") {
            try doCreate(name: name1)
            try doCreate(name: name2)
            defer {
                try? doRemove(name: name1)
                try? doRemove(name: name2)
            }

            // Use a prefix that matches both containers
            let partialID = String(baseName.prefix(min(8, baseName.count)))
            let result = try run(arguments: ["start", partialID])

            // Should fail with an error about ambiguous match
            #expect(result.status != 0, "expected start to fail with ambiguous ID")
            #expect(result.error.contains("Ambiguous") || result.error.contains("ambiguous"),
                    "expected error message to mention ambiguity")
        }
    }

    // MARK: - Container Exec with Partial ID Tests

    @Test func testExecWithPartialID() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected container exec with partial ID to succeed") {
            try doCreate(name: name)
            try doStart(name: name)
            defer {
                try? doStop(name: name)
                try? doRemove(name: name)
            }

            try waitForContainerRunning(name)

            // Use first 8 characters of the container ID as partial match
            let partialID = String(name.prefix(8))
            let result = try doExec(name: partialID, cmd: ["echo", "test"])
            #expect(result.contains("test"), "expected echo output")
        }
    }

    @Test func testExecWithAmbiguousID() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-1"
        let name2 = "\(baseName)-2"

        #expect(throws: Never.self, "expected ambiguous container exec to fail gracefully") {
            try doCreate(name: name1)
            try doCreate(name: name2)
            try doStart(name: name1)
            try doStart(name: name2)
            defer {
                try? doStop(name: name1)
                try? doStop(name: name2)
                try? doRemove(name: name1)
                try? doRemove(name: name2)
            }

            try waitForContainerRunning(name1)
            try waitForContainerRunning(name2)

            // Use a prefix that matches both containers
            let partialID = String(baseName.prefix(min(8, baseName.count)))

            // Should fail with an error about ambiguous match
            do {
                _ = try doExec(name: partialID, cmd: ["echo", "test"])
                #expect(Bool(false), "expected exec to fail with ambiguous ID")
            } catch {
                let errorMessage = String(describing: error)
                #expect(errorMessage.contains("Ambiguous") || errorMessage.contains("ambiguous"),
                        "expected error message to mention ambiguity")
            }
        }
    }

    // MARK: - Container Delete with Multiple Partial IDs Tests

    @Test func testDeleteWithMultiplePartialIDs() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc123"
        let name2 = "\(baseName)-def456"
        let name3 = "\(baseName)-ghi789"

        #expect(throws: Never.self, "expected container delete with multiple partial IDs to succeed") {
            try doCreate(name: name1)
            try doCreate(name: name2)
            try doCreate(name: name3)

            // Delete using partial IDs for first two containers
            let partial1 = String(name1.suffix(6)) // "abc123"
            let partial2 = String(name2.suffix(6)) // "def456"

            let result = try run(arguments: ["delete", partial1, partial2])
            #expect(result.status == 0, "expected delete to succeed with multiple partial IDs")

            // Verify only name3 remains
            let listResult = try run(arguments: ["list", "--all"])
            #expect(listResult.output.contains(name3), "expected name3 to still exist")
            #expect(!listResult.output.contains(name1), "expected name1 to be deleted")
            #expect(!listResult.output.contains(name2), "expected name2 to be deleted")

            // Cleanup
            try? doRemove(name: name3)
        }
    }

    // MARK: - Container Inspect with Multiple Partial IDs Tests

    @Test func testInspectWithMultiplePartialIDs() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc123"
        let name2 = "\(baseName)-def456"

        #expect(throws: Never.self, "expected container inspect with multiple partial IDs to succeed") {
            try doCreate(name: name1)
            try doCreate(name: name2)
            defer {
                try? doRemove(name: name1)
                try? doRemove(name: name2)
            }

            // Inspect using partial IDs
            let partial1 = String(name1.suffix(6)) // "abc123"
            let partial2 = String(name2.suffix(6)) // "def456"

            let result = try run(arguments: ["inspect", partial1, partial2])
            #expect(result.status == 0, "expected inspect to succeed with multiple partial IDs")

            // Verify both containers are in the output
            #expect(result.output.contains(name1), "expected name1 in inspect output")
            #expect(result.output.contains(name2), "expected name2 in inspect output")
        }
    }
}
