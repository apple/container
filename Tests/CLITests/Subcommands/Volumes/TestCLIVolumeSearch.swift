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

/// Tests for volume search functionality with partial name matching
@Suite(.serialized)
class TestCLIVolumeSearch: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    // MARK: - Volume Delete with Partial Name Tests

    @Test func testDeleteVolumeWithPartialName() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected volume delete with partial name to succeed") {
            _ = try run(arguments: ["volume", "create", name])
            defer {
                _ = try? run(arguments: ["volume", "delete", name])
            }

            // Use first 6 characters as partial match
            let partialName = String(name.prefix(min(6, name.count)))
            let result = try run(arguments: ["volume", "delete", partialName])
            #expect(result.status == 0, "expected volume delete to succeed with partial name")

            // Verify volume is deleted
            let listResult = try run(arguments: ["volume", "list"])
            #expect(!listResult.output.contains(name), "expected volume to be deleted")
        }
    }

    @Test func testDeleteVolumeWithAmbiguousName() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-vol1"
        let name2 = "\(baseName)-vol2"

        #expect(throws: Never.self, "expected ambiguous volume delete to fail gracefully") {
            _ = try run(arguments: ["volume", "create", name1])
            _ = try run(arguments: ["volume", "create", name2])
            defer {
                _ = try? run(arguments: ["volume", "delete", name1])
                _ = try? run(arguments: ["volume", "delete", name2])
            }

            // Use a prefix that matches both volumes
            let partialName = String(baseName.prefix(min(6, baseName.count)))
            let result = try run(arguments: ["volume", "delete", partialName])

            // Should fail with an error about ambiguous match or missing volume
            #expect(result.status != 0, "expected volume delete to fail with ambiguous name")
        }
    }

    @Test func testDeleteMultipleVolumesWithPartialNames() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc"
        let name2 = "\(baseName)-def"

        #expect(throws: Never.self, "expected delete multiple volumes with partial names to succeed") {
            _ = try run(arguments: ["volume", "create", name1])
            _ = try run(arguments: ["volume", "create", name2])

            // Delete using partial names
            let partial1 = String(name1.suffix(3)) // "abc"
            let partial2 = String(name2.suffix(3)) // "def"

            let result = try run(arguments: ["volume", "delete", partial1, partial2])
            #expect(result.status == 0, "expected volume delete to succeed with multiple partial names")

            // Verify both volumes are deleted
            let listResult = try run(arguments: ["volume", "list"])
            #expect(!listResult.output.contains(name1), "expected name1 to be deleted")
            #expect(!listResult.output.contains(name2), "expected name2 to be deleted")
        }
    }

    // MARK: - Volume Inspect with Partial Name Tests

    @Test func testInspectVolumeWithPartialName() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected volume inspect with partial name to succeed") {
            _ = try run(arguments: ["volume", "create", name])
            defer {
                _ = try? run(arguments: ["volume", "delete", name])
            }

            // Use first 6 characters as partial match
            let partialName = String(name.prefix(min(6, name.count)))
            let result = try run(arguments: ["volume", "inspect", partialName])
            #expect(result.status == 0, "expected volume inspect to succeed with partial name")
            #expect(result.output.contains(name), "expected volume name in inspect output")
        }
    }

    @Test func testInspectMultipleVolumesWithPartialNames() throws {
        let baseName = getTestName()
        let name1 = "\(baseName)-abc"
        let name2 = "\(baseName)-def"

        #expect(throws: Never.self, "expected inspect multiple volumes with partial names to succeed") {
            _ = try run(arguments: ["volume", "create", name1])
            _ = try run(arguments: ["volume", "create", name2])
            defer {
                _ = try? run(arguments: ["volume", "delete", name1])
                _ = try? run(arguments: ["volume", "delete", name2])
            }

            // Inspect using partial names
            let partial1 = String(name1.suffix(3)) // "abc"
            let partial2 = String(name2.suffix(3)) // "def"

            let result = try run(arguments: ["volume", "inspect", partial1, partial2])
            #expect(result.status == 0, "expected volume inspect to succeed with multiple partial names")

            // Verify both volumes are in the output
            #expect(result.output.contains(name1), "expected name1 in inspect output")
            #expect(result.output.contains(name2), "expected name2 in inspect output")
        }
    }
}
