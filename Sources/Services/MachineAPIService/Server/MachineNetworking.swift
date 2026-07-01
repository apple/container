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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras

/// Resolves the network settings persisted on a container machine into the
/// attachment configurations its backing container boots with.
enum MachineNetworking {
    /// Map `container machine set network=` specs to attachments.
    ///
    /// With no specs, the machine attaches to the builtin NAT network.
    /// Otherwise each `container run`-style spec
    /// (`name[,ip=ADDR][,mac=..][,mtu=..]`) is resolved to its network id,
    /// reusing the same parser as regular containers. Order matters. The first
    /// attachment owns the DNS hostname and is the only one given a gateway
    /// (default route and resolver), so list the egress network first. The rest
    /// register under the container id and reach only their own subnet.
    static func attachments(
        for networks: [String],
        dnsHostname: String,
        containerId: String
    ) async throws -> [AttachmentConfiguration] {
        guard !networks.isEmpty else {
            guard let defaultNetwork = try await NetworkClient().builtin else {
                throw ContainerizationError(.invalidState, message: "default network is not present")
            }
            return [
                AttachmentConfiguration(
                    network: defaultNetwork.id,
                    options: AttachmentOptions(hostname: dnsHostname)
                )
            ]
        }

        let networkClient = NetworkClient()
        var attachments: [AttachmentConfiguration] = []
        for (index, spec) in networks.enumerated() {
            let parsed = try Parser.network(spec)
            // Confirm the network exists and resolve its id.
            let resource = try await networkClient.get(id: parsed.name)
            let macAddress = try parsed.macAddress.map { try MACAddress($0) }
            let hostname = index == 0 ? dnsHostname : containerId
            attachments.append(
                AttachmentConfiguration(
                    network: resource.id,
                    options: AttachmentOptions(
                        hostname: hostname,
                        macAddress: macAddress,
                        mtu: parsed.mtu,
                        ip: parsed.ip
                    )
                )
            )
        }
        return attachments
    }
}
