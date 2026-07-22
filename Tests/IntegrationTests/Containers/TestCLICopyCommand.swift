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

@Suite
struct TestCLICopyCommand {

    // MARK: - Basic host/container copy

    @Test func testCopyHostToContainer() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let src = f.testDir.appending("testfile.txt")
                let content = "hello from host"
                try content.write(toFile: src.string, atomically: true, encoding: .utf8)
                try f.run(["copy", src.string, "\(name):/tmp/"]).check()
                let cat = try f.doExec(name, cmd: ["cat", "/tmp/testfile.txt"])
                #expect(cat.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            }
        }
    }

    @Test func testCopyContainerToHost() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "hello from container"
                try f.doExec(name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/containerfile.txt"])
                let dest = f.testDir.appending("containerfile.txt")
                try f.run(["copy", "\(name):/tmp/containerfile.txt", dest.string]).check()
                let hostContent = try String(contentsOfFile: dest.string, encoding: .utf8)
                #expect(hostContent == content)
            }
        }
    }

    @Test func testCopyUsingCpAlias() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let src = f.testDir.appending("aliasfile.txt")
                let content = "testing cp alias"
                try content.write(toFile: src.string, atomically: true, encoding: .utf8)
                try f.run(["cp", src.string, "\(name):/tmp/"]).check()
                let cat = try f.doExec(name, cmd: ["cat", "/tmp/aliasfile.txt"])
                #expect(cat.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            }
        }
    }

    @Test func testCopyLocalToLocalFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["copy", "/tmp/source.txt", "/tmp/dest.txt"])
            #expect(result.status != 0, "expected local-to-local copy to fail")
        }
    }

    @Test func testCopyContainerToContainerFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try f.doRemoveIfExists(name, ignoreFailure: true) }
            let result = try f.run(["copy", "\(name):/tmp/file.txt", "\(name):/tmp/file2.txt"])
            #expect(result.status != 0, "expected container-to-container copy to fail")
        }
    }

    @Test func testCopyToNonRunningContainerFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try f.doRemoveIfExists(name, ignoreFailure: true) }
            let src = f.testDir.appending("norun.txt")
            try "test".write(toFile: src.string, atomically: true, encoding: .utf8)
            let result = try f.run(["copy", src.string, "\(name):/tmp/"])
            #expect(result.status != 0, "expected copy to non-running container to fail")
        }
    }

    @Test func testCopyDirectoryHostToContainer() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("hostdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "file1 content".write(toFile: srcDir.appending("file1.txt").string, atomically: true, encoding: .utf8)
                try "file2 content".write(toFile: srcDir.appending("file2.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", srcDir.string, "\(name):/tmp/"]).check()
                let cat1 = try f.doExec(name, cmd: ["cat", "/tmp/hostdir/file1.txt"])
                #expect(cat1.trimmingCharacters(in: .whitespacesAndNewlines) == "file1 content")
                let cat2 = try f.doExec(name, cmd: ["cat", "/tmp/hostdir/file2.txt"])
                #expect(cat2.trimmingCharacters(in: .whitespacesAndNewlines) == "file2 content")
            }
        }
    }

    @Test func testCopyDirectoryContainerToHost() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/guestdir && echo -n 'aaa' > /tmp/guestdir/a.txt && echo -n 'bbb' > /tmp/guestdir/b.txt"])
                let dest = f.testDir.appending("guestdir")
                try f.run(["copy", "\(name):/tmp/guestdir", dest.string]).check()
                let a = try String(contentsOfFile: dest.appending("a.txt").string, encoding: .utf8)
                #expect(a == "aaa")
                let b = try String(contentsOfFile: dest.appending("b.txt").string, encoding: .utf8)
                #expect(b == "bbb")
            }
        }
    }

    @Test func testCopyNestedDirectoryHostToContainer() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("nested")
                let subDir = srcDir.appending("sub")
                try FileManager.default.createDirectory(atPath: subDir.string, withIntermediateDirectories: true, attributes: nil)
                try "root file".write(toFile: srcDir.appending("root.txt").string, atomically: true, encoding: .utf8)
                try "nested file".write(toFile: subDir.appending("deep.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", srcDir.string, "\(name):/tmp/"]).check()
                let catRoot = try f.doExec(name, cmd: ["cat", "/tmp/nested/root.txt"])
                #expect(catRoot.trimmingCharacters(in: .whitespacesAndNewlines) == "root file")
                let catDeep = try f.doExec(name, cmd: ["cat", "/tmp/nested/sub/deep.txt"])
                #expect(catDeep.trimmingCharacters(in: .whitespacesAndNewlines) == "nested file")
            }
        }
    }

    @Test func testCopyNestedDirectoryContainerToHost() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/nested/sub && echo -n 'root file' > /tmp/nested/root.txt && echo -n 'nested file' > /tmp/nested/sub/deep.txt"])
                let dest = f.testDir.appending("nested")
                try f.run(["copy", "\(name):/tmp/nested", dest.string]).check()
                let root = try String(contentsOfFile: dest.appending("root.txt").string, encoding: .utf8)
                #expect(root == "root file")
                let deep = try String(contentsOfFile: dest.appending("sub").appending("deep.txt").string, encoding: .utf8)
                #expect(deep == "nested file")
            }
        }
    }

    // MARK: - CopyOut S1: no trailing slash

    @Test func testCopyOutFileToExistingFile() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "container content"
                try f.doExec(name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])
                let dest = f.testDir.appending("existing.txt")
                try "old content".write(toFile: dest.string, atomically: true, encoding: .utf8)
                try f.run(["copy", "\(name):/tmp/source.txt", dest.string]).check()
                let result = try String(contentsOfFile: dest.string, encoding: .utf8)
                #expect(result == content)
            }
        }
    }

    @Test func testCopyOutDirectoryToExistingFileFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'x' > /tmp/srcdir/file.txt"])
                let dest = f.testDir.appending("existing.txt")
                try "x".write(toFile: dest.string, atomically: true, encoding: .utf8)
                let result = try f.run(["copy", "\(name):/tmp/srcdir", dest.string])
                #expect(result.status != 0, "expected directory-to-existing-file to fail")
            }
        }
    }

    @Test func testCopyOutFileToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "container content"
                try f.doExec(name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/source.txt", destDir.string]).check()
                let result = try String(contentsOfFile: destDir.appending("source.txt").string, encoding: .utf8)
                #expect(result == content)
            }
        }
    }

    @Test func testCopyOutDirectoryToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/srcdir", destDir.string]).check()
                let result = try String(contentsOfFile: destDir.appending("srcdir").appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    // MARK: - CopyOut S2: trailing slash on dst

    @Test func testCopyOutFileToNonExistingTrailingSlashFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/source.txt"])
                let dest = f.testDir.appending("nonexistent").string + "/"
                let result = try f.run(["copy", "\(name):/tmp/source.txt", dest])
                #expect(result.status != 0, "expected file-to-nonexisting/ to fail")
            }
        }
    }

    @Test func testCopyOutDirectoryToNonExistingTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("newdir")
                try f.run(["copy", "\(name):/tmp/srcdir", destDir.string + "/"]).check()
                var isDir: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: destDir.string, isDirectory: &isDir) && isDir.boolValue)
                let result = try String(contentsOfFile: destDir.appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    @Test func testCopyOutFileToExistingDirectoryTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "container content"
                try f.doExec(name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/source.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/source.txt", destDir.string + "/"]).check()
                let result = try String(contentsOfFile: destDir.appending("source.txt").string, encoding: .utf8)
                #expect(result == content)
            }
        }
    }

    @Test func testCopyOutDirectoryToExistingDirectoryTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/srcdir", destDir.string + "/"]).check()
                let result = try String(contentsOfFile: destDir.appending("srcdir").appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    // MARK: - CopyOut S3: trailing slash on src

    @Test func testCopyOutDirectoryContentsToNonExisting() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir/sub && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("newdir")
                try f.run(["copy", "\(name):/tmp/srcdir/", destDir.string]).check()
                let result = try String(contentsOfFile: destDir.appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
                var isDir: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: destDir.appending("sub").string, isDirectory: &isDir) && isDir.boolValue)
            }
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingFileFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'x' > /tmp/srcdir/file.txt"])
                let dest = f.testDir.appending("existing.txt")
                try "x".write(toFile: dest.string, atomically: true, encoding: .utf8)
                let result = try f.run(["copy", "\(name):/tmp/srcdir/", dest.string])
                #expect(result.status != 0, "expected directory/-to-existing-file to fail")
            }
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/srcdir/", destDir.string]).check()
                let result = try String(contentsOfFile: destDir.appending("srcdir").appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    // MARK: - CopyOut S4: trailing slash on both src and dst

    @Test func testCopyOutDirectoryContentsToNonExistingTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("newdir")
                try f.run(["copy", "\(name):/tmp/srcdir/", destDir.string + "/"]).check()
                let result = try String(contentsOfFile: destDir.appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    @Test func testCopyOutDirectoryContentsToExistingDirectoryTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/srcdir && echo -n 'hello' > /tmp/srcdir/file.txt"])
                let destDir = f.testDir.appending("dstdir")
                try FileManager.default.createDirectory(atPath: destDir.string, withIntermediateDirectories: true, attributes: nil)
                try f.run(["copy", "\(name):/tmp/srcdir/", destDir.string + "/"]).check()
                let result = try String(contentsOfFile: destDir.appending("srcdir").appending("file.txt").string, encoding: .utf8)
                #expect(result == "hello")
            }
        }
    }

    // MARK: - CopyIn S1: no trailing slash

    @Test func testCopyInFileToExistingFile() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "new content"
                let src = f.testDir.appending("source.txt")
                try content.write(toFile: src.string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["sh", "-c", "echo -n 'old content' > /tmp/existing.txt"])
                try f.run(["copy", src.string, "\(name):/tmp/existing.txt"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/existing.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            }
        }
    }

    @Test func testCopyInDirectoryToExistingFileFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "x".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/existing.txt"])
                let result = try f.run(["copy", srcDir.string, "\(name):/tmp/existing.txt"])
                #expect(result.status != 0, "expected directory-to-existing-file to fail")
            }
        }
    }

    @Test func testCopyInFileToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "host content"
                let src = f.testDir.appending("source.txt")
                try content.write(toFile: src.string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/dstdir"])
                try f.run(["copy", src.string, "\(name):/tmp/dstdir"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/dstdir/source.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            }
        }
    }

    @Test func testCopyInDirectoryToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/dstdir"])
                try f.run(["copy", srcDir.string, "\(name):/tmp/dstdir"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    // MARK: - CopyIn S2: trailing slash on dst

    @Test func testCopyInFileToNonExistingTrailingSlashFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let src = f.testDir.appending("source.txt")
                try "x".write(toFile: src.string, atomically: true, encoding: .utf8)
                let result = try f.run(["copy", src.string, "\(name):/tmp/nonexistent/"])
                #expect(result.status != 0, "expected file-to-nonexisting/ to fail")
            }
        }
    }

    @Test func testCopyInDirectoryToNonExistingTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", srcDir.string, "\(name):/tmp/newdir/"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/newdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    // MARK: - CopyIn S3: trailing slash on src

    @Test func testCopyInDirectoryContentsToNonExisting() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                let subDir = srcDir.appending("sub")
                try FileManager.default.createDirectory(atPath: subDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", srcDir.string + "/", "\(name):/tmp/newdir"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/newdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    @Test func testCopyInDirectoryContentsToExistingFileFails() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "x".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["sh", "-c", "echo -n 'x' > /tmp/existing.txt"])
                let result = try f.run(["copy", srcDir.string + "/", "\(name):/tmp/existing.txt"])
                #expect(result.status != 0, "expected directory/-to-existing-file to fail")
            }
        }
    }

    @Test func testCopyInDirectoryContentsToExistingDirectory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/dstdir"])
                try f.run(["copy", srcDir.string + "/", "\(name):/tmp/dstdir"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    // MARK: - CopyIn S4: trailing slash on both src and dst

    @Test func testCopyInDirectoryContentsToNonExistingTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", srcDir.string + "/", "\(name):/tmp/newdir/"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/newdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    @Test func testCopyInDirectoryContentsToExistingDirectoryTrailingSlash() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let srcDir = f.testDir.appending("srcdir")
                try FileManager.default.createDirectory(atPath: srcDir.string, withIntermediateDirectories: true, attributes: nil)
                try "hello".write(toFile: srcDir.appending("file.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/dstdir"])
                try f.run(["copy", srcDir.string + "/", "\(name):/tmp/dstdir/"]).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/dstdir/srcdir/file.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            }
        }
    }

    // MARK: - Relative path resolution

    @Test func testCopyInRelativeSourcePath() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "relative source"
                try content.write(toFile: f.testDir.appending("relfile.txt").string, atomically: true, encoding: .utf8)
                try f.run(["copy", "./relfile.txt", "\(name):/tmp/"], currentDirectory: f.testDir).check()
                let result = try f.doExec(name, cmd: ["cat", "/tmp/relfile.txt"])
                #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == content)
            }
        }
    }

    @Test func testCopyOutRelativeDestinationPath() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            try await f.withContainer(image: image) { name in
                let content = "relative dest"
                try f.doExec(name, cmd: ["sh", "-c", "echo -n '\(content)' > /tmp/relfile.txt"])
                try f.run(["copy", "\(name):/tmp/relfile.txt", "./"], currentDirectory: f.testDir).check()
                let result = try String(contentsOfFile: f.testDir.appending("relfile.txt").string, encoding: .utf8)
                #expect(result == content)
            }
        }
    }
}
