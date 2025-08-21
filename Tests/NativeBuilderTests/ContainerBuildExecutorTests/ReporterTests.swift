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

import ContainerBuildIR
import ContainerBuildReporting
import Foundation
import Testing

@testable import ContainerBuildExecutor

@MainActor
final class EventCollector {
    private var events: [BuildEvent] = []

    func add(_ event: BuildEvent) {
        events.append(event)
    }

    func getEvents() -> [BuildEvent] {
        events
    }
}

struct ReporterTests {
    @Test func reporterEmitsEvents() async throws {
        let reporter = Reporter()
        let eventCollector = EventCollector()

        // Collect events in background
        let collectionTask = Task {
            for await event in reporter.stream {
                await eventCollector.add(event)
            }
        }

        // Emit test events
        await reporter.report(.buildStarted(totalOperations: 5, stages: 2, timestamp: Date()))

        let context = ReportContext(
            nodeId: UUID(),
            stageId: "test-stage",
            description: "RUN echo hello"
        )

        await reporter.report(.operationStarted(context: context))
        await reporter.report(.operationLog(context: context, message: "Hello, world!"))
        await reporter.report(.operationFinished(context: context, duration: 1.5))

        await reporter.report(.buildCompleted(success: true, timestamp: Date()))
        await reporter.finish()

        // Wait for collection to complete
        await collectionTask.value

        // Verify events
        let events = await eventCollector.getEvents()
        #expect(events.count == 5)

        if case .buildStarted(let ops, let stages, _) = events[0] {
            #expect(ops == 5)
            #expect(stages == 2)
        } else {
            Issue.record("Expected buildStarted event")
        }

        if case .operationStarted(let ctx) = events[1] {
            #expect(ctx.description == "RUN echo hello")
        } else {
            Issue.record("Expected operationStarted event")
        }

        if case .operationLog(_, let message) = events[2] {
            #expect(message == "Hello, world!")
        } else {
            Issue.record("Expected operationLog event")
        }

        if case .operationFinished(_, let duration) = events[3] {
            #expect(duration == 1.5)
        } else {
            Issue.record("Expected operationFinished event")
        }

        if case .buildCompleted(let success, _) = events[4] {
            #expect(success == true)
        } else {
            Issue.record("Expected buildCompleted event")
        }
    }

    @Test func plainProgressConsumer() async throws {
        let reporter = Reporter()

        // Start consumer in background
        let consumerTask = Task {
            let consumer = PlainProgressConsumer(configuration: .init())
            try await consumer.consume(reporter: reporter)
        }

        // Emit events
        await reporter.report(.buildStarted(totalOperations: 2, stages: 1, timestamp: Date()))

        let nodeId = UUID()
        let context = ReportContext(
            nodeId: nodeId,
            stageId: "main",
            description: "RUN apt-get update"
        )

        await reporter.report(.stageStarted(stageName: "main", timestamp: Date()))
        await reporter.report(.operationStarted(context: context))
        await reporter.report(.operationLog(context: context, message: "Reading package lists..."))
        await reporter.report(.operationLog(context: context, message: "Building dependency tree..."))
        await reporter.report(.operationFinished(context: context, duration: 2.3))
        await reporter.report(.stageCompleted(stageName: "main", timestamp: Date()))
        await reporter.report(.buildCompleted(success: true, timestamp: Date()))

        await reporter.finish()
        try await consumerTask.value

        // Test passes if consumer completes without error
    }

    @Test func operationCacheHit() async throws {
        let reporter = Reporter()
        let eventCollector = EventCollector()

        let collectionTask = Task {
            for await event in reporter.stream {
                await eventCollector.add(event)
            }
        }

        let context = ReportContext(
            nodeId: UUID(),
            stageId: "cached-stage",
            description: "COPY src/ /app/"
        )

        await reporter.report(.operationStarted(context: context))
        await reporter.report(.operationCacheHit(context: context))
        await reporter.finish()

        await collectionTask.value

        let events = await eventCollector.getEvents()
        #expect(events.count == 2)

        if case .operationCacheHit(let ctx) = events[1] {
            #expect(ctx.description == "COPY src/ /app/")
        } else {
            Issue.record("Expected operationCacheHit event")
        }
    }

    @Test func operationFailure() async throws {
        let reporter = Reporter()
        let eventCollector = EventCollector()

        let collectionTask = Task {
            for await event in reporter.stream {
                await eventCollector.add(event)
            }
        }

        let context = ReportContext(
            nodeId: UUID(),
            stageId: "failing-stage",
            description: "RUN false"
        )

        let error = BuildEventError(
            type: .executionFailed,
            description: "Command exited with non-zero status",
            diagnostics: [
                "exitCode": "1",
                "workingDirectory": "/app",
            ]
        )

        await reporter.report(.operationStarted(context: context))
        await reporter.report(.operationFailed(context: context, error: error))
        await reporter.report(.buildCompleted(success: false, timestamp: Date()))
        await reporter.finish()

        await collectionTask.value

        let events = await eventCollector.getEvents()
        #expect(events.count == 3)

        if case .operationFailed(let ctx, let err) = events[1] {
            #expect(ctx.description == "RUN false")
            #expect(err.type == .executionFailed)
            #expect(err.diagnostics?["exitCode"] == "1")
        } else {
            Issue.record("Expected operationFailed event")
        }
    }
}
