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

@Suite("BuildEvent Tests")
struct BuildEventTests {

    // MARK: - BuildEvent Creation Tests

    @Test("Create buildStarted event")
    func testBuildStartedEvent() {
        let timestamp = Date()
        let event = BuildEvent.buildStarted(totalOperations: 10, stages: 3, timestamp: timestamp)

        switch event {
        case .buildStarted(let ops, let stages, let ts):
            #expect(ops == 10)
            #expect(stages == 3)
            #expect(ts == timestamp)
        default:
            Issue.record("Expected buildStarted event")
        }
    }

    @Test("Create buildCompleted event")
    func testBuildCompletedEvent() {
        let timestamp = Date()
        let successEvent = BuildEvent.buildCompleted(success: true, timestamp: timestamp)
        let failureEvent = BuildEvent.buildCompleted(success: false, timestamp: timestamp)

        switch successEvent {
        case .buildCompleted(let success, let ts):
            #expect(success == true)
            #expect(ts == timestamp)
        default:
            Issue.record("Expected buildCompleted event")
        }

        switch failureEvent {
        case .buildCompleted(let success, _):
            #expect(success == false)
        default:
            Issue.record("Expected buildCompleted event")
        }
    }

    @Test("Create stage events")
    func testStageEvents() {
        let timestamp = Date()
        let startEvent = BuildEvent.stageStarted(stageName: "compile", timestamp: timestamp)
        let completeEvent = BuildEvent.stageCompleted(stageName: "compile", timestamp: timestamp)

        switch startEvent {
        case .stageStarted(let name, let ts):
            #expect(name == "compile")
            #expect(ts == timestamp)
        default:
            Issue.record("Expected stageStarted event")
        }

        switch completeEvent {
        case .stageCompleted(let name, let ts):
            #expect(name == "compile")
            #expect(ts == timestamp)
        default:
            Issue.record("Expected stageCompleted event")
        }
    }

    @Test("Create operation events")
    func testOperationEvents() {
        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Build operation")

        let startedEvent = BuildEvent.operationStarted(context: context)
        let finishedEvent = BuildEvent.operationFinished(context: context, duration: 2.5)
        let cacheHitEvent = BuildEvent.operationCacheHit(context: context)
        let progressEvent = BuildEvent.operationProgress(context: context, fraction: 0.75)
        let logEvent = BuildEvent.operationLog(context: context, message: "Building...")

        switch startedEvent {
        case .operationStarted(let ctx):
            #expect(ctx.nodeId == nodeId)
            #expect(ctx.description == "Build operation")
        default:
            Issue.record("Expected operationStarted event")
        }

        switch finishedEvent {
        case .operationFinished(let ctx, let duration):
            #expect(ctx.nodeId == nodeId)
            #expect(duration == 2.5)
        default:
            Issue.record("Expected operationFinished event")
        }

        switch cacheHitEvent {
        case .operationCacheHit(let ctx):
            #expect(ctx.nodeId == nodeId)
        default:
            Issue.record("Expected operationCacheHit event")
        }

        switch progressEvent {
        case .operationProgress(let ctx, let fraction):
            #expect(ctx.nodeId == nodeId)
            #expect(fraction == 0.75)
        default:
            Issue.record("Expected operationProgress event")
        }

        switch logEvent {
        case .operationLog(let ctx, let message):
            #expect(ctx.nodeId == nodeId)
            #expect(message == "Building...")
        default:
            Issue.record("Expected operationLog event")
        }
    }

    @Test("Create operation failed event")
    func testOperationFailedEvent() {
        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Failed operation")
        let error = BuildEventError(
            type: .executionFailed,
            description: "Build failed",
            diagnostics: ["exit_code": "1", "stderr": "error output"]
        )

        let failedEvent = BuildEvent.operationFailed(context: context, error: error)

        switch failedEvent {
        case .operationFailed(let ctx, let err):
            #expect(ctx.nodeId == nodeId)
            #expect(err.description == "Build failed")
            #expect(err.type == .executionFailed)
            #expect(err.diagnostics?.count == 2)
        default:
            Issue.record("Expected operationFailed event")
        }
    }

