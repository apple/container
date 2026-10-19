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

/// Manages the lifecycle of a single cluster node (control plane or worker).
///
/// Implement this protocol to provision nodes for a cluster created by `K8sCreate`.
///
/// For a **control-plane** node, `ClusterBootstrapper` calls:
/// 1. `provision` — start the node before kubeadm init runs
/// 2. `address` — return the node IP, used as the advertise address and cert SAN
/// 3. `teardown` — called on failure to clean up the node
///
/// For a **worker** node, the caller additionally calls:
/// 4. `join` — run kubeadm join with the bootstrap token and CA cert hash
/// 5. `waitForReady` — poll until the node is registered and Ready in the cluster, or
///    `waitForRegistered` when no CNI is installed (nodes stay NotReady without one)
///
/// If any step after `provision` throws, `ClusterBootstrapper` tears down the cluster before
/// re-throwing. A `provision` that throws is not followed by `teardown`, so it must leave
/// nothing behind itself.
public protocol NodeProvisioner: Sendable {
    /// The identifier of the node this provisioner manages. A worker's name must be
    /// `K8sHelper.workerName(cluster:index:)`, which `list` and `delete` rely on.
    var name: String { get }

    /// The roles this node will serve (e.g. `[StandardRoles.controlPlane]`).
    var roles: [String] { get }

    /// Start the node before cluster initialisation.
    ///
    /// If this throws, it must remove anything it created: the caller does not call
    /// `teardown` for a node whose `provision` failed.
    func provision(log: Logger) async throws

    /// Return the IP address of the node.
    func address(log: Logger) async throws -> String

    /// Join a worker node to the cluster using the supplied kubeadm credentials.
    ///
    /// - Parameters:
    ///   - controlPlaneEndpoint: `<ip>:<port>` of the control-plane API server.
    ///   - token: kubeadm bootstrap token (format `<id>.<secret>`).
    ///   - caCertHash: Discovery token CA cert hash including the `sha256:` prefix.
    func join(controlPlaneEndpoint: String, token: String, caCertHash: String, log: Logger) async throws

    /// Poll until the node is registered and Ready in the cluster.
    func waitForReady(log: Logger) async throws

    /// Poll until the node is registered in the cluster, without requiring it to be Ready.
    /// Used instead of `waitForReady` when no CNI is installed.
    func waitForRegistered(log: Logger) async throws

    /// Remove the node. Must be safe to call for a cluster that was
    /// never provisioned, and must leave nodes this provisioner did not create alone.
    func teardown(log: Logger) async throws
}
