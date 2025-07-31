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

@Suite("JSONProgressConsumer Tests")
struct JSONProgressConsumerTests {

    // MARK: - Test Utilities

    private func createTestPipe() -> (FileHandle, FileHandle) {
        let pipe = Pipe()
        return (pipe.fileHandleForWriting, pipe.fileHandleForReading)
    }

    private func readOutputAsString(from readHandle: FileHandle) -> String {
        let data = readHandle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseJSONLines(_ output: String) -> [[String: Any]] {
        let lines = output.split(separator: "\n").map(String.init)
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return json
        }
    }

    // MARK: - Initialization Tests

    @Test("Default initialization sets correct configuration values")
    func testDefaultInitialization() {
        let consumer = JSONProgressConsumer(configuration: JSONProgressConsumer.Configuration())

        #expect(!consumer.configuration.prettyPrint)
        #expect(consumer.configuration.output == FileHandle.standardOutput)
    }

    @Test("Initialization with custom configuration applies settings correctly")
    func testInitializationWithCustomConfiguration() {
        let (writeHandle, _) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(
            output: writeHandle,
            prettyPrint: true
        )
        let consumer = JSONProgressConsumer(configuration: config)

        #expect(consumer.configuration.prettyPrint)
        #expect(consumer.configuration.output == writeHandle)
    }

    // MARK: - Build Event JSON Output Tests

