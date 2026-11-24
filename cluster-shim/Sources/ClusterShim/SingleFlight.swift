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

import Foundation

/// Runs one operation per key at a time. A caller whose key is already running
/// waits for that run and gets its result instead of starting another. A
/// cancelled caller stops waiting at once, and when the last caller of a run
/// is cancelled the run's operation is cancelled.
actor SingleFlight {
    private struct Run {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Void, any Error>]
    }

    private var runs: [String: Run] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait(key: key, waiter: waiter, continuation: continuation, operation: operation)
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    /// The number of callers waiting on the run for `key`, or 0 when none is running.
    func callers(for key: String) -> Int {
        guard let run = runs[key] else {
            return 0
        }
        return run.waiters.count
    }

    /// Adds a waiter to the run for `key`, starting the run when there is none.
    private func wait(
        key: String,
        waiter: UUID,
        continuation: CheckedContinuation<Void, any Error>,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var run = runs[key] {
            run.waiters[waiter] = continuation
            runs[key] = run
            return
        }
        let id = UUID()
        let task = Task {
            let result: Result<Void, any Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finish(key: key, run: id, result: result)
        }
        runs[key] = Run(id: id, task: task, waiters: [waiter: continuation])
    }

    /// Hands `result` to every waiter of run `id`, unless it was cancelled and removed.
    private func finish(key: String, run id: UUID, result: Result<Void, any Error>) {
        guard let run = runs[key], run.id == id else {
            return
        }
        runs[key] = nil
        for continuation in run.waiters.values {
            continuation.resume(with: result)
        }
    }

    /// Ends one waiter's wait, cancelling the run when it was the last waiter.
    private func cancel(key: String, waiter: UUID) {
        guard var run = runs[key], let continuation = run.waiters.removeValue(forKey: waiter) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if run.waiters.isEmpty {
            run.task.cancel()
            runs[key] = nil
        } else {
            runs[key] = run
        }
    }
}
