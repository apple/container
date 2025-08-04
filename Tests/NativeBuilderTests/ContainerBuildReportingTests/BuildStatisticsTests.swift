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
import Testing

@testable import ContainerBuildReporting

@Suite("BuildStatistics Tests")
struct BuildStatisticsTests {

    // MARK: - BuildStatistics Tests

    @Test("BuildStatistics initialization with all parameters")
    func testBuildStatisticsInitialization() {
        let startTime = Date()
        let endTime = Date(timeIntervalSinceNow: 5.0)
        let stageStats = ["stage1": StageStatistics(name: "stage1", operationCount: 2)]
        let events = [BuildEvent.buildStarted(totalOperations: 1, stages: 1, timestamp: Date())]

        let stats = BuildStatistics(
            startTime: startTime,
            endTime: endTime,
            success: true,
            totalOperations: 10,
            executedOperations: 8,
            cacheHits: 2,
            failedOperations: 0,
            totalStages: 1,
            stageStatistics: stageStats,
            events: events
        )

        #expect(stats.startTime == startTime)
        #expect(stats.endTime == endTime)
        #expect(stats.success == true)
        #expect(stats.totalOperations == 10)
        #expect(stats.executedOperations == 8)
        #expect(stats.cacheHits == 2)
        #expect(stats.failedOperations == 0)
        #expect(stats.totalStages == 1)
        #expect(stats.stageStatistics.count == 1)
        #expect(stats.events.count == 1)
    }

    @Test("BuildStatistics default initialization")
    func testBuildStatisticsDefaultInitialization() {
        let stats = BuildStatistics()

        #expect(stats.startTime == nil)
        #expect(stats.endTime == nil)
        #expect(stats.success == nil)
        #expect(stats.totalOperations == 0)
        #expect(stats.executedOperations == 0)
        #expect(stats.cacheHits == 0)
        #expect(stats.failedOperations == 0)
        #expect(stats.totalStages == 0)
        #expect(stats.stageStatistics.isEmpty)
        #expect(stats.events.isEmpty)
    }

    @Test("BuildStatistics duration calculation")
    func testBuildStatisticsDurationCalculation() {
        let startTime = Date()
        let endTime = Date(timeInterval: 3.5, since: startTime)

        let stats = BuildStatistics(startTime: startTime, endTime: endTime)

        #expect(abs(stats.duration! - 3.5) < 0.001)
    }

    @Test("BuildStatistics duration with nil start time")
    func testBuildStatisticsDurationWithNilStartTime() {
        let endTime = Date()

        let stats = BuildStatistics(endTime: endTime)

        #expect(stats.duration == nil)
    }

    @Test("BuildStatistics duration with nil end time")
    func testBuildStatisticsDurationWithNilEndTime() {
        let startTime = Date()

        let stats = BuildStatistics(startTime: startTime)

        #expect(stats.duration == nil)
    }

    @Test("BuildStatistics duration with nil times")
    func testBuildStatisticsDurationWithNilTimes() {
        let stats = BuildStatistics()

        #expect(stats.duration == nil)
    }

    @Test("BuildStatistics duration with same start and end time")
    func testBuildStatisticsDurationWithSameStartAndEndTime() {
        let time = Date()

        let stats = BuildStatistics(startTime: time, endTime: time)

        #expect(stats.duration == 0.0)
    }

    @Test("BuildStatistics duration with negative interval")
    func testBuildStatisticsDurationWithNegativeInterval() {
        let endTime = Date()
        let startTime = Date(timeInterval: 1.0, since: endTime)

        let stats = BuildStatistics(startTime: startTime, endTime: endTime)

        #expect(abs(stats.duration! - (-1.0)) < 0.001)
    }

    @Test("BuildStatistics with complex event sequence")
    func testBuildStatisticsWithComplexEventSequence() {
        let startTime = Date()
        let endTime = Date(timeInterval: 10.0, since: startTime)

        let events = [
            BuildEvent.buildStarted(totalOperations: 6, stages: 2, timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage1", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), description: "Operation 1")),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), description: "Operation 2")),
            BuildEvent.operationFailed(context: ReportContext(nodeId: UUID(), description: "Operation 3"), error: BuildEventError(type: .executionFailed, description: "Failed")),
            BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date()),
            BuildEvent.buildCompleted(success: false, timestamp: Date()),
        ]

        let stageStats = [
            "stage1": StageStatistics(name: "stage1", operationCount: 3, cacheHits: 1, failures: 1)
        ]

        let stats = BuildStatistics(
            startTime: startTime,
            endTime: endTime,
            success: false,
            totalOperations: 3,
            executedOperations: 1,
            cacheHits: 1,
            failedOperations: 1,
            totalStages: 1,
            stageStatistics: stageStats,
            events: events
        )

        #expect(abs(stats.duration! - 10.0) < 0.001)
        #expect(stats.success == false)
        #expect(stats.totalOperations == 3)
        #expect(stats.executedOperations == 1)
        #expect(stats.cacheHits == 1)
        #expect(stats.failedOperations == 1)
        #expect(stats.events.count == 8)
        #expect(stats.stageStatistics["stage1"]?.operationCount == 3)
        #expect(stats.stageStatistics["stage1"]?.cacheHits == 1)
        #expect(stats.stageStatistics["stage1"]?.failures == 1)
    }

