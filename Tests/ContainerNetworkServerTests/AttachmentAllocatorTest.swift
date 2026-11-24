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
import DNSServer
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

    @Test func testRequestedAddressIsReserved() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let address: UInt32 = 105  // any address within [100, 110)

        let reserved = try await allocator.allocate(hostname: "test-host", requested: address)
        #expect(reserved == address)
        #expect(try await allocator.lookup(hostname: "test-host") == address)

        // Same hostname returns the existing address (dedup).
        let again = try await allocator.allocate(hostname: "test-host", requested: address)
        #expect(again == address)
    }

    @Test func testReservedAddressExcludedFromAllocate() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 3)  // pool [100, 103)
        let reserved: UInt32 = 101

        _ = try await allocator.allocate(hostname: "pinned", requested: reserved)

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
        // If the requested path skips hostnames[hostname], release never runs and the address leaks.
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let only: UInt32 = 100  // the pool's sole address

        _ = try await allocator.allocate(hostname: "sticky", requested: only)

        await #expect(throws: AllocatorError.allocatorFull) {
            try await allocator.allocate(hostname: "other")
        }

        // deallocate = the stop / session-disconnect release path.
        let released = try #require(
            try await allocator.deallocate(hostname: "sticky"),
            "deallocate must return the reserved address; nil means release never ran"
        )
        #expect(released == only)

        // Requesting the same address must now succeed - proves release ran.
        let again = try await allocator.allocate(hostname: "sticky", requested: only)
        #expect(again == only)
    }

    @Test func testRequestedFallsBackWhenTaken() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let taken = try await allocator.allocate(hostname: "owner")

        let address = try await allocator.allocate(hostname: "sticky", requested: taken)

        #expect(address != taken)
        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testRequestedFallsBackWhenRequestOutOfRange() async throws {
        // A sticky address from a previous, different subnet must not fail the start.
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "sticky", requested: 5_000)

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testRequestedStillFailsWhenPoolFull() async throws {
        // Fallback must not mask exhaustion: taken + full pool fails loud.
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let only = try await allocator.allocate(hostname: "owner")

        await #expect(throws: AllocatorError.allocatorFull) {
            try await allocator.allocate(hostname: "sticky", requested: only)
        }
    }

    @Test func testLookupIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "FOO.TEST.") == allocatedAddress)
    }

    @Test func testLookupIgnoresTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "foo.test")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
    }

    @Test func testAllocateSameHostnameDifferentCaseReusesAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "foo.test.")
        let address2 = try await allocator.allocate(hostname: "FOO.test.")

        #expect(address1 == address2)
    }

    @Test func testDeallocateIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")
        let deallocatedAddress = try await allocator.deallocate(hostname: "foo.test.")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "foo.test.") == nil)
    }

    // MARK: - Aliases

    private func rules(_ strings: String...) throws -> [DNSMatchRule] {
        try strings.map { try DNSMatchRule($0) }
    }

    @Test func testMatchResolvesHostnameAndAliasesToTheSameAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))

        #expect(try await allocator.match(name: "gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .hostname))
        #expect(try await allocator.match(name: "api.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .alias))
        #expect(try await allocator.match(name: "web.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
        #expect(try await allocator.match(name: "a.b.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
    }

    @Test func testMatchIgnoresCaseAndTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("API.test", ".GW.test"))

        #expect(try await allocator.match(name: "Api.Test")?.index == index)
        #expect(try await allocator.match(name: "WEB.gw.test.")?.index == index)
    }

    @Test func testSubtreeDoesNotMatchItsBaseOrUnrelatedNames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        try await allocator.allocate(hostname: "host.test.", aliases: rules(".example.test"))

        #expect(try await allocator.match(name: "example.test.") == nil)
        #expect(try await allocator.match(name: "evilexample.test.") == nil)
        #expect(try await allocator.match(name: "web.example.com.") == nil)
        #expect(try await allocator.match(name: "test.") == nil)
        #expect(try await allocator.match(name: "") == nil)
    }

    @Test func testHostnameBeatsAliasAndAliasBeatsSubtree() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let gateway = try await allocator.allocate(hostname: "gw.test.", aliases: rules(".gw.test"))
        let other = try await allocator.allocate(hostname: "other.test.", aliases: rules("web.gw.test"))
        let api = try await allocator.allocate(hostname: "api.gw.test.")

        #expect(try await allocator.match(name: "api.gw.test.")?.index == api)
        #expect(try await allocator.match(name: "api.gw.test.")?.kind == .hostname)
        #expect(try await allocator.match(name: "web.gw.test.")?.index == other)
        #expect(try await allocator.match(name: "web.gw.test.")?.kind == .alias)
        #expect(try await allocator.match(name: "x.gw.test.")?.index == gateway)
        #expect(try await allocator.match(name: "x.gw.test.")?.kind == .subtree(baseLabelCount: 2))
    }

    @Test func testLongestSubtreeWins() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let outer = try await allocator.allocate(hostname: "example.test.", aliases: rules(".example.test"))
        let inner = try await allocator.allocate(hostname: "sub.example.test.", aliases: rules(".sub.example.test"))

        #expect(try await allocator.match(name: "a.sub.example.test.") == AttachmentAllocator.Match(index: inner, hostname: "sub.example.test", kind: .subtree(baseLabelCount: 3)))
        #expect(try await allocator.match(name: "a.b.sub.example.test.")?.index == inner)
        #expect(try await allocator.match(name: "a.example.test.") == AttachmentAllocator.Match(index: outer, hostname: "example.test", kind: .subtree(baseLabelCount: 2)))
        // The inner base is a hostname, so it resolves as one and not as part of the outer subtree.
        #expect(try await allocator.match(name: "sub.example.test.")?.kind == .hostname)
    }

    @Test func testLookupDoesNotConsiderAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))

        #expect(try await allocator.lookup(hostname: "api.test.") == nil)
        #expect(try await allocator.lookup(hostname: "web.gw.test.") == nil)
    }

    @Test func testAliasAlreadyUsedByAnotherHostIsRejectedWithoutChangingState() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules("fresh.test", "api.test"))
        }

        #expect(try await allocator.lookup(hostname: "two.test.") == nil)
        #expect(try await allocator.match(name: "fresh.test.") == nil)
        #expect(try await allocator.match(name: "api.test.")?.hostname == "one.test")
    }

    @Test func testSubtreeAlreadyUsedByAnotherHostIsRejected() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules(".gw.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules(".gw.test"))
        }
        #expect(try await allocator.lookup(hostname: "two.test.") == nil)
    }

    @Test func testAliasMatchingAHostnameIsRejected() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.")

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules("one.test"))
        }
        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "three.test.", aliases: rules("three.test"))
        }
    }

    @Test func testHostnameMatchingAnAliasIsRejected() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "api.test.")
        }
        #expect(try await allocator.match(name: "api.test.")?.hostname == "one.test")
    }

    @Test func testAllocatingAgainWithTheSameAliasesIsIdempotent() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index1 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        let index2 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        #expect(index1 == index2)

        try await allocator.deallocate(hostname: "gw.test.")
        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.gw.test.") == nil)
    }

    @Test func testAllocatingAgainAddsNewAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test"))
        _ = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test", "two.test"))

        #expect(try await allocator.match(name: "one.test.")?.index == index)
        #expect(try await allocator.match(name: "two.test.")?.index == index)
    }

    @Test func testDeallocateRemovesAliasesAndFreesThemForReuse() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test", ".one.test"))

        try await allocator.deallocate(hostname: "one.test.")

        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.one.test.") == nil)

        let index = try await allocator.allocate(hostname: "two.test.", aliases: rules("api.test", ".one.test"))
        #expect(try await allocator.match(name: "api.test.")?.index == index)
        #expect(try await allocator.match(name: "web.one.test.")?.index == index)
    }

    @Test func testFailedAllocationDoesNotRegisterAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let first = try await allocator.allocate(hostname: "one.test.", aliases: rules("one-alias.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules("two-alias.test"))
        }

        #expect(try await allocator.match(name: "two-alias.test.") == nil)
        #expect(try await allocator.match(name: "one-alias.test.")?.index == first)
    }
}
