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

@Suite
struct BaseProgressConsumerTests {

    // MARK: - Test Configuration

    struct TestConfiguration: Sendable {
        let name: String
        let bufferSize: Int

        init(name: String = "test", bufferSize: Int = 100) {
            self.name = name
            self.bufferSize = bufferSize
        }
    }

    // Test concrete implementation of BaseProgressConsumer
    @MainActor
    final class TestProgressConsumer: BaseProgressConsumer<TestConfiguration>, @unchecked Sendable {
        private var formattedEvents: [String] = []

        override func formatAndOutput(_ event: BuildEvent) async throws {
            formattedEvents.append("Formatted: \(event)")
        }

        func getFormattedEvents() -> [String] {
            formattedEvents
        }

        func clearFormattedEvents() {
            formattedEvents.removeAll()
        }
    }

    // MARK: - Initialization Tests

    @Test("Initialization with configuration")
    @MainActor
    func initializationWithConfiguration() {
        let config = TestConfiguration(name: "test-consumer", bufferSize: 200)
        let consumer = TestProgressConsumer(configuration: config)

        #expect(consumer.configuration.name == "test-consumer")
        #expect(consumer.configuration.bufferSize == 200)
        #expect(consumer.getEvents().isEmpty)
        #expect(consumer.getFormattedEvents().isEmpty)
    }

    @Test("Initialization with default configuration")
    @MainActor
    func initializationWithDefaultConfiguration() {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        #expect(consumer.configuration.name == "test")
        #expect(consumer.configuration.bufferSize == 100)
        #expect(consumer.getEvents().isEmpty)
    }

    // MARK: - Event Handling Tests

    @Test("Handles build started event")
    @MainActor
    func handlesBuildStartedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.buildStarted(totalOperations: 10, stages: 1, timestamp: Date())

        try await consumer.handle(event)

        let events = consumer.getEvents()
        #expect(events.count == 1)

