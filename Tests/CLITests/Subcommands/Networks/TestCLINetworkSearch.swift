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

/// Tests for network search functionality with partial ID matching
@Suite(.serialized)
class TestCLINetworkSearch: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    // MARK: - Network Delete with Partial ID Tests

    @Test func testDeleteNetworkWithPartialID() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected network delete with partial ID to succeed") {
            _ = try run(arguments: ["network", "create", name])
            defer {
                _ = try? run(arguments: ["network", "delete", name])
            }

            // Use first 6 characters as partial match
            let partialID = String(name.prefix(min(6, name.count)))
            let result = try run(arguments: ["network", "delete", partialID])
            #expect(result.status == 0, "expected network delete to succeed with partial ID")

            // Verify network is deleted
            let listResult = try run(arguments: ["network", "list"])
            #expect(!listResult.output.contains(name), "expected network to be deleted")
        }
    }

    @Test func testDeleteNetworkWithAmbiguousID() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-net1"
        let name2 = "\(baseName)-net2"

        #expect(throws: Never.self, "expected ambiguous network delete to fail gracefully") {
            _ = try run(arguments: ["network", "create", name1])
            _ = try run(arguments: ["network", "create", name2])
            defer {
                _ = try? run(arguments: ["network", "delete", name1])
                _ = try? run(arguments: ["network", "delete", name2])
            }

            // Use a prefix that matches both networks
            let partialID = String(baseName.prefix(min(6, baseName.count)))
            let result = try run(arguments: ["network", "delete", partialID])

            // Should fail with an error about ambiguous match or missing network
            #expect(result.status != 0, "expected network delete to fail with ambiguous ID")
        }
    }

    @Test func testDeleteMultipleNetworksWithPartialIDs() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc"
        let name2 = "\(baseName)-def"

        #expect(throws: Never.self, "expected delete multiple networks with partial IDs to succeed") {
            _ = try run(arguments: ["network", "create", name1])
            _ = try run(arguments: ["network", "create", name2])

            // Delete using partial IDs
            let partial1 = String(name1.suffix(3)) // "abc"
            let partial2 = String(name2.suffix(3)) // "def"

            let result = try run(arguments: ["network", "delete", partial1, partial2])
            #expect(result.status == 0, "expected network delete to succeed with multiple partial IDs")

            // Verify both networks are deleted
            let listResult = try run(arguments: ["network", "list"])
            #expect(!listResult.output.contains(name1), "expected name1 to be deleted")
            #expect(!listResult.output.contains(name2), "expected name2 to be deleted")
        }
    }

    // MARK: - Network Inspect with Partial ID Tests

    @Test func testInspectNetworkWithPartialID() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected network inspect with partial ID to succeed") {
            _ = try run(arguments: ["network", "create", name])
            defer {
                _ = try? run(arguments: ["network", "delete", name])
            }

            // Use first 6 characters as partial match
            let partialID = String(name.prefix(min(6, name.count)))
            let result = try run(arguments: ["network", "inspect", partialID])
            #expect(result.status == 0, "expected network inspect to succeed with partial ID")
            #expect(result.output.contains(name), "expected network name in inspect output")
        }
    }

    @Test func testInspectMultipleNetworksWithPartialIDs() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc"
        let name2 = "\(baseName)-def"

        #expect(throws: Never.self, "expected inspect multiple networks with partial IDs to succeed") {
            _ = try run(arguments: ["network", "create", name1])
            _ = try run(arguments: ["network", "create", name2])
            defer {
                _ = try? run(arguments: ["network", "delete", name1])
                _ = try? run(arguments: ["network", "delete", name2])
            }

            // Inspect using partial IDs
            let partial1 = String(name1.suffix(3)) // "abc"
            let partial2 = String(name2.suffix(3)) // "def"

            let result = try run(arguments: ["network", "inspect", partial1, partial2])
            #expect(result.status == 0, "expected network inspect to succeed with multiple partial IDs")

            // Verify both networks are in the output
            #expect(result.output.contains(name1), "expected name1 in inspect output")
            #expect(result.output.contains(name2), "expected name2 in inspect output")
        }
    }
}
