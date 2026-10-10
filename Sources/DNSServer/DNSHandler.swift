//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

/// Context for a DNS request.
public struct DNSRequestContext: Sendable {
    /// The source IP address for the datagram, if available.
    public let remoteIPAddress: String?

    /// The source port for the datagram, if available.
    public let remotePort: Int?

    public init(remoteIPAddress: String? = nil, remotePort: Int? = nil) {
        self.remoteIPAddress = remoteIPAddress
        self.remotePort = remotePort
    }
}

/// Protocol for implementing custom DNS handlers.
public protocol DNSHandler {
    /// Attempt to answer a DNS query
    /// - Parameter query: the query message
    /// - Throws: a server failure occurred during the query
    /// - Returns: The response message for the query, or nil if the request
    ///   is not within the scope of the handler.
    func answer(query: Message) async throws -> Message?

    /// Attempt to answer a DNS query with request context.
    /// - Parameters:
    ///   - query: the query message
    ///   - context: request context such as the source address.
    /// - Throws: a server failure occurred during the query
    /// - Returns: The response message for the query, or nil if the request
    ///   is not within the scope of the handler.
    func answer(query: Message, context: DNSRequestContext) async throws -> Message?
}

extension DNSHandler {
    public func answer(query: Message, context: DNSRequestContext) async throws -> Message? {
        try await answer(query: query)
    }
}
