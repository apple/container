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

/// Tests for `container system status` output formats and content validation.
final class TestCLIStatus: CLITest {
    struct StatusJSON: Codable {
        let status: String
        let appRoot: String
        let installRoot: String
        let logRoot: String?
        let apiServerVersion: String
        let apiServerCommit: String
        let apiServerBuild: String
        let apiServerAppName: String
    }

    @Test func defaultDisplaysTable() throws {
        let (data, out, _, status) = try run(arguments: ["system", "status"])  // default is table

        // If apiserver is not running, skip this test
        guard status == 0 else {
            return
        }

        #expect(!out.isEmpty)

        // Validate table structure
        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 2)  // header + at least one data row

        // Check for header row
        #expect(lines[0].contains("FIELD") && lines[0].contains("VALUE"))

        // Check for key fields in output
        let fullOutput = lines.joined(separator: "\n")
        #expect(fullOutput.contains("status"))
        #expect(fullOutput.contains("running"))
        #expect(fullOutput.contains("app-root"))
        #expect(fullOutput.contains("install-root"))
        #expect(fullOutput.contains("apiserver-version"))
        #expect(fullOutput.contains("apiserver-commit"))

        _ = data  // silence unused warning if assertions short-circuit
    }

    @Test func jsonFormat() throws {
        let (data, out, _, status) = try run(arguments: ["system", "status", "--format", "json"])

        // If apiserver is not running, validate error JSON
        if status != 0 {
            #expect(!out.isEmpty)
            let decoded = try JSONDecoder().decode(StatusJSON.self, from: data)
            #expect(decoded.status == "not running" || decoded.status == "unregistered")
            return
        }

        #expect(!out.isEmpty)

        let decoded = try JSONDecoder().decode(StatusJSON.self, from: data)
        #expect(decoded.status == "running")
        #expect(!decoded.appRoot.isEmpty)
        #expect(!decoded.installRoot.isEmpty)
        #expect(!decoded.apiServerVersion.isEmpty)
        #expect(!decoded.apiServerCommit.isEmpty)
        #expect(!decoded.apiServerBuild.isEmpty)
        #expect(!decoded.apiServerAppName.isEmpty)
    }

    @Test func explicitTableFormat() throws {
        let (_, out, _, status) = try run(arguments: ["system", "status", "--format", "table"])

        // If apiserver is not running, skip validation
        guard status == 0 else {
            return
        }

        #expect(!out.isEmpty)

        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 2)
        #expect(lines[0].contains("FIELD") && lines[0].contains("VALUE"))

        let fullOutput = lines.joined(separator: "\n")
        #expect(fullOutput.contains("status"))
        #expect(fullOutput.contains("running"))
    }

    @Test func statusFieldsMatch() throws {
        // Validate that JSON and table outputs contain the same information
        let (jsonData, _, _, jsonStatus) = try run(arguments: ["system", "status", "--format", "json"])
        let (_, tableOut, _, tableStatus) = try run(arguments: ["system", "status", "--format", "table"])

        #expect(jsonStatus == tableStatus)

        // If apiserver is not running, just verify consistency
        guard jsonStatus == 0 else {
            return
        }

        let decoded = try JSONDecoder().decode(StatusJSON.self, from: jsonData)

        // Verify table output contains key values from JSON
        #expect(tableOut.contains(decoded.status))
        #expect(tableOut.contains(decoded.appRoot))
        #expect(tableOut.contains(decoded.installRoot))
        #expect(tableOut.contains(decoded.apiServerVersion))
        #expect(tableOut.contains(decoded.apiServerCommit))
        #expect(tableOut.contains(decoded.apiServerBuild))
        #expect(tableOut.contains(decoded.apiServerAppName))
    }

    @Test func jsonOutputValidStructure() throws {
        let (data, _, _, status) = try run(arguments: ["system", "status", "--format", "json"])

        // Should always produce valid JSON regardless of status
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(StatusJSON.self, from: data)
        }

        let decoded = try JSONDecoder().decode(StatusJSON.self, from: data)

        if status == 0 {
            // When running, all fields should be populated
            #expect(decoded.status == "running")
            #expect(!decoded.appRoot.isEmpty)
            #expect(!decoded.installRoot.isEmpty)
            #expect(!decoded.apiServerVersion.isEmpty)
        } else {
            // When not running, status should indicate the issue
            #expect(decoded.status == "not running" || decoded.status == "unregistered")
        }
    }

    @Test func prefixOption() throws {
        // Test with explicit prefix (should work the same as default)
        let (_, out, _, status) = try run(arguments: ["system", "status", "--prefix", "com.apple.container."])

        guard status == 0 else {
            return
        }

        #expect(!out.isEmpty)
        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 2)
    }
}
