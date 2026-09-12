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
import ContainerizationExtras
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

    /// Allocate an API server publish spec on a free host port, skipping `claimed`.
    public static func clusterPort(excluding claimed: Set<HostPort> = []) throws -> String {
        let taken = Set(claimed.lazy.filter { $0.proto == .tcp }.map(\.port))
        let port = try findAvailableHostPort(excluding: taken)
        return "\(port):\(clusterContainerPort)"
    }

    // MARK: - Published host ports

    /// A single host-side listener claimed by a publish spec. Keyed at the same
    /// granularity `[PublishPort].hasOverlaps()` collides on, so a spec that clears
    /// `ensureHostPortsAvailable` is one the runtime accepts too.
    public struct HostPort: Hashable, Sendable, CustomStringConvertible {
        let port: UInt16
        let proto: PublishProtocol

        public var description: String { "\(port)/\(proto.rawValue)" }
    }

    /// The container that published a host port, and what it forwards to.
    public struct HostPortClaim: Sendable, CustomStringConvertible {
        let container: String
        let containerPort: UInt16
        let status: RuntimeStatus
        let isCluster: Bool

        /// Whether the container is expected to be holding the host listener. A
        /// stopped container has published the port on paper only.
        var isLive: Bool { status != .stopped }

        public var description: String {
            let state: String
            switch status {
            case .running, .stopping: state = "running "
            case .stopped: state = "stopped "
            case .unknown: state = ""
            }
            let kind = isCluster ? "k8s cluster" : "container"
            let target =
                isCluster && containerPort == clusterContainerPort
                ? " for its Kubernetes API server"
                : " (-> \(containerPort))"
            return "\(state)\(kind) '\(container)'\(target)"
        }
    }

    /// Composes a node's publish list: the API server spec first, so the kubeconfig
    /// transform keeps selecting it, then the user's specs in the order given. Returns
    /// a warning for each requested port that only a stopped container claims.
    public static func composePublishPorts(userSpecs: [String], allocateAPIServer: Bool) async throws -> (specs: [String], warnings: [String]) {
        let userHostPorts = hostPorts(of: try Parser.publishPorts(userSpecs))
        let reserved = try await reservedHostPorts()
        let warnings = try ensureHostPortsAvailable(userHostPorts, reserved: reserved)
        guard allocateAPIServer else { return (userSpecs, warnings) }
        let apiServer = try clusterPort(excluding: userHostPorts.union(reserved.keys))
        return ([apiServer] + userSpecs, warnings)
    }

    /// Host ports published by existing containers, clusters and plain containers alike.
    static func reservedHostPorts() async throws -> [HostPort: HostPortClaim] {
        claims(of: try await ContainerClient().list())
    }

    /// Maps every published host port back to the container that holds it. A live
    /// claim wins over a stopped one on the same port, so the diagnostic names the
    /// container actually in the way.
    static func claims(of snapshots: [ContainerSnapshot]) -> [HostPort: HostPortClaim] {
        var claims: [HostPort: HostPortClaim] = [:]
        for snapshot in snapshots {
            let isCluster = snapshot.configuration.labels[ResourceLabelKeys.plugin] == pluginName
            for spec in snapshot.configuration.publishedPorts {
                for offset in 0..<spec.count {
                    let host = HostPort(port: spec.hostPort + offset, proto: spec.proto)
                    let claim = HostPortClaim(
                        container: snapshot.configuration.id,
                        containerPort: spec.containerPort + offset,
                        status: snapshot.status,
                        isCluster: isCluster)
                    if let existing = claims[host], existing.isLive, !claim.isLive { continue }
                    claims[host] = claim
                }
            }
        }
        return claims
    }

    /// Every host listener covered by the given publish specs, with port ranges expanded.
    static func hostPorts(of publishPorts: [PublishPort]) -> Set<HostPort> {
        var hosts: Set<HostPort> = []
        for spec in publishPorts {
            for offset in 0..<spec.count {
                hosts.insert(HostPort(port: spec.hostPort + offset, proto: spec.proto))
            }
        }
        return hosts
    }

    /// Rejects, naming the holder, any requested host port that a running container
    /// already publishes. Ports claimed only by a stopped container are free to take,
    /// and come back as warnings: that container cannot start again while this cluster
    /// holds the port. Both orderings report the lowest colliding port first, so
    /// messages stay stable across runs.
    @discardableResult
    static func ensureHostPortsAvailable(_ requested: Set<HostPort>, reserved: [HostPort: HostPortClaim]) throws -> [String] {
        let clashes =
            requested
            .compactMap { host in reserved[host].map { (host: host, claim: $0) } }
            .sorted { ($0.host.port, $0.host.proto.rawValue) < ($1.host.port, $1.host.proto.rawValue) }

        if let live = clashes.first(where: { $0.claim.isLive }) {
            throw ContainerizationError(
                .invalidArgument,
                message: "host port \(live.host) is already published by \(live.claim); choose a different host port")
        }
        return clashes.map {
            "host port \($0.host) is also published by \($0.claim), which cannot start again while this cluster holds the port"
        }
    }

    /// Renders a publish spec for the `PORTS` column as
    /// `[host-ip:]host-port[-end]->container-port[-end][/protocol]`. Host address and
    /// protocol are elided when they carry no information, so a plain TCP publish on
    /// every interface stays as terse as `8080->30080`.
    static func renderPublishPort(_ spec: PublishPort) -> String {
        let address: String
        if spec.hostAddress.isUnspecified {
            address = ""
        } else if spec.hostAddress.isV6 {
            address = "[\(spec.hostAddress)]:"
        } else {
            address = "\(spec.hostAddress):"
        }
        let range = { (start: UInt16) in spec.count > 1 ? "\(start)-\(start + spec.count - 1)" : "\(start)" }
        let proto = spec.proto == .tcp ? "" : "/\(spec.proto.rawValue)"
        return "\(address)\(range(spec.hostPort))->\(range(spec.containerPort))\(proto)"
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
