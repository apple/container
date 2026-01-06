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

import ContainerAPIService
import ContainerizationExtras
import DNSServer
import Logging

/// Adapter that connects NetworksService events to DNSServerManager.
/// Binds DNS listeners to network gateway addresses when networks start.
public struct DNSBindingAdapter: NetworkDNSDelegate, Sendable {
    private let dnsManager: DNSServerManager
    private let log: Logger?

    public init(dnsManager: DNSServerManager, log: Logger? = nil) {
        self.dnsManager = dnsManager
        self.log = log
    }

    public func networkDidStart(gateway: IPv4Address) async {
        let host = gateway.description
        do {
            try await dnsManager.addListener(host: host)
        } catch {
            log?.error("Failed to add DNS listener for \(host): \(error)")
        }
    }

    public func networkDidStop(gateway: IPv4Address) async {
        let host = gateway.description
        await dnsManager.removeListener(host: host)
    }
}
