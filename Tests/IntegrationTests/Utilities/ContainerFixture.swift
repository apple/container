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
import Darwin
import Foundation
import Logging
import Synchronization
import SystemPackage
import Testing

/// Per-test fixture for CLI integration tests.
///
/// Open a fixture scope with ``ContainerFixture/with(_:)``. Every resource
/// created during the scope is tracked and torn down on exit — whether the
/// test passes, fails, or throws.
///
/// ## Unstructured API (Tier 1)
///
/// Primitives that execute commands or register cleanup without enforcing
/// a scope boundary. The caller owns the resource lifetime.
///
/// - ``run(_:stdin:currentDirectory:env:)`` runs the CLI and returns a
///   ``CommandResult``; call ``CommandResult/check(_:)`` to assert success.
/// - ``addCleanup(_:)`` registers an async closure that runs LIFO on scope exit.
/// - ``copyWarmupImage(_:)`` tags a pre-warmed image to a test-local name and
///   auto-registers its removal.
/// - ``waitForContainerRunning(_:attempts:)`` polls until a container is
///   `running`; required when using lower-level create/start helpers directly.
///
/// ## Structured API (Tier 2)
///
/// Scoped helpers that manage resource lifetime via a closure boundary.
/// Resources are torn down when the closure exits regardless of whether it
/// throws.
///
/// - ``withContainer(image:tag:runArgs:containerArgs:autoRemove:_:)`` starts a
///   detached container, waits for `running`, calls the body, then stops (and
///   optionally deletes) it on exit.
///
/// ## Choosing a tier
///
/// Prefer Tier 2 for common patterns — it eliminates cleanup boilerplate and
/// prevents leaks. Drop to Tier 1 when a test exercises a specific
/// create/start/stop sequence, needs low-level control, or uses a resource
/// pattern the structured helpers don't cover.
final class ContainerFixture: Sendable {

    // MARK: - Configuration

    /// Images preloaded by the ``ImageWarmup`` suite before concurrent tests run.
    /// Add new commonly-used images here; the warmup pass pulls them in parallel.
    static let warmupImages: [String] = [
        "ghcr.io/linuxcontainers/alpine:3.20",
        "ghcr.io/linuxcontainers/alpine:3.18",
        "ghcr.io/containerd/busybox:1.36",
    ]

    // MARK: - State

    /// Short random identifier prefixed to every resource this test creates.
    let testID: String

    /// Scratch directory for build inputs, test data, and command output.
    /// Created at fixture init; removed on cleanup unless `CLITEST_PRESERVE_SCRATCH=true`.
    let testDir: FilePath

    /// Logger for this fixture scope. Tests may emit diagnostic messages via this logger.
    let log: Logger

    // MARK: - Unstructured API

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

        let testName =
            Test.current.map { $0.name.hasSuffix("()") ? String($0.name.dropLast(2)) : $0.name }
            ?? testID
        let suiteName = Test.current.map { "\(type(of: $0))" } ?? "unknown"

        // Name the scratch directory so it's immediately identifiable when browsing:
        // {sanitizedTestName}-{testID}
        let safeName = testName.replacingOccurrences(
            of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let testDir = scratchRoot.appending("\(safeName)-\(testID)")
        try FileManager.default.createDirectory(
            atPath: testDir.string, withIntermediateDirectories: true, attributes: nil)

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
            return StreamLogHandler.standardOutput(label: label)
        }
        logger[metadataKey: "testID"] = "\(testID)"

        let fixture = ContainerFixture(testID: testID, testDir: testDir, log: logger)

