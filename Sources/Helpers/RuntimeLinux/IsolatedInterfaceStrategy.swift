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

import ContainerNetworkService
import ContainerSandboxService
import ContainerXPC
import Containerization

/// Isolated container network interface strategy. This strategy prohibits
/// container to container networking, but it is the only approach that
/// works for macOS Sequoia.
struct IsolatedInterfaceStrategy: InterfaceStrategy {
    public func toInterface(attachment: Attachment, interfaceIndex: Int, additionalData: XPCMessage?) -> Interface {
        let gateway = interfaceIndex == 0 ? attachment.gateway : nil
        return NATInterface(address: attachment.address, gateway: gateway)
    }
}
