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

import ContainerizationExtras
import Foundation
import Testing

class TestCLICopyCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testCopyHostToContainer() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let tempFile = testDir.appendingPathComponent("testfile.txt")
            let content = "hello from host"
            try content.write(to: tempFile, atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: [
                "copy",
                tempFile.path,
                "\(name):/tmp/",
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy failed: \(error)")
            }

            let catOutput = try doExec(name: name, cmd: ["cat", "/tmp/testfile.txt"])
            #expect(
                catOutput.trimmingCharacters(in: .whitespacesAndNewlines) == content,
                "expected file content to be '\(content)', got '\(catOutput.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy file from host to container: \(error)")
            return
        }
    }

    @Test func testCopyContainerToHost() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "hello from container"
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/containerfile.txt"])

            let destPath = testDir.appendingPathComponent("containerfile.txt")
            let (_, _, error, status) = try run(arguments: [
                "copy",
                "\(name):/tmp/containerfile.txt",
                destPath.path,
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy failed: \(error)")
            }

            let hostContent = try String(contentsOfFile: destPath.path, encoding: .utf8)
            #expect(
                hostContent == content,
                "expected file content to be '\(content)', got '\(hostContent)'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy file from container to host: \(error)")
            return
        }
    }

    @Test func testCopyUsingCpAlias() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let tempFile = testDir.appendingPathComponent("aliasfile.txt")
            let content = "testing cp alias"
            try content.write(to: tempFile, atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: [
                "cp",
                tempFile.path,
                "\(name):/tmp/",
            ])
            if status != 0 {
                throw CLIError.executionFailed("cp alias failed: \(error)")
            }

            let catOutput = try doExec(name: name, cmd: ["cat", "/tmp/aliasfile.txt"])
            #expect(
                catOutput.trimmingCharacters(in: .whitespacesAndNewlines) == content,
                "expected file content to be '\(content)', got '\(catOutput.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy file using cp alias: \(error)")
            return
        }
    }

    @Test func testCopyLocalToLocalFails() throws {
        let (_, _, _, status) = try run(arguments: [
            "copy",
            "/tmp/source.txt",
            "/tmp/dest.txt",
        ])
        #expect(status != 0, "expected local-to-local copy to fail")
    }

    @Test func testCopyContainerToContainerFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }

            let (_, _, _, status) = try run(arguments: [
                "copy",
                "\(name):/tmp/file.txt",
                "\(name):/tmp/file2.txt",
            ])
            #expect(status != 0, "expected container-to-container copy to fail")
        } catch {
            Issue.record("failed test for container-to-container copy: \(error)")
            return
        }
    }

    @Test func testCopyToNonRunningContainerFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }

            let tempFile = testDir.appendingPathComponent("norun.txt")
            try "test".write(to: tempFile, atomically: true, encoding: .utf8)

            let (_, _, _, status) = try run(arguments: [
                "copy",
                tempFile.path,
                "\(name):/tmp/",
            ])
            #expect(status != 0, "expected copy to non-running container to fail")
        } catch {
            Issue.record("failed test for copy to non-running container: \(error)")
            return
        }
    }

    @Test func testCopyHostToContainerWithoutTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let tempFile = testDir.appendingPathComponent("noslash.txt")
            let content = "no trailing slash"
            try content.write(to: tempFile, atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: [
                "copy",
                tempFile.path,
                "\(name):/tmp",
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy failed: \(error)")
            }

            let catOutput = try doExec(name: name, cmd: ["cat", "/tmp/noslash.txt"])
            #expect(
                catOutput.trimmingCharacters(in: .whitespacesAndNewlines) == content,
                "expected file content to be '\(content)', got '\(catOutput.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy file without trailing slash: \(error)")
            return
        }
    }
}