        let statistics = consumer.getStatistics()
        #expect(statistics.startTime != nil)
        #expect(statistics.totalOperations == 10)
        #expect(statistics.endTime == nil)
        #expect(statistics.success == nil)
    }

    @Test("Handles build completed event")
    @MainActor
    func handlesBuildCompletedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.buildCompleted(success: true, timestamp: Date())

        try await consumer.handle(event)

        let events = consumer.getEvents()
        #expect(events.count == 1)

        let statistics = consumer.getStatistics()
        #expect(statistics.endTime != nil)
        #expect(statistics.success == true)
    }

    @Test("Handles stage started event")
    @MainActor
    func handlesStageStartedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.stageStarted(stageName: "stage1", timestamp: Date())

        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.totalStages == 1)
        #expect(statistics.stageStatistics["stage1"] != nil)
        #expect(statistics.stageStatistics["stage1"]?.startTime != nil)
        #expect(statistics.stageStatistics["stage1"]?.endTime == nil)
    }

    @Test("Handles stage completed event")
    @MainActor
    func handlesStageCompletedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Start stage first
        let startEvent = BuildEvent.stageStarted(stageName: "stage1", timestamp: Date())
        try await consumer.handle(startEvent)

        // Complete stage
        let completeEvent = BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date())
        try await consumer.handle(completeEvent)

        let statistics = consumer.getStatistics()
        #expect(statistics.totalStages == 1)
        #expect(statistics.stageStatistics["stage1"]?.startTime != nil)
        #expect(statistics.stageStatistics["stage1"]?.endTime != nil)
    }

    @Test("Handles operation started event")
    @MainActor
    func handlesOperationStartedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let context = ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 1")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.stageStatistics["stage1"]?.operationCount == 1)
        #expect(statistics.stageStatistics["stage1"]?.cacheHits == 0)
        #expect(statistics.stageStatistics["stage1"]?.failures == 0)
    }

    @Test("Handles operation finished event")
    @MainActor
    func handlesOperationFinishedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0)

        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == 1)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.cacheHits == 0)
    }

    @Test("Handles operation failed event")
    @MainActor
    func handlesOperationFailedEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let context = ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 1")
        let error = BuildEventError(type: .executionFailed, description: "Test failure")
        let event = BuildEvent.operationFailed(context: context, error: error)

        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.failedOperations == 1)
        #expect(statistics.executedOperations == 0)
        #expect(statistics.stageStatistics["stage1"]?.failures == 1)
    }

    @Test("Handles operation cache hit event")
    @MainActor
    func handlesOperationCacheHitEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let context = ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 1")
        let event = BuildEvent.operationCacheHit(context: context)

        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.cacheHits == 1)
        #expect(statistics.stageStatistics["stage1"]?.cacheHits == 1)
    }

    @Test("Handles operation progress event")
    @MainActor
    func handlesOperationProgressEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.operationProgress(context: ReportContext(nodeId: UUID(), description: "Operation 1"), fraction: 0.5)

        try await consumer.handle(event)

        let events = consumer.getEvents()
        #expect(events.count == 1)

        // Progress events don't affect statistics
        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == 0)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.cacheHits == 0)
    }

    @Test("Handles operation log event")
    @MainActor
    func handlesOperationLogEvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.operationLog(context: ReportContext(nodeId: UUID(), description: "Operation 1"), message: "Log message")

        try await consumer.handle(event)

        let events = consumer.getEvents()
        #expect(events.count == 1)

        // Log events don't affect statistics
        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == 0)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.cacheHits == 0)
    }

    @Test("Handles IR event")
    @MainActor
    func handlesIREvent() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "IR event"), type: .graphStarted)

        try await consumer.handle(event)

        let events = consumer.getEvents()
        #expect(events.count == 1)

        // IR events don't affect statistics
        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == 0)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.cacheHits == 0)
    }

    // MARK: - Statistics Accumulation Tests

    @Test("Statistics accumulation with complex sequence")
    @MainActor
    func statisticsAccumulationWithComplexSequence() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Build sequence: start -> 2 stages -> multiple operations -> complete
        let events = [
            BuildEvent.buildStarted(totalOperations: 6, stages: 2, timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage1", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 1")),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 1"), duration: 1.0),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 2")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 2")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 3")),
            BuildEvent.operationFailed(
                context: ReportContext(nodeId: UUID(), stageId: "stage1", description: "Operation 3"), error: BuildEventError(type: .executionFailed, description: "Failed")),
            BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage2", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 4")),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 4"), duration: 1.0),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 5")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 5")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 6")),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), stageId: "stage2", description: "Operation 6"), duration: 1.0),
            BuildEvent.stageCompleted(stageName: "stage2", timestamp: Date()),
            BuildEvent.buildCompleted(success: false, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        let statistics = consumer.getStatistics()

        // Verify build-level statistics
        #expect(statistics.totalOperations == 6)
        #expect(statistics.executedOperations == 3)  // op1, op4, op6
        #expect(statistics.cacheHits == 2)  // op2, op5
        #expect(statistics.failedOperations == 1)  // op3
        #expect(statistics.success == false)
        #expect(statistics.totalStages == 2)
        #expect(statistics.startTime != nil)
        #expect(statistics.endTime != nil)
        #expect(statistics.events.count == 18)

        // Verify stage1 statistics
        let stage1Stats = statistics.stageStatistics["stage1"]
        #expect(stage1Stats != nil)
        #expect(stage1Stats?.operationCount == 3)
        #expect(stage1Stats?.cacheHits == 1)
        #expect(stage1Stats?.failures == 1)
        #expect(stage1Stats?.startTime != nil)
        #expect(stage1Stats?.endTime != nil)

        // Verify stage2 statistics
        let stage2Stats = statistics.stageStatistics["stage2"]
        #expect(stage2Stats != nil)
        #expect(stage2Stats?.operationCount == 3)
        #expect(stage2Stats?.cacheHits == 1)
        #expect(stage2Stats?.failures == 0)
        #expect(stage2Stats?.startTime != nil)
        #expect(stage2Stats?.endTime != nil)
    }

    @Test("Statistics with multiple stages")
    @MainActor
    func statisticsWithMultipleStages() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Create multiple stages with different characteristics
        let stages = [
            ("stage1", 5, 2, 1),  // 5 ops, 2 cache hits, 1 failure
            ("stage2", 3, 1, 0),  // 3 ops, 1 cache hit, 0 failures
            ("stage3", 2, 0, 2),  // 2 ops, 0 cache hits, 2 failures
            ("stage4", 1, 1, 0),  // 1 op, 1 cache hit, 0 failures
        ]

        for (stageName, opCount, cacheHits, failures) in stages {
            let stageStartEvent = BuildEvent.stageStarted(stageName: stageName, timestamp: Date())
            try await consumer.handle(stageStartEvent)

            // Add operations
            for i in 0..<opCount {
                let opStartEvent = BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), stageId: stageName, description: "Operation \(i)"))
                try await consumer.handle(opStartEvent)
            }

            // Add cache hits
            for i in 0..<cacheHits {
                let cacheHitEvent = BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), stageId: stageName, description: "Cache hit \(i)"))
                try await consumer.handle(cacheHitEvent)
            }

            // Add failures
            for i in 0..<failures {
                let failureEvent = BuildEvent.operationFailed(
                    context: ReportContext(nodeId: UUID(), stageId: stageName, description: "Failure \(i)"),
                    error: BuildEventError(type: .executionFailed, description: "Test failure"))
                try await consumer.handle(failureEvent)
            }

            let stageEndEvent = BuildEvent.stageCompleted(stageName: stageName, timestamp: Date())
            try await consumer.handle(stageEndEvent)
        }

        let statistics = consumer.getStatistics()

        // Verify overall statistics
        #expect(statistics.totalStages == 4)
        #expect(statistics.cacheHits == 4)  // 2 + 1 + 0 + 1
        #expect(statistics.failedOperations == 3)  // 1 + 0 + 2 + 0

        // Verify individual stage statistics
        #expect(statistics.stageStatistics["stage1"]?.operationCount == 5)
        #expect(statistics.stageStatistics["stage1"]?.cacheHits == 2)
        #expect(statistics.stageStatistics["stage1"]?.failures == 1)

        #expect(statistics.stageStatistics["stage2"]?.operationCount == 3)
        #expect(statistics.stageStatistics["stage2"]?.cacheHits == 1)
        #expect(statistics.stageStatistics["stage2"]?.failures == 0)

        #expect(statistics.stageStatistics["stage3"]?.operationCount == 2)
        #expect(statistics.stageStatistics["stage3"]?.cacheHits == 0)
        #expect(statistics.stageStatistics["stage3"]?.failures == 2)

        #expect(statistics.stageStatistics["stage4"]?.operationCount == 1)
        #expect(statistics.stageStatistics["stage4"]?.cacheHits == 1)
        #expect(statistics.stageStatistics["stage4"]?.failures == 0)
    }

    // MARK: - Thread Safety Tests

    @Test("Thread safety with concurrent event handling")
    @MainActor
    func threadSafetyWithConcurrentEventHandling() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let eventCount = 1000

        // Create events to handle concurrently
        let events = (0..<eventCount).map { index in
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation \(index)"), duration: 1.0)
        }

        // Handle events concurrently
        await withThrowingTaskGroup(of: Void.self) { group in
            for event in events {
                group.addTask {
                    try await consumer.handle(event)
                }
            }
        }

        let statistics = consumer.getStatistics()
        let storedEvents = consumer.getEvents()

        #expect(storedEvents.count == eventCount)
        #expect(statistics.executedOperations == eventCount)
        #expect(statistics.events.count == eventCount)
    }

    @Test("Thread safety with concurrent statistics access")
    @MainActor
    func threadSafetyWithConcurrentStatisticsAccess() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Add some initial events
        let events = [
            BuildEvent.buildStarted(totalOperations: 100, stages: 1, timestamp: Date()),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), description: "Operation 2")),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        // Test concurrent access to statistics
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = consumer.getStatistics()
                    _ = consumer.getEvents()
                }
            }
        }

        // Verify statistics are still consistent
        let finalStatistics = consumer.getStatistics()
        #expect(finalStatistics.totalOperations == 100)
        #expect(finalStatistics.executedOperations == 1)
        #expect(finalStatistics.cacheHits == 1)
        #expect(finalStatistics.success == true)
    }

    // MARK: - Event Storage Tests

    @Test("Event storage and retrieval")
    @MainActor
    func eventStorageAndRetrieval() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        let events = [
            BuildEvent.buildStarted(totalOperations: 2, stages: 1, timestamp: Date()),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 2"), duration: 1.0),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        let storedEvents = consumer.getEvents()
        #expect(storedEvents.count == 4)

        // Verify event order is preserved
        guard case .buildStarted = storedEvents[0] else {
            Issue.record("First event should be buildStarted")
            return
        }

        guard case .operationFinished = storedEvents[1] else {
            Issue.record("Second event should be operationFinished")
            return
        }

        guard case .operationFinished = storedEvents[2] else {
            Issue.record("Third event should be operationFinished")
            return
        }

        guard case .buildCompleted = storedEvents[3] else {
            Issue.record("Fourth event should be buildCompleted")
            return
        }
    }

    @Test("Event storage with large data set")
    @MainActor
    func eventStorageWithLargeDataSet() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let eventCount = 50000

        let events = (0..<eventCount).map { index in
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation \(index)"), duration: 1.0)
        }

        for event in events {
            try await consumer.handle(event)
        }

        let storedEvents = consumer.getEvents()
        #expect(storedEvents.count == eventCount)

        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == eventCount)
        #expect(statistics.events.count == eventCount)
    }

    // MARK: - Format Output Tests

    @Test("Format and output called")
    @MainActor
    func formatAndOutputCalled() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())
        let event = BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0)

        try await consumer.handle(event)

        let formattedEvents = consumer.getFormattedEvents()
        #expect(formattedEvents.count == 1)
        #expect(formattedEvents[0].contains("Formatted:"))
        #expect(formattedEvents[0].contains("operationFinished"))
    }

    @Test("Format and output called for all events")
    @MainActor
    func formatAndOutputCalledForAllEvents() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        let events = [
            BuildEvent.buildStarted(totalOperations: 3, stages: 1, timestamp: Date()),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: UUID(), description: "Operation 2")),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        let formattedEvents = consumer.getFormattedEvents()
        #expect(formattedEvents.count == 4)

        #expect(formattedEvents[0].contains("buildStarted"))
        #expect(formattedEvents[1].contains("operationFinished"))
        #expect(formattedEvents[2].contains("operationCacheHit"))
        #expect(formattedEvents[3].contains("buildCompleted"))
    }

    // MARK: - Consumer Integration Tests

    @Test("Consume with reporter")
    @MainActor
    func consumeWithReporter() async throws {
        let reporter = Reporter(bufferSize: 100)
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Start consuming in background
        let consumeTask = Task {
            try await consumer.consume(reporter: reporter)
        }

        // Report some events
        let events = [
            BuildEvent.buildStarted(totalOperations: 2, stages: 1, timestamp: Date()),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 1"), duration: 1.0),
            BuildEvent.operationFinished(context: ReportContext(nodeId: UUID(), description: "Operation 2"), duration: 1.0),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            await reporter.report(event)
        }

        // Finish reporting
        await reporter.finish()

        // Wait for consumption to complete
        try await consumeTask.value

        let statistics = consumer.getStatistics()
        #expect(statistics.totalOperations == 2)
        #expect(statistics.executedOperations == 2)
        #expect(statistics.success == true)
        #expect(statistics.events.count == 4)

        let formattedEvents = consumer.getFormattedEvents()
        #expect(formattedEvents.count == 4)
    }

    // MARK: - Edge Cases and Error Handling

    @Test("Statistics with no events")
    @MainActor
    func statisticsWithNoEvents() {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        let statistics = consumer.getStatistics()
        #expect(statistics.startTime == nil)
        #expect(statistics.endTime == nil)
        #expect(statistics.success == nil)
        #expect(statistics.totalOperations == 0)
        #expect(statistics.executedOperations == 0)
        #expect(statistics.cacheHits == 0)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.totalStages == 0)
        #expect(statistics.stageStatistics.isEmpty)
        #expect(statistics.events.isEmpty)
    }

    @Test("Statistics with only progress events")
    @MainActor
    func statisticsWithOnlyProgressEvents() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        let nodeId = UUID()
        let events = [
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId, description: "Operation 1"), fraction: 0.25),
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId, description: "Operation 1"), fraction: 0.50),
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId, description: "Operation 1"), fraction: 0.75),
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId, description: "Operation 1"), fraction: 1.0),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        let statistics = consumer.getStatistics()
        #expect(statistics.executedOperations == 0)
        #expect(statistics.failedOperations == 0)
        #expect(statistics.cacheHits == 0)
        #expect(statistics.events.count == 4)
    }

    @Test("Operation without stage ID")
    @MainActor
    func operationWithoutStageId() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Operation without stage ID
        let nodeId = UUID()
        let event = BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId, description: "Operation 1"))
        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.totalStages == 0)
        #expect(statistics.stageStatistics.isEmpty)
    }

    @Test("Stage completion without start")
    @MainActor
    func stageCompletionWithoutStart() async throws {
        let consumer = TestProgressConsumer(configuration: TestConfiguration())

        // Complete stage without starting it
        let event = BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date())
        try await consumer.handle(event)

        let statistics = consumer.getStatistics()
        #expect(statistics.totalStages == 1)
        #expect(statistics.stageStatistics["stage1"]?.startTime == nil)
        #expect(statistics.stageStatistics["stage1"]?.endTime != nil)
    }
}
