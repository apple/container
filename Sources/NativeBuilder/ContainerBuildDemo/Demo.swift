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

import ContainerBuildCache
import ContainerBuildExecutor
import ContainerBuildIR
import ContainerBuildReporting
import ContainerBuildSnapshotter
import Foundation

/// A simple demonstration of the build execution system.
public struct Demo {
    public static func runDemo() async throws {
        // Set up the build environment first
        let snapshotter = MemorySnapshotter()
        let cache = MemoryBuildCache()
        let reporter = Reporter()

        // Create a build graph with parallel operations, passing the reporter
        let graph = try IRExample.createParallelBuild(reporter: reporter)
        let config = Scheduler.Configuration(
            maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
            failFast: true,
            enableProgressReporting: true
        )
        let executor = Scheduler(
            snapshotter: snapshotter,
            cache: cache,
            reporter: reporter,
            configuration: config
        )

        // Create progress consumer
        let consumer = PlainProgressConsumer(
            configuration: .init()
        )

        // Start progress monitoring task
        let progressTask = Task {
            try await consumer.consume(reporter: reporter)
        }

        // Register completion handler to wait for progress task
        executor.onCompletion {
            try? await progressTask.value
        }

        // Execute the build - this will wait for progress to complete before returning
        _ = try await executor.execute(graph)

        // Get build statistics
        let stats = consumer.getStatistics()

        // Print build summary based on statistics
        if let duration = stats.duration {
            if stats.success == true {
                print("\nBuild completed successfully in \(String(format: "%.2f", duration))s")
                // print("  Total operations: \(stats.totalOperations)")
                // print("  Cache hits: \(stats.cacheHits)")
                // print("  Executed: \(stats.executedOperations)")
            } else {
                print("\nBuild failed after \(String(format: "%.2f", duration))s")
                // print("  Failed operations: \(stats.failedOperations)")
            }
        }
    }

}
