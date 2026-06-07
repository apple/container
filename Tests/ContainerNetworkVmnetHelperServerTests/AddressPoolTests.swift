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
import Testing

@testable import ContainerNetworkVmnetHelperServer

struct AddressPoolTests {
    private func config(
        subnet: String = "192.168.1.0/24",
        gateway: String = "192.168.1.1",
        pool: ClosedRange<UInt32>? = nil
    ) throws -> VmnetHelperPhysicalNetwork.Configuration {
        try .init(
            id: "test",
            ipv4Subnet: try CIDRv4(subnet),
            ipv4Gateway: try IPv4Address(gateway),
            hostInterface: "en0",
            pool: pool,
            helperPath: nil
        )
    }

    private func value(_ s: String) throws -> UInt32 {
        try IPv4Address(s).value
    }

    // MARK: validate / isAssignable

    @Test func validateAcceptsHostAddress() throws {
        let pool = AddressPool(configuration: try config())
        #expect(throws: Never.self) {
            try pool.validate(try IPv4Address("192.168.1.50"))
        }
    }

    @Test func validateRejectsGatewayNetworkBroadcastAndOutside() throws {
        let pool = AddressPool(configuration: try config())
        for bad in ["192.168.1.1", "192.168.1.0", "192.168.1.255", "10.0.0.1"] {
            #expect(throws: ContainerizationError.self) {
                try pool.validate(try IPv4Address(bad))
            }
        }
    }

    @Test func isAssignableExcludesBoundaryAndOutsideAddresses() throws {
        let pool = AddressPool(configuration: try config())
        #expect(pool.isAssignable(try IPv4Address("192.168.1.50")))
        #expect(!pool.isAssignable(try IPv4Address("192.168.1.1")))  // gateway
        #expect(!pool.isAssignable(try IPv4Address("192.168.1.0")))  // network
        #expect(!pool.isAssignable(try IPv4Address("192.168.1.255")))  // broadcast
        #expect(!pool.isAssignable(try IPv4Address("10.0.0.1")))  // outside subnet
    }

    // MARK: reserve / release

    @Test func reserveAndReleaseTrackAllocation() throws {
        var pool = AddressPool(configuration: try config())
        let v = try value("192.168.1.50")
        #expect(!pool.isAllocated(v))
        pool.reserve(v)
        #expect(pool.isAllocated(v))
        pool.release(v)
        #expect(!pool.isAllocated(v))
    }

    // MARK: allocateFromPool

    @Test func allocateFromPoolWithoutPoolThrows() throws {
        var pool = AddressPool(configuration: try config())  // no pool
        #expect(throws: ContainerizationError.self) {
            _ = try pool.allocateFromPool()
        }
    }

    @Test func allocateFromPoolReturnsSequentialAddresses() throws {
        let lo = try value("192.168.1.10")
        var pool = AddressPool(configuration: try config(pool: lo...(lo + 2)))
        let a = try pool.allocateFromPool()
        pool.reserve(a)
        let b = try pool.allocateFromPool()
        #expect(a == lo)
        #expect(b == lo + 1)
    }

    @Test func allocateFromPoolSkipsReservedAddresses() throws {
        let lo = try value("192.168.1.10")
        var pool = AddressPool(configuration: try config(pool: lo...(lo + 2)))
        pool.reserve(lo)
        #expect(try pool.allocateFromPool() == lo + 1)
    }

    @Test func allocateFromPoolSkipsUnassignableAddresses() throws {
        // Pool spans the gateway (.1), which is not assignable and is skipped.
        let lo = try value("192.168.1.1")
        var pool = AddressPool(configuration: try config(pool: lo...(lo + 2)))
        #expect(try pool.allocateFromPool() == (try value("192.168.1.2")))
    }

    @Test func allocateFromPoolThrowsWhenExhausted() throws {
        let lo = try value("192.168.1.10")
        var pool = AddressPool(configuration: try config(pool: lo...(lo + 1)))
        pool.reserve(try pool.allocateFromPool())
        pool.reserve(try pool.allocateFromPool())
        #expect(throws: ContainerizationError.self) {
            _ = try pool.allocateFromPool()
        }
    }

    @Test func allocateFromPoolWrapsAroundCursor() throws {
        let lo = try value("192.168.1.10")
        var pool = AddressPool(configuration: try config(pool: lo...(lo + 1)))
        let a = try pool.allocateFromPool()  // lo, cursor -> lo+1
        pool.reserve(a)
        let b = try pool.allocateFromPool()  // lo+1, cursor wraps -> lo
        pool.reserve(b)
        pool.release(a)  // free lo again
        #expect(try pool.allocateFromPool() == lo)  // cursor at lo, reuses it
    }
}
