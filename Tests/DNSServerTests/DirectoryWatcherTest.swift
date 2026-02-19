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

    private class CreatedURLs {
        public var urls: [URL]

        public init() {
            self.urls = []
        }

        public func append(url: URL) {
            urls.append(url)
        }
    }

    @Test func testWatchingExistingDirectory() async throws {
        try await withTempDir { tempDir in

            let watcher = DirectoryWatcher(directoryURL: tempDir, log: nil)
            let createdURLs = CreatedURLs()
            let name = "newFile"

            #expect(throws: Never.self) {
                try watcher.startWatching { [createdURLs] urls in
                    for url in urls where url.lastPathComponent == name {
                        createdURLs.append(url: url)
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(500))
            let newFile = tempDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(500))

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

            #expect(throws: Never.self) {
                try watcher.startWatching { [createdURLs] urls in
                    for url in urls where url.lastPathComponent == name {
                        createdURLs.append(url: url)
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(300))
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            try await Task.sleep(for: .milliseconds(300))
            let newFile = childDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(300))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdURLs.urls.first!.lastPathComponent == name)

        }

        try await withTempDir { tempDir in
            let parent = UUID().uuidString
            let symlink = UUID().uuidString
            let child = UUID().uuidString

            let parentDir = tempDir.appendingPathComponent(parent)
            let symlinkDir = tempDir.appendingPathComponent(symlink)
            let childDir = symlinkDir.appendingPathComponent(child)

            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: parentDir)

            let watcher = DirectoryWatcher(directoryURL: childDir, log: nil)
            let createdURLs = CreatedURLs()
            let name = "newFile"

            #expect(throws: Never.self) {
                try watcher.startWatching { [createdURLs] urls in
                    for url in urls where url.lastPathComponent == name {
                        createdURLs.append(url: url)
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(300))
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            try await Task.sleep(for: .milliseconds(300))
            let newFile = childDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: newFile.path, contents: nil)
            try await Task.sleep(for: .milliseconds(300))

            #expect(!createdURLs.urls.isEmpty, "directory watcher failed to detect symbolic parent directory")
            #expect(createdURLs.urls.first!.lastPathComponent == name)
        }
    }

    @Test func testWatchingNonExistingParent() async throws {
        try await withTempDir { tempDir in
            let parent = UUID().uuidString
            let child = UUID().uuidString
            let childDir = tempDir.appendingPathComponent(parent).appendingPathComponent(child)

            let watcher = DirectoryWatcher(directoryURL: childDir, log: nil)
            #expect(throws: ContainerizationError.self, "directory watcher should fail if no parent") {
                try watcher.startWatching { urls in }
            }
        }
    }

}
