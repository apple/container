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

/// Async semaphore with capacity 1. Used by SerialSuiteTrait to ensure only one
/// integration test suite executes at a time.
actor SuiteGate {
    static let shared = SuiteGate()

    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // Must remain synchronous (non-async body). This guarantees the call
    // completes even if the calling task is cancelled, because actor hops
    // for synchronous methods are not cancellation points.
    func leave() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isOccupied = false
        }
    }
}
