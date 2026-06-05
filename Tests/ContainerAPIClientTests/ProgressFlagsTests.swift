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

@testable import ContainerAPIClient

struct ProgressFlagsTests {

    // MARK: - Default behavior

    @Test
    func testDefaultWithNoFlagOrEnvVar() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .auto)
    }

    // MARK: - Explicit flag

    @Test
    func testExplicitFlagPlain() {
        let flags = Flags.Progress(progress: .plain)
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .plain)
    }

    @Test
    func testExplicitFlagNone() {
        let flags = Flags.Progress(progress: .none)
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .none)
    }

    @Test
    func testExplicitFlagAnsi() {
        let flags = Flags.Progress(progress: .ansi)
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .ansi)
    }

    @Test
    func testExplicitFlagColor() {
        let flags = Flags.Progress(progress: .color)
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .color)
    }

    @Test
    func testExplicitFlagAuto() {
        let flags = Flags.Progress(progress: .auto)
        let result = flags.resolveProgress(environment: [:])
        #expect(result == .auto)
    }

    // MARK: - Environment variable

    @Test
    func testEnvVarPlain() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "plain"])
        #expect(result == .plain)
    }

    @Test
    func testEnvVarNone() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "none"])
        #expect(result == .none)
    }

    @Test
    func testEnvVarAnsi() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "ansi"])
        #expect(result == .ansi)
    }

    @Test
    func testEnvVarColor() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "color"])
        #expect(result == .color)
    }

    @Test
    func testEnvVarAuto() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "auto"])
        #expect(result == .auto)
    }

    // MARK: - Flag takes precedence over environment variable

    @Test
    func testFlagOverridesEnvVar() {
        let flags = Flags.Progress(progress: .ansi)
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "plain"])
        #expect(result == .ansi)
    }

    @Test
    func testFlagNoneOverridesEnvVar() {
        let flags = Flags.Progress(progress: .none)
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "ansi"])
        #expect(result == .none)
    }

    @Test
    func testFlagColorOverridesEnvVar() {
        let flags = Flags.Progress(progress: .color)
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "plain"])
        #expect(result == .color)
    }

    // MARK: - Invalid environment variable

    @Test
    func testInvalidEnvVarFallsBackToDefault() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": "bogus"])
        #expect(result == .auto)
    }

    @Test
    func testEmptyEnvVarFallsBackToDefault() throws {
        let flags = try Flags.Progress.parse([])
        let result = flags.resolveProgress(environment: ["CONTAINER_CLI_PROGRESS": ""])
        #expect(result == .auto)
    }

    // MARK: - Environment variable name

    @Test
    func testEnvironmentVariableName() {
        #expect(Flags.Progress.environmentVariable == "CONTAINER_CLI_PROGRESS")
    }
}
