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

@Suite("PlainProgressConsumer Tests")
struct PlainProgressConsumerTests {

    // MARK: - Test Utilities

    private func createTestPipe() -> (FileHandle, FileHandle) {
        let pipe = Pipe()
        return (pipe.fileHandleForWriting, pipe.fileHandleForReading)
    }

    private func readOutputAsString(from readHandle: FileHandle) -> String {
        let data = readHandle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseLines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Initialization Tests

    @Test("Default initialization uses standard output")
    func defaultInitialization() {
        let consumer = PlainProgressConsumer(configuration: PlainProgressConsumer.Configuration())

        #expect(consumer.configuration.output == FileHandle.standardOutput)
    }

    @Test("Initialization with custom configuration")
    func initializationWithCustomConfiguration() {
        let (writeHandle, _) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        #expect(consumer.configuration.output == writeHandle)
    }

    // MARK: - Build Event Formatting Tests

    @Test("Build started event produces no output")
    func buildStartedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let event = BuildEvent.buildStarted(totalOperations: 5, stages: 2, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // BuildKit doesn't show explicit build start, so should be empty
        #expect(output.isEmpty)
    }

    @Test("Build completed event produces no output")
    func buildCompletedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let event = BuildEvent.buildCompleted(success: true, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // BuildKit doesn't show explicit build completion in plain output
        #expect(output.isEmpty)
    }

    @Test("Stage events produce no output")
    func stageEvents() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let startEvent = BuildEvent.stageStarted(stageName: "stage1", timestamp: Date())
        let completeEvent = BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date())

        try await consumer.handle(startEvent)
        try await consumer.handle(completeEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Stages are implicit in operation descriptions
        #expect(output.isEmpty)
    }

