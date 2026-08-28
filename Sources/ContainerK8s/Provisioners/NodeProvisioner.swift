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

import Logging

/// Well-known role identifiers for use in `NodeProvisioner.roles`.
public struct StandardRoles {
    public static let controlPlane = "control-plane"
    public static let worker = "worker"
}

/// Manages the lifecycle of a cluster node (control plane or worker).
///
/// Implement this protocol to provision nodes for a cluster created by `K8sCreate`.
///
/// For a **control-plane** node, `K8sCreate` calls:
/// 1. `provision` — start the machine before kubeadm init runs
/// 2. `address` — return the node IP, used as the advertise address and cert SAN
/// 3. `teardown` — called on failure to clean up the node
///
/// For a **worker** node, the caller additionally calls:
/// 4. `join` — run kubeadm join with the bootstrap token and CA cert hash
/// 5. `waitForReady` — poll until the node is registered and Ready in the cluster
///
/// `K8sDelete` calls `teardown` before removing cluster containers.
///
/// If any provisioner step throws, `K8sCreate` tears down the cluster before re-throwing.
public protocol NodeProvisioner: Sendable {
    /// The roles this node will serve (e.g. `[StandardRoles.controlPlane]`).
    var roles: [String] { get }

    /// Start the machine identified by `name` before cluster initialisation.
    func provision(name: String, log: Logger) async throws

    /// Return the IP address of the machine identified by `name`.
    func address(name: String, log: Logger) async throws -> String

    /// Join a worker node to the cluster using the supplied kubeadm credentials.
    ///
    /// - Parameters:
    ///   - name: Node identifier (matches the name passed to `provision`).
    ///   - controlPlaneEndpoint: `<ip>:<port>` of the control-plane API server.
    ///   - token: kubeadm bootstrap token (format `<id>.<secret>`).
    ///   - caCertHash: Discovery token CA cert hash including the `sha256:` prefix.
    func join(name: String, controlPlaneEndpoint: String, token: String, caCertHash: String, log: Logger) async throws

    /// Poll until the node with `name` is registered and Ready in the cluster.
    func waitForReady(name: String, log: Logger) async throws

    /// Remove the machine identified by `name`.
    func teardown(name: String, log: Logger) async throws
}
