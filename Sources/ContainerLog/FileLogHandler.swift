//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import Logging
import SystemPackage

/// Log handler that appends messages to a file, without any
/// rotation or truncation strategy. Use for development purposes only.
public struct FileLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]

    private let label: String
    private let category: String
    private let fileHandle: FileHandle

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    /// Create a log handler that appends to the specified file.
    ///
    /// - Parameters:
    ///   - label: A unique identifier for the application.
    ///   - category: An identifier for the application subsystem.
    ///   - path: The log file location. The log handler creates the
    ///     file and parent directory if needed.
    /// - Returns: The log handler.
    public init(label: String, category: String, path: FilePath) throws {
        self.label = label
        self.category = category
        let parentPath = path.removingLastComponent()
        try FileManager.default.createDirectory(atPath: parentPath.string, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.string) {
            FileManager.default.createFile(atPath: path.string, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path.string) else {
            throw FileLogFailure.openFailed
        }
        self.fileHandle = handle
        self.fileHandle.seekToEndOfFile()
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter
        }()
        let timestamp = timestampFormatter.string(from: Date())

        // Merge logger-level metadata with per-message metadata
        var effectiveMetadata = self.metadata
        if let metadata {
            effectiveMetadata.merge(metadata) { _, new in new }
        }

        let text: String
        if !effectiveMetadata.isEmpty {
            text = "\(timestamp) [\(level)] \(label) \(category) \(effectiveMetadata.description): \(message)\n"
        } else {
            text = "\(timestamp) [\(level)] \(label): \(category) \(message)\n"
        }
        if let data = text.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    /// Failures relating to the log handler.
    public enum FileLogFailure: Error {
        /// The log handler could not open the log file.
        case openFailed
    }
}
