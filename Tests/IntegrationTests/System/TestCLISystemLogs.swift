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

import ContainerTestSupport
import Foundation
import Testing

/// Tests for `container system logs` argument validation.
@Suite
struct TestCLISystemLogs {
    @Test func testLogsRejectsInvalidLastUnit() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "logs", "--last", "1x"])
            #expect(result.status != 0, "Expected non-zero exit for invalid --last unit")
            #expect(result.error.contains("invalid --last value"))
        }
    }

    @Test func testLogsRejectsNonNumericLast() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "logs", "--last", "abc"])
            #expect(result.status != 0, "Expected non-zero exit for non-numeric --last")
            #expect(result.error.contains("invalid --last value"))
        }
    }

    @Test func testLogsRejectsZeroLast() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "logs", "--last", "0m"])
            #expect(result.status != 0, "Expected non-zero exit for zero --last value")
            #expect(result.error.contains("invalid --last value"))
        }
    }
}
