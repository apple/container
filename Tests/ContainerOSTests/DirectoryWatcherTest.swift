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

import ContainerOS
import ContainerizationError
import DNSServer
import Foundation
import Testing

struct DirectoryWatcherTest {
    let testUUID = UUID().uuidString

    private var testDir: URL! {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".clitests")
            .appendingPathComponent(testUUID)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return try await body(tempDir)
    }

    private actor CreatedURLs {
        nonisolated(unsafe) public var urls: [URL]

        public init() {
            self.urls = []
        }
    }

    @Test func testWatchingExistingDirectory() async throws {
        try await withTempDir { tempDir in

            let watcher = DirectoryWatcher(directoryURL: tempDir, log: nil)
            let createdURLs = CreatedURLs()
            let name = "newFile"

            await watcher.startWatching { [createdURLs] urls in
                for url in urls where url.lastPathComponent == name {
                    createdURLs.urls.append(url)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            let newFile = tempDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(100))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect new file")
            #expect(createdURLs.urls.first!.lastPathComponent == name)
        }
    }

    @Test func testWatchingNonExistingDirectory() async throws {
        try await withTempDir { tempDir in
            let uuid = UUID().uuidString
            let childDir = tempDir.appendingPathComponent(uuid)

            let watcher = DirectoryWatcher(directoryURL: childDir, log: nil)
            let createdURLs = CreatedURLs()
            let name = "newFile"

            await watcher.startWatching { [createdURLs] urls in
                for url in urls where url.lastPathComponent == name {
                    createdURLs.urls.append(url)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            try await Task.sleep(for: DirectoryWatcher.watchPeriod)
            let newFile = childDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(100))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdURLs.urls.first!.lastPathComponent == name)
        }
    }

    @Test func testWatchingNonExistingParent() async throws {
        try await withTempDir { tempDir in
            let parent = UUID().uuidString
            let child = UUID().uuidString
            let childDir = tempDir.appendingPathComponent(parent).appendingPathComponent(child)

            let watcher = DirectoryWatcher(directoryURL: childDir, log: nil)
            let createdURLs = CreatedURLs()
            let name = "newFile"

            await watcher.startWatching { urls in
                for url in urls where url.lastPathComponent == name {
                    createdURLs.urls.append(url)
                }
            }

            try await Task.sleep(for: .microseconds(100))
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            try await Task.sleep(for: DirectoryWatcher.watchPeriod)

            let newFile = childDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(100))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdURLs.urls.first!.lastPathComponent == name)
        }
    }

    @Test func testWatchingRecreatedDirectory() async throws {
        try await withTempDir { tempDir in
            let dir = tempDir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let watcher = DirectoryWatcher(directoryURL: dir, log: nil)
            let createdURLs = CreatedURLs()
            let beforeDelete = "beforeDelete"
            let afterDelete = "afterDelete"

            await watcher.startWatching { [createdURLs] urls in
                for url in urls
                where url.lastPathComponent == beforeDelete || url.lastPathComponent == afterDelete {
                    createdURLs.urls.append(url)
                }
            }

            try await Task.sleep(for: .milliseconds(100))
            let file1 = dir.appendingPathComponent(beforeDelete)
            FileManager.default.createFile(atPath: file1.path, contents: nil)
            try await Task.sleep(for: .milliseconds(100))

            try FileManager.default.removeItem(at: dir)
            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(1000))

            let file2 = dir.appendingPathComponent(afterDelete)
            FileManager.default.createFile(atPath: file2.path, contents: nil)

            try await Task.sleep(for: .milliseconds(100))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect new file")
            #expect(Set(createdURLs.urls.map { $0.lastPathComponent }) == Set([beforeDelete, afterDelete]))
        }

    }
}
