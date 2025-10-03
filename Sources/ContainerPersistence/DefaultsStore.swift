//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerizationError
import Foundation

public enum DefaultsStore {
    private static let userDefaultDomain = "com.apple.container.defaults"

    public enum Keys: String {
        case buildRosetta = "build.rosetta"
        case defaultDNSDomain = "dns.domain"
        case defaultBuilderImage = "image.builder"
        case defaultInitImage = "image.init"
        case defaultKernelBinaryPath = "kernel.binaryPath"
        case defaultKernelURL = "kernel.url"
        case defaultSubnet = "network.subnet"
        case defaultRegistryDomain = "registry.domain"
    }

    public static func set(value: String, key: DefaultsStore.Keys) {
        udSuite.set(value, forKey: key.rawValue)
    }

    public static func unset(key: DefaultsStore.Keys) {
        udSuite.removeObject(forKey: key.rawValue)
    }

    public static func get(key: DefaultsStore.Keys) -> String {
        let current = udSuite.string(forKey: key.rawValue)
        return current ?? key.defaultValue
    }

    public static func getOptional(key: DefaultsStore.Keys) -> String? {
        udSuite.string(forKey: key.rawValue)
    }

    public static func setBool(value: Bool, key: DefaultsStore.Keys) {
        udSuite.set(value, forKey: key.rawValue)
    }

    public static func getBool(key: DefaultsStore.Keys) -> Bool? {
        guard udSuite.object(forKey: key.rawValue) != nil else { return nil }
        return udSuite.bool(forKey: key.rawValue)
    }

    public static func allValues() -> [DefaultsStoreValue] {
        let allKeys: [(Self.Keys, (Self.Keys) -> Any?)] = [
            (.buildRosetta, { Self.getBool(key: $0) }),
            (.defaultBuilderImage, { Self.get(key: $0) }),
            (.defaultInitImage, { Self.get(key: $0) }),
            (.defaultKernelBinaryPath, { Self.get(key: $0) }),
            (.defaultKernelURL, { Self.get(key: $0) }),
            (.defaultSubnet, { Self.getOptional(key: $0) }),
            (.defaultDNSDomain, { Self.getOptional(key: $0) }),
            (.defaultRegistryDomain, { Self.get(key: $0) }),
        ]
        return
            allKeys
            .map { DefaultsStoreValue(id: $0.rawValue, description: $0.summary, value: $1($0) as? (Encodable & CustomStringConvertible), type: $0.type) }
            .sorted(by: { $0.id < $1.id })
    }

    private static var udSuite: UserDefaults {
        guard let ud = UserDefaults.init(suiteName: self.userDefaultDomain) else {
            fatalError("Failed to initialize UserDefaults for domain \(self.userDefaultDomain)")
        }
        return ud
    }
}

public struct DefaultsStoreValue: Identifiable, CustomStringConvertible, Encodable {
    public let id: String
    public let description: String
    public let value: (Encodable & CustomStringConvertible)?
    public let type: Any.Type

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(description, forKey: .description)

        if let value = value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }

        try container.encode(String(describing: type), forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case id, description, value, type
    }
}

extension DefaultsStore.Keys {
    public var summary: String {
        switch self {
        case .buildRosetta:
            return "Build amd64 images on arm64 using Rosetta, instead of QEMU."
        case .defaultDNSDomain:
            return "If defined, the local DNS domain to use for containers with unqualified names."
        case .defaultBuilderImage:
            return "The image reference for the utility container that `container build` uses."
        case .defaultInitImage:
            return "The image reference for the default initial filesystem image."
        case .defaultKernelBinaryPath:
            return "If the kernel URL is for an archive, the archive member pathname for the kernel file."
        case .defaultKernelURL:
            return "The URL for the kernel file to install, or the URL for an archive containing the kernel file."
        case .defaultSubnet:
            return "Default subnet for IP allocation (used on macOS 15 only)."
        case .defaultRegistryDomain:
            return "The default registry to use for image references that do not specify a registry."
        }
    }

    public var type: Any.Type {
        switch self {
        case .buildRosetta:
            return Bool.self
        case .defaultDNSDomain:
            return String.self
        case .defaultBuilderImage:
            return String.self
        case .defaultInitImage:
            return String.self
        case .defaultKernelBinaryPath:
            return String.self
        case .defaultKernelURL:
            return String.self
        case .defaultSubnet:
            return String.self
        case .defaultRegistryDomain:
            return String.self
        }
    }

    fileprivate var defaultValue: String {
        switch self {
        case .buildRosetta:
            // This is a boolean key, not used with the string get() method
            return "true"
        case .defaultDNSDomain:
            return "test"
        case .defaultBuilderImage:
            let tag = String(cString: get_container_builder_shim_version())
            return "ghcr.io/apple/container-builder-shim/builder:\(tag)"
        case .defaultInitImage:
            let tag = String(cString: get_swift_containerization_version())
            guard tag != "latest" else {
                return "vminit:latest"
            }
            return "ghcr.io/apple/containerization/vminit:\(tag)"
        case .defaultKernelBinaryPath:
            return "opt/kata/share/kata-containers/vmlinux-6.12.28-153"
        case .defaultKernelURL:
            return "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
        case .defaultSubnet:
            return "192.168.64.1/24"
        case .defaultRegistryDomain:
            return "docker.io"
        }
    }
}
