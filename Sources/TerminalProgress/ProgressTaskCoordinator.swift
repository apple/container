//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// A type that represents a task whose progress is being monitored.
public struct ProgressTask: Sendable, Equatable {
    private var id = UUID()
    private var coordinator: ProgressTaskCoordinator

    init(manager: ProgressTaskCoordinator) {
        self.coordinator = manager
    }

    static public func == (lhs: ProgressTask, rhs: ProgressTask) -> Bool {
        lhs.id == rhs.id
    }

    /// Returns `true` if this task is the currently active task, `false` otherwise.
    public func isCurrent() async -> Bool {
        guard let currentTask = await coordinator.currentTask else {
            return false
        }
        return currentTask == self
    }
}

/// A type that coordinates progress tasks to ignore updates from completed tasks.
public actor ProgressTaskCoordinator {
    var currentTask: ProgressTask?

    /// Creates an instance of `ProgressTaskCoordinator`.
    public init() {}

    /// Returns a new task that should be monitored for progress updates.
    public func startTask() -> ProgressTask {
        let newTask = ProgressTask(manager: self)
        currentTask = newTask
        return newTask
    }

    /// Performs cleanup when the monitored tasks complete.
    public func finish() {
        currentTask = nil
    }

    /// Returns a handler that updates the progress of a given task.
    /// - Parameters:
    ///   - task: The task whose progress is being updated.
    ///   - progressUpdate: The handler to invoke when progress updates are received.
    public static func handler(for task: ProgressTask, from progressUpdate: @escaping ProgressUpdateHandler) -> ProgressUpdateHandler {
        { events in
            // Ignore updates from completed tasks.
            if await task.isCurrent() {
                await progressUpdate(events)
            }
        }
    }
}
