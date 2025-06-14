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

import CVersion
import ContainerizationError
import Foundation

public enum ClientDefaults {
    private static let userDefaultDomain = "com.apple.container.defaults"

    public enum Keys: String {
        case defaultBuilderImage = "image.builder"
        case defaultDNSDomain = "dns.domain"
        case defaultRegistryDomain = "registry.domain"
        case defaultInitImage = "image.init"
        case defaultKernelURL = "kernel.url"
        case defaultKernelBinaryPath = "kernel.binaryPath"
    }

    public static func set(value: String, key: ClientDefaults.Keys) {
        udSuite.set(value, forKey: key.rawValue)
    }

    public static func unset(key: ClientDefaults.Keys) {
        udSuite.removeObject(forKey: key.rawValue)
    }

    public static func get(key: ClientDefaults.Keys) -> String {
        let current = udSuite.string(forKey: key.rawValue)
        return current ?? key.defaultValue
    }

    public static func getOptional(key: ClientDefaults.Keys) -> String? {
        udSuite.string(forKey: key.rawValue)
    }

    private static var udSuite: UserDefaults {
        guard let ud = UserDefaults.init(suiteName: self.userDefaultDomain) else {
            fatalError("Failed to initialize UserDefaults for domain \(self.userDefaultDomain)")
        }
        return ud
    }
}

extension ClientDefaults.Keys {
    fileprivate var defaultValue: String {
        switch self {
        case .defaultKernelURL:
            return "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
        case .defaultKernelBinaryPath:
            return "opt/kata/share/kata-containers/vmlinux-6.12.28-153"
        case .defaultBuilderImage:
            let tag = String(cString: get_container_builder_shim_version())
            return "ghcr.io/apple/container-builder-shim/builder:\(tag)"
        case .defaultDNSDomain:
            return "test"
        case .defaultRegistryDomain:
            return "docker.io"
        case .defaultInitImage:
            let tag = String(cString: get_swift_containerization_version())
            guard tag != "latest" else {
                return "vminit:latest"
            }
            return "ghcr.io/apple/containerization/vminit:\(tag)"
        }
    }
}
