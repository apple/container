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

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// A unique identifier for the network
    public let id: String

    /// The network type
    public let mode: NetworkMode

    /// The preferred CIDR address for the subnet, if specified
    public let subnet: String?

    /// Creates a network configuration
    public init(
        id: String,
        mode: NetworkMode,
        subnet: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.subnet = subnet
    }
}