    @Test("BuildStatistics with multiple stages")
    func testBuildStatisticsWithMultipleStages() {
        let stageStats = [
            "stage1": StageStatistics(name: "stage1", operationCount: 5, cacheHits: 2, failures: 0),
            "stage2": StageStatistics(name: "stage2", operationCount: 3, cacheHits: 1, failures: 1),
            "stage3": StageStatistics(name: "stage3", operationCount: 2, cacheHits: 0, failures: 0),
        ]

        let stats = BuildStatistics(
            totalOperations: 10,
            executedOperations: 7,
            cacheHits: 3,
            failedOperations: 1,
            totalStages: 3,
            stageStatistics: stageStats
        )

        #expect(stats.totalStages == 3)
        #expect(stats.stageStatistics.count == 3)
        #expect(stats.totalOperations == 10)
        #expect(stats.executedOperations == 7)
        #expect(stats.cacheHits == 3)
        #expect(stats.failedOperations == 1)
    }

    @Test("BuildStatistics with large event set")
    func testBuildStatisticsWithLargeEventSet() {
        let eventCount = 10000
        let events = (0..<eventCount).map { index in
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation \(index)"), duration: 1.0)
        }

        let stats = BuildStatistics(
            totalOperations: eventCount,
            executedOperations: eventCount,
            events: events
        )

        #expect(stats.events.count == eventCount)
        #expect(stats.totalOperations == eventCount)
        #expect(stats.executedOperations == eventCount)
    }

    @Test("BuildStatistics with empty stage statistics")
    func testBuildStatisticsWithEmptyStageStatistics() {
        let stats = BuildStatistics(
            totalOperations: 5,
            executedOperations: 5,
            totalStages: 0,
            stageStatistics: [:]
        )

        #expect(stats.totalStages == 0)
        #expect(stats.stageStatistics.isEmpty)
    }

    // MARK: - StageStatistics Tests

    @Test("StageStatistics initialization with all parameters")
    func testStageStatisticsInitialization() {
        let startTime = Date()
        let endTime = Date(timeIntervalSinceNow: 2.0)

        let stageStats = StageStatistics(
            name: "test-stage",
            startTime: startTime,
            endTime: endTime,
            operationCount: 5,
            cacheHits: 2,
            failures: 1
        )

        #expect(stageStats.name == "test-stage")
        #expect(stageStats.startTime == startTime)
        #expect(stageStats.endTime == endTime)
        #expect(stageStats.operationCount == 5)
        #expect(stageStats.cacheHits == 2)
        #expect(stageStats.failures == 1)
    }

    @Test("StageStatistics default initialization")
    func testStageStatisticsDefaultInitialization() {
        let stageStats = StageStatistics(name: "test-stage")

        #expect(stageStats.name == "test-stage")
        #expect(stageStats.startTime == nil)
        #expect(stageStats.endTime == nil)
        #expect(stageStats.operationCount == 0)
        #expect(stageStats.cacheHits == 0)
        #expect(stageStats.failures == 0)
    }

    @Test("StageStatistics duration calculation")
    func testStageStatisticsDurationCalculation() {
        let startTime = Date()
        let endTime = Date(timeInterval: 1.5, since: startTime)

        let stageStats = StageStatistics(name: "test-stage", startTime: startTime, endTime: endTime)

        #expect(abs(stageStats.duration! - 1.5) < 0.001)
    }

    @Test("StageStatistics duration with nil start time")
    func testStageStatisticsDurationWithNilStartTime() {
        let endTime = Date()

        let stageStats = StageStatistics(name: "test-stage", endTime: endTime)

        #expect(stageStats.duration == nil)
    }

    @Test("StageStatistics duration with nil end time")
    func testStageStatisticsDurationWithNilEndTime() {
        let startTime = Date()

        let stageStats = StageStatistics(name: "test-stage", startTime: startTime)

        #expect(stageStats.duration == nil)
    }

    @Test("StageStatistics duration with nil times")
    func testStageStatisticsDurationWithNilTimes() {
        let stageStats = StageStatistics(name: "test-stage")

        #expect(stageStats.duration == nil)
    }

    @Test("StageStatistics duration with same start and end time")
    func testStageStatisticsDurationWithSameStartAndEndTime() {
        let time = Date()

        let stageStats = StageStatistics(name: "test-stage", startTime: time, endTime: time)

        #expect(stageStats.duration == 0.0)
    }

