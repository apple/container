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
import ContainerizationExtras

/// A network service
public protocol NetworkService: Sendable {
    /// Gets the properties of the realized network.
    func status() async throws -> NetworkStatus

    /// Register a hostname and aliases that resolve to it, and allocate associated addresses.
    ///
    /// Each alias is in its normalized string form: an exact name, or a name with a leading dot that
    /// matches every name below it.
    func allocate(
        hostname: String,
        macAddress: MACAddress?,
        aliases: [String],
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?)

    /// Look up a name on the network.
    ///
    /// The name can be the hostname of an attachment, an alias of it, or a name below a subtree alias.
    /// Returns the attachment that the name resolves to and how the name matched, or nil if the name
    /// does not resolve on this network.
    func lookup(name: String) async throws -> NetworkMatch?
}
