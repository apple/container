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

public protocol BuildParser {
    associatedtype Input
    func parse(_ input: Input) throws -> BuildGraph
}

/// Error types encountered while parsing.
/// TODO: These will be removed/enhanced
public enum ParseError: Error, Equatable {
    case invalidImage(String)
    case missingInstruction
    case invalidInstruction(String)
    case unexpectedValue
    case invalidOption(String)
    case missingRequiredField(String)
    case duplicateOptionSet(String)
    case invalidSyntax
    case invalidBoolOption(String)
    case invalidUint32Option(String)
}

/// Token represents a logical unit within a line of builder input, such as
/// a dockerfile
public enum Token: Sendable, Equatable {
    case stringLiteral(String)
    case stringList([String])
    case option(Option)
}

public struct Option: Sendable, Equatable {
    let key: String
    let value: String
    let raw: String

    init(key: String, value: String, raw: String) {
        self.key = key
        self.value = value
        self.raw = raw
    }
}
