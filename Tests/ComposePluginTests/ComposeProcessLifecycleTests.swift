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
import ContainerizationOS
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerCompose

@Suite("Compose process lifecycle")
struct ComposeProcessLifecycleTests {
    @Test
    func captureCancellationKillsBeforeStartupAcknowledgement() async throws {
        let process = MockClientProcess()
        let cancellation = ComposeProcessCancellation(process: process)

        cancellation.cancel()
        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }

    @Test
    func capturedOutputLimitKillsTheProcess() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = MockClientProcess {
            try? stderr.fileHandleForWriting.close()
        }
        stdout.fileHandleForWriting.write(Data(repeating: 1, count: 1_025))
        try stdout.fileHandleForWriting.close()
        defer { try? stderr.fileHandleForWriting.close() }
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: ContainerizationError.self) {
            try await ComposeProcessRunner.capture(
                process: process,
                stdout: stdout,
                stderr: stderr,
                timeout: .seconds(5),
                maxOutputBytes: 1_024
            )
        }
        #expect(clock.now - start < .seconds(1))
        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }

    @Test
    func capturedOutputAcceptsTheLimit() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 1, count: 1_024))
        try pipe.fileHandleForWriting.close()

        let output = try ComposeProcessRunner.readAll(
            from: pipe.fileHandleForReading,
            maxBytes: 1_024
        )
        #expect(output.count == 1_024)
    }

    @Test(.timeLimit(.minutes(1)))
    func startupTimeoutKillsTheProcess() async throws {
        let process = BlockingComposeProcess()
        let stdout = Pipe()
        let stderr = Pipe()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        do {
            _ = try await ComposeProcessRunner.capture(
                process: process,
                stdout: stdout,
                stderr: stderr,
                timeout: .milliseconds(20),
                maxOutputBytes: 1_024
            )
            Issue.record("timed out capture unexpectedly succeeded")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.timeout))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationEscalatesWhenBuildIgnoresTermination() async throws {
        let task = Task {
            try await ComposeMachineImageBuilder.CommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                log: Logger(label: "compose-process-test")
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled build unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private actor MockClientProcess: ClientProcess {
    nonisolated let id = "mock"
    private let onKill: @Sendable () -> Void
    private var signals = [Int32]()

    init(onKill: @escaping @Sendable () -> Void = {}) {
        self.onKill = onKill
    }

    func start() async throws {}

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        onKill()
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}

private actor BlockingComposeProcess: ClientProcess {
    nonisolated let id = "blocking"
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var signals = [Int32]()

    func start() async throws {
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        startContinuation?.resume()
        startContinuation = nil
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}
