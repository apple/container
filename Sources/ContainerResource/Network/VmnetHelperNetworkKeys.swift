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

/// Constants shared between the bridged network plugin and the runtime
/// interface strategy.
public enum VmnetHelperNetwork {
    /// The name of the bridged network plugin.
    public static let pluginName = "container-network-vmnet-helper"

    /// Network creation options (`container network create --option key=value`).
    public enum Option: String {
        /// The physical host interface to bridge (e.g. `en0`). Required.
        case interface
        /// The IPv4 gateway address on the bridged subnet. Required.
        case gateway
        /// An optional pool for automatic allocation, formatted as
        /// `START-END` (e.g. `192.168.1.200-192.168.1.220`).
        case pool
        /// An optional override for the vmnet-helper binary path.
        case helperPath = "helper-path"
    }

    /// Keys for the additional data message returned with each
    /// allocation.
    public enum AdditionalDataKey: String {
        /// The physical host interface to bridge.
        case interface
        /// The vmnet-helper binary path override, if configured.
        case helperPath
    }
}
