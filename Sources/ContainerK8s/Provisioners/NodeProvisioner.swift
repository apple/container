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

/// Manages the full lifecycle of an external worker node that joins a cluster created by `K8sCreate`.
///
/// Implement this protocol in a plugin binary to provision and join external machines as worker
/// nodes without modifying OSS sources.  `K8sCreate` calls the methods in this order:
///
/// 1. `provision` — set up the machine before the cluster is initialized
/// 2. `address` — return the worker IP, passed as a cert SAN to `bootstrapControlPlane`
/// 3. `join` — called with the kubeadm bootstrap token and CA cert hash after the control-plane is ready
/// 4. `waitForReady` — poll until the worker node is registered and Ready
///
/// `K8sDelete` calls `teardown` before removing cluster containers.
///
/// If any provisioner step throws, `K8sCreate` deletes the cluster before re-throwing.
public protocol NodeProvisioner: Sendable {
    /// Optional node image the provisioner prefers.  `K8sCreate` does not use this directly;
    /// it is available for the provisioner's own `provision` implementation.
    var defaultNodeImage: String? { get }

    /// Set up the external machine identified by `name` before cluster initialisation.
    func provision(name: String, log: Logger) async throws

    /// Return the IP address of the worker machine identified by `name`.
    func address(name: String, log: Logger) async throws -> String

    /// Join the worker machine to the cluster using the supplied kubeadm credentials.
    ///
    /// - Parameters:
    ///   - name: Worker node identifier (matches the name passed to `provision`).
    ///   - controlPlaneEndpoint: `<ip>:<port>` of the control-plane API server.
    ///   - token: kubeadm bootstrap token (format `<id>.<secret>`).
    ///   - caCertHash: Discovery token CA cert hash including the `sha256:` prefix.
    func join(name: String, controlPlaneEndpoint: String, token: String, caCertHash: String, log: Logger) async throws

    /// Poll until the worker node with `name` is registered and Ready in the cluster.
    func waitForReady(name: String, log: Logger) async throws

    /// Remove the external machine identified by `name`.
    func teardown(name: String, log: Logger) async throws
}
