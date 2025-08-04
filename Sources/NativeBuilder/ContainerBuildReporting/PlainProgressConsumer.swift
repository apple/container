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

/// Plain text progress consumer that mimics BuildKit's progress=plain format.
///
/// Output format matches BuildKit's clean, numbered operation display:
/// ```
/// #1 [internal] load build definition
/// #1 DONE 0.1s
///
/// #2 [base 1/3] FROM alpine:latest
/// #2 CACHED
///
/// #3 [base 2/3] RUN apk add --no-cache git
/// #3 0.245 fetch https://dl-cdn.alpinelinux.org/alpine/...
/// #3 DONE 1.2s
/// ```
public final class PlainProgressConsumer: BaseProgressConsumer<PlainProgressConsumer.Configuration>, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// File handle to write output to (default: stdout)
        public let output: FileHandle

        public init(
            output: FileHandle = .standardOutput,
            includeEventIds: Bool = false,
            timestampFormat: TimestampFormat = .iso8601
        ) {
            self.output = output
        }

        public enum TimestampFormat: Sendable {
            case iso8601
            case unix
            case relative(startTime: Date)
        }
    }

    private let lock = NSLock()

    // State tracking for BuildKit-style formatting
    private var operationNumbers: [UUID: Int] = [:]
    private var operationStartTimes: [UUID: Date] = [:]
    private var nextOperationNumber = 1

    public required init(configuration: Configuration) {
        super.init(configuration: configuration)
    }

    override public func formatAndOutput(_ event: BuildEvent) async throws {
        let output = formatEvent(event)
        if !output.isEmpty {
            let data = (output + "\n").data(using: .utf8) ?? Data()
            try configuration.output.write(contentsOf: data)
        }
    }

    private func formatEvent(_ event: BuildEvent) -> String {
        lock.withLock {
            switch event {
            case .buildStarted:
                return ""  // BuildKit doesn't show explicit build start

            case .buildCompleted:
                return ""  // Let caller handle build completion messages

            case .stageStarted:
                return ""  // Stages are implicit in operation descriptions

            case .stageCompleted:
                return ""  // Stages are implicit in operation descriptions

            case .operationStarted(let context):
                guard let nodeId = context.nodeId else { return "" }
                let number = assignOperationNumber(for: nodeId)
                operationStartTimes[nodeId] = context.timestamp
                return "#\(number) \(formatOperationDescription(context.description, stage: context.stageId))"

            case .operationFinished(let context, _):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId],
                    let startTime = operationStartTimes[nodeId]
                else {
                    return ""
                }
                let duration = context.timestamp.timeIntervalSince(startTime)
                operationStartTimes.removeValue(forKey: nodeId)
                return "#\(number) DONE \(formatDuration(duration))"

            case .operationFailed(let context, let error):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return "" }
                operationStartTimes.removeValue(forKey: nodeId)
                return "#\(number) ERROR: \(error.description)"

            case .operationCacheHit(let context):
                guard let nodeId = context.nodeId else { return "" }

                // Check if this operation was already started
                let wasStarted = operationNumbers[nodeId] != nil
                let number = assignOperationNumber(for: nodeId)
                operationStartTimes.removeValue(forKey: nodeId)

                guard wasStarted else {
                    // Cache hit without prior start - show both description and CACHED
                    let description = formatOperationDescription(context.description, stage: context.stageId)
                    return "#\(number) \(description)\n#\(number) CACHED"
                }
                // Just show CACHED - the operation description was already shown
                return "#\(number) CACHED"

            case .operationProgress(let context, let fraction):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId]
                else { return "" }
                let percentage = Int(fraction * 100)
                return "#\(number) \(percentage)% complete"

            case .operationLog(let context, let message):
                guard let nodeId = context.nodeId,
                    let number = operationNumbers[nodeId],
                    let startTime = operationStartTimes[nodeId]
                else {
                    return ""
                }
                let elapsed = context.timestamp.timeIntervalSince(startTime)
                // Format log lines like BuildKit: #N elapsed message
                return "#\(number) \(String(format: "%.3f", elapsed)) \(message)"

            case .irEvent(let context, let type):
                // Format IR events based on type
                switch type {
                case .graphStarted, .graphCompleted:
                    return ""  // Don't show graph-level events in plain output
                case .stageAdded:
                    return ""  // Stage creation is implicit in BuildKit output
                case .nodeAdded:
                    return ""  // Node addition is shown when executed
                case .analyzing:
                    return "=> \(context.description)"
                case .validating:
                    return "=> \(context.description)"
                case .error:
                    if let sourceMap = context.sourceMap {
                        return "ERROR: \(context.description) at \(sourceMap.file ?? "unknown"):\(sourceMap.line ?? 0)"
                    }
                    return "ERROR: \(context.description)"
                case .warning:
                    if let sourceMap = context.sourceMap {
                        return "WARNING: \(context.description) at \(sourceMap.file ?? "unknown"):\(sourceMap.line ?? 0)"
                    }
                    return "WARNING: \(context.description)"
                }
            }
        }
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

    private func formatOperationDescription(_ description: String, stage: String? = nil) -> String {
        // Transform operation descriptions to BuildKit style
        // Examples:
        // "FROM alpine:latest" -> "[internal] load metadata for alpine:latest"
        // "RUN apk add git" -> "[stage-name] RUN apk add git"

        if description.hasPrefix("FROM ") {
            let imageName = description.replacingOccurrences(of: "FROM ", with: "")
            return "[internal] load metadata for \(imageName)"
        } else if description.hasPrefix("BaseImage:") {
            // Transform our internal representation
            let imageName = description.replacingOccurrences(of: "BaseImage: ", with: "")
            return "[internal] load metadata for \(imageName)"
        } else if let stage = stage {
            // Clean up stage name (remove "stage-" prefix if it's a UUID)
            let stageName = stage.hasPrefix("stage-") && stage.count > 12 ? "stage" : stage
            return "[\(stageName)] \(description)"
        } else {
            return "[stage] \(description)"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1.0 {
            return String(format: "%.1fs", duration)
        } else if duration < 60.0 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return String(format: "%dm%ds", minutes, seconds)
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
