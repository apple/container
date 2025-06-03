//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

//

import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

/// Track when a long running method exits, and notify the caller via a callback.
public actor ExitMonitor {
    public typealias ExitCallback = @Sendable (String, Int32) async throws -> Void
    public typealias WaitHandler = @Sendable () async throws -> Int32

    public init(log: Logger? = nil) {
        self.log = log
    }

    private var exitCallbacks: [String: ExitCallback] = [:]
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private let log: Logger?

    public func stopTracking(id: String) async {
        if let task = self.runningTasks[id] {
            task.cancel()
        }
        exitCallbacks.removeValue(forKey: id)
        runningTasks.removeValue(forKey: id)
    }

    public func registerProcess(id: String, onExit: @escaping ExitCallback) async throws {
        guard self.exitCallbacks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor already setup for process \(id)")
        }
        self.exitCallbacks[id] = onExit
    }

    public func track(id: String, waitingOn: @escaping WaitHandler) async throws {
        guard let onExit = self.exitCallbacks[id] else {
            throw ContainerizationError(.invalidState, message: "ExitMonitor not setup for process \(id)")
        }
        guard self.runningTasks[id] == nil else {
            throw ContainerizationError(.invalidState, message: "Already have a running task tracking process \(id)")
        }
        self.runningTasks[id] = Task {
            do {
                let exitStatus = try await waitingOn()
                try await onExit(id, exitStatus)
            } catch {
                self.log?.error("WaitHandler for \(id) threw error \(String(describing: error))")
                try? await onExit(id, -1)
            }
        }
    }
}
