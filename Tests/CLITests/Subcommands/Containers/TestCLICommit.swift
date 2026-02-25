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

class TestCLICommitCommand: CLITest {
    @Test func testCommitRunningDefaultQuiesce() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-dq-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        let mustBeInImage = "must-be-in-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo && sync"])

        try doCommit(name: name, image: image)
        try waitForContainerRunning(name)
        let status = try getContainerStatus(name)
        #expect(status == "running")

        let committed = "commit-dq-new-\(suffix)"
        try doLongRun(name: committed, image: image, autoRemove: false)
        defer {
            try? doStop(name: committed)
            try? doRemove(name: committed)
        }

        let foo = try doExec(name: committed, cmd: ["cat", "/foo"])
        #expect(foo == mustBeInImage + "\n")
    }

    @Test func testCommitRunningLive() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-live-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        let mustBeInImage = "must-be-in-live-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo && sync"])

        let commitResult = try doCommit(name: name, image: image, live: true)
        #expect(commitResult.error.contains("best-effort live commit"))
        let status = try getContainerStatus(name)
        #expect(status == "running")

        let committed = "commit-live-new-\(suffix)"
        try doLongRun(name: committed, image: image, autoRemove: false)
        defer {
            try? doStop(name: committed)
            try? doRemove(name: committed)
        }

        let foo = try doExec(name: committed, cmd: ["cat", "/foo"])
        #expect(foo == mustBeInImage + "\n")
    }

    @Test func testCommitStopped() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-stop-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        let mustBeInImage = "must-be-in-stopped-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo && sync"])
        try doStop(name: name)

        try doCommit(name: name, image: image)
        let status = try getContainerStatus(name)
        #expect(status == "stopped")

        let committed = "commit-stop-new-\(suffix)"
        try doLongRun(name: committed, image: image, autoRemove: false)
        defer {
            try? doStop(name: committed)
            try? doRemove(name: committed)
        }

        let foo = try doExec(name: committed, cmd: ["cat", "/foo"])
        #expect(foo == mustBeInImage + "\n")
    }

    @Test func testCommitPreservesAutoRemoveContainer() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-rm-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        let mustBeInImage = "must-survive-quiesce-stop"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo && sync"])

        try doCommit(name: name, image: image)
        try waitForContainerRunning(name)

        let status = try getContainerStatus(name)
        #expect(status == "running", "auto-remove container should still be present and running after commit")

        let committed = "commit-rm-new-\(suffix)"
        try doLongRun(name: committed, image: image, autoRemove: false)
        defer {
            try? doStop(name: committed)
            try? doRemove(name: committed)
        }

        let foo = try doExec(name: committed, cmd: ["cat", "/foo"])
        #expect(foo == mustBeInImage + "\n")
    }

    @Test func testCommitPreservesDefaultProcessCommand() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-cmd-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        try doCommit(name: name, image: image)
        try waitForContainerRunning(name)

        let committed = "commit-cmd-new-\(suffix)"
        try doLongRun(name: committed, image: image, containerArgs: [], autoRemove: false)
        defer {
            try? doStop(name: committed)
            try? doRemove(name: committed)
        }

        let status = try getContainerStatus(committed)
        #expect(status == "running")
    }

    @Test func testExportFailsWhenContainerRunning() throws {
        let suffix = String(testUUID.prefix(8)).lowercased()
        let name = "commit-exp-\(suffix)"
        let image = "\(name)-image"
        try? doRemove(name: name, force: true)
        try? doRemoveImages(images: [image])

        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doRemoveImages(images: [image])
        }

        let (_, _, error, status) = try run(arguments: ["export", "--image", image, name])
        #expect(status != 0)
        #expect(error.contains("container is not stopped"))
    }
}
