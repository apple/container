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

/// An error that occurs during the parsing or validation of a build definition.
public enum BuildDefinitionError: Error, LocalizedError {
    /// A syntax error was found at a specific location.
    case invalidSyntax(line: Int, column: Int, message: String)

    /// An instruction or command is not recognized.
    case unknownInstruction(name: String, line: Int)

    /// An argument for an instruction is invalid.
    case invalidArgument(instruction: String, argument: String, reason: String)

    /// A required resource, like a file for a `COPY` command, was not found.
    case sourceNotFound(path: String, instructionLine: Int)

    // MARK: - LocalizedError Conformance

    public var errorDescription: String? {
        switch self {
        case .invalidSyntax(let line, let col, let msg):
            return "Syntax error on line \(line):\(col): \(msg)"
        case .unknownInstruction(let name, let line):
            return "Unknown instruction '\(name)' on line \(line)"
        case .invalidArgument(let instruction, let argument, let reason):
            return "Invalid argument '\(argument)' for instruction '\(instruction)': \(reason)"
        case .sourceNotFound(let path, let line):
            return "Source path '\(path)' not found for instruction on line \(line)"
        }
    }
}
