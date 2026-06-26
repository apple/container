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

import ContainerAPIClient
import ContainerizationError
import Darwin
import Foundation
import Testing

@testable import ContainerCommands

@Suite(.serialized)
struct ApplicationHealthTests {
    @Test(arguments: [
        (["container", "--help"], true),
        (["container", "-h"], true),
        (["container"], false),
        (["container", "compose", "--help"], false),
        (["container", "--version"], false),
    ])
    func rootHelpRequestDetection(arguments: [String], expected: Bool) {
        #expect(Application.isRootHelpRequest(arguments) == expected)
    }

    @Test
    func pluginLoaderForHelpReturnsLoaderWhenHealthCheckSucceeds() async throws {
        let appRoot = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appRoot) }

        let loader = await Application.pluginLoaderForHelp { timeout in
            #expect(timeout == .seconds(1))
            return try Self.makeSystemHealth(appRoot: appRoot)
        }

        #expect(loader != nil)
    }

    @Test
    func pluginLoaderForHelpReturnsNilWhenHealthCheckTimesOut() async throws {
        let loader = await Application.pluginLoaderForHelp { _ in
            try await Task.sleep(for: .seconds(2))
            return try Self.makeSystemHealth()
        }

        #expect(loader == nil)
    }

    @Test
    func defaultCommandWithoutArgumentsCompletesWhenPluginDiscoveryIsUnavailable() async throws {
        var command = DefaultCommand()
        command.remaining = []
        let box = UncheckedSendableBox(command)

        try await Self.requireCompletesWithin(.seconds(2)) {
            try await Self.discardStandardOutput {
                try await box.value.run()
            }
        }
    }

    @Test
    func helpCommandWithoutPathCompletesWhenPluginDiscoveryIsUnavailable() async throws {
        var command = HelpCommand()
        command.subcommandPath = []
        let box = UncheckedSendableBox(command)

        try await Self.requireCompletesWithin(.seconds(2)) {
            try await Self.discardStandardOutput {
                try await box.value.run()
            }
        }
    }

    @Test
    func apiServerHealthReturnsSuccessfulHealthCheck() async throws {
        let expected = try Self.makeSystemHealth()

        let health = try await Application.apiServerHealth(
            healthTimeout: .seconds(10),
            wallTimeout: .seconds(1)
        ) { timeout in
            #expect(timeout == .seconds(10))
            return expected
        }

        #expect(health.appRoot == expected.appRoot)
        #expect(health.installRoot == expected.installRoot)
        #expect(health.logRoot == expected.logRoot)
        #expect(health.apiServerCommit == expected.apiServerCommit)
    }

    @Test
    func apiServerHealthReturnsHealthCheckErrorBeforeWallTimeout() async throws {
        do {
            _ = try await Application.apiServerHealth(
                healthTimeout: .seconds(10),
                wallTimeout: .seconds(1)
            ) { _ in
                throw ContainerizationError(.invalidState, message: "health check failed")
            }
            Issue.record("expected health check to throw")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
            #expect(error.message == "health check failed")
        }
    }

    @Test
    func apiServerHealthReturnsWallTimeoutWhenHealthCheckDoesNotComplete() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await Application.apiServerHealth(
                healthTimeout: .seconds(10),
                wallTimeout: .milliseconds(100)
            ) { _ in
                try await Task.sleep(for: .seconds(1))
                return try Self.makeSystemHealth()
            }
            Issue.record("expected health check to time out")
        } catch let error as ContainerizationError {
            let elapsed = start.duration(to: clock.now)
            #expect(error.code == .timeout)
            #expect(error.message == "unable to retrieve application data root from API server")
            #expect(elapsed < .seconds(2))
        }
    }

    @Test
    func apiServerHealthIgnoresLateHealthCheckAfterWallTimeout() async throws {
        do {
            _ = try await Application.apiServerHealth(
                healthTimeout: .seconds(10),
                wallTimeout: .milliseconds(50)
            ) { _ in
                try await Task.sleep(for: .milliseconds(150))
                return try Self.makeSystemHealth()
            }
            Issue.record("expected health check to time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        try await Task.sleep(for: .milliseconds(250))
    }

    private static func makeSystemHealth(appRoot: URL = URL(filePath: "/tmp/container-test-app-root")) throws -> SystemHealth {
        let json = """
            {
                "appRoot": "\(appRoot.absoluteString)",
                "installRoot": "file:///tmp/container-test-install-root",
                "apiServerVersion": "test-version",
                "apiServerCommit": "test-commit",
                "apiServerBuild": "debug",
                "apiServerAppName": "container-apiserver"
            }
            """
        return try JSONDecoder().decode(SystemHealth.self, from: Data(json.utf8))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func requireCompletesWithin(_ timeout: Duration, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = VoidAsyncResult(continuation)

            let operationTask = Task {
                do {
                    try await operation()
                    await result.resume(.success(()))
                } catch {
                    await result.resume(.failure(error))
                }
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                await result.resume(
                    .failure(
                        ContainerizationError(
                            .timeout,
                            message: "operation did not complete within \(timeout)"
                        )))
            }

            Task {
                await result.setTasks(operationTask: operationTask, timeoutTask: timeoutTask)
            }
        }
    }

    private static func discardStandardOutput(operation: () async throws -> Void) async throws {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        var restored = false
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        defer {
            fflush(stdout)
            if !restored {
                dup2(original, STDOUT_FILENO)
                pipe.fileHandleForWriting.closeFile()
            }
            close(original)
            pipe.fileHandleForReading.closeFile()
        }

        try await operation()
        fflush(stdout)
        dup2(original, STDOUT_FILENO)
        restored = true
        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.readDataToEndOfFile()
    }
}

private actor VoidAsyncResult {
    private let continuation: CheckedContinuation<Void, any Error>
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resumed = false

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func setTasks(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        if resumed {
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
    }

    func resume(_ result: Result<Void, any Error>) {
        guard !resumed else {
            return
        }
        resumed = true
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