    @Test("Build started event produces correct JSON output")
    func testBuildStartedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.buildStarted(totalOperations: 5, stages: 2, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "build_started")
        #expect(json["total_operations"] as? Int == 5)
        #expect(json["stages"] as? Int == 2)
        #expect(json["timestamp"] != nil)
    }

    @Test("Build completed event produces correct JSON output")
    func testBuildCompletedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.buildCompleted(success: true, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "build_completed")
        #expect(json["success"] as? Bool == true)
        #expect(json["timestamp"] != nil)
    }

    @Test("Stage started event produces correct JSON output")
    func testStageStartedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.stageStarted(stageName: "stage1", timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "stage_started")
        #expect(json["stage"] as? String == "stage1")
        #expect(json["timestamp"] != nil)
    }

    @Test("Stage completed event produces correct JSON output")
    func testStageCompletedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "stage_completed")
        #expect(json["stage"] as? String == "stage1")
        #expect(json["timestamp"] != nil)
    }

    @Test("Operation started event produces correct JSON output with operation number")
    func testOperationStartedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, stageId: "stage1", description: "Test operation")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "operation_started")
        #expect(json["operation"] as? String == "#1")
        #expect(json["description"] as? String == "Test operation")
        #expect(json["stage"] as? String == "stage1")
        #expect(json["timestamp"] != nil)
    }

    @Test("Operation finished event produces correct JSON output with duration")
    func testOperationFinishedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        // First start the operation to assign a number
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then finish it
        let finishEvent = BuildEvent.operationFinished(context: context, duration: 1.5)
        try await consumer.handle(finishEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 2)
        let finishJson = jsonLines[1]
        #expect(finishJson["type"] as? String == "operation_finished")
        #expect(finishJson["operation"] as? String == "#1")
        #expect(finishJson["duration"] as? Double == 1.5)
        #expect(finishJson["timestamp"] != nil)
    }

    @Test("Operation failed event produces correct JSON output with error details")
    func testOperationFailedEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let error = BuildEventError(type: .executionFailed, description: "Test error")

        // First start the operation to assign a number
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then fail it
        let failEvent = BuildEvent.operationFailed(context: context, error: error)
        try await consumer.handle(failEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 2)
        let failJson = jsonLines[1]
        #expect(failJson["type"] as? String == "operation_failed")
        #expect(failJson["operation"] as? String == "#1")
        #expect(failJson["error"] as? String == "Test error")
        #expect(failJson["error_type"] as? String == "executionFailed")
        #expect(failJson["timestamp"] != nil)
    }

    @Test("Operation cache hit event produces correct JSON output")
    func testOperationCacheHitEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationCacheHit(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "operation_cache_hit")
        #expect(json["operation"] as? String == "#1")
        #expect(json["description"] as? String == "Test operation")
        #expect(json["timestamp"] != nil)
    }

    @Test("Operation progress event produces correct JSON output with progress fraction")
    func testOperationProgressEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        // First start the operation to assign a number
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then progress it
        let progressEvent = BuildEvent.operationProgress(context: context, fraction: 0.75)
        try await consumer.handle(progressEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 2)
        let progressJson = jsonLines[1]
        #expect(progressJson["type"] as? String == "operation_progress")
        #expect(progressJson["operation"] as? String == "#1")
        #expect(progressJson["progress"] as? Double == 0.75)
        #expect(progressJson["timestamp"] != nil)
    }

    @Test("Operation log event produces correct JSON output with message")
    func testOperationLogEvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        // First start the operation to assign a number
        let startEvent = BuildEvent.operationStarted(context: context)
        try await consumer.handle(startEvent)

        // Then log a message
        let logEvent = BuildEvent.operationLog(context: context, message: "Test log message")
        try await consumer.handle(logEvent)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 2)
        let logJson = jsonLines[1]
        #expect(logJson["type"] as? String == "operation_log")
        #expect(logJson["operation"] as? String == "#1")
        #expect(logJson["message"] as? String == "Test log message")
        #expect(logJson["timestamp"] != nil)
    }

    @Test("IR event produces correct JSON output with source map information")
    func testIREvent() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let sourceMap = SourceMap(file: "test.swift", line: 42, column: 10, snippet: "let x = 1")
        let context = ReportContext(nodeId: nodeId, stageId: "stage1", description: "IR test", sourceMap: sourceMap)
        let event = BuildEvent.irEvent(context: context, type: .graphStarted)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "ir_event")
        #expect(json["event_type"] as? String == "graph_started")
        #expect(json["description"] as? String == "IR test")
        #expect(json["node_id"] as? String == nodeId.uuidString)
        #expect(json["stage_id"] as? String == "stage1")
        #expect(json["timestamp"] != nil)

        // Check source map
        let sourceMapJson = json["source_map"] as? [String: Any]
        #expect(sourceMapJson != nil)
        #expect(sourceMapJson?["file"] as? String == "test.swift")
        #expect(sourceMapJson?["line"] as? Int == 42)
        #expect(sourceMapJson?["column"] as? Int == 10)
        #expect(sourceMapJson?["snippet"] as? String == "let x = 1")
    }

    // MARK: - Operation Number Assignment Tests

    @Test("Operation number assignment assigns sequential numbers to operations")
    func testOperationNumberAssignment() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let nodeId3 = UUID()

        let events = [
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, description: "Op 1")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, description: "Op 2")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId3, description: "Op 3")),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId1, description: "Op 1"), duration: 1.0),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId2, description: "Op 2"), duration: 2.0),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId3, description: "Op 3"), duration: 3.0),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 6)

        // Check operation numbers are assigned sequentially
        #expect(jsonLines[0]["operation"] as? String == "#1")
        #expect(jsonLines[1]["operation"] as? String == "#2")
        #expect(jsonLines[2]["operation"] as? String == "#3")
        #expect(jsonLines[3]["operation"] as? String == "#1")
        #expect(jsonLines[4]["operation"] as? String == "#2")
        #expect(jsonLines[5]["operation"] as? String == "#3")
    }

    @Test("Operation number consistency maintains same number across operation lifecycle")
    func testOperationNumberConsistency() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        let events = [
            BuildEvent.operationStarted(context: context),
            BuildEvent.operationProgress(context: context, fraction: 0.5),
            BuildEvent.operationLog(context: context, message: "Progress update"),
            BuildEvent.operationFinished(context: context, duration: 1.0),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 4)

        // All events should have the same operation number
        for json in jsonLines {
            #expect(json["operation"] as? String == "#1")
        }
    }

    // MARK: - Pretty Print Tests

    @Test("Pretty print formatting produces indented JSON with newlines")
    func testPrettyPrintFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: true)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.buildStarted(totalOperations: 5, stages: 2, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Pretty printed JSON should contain newlines and indentation
        #expect(output.contains("{\n"))
        #expect(output.contains("  "))
        #expect(output.contains("\"stages\" : 2"))
        #expect(output.contains("\"total_operations\" : 5"))
        #expect(output.contains("\"type\" : \"build_started\""))
    }

    @Test("Compact formatting produces single-line JSON without indentation")
    func testCompactFormatting() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.buildStarted(totalOperations: 5, stages: 2, timestamp: Date())
        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Compact JSON should be on a single line
        let lines = output.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(!output.contains("  "))
    }

    // MARK: - Edge Cases and Error Handling

    @Test("Operation event without node ID produces no output")
    func testOperationEventWithoutNodeId() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: nil, description: "Test operation")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when nodeId is nil
        #expect(output.isEmpty)
    }

    @Test("Operation finished without prior start produces no output")
    func testOperationFinishedWithoutPriorStart() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationFinished(context: context, duration: 1.0)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)

        // Should produce no output when operation wasn't started
        #expect(output.isEmpty)
    }

    @Test("IR event with minimal context produces basic JSON output")
    func testIREventWithMinimalContext() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let context = ReportContext(nodeId: nil, description: "Minimal IR event")
        let event = BuildEvent.irEvent(context: context, type: .graphStarted)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        #expect(json["type"] as? String == "ir_event")
        #expect(json["event_type"] as? String == "graph_started")
        #expect(json["description"] as? String == "Minimal IR event")
        #expect(json["node_id"] == nil)
        #expect(json["stage_id"] == nil)
        #expect(json["source_map"] == nil)
    }

    @Test("IR event with partial source map includes only available fields")
    func testIREventWithPartialSourceMap() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let sourceMap = SourceMap(file: "test.swift", line: nil, column: nil, snippet: nil)
        let context = ReportContext(nodeId: nil, description: "Partial source map", sourceMap: sourceMap)
        let event = BuildEvent.irEvent(context: context, type: .graphStarted)

        try await consumer.handle(event)

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 1)
        let json = jsonLines[0]
        let sourceMapJson = json["source_map"] as? [String: Any]
        #expect(sourceMapJson != nil)
        #expect(sourceMapJson?["file"] as? String == "test.swift")
        #expect(sourceMapJson?["line"] == nil)
        #expect(sourceMapJson?["column"] == nil)
        #expect(sourceMapJson?["snippet"] == nil)
    }

    // MARK: - Thread Safety Tests

    @Test("Thread safety with concurrent operations maintains unique operation numbers")
    func testThreadSafetyWithConcurrentOperations() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

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
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == operationCount * 2)

        // Check that all operations got unique numbers
        let operationNumbers = Set(jsonLines.compactMap { $0["operation"] as? String })
        #expect(operationNumbers.count == operationCount)
    }

    // MARK: - Complex Integration Tests

    @Test("Complex build sequence produces correct JSON output in proper order")
    func testComplexBuildSequence() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let nodeId3 = UUID()

        let events = [
            BuildEvent.buildStarted(totalOperations: 3, stages: 2, timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage1", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId1, stageId: "stage1", description: "Operation 1")),
            BuildEvent.operationProgress(context: ReportContext(nodeId: nodeId1, description: "Operation 1"), fraction: 0.5),
            BuildEvent.operationFinished(context: ReportContext(nodeId: nodeId1, description: "Operation 1"), duration: 1.0),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId2, stageId: "stage1", description: "Operation 2")),
            BuildEvent.operationCacheHit(context: ReportContext(nodeId: nodeId2, description: "Operation 2")),
            BuildEvent.stageCompleted(stageName: "stage1", timestamp: Date()),
            BuildEvent.stageStarted(stageName: "stage2", timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: nodeId3, stageId: "stage2", description: "Operation 3")),
            BuildEvent.operationFailed(
                context: ReportContext(nodeId: nodeId3, description: "Operation 3"), error: BuildEventError(type: .executionFailed, description: "Test failure")),
            BuildEvent.stageCompleted(stageName: "stage2", timestamp: Date()),
            BuildEvent.buildCompleted(success: false, timestamp: Date()),
        ]

        for event in events {
            try await consumer.handle(event)
        }

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 13)

        // Verify event types in order
        #expect(jsonLines[0]["type"] as? String == "build_started")
        #expect(jsonLines[1]["type"] as? String == "stage_started")
        #expect(jsonLines[2]["type"] as? String == "operation_started")
        #expect(jsonLines[3]["type"] as? String == "operation_progress")
        #expect(jsonLines[4]["type"] as? String == "operation_finished")
        #expect(jsonLines[5]["type"] as? String == "operation_started")
        #expect(jsonLines[6]["type"] as? String == "operation_cache_hit")
        #expect(jsonLines[7]["type"] as? String == "stage_completed")
        #expect(jsonLines[8]["type"] as? String == "stage_started")
        #expect(jsonLines[9]["type"] as? String == "operation_started")
        #expect(jsonLines[10]["type"] as? String == "operation_failed")
        #expect(jsonLines[11]["type"] as? String == "stage_completed")
        #expect(jsonLines[12]["type"] as? String == "build_completed")

        // Verify operation numbers
        #expect(jsonLines[2]["operation"] as? String == "#1")
        #expect(jsonLines[3]["operation"] as? String == "#1")
        #expect(jsonLines[4]["operation"] as? String == "#1")
        #expect(jsonLines[5]["operation"] as? String == "#2")
        #expect(jsonLines[6]["operation"] as? String == "#2")
        #expect(jsonLines[9]["operation"] as? String == "#3")
        #expect(jsonLines[10]["operation"] as? String == "#3")

        // Verify stage information
        #expect(jsonLines[1]["stage"] as? String == "stage1")
        #expect(jsonLines[2]["stage"] as? String == "stage1")
        #expect(jsonLines[7]["stage"] as? String == "stage1")
        #expect(jsonLines[8]["stage"] as? String == "stage2")
        #expect(jsonLines[11]["stage"] as? String == "stage2")

        // Verify final build result
        #expect(jsonLines[12]["success"] as? Bool == false)
    }

    @Test("Consumer with reporter processes events correctly through reporter interface")
    func testConsumerWithReporter() async throws {
        let (writeHandle, readHandle) = createTestPipe()
        let config = JSONProgressConsumer.Configuration(output: writeHandle, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)
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
        let events = [
            BuildEvent.buildStarted(totalOperations: 2, stages: 1, timestamp: Date()),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), description: "Op 1")),
            BuildEvent.operationStarted(context: ReportContext(nodeId: UUID(), description: "Op 2")),
            BuildEvent.buildCompleted(success: true, timestamp: Date()),
        ]

        for event in events {
            await reporter.report(event)
        }

        await reporter.finish()
        await consumeTask.value

        writeHandle.closeFile()
        let output = readOutputAsString(from: readHandle)
        let jsonLines = parseJSONLines(output)

        #expect(jsonLines.count == 4)
        #expect(jsonLines[0]["type"] as? String == "build_started")
        #expect(jsonLines[1]["type"] as? String == "operation_started")
        #expect(jsonLines[2]["type"] as? String == "operation_started")
        #expect(jsonLines[3]["type"] as? String == "build_completed")
    }
}
