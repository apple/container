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
import Foundation
import Logging

actor AttachmentAllocator {
    /// What a host was given the last time it asked, kept so that asking
    /// again gets the same answer.
    struct Lease: Codable, Sendable {
        let index: UInt32
        let macAddress: MACAddress
    }

    private let allocator: any AddressAllocator<UInt32>
    private var allocated: [String: Lease] = [:]
    private var leases: [String: Lease] = [:]
    private let store: URL?
    private let log: Logger?

    /// - Parameters:
    ///   - store: where the leases are written, so a host keeps its address
    ///     and hardware address across restarts of this service. Nothing is
    ///     remembered without one.
    init(lower: UInt32, size: Int, store: URL? = nil, log: Logger? = nil) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
        self.store = store
        self.log = log
        self.leases = Self.read(store: store, log: log)
    }

    /// Allocate a network address for a host.
    ///
    /// A host that is already attached keeps what it has. One that attached
    /// before is given what it had, when that address is still free: an
    /// address a host answers to outlives the attachment, since the resolver
    /// entries, the hosts files, and the caches on the other side of the
    /// network all name it. Otherwise the next free address is taken, and
    /// what the host was given is written down.
    /// https://cni.dev/plugins/current/ipam/host-local/
    func allocate(hostname: String, macAddress: MACAddress) async throws -> Lease {
        if let held = allocated[hostname] {
            return held
        }

        if let remembered = leases[hostname], (try? allocator.reserve(remembered.index)) != nil {
            allocated[hostname] = remembered
            return remembered
        }

        let lease = Lease(index: try allocator.allocate(), macAddress: macAddress)
        allocated[hostname] = lease
        leases[hostname] = lease
        write()
        return lease
    }

    /// Free an allocated network address by hostname. What the host was given
    /// is still remembered, so the same host attaching again is given it back.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        guard let lease = allocated.removeValue(forKey: hostname) else {
            return nil
        }

        try allocator.release(lease.index)
        return lease.index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        allocated[hostname]?.index
    }

    private static func read(store: URL?, log: Logger?) -> [String: Lease] {
        guard let store, let data = FileManager.default.contents(atPath: store.path) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: Lease].self, from: data)
        } catch {
            // What was written down is a convenience, so a file that cannot be
            // read costs the addresses their stability and nothing else.
            log?.warning("cannot read the addresses given out before", metadata: ["path": "\(store.path)", "error": "\(error)"])
            return [:]
        }
    }

    private func write() {
        guard let store else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(leases).write(to: store, options: .atomic)
        } catch {
            log?.warning("cannot write down the addresses given out", metadata: ["path": "\(store.path)", "error": "\(error)"])
        }
    }
}
