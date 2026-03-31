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

/// Tests that containers can be referenced by a unique prefix of their ID.
class TestCLIPrefixMatch: CLITest {

    @Test func testStopByPrefix() throws {
        let name = "prefix-stop-test"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        try waitForContainerRunning(name)

        let fullId = try getContainerId(name)
        let prefix = String(fullId.prefix(8))

        let (_, _, error, status) = try run(arguments: ["stop", "-s", "SIGKILL", prefix])
        #expect(status == 0, "stop by prefix should succeed, error: \(error)")
    }

    @Test func testInspectByPrefix() throws {
        let name = "prefix-inspect-test"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        try waitForContainerRunning(name)

        let fullId = try getContainerId(name)
        let prefix = String(fullId.prefix(8))

        let (_, output, error, status) = try run(arguments: ["inspect", prefix])
        #expect(status == 0, "inspect by prefix should succeed, error: \(error)")
        #expect(output.contains(fullId), "inspect output should contain the full container ID")
    }

    @Test func testExecByPrefix() throws {
        let name = "prefix-exec-test"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        try waitForContainerRunning(name)

        let fullId = try getContainerId(name)
        let prefix = String(fullId.prefix(8))

        let output = try doExec(name: prefix, cmd: ["echo", "hello"])
        #expect(output.contains("hello"), "exec by prefix should work")
    }

    @Test func testDeleteByPrefix() throws {
        let name = "prefix-delete-test"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }
        try waitForContainerRunning(name)

        let fullId = try getContainerId(name)
        let prefix = String(fullId.prefix(8))

        // Stop first so we can delete.
        try doStop(name: name)

        let (_, _, error, status) = try run(arguments: ["delete", prefix])
        #expect(status == 0, "delete by prefix should succeed, error: \(error)")
    }

    @Test func testAmbiguousPrefixReturnsError() throws {
        // Create two containers whose names share a common prefix.
        let name1 = "ambiguous-pfx-aaa"
        let name2 = "ambiguous-pfx-bbb"
        try doLongRun(name: name1, autoRemove: false)
        try doLongRun(name: name2, autoRemove: false)
        defer {
            try? doStop(name: name1)
            try? doStop(name: name2)
            try? doRemove(name: name1)
            try? doRemove(name: name2)
        }
        try waitForContainerRunning(name1)
        try waitForContainerRunning(name2)

        // "ambiguous-pfx" is a prefix of both container names.
        let (_, _, error, status) = try run(arguments: ["stop", "-s", "SIGKILL", "ambiguous-pfx"])
        #expect(status != 0, "ambiguous prefix should fail")
        #expect(error.contains("multiple containers found"), "error should mention multiple matches, got: \(error)")
    }
}
