//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerNetworkService
import ContainerSandboxService
import ContainerXPC
import Containerization
import ContainerizationError
import Logging
import Virtualization
import vmnet

#if !CURRENT_SDK
/// Interface strategy for containers that use macOS's custom network feature.
@available(macOS 26, *)
struct NonisolatedInterfaceStrategy: InterfaceStrategy {
    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    public func toInterface(attachment: Attachment, additionalData: XPCMessage?) throws -> Interface {
        guard let additionalData else {
            throw ContainerizationError(.invalidState, message: "network state does not contain custom network reference")
        }

        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let networkRef = vmnet_network_create_with_serialization(additionalData.underlying, &status) else {
            throw ContainerizationError(.invalidState, message: "cannot deserialize custom network reference, status \(status)")
        }

        log.info("creating NATNetworkInterface with network reference")
        return NATNetworkInterface(address: attachment.address, gateway: attachment.gateway, reference: networkRef)
    }
}
#endif
