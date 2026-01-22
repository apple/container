//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

/// Tests for `container system version` output formats and build type detection.
final class TestCLIVersion: CLITest {
    struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
    }

    struct VersionJSON: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
        let server: VersionInfo?
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
        let (data, out, err, status) = try run(arguments: ["system", "version"])  // default is table
        #expect(status == 0, "system version should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        // Validate table structure
        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 2)  // header + at least CLI row
        #expect(lines[0].contains("COMPONENT") && lines[0].contains("VERSION") && lines[0].contains("BUILD") && lines[0].contains("COMMIT"))
        #expect(lines[1].hasPrefix("CLI "))

        // Build should reflect the binary we are running (debug/release)
        let expected = try expectedBuildType()
        #expect(lines.joined(separator: "\n").contains(" CLI "))
        #expect(lines.joined(separator: "\n").contains(" \(expected) "))
        _ = data  // silence unused warning if assertions short-circuit
    }

    @Test func jsonFormat() throws {
        let (data, out, err, status) = try run(arguments: ["system", "version", "--format", "json"])
        #expect(status == 0, "system version --format json should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let decoded = try JSONDecoder().decode(VersionJSON.self, from: data)
        #expect(decoded.appName == "container CLI")
        #expect(!decoded.version.isEmpty)
        #expect(!decoded.commit.isEmpty)

        let expected = try expectedBuildType()
        #expect(decoded.buildType == expected)
    }

    @Test func explicitTableFormat() throws {
        let (_, out, err, status) = try run(arguments: ["system", "version", "--format", "table"])
        #expect(status == 0, "system version --format table should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 2)
        #expect(lines[0].contains("COMPONENT") && lines[0].contains("VERSION") && lines[0].contains("BUILD") && lines[0].contains("COMMIT"))
        #expect(lines[1].hasPrefix("CLI "))
    }

    @Test func buildTypeMatchesBinary() throws {
        // Validate build type via JSON to avoid parsing table text loosely
        let (data, _, err, status) = try run(arguments: ["system", "version", "--format", "json"])
        #expect(status == 0, "version --format json should succeed, stderr: \(err)")
        let decoded = try JSONDecoder().decode(VersionJSON.self, from: data)

        let expected = try expectedBuildType()
        #expect(decoded.buildType == expected, "Expected build type \(expected) but got \(decoded.buildType)")
    }
}
