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

import ContainerizationOS
import Darwin
import Logging
import Testing

@testable import ContainerAPIClient

@Suite("Process cancellation")
struct ProcessCancellationTests {
    @Test
    func cancellationBeforeStartupAcknowledgementEscalatesOnce() async throws {
        let process = CancellationTestProcess()
        let cancellation = ProcessCancellationController(
            process: process,
            gracePeriod: .milliseconds(10)
        )

        cancellation.cancel()
        cancellation.cancel()
        for _ in 0..<20 where await process.recordedSignals().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGTERM, SIGKILL])
    }

    @Test
    func signalDuringStartupIsForwarded() async throws {
        let process = BlockingStartProcess()
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        let task = Task {
            try await io.handleProcess(
                process: process,
                log: Logger(label: "process-signal-test")
            )
        }

        for _ in 0..<20 where !(await process.startEntered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await process.startEntered else {
            task.cancel()
            _ = try? await task.value
            Issue.record("process startup did not begin")
            return
        }
        raise(SIGUSR2)
        await process.releaseStart()

        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let signals = await process.recordedSignals()
        task.cancel()
        _ = try? await task.value
        #expect(signals.first == SIGUSR2)
    }
}

private actor CancellationTestProcess: ClientProcess {
    nonisolated let id = "mock"
    private var signals = [Int32]()

    func start() async throws {}

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}

private actor BlockingStartProcess: ClientProcess {
    nonisolated let id = "blocking-start"
    private(set) var startEntered = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var signals = [Int32]()
    private var exitCode: Int32?
    private var waitContinuation: CheckedContinuation<Int32, Never>?

    func start() async throws {
        startEntered = true
        guard exitCode == nil else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        exitCode = 0
        startContinuation?.resume()
        startContinuation = nil
        waitContinuation?.resume(returning: 0)
        waitContinuation = nil
    }

    func wait() async throws -> Int32 {
        if let exitCode {
            return exitCode
        }
        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func recordedSignals() -> [Int32] { signals }
}
