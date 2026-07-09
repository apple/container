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

@Suite
struct TestCLIRegistry {
    @Test func testListDefaultFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["registry", "list"])
            #expect(result.status == 0, "registry list should succeed, stderr: \(result.error)")

            let requiredHeaders = ["HOSTNAME", "USERNAME", "MODIFIED", "CREATED"]
            #expect(
                requiredHeaders.allSatisfy { result.output.contains($0) },
                "output should contain all required headers"
            )
        }
    }

    @Test func testListJSONFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["registry", "list", "--format", "json"])
            #expect(
                result.status == 0,
                "registry list --format json should succeed, stderr: \(result.error)")

            let json = try JSONSerialization.jsonObject(with: result.outputData, options: [])
            #expect(json is [Any], "JSON output should be an array")
        }
    }

    @Test func testListQuietMode() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["registry", "list", "-q"])
            #expect(result.status == 0, "registry list -q should succeed, stderr: \(result.error)")
            #expect(!result.output.contains("HOSTNAME"), "quiet mode should not contain headers")
            #expect(!result.output.contains("USERNAME"), "quiet mode should not contain headers")
        }
    }
}
