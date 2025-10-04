#!/usr/bin/env swift

import Foundation

func testConcurrentDownloads() async throws {
    print("Testing concurrent download behavior...\n")

    // Track concurrent task count
    actor ConcurrencyTracker {
        var currentCount = 0
        var maxObservedCount = 0
        var completedTasks = 0

        func taskStarted() {
            currentCount += 1
            maxObservedCount = max(maxObservedCount, currentCount)
        }

        func taskCompleted() {
            currentCount -= 1
            completedTasks += 1
        }

        func getStats() -> (max: Int, completed: Int) {
            return (maxObservedCount, completedTasks)
        }

        func reset() {
            currentCount = 0
            maxObservedCount = 0
            completedTasks = 0
        }
    }

    let tracker = ConcurrencyTracker()

    // Test with different concurrency limits
    for maxConcurrent in [1, 3, 6] {
        await tracker.reset()

        // Simulate downloading 20 layers
        let layerCount = 20
        let layers = Array(0..<layerCount)

        print("Testing maxConcurrent=\(maxConcurrent) with \(layerCount) layers...")

        let startTime = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = layers.makeIterator()

            // Start initial batch based on maxConcurrent
            for _ in 0..<maxConcurrent {
                if iterator.next() != nil {
                    group.addTask {
                        await tracker.taskStarted()
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await tracker.taskCompleted()
                    }
                }
            }
            for try await _ in group {
                if iterator.next() != nil {
                    group.addTask {
                        await tracker.taskStarted()
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await tracker.taskCompleted()
                    }
                }
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        let stats = await tracker.getStats()

        print("  ✓ Completed: \(stats.completed)/\(layerCount)")
        print("  ✓ Max concurrent: \(stats.max)")
        print("  ✓ Duration: \(String(format: "%.3f", duration))s")

        guard stats.max <= maxConcurrent + 1 else {
            throw TestError.concurrencyLimitExceeded
        }

        guard stats.completed == layerCount else {
            throw TestError.incompleteTasks
        }

        print("  ✅ PASSED\n")
    }

    print("All tests passed!")
}

enum TestError: Error {
    case concurrencyLimitExceeded
    case incompleteTasks
}

Task {
    do {
        try await testConcurrentDownloads()
        exit(0)
    } catch {
        print("Test failed: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
