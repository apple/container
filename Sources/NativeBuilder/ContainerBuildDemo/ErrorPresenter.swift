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

import ContainerBuildCache
import ContainerBuildExecutor
import ContainerBuildIR
import Foundation

/// A utility to present various error types in a uniform, user-friendly format.
public struct ErrorPresenter {
    /// Renders any error into a formatted string for console output.
    public func present(error: Error) -> String {
        var output: [String] = []
        output.append("❌ Build failed.")
        output.append("----------------------------------------")
        appendErrorDetails(error, to: &output, isRoot: true)
        output.append("----------------------------------------")
        return output.joined(separator: "\n")
    }

    /// A recursive helper to print error chains.
    private func appendErrorDetails(_ error: Error, to output: inout [String], isRoot: Bool) {
        let title: String
        var details: String = error.localizedDescription
        var underlyingError: (any Error)?

        switch error {
        case let err as BuildDefinitionError:
            title = "Build Definition Error"
            details = err.errorDescription ?? "No details."

        case let err as CacheError:
            title = "Cache Error"
            details = err.errorDescription ?? "No details."
            if case .storageFailed(_, let underlying) = err {
                underlyingError = underlying
            } else if case .manifestUnreadable(_, let underlying) = err {
                underlyingError = underlying
            }

        case let err as ExecutorError:
            title = "Build Execution Error"
            // Extract richer details from the context
            details = "Operation '\(String(describing: err.context.operation))' failed."
            underlyingError = err.context.underlyingError

        default:
            title = "Unexpected Error"
        }

        output.append(isRoot ? "Reason: \(title)" : "Caused by: \(title)")
        output.append("  ↳ Details: \(details)")

        // If there's a wrapped error, recurse.
        if let underlyingError = underlyingError {
            appendErrorDetails(underlyingError, to: &output, isRoot: false)
        }
    }
}
