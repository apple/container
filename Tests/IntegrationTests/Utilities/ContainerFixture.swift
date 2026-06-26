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

import ContainerLog
import Foundation
import Logging
import Synchronization
import SystemPackage
import Testing

/// Per-test fixture providing CLI execution, resource lifecycle, and cleanup.
///
/// Each test gets an isolated instance via ``ContainerFixture/with(_:)``. All
/// resources (containers, networks, volumes, images, scratch files) created
/// through the fixture are tracked and torn down automatically when the scope
/// exits — whether the test passes, fails, or throws.
///
/// Tier 1 — unstructured: call ``addCleanup(_:)`` to register any async
/// closure. Closures run LIFO on scope exit.
///
/// Tier 2 — structured: helpers like ``withContainer(image:tag:runArgs:containerArgs:_:)``
/// register cleanup on your behalf and express resource lifetime as a scope.
final class ContainerFixture: Sendable {

    // MARK: - Well-known images

    /// Images preloaded by the ImageWarmup suite before concurrent tests run.
    /// Add new commonly-used images here; the warmup pass pulls them in parallel.
    static let warmupImages: [String] = [
        "ghcr.io/linuxcontainers/alpine:3.20",
        "ghcr.io/linuxcontainers/alpine:3.18",
        "ghcr.io/containerd/busybox:1.36",
    ]

    // MARK: - Per-instance state

    /// Short random identifier prefixed to every resource this test creates.
    let testID: String

    /// Scratch directory for build inputs, test data, and command output.
    /// Created at fixture init; removed on cleanup unless ``CLITEST_PRESERVE_SCRATCH``
    /// is set in the environment.
    let testDir: FilePath

    private let log: Logger
    private let cleanupTasks: Mutex<[@Sendable () async throws -> Void]> = .init([])
    private static let commandSeq: Mutex<Int> = .init(0)

    // MARK: - Lifecycle

    private init(testID: String, testDir: FilePath, log: Logger) {
        self.testID = testID
        self.testDir = testDir
        self.log = log
    }

    /// Runs `body` with a fresh fixture, then tears down all registered resources.
    ///
    /// Cleanup runs in LIFO order regardless of whether `body` throws.
    @discardableResult
    static func with<T>(_ body: (ContainerFixture) async throws -> T) async throws -> T {
        let testID = String(UUID().uuidString.prefix(8)).lowercased()

        let scratchRoot =
            ProcessInfo.processInfo.environment["CLITEST_SCRATCH_ROOT"]
            .map { FilePath($0) }
            ?? FilePath(FileManager.default.temporaryDirectory.path)
        let testDir = scratchRoot.appending(testID)
        try FileManager.default.createDirectory(
            atPath: testDir.string, withIntermediateDirectories: true, attributes: nil)

        let testName =
            Test.current.map { $0.name.hasSuffix("()") ? String($0.name.dropLast(2)) : $0.name }
            ?? testID
        let suiteName = Test.current.map { "\(type(of: $0))" } ?? "unknown"

        var logger = Logger(label: "com.apple.container.test") { label in
            if let root = ProcessInfo.processInfo.environment["CLITEST_LOG_ROOT"], !root.isEmpty {
                let path =
                    FilePath(root)
                    .appending("clitests")
                    .appending(suiteName)
                    .appending(testName + ".log")
                if let handler = try? FileLogHandler(label: label, category: "clitests", path: path) {
                    return handler
                }
            }
            return StderrLogHandler()
        }
        logger[metadataKey: "testID"] = "\(testID)"

        let fixture = ContainerFixture(testID: testID, testDir: testDir, log: logger)

        if ProcessInfo.processInfo.environment["CLITEST_PRESERVE_SCRATCH"] == nil {
            fixture.addCleanup {
                try? FileManager.default.removeItem(atPath: testDir.string)
            }
        }

        do {
            let result = try await body(fixture)
            await fixture.runCleanup()
            return result
        } catch {
            await fixture.runCleanup()
            throw error
        }
    }

    /// Registers a cleanup closure to run when the fixture scope exits.
    /// Closures execute in LIFO order.
    func addCleanup(_ task: @escaping @Sendable () async throws -> Void) {
        cleanupTasks.withLock { $0.append(task) }
    }

    private func runCleanup() async {
        let tasks = cleanupTasks.withLock { tasks -> [@Sendable () async throws -> Void] in
            let reversed = Array(tasks.reversed())
            tasks.removeAll()
            return reversed
        }
        for task in tasks {
            try? await task()
        }
    }

    // MARK: - CLI execution

