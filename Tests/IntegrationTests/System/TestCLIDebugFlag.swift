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

import Testing

/// Regression coverage for https://github.com/apple/container/issues/1936:
/// `--debug` was rejected with "Unknown option '--debug'. Did you mean
/// '--debug'?" for many subcommands even though it's listed in their own
/// usage text, because ArgumentParser's `defaultSubcommand` mechanism
/// (used for plugin dispatch) broke flag parsing for unrelated subcommands
/// when combined with a `.captureForPassthrough` argument.
@Suite
struct TestCLIDebugFlag {
    private static func expectDebugAccepted(_ f: ContainerFixture, _ args: [String]) throws {
        let result = try f.run(args)
        #expect(
            !result.error.contains("Unknown option '--debug'"),
            "expected '--debug' to be accepted for \(args.joined(separator: " ")), stderr: \(result.error)"
        )
    }

    @Test func systemStatusAcceptsDebugFlag() async throws {
        try await ContainerFixture.with { f in
            try Self.expectDebugAccepted(f, ["system", "status", "--debug"])
            try Self.expectDebugAccepted(f, ["s", "status", "--debug"])
        }
    }

    @Test func systemVersionAndDfAcceptDebugFlag() async throws {
        try await ContainerFixture.with { f in
            try Self.expectDebugAccepted(f, ["system", "version", "--debug"])
            try Self.expectDebugAccepted(f, ["system", "df", "--debug"])
        }
    }

    @Test func nestedInspectAndDeleteCommandsAcceptDebugFlag() async throws {
        try await ContainerFixture.with { f in
            try Self.expectDebugAccepted(f, ["image", "inspect", "nonexistent", "--debug"])
            try Self.expectDebugAccepted(f, ["volume", "inspect", "nonexistent", "--debug"])
            try Self.expectDebugAccepted(f, ["network", "inspect", "nonexistent", "--debug"])
            try Self.expectDebugAccepted(f, ["builder", "status", "--debug"])
        }
    }
}
