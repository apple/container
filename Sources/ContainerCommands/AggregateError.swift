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

/// An error type that aggregates multiple errors into one.
///
/// When displayed, each underlying error is printed on its own line.
public struct AggregateError: Swift.Error, Sendable {
    public let errors: [any Error]

    public init(_ errors: [any Error]) {
        self.errors = errors
    }
}

extension AggregateError: CustomStringConvertible {
    public var description: String {
        errors.map { String(describing: $0) }.joined(separator: "\n")
    }
}
