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

import Logging
import SystemPackage

/// Common logging setup for application services.
public struct ServiceLogger {
    /// Create a logger
    public static func bootstrap(
        category: String,
        label: String = "com.apple.container",
        metadata: [String: String] = [:],
        debug: Bool,
        logPath: FilePath?
    ) -> Logger {
        LoggingSystem.bootstrap { label in
            if let logPath {
                if let handler = try? FileLogHandler(label: label, path: logPath) {
                    return handler
                }
            }
            return OSLogHandler(label: label, category: category)
        }
        var log = Logger(label: label)
        if debug {
            log.logLevel = .debug
        }
        for (key, value) in metadata {
            log[metadataKey: key] = "\(value)"
        }
        return log
    }
}
