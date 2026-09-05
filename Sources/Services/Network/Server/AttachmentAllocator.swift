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

actor AttachmentAllocator {
    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: UInt32] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Map `hostname` to an index (existing if known, else `allocateIndex()`).
    private func register(hostname: String, allocateIndex: () throws -> UInt32) throws -> UInt32 {
        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let index = hostnames[hostname] {
            return index
        }

        let index = try allocateIndex()
        hostnames[hostname] = index
        return index
    }

    /// Allocate a network address for a host.
    func allocate(hostname: String) async throws -> UInt32 {
        try register(hostname: hostname) { try allocator.allocate() }
    }

    /// Reserve a specific address for a host.
    func reserve(hostname: String, address: UInt32) async throws -> UInt32 {
        try register(hostname: hostname) {
            try allocator.reserve(address)
            return address
        }
    }

    /// Reserve `requested` if free, else allocate fresh; `allocatorFull` still propagates.
    func acquire(hostname: String, requested: UInt32?) async throws -> UInt32 {
        guard let requested else {
            return try await allocate(hostname: hostname)
        }
        do {
            return try await reserve(hostname: hostname, address: requested)
        } catch AllocatorError.alreadyAllocated, AllocatorError.invalidAddress {
            // Address taken, or out of range after a subnet change — reassign.
            return try await allocate(hostname: hostname)
        }
    }

    /// Free an allocated network address by hostname.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        guard let index = hostnames.removeValue(forKey: hostname) else {
            return nil
        }

        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[hostname]
    }
}
