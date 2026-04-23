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

/// Tests that stop, kill, and delete return errors for non-existent containers.
class TestCLINotFound: CLITest {

    @Test func testStopNonExistentContainer() throws {
        let (_, _, _, status) = try run(arguments: ["stop", "does-not-exist"])
        #expect(status != 0, "stop should fail for a non-existent container")
    }

    @Test func testKillNonExistentContainer() throws {
        let (_, _, _, status) = try run(arguments: ["kill", "does-not-exist"])
        #expect(status != 0, "kill should fail for a non-existent container")
    }

    @Test func testDeleteNonExistentContainer() throws {
        let (_, _, _, status) = try run(arguments: ["delete", "does-not-exist"])
        #expect(status != 0, "delete should fail for a non-existent container")
    }
}
