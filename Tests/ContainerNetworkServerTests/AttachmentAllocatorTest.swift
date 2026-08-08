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
import Testing

@testable import ContainerNetworkServer

struct AttachmentAllocatorTest {
    @Test func testAllocateSingleHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAllocateSameHostnameTwice() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let address2 = try await allocator.allocate(hostname: "test-host")

        #expect(address1 == address2)
    }

    @Test func testAllocateMultipleHostnames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        #expect(address1 != address2)
        #expect(address2 != address3)
        #expect(address1 != address3)
    }

    @Test func testLookupAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")

        #expect(lookedUpAddress == allocatedAddress)
    }

    @Test func testLookupNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.lookup(hostname: "non-existent")

        #expect(address == nil)
    }

    @Test func testDeallocateAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let deallocatedAddress = try await allocator.deallocate(hostname: "test-host")

        #expect(deallocatedAddress == allocatedAddress)

        // After deallocation, lookup should return nil
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")
        #expect(lookedUpAddress == nil)
    }

    @Test func testDeallocateNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let deallocatedAddress = try await allocator.deallocate(hostname: "non-existent")

        #expect(deallocatedAddress == nil)
    }

    @Test func testReallocateAfterDeallocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let released1 = try await allocator.deallocate(hostname: "test-host")
        #expect(address1 == released1)
        let address2 = try await allocator.allocate(hostname: "test-host")

        // After deallocation, allocating the same hostname should give a new address
        #expect(address2 >= 100)
        #expect(address2 < 110)
    }

    @Test func testAllocateUntilFull() async throws {
        let size = 5
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Allocate up to the limit
        for i in 0..<size {
            _ = try await allocator.allocate(hostname: "host\(i)")
        }

        // Attempting to allocate one more should throw
        await #expect(throws: Error.self) {
            try await allocator.allocate(hostname: "extra-host")
        }
    }

    @Test func testDeallocateAndReallocateDifferentHostname() async throws {
        let size = 3
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Fill up the allocator
        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        // Deallocate one
        let released2 = try await allocator.deallocate(hostname: "host2")
        #expect(address2 == released2)

        // Should be able to allocate a new hostname now
        let newAddress = try await allocator.allocate(hostname: "host4")
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
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        let firstDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(firstDeallocate == address)

        // Second deallocation should return nil since it's already deallocated
        let secondDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(secondDeallocate == nil)
    }

    @Test func testReserveSpecificAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let address: UInt32 = 105  // any address within [100, 110)

        let reserved = try await allocator.reserve(hostname: "test-host", address: address)
        #expect(reserved == address)
        #expect(try await allocator.lookup(hostname: "test-host") == address)

        // Same hostname returns the existing address (dedup), like allocate().
        let again = try await allocator.reserve(hostname: "test-host", address: address)
        #expect(again == address)
    }

    @Test func testReserveAlreadyAllocatedAddressThrows() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let taken = try await allocator.allocate(hostname: "owner")

        await #expect(throws: AllocatorError.alreadyAllocated("\(taken)")) {
            try await allocator.reserve(hostname: "thief", address: taken)
        }
    }

    @Test(arguments: [99 as UInt32, 110, 200])
    func testReserveOutOfRangeAddressThrows(address: UInt32) async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        await #expect(throws: AllocatorError.self) {
            try await allocator.reserve(hostname: "test-host", address: address)
        }
    }

    @Test func testReservedAddressExcludedFromAllocate() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 3)  // pool [100, 103)
        let reserved: UInt32 = 101

        _ = try await allocator.reserve(hostname: "pinned", address: reserved)

        let a = try await allocator.allocate(hostname: "host-a")
        let b = try await allocator.allocate(hostname: "host-b")
        #expect(a != reserved)
        #expect(b != reserved)
        #expect(a != b)

        // Pool now full (1 reserved + 2 allocated of 3): next allocate must fail.
        await #expect(throws: AllocatorError.allocatorFull) {
            try await allocator.allocate(hostname: "host-c")
        }
    }

    @Test func testReservedAddressIsReleasedOnDeallocate() async throws {
        // If reserve skips hostnames[hostname], release never runs and the address leaks.
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let only: UInt32 = 100  // the pool's sole address

        _ = try await allocator.reserve(hostname: "sticky", address: only)

        await #expect(throws: AllocatorError.allocatorFull) {
            try await allocator.allocate(hostname: "other")
        }

        // deallocate = the stop / session-disconnect release path.
        let released = try #require(
            try await allocator.deallocate(hostname: "sticky"),
            "deallocate must return the reserved address; nil means release never ran"
        )
        #expect(released == only)

        // Re-reserving the same address must now succeed — proves release ran.
        let again = try await allocator.reserve(hostname: "sticky", address: only)
        #expect(again == only)
    }

    @Test func testAcquireWithoutRequestUsesDynamicAllocate() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.acquire(hostname: "h", requested: nil)

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAcquireWithFreeRequestReservesIt() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let requested: UInt32 = 105  // any address within [100, 110)

        let address = try await allocator.acquire(hostname: "h", requested: requested)

        #expect(address == requested)
    }

    @Test func testAcquireFallsBackWhenTaken() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let taken = try await allocator.allocate(hostname: "owner")

        let address = try await allocator.acquire(hostname: "sticky", requested: taken)

        #expect(address != taken)
        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAcquireStillFailsWhenPoolFull() async throws {
        // Fallback must not mask exhaustion: taken + full pool fails loud.
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let only = try await allocator.allocate(hostname: "owner")

        await #expect(throws: AllocatorError.allocatorFull) {
            try await allocator.acquire(hostname: "sticky", requested: only)
        }
    }
}
