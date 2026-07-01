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

@Suite(.serialSuites)
class TestCLIRegistry: CLITest {
    @Test func testListDefaultFormat() throws {
        let (_, output, error, status) = try run(arguments: ["registry", "list"])
        #expect(status == 0, "registry list should succeed, stderr: \(error)")

        let requiredHeaders = ["HOSTNAME", "USERNAME", "MODIFIED", "CREATED"]
        #expect(
            requiredHeaders.allSatisfy { output.contains($0) },
            "output should contain all required headers"
        )
    }

    @Test func testListJSONFormat() throws {
        let (data, _, error, status) = try run(arguments: ["registry", "list", "--format", "json"])
        #expect(status == 0, "registry list --format json should succeed, stderr: \(error)")

        let json = try JSONSerialization.jsonObject(with: data, options: [])
        #expect(json is [Any], "JSON output should be an array")
    }

    @Test func testListQuietMode() throws {
        let (_, output, error, status) = try run(arguments: ["registry", "list", "-q"])
        #expect(status == 0, "registry list -q should succeed, stderr: \(error)")

        #expect(!output.contains("HOSTNAME"), "quiet mode should not contain headers")
        #expect(!output.contains("USERNAME"), "quiet mode should not contain headers")
    }
}
