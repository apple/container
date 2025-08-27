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
        // A global FROM-only ARG.
        guard let currentStage, !inFromContext else {
            return resolveBuildArgWithFallback(key: key)
        }

        let (found, defaultValue) = currentStage.getDeclaredArg(key)
        if found {
            // A stage-local ARG with a default value.
            if let defaultValue {
                return defaultValue
            }
            // A stage-local ARG without a default value - a redeclared global FROM-only ARG.
            return resolveBuildArgWithFallback(key: key)
        }

        // Check the predefined ARGs only.
        return resolvePredefinedArg(key: key)
    }

    private func resolvePredefinedArg(key: String) -> String? {
        guard GraphBuilder.predefinedArgs.contains(key) else {
            return nil
        }
        return ProcessInfo.processInfo.environment[key]
    }

    private func resolveBuildArgWithFallback(key: String) -> String? {
        let value = buildArgs[key]
        if value != nil {
            return value
        }
        return resolvePredefinedArg(key: key)
    }

    static let predefinedArgs: Set<String> = {
        let baseArgs = [
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "FTP_PROXY",
            "NO_PROXY",
            "ALL_PROXY",
        ]

        var allArgs = Set<String>()
        for arg in baseArgs {
            allArgs.insert(arg)
            allArgs.insert(arg.lowercased())
        }
        return allArgs
    }()

    private static let argRegex: NSRegularExpression = {
        // `${ARG}`, `${ARG:-default}`, `${ARG:+value}`, or `$ARG`
        try! NSRegularExpression(pattern: #"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?:(:-|:\+)([^}]*))?\}|([A-Za-z_][A-Za-z0-9_]*))"#)
    }()

    /// Substitute ARG variables in a string.
    /// - Parameters:
    ///   - input: The string that may contain `${ARG}`, `${ARG:-default}`, `${ARG:+value}`, or `$ARG`.
    ///   - inFromContext: Whether this substitution is happening in a FROM instruction context.
    /// - Returns: The string with ARG variables substituted.
    public func substituteArgs(_ input: String, inFromContext: Bool) -> String {
        let range = NSRange(location: 0, length: input.utf16.count)

        var result = input
        var offset = 0

        GraphBuilder.argRegex.enumerateMatches(in: input, range: range) { match, _, _ in
            guard let match else {
                return
            }

            var varName: String
            var operatorType: String? = nil
            var operatorValue: String? = nil

            // Check if it's the `${var}` format (capture group 1) or `$var` format (capture group 4).
            if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                // The `${var}` format: variable name is in capture group 1.
                guard let varRange = Range(match.range(at: 1), in: input) else {
                    return
                }
                varName = String(input[varRange])

                // The operator (capture group 2) and value (capture group 3).
                if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    if let operatorRange = Range(match.range(at: 2), in: input) {
                        operatorType = String(input[operatorRange])
                    }
                }
                if match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
                    if let valueRange = Range(match.range(at: 3), in: input) {
                        operatorValue = String(input[valueRange])
                    }
                }
            } else if match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound {
                // The `$var` format: the variable name is in capture group 4.
                guard let varRange = Range(match.range(at: 4), in: input) else {
                    return
                }
                varName = String(input[varRange])
            } else {
                return
            }

            let resolvedValue = resolveArg(key: varName, inFromContext: inFromContext)

            let replacement: String
            switch operatorType {
            case ":-":
                replacement = resolvedValue ?? operatorValue ?? ""
            case ":+":
                replacement = (resolvedValue != nil && !resolvedValue!.isEmpty) ? (operatorValue ?? "") : ""
            default:
                replacement = resolvedValue ?? ""
            }

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
