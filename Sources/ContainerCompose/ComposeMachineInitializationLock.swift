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

import ContainerizationError
import Darwin
import Foundation

/// Serializes first-use Compose machine initialization across plugin processes.
final class ComposeMachineInitializationLock: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var isReleased = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
    }

    static func acquire(
        appRoot: URL,
        retryInterval: Duration = .milliseconds(100)
    ) async throws -> ComposeMachineInitializationLock {
        let directory = appRoot.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("compose-machine-init.lock")
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "failed to open Compose machine initialization lock: \(String(cString: strerror(errno)))"
            )
        }

        let lock = ComposeMachineInitializationLock(descriptor: descriptor)
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to acquire Compose machine initialization lock: \(String(cString: strerror(errno)))"
                    )
                }
                do {
                    try await Task.sleep(for: retryInterval)
                } catch is CancellationError {
                    throw CancellationError()
                }
            }
        } catch {
            lock.release()
            throw error
        }
        return lock
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isReleased else { return }
        isReleased = true
        _ = flock(descriptor, LOCK_UN)
    }
}
