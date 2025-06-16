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

    /// Allocate a network address for a host.
    func allocate(hostname: String) async throws -> UInt32 {
        guard hostnames[hostname] == nil else {
            throw ContainerizationError(.exists, message: "Hostname \(hostname) already exists on the network")
        }
        let index = try allocator.allocate()
        hostnames[hostname] = index

        return index
    }

    /// Free an allocated network address by hostname.
    func deallocate(hostname: String) async throws {
        if let index = hostnames.removeValue(forKey: hostname) {
            try allocator.release(index)
        }
    }

    /// If no addresses are allocated, prevent future allocations and return true.
    func disableAllocator() async -> Bool {
        allocator.disableAllocator()
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[hostname]
    }
}
