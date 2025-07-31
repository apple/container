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

import Foundation

/// `AsyncLock` provides cooperative async locking for serialized access to critical sections.
/// This is particularly useful for atomic updates to cache.json and other shared resources.
public actor AsyncLock {
    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<Void, Never>> = []

    public init() {}

    /// Executes the given async closure while holding the lock, ensuring serialized access.
    /// - Parameter body: The async closure to execute while holding the lock.
    /// - Returns: The result of the closure execution.
    /// - Throws: Any error thrown by the closure.
    public func withLock<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        // Wait if the lock is currently held
        while busy {
            await withCheckedContinuation { continuation in
                queue.append(continuation)
            }
        }

        // Acquire the lock
        busy = true

        // Ensure we release the lock and wake up the next waiter
        defer {
            busy = false
            if let next = queue.popFirst() {
                next.resume()
            } else {
                // Clear the queue if empty to avoid potential memory growth
                queue = []
            }
        }

        // Execute the critical section
        return try await body()
    }
}
