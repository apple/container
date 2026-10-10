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

    /// Allocate a network address for a host and any additional DNS aliases.
    func allocate(hostname: String, aliases: [String] = []) async throws -> UInt32 {
        let names = Self.normalizedNames(hostname: hostname, aliases: aliases)
        guard names.allSatisfy({ !$0.isEmpty }) else {
            throw ContainerizationError(.invalidArgument, message: "hostname and aliases cannot be empty")
        }
        let hostname = names[0]

        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let index = hostnames[hostname] {
            try ensureNames(names, canMapTo: index)
            for name in names {
                hostnames[name] = index
            }
            return index
        }

        try ensureNames(names, canMapTo: nil)

        let index = try allocator.allocate()
        for name in names {
            hostnames[name] = index
        }

        return index
    }

    /// Free an allocated network address by hostname.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        let hostname = Self.normalized(hostname: hostname)
        guard let index = hostnames[hostname] else {
            return nil
        }

        let names = hostnames.compactMap { name, mappedIndex in
            mappedIndex == index ? name : nil
        }
        for name in names {
            hostnames.removeValue(forKey: name)
        }

        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        let hostname = Self.normalized(hostname: hostname)
        return hostnames[hostname]
    }

    private static func normalized(hostname: String) -> String {
        let hostname = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        return hostname.lowercased()
    }

    private static func normalizedNames(hostname: String, aliases: [String]) -> [String] {
        var seen = Set<String>()
        return ([hostname] + aliases)
            .map(Self.normalized(hostname:))
            .filter { seen.insert($0).inserted }
    }

    private func ensureNames(_ names: [String], canMapTo expectedIndex: UInt32?) throws {
        for name in names {
            guard let index = hostnames[name] else {
                continue
            }
            if let expectedIndex, expectedIndex == index {
                continue
            }
            throw ContainerizationError(.exists, message: "hostname already exists: \(name)")
        }
    }
}
