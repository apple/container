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

/// A rule that matches DNS names, as written in an alias.
///
/// The string form is the name itself for an exact rule (`api.example.test`) and the name with a
/// leading dot for a subtree rule (`.example.test`). A subtree rule matches every name below its
/// base, at one or more labels, and does not match the base itself, which follows the wildcard
/// semantics of RFC 4592. Matching is by label, so `evilexample.test` is not below `example.test`.
public enum DNSMatchRule: Sendable, Hashable, CustomStringConvertible {
    /// Matches exactly one name.
    case exact(DNSName)
    /// Matches every name below the base name.
    case subtree(DNSName)

    /// Creates a rule from its string form.
    ///
    /// The name is validated and lowercased by `DNSName`, and a trailing dot is accepted.
    ///
    /// - Throws: `DNSBindError.invalidName` if the name is empty or is only a dot, contains `*`,
    ///   or is not a valid DNS name.
    public init(_ string: String) throws {
        guard !string.contains("*") else {
            throw DNSBindError.invalidName(
                "\"\(string)\" contains \"*\"; use a leading dot to match every name below a domain, for example \".example.test\""
            )
        }

        let isSubtree = string.hasPrefix(".")
        let name = try DNSName(isSubtree ? String(string.dropFirst()) : string)
        guard !name.labels.isEmpty else {
            throw DNSBindError.invalidName("\"\(string)\" does not name a host")
        }
        self = isSubtree ? .subtree(name) : .exact(name)
    }

    /// The normalized string form: lowercase, without a trailing dot, and with a leading dot for a subtree.
    public var description: String {
        switch self {
        case .exact(let name):
            return name.pqdn
        case .subtree(let base):
            return "." + base.pqdn
        }
    }

    /// Returns whether the rule matches the name.
    public func matches(_ name: DNSName) -> Bool {
        switch self {
        case .exact(let exact):
            return name == exact
        case .subtree(let base):
            return name.labels.count > base.labels.count && name.labels.suffix(base.labels.count) == base.labels
        }
    }

    /// Returns the names a subtree rule would need as its base to match `name`.
    ///
    /// These are the proper suffixes of `name` that have at least one label, longest first. For
    /// `a.b.example.test` they are `b.example.test`, `example.test` and `test`. A lookup that
    /// wants the most specific subtree tries them in order.
    public static func subtreeBases(of name: DNSName) -> [DNSName] {
        (1..<max(name.labels.count, 1)).compactMap { try? DNSName(labels: Array(name.labels.dropFirst($0))) }
    }
}
