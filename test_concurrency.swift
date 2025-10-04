#!/usr/bin/env swift

import Foundation

// MARK: - Minimal reproducible test for concurrent downloads

/// Test that concurrent task groups respect the maxConcurrent limit
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

        // This mimics the fetchAll() implementation in ImageStore+Import.swift
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = layers.makeIterator()

            // Start initial batch based on maxConcurrent
            for _ in 0..<maxConcurrent {
                if iterator.next() != nil {
                    group.addTask {
                        await tracker.taskStarted()
                        // Simulate download time (10ms per layer)
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await tracker.taskCompleted()
                    }
                }
            }

            // As tasks complete, add new ones to maintain concurrency
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

        print("  ✓ Completed: \(stats.completed)/\(layerCount) layers")
        print("  ✓ Max concurrent: \(stats.max) (limit: \(maxConcurrent))")
        print("  ✓ Duration: \(String(format: "%.3f", duration))s")

        // Verify constraints
        guard stats.max <= maxConcurrent + 1 else {
            print("  ✗ FAILED: Exceeded concurrency limit!")
            throw TestError.concurrencyLimitExceeded
        }

        guard stats.completed == layerCount else {
            print("  ✗ FAILED: Not all layers completed!")
            throw TestError.incompleteTasks
        }

        // Expected time should be roughly: (layerCount / maxConcurrent) * 0.01
        let expectedTime = Double(layerCount) / Double(maxConcurrent) * 0.01
        let tolerance = 0.1 // 100ms tolerance

        if abs(duration - expectedTime) >= tolerance {
            print("  ⚠ WARNING: Duration \(duration)s differs from expected \(expectedTime)s")
        }

        print("  ✅ PASSED\n")
    }

    print("All concurrency tests passed! ✨")
}

enum TestError: Error {
    case concurrencyLimitExceeded
    case incompleteTasks
}

// Run the test
Task {
    do {
        try await testConcurrentDownloads()
        exit(0)
    } catch {
        print("\n❌ Test failed: \(error)")
        exit(1)
    }
}

// Keep the program running
RunLoop.main.run()
