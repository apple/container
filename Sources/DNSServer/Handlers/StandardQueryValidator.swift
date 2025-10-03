//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// Pass standard queries to a delegate handler.
public struct StandardQueryValidator: DNSHandler {
    private let handler: DNSHandler

    /// Create the handler.
    /// - Parameter delegate: the handler that receives valid queries
    public init(handler: DNSHandler) {
        self.handler = handler
    }

    /// Ensures the query is valid before forwarding it to the delegate.
    /// - Parameter msg: the query message
    /// - Returns: the delegate response if the query is valid, and an
    ///   error response otherwise
    public func answer(query: Message) async throws -> Message? {
        // Reject response messages.
        guard query.type == .query else {
            return Message(
                id: query.id,
                type: .response,
                returnCode: .formatError,
                questions: query.questions
            )
        }

        // Standard DNS servers handle only query operations.
        guard query.operationCode == .query else {
            return Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions
            )
        }

        // Standard DNS servers only handle messages with exactly one question.
        guard query.questions.count == 1 else {
            return Message(
                id: query.id,
                type: .response,
                returnCode: .formatError,
                questions: query.questions
            )
        }

        return try await handler.answer(query: query)
    }
}
