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

import ContainerizationError
import ContainerizationExtras

/// IPv4 address bookkeeping for a bridged network: which addresses are in
/// use, which are valid host addresses, and a rotating cursor over the
/// optional pool.
///
/// Split out from `VmnetHelperNetworkService` so the address arithmetic is
/// pure and unit-testable; the service keeps the hostname and session
/// ownership that depend on live XPC sessions.
struct AddressPool {
    private let configuration: VmnetHelperPhysicalNetwork.Configuration
    private var allocated: Set<UInt32> = []
    /// Rotating cursor into the pool. Allocation stays O(1) amortized and a
    /// released address is not immediately reused.
    private var cursor: UInt32?

    init(configuration: VmnetHelperPhysicalNetwork.Configuration) {
        self.configuration = configuration
        self.cursor = configuration.pool?.lowerBound
    }

    func isAllocated(_ address: UInt32) -> Bool {
        allocated.contains(address)
    }

    mutating func reserve(_ address: UInt32) {
        allocated.insert(address)
    }

    mutating func release(_ address: UInt32) {
        allocated.remove(address)
    }

    /// Whether `address` is a usable host address: inside the subnet and
    /// not the gateway, network, or broadcast address.
    func isAssignable(_ address: IPv4Address) -> Bool {
        let subnet = configuration.ipv4Subnet
        return subnet.contains(address)
            && address != configuration.ipv4Gateway
            && address != subnet.lower
            && address != subnet.upper
    }

    /// Validate an explicitly requested address, throwing a descriptive
    /// error when it cannot be assigned.
    func validate(_ address: IPv4Address) throws {
        let subnet = configuration.ipv4Subnet
        guard subnet.contains(address) else {
            throw ContainerizationError(.invalidArgument, message: "address \(address) is not in subnet \(subnet)")
        }
        guard address != configuration.ipv4Gateway else {
            throw ContainerizationError(.invalidArgument, message: "address \(address) is the gateway address")
        }
        guard address != subnet.lower, address != subnet.upper else {
            throw ContainerizationError(.invalidArgument, message: "address \(address) is the network or broadcast address")
        }
    }

    /// Find the next free pool address, scanning at most one full rotation
    /// from the cursor and advancing it. Does not reserve; the caller
    /// reserves once it commits the allocation.
    mutating func allocateFromPool() throws -> UInt32 {
        guard let pool = configuration.pool, var candidate = cursor else {
            throw ContainerizationError(
                .invalidArgument,
                message: "network \(configuration.id) has no address pool; request a specific address with the ip= attachment option"
            )
        }
        // `pool.count` is an Int, so a pool spanning the full UInt32 range
        // cannot overflow the way `upperBound - lowerBound + 1` would.
        let poolSize = pool.count
        for _ in 0..<poolSize {
            let next = candidate == pool.upperBound ? pool.lowerBound : candidate + 1
            if !allocated.contains(candidate), isAssignable(IPv4Address(candidate)) {
                cursor = next
                return candidate
            }
            candidate = next
        }
        throw ContainerizationError(.invalidState, message: "no free addresses in the pool of network \(configuration.id)")
    }
}
