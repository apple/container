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

/// Statistics collected during a build execution.
public struct BuildStatistics: Sendable {
    /// When the build started
    public let startTime: Date?

    /// When the build completed
    public let endTime: Date?

    /// Total build duration
    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Whether the build succeeded
    public let success: Bool?

    /// Total number of operations
    public let totalOperations: Int

    /// Number of operations executed
    public let executedOperations: Int

    /// Number of cache hits
    public let cacheHits: Int

    /// Number of failed operations
    public let failedOperations: Int

    /// Number of stages
    public let totalStages: Int

    /// Per-stage statistics
    public let stageStatistics: [String: StageStatistics]

    /// All events that occurred during the build
    public let events: [BuildEvent]

    public init(
        startTime: Date? = nil,
        endTime: Date? = nil,
        success: Bool? = nil,
        totalOperations: Int = 0,
        executedOperations: Int = 0,
        cacheHits: Int = 0,
        failedOperations: Int = 0,
        totalStages: Int = 0,
        stageStatistics: [String: StageStatistics] = [:],
        events: [BuildEvent] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.success = success
        self.totalOperations = totalOperations
        self.executedOperations = executedOperations
        self.cacheHits = cacheHits
        self.failedOperations = failedOperations
        self.totalStages = totalStages
        self.stageStatistics = stageStatistics
        self.events = events
    }
}

/// Statistics for a single build stage.
public struct StageStatistics: Sendable {
    /// Stage name
    public let name: String

    /// When the stage started
    public let startTime: Date?

    /// When the stage completed
    public let endTime: Date?

    /// Stage duration
    public var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Number of operations in this stage
    public let operationCount: Int

    /// Number of cache hits in this stage
    public let cacheHits: Int

    /// Number of failures in this stage
    public let failures: Int

    public init(
        name: String,
        startTime: Date? = nil,
        endTime: Date? = nil,
        operationCount: Int = 0,
        cacheHits: Int = 0,
        failures: Int = 0
    ) {
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.operationCount = operationCount
        self.cacheHits = cacheHits
        self.failures = failures
    }
}
