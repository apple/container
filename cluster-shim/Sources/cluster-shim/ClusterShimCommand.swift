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

import ArgumentParser
import ClusterShim
import Logging

/// cluster-shim runs inside a container cluster node. It serves the kubelet's
/// CRI image service, which copies host images into containerd on demand.
@main
struct ClusterShimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cluster-shim",
        abstract: "Serve host images to a container cluster node"
    )

    @Option(help: "Host content store socket, relayed into the node")
    var hostSocket = "/opt/cluster-shim/hoststore.sock"

    @Option(help: "Socket for the kubelet's CRI image service")
    var imageSocket = "/run/cluster-shim/cri-image.sock"

    @Option(help: "containerd's API socket")
    var containerdSocket = "/run/containerd/containerd.sock"

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let paths = ShimPaths(hostSocket: hostSocket, imageSocket: imageSocket, containerdSocket: containerdSocket)
        try await runClusterShim(paths: paths, log: Logger(label: "cluster-shim"))
    }
}
