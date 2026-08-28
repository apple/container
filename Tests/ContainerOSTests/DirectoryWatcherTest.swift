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
import SystemPackage
import Testing

struct DirectoryWatcherTest {
    let testUUID = UUID().uuidString

    private var testDir: FilePath {
        let tempURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".clitests")
            .appendingPathComponent(testUUID)
        try! FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return FilePath(tempURL.path)
    }

    private func withTempDir<T>(_ body: (FilePath) async throws -> T) async throws -> T {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let tempPath = FilePath(tempURL.path)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try await body(tempPath)
    }

    private actor CreatedPaths {
        nonisolated(unsafe) public var paths: [FilePath]

        public init() {
            self.paths = []
        }
    }

    /// Polls `condition` until it returns true or `timeout` elapses. Used only to wait for the
    /// handler's async invocation after a mutation, never to guess how long watcher setup takes.
    private func waitUntil(timeout: Duration = .seconds(10), condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func testWatchingExistingDirectory() async throws {
        try await withTempDir { tempPath in
            let watcher = DirectoryWatcher(directoryPath: tempPath, log: nil)
            var readyIterator = await watcher.readyEvents.makeAsyncIterator()
            let createdPaths = CreatedPaths()
            let name = "newFile"

            try await watcher.startWatching { [createdPaths] paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.paths.append(path)
                }
            }

            // Wait for the watcher to actually resume watching, instead of guessing a sleep
            // duration that can race the watcher's own poll cadence.
            await readyIterator.next()

            let newFile = tempPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitUntil { !createdPaths.paths.isEmpty }

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect new file")
            #expect(createdPaths.paths.first!.lastComponent?.string == name)
        }
    }

    @Test func testWatchingNonExistingDirectory() async throws {
        try await withTempDir { tempPath in
            let uuid = UUID().uuidString
            let childPath = tempPath.appending(uuid)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            var readyIterator = await watcher.readyEvents.makeAsyncIterator()
            let createdPaths = CreatedPaths()
            let name = "newFile"

            try await watcher.startWatching { [createdPaths] paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.paths.append(path)
                }
            }

            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)

            // Wait for the watcher to actually resume watching, instead of guessing a sleep
            // duration that can race the watcher's own poll cadence.
            await readyIterator.next()

            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitUntil { !createdPaths.paths.isEmpty }

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdPaths.paths.first!.lastComponent?.string == name)
        }
    }

    @Test func testWatchingNonExistingParent() async throws {
        try await withTempDir { tempPath in
            let parent = UUID().uuidString
            let child = UUID().uuidString
            let childPath = tempPath.appending(parent).appending(child)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            var readyIterator = await watcher.readyEvents.makeAsyncIterator()
            let createdPaths = CreatedPaths()
            let name = "newFile"

            try await watcher.startWatching { paths in
                for path in paths where path.lastComponent?.string == name {
                    createdPaths.paths.append(path)
                }
            }

            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)

            // Wait for the watcher to actually resume watching, instead of guessing a sleep
            // duration that can race the watcher's own poll cadence.
            await readyIterator.next()

            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)
            try await waitUntil { !createdPaths.paths.isEmpty }

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect parent directory")
            #expect(createdPaths.paths.first!.lastComponent?.string == name)
        }
    }

    @Test func testWatchingRecreatedDirectory() async throws {
        try await withTempDir { tempPath in
            let dirPath = tempPath.appending(UUID().uuidString)
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)

            let watcher = DirectoryWatcher(directoryPath: dirPath, log: nil)
            var readyIterator = await watcher.readyEvents.makeAsyncIterator()
            let createdPaths = CreatedPaths()
            let beforeDelete = "beforeDelete"
            let afterDelete = "afterDelete"

            try await watcher.startWatching { [createdPaths] paths in
                for path in paths
                where path.lastComponent?.string == beforeDelete || path.lastComponent?.string == afterDelete {
                    createdPaths.paths.append(path)
                }
            }

            // Wait for the watcher to actually resume watching, instead of guessing a sleep
            // duration that can race the watcher's own poll cadence.
            await readyIterator.next()

            let file1 = dirPath.appending(beforeDelete)
            FileManager.default.createFile(atPath: file1.string, contents: nil)
            try await waitUntil { createdPaths.paths.contains { $0.lastComponent?.string == beforeDelete } }

            try FileManager.default.removeItem(atPath: dirPath.string)
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)

            // `readyEvents` yields once per resume, so this waits however long the watcher
            // actually takes to notice the delete, then re-arm on the recreated directory —
            // no guessing needed even though this transition takes an unknown amount of time.
            await readyIterator.next()

            let file2 = dirPath.appending(afterDelete)
            FileManager.default.createFile(atPath: file2.string, contents: nil)
            try await waitUntil { createdPaths.paths.contains { $0.lastComponent?.string == afterDelete } }

            #expect(!createdPaths.paths.isEmpty, "directory watcher failed to detect new file")
            #expect(
                Set(createdPaths.paths.compactMap { $0.lastComponent?.string }) == Set([beforeDelete, afterDelete]))
        }
    }
}
