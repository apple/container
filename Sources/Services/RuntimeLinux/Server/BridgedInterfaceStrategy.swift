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
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Logging

/// Interface strategy for containers that use macOS's custom network feature.
@available(macOS 26, *)
public struct BridgedInterfaceStrategy: InterfaceStrategy {
    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    public func toInterface(attachment: Attachment, interfaceIndex: Int, additionalData: XPCMessage?) throws -> Interface {
        guard let bridgeDictionary = additionalData?.xpcDictionary(key: NetworkKeys.additionalData.rawValue) else {
            throw ContainerizationError(.internalError, message: "did not receive bridge dictionary in interface additional message")
        }
        let bridgeData = XPCMessage(object: bridgeDictionary)

        guard let ifaceName = bridgeData.string(key: BridgeNetworkKeys.hostInterface.rawValue)
        else {
            throw ContainerizationError(.invalidState, message: "bridge network missing host interface name")
        }
        guard let containerBridgeEndpoint = bridgeData.fileHandle(key: BridgeNetworkKeys.sandboxEndpoint.rawValue) else {
            return BridgedNetworkInterface(
                hostInterfaceName: ifaceName,
                macAddress: attachment.macAddress
            )
        }

        return FileHandleNetworkInterface(
            fileHandle: containerBridgeEndpoint,
            macAddress: attachment.macAddress
        )
    }
}
