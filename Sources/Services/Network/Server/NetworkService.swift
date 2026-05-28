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

import ContainerResource
import ContainerXPC
import ContainerizationExtras

/// A network service
public protocol NetworkService: Sendable {
    /// Gets the properties of the realized network.
    func state() async throws -> NetworkState

    /// Register a hostname and allocate associated addresses.
    func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?)

    /// Return the attachment for a hostname if it is registered with the network.
    func lookup(hostname: String) async throws -> Attachment?
}
