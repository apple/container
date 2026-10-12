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
import DNSServer

/// Validates the DNS names that the network attachments of a new container claim.
///
/// A container claims the hostname of each attachment and the aliases it declares. Exact names must be
/// unique across all containers, whether they are running or stopped. A subtree alias such as
/// `.example.test` must be rooted at a name that the same attachment owns, so a container cannot claim
/// the part of the namespace below another container's name.
enum AttachmentNameValidator {
    /// The most aliases that a single attachment may declare.
    static let maximumAliasesPerAttachment = 32

    /// The fewest labels that an exact alias, or the base of a subtree alias, may have.
    ///
    /// A name with one label is not under any domain, so the system resolver never sends queries for
    /// it to the container DNS server, and an alias like that would never resolve. For a subtree it
    /// also keeps an alias from capturing a whole top-level domain.
    static let minimumAliasLabels = 2

    /// Validates the attachments of a new container against the attachments of all existing containers.
    ///
    /// Names are compared case-insensitively and without a trailing dot.
    ///
    /// - Parameters:
    ///   - networks: The attachments of the container being created.
    ///   - existing: The attachments of every existing container.
    /// - Throws: `ContainerizationError` with code `.exists` if a hostname or alias is already claimed,
    ///   and with code `.invalidArgument` if an alias is malformed or breaks a rule.
    static func validate(networks: [AttachmentConfiguration], existing: [AttachmentConfiguration]) throws {
        var claimed = Set<String>()
        for attachment in existing {
            claimed.insert(AttachmentOptions.canonicalHostname(attachment.options.hostname))
            for alias in attachment.options.aliases ?? [] {
                claimed.insert(Self.canonicalAlias(alias))
            }
        }

        var conflictingHostnames = [String]()
        for attachment in networks where claimed.contains(AttachmentOptions.canonicalHostname(attachment.options.hostname)) {
            conflictingHostnames.append(attachment.options.hostname)
        }
        guard conflictingHostnames.isEmpty else {
            throw ContainerizationError(.exists, message: "hostname(s) already exist: \(conflictingHostnames)")
        }

        let ownHostnames = Set(networks.map { AttachmentOptions.canonicalHostname($0.options.hostname) })
        var ownAliases = Set<String>()
        var conflictingAliases = [String]()
        for attachment in networks {
            let aliases = attachment.options.aliases ?? []
            guard !aliases.isEmpty else {
                continue
            }
            guard aliases.count <= Self.maximumAliasesPerAttachment else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "network \(attachment.network) has \(aliases.count) aliases, but at most \(Self.maximumAliasesPerAttachment) are allowed"
                )
            }

            var rules = [(alias: String, rule: DNSMatchRule)]()
            for alias in aliases {
                do {
                    rules.append((alias, try DNSMatchRule(alias)))
                } catch {
                    throw ContainerizationError(.invalidArgument, message: "invalid alias \"\(alias)\" for network \(attachment.network): \(error)")
                }
            }

            // The names this attachment owns, which are the roots a subtree alias may use.
            var owned = Set<DNSName>()
            if let hostname = try? DNSName(AttachmentOptions.canonicalHostname(attachment.options.hostname)) {
                owned.insert(hostname)
            }
            for case (_, .exact(let name)) in rules {
                owned.insert(name)
            }

            var seen = Set<DNSMatchRule>()
            for (alias, rule) in rules {
                guard seen.insert(rule).inserted else {
                    throw ContainerizationError(.invalidArgument, message: "alias \"\(alias)\" is listed more than once for network \(attachment.network)")
                }
                switch rule {
                case .exact(let exactName):
                    let name = rule.description
                    guard exactName.labels.count >= Self.minimumAliasLabels else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message:
                                "alias \"\(alias)\" must be a fully qualified name with at least \(Self.minimumAliasLabels) labels, such as \"api.example.test\". Configure a default DNS domain to have the domain added to a name that has none"
                        )
                    }
                    guard !ownHostnames.contains(name) else {
                        throw ContainerizationError(.invalidArgument, message: "alias \"\(alias)\" is already a hostname of the container")
                    }
                    guard ownAliases.insert(name).inserted else {
                        throw ContainerizationError(.invalidArgument, message: "alias \"\(alias)\" is declared on more than one network")
                    }
                    if claimed.contains(name) {
                        conflictingAliases.append(alias)
                    }
                case .subtree(let base):
                    guard base.labels.count >= Self.minimumAliasLabels else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message:
                                "alias \"\(alias)\" must have at least \(Self.minimumAliasLabels) labels after the leading dot. Configure a default DNS domain to have the domain added to a name that has none"
                        )
                    }
                    guard owned.contains(base) else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message:
                                "alias \"\(alias)\" must be below the hostname or an exact alias of network \(attachment.network), but \"\(base.pqdn)\" is neither"
                        )
                    }
                }
            }
        }
        guard conflictingAliases.isEmpty else {
            throw ContainerizationError(.exists, message: "alias(es) already exist: \(conflictingAliases)")
        }
    }

    /// The normalized form of an alias that was stored with an existing container.
    private static func canonicalAlias(_ alias: String) -> String {
        guard let rule = try? DNSMatchRule(alias) else {
            return AttachmentOptions.canonicalHostname(alias)
        }
        return rule.description
    }
}