    private var executableURL: URL {
        get throws {
            let path: FilePath
            if let env = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"] {
                path = FilePath(env)
            } else {
                let candidate = FilePath(FileManager.default.currentDirectoryPath)
                    .appending("bin").appending("container")
                guard FileManager.default.fileExists(atPath: candidate.string) else {
                    throw CommandError.binaryNotFound
                }
                path = candidate
            }
            return URL(filePath: path.string)
        }
    }

    /// Runs the container CLI with the given arguments and returns the result.
    ///
    /// Throws ``CommandError`` only for execution failures (binary not found,
    /// process launch error). A non-zero exit status is represented in
    /// ``CommandResult/status`` — call ``CommandResult/check(_:)`` to turn it
    /// into a thrown error.
    func run(
        _ arguments: [String],
        stdin: Data? = nil,
        currentDirectory: FilePath? = nil,
        env: [String: String] = [:]
    ) throws -> CommandResult {
        let seq = Self.commandSeq.withLock { n in
            defer { n += 1 }
            return n
        }
        log.info(
            "command start",
            metadata: ["seq": "\(seq)", "args": "\(arguments.joined(separator: " "))"])

        let process = Process()
        process.executableURL = try executableURL
        process.arguments = arguments
        if let dir = currentDirectory { process.currentDirectoryURL = URL(filePath: dir.string) }
        if !env.isEmpty {
            var e = ProcessInfo.processInfo.environment
            for (k, v) in env { e[k] = v }
            process.environment = e
        }

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        // Write stdout/stderr to temp files to avoid blocking on full pipe buffers.
        let tmpDir = FilePath(FileManager.default.temporaryDirectory.path)
            .appending(UUID().uuidString)
        try FileManager.default.createDirectory(
            atPath: tmpDir.string, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir.string) }

        let stdoutPath = tmpDir.appending("stdout")
        let stderrPath = tmpDir.appending("stderr")
        FileManager.default.createFile(atPath: stdoutPath.string, contents: nil)
        FileManager.default.createFile(atPath: stderrPath.string, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: URL(filePath: stdoutPath.string))
        defer { try? stdoutHandle.close() }
        let stderrHandle = try FileHandle(forWritingTo: URL(filePath: stderrPath.string))
        defer { try? stderrHandle.close() }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw CommandError.executionFailed("process launch failed: \(error)")
        }
        if let data = stdin { inputPipe.fileHandleForWriting.write(data) }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = (try? Data(contentsOf: URL(filePath: stdoutPath.string))) ?? Data()
        let errorData = (try? Data(contentsOf: URL(filePath: stderrPath.string))) ?? Data()

        log.info(
            "command end",
            metadata: [
                "seq": "\(seq)",
                "status": "\(process.terminationStatus)",
            ])

        return CommandResult(
            outputData: outputData,
            errorData: errorData,
            status: process.terminationStatus)
    }

    // MARK: - Image helpers

    /// Tags a warmup image to a test-local reference and registers its removal.
    ///
    /// The returned name is `{testID}-{imageName}:{tag}`, e.g.
    /// `a3f7c2b1-alpine:3.20`. Tests operate freely on this reference;
    /// the canonical warmup image is never touched.
    func copyWarmupImage(_ canonical: String) throws -> String {
        let lastComponent = canonical.split(separator: "/").last.map(String.init) ?? canonical
        let parts = lastComponent.split(separator: ":", maxSplits: 1)
        let name = String(parts[0])
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        let localRef = "\(testID)-\(name):\(tag)"

        try run(["image", "tag", canonical, localRef]).check()
        addCleanup {
            _ = try? self.run(["image", "rm", localRef])
        }
        return localRef
    }

    // MARK: - Container helpers

    /// Runs a container, calls `body`, then stops and removes the container.
    ///
    /// The container name is `{testID}-{tag}`. Supply a `tag` when a test
    /// needs more than one container to avoid name collisions.
    func withContainer(
        image: String,
        tag: String = "c",
        runArgs: [String] = [],
        containerArgs: [String] = ["sleep", "infinity"],
        _ body: (String) async throws -> Void
    ) async throws {
        let name = "\(testID)-\(tag)"
        let args = ["run", "--rm", "--name", name, "-d"] + runArgs + [image] + containerArgs
        try run(args).check()
        defer {
            _ = try? run(["stop", "-s", "SIGKILL", name])
        }
        try await body(name)
    }

    /// Polls until the named container reaches the `running` state.
    func waitForContainerRunning(_ name: String, attempts: Int = 30) throws {
        for _ in 0..<attempts {
            if let result = try? run(["inspect", name]),
                result.status == 0,
                result.output.contains("\"running\"")
            {
                return
            }
            sleep(1)
        }
        throw CommandError.executionFailed("container '\(name)' did not reach running state")
    }
}
