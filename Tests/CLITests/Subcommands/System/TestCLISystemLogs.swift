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
final class TestCLISystemLogs: CLITest {

    @Test func testLogsRejectsInvalidLastUnit() throws {
        let (_, _, error, status) = try run(arguments: ["system", "logs", "--last", "1x"])
        #expect(status != 0, "Expected non-zero exit for invalid --last unit")
        #expect(error.contains("invalid --last value"))
    }

    @Test func testLogsRejectsNonNumericLast() throws {
        let (_, _, error, status) = try run(arguments: ["system", "logs", "--last", "abc"])
        #expect(status != 0, "Expected non-zero exit for non-numeric --last")
        #expect(error.contains("invalid --last value"))
    }

    @Test func testLogsRejectsZeroLast() throws {
        let (_, _, error, status) = try run(arguments: ["system", "logs", "--last", "0m"])
        #expect(status != 0, "Expected non-zero exit for zero --last value")
        #expect(error.contains("invalid --last value"))
    }
}