    @Test("StageStatistics duration with negative interval")
    func testStageStatisticsDurationWithNegativeInterval() {
        let endTime = Date()
        let startTime = Date(timeInterval: 0.5, since: endTime)

        let stageStats = StageStatistics(name: "test-stage", startTime: startTime, endTime: endTime)

        #expect(abs(stageStats.duration! - (-0.5)) < 0.001)
    }

    @Test("StageStatistics with empty name")
    func testStageStatisticsWithEmptyName() {
        let stageStats = StageStatistics(name: "")

        #expect(stageStats.name == "")
    }

    @Test("StageStatistics with special characters in name")
    func testStageStatisticsWithSpecialCharactersInName() {
        let name = "test-stage!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let stageStats = StageStatistics(name: name)

        #expect(stageStats.name == name)
    }

    @Test("StageStatistics with unicode characters in name")
    func testStageStatisticsWithUnicodeCharactersInName() {
        let name = "测试阶段-🚀-étape-тест"
        let stageStats = StageStatistics(name: name)

        #expect(stageStats.name == name)
    }

    @Test("StageStatistics with zero operations")
    func testStageStatisticsWithZeroOperations() {
        let stageStats = StageStatistics(name: "empty-stage", operationCount: 0, cacheHits: 0, failures: 0)

        #expect(stageStats.operationCount == 0)
        #expect(stageStats.cacheHits == 0)
        #expect(stageStats.failures == 0)
    }

    @Test("StageStatistics with high operation counts")
    func testStageStatisticsWithHighOperationCounts() {
        let stageStats = StageStatistics(name: "large-stage", operationCount: 10000, cacheHits: 5000, failures: 100)

        #expect(stageStats.operationCount == 10000)
        #expect(stageStats.cacheHits == 5000)
        #expect(stageStats.failures == 100)
    }

    @Test("StageStatistics with all cache hits")
    func testStageStatisticsWithAllCacheHits() {
        let stageStats = StageStatistics(name: "cached-stage", operationCount: 10, cacheHits: 10, failures: 0)

        #expect(stageStats.operationCount == 10)
        #expect(stageStats.cacheHits == 10)
        #expect(stageStats.failures == 0)
    }

    @Test("StageStatistics with all failures")
    func testStageStatisticsWithAllFailures() {
        let stageStats = StageStatistics(name: "failed-stage", operationCount: 5, cacheHits: 0, failures: 5)

        #expect(stageStats.operationCount == 5)
        #expect(stageStats.cacheHits == 0)
        #expect(stageStats.failures == 5)
    }

    // MARK: - Edge Cases and Performance Tests

    @Test("BuildStatistics with extremely long duration")
    func testBuildStatisticsWithExtremelyLongDuration() {
        let startTime = Date(timeIntervalSince1970: 0)
        let endTime = Date()

        let stats = BuildStatistics(startTime: startTime, endTime: endTime)

        #expect(stats.duration != nil)
        #expect(stats.duration! > 0)
    }

    @Test("BuildStatistics with very short duration")
    func testBuildStatisticsWithVeryShortDuration() {
        let startTime = Date()
        let endTime = Date(timeInterval: 0.001, since: startTime)

        let stats = BuildStatistics(startTime: startTime, endTime: endTime)

        #expect(abs(stats.duration! - 0.001) < 0.0001)
    }

    @Test("BuildStatistics memory usage with large data set")
    func testBuildStatisticsMemoryUsageWithLargeDataSet() {
        let eventCount = 100000
        let stageCount = 1000

        let events = (0..<eventCount).map { index in
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation \(index)"), duration: 1.0)
        }

        let stageStats = Dictionary(
            uniqueKeysWithValues: (0..<stageCount).map { index in
                ("stage\(index)", StageStatistics(name: "stage\(index)", operationCount: eventCount / stageCount))
            })

        let stats = BuildStatistics(
            totalOperations: eventCount,
            executedOperations: eventCount,
            totalStages: stageCount,
            stageStatistics: stageStats,
            events: events
        )

        #expect(stats.events.count == eventCount)
        #expect(stats.stageStatistics.count == stageCount)
        #expect(stats.totalOperations == eventCount)
        #expect(stats.totalStages == stageCount)
    }

    @Test("BuildStatistics thread safety")
    func testBuildStatisticsThreadSafety() async {
        let events = [
            BuildEvent.buildStarted(totalOperations: 6, stages: 2, timestamp: Date()),
            BuildEvent.buildCompleted(success: false, timestamp: Date()),
        ]

        let stageStats = [
            "stage1": StageStatistics(name: "stage1", operationCount: 1)
        ]

        let stats = BuildStatistics(
            totalOperations: 1,
            executedOperations: 1,
            totalStages: 1,
            stageStatistics: stageStats,
            events: events
        )

        // Test concurrent access to statistics properties using TaskGroup
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = stats.duration
                    _ = stats.success
                    _ = stats.totalOperations
                    _ = stats.events.count
                    _ = stats.stageStatistics.count
                }
            }
        }

        // If we reach here without crashes, the thread safety test passed
        #expect(stats.totalOperations == 1)
    }
}
