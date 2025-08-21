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

/// Base implementation for progress consumers that provides common statistics tracking.
///
/// This class handles:
/// - Event accumulation
/// - Statistics calculation
/// - Thread-safe state management
///
/// Subclasses should override `formatEvent` to provide custom output formatting.
open class BaseProgressConsumer<Configuration: Sendable>: ProgressConsumer, @unchecked Sendable {
    public let configuration: Configuration
    private let lock = NSLock()

    // Statistics tracking
    private var accumulatedEvents: [BuildEvent] = []
    private var buildStartTime: Date?
    private var buildEndTime: Date?
    private var buildSuccess: Bool?
    private var totalOperationCount = 0
    private var executedOperationCount = 0
    private var cacheHitCount = 0
    private var failedOperationCount = 0
    private var stageStats: [String: MutableStageStats] = [:]

    private struct MutableStageStats {
        var name: String
        var startTime: Date?
        var endTime: Date?
        var operationCount = 0
        var cacheHits = 0
        var failures = 0
    }

    public required init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func consume(reporter: Reporter) async throws {
        for await event in reporter.stream {
            try await handle(event)
        }
    }

    public func handle(_ event: BuildEvent) async throws {
        // Store event and update statistics
        lock.withLock {
            accumulatedEvents.append(event)
            updateStatistics(event)
        }

        // Let subclass format the output
        try await formatAndOutput(event)
    }

    /// Subclasses must implement this to format and output events.
    open func formatAndOutput(_ event: BuildEvent) async throws {
        fatalError("Subclasses must implement formatAndOutput(_:)")
    }

    public func getStatistics() -> BuildStatistics {
        lock.withLock {
            let stageStatistics = stageStats.mapValues { stats in
                StageStatistics(
                    name: stats.name,
                    startTime: stats.startTime,
                    endTime: stats.endTime,
                    operationCount: stats.operationCount,
                    cacheHits: stats.cacheHits,
                    failures: stats.failures
                )
            }

            return BuildStatistics(
                startTime: buildStartTime,
                endTime: buildEndTime,
                success: buildSuccess,
                totalOperations: totalOperationCount,
                executedOperations: executedOperationCount,
                cacheHits: cacheHitCount,
                failedOperations: failedOperationCount,
                totalStages: stageStats.count,
                stageStatistics: stageStatistics,
                events: accumulatedEvents
            )
        }
    }

    public func getEvents() -> [BuildEvent] {
        lock.withLock {
            accumulatedEvents
        }
    }

    private func updateStatistics(_ event: BuildEvent) {
        switch event {
        case .buildStarted(let totalOps, _, let timestamp):
            buildStartTime = timestamp
            totalOperationCount = totalOps

        case .buildCompleted(let success, let timestamp):
            buildEndTime = timestamp
            buildSuccess = success

        case .stageStarted(let stageName, let timestamp):
            if stageStats[stageName] == nil {
                stageStats[stageName] = MutableStageStats(name: stageName)
            }
            stageStats[stageName]?.startTime = timestamp

        case .stageCompleted(let stageName, let timestamp):
            if stageStats[stageName] == nil {
                stageStats[stageName] = MutableStageStats(name: stageName)
            }
            stageStats[stageName]?.endTime = timestamp

        case .operationStarted(let context):
            if let stage = context.stageId {
                if stageStats[stage] == nil {
                    stageStats[stage] = MutableStageStats(name: stage)
                }
                stageStats[stage]?.operationCount += 1
            }

        case .operationFinished:
            executedOperationCount += 1

        case .operationFailed(let context, _):
            failedOperationCount += 1
            if let stage = context.stageId {
                if stageStats[stage] == nil {
                    stageStats[stage] = MutableStageStats(name: stage)
                }
                stageStats[stage]?.failures += 1
            }

        case .operationCacheHit(let context):
            cacheHitCount += 1
            if let stage = context.stageId {
                if stageStats[stage] == nil {
                    stageStats[stage] = MutableStageStats(name: stage)
                }
                stageStats[stage]?.cacheHits += 1
            }

        case .operationProgress, .operationLog:
            break  // These don't affect statistics

        case .irEvent(_, _):
            // Track IR events if needed in the future
            break
        }
    }
}

// Helper extension for thread-safe lock usage
extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
