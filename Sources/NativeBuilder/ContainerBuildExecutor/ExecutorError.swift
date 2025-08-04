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

import ContainerBuildIR
import Foundation

/// An error originating from the build executor, enriched with runtime context.
public struct ExecutorError: Error, LocalizedError {
    public let type: FailureType
    public let context: ErrorContext

    public var errorDescription: String? {
        "Execution failed: \(context.underlyingError.localizedDescription)"
    }
}

extension ExecutorError {
    /// The general category of the execution failure.
    public enum FailureType: Sendable {
        case executionFailed
        case cancelled
        case invalidConfiguration
    }

    /// Represents the detailed context of an error that occurred during a build.
    public struct ErrorContext: Sendable {
        public let operation: ContainerBuildIR.Operation  // The operation that failed
        public let underlyingError: any Error
        public let diagnostics: Diagnostics
    }

    /// Basic diagnostic information captured at failure time.
    public struct Diagnostics: Sendable {
        public let environment: [String: String]
        public let workingDirectory: String
        public let recentLogs: [String]
    }
}
