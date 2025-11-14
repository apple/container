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

class TestCLIStopKillErrors: CLITest {
    @Test func testStopNonExistentContainer() throws {
        let nonExistentName = "nonexistent-container-\(UUID().uuidString)"

        let (_, error, status) = try run(arguments: [
            "stop",
            nonExistentName,
        ])

        #expect(status == 1)
        #expect(error.contains(nonExistentName))
    }

    @Test func testStopMultipleNonExistentContainers() throws {
        let nonExistent1 = "nonexistent-1-\(UUID().uuidString)"
        let nonExistent2 = "nonexistent-2-\(UUID().uuidString)"

        let (_, error, status) = try run(arguments: [
            "stop",
            nonExistent1,
            nonExistent2,
        ])

        #expect(status == 1)
        #expect(error.contains(nonExistent1))
        #expect(error.contains(nonExistent2))
    }

    @Test func testKillNonExistentContainer() throws {
        let nonExistentName = "nonexistent-container-\(UUID().uuidString)"

        let (_, error, status) = try run(arguments: [
            "kill",
            nonExistentName,
        ])

        #expect(status == 1)
        #expect(error.contains(nonExistentName))
    }

    @Test func testKillMultipleNonExistentContainers() throws {
        let nonExistent1 = "nonexistent-1-\(UUID().uuidString)"
        let nonExistent2 = "nonexistent-2-\(UUID().uuidString)"

        let (_, error, status) = try run(arguments: [
            "kill",
            nonExistent1,
            nonExistent2,
        ])

        #expect(status == 1)
        #expect(error.contains(nonExistent1))
        #expect(error.contains(nonExistent2))
    }

    @Test func testStopMixedExistentAndNonExistent() throws {
        let existentName = "test-stop-mixed-\(UUID().uuidString)"
        let nonExistentName = "nonexistent-\(UUID().uuidString)"

        try doCreate(name: existentName)
        try doStart(name: existentName)
        try waitForContainerRunning(existentName)

        defer {
            try? doStop(name: existentName)
            try? doRemove(name: existentName)
        }

        let (output, error, status) = try run(arguments: [
            "stop",
            existentName,
            nonExistentName,
        ])

        #expect(status == 1)
        #expect(output.contains(existentName))
        #expect(error.contains(nonExistentName))
    }

    @Test func testKillMixedExistentAndNonExistent() throws {
        let existentName = "test-kill-mixed-\(UUID().uuidString)"
        let nonExistentName = "nonexistent-\(UUID().uuidString)"

        try doCreate(name: existentName)
        try doStart(name: existentName)
        try waitForContainerRunning(existentName)

        defer {
            try? doStop(name: existentName)
            try? doRemove(name: existentName)
        }

        let (output, error, status) = try run(arguments: [
            "kill",
            existentName,
            nonExistentName,
        ])

        #expect(status == 1)
        #expect(output.contains(existentName))
        #expect(error.contains(nonExistentName))
    }
}
