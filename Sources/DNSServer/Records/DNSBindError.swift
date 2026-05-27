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

/// Errors that can occur during DNS message serialization/deserialization.
public enum DNSBindError: Error, CustomStringConvertible {
    case marshalFailure(type: String, field: String)
    case unmarshalFailure(type: String, field: String)
    case unsupportedValue(type: String, field: String)
    case invalidName(String)
    case unexpectedOffset(type: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .marshalFailure(let type, let field):
            return "failed to marshal \(type).\(field)"
        case .unmarshalFailure(let type, let field):
            return "failed to unmarshal \(type).\(field)"
        case .unsupportedValue(let type, let field):
            return "unsupported value for \(type).\(field)"
        case .invalidName(let reason):
            return "invalid DNS name: \(reason)"
        case .unexpectedOffset(let type, let expected, let actual):
            return "unexpected offset serializing \(type): expected \(expected), got \(actual)"
        }
    }
}
