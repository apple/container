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

/// JSON progress consumer that outputs newline-delimited JSON events.
///
/// This consumer is useful for:
/// - Machine-readable output
/// - Integration with external tools
/// - Structured logging systems
///
/// Example output:
/// ```
/// {"type":"operation_started","operation":"#1","description":"[internal] load metadata for alpine:latest","timestamp":"2025-01-09T10:30:45.123Z"}
/// {"type":"operation_finished","operation":"#1","duration":0.5,"timestamp":"2025-01-09T10:30:45.623Z"}
/// ```
public final class JSONProgressConsumer: BaseProgressConsumer<JSONProgressConsumer.Configuration>, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// File handle to write output to (default: stdout)
        public let output: FileHandle

        /// Pretty print JSON (with indentation)
        public let prettyPrint: Bool

        public init(
            output: FileHandle = .standardOutput,
            prettyPrint: Bool = false
        ) {
            self.output = output
            self.prettyPrint = prettyPrint
        }
    }

    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var operationNumbers: [UUID: Int] = [:]
    private var nextOperationNumber = 1

    public required init(configuration: Configuration) {
        self.encoder = JSONEncoder()
        if configuration.prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        encoder.dateEncodingStrategy = .iso8601
        super.init(configuration: configuration)
    }

    override public func formatAndOutput(_ event: BuildEvent) async throws {
        try lock.withLock {
            if let output = try formatEventAsJSON(event) {
                try configuration.output.write(contentsOf: output)
                try configuration.output.write(contentsOf: "\n".data(using: .utf8)!)
            }
        }
    }

    private func formatEventAsJSON(_ event: BuildEvent) throws -> Data? {
        let jsonEvent: JSONEvent? = {
            switch event {
            case .buildStarted(let totalOps, let stages, let timestamp):
                return JSONEvent(
                    type: "build_started",
                    timestamp: timestamp,
                    data: [
                        "total_operations": totalOps,
                        "stages": stages,
                    ]
                )

            case .buildCompleted(let success, let timestamp):
                return JSONEvent(
                    type: "build_completed",
                    timestamp: timestamp,
                    data: ["success": success]
                )

            case .stageStarted(let stageName, let timestamp):
                return JSONEvent(
                    type: "stage_started",
                    timestamp: timestamp,
                    data: ["stage": stageName]
                )

            case .stageCompleted(let stageName, let timestamp):
                return JSONEvent(
                    type: "stage_completed",
                    timestamp: timestamp,
                    data: ["stage": stageName]
                )

            case .operationStarted(let context):
                guard let nodeId = context.nodeId else { return nil }
                let number = assignOperationNumber(for: nodeId)
                var data: [String: Any] = [
                    "operation": "#\(number)",
                    "description": context.description,
                ]
                if let stageId = context.stageId {
                    data["stage"] = stageId
                }
                return JSONEvent(
                    type: "operation_started",
                    timestamp: context.timestamp,
                    data: data
                )

            case .operationFinished(let context, let duration):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return nil }
                return JSONEvent(
                    type: "operation_finished",
                    timestamp: context.timestamp,
                    data: [
                        "operation": "#\(number)",
                        "duration": duration,
                    ]
                )

            case .operationFailed(let context, let error):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return nil }
                return JSONEvent(
                    type: "operation_failed",
                    timestamp: context.timestamp,
                    data: [
                        "operation": "#\(number)",
                        "error": error.description,
                        "error_type": error.type.rawValue,
                    ]
                )

            case .operationCacheHit(let context):
                guard let nodeId = context.nodeId else { return nil }
                let number = assignOperationNumber(for: nodeId)
                return JSONEvent(
                    type: "operation_cache_hit",
                    timestamp: context.timestamp,
                    data: [
                        "operation": "#\(number)",
                        "description": context.description,
                    ]
                )

            case .operationProgress(let context, let fraction):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return nil }
                return JSONEvent(
                    type: "operation_progress",
                    timestamp: context.timestamp,
                    data: [
                        "operation": "#\(number)",
                        "progress": fraction,
                    ]
                )

            case .operationLog(let context, let message):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return nil }
                return JSONEvent(
                    type: "operation_log",
                    timestamp: context.timestamp,
                    data: [
                        "operation": "#\(number)",
                        "message": message,
                    ]
                )

            case .irEvent(let context, let type):
                var data: [String: Any] = [
                    "event_type": type.rawValue,
                    "description": context.description,
                ]

                if let nodeId = context.nodeId {
                    data["node_id"] = nodeId.uuidString
                }
                if let stageId = context.stageId {
                    data["stage_id"] = stageId
                }
                if let sourceMap = context.sourceMap {
                    var mapData: [String: Any] = [:]
                    if let file = sourceMap.file { mapData["file"] = file }
                    if let line = sourceMap.line { mapData["line"] = line }
                    if let column = sourceMap.column { mapData["column"] = column }
                    if let snippet = sourceMap.snippet { mapData["snippet"] = snippet }
                    data["source_map"] = mapData
                }

                return JSONEvent(
                    type: "ir_event",
                    timestamp: context.timestamp,
                    data: data
                )
            }
        }()

        if let jsonEvent = jsonEvent {
            return try encoder.encode(jsonEvent)
        }
        return nil
    }

    private func assignOperationNumber(for nodeId: UUID) -> Int {
        if let existing = operationNumbers[nodeId] {
            return existing
        }
        let number = nextOperationNumber
        operationNumbers[nodeId] = number
        nextOperationNumber += 1
        return number
    }

    private struct JSONEvent: Encodable {
        let type: String
        let timestamp: Date
        let data: [String: Any]

        enum CodingKeys: String, CodingKey {
            case type
            case timestamp
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)

            // Encode the dynamic data fields
            var dataContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in data {
                let codingKey = DynamicCodingKey(stringValue: key)
                switch value {
                case let intValue as Int:
                    try dataContainer.encode(intValue, forKey: codingKey)
                case let doubleValue as Double:
                    try dataContainer.encode(doubleValue, forKey: codingKey)
                case let stringValue as String:
                    try dataContainer.encode(stringValue, forKey: codingKey)
                case let boolValue as Bool:
                    try dataContainer.encode(boolValue, forKey: codingKey)
                case let dictValue as [String: Any]:
                    // For dictionary values, we need to encode them properly
                    let nestedContainer = dataContainer.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: codingKey)
                    try encodeNestedDictionary(dictValue, to: nestedContainer)
                default:
                    // Skip unsupported types
                    break
                }
            }
        }

        private func encodeNestedDictionary(_ dict: [String: Any], to container: KeyedEncodingContainer<DynamicCodingKey>) throws {
            var container = container
            for (key, value) in dict {
                let codingKey = DynamicCodingKey(stringValue: key)
                switch value {
                case let intValue as Int:
                    try container.encode(intValue, forKey: codingKey)
                case let doubleValue as Double:
                    try container.encode(doubleValue, forKey: codingKey)
                case let stringValue as String:
                    try container.encode(stringValue, forKey: codingKey)
                case let boolValue as Bool:
                    try container.encode(boolValue, forKey: codingKey)
                default:
                    // Skip unsupported types
                    break
                }
            }
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
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
