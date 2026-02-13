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

import ContainerizationOS
import Foundation

/// A container registry resource representing a configured registry endpoint.
///
/// Registry resources store authentication and configuration information for
/// container registries such as Docker Hub, GitHub Container Registry, or
/// private registries.
public struct RegistryResource: ManagedResource {
    /// The registry hostname that uniquely identifies this resource.
    ///
    /// For registry resources, the identifier is the same as the hostname.
    public let id: String

    /// The hostname of the registry.
    ///
    /// This value must be a valid DNS hostname or IPv6 address, optionally
    /// followed by a port number (e.g., "docker.io", "localhost:5000", "[::1]:5000").
    public var name: String

    /// The username used for authentication with this registry.
    public let username: String

    /// The time at which the system created this registry resource.
    public var creationDate: Date

    /// The time at which the registry resource was last modified.
    public var modificationDate: Date

    /// Key-value properties for the resource.
    ///
    /// The user and system may both make use of labels to read and write
    /// annotations or other metadata.
    public var labels: [String: String]

    /// Validates a registry hostname according to OCI distribution specification.
    ///
    /// This method validates that a registry hostname conforms to the domain pattern
    /// used by OCI image references. It supports DNS hostnames, IPv6 addresses, and
    /// optional port numbers.
    ///
    /// - Parameter name: The registry hostname to validate
    /// - Returns: `true` if the hostname is syntactically valid, `false` otherwise
    ///
    /// ## Valid Examples
    /// - `docker.io`
    /// - `registry.example.com`
    /// - `localhost:5000`
    /// - `[::1]:5000`
    ///
    /// ## Implementation Notes
    /// The validation logic is based on ContainerizationOCI's `Reference.domainPattern`.
    /// See <https://github.com/apple/containerization/blob/main/Sources/ContainerizationOCI/Reference.swift>
    public static func nameValid(_ name: String) -> Bool {
        // Domain validation logic based on ContainerizationOCI Reference.domainPattern
        // See: https://github.com/apple/containerization/blob/main/Sources/ContainerizationOCI/Reference.swift
        // TODO: if we have domain IP validation API, use that instead
        let domainNameComponent = "(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])"
        let optionalPort = "(?::[0-9]+)?"
        let ipv6address = "\\[(?:[a-fA-F0-9:]+)\\]"
        let domainName = "\(domainNameComponent)(?:\\.\(domainNameComponent))*"
        let host = "(?:\(domainName)|\(ipv6address))"
        let pattern = "^\(host)\(optionalPort)$"

        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Creates a new registry resource.
    ///
    /// - Parameters:
    ///   - hostname: The registry hostname (also used as the resource ID)
    ///   - username: The username for authentication
    ///   - creationDate: The time the resource was created
    ///   - modifiedDate: The time the resource was last modified
    ///   - labels: Optional key-value labels for metadata (default: empty dictionary)
    public init(
        hostname: String,
        username: String,
        creationDate: Date,
        modifiedDate: Date,
        labels: [String: String] = [:]
    ) {
        self.id = hostname
        self.name = hostname
        self.username = username
        self.creationDate = creationDate
        self.modificationDate = modifiedDate
        self.labels = labels
    }
}

extension RegistryResource {
    /// Creates a registry resource from registry information.
    ///
    /// - Parameter registryInfo: The registry information to convert
    public init(from registryInfo: RegistryInfo) {
        self.init(
            hostname: registryInfo.hostname,
            username: registryInfo.username,
            creationDate: registryInfo.createdDate,
            modifiedDate: registryInfo.modifiedDate
        )
    }
}
