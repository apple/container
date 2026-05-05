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

import CVersion
import ContainerVersion
import ContainerizationExtras
import Foundation

/// Top-level configuration decoded from runtime-config.toml.
///
/// Each section maps to a nested struct. Missing keys fall back to
/// hardcoded defaults via custom `init(from:)` implementations.
final public class ContainerSystemConfig: Codable, Sendable {
    public let build: BuildConfig
    public let container: ContainerConfig
    public let dns: DNSConfig
    public let kernel: KernelConfig
    public let network: NetworkConfig
    public let registry: RegistryConfig
    public let vminit: VminitConfig

    public init(
        build: BuildConfig = .init(),
        container: ContainerConfig = .init(),
        dns: DNSConfig = .init(),
        kernel: KernelConfig = .init(),
        network: NetworkConfig = .init(),
        registry: RegistryConfig = .init(),
        vminit: VminitConfig = .init()
    ) {
        self.build = build
        self.container = container
        self.dns = dns
        self.kernel = kernel
        self.network = network
        self.registry = registry
        self.vminit = vminit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.build = try container.decodeIfPresent(BuildConfig.self, forKey: .build) ?? .init()
        self.container = try container.decodeIfPresent(ContainerConfig.self, forKey: .container) ?? .init()
        self.dns = try container.decodeIfPresent(DNSConfig.self, forKey: .dns) ?? .init()
        self.kernel = try container.decodeIfPresent(KernelConfig.self, forKey: .kernel) ?? .init()
        self.network = try container.decodeIfPresent(NetworkConfig.self, forKey: .network) ?? .init()
        self.registry = try container.decodeIfPresent(RegistryConfig.self, forKey: .registry) ?? .init()
        self.vminit = try container.decodeIfPresent(VminitConfig.self, forKey: .vminit) ?? .init()
    }
}

final public class BuildConfig: Codable, Sendable {
    public static let defaultRosetta = true
    public static let defaultCPUs = 2
    public static let defaultMemory = try! MemorySize("2048MB")
    public static var defaultImage: String {
        let tag = String(cString: get_container_builder_shim_version())
        return "ghcr.io/apple/container-builder-shim/builder:\(tag)"
    }

    public let rosetta: Bool
    public let cpus: Int
    public let memory: MemorySize
    public let image: String

    public init(
        rosetta: Bool = defaultRosetta,
        cpus: Int = defaultCPUs,
        memory: MemorySize = defaultMemory,
        image: String = defaultImage
    ) {
        self.rosetta = rosetta
        self.cpus = cpus
        self.memory = memory
        self.image = image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? Self.defaultRosetta
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? Self.defaultMemory
        self.image = try container.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
    }
}

final public class ContainerConfig: Codable, Sendable {
    public static let defaultCPUs = 4
    public static let defaultMemory = try! MemorySize("1g")

    public let cpus: Int
    public let memory: MemorySize

    public init(cpus: Int = defaultCPUs, memory: MemorySize = defaultMemory) {
        self.cpus = cpus
        self.memory = memory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? Self.defaultMemory
    }
}

final public class DNSConfig: Codable, Sendable {
    public let domain: String?

    public init(domain: String? = nil) {
        self.domain = domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain)
    }
}

final public class VminitConfig: Codable, Sendable {
    public static var defaultImage: String {
        let tag = String(cString: get_swift_containerization_version())
        return tag == "latest"
            ? "vminit:latest"
            : "ghcr.io/apple/containerization/vminit:\(tag)"
    }

    public let image: String

    public init(image: String = defaultImage) {
        self.image = image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try container.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
    }
}

final public class KernelConfig: Codable, Sendable {
    public static let defaultBinaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
    public static let defaultURL: URL =
        URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst")!

    private enum CodingKeys: String, CodingKey {
        case binaryPath
        case url
    }

    public let binaryPath: String
    public let url: URL

    public init(
        binaryPath: String = defaultBinaryPath,
        url: URL = defaultURL
    ) {
        self.binaryPath = binaryPath
        self.url = url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.binaryPath =
            try container.decodeIfPresent(String.self, forKey: .binaryPath)
            ?? Self.defaultBinaryPath
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url),
            let parsed = URL(string: urlString)
        {
            self.url = parsed
        } else {
            self.url = Self.defaultURL
        }
    }

    // JSONEncoder special-cases URL to encode as absoluteString, but third-party
    // encoders (e.g. TOMLEncoder) hit Foundation's default Codable conformance which
    // encodes into a keyed container with a "relative" key. Encode as a plain string
    // so all formats produce a consistent URL representation.
    // If more config types start using URL, consider a property wrapper or a wrapper
    // type (like MemorySize) that encodes/decodes URL as a string uniformly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binaryPath, forKey: .binaryPath)
        try container.encode(url.absoluteString, forKey: .url)
    }
}

final public class NetworkConfig: Codable, Sendable {
    public let subnet: CIDRv4?
    public let subnetv6: CIDRv6?

    public init(subnet: CIDRv4? = nil, subnetv6: CIDRv6? = nil) {
        self.subnet = subnet
        self.subnetv6 = subnetv6
    }
}

final public class RegistryConfig: Codable, Sendable {
    public static let defaultDomain = "docker.io"

    public let domain: String

    public init(domain: String = defaultDomain) {
        self.domain = domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? Self.defaultDomain
    }
}
