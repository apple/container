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

import ContainerResource
import ContainerizationError
import ContainerizationExtras
import DNSServer

actor AttachmentAllocator {
    /// The kind of name that matched a query.
    enum MatchKind: Sendable, Equatable {
        /// The hostname of an attachment.
        case hostname
        /// An exact alias of an attachment.
        case alias
        /// A subtree alias of an attachment, with the number of labels in its base.
        case subtree(baseLabelCount: Int)
    }

    /// The attachment that a name resolves to.
    struct Match: Sendable, Equatable {
        /// The allocator index of the attachment.
        let index: UInt32
        /// The canonical hostname of the attachment, which is not necessarily the name that matched.
        let hostname: String
        let kind: MatchKind
    }

    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: UInt32] = [:]
    // Exact aliases, as the canonical alias mapped to the canonical hostname that owns it.
    private var exactAliases: [String: String] = [:]
    // Subtree aliases, as the base name mapped to the canonical hostname that owns it.
    private var subtreeAliases: [DNSName: String] = [:]
    // The aliases registered for each canonical hostname, so that they can be removed with it.
    private var aliasesByHostname: [String: [DNSMatchRule]] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Allocate a network address for a host, and register aliases that resolve to it.
    ///
    /// The allocation fails without changing any state if an alias is already in use by another host
    /// on this network, either as a hostname or as an alias.
    ///
    /// `requested` is reserved if free, else a fresh address is allocated.
    ///
    /// - Throws: `ContainerizationError` with code `.exists` if a name is already in use;
    ///   `AllocatorError.allocatorFull` if no address is free.
    @discardableResult
    func allocate(hostname: String, aliases: [DNSMatchRule] = [], requested: UInt32? = nil) async throws -> UInt32 {
        let hostname = AttachmentOptions.canonicalHostname(hostname)

        if hostnames[hostname] == nil, let owner = exactAliases[hostname], owner != hostname {
            throw ContainerizationError(.exists, message: "hostname \(hostname) is already an alias of \(owner)")
        }

        var newAliases = [DNSMatchRule]()
        for rule in aliases where !newAliases.contains(rule) {
            switch rule {
            case .exact:
                let name = rule.description
                if hostnames[name] != nil || name == hostname {
                    throw ContainerizationError(.exists, message: "alias \(name) is already a hostname")
                }
                if let owner = exactAliases[name] {
                    if owner == hostname {
                        continue
                    }
                    throw ContainerizationError(.exists, message: "alias \(name) is already an alias of \(owner)")
                }
            case .subtree(let base):
                if let owner = subtreeAliases[base] {
                    if owner == hostname {
                        continue
                    }
                    throw ContainerizationError(.exists, message: "alias \(rule) is already an alias of \(owner)")
                }
            }
            newAliases.append(rule)
        }

        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        let index: UInt32
        if let existing = hostnames[hostname] {
            index = existing
        } else {
            index = try acquireIndex(requested: requested)
            hostnames[hostname] = index
        }

        for rule in newAliases {
            switch rule {
            case .exact:
                exactAliases[rule.description] = hostname
            case .subtree(let base):
                subtreeAliases[base] = hostname
            }
        }
        aliasesByHostname[hostname, default: []].append(contentsOf: newAliases)

        return index
    }

    private func acquireIndex(requested: UInt32?) throws -> UInt32 {
        guard let requested else {
            return try allocator.allocate()
        }
        do {
            try allocator.reserve(requested)
            return requested
        } catch AllocatorError.alreadyAllocated, AllocatorError.invalidAddress {
            // Address taken, or out of range after a subnet change - reassign.
            return try allocator.allocate()
        }
    }

    /// Free an allocated network address by hostname, along with the aliases registered for it.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        let hostname = AttachmentOptions.canonicalHostname(hostname)
        guard let index = hostnames.removeValue(forKey: hostname) else {
            return nil
        }

        for rule in aliasesByHostname.removeValue(forKey: hostname) ?? [] {
            switch rule {
            case .exact:
                exactAliases.removeValue(forKey: rule.description)
            case .subtree(let base):
                subtreeAliases.removeValue(forKey: base)
            }
        }

        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname. Aliases are not considered.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[AttachmentOptions.canonicalHostname(hostname)]
    }

    /// Find the attachment that a name resolves to.
    ///
    /// A hostname wins over an exact alias, and an exact alias wins over a subtree alias. Among subtree
    /// aliases the one with the longest base wins.
    func match(name: String) async throws -> Match? {
        let name = AttachmentOptions.canonicalHostname(name)
        if let index = hostnames[name] {
            return Match(index: index, hostname: name, kind: .hostname)
        }
        if let owner = exactAliases[name], let index = hostnames[owner] {
            return Match(index: index, hostname: owner, kind: .alias)
        }
        guard let dnsName = try? DNSName(name) else {
            return nil
        }
        for base in DNSMatchRule.subtreeBases(of: dnsName) {
            if let owner = subtreeAliases[base], let index = hostnames[owner] {
                return Match(index: index, hostname: owner, kind: .subtree(baseLabelCount: base.labels.count))
            }
        }
        return nil
    }
}
