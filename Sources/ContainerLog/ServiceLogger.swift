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
    /// Set up the logging system and create a root logger.
    ///
    /// - Parameters:
    ///   - label: A unique identifier for the application.
    ///   - category: An identifier for the application subsystem.
    ///   - metadata: Metadata to include for all messsages. A message
    ///     specific value for a duplicate key overrides these values.
    ///   - debug: Enable debug logging.
    ///   - logPath: If supplied, create log files under the named
    ///     directory. Otherwise, log to the OS log facility.
    /// - Returns: The root logger.
    public static func bootstrap(
        label: String = "com.apple.container",
        category: String,
        metadata: [String: String] = [:],
        debug: Bool,
        logPath: FilePath?
    ) -> Logger {
        // Select the log handler and bootstrap logging.
        LoggingSystem.bootstrap { label in
            if let logPath {
                if let handler = try? FileLogHandler(
                    label: label,
                    category: category,
                    path: logPath
                ) {
                    return handler
                }
            }
            return OSLogHandler(label: label, category: category)
        }

        // Configure log level and metadata.
        var log = Logger(label: label)
        if debug {
            log.logLevel = .debug
        }
        for (key, value) in metadata {
            log[metadataKey: key] = "\(value)"
        }

        // Log an error if for some reason FileLogHandler init failed.
        if let logPath, log.handler as? OSLogHandler != nil {
            log.error(
                "unable to initialize FileLogHandler, using OSLogHandler",
                metadata: [
                    "logPath": "\(logPath)"
                ])
        }

        return log
    }
}