    @Test("Create IR events")
    func testIREvents() {
        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "IR operation")

        let irEventTypes: [IREventType] = [
            .stageAdded,
            .nodeAdded,
            .analyzing,
            .graphStarted,
            .graphCompleted,
        ]

        for eventType in irEventTypes {
            let event = BuildEvent.irEvent(context: context, type: eventType)

            switch event {
            case .irEvent(let ctx, let type):
                #expect(ctx.nodeId == nodeId)

                switch (type, eventType) {
                case (.stageAdded, .stageAdded):
                    break  // Match
                case (.nodeAdded, .nodeAdded):
                    break  // Match
                case (.analyzing, .analyzing):
                    break  // Match
                case (.graphStarted, .graphStarted):
                    break  // Match
                case (.graphCompleted, .graphCompleted):
                    break  // Match
                default:
                    Issue.record("IR event type mismatch")
                }
            default:
                Issue.record("Expected irEvent")
            }
        }
    }

    // MARK: - ReportContext Tests

    @Test("ReportContext convenience init")
    func testReportContextConvenienceInit() {
        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")

        #expect(context.nodeId == nodeId)
        #expect(context.stageId == nil)
        #expect(context.description == "Test operation")
        #expect(context.sourceMap == nil)
    }

    @Test("ReportContext full init")
    func testReportContextFullInit() {
        let sourceMap = SourceMap(file: "main.swift", line: 42, column: 8)
        let nodeId = UUID()
        let context = ReportContext(
            nodeId: nodeId,
            stageId: "stage1",
            description: "Full context",
            sourceMap: sourceMap
        )

        #expect(context.nodeId == nodeId)
        #expect(context.stageId == "stage1")
        #expect(context.description == "Full context")
        #expect(context.sourceMap?.file == "main.swift")
        #expect(context.sourceMap?.line == 42)
        #expect(context.sourceMap?.column == 8)
    }

    // MARK: - SourceMap Tests

    @Test("SourceMap creation")
    func testSourceMapCreation() {
        let sourceMap = SourceMap(file: "/path/to/file.swift", line: 100, column: 25)

        #expect(sourceMap.file == "/path/to/file.swift")
        #expect(sourceMap.line == 100)
        #expect(sourceMap.column == 25)
    }

    @Test("SourceMap with edge values")
    func testSourceMapEdgeValues() {
        let sourceMap1 = SourceMap(file: "", line: 0, column: 0)
        let sourceMap2 = SourceMap(file: "file.swift", line: Int.max, column: Int.max)

        #expect(sourceMap1.file == "")
        #expect(sourceMap1.line == 0)
        #expect(sourceMap1.column == 0)

        #expect(sourceMap2.file == "file.swift")
        #expect(sourceMap2.line == Int.max)
        #expect(sourceMap2.column == Int.max)
    }

    // MARK: - BuildEventError Tests

    @Test("BuildEventError creation")
    func testBuildEventErrorCreation() {
        let error = BuildEventError(
            type: .executionFailed,
            description: "Compilation failed",
            diagnostics: ["error": "undefined symbol", "warning": "unused variable"]
        )

        #expect(error.description == "Compilation failed")
        #expect(error.type == .executionFailed)
        #expect(error.diagnostics?.count == 2)
        #expect(error.diagnostics?["error"] == "undefined symbol")
        #expect(error.diagnostics?["warning"] == "unused variable")
    }

    @Test("BuildEventError without diagnostics")
    func testBuildEventErrorNoDiagnostics() {
        let error = BuildEventError(
            type: .executionFailed,
            description: "Simple error",
            diagnostics: nil
        )

        #expect(error.description == "Simple error")
        #expect(error.type == .executionFailed)
        #expect(error.diagnostics == nil)
    }

    @Test("BuildEventError failure types")
    func testBuildEventErrorFailureTypes() {
        let failureTypes: [BuildEventError.FailureType] = [
            .executionFailed,
            .cancelled,
            .invalidConfiguration,
            .timeout,
            .resourceExhausted,
        ]

        for failureType in failureTypes {
            let error = BuildEventError(
                type: failureType,
                description: "Test error",
                diagnostics: nil
            )
            #expect(error.type == failureType)
        }
    }

    // MARK: - Codable Tests

    @Test("BuildEvent JSON encoding/decoding")
    func testBuildEventCodable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let timestamp = Date()
        let events: [BuildEvent] = [
            .buildStarted(totalOperations: 5, stages: 2, timestamp: timestamp),
            .buildCompleted(success: true, timestamp: timestamp),
            .stageStarted(stageName: "test", timestamp: timestamp),
            .operationStarted(context: ReportContext(nodeId: UUID(), description: "test")),
            .operationCacheHit(context: ReportContext(nodeId: UUID(), description: "cached")),
            .operationProgress(context: ReportContext(nodeId: UUID(), description: "progress"), fraction: 0.5),
            .irEvent(context: ReportContext(nodeId: UUID(), description: "ir"), type: .analyzing),
        ]

        for event in events {
            let encoded = try encoder.encode(event)
            let decoded = try decoder.decode(BuildEvent.self, from: encoded)

            // Since BuildEvent doesn't conform to Equatable, we need to compare manually
            switch (event, decoded) {
            case (.buildStarted(let ops1, let stages1, let ts1), .buildStarted(let ops2, let stages2, let ts2)):
                #expect(ops1 == ops2)
                #expect(stages1 == stages2)
                #expect(abs(ts1.timeIntervalSince(ts2)) < 1.0)  // Allow time difference for ISO8601 encoding
            case (.buildCompleted(let success1, let ts1), .buildCompleted(let success2, let ts2)):
                #expect(success1 == success2)
                #expect(abs(ts1.timeIntervalSince(ts2)) < 1.0)
            case (.stageStarted(let name1, let ts1), .stageStarted(let name2, let ts2)):
                #expect(name1 == name2)
                #expect(abs(ts1.timeIntervalSince(ts2)) < 1.0)
            case (.operationStarted(let ctx1), .operationStarted(let ctx2)):
                #expect(ctx1.nodeId == ctx2.nodeId)
                #expect(ctx1.description == ctx2.description)
            case (.operationCacheHit(let ctx1), .operationCacheHit(let ctx2)):
                #expect(ctx1.nodeId == ctx2.nodeId)
            case (.operationProgress(let ctx1, let frac1), .operationProgress(let ctx2, let frac2)):
                #expect(ctx1.nodeId == ctx2.nodeId)
                #expect(frac1 == frac2)
            case (.irEvent(let ctx1, let type1), .irEvent(let ctx2, let type2)):
                #expect(ctx1.nodeId == ctx2.nodeId)
                switch (type1, type2) {
                case (.analyzing, .analyzing):
                    break  // Match
                default:
                    Issue.record("IR event type mismatch in codable test")
                }
            default:
                Issue.record("Event type mismatch in codable test")
            }
        }
    }

    @Test("ReportContext JSON encoding/decoding")
    func testReportContextCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let sourceMap = SourceMap(file: "test.swift", line: 10, column: 5)
        let context = ReportContext(
            nodeId: UUID(),
            stageId: "stage1",
            description: "Test context",
            sourceMap: sourceMap
        )

        let encoded = try encoder.encode(context)
        let decoded = try decoder.decode(ReportContext.self, from: encoded)

        #expect(decoded.nodeId == context.nodeId)
        #expect(decoded.stageId == context.stageId)
        #expect(decoded.description == context.description)
        #expect(decoded.sourceMap?.file == context.sourceMap?.file)
        #expect(decoded.sourceMap?.line == context.sourceMap?.line)
        #expect(decoded.sourceMap?.column == context.sourceMap?.column)
    }

    @Test("BuildEventError JSON encoding/decoding")
    func testBuildEventErrorCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let error = BuildEventError(
            type: .executionFailed,
            description: "Test error",
            diagnostics: ["line1": "line 1", "line2": "line 2"]
        )

        let encoded = try encoder.encode(error)
        let decoded = try decoder.decode(BuildEventError.self, from: encoded)

        #expect(decoded.description == error.description)
        #expect(decoded.type == error.type)
        #expect(decoded.diagnostics?.count == error.diagnostics?.count)
        if let decodedDiagnostics = decoded.diagnostics, let originalDiagnostics = error.diagnostics {
            #expect(decodedDiagnostics == originalDiagnostics)
        }
    }

    // MARK: - Edge Cases

    @Test("Empty strings and nil values")
    func testEmptyStringsAndNilValues() {
        let context1 = ReportContext(nodeId: nil, description: "")
        let context2 = ReportContext(nodeId: UUID(), stageId: nil, description: "", sourceMap: nil)

        #expect(context1.nodeId == nil)
        #expect(context1.description == "")
        #expect(context1.stageId == nil)
        #expect(context1.sourceMap == nil)

        #expect(context2.nodeId != nil)
        #expect(context2.description == "")
        #expect(context2.stageId == nil)
        #expect(context2.sourceMap == nil)

        let error = BuildEventError(type: .executionFailed, description: "", diagnostics: [:])
        #expect(error.description == "")
        #expect(error.diagnostics?.isEmpty == true)
    }

    @Test("Extreme values")
    func testExtremeValues() {
        let longString = String(repeating: "a", count: 10000)
        let context = ReportContext(nodeId: UUID(), description: longString)

        #expect(context.description.count == 10000)
        #expect(context.description.count == 10000)

        let event1 = BuildEvent.buildStarted(totalOperations: Int.max, stages: Int.max, timestamp: Date.distantFuture)
        let event2 = BuildEvent.operationFinished(context: context, duration: Double.infinity)
        let event3 = BuildEvent.operationProgress(context: context, fraction: -1.0)
        let event4 = BuildEvent.operationProgress(context: context, fraction: 2.0)

        switch event1 {
        case .buildStarted(let ops, let stages, let ts):
            #expect(ops == Int.max)
            #expect(stages == Int.max)
            #expect(ts == Date.distantFuture)
        default:
            Issue.record("Expected buildStarted event")
        }

        switch event2 {
        case .operationFinished(_, let duration):
            #expect(duration == Double.infinity)
        default:
            Issue.record("Expected operationFinished event")
        }

        switch event3 {
        case .operationProgress(_, let fraction):
            #expect(fraction == -1.0)  // Should allow out-of-range values
        default:
            Issue.record("Expected operationProgress event")
        }

        switch event4 {
        case .operationProgress(_, let fraction):
            #expect(fraction == 2.0)  // Should allow out-of-range values
        default:
            Issue.record("Expected operationProgress event")
        }
    }

    // MARK: - Real-world Scenarios

    @Test("Typical build event sequence")
    func testTypicalBuildEventSequence() {
        var events: [BuildEvent] = []
        let buildStart = Date()

        // Build starts
        events.append(.buildStarted(totalOperations: 10, stages: 3, timestamp: buildStart))

        // Stage 1: Preparation
        events.append(.stageStarted(stageName: "preparation", timestamp: buildStart.addingTimeInterval(0.1)))

        let prepContext = ReportContext(
            nodeId: UUID(),
            stageId: "preparation",
            description: "Preparing build environment",
            sourceMap: SourceMap(file: "Buildfile", line: 1, column: 1)
        )
        events.append(.operationStarted(context: prepContext))
        events.append(.operationLog(context: prepContext, message: "Setting up directories"))
        events.append(.operationFinished(context: prepContext, duration: 0.5))

        events.append(.stageCompleted(stageName: "preparation", timestamp: buildStart.addingTimeInterval(0.6)))

        // Stage 2: Compilation
        events.append(.stageStarted(stageName: "compilation", timestamp: buildStart.addingTimeInterval(0.7)))

        let compileContext = ReportContext(
            nodeId: UUID(),
            stageId: "compilation",
            description: "Compiling sources"
        )
        events.append(.operationStarted(context: compileContext))
        events.append(.operationProgress(context: compileContext, fraction: 0.25))
        events.append(.operationProgress(context: compileContext, fraction: 0.5))
        events.append(.operationProgress(context: compileContext, fraction: 0.75))
        events.append(.operationFinished(context: compileContext, duration: 2.0))

        // Cache hit
        let cacheContext = ReportContext(
            nodeId: UUID(),
            stageId: "compilation",
            description: "Compiling cached module"
        )
        events.append(.operationStarted(context: cacheContext))
        events.append(.operationCacheHit(context: cacheContext))

        events.append(.stageCompleted(stageName: "compilation", timestamp: buildStart.addingTimeInterval(3.0)))

        // Stage 3: Testing (with failure)
        events.append(.stageStarted(stageName: "testing", timestamp: buildStart.addingTimeInterval(3.1)))

        let testContext = ReportContext(
            nodeId: UUID(),
            stageId: "testing",
            description: "Running unit tests"
        )
        events.append(.operationStarted(context: testContext))
        events.append(
            .operationFailed(
                context: testContext,
                error: BuildEventError(
                    type: .executionFailed,
                    description: "Test failed: testExample",
                    diagnostics: ["expected": "42", "actual": "41", "location": "TestFile.swift:25"]
                )
            ))

        events.append(.stageCompleted(stageName: "testing", timestamp: buildStart.addingTimeInterval(4.0)))

        // Build completes with failure
        events.append(.buildCompleted(success: false, timestamp: buildStart.addingTimeInterval(4.1)))

        // Verify sequence
        #expect(events.count == 20)
        #expect(events.first != nil)
        #expect(events.last != nil)

        if case .buildStarted = events.first! {
            // Expected
        } else {
            Issue.record("Expected build to start with buildStarted event")
        }

        if case .buildCompleted(let success, _) = events.last! {
            #expect(success == false)
        } else {
            Issue.record("Expected build to end with buildCompleted event")
        }
    }

    @Test("IR event workflow")
    func testIREventWorkflow() {
        var events: [BuildEvent] = []
        let irContext = ReportContext(nodeId: UUID(), description: "IR Analysis")

        // IR analysis workflow
        events.append(.irEvent(context: irContext, type: .graphStarted))
        events.append(.irEvent(context: irContext, type: .analyzing))

        // Add stages
        events.append(.irEvent(context: irContext, type: .stageAdded))
        events.append(.irEvent(context: irContext, type: .stageAdded))

        // Add nodes
        events.append(.irEvent(context: irContext, type: .nodeAdded))
        events.append(.irEvent(context: irContext, type: .nodeAdded))
        events.append(.irEvent(context: irContext, type: .nodeAdded))

        // Complete
        events.append(.irEvent(context: irContext, type: .graphCompleted))

        // Verify workflow
        #expect(events.count == 8)

        var graphStarted = false
        var analyzing = false
        var stagesAdded = 0
        var nodesAdded = 0
        var graphCompleted = false

        for event in events {
            if case .irEvent(_, let type) = event {
                switch type {
                case .graphStarted:
                    graphStarted = true
                case .analyzing:
                    analyzing = true
                case .stageAdded:
                    stagesAdded += 1
                case .nodeAdded:
                    nodesAdded += 1
                case .graphCompleted:
                    graphCompleted = true
                case .validating, .error, .warning:
                    break
                }
            }
        }

        #expect(graphStarted == true)
        #expect(analyzing == true)
        #expect(stagesAdded == 2)
        #expect(nodesAdded == 3)
        #expect(graphCompleted == true)
    }
}
