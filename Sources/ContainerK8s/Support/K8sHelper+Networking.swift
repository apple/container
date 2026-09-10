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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging

extension K8sHelper {
    // MARK: - Networking

    private static var clusterHostPortBase: UInt16 { 6445 }

    // Returns proxy env vars with NO_PROXY augmented to bypass internal cluster CIDRs.
    // Without this, kubelet routes apiserver traffic through the host proxy and times out.
    public static func nodeProxyEnv() -> [String] {
        let bypassCIDRs = "192.168.0.0/16,\(podSubnet),\(serviceSubnet)"
        let hostEnv = ProcessInfo.processInfo.environment
        return proxyEnvVars.map { name in
            guard name.uppercased() == "NO_PROXY" else { return name }
            let existing = hostEnv[name] ?? hostEnv[name == "NO_PROXY" ? "no_proxy" : "NO_PROXY"] ?? ""
            let augmented = existing.isEmpty ? bypassCIDRs : "\(existing),\(bypassCIDRs)"
            return "\(name)=\(augmented)"
        }
    }

    private static func findAvailableHostPort(excluding: Set<UInt16> = []) throws -> UInt16 {
        var port = clusterHostPortBase
        while port < UInt16.max {
            if excluding.contains(port) {
                port += 1
                continue
            }
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                throw ContainerizationError(.internalError, message: "socket() failed while probing for available port")
            }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let available = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            Darwin.close(sock)
            if available { return port }
            port += 1
        }
        throw ContainerizationError(.internalError, message: "no available host port found above \(clusterHostPortBase)")
    }

    public static func clusterPort() async throws -> String {
        let snapshots = try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: pluginName])
        )
        let reserved = Set(snapshots.flatMap { $0.configuration.publishedPorts.map(\.hostPort) })
        let port = try findAvailableHostPort(excluding: reserved)
        return "\(port):\(clusterContainerPort)"
    }

    // MARK: - FQDN detection

    static func fqdn(for name: String, domain: String?) -> String? {
        if name.contains(".") { return name }
        guard let domain, !domain.isEmpty else { return nil }
        return "\(name).\(domain)"
    }

    static func detectFQDN(name: String) async -> String? {
        let domain = try? await ConfigurationLoader.load().dns.domain
        return fqdn(for: name, domain: domain)
    }
}