    @Test("Operation started event formats correctly")
    func operationStartedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, stageId: "stage1", description: "RUN apk add git")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [stage1] RUN apk add git")
    }

    @Test("Operation finished event shows duration")
    func operationFinishedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let endTime = Date(timeInterval: 1.5, since: startTime)
        let context = ReportContext(nodeId: nodeId, description: "RUN apk add git", timestamp: startTime)
        let endContext = ReportContext(nodeId: nodeId, description: "RUN apk add git", timestamp: endTime)

        // Start operation first
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then finish it
        let finishEvent = BuildEvent.operationFinished(context: endContext, duration: 1.5)
        try await consumer.handle(finishEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[0] == "#1 [stage] RUN apk add git")
        #expect(lines[1] == "#1 DONE 1.5s")
    }

    @Test("Operation failed event shows error message")
    func operationFailedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "RUN apk add git")
        let error = BuildEventError(type: .executionFailed, description: "Package not found")

        // Start operation first
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then fail it
        let failEvent = BuildEvent.operationFailed(context: context, error: error)
        try await consumer.handle(failEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[0] == "#1 [stage] RUN apk add git")
        #expect(lines[1] == "#1 ERROR: Package not found")
    }

    @Test("Operation cache hit event shows CACHED status")
    func operationCacheHitEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, stageId: "stage1", description: "RUN apk add git")
        let event = BuildEvent.operationCacheHit(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[0] == "#1 [stage1] RUN apk add git")
        #expect(lines[1] == "#1 CACHED")
    }

    @Test("Operation progress event shows percentage")
    func operationProgressEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "RUN apk add git")

        // Start operation first
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then show progress
        let progressEvent = BuildEvent.operationProgress(context: context, fraction: 0.75)
        try await consumer.handle(progressEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[0] == "#1 [stage] RUN apk add git")
        #expect(lines[1] == "#1 75% complete")
    }

    @Test("Operation log event shows timestamped message")
    func operationLogEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let logTime = Date(timeInterval: 0.245, since: startTime)
        let context = ReportContext(nodeId: nodeId, description: "RUN apk add git", timestamp: startTime)
        let logContext = ReportContext(nodeId: nodeId, description: "RUN apk add git", timestamp: logTime)

        // Start operation first
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then log a message
        let logEvent = BuildEvent.operationLog(context: logContext, message: "fetch https://dl-cdn.alpinelinux.org/alpine/...")
        try await consumer.handle(logEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[0] == "#1 [stage] RUN apk add git")
        #expect(lines[1] == "#1 0.245 fetch https://dl-cdn.alpinelinux.org/alpine/...")
    }

    // MARK: - Operation Description Formatting Tests

    @Test("FROM operation description formatting")
    func fromOperationDescriptionFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "FROM alpine:latest")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [internal] load metadata for alpine:latest")
    }

    @Test("BaseImage operation description formatting")
    func baseImageOperationDescriptionFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "BaseImage: ubuntu:20.04")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [internal] load metadata for ubuntu:20.04")
    }

    @Test("Stage name formatting")
    func stageNameFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, stageId: "build-stage", description: "COPY . /app")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [build-stage] COPY . /app")
    }

    @Test("UUID stage name formatting")
    func uuidStageNameFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, stageId: "stage-\(UUID().uuidString)", description: "RUN make")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [stage] RUN make")
    }

    @Test("Operation without stage ID")
    func operationWithoutStageId() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "COPY . /app")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "#1 [stage] COPY . /app")
    }

    // MARK: - Duration Formatting Tests

    @Test("Duration formatting for sub-second durations")
    func durationFormattingSubSecond() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let endTime = Date(timeInterval: 0.123, since: startTime)
        let context = ReportContext(nodeId: nodeId, description: "Test", timestamp: startTime)
        let endContext = ReportContext(nodeId: nodeId, description: "Test", timestamp: endTime)

        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        let finishEvent = BuildEvent.operationFinished(context: endContext, duration: 0.123)
        try await consumer.handle(finishEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[1] == "#1 DONE 0.1s")
    }

    @Test("Duration formatting for seconds")
    func durationFormattingSeconds() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let endTime = Date(timeInterval: 15.7, since: startTime)
        let context = ReportContext(nodeId: nodeId, description: "Test", timestamp: startTime)
        let endContext = ReportContext(nodeId: nodeId, description: "Test", timestamp: endTime)

        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        let finishEvent = BuildEvent.operationFinished(context: endContext, duration: 15.7)
        try await consumer.handle(finishEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[1] == "#1 DONE 15.7s")
    }

    @Test("Duration formatting for minutes")
    func durationFormattingMinutes() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let endTime = Date(timeInterval: 125.0, since: startTime)  // 2m5s
        let context = ReportContext(nodeId: nodeId, description: "Test", timestamp: startTime)
        let endContext = ReportContext(nodeId: nodeId, description: "Test", timestamp: endTime)

        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        let finishEvent = BuildEvent.operationFinished(context: endContext, duration: 125.0)
        try await consumer.handle(finishEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 2)
        #expect(lines[1] == "#1 DONE 2m5s")
    }

    // MARK: - IR Event Formatting Tests

    @Test("IR event analyzing")
    func irEventAnalyzing() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: UUID(), description: "Analyzing build dependencies")
        let event = BuildEvent.irEvent(context: context, type: .analyzing)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "=> Analyzing build dependencies")
    }

    @Test("IR event validating")
    func irEventValidating() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: UUID(), description: "Validating build graph")
        let event = BuildEvent.irEvent(context: context, type: .validating)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "=> Validating build graph")
    }

    @Test("IR event error")
    func irEventError() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: UUID(), description: "Invalid syntax")
        let event = BuildEvent.irEvent(context: context, type: .error)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "ERROR: Invalid syntax")
    }

    @Test("IR event error with source map")
    func irEventErrorWithSourceMap() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let sourceMap = SourceMap(file: "Dockerfile", line: 15, column: 5, snippet: "RUN invalid-command")
        let context = ReportContext(nodeId: UUID(), description: "Command not found", sourceMap: sourceMap)
        let event = BuildEvent.irEvent(context: context, type: .error)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "ERROR: Command not found at Dockerfile:15")
    }

    @Test("IR event warning")
    func irEventWarning() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: UUID(), description: "Deprecated instruction")
        let event = BuildEvent.irEvent(context: context, type: .warning)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "WARNING: Deprecated instruction")
    }

    @Test("IR event warning with source map")
    func irEventWarningWithSourceMap() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let sourceMap = SourceMap(file: "Dockerfile", line: 8, column: nil, snippet: nil)
        let context = ReportContext(nodeId: UUID(), description: "MAINTAINER is deprecated", sourceMap: sourceMap)
        let event = BuildEvent.irEvent(context: context, type: .warning)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 1)
        #expect(lines[0] == "WARNING: MAINTAINER is deprecated at Dockerfile:8")
    }

    @Test("IR event graph events produce no output")
    func irEventGraphEvents() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let events = [
            BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "Graph started"), type: .graphStarted),
            BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "Graph completed"), type: .graphCompleted),
            BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "Stage added"), type: .stageAdded),
            BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "Node added"), type: .nodeAdded),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // These events should not produce output in plain format
        #expect(output.isEmpty)
    }

    // MARK: - Operation Number Assignment Tests

    @Test("Operation number assignment")
    func operationNumberAssignment() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let nodeId3 = UUID()

        let events = [
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, description: "Op 1")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, description: "Op 2")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId3, description: "Op 3")),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("#1 "))
        #expect(lines[1].hasPrefix("#2 "))
        #expect(lines[2].hasPrefix("#3 "))
    }

    @Test("Operation number consistency")
    func operationNumberConsistency() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let startTime = Date()
        let progressTime = Date(timeInterval: 0.5, since: startTime)
        let logTime = Date(timeInterval: 1.0, since: startTime)
        let endTime = Date(timeInterval: 2.0, since: startTime)

        let events = [
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId, description: "Test", timestamp: startTime)),
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId, description: "Test", timestamp: progressTime), fraction: 0.5),
            BuildEvent.operationLog(context: ReportContext(nodeId: nodeId, description: "Test", timestamp: logTime), message: "Log message"),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId, description: "Test", timestamp: endTime), duration: 2.0),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("#1 "))
        #expect(lines[1].hasPrefix("#1 "))
        #expect(lines[2].hasPrefix("#1 "))
        #expect(lines[3].hasPrefix("#1 "))
    }

    // MARK: - Edge Cases and Error Handling

    @Test("Operation event without node ID produces no output")
    func operationEventWithoutNodeId() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: nil, description: "Test operation")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when nodeId is nil
        #expect(output.isEmpty)
    }

    @Test("Operation finished without prior start produces no output")
    func operationFinishedWithoutPriorStart() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationFinished(context: context, duration: 1.0)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when operation wasn't started
        #expect(output.isEmpty)
    }

    @Test("Operation progress without prior start produces no output")
    func operationProgressWithoutPriorStart() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationProgress(context: context, fraction: 0.5)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when operation wasn't started
        #expect(output.isEmpty)
    }

    @Test("Operation log without prior start produces no output")
    func operationLogWithoutPriorStart() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationLog(context: context, message: "Log message")

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when operation wasn't started
        #expect(output.isEmpty)
    }

    @Test("Multiple operations with same node ID")
    func multipleOperationsWithSameNodeId() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        let events = [
            BuildEvent.operationStarted(context: context),
            BuildEvent.operationStarted(context: context),  // Same nodeId
            BuildEvent.operationFinished(context: context, duration: 1.0),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("#1 "))
        #expect(lines[1].hasPrefix("#1 "))  // Same number reused
        #expect(lines[2].hasPrefix("#1 "))
    }

    // MARK: - Thread Safety Tests

    @Test("Thread safety with concurrent operations")
    func threadSafetyWithConcurrentOperations() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let operationCount = 100
        let nodeIds = (0..<operationCount).map { _ in UUID() }

        // Handle operations concurrently
        await withTaskGroup(of: Void.self) { group in
            for (index, nodeId) in nodeIds.enumerated() {
                group.addTask {
                    do {
                        let context = ReportContext(nodeId: nodeId, description: "Operation \(index)")
                        let startEvent = BuildEvent.operationStarted(context: context)
                        try await consumer.handle(startEvent)

                        let finishEvent = BuildEvent.operationFinished(context: context, duration: 1.0)
                        try await consumer.handle(finishEvent)
                    } catch {
                        Issue.record("Failed to handle event: \(error)")
                    }
                }
            }
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == operationCount * 2)

        // Check that all operations got unique numbers
        let operationNumbers = Set(
            lines.compactMap { line in
                if let range = line.range(of: "#") {
                    let numberPart = String(line[range.upperBound...])
                    if let spaceRange = numberPart.range(of: " ") {
                        return String(numberPart[..<spaceRange.lowerBound])
                    }
                }
                return nil
            })
        #expect(operationNumbers.count == operationCount)
    }

    // MARK: - Complex Integration Tests

    @Test("Complex build sequence")
    func complexBuildSequence() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let nodeId3 = UUID()

        let events = [
            BuildEvent.buildStarted(totalOperations: 3, stages: 2, timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage1", timestamp: Date()),
            BuildEvent.irEvent(context: ReportContext(nodeId: UUID(), description: "Analyzing build graph"), type: .analyzing),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, stageId: "stage1", description: "FROM alpine:latest")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: nodeId1, description: "FROM alpine:latest")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, stageId: "stage1", description: "RUN apk add --no-cache git")),
            BuildEvent.operationLog(
                context: ReportContext(nodeId: nodeId2, description: "RUN apk add --no-cache git", timestamp: Date(timeInterval: 0.245, since: Date())),
                message: "fetch https://dl-cdn.alpinelinux.org/alpine/..."),
            BuildEvent.operationFinished(
                context: ReportContext(nodeId: nodeId2, description: "RUN apk add --no-cache git", timestamp: Date(timeInterval: 1.2, since: Date())), duration: 1.2),
            BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage2", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId3, stageId: "stage2", description: "COPY . /app")),
            BuildEvent.operationFailed(
                context: ReportContext(nodeId: nodeId3, description: "COPY . /app"), error: BuildEventError(type: .executionFailed, description: "No such file or directory")),
            BuildEvent.stageCompleted(stageName: "stage2", timestamp: Date()),
            BuildEvent.buildCompleted(success: false, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 8)

        // Verify output format
        #expect(lines[0] == "=> Analyzing build graph")
        #expect(lines[1] == "#1 [internal] load metadata for alpine:latest")
        #expect(lines[2] == "#1 CACHED")
        #expect(lines[3] == "#2 [stage1] RUN apk add --no-cache git")
        #expect(lines[4] == "#2 0.245 fetch https://dl-cdn.alpinelinux.org/alpine/...")
        #expect(lines[5] == "#2 DONE 1.2s")
        #expect(lines[6] == "#3 [stage2] COPY . /app")
        #expect(lines[7] == "#3 ERROR: No such file or directory")

        // Note: The failure line is now included in the count
    }

    @Test("BuildKit-style output")
    func buildKitStyleOutput() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId1 = UUID()
        let nodeId2 = UUID()

        let events = [
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, description: "BaseImage: alpine:latest")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: nodeId1, description: "BaseImage: alpine:latest")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, stageId: "base", description: "RUN apk add --no-cache git")),
            BuildEvent.operationLog(
                context: ReportContext(nodeId: nodeId2, description: "RUN apk add --no-cache git", timestamp: Date(timeInterval: 0.245, since: Date())),
                message: "fetch https://dl-cdn.alpinelinux.org/alpine/..."),
            BuildEvent.operationFinished(
                context: ReportContext(nodeId: nodeId2, description: "RUN apk add --no-cache git", timestamp: Date(timeInterval: 1.2, since: Date())), duration: 1.2),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 5)

        // Verify BuildKit-style output
        #expect(lines[0] == "#1 [internal] load metadata for alpine:latest")
        #expect(lines[1] == "#1 CACHED")
        #expect(lines[2] == "#2 [base] RUN apk add --no-cache git")
        #expect(lines[3] == "#2 0.245 fetch https://dl-cdn.alpinelinux.org/alpine/...")
        #expect(lines[4] == "#2 DONE 1.2s")
    }

    @Test("Consumer with reporter")
    func consumerWithReporter() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = PlainProgressConsumer.Configuration(output: writeHandle)
        let consumer = PlainProgressConsumer(configuration: config)
        let reporter = Reporter(bufferSize: 100)

        // Start consuming in background
        let consumeTask = Task {
            do {
                try await consumer.consume(reporter: reporter)
            } catch {
                Issue.record("Consumer failed: \(error)")
            }
        }

        // Report some events
        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let startTime = Date()
        let finishTime = Date(timeInterval: 1.0, since: startTime)
        let events = [
            BuildEvent.buildStarted(totalOperations: 2, stages: 1, timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, description: "FROM alpine:latest")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: nodeId1, description: "FROM alpine:latest")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, description: "RUN apk add git", timestamp: startTime)),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId2, description: "RUN apk add git", timestamp: finishTime), duration: 1.0),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            await reporter.report(event)
        }

        await reporter.finish()
        await consumeTask.value

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let lines = parseLines(output)

        #expect(lines.count == 4)
        #expect(lines[0] == "#1 [internal] load metadata for alpine:latest")
        #expect(lines[1] == "#1 CACHED")
        #expect(lines[2] == "#2 [stage] RUN apk add git")
        #expect(lines[3] == "#2 DONE 1.0s")
    }

}
