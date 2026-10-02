//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerRuntimeClient
import Containerization
import ContainerizationError
import Foundation
import Testing

private actor CallbackRecorder {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func invocationCount() -> Int {
        count
    }

    func waitForInvocation() async {
        guard count == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor WaitGate {
    private var continuation: CheckedContinuation<Containerization.ExitStatus, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async -> Containerization.ExitStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ status: Containerization.ExitStatus) {
        continuation?.resume(returning: status)
        continuation = nil
    }
}

struct ExitMonitorTests {
    @Test func intentionalCancellationDoesNotInvokeExitCallback() async throws {
        let monitor = ExitMonitor()
        let recorder = CallbackRecorder()

        try await monitor.registerProcess(id: "cancelled") { _, _ in
            await recorder.record()
        }
        try await monitor.track(id: "cancelled") {
            try await Task.sleep(for: .seconds(60))
            return Containerization.ExitStatus(exitCode: 0)
        }

        await monitor.stopTracking(id: "cancelled")
        try await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.invocationCount() == 0)
    }

    @Test func cancelledOldGenerationCannotInvokeAfterSameIDRegistration() async throws {
        let monitor = ExitMonitor()
        let oldRecorder = CallbackRecorder()
        let replacementRecorder = CallbackRecorder()
        let gate = WaitGate()

        try await monitor.registerProcess(id: "reused") { _, _ in
            await oldRecorder.record()
        }
        try await monitor.track(id: "reused") {
            await gate.wait()
        }
        while !(await gate.isWaiting) {
            await Task.yield()
        }

        await monitor.stopTracking(id: "reused")
        try await monitor.registerProcess(id: "reused") { _, _ in
            await replacementRecorder.record()
        }
        await gate.release(Containerization.ExitStatus(exitCode: 0))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await oldRecorder.invocationCount() == 0)
        #expect(await replacementRecorder.invocationCount() == 0)
    }

    @Test func callbackRetainsRegistrationUntilItCompletes() async throws {
        let monitor = ExitMonitor()
        let callbackStarted = CallbackRecorder()
        let callbackGate = WaitGate()

        try await monitor.registerProcess(id: "callback-in-progress") { _, _ in
            await callbackStarted.record()
            _ = await callbackGate.wait()
        }
        try await monitor.track(id: "callback-in-progress") {
            Containerization.ExitStatus(exitCode: 0)
        }
        await callbackStarted.waitForInvocation()

        await #expect(throws: ContainerizationError.self) {
            try await monitor.registerProcess(id: "callback-in-progress") { _, _ in }
        }

        await callbackGate.release(Containerization.ExitStatus(exitCode: 0))
    }

    @Test func waitFailureStillInvokesExitCallbackOnce() async throws {
        struct WaitFailure: Error {}

        let monitor = ExitMonitor()
        let recorder = CallbackRecorder()

        try await monitor.registerProcess(id: "failed-wait") { _, _ in
            await recorder.record()
        }
        try await monitor.track(id: "failed-wait") {
            throw WaitFailure()
        }
        await recorder.waitForInvocation()

        #expect(await recorder.invocationCount() == 1)
    }

    @Test func uncancelledCancellationErrorStillInvokesExitCallbackOnce() async throws {
        let monitor = ExitMonitor()
        let recorder = CallbackRecorder()

        try await monitor.registerProcess(id: "failed-wait-cancellation-error") { _, _ in
            await recorder.record()
        }
        try await monitor.track(id: "failed-wait-cancellation-error") {
            throw CancellationError()
        }
        await recorder.waitForInvocation()

        #expect(await recorder.invocationCount() == 1)
    }
}
