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

import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

/// Track when long running work exits, and notify the caller via a callback.
public actor ExitMonitor {
    /// A callback that receives the client identifier and exit code.
    public typealias ExitCallback = @Sendable (String, ExitStatus) async throws -> Void

    /// A function that waits for work to complete, returning an exit code.
    public typealias WaitHandler = @Sendable () async throws -> ExitStatus

    /// Create a new monitor.
    ///
    /// - Parameters:
    ///   - log: The destination for log messages.
    public init(log: Logger? = nil) {
        self.log = log
    }

    private struct CallbackRegistration {
        let generation: UUID
        let callback: ExitCallback
    }

    private struct RunningTask {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var exitCallbacks: [String: CallbackRegistration] = [:]
    private var runningTasks: [String: RunningTask] = [:]
    private let log: Logger?

    /// Remove tracked work from the monitor.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the tracked work.
    public func stopTracking(id: String) async {
        if let runningTask = self.runningTasks.removeValue(forKey: id) {
            runningTask.task.cancel()
        }
        exitCallbacks.removeValue(forKey: id)
    }

    /// Register long running work so that the monitor invokes
    /// a callback when the work completes.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the work.
    ///   - onExit: The callback to invoke when the work completes.
    public func registerProcess(id: String, onExit: @escaping ExitCallback) async throws {
        guard self.exitCallbacks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor already setup for process \(id)")
        }
        self.exitCallbacks[id] = CallbackRegistration(
            generation: UUID(),
            callback: onExit
        )
    }

    /// Await the completion of previously registered item of work.
    ///
    /// - Parameters:
    ///   - id: The client identifier for the work.
    ///   - waitingOn: A function that waits for the work to complete,
    ///     and then returns an exit code.
    public func track(id: String, waitingOn: @escaping WaitHandler) async throws {
        guard let registration = self.exitCallbacks[id] else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor not setup for process \(id)")
        }
        guard self.runningTasks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "already have a running task tracking process \(id)")
        }

        let generation = registration.generation
        let task = Task {
            let exitStatus: ExitStatus
            do {
                exitStatus = try await waitingOn()
            } catch {
                guard !Task.isCancelled else {
                    self.discardRegistration(id: id, generation: generation)
                    return
                }
                self.log?.error("WaitHandler for \(id) threw error \(String(describing: error))")
                exitStatus = ExitStatus(exitCode: -1)
            }

            guard !Task.isCancelled else {
                self.discardRegistration(id: id, generation: generation)
                return
            }
            guard let onExit = self.callback(id: id, generation: generation) else {
                return
            }
            defer {
                self.discardRegistration(id: id, generation: generation)
            }

            do {
                try await onExit(id, exitStatus)
            } catch {
                self.log?.error("Exit callback for \(id) threw error \(String(describing: error))")
            }
        }
        self.runningTasks[id] = RunningTask(generation: generation, task: task)
    }

    private func callback(id: String, generation: UUID) -> ExitCallback? {
        guard let registration = self.exitCallbacks[id], registration.generation == generation else {
            return nil
        }
        return registration.callback
    }

    private func discardRegistration(id: String, generation: UUID) {
        guard self.exitCallbacks[id]?.generation == generation else {
            return
        }
        self.exitCallbacks.removeValue(forKey: id)
        if self.runningTasks[id]?.generation == generation {
            self.runningTasks.removeValue(forKey: id)
        }
    }
}
