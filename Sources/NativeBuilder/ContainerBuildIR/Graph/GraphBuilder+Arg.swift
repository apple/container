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

extension GraphBuilder {
    /// Add a build argument.
    /// These arguments are available within the stage.
    @discardableResult
    public func arg(_ name: String, defaultValue: String? = nil) throws -> Self {
        let operation = MetadataOperation(
            action: .declareArg(name: name, defaultValue: defaultValue)
        )
        return try add(operation)
    }

    /// Add a FROM-only build argument (ARG before the first FROM).
    /// These arguments are only available in FROM instructions, not within stages.
    @discardableResult
    public func fromOnlyArg(_ name: String, defaultValue: String? = nil) -> Self {
        buildArgs[name] = defaultValue
        return self
    }

    /// Check if there's an active stage.
    public var hasActiveStage: Bool {
        currentStage != nil
    }

    /// Resolve an ARG value.
    /// - Parameters:
    ///   - key: The ARG name to resolve.
    ///   - inFromContext: Whether this is being called from a FROM instruction context.
    /// - Returns: The resolved ARG value, or nil if not found.
    public func resolveArg(key: String, inFromContext: Bool = false) -> String? {
        // A global FROM-only ARG
        guard let currentStage, !inFromContext else {
            return buildArgs[key]
        }

        let (found, defaultValue) = currentStage.getDeclaredArg(key)
        if found {
            // A stage-local ARG with a default value
            if let defaultValue {
                return defaultValue
            }
            // A stage-local ARG without a default value - a redeclared global FROM-only ARG
            return buildArgs[key]
        }

        return nil
    }

    /// Substitute ARG variables in a string.
    /// - Parameters:
    ///   - input: The string that may contain `${ARG}` references.
    ///   - inFromContext: Whether this substitution is happening in a FROM instruction context.
    /// - Returns: The string with ARG variables substituted.
    public func substituteArgs(_ input: String, inFromContext: Bool) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#  // `${ARG}`
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: input.count)

        var result = input
        var offset = 0

        regex.enumerateMatches(in: input, range: range) { match, _, _ in
            guard let match, let varRange = Range(match.range(at: 1), in: input) else {
                return
            }

            let varName = String(input[varRange])
            let replacement = resolveArg(key: varName, inFromContext: inFromContext) ?? ""

            let matchRange = match.range
            let adjustedMatchRange = NSRange(location: matchRange.location + offset, length: matchRange.length)

            if let replacementRange = Range(adjustedMatchRange, in: result) {
                result.replaceSubrange(replacementRange, with: replacement)
                offset += replacement.utf16.count - matchRange.length
            }
        }

        return result
    }
}
