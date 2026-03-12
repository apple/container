//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

/// Basic log handler for where simple message output is needed,
/// such as CLI commands.
public struct StderrLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public init() {}

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let data: Data
        switch logLevel {
        case .debug, .trace:
            let timestamp = isoTimestamp()
            if let metadata, !metadata.isEmpty {
                data =
                    "\(timestamp) \(message.description): \(metadata.description)\n"
                    .data(using: .utf8) ?? Data()
            } else {
                data =
                    "\(timestamp) \(message.description)\n"
                    .data(using: .utf8) ?? Data()
            }
        default:
            if let metadata, !metadata.isEmpty {
                data =
                    "\(message.description): \(metadata.description)\n"
                    .data(using: .utf8) ?? Data()
            } else {
                data =
                    "\(message.description)\n"
                    .data(using: .utf8) ?? Data()
            }
        }

        FileHandle.standardError.write(data)
    }

    private func isoTimestamp() -> String {
        let date = Date()
        var time = time_t(date.timeIntervalSince1970)
        var ms = Int(date.timeIntervalSince1970 * 1000) % 1000
        if ms < 0 { ms += 1000 }
        var tm = tm()
        gmtime_r(&time, &tm)
        let buf = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { ptr -> String in
            strftime(ptr.baseAddress!, 32, "%Y-%m-%dT%H:%M:%S", &tm)
            return String(cString: ptr.baseAddress!)
        }
        return String(format: "%@.%03dZ", buf, ms)
    }
}
