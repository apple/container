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
import Darwin
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ContainerOS

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

    private final class CreatedPaths: Sendable {
        private let paths = Mutex<[FilePath]>([])

        func record(_ paths: [FilePath]) {
            self.paths.withLock { $0.append(contentsOf: paths) }
        }

        func contains(_ expectedNames: Set<String>) -> Bool {
            paths.withLock { paths in
                let names = Set(paths.compactMap { $0.lastComponent?.string })
                return names.isSuperset(of: expectedNames)
            }
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return await condition()
    }

    private func waitForPaths(
        _ expectedNames: Set<String>,
        in createdPaths: CreatedPaths
    ) async -> Bool {
        await waitUntil {
            createdPaths.contains(expectedNames)
        }
    }

    private func waitForWatcher(
        _ watcher: DirectoryWatcher,
        toBeWatching expected: Bool = true
    ) async -> Bool {
        await waitUntil {
            await watcher.isWatching == expected
        }
    }

    @Test func testWatchingExistingDirectory() async throws {
        try await withTempDir { tempPath in

            let watcher = DirectoryWatcher(directoryPath: tempPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { [createdPaths] paths in
                createdPaths.record(paths)
            }

            try #require(await waitForWatcher(watcher), "directory watcher did not initialise")
            let newFile = tempPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)

            #expect(
                await waitForPaths([name], in: createdPaths),
                "directory watcher failed to detect new file"
            )
        }
    }

    @Test func testWatchingNonExistingDirectory() async throws {
        try await withTempDir { tempPath in
            let uuid = UUID().uuidString
            let childPath = tempPath.appending(uuid)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { [createdPaths] paths in
                createdPaths.record(paths)
            }

            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)
            try #require(await waitForWatcher(watcher), "directory watcher did not initialise")
            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)

            #expect(
                await waitForPaths([name], in: createdPaths),
                "directory watcher failed to detect directory"
            )
        }
    }

    @Test func testWatchingNonExistingParent() async throws {
        try await withTempDir { tempPath in
            let parent = UUID().uuidString
            let child = UUID().uuidString
            let childPath = tempPath.appending(parent).appending(child)

            let watcher = DirectoryWatcher(directoryPath: childPath, log: nil)
            let createdPaths = CreatedPaths()
            let name = "newFile"

            await watcher.startWatching { paths in
                createdPaths.record(paths)
            }

            try FileManager.default.createDirectory(atPath: childPath.string, withIntermediateDirectories: true)
            try #require(await waitForWatcher(watcher), "directory watcher did not initialise")

            let newFile = childPath.appending(name)
            FileManager.default.createFile(atPath: newFile.string, contents: nil)

            #expect(
                await waitForPaths([name], in: createdPaths),
                "directory watcher failed to detect parent directory"
            )
        }
    }

    @Test func testFailingHandlerDoesNotLeakDescriptors() async throws {
        try await withTempDir { tempPath in
            let watcher = DirectoryWatcher(directoryPath: tempPath, log: nil)
            let baseline = try openDescriptorCount(for: tempPath)
            let handlerCalls = Mutex(0)

            for _ in 0..<32 {
                do {
                    try await watcher._startWatching { _ in
                        handlerCalls.withLock { $0 += 1 }
                        throw ContainerizationError(.internalError, message: "intentional test failure")
                    }
                    Issue.record("expected the failing watch handler to throw")
                } catch is ContainerizationError {
                    // Expected.
                }
            }

            let afterFailures = try openDescriptorCount(for: tempPath)
            #expect(handlerCalls.withLock { $0 } == 32)
            #expect(
                afterFailures == baseline,
                "failing handlers leaked descriptors: before=\(baseline), after=\(afterFailures)"
            )
        }
    }

    @Test func testWatchingRecreatedDirectory() async throws {
        try await withTempDir { tempPath in
            let dirPath = tempPath.appending(UUID().uuidString)
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)

            let watcher = DirectoryWatcher(directoryPath: dirPath, log: nil)
            let createdPaths = CreatedPaths()
            let beforeDelete = "beforeDelete"
            let afterDelete = "afterDelete"

            await watcher.startWatching { [createdPaths] paths in
                createdPaths.record(paths)
            }

            try #require(await waitForWatcher(watcher), "directory watcher did not initialise")
            let file1 = dirPath.appending(beforeDelete)
            FileManager.default.createFile(atPath: file1.string, contents: nil)
            try #require(
                await waitForPaths([beforeDelete], in: createdPaths),
                "directory watcher failed to detect file before directory recreation"
            )

            try FileManager.default.removeItem(atPath: dirPath.string)
            try #require(
                await waitForWatcher(watcher, toBeWatching: false),
                "directory watcher did not stop after directory removal"
            )
            try FileManager.default.createDirectory(atPath: dirPath.string, withIntermediateDirectories: true)
            try #require(
                await waitForWatcher(watcher),
                "directory watcher did not resume after directory recreation"
            )

            let file2 = dirPath.appending(afterDelete)
            FileManager.default.createFile(atPath: file2.string, contents: nil)

            #expect(
                await waitForPaths([beforeDelete, afterDelete], in: createdPaths),
                "directory watcher failed to detect file after directory recreation"
            )
        }

    }

    private func openDescriptorCount(for path: FilePath) throws -> Int {
        var expectedBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard realpath(path.string, &expectedBuffer) != nil else {
            throw ContainerizationError(.internalError, message: "failed to resolve test directory: \(path)")
        }
        let expectedBytes = expectedBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let expectedPath = String(decoding: expectedBytes, as: UTF8.self)
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        return
            descriptors
            .compactMap(Int.init)
            .filter { descriptor in
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(CInt(descriptor), F_GETPATH, &buffer) == 0 else {
                    return false
                }
                let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: pathBytes, as: UTF8.self) == expectedPath
            }
            .count
    }
}
