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

import ContainerizationOCI

public struct ContainerConfiguration: Sendable, Codable {
    /// Identifier for the container.
    public var id: String
    /// Image used to create the container.
    public var image: ImageDescription
    /// External mounts to add to the container.
    public var mounts: [Filesystem] = []
    /// Key/Value labels for the container.
    public var labels: [String: String] = [:]
    /// System controls for the container.
    public var sysctls: [String: String] = [:]
    /// The networks the container will be added to.
    public var networks: [String] = []
    /// The DNS configuration for the container.
    public var dns: DNSConfiguration? = nil
    /// Whether to enable rosetta x86-64 translation for the container.
    public var rosetta: Bool = false
    /// The hostname for the container.
    public var hostname: String? = nil
    /// Initial or main process of the container.
    public var initProcess: ProcessConfiguration
    /// Platform for the container
    public var platform: ContainerizationOCI.Platform = .current
    /// Resource values for the container.
    public var resources: Resources = .init()
    /// Name of the runtime that supports the container
    public var runtimeHandler: String = "container-runtime-linux"

    public struct DNSConfiguration: Sendable, Codable {
        public static let defaultNameservers = ["1.1.1.1"]

        public let nameservers: [String]
        public let domain: String?
        public let searchDomains: [String]
        public let options: [String]

        public init(
            nameservers: [String] = defaultNameservers,
            domain: String? = nil,
            searchDomains: [String] = [],
            options: [String] = []
        ) {
            self.nameservers = nameservers
            self.domain = domain
            self.searchDomains = searchDomains
            self.options = options
        }
    }

    /// Resources like cpu, memory, and storage quota.
    public struct Resources: Sendable, Codable {
        /// Number of CPU cores allocated.
        public var cpus: Int = 4
        /// Memory in bytes allocated.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// Storage quota/size in bytes.
        public var storage: UInt64?

        public init() {}
    }

    public init(
        id: String,
        image: ImageDescription,
        process: ProcessConfiguration
    ) {
        self.id = id
        self.image = image
        self.initProcess = process
    }
}
