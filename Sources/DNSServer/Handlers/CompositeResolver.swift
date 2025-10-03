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

/// Delegates a query sequentially to handlers until one provides a response.
public struct CompositeResolver: DNSHandler {
    private let handlers: [DNSHandler]

    public init(handlers: [DNSHandler]) {
        self.handlers = handlers
    }

    public func answer(query: Message) async throws -> Message? {
        for handler in self.handlers {
            if let response = try await handler.answer(query: query) {
                return response
            }
        }

        return nil
    }
}
