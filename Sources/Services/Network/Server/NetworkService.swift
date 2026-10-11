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

import ContainerNetworkClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras

/// A network service
public protocol NetworkService: Sendable {
    /// Gets the properties of the realized network.
    func status() async throws -> NetworkStatus

    /// Register a hostname and allocate associated addresses.
    func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?)

    /// Register a hostname and aliases that resolve to it, and allocate associated addresses.
    ///
    /// Each alias is in its normalized string form: an exact name, or a name with a leading dot that
    /// matches every name below it. A network service that does not support aliases does not need to
    /// implement this, and the default implementation rejects a request that has any.
    func allocate(
        hostname: String,
        macAddress: MACAddress?,
        aliases: [String],
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?)

    /// Return the attachment for a hostname if it is registered with the network.
    func lookup(hostname: String) async throws -> Attachment?

    /// Return the attachment that a name resolves to, and how the name matched.
    ///
    /// The default implementation matches hostnames only.
    func match(name: String) async throws -> NetworkMatch?
}

extension NetworkService {
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        aliases: [String],
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        guard aliases.isEmpty else {
            throw ContainerizationError(.unsupported, message: "this network does not support aliases")
        }
        return try await allocate(hostname: hostname, macAddress: macAddress, session: session)
    }

    public func match(name: String) async throws -> NetworkMatch? {
        try await lookup(hostname: name).map { NetworkMatch(attachment: $0, kind: .hostname) }
    }
}
