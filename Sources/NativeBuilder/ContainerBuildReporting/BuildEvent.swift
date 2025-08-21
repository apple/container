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

/// Represents all types of events that can occur during a build.
///
/// Design rationale:
/// - Single enum to capture all build activity (operations, logs, progress)
/// - Each case carries relevant context and data
/// - Sendable and Codable for thread safety and serialization
/// - Extensible for future event types
public enum BuildEvent: Sendable, Codable {
    // MARK: - Build Lifecycle Events

    /// Build has started
    case buildStarted(totalOperations: Int, stages: Int, timestamp: Date)

    /// Build has completed
    case buildCompleted(success: Bool, timestamp: Date)

    // MARK: - Stage Events

    /// A build stage has started
    case stageStarted(stageName: String, timestamp: Date)

    /// A build stage has completed
    case stageCompleted(stageName: String, timestamp: Date)

    // MARK: - Operation Events

    /// An operation has started executing
    case operationStarted(context: ReportContext)

    /// An operation has finished successfully
    case operationFinished(context: ReportContext, duration: TimeInterval)

    /// An operation has failed
    case operationFailed(context: ReportContext, error: BuildEventError)

    /// An operation was satisfied from cache
    case operationCacheHit(context: ReportContext)

    /// Progress update for a long-running operation
    case operationProgress(context: ReportContext, fraction: Double)

    /// Log output from an operation
    case operationLog(context: ReportContext, message: String)

    // MARK: - IR Events

    /// IR construction or analysis event
    case irEvent(context: ReportContext, type: IREventType)
}

/// Context information for events.
///
/// Design rationale:
/// - Provides provenance for each event
/// - Enables grouping and correlation of events
/// - Rich context for UI/logging decisions
/// - Source mapping for precise error location
public struct ReportContext: Sendable, Codable {
    /// Unique identifier for the node (if applicable)
    public let nodeId: UUID?

    /// Identifier for the build stage (if applicable)
    public let stageId: String?

    /// Human-readable description
    public let description: String

    /// Timestamp when the event was generated
    public let timestamp: Date

    /// Source location mapping (if available)
    public let sourceMap: SourceMap?

    public init(
        nodeId: UUID? = nil,
        stageId: String? = nil,
        description: String,
        timestamp: Date = Date(),
        sourceMap: SourceMap? = nil
    ) {
        self.nodeId = nodeId
        self.stageId = stageId
        self.description = description
        self.timestamp = timestamp
        self.sourceMap = sourceMap
    }

    /// Convenience init for operation events (backwards compatibility)
    public init(
        nodeId: UUID,
        stageId: String,
        operationDescription: String,
        timestamp: Date = Date()
    ) {
        self.init(
            nodeId: nodeId,
            stageId: stageId,
            description: operationDescription,
            timestamp: timestamp
        )
    }
}

/// Source location information for precise error reporting
public struct SourceMap: Sendable, Codable {
    /// Source file path (e.g., Dockerfile path)
    public let file: String?

    /// Line number (1-based)
    public let line: Int?

    /// Column number (1-based)
    public let column: Int?

    /// Source text snippet for context
    public let snippet: String?

    public init(file: String? = nil, line: Int? = nil, column: Int? = nil, snippet: String? = nil) {
        self.file = file
        self.line = line
        self.column = column
        self.snippet = snippet
    }
}

/// Types of IR events
public enum IREventType: String, Sendable, Codable {
    case graphStarted = "graph_started"
    case graphCompleted = "graph_completed"
    case stageAdded = "stage_added"
    case nodeAdded = "node_added"
    case analyzing = "analyzing"
    case validating = "validating"
    case error = "error"
    case warning = "warning"
}

/// Error information for build events.
///
/// Design rationale:
/// - Structured error representation for serialization
/// - Captures error type and description
/// - Extensible with diagnostics
public struct BuildEventError: Sendable, Codable {
    /// The type of failure
    public let type: FailureType

    /// Human-readable error description
    public let description: String

    /// Additional diagnostic information
    public let diagnostics: [String: String]?

    public init(
        type: FailureType,
        description: String,
        diagnostics: [String: String]? = nil
    ) {
        self.type = type
        self.description = description
        self.diagnostics = diagnostics
    }

    public enum FailureType: String, Sendable, Codable {
        case executionFailed
        case cancelled
        case invalidConfiguration
        case timeout
        case resourceExhausted
    }
}
