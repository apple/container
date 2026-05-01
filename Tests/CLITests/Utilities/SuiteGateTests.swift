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

/// Helper actor that tracks how many callers are active simultaneously.
actor ConcurrencyTracker {
    private var current = 0
    private var peak = 0

    func enterAndGetCount() -> Int {
        current += 1
        if current > peak { peak = current }
        return current
    }

    func leave() {
        current -= 1
    }

    func peakConcurrency() -> Int {
        peak
    }
}

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

/// Helper actor that records the order in which tasks complete.
private actor CompletionRecorder {
    private var order: [Int] = []

    func record(_ id: Int) {
        order.append(id)
    }

    func completedCount() -> Int {
        order.count
    }
}

@Suite struct SuiteGateTests {
    @Test func mutualExclusion() async {
        let gate = SuiteGate()
        let tracker = ConcurrencyTracker()
        let barrier = Barrier(count: 5)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    // Barrier ensures all 5 tasks are live before any enters the gate
                    await barrier.arriveAndWait()
                    await gate.enter()
                    let count = await tracker.enterAndGetCount()
                    #expect(count == 1, "Only 1 task should be inside the gate at a time")
                    await tracker.leave()
                    await gate.leave()
                }
            }
        }
    }

    @Test func multipleWaiters() async {
        let gate = SuiteGate()
        let recorder = CompletionRecorder()
        let barrier = Barrier(count: 3)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    await barrier.arriveAndWait()
                    await gate.enter()
                    await recorder.record(i)
                    await gate.leave()
                }
            }
        }

        let count = await recorder.completedCount()
        #expect(count == 3, "All 3 tasks should have completed")
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