        if ProcessInfo.processInfo.environment["CLITEST_PRESERVE_SCRATCH"] != "true" {
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
        env: [String: String] = [:],
        pty: Bool = false
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

        // When pty is true, allocate a PTY slave for stdin so the child process
        // sees a real terminal (satisfying isatty checks and tcgetattr calls).
        // stdout/stderr still go to temp files so output is captured separately.
        var masterFd: Int32 = -1
        let inputPipe = Pipe()
        if pty {
            var slaveFd: Int32 = -1
            guard openpty(&masterFd, &slaveFd, nil, nil, nil) == 0 else {
                throw CommandError.executionFailed("openpty failed: errno \(errno)")
            }
            process.standardInput = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: true)
        } else {
            process.standardInput = inputPipe
        }

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
        if pty {
            // Write through the master side; the kernel tty buffers input until the
            // child reads it, so this works even before the child is ready (e.g. a
            // shell that hasn't started reading stdin yet). Master stays open until
            // after the process exits so the slave doesn't receive SIGHUP prematurely.
            if let data = stdin { FileHandle(fileDescriptor: masterFd, closeOnDealloc: false).write(data) }
        } else {
            if let data = stdin { inputPipe.fileHandleForWriting.write(data) }
            inputPipe.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()
        if masterFd >= 0 { Darwin.close(masterFd) }

        let outputData = (try? Data(contentsOf: URL(filePath: stdoutPath.string))) ?? Data()
        let errorData = (try? Data(contentsOf: URL(filePath: stderrPath.string))) ?? Data()

        log.info(
            "command end",
            metadata: ["seq": "\(seq)", "status": "\(process.terminationStatus)"])

        return CommandResult(
            outputData: outputData,
            errorData: errorData,
            status: process.terminationStatus)
    }

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

    /// Polls until the named container reaches the `running` state.
    ///
    /// Call this directly only when using ``doCreate(_:image:args:volumes:networks:ports:)``
    /// and ``doStart(_:)`` — ``withContainer(image:tag:runArgs:containerArgs:autoRemove:_:)``
    /// waits automatically.
    func waitForContainerRunning(_ name: String, attempts: Int = 30) async throws {
        for _ in 0..<attempts {
            if let result = try? run(["inspect", name]),
                result.status == 0,
                result.output.contains("\"running\"")
            {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CommandError.executionFailed("container '\(name)' did not reach running state")
    }

    // MARK: - Structured API

    /// Starts a detached container, waits for `running`, calls `body`, then
    /// stops and removes the container.
    ///
    /// The container name is `{testID}-{tag}`. Supply a distinct `tag` when a
    /// test needs more than one container simultaneously.
    ///
    /// When `autoRemove` is `true` (default), `--rm` is passed so the runtime
    /// removes the container on stop. Set `autoRemove: false` when the test
    /// needs to inspect the container's stopped state — cleanup will then stop
    /// *and* delete it.
    func withContainer(
        image: String,
        tag: String = "c",
        runArgs: [String] = [],
        containerArgs: [String] = ["sleep", "infinity"],
        autoRemove: Bool = true,
        _ body: (String) async throws -> Void
    ) async throws {
        let name = "\(testID)-\(tag)"
        var args = ["run", "--name", name, "-d"]
        if autoRemove { args.append("--rm") }
        args += runArgs + [image] + containerArgs
        try run(args).check()
        defer {
            _ = try? run(["stop", "-s", "SIGKILL", name])
            if !autoRemove { _ = try? run(["delete", name]) }
        }
        try await waitForContainerRunning(name)
        try await body(name)
    }

    // MARK: - Private

    private let cleanupTasks: Mutex<[@Sendable () async throws -> Void]> = .init([])
    private static let commandSeq: Mutex<Int> = .init(0)

    private init(testID: String, testDir: FilePath, log: Logger) {
        self.testID = testID
        self.testDir = testDir
        self.log = log
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
}

// MARK: - Retry

extension ContainerFixture {
    /// Retries `body` up to `attempts` times, sleeping `delay` between each attempt.
    ///
    /// - Returns when `body` returns `true`.
    /// - Retries when `body` returns `false`.
    /// - Propagates immediately (aborting the loop) when `body` throws.
    ///
    /// Throws `CommandError.executionFailed` if all attempts return `false`.
    func retry(attempts: Int, delay: Duration = .seconds(1), _ body: () async throws -> Bool) async throws {
        for attempt in 1...attempts {
            if try await body() { return }
            print("retry: attempt \(attempt)/\(attempts) not yet ready")
            if attempt < attempts {
                try await Task.sleep(for: delay)
            }
        }
        throw CommandError.executionFailed("retry: condition not met after \(attempts) attempts")
    }
}
