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

/// Tests for `container version` output formats and build type detection.
final class TestCLIVersion: CLITest {
    struct VersionInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
    }

    private func expectedBuildType() throws -> String {
        let path = try executablePath
        if path.path.contains("/debug/") {
            return "debug"
        } else if path.path.contains("/release/") {
            return "release"
        }
        // Fallback: prefer debug when ambiguous (matches SwiftPM default for tests)
        return "debug"
    }

    @Test func defaultDisplaysTable() throws {
        let (data, out, err, status) = try run(arguments: ["version"]) // default is table
        #expect(status == 0, "version command should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        // Validate basic table structure
        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 3)
        #expect(lines[0].hasPrefix("container CLI version "))
        #expect(lines[1].hasPrefix("Build: "))
        #expect(lines[2].hasPrefix("Commit: "))

        // Build should reflect the binary we are running (debug/release)
        let expected = try expectedBuildType()
        #expect(lines[1] == "Build: \(expected)")
        _ = data // silence unused warning if assertions short-circuit
    }

    @Test func jsonFormat() throws {
        let (data, out, err, status) = try run(arguments: ["version", "--format", "json"])
        #expect(status == 0, "version --format json should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let decoded = try JSONDecoder().decode(VersionInfo.self, from: data)
        #expect(decoded.appName == "container CLI")
        #expect(!decoded.version.isEmpty)
        #expect(!decoded.commit.isEmpty)

        let expected = try expectedBuildType()
        #expect(decoded.build == expected)
    }

    @Test func explicitTableFormat() throws {
        let (_, out, err, status) = try run(arguments: ["version", "--format", "table"])
        #expect(status == 0, "version --format table should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 3)
        #expect(lines[0].hasPrefix("container CLI version "))
        #expect(lines[1].hasPrefix("Build: "))
        #expect(lines[2].hasPrefix("Commit: "))
    }

    @Test func buildTypeMatchesBinary() throws {
        // Validate build type via JSON to avoid parsing table text loosely
        let (data, _, err, status) = try run(arguments: ["version", "--format", "json"])
        #expect(status == 0, "version --format json should succeed, stderr: \(err)")
        let decoded = try JSONDecoder().decode(VersionInfo.self, from: data)

        let expected = try expectedBuildType()
        #expect(decoded.build == expected, "Expected build type \(expected) but got \(decoded.build)")
    }
}