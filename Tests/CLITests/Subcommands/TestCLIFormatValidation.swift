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

/// Verifies that commands which only implement `--format json|table` reject
/// `--format yaml` and `--format toml` instead of silently falling through to
/// table output. As each command grows real yaml/toml support, drop the
/// corresponding cases from these tests.
@Suite(.serialSuites)
final class TestCLIFormatValidation: CLITest {

    private func expectRejected(_ args: [String], format: String) throws {
        let (_, _, error, status) = try run(arguments: args)
        #expect(status != 0, "Expected non-zero exit for --format \(format) on \(args.joined(separator: " "))")
        #expect(error.contains("--format \(format) is not supported"))
    }

    @Test func testImageListRejectsYAML() throws {
        try expectRejected(["image", "list", "--format", "yaml"], format: "yaml")
    }

    @Test func testImageListRejectsTOML() throws {
        try expectRejected(["image", "list", "--format", "toml"], format: "toml")
    }

    @Test func testContainerStatsRejectsYAML() throws {
        try expectRejected(["stats", "--format", "yaml"], format: "yaml")
    }

    @Test func testContainerStatsRejectsTOML() throws {
        try expectRejected(["stats", "--format", "toml"], format: "toml")
    }

    @Test func testSystemDFRejectsYAML() throws {
        try expectRejected(["system", "df", "--format", "yaml"], format: "yaml")
    }

    @Test func testSystemDFRejectsTOML() throws {
        try expectRejected(["system", "df", "--format", "toml"], format: "toml")
    }

    @Test func testBuilderStatusRejectsYAML() throws {
        try expectRejected(["builder", "status", "--format", "yaml"], format: "yaml")
    }

    @Test func testBuilderStatusRejectsTOML() throws {
        try expectRejected(["builder", "status", "--format", "toml"], format: "toml")
    }

    @Test func testVolumeListRejectsYAML() throws {
        try expectRejected(["volume", "list", "--format", "yaml"], format: "yaml")
    }

    @Test func testVolumeListRejectsTOML() throws {
        try expectRejected(["volume", "list", "--format", "toml"], format: "toml")
    }

    @Test func testSystemStatusRejectsYAML() throws {
        try expectRejected(["system", "status", "--format", "yaml"], format: "yaml")
    }

    @Test func testSystemStatusRejectsTOML() throws {
        try expectRejected(["system", "status", "--format", "toml"], format: "toml")
    }
}
