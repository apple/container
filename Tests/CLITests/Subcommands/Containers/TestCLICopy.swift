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

    @Test func testCopyDirectoryHostToContainer() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("hostdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "file1 content".write(to: srcDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
            try "file2 content".write(to: srcDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: [
                "copy",
                srcDir.path,
                "\(name):/tmp/",
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy directory failed: \(error)")
            }

            let cat1 = try doExec(name: name, cmd: ["cat", "/tmp/hostdir/file1.txt"])
            #expect(
                cat1.trimmingCharacters(in: .whitespacesAndNewlines) == "file1 content",
                "expected file1 content, got '\(cat1.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )
            let cat2 = try doExec(name: name, cmd: ["cat", "/tmp/hostdir/file2.txt"])
            #expect(
                cat2.trimmingCharacters(in: .whitespacesAndNewlines) == "file2 content",
                "expected file2 content, got '\(cat2.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy directory from host to container: \(error)")
            return
        }
    }

    @Test func testCopyDirectoryContainerToHost() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/guestdir && echo -n 'aaa' > /tmp/guestdir/a.txt && echo -n 'bbb' > /tmp/guestdir/b.txt"])

            let destPath = testDir.appendingPathComponent("guestdir")
            let (_, _, error, status) = try run(arguments: [
                "copy",
                "\(name):/tmp/guestdir",
                destPath.path,
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy directory failed: \(error)")
            }

            let contentA = try String(contentsOfFile: destPath.appendingPathComponent("a.txt").path, encoding: .utf8)
            #expect(contentA == "aaa", "expected 'aaa', got '\(contentA)'")
            let contentB = try String(contentsOfFile: destPath.appendingPathComponent("b.txt").path, encoding: .utf8)
            #expect(contentB == "bbb", "expected 'bbb', got '\(contentB)'")

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy directory from container to host: \(error)")
            return
        }
    }

    @Test func testCopyNestedDirectoryHostToContainer() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("nested")
            let subDir = srcDir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try "root file".write(to: srcDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
            try "nested file".write(to: subDir.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: [
                "copy",
                srcDir.path,
                "\(name):/tmp/",
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy nested directory failed: \(error)")
            }

            let catRoot = try doExec(name: name, cmd: ["cat", "/tmp/nested/root.txt"])
            #expect(
                catRoot.trimmingCharacters(in: .whitespacesAndNewlines) == "root file",
                "expected 'root file', got '\(catRoot.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )
            let catDeep = try doExec(name: name, cmd: ["cat", "/tmp/nested/sub/deep.txt"])
            #expect(
                catDeep.trimmingCharacters(in: .whitespacesAndNewlines) == "nested file",
                "expected 'nested file', got '\(catDeep.trimmingCharacters(in: .whitespacesAndNewlines))'"
            )

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy nested directory from host to container: \(error)")
            return
        }
    }

    @Test func testCopyNestedDirectoryContainerToHost() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(
                name: name, cmd: ["sh", "-c", "mkdir -p /tmp/nested/sub && echo -n 'root file' > /tmp/nested/root.txt && echo -n 'nested file' > /tmp/nested/sub/deep.txt"])

            let destPath = testDir.appendingPathComponent("nested")
            let (_, _, error, status) = try run(arguments: [
                "copy",
                "\(name):/tmp/nested",
                destPath.path,
            ])
            if status != 0 {
                throw CLIError.executionFailed("copy nested directory failed: \(error)")
            }

            let contentRoot = try String(contentsOfFile: destPath.appendingPathComponent("root.txt").path, encoding: .utf8)
            #expect(contentRoot == "root file", "expected 'root file', got '\(contentRoot)'")
            let contentDeep = try String(contentsOfFile: destPath.appendingPathComponent("sub").appendingPathComponent("deep.txt").path, encoding: .utf8)
            #expect(contentDeep == "nested file", "expected 'nested file', got '\(contentDeep)'")

            try doStop(name: name)
        } catch {
            Issue.record("failed to copy nested directory from container to host: \(error)")
            return
        }
    }

    // MARK: - CopyOut S1: no trailing slash

    @Test func testCopyOutFileToExistingFile() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "container content"
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])

            let destPath = testDir.appendingPathComponent("existing.txt")
            try "old content".write(to: destPath, atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/source.txt", destPath.path])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destPath.path, encoding: .utf8)
            #expect(result == content)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutFileToExistingFile failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryToExistingFileFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'x' > /tmp/srcdir/file.txt"])

            let destPath = testDir.appendingPathComponent("existing.txt")
            try "x".write(to: destPath, atomically: true, encoding: .utf8)

            let (_, _, _, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir", destPath.path])
            #expect(status != 0, "expected directory-to-existing-file to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryToExistingFileFails failed: \(error)")
        }
    }

    @Test func testCopyOutFileToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "container content"
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/source.txt", destDir.path])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("source.txt").path, encoding: .utf8)
            #expect(result == content)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutFileToExistingDirectory failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir", destDir.path])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("srcdir").appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryToExistingDirectory failed: \(error)")
        }
    }

    // MARK: - CopyOut S2: trailing slash on dst

    @Test func testCopyOutFileToNonExistingTrailingSlashFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/source.txt"])

            let destPath = testDir.appendingPathComponent("nonexistent").path + "/"
            let (_, _, _, status) = try run(arguments: ["copy", "\(name):/tmp/source.txt", destPath])
            #expect(status != 0, "expected file-to-nonexisting/ to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutFileToNonExistingTrailingSlashFails failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryToNonExistingTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("newdir")
            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir", destDir.path + "/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: destDir.path, isDirectory: &isDir) && isDir.boolValue)
            let result = try String(contentsOfFile: destDir.appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryToNonExistingTrailingSlash failed: \(error)")
        }
    }

    @Test func testCopyOutFileToExistingDirectoryTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "container content"
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/source.txt", destDir.path + "/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("source.txt").path, encoding: .utf8)
            #expect(result == content)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutFileToExistingDirectoryTrailingSlash failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryToExistingDirectoryTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir", destDir.path + "/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("srcdir").appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryToExistingDirectoryTrailingSlash failed: \(error)")
        }
    }

    // MARK: - CopyOut S3: trailing slash on src

    @Test func testCopyOutDirectoryContentsToNonExisting() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir/sub && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("newdir")
            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir/", destDir.path])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("sub").path, isDirectory: &isDir) && isDir.boolValue)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryContentsToNonExisting failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingFileFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'x' > /tmp/srcdir/file.txt"])

            let destPath = testDir.appendingPathComponent("existing.txt")
            try "x".write(to: destPath, atomically: true, encoding: .utf8)

            let (_, _, _, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir/", destPath.path])
            #expect(status != 0, "expected directory/-to-existing-file to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryContentsToExistingFileFails failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir/", destDir.path])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("srcdir").appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryContentsToExistingDirectory failed: \(error)")
        }
    }

    // MARK: - CopyOut S4: trailing slash on both src and dst

    @Test func testCopyOutDirectoryContentsToNonExistingTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("newdir")
            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir/", destDir.path + "/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryContentsToNonExistingTrailingSlash failed: \(error)")
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingDirectoryTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])

            let destDir = testDir.appendingPathComponent("dstdir")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (_, _, error, status) = try run(arguments: ["copy", "\(name):/tmp/srcdir/", destDir.path + "/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try String(contentsOfFile: destDir.appendingPathComponent("srcdir").appendingPathComponent("file.txt").path, encoding: .utf8)
            #expect(result == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyOutDirectoryContentsToExistingDirectoryTrailingSlash failed: \(error)")
        }
    }

    // MARK: - CopyIn S1: no trailing slash

    @Test func testCopyInFileToExistingFile() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "new content"
            let srcFile = testDir.appendingPathComponent("source.txt")
            try content.write(to: srcFile, atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n 'old content' > /tmp/existing.txt"])

            let (_, _, error, status) = try run(arguments: ["copy", srcFile.path, "\(name):/tmp/existing.txt"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/existing.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInFileToExistingFile failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryToExistingFileFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "x".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/existing.txt"])

            let (_, _, _, status) = try run(arguments: ["copy", srcDir.path, "\(name):/tmp/existing.txt"])
            #expect(status != 0, "expected directory-to-existing-file to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryToExistingFileFails failed: \(error)")
        }
    }

    @Test func testCopyInFileToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let content = "host content"
            let srcFile = testDir.appendingPathComponent("source.txt")
            try content.write(to: srcFile, atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["mkdir", "-p", "/tmp/dstdir"])

            let (_, _, error, status) = try run(arguments: ["copy", srcFile.path, "\(name):/tmp/dstdir"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/dstdir/source.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInFileToExistingDirectory failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["mkdir", "-p", "/tmp/dstdir"])

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path, "\(name):/tmp/dstdir"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryToExistingDirectory failed: \(error)")
        }
    }

    // MARK: - CopyIn S2: trailing slash on dst

    @Test func testCopyInFileToNonExistingTrailingSlashFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcFile = testDir.appendingPathComponent("source.txt")
            try "x".write(to: srcFile, atomically: true, encoding: .utf8)

            let (_, _, _, status) = try run(arguments: ["copy", srcFile.path, "\(name):/tmp/nonexistent/"])
            #expect(status != 0, "expected file-to-nonexisting/ to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInFileToNonExistingTrailingSlashFails failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryToNonExistingTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path, "\(name):/tmp/newdir/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/newdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryToNonExistingTrailingSlash failed: \(error)")
        }
    }

    // MARK: - CopyIn S3: trailing slash on src

    @Test func testCopyInDirectoryContentsToNonExisting() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            let subDir = srcDir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path + "/", "\(name):/tmp/newdir"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/newdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryContentsToNonExisting failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryContentsToExistingFileFails() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "x".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/existing.txt"])

            let (_, _, _, status) = try run(arguments: ["copy", srcDir.path + "/", "\(name):/tmp/existing.txt"])
            #expect(status != 0, "expected directory/-to-existing-file to fail")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryContentsToExistingFileFails failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryContentsToExistingDirectory() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["mkdir", "-p", "/tmp/dstdir"])

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path + "/", "\(name):/tmp/dstdir"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryContentsToExistingDirectory failed: \(error)")
        }
    }

    // MARK: - CopyIn S4: trailing slash on both src and dst

    @Test func testCopyInDirectoryContentsToNonExistingTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path + "/", "\(name):/tmp/newdir/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/newdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryContentsToNonExistingTrailingSlash failed: \(error)")
        }
    }

    @Test func testCopyInDirectoryContentsToExistingDirectoryTrailingSlash() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer { try? doStop(name: name) }
            try doStart(name: name)
            try waitForContainerRunning(name)

            let srcDir = testDir.appendingPathComponent("srcdir")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "hello".write(to: srcDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try doExec(name: name, cmd: ["mkdir", "-p", "/tmp/dstdir"])

            let (_, _, error, status) = try run(arguments: ["copy", srcDir.path + "/", "\(name):/tmp/dstdir/"])
            if status != 0 { throw CLIError.executionFailed("copy failed: \(error)") }

            let result = try doExec(name: name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
            #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            try doStop(name: name)
        } catch {
            Issue.record("testCopyInDirectoryContentsToExistingDirectoryTrailingSlash failed: \(error)")
        }
    }
}
