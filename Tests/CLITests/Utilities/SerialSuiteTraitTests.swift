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

import Testing

/// Async countdown latch. N callers suspend on arriveAndWait(); the Nth arrival
/// resumes them all simultaneously, proving they were running concurrently.
actor Barrier {
    private let count: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.count = count
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= count {
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Verifies that tests within a `.serialSuites`-annotated suite still run in parallel.
/// All 3 tests rendezvous at a shared barrier. If they run concurrently, the barrier
/// opens and tests pass instantly. If serialized, the first test deadlocks waiting for
/// the others and the time limit fails the suite.
@Suite(.serialSuites, .timeLimit(.minutes(1)))
struct InnerParallelismTests {
    static let barrier = Barrier(count: 3)

    @Test func parallelA() async {
        await Self.barrier.arriveAndWait()
    }

    @Test func parallelB() async {
        await Self.barrier.arriveAndWait()
    }

    @Test func parallelC() async {
        await Self.barrier.arriveAndWait()
    }
}
