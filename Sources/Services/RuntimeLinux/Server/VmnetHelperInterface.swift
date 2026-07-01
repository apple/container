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

import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Synchronization
import Virtualization

/// A network interface backed by an external resource that needs
/// explicit teardown.
///
/// The runtime calls `teardown()` during container cleanup and on
/// bootstrap failure, so external resources are reaped deterministically
/// instead of relying on deallocation order.
public protocol ManagedInterface: Interface {
    func teardown()
}

/// A network interface backed by a datagram socket connected to a
/// vmnet-helper process that bridges guest traffic onto a physical host
/// interface.
///
/// The interface owns one end of a `SOCK_DGRAM` socketpair and the helper
/// holds the other. Closing the file handle or terminating the helper
/// tears down the data path.
public final class VmnetHelperInterface: ManagedInterface, @unchecked Sendable {
    public let ipv4Address: CIDRv4
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?
    /// The guest link MTU, applied to the interface inside the container.
    public let mtu: UInt32
    /// The frame size of the vmnet data path, as reported by
    /// vmnet-helper. Independent of the guest link MTU.
    private let vmnetMtu: UInt32

    private let fileHandle: FileHandle
    private let processMutex: Mutex<Process?>

    init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        macAddress: MACAddress?,
        mtu: UInt32,
        vmnetMtu: UInt32,
        fileHandle: FileHandle,
        helperProcess: Process
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
        self.vmnetMtu = vmnetMtu
        self.fileHandle = fileHandle
        self.processMutex = Mutex(helperProcess)
    }

    /// Terminate the vmnet-helper process. The helper also exits on its
    /// own when both socket ends close. `terminate()` is documented as a
    /// no op for a finished process, so no liveness check is needed.
    public func teardown() {
        processMutex.withLock { process in
            guard let p = process else {
                return
            }
            process = nil
            p.terminate()
        }
    }
}

extension VmnetHelperInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: self.fileHandle)
        // The frame size ceiling of the data path, not the guest link
        // MTU. The framework accepts only 1500 through 65535 and rejects
        // the VM configuration otherwise, so clamp the reported value.
        if self.vmnetMtu > 1500 {
            attachment.maximumTransmissionUnit = Int(min(self.vmnetMtu, 65535))
        }
        config.attachment = attachment
        return config
    }
}
