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

public struct RegistryResource: ManagedResource {
    public let id: String

    public var name: String

    public let username: String

    public var creationDate: Date

    public var modificationDate: Date

    public var labels: [String: String]

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
    public init(from registryInfo: RegistryInfo) {
        self.init(
            hostname: registryInfo.hostname,
            username: registryInfo.username,
            creationDate: registryInfo.createdDate,
            modifiedDate: registryInfo.modifiedDate
        )
    }
}
