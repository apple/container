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

import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerNetworkServer

/// A store that keeps leases the way a file would, so what is written down
/// can be read back by an allocator that was not there when it was written.
private actor RememberingStore: AttachmentLeaseStore {
    private var leases: [String: AttachmentAllocator.Lease] = [:]

    func load() async -> [AttachmentAllocator.Lease] {
        Array(leases.values)
    }

    func save(_ lease: AttachmentAllocator.Lease) async {
        leases[lease.id] = lease
    }
}

struct AttachmentAllocatorTest {
    /// A hardware address to attach with, different for each host so that a
    /// remembered one is recognizable.
    private func mac(_ last: UInt8) -> MACAddress {
        MACAddress(0xf200_0000_0000 | UInt64(last))
    }

    private func allocate(_ allocator: AttachmentAllocator, _ hostname: String, _ last: UInt8 = 1) async throws -> UInt32 {
        try await allocator.allocate(hostname: hostname, macAddress: mac(last)).index
    }

    @Test func testAllocateSingleHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocate(allocator, "test-host")

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAllocateSameHostnameTwice() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocate(allocator, "test-host")
        let address2 = try await allocate(allocator, "test-host")

        #expect(address1 == address2)
    }

    @Test func testAllocateMultipleHostnames() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocate(allocator, "host1")
        let address2 = try await allocate(allocator, "host2")
        let address3 = try await allocate(allocator, "host3")

        #expect(address1 != address2)
        #expect(address2 != address3)
        #expect(address1 != address3)
    }

    @Test func testLookupAllocatedHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocate(allocator, "test-host")
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")

        #expect(lookedUpAddress == allocatedAddress)
    }

    @Test func testLookupNonExistentHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.lookup(hostname: "non-existent")

        #expect(address == nil)
    }

    @Test func testDeallocateAllocatedHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocate(allocator, "test-host")
        let deallocatedAddress = try await allocator.deallocate(hostname: "test-host")

        #expect(deallocatedAddress == allocatedAddress)

        // After deallocation, lookup should return nil
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")
        #expect(lookedUpAddress == nil)
    }

    @Test func testDeallocateNonExistentHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let deallocatedAddress = try await allocator.deallocate(hostname: "non-existent")

        #expect(deallocatedAddress == nil)
    }

    @Test func testHostAttachingAgainIsGivenWhatItHad() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let first = try await allocator.allocate(hostname: "test-host", macAddress: mac(7))
        _ = try await allocator.deallocate(hostname: "test-host")
        // Another host takes an address in between, so the answer is the one
        // remembered rather than the one next in line.
        _ = try await allocate(allocator, "other-host", 8)
        let again = try await allocator.allocate(hostname: "test-host", macAddress: mac(9))

        #expect(again.index == first.index)
        #expect(again.macAddress == first.macAddress)
    }

    @Test func testWhatAHostWasGivenOutlivesTheAllocator() async throws {
        let store = RememberingStore()

        let first = try await AttachmentAllocator(lower: 100, size: 10, store: store)
            .allocate(hostname: "test-host", macAddress: mac(3))

        let second = try await AttachmentAllocator(lower: 100, size: 10, store: store)
            .allocate(hostname: "test-host", macAddress: mac(4))

        #expect(second.index == first.index)
        #expect(second.macAddress == first.macAddress)
    }

    @Test func testAllocateUntilFull() async throws {
        let size = 5
        let allocator = try await AttachmentAllocator(lower: 100, size: size)

        // Allocate up to the limit
        for i in 0..<size {
            _ = try await allocate(allocator, "host\(i)")
        }

        // Attempting to allocate one more should throw
        await #expect(throws: Error.self) {
            try await allocate(allocator, "extra-host")
        }
    }

    @Test func testDeallocateAndReallocateDifferentHostname() async throws {
        let size = 3
        let allocator = try await AttachmentAllocator(lower: 100, size: size)

        // Fill up the allocator
        let address1 = try await allocate(allocator, "host1")
        let address2 = try await allocate(allocator, "host2")
        let address3 = try await allocate(allocator, "host3")

        // Deallocate one
        let released2 = try await allocator.deallocate(hostname: "host2")
        #expect(address2 == released2)

        // Should be able to allocate a new hostname now
        let newAddress = try await allocate(allocator, "host4")
        #expect(newAddress >= 100)
        #expect(newAddress < 103)

        // The three remaining allocations should all be different
        let finalAddress1 = try await allocator.lookup(hostname: "host1")
        let finalAddress3 = try await allocator.lookup(hostname: "host3")
        let finalAddress4 = try await allocator.lookup(hostname: "host4")

        #expect(finalAddress1 == address1)
        #expect(finalAddress3 == address3)
        #expect(finalAddress4 == newAddress)
    }

    @Test func testMultipleDeallocationsOfSameHostname() async throws {
        let allocator = try await AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocate(allocator, "test-host")

        let firstDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(firstDeallocate == address)

        // Second deallocation should return nil since it's already deallocated
        let secondDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(secondDeallocate == nil)
    }
}
